// 通知服务 · 事务伴侣（M-037a / REQ-015）
// App 在后台收到 AI 回复 → 系统通知栏呈现（沟通=摘要；安排=时间块列表）；
// 点通知 → 拉起 App 跳对应会话页（payload 带 mode）。
// 平台：Android 为主；Windows 下静默跳过（通知非本轮范围）。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

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

  // ============ M-060 晨报定时通知 ============

  /// 时区初始化（zonedSchedule 需要；main 启动时与 init 一并调用）
  static void _initTz() {
    try {
      tzdata.initializeTimeZones();
      // 国内用户为主——不做系统时区探测的复杂化，直接 Asia/Shanghai
      tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
    } catch (_) {}
  }

  /// 定点通知：醒时弹"晨报就绪"（M-060 睡眠感知）
  static Future<void> scheduleMorningBrief(DateTime wakeAt) async {
    if (!_inited || !_enabled) return;
    _initTz();
    final when = tz.TZDateTime.from(wakeAt, tz.local);
    if (!when.isAfter(tz.TZDateTime.now(tz.local))) return; // 已过时不排
    final androidDetails = AndroidNotificationDetails(
      'morning_channel',
      '晨报',
      channelDescription: '醒来时的今日规划提醒',
      importance: Importance.high,
      priority: Priority.high,
    );
    try {
      await _plugin.zonedSchedule(
        3, // 晨报专用 id
        '早上好',
        '今日规划已就绪——点开看看这一天的安排',
        when,
        NotificationDetails(android: androidDetails),
        payload: 'arrange',
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      debugPrint('晨报定时失败（不影响主功能）：$e');
    }
  }

  /// 取消晨报定时（改睡眠时间时先撤旧的）
  /// M-093：通知权限检查（第三防线——App 被杀时系统通知是唯一兜底）
  static Future<bool> notificationsEnabled() async {
    try {
      return await _plugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission() ??
          true; // 非 Android 平台视为已开
    } catch (_) {
      return true;
    }
  }

  /// M-093：请求通知权限（弹系统对话框）
  static Future<void> requestNotifyPermission() async {
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {}
  }

  static Future<void> cancelMorningBrief() async {
    try {
      await _plugin.cancel(3);
    } catch (_) {}
  }

  // ============ M-061 闹钟级唤醒（自定义铃声+全屏+震动）============

  /// 立即弹闹钟通知（到点时由 App 内触发——配合铃声文件槽位）
  /// [soundPath] 传 null 用系统默认提示音；传文件路径用自定义铃声。
  static Future<void> showAlarm({
    required String title,
    required String body,
    String? soundPath,
  }) async {
    if (!_inited) return;
    final sound = (soundPath != null)
        ? UriAndroidNotificationSound(soundPath)
        : null;
    final androidDetails = AndroidNotificationDetails(
      'alarm_channel',
      '闹钟',
      channelDescription: '睡醒闹钟（自定义铃声）',
      importance: Importance.max,
      priority: Priority.max,
      sound: sound,
      enableVibration: true,
      vibrationPattern: Int64List.fromList(
          [0, 800, 400, 800, 400, 800]), // 三段震动（叫醒加成）
      fullScreenIntent: true, // 息屏直接亮屏弹出（锁屏可见）
      category: AndroidNotificationCategory.alarm,
      timeoutAfter: const Duration(minutes: 2).inMilliseconds, // 2 分钟没理自动停
    );
    try {
      await _plugin.show(
        4, // 闹钟专用 id
        title,
        body,
        NotificationDetails(android: androidDetails),
        payload: 'chat',
      );
    } catch (e) {
      debugPrint('闹钟通知失败：$e');
    }
  }

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