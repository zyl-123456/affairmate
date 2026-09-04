// 应用状态中枢 · 事务伴侣
// 对应设计：D-006 最小闭环——输入 → 三件套组装 → API → 解析 → 两库落盘 → UI 刷新
// M-009：schedule 持久化（按日期分桶，重启恢复今日）+ clientFactory 测试注入点
// M-011：聊天历史持久化（chat.json 截尾 200 条）+ 对话上下文滑窗入报文

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../data/safe_io.dart';
import '../llm/providers.dart';

/// 聊天界面的一条消息
class ChatMsg {
  final String text;
  final bool fromUser;
  final List<String> sideLog; // 库变更摘要（给用户看的透明度）

  const ChatMsg(this.text, {this.fromUser = false, this.sideLog = const []});

  Map<String, dynamic> toJson() => {
        'text': text,
        'from_user': fromUser,
        'side_log': sideLog,
      };

  factory ChatMsg.fromJson(Map<String, dynamic> j) => ChatMsg(
        (j['text'] ?? '').toString(),
        fromUser: j['from_user'] == true,
        sideLog: ((j['side_log'] as List?) ?? [])
            .map((e) => e.toString())
            .toList(growable: false),
      );
}

/// 全局应用状态：两库 + 聊天 + 供应商 + 日程
class AppState extends ChangeNotifier {
  final Repo repo;
  final File scheduleFile;
  final File chatFile;

  /// 依赖注入：测试传 FakeClient 工厂；生产默认真实 LlmClient
  final LlmClient Function(ProviderConfig config)? clientFactory;

  /// 报文携带的最近对话条数（C2 反问续答 / 指代理解所需的最小窗口，C-003 从简）
  static const kContextWindow = 6;

  List<Matter> matters = [];
  List<StateDay> stateDays = [];
  List<ChatMsg> chat = [];
  List<ScheduleBlock> schedule = []; // 今日安排块

  List<ProviderConfig> providers = [];
  String? activeProviderId;
  bool sending = false;
  String? error;

  AppState(this.repo, {File? scheduleFile, File? chatFile, this.clientFactory})
      : scheduleFile = scheduleFile ??
            File('${repo.mattersFile.parent.path}${Platform.pathSeparator}schedule.json'),
        chatFile = chatFile ??
            File('${repo.mattersFile.parent.path}${Platform.pathSeparator}chat.json') {
    matters = repo.loadMatters();
    stateDays = repo.loadState();
    schedule = _loadScheduleFor(today());
    chat = _loadChat();
  }

  // ============ 日程持久化（schedule.json 按日期分桶）============

  static String today() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  // ============ 聊天历史持久化（chat.json，截尾 200 条）============

  List<ChatMsg> _loadChat() {
    final decoded = readJsonWithFallback(chatFile);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((m) => ChatMsg.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  void _persistChat() {
    // 截尾 200 条：全量历史对单用户无收益，防文件无限膨胀（C-003）
    final kept = chat.length > 200 ? chat.sublist(chat.length - 200) : chat;
    safeWriteJson(chatFile, kept.map((m) => m.toJson()).toList());
  }

  Map<String, dynamic> _readScheduleAll() {
    final decoded = readJsonWithFallback(scheduleFile);
    if (decoded is! Map) return {};
    return Map<String, dynamic>.from(decoded);
  }

  List<ScheduleBlock> _loadScheduleFor(String date) {
    final all = _readScheduleAll();
    final bucket = all[date];
    if (bucket is! List) return [];
    return bucket
        .whereType<Map>()
        .map((m) => ScheduleBlock.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  void _persistSchedule(List<ScheduleBlock> blocks) {
    final all = _readScheduleAll();
    all[today()] = blocks.map((b) => b.toJson()).toList();
    // 只保留最近 30 天，防止无限增长（C-003 精简）
    final keys = all.keys.toList()..sort();
    while (keys.length > 30) {
      all.remove(keys.first);
      keys.removeAt(0);
    }
    safeWriteJson(scheduleFile, all);
  }

  /// M-013 合并语义：新安排块只覆盖与其时间**重叠**的旧块，非重叠旧块保留。
  /// 修复"下午安排冲掉上午安排"的整体覆盖 bug；结果按开始时间排序。
  static List<ScheduleBlock> mergeSchedule(
      List<ScheduleBlock> old, List<ScheduleBlock> incoming) {
    final kept = <ScheduleBlock>[];
    for (final o in old) {
      final os = o.startMinutes;
      final oe = o.endMinutes;
      // 旧块时间不完整 → 无法判重叠，保守保留
      if (os == null || oe == null) {
        kept.add(o);
        continue;
      }
      final overlapped = incoming.any((n) {
        final ns = n.startMinutes;
        final ne = n.endMinutes;
        if (ns == null || ne == null) return false;
        return ns < oe && ne > os; // 区间相交
      });
      if (!overlapped) kept.add(o);
    }
    final merged = [...kept, ...incoming];
    merged.sort((a, b) =>
        (a.startMinutes ?? 0).compareTo(b.startMinutes ?? 0));
    return merged;
  }

  // ============ 供应商 ============

  Future<void> loadProviders() async {
    providers = await ProviderStore.loadAll();
    activeProviderId = await ProviderStore.activeId();
    notifyListeners();
  }

  Future<void> saveProvider(ProviderConfig c, {bool activate = false}) async {
    await ProviderStore.save(c);
    if (activate) {
      await ProviderStore.setActive(c.id);
      activeProviderId = c.id;
    }
    await loadProviders();
  }

  Future<void> deleteProvider(String id) async {
    await ProviderStore.delete(id);
    if (activeProviderId == id) activeProviderId = null;
    await loadProviders();
  }

  Future<void> activateProvider(String id) async {
    await ProviderStore.setActive(id);
    activeProviderId = id;
    notifyListeners();
  }

  // ============ 对话上下文（M-011 滑窗 + M-014 过滤）============

  /// 提取发给模型的最近对话：排除最后一条（本轮刚发的），排除错误气泡（⚠️ 开头），
  /// 从过滤后的流里取最近 window 条。纯函数便于单测。
  static List<Map<String, dynamic>> dialogueContext(
      List<ChatMsg> chat, int window) {
    final prior = chat.length - 1;
    if (prior <= 0) return const [];
    final usable = chat
        .sublist(0, prior)
        .where((m) => !m.text.startsWith('⚠️'))
        .toList();
    if (usable.isEmpty) return const [];
    final start = usable.length > window ? usable.length - window : 0;
    return usable
        .sublist(start)
        .map((m) => {'role': m.fromUser ? 'user' : 'assistant', 'text': m.text})
        .toList();
  }

  // ============ 核心闭环 ============

  /// 从盘上重载两库与日程（详情弹窗手动归档/恢复后刷新 UI 用，M-017）
  void reloadFromRepo() {
    matters = repo.loadMatters();
    stateDays = repo.loadState();
    schedule = _loadScheduleFor(today());
    notifyListeners();
  }

  LlmClient? _activeClient() {
    final c = providers.where((p) => p.id == activeProviderId).firstOrNull;
    if (c == null || c.apiKey.isEmpty) return null;
    if (clientFactory != null) return clientFactory!(c);
    return LlmClient(c);
  }

  bool get ready => _activeClient() != null;

  /// 发一句话：沟通模式（默认）或安排模式
  Future<void> send(String text, {bool arrangeMode = false}) async {
    if (text.trim().isEmpty || sending) return;
    final client = _activeClient();
    if (client == null) {
      error = '未配置可用的模型供应商（或 Key 为空），请到设置页添加';
      chat = [
        ...chat,
        ChatMsg(text, fromUser: true),
        const ChatMsg('⚠️ 还没配置模型供应商。请点右上角设置，添加 API 供应商后再聊。'),
      ];
      notifyListeners();
      return;
    }

    chat = [...chat, ChatMsg(text, fromUser: true)];
    sending = true;
    error = null;
    notifyListeners();

    // 对话上下文滑窗：本轮之前最近 N 条（不含刚发的这句），供模型理解指代与反问续答
    final recent = dialogueContext(chat, kContextWindow);

    try {
      final rf = await client.chat(
        matters: matters,
        state: stateDays,
        userMessage: text,
        arrangeMode: arrangeMode,
        recentDialogue: recent,
      );

      // 应用增量（App 侧确定性规则）
      final log = <String>[];
      if (rf.matterOps.isNotEmpty) {
        final r = repo.applyMatterOps(rf.matterOps);
        matters = r.data as List<Matter>;
        log.addAll(r.log);
      }
      if (rf.stateUpdates.isNotEmpty) {
        final r = repo.applyStateUpdates(rf.stateUpdates);
        stateDays = r.data as List<StateDay>;
        log.addAll(r.log);
      }
      if (rf.scheduleBlocks.isNotEmpty) {
        // M-013 合并语义：非重叠旧块保留，重叠的被新安排替换
        schedule = mergeSchedule(schedule, rf.scheduleBlocks);
        _persistSchedule(schedule);
      }

      final replyText = rf.reply.trim().isEmpty ? '（模型未给回复文字）' : rf.reply;
      chat = [...chat, ChatMsg(replyText, sideLog: log)];
    } on LlmException catch (e) {
      error = e.message;
      chat = [
        ...chat,
        ChatMsg('⚠️ 模型调用失败：${e.message}'),
      ];
    } on SocketException catch (e) {
      error = e.message;
      chat = [
        ...chat,
        const ChatMsg('⚠️ 网络不通或供应商域名不可达，请检查网络与配置。'),
      ];
    } catch (e) {
      error = e.toString();
      chat = [...chat, ChatMsg('⚠️ 出错了：$e')];
    } finally {
      _persistChat(); // 无论成败，聊天历史落盘（M-011）
      sending = false;
      notifyListeners();
    }
  }
}
