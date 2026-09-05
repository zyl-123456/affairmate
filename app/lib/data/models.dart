// 数据模型 · 事务伴侣
// 对应设计：03 文档 D-001（两库 schema）+ D-002（接收文件协议）

import 'dart:convert';

// ============ 事项知识库 ============

/// 事项内核属性（内核层，固定）
class CoreAttrs {
  final String timeReq; // 时间要求（含截止日、耗时，自然语言，如"下周三截止，约需2小时"）
  final String energyReq; // 精力要求（如"高认知"）
  final bool exclusive; // 独占性：能否与其他事并行
  final String mastery; // 掌握度（REQ-013）：familiar 熟 / average 一般 / unfamiliar 生疏

  const CoreAttrs({
    this.timeReq = '',
    this.energyReq = '',
    this.exclusive = false,
    this.mastery = '',
  });

  factory CoreAttrs.fromJson(Map<String, dynamic> j) => CoreAttrs(
        timeReq: (j['time_req'] ?? '').toString(),
        energyReq: (j['energy_req'] ?? '').toString(),
        exclusive: j['exclusive'] == true || j['exclusive'] == 1,
        mastery: (j['mastery'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'time_req': timeReq,
        'energy_req': energyReq,
        'exclusive': exclusive,
        if (mastery.isNotEmpty) 'mastery': mastery,
      };

  CoreAttrs copyWith({
    String? timeReq,
    String? energyReq,
    bool? exclusive,
    String? mastery,
  }) =>
      CoreAttrs(
        timeReq: timeReq ?? this.timeReq,
        energyReq: energyReq ?? this.energyReq,
        exclusive: exclusive ?? this.exclusive,
        mastery: mastery ?? this.mastery,
      );
}

/// 单条事项（on/off 开关 + 两层属性）
class Matter {
  final String id;
  final String name;
  final bool active; // on/off：off=已归档（完成或放弃）
  final CoreAttrs core; // 内核层三属性
  final Map<String, dynamic> ext; // 扩展层开放键值（如 progress）
  final String createdAt;
  final String updatedAt;

  const Matter({
    required this.id,
    required this.name,
    this.active = true,
    this.core = const CoreAttrs(),
    this.ext = const {},
    required this.createdAt,
    required this.updatedAt,
  });

  factory Matter.fromJson(Map<String, dynamic> j) => Matter(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        active: j['active'] != false,
        core: j['core'] is Map
            ? CoreAttrs.fromJson(Map<String, dynamic>.from(j['core']))
            : const CoreAttrs(),
        ext: j['ext'] is Map ? Map<String, dynamic>.from(j['ext']) : {},
        createdAt: (j['created_at'] ?? '').toString(),
        updatedAt: (j['updated_at'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'active': active,
        'core': core.toJson(),
        'ext': ext,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  /// 发送给大模型时的瘦身视图：off 事项只传名称（REQ-003）
  Map<String, dynamic> toWireJson() =>
      active ? toJson() : {'id': id, 'name': name, 'active': false};

  Matter copyWith({
    String? id,
    String? name,
    bool? active,
    CoreAttrs? core,
    Map<String, dynamic>? ext,
    String? createdAt,
    String? updatedAt,
  }) =>
      Matter(
        id: id ?? this.id,
        name: name ?? this.name,
        active: active ?? this.active,
        core: core ?? this.core,
        ext: ext ?? this.ext,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

// ============ 状态知识库（四维电量模型）============

/// 单个维度状态：值 + 更新时间 + 依据条目 + 当日轨迹（M-018）
class DimState {
  final String value; // 电量描述（自然语言，如"70%"、"睡眠不足"）
  final String updatedAt;
  final List<String> evidence; // 依据条目（来自用户的话）
  final List<Map<String, String>> history; // 当日轨迹 [{time:HH:mm, value:..}]，截尾保留

  const DimState({
    this.value = '',
    this.updatedAt = '',
    this.evidence = const [],
    this.history = const [],
  });

  factory DimState.fromJson(Map<String, dynamic> j) => DimState(
        value: (j['value'] ?? '').toString(),
        updatedAt: (j['updated_at'] ?? '').toString(),
        evidence: (j['evidence'] as List? ?? [])
            .map((e) => e.toString())
            .toList(growable: false),
        history: (j['history'] as List? ?? [])
            .whereType<Map>()
            .map((m) => {
                  'time': (m['time'] ?? '').toString(),
                  'value': (m['value'] ?? '').toString(),
                })
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
        'value': value,
        'updated_at': updatedAt,
        if (evidence.isNotEmpty) 'evidence': evidence,
        if (history.isNotEmpty)
          'history': history.map((h) => {'time': h['time'], 'value': h['value']}).toList(),
      };

  DimState copyWith({
    String? value,
    String? updatedAt,
    List<String>? evidence,
    List<Map<String, String>>? history,
  }) =>
      DimState(
        value: value ?? this.value,
        updatedAt: updatedAt ?? this.updatedAt,
        evidence: evidence ?? this.evidence,
        history: history ?? this.history,
      );
}

/// 一天的四维状态（渐进填充：缺省字段合法）
class StateDay {
  final String date; // YYYY-MM-DD
  final DimState body; // 身体
  final DimState cognition; // 认知
  final DimState emotion; // 情绪
  final DimState motivation; // 动机

  const StateDay({
    required this.date,
    this.body = const DimState(),
    this.cognition = const DimState(),
    this.emotion = const DimState(),
    this.motivation = const DimState(),
  });

  factory StateDay.fromJson(Map<String, dynamic> j) => StateDay(
        date: (j['date'] ?? '').toString(),
        body: j['body'] is Map
            ? DimState.fromJson(Map<String, dynamic>.from(j['body']))
            : const DimState(),
        cognition: j['cognition'] is Map
            ? DimState.fromJson(Map<String, dynamic>.from(j['cognition']))
            : const DimState(),
        emotion: j['emotion'] is Map
            ? DimState.fromJson(Map<String, dynamic>.from(j['emotion']))
            : const DimState(),
        motivation: j['motivation'] is Map
            ? DimState.fromJson(Map<String, dynamic>.from(j['motivation']))
            : const DimState(),
      );

  Map<String, dynamic> toJson() => {
        'date': date,
        'body': body.toJson(),
        'cognition': cognition.toJson(),
        'emotion': emotion.toJson(),
        'motivation': motivation.toJson(),
      };

  /// 测试辅助：改日期（M-036 e2e 造多天数据用）
  StateDay copyWithDate(String newDate) => StateDay(
        date: newDate,
        body: body,
        cognition: cognition,
        emotion: emotion,
        motivation: motivation,
      );
}

// ============ 个人说明书（底色层，REQ-012 / M-032）============

/// 说明书单条记录：内容 + 依据 + 可信度 + 来源 + 时间
class ProfileEntry {
  final String content; // 一句话结论（如"轻度运动15分钟能恢复认知疲劳"）
  final String evidence; // 依据（如"近14天有11天运动后认知回升"）
  final String confidence; // high / medium / low
  final String origin; // user=亲述 / ai=观察提炼 / review=复盘重写
  final String updatedAt; // ISO 时间

  const ProfileEntry({
    required this.content,
    this.evidence = '',
    this.confidence = 'medium',
    this.origin = 'ai',
    this.updatedAt = '',
  });

  factory ProfileEntry.fromJson(Map<String, dynamic> j) => ProfileEntry(
        content: (j['content'] ?? '').toString(),
        evidence: (j['evidence'] ?? '').toString(),
        confidence: (j['confidence'] ?? 'medium').toString(),
        origin: (j['origin'] ?? 'ai').toString(),
        updatedAt: (j['updated_at'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'content': content,
        'evidence': evidence,
        'confidence': confidence,
        'origin': origin,
        'updated_at': updatedAt,
      };

  ProfileEntry copyWith({
    String? content,
    String? evidence,
    String? confidence,
    String? origin,
    String? updatedAt,
  }) =>
      ProfileEntry(
        content: content ?? this.content,
        evidence: evidence ?? this.evidence,
        confidence: confidence ?? this.confidence,
        origin: origin ?? this.origin,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// 个人说明书四板块（REQ-012 初始结构，可扩展）
class UserPlaybook {
  final List<ProfileEntry> traits; // 画像：我是什么样
  final List<ProfileEntry> patterns; // 规律：什么导致什么
  final List<ProfileEntry> recharges; // 充电法：什么恢复什么
  final List<ProfileEntry> preferences; // 偏好：想被怎么对待
  final String lastReviewAt; // 上次大复盘时间（10 天周期判定）

  const UserPlaybook({
    this.traits = const [],
    this.patterns = const [],
    this.recharges = const [],
    this.preferences = const [],
    this.lastReviewAt = '',
  });

  factory UserPlaybook.fromJson(Map<String, dynamic> j) => UserPlaybook(
        traits: _entries(j['traits']),
        patterns: _entries(j['patterns']),
        recharges: _entries(j['recharges']),
        preferences: _entries(j['preferences']),
        lastReviewAt: (j['last_review_at'] ?? '').toString(),
      );

  static List<ProfileEntry> _entries(dynamic raw) => (raw as List? ?? [])
      .whereType<Map>()
      .map((m) => ProfileEntry.fromJson(Map<String, dynamic>.from(m)))
      .toList(growable: false);

  Map<String, dynamic> toJson() => {
        'traits': traits.map((e) => e.toJson()).toList(),
        'patterns': patterns.map((e) => e.toJson()).toList(),
        'recharges': recharges.map((e) => e.toJson()).toList(),
        'preferences': preferences.map((e) => e.toJson()).toList(),
        'last_review_at': lastReviewAt,
      };

  bool get isEmpty =>
      traits.isEmpty && patterns.isEmpty && recharges.isEmpty && preferences.isEmpty;

  UserPlaybook copyWith({
    List<ProfileEntry>? traits,
    List<ProfileEntry>? patterns,
    List<ProfileEntry>? recharges,
    List<ProfileEntry>? preferences,
    String? lastReviewAt,
  }) =>
      UserPlaybook(
        traits: traits ?? this.traits,
        patterns: patterns ?? this.patterns,
        recharges: recharges ?? this.recharges,
        preferences: preferences ?? this.preferences,
        lastReviewAt: lastReviewAt ?? this.lastReviewAt,
      );

  static const sectionKeys = {
    'traits': '画像',
    'patterns': '规律',
    'recharges': '充电法',
    'preferences': '偏好',
  };
}

// ============ 接收文件协议（D-002 四键）============

/// 事项操作（大模型 → App）
class MatterOp {
  final String op; // add / update / complete / delete / archive / restore
  final String? id; // 目标事项 id（add 时可空，由 App 生成）
  final String? name; // 名称（add 必填）
  final Map<String, dynamic> corePatch; // 内核属性补丁
  final Map<String, dynamic> extPatch; // 扩展属性补丁
  final String? note; // 操作附言（如"用户说交了"）

  const MatterOp({
    required this.op,
    this.id,
    this.name,
    this.corePatch = const {},
    this.extPatch = const {},
    this.note,
  });

  factory MatterOp.fromJson(Map<String, dynamic> j) => MatterOp(
        op: (j['op'] ?? '').toString().toLowerCase(),
        id: j['id']?.toString(),
        name: j['name']?.toString(),
        corePatch:
            j['core'] is Map ? Map<String, dynamic>.from(j['core']) : {},
        extPatch: j['ext'] is Map ? Map<String, dynamic>.from(j['ext']) : {},
        note: j['note']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'op': op,
        if (id != null) 'id': id,
        if (name != null) 'name': name,
        if (corePatch.isNotEmpty) 'core': corePatch,
        if (extPatch.isNotEmpty) 'ext': extPatch,
        if (note != null) 'note': note,
      };
}

/// 状态回填条目（大模型 → App）
class StateUpdate {
  final String dim; // body / cognition / emotion / motivation
  final String value;
  final String evidence; // 依据（用户原话要点）

  const StateUpdate(
      {required this.dim, required this.value, required this.evidence});

  factory StateUpdate.fromJson(Map<String, dynamic> j) => StateUpdate(
        dim: (j['dim'] ?? '').toString().toLowerCase(),
        value: (j['value'] ?? '').toString(),
        evidence: (j['evidence'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() =>
      {'dim': dim, 'value': value, 'evidence': evidence};
}

/// 说明书操作（大模型 → App，REQ-012：改底色必须明示）
class PlaybookOp {
  final String op; // add / update / remove
  final String section; // traits / patterns / recharges / preferences
  final String? index; // update/remove 时的目标序号（字符串数字）
  final ProfileEntry entry; // 新内容（add/update 时）

  const PlaybookOp({
    required this.op,
    required this.section,
    this.index,
    required this.entry,
  });

  factory PlaybookOp.fromJson(Map<String, dynamic> j) => PlaybookOp(
        op: (j['op'] ?? '').toString().toLowerCase(),
        section: (j['section'] ?? '').toString().toLowerCase(),
        index: j['index']?.toString(),
        entry: j['entry'] is Map
            ? ProfileEntry.fromJson(Map<String, dynamic>.from(j['entry']))
            : const ProfileEntry(content: ''),
      );

  Map<String, dynamic> toJson() => {
        'op': op,
        'section': section,
        if (index != null) 'index': index,
        'entry': entry.toJson(),
      };
}

/// 安排块（安排模式，大模型 → App）
/// M-034 多轨制：track 0=主轨（独占任务），1+ =伴随轨（并行轻任务，如等编译时背单词）。
/// 结构天生支持任意轨数——数据层不设上限，渲染层默认展示主轨+伴随轨两层。
class ScheduleBlock {
  final String start; // HH:mm
  final String end; // HH:mm
  final String matterRef; // 事项名称或引用
  final String reason; // 安排理由
  final int track; // 轨道号：0 主轨 / 1,2,3… 伴随轨（M-034）

  const ScheduleBlock({
    required this.start,
    required this.end,
    required this.matterRef,
    this.reason = '',
    this.track = 0,
  });

  bool get isParallel => track > 0; // 伴随轨块（旧数据无 track 字段 → 0 → 主轨，兼容）

  factory ScheduleBlock.fromJson(Map<String, dynamic> j) => ScheduleBlock(
        start: (j['start'] ?? '').toString(),
        end: (j['end'] ?? '').toString(),
        matterRef: (j['matter_ref'] ?? (j['matterRef'] ?? '')).toString(),
        reason: (j['reason'] ?? '').toString(),
        track: (j['track'] is int) ? j['track'] as int : (int.tryParse((j['track'] ?? '0').toString()) ?? 0),
      );

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'matter_ref': matterRef,
        'reason': reason,
        if (track > 0) 'track': track, // 主轨不带字段（省空间+旧版兼容）
      };

  /// 起止分钟数（自 00:00 起）；解析失败返回 null
  int? get startMinutes => _hhmmToMinutes(start);
  int? get endMinutes => _hhmmToMinutes(end);

  static int? _hhmmToMinutes(String s) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s.trim());
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!);
    final min = int.tryParse(m.group(2)!);
    if (h == null || min == null || h > 24 || min > 59) return null;
    return h * 60 + min;
  }
}

/// 接收文件（大模型回传的整体结构）
class ReceiveFile {
  final List<MatterOp> matterOps;
  final List<StateUpdate> stateUpdates;
  final String reply; // 给用户的文字回复（兜底必展示）
  final List<ScheduleBlock> scheduleBlocks; // 仅安排模式
  final List<PlaybookOp> playbookOps; // 说明书操作（REQ-012，M-032）

  const ReceiveFile({
    this.matterOps = const [],
    this.stateUpdates = const [],
    this.reply = '',
    this.scheduleBlocks = const [],
    this.playbookOps = const [],
  });

  /// 容错解析：逐键独立，任一键畸形仅丢弃该键（D-002 红线：不崩溃、不写坏两库）
  /// 支持 LLM 返回体被 ```json ...``` 包裹、含 // 行注释的情况。
  static ReceiveFile parse(String raw) {
    var text = raw.trim();
    if (text.startsWith('```')) {
      final nl = text.indexOf('\n');
      if (nl > 0) text = text.substring(nl + 1);
      if (text.endsWith('```')) text = text.substring(0, text.length - 3);
      text = text.trim();
    }
    // 剥离 // 行注释
    final buf = StringBuffer();
    for (final line in text.split('\n')) {
      if (line.trim().startsWith('//')) continue;
      buf.writeln(line);
    }
    Map<String, dynamic> root;
    try {
      final decoded = jsonDecode(buf.toString());
      if (decoded is! Map) return ReceiveFile(reply: raw);
      root = Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 整体不是 JSON：全部视为纯文字回复
      return ReceiveFile(reply: raw);
    }

    final ops = <MatterOp>[];
    if (root['matter_ops'] is List) {
      for (final e in root['matter_ops'] as List) {
        if (e is Map) {
          try {
            ops.add(MatterOp.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {/* 丢一条坏操作 */}
        }
      }
    }

    final updates = <StateUpdate>[];
    if (root['state_updates'] is List) {
      for (final e in root['state_updates'] as List) {
        if (e is Map) {
          try {
            updates.add(StateUpdate.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {}
        }
      }
    }

    final blocks = <ScheduleBlock>[];
    if (root['schedule_blocks'] is List) {
      for (final e in root['schedule_blocks'] as List) {
        if (e is Map) {
          try {
            blocks.add(ScheduleBlock.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {}
        }
      }
    }

    final pOps = <PlaybookOp>[];
    if (root['playbook_ops'] is List) {
      for (final e in root['playbook_ops'] as List) {
        if (e is Map) {
          try {
            pOps.add(PlaybookOp.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {}
        }
      }
    }

    return ReceiveFile(
      matterOps: ops,
      stateUpdates: updates,
      reply: (root['reply'] ?? '').toString(),
      scheduleBlocks: blocks,
      playbookOps: pOps,
    );
  }
}
