// 懂我页 · 个人说明书展示（REQ-014 / M-032）
// 「AI 眼中的我」：四板块结构化呈现，每条带依据/可信度/来源——用户随时查看并借对话纠正。

import 'package:flutter/material.dart';

import '../app_state_scope.dart';
import '../data/models.dart';
import '../state.dart';

class PlaybookPage extends StatefulWidget {
  const PlaybookPage({super.key});

  @override
  State<PlaybookPage> createState() => _PlaybookPageState();
}

class _PlaybookPageState extends State<PlaybookPage> {
  @override
  Widget build(BuildContext context) {
    final app = InheritedAppState.of(context);
    final scheme = Theme.of(context).colorScheme;
    final pb = app.playbook;
    final profile = app.profile;

    return Scaffold(
      appBar: AppBar(title: const Text('懂我 · AI 眼中的你')),
      body: AnimatedBuilder(
        animation: app,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(12),
          children: [
            // M-054（老大 UI-05）：介绍段已删——教学文案从简
            const SizedBox(height: 0),
            // M-049 身份并入画像 + M-050 人工可编辑：
            // 身份条目（称呼/当前/曾经）编辑走 identity API；traits 条目走 playbook API。
            // 用动态 dispatch：前 N 条身份→identity 编辑；其余→playbook 编辑。
            Builder(builder: (ctx) {
              final idCount = (profile.nickname.isNotEmpty ? 1 : 0) +
                  profile.identityTimeline.length;
              final merged = <dynamic>[
                if (profile.nickname.isNotEmpty)
                  ProfileEntry(
                    content: '称呼：${profile.nickname}',
                    origin: 'user', confidence: 'high',
                    evidence: '用户设定', updatedAt: '',
                  ),
                for (final p in profile.identityTimeline)
                  ProfileEntry(
                    content: p.isCurrent
                        ? '当前身份：${p.identity}'
                        : '曾经：${p.identity}（${p.from}~${p.to}）',
                    origin: 'user', confidence: 'high',
                    evidence: '对话记录', updatedAt: '',
                  ),
                ...pb.traits,
              ];
              return _sectionWithCustomEdit(
                ctx, '画像', '我是谁 · 我是什么样', merged, Icons.person_outline,
                (i, current) async {
                  if (i < idCount) {
                    // 身份区：简单方案——支持删除身份段/改称呼
                    if (i == 0 && profile.nickname.isNotEmpty) {
                      // 称呼
                      final c = TextEditingController(text: profile.nickname);
                      final v = await showDialog<String>(context: ctx, builder: (d) => AlertDialog(
                        title: const Text('修改称呼'),
                        content: TextField(controller: c, autofocus: true),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
                          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('保存')),
                        ],
                      ));
                      if (v != null && v.trim().isNotEmpty) await app.setNickname(v);
                    } else {
                      // 身份段：长按确认删除（改身份建议对话更自然）
                      final idx = i - (profile.nickname.isNotEmpty ? 1 : 0);
                      final ok = await showDialog<bool>(context: ctx, builder: (d) => AlertDialog(
                        title: Text('删除这条身份？'),
                        content: Text(merged[i].content as String),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
                          FilledButton(onPressed: () => Navigator.pop(d, true),
                              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                              child: const Text('删除')),
                        ],
                      ));
                      if (ok == true) await app.deleteIdentity(idx);
                    }
                  } else {
                    await _editEntryDialog(ctx, app, 'traits', i - idCount, current);
                  }
                },
              );
            }),
            _section(context, '规律', '什么导致什么', pb.patterns, Icons.insights_outlined, 'patterns', app),
            _section(context, '充电法', '什么能恢复我', pb.recharges, Icons.battery_charging_full_outlined, 'recharges', app),
            _section(context, '偏好', '我想被怎么对待', pb.preferences, Icons.tune, 'preferences', app),
            if (pb.isEmpty && profile.nickname.isEmpty)
              Card(
                elevation: 0,
                color: scheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(children: [
                    Icon(Icons.auto_stories_outlined, size: 40, color: scheme.outline),
                    const SizedBox(height: 12),
                    Text('说明书还是空白的',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(
                      '多用几天、多聊聊你的习惯和状态，\nAI 会把对你的理解一条条记到这里。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: scheme.outline, height: 1.6),
                    ),
                  ]),
                ),
              ),
            if (pb.lastReviewAt.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '上次全面复盘：${pb.lastReviewAt.substring(0, pb.lastReviewAt.length > 10 ? 10 : pb.lastReviewAt.length)}（每 10 天自动复盘一次）',
                  style: TextStyle(fontSize: 10, color: scheme.outline),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title, String subtitle,
      List entries, IconData icon, String sectionKey, AppState app) {
    final scheme = Theme.of(context).colorScheme;
    if (entries.isEmpty) {
      return Card(
        elevation: 0,
        color: scheme.surfaceContainerLowest,
        child: ListTile(
          leading: Icon(icon, size: 20, color: scheme.outline),
          title: Text(title, style: const TextStyle(fontSize: 14)),
          subtitle: Text('$subtitle · 暂无记录', style: const TextStyle(fontSize: 11)),
        ),
      );
    }
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Text(title,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.primary)),
              const SizedBox(width: 8),
              Text(subtitle, style: TextStyle(fontSize: 11, color: scheme.outline)),
              const Spacer(),
              Text('${entries.length} 条',
                  style: TextStyle(fontSize: 10, color: scheme.outline)),
            ]),
            for (final (i, e) in entries.indexed)
              _entryTile(context, e, () => _editEntryDialog(
                  context, app, sectionKey, i, e.content as String)),
          ],
        ),
      ),
    );
  }

  /// M-050：长按条目弹编辑/删除（人工修订带标记）
  Future<void> _editEntryDialog(
      BuildContext context, AppState app, String section, int index, String current) async {
    final controller = TextEditingController(text: current);
    final edited = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改这条', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: controller,
          maxLines: 3,
          autofocus: true,
          decoration: const InputDecoration(hintText: '修改内容（保存后标记为"手工修订"）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, '__DELETE__'),
            child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (edited == null || edited == '__DELETE__SAME__') return;
    if (edited == '__DELETE__') {
      await app.deletePlaybookEntry(section, index);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已删除')));
      }
    } else if (edited.trim().isNotEmpty && edited != current) {
      await app.editPlaybookEntry(section, index, edited.trim());
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已修改（AI 将看到"手工修订"标记）')));
      }
    }
  }

  /// M-050：带自定义编辑回调的 section（画像板块用——身份/traits 混合编辑路由）
  Widget _sectionWithCustomEdit(BuildContext context, String title, String subtitle,
      List entries, IconData icon, Future<void> Function(int i, String current) onEdit) {
    final scheme = Theme.of(context).colorScheme;
    if (entries.isEmpty) {
      return Card(
        elevation: 0,
        color: scheme.surfaceContainerLowest,
        child: ListTile(
          leading: Icon(icon, size: 20, color: scheme.outline),
          title: Text(title, style: const TextStyle(fontSize: 14)),
          subtitle: Text('$subtitle · 暂无记录', style: const TextStyle(fontSize: 11)),
        ),
      );
    }
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Text(title,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.primary)),
              const SizedBox(width: 8),
              Text(subtitle, style: TextStyle(fontSize: 11, color: scheme.outline)),
              const Spacer(),
              Text('${entries.length} 条 · 长按可编辑',
                  style: TextStyle(fontSize: 10, color: scheme.outline)),
            ]),
            for (final (i, e) in entries.indexed)
              _entryTile(context, e, () => onEdit(i, e.content as String)),
          ],
        ),
      ),
    );
  }

  Widget _entryTile(BuildContext context, dynamic e, [Future<void> Function()? onEdit]) {
    return GestureDetector(
      onLongPress: onEdit,
      child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(e.content as String,
              style: const TextStyle(fontSize: 13, height: 1.5)),
          // UI-05（老大 22:55）：可信度/依据/来源是给 AI 的元数据——随报文照发，前端不显示
          const Divider(height: 8),
        ],
      ),
      ),
    );
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: color.withOpacity(0.1),
        ),
        child: Text(text, style: TextStyle(fontSize: 10.5, color: color)),
      );
}
