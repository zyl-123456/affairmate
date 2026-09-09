// 目标页 · 大局观总览（M-039 / 老大 02:41 构想；M-044 防崩加固）
// 目标=统领事项的枝干：每个目标卡=标题+进度总结+旗下事项清单。
// 数据全由对话自动维护（goal_ops），此页只读展示——老大哲学：不填表。
//
// M-044 加固原则（老大 04:42："不要稍微有点问题就报错"）：
// 1. 整页包 ErrorWidget 兜底——任何数据异常显示降级卡而非红屏
// 2. 所有列表/字段访问防御式（null/空/类型错都给默认值）
// 3. 数据从盘上来什么都能画：坏条目跳过不拖垮整页

import 'package:flutter/material.dart';

import '../app_state_scope.dart';
import '../data/models.dart';
import '../state.dart';

class GoalsPage extends StatefulWidget {
  const GoalsPage({super.key});

  @override
  State<GoalsPage> createState() => _GoalsPageState();
}

class _GoalsPageState extends State<GoalsPage> {
  @override
  Widget build(BuildContext context) {
    final app = InheritedAppState.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('目标 · 我要去哪')),
      body: AnimatedBuilder(
        animation: app,
        builder: (context, _) {
          // M-044：整页防崩兜底——数据再异常也只降级不红屏
          return _Guard(child: () => _buildBody(context, app));
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppState app) {
    final scheme = Theme.of(context).colorScheme;

    final allGoals = app.goals;
    final allMatters = app.matters;

    final active = allGoals.where((g) => g.active).toList();
    final archived = allGoals.where((g) => !g.active).toList();
    final orphans =
        allMatters.where((m) => m.active && m.goalRef.isEmpty).toList();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [

        // 进行中的目标（长按弹管理菜单：改名/归档/删除——M-065 人工管理）
        for (final g in active)
          _Guard(
              child: () => GestureDetector(
                    onLongPress: () => _manageGoal(context, app, g.id, g.title, true),
                    child: _goalCard(context, app, g),
                  )),

        if (active.isEmpty)
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                Icon(Icons.flag_outlined, size: 40, color: scheme.outline),
                const SizedBox(height: 12),
                const Text('还没有目标',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(
                  '在对话中说说你想做成什么即可',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 12, color: scheme.outline, height: 1.7),
                ),
              ]),
            ),
          ),

        // 未归属事项提醒
        if (orphans.isNotEmpty && active.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            color: scheme.tertiaryContainer.withOpacity(0.4),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.link_off_outlined,
                        size: 15, color: scheme.tertiary),
                    const SizedBox(width: 5),
                    Text('${orphans.length} 个事项还没归属任何目标',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: scheme.tertiary)),
                  ]),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final m in orphans.take(6))
                        Text('·${m.name}',
                            style: TextStyle(
                                fontSize: 11, color: scheme.outline)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text('对话中说明归属即可',
                      style:
                          TextStyle(fontSize: 10, color: scheme.outline)),
                ],
              ),
            ),
          ),
        ],

        // 已归档目标（长按：恢复/删除）
        if (archived.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('已达成 / 搁置',
              style: TextStyle(
                  fontSize: 12,
                  color: scheme.outline,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          for (final g in archived)
            _Guard(
                child: () => GestureDetector(
                      onLongPress: () =>
                          _manageGoal(context, app, g.id, g.title, false),
                      child: _archivedCard(context, g),
                    )),
        ],
      ],
    );
  }

  Widget _archivedCard(BuildContext context, Goal g) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLowest,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.outlined_flag_outlined,
            size: 18, color: scheme.outline),
        title: Text(_safe(g.title, fallback: '（无标题）'),
            style: TextStyle(fontSize: 13, color: scheme.outline)),
        subtitle: g.progress.isNotEmpty
            ? Text(g.progress, maxLines: 1, overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 10.5, color: scheme.outline))
            : null,
      ),
    );
  }

  Widget _goalCard(BuildContext context, AppState app, Goal g) {
    final scheme = Theme.of(context).colorScheme;
    final matters =
        app.matters.where((m) => m.active && m.goalRef == g.id).toList();
    final title = _safe(g.title, fallback: '（无标题）');
    final progress = _safe(g.progress);
    final history = _safeHistory(g.progressHistory); // 防御式：逐条滤坏

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.flag_outlined, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary)),
              ),
              Text('${matters.length} 项',
                  style:
                      TextStyle(fontSize: 10.5, color: scheme.outline)),
            ]),
            // M-052 要求清单（老大哲学：要求是核心，事项是行动）——
            // 目标卡内先列"要做到什么标准"，再显示最新进度
            if (g.requirements.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final r in g.requirements)
                Padding(
                  padding: const EdgeInsets.only(top: 3, left: 2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.check_circle_outline, size: 13, color: scheme.primary),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(r, style: const TextStyle(fontSize: 11.5, height: 1.4)),
                    ),
                  ]),
                ),
            ],
            if (progress.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(progress,
                    style: TextStyle(fontSize: 11.5, height: 1.5)),
              ),
            ],
            if (history.length > 1) ...[
              // M-040 进度累积史（最近 5 条，时间线式）——M-043 已修负数；M-044 再包一层安全截取
              const SizedBox(height: 6),
              for (final h in _lastN(history, 5).reversed)
                Padding(
                  padding: const EdgeInsets.only(top: 3, left: 2),
                  child:
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(h['date'] ?? '',
                        style: TextStyle(
                            fontSize: 9.5, color: scheme.outline)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(h['note'] ?? '',
                          style:
                              const TextStyle(fontSize: 11, height: 1.4)),
                    ),
                  ]),
                ),
            ],
            if (matters.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('还没有挂靠事项——聊到相关的事它会自动归进来',
                    style:
                        TextStyle(fontSize: 10.5, color: scheme.outline)),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final m in matters)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer.withOpacity(0.35),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(m.name,
                            style: const TextStyle(fontSize: 11)),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// M-065：目标人工管理菜单（长按触发）
  Future<void> _manageGoal(
      BuildContext context, AppState app, String id, String title, bool isActive) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined, size: 20),
              title: const Text('改名', style: TextStyle(fontSize: 13)),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            if (isActive)
              ListTile(
                leading: const Icon(Icons.archive_outlined, size: 20),
                title: const Text('归档（达成或搁置）', style: TextStyle(fontSize: 13)),
                onTap: () => Navigator.pop(ctx, 'archive'),
              )
            else
              ListTile(
                leading: const Icon(Icons.restore_outlined, size: 20),
                title: const Text('恢复进行中', style: TextStyle(fontSize: 13)),
                onTap: () => Navigator.pop(ctx, 'restore'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
              title: const Text('删除（旗下事项转未归属）',
                  style: TextStyle(fontSize: 13, color: Colors.redAccent)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'rename':
        final c = TextEditingController(text: title);
        final v = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('目标改名', style: TextStyle(fontSize: 16)),
            content: TextField(controller: c, autofocus: true),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, c.text), child: const Text('保存')),
            ],
          ),
        );
        if (v != null && v.trim().isNotEmpty) await app.renameGoal(id, v.trim());
      case 'archive':
        await app.archiveGoal(id);
      case 'restore':
        await app.restoreGoal(id);
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('确认删除？'),
            content: Text('「$title」将被删除，旗下事项转为未归属。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (ok == true) await app.deleteGoal(id);
    }
  }

  // ============ M-044 防御工具 ============

  /// 安全字符串：null/非 String 给 fallback
  static String _safe(String? s, {String fallback = ''}) =>
      s?.trim() ?? fallback;

  /// 安全历史：逐条校验 date/note 可用（类型错/缺失给空串），null 列表给空
  static List<Map<String, String>> _safeHistory(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map)
          {
            'date': e['date']?.toString() ?? '',
            'note': e['note']?.toString() ?? '',
          }
    ];
  }

  /// 安全取末尾 N 条（长度不足给全量；N<=0 给空）
  static List<Map<String, String>> _lastN(
      List<Map<String, String>> list, int n) {
    if (n <= 0) return const [];
    if (list.length <= n) return list;
    return list.sublist(list.length - n);
  }
}

/// M-044 局部防崩护栏：builder 抛异常时显示降级卡（不红屏、不拖垮整页）
class _Guard extends StatelessWidget {
  final Widget Function() child;
  const _Guard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) {
        try {
          return child();
        } catch (e) {
          debugPrint('GoalsPage 局部降级: $e');
          return Card(
            elevation: 0,
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                Icon(Icons.warning_amber_outlined,
                    size: 14, color: Theme.of(context).colorScheme.outline),
                const SizedBox(width: 6),
                Text('这条数据有点问题，已跳过（不影响其他）',
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.outline)),
              ]),
            ),
          );
        }
      },
    );
  }
}
