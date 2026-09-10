// M-087 每日数据快照：把"今天的全部状态"结构化冻结一份。
// 老大的数据观（2026-09-10）：用户数据是软件优化的底座——
// 用久了提示词/报文膨胀、记录冗杂，靠快照序列才能看清"什么在长、长多快"，
// 也为未来"AI 基于历史数据提优化建议"备好原料。
// 设计：每天 08:00（App 存活检查触发，错过则当天首启补拍）把
//   两库全量 + 说明书 + 画像 + 当日完整对话（含用户原话与 AI 回复）+ 报文体积
//   存成一个 dated JSON 文件；保留 90 天自动滚动。

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class DailySnapshot {
  static Future<Directory> _dir() async {
    final doc = await getApplicationDocumentsDirectory();
    final d = Directory('${doc.path}${Platform.pathSeparator}snapshots');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 当天快照是否已存在
  static Future<bool> hasToday(String date) async {
    final d = await _dir();
    return File('${d.path}${Platform.pathSeparator}daily_$date.json').existsSync();
  }

  /// 拍快照（当日重复调用覆盖——以最新状态为准）
  static Future<void> capture({
    required String date,
    required List<Map<String, dynamic>> matters,
    required List<Map<String, dynamic>> goals,
    required List<Map<String, dynamic>> stateDays,
    required List<Map<String, dynamic>> chatChat,
    required List<Map<String, dynamic>> chatArrange,
    Map<String, dynamic>? playbook,
    Map<String, dynamic>? profile,
    int lastPayloadBytes = 0,
    int lastSysPromptBytes = 0,
  }) async {
    try {
      final d = await _dir();
      final body = {
        'snapshot_date': date,
        'captured_at': DateTime.now().toIso8601String(),
        'counts': {
          // M-088：当日线上实录（wire_log/ 每轮一文件——归因分析原料）
          'wire_turns_today': await _wireTurnsToday(date),
          'matters_active': matters.where((m) => m['active'] == true).length,
          'matters_archived': matters.where((m) => m['active'] != true).length,
          'goals_active': goals.where((g) => g['active'] == true).length,
          'state_days': stateDays.length,
          'chat_msgs': chatChat.length + chatArrange.length,
          'playbook_entries': _countPlaybook(playbook),
        },
        'sizes': {
          'matters_json_bytes': jsonEncode(matters).length,
          'goals_json_bytes': jsonEncode(goals).length,
          'chat_json_bytes': jsonEncode(chatChat).length + jsonEncode(chatArrange).length,
          'playbook_bytes': playbook != null ? jsonEncode(playbook).length : 0,
          'last_request_payload_bytes': lastPayloadBytes,
          'last_sys_prompt_bytes': lastSysPromptBytes,
        },
        'matters': matters,
        'goals': goals,
        'state': stateDays,
        'chat_today': chatChat,
        'arrange_today': chatArrange,
        if (playbook != null) 'playbook': playbook,
        if (profile != null) 'profile': profile,
      };
      await File('${d.path}${Platform.pathSeparator}daily_$date.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(body));
      // M-087b（老大 02:11 裁决）：快照永久保留——不清理。数据只在本地，
      // 不进大模型报文（零 token 成本）；512GB 手机存十年也用不到 1%。
    } catch (_) {}
  }

  static Future<int> _wireTurnsToday(String date) async {
    try {
      final doc = await getApplicationDocumentsDirectory();
      final d = Directory('${doc.path}${Platform.pathSeparator}wire_log');
      if (!d.existsSync()) return 0;
      final mmdd = date.substring(5).replaceAll('-', '');
      return d
          .listSync()
          .whereType<File>()
          .where((f) => f.path.split(Platform.pathSeparator).last.contains(mmdd))
          .length;
    } catch (_) {
      return 0;
    }
  }

  static int _countPlaybook(Map<String, dynamic>? pb) {
    if (pb == null) return 0;
    var n = 0;
    for (final v in pb.values) {
      if (v is List) n += v.length;
    }
    return n;
  }

  /// 快照日期清单（导出/分析用）
  static Future<List<String>> availableDates() async {
    final d = await _dir();
    final dates = <String>[];
    for (final f in d.listSync()) {
      final m = RegExp(r'daily_(\d{4}-\d{2}-\d{2})\.json').firstMatch(f.path);
      if (m != null) dates.add(m.group(1)!);
    }
    return dates..sort();
  }
}
