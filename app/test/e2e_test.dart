// 集成测试：全链路离线验证（M-009）
// FakeClient 模拟供应商 HTTP 响应，验证：
// 发送 → 三件套组装 → HTTP → 协议解析 → 两库落盘 → schedule 持久化 → 聊天回复
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiwu_companion/data/repo.dart';
import 'package:shiwu_companion/llm/providers.dart';
import 'package:shiwu_companion/state.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shiwu_e2e_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 造一个注入了 FakeClient 的 AppState：HTTP 层模拟供应商返回固定接收文件
  /// （receiveFileJson 会被包进 OpenAI choices 信封，还原真实供应商行为）
  (AppState, List<Map<String, dynamic>>) newApp(String receiveFileJson) {
    final captured = <Map<String, dynamic>>[]; // 捕获发往"供应商"的请求体

    // 按请求内容路由响应：arrange 轮回 schedule_blocks，chat 轮回 add op
    // （userPayload 是嵌套 JSON 字符串，外层信封会转义引号，故匹配转义形式）
    String respFor(String body) {
      if (body.contains(r'\"mode\":\"arrange\"')) return receiveFileJson;
      return '{"matter_ops": [{"op": "add", "name": "交报表", "core": {"time_req": "下周三截止"}}], "state_updates": [{"dim": "body", "value": "电量60%", "evidence": "昨晚只睡5小时"}], "reply": "记下了", "schedule_blocks": []}';
    }

    final fake = MockClient((req) async {
      if (req.body.isNotEmpty) {
        try {
          captured.add(Map<String, dynamic>.from(jsonDecode(req.body) as Map));
        } catch (_) {}
      }
      final envelope = jsonEncode({
        'choices': [
          {'message': {'role': 'assistant', 'content': respFor(req.body)}}
        ],
      });
      // 显式 UTF-8：http.Response 默认 latin1，中文响应体会直接 ArgumentError
      return http.Response(envelope, 200, headers: {
        'content-type': 'application/json; charset=utf-8',
      });
    });

    final repo = Repo.at(tmp);
    final app = AppState(
      repo,
      scheduleFile: File('${tmp.path}${Platform.pathSeparator}schedule.json'),
      clientFactory: (c) => LlmClient(c, client: fake),
    );
    return (app, captured);
  }

  void equip(AppState app) {
    app.providers = const [
      ProviderConfig(
          id: 'zhipu', label: '智谱', baseUrl: 'https://x', model: 'm', apiKey: 'sk-test'),
    ];
    app.activeProviderId = 'zhipu';
  }

  test('沟通模式全链路：一句话 → 事项入库 + 状态回填 + 回复气泡', () async {
    const llmResp = '''
    {"matter_ops": [{"op": "add", "name": "交报表", "core": {"time_req": "下周三截止", "exclusive": true}}],
     "state_updates": [{"dim": "body", "value": "电量60%", "evidence": "昨晚只睡5小时"}],
     "reply": "记下了，下周三交报表。昨晚没睡好，今天悠着点。",
     "schedule_blocks": []}
    ''';
    final (app, captured) = newApp(llmResp);
    equip(app);

    await app.send('下周三要交报表，昨晚没睡好');

    // 1) HTTP 请求发出且带三件套
    expect(captured.length, 1);
    final body = captured.first;
    expect(body['model'], 'm'); // OpenAI 兼容载荷
    final messages = body['messages'] as List;
    expect(messages.first['role'], 'system');
    expect(messages.last['role'], 'user');
    final userPayload =
        Map<String, dynamic>.from(jsonDecode(messages.last['content'] as String) as Map);
    expect(userPayload['mode'], 'chat');
    expect(userPayload['user_said'], '下周三要交报表，昨晚没睡好');
    expect(userPayload['matters_kb'], isA<List>());
    expect(userPayload['state_kb'], isA<List>());

    // 2) 事项落库（真实写盘，重启可恢复）
    expect(app.matters.length, 1);
    expect(app.matters.first.name, '交报表');
    expect(app.matters.first.core.timeReq, '下周三截止');
    expect(Repo.at(tmp).loadMatters().length, 1);

    // 3) 状态回填
    expect(app.stateDays.length, 1);
    expect(app.stateDays.first.body.value, '电量60%');

    // 4) 聊天回复带透明摘要
    expect(app.chat.length, 2);
    expect(app.chat.last.fromUser, false);
    expect(app.chat.last.text, contains('记下了'));
    expect(app.chat.last.sideLog.join(' '), contains('新增'));
    expect(app.sending, false);
  });

  test('安排模式全链路：请求 → schedule_blocks 落进度条并持久化', () async {
    final (app, captured) = newApp('''
    {"matter_ops": [], "state_updates": [],
     "reply": "上午认知好，先干报表。",
     "schedule_blocks": [
       {"start": "09:00", "end": "10:30", "matter_ref": "交报表", "reason": "认知高峰期"},
       {"start": "10:45", "end": "11:15", "matter_ref": "回邮件", "reason": "轻活过渡"}
     ]}
    ''');
    equip(app);

    // 先攒一点库内容，验证安排模式报文携带两库全量（REQ-006）
    await app.send('下周三要交报表');
    expect(app.matters.length, 1, reason: '前置：沟通轮已入库');
    captured.clear();

    await app.send('安排我接下来两小时', arrangeMode: true);

    // REQ-006：安排模式报文=两库全量+请求，mode=arrange
    expect(captured.length, 1);
    final userPayload = Map<String, dynamic>.from(jsonDecode(
        (captured.first['messages'] as List).last['content'] as String) as Map);
    expect(userPayload['mode'], 'arrange');
    expect(userPayload['matters_kb'] as List, isNotEmpty,
        reason: '安排模式必须带事项库全量（REQ-006）');
    expect(userPayload['state_kb'], isA<List>());

    // 时间块进内存 + 落盘
    expect(app.schedule.length, 2);
    expect(app.schedule.first.matterRef, '交报表');
    final persisted = File('${tmp.path}${Platform.pathSeparator}schedule.json');
    expect(persisted.existsSync(), true);
    final saved = Map<String, dynamic>.from(jsonDecode(persisted.readAsStringSync()) as Map);
    expect((saved[AppState.today()] as List).length, 2);

    // 重启模拟：今日安排自动恢复
    final app2 = AppState(Repo.at(tmp), scheduleFile: persisted);
    expect(app2.schedule.length, 2);
  });

  test('供应商故障：报错气泡但不丢用户消息、不写坏库', () async {
    final fake500 = MockClient((req) async => http.Response('boom', 500));
    final repo = Repo.at(tmp);
    final app = AppState(
      repo,
      scheduleFile: File('${tmp.path}${Platform.pathSeparator}schedule.json'),
      clientFactory: (c) => LlmClient(c, client: fake500),
    );
    equip(app);

    await app.send('随便说点什么');

    expect(app.chat.length, 2);
    expect(app.chat.first.fromUser, true); // 用户消息保留
    expect(app.chat.last.text, contains('模型调用失败')); // 错误可见
    expect(app.matters, isEmpty); // 库未被写坏
    expect(app.sending, false); // 状态复位，不卡死
  });

  test('未配置供应商：引导提示而非崩溃', () async {
    final repo = Repo.at(tmp);
    final app = AppState(
      repo,
      scheduleFile: File('${tmp.path}${Platform.pathSeparator}schedule.json'),
    );
    await app.send('你好');
    expect(app.chat.last.text, contains('设置'));
    expect(app.error, isNotNull);
  });

  test('M-022：保存并激活供应商后 AppState 立即可用，无需重启', () async {
    final (app, captured) = newApp(
        '{"matter_ops": [], "state_updates": [], "reply": "收到", "schedule_blocks": []}');
    // 注入 ProviderStore 文件路径，避免单元测试依赖 path_provider 平台实现
    ProviderStore.setStoreFile(File('${tmp.path}${Platform.pathSeparator}providers.json'));
    expect(app.ready, false, reason: '初始无供应商，不可发送');

    // 模拟设置页保存并激活供应商（M-022 根因：设置页绕过 AppState 导致内存未更新）
    await app.saveProvider(
      const ProviderConfig(
        id: 'zhipu_coding',
        label: '智谱 Coding Plan',
        baseUrl: 'https://open.bigmodel.cn/api/coding/paas/v4',
        model: 'glm-5.2',
        apiKey: 'sk-test',
      ),
      activate: true,
    );

    expect(app.ready, true, reason: 'saveProvider 后 AppState 应立即识别激活的供应商');
    expect(app.activeProviderId, 'zhipu_coding');
    expect(app.providers.length, 1);
    expect(app.providers.first.apiKey, 'sk-test');

    // 验证发送时不再报“未配置”，且请求能正常发出
    await app.send('你好');
    expect(captured.length, 1, reason: '供应商可用后请求应发出');
    expect(app.chat.last.text, '记下了');
  });

  test('M-013：两轮非重叠安排合并保留（不整体覆盖）', () async {
    // mock 按 arrange 调用次序返回不同安排块（第1轮上午块，第2轮晚上块）
    var arrangeCalls = 0;
    final arrangeResponses = [
      '''
      {"matter_ops": [], "state_updates": [], "reply": "上午安排好了",
       "schedule_blocks": [
         {"start": "09:00", "end": "11:00", "matter_ref": "交报表", "reason": "认知高峰"}
       ]}
      ''',
      '''
      {"matter_ops": [], "state_updates": [], "reply": "晚上安排好了",
       "schedule_blocks": [
         {"start": "20:00", "end": "22:00", "matter_ref": "读文档", "reason": "晚间安静"}
       ]}
      ''',
    ];

    final fake = MockClient((req) async {
      final isArrange = req.body.contains(r'\"mode\":\"arrange\"');
      final rf = isArrange
          ? arrangeResponses[arrangeCalls++ % arrangeResponses.length]
          : '{"matter_ops": [], "state_updates": [], "reply": "好", "schedule_blocks": []}';
      return http.Response(
          jsonEncode({
            'choices': [
              {'message': {'role': 'assistant', 'content': rf}}
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });

    final repo = Repo.at(tmp);
    final app = AppState(repo,
        scheduleFile: File('${tmp.path}${Platform.pathSeparator}schedule.json'),
        clientFactory: (c) => LlmClient(c, client: fake));
    equip(app);

    await app.send('安排我上午', arrangeMode: true);
    expect(app.schedule.length, 1);
    expect(app.schedule.first.start, '09:00');

    await app.send('安排我今晚', arrangeMode: true);
    // 合并语义：上午块保留 + 晚上新块，共 2 块且按时间排序
    expect(app.schedule.length, 2, reason: 'M-013：非重叠旧块不得被覆盖');
    expect(app.schedule.first.start, '09:00');
    expect(app.schedule.last.start, '20:00');

    // 落盘同样合并
    final saved = Map<String, dynamic>.from(jsonDecode(
        File('${tmp.path}${Platform.pathSeparator}schedule.json')
            .readAsStringSync()) as Map);
    expect((saved[AppState.today()] as List).length, 2);
  });

  test('M-011：对话上下文滑窗传递 + 聊天历史重启恢复', () async {
    final (app, captured) = newApp(
        '{"matter_ops": [], "state_updates": [], "reply": "好的", "schedule_blocks": []}');
    equip(app);

    // 第一轮
    await app.send('下周三要交报表');
    // 第二轮：报文应含第一轮的对话上下文
    captured.clear();
    await app.send('就是那个报表，要提前两天准备');

    expect(captured.length, 1);
    final payload = Map<String, dynamic>.from(jsonDecode(
        (captured.first['messages'] as List).last['content'] as String) as Map);
    final dialogue = payload['recent_dialogue'] as List?;
    expect(dialogue, isNotNull, reason: '第二轮报文必须带对话上下文（M-011）');
    expect(dialogue!.length, 2); // 第一轮 user+assistant
    expect(dialogue.first['role'], 'user');
    expect(dialogue.first['text'], '下周三要交报表');
    expect(dialogue.last['role'], 'assistant');

    // 聊天历史落盘 + 重启恢复（chat.json 与两库同目录 tmp/data/）
    final dataDir = '${tmp.path}${Platform.pathSeparator}data';
    final chatFile = File('$dataDir${Platform.pathSeparator}chat.json');
    expect(chatFile.existsSync(), true);
    final app2 = AppState(Repo.at(tmp),
        scheduleFile: File('${tmp.path}${Platform.pathSeparator}schedule.json'),
        chatFile: chatFile);
    expect(app2.chat.length, 4, reason: '重启后聊天历史恢复');
    expect(app2.chat.first.text, '下周三要交报表');
  });
}
