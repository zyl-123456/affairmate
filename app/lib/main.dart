// 主入口与双模式界面 · 事务伴侣
// 对应设计：D-006（双模式切换即两个页面，共享同一会话状态）

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_state_scope.dart';
import 'data/repo.dart';
import 'llm/notify.dart';
import 'llm/sprite.dart';
import 'llm/voice.dart';
import 'pages/playbook_page.dart';
import 'pages/timeline_page.dart';
import 'pages/settings_page.dart';
import 'state.dart';

void main() {
  runApp(const ShiwuApp());
}

class ShiwuApp extends StatelessWidget {
  const ShiwuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '事务伴侣',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3F6C51)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3F6C51),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const BootPage(),
    );
  }
}

/// 启动页：初始化 Repo + AppState
class BootPage extends StatefulWidget {
  const BootPage({super.key});

  @override
  State<BootPage> createState() => _BootPageState();
}

class _BootPageState extends State<BootPage> {
  late Future<AppState> _init;

  @override
  void initState() {
    super.initState();
    _init = _boot();
  }

  Future<AppState> _boot() async {
    final dir = await getApplicationSupportDirectory();
    final repo = Repo.at(dir);
    final app = AppState(repo);
    await app.loadProviders();
    return app;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppState>(
      future: _init,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return InheritedAppState(
          app: snap.data!,
          child: const HomePage(),
        );
      },
    );
  }
}

/// 主页：底部导航三页——沟通 / 安排 / 展示
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _tab = 0;
  final _input = TextEditingController();
  final _voice = VoiceInput();
  final _chatScroll = ScrollController();
  int _lastChatLen = 0; // 用于侦测新消息滚底（M-012）

  // M-035 补账提醒：侦测今天已过时段的时间空洞，超阈值弹页顶提醒条。
  // 节流口径：同一"洞结束时刻"只提醒一次（用户补录/调整后自然消停）。
  Timer? _gapTimer;
  int? _lastNudgedGapEnd;
  bool _gapNudgeShown = false;

  // M-036 复盘横幅：到周期+数据够 → 问一次；拒绝后 7 天内不再问
  bool _reviewBannerShown = false;
  DateTime? _reviewDeclinedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // M-037a 前后台侦测
    NotifyService.init(); // 通知初始化（安卓）
    NotifyService.onTapNavigate = (mode) {
      // 点通知跳对应会话页（App 可能冷启动，navigate 回调在 build 后消费）
      if (!mounted) return;
      setState(() => _tab = mode == 'arrange' ? 1 : 0);
    };
    // M-037b：精灵初始化 + 转写文本 → 复用完整发送链路
    SpriteController.init();
    SpriteController.onSpriteMessage = (text, arrange) {
      final app = InheritedAppState.maybeOf(context);
      app?.send(text, arrangeMode: arrange);
    };
    _voice.addListener(() => setState(() {})); // 语音状态变化刷新输入区
    _gapTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (!mounted) return;
      final app = InheritedAppState.maybeOf(context);
      if (app == null) return;
      _checkGaps(app);
    });
    // M-036：启动即查复盘点（老大 00:09 裁决：复盘汇报要弹通知=横幅提示）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final app = InheritedAppState.maybeOf(context);
      if (app == null || !app.dueForReview) return;
      final declinedRecently = _reviewDeclinedAt != null &&
          DateTime.now().difference(_reviewDeclinedAt!).inDays < 7;
      if (!declinedRecently) setState(() => _reviewBannerShown = true);
    });
  }

  void _checkGaps(AppState app) {
    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;
    // 8 点起床口径到当前时间，未覆盖 ≥45 分钟才提醒（避免碎片误扰）
    final gaps = AppState.uncoveredGaps(app.schedule,
        fromMinute: 8 * 60, toMinute: nowMin, minMinutes: 45);
    if (gaps.isEmpty) {
      if (_gapNudgeShown) setState(() => _gapNudgeShown = false);
      return;
    }
    final gapEnd = gaps.last.$2;
    if (gapEnd == _lastNudgedGapEnd) return; // 这个洞已提醒过
    _lastNudgedGapEnd = gapEnd;
    setState(() => _gapNudgeShown = true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gapTimer?.cancel();
    _input.dispose();
    _voice.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // M-037a：后台标记——后台收到的回复才弹系统通知（前台不打扰）
    NotifyService.appInBackground =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
  }

  /// 聊天有新消息时滚到底部（M-012：回复不再跑到屏幕外）
  void _scrollChatToBottom(AppState app) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chatScroll.hasClients) return;
      _chatScroll.animateTo(
        _chatScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = InheritedAppState.of(context);
    final scheme = Theme.of(context).colorScheme; // M-035 提醒条配色
    final tabs = [
      ('沟通', Icons.chat_bubble_outline),
      ('安排', Icons.event_note_outlined),
      ('展示', Icons.view_timeline_outlined),
      ('懂我', Icons.auto_stories_outlined), // M-032 个人说明书页（REQ-014）
    ];

    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        // 双模式独立会话（M-024）：当前模式的会话才参与滚底侦测与渲染
        final session = _tab == 1 ? app.chatArrange : app.chatChat;
        final chatLen = session.length;
        if (chatLen != _lastChatLen) {
          _lastChatLen = chatLen;
          _scrollChatToBottom(app); // 新消息（含 AI 回复）自动滚底
        }
        final isChatTab = _tab == 0 || _tab == 1;
        return Scaffold(
          appBar: AppBar(
            title: Text(isChatTab ? '事务伴侣 · ${tabs[_tab].$1}模式' : '事务伴侣 · ${tabs[_tab].$1}'),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: '模型供应商设置',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => SettingsPage(app: app)),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              // M-036 复盘邀请横幅：到周期+数据够时置顶询问（花 token 须老大点头）
              if (_reviewBannerShown)
                Material(
                  color: scheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Row(children: [
                      Icon(Icons.auto_awesome, size: 16, color: scheme.onPrimaryContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '用了一阵子啦——要让我复盘一下最近的你吗？我会翻翻这阵子的状态和日程，更新「懂我」说明书。',
                          style: TextStyle(fontSize: 12, color: scheme.onPrimaryContainer, height: 1.3),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          setState(() => _reviewBannerShown = false);
                          await app.runReview();
                        },
                        child: const Text('现在复盘', style: TextStyle(fontSize: 12)),
                      ),
                      TextButton(
                        onPressed: () => setState(() {
                          _reviewBannerShown = false;
                          _reviewDeclinedAt = DateTime.now(); // 7 天后再问
                        }),
                        child: const Text('先不用', style: TextStyle(fontSize: 12)),
                      ),
                    ]),
                  ),
                ),
              // M-035 补账提醒条：今天有大段未记录时间时置顶提示
              if (_gapNudgeShown)
                Material(
                  color: scheme.errorContainer,
                  child: InkWell(
                    onTap: () => setState(() => _gapNudgeShown = false), // 点掉稍后再说
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Row(children: [
                        Icon(Icons.notifications_active_outlined,
                            size: 16, color: scheme.onError),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '有段时间还没记录哦——刚才在忙什么？去沟通页告诉它，哪怕是在休息。',
                            style: TextStyle(fontSize: 12, color: scheme.onError, height: 1.3),
                          ),
                        ),
                        Icon(Icons.close, size: 14, color: scheme.onError),
                      ]),
                    ),
                  ),
                ),
              Expanded(
                child: switch (_tab) {
                  2 => TimelinePage(app: app),
                  3 => const PlaybookPage(), // M-032 懂我页
                  _ => _buildChat(app, arrangeMode: _tab == 1),
                },
              ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              for (final (label, icon) in tabs)
                NavigationDestination(icon: Icon(icon), label: label),
            ],
          ),
        );
      },
    );
  }

  Widget _buildChat(AppState app, {required bool arrangeMode}) {
    final session = arrangeMode ? app.chatArrange : app.chatChat;
    return Column(
      children: [
        Expanded(
          child: session.isEmpty
              ? Center(
                  child: Text(
                    arrangeMode
                        ? '说说你想要什么安排，例如：\n"安排我接下来两小时"\n"明天上午怎么安排"'
                        : '随便聊聊你今天的事和状态，例如：\n"下周三要交报表"\n"昨晚没睡好，有点累"',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade500, height: 1.8),
                  ),
                )
              : ListView.builder(
                  controller: _chatScroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: session.length,
                  itemBuilder: (_, i) => _bubble(context, session[i]),
                ),
        ),
        if (app.sending)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8),
                Text('思考中…',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: !app.sending,
                    onSubmitted: (_) => _send(app, arrangeMode),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22)),
                      hintText: _voiceHint(arrangeMode),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _micButton(app, arrangeMode),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: app.sending ? null : () => _send(app, arrangeMode),
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _send(AppState app, bool arrangeMode) {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _scrollChatToBottom(app);
    app.send(text, arrangeMode: arrangeMode);
  }

  // ============ 语音输入（D-005：按住说话，松开自动发送）============

  String _voiceHint(bool arrangeMode) {
    if (_voice.state == VoiceState.listening) return '在听…再点一下麦克风结束';
    if (_voice.state == VoiceState.finalizing) return '转写中…（云端识别）';
    if (_voice.state == VoiceState.unavailable) {
      return _voice.lastError.isEmpty
          ? (arrangeMode ? '想怎么安排？（语音不可用）' : '说点什么…（语音不可用）')
          : _voice.lastError; // 具体失败原因直接亮给用户（M-026：不静默吞）
    }
    return arrangeMode ? '想怎么安排？' : '说点什么…';
  }

  Widget _micButton(AppState app, bool arrangeMode) {
    // M-030 点击式语音（老大 2026-09-05）：点一下开始，再点一下停止发送——
    // 替代长按式（手指一直摁着累）。录音中图标变实心+红底，一眼可辨状态。
    final listening = _voice.isListening;
    final finalizing = _voice.state == VoiceState.finalizing;
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: finalizing
          ? null // 转写中不可重复触发
          : () async {
              if (listening) {
                final text = await _voice.stop();
                if (text.isNotEmpty && !app.sending) {
                  app.send(text, arrangeMode: arrangeMode);
                }
              } else {
                await _voice.start();
              }
            },
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: listening
              ? scheme.errorContainer
              : scheme.surfaceContainerHighest,
        ),
        child: finalizing
            ? const Padding(
                padding: EdgeInsets.all(14),
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                listening ? Icons.mic : Icons.mic_none,
                color: listening ? scheme.onError : scheme.onSurfaceVariant,
                size: 22,
              ),
      ),
    );
  }

  Widget _bubble(BuildContext context, ChatMsg m) {
    final isUser = m.fromUser;
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? scheme.primary
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              m.text,
              style: TextStyle(
                color: isUser ? Colors.white : scheme.onSurface,
                height: 1.4,
              ),
            ),
            if (m.sideLog.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in m.sideLog)
                      Text(
                        '· $line',
                        style: TextStyle(
                          fontSize: 11,
                          color: isUser ? Colors.white70 : scheme.primary,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
