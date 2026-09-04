// 两库仓库 · 事务伴侣
// 对应设计：03 文档 D-001（matters.json / state.json 读写）+ D-002（增量应用）

import 'dart:io';

import '../data/models.dart';
import 'safe_io.dart';

/// 事项库 + 状态库的本地读写与应用增量。
/// 两库即真相源（C-003：不建数据库、不加索引层，单机 JSON 量级足够）。
class Repo {
  final File mattersFile;
  final File stateFile;

  Repo(this.mattersFile, this.stateFile);

  /// 工厂：按目录构造（目录自动创建，文件不存在时给空库）
  factory Repo.at(Directory dir) {
    final d = Directory('${dir.path}${Platform.pathSeparator}data');
    if (!d.existsSync()) d.createSync(recursive: true);
    return Repo(File('${d.path}${Platform.pathSeparator}matters.json'),
        File('${d.path}${Platform.pathSeparator}state.json'));
  }

  // ============ 事项库 ============

  List<Matter> loadMatters() {
    final decoded = readJsonWithFallback(mattersFile);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((m) => Matter.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  void saveMatters(List<Matter> matters) {
    safeWriteJson(mattersFile, matters.map((m) => m.toJson()).toList());
  }

  // ============ 状态库 ============

  List<StateDay> loadState() {
    final decoded = readJsonWithFallback(stateFile);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((m) => StateDay.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  void saveState(List<StateDay> days) {
    safeWriteJson(stateFile, days.map((d) => d.toJson()).toList());
  }

  // ============ 增量应用（接收文件 → 两库）============

  /// 统一目标定位（M-012）：id 优先；id 未命中/未给时按名称兜底（在办事项精确匹配，
  /// 唯一命中才应用——多命中/零命中都丢弃并记日志，宁缺勿错）。
  int _locate(List<Matter> matters, MatterOp o, String op, List<String> log) {
    if (o.id != null && o.id!.isNotEmpty) {
      final i = matters.indexWhere((m) => m.id == o.id);
      if (i >= 0) return i;
    }
    final name = (o.name ?? '').trim();
    if (name.isNotEmpty) {
      final hits = matters.where((m) => m.active && m.name == name).toList();
      if (hits.length == 1) {
        if (o.id != null && o.id!.isNotEmpty) {
          log.add('注意：$op id=${o.id} 未命中，按名称「$name」兜底');
        }
        return matters.indexOf(hits.first);
      }
      if (hits.length > 1) {
        log.add('丢弃 $op：名称「$name」命中 ${hits.length} 条，有歧义');
        return -1;
      }
    }
    log.add('丢弃 $op：无法定位目标（id=${o.id}，名称="$name"）');
    return -1;
  }

  /// 应用一批事项操作。返回 (新事项列表, 应用日志)。
  /// App 侧确定性规则：id 为准；add 由 App 生成 id；未知 id/未知 op 丢弃并记日志。
  ApplyResult applyMatterOps(List<MatterOp> ops) {
    var matters = loadMatters();
    final log = <String>[];
    final now = _nowIso();

    for (final o in ops) {
      switch (o.op) {
        case 'add':
          if ((o.name ?? '').trim().isEmpty) {
            log.add('丢弃 add：无名称');
            break;
          }
          final id = _genId();
          matters.add(Matter(
            id: id,
            name: o.name!.trim(),
            active: true,
            core: CoreAttrs.fromJson(o.corePatch),
            ext: Map<String, dynamic>.from(o.extPatch),
            createdAt: now,
            updatedAt: now,
          ));
          log.add('新增「${o.name}」');
          break;

        case 'update':
          final i = _locate(matters, o, 'update', log);
          if (i < 0) break;
          matters[i] = _patchMatter(matters[i], o, now, log);
          log.add('更新「${matters[i].name}」');
          break;

        case 'complete':
        case 'archive':
          final i = _locate(matters, o, o.op, log);
          if (i < 0) break;
          matters[i] = matters[i].copyWith(active: false, updatedAt: now);
          log.add('归档「${matters[i].name}」(${o.op})');
          break;

        case 'restore':
          final i = _locate(matters, o, 'restore', log);
          if (i < 0) break;
          matters[i] = matters[i].copyWith(active: true, updatedAt: now);
          log.add('恢复「${matters[i].name}」');
          break;

        case 'delete':
          final i = _locate(matters, o, 'delete', log);
          if (i < 0) break;
          log.add('删除「${matters[i].name}」');
          matters.removeAt(i);
          break;

        default:
          log.add('丢弃未知 op=${o.op}');
      }
    }

    saveMatters(matters);
    return ApplyResult(matters, log);
  }

  /// REQ-003 分层铁律：扩展层不得与内核层语义重叠。
  /// 内核三属性的键与常见变体都算越界，拦截丢弃。
  static const _coreReservedKeys = {
    'time_req', 'timereq', 'time', 'deadline',
    'energy_req', 'energyreq', 'energy',
    'exclusive', '独占',
  };

  Matter _patchMatter(Matter m, MatterOp o, String now, List<String> log) {
    var core = m.core;
    if (o.corePatch.isNotEmpty) {
      core = CoreAttrs.fromJson({...core.toJson(), ...o.corePatch});
    }
    var ext = Map<String, dynamic>.from(m.ext);
    for (final e in o.extPatch.entries) {
      if (_coreReservedKeys.contains(e.key.toLowerCase())) {
        log.add('拦截扩展层越界键「${e.key}」（属内核属性，REQ-003 分层铁律）');
        continue;
      }
      ext[e.key] = e.value;
    }
    return m.copyWith(
      core: core,
      ext: ext,
      name: (o.name ?? '').trim().isNotEmpty ? o.name!.trim() : m.name,
      updatedAt: now,
    );
  }

  /// 应用状态回填：写入今天的四维条目。返回 (新状态列表, 日志)。
  ApplyResult applyStateUpdates(List<StateUpdate> updates) {
    var days = loadState();
    final log = <String>[];
    final today = _today();
    final now = _nowIso();

    var i = days.indexWhere((d) => d.date == today);
    if (i < 0) {
      days.add(StateDay(date: today));
      i = days.length - 1;
    }

    for (final u in updates) {
      final evidence = u.evidence.trim().isEmpty ? '本轮对话' : u.evidence.trim();
      DimState dim;
      switch (u.dim) {
        case 'body':
          dim = days[i].body;
          break;
        case 'cognition':
          dim = days[i].cognition;
          break;
        case 'emotion':
          dim = days[i].emotion;
          break;
        case 'motivation':
          dim = days[i].motivation;
          break;
        default:
          log.add('丢弃状态回填：未知维度 ${u.dim}');
          continue;
      }
      // M-018 轨迹：覆盖 value 前把旧值存入当日历史（REQ-007 各时段状态描述）
      final hhmm = now.length >= 16 ? now.substring(11, 16) : now;
      var newHistory = dim.value.isEmpty
          ? [...dim.history]
          : [...dim.history, {'time': hhmm, 'value': dim.value}];
      if (newHistory.length > 12) newHistory = newHistory.sublist(newHistory.length - 12);

      // evidence 截尾最近 10 条：状态描述会被新值覆盖，旧依据只留参考（M-013 防膨胀）
      final newEvidence = [...dim.evidence, evidence];
      final updated = dim.copyWith(
        value: u.value,
        updatedAt: now,
        evidence: newEvidence.length > 10
            ? newEvidence.sublist(newEvidence.length - 10)
            : newEvidence,
        history: newHistory,
      );
      days[i] = _withDim(days[i], u.dim, updated);
      log.add('状态[${u.dim}] ← "${u.value}"');
    }

    saveState(days);
    return ApplyResult(days, log);
  }

  StateDay _withDim(StateDay d, String dim, DimState v) {
    switch (dim) {
      case 'body':
        return StateDay(
            date: d.date, body: v, cognition: d.cognition, emotion: d.emotion, motivation: d.motivation);
      case 'cognition':
        return StateDay(
            date: d.date, body: d.body, cognition: v, emotion: d.emotion, motivation: d.motivation);
      case 'emotion':
        return StateDay(
            date: d.date, body: d.body, cognition: d.cognition, emotion: v, motivation: d.motivation);
      case 'motivation':
        return StateDay(
            date: d.date, body: d.body, cognition: d.cognition, emotion: d.emotion, motivation: v);
      default:
        return d;
    }
  }

  // ============ 工具 ============

  static String _nowIso() => DateTime.now().toIso8601String();
  static String _today() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  static int _idSeq = 0;
  static String _genId() {
    _idSeq++;
    return 'm${DateTime.now().millisecondsSinceEpoch}_$_idSeq';
  }
}

/// applyXxx 的统一返回
class ApplyResult {
  final dynamic data; // List<Matter> 或 List<StateDay>
  final List<String> log;

  const ApplyResult(this.data, this.log);
}
