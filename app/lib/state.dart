// 应用状态中枢 · 事务伴侣
// 对应设计：D-006 最小闭环——输入 → 三件套组装 → API → 解析 → 两库落盘 → UI 刷新
// M-009：schedule 持久化（按日期分桶，重启恢复今日）+ clientFactory 测试注入点
// M-011：聊天历史持久化（chat.json 截尾 200 条）+ 对话上下文滑窗入报文

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/models.dart';
import '../data/profile.dart';
import '../data/repo.dart';
import '../data/safe_io.dart';
import '../data/daily_snapshot.dart';
import '../data/day_plan_archive.dart';
import '../platform/power_service.dart';
import '../data/wire_log.dart';
import '../data/usage_log.dart';
import '../llm/alarm_player.dart';
import '../llm/audio_store.dart';
import '../llm/notify.dart';
import '../llm/prompt.dart';
import '../llm/providers.dart';

/// 聊天界面的一条消息
/// M-081：闹钟历史记录（展示页闹铃卡片的数据）
class AlarmRecord {
  final String setAt; // 设置时刻 ISO
  final String wakeAt; // 应响时刻 ISO
  final int slot; // 铃声槽位
  final bool wantBrief; // 是否晨报
  final String userPhrase; // 用户原话
  final bool done; // 已响过（到点触发过=打勾）

  const AlarmRecord({
    required this.setAt,
    required this.wakeAt,
    this.slot = 1,
    this.wantBrief = false,
    this.userPhrase = '',
    this.done = false,
  });

  factory AlarmRecord.fromJson(Map<String, dynamic> j) => AlarmRecord(
        setAt: (j['set_at'] ?? '').toString(),
        wakeAt: (j['wake_at'] ?? '').toString(),
        slot: (j['slot'] as num?)?.toInt() ?? 1,
        wantBrief: j['want_brief'] == true,
        userPhrase: (j['user_phrase'] ?? '').toString(),
        done: j['done'] == true,
      );

  Map<String, dynamic> toJson() => {
        'set_at': setAt,
        'wake_at': wakeAt,
        'slot': slot,
        'want_brief': wantBrief,
        'user_phrase': userPhrase,
        'done': done,
      };
}

class ChatMsg {
  final String text;
  final bool fromUser;
  final List<String> sideLog; // 库变更摘要（给用户看的透明度）
  final int promptTokens; // 本轮输入 token（M-058）
  final int completionTokens; // 本轮输出 token（M-058）
  final String at; // 消息时刻 HH:mm（M-062：每条消息显示发送/接收时间）

  const ChatMsg(this.text,
      {this.fromUser = false,
      this.sideLog = const [],
      this.promptTokens = 0,
      this.completionTokens = 0,
      this.at = ''});

  Map<String, dynamic> toJson() => {
        'text': text,
        'from_user': fromUser,
        'side_log': sideLog,
        if (promptTokens > 0) 'prompt_tokens': promptTokens,
        if (completionTokens > 0) 'completion_tokens': completionTokens,
        if (at.isNotEmpty) 'at': at,
      };

  factory ChatMsg.fromJson(Map<String, dynamic> j) => ChatMsg(
        (j['text'] ?? '').toString(),
        fromUser: j['from_user'] == true,
        sideLog: ((j['side_log'] as List?) ?? [])
            .map((e) => e.toString())
            .toList(growable: false),
        promptTokens: (j['prompt_tokens'] as int?) ?? 0,
        completionTokens: (j['completion_tokens'] as int?) ?? 0,
        at: (j['at'] ?? '').toString(),
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
  List<Goal> goals = []; // 目标账本（M-039）

  // 双模式独立会话（M-024 老大裁决 B 方案）：沟通/安排各自窗口，互不污染
  List<ChatMsg> chatChat = []; // 沟通模式会话
  List<ChatMsg> chatArrange = []; // 安排模式会话
  List<ChatMsg> get chat => chatChat; // 兼容旧调用方（默认沟通视角）

  List<ProviderConfig> providers = [];
  String? activeProviderId;
  bool sending = false;
  String? error;
  String streamingPreview = ''; // M-046 流式预览
  int _lastPromptTokens = 0; // M-058：本轮输入 token
  int _lastPayloadBytes = 0; // M-087：最近一轮报文体积（快照记录用）
  bool _snapshotChecked = false; // M-087：今日快照是否已检查过
  int _lastCompletionTokens = 0; // M-058：本轮输出 token
  // M-060 晨报：醒来时刻（App 内持久化小文件）+ 今日晨报是否已发
  DateTime? _wakeAt;
  Timer? _alarmTimer; // M-080：秒级直达闹钟（不等分钟轮询）
  int alarmSlot = 1; // M-061b：本次闹钟用的铃声槽位（对话可选，默认1）
  bool _wakeWantBrief = true; // M-063：醒时要不要晨报（"纯叫我"场景=false）
  static int _goalIdSeq = 0; // M-074：目标 id 防碰撞序号
  bool _isRemedyRound = false; // M-076 V1：补救轮标记（防无限递归）
  List<AlarmRecord> alarmHistory = []; // M-081：闹钟历史（展示页卡片）
  File get _alarmLogFile =>
      File('${repo.mattersFile.parent.path}${Platform.pathSeparator}alarm_log.json');

  void _loadAlarmHistory() {
    try {
      if (_alarmLogFile.existsSync()) {
        final j = jsonDecode(_alarmLogFile.readAsStringSync());
        if (j is List) {
          alarmHistory = j
              .whereType<Map>()
              .map((m) => AlarmRecord.fromJson(Map<String, dynamic>.from(m)))
              .toList();
        }
      }
    } catch (_) {}
  }

  void _saveAlarmHistory() {
    try {
      // 保留最近 200 条
      if (alarmHistory.length > 200) {
        alarmHistory = alarmHistory.sublist(alarmHistory.length - 200);
      }
      _alarmLogFile.writeAsStringSync(jsonEncode(alarmHistory.map((a) => a.toJson()).toList()));
    } catch (_) {}
  }

  /// M-081：记录一次闹钟设置
  void _logAlarm(String userPhrase) {
    if (_wakeAt == null) return;
    alarmHistory.add(AlarmRecord(
      setAt: DateTime.now().toIso8601String(),
      wakeAt: _wakeAt!.toIso8601String(),
      slot: alarmSlot,
      wantBrief: _wakeWantBrief,
      userPhrase: userPhrase.length > 40 ? userPhrase.substring(0, 40) : userPhrase,
    ));
    _saveAlarmHistory();
  }

  /// M-081：到点触发后打勾
  void markAlarmDone() {
    var changed = false;
    for (var i = 0; i < alarmHistory.length; i++) {
      final a = alarmHistory[i];
      final wake = DateTime.tryParse(a.wakeAt);
      if (!a.done && wake != null && DateTime.now().isAfter(wake)) {
        alarmHistory[i] = AlarmRecord(
          setAt: a.setAt, wakeAt: a.wakeAt, slot: a.slot,
          wantBrief: a.wantBrief, userPhrase: a.userPhrase, done: true);
        changed = true;
      }
    }
    if (changed) _saveAlarmHistory();
  }
  // 测试注入：测试环境禁用 wakelock（无平台通道会崩）
  static bool _wakelockCapable = true;
  @visibleForTesting
  static set wakelockCapable(bool v) => _wakelockCapable = v;
  // M-065 goal delete：applyGoalOps 内直接改 matters（上面已做）
  String get _wakeAtFile =>
      '${repo.mattersFile.parent.path}${Platform.pathSeparator}wake.json';
  bool _briefSentToday = false;

  AppState(this.repo, {File? scheduleFile, File? chatFile, this.clientFactory})
      : scheduleFile = scheduleFile ??
            File('${repo.mattersFile.parent.path}${Platform.pathSeparator}schedule.json'),
        chatFile = chatFile ??
            File('${repo.mattersFile.parent.path}${Platform.pathSeparator}chat.json') {
    matters = repo.loadMatters();
    stateDays = repo.loadState();
    goals = repo.loadGoals(); // M-039
    _loadWakeState(); // M-060
    _loadSettleMark(); // M-096b：日终结算标记
    _loadAlarmHistory(); // M-081
    _dedupeGoalIds(); // M-074：存量同 id 目标重分配（历史碰撞数据自愈）
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

  /// 测试入口（M-040 e2e）：应用并回写内存（模拟 send() 路径行为）
  (List<Goal>, List<String>) applyGoalOpsForTest(List<GoalOp> ops) {
    final r = _applyGoalOps(ops);
    goals = r.$1;
    return r;
  }

  // ============ M-060 晨报机制 ============

  /// M-074：修复历史 ID 碰撞——同 id 多目标时保留第一个，其余重分配唯一 id
  void _dedupeGoalIds() {
    final seen = <String>{};
    var changed = false;
    goals = goals.map((g) {
      if (seen.contains(g.id)) {
        changed = true;
        return g.copyWith(
            id: 'g_${DateTime.now().millisecondsSinceEpoch}_${_goalIdSeq++}_fix',
            updatedAt: DateTime.now().toIso8601String());
      }
      seen.add(g.id);
      return g;
    }).toList();
    if (changed) repo.saveGoals(goals);
  }

  void _loadWakeState() {
    try {
      final f = File(_wakeAtFile);
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync());
        if (j is Map) {
          _wakeAt = DateTime.tryParse((j['wake_at'] ?? '').toString());
          final lastBrief = (j['brief_date'] ?? '').toString();
          _briefSentToday = lastBrief == today();
          _wakeWantBrief = j['want_brief'] == true; // M-092：恢复真实意图（旧文件无此键=false，纯闹钟安全默认）
          // M-092b：已过期的残留闹钟——清系统通知（安卓会补发错过的 exact alarm，
          // 这就是"没设却响了"的来源），再决定是否排新 Timer
          if (_wakeAt != null && DateTime.now().isAfter(_wakeAt!)) {
            NotifyService.cancelMorningBrief();
            if (DateTime.now().difference(_wakeAt!) <= const Duration(hours: 2) && _wakeWantBrief) {
              // 2h 内且要晨报：保留，由轮询补发
            } else {
              _wakeAt = null; // 纯闹钟过期 = 作废（响过没响都翻篇，别诈尸）
              _saveWakeState();
              PowerService.stopAlarmGuard(); // M-094
            }
          }
          _scheduleExactRing(); // M-080：重启后恢复秒级直达
        }
      }
    } catch (_) {}
  }

  void _saveWakeState() {
    try {
      File(_wakeAtFile).writeAsStringSync(jsonEncode({
        'wake_at': _wakeAt?.toIso8601String() ?? '',
        'brief_date': _briefSentToday ? today() : '',
        'want_brief': _wakeWantBrief, // M-092：持久化——否则重启后被默认 true 复活（幽灵晨报根因）
      }));
    } catch (_) {}
  }

  /// 睡眠/闹钟意图识别（M-063 分级）：
  /// "叫醒我/叫我/闹钟/提醒" → 纯闹钟（响铃即止，不出晨报）
  /// "我要睡了/休息" → 睡眠（响铃+晨报+规划）
  /// 返回：none / alarmOnly / sleepBrief
  Future<String> detectSleepIntent(String text) async {
    final t = text;
    // 匹配"睡到 HH点/H点" 或 "睡 N 个小时/小时" 或 "睡 N 分钟"（M-061b 午睡）
    // M-062：中文数字归一化（一→1 两/二→2 三→3…半→0.5）——"睡一分钟/睡半小时"能认
    final normalized = t
        .replaceAllMapped(RegExp(r'[一二两三四五六七八九十半]'), (m) {
          const cn = {'一': '1', '二': '2', '两': '2', '三': '3', '四': '4', '五': '5',
                      '六': '6', '七': '7', '八': '8', '九': '9', '十': '10', '半': '0.5'};
          return cn[m.group(0)]!;
        });
    final wakeMatch = RegExp(r'睡到[^0-9.]*(\d{1,2})[点时:：]').firstMatch(normalized);
    final durMatch =
        RegExp(r'睡[^0-9.]*(\d{1,3}(?:\.\d)?)\s*[个]?[小]?时').firstMatch(normalized);
    final minMatch = RegExp(r'睡[^0-9.]*(\d{1,4})\s*分钟?').firstMatch(normalized);
    // M-077（老大 19:28 日志破案）：闹钟句不带"睡"字也要能触发——
    // "设一个三分钟之后的闹钟"/"N分钟后叫我/提醒我"
    // M-078b：回补日志点名的漏网模式——"设定一个5分钟之后的闹钟"（数字前有"个"等量词噪声）、
    // "睡8个小时"（"个小时"口径）。取最后一个数字段为准（避免"一个5分钟"吃到"1"）。
    final hasAlarmWord = normalized.contains('闹钟') ||
        normalized.contains('叫') ||
        normalized.contains('提醒');
    final alarmMinMatch = hasAlarmWord || normalized.contains('睡')
        ? RegExp(r'(\d{1,4})\s*分钟').firstMatch(normalized)
        : null;
    final alarmHourMatch = hasAlarmWord || normalized.contains('睡')
        ? RegExp(r'(\d{1,2})\s*[个]?小时').firstMatch(normalized)
        : null;
    // M-061b：可选铃声槽位（"用铃声3"/"用3号铃声"/"铃声2叫我"）
    final slotMatch =
        RegExp(r'铃声\s*([1-4])|([1-4])\s*号铃声').firstMatch(t);
    if (slotMatch != null) {
      alarmSlot = int.parse(slotMatch.group(1) ?? slotMatch.group(2)!);
    }
    final hasTime = wakeMatch != null ||
        durMatch != null ||
        minMatch != null ||
        alarmMinMatch != null ||
        alarmHourMatch != null;
    if (!hasTime) return 'none';
    // M-079 晨报显式制（老大 02:31 裁决，废弃 M-066 时长分级猜语义）：
    // 唤醒意图的表达里出现"晨报"二字 → 出晨报；没有 → 一律纯闹钟。
    // 判定从"猜"变"认死理"——零误判，代价是用户要记得说"晨报"俩字。
    final sleepWord = normalized.contains('睡') || normalized.contains('休息');

    if (normalized.contains('晨报')) {
      _wakeWantBrief = true; // 显式要求晨报
    } else {
      _wakeWantBrief = false; // 没提晨报 = 纯闹钟（哪怕是整夜睡眠）
    }
    // 保留意图词校验：既非睡眠词也无闹钟词则不触发（防误伤普通消息）
    final alarmWord = normalized.contains('叫醒') ||
        normalized.contains('叫我') ||
        normalized.contains('闹钟') ||
        normalized.contains('提醒我') ||
        normalized.contains('响铃通知') ||
        normalized.contains('测试');
    if (!sleepWord && !alarmWord) {
      return 'none';
    }

    DateTime wake;
    final now = DateTime.now();
    if (wakeMatch != null) {
      final h = int.parse(wakeMatch.group(1)!) % 24;
      wake = DateTime(now.year, now.month, now.day, h);
      if (!wake.isAfter(now)) wake = wake.add(const Duration(days: 1)); // 已过=明早
    } else if (minMatch != null) {
      wake = now.add(Duration(minutes: int.parse(minMatch.group(1)!)));
    } else if (alarmMinMatch != null) {
      wake = now.add(Duration(minutes: int.parse(alarmMinMatch.group(1)!)));
    } else if (alarmHourMatch != null) {
      wake = now.add(Duration(hours: int.parse(alarmHourMatch.group(1)!)));
    } else {
      final hours = double.parse(durMatch!.group(1)!);
      wake = now.add(Duration(minutes: (hours * 60).round()));
    }
    _wakeAt = wake;
    _briefSentToday = false; // 新睡眠周期：下次醒时再触发
    _saveWakeState();
    await NotifyService.cancelMorningBrief();
    await NotifyService.scheduleMorningBrief(wake);
    // M-093：设闹钟瞬间确保通知权限在线（第三防线——揣兜被杀时系统通知是唯一响铃通道）
    final nOk = await NotifyService.notificationsEnabled();
    if (!nOk) await NotifyService.requestNotifyPermission();
    _scheduleExactRing(); // M-080：秒级直达
    _logAlarm(text); // M-081：入历史
    // M-094：前台服务守护——黑屏/揣兜期间系统不杀进程（亮屏等就响、黑屏等就哑的终结者）
    final hm0 = '${wake.hour.toString().padLeft(2, '0')}:${wake.minute.toString().padLeft(2, '0')}';
    await PowerService.startAlarmGuard('闹钟已设 · $hm0 响');
    return _wakeWantBrief ? 'sleepBrief' : 'alarmOnly';
  }
  // M-066 意图判定结束

  /// M-096b：日终结算触发——跨过 0 点后首次检查时结算昨天（补漏：次日任何时刻启动都会补）
  Future<void> maybeDayEndSettle() async {
    final now = DateTime.now();
    final y = DateTime(now.year, now.month, now.day - 1);
    final yesterday = '${y.year}-${y.month.toString().padLeft(2, '0')}-${y.day.toString().padLeft(2, '0')}';
    if (_lastSettledDate == null || _lastSettledDate!.compareTo(yesterday) < 0) {
      await settleDayInvestment(yesterday);
    }
  }

  /// M-087：每日数据快照——每天 08:00 后首次检查时拍（错过时段补拍）。
  /// 数据是软件优化的底座（老大 01:59 数据观）：快照序列 = 增长的可视化证据。
  Future<void> maybeDailySnapshot() async {
    if (_snapshotChecked) return;
    _snapshotChecked = true;
    final now = DateTime.now();
    if (now.hour < 8) {
      _snapshotChecked = false; // 还没到 08:00，下小时再查
      return;
    }
    final date = today();
    if (await DailySnapshot.hasToday(date)) return;
    try {
      await DailySnapshot.capture(
        date: date,
        matters: matters.map((m) => m.toJson()).toList(),
        goals: goals.map((g) => g.toJson()).toList(),
        stateDays: stateDays.map((s) => s.toJson()).toList(),
        chatChat: _todayMessages(chatChat),
        chatArrange: _todayMessages(chatArrange),
        playbook: playbook.toJson(),
        profile: profileWire.isNotEmpty ? profileWire : null,
        lastPayloadBytes: _lastPayloadBytes,
      );
      UsageLog.log('APP', '每日数据快照已保存（$date）');
    } catch (_) {}
  }

  List<Map<String, dynamic>> _todayMessages(List<ChatMsg> msgs) {
    // 会话本体已截尾 200 条/桶；快照再保险截 400——体积永远可控
    final all = msgs.map((m) => m.toJson()).toList();
    return all.length > 400 ? all.sublist(all.length - 400) : all;
  }

  /// M-080：排秒级直达闹钟——到点直接响铃（不等 10 秒轮询，更不等被冻结的周期器）
  void _scheduleExactRing() {
    _alarmTimer?.cancel();
    if (_wakeAt == null) return;
    final delay = _wakeAt!.difference(DateTime.now());
    if (delay.isNegative || delay.inSeconds > 24 * 3600) return; // 已过/超远不排
    _alarmTimer = Timer(delay, () {
      runMorningBrief(); // M-095：到点直接触发（内部自判 ringDue——纯闹钟也响）
    });
  }

  /// 到达醒时且今日未发 → 自动触发晨报（main 层定时/App 生命周期回调调用）
  bool get morningBriefDue {
    if (_wakeAt == null || _briefSentToday || !_wakeWantBrief) return false;
    final now = DateTime.now();
    // M-085：醒时已过 2 小时仍未触发=陈旧记录（跨天残留/已响过的旧账）——
    // 清掉不触发（幽灵晨报根治：昨晚的闹钟不能在今天凌晨诈尸）
    if (now.difference(_wakeAt!) > const Duration(hours: 2)) {
      _wakeAt = null;
      _saveWakeState();
      return false;
    }
    return now.isAfter(_wakeAt!);
  }

  /// 到点执行：响铃（播放器循环响）+ 按意图决定是否晨报
  Future<void> runMorningBrief() async {
    // M-095：铃声与晨报解耦——到点+未触发过就必响铃（纯闹钟也想响！）
    // 旧 bug：这里查 morningBriefDue（含 !wantBrief）→ 纯闹钟第一行就被
    // return 挡死，铃声代码永远到不了——"守护条在+记录在+不响"的真凶。
    final now = DateTime.now();
    final ringDue = _wakeAt != null &&
        now.isAfter(_wakeAt!) &&
        !_briefSentToday &&
        now.difference(_wakeAt!) <= const Duration(hours: 2);
    if (!ringDue) return;
    _briefSentToday = true; // 先标记防重入
    _saveWakeState();
    markAlarmDone(); // M-081：到点触发 → 历史打勾
    PowerService.stopAlarmGuard(); // M-094：响过了，撤守护
    // M-063：播放器直接响（循环直到停）+ 全屏通知（视觉）
    String? s;
    try {
      s = await AudioStore.slotPath(alarmSlot) ?? await AudioStore.slotPath(1);
    } catch (_) {}
    await AlarmPlayer.start(s);
    await NotifyService.showAlarm(
      title: _wakeWantBrief ? '该醒了' : '时间到',
      body: _wakeWantBrief ? '晨报正在生成——今天的安排马上就好' : '你定的闹钟到了',
    );
    if (!_wakeWantBrief) return; // 纯闹钟：响完就完
    try {
      await send(kMorningBriefUserMessage, arrangeMode: true);
    } catch (e) {
      _briefSentToday = false; // 失败回滚，下次再试
      _saveWakeState();
      UsageLog.err('ALARM', '晨报生成失败（回滚待重试）：$e');
      notifyListeners();
    }
  }

  /// M-096：人工编辑事项全属性（老大要求：AI 之外人也要能改）
  Future<void> manualEditMatter(String id,
      {String? name, Map<String, String>? core, Map<String, dynamic>? ext}) async {
    final i = matters.indexWhere((m) => m.id == id);
    if (i < 0) return;
    final j = matters[i].toJson();
    if (name != null && name.trim().isNotEmpty) j['name'] = name.trim();
    if (core != null) {
      final c = (j['core'] as Map?) ?? {};
      for (final e in core.entries) {
        if (e.value.trim().isNotEmpty) c[e.key] = e.value.trim();
      }
      j['core'] = c;
    }
    if (ext != null) {
      final x = (j['ext'] as Map?) ?? {};
      for (final e in ext.entries) {
        if (e.value.toString().trim().isNotEmpty) x[e.key] = e.value;
      }
      j['ext'] = x;
    }
    matters[i] = Matter.fromJson(Map<String, dynamic>.from(j));
    repo.saveMatters(matters);
    notifyListeners();
  }

  /// M-096：人工写入状态（manual 标记与 AI 推断区分）
  Future<void> manualWriteState(String dimKey, String value, String evidence) async {
    final d = today();
    final idx = stateDays.indexWhere((s) => s.date == d);
    final j = idx >= 0 ? stateDays[idx].toJson() : {'date': d};
    final dims = (j['dims'] as Map?) ?? {};
    dims[dimKey] = {
      'value': value,
      'evidence': evidence.isNotEmpty ? evidence : '人工写入',
      'manual': true,
    };
    j['dims'] = dims;
    final updated = StateDay.fromJson(Map<String, dynamic>.from(j));
    if (idx >= 0) {
      stateDays[idx] = updated;
    } else {
      stateDays.insert(0, updated);
    }
    repo.saveState(stateDays);
    notifyListeners();
  }

  /// M-089：给时间块回评（照做/改时做了/没做）——安排效果数据闭环
  Future<void> reviewBlock(String date, String start, String matterRef, String review) async {
    final all = _loadScheduleFor(date);
    var changed = false;
    final updated = all.map((b) {
      if (b.date == date && b.start == start && b.matterRef == matterRef && b.review != review) {
        changed = true;
        return b.copyWith(review: review);
      }
      return b;
    }).toList();
    if (changed) {
      if (date == today()) {
        schedule = updated;
        _persistSchedule(updated);
      } else {
        _persistScheduleByDate({date: updated});
      }
      notifyListeners();
    }
  }

  /// M-096b：日终结算——把某天时间条上的最终块形态记入各事项投入履历。
  /// 幂等：同一天重复结算以最终形态覆盖（结算标记防跨天重算）。
  String? _lastSettledDate; // 已结算到哪天（内存+盘存）
  Future<void> settleDayInvestment(String date) async {
    try {
      if (_lastSettledDate != null && date.compareTo(_lastSettledDate!) <= 0) return;
      final blocks = _loadScheduleFor(date);
      // 按事项名聚合当日总时长
      final byMatter = <String, double>{};
      for (final b in blocks) {
        final d = b.date.isNotEmpty ? b.date : date;
        if (d != date) continue;
        final s = _hhmmToMin(b.start), e = _hhmmToMin(b.end);
        if (s == null || e == null || e <= s) continue;
        byMatter[b.matterRef] = (byMatter[b.matterRef] ?? 0) + (e - s) / 60.0;
      }
      var changed = false;
      matters = matters.map((m) {
        final hrs = byMatter[m.name];
        final log = [...m.investLog.where((l) => l['date'] != date)]; // 先剔除当日旧记录
        if (hrs != null && hrs > 0) {
          log.add({'date': date, 'hours': ((hrs * 10).round() / 10).toString(), 'note': '日终结算'});
          changed = true;
        } else if (log.length != m.investLog.length) {
          changed = true; // 当日块被清空的修正
        }
        return changed && log.length != m.investLog.length ? _matterWithInvest(m, log) : m;
      }).toList();
      if (changed) repo.saveMatters(matters);
      _lastSettledDate = date;
      _saveSettleMark(date);
      // M-097：安排史存档 finalize——最终形态+当日回评计数（晨报学习闭环的原料）
      final finalJson = blocks.map((b) => b.toJson()).toList();
      var doneN = 0, movedN = 0, skippedN = 0;
      for (final b in blocks) {
        if (b.review == 'done') doneN++;
        if (b.review == 'moved') movedN++;
        if (b.review == 'skipped') skippedN++;
      }
      await DayPlanArchive.finalize(date, finalJson,
          doneCount: doneN, movedCount: movedN, skippedCount: skippedN);
      if (date == today()) {
        UsageLog.log('APP', '当日投入已结算（$date，${byMatter.length} 个事项）');
      }
    } catch (_) {}
  }

  File get _settleMarkFile =>
      File('${repo.mattersFile.parent.path}${Platform.pathSeparator}invest_settle_mark.json');

  void _saveSettleMark(String date) {
    try {
      _settleMarkFile.writeAsStringSync('{"last_settled": "$date"}');
    } catch (_) {}
  }

  void _loadSettleMark() {
    try {
      if (_settleMarkFile.existsSync()) {
        final j = jsonDecode(_settleMarkFile.readAsStringSync());
        if (j is Map) _lastSettledDate = (j['last_settled'] ?? '').toString();
      }
    } catch (_) {}
  }

  static Matter _matterWithInvest(Matter m, List<Map<String, String>> log) {
    // Matter 无 copyWith 全参——经 json 往返最稳
    final j = m.toJson();
    j['invest_log'] = log;
    return Matter.fromJson(j);
  }

  static int? _hhmmToMin(String hhmm) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm);
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!), mm = int.tryParse(m.group(2)!);
    if (h == null || mm == null) return null;
    return h * 60 + mm;
  }

  // ============ M-065 目标人工管理（长按菜单）============

  Future<void> renameGoal(String id, String title) async {
    final i = goals.indexWhere((g) => g.id == id);
    if (i < 0) return;
    goals[i] = goals[i].copyWith(title: title, updatedAt: DateTime.now().toIso8601String());
    repo.saveGoals(goals);
    notifyListeners();
  }

  Future<void> archiveGoal(String id) async {
    final i = goals.indexWhere((g) => g.id == id);
    if (i < 0) return;
    goals[i] = goals[i].copyWith(active: false, updatedAt: DateTime.now().toIso8601String());
    repo.saveGoals(goals);
    notifyListeners();
  }

  Future<void> restoreGoal(String id) async {
    final i = goals.indexWhere((g) => g.id == id);
    if (i < 0) return;
    goals[i] = goals[i].copyWith(active: true, updatedAt: DateTime.now().toIso8601String());
    repo.saveGoals(goals);
    notifyListeners();
  }

  Future<void> deleteGoal(String id) async {
    goals = goals.where((g) => g.id != id).toList();
    matters = matters.map((m) => m.goalRef == id ? m.copyWith(goalRef: '') : m).toList();
    repo.saveGoals(goals);
    repo.saveMatters(matters);
    notifyListeners();
  }

  // ============ M-069 事项人工管理（长按菜单）============

  Future<void> renameMatter(String id, String name) async {
    final i = matters.indexWhere((m) => m.id == id);
    if (i < 0) return;
    matters[i] = matters[i].copyWith(name: name, updatedAt: DateTime.now().toIso8601String());
    repo.saveMatters(matters);
    notifyListeners();
  }

  Future<void> archiveMatter(String id) async {
    final i = matters.indexWhere((m) => m.id == id);
    if (i < 0) return;
    matters[i] = matters[i].copyWith(active: false, updatedAt: DateTime.now().toIso8601String());
    repo.saveMatters(matters);
    notifyListeners();
  }

  Future<void> deleteMatter(String id) async {
    matters = matters.where((m) => m.id != id).toList();
    repo.saveMatters(matters);
    notifyListeners();
  }

  /// M-039 目标操作应用。返回 (新目标列表, 日志)。
  (List<Goal>, List<String>) _applyGoalOps(List<GoalOp> ops) {
    var list = [...goals];
    final log = <String>[];
    final now = DateTime.now().toIso8601String();
    for (final o in ops) {
      switch (o.op) {
        case 'add':
          final t = (o.title ?? '').trim();
          if (t.isEmpty) {
            log.add('丢弃目标新增：标题为空');
            continue;
          }
          final reqs = o.requirements
              .map((r) => r.trim())
              .where((r) => r.isNotEmpty)
              .toList();
          final g = Goal(
            id: 'g_${DateTime.now().millisecondsSinceEpoch}_${_goalIdSeq++}', // M-074：防同毫秒碰撞（一轮建多目标时旧写法全撞同一 id）
            title: t,
            requirements: reqs, // M-052：建目标时提炼要求清单
            createdAt: now,
            updatedAt: now,
          );
          list = [...list, g];
          log.add('新目标「$t」已建立');
          if (reqs.isNotEmpty) log.add('目标要求 ${reqs.length} 项已记录');
        case 'update':
          final i = list.indexWhere((g) => g.id == o.id);
          if (i < 0) {
            log.add('丢弃目标修改：找不到 ${o.id}');
            continue;
          }
          final t = (o.title ?? '').trim();
          list[i] = list[i].copyWith(title: t.isEmpty ? null : t, updatedAt: now);
          log.add('目标改为「${list[i].title}」');
        case 'update_requirements': // M-052：改要求清单（全量替换）
          final i = list.indexWhere((g) => g.id == o.id);
          if (i < 0) {
            log.add('丢弃要求更新：目标不存在');
            continue;
          }
          final reqs = o.requirements
              .map((r) => r.trim())
              .where((r) => r.isNotEmpty)
              .toList();
          list[i] = list[i].copyWith(requirements: reqs, updatedAt: now);
          log.add('「${list[i].title}」要求清单已更新（${reqs.length} 项）');
        case 'archive':
          final i = list.indexWhere((g) => g.id == o.id);
          if (i < 0) continue;
          // M-053：goal_type 已删——类型保护随之移除。
          // 统一哲学（老大 03:20+03:38）：完成不是关键点，AI 不得主动判完成
          // （提示词 F4 管）；archive 只在用户明确说达成/搁置时发生。
          if ((o.progress ?? '').contains('AI判断达成')) {
            continue; // 防线保留：AI 自作主张的完成判定丢弃
          }
          list[i] = list[i].copyWith(active: false, updatedAt: now);
          log.add('目标「${list[i].title}」已归档（达成或搁置）');
        case 'restore':
          final i = list.indexWhere((g) => g.id == o.id);
          if (i < 0) continue;
          list[i] = list[i].copyWith(active: true, updatedAt: now);
          log.add('目标「${list[i].title}」重新激活');
        case 'delete': // M-065：真删（用户明确说删除时）——旗下事项解除挂靠不删
          final i = list.indexWhere((g) => g.id == o.id);
          if (i < 0) {
            log.add('丢弃 delete：目标不存在（id=${o.id}）');
            continue;
          }
          final title = list[i].title;
          list.removeAt(i);
          // 旗下事项解挂（事项本身保留，转为未归属）
          matters = matters
              .map((m) => m.goalRef == o.id ? (m.copyWith(goalRef: '')) : m)
              .toList();
          log.add('目标「$title」已删除（旗下事项转为未归属）');
        case 'set_progress':
          final i = list.indexWhere((g) => g.id == o.id);
          if (i < 0) continue;
          final p = (o.progress ?? '').trim();
          if (p.isEmpty) continue;
          // M-040 累积式进度：新进度 append 进 history（不覆盖旧记录，老大裁决）；
          // progress 字段仍存最新一条供展示。
          final today = o.date?.isNotEmpty == true
              ? o.date!
              : now.substring(0, 10);
          final hist = [
            ...list[i].progressHistory,
            {'date': today, 'note': p},
          ];
          // 防膨胀：终身型目标历史长——保留最近 200 条（约大半年日更量级）
          final trimmed =
              hist.length > 200 ? hist.sublist(hist.length - 200) : hist;
          list[i] = list[i].copyWith(
              progress: p, progressHistory: trimmed, updatedAt: now);
          log.add('目标「${list[i].title}」进度记录 +1（$today）');
        case 'attach_matter':
          // 把事项挂到目标：改 matters 的 goal_ref（一事项一目标，老大裁决）
          final gi = list.indexWhere((g) => g.id == o.id);
          if (gi < 0) {
            log.add('丢弃挂靠：目标不存在');
            continue;
          }
          var ms = repo.loadMatters();
          var hit = false;
          final updated = <Matter>[];
          for (final m in ms) {
            if ((o.matterId != null && m.id == o.matterId) ||
                (o.matterName != null && m.active && m.name == o.matterName)) {
              hit = true;
              log.add('「${m.name}」已归入目标「${list[gi].title}」');
              updated.add(m.copyWith(goalRef: list[gi].id, updatedAt: now));
            } else {
              updated.add(m);
            }
          }
          if (hit) repo.saveMatters(updated);
          if (!hit) log.add('挂靠失败：找不到该事项');
        default:
          log.add('丢弃目标操作：未知 op ${o.op}');
      }
    }
    repo.saveGoals(list);
    return (list, log);
  }

  // ============ M-050 人工编辑（懂我页，老大 22:00 需求）============

  /// 改说明书条目（section+index 定位）；人工改的条目 origin='user' + evidence 标记
  Future<void> editPlaybookEntry(String section, int index, String newContent) async {
    final sections = {
      'traits': profile.traits, 'patterns': profile.patterns,
      'recharges': profile.recharges, 'preferences': profile.preferences,
    };
    final list = sections[section];
    if (list == null || index < 0 || index >= list.length) return;
    final updated = [...list];
    updated[index] = updated[index].copyWith(
      content: newContent,
      origin: 'user',
      evidence: '老大手工修订',
      updatedAt: DateTime.now().toIso8601String(),
    );
    profile = profile.copyWith(
      traits: section == 'traits' ? updated.cast<ProfileEntry>() : null,
      patterns: section == 'patterns' ? updated.cast<ProfileEntry>() : null,
      recharges: section == 'recharges' ? updated.cast<ProfileEntry>() : null,
      preferences: section == 'preferences' ? updated.cast<ProfileEntry>() : null,
    );
    await profileStore.save(profile);
    _syncPlaybookFromProfile();
    notifyListeners();
  }

  /// 删说明书条目
  Future<void> deletePlaybookEntry(String section, int index) async {
    final sections = {
      'traits': profile.traits, 'patterns': profile.patterns,
      'recharges': profile.recharges, 'preferences': profile.preferences,
    };
    final list = sections[section];
    if (list == null || index < 0 || index >= list.length) return;
    final updated = [...list]..removeAt(index);
    profile = profile.copyWith(
      traits: section == 'traits' ? updated.cast<ProfileEntry>() : null,
      patterns: section == 'patterns' ? updated.cast<ProfileEntry>() : null,
      recharges: section == 'recharges' ? updated.cast<ProfileEntry>() : null,
      preferences: section == 'preferences' ? updated.cast<ProfileEntry>() : null,
    );
    await profileStore.save(profile);
    _syncPlaybookFromProfile();
    notifyListeners();
  }

  /// 改身份段（index 定位；identity/from/to 可空=不改）
  Future<void> editIdentity(int index, {String? identity, String? from, String? to}) async {
    final tl = [...profile.identityTimeline];
    if (index < 0 || index >= tl.length) return;
    tl[index] = tl[index].copyWith(
      identity: identity?.trim().isEmpty == true ? null : identity?.trim(),
      from: from?.trim().isEmpty == true ? null : from?.trim(),
      to: to?.trim().isEmpty == true ? null : to?.trim(),
    );
    profile = profile.copyWith(identityTimeline: tl);
    await profileStore.save(profile);
    _syncPlaybookFromProfile();
    notifyListeners();
  }

  /// 删身份段
  Future<void> deleteIdentity(int index) async {
    final tl = [...profile.identityTimeline];
    if (index < 0 || index >= tl.length) return;
    tl.removeAt(index);
    profile = profile.copyWith(identityTimeline: tl);
    await profileStore.save(profile);
    _syncPlaybookFromProfile();
    notifyListeners();
  }

  /// 改称呼
  Future<void> setNickname(String nickname) async {
    profile = profile.copyWith(nickname: nickname.trim());
    await profileStore.save(profile);
    notifyListeners();
  }

  void _syncPlaybookFromProfile() {
    playbook = UserPlaybook(
      traits: profile.traits, patterns: profile.patterns,
      recharges: profile.recharges, preferences: profile.preferences,
      lastReviewAt: profile.lastReviewAt,
    );
  }

  /// M-038 档案操作：set_nickname / add_identity（新段）/ end_identity（末段补 to）。
  /// 返回 (新档案, 日志)；非法 op 丢弃记日志。
  (UserProfile, List<String>) _applyProfileOps(List<ProfileOp> ops) {
    var p = profile;
    final log = <String>[];
    for (final o in ops) {
      switch (o.op) {
        case 'set_nickname':
          final n = (o.nickname ?? '').trim();
          if (n.isEmpty) {
            log.add('丢弃 set_nickname：称呼为空');
            continue;
          }
          p = p.copyWith(nickname: n);
          log.add('称呼已设为「$n」');
        case 'add_identity':
          final id = (o.identity ?? '').trim();
          if (id.isEmpty) {
            log.add('丢弃 add_identity：身份为空');
            continue;
          }
          // 若末段未结束，先补 to（AI 通常同时发 end_identity；此处兜底）
          var timeline = [...p.identityTimeline];
          if (timeline.isNotEmpty && timeline.last.isCurrent && o.to.isNotEmpty) {
            timeline[timeline.length - 1] = timeline.last.copyWith(to: o.to);
          }
          timeline = [...timeline, IdentityPeriod(
            identity: id, from: o.from, note: o.note)];
          p = p.copyWith(identityTimeline: timeline);
          log.add('身份入档：${o.from.isNotEmpty ? '${o.from}起 ' : ''}$id');
        case 'end_identity':
          var timeline = [...p.identityTimeline];
          if (timeline.isEmpty || !timeline.last.isCurrent) {
            log.add('丢弃 end_identity：无进行中的身份段');
            continue;
          }
          timeline[timeline.length - 1] = timeline.last.copyWith(to: o.to);
          p = p.copyWith(identityTimeline: timeline);
          log.add('身份段结束于 ${o.to}');
        case 'update_identity': // M-045 UI-02：改段（描述/年份/时间）
          var timeline = [...p.identityTimeline];
          final i = int.tryParse(o.index) ?? -1;
          if (i < 0 || i >= timeline.length) {
            log.add('丢弃 update_identity：序号越界（$i）');
            continue;
          }
          timeline[i] = timeline[i].copyWith(
            identity: (o.identity ?? '').trim().isEmpty ? null : o.identity!.trim(),
            from: o.from.isEmpty ? null : o.from,
            to: o.to.isEmpty ? null : o.to,
            note: o.note.isEmpty ? null : o.note,
          );
          p = p.copyWith(identityTimeline: timeline);
          log.add('身份段已改为「${timeline[i].identity}」');
        case 'remove_identity': // M-045 UI-02：删段
          var timeline = [...p.identityTimeline];
          final i = int.tryParse(o.index) ?? -1;
          if (i < 0 || i >= timeline.length) {
            log.add('丢弃 remove_identity：序号越界（$i）');
            continue;
          }
          log.add('身份段「${timeline[i].identity}」已删除');
          timeline.removeAt(i);
          p = p.copyWith(identityTimeline: timeline);
        default:
          log.add('丢弃档案操作：未知 op ${o.op}');
      }
    }
    return (p, log);
  }

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
        goals: goals, // M-039：目标进复盘（定期更新进度的主通道）
        matters: matters,
      );

      final log = <String>['📅 10 天复盘完成'];
      if (rf.goalOps.isNotEmpty) {
        // M-039：复盘更新目标进度
        final r = _applyGoalOps(rf.goalOps);
        goals = r.$1;
        log.addAll(r.$2);
      }
      if (rf.profileOps.isNotEmpty) {
        // M-038：身份/称呼对话自动维护（老大裁决：不让用户填表）
        final r = _applyProfileOps(rf.profileOps);
        profile = r.$1;
        await profileStore.save(profile);
        playbook = UserPlaybook(
          traits: profile.traits, patterns: profile.patterns,
          recharges: profile.recharges, preferences: profile.preferences,
          lastReviewAt: profile.lastReviewAt,
        );
        log.addAll(r.$2);
      }
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

  /// M-047 补录：按日期分桶落盘（历史时段归位到真实那天）
  void _persistScheduleByDate(Map<String, List<ScheduleBlock>> byDate) {
    final all = _readScheduleAll();
    for (final e in byDate.entries) {
      final old = (all[e.key] as List? ?? [])
          .whereType<Map>()
          .map((m) => ScheduleBlock.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      all[e.key] = mergeSchedule(old, e.value)
          .map((b) => b.toJson())
          .toList();
    }
    safeWriteJson(scheduleFile, all);
    // 若补录含今天，刷新内存
    if (byDate.containsKey(today())) {
      schedule = _loadScheduleFor(today());
    }
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

    final nowHm =
        '${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}';
    _replaceSession(arrangeMode,
        [...session, ChatMsg(text, fromUser: true, at: nowHm)]);
    UsageLog.log('CHAT',
        '发(${arrangeMode ? '安排' : '沟通'}) ${text.length}字: ${text.length > 50 ? '${text.substring(0, 50)}…' : text}');
    final _sendSw = Stopwatch()..start();
    // M-065（BUG-02）：发送期间保活——黑屏下系统 Doze 不掐网络（屏黑但连接在）
    // 测试环境（无平台通道，wakelockCapable=false）跳过
    if (_wakelockCapable) WakelockPlus.enable();
    sending = true;
    streamingPreview = ''; // M-046 重置流式预览
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
        goals: goals, // M-039 目标账本随报文（大局观）
        onDelta: (d) {
          // M-046：流式增量 → UI 实时显示（首字即见，不再干等）
          streamingPreview += d;
          notifyListeners();
        },
        onUsage: (pt, ct) {
          _lastPromptTokens = pt;
          _lastCompletionTokens = ct;
        },
        onTiming: (connectMs, ttfbMs, totalMs, chunkCount) {
          // M-066/067：耗时分解落使用日志（chunk 数=吞吐健康度）
          UsageLog.log('CHAT',
              '分解 建连${connectMs}ms 首字${ttfbMs}ms 全程${totalMs}ms 块数$chunkCount');
        },
        deepThink: text == kMorningBriefUserMessage, // M-073：晨报开深度思考（全天权衡复杂题）
        onWire: (payload, raw) {
          // M-088：轮级线上实录——完整包裹+原始作业落盘（归因分析的原料）
          WireLog.logTurn(
            arrangeMode: arrangeMode,
            userSaid: text,
            payload: payload,
            rawResponse: raw,
            promptTokens: _lastPromptTokens,
            completionTokens: _lastCompletionTokens,
            elapsedMs: _sendSw.elapsedMilliseconds,
          );
        },
      );
      streamingPreview = ''; // 完成后清预览（正式气泡已落位）

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
      if (rf.goalOps.isNotEmpty) {
        // M-039 目标操作：add/update/archive/restore/set_progress/attach_matter
        final r = _applyGoalOps(rf.goalOps);
        goals = r.$1;
        matters = repo.loadMatters(); // attach 可能改了事项的 goal_ref
        log.addAll(r.$2);
      }
      if (rf.profileOps.isNotEmpty) {
        // M-038：身份/称呼对话自动维护（老大裁决：不让用户填表）
        final r = _applyProfileOps(rf.profileOps);
        profile = r.$1;
        await profileStore.save(profile);
        playbook = UserPlaybook(
          traits: profile.traits, patterns: profile.patterns,
          recharges: profile.recharges, preferences: profile.preferences,
          lastReviewAt: profile.lastReviewAt,
        );
        log.addAll(r.$2);
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
        // M-013 合并语义 + M-047 补录分桶：
        // 带 date 的块（补录历史）落到对应日期桶；不带（今天的安排）走原逻辑
        final todayBlocks = <ScheduleBlock>[];
        final byDate = <String, List<ScheduleBlock>>{};
        for (final b in rf.scheduleBlocks) {
          if (b.date.isEmpty) {
            todayBlocks.add(b);
          } else {
            byDate.putIfAbsent(b.date, () => []).add(b);
          }
        }
        // M-083：修正日程——replace 日期先清空该日，再落新块（治"旧块残留叠加"）
        if (rf.scheduleReplaceDates.isNotEmpty) {
          schedule = schedule
              .where((b) => !rf.scheduleReplaceDates.contains(b.date))
              .toList();
          log.add('已清空 ${rf.scheduleReplaceDates.join("、")} 的旧安排，以本次为准');
        }
        if (todayBlocks.isNotEmpty) {
          // M-097：当天首次落块=晨报初稿存档；后续=修改追记（学习闭环原料）
          final date0 = today();
          final json0 = todayBlocks.map((b) => b.toJson()).toList();
          await DayPlanArchive.saveDraft(date0, json0);
          await DayPlanArchive.addRevision(date0, {
            'at': DateTime.now().toIso8601String(),
            'blocks': json0.map((b) => "\${b['start']}~\${b['end']} \${b['matter_ref']}").join('; '),
          });
          schedule = mergeSchedule(schedule, todayBlocks);
          _persistSchedule(schedule);
          // M-096b：不再落块即累计（晨报草案≠最终执行）——当日 24 点日终结算
        }
        if (byDate.isNotEmpty) {
          _persistScheduleByDate(byDate);
          log.add('已补录 ${byDate.length} 天的历史时段');
        }
      }

      // M-076 V1 作业单回执：有操作被拒 → 把失败清单回喂 AI 补救（最多一次）
      // 设计（老大裁决的"验收模式"）：全绿零成本；有红才回喂；补救轮再失败就如实上报
      if (!_isRemedyRound) {
        final failures = log
            .where((l) => l.contains('丢弃') ||
                l.contains('越界') ||
                l.contains('不存在') ||
                l.contains('失败'))
            .toList();
        if (failures.isNotEmpty &&
            (rf.matterOps.isNotEmpty ||
                rf.goalOps.isNotEmpty ||
                rf.playbookOps.isNotEmpty)) {
          UsageLog.log('CHAT', '回执触发（${failures.length} 条失败）：${failures.join('; ')}');
          _isRemedyRound = true;
          try {
            final remedyMsg = '【系统回执】你上一轮的操作部分被拒绝，失败清单如下：\n'
                '${failures.map((f) => '· $f').join('\n')}\n'
                '请根据失败原因修正操作（如改用正确 id、修正 index、换正确的 op），'
                '只输出补救所需的 ops 和一句简短说明，不要重复已成功的操作。';
            final rf2 = await client.chat(
              matters: matters,
              state: stateDays,
              userMessage: remedyMsg,
              arrangeMode: arrangeMode,
              userProfile: profileWire,
              playbook: playbook,
              goals: goals,
            );
            // 应用补救 ops
            if (rf2.matterOps.isNotEmpty) {
              final r2 = repo.applyMatterOps(rf2.matterOps);
              matters = r2.data as List<Matter>;
              log.addAll(r2.log);
            }
            if (rf2.goalOps.isNotEmpty) {
              final (g2, gl2) = applyGoalOpsForTest(rf2.goalOps);
              goals = g2;
              log.addAll(gl2);
              repo.saveGoals(goals);
            }
            if (rf2.stateUpdates.isNotEmpty) {
              final r2s = repo.applyStateUpdates(rf2.stateUpdates);
              stateDays = r2s.data as List<StateDay>;
              log.addAll(r2s.log);
            }
            log.add('已自动补救：${rf2.reply.isEmpty ? "见操作摘要" : rf2.reply}');
          } catch (e) {
            log.add('补救失败，请人工检查：$e');
          } finally {
            _isRemedyRound = false;
          }
        }
      }

      final replyText = rf.reply.trim().isEmpty ? '（模型未给回复文字）' : rf.reply;
      // M-064：本轮完成落日志（耗时/token/操作数）
      UsageLog.log('CHAT',
          '收 ${_sendSw.elapsedMilliseconds}ms ↑$_lastPromptTokens ↓$_lastCompletionTokens tok | ops:${rf.matterOps.length}m/${rf.goalOps.length}g/${rf.stateUpdates.length}s/${rf.playbookOps.length}p/${rf.scheduleBlocks.length}块 | ${log.isEmpty ? "无库变更" : log.join("; ")}');
      // M-060：本地确定性睡眠检测（不依赖 AI）——命中则排醒时通知+摘要提示
      final intent = await detectSleepIntent(text);
      if (intent != 'none') {
        UsageLog.log('ALARM', '意图=$intent 铃声$alarmSlot 醒时=$_wakeAt');
        final hm =
            '${_wakeAt!.hour.toString().padLeft(2, '0')}:${_wakeAt!.minute.toString().padLeft(2, '0')}';
        log.add(_wakeWantBrief
            ? '已记睡眠（铃声$alarmSlot），$hm 响铃并出晨报'
            : '闹钟已设（铃声$alarmSlot，$hm 响）');
      }

      // M-078：闹钟兜底——AI 补设（正则漏网的表达）
      if (rf.alarmOps.isNotEmpty) {
        for (final ao in rf.alarmOps) {
          if (ao.minutesFromNow <= 0) continue;
          // 判重：本地本轮已设（摘要里有"闹钟已设"）则丢弃 AI 的重复补设
          final alreadySet = log.any((l) => l.contains('闹钟已设') || l.contains('已记睡眠'));
          if (alreadySet) {
            UsageLog.log('ALARM', 'AI 兜底补设被丢弃（本地已设）：${ao.userPhrase}');
            continue;
          }
          _wakeAt = DateTime.now().add(Duration(minutes: ao.minutesFromNow));
          _wakeWantBrief = ao.wantBrief;
          alarmSlot = ao.slot;
          _briefSentToday = false;
          _saveWakeState();
          await NotifyService.cancelMorningBrief();
          await NotifyService.scheduleMorningBrief(_wakeAt!);
          _scheduleExactRing(); // M-080
          final hm = '${_wakeAt!.hour.toString().padLeft(2, '0')}:${_wakeAt!.minute.toString().padLeft(2, '0')}';
          log.add(ao.wantBrief
              ? '已记睡眠（铃声${ao.slot}），$hm 响铃并出晨报'
              : '闹钟已设（铃声${ao.slot}，$hm 响）');
          _logAlarm(ao.userPhrase.isNotEmpty ? ao.userPhrase : text); // M-081
          // 自学习闭环：漏网表达沉淀日志——喂回开发者优化正则
          UsageLog.log('ALARM',
              '【正则漏网·AI兜底】说法="${ao.userPhrase}" 分钟=${ao.minutesFromNow} 晨报=${ao.wantBrief}——请把此模式补进本地正则');
        }
      }


      _appendSession(arrangeMode, ChatMsg(replyText,
          sideLog: log,
          promptTokens: _lastPromptTokens, // M-058：本轮用量随气泡落史
          completionTokens: _lastCompletionTokens,
          at: nowHm)); // M-062：回复时刻
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
      UsageLog.err('CHAT', '模型调用失败 ${_sendSw.elapsedMilliseconds}ms: ${e.message}');
      _appendSession(arrangeMode, ChatMsg('⚠️ 模型调用失败：${e.message}'));
    } on SocketException catch (e) {
      error = e.message;
      UsageLog.err('CHAT', '网络断 ${_sendSw.elapsedMilliseconds}ms: ${e.message}（黑屏Doze嫌疑）');
      _appendSession(
          arrangeMode, const ChatMsg('⚠️ 网络不通或供应商域名不可达，请检查网络与配置。'));
    } catch (e) {
      error = e.toString();
      UsageLog.err('CHAT', '未知异常: $e');
      _appendSession(arrangeMode, ChatMsg('⚠️ 出错了：$e'));
    } finally {
      if (_wakelockCapable) WakelockPlus.disable(); // 回复完成解除保活
      _persistChat(); // 无论成败，聊天历史落盘（M-011；M-024 起两桶齐落）
      streamingPreview = '';
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
