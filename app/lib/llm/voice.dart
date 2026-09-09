// 语音输入 · 事务伴侣（M-026 云端方案）
// 对应设计：D-005（TECH-006 / REQ-002 / REQ-009）；M-026 重构：本地系统识别 → record 录原始音频 + GLM-ASR 云端转写。
// 动因（M-025 实测结论）：speech_to_text 依赖设备 Google 系语音服务——模拟器收不到宿主麦克风、
// 无 GMS 国产机型（小米/华为等）服务缺失；云端 ASR 与模型同厂（智谱 glm-asr-2512），同 Key 体系，全平台可用。
// 交互不变：微信式按住说话、松开自动发送；转写失败优雅降级纯文字输入。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';

import 'providers.dart';

/// 语音会话状态
enum VoiceState { idle, listening, finalizing, unavailable }

/// 云端语音输入控制器：录音（record 包）→ GLM-ASR 转写 → 返回文字
class VoiceInput extends ChangeNotifier {
  final AudioRecorder _rec = AudioRecorder();
  File? _tmpFile;

  VoiceState state = VoiceState.idle;
  String partialText = ''; // 云端方案为整段转写，无实时中间结果（预留字段兼容 UI）
  String lastError = '';

  bool get isListening => state == VoiceState.listening;

  /// 按下：请求权限并开始录音（WAV 单声道，GLM-ASR 规格）
  Future<void> start() async {
    lastError = '';
    try {
      if (!await _rec.hasPermission()) {
        _markUnavailable('麦克风权限被拒绝，请到系统设置开启');
        return;
      }
      final dir = Directory.systemTemp;
      _tmpFile = File(
          '${dir.path}${Platform.pathSeparator}voice_${DateTime.now().millisecondsSinceEpoch}.wav');
      state = VoiceState.listening;
      notifyListeners();
      // M-026c：WAV + 单声道——两个实测坑的合解：
      // ①GLM-ASR 仅支持 wav/mp3（m4a 报 1214 不支持当前文件格式）
      // ②GLM-ASR 要求单声道（麦克风阵列默认双声道报 1214 只支持单声道）
      // ③采样率/位深不钉死（写死采样率在部分设备链报 0xC00D36B4 媒体类型无效）
      await _rec.start(
        const RecordConfig(encoder: AudioEncoder.wav, numChannels: 1),
        path: _tmpFile!.path,
      );
    } catch (e) {
      _markUnavailable('录音启动失败：$e');
    }
  }

  /// 松开：停止录音 → 云端转写 → 返回文字（空串=当没说/失败，失败原因在 lastError）
  Future<String> stop() async {
    if (state != VoiceState.listening) return '';
    state = VoiceState.finalizing;
    notifyListeners();
    try {
      await _rec.stop();
    } catch (_) {}
    final f = _tmpFile;
    _tmpFile = null;
    if (f == null || !f.existsSync() || f.lengthSync() < 1000) {
      // 过短（<1KB）视为误触，静默忽略
      state = VoiceState.idle;
      partialText = '';
      notifyListeners();
      try { if (f != null && f.existsSync()) f.deleteSync(); } catch (_) {}
      return '';
    }
    try {
      final text = await transcribe(f);
      state = VoiceState.idle;
      partialText = '';
      notifyListeners();
      return text;
    } catch (e) {
      _markUnavailable('语音转写失败：$e'); // 不静默吞，用户可改打字
      return '';
    } finally {
      try { if (f.existsSync()) f.deleteSync(); } catch (_) {}
    }
  }

  /// 取消（如移出按钮区域）
  Future<void> cancel() async {
    try {
      if (await _rec.isRecording()) await _rec.cancel();
    } catch (_) {}
    final f = _tmpFile;
    _tmpFile = null;
    try { if (f != null && f.existsSync()) f.deleteSync(); } catch (_) {}
    state = VoiceState.idle;
    partialText = '';
    notifyListeners();
  }

  // ============ GLM-ASR 云端转写（M-026 实测：Coding/常规两通道均 200）============

  /// 用当前激活供应商的 Key 调 GLM-ASR。端点跟随供应商配置：
  /// Coding Plan 供应商 → coding 通道；其余 → 常规通道。
  /// M-045 UI-03：云端限单条 ≤30s——超 25s 自动按 WAV 帧切段逐段转写拼接（用户无感）。
  static Future<String> transcribe(File audio) async {
    final seg = await _splitWavIfLong(audio, const Duration(seconds: 25));
    if (seg == null) return _transcribeOnce(audio);
    // 多段：逐段转写，空格拼接；单段失败不拖垮整体（跳过该段）
    final parts = <String>[];
    for (final f in seg) {
      try {
        final t = await _transcribeOnce(f);
        if (t.trim().isNotEmpty) parts.add(t.trim());
      } catch (_) {/* 单段失败跳过 */}
      try { if (f != audio && f.existsSync()) f.deleteSync(); } catch (_) {}
    }
    return parts.join('');
  }

  /// WAV 时长超 max → 按字节切段（WAV=PCM 等长帧，字节切=时间切）；
  /// 返回 null 表示不用切。非 WAV（理论上不会）返回 null 走单次。
  static Future<List<File>?> _splitWavIfLong(File audio, Duration max) async {
    try {
      final bytes = await audio.readAsBytes();
      if (bytes.length < 100) return null;
      // WAV 头: RIFF....WAVEfmt (28 字节内含采样率/位深/声道)
      if (!(bytes.length > 44 &&
          bytes[0] == 0x52 && bytes[1] == 0x49)) return null; // 非 RIFF
      final byteRate = bytes[28] |
          (bytes[29] << 8) |
          (bytes[30] << 16) |
          (bytes[31] << 24); // bytes/秒
      if (byteRate <= 0) return null;
      final dataLen = bytes.length - 44;
      final durSec = dataLen / byteRate;
      if (durSec <= max.inSeconds) return null;
      // 切：每段 max 秒的 PCM + 原 44 字节头
      final segBytes = byteRate * max.inSeconds;
      final header = bytes.sublist(0, 44);
      final files = <File>[];
      var pos = 44;
      var i = 0;
      while (pos < bytes.length) {
        final end = (pos + segBytes > bytes.length) ? bytes.length : pos + segBytes;
        final seg = List<int>.from(header)..addAll(bytes.sublist(pos, end));
        final f = File('${audio.path}.seg$i');
        await f.writeAsBytes(seg, flush: true);
        files.add(f);
        pos = end;
        i++;
      }
      return files;
    } catch (_) {
      return null; // 切割失败走单次（宁可被云端拒也不本地崩）
    }
  }

  static Future<String> _transcribeOnce(File audio) async {
    final cfg = await ProviderStore.activeProvider();
    if (cfg == null || cfg.apiKey.isEmpty) {
      throw Exception('尚未配置模型供应商');
    }
    final base = cfg.baseUrl.contains('/coding/')
        ? 'https://open.bigmodel.cn/api/coding/paas/v4'
        : 'https://open.bigmodel.cn/api/paas/v4';
    final req = http.MultipartRequest('POST', Uri.parse('$base/audio/transcriptions'))
      ..headers['Authorization'] = 'Bearer ${cfg.apiKey}'
      ..fields['model'] = 'glm-asr-2512'
      ..fields['stream'] = 'false'
      ..files.add(await http.MultipartFile.fromPath('file', audio.path));
    final resp = await req.send().timeout(const Duration(seconds: 60));
    final body = await resp.stream.bytesToString();
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${body.length > 120 ? body.substring(0, 120) : body}');
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['text'] != null) {
        return decoded['text'].toString().trim();
      }
    } catch (_) {}
    return '';
  }

  void _markUnavailable(String why) {
    lastError = why;
    state = VoiceState.unavailable;
    notifyListeners();
  }
}
