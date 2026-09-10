// M-097 当日安排存档：晨报初稿 → 用户历次修改 → 24 点最终形态。
// 老大的学习闭环需求：AI 要吸收"前几天的晨报+你怎么改的"，明天才能排得更准。
// 存档结构（day_plan_YYYY-MM-DD.json）：
//   brief_draft   当天第一次块的快照（≈晨报初稿）
//   revisions     每次块变更的增量记录（时间+改动摘要）
//   final         24 点结算时的最终形态
//   review_notes  当天的回评汇总（done/moved/skipped 计数）
// 永久保留（M-087b 同款裁决）。

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class DayPlanArchive {
  static Future<Directory> _dir() async {
    final doc = await getApplicationDocumentsDirectory();
    final d = Directory('${doc.path}${Platform.pathSeparator}day_plans');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static Future<File> _file(String date) async =>
      File('\${(await _dir()).path}${Platform.pathSeparator}day_plan_$date.json');

  /// 记录"当天第一次块"（≈晨报初稿）
  static Future<void> saveDraft(String date, List<Map<String, dynamic>> blocks) async {
    try {
      final f = await _file(date);
      if (f.existsSync()) return; // 初稿只记第一次
      final body = {
        'date': date,
        'brief_draft': blocks,
        'revisions': <Map<String, dynamic>>[],
        'final': null,
      };
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(body));
    } catch (_) {}
  }

  /// 追记一次修改（增量）
  static Future<void> addRevision(String date, Map<String, dynamic> rev) async {
    try {
      final f = await _file(date);
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync());
      if (j is Map) {
        (j['revisions'] as List?)?.add(rev);
        f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(j));
      }
    } catch (_) {}
  }

  /// 24 点结算：定格最终形态+回评汇总
  static Future<void> finalize(String date, List<Map<String, dynamic>> finalBlocks,
      {int doneCount = 0, int movedCount = 0, int skippedCount = 0}) async {
    try {
      final f = await _file(date);
      if (!f.existsSync()) {
        // 当天从没存过初稿（无晨报日）——直接建终稿
        await saveDraft(date, finalBlocks);
      }
      final j = jsonDecode((await _file(date)).readAsStringSync());
      if (j is Map) {
        j['final'] = finalBlocks;
        j['review_notes'] = {
          'done': doneCount, 'moved': movedCount, 'skipped': skippedCount,
        };
        (await _file(date))
            .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(j));
      }
    } catch (_) {}
  }
}
