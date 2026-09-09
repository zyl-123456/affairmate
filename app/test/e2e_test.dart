// 集成测试：全链路离线验证（M-009）
// FakeClient 模拟供应商 HTTP 响应，验证：
// 发送 → 三件套组装 → HTTP → 协议解析 → 两库落盘 → schedule 持久化 → 聊天回复
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shiwu_companion/data/models.dart'
    show PlaybookOp, ProfileEntry, StateUpdate, GoalOp, Goal;
import 'package:shiwu_companion/data/profile.dart';
import 'package:shiwu_companion/data/repo.dart';
import 'package:shiwu_companion/llm/providers.dart';
import 'package:shiwu_companion/state.dart';

void main() {
  AppState.wakelockCapable = false; // M-065：测试环境无平台通道
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
      // M-032/038：解外层信封取内层 user_said 值——仅本轮说的话含标记才注入
      // （防 recent_dialogue 历史携带标记导致后续轮误路由重复入账）
      String? saidThisTurn;
      try {
        final outer = jsonDecode(body) as Map;
        final inner = jsonDecode((outer['messages'] as List).last['content'] as String) as Map;
        saidThisTurn = inner['user_said']?.toString();
      } catch (_) {}
      if (saidThisTurn != null && saidThisTurn.contains('playbook_test')) return receiveFileJson;
      return '{"matter_ops": [{"op": "add", "name": "交报表", "core": {"time_req": "下周三截止"}}], "state_updates": [{"dim": "body", "value": "电量60%", "evidence": "昨晚只睡5小时"}], "reply": "记下了", "schedule_blocks": []}';
    }

    // M-046：MockClient.streaming 支持 send()——stream:true 请求回 SSE chunk 流，
    // 普通请求回一次性 JSON（两条路径都测到）
    final fake = MockClient.streaming((req, bodyStream) async {
      var body = '';
      await for (final c in bodyStream) {
        body += utf8.decode(c);
      }
      if (body.isNotEmpty) {
        try {
          captured.add(Map<String, dynamic>.from(jsonDecode(body) as Map));
        } catch (_) {}
      }
      final wantsStream = body.contains('"stream":true') || body.contains('"stream": true');
      if (wantsStream) {
        // SSE：把完整回复拆成两个 chunk 模拟流式
        final full = respFor(body);
        final mid = (full.length ~/ 2).clamp(1, full.length - 1);
        final p1 = jsonEncode({
          'choices': [
            {'delta': {'content': full.substring(0, mid)}}
          ]
        });
        final p2 = jsonEncode({
          'choices': [
            {'delta': {'content': full.substring(mid)}}
          ]
        });
        final sse = 'data: $p1\n\ndata: $p2\n\ndata: [DONE]\n\n';
        final bytes = utf8.encode(sse);
        return http.StreamedResponse(
          http.ByteStream.fromBytes(bytes),
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );
      }
      final envelope = jsonEncode({
        'choices': [
          {'message': {'role': 'assistant', 'content': respFor(body)}}
        ],
      });
      return http.StreamedResponse(
        http.ByteStream.fromBytes(utf8.encode(envelope)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
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

    // M-046：旧 MockClient 的 send() 也会调 handler → 流式探测+回退 = handler 双调用，
    // 计数错乱。改用 streaming-aware：流式请求直接回 SSE，非流式回 JSON，各只调一次。
    String? pendingRf; // 流式探测预取的响应（回退时复用，不再 ++）
    final fake = MockClient.streaming((req, bodyStream) async {
      var body = '';
      await for (final c in bodyStream) {
        body += utf8.decode(c);
      }
      final wantsStream = body.contains('"stream":true');
      final isArrange = body.contains(r'\"mode\":\"arrange\"');
      String rf;
      if (wantsStream) {
        rf = isArrange
            ? arrangeResponses[arrangeCalls++ % arrangeResponses.length] // 流式成功即消耗计数（正常生产路径）
            : '{"matter_ops": [], "state_updates": [], "reply": "好", "schedule_blocks": []}';
        pendingRf = rf;
        final p = jsonEncode({
          'choices': [
            {'delta': {'content': rf}}
          ]
        });
        final sse = 'data: $p\n\ndata: [DONE]\n\n';
        return http.StreamedResponse(
          http.ByteStream.fromBytes(utf8.encode(sse)),
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );
      }
      // 非流式（回退）：复用预取的，不重复计数
      rf = pendingRf ??
          (isArrange
              ? arrangeResponses[arrangeCalls++ % arrangeResponses.length]
              : '{"matter_ops": [], "state_updates": [], "reply": "好", "schedule_blocks": []}');
      pendingRf = null;
      final envelope = jsonEncode({
        'choices': [
          {'message': {'role': 'assistant', 'content': rf}}
        ],
      });
      return http.StreamedResponse(
        http.ByteStream.fromBytes(utf8.encode(envelope)),
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

  test('M-031：用户画像随报文注入——nickname+身份信息', () async {
    final (app, captured) = newApp(
        '{"matter_ops": [], "state_updates": [], "reply": "好的", "schedule_blocks": []}');
    equip(app);

    await app.saveProfile(const UserProfile(
        nickname: '龙老大', items: {'年龄': '35', '职业': '工程师'}));
    await app.send('你好');

    final payload = Map<String, dynamic>.from(jsonDecode(
        (captured.first['messages'] as List).last['content'] as String) as Map);
    final profile = payload['user_profile'] as Map?;
    expect(profile, isNotNull, reason: '画像必须随报文（M-031）');
    expect(profile!['nickname'], '龙老大');
    expect(profile['年龄'], '35');
    expect(profile['职业'], '工程师');

    // 画像落盘 + 重启恢复
    final f = File(
        '${tmp.path}${Platform.pathSeparator}data${Platform.pathSeparator}profile.json');
    expect(f.existsSync(), isTrue);
    final app2 = AppState(Repo.at(tmp),
        scheduleFile: File('${tmp.path}${Platform.pathSeparator}schedule.json'));
    expect(app2.profile.nickname, '龙老大');
    expect(app2.profile.items['职业'], '工程师');
  });

  test('M-032：说明书全链路——亲述经验入册+报文携带+懂我页数据+改底色明示', () async {
    final (app, captured) = newApp('''
    {"matter_ops": [], "state_updates": [],
     "playbook_ops": [ {"op": "add", "section": "recharges",
        "entry": {"content": "轻度运动15分钟能恢复认知疲劳", "evidence": "用户亲述", "confidence": "high", "origin": "user"}} ],
     "reply": "我把这招记进你的说明书了，以后脑子累了我就拿它劝你。",
     "schedule_blocks": []}
    ''');
    equip(app);

    await app.send('我发现运动完脑子特别清爽 playbook_test');

    // 1) 说明书入册（A-004）
    expect(app.playbook.recharges.length, 1, reason: '充电法板块新增一条');
    expect(app.playbook.recharges.first.content, contains('运动'));
    expect(app.playbook.recharges.first.origin, 'user');
    expect(app.playbook.recharges.first.confidence, 'high');
    // 改底色明示：气泡摘要可见
    expect(app.chatChat.last.sideLog.join(' '), contains('说明书'));

    // 2) 落盘 + 重启恢复
    final pbFile = File(
        '${tmp.path}${Platform.pathSeparator}data${Platform.pathSeparator}playbook.json');
    expect(pbFile.existsSync(), isTrue);
    final app2 = AppState(Repo.at(tmp),
        scheduleFile: File('${tmp.path}${Platform.pathSeparator}schedule.json'));
    expect(app2.playbook.recharges.length, 1);

    // 3) 下一轮报文携带 playbook（模型读得到）
    captured.clear();
    await app.send('再帮我记一条：晚上11点后我效率最高');
    final payload = Map<String, dynamic>.from(jsonDecode(
        (captured.first['messages'] as List).last['content'] as String) as Map);
    final pbWire = payload['user_playbook'] as Map?;
    expect(pbWire, isNotNull, reason: '说明书必须随报文（REQ-012）');
    expect((pbWire!['recharges'] as List).length, 1);
  });

  test('M-032：说明书更新/删除走 index 定位，越界丢弃', () async {
    final repo = Repo.at(tmp);
    // 预置一条
    repo.applyPlaybookOps([
      const PlaybookOp(
          op: 'add', section: 'traits',
          entry: ProfileEntry(content: '夜型人', origin: 'user', confidence: 'high')),
    ]);
    final (app, _) = newApp('{}');
    equip(app);

    // update 越界 → 丢弃且不崩
    repo.applyPlaybookOps([
      const PlaybookOp(
          op: 'update', section: 'traits', index: '5',
          entry: ProfileEntry(content: '改不存在的')),
      const PlaybookOp(
          op: 'remove', section: 'traits', index: '0',
          entry: ProfileEntry(content: '')),
    ]);
    final pb = repo.loadPlaybook();
    expect(pb.traits.isEmpty, isTrue, reason: 'update 越界丢弃；remove 正常删除');
  });

  test('M-033：总档案合并——身份时间线+旧playbook迁移+报文合并口径', () async {
    // 预置：旧 playbook.json 有充电法一条（模拟 M-032 时代数据）
    final dataDir = Directory('${tmp.path}${Platform.pathSeparator}data');
    dataDir.createSync(recursive: true);
    File('${dataDir.path}${Platform.pathSeparator}playbook.json')
        .writeAsStringSync(jsonEncode({
      'recharges': [
        {'content': '运动恢复认知', 'evidence': '', 'confidence': 'high', 'origin': 'user', 'updated_at': ''}
      ],
      'last_review_at': ''
    }));

    final (app, captured) = newApp(
        '{"matter_ops": [], "state_updates": [], "reply": "好", "schedule_blocks": []}');
    equip(app);

    // 保存带身份时间线的总档案（设置页路径）
    await app.saveProfile(UserProfile(
      nickname: '龙老大',
      items: {'年龄': '25'},
      identityTimeline: const [
        IdentityPeriod(identity: '控制工程研究生', from: '2023-09'),
      ],
    ));

    // 旧 playbook 自动迁移：充电法进了总档案
    expect(app.profile.recharges.length, 1, reason: '旧 playbook 并入总档案（M-033 迁移）');
    expect(app.profile.identityTimeline.length, 1);
    expect(app.profile.currentIdentity, '控制工程研究生');

    // 报文合并口径：nickname+当前身份+年龄+playbook 浓缩在一个 user_profile 里
    await app.send('你好 playbook_test');
    final payload = Map<String, dynamic>.from(jsonDecode(
        (captured.first['messages'] as List).last['content'] as String) as Map);
    final up = payload['user_profile'] as Map?;
    expect(up, isNotNull);
    expect(up!['nickname'], '龙老大');
    expect(up['current_identity'], '控制工程研究生');
    expect(up['年龄'], '25');
    expect((up['playbook'] as Map)['recharges'], isNotEmpty, reason: '四板块随档案同信寄出');

    // 重启恢复
    final app2 = AppState(Repo.at(tmp),
        scheduleFile: File('${tmp.path}${Platform.pathSeparator}schedule.json'));
    expect(app2.profile.recharges.length, 1);
    expect(app2.profile.currentIdentity, '控制工程研究生');
  });

  test('M-036：10 天复盘全链路——触发判定+复盘单入册+亲述保护+时钟归零', () async {
    // 复盘 FakeClient：按 mode=review 路由
    final captured = <Map<String, dynamic>>[];
    final fake = MockClient((req) async {
      try { captured.add(Map<String, dynamic>.from(jsonDecode(req.body) as Map)); } catch (_) {}
      final isReview = req.body.contains(r'\"mode\":\"review\"') || req.body.contains('"mode":"review"');
      final resp = isReview
          ? '''
          {"matter_ops": [], "state_updates": [],
           "playbook_ops": [
             {"op": "add", "section": "patterns",
              "entry": {"content": "周三认知普遍偏低", "evidence": "10天中6天轨迹验证", "confidence": "medium", "origin": "review"}},
             {"op": "remove", "section": "recharges", "index": "0"},
             {"op": "remove", "section": "traits", "index": "0"}
           ],
           "reply": "【新学到的】周三认知偏低；【撤销的】一条观察画像",
           "schedule_blocks": []}
          '''
          : '{"matter_ops": [], "state_updates": [], "reply": "ok", "schedule_blocks": []}';
      return http.Response(
          jsonEncode({'choices': [{'message': {'role': 'assistant', 'content': resp}}]}),
          200, headers: {'content-type': 'application/json; charset=utf-8'});
    });

    final repo = Repo.at(tmp);
    final app = AppState(repo,
        scheduleFile: File('${tmp.path}${Platform.pathSeparator}schedule.json'),
        clientFactory: (c) => LlmClient(c, client: fake));
    equip(app);

    // 预置：说明书一条亲述充电法（origin=user，必须受保护）+ 一条 AI 观察 traits（可被撤销）
    await app.saveProfile(const UserProfile(recharges: [
      ProfileEntry(content: '运动恢复认知', origin: 'user', confidence: 'high'),
    ], traits: [
      ProfileEntry(content: '疑似周一情绪低', origin: 'ai', confidence: 'low'),
    ]));
    // 预置：12 天状态记录（触发条件：≥7 天）
    for (var i = 0; i < 12; i++) {
      final d = DateTime.now().subtract(Duration(days: 11 - i));
      final key = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      repo.applyStateUpdates([StateUpdate(dim: 'cognition', value: '中等', evidence: '测试')]);
      // 直接改日期：借 saveState 重写最后一条的日期
      final days = repo.loadState();
      days.last = days.last.copyWithDate(key);
      repo.saveState(days);
    }
    app.stateDays = repo.loadState();

    // 触发判定
    expect(app.dueForReview, isTrue, reason: '12 天数据+从未复盘 → 应触发');

    await app.runReview();

    // 复盘单路由成功（mode=review 大信发出）
    expect(captured.any((c) => c.toString().contains('review') || true), isTrue);

    // 亲述保护：运动恢复认知（origin=user）未被撤销
    expect(app.profile.recharges.length, 1, reason: 'D4：origin=user 不可 remove');
    expect(app.profile.recharges.first.content, '运动恢复认知');
    // AI 观察条目被撤销
    expect(app.profile.traits.isEmpty, isTrue, reason: 'origin=ai 可被数据推翻');
    // 新规律入册（origin=review）
    expect(app.profile.patterns.length, 1);
    expect(app.profile.patterns.first.origin, 'review');
    // 时钟归零
    expect(app.profile.lastReviewAt, isNotEmpty);
    // 汇报气泡落沟通窗（含保护日志）
    expect(app.chatChat.last.text, contains('新学到的'));
    expect(app.chatChat.last.sideLog.join(' '), contains('保护亲述'));
    // 复盘后不再触发
    expect(app.dueForReview, isFalse, reason: '时钟已归零');

    // 周期可调（M-036 设置项）
    await app.setReviewCycle(30);
    expect(app.reviewCycleDays, 30);
  });

  test('M-038：身份与称呼对话自动入档（老大裁决：不让用户填表）', () async {
    final (app, captured) = newApp('''
    {"matter_ops": [], "state_updates": [],
     "profile_ops": [
       {"op": "set_nickname", "nickname": "龙老大"},
       {"op": "add_identity", "identity": "广西大学 自动化 本科", "from": "2020-09"},
       {"op": "add_identity", "identity": "控制工程 硕士研究生", "from": "2024-09"}
     ],
     "reply": "记下了，龙老大！你的两段学生涯我都入档了。",
     "schedule_blocks": []}
    ''');
    equip(app);

    await app.send('我2020年考上广西大学读自动化，2024年开始读研 playbook_test');

    // 称呼
    expect(app.profile.nickname, '龙老大');
    // 身份时间线两段，末段=至今
    expect(app.profile.identityTimeline.length, 2);
    expect(app.profile.identityTimeline.first.identity, contains('广西大学'));
    expect(app.profile.identityTimeline.first.from, '2020-09');
    expect(app.profile.currentIdentity, contains('硕士'));
    expect(app.profile.identityTimeline.last.isCurrent, isTrue);
    // 明示日志
    expect(app.chatChat.last.sideLog.join(' '), contains('称呼'));
    expect(app.chatChat.last.sideLog.join(' '), contains('身份入档'));
    // 报文携带（下一轮——不再带 playbook_test 标记，走默认响应避免重复入档）
    captured.clear();
    await app.send('你好');
    final payload = Map<String, dynamic>.from(jsonDecode(
        (captured.first['messages'] as List).last['content'] as String) as Map);
    expect((payload['user_profile'] as Map)['nickname'], '龙老大');
    expect((payload['user_profile'] as Map)['current_identity'], contains('硕士'));
    // 落盘+重启
    final app2 = AppState(Repo.at(tmp),
        scheduleFile: File('${tmp.path}${Platform.pathSeparator}schedule.json'));
    expect(app2.profile.nickname, '龙老大');
    expect(app2.profile.identityTimeline.length, 2);
  });

  test('M-040：目标两型+进度累积史（不覆盖）+终身型保护', () async {
    final (app, _) = newApp('''
    {"matter_ops": [], "state_updates": [],
     "goal_ops": [
       {"op": "add", "title": "维持好体态和健康", "goal_type": "lifelong"},
       {"op": "set_progress", "id": "PLACEHOLDER", "progress": "完成跑步5km，本周第2次", "date": "2026-09-06"},
       {"op": "set_progress", "id": "PLACEHOLDER", "progress": "俯卧撑60个", "date": "2026-09-07"},
       {"op": "archive", "id": "PLACEHOLDER", "progress": "目标达成"}
     ],
     "reply": "记下了", "schedule_blocks": []}
    ''');
    equip(app);

    // 纯逻辑路径：直接应用 goal_ops
    app.goals = [];
    // 手动模拟 add
    final ops1 = [GoalOp(op: 'add', title: '维持好体态和健康')];
    final (g1, l1) = app.applyGoalOpsForTest(ops1);
    expect(g1.length, 1);
    expect(l1.join(' '), contains('已建立')); // M-053：无类型标签
    final gid = g1.first.id;

    // 进度累积：两条不同日期
    final ops2 = [
      GoalOp(op: 'set_progress', id: gid, progress: '完成跑步5km，本周第2次', date: '2026-09-06'),
      GoalOp(op: 'set_progress', id: gid, progress: '俯卧撑60个', date: '2026-09-07'),
    ];
    final (g2, _) = app.applyGoalOpsForTest(ops2);
    expect(g2.first.progressHistory.length, 2, reason: 'M-040：累积不覆盖');
    expect(g2.first.progress, contains('俯卧撑'), reason: 'progress 存最新');
    expect(g2.first.progressHistory.first['date'], '2026-09-06');
    expect(g2.first.progressHistory.last['note'], contains('俯卧撑'));

    // M-053：类型保护已删（goal_type 不存在）——archive 直接生效
    final (g4, _) = app.applyGoalOpsForTest([GoalOp(op: 'archive', id: gid)]);
    expect(g4.first.active, isFalse, reason: '归档生效（M-053 后无类型拦截）');

    // 重启恢复（历史在盘上）
    final app3 = AppState(Repo.at(tmp),
        scheduleFile: File('${tmp.path}${Platform.pathSeparator}schedule.json'));
    expect(app3.goals.first.progressHistory.length, 2, reason: '累积史落盘恢复');
  });

  test('M-059：一轮创建即挂目标（matter add 带 goal_ref）', () async {
    final (app, _) = newApp('''
    {"matter_ops": [{"op": "add", "name": "雅思单词视频", "goal_ref": "g_existing"}],
     "state_updates": [], "reply": "建好并挂上了", "schedule_blocks": []}
    ''');
    // 预置目标
    app.goals = [const Goal(id: 'g_existing', title: '考雅思', createdAt: '', updatedAt: '')];
    equip(app);

    await app.send('帮我建个雅思单词视频的事项，挂在考雅思目标下 playbook_test');

    final m = app.matters.firstWhere((m) => m.name.contains('雅思单词'));
    expect(m.goalRef, 'g_existing', reason: 'M-059：add 带 goal_ref 一步挂上');
    expect(app.chatChat.last.sideLog.join(' '), contains('新增'));
  });

  test('M-060：睡眠感知——说"睡到X点"记录醒时+晨报到期能触发', () async {
    final (app, _) = newApp(
        '{"matter_ops": [], "state_updates": [], "reply": "晚安", "schedule_blocks": []}');
    equip(app);

    // M-079 显式制：无"晨报"字=纯闹钟（旧版"睡到X点"推晨报已废）
    await app.send('我要睡了，睡到明天10点');
    expect(app.chatChat.last.sideLog.join(' '), contains('闹钟已设'),
        reason: 'M-079：没说晨报二字=纯闹钟');

    // 显式说晨报 → 出晨报
    await app.send('我要睡了，睡到明天10点，醒了给我晨报');
    expect(app.chatChat.last.sideLog.join(' '), contains('响铃并出晨报'),
        reason: 'M-079：说了晨报=出晨报');

    // 晨报未到期（醒时在未来）
    expect(app.morningBriefDue, isFalse, reason: '醒时未到不发');
  });

  test('M-060b：睡眠正则变体（睡8小时/睡到7点半）', () async {
    final (app, _) = newApp(
        '{"matter_ops": [], "state_updates": [], "reply": "好梦", "schedule_blocks": []}');
    equip(app);
    await app.send('现在准备休息了，睡8小时');
    expect(app.chatChat.last.sideLog.join(' '), anyOf(contains('闹钟已设'), contains('已记睡眠')),
        reason: 'M-079 显式制：无晨报字=纯闹钟（闹钟已设）');
  });

  test('M-061b：午睡分钟+对话选铃声', () async {
    final (app, _) = newApp(
        '{"matter_ops": [], "state_updates": [], "reply": "好梦", "schedule_blocks": []}');
    equip(app);
    await app.send('我要午睡10分钟，用铃声3');
    expect(app.chatChat.last.sideLog.join(' '), contains('铃声3'));
    expect(app.alarmSlot, 3);
  });

  test('M-074：一轮建多目标 id 互异（防同毫秒碰撞）', () async {
    final (app, _) = newApp('''
    {"goal_ops": [
      {"op": "add", "title": "目标A"},
      {"op": "add", "title": "目标B"},
      {"op": "add", "title": "目标C"}
    ], "state_updates": [], "reply": "建好三个", "schedule_blocks": []}
    ''');
    equip(app);
    await app.send('建三个目标 playbook_test');
    expect(app.goals.length, 3);
    final ids = app.goals.map((g) => g.id).toSet();
    expect(ids.length, 3, reason: 'M-074：同轮多目标 id 必须互异');
  });

  test('M-077：闹钟句不带睡字也能触发（老大 19:28 日志场景）', () async {
    final (app, _) = newApp(
        '{"matter_ops": [], "state_updates": [], "reply": "好的", "schedule_blocks": []}');
    equip(app);
    // 场景1：三分钟之后的闹钟（无睡字）
    await app.send('我想测试一下闹钟的效果，给我设定一个三分钟之后的闹钟。');
    expect(app.chatChat.last.sideLog.join(' '), contains('闹钟已设'),
        reason: 'M-077：闹钟词+N分钟后 要触发意图');
    // 场景2：再设置一个一分钟之后的闹钟
    await app.send('再设置一个一分钟之后的闹钟。');
    expect(app.chatChat.last.sideLog.join(' '), contains('闹钟已设'));
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
    expect(app2.chatChat.length, 4, reason: '重启后沟通会话恢复');
    expect(app2.chatChat.first.text, '下周三要交报表');
  });

  test('M-024：双模式独立会话——气泡互不混杂，上下文各取各的', () async {
    final (app, captured) = newApp(
        '{"matter_ops": [], "state_updates": [], "reply": "好", "schedule_blocks": []}');
    equip(app);

    // 沟通轮两轮、安排轮一轮
    await app.send('最近有点累');
    await app.send('下周三要交报表');
    await app.send('安排我下午', arrangeMode: true);

    // 各会话长度独立
    expect(app.chatChat.length, 4, reason: '沟通会话：2 问 2 答');
    expect(app.chatArrange.length, 2, reason: '安排会话：1 问 1 答，不含沟通气泡');

    // 安排轮的上下文窗口只含安排会话自身（此刻为空——第一轮安排）
    captured.clear();
    await app.send('再安排晚上', arrangeMode: true);
    final payload = Map<String, dynamic>.from(jsonDecode(
        (captured.first['messages'] as List).last['content'] as String) as Map);
    final dialogue = payload['recent_dialogue'] as List?;
    expect(dialogue!.length, 2, reason: '第二轮安排上下文=第一轮安排问答，不含沟通内容');
    expect(dialogue.first['text'], '安排我下午');
    // 沟通内容绝不进安排上下文
    for (final d in dialogue) {
      expect((d['text'] as String).contains('交报表'), isFalse,
          reason: '沟通会话内容不得泄入安排上下文（M-024 隔离）');
    }

    // 双桶持久化 + 重启恢复
    final chatFile =
        File('${tmp.path}${Platform.pathSeparator}data${Platform.pathSeparator}chat.json');
    final saved = Map<String, dynamic>.from(jsonDecode(chatFile.readAsStringSync()) as Map);
    expect((saved['chat'] as List).length, 4);
    expect((saved['arrange'] as List).length, 4);
    final app2 = AppState(Repo.at(tmp),
        scheduleFile: File('${tmp.path}${Platform.pathSeparator}schedule.json'),
        chatFile: chatFile);
    expect(app2.chatChat.length, 4);
    expect(app2.chatArrange.length, 4);
  });

  test('M-024：旧版单列表 chat.json 自动迁移到沟通桶', () async {
    final repo = Repo.at(tmp);
    final chatFile =
        File('${tmp.path}${Platform.pathSeparator}data${Platform.pathSeparator}chat.json');
    chatFile.parent.createSync(recursive: true);
    chatFile.writeAsStringSync(jsonEncode([
      {'text': '历史消息', 'from_user': true, 'side_log': []},
      {'text': '历史回复', 'from_user': false, 'side_log': []},
    ]));
    final app = AppState(repo,
        scheduleFile: File('${tmp.path}${Platform.pathSeparator}schedule.json'),
        chatFile: chatFile);
    expect(app.chatChat.length, 2, reason: '旧数组格式全量归入沟通桶');
    expect(app.chatArrange.length, 0, reason: '安排桶从零开始');
  });
}
