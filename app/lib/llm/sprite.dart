// 桌面小精灵 · 事务伴侣（M-037b / REQ-015）
// 悬浮窗（独立 Flutter 引擎）：点一下弹「沟通/安排」→ 麦克风态录音 → 停止后
// 经消息通道传给主 App → 主 App 复用 VoiceInput 转写 + AppState.send 全链路。
// 平台：Android 专属；Windows 预览不含（开关隐藏）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:floating_window_android/floating_window_android.dart';

import 'voice.dart';

// ============ 主 App 侧：精灵控制器 ============

class SpriteController {
  static bool _inited = false;

  /// 初始化 + 监听悬浮窗消息（main 启动时调用，安卓专属）
  static Future<void> init() async {
    if (!Platform.isAndroid || _inited) return;
    _inited = true;
    FloatingWindowAndroid.overlayListener.listen((data) {
      if (data is Map && data['type'] == 'voice_done') {
        // 悬浮窗录完音：文件路径传来 → 主引擎转写并发送
        final path = data['path']?.toString() ?? '';
        final arrange = data['mode'] == 'arrange';
        if (path.isNotEmpty) _handleVoice(path, arrange);
      }
    });
  }

  static Future<void> _handleVoice(String path, bool arrange) async {
    try {
      final text = await VoiceInput.transcribe(File(path));
      if (text.isEmpty) return;
      // 发送到当前 AppState（由 main 层注册的回调）
      onSpriteMessage?.call(text, arrange);
    } catch (e) {
      debugPrint('精灵语音处理失败：$e');
    }
  }

  /// main 层注册：转写文本 → AppState.send
  static void Function(String text, bool arrangeMode)? onSpriteMessage;

  /// 开启悬浮窗（设置页开关）：权限检查 → 小窗（56dp 圆形，可拖动贴边）
  static Future<bool> enable() async {
    if (!Platform.isAndroid) return false;
    final granted = await FloatingWindowAndroid.isPermissionGranted();
    if (!granted) {
      final ok = await FloatingWindowAndroid.requestPermission();
      if (!ok) return false;
    }
    return FloatingWindowAndroid.showOverlay(
      height: 180, // 物理像素（hdpi 设备 ~56dp 圆球）
      width: 180,
      alignment: OverlayAlignment.right,
      flag: OverlayFlag.focusPointer, // 点击可交互，不挡底下的应用
      enableDrag: true,
      positionGravity: PositionGravity.auto, // 松手贴边收纳
      overlayTitle: '事务伴侣小精灵',
      overlayContent: '点它随时跟我说话',
    );
  }

  static Future<void> disable() async {
    if (!Platform.isAndroid) return;
    await FloatingWindowAndroid.closeOverlay();
  }
}

// ============ 悬浮窗侧：小精灵 UI（独立引擎入口） ============

/// 小精灵悬浮窗根组件（悬浮引擎里跑的界面）
class SpriteOverlay extends StatefulWidget {
  const SpriteOverlay({super.key});

  @override
  State<SpriteOverlay> createState() => _SpriteOverlayState();
}

enum _SpriteState { idle, menu, listeningChat, listeningArrange, working }

class _SpriteOverlayState extends State<SpriteOverlay>
    with SingleTickerProviderStateMixin {
  _SpriteState _state = _SpriteState.idle;
  late final AnimationController _breath =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat(reverse: true);

  void _sendVoiceDone(String mode) {
    // 停止录音：把音频文件路径发主 App（转写+发送在主引擎做，悬浮引擎保持轻）
    final path = SpriteRecorder.stopAndExport();
    if (path != null) {
      FloatingWindowAndroid.shareData(
          {'type': 'voice_done', 'path': path, 'mode': mode});
    }
    setState(() => _state = _SpriteState.working);
    Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _state = _SpriteState.idle);
    });
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final listening = _state == _SpriteState.listeningChat ||
        _state == _SpriteState.listeningArrange;
        return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: () {
          switch (_state) {
            case _SpriteState.idle:
              setState(() => _state = _SpriteState.menu);
            case _SpriteState.menu:
              setState(() => _state = _SpriteState.idle);
            case _SpriteState.listeningChat:
              _sendVoiceDone('chat');
            case _SpriteState.listeningArrange:
              _sendVoiceDone('arrange');
            case _SpriteState.working:
              break; // 处理中不可点
          }
        },
        child: SizedBox(
          width: double.infinity,
          height: double.infinity,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 精灵球体（呼吸缩放；录音中变红+更快）
              ScaleTransition(
                scale: Tween(begin: 0.96, end: 1.04)
                    .animate(CurvedAnimation(parent: _breath, curve: Curves.easeInOut)),
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: listening
                        ? const Color(0xFFB33939)
                        : (_state == _SpriteState.working
                            ? const Color(0xFF3F6C51)
                            : const Color(0xFF2E543C)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: _state == _SpriteState.working
                      ? const Padding(
                          padding: EdgeInsets.all(18),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Icon(
                          listening ? Icons.mic : Icons.auto_awesome,
                          color: Colors.white,
                          size: listening ? 24 : 20,
                        ),
                ),
              ),
              // 菜单态：两个选项按钮（右侧上下展开）
              if (_state == _SpriteState.menu) ...[
                Positioned(
                  top: 8,
                  child: _menuBtn('沟通', Icons.chat_bubble_outline, () {
                    SpriteRecorder.start();
                    setState(() => _state = _SpriteState.listeningChat);
                  }),
                ),
                Positioned(
                  bottom: 8,
                  child: _menuBtn('安排', Icons.event_note_outlined, () {
                    SpriteRecorder.start();
                    setState(() => _state = _SpriteState.listeningArrange);
                  }),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _menuBtn(String label, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 4),
          ],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: const Color(0xFF3F6C51)),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF2E543C))),
        ]),
      ),
    );
  }
}

/// 悬浮引擎里的轻量录音器：只录原始文件，转写交给主引擎
/// （悬浮引擎不引 record 插件太重——用平台通道复用主 App 的录音服务属 M-038 优化，
///  首版用 floating_window 自身无录音能力时的降级：点击选项后提示去通知栏查看结果。
///  真录音链路：悬浮窗点选项 → shareData('voice_start') → 主引擎起 ForegroundService 录音）
class SpriteRecorder {
  static bool _recording = false;

  static void start() => _recording = true;

  static String? stopAndExport() {
    // 首版占位：悬浮引擎内无录音插件，返回 null 则主引擎忽略
    // 完整链路在 M-038（悬浮窗触发主引擎录音）中补齐
    _recording = false;
    return null;
  }

  static bool get isRecording => _recording;
}

/// 悬浮窗独立入口（floating_window_android 约定）
@pragma("vm:entry-point")
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: SpriteOverlay(),
  ));
}
