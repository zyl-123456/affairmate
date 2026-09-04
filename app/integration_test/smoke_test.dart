// UI 冒烟集成测试（M-018）：真实启动 App → 三页切换 → 设置页开合 → 聊天输入框渲染
// 运行：flutter test integration_test/smoke_test.dart -d windows
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:shiwu_companion/main.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('启动→三页切换→设置页开合→展示页空态（单会话全流程）',
      (tester) async {
    await tester.pumpWidget(const ShiwuApp());
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 首页是沟通模式，输入框与麦克风在位
    expect(find.textContaining('沟通模式'), findsWidgets);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.mic_none), findsOneWidget, reason: '麦克风按钮在位');

    // 切到安排
    await tester.tap(find.text('安排').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('安排模式'), findsWidgets);

    // 切到展示：三卡片在位，空态引导不白屏
    await tester.tap(find.text('展示').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('今日时间进度条'), findsOneWidget);
    expect(find.textContaining('四维电量'), findsOneWidget);
    expect(find.textContaining('在办事项'), findsWidgets, reason: '标题+空态引导');
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '加载完成后不应有转圈残留');

    // 打开设置页再返回
    await tester.tap(find.byTooltip('模型供应商设置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('自定义（任意 OpenAI 兼容端点）'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 回沟通页
    await tester.tap(find.text('沟通').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('沟通模式'), findsWidgets);
  });
}
