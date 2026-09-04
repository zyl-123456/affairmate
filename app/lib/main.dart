// 主入口与双模式界面 · 事务伴侣
// 对应设计：D-006（双模式切换即两个页面，共享同一会话状态）

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_state_scope.dart';
import 'data/repo.dart';
import 'llm/voice.dart';
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

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  final _input = TextEditingController();
  final _voice = VoiceInput();
  final _chatScroll = ScrollController();
  int _lastChatLen = 0; // 用于侦测新消息滚底（M-012）

  @override
  void initState() {
    super.initState();
    _voice.addListener(() => setState(() {})); // 语音状态变化刷新输入区
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
  void dispose() {
    _input.dispose();
    _voice.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = InheritedAppState.of(context);
    final tabs = [
      ('沟通', Icons.chat_bubble_outline),
      ('安排', Icons.event_note_outlined),
      ('展示', Icons.view_timeline_outlined),
    ];

    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final chatLen = app.chat.length;
        if (chatLen != _lastChatLen) {
          _lastChatLen = chatLen;
          _scrollChatToBottom(app); // 新消息（含 AI 回复）自动滚底
        }
        return Scaffold(
          appBar: AppBar(
            title: Text('事务伴侣 · ${tabs[_tab].$1}模式'),
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
          body: _tab == 2
              ? TimelinePage(app: app)
              : _buildChat(app, arrangeMode: _tab == 1),
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
    return Column(
      children: [
        Expanded(
          child: app.chat.isEmpty
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
                  itemCount: app.chat.length,
                  itemBuilder: (_, i) => _bubble(context, app.chat[i]),
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
    if (_voice.state == VoiceState.listening) {
      return _voice.partialText.isEmpty ? '在听…说话吧' : _voice.partialText;
    }
    if (_voice.state == VoiceState.unavailable) return arrangeMode ? '想怎么安排？（语音不可用）' : '说点什么…（语音不可用）';
    return arrangeMode ? '想怎么安排？' : '说点什么…';
  }

  Widget _micButton(AppState app, bool arrangeMode) {
    final listening = _voice.isListening;
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onLongPressStart: (_) => _voice.start(),
      onLongPressEnd: (_) async {
        final text = await _voice.stop();
        if (text.isNotEmpty && !app.sending) {
          app.send(text, arrangeMode: arrangeMode);
        }
      },
      onLongPressCancel: () => _voice.cancel(),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: listening ? scheme.errorContainer : scheme.surfaceContainerHighest,
        ),
        child: Icon(
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
