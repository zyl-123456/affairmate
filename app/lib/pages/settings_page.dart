// 设置页 · 多供应商 API 配置（REQ-008 / D-004）
// Key 仅本地加密存储（SEC-002/004）；预设模板 + 自定义增删改

import 'package:flutter/material.dart';

import '../app_state_scope.dart';
import '../llm/providers.dart';
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
      appBar: AppBar(title: const Text('模型供应商')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
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
        ],
      ),
    );
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
