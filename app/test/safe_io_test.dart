// 数据安全单测（M-015）：原子写 + 备份回退 + 自愈
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiwu_companion/data/models.dart';
import 'package:shiwu_companion/data/repo.dart';
import 'package:shiwu_companion/data/safe_io.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('shiwu_safe_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('safeWriteJson / readJsonWithFallback', () {
    test('写后主文件可读且 .bak 存在（二次写后才生成）', () {
      final f = File('${tmp.path}${Platform.pathSeparator}a.json');
      safeWriteJson(f, {'v': 1});
      expect(readJsonWithFallback(f), {'v': 1});
      expect(File('${f.path}.bak').existsSync(), false, reason: '首写无旧内容可备份');

      safeWriteJson(f, {'v': 2});
      expect(readJsonWithFallback(f), {'v': 2});
      expect(File('${f.path}.bak').existsSync(), true);
      expect(readJsonWithFallback(File('${f.path}.bak')), {'v': 1});
    });

    test('主文件损坏 → 回退 bak 且自愈回写', () {
      final f = File('${tmp.path}${Platform.pathSeparator}b.json');
      safeWriteJson(f, {'v': 1});
      safeWriteJson(f, {'v': 2}); // bak=v1
      // 模拟写盘中途崩溃：主文件半截
      f.writeAsStringSync('{"v": 2, "bro');

      expect(readJsonWithFallback(f), {'v': 1}, reason: '回退到 bak');
      // 自愈已回写主文件
      expect(readJsonWithFallback(f), {'v': 1});
      expect(f.readAsStringSync().contains('"v"'), true, reason: '主文件已被 bak 修复');
    });

    test('主坏且无 bak → null（空但不写坏主文件）', () {
      final f = File('${tmp.path}${Platform.pathSeparator}c.json');
      f.writeAsStringSync('彻底坏的');
      expect(readJsonWithFallback(f), isNull);
    });

    test('主坏 bak 也坏 → null', () {
      final f = File('${tmp.path}${Platform.pathSeparator}d.json');
      f.writeAsStringSync('主坏');
      File('${f.path}.bak').writeAsStringSync('bak也坏');
      expect(readJsonWithFallback(f), isNull);
    });
  });

  group('Repo 走安全通道', () {
    test('matters.json 损坏但有 bak：数据不丢', () {
      // 第一笔
      Repo.at(tmp).applyMatterOps(
          const [MatterOp(op: 'add', name: '重要事项')]);
      // 第二笔（生成 bak）
      Repo.at(tmp).applyMatterOps(
          const [MatterOp(op: 'add', name: '第二事项')]);
      // 模拟主文件损坏
      File('${tmp.path}${Platform.pathSeparator}data${Platform.pathSeparator}matters.json')
          .writeAsStringSync('半截{"na');

      final repo3 = Repo.at(tmp);
      final matters = repo3.loadMatters();
      expect(matters.length, 1, reason: '回退 bak，保住第一笔');
      expect(matters.first.name, '重要事项');
      // 且自愈后再保存不会丢
      repo3.applyMatterOps(const [MatterOp(op: 'add', name: '第三事项')]);
      expect(Repo.at(tmp).loadMatters().length, 2);
    });
  });
}
