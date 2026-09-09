// M-063 铃声播放器：App 内直接响（绕过通知渠道声音的种种限制）
// 到点触发时是我们的代码在跑——播放器放铃声 + 全屏通知弹窗（视觉）双管齐下。
// 循环响直到停止（真闹钟体验）+ 震动（播放器自带 setReleaseMode loop + 震动插件系统级）。

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:vibration/vibration.dart';

class AlarmPlayer {
  static final AudioPlayer _player = AudioPlayer(playerId: 'alarm');
  static bool _ringing = false;
  static bool get ringing => _ringing;

  /// 响铃：循环播放槽位铃声直到 stopAlarm()。
  /// [soundPath] null 时用短促默认音（连续 3 声的原始提示音资源不可用——
  /// 用系统通知提示音兜底由调用方处理；这里静默震动）。
  static Future<void> start(String? soundPath) async {
    if (_ringing) return;
    _ringing = true;
    try {
      // 震动循环（有震动器的设备）
      final hasVib = await Vibration.hasVibrator();
      if (hasVib == true) {
        Vibration.vibrate(pattern: [800, 400], repeat: 1);
      }
      if (soundPath != null) {
        await _player.setReleaseMode(ReleaseMode.loop);
        await _player.setVolume(1.0);
        await _player.play(DeviceFileSource(soundPath));
      }
    } catch (e) {
      debugPrint('响铃失败：$e');
    }
  }

  /// 停止（用户点开 App 或点通知时由 main 层调用）
  static Future<void> stop() async {
    _ringing = false;
    try {
      await _player.stop();
      await _player.release();
      Vibration.cancel();
    } catch (_) {}
  }
}
