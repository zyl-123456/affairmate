// M-064 使用日志：把"软件怎么被使用的"全程落盘，出错时用户一键导出发给开发者。
// 设计原则（老大 02:15 授权全权设计）：
// 1. 记什么：会话（发/收/耗时/token/错误）、库变更（matter/goal/state/playbook 摘要）、
//    睡眠闹钟事件、通知、页面切换不记（噪音）。
// 2. 怎么存：单文件 usage_log.txt（追加写，人可读），按天分节；
//    自动截尾（保留最近 7 天 / 5000 行，够诊断不撑盘）。
// 3. 怎么用：设置页"导出使用日志"按钮 → 分享/保存文件 → 用户发给开发者。
// 4. 性能：内存缓冲 + 每 10 条/3 秒 flush（不卡 UI）；异常全吞（日志系统绝不能反噬主功能）。

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class UsageLog {
  static final List<String> _buf = [];
  static File? _file;
  static Timer? _flushTimer;
  static const int _maxLines = 12000; // M-069：30 天连续记录容量（UI-10）
  static bool _inited = false;

  static Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      final doc = await getApplicationDocumentsDirectory();
      _file = File('${doc.path}${Platform.pathSeparator}usage_log.txt');
      await _file?.create(recursive: true);
      // 启动截尾（异步不阻塞）
      _trim();
      log('APP', '启动');
      _flushTimer = Timer.periodic(const Duration(seconds: 3), (_) => flush());
    } catch (_) {}
  }

  /// 记一条：tag=模块（CHAT/GOAL/MATTER/ALARM/ERR），msg=内容
  static void log(String tag, String msg) {
    try {
      final now = DateTime.now();
      final line =
          '${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:'
          '${now.second.toString().padLeft(2, '0')} [$tag] $msg';
      _buf.add(line);
      if (_buf.length >= 10) flush();
    } catch (_) {}
  }

  /// 关键错误单独记（含堆栈可选）
  static void err(String tag, String msg, [StackTrace? st]) {
    log('ERR', '$tag: $msg');
    if (st != null) {
      log('ERR', st.toString().split('\n').take(5).join(' | '));
    }
  }

  static Future<void> flush() async {
    if (_buf.isEmpty || _file == null) return;
    try {
      final lines = List<String>.from(_buf);
      _buf.clear();
      await _file!.writeAsString(lines.join('\n') + '\n',
          mode: FileMode.append);
    } catch (_) {}
  }

  /// 截尾：超行数从头删（保留最近）
  static Future<void> _trim() async {
    try {
      if (_file == null || !(_file!.existsSync())) return;
      final lines = _file!.readAsLinesSync();
      if (lines.length > _maxLines) {
        final kept = lines.sublist(lines.length - _maxLines);
        await _file!.writeAsString(kept.join('\n') + '\n');
      }
    } catch (_) {}
  }

  /// UI-10：按日期筛选（'09-08' 格式；null=全部）
  static Future<String> exportByDate(String? datePrefix) async {
    final all = await export();
    if (datePrefix == null) return all;
    final lines = all.split('\n');
    // 日期行格式 'MM-DD HH:mm:ss [TAG]...'——收集匹配段的连续行
    final out = <String>[];
    var inMatch = false;
    for (final l in lines) {
      final isDateLine = RegExp(r'^\d{2}-\d{2} ').hasMatch(l);
      if (isDateLine) {
        inMatch = l.startsWith(datePrefix);
      }
      if (inMatch) out.add(l);
    }
    return out.isEmpty ? '（$datePrefix 无记录）' : out.join('\n');
  }

  /// UI-10：日志覆盖的日期列表（供筛选器）
  static Future<List<String>> availableDates() async {
    final all = await export();
    final dates = <String>[];
    for (final l in all.split('\n')) {
      final m = RegExp(r'^(\d{2}-\d{2}) ').firstMatch(l);
      if (m != null && !dates.contains(m.group(1))) dates.add(m.group(1)!);
    }
    return dates;
  }

  /// 导出：返回日志全文（设置页分享用）
  static Future<String> export() async {
    await flush();
    try {
      return _file?.readAsStringSync() ?? '（日志为空）';
    } catch (_) {
      return '（日志读取失败）';
    }
  }

  static void dispose() {
    _flushTimer?.cancel();
    flush();
  }
}
