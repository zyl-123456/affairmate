// 数据落盘安全通道 · 事务伴侣
// M-015：原子写入（tmp→bak→替换）+ 备份回退（主坏读 bak）+ 自愈（bak 恢复后回写主文件）。
// 背景：writeAsStringSync 直写非原子——中途崩溃产生半截文件，且坏文件加载返回空库，
// 下次保存会用空库覆盖全量历史（数据一笔勾销）。本模块消灭该路径。

import 'dart:convert';
import 'dart:io';

/// 安全写 JSON：tmp 先写全 → 老内容转 .bak → tmp 原子 rename 顶替主文件。
/// 任何一步失败：主文件保持旧内容或完整新内容，绝不出现半截。
void safeWriteJson(File file, Object? data, {String indent = '  '}) {
  final path = file.path;
  final tmp = File('$path.tmp');
  final bak = File('$path.bak');

  // 1. 完整新内容先落 tmp（flush 保证出盘）
  tmp.writeAsStringSync(JsonEncoder.withIndent(indent).convert(data),
      flush: true);

  // 2. 现有主文件 → .bak（若有）
  if (file.existsSync()) {
    try {
      if (bak.existsSync()) bak.deleteSync();
      file.renameSync(bak.path);
    } catch (_) {
      // rename 失败（被占用等）：继续尝试直接替换，最坏情况等于旧版直写
    }
  }

  // 3. tmp → 主文件（同卷 rename，原子）
  tmp.renameSync(path);
}

/// 安全读 JSON：主文件坏/缺失时回退 .bak；读到 bak 后**自愈**（回写主文件）。
/// 两者都坏/都无：返回 null（调用方按"空"处理，但绝不写坏主文件）。
dynamic readJsonWithFallback(File file) {
  dynamic tryDecode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  if (file.existsSync()) {
    final r = tryDecode(file.readAsStringSync());
    if (r != null) return r;
  }

  final bak = File('${file.path}.bak');
  if (bak.existsSync()) {
    final r = tryDecode(bak.readAsStringSync());
    if (r != null) {
      // 自愈：用 bak 内容重建主文件，下次坏的是 bak 而不是主文件
      try {
        safeWriteJson(file, r);
      } catch (_) {/* 自愈失败不影响本次读取 */}
      return r;
    }
  }

  return null;
}
