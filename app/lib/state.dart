// 应用状态中枢 · 事务伴侣
// 对应设计：D-006 最小闭环——输入 → 三件套组装 → API → 解析 → 两库落盘 → UI 刷新
// M-009：schedule 持久化（按日期分桶，重启恢复今日）+ clientFactory 测试注入点
// M-011：聊天历史持久化（chat.json 截尾 200 条）+ 对话上下文滑窗入报文

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../data/profile.dart';
import '../data/repo.dart';
import '../data/safe_io.dart';
import '../llm/notify.dart';
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

/// 全局应用状态：两库 + 用户画像 + 双模式独立会话 + 供应商 + 日程
class AppState extends ChangeNotifier {
  final Repo repo;
  final File scheduleFile;
  final File chatFile;
  late final ProfileStore profileStore; // M-031 用户画像（第三库）
  UserProfile profile = const UserProfile();

  /// 依赖注入：测试传 FakeClient 工厂；生产默认真实 LlmClient
  final LlmClient Function(ProviderConfig config)? clientFactory;

  /// 报文携带的最近对话条数（C2 反问续答 / 指代理解所需的最小窗口，C-003 从简）
  static const kContextWindow = 6;

  List<Matter> matters = [];
  List<StateDay> stateDays = [];
  List<ScheduleBlock> schedule = []; // 今日安排块
  UserPlaybook playbook = const UserPlaybook(); // 个人说明书（底色层，M-032）

  // 双模式独立会话（M-024 老大裁决 B 方案）：沟通/安排各自窗口，互不污染
  List<ChatMsg> chatChat = []; // 沟通模式会话
  List<ChatMsg> chatArrange = []; // 安排模式会话
  List<ChatMsg> get chat => chatChat; // 兼容旧调用方（默认沟通视角）

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
    _loadChats();
    // M-033 总档案（合并结构，含旧 playbook 自动迁移）
    profileStore = ProfileStore(File(
        '${repo.mattersFile.parent.path}${Platform.pathSeparator}profile.json'));
    profile = profileStore.load();
    playbook = UserPlaybook(
      traits: profile.traits,
      patterns: profile.patterns,
      recharges: profile.recharges,
      preferences: profile.preferences,
      lastReviewAt: profile.lastReviewAt,
    );
  }

  /// 保存用户总档案（设置页调用）：盘上落定 + 内存同步。
  /// M-033 防覆盖：设置页编辑的是用户字段（nickname/items/时间线），
  /// 四板块是 AI 维护的——save 前先并入当前内存四板块，避免手动保存清空说明书。
  Future<void> saveProfile(UserProfile p) async {
    final merged = p.copyWith(
      traits: p.traits.isNotEmpty ? p.traits : profile.traits,
      patterns: p.patterns.isNotEmpty ? p.patterns : profile.patterns,
      recharges: p.recharges.isNotEmpty ? p.recharges : profile.recharges,
      preferences:
          p.preferences.isNotEmpty ? p.preferences : profile.preferences,
      lastReviewAt:
          p.lastReviewAt.isNotEmpty ? p.lastReviewAt : profile.lastReviewAt,
    );
    await profileStore.save(merged);
    profile = merged;
    // M-033 合并档案：四板块并入 profile，playbook 内存镜像同步（懂我页等消费方无感）
    playbook = UserPlaybook(
      traits: p.traits,
      patterns: p.patterns,
      recharges: p.recharges,
      preferences: p.preferences,
      lastReviewAt: p.lastReviewAt,
    );
    notifyListeners();
  }

  /// 报文用的档案视图（M-033 合并口径：nickname+身份线+items+四板块浓缩）
  Map<String, dynamic> get profileWire => profile.toWireJson();

  // ============ 10 天大复盘（M-036，REQ-012 C 方案之后半）============

  /// 复盘周期（天）——设置项可调（老大 2026-09-06 裁决），默认 10。
  int reviewCycleDays = 10;

  /// 设置页调用：调周期（M-036 可调项）
  Future<void> setReviewCycle(int days) async {
    reviewCycleDays = days;
    notifyListeners();
  }

  /// 是否到复盘点：距上次复盘 ≥ 周期天 且 状态库有 ≥7 天记录（数据不足不空转）。
  /// 首次使用（last_review_at 空）从状态库最早记录日起算。
  bool get dueForReview {
    if (stateDays.length < 7) return false; // 数据不足
    final last = DateTime.tryParse(profile.lastReviewAt);
    DateTime anchor;
    if (last != null) {
      anchor = last;
    } else {
      // 从未复盘：以状态库最早日期起算（不是安装日——没用够不算）
      final earliest = stateDays.map((d) => d.date).toList()..sort();
      anchor = DateTime.tryParse(earliest.first) ?? DateTime.now();
    }
    final elapsed = DateTime.now().difference(anchor).inDays;
    return elapsed >= reviewCycleDays;
  }

  /// 执行复盘（横幅「现在复盘」触发）：大信→复盘单→验货入账→时钟归零→汇报气泡。
  /// 失败不消耗周期（last_review_at 仅成功后更新，D5）。
  Future<void> runReview() async {
    if (sending) return;
    final client = _activeClient();
    if (client == null) {
      error = '复盘需要可用的模型供应商';
      notifyListeners();
      return;
    }
    sending = true;
    notifyListeners();
    try {
      final rf = await client.reviewChat(
        state: stateDays,
        scheduleAll: _readScheduleAll(),
        playbook: playbook,
        userProfile: profileWire,
        days: reviewCycleDays * 2, // 状态数据给两倍周期，供交叉验证
      );

      final log = <String>['📅 10 天复盘完成'];
      if (rf.playbookOps.isNotEmpty) {
        // D4 撤销保护：origin=user 条目不可 remove——在验货前过滤
        final protected = <int>[];
        final sections = {
          'traits': playbook.traits,
          'patterns': playbook.patterns,
          'recharges': playbook.recharges,
          'preferences': playbook.preferences,
        };
        final ops = <PlaybookOp>[];
        for (final o in rf.playbookOps) {
          if (o.op == 'remove') {
            final list = sections[o.section];
            final i = int.tryParse(o.index ?? '-1') ?? -1;
            if (list != null && i >= 0 && i < list.length && list[i].origin == 'user') {
              protected.add(i);
              log.add('保护亲述条目「${list[i].content}」不被撤销（用户主权）');
              continue;
            }
          }
          ops.add(o);
        }
        final r = repo.applyPlaybookOps(ops, base: playbook); // M-036：以内存真相源为基础
        final newPb = r.data as UserPlaybook;
        profile = profile.copyWith(
          traits: newPb.traits,
          patterns: newPb.patterns,
          recharges: newPb.recharges,
          preferences: newPb.preferences,
          lastReviewAt: DateTime.now().toIso8601String(), // 时钟归零（成功路径）
        );
        await profileStore.save(profile);
        playbook = newPb;
        log.addAll(r.log);
      } else {
        // 无条目变动也要归零时钟（复盘做了，只是没结论）
        profile = profile.copyWith(lastReviewAt: DateTime.now().toIso8601String());
        await profileStore.save(profile);
      }

      final report = rf.reply.trim().isEmpty ? '（复盘完成，无特别发现）' : rf.reply;
      _appendSession(false, ChatMsg(report, sideLog: log));
    } on LlmException catch (e) {
      error = e.message;
      _appendSession(false, ChatMsg('⚠️ 复盘失败：${e.message}（周期未消耗，可稍后再试）'));
    } catch (e) {
      error = e.toString();
      _appendSession(false, ChatMsg('⚠️ 复盘出错：$e（周期未消耗）'));
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  // ============ 日程持久化（schedule.json 按日期分桶）============

  static String today() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  // ============ 双模式会话持久化（chat.json 按模式分桶，截尾 200 条/模式）============

  Map<String, dynamic> _readChatAll() {
    final decoded = readJsonWithFallback(chatFile);
    if (decoded is! Map) return {};
    return Map<String, dynamic>.from(decoded);
  }

  List<ChatMsg> _chatFromBucket(dynamic bucket) {
    if (bucket is! List) return [];
    return bucket
        .whereType<Map>()
        .map((m) => ChatMsg.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  void _loadChats() {
    final all = _readChatAll();
    // 兼容迁移：旧版 chat.json 是纯数组（单会话）→ 全部归入沟通模式
    if (all.isEmpty && chatFile.existsSync()) {
      final legacy = readJsonWithFallback(chatFile);
      if (legacy is List) chatChat = _chatFromBucket(legacy);
      return;
    }
    chatChat = _chatFromBucket(all['chat']);
    chatArrange = _chatFromBucket(all['arrange']);
  }

  void _persistChat() {
    // 截尾 200 条/模式：全量历史对单用户无收益，防文件无限膨胀（C-003）
    List<Map<String, dynamic>> trim(List<ChatMsg> l) =>
        (l.length > 200 ? l.sublist(l.length - 200) : l)
            .map((m) => m.toJson())
            .toList();
    safeWriteJson(chatFile, {
      'chat': trim(chatChat),
      'arrange': trim(chatArrange),
    });
  }

  Map<String, dynamic> _readScheduleAll() {
    final decoded = readJsonWithFallback(scheduleFile);
    if (decoded is! Map) return {};
    return Map<String, dynamic>.from(decoded);
  }

  /// 展示页日历回看用（M-034）：只读访问日程文件
  File get scheduleFileForRead => scheduleFile;

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
    // M-034：日程永久保留（老大 2026-09-05 裁决——回看每一天是核心价值；
    // 一天几 KB，一年 ~1MB，个人软件无压力）
    safeWriteJson(scheduleFile, all);
  }

  /// M-035 时间空洞：主轨（track=0）未覆盖的时段。返回 [(startMin, endMin)]。
  /// 口径：只看主轨——伴随轨是搭车主，不算覆盖；阈值 minMinutes 以下的不算洞。
  static List<(int, int)> uncoveredGaps(List<ScheduleBlock> blocks,
      {int fromMinute = 0, int toMinute = 1440, int minMinutes = 15}) {
    final mains = blocks
        .where((b) => !b.isParallel && b.startMinutes != null && b.endMinutes != null)
        .map((b) => (b.startMinutes!, b.endMinutes!))
        .toList()
      ..sort((a, b) => a.$1.compareTo(b.$1));
    final gaps = <(int, int)>[];
    var cursor = fromMinute.clamp(0, 1440);
    final end = toMinute.clamp(0, 1440);
    for (final (s, e) in mains) {
      if (s > cursor && s - cursor >= minMinutes) gaps.add((cursor, s));
      if (e > cursor) cursor = e;
    }
    if (end > cursor && end - cursor >= minMinutes) gaps.add((cursor, end));
    return gaps;
  }

  static String fmtMin(int m) =>
      '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  /// M-013 合并语义 + M-034 多轨制：新块只覆盖**同轨且时间重叠**的旧块。
  /// 不同轨互不干扰（主轨重排不动伴随轨的背单词；伴随轨更新不冲主轨）。
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
        if (n.track != o.track) return false; // 异轨不冲突（M-034）
        final ns = n.startMinutes;
        final ne = n.endMinutes;
        if (ns == null || ne == null) return false;
        return ns < oe && ne > os; // 区间相交
      });
      if (!overlapped) kept.add(o);
    }
    final merged = [...kept, ...incoming];
    merged.sort((a, b) {
      final byStart =
          (a.startMinutes ?? 0).compareTo(b.startMinutes ?? 0);
      return byStart != 0 ? byStart : a.track.compareTo(b.track); // 同起点主轨在前
    });
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

  /// 发一句话：沟通模式（默认）或安排模式。双模式独立会话（M-024）：
  /// 各模式的气泡列表、持久化桶、recent_dialogue 滑窗互不混杂。
  Future<void> send(String text, {bool arrangeMode = false}) async {
    if (text.trim().isEmpty || sending) return;
    final session = arrangeMode ? chatArrange : chatChat;
    final client = _activeClient();
    if (client == null) {
      error = '未配置可用的模型供应商（或 Key 为空），请到设置页添加';
      _replaceSession(arrangeMode, [
        ...session,
        ChatMsg(text, fromUser: true),
        const ChatMsg('⚠️ 还没配置模型供应商。请点右上角设置，添加 API 供应商后再聊。'),
      ]);
      notifyListeners();
      return;
    }

    _replaceSession(arrangeMode, [...session, ChatMsg(text, fromUser: true)]);
    sending = true;
    error = null;
    notifyListeners();

    // 对话上下文滑窗：本会话（同模式）内、本轮之前最近 N 条，供模型理解指代与反问续答
    final recent = dialogueContext(
        arrangeMode ? chatArrange : chatChat, kContextWindow);

    try {
      final rf = await client.chat(
        matters: matters,
        state: stateDays,
        userMessage: text,
        arrangeMode: arrangeMode,
        recentDialogue: recent,
        userProfile: profileWire, // M-031 画像随报文（nickname+身份信息）
        playbook: playbook, // M-032 底色层随报文（个人说明书）
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
      if (rf.playbookOps.isNotEmpty) {
        // M-032 说明书增量：改底色必须明示（log 进气泡摘要 = 用户可见可纠）
        // M-033：总档案为唯一真源——ops 应用到合并档案，playbook 镜像同步
        final pbApplied = repo.applyPlaybookOps(rf.playbookOps, base: playbook); // M-036 内存真相源
        final newPb = pbApplied.data as UserPlaybook;
        profile = profile.copyWith(
          traits: newPb.traits,
          patterns: newPb.patterns,
          recharges: newPb.recharges,
          preferences: newPb.preferences,
        );
        await profileStore.save(profile); // 并入总档案落盘
        playbook = newPb;
        log.addAll(pbApplied.log);
      }
      if (rf.scheduleBlocks.isNotEmpty) {
        // M-013 合并语义：非重叠旧块保留，重叠的被新安排替换
        schedule = mergeSchedule(schedule, rf.scheduleBlocks);
        _persistSchedule(schedule);
      }

      final replyText = rf.reply.trim().isEmpty ? '（模型未给回复文字）' : rf.reply;
      _appendSession(arrangeMode, ChatMsg(replyText, sideLog: log));
      // M-037a：后台时结果走系统通知栏（REQ-015；前台不打扰）
      NotifyService.showReply(
        arrangeMode: arrangeMode,
        replyText: replyText,
        blockLines: [
          for (final b in rf.scheduleBlocks)
            '${b.start}~${b.end} ${b.matterRef}${b.isParallel ? ' ∥' : ''}',
        ],
      );
    } on LlmException catch (e) {
      error = e.message;
      _appendSession(arrangeMode, ChatMsg('⚠️ 模型调用失败：${e.message}'));
    } on SocketException catch (e) {
      error = e.message;
      _appendSession(
          arrangeMode, const ChatMsg('⚠️ 网络不通或供应商域名不可达，请检查网络与配置。'));
    } catch (e) {
      error = e.toString();
      _appendSession(arrangeMode, ChatMsg('⚠️ 出错了：$e'));
    } finally {
      _persistChat(); // 无论成败，聊天历史落盘（M-011；M-024 起两桶齐落）
      sending = false;
      notifyListeners();
    }
  }

  // ============ 会话桶操作（M-024 双模式独立会话）============

  void _replaceSession(bool arrangeMode, List<ChatMsg> newList) {
    if (arrangeMode) {
      chatArrange = newList;
    } else {
      chatChat = newList;
    }
  }

  void _appendSession(bool arrangeMode, ChatMsg msg) {
    if (arrangeMode) {
      chatArrange = [...chatArrange, msg];
    } else {
      chatChat = [...chatChat, msg];
    }
  }
}
