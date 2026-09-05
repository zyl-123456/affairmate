// 通知服务 · 事务伴侣（M-037a / REQ-015）
// App 在后台收到 AI 回复 → 系统通知栏呈现（沟通=摘要；安排=时间块列表）；
// 点通知 → 拉起 App 跳对应会话页（payload 带 mode）。
// 平台：Android 为主；Windows 下静默跳过（通知非本轮范围）。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotifyService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;
  static bool _enabled = true; // 设置开关（M-037b 挂到设置页）

  /// 初始化（main 启动时调用一次；Android 13+ 请求权限）
  static Future<void> init() async {
    if (!Platform.isAndroid && !Platform.isIOS) return; // Windows 桌面静默跳过
    if (_inited) return;
    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const init = InitializationSettings(android: androidInit);
      await _plugin.initialize(
        init,
        onDidReceiveNotificationResponse: _onTap,
      );
      // Android 13+ 运行时通知权限
      final impl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await impl?.requestNotificationsPermission();
      _inited = true;
    } catch (e) {
      debugPrint('通知初始化失败（不影响主功能）：$e');
    }
  }

  /// 点通知回调：payload 是 'chat' / 'arrange'——由 main 层导航消费
  static void Function(String mode)? onTapNavigate;

  static void _onTap(NotificationResponse resp) {
    final mode = resp.payload ?? 'chat';
    onTapNavigate?.call(mode == 'arrange' ? 'arrange' : 'chat');
  }

  /// App 生命周期可见性（由 main 层 WidgetsBindingObserver 更新）
  static bool appInBackground = false;

  /// 收到 AI 回复时调用：后台才弹通知（前台用户正看着界面，不打扰）
  static Future<void> showReply({
    required bool arrangeMode,
    required String replyText,
    List<String> blockLines = const [],
  }) async {
    if (!_inited || !_enabled || !appInBackground) return;
    final title = arrangeMode
        ? (blockLines.isEmpty ? '安排好了' : '安排好了 · ${blockLines.length} 个时段')
        : '事务伴侣回复';
    final body = arrangeMode && blockLines.isNotEmpty
        ? blockLines.take(4).join('\n') // 通知栏最多 4 行，多的进 App 看
        : (replyText.length > 60 ? '${replyText.substring(0, 60)}…' : replyText);

    final androidDetails = AndroidNotificationDetails(
      'reply_channel',
      'AI 回复',
      channelDescription: '后台收到的 AI 回复与安排结果',
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: BigTextStyleInformation(body), // 多行安排完整可读
    );
    final details = NotificationDetails(android: androidDetails);

    try {
      await _plugin.show(
        arrangeMode ? 2 : 1,
        title,
        body,
        details,
        payload: arrangeMode ? 'arrange' : 'chat',
      );
    } catch (e) {
      debugPrint('通知发送失败（不影响主功能）：$e');
    }
  }
}