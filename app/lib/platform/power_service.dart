// M-070 电池优化豁免（Doze 网络限制的正解）：
// 黑屏后系统 Doze 掐网（Failed host lookup 是标志）——wakelock 挡不住主动黑屏后的深度休眠。
// 进电池优化白名单的 App 不受 Doze 网络限制（微信后台收消息同款待遇）。
// 流程：首次启动检测→引导用户点"允许"→记偏好不再烦。

import 'package:flutter/services.dart';

class PowerService {
  static const _ch = MethodChannel('affairmate/power');

  /// 是否已在白名单
  static Future<bool> isExempted() async {
    try {
      return await _ch.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
    } catch (_) {
      return true; // 平台不支持（Windows/测试）视为已豁免，不弹引导
    }
  }

  /// 弹系统对话框申请白名单
  static Future<void> requestExempt() async {
    try {
      await _ch.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }
}
