// M-088 轮级线上实录：每轮对话的"完整包裹+原始作业"逐轮落盘。
// 老大的归因分析需求（02:19）：能看到"发给模型的内容组合"与"模型交回的工作效果"，
// 未来才能判断——哪些话多余、哪里没说透导致效果差。
// 存储：wire_log/turn_序号_时刻.json（与库快照分离，按轮组织——分析单位是"一轮"）。
// 永久保留（同 M-087b 裁决）。

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class WireLog {
  static int _seq = 0;
  static Directory? _dir;

  static Future<Directory> dir() async {
    _dir ??= () {
      return null;
    }();
    final doc = await getApplicationDocumentsDirectory();
    final d = Directory('${doc.path}${Platform.pathSeparator}wire_log');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 记一轮：完整用户报文 + 模型原始响应 + 上下文
  static Future<void> logTurn({
    required bool arrangeMode,
    required String userSaid,
    required String payload,
    required String rawResponse,
    int promptTokens = 0,
    int completionTokens = 0,
    int elapsedMs = 0,
  }) async {
    try {
      final d = await dir();
      final now = DateTime.now();
      final ts =
          '${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
      final body = {
        'at': now.toIso8601String(),
        'mode': arrangeMode ? 'arrange' : 'chat',
        'user_said': userSaid,
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'elapsed_ms': elapsedMs,
        // 完整请求包裹（发给模型的所有内容的结构化原文）
        'request_payload': jsonDecode(payload),
        // 模型交回的原始作业（未经 App 解析的原文）
        'raw_response': rawResponse,
      };
      _seq++;
      await File('${d.path}${Platform.pathSeparator}turn_${_seq.toString().padLeft(5, '0')}_$ts.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(body));
    } catch (_) {}
  }
}
