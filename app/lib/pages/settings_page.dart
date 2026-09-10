import 'package:cross_file/cross_file.dart';
// 设置页 · 多供应商 API 配置（REQ-008 / D-004）
// Key 仅本地加密存储（SEC-002/004）；预设模板 + 自定义增删改

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'dart:io';

import '../data/backup.dart';
import '../llm/providers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../data/daily_snapshot.dart';
import '../data/usage_log.dart';
import '../llm/audio_store.dart';
import '../state.dart';

class SettingsPage extends StatefulWidget {
  final AppState app;

  const SettingsPage({super.key, required this.app});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<ProviderConfig> _providers = [];
  String? _activeId;

  @override
  void initState() {
    super.initState();
    _reload();
  }


  Future<void> _reload() async {
    final all = await ProviderStore.loadAll();
    final active = await ProviderStore.activeId();
    if (!mounted) return;
    setState(() {
      _providers = all;
      _activeId = active;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // ============ 用户档案（M-038：对话自动维护，老大裁决不让用户填表）============
          Text('用户档案',
              style: TextStyle(fontSize: 12, color: scheme.primary, fontWeight: FontWeight.w600)),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.smart_toy_outlined, size: 18, color: scheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.app.profile.nickname.isEmpty
                            ? '还没有称呼'
                            : '它叫你「${widget.app.profile.nickname}」',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ]),
                  for (final p in widget.app.profile.identityTimeline)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 24),
                      child: Text(
                        '· $p.identity（${p.from.isEmpty ? '?' : p.from} ~ ${p.isCurrent ? '至今' : p.to}）',
                        style: TextStyle(fontSize: 12, color: p.isCurrent ? null : scheme.outline),
                      ),
                    ),
                  if (widget.app.profile.identityTimeline.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 24),
                      child: Text(
                        '身份经历随对话自动记录',
                        style: TextStyle(fontSize: 11, color: scheme.outline, height: 1.5),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Text('档案由 AI 在对话中自动维护（改了会明说）；完整认知见「懂我」页',
                      style: TextStyle(fontSize: 10, color: scheme.outline)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ============ 模型供应商 ============
          Text('模型供应商',
              style: TextStyle(fontSize: 12, color: scheme.primary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('· API Key 仅保存在本机加密存储，不上传、不进版本库。',
              style: TextStyle(fontSize: 11, color: scheme.outline)),
          const SizedBox(height: 4),
          Text('· 三件套报文只发往你配置的供应商域名（网络白名单口径）。',
              style: TextStyle(fontSize: 11, color: scheme.outline)),
          const SizedBox(height: 12),

          // 已配置
          for (final c in _providers)
            Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              child: ListTile(
                title: Text('${c.label}${c.id == _activeId ? '  ✓ 使用中' : ''}'),
                subtitle: Text('${c.model}\n${c.baseUrl}',
                    style: const TextStyle(fontSize: 11, height: 1.4)),
                isThreeLine: true,
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    switch (v) {
                      case 'use':
                        await widget.app.activateProvider(c.id);
                        _reload();
                      case 'edit':
                        _openEditor(existing: c);
                      case 'delete':
                        await widget.app.deleteProvider(c.id);
                        _reload();
                      case 'test':
                        await _testConnection(c);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'use', child: Text('设为使用中')),
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'test', child: Text('测试连接')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 8),
          Text('从预设添加',
              style: TextStyle(fontSize: 12, color: scheme.primary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          for (final p in ProviderStore.presets)
            if (!_providers.any((c) => c.id == p.id))
              ListTile(
                dense: true,
                leading: const Icon(Icons.add_circle_outline, size: 20),
                title: Text(p.label, style: const TextStyle(fontSize: 14)),
                subtitle: Text(p.model, style: const TextStyle(fontSize: 11)),
                onTap: () => _openEditor(preset: p),
              ),

          const Divider(),
          ListTile(
            dense: true,
            leading: const Icon(Icons.dns_outlined, size: 20),
            title: const Text('自定义（任意 OpenAI 兼容端点）',
                style: TextStyle(fontSize: 14)),
            onTap: () => _openEditor(),
          ),

          // ============ 复盘设置（M-036：周期可调，老大 2026-09-06 裁决）============
          const Divider(),
          Text('AI 复盘',
              style: TextStyle(fontSize: 12, color: scheme.primary, fontWeight: FontWeight.w600)),
          ListTile(
            dense: true,
            leading: const Icon(Icons.auto_awesome_outlined, size: 20),
            title: const Text('复盘周期（天）', style: TextStyle(fontSize: 14)),
            subtitle: Text('每隔多久全面复盘一次你的状态与规律（当前 ${widget.app.reviewCycleDays} 天）',
                style: const TextStyle(fontSize: 11)),
            trailing: SizedBox(
              width: 72,
              child: DropdownButton<int>(
                value: widget.app.reviewCycleDays,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 7, child: Text('7 天', style: TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: 10, child: Text('10 天', style: TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: 14, child: Text('14 天', style: TextStyle(fontSize: 13))),
                  DropdownMenuItem(value: 30, child: Text('30 天', style: TextStyle(fontSize: 13))),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  await widget.app.setReviewCycle(v);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('✅ 复盘周期已调为 $v 天')));
                  }
                },
              ),
            ),
          ),

          // ============ 闹钟铃声（M-061：槽位导入，睡醒闹钟用）============
          Text('闹钟铃声',
              style: TextStyle(fontSize: 12, color: scheme.primary, fontWeight: FontWeight.w600)),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  FutureBuilder<List<int>>(
                    future: AudioStore.usedSlots(),
                    builder: (context, snap) {
                      final used = snap.data ?? [];
                      return Column(
                        children: [
                          for (var s = 1; s <= AudioStore.maxSlots; s++)
                            ListTile(
                              dense: true,
                              leading: Icon(
                                used.contains(s) ? Icons.music_note : Icons.music_off_outlined,
                                size: 20,
                                color: used.contains(s) ? scheme.primary : scheme.outline,
                              ),
                              title: Text('铃声$s' + (used.contains(s) ? ' · 已配置' : ' · 空'),
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: used.contains(s)
                                  ? const Text('睡醒闹钟可用', style: TextStyle(fontSize: 10.5))
                                  : const Text('点右侧导入音频', style: TextStyle(fontSize: 10.5)),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton(
                                    onPressed: () async {
                                      final ok = await AudioStore.importToSlot(s);
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                            content: Text(ok ? '铃声$s 已导入' : '未选择音频或格式不支持')));
                                      }
                                      setState(() {});
                                    },
                                    child: const Text('导入', style: TextStyle(fontSize: 12)),
                                  ),
                                  if (used.contains(s))
                                    TextButton(
                                      onPressed: () async {
                                        await AudioStore.clearSlot(s);
                                        setState(() {});
                                      },
                                      child: const Text('清除',
                                          style: TextStyle(fontSize: 12, color: Colors.redAccent)),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  Text('从手机选音频文件导入（mp3/wav/ogg）；铃声1 是睡醒闹钟默认。到点响一遍+震动+亮屏。',
                      style: TextStyle(fontSize: 10, color: scheme.outline)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ============ 数据快照（M-087：每日全量冻结，永久保留，可导出电脑分析）============
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: ListTile(
              leading: Icon(Icons.photo_camera_back_outlined, size: 20, color: scheme.primary),
              title: const Text('数据快照', style: TextStyle(fontSize: 14)),
              subtitle: FutureBuilder<List<String>>(
                future: DailySnapshot.availableDates(),
                builder: (context, snap) => Text(
                  snap.hasData
                      ? '已存 ${snap.data!.length} 天 · 永久保留 · 点导出全部'
                      : '每天 08:00 自动冻结一份数据全貌',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              trailing: const Icon(Icons.ios_share_outlined, size: 18),
              onTap: () async {
                // 全部快照打包成一个 txt（JSON 数组形式——电脑端 AI 直接可读）
                final dates = await DailySnapshot.availableDates();
                if (dates.isEmpty) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('还没有快照——明天 8 点后自动生成第一份')));
                  }
                  return;
                }
                final doc = await getApplicationDocumentsDirectory();
                final dir = Directory('${doc.path}${Platform.pathSeparator}snapshots');
                final buf = StringBuffer('[');
                for (final d in dates) {
                  final f = File('${dir.path}${Platform.pathSeparator}daily_$d.json');
                  if (f.existsSync()) {
                    buf.writeln(f.readAsStringSync());
                    buf.writeln(',');
                  }
                }
                buf.writeln(']');
                final out = File('${doc.path}${Platform.pathSeparator}exports${Platform.pathSeparator}snapshots_all_${dates.first}_${dates.last}.txt');
                await out.create(recursive: true);
                await out.writeAsString(buf.toString());
                if (context.mounted) {
                  await Share.shareXFiles([XFile(out.path)], text: '事务伴侣数据快照（${dates.length} 天）');
                }
              },
            ),
          ),
          const SizedBox(height: 12),

          // ============ 使用日志（M-064：出问题时导出发给开发者）============
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: ListTile(
              leading: Icon(Icons.receipt_long_outlined, size: 20, color: scheme.primary),
              title: const Text('使用日志', style: TextStyle(fontSize: 14)),
              subtitle: const Text('记录使用过程，出问题时导出发我排查', style: TextStyle(fontSize: 11)),
              trailing: const Icon(Icons.ios_share_outlined, size: 18),
              onTap: () async {
                // UI-10：日期筛选（选某天看某天；不选=全部）
                final dates = await UsageLog.availableDates();
                String? picked;
                if (dates.isNotEmpty && context.mounted) {
                  picked = await showModalBottomSheet<String>(
                    context: context,
                    builder: (ctx) => SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            title: const Text('全部日志'),
                            onTap: () => Navigator.pop(ctx, '__ALL__'),
                          ),
                          for (final d in dates.reversed)
                            ListTile(
                              leading: const Icon(Icons.calendar_today_outlined, size: 16),
                              title: Text(d, style: const TextStyle(fontSize: 13)),
                              onTap: () => Navigator.pop(ctx, d),
                            ),
                        ],
                      ),
                    ),
                  );
                  if (picked == null) return;
                }
                final text = await UsageLog.exportByDate(
                    (picked == null || picked == '__ALL__') ? null : picked);
                if (!context.mounted) return;
                // 简单可靠：弹全屏对话框展示+可长按复制（分享依赖系统面板复杂化，先够用）
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('使用日志（长按可复制全文）', style: TextStyle(fontSize: 15)),
                    content: SizedBox(
                      width: double.maxFinite,
                      child: SelectableText(
                        text.length > 8000 ? '…${text.substring(text.length - 8000)}' : text,
                        style: const TextStyle(fontSize: 10.5, height: 1.5),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () async {
                          final path = await UsageLog.exportToFile(
                              (picked == null || picked == '__ALL__') ? null : picked);
                          if (path != null && ctx.mounted) {
                            Navigator.pop(ctx);
                            await Share.shareXFiles([XFile(path)], text: '事务伴侣使用日志');
                          }
                        },
                        child: const Text('导出文件'),
                      ),
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),

          // ============ 数据备份/迁移（M-027 老大需求：换机一键迁移）============
          const Divider(),
          Text('数据备份与迁移',
              style: TextStyle(fontSize: 12, color: scheme.primary, fontWeight: FontWeight.w600)),
          ListTile(
            dense: true,
            leading: const Icon(Icons.upload_file_outlined, size: 20),
            title: const Text('导出备份（四库+供应商配置）',
                style: TextStyle(fontSize: 14)),
            subtitle: const Text('生成单个 JSON 文件，微信/QQ/网盘均可传输',
                style: TextStyle(fontSize: 11)),
            onTap: _exportBackup,
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.download_for_offline_outlined, size: 20),
            title: const Text('导入备份（换机恢复）',
                style: TextStyle(fontSize: 14)),
            subtitle: const Text('选择备份文件，覆盖当前全部数据',
                style: TextStyle(fontSize: 11)),
            onTap: _importBackup,
          ),
        ],
      ),
    );
  }

  Future<void> _exportBackup() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final f = await BackupManager.exportAll();
      messenger.showSnackBar(SnackBar(
          content: Text('✅ 备份已导出：${f.path}'),
          duration: const Duration(seconds: 6)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('❌ 导出失败：$e')));
    }
  }

  Future<void> _importBackup() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('导入备份'),
        content: const Text(
            '导入将覆盖当前的全部数据（事项/状态/日程/聊天/供应商配置）。\n建议先导出一份当前数据再做导入。继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('选择文件')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        dialogTitle: '选择事务伴侣备份文件',
      );
      final path = picked?.files.single.path;
      if (path == null) return; // 用户取消
      final summary = await BackupManager.importAll(File(path));
      await widget.app.loadProviders(); // 供应商配置已换，内存同步
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text('✅ $summary'), duration: const Duration(seconds: 6)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('❌ 导入失败：$e')));
    }
  }

  void _openEditor({ProviderConfig? existing, ProviderConfig? preset}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ProviderEditor(app: widget.app, existing: existing, preset: preset),
      ),
    ).then((_) => _reload());
  }

  Future<void> _testConnection(ProviderConfig c) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
      content: Row(children: [
        SizedBox(
            width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(width: 10),
        Text('正在测试连接…'),
      ]),
      duration: Duration(seconds: 15),
    ));
    try {
      await LlmClient(c).testConnection();
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
          SnackBar(content: Text('✅ 连接成功：${c.label}（${c.model}）')));
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('❌ 连接失败：$e')));
    }
  }
}

class _ProviderEditor extends StatefulWidget {
  final AppState app;
  final ProviderConfig? existing;
  final ProviderConfig? preset;

  const _ProviderEditor({required this.app, this.existing, this.preset});

  @override
  State<_ProviderEditor> createState() => _ProviderEditorState();
}

class _ProviderEditorState extends State<_ProviderEditor> {
  late final _label = TextEditingController(
      text: widget.existing?.label ?? widget.preset?.label ?? '');
  late final _baseUrl = TextEditingController(
      text: widget.existing?.baseUrl ?? widget.preset?.baseUrl ?? '');
  late final _model = TextEditingController(
      text: widget.existing?.model ?? widget.preset?.model ?? '');
  late final _apiKey = TextEditingController(text: widget.existing?.apiKey ?? '');
  bool _activate = true;

  @override
  void dispose() {
    _label.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? '编辑供应商' : '添加供应商')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _label,
            decoration: const InputDecoration(
                labelText: '显示名称', hintText: '如 智谱 GLM'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(
                labelText: 'Base URL（OpenAI 兼容）',
                hintText: 'https://open.bigmodel.cn/api/paas/v4'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            decoration:
                const InputDecoration(labelText: '模型名', hintText: 'glm-5.3'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: 'API Key', hintText: '仅存本机加密存储'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('保存后设为使用中'),
            value: _activate,
            onChanged: (v) => setState(() => _activate = v),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final id = widget.existing?.id ??
        widget.preset?.id ??
        'custom_${DateTime.now().millisecondsSinceEpoch}';
    final c = ProviderConfig(
      id: id,
      label: _label.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      model: _model.text.trim(),
      apiKey: _apiKey.text.trim(),
    );
    if (c.label.isEmpty || c.baseUrl.isEmpty || c.model.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('名称 / Base URL / 模型名不能为空')));
      }
      return;
    }
    await widget.app.saveProvider(c, activate: _activate);
    if (mounted) Navigator.pop(context);
  }
}
