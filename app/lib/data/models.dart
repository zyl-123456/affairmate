// 数据模型 · 事务伴侣
// 对应设计：03 文档 D-001（两库 schema）+ D-002（接收文件协议）

import 'dart:convert';

// ============ 事项知识库 ============

/// 事项内核三属性（内核层，固定）
class CoreAttrs {
  final String timeReq; // 时间要求（含截止日、耗时，自然语言，如"下周三截止，约需2小时"）
  final String energyReq; // 精力要求（如"高认知"）
  final bool exclusive; // 独占性：能否与其他事并行

  const CoreAttrs({
    this.timeReq = '',
    this.energyReq = '',
    this.exclusive = false,
  });

  factory CoreAttrs.fromJson(Map<String, dynamic> j) => CoreAttrs(
        timeReq: (j['time_req'] ?? '').toString(),
        energyReq: (j['energy_req'] ?? '').toString(),
        exclusive: j['exclusive'] == true || j['exclusive'] == 1,
      );

  Map<String, dynamic> toJson() => {
        'time_req': timeReq,
        'energy_req': energyReq,
        'exclusive': exclusive,
      };
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

/// 安排块（安排模式，大模型 → App）
class ScheduleBlock {
  final String start; // HH:mm
  final String end; // HH:mm
  final String matterRef; // 事项名称或引用
  final String reason; // 安排理由

  const ScheduleBlock({
    required this.start,
    required this.end,
    required this.matterRef,
    this.reason = '',
  });

  factory ScheduleBlock.fromJson(Map<String, dynamic> j) => ScheduleBlock(
        start: (j['start'] ?? '').toString(),
        end: (j['end'] ?? '').toString(),
        matterRef: (j['matter_ref'] ?? (j['matterRef'] ?? '')).toString(),
        reason: (j['reason'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() =>
      {'start': start, 'end': end, 'matter_ref': matterRef, 'reason': reason};

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

  const ReceiveFile({
    this.matterOps = const [],
    this.stateUpdates = const [],
    this.reply = '',
    this.scheduleBlocks = const [],
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

    return ReceiveFile(
      matterOps: ops,
      stateUpdates: updates,
      reply: (root['reply'] ?? '').toString(),
      scheduleBlocks: blocks,
    );
  }
}
