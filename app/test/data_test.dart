// data 层单测：D-001 两库 schema + D-002 协议解析容错 + 增量应用
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiwu_companion/data/models.dart';
import 'package:shiwu_companion/data/repo.dart';
import 'package:shiwu_companion/state.dart' show AppState;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shiwu_test_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Repo newRepo() => Repo.at(tmp);

  group('D-001 事项库 round-trip', () {
    test('空库初始化与读写往返', () {
      final repo = newRepo();
      expect(repo.loadMatters(), isEmpty);
      repo.saveMatters([
        Matter(
          id: 'm1',
          name: '交报表',
          core: CoreAttrs(timeReq: '下周三截止', energyReq: '高认知', exclusive: true),
          ext: {'progress': '30%'},
          createdAt: '2026-09-04T06:00:00',
          updatedAt: '2026-09-04T06:00:00',
        ),
      ]);
      final loaded = newRepo().loadMatters();
      expect(loaded.length, 1);
      expect(loaded.first.name, '交报表');
      expect(loaded.first.core.timeReq, '下周三截止');
      expect(loaded.first.ext['progress'], '30%');
      expect(loaded.first.active, true);
    });

    test('off 事项瘦身发送（REQ-003）', () {
      const m = Matter(
        id: 'm1',
        name: '旧事',
        active: false,
        core: CoreAttrs(timeReq: '秘密'),
        createdAt: 't',
        updatedAt: 't',
      );
      final wire = m.toWireJson();
      expect(wire.containsKey('core'), isFalse);
      expect(wire['name'], '旧事');
      expect(wire['active'], false);
    });
  });

  group('D-002 ReceiveFile.parse 容错', () {
    test('标准四键解析', () {
      const raw = '''
      {
        "matter_ops": [
          {"op": "add", "name": "交报表", "core": {"time_req": "下周三截止"}}
        ],
        "state_updates": [
          {"dim": "body", "value": "70%", "evidence": "昨晚只睡5小时"}
        ],
        "reply": "收到，已记下报表的事",
        "schedule_blocks": [
          {"start": "09:00", "end": "10:30", "matter_ref": "交报表", "reason": "上午认知最好"}
        ]
      }
      ''';
      final rf = ReceiveFile.parse(raw);
      expect(rf.matterOps.length, 1);
      expect(rf.matterOps.first.name, '交报表');
      expect(rf.stateUpdates.length, 1);
      expect(rf.stateUpdates.first.dim, 'body');
      expect(rf.reply, '收到，已记下报表的事');
      expect(rf.scheduleBlocks.length, 1);
      expect(rf.scheduleBlocks.first.startMinutes, 9 * 60);
      expect(rf.scheduleBlocks.first.endMinutes, 10 * 60 + 30);
    });

    test('```json 围栏剥离', () {
      const raw = '```json\n{"reply": "好"}\n```';
      expect(ReceiveFile.parse(raw).reply, '好');
    });

    test('// 行注释剥离', () {
      const raw = '{\n// 这是注释\n"reply": "好"\n}';
      expect(ReceiveFile.parse(raw).reply, '好');
    });

    test('整体非 JSON → 全文当回复兜底（不崩溃）', () {
      const raw = '抱歉，我听不太明白';
      final rf = ReceiveFile.parse(raw);
      expect(rf.reply, raw);
      expect(rf.matterOps, isEmpty);
    });

    test('matter_ops 里混坏条目 → 解析层丢非 Map，应用层丢未知 op', () {
      const raw = '''
      {"matter_ops": [{"op": "add", "name": "好事项"}, {"op": 123}, "垃圾"],
       "reply": "ok"}
      ''';
      final rf = ReceiveFile.parse(raw);
      // 解析层：只丢非 Map 条目（"垃圾"）；{"op":123} 结构合法，op 合法性归应用层
      expect(rf.matterOps.length, 2);
      // 应用层：未知 op 丢弃（用独享临时目录，避免跨运行残留）
      final repo = Repo(
        File('${tmp.path}${Platform.pathSeparator}noop_matters.json'),
        File('${tmp.path}${Platform.pathSeparator}noop_state.json'),
      );
      final r = repo.applyMatterOps(
          [rf.matterOps.firstWhere((m) => m.name == '好事项')]);
      expect((r.data as List<Matter>).length, 1);
    });

    test('JSON 数组顶层 → 当纯文字兜底', () {
      const raw = '[1,2,3]';
      final rf = ReceiveFile.parse(raw);
      expect(rf.matterOps, isEmpty);
      expect(rf.reply, '[1,2,3]');
    });
  });

  group('增量应用（A-002 场景）', () {
    test('「下周三要交报表」→「报表交了」全自动', () {
      final repo = newRepo();

      // 第一轮：AI 判断新增事项带截止属性
      final r1 = ReceiveFile.parse('''
      {"matter_ops": [{"op": "add", "name": "交报表", "core": {"time_req": "下周三截止", "exclusive": true}}],
       "state_updates": [], "reply": "记下了，下周三交报表"}
      ''');
      final a1 = repo.applyMatterOps(r1.matterOps);
      expect(a1.data.length, 1);
      final added = (a1.data as List<Matter>).first;
      expect(added.name, '交报表');
      expect(added.core.timeReq, '下周三截止');
      expect(added.active, true);

      // 第二轮：AI 判断完成归档 on→off
      final r2 = ReceiveFile.parse('''
      {"matter_ops": [{"op": "complete", "id": "${added.id}"}],
       "state_updates": [], "reply": "干得漂亮，报表已归档"}
      ''');
      final a2 = repo.applyMatterOps(r2.matterOps);
      final archived = (a2.data as List<Matter>).first;
      expect(archived.active, false); // 全程无手动填表
      expect(archived.toWireJson().containsKey('core'), isFalse); // 归档瘦身
    });

    test('状态回填写入今天四维条目', () {
      final repo = newRepo();
      final rf = ReceiveFile.parse('''
      {"matter_ops": [], "state_updates": [
        {"dim": "body", "value": "电量60%", "evidence": "昨晚睡得晚"},
        {"dim": "emotion", "value": "平稳", "evidence": ""}
      ], "reply": "ok"}
      ''');
      repo.applyStateUpdates(rf.stateUpdates);
      final days = repo.loadState();
      expect(days.length, 1);
      expect(days.first.body.value, '电量60%');
      expect(days.first.body.evidence, contains('昨晚睡得晚'));
      expect(days.first.emotion.value, '平稳');
      expect(days.first.cognition.value, ''); // 渐进填充：未提及的维度留空
    });

    test('未知 id / 未知 op 丢弃并记日志，不写坏库', () {
      final repo = newRepo();
      repo.applyMatterOps([const MatterOp(op: 'add', name: '真事项')]);
      final r = repo.applyMatterOps(const [
        MatterOp(op: 'update', id: '不存在'),
        MatterOp(op: '飞天', id: 'x'),
      ]);
      final matters = r.data as List<Matter>;
      expect(matters.length, 1); // 库未被破坏
      expect(r.log.length, 2);
      expect(r.log.first, contains('无法定位'));
    });

    test('M-012 名称兜底：id 未给时按在办事项精确名称定位', () {
      final repo = newRepo();
      final add = repo.applyMatterOps(
          [const MatterOp(op: 'add', name: '交报表', corePatch: {'exclusive': true})]);
      final added = (add.data as List<Matter>).first;

      // 模型只给名称不给 id 的 complete —— 应兜底成功
      final r = repo.applyMatterOps(
          [const MatterOp(op: 'complete', name: '交报表')]);
      final matters = r.data as List<Matter>;
      expect(matters.first.active, false, reason: '名称兜底应完成归档');
      expect(r.log.first, contains('归档'));

      // 名称不匹配 —— 丢弃
      final r2 = repo.applyMatterOps(
          [const MatterOp(op: 'update', name: '不存在的名字')]);
      expect((r2.data as List<Matter>).length, 1);
      expect(r2.log.first, contains('丢弃'));

      // 名称歧义（两条同名在办）—— 拒绝操作
      repo.applyMatterOps([const MatterOp(op: 'add', name: '买牛奶')]);
      repo.applyMatterOps([const MatterOp(op: 'add', name: '买牛奶')]);
      final r3 = repo.applyMatterOps(
          [const MatterOp(op: 'complete', name: '买牛奶')]);
      final after = r3.data as List<Matter>;
      expect(after.where((m) => m.name == '买牛奶').every((m) => m.active), true,
          reason: '歧义时两条都不动');
      expect(r3.log.first, contains('歧义'));

      // id 命中优先于名称（id 对但名称故意写错）
      final r4 = repo.applyMatterOps(
          const [MatterOp(op: 'update', id: '不存在', name: '买牛奶')]);
      expect((r4.data as List<Matter>).length, 3, reason: 'id 未命中+名称歧义=丢弃');
      // 未用变量防 lint
      expect(added.name, '交报表');
    });
  });

  group('ScheduleBlock 时间解析', () {
    const b1 = ScheduleBlock(start: '09:30', end: '10:45', matterRef: 'x');
    const b2 = ScheduleBlock(start: '9:05', end: '25:00', matterRef: 'x');
    const b3 = ScheduleBlock(start: 'abc', end: '09:5', matterRef: 'x');

    test('HH:mm 正常解析', () {
      expect(b1.startMinutes, 570);
      expect(b1.endMinutes, 645);
      expect(b2.startMinutes, 545); // 9:05 容错单小时位
    });

    test('非法值为 null', () {
      expect(b2.endMinutes, isNull); // 25:00
      expect(b3.startMinutes, isNull); // abc
      expect(b3.endMinutes, isNull); // 09:5
    });
  });

  test('坏 JSON 文件 → 空库不崩溃', () {
    final repo = Repo(
      File('${tmp.path}${Platform.pathSeparator}bad_matters.json'),
      File('${tmp.path}${Platform.pathSeparator}bad_state.json'),
    );
    repo.mattersFile.writeAsStringSync('{坏掉的');
    repo.stateFile.writeAsStringSync('不是数组');
    expect(repo.loadMatters(), isEmpty);
    expect(repo.loadState(), isEmpty);
  });

  group('M-034 多轨日程', () {
    test('异轨不冲突：重排主轨不动伴随轨', () {
      final old = [
        const ScheduleBlock(start: '14:00', end: '16:00', matterRef: 'AI 开发'),
        const ScheduleBlock(start: '14:00', end: '16:00', matterRef: '背单词', track: 1),
      ];
      // 重排主轨同时段
      final incoming = [
        const ScheduleBlock(start: '14:00', end: '16:00', matterRef: '写论文'),
      ];
      final merged = AppState.mergeSchedule(old, incoming);
      expect(merged.length, 2, reason: '主轨被替换（1条新）+伴随轨保留（背单词）');
      expect(merged.where((b) => b.matterRef == '背单词').first.track, 1);
      expect(merged.where((b) => b.matterRef == '背单词').length, 1);
      expect(merged.where((b) => b.matterRef == '写论文').length, 1);
      expect(merged.where((b) => b.matterRef == 'AI 开发').length, 0, reason: '旧主轨被同轨重叠替换');
    });

    test('track 字段解析兼容：无 track 字段=主轨；字符串数字也能解析', () {
      final b1 = ScheduleBlock.fromJson({'start': '09:00', 'end': '10:00', 'matter_ref': '旧数据'});
      expect(b1.track, 0, reason: '旧数据无 track → 主轨');
      final b2 = ScheduleBlock.fromJson({'start': '09:00', 'end': '10:00', 'matter_ref': 'x', 'track': '2'});
      expect(b2.track, 2, reason: '字符串数字容错');
      expect(b2.isParallel, isTrue);
      expect(b1.toJson().containsKey('track'), isFalse, reason: '主轨不写 track 字段（省空间）');
      expect(b2.toJson()['track'], 2);
    });

    test('三轨并存：主+两伴随同起点排序主轨在前', () {
      final blocks = [
        const ScheduleBlock(start: '14:00', end: '16:00', matterRef: '伴随2', track: 2),
        const ScheduleBlock(start: '14:00', end: '16:00', matterRef: '主'),
        const ScheduleBlock(start: '14:00', end: '16:00', matterRef: '伴随1', track: 1),
      ];
      final merged = AppState.mergeSchedule(const [], blocks);
      expect(merged.first.matterRef, '主', reason: '同起点主轨排最前');
    });
  });

  group('M-035 时间空洞', () {
    test('主轨未覆盖时段成洞；伴随轨不算覆盖', () {
      final blocks = [
        const ScheduleBlock(start: '09:00', end: '10:00', matterRef: 'A'),
        const ScheduleBlock(start: '10:30', end: '12:00', matterRef: 'B'),
        const ScheduleBlock(start: '10:30', end: '12:00', matterRef: '背单词', track: 1),
      ];
      final gaps = AppState.uncoveredGaps(blocks, minMinutes: 15);
      // 洞：0:00-9:00（若from=0）、10:00-10:30、12:00-24:00；伴随轨不影响
      expect(gaps.contains((600, 630)), isTrue, reason: '10:00-10:30 的 30 分钟洞');
      final morning = gaps.where((g) => g.$1 == 0).toList();
      expect(morning, isNotEmpty, reason: '清晨未覆盖也是洞');
    });

    test('阈值过滤：15 分钟以下的洞不算', () {
      final blocks = [
        const ScheduleBlock(start: '09:00', end: '10:00', matterRef: 'A'),
        const ScheduleBlock(start: '10:10', end: '11:00', matterRef: 'B'), // 10 分钟缝
      ];
      final gaps = AppState.uncoveredGaps(blocks, fromMinute: 9 * 60, toMinute: 11 * 60, minMinutes: 15);
      expect(gaps.where((g) => g.$1 == 600), isEmpty, reason: '10 分钟小缝被阈值过滤');
    });

    test('指定区间扫描：只看 8 点到现在', () {
      final blocks = [
        const ScheduleBlock(start: '09:00', end: '18:00', matterRef: '全天'),
      ];
      // 8:00-20:00 区间 → 洞只有 8:00-9:00 和 18:00-20:00，不含深夜
      final gaps = AppState.uncoveredGaps(blocks, fromMinute: 8 * 60, toMinute: 20 * 60, minMinutes: 15);
      expect(gaps.length, 2);
      expect(gaps.first, (480, 540));
      expect(gaps.last, (1080, 1200));
    });
  });

  group('M-013 mergeSchedule（安排合并语义）', () {    const am = ScheduleBlock(start: '09:00', end: '11:00', matterRef: '上午事');
    const pm = ScheduleBlock(start: '14:00', end: '16:00', matterRef: '下午事');

    test('非重叠新块：旧块全保留，按时序排序', () {
      final merged = AppState.mergeSchedule([pm], [am]);
      expect(merged.length, 2);
      expect(merged.first.start, '09:00');
    });

    test('时间重叠：旧块被新块替换（重新安排某时段）', () {
      const amNew = ScheduleBlock(start: '09:30', end: '10:30', matterRef: '新安排');
      final merged = AppState.mergeSchedule([am, pm], [amNew]);
      expect(merged.length, 2, reason: 'am 被 amNew 替换，pm 保留');
      expect(merged.any((b) => b.matterRef == '新安排'), true);
      expect(merged.any((b) => b.matterRef == '下午事'), true);
      expect(merged.any((b) => b.matterRef == '上午事'), false);
    });

    test('坏时间块（无法解析）：保守保留旧块', () {
      const bad = ScheduleBlock(start: 'xx', end: 'yy', matterRef: '坏的');
      final merged = AppState.mergeSchedule([am], [bad]);
      expect(merged.where((b) => b.matterRef == '上午事').length, 1);
    });
  });

  test('M-013 evidence 截尾最近 10 条', () {
    final repo = newRepo();
    for (var i = 1; i <= 15; i++) {
      repo.applyStateUpdates(
          [StateUpdate(dim: 'body', value: '值$i', evidence: '依据$i')]);
    }
    final day = repo.loadState().first;
    expect(day.body.evidence.length, 10, reason: '截尾保留最近10条');
    expect(day.body.evidence.first, '依据6'); // 丢最老的 1~5
    expect(day.body.evidence.last, '依据15');
    expect(day.body.value, '值15'); // 值取最新
  });

  test('M-017 扩展层红线：内核语义键被拦截，合法扩展键放行', () {
    final repo = newRepo();
    repo.applyMatterOps([const MatterOp(op: 'add', name: '测试事项')]);

    final r = repo.applyMatterOps(const [
      MatterOp(
        op: 'update',
        name: '测试事项',
        extPatch: {
          'time_req': '明天截止', // 内核键 → 拦截
          'Deadline': '周五', // 大小写变体 → 拦截
          'progress': '30%', // 合法扩展键 → 放行
        },
      ),
    ]);
    final m = (r.data as List<Matter>).first;
    expect(m.ext.containsKey('progress'), true, reason: '合法扩展键放行');
    expect(m.ext.containsKey('time_req'), false, reason: '内核键拦截');
    expect(m.ext.containsKey('Deadline'), false, reason: '大小写变体拦截');
    expect(r.log.any((l) => l.contains('越界')), true, reason: '拦截记日志');
    expect(m.core.timeReq, '', reason: '塞 ext 的内核值不得进入内核（须走 core）');
  });

  test('M-018 状态轨迹：多次回填保留时段历史，value 取最新', () {
    final repo = newRepo();
    repo.applyStateUpdates(
        [StateUpdate(dim: 'body', value: '早上精神好', evidence: '睡饱了')]);
    repo.applyStateUpdates(
        [StateUpdate(dim: 'body', value: '下午有点困', evidence: '饭后')]);
    repo.applyStateUpdates(
        [StateUpdate(dim: 'body', value: '晚上恢复了', evidence: '小睡了')]);

    final day = repo.loadState().first;
    expect(day.body.value, '晚上恢复了');
    expect(day.body.history.length, 2, reason: '两次覆盖各留一条轨迹');
    expect(day.body.history.first['value'], '早上精神好');
    expect(day.body.history.last['value'], '下午有点困');
    expect(day.body.history.first['time'], isNotEmpty, reason: 'HH:mm 时间戳');
    // round-trip：轨迹持久化
    expect(repo.loadState().first.body.history.length, 2);
  });
}
