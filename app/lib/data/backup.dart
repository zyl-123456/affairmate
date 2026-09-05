// 备份导出/导入 · 事务伴侣（M-027）
// 需求：老大 2026-09-04——软件价值在长期积累的两库，换机须一键迁移。
// 设计：单文件 JSON 备份（matters/state/schedule/chat 四库 + providers 供应商配置含 Key）；
//       schema_version 字段为未来结构演进留迁移口；微信/QQ/网盘传文件即迁移。

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../data/safe_io.dart';
import '../llm/providers.dart';

class BackupManager {
  static const kSchemaVersion = 1;

  /// 一键导出：四库 + 供应商配置 → 单 JSON 文件，返回文件路径（供分享）
  /// 文件名带日期：事务伴侣备份_2026-09-04.json
  static Future<File> exportAll() async {
    final dir = await getApplicationSupportDirectory();
    final dataDir = _dataDir(dir);

    Map<String, dynamic> readAsMap(String name) {
      final f = File('${dataDir.path}${Platform.pathSeparator}$name');
      final decoded = readJsonWithFallback(f);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    }

    List<dynamic> readAsList(String name) {
      final f = File('${dataDir.path}${Platform.pathSeparator}$name');
      final decoded = readJsonWithFallback(f);
      return decoded is List ? decoded : (decoded is Map ? [] : []);
    }

    // chat.json 是双桶 Map（M-024）；matters/state 是数组；schedule 是日期桶 Map
    final chatRaw = readJsonWithFallback(
        File('${dataDir.path}${Platform.pathSeparator}chat.json'));
    final chatMap = chatRaw is Map
        ? Map<String, dynamic>.from(chatRaw)
        : {'legacy': chatRaw is List ? chatRaw : []}; // 旧单列表格式

    final providersAll = await ProviderStore.exportAll();

    final backup = {
      'app': 'affairmate',
      'schema_version': kSchemaVersion,
      'exported_at': DateTime.now().toIso8601String(),
      'matters': readAsList('matters.json'),
      'state': readAsList('state.json'),
      'schedule': readAsMap('schedule.json'),
      'chat': chatMap,
      'profile': readAsMap('profile.json'), // M-031 用户画像随备份迁移
      'providers': providersAll,
    };

    // 导出到系统「下载」或文档目录（用户可直接拿文件传输）
    final stamp = DateTime.now().toString().substring(0, 10);
    final outDir = await _exportDir();
    final out = File(
        '${outDir.path}${Platform.pathSeparator}事务伴侣备份_$stamp.json');
    var n = 1;
    var candidate = out;
    while (candidate.existsSync()) {
      // 同日多次导出不覆盖：追加序号
      candidate = File(
          '${outDir.path}${Platform.pathSeparator}事务伴侣备份_${stamp}_$n.json');
      n++;
    }
    safeWriteJson(candidate, backup);
    return candidate;
  }

  /// 一键导入：校验 → 覆盖四库 + 供应商配置 → 返回导入摘要（供 UI 提示）
  static Future<String> importAll(File backupFile) async {
    final decoded = readJsonWithFallback(backupFile);
    if (decoded is! Map || decoded['app'] != 'affairmate') {
      throw Exception('不是事务伴侣的备份文件');
    }
    final ver = (decoded['schema_version'] ?? 0) as int;
    if (ver > kSchemaVersion) {
      throw Exception('备份版本（v$ver）比当前软件新，请先升级软件再导入');
    }

    final dir = await getApplicationSupportDirectory();
    final dataDir = _dataDir(dir);
    if (!dataDir.existsSync()) dataDir.createSync(recursive: true);

    // 先写临时文件再原子替换的目标：四个库文件
    void writeSafe(String name, dynamic content) {
      final f = File('${dataDir.path}${Platform.pathSeparator}$name');
      if (content is List && content.isEmpty) {
        // 备份里该库为空且盘上也无文件 → 不生成空文件（保持首次写入才建文件的现状）
        if (!f.existsSync()) return;
      }
      safeWriteJson(f, content);
    }

    writeSafe('matters.json', decoded['matters'] ?? []);
    writeSafe('state.json', decoded['state'] ?? []);
    writeSafe('schedule.json', decoded['schedule'] ?? {});
    writeSafe('chat.json', decoded['chat'] ?? {'chat': [], 'arrange': []});
    writeSafe('profile.json', decoded['profile'] ?? {}); // M-031

    // 供应商配置（含 Key）——走 ProviderStore 统一入口保持原子性
    final providers = decoded['providers'];
    if (providers is Map && providers.isNotEmpty) {
      await ProviderStore.importAll(Map<String, dynamic>.from(providers));
    }

    final matterCount = (decoded['matters'] as List? ?? []).length;
    final stateCount = (decoded['state'] as List? ?? []).length;
    return '已导入 $matterCount 条事项、$stateCount 天状态记录、供应商配置';
  }

  static Directory _dataDir(Directory base) =>
      Directory('${base.path}${Platform.pathSeparator}data');

  /// 导出目录：Windows 用「文档」，Android 用公共 Download（file_picker 分享用）
  static Future<Directory> _exportDir() async {
    if (Platform.isAndroid) {
      // Android 公共下载目录
      final d = Directory('/storage/emulated/0/Download');
      if (d.existsSync()) return d;
    }
    return getApplicationDocumentsDirectory();
  }
}
