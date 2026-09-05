// 设置页 · 多供应商 API 配置（REQ-008 / D-004）
// Key 仅本地加密存储（SEC-002/004）；预设模板 + 自定义增删改

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'dart:io';

import '../data/backup.dart';
import '../data/profile.dart' show IdentityPeriod;
import '../data/profile.dart';
import '../llm/providers.dart';
import '../llm/sprite.dart';
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
    _nickname = TextEditingController(text: widget.app.profile.nickname);
    _identityRows = widget.app.profile.identityTimeline
        .map((p) => (TextEditingController(text: p.identity),
                     TextEditingController(text: p.from),
                     TextEditingController(text: p.to)))
        .toList();
    _profileRows = widget.app.profile.items.entries
        .map((e) => (TextEditingController(text: e.key),
                     TextEditingController(text: e.value)))
        .toList();
  }

  late final TextEditingController _nickname;
  bool _spriteOn = false; // M-037b 小精灵开关状态（会话内存态；精灵常驻由系统管）
  List<(TextEditingController, TextEditingController, TextEditingController)> _identityRows = []; // M-033 身份时间线
  List<(TextEditingController, TextEditingController)> _profileRows = [];

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
          // ============ 用户画像（M-031：AI 怎么称呼你 + 身份信息）============
          Text('用户画像',
              style: TextStyle(fontSize: 12, color: scheme.primary, fontWeight: FontWeight.w600)),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _nickname,
                    decoration: const InputDecoration(
                        labelText: 'AI 怎么称呼你',
                        hintText: '如：龙老大',
                        isDense: true),
                  ),
                  const SizedBox(height: 10),

                  // ============ 身份时间线（M-033：身份会变，历史不丢）============
                  Text('身份经历（时间段保留历史，AI 按当前身份安排）',
                      style: TextStyle(fontSize: 11, color: scheme.outline)),
                  const SizedBox(height: 6),
                  for (final (i, row) in _identityRows.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        Expanded(
                          flex: 4,
                          child: TextField(
                              controller: row.$1,
                              decoration: const InputDecoration(
                                  hintText: '身份（如 控制工程研究生）', isDense: true)),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          flex: 2,
                          child: TextField(
                              controller: row.$2,
                              decoration: const InputDecoration(
                                  hintText: '从(2023-09)', isDense: true)),
                        ),
                        Expanded(
                          flex: 2,
                          child: TextField(
                              controller: row.$3,
                              decoration: const InputDecoration(
                                  hintText: '到(空=至今)', isDense: true)),
                        ),
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline, size: 18),
                          onPressed: () => setState(() => _identityRows.removeAt(i)),
                        ),
                      ]),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('加一段身份', style: TextStyle(fontSize: 12)),
                      onPressed: () => setState(() => _identityRows.add((
                            TextEditingController(),
                            TextEditingController(),
                            TextEditingController()))),
                    ),
                  ),
                  const Divider(height: 4),
                  const SizedBox(height: 6),
                  for (final (i, row) in _profileRows.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                              controller: row.$1,
                              decoration: const InputDecoration(
                                  hintText: '属性（如 年龄）', isDense: true)),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          flex: 3,
                          child: TextField(
                              controller: row.$2,
                              decoration: const InputDecoration(
                                  hintText: '值（如 35）', isDense: true)),
                        ),
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline, size: 18),
                          onPressed: () => setState(() => _profileRows.removeAt(i)),
                        ),
                      ]),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('加一项（年龄/职业/身份…）', style: TextStyle(fontSize: 12)),
                      onPressed: () => setState(() => _profileRows.add((
                        TextEditingController(), TextEditingController()))),
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _saveProfile,
                      child: const Text('保存画像'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('画像会随每轮对话发给 AI——它将用这个称呼叫你，并结合身份信息做安排。',
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

          // ============ 桌面小精灵（M-037b，安卓专属）============
          if (Theme.of(context).platform == TargetPlatform.android) ...[
            const Divider(),
            Text('桌面小精灵',
                style: TextStyle(fontSize: 12, color: scheme.primary, fontWeight: FontWeight.w600)),
            SwitchListTile(
              dense: true,
              secondary: const Icon(Icons.auto_awesome_outlined, size: 20),
              title: const Text('在桌面显示小精灵（免开 App 随时说）', style: TextStyle(fontSize: 14)),
              subtitle: const Text('点它选沟通/安排，说话后结果弹通知栏；需要悬浮窗权限',
                  style: TextStyle(fontSize: 11)),
              value: _spriteOn,
              onChanged: (v) async {
                bool ok;
                if (v) {
                  ok = await SpriteController.enable();
                } else {
                  await SpriteController.disable();
                  ok = true;
                }
                if (!mounted) return;
                setState(() => _spriteOn = ok && v);
                if (v && !ok) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('⚠️ 未授予悬浮窗权限（设置→应用→显示在其他应用上层）')));
                }
              },
            ),
          ],

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

  Future<void> _saveProfile() async {
    final items = <String, String>{};
    for (final (k, v) in _profileRows) {
      final key = k.text.trim();
      if (key.isNotEmpty) items[key] = v.text.trim();
    }
    // M-033：身份时间线（身份为空的行丢弃；保持顺序）
    final timeline = <IdentityPeriod>[];
    for (final (idc, fc, tc) in _identityRows) {
      final identity = idc.text.trim();
      if (identity.isEmpty) continue;
      timeline.add(IdentityPeriod(
          identity: identity, from: fc.text.trim(), to: tc.text.trim()));
    }
    final old = widget.app.profile;
    await widget.app.saveProfile(old.copyWith(
      nickname: _nickname.text.trim(),
      items: items,
      identityTimeline: timeline,
    ));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ 档案已保存，下一轮对话生效')));
    }
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
