// M-061 铃声库：用户导入的闹钟音频（最多 4 个槽位）
// 文件存 App 文档目录 alarms/（alarm1.mp3...），通知用 AndroidNotificationSound。
// RawResource 需要 res/raw 资源——所以自定义文件走 AndroidNotificationSound(fileUri) 通道。

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';

class AudioStore {
  static const int maxSlots = 4;

  static Future<Directory> _dir() async {
    final doc = await getApplicationDocumentsDirectory();
    final d = Directory('${doc.path}${Platform.pathSeparator}alarms');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 槽位文件路径（不存在返回 null）
  static Future<String?> slotPath(int slot) async {
    if (slot < 1 || slot > maxSlots) return null;
    final d = await _dir();
    for (final ext in ['.mp3', '.wav', '.ogg', '.m4a', '.aac']) {
      final f = File('${d.path}${Platform.pathSeparator}alarm$slot$ext');
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  /// 从文件选择器导入音频到槽位（拷贝+改名）
  /// 返回 true=成功
  static Future<bool> importToSlot(int slot) async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (picked == null || picked.files.isEmpty) return false;
    final src = File(picked.files.single.path!);
    final ext = src.path.contains('.')
        ? src.path.substring(src.path.lastIndexOf('.')).toLowerCase()
        : '.mp3';
    if (!['.mp3', '.wav', '.ogg', '.m4a', '.aac'].contains(ext)) return false;
    // 清掉该槽旧文件（换铃声）
    await clearSlot(slot);
    final d = await _dir();
    await src.copy('${d.path}${Platform.pathSeparator}alarm$slot$ext');
    return true;
  }

  /// 清空槽位
  static Future<void> clearSlot(int slot) async {
    final d = await _dir();
    for (final f in d.listSync()) {
      final name = f.path.split(Platform.pathSeparator).last;
      if (name.startsWith('alarm$slot.')) {
        f.deleteSync();
      }
    }
  }

  /// 已配置的槽位号列表
  static Future<List<int>> usedSlots() async {
    final used = <int>[];
    for (var s = 1; s <= maxSlots; s++) {
      if (await slotPath(s) != null) used.add(s);
    }
    return used;
  }
}
