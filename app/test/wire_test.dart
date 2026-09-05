// llm/state 层纯函数单测：M-014 报文瘦身 + 上下文过滤
import 'package:flutter_test/flutter_test.dart';
import 'package:shiwu_companion/data/models.dart';
import 'package:shiwu_companion/llm/providers.dart';
import 'package:shiwu_companion/state.dart';

void main() {
  group('M-014 wire 层裁剪', () {
    Matter matter(String name, {bool active = true, String day = '2026-09-01'}) =>
        Matter(
            id: 'm_$name$day',
            name: name,
            active: active,
            createdAt: 't',
            updatedAt: 't');

    test('归档只发名称且截尾 30 个，在办全量', () {
      final matters = [
        matter('在办A'),
        matter('在办B'),
        for (var i = 1; i <= 50; i++) matter('旧事$i', active: false, day: 'd$i'),
      ];
      final wire = LlmClient.wireMatters(matters);
      final activeW = wire.where((m) => m['active'] == true).toList();
      final archivedW = wire.where((m) => m['active'] != true).toList();
      expect(activeW.length, 2);
      expect(activeW.first.containsKey('core'), true); // 在办带全量属性
      expect(archivedW.length, 30, reason: '归档截尾最近 30 个');
      expect(archivedW.first.containsKey('core'), false); // 归档瘦身
      // 最近 30 个 = 旧事21..旧事50
      expect(archivedW.last['name'], '旧事50');
      expect(archivedW.first['name'], '旧事21');
    });

    test('状态库只发今天+昨天（M-032 两层策略：底色走 playbook 字段）', () {
      final days = [
        for (var i = 1; i <= 15; i++)
          StateDay(date: '2026-09-${i.toString().padLeft(2, '0')}'),
      ];
      final wire = LlmClient.wireState(days);
      expect(wire.length, 2, reason: 'REQ-011：底色+今日+昨日替代 7 天流水');
      expect(wire.first['date'], '2026-09-15', reason: '最新在前');
      expect(wire.last['date'], '2026-09-14', reason: '昨天作参照');
    });
  });

  group('M-014 dialogueContext 过滤', () {
    test('⚠️ 错误气泡不进上下文', () {
      final chat = [
        const ChatMsg('下周三要交报表', fromUser: true),
        const ChatMsg('记下了'),
        const ChatMsg('⚠️ 模型调用失败：HTTP 500'),
        const ChatMsg('再试试', fromUser: true),
        const ChatMsg('好的'),
      ];
      final ctx = AppState.dialogueContext(chat, 6);
      expect(ctx.length, 3, reason: '5条去最后1条再滤⚠️1条=3');
      expect(ctx.any((m) => (m['text'] as String).startsWith('⚠️')), false);
    });

    test('滑窗只取最近 N 条且不含最后一条（本轮刚发）', () {
      final chat = [
        const ChatMsg('消息1', fromUser: true),
        const ChatMsg('回1'),
        const ChatMsg('消息2', fromUser: true),
        const ChatMsg('回2'),
        const ChatMsg('刚发的这句', fromUser: true),
      ];
      final ctx = AppState.dialogueContext(chat, 2);
      expect(ctx.length, 2);
      expect(ctx.first['text'], '消息2');
      expect(ctx.last['text'], '回2');
      expect(ctx.any((m) => m['text'] == '刚发的这句'), false);
    });
  });
}
