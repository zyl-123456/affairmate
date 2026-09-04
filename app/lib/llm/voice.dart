// 语音输入 · 事务伴侣
// 对应设计：D-005（TECH-006 / REQ-002 / REQ-009）
// ASM-003：首选 Android 原生 SpeechRecognizer（speech_to_text 封装）。
// 微信式交互：按住说话、松开自动转写发送；不可用/失败优雅降级纯文字。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 语音会话状态
enum VoiceState { idle, initializing, listening, finalizing, unavailable }

/// 语音输入控制器：单例语义（一个会话一个麦克风）
class VoiceInput extends ChangeNotifier {
  final _stt = SpeechToText();

  VoiceState state = VoiceState.idle;
  String partialText = ''; // 实时中间结果
  String lastError = '';

  bool get isListening => state == VoiceState.listening;

  /// 按下：初始化（首次）并开始监听
  Future<void> start() async {
    lastError = '';
    // Windows 无 speech_to_text 实现（方法通道无人应答，initialize 永挂）——直接降级（M-020）
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      _markUnavailable('Windows 预览版暂不支持语音，请用文字输入（安卓端完整支持）');
      return;
    }
    try {
      if (!_stt.isAvailable) {
        state = VoiceState.initializing;
        notifyListeners();
        final ok = await _stt.initialize(
          onError: _onError,
          finalTimeout: const Duration(milliseconds: 1500),
        ).timeout(const Duration(seconds: 8), onTimeout: () => false);
        if (!ok) {
          _markUnavailable('语音服务不可用');
          return;
        }
      }
      partialText = '';
      state = VoiceState.listening;
      notifyListeners();
      _stt.listen(
        onResult: (r) {
          partialText = r.recognizedWords;
          notifyListeners();
        },
        listenOptions: SpeechListenOptions(
          localeId: 'zh_CN',
          partialResults: true,
          cancelOnError: true,
          autoPunctuation: true,
        ),
      );
    } catch (e) {
      _markUnavailable('语音初始化失败：$e');
    }
  }

  /// 松开：停止并返回转写文本（可能为空=当没说）
  Future<String> stop() async {
    if (state != VoiceState.listening) return '';
    state = VoiceState.finalizing;
    notifyListeners();
    try {
      await _stt.stop();
    } catch (_) {}
    final text = partialText.trim();
    state = VoiceState.idle;
    partialText = '';
    notifyListeners();
    return text;
  }

  /// 取消（如移出按钮区域）
  Future<void> cancel() async {
    try {
      if (_stt.isListening) await _stt.cancel();
    } catch (_) {}
    state = VoiceState.idle;
    partialText = '';
    notifyListeners();
  }

  void _onError(SpeechRecognitionError e) {
    // 权限拒绝/无语音输入等：安静降级，不打断聊天
    lastError = e.errorMsg;
    state = VoiceState.idle;
    partialText = '';
    notifyListeners();
  }

  void _markUnavailable(String why) {
    lastError = why;
    state = VoiceState.unavailable;
    notifyListeners();
  }
}
