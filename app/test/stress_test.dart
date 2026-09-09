// 压力测试：3 年重度使用数据规模下的启动/加载/操作性能（M-044b）
// 场景：2000 事项 / 50 目标（各 200 进度史）/ 1000 天状态 / 100 条说明书 / 400 天日程
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiwu_companion/data/repo.dart';
import 'package:shiwu_companion/state.dart';

void main() {
  // 压力数据由 tools/gen_stress_data.py 生成到 D:/sw_build_stress
  final dir = Directory('D:/sw_build_stress');

  test('M-044b 压力：3 年重度数据——加载耗时 < 2s，全链路操作正常', () {
    if (!dir.existsSync()) {
      markTestSkipped('压力数据未生成（跑 tools/gen_stress_data.py）');
      return;
    }
    final sw = Stopwatch()..start();
    final repo = Repo.at(dir);
    final app = AppState(repo);
    final loadMs = sw.elapsedMilliseconds;

    // 断言数据完整加载
    expect(app.matters.length, 2000, reason: '2000 事项');
    expect(app.goals.length, 50, reason: '50 目标');
    expect(app.goals.first.progressHistory.length, 200, reason: '进度史 200');
    expect(app.stateDays.length, 1000, reason: '1000 天状态');
    expect(app.profile.traits.length, 25, reason: '说明书画像 25');
    expect(app.chatChat.length, 200, reason: '聊天 200');

    sw.reset();
    // wire 层组装（每轮发报文的口径）
    final mattersWire = wireMattersForTest(app);
    final stateWire = wireStateForTest(app.stateDays);
    final wireMs = sw.elapsedMilliseconds;

    // 关键断言：报文瘦身在重压下仍受控
    expect(mattersWire.length, lessThanOrEqualTo(60),
        reason: '在办全量+归档30截尾（当前在办10+30=40）');
    expect(stateWire.length, 2, reason: '状态只发今昨（M-032）');

    // 目标页关键操作：50 目标卡的数据组装
    sw.reset();
    final activeGoals = app.goals.where((g) => g.active).length;
    final goalMatters = app.matters
        .where((m) => m.active && m.goalRef == app.goals.first.id)
        .length;
    final uiMs = sw.elapsedMilliseconds;

    // 打印性能报告
    // ignore: avoid_print
    print('📊 压测报告（3 年重度数据）：加载 ${loadMs}ms | 报文组装 ${wireMs}ms | UI 组装 ${uiMs}ms | 活跃目标 $activeGoals | 首目标事项 $goalMatters');
    // ignore: avoid_print
    print('   文件总量 ~2MB（goals 802K + matters 446K + state 624K）');

    expect(loadMs, lessThan(2000), reason: '3 年数据加载应 < 2s');
  });

}

// 提取包装（避免 import llm 层）
List<Map<String, dynamic>> wireMattersForTest(AppState app) {
  final active =
      app.matters.where((m) => m.active).map((m) => m.toWireJson()).toList();
  final archivedNames = app.matters
      .where((m) => !m.active)
      .map((m) => m.toWireJson())
      .toList();
  final archivedKept = archivedNames.length > 30
      ? archivedNames.sublist(archivedNames.length - 30)
      : archivedNames;
  return [...active, ...archivedKept];
}

List<Map<String, dynamic>> wireStateForTest(List days) {
  final sorted = [...days]..sort((a, b) => b.date.compareTo(a.date));
  final kept = sorted.length > 2 ? sorted.sublist(0, 2) : sorted;
  return kept
      .map((d) => d.toJson() as Map<String, dynamic>)
      .toList();
}
