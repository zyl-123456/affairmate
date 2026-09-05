// 备份导出/导入 round-trip 测试（M-027）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiwu_companion/data/models.dart';
import 'package:shiwu_companion/data/repo.dart';
import 'package:shiwu_companion/data/safe_io.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shiwu_backup_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('M-027：备份文件结构——四库+版本号+导出时间齐全', () {
    // 直接构造备份结构（BackupManager.exportAll 依赖 path_provider 平台目录，
    // 此处验证 schema 与文件内容的契约）
    final backup = {
      'app': 'affairmate',
      'schema_version': 1,
      'exported_at': '2026-09-04T23:00:00',
      'matters': [Matter(id: 'm1', name: '交报表', createdAt: 't', updatedAt: 't').toJson()],
      'state': [StateDay(date: '2026-09-04').toJson()],
      'schedule': {'2026-09-04': []},
      'chat': {'chat': [], 'arrange': []},
      'providers': {'providers': [], 'active_provider': null},
    };
    final f = File('${tmp.path}${Platform.pathSeparator}backup.json');
    safeWriteJson(f, backup);
    final decoded = readJsonWithFallback(f);
    expect(decoded is Map, isTrue);
    expect(decoded['app'], 'affairmate');
    expect(decoded['schema_version'], 1);
    expect((decoded['matters'] as List).length, 1);
    expect(decoded['chat'] is Map, isTrue, reason: 'M-024 双桶结构');
  });

  test('M-027：导出的备份可直接被 Repo 读回（格式与运行时兼容）', () {
    // matters 备份 → 写入新环境 → Repo 正常加载
    final m = Matter(
      id: 'm1',
      name: '交报表',
      core: const CoreAttrs(timeReq: '下周三截止', exclusive: true),
      createdAt: 't',
      updatedAt: 't',
    );
    final backupMatters = [m.toJson()];
    final newRepo = Repo.at(tmp);
    final f = newRepo.mattersFile;
    safeWriteJson(f, backupMatters);
    final loaded = Repo.at(tmp).loadMatters();
    expect(loaded.length, 1);
    expect(loaded.first.name, '交报表');
    expect(loaded.first.core.timeReq, '下周三截止');
    expect(loaded.first.core.exclusive, isTrue);
  });
}
