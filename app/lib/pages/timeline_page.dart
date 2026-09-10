// 展示页 · 24h 时间进度条 + 事项列表 + 四维状态 + 日历回看
// 对应设计：D-006（TECH-007）——REQ-007 三类信息；M-034 历史日程回看

import 'package:flutter/material.dart';

import '../app_state_scope.dart';
import '../data/models.dart';
import '../data/safe_io.dart';
import '../state.dart';

class TimelinePage extends StatefulWidget {
  final AppState app;
  const TimelinePage({super.key, required this.app});

  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage> {


  /// M-096：人工写入状态弹窗（manual 标记与 AI 推断区分）
  void _showManualStateEditor(BuildContext context) {
    final app = InheritedAppState.of(context);
    final bodyCtl = TextEditingController();
    final cogCtl = TextEditingController();
    final emoCtl = TextEditingController();
    final motCtl = TextEditingController();
    final noteCtl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('人工写入今日状态', style: TextStyle(fontSize: 15)),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _edField('身体（如：精力充沛/腰有点酸）', bodyCtl),
            _edField('认知（如：头脑清晰/有点糊）', cogCtl),
            _edField('情绪（如：平稳/有点烦）', emoCtl),
            _edField('动机（如：想干活/提不起劲）', motCtl),
            _edField('依据（可选，一句话）', noteCtl),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final dims = {
                'body': bodyCtl.text, 'cognition': cogCtl.text,
                'emotion': emoCtl.text, 'motivation': motCtl.text,
              };
              var n = 0;
              for (final e in dims.entries) {
                if (e.value.trim().isNotEmpty) {
                  app.manualWriteState(e.key, e.value.trim(), noteCtl.text.trim());
                  n++;
                }
              }
              Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已人工写入 $n 维状态（带 ✍ 标记）')));
              }
            },
            child: const Text('写入'),
          ),
        ],
      ),
    );
  }

  /// M-096：事项全属性编辑器（人工通道——跟 AI 编辑并列，人也可以打字改）
  void _showMatterEditor(BuildContext context, String id) {
    final app = InheritedAppState.of(context);
    final m = app.matters.firstWhere((x) => x.id == id,
        orElse: () => app.matters.first);
    final nameCtl = TextEditingController(text: m.name);
    final timeCtl = TextEditingController(text: m.core.timeReq);
    final energyCtl = TextEditingController(text: m.core.energyReq);
    final masteryCtl = TextEditingController(text: m.core.mastery);
    final stanceCtl = TextEditingController(text: (m.ext['stance'] ?? '').toString());
    final progressCtl = TextEditingController(text: (m.ext['progress'] ?? '').toString());
    final extraKeyCtl = TextEditingController();
    final extraValCtl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text('编辑：\${m.name}', style: const TextStyle(fontSize: 15)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _edField('名称', nameCtl),
              _edField('时间要求（如：每周3次/截止周五）', timeCtl),
              _edField('精力要求（如：高专注/轻度）', energyCtl),
              _edField('掌握度（familiar/average/unfamiliar）', masteryCtl),
              _edField('我的态度认知（这事在我心里的地位）', stanceCtl),
              _edField('当前进度（复杂事项的推进状态）', progressCtl),
              const Divider(height: 20),
              _edField('扩展键（新键名）', extraKeyCtl),
              _edField('扩展值', extraValCtl),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                app.manualEditMatter(id,
                    name: nameCtl.text,
                    core: {
                      'time_req': timeCtl.text,
                      'energy_req': energyCtl.text,
                      'mastery': masteryCtl.text,
                    },
                    ext: {
                      if (stanceCtl.text.trim().isNotEmpty) 'stance': stanceCtl.text,
                      if (progressCtl.text.trim().isNotEmpty) 'progress': progressCtl.text,
                      if (extraKeyCtl.text.trim().isNotEmpty && extraValCtl.text.trim().isNotEmpty)
                        extraKeyCtl.text.trim(): extraValCtl.text.trim(),
                    });
                Navigator.pop(ctx);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _edField(String label, TextEditingController ctl) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: ctl,
          decoration: InputDecoration(
              labelText: label, isDense: true,
              border: const OutlineInputBorder()),
          style: const TextStyle(fontSize: 13),
        ),
      );

  String? _viewingDate; // null=今天；否则回看历史某天（M-034）
  Map<String, dynamic> _allSchedule = {};

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    _allSchedule = _readAllSchedule();
    app.addListener(_onAppChange);
  }

  void _onAppChange() {
    // 安排更新时刷新本地缓存（新安排落盘后）
    if (app.schedule.isNotEmpty) _allSchedule = _readAllSchedule();
  }

  @override
  void dispose() {
    app.removeListener(_onAppChange);
    super.dispose();
  }

  Map<String, dynamic> _readAllSchedule() {
    final f = app.scheduleFileForRead;
    final decoded = f.existsSync() ? readJsonWithFallback(f) : null;
    return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
  }

  List<ScheduleBlock> _blocksFor(String date) {
    final bucket = _allSchedule[date];
    if (bucket is! List) return [];
    return bucket
        .whereType<Map>()
        .map((m) => ScheduleBlock.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onMatters = app.matters.where((m) => m.active).toList();
    final today = _todayStr();
    final viewingToday = _viewingDate == null || _viewingDate == today;
    final dateKey = viewingToday ? today : _viewingDate!;
    final blocks = viewingToday ? app.schedule : _blocksFor(dateKey);
    // UI-07（老大 04:59）：状态跟随日历所选日期——回看 8/31 就显示 8/31 的四维
    final todayState = app.stateDays.where((d) => d.date == dateKey).firstOrNull;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // —— 时间进度条（M-034：支持回看任意历史日）——
        Card(
          elevation: 0,
          color: scheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.view_timeline_outlined, size: 18, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                        viewingToday
                            ? '今日时间进度条'
                            : '$dateKey 的安排（回看）',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    // 日历入口（M-034：点开月历，有安排的日子带标记）
                    IconButton(
                      icon: Icon(Icons.calendar_month_outlined,
                          size: 18, color: scheme.primary),
                      tooltip: '日历回看',
                      onPressed: () => _pickDate(context),
                    ),
                    if (!viewingToday)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: TextButton(
                          onPressed: () => setState(() => _viewingDate = null),
                          child: const Text('回今天', style: TextStyle(fontSize: 11)),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                TimeBar(blocks: blocks),
                // UI-08（老大 04:59）：进度条下方一行一时间段+左侧色块与时间条同色（图例即行）
                if (blocks.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final b in blocks)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Row(children: [
                              Container(
                                width: 10,
                                height: 10,
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                  color: TimeBar.colorOf(blocks, b),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                              Text(
                                '${b.isParallel ? "∥ " : ""}${b.start}~${b.end} ${b.matterRef}',
                                style: TextStyle(
                                    fontSize: 11.5, height: 1.4),
                              ),
                            ]),
                          ),
                      ],
                    ),
                  ),
                // M-035 空洞清单：今天已过时段中未记录的部分（回看时"时间哪去了"）
                if (viewingToday) () {
                  final now = DateTime.now();
                  final nowMin = now.hour * 60 + now.minute;
                  // 只统计今天 8 点（起床口径）到当前时间的洞
                  final gaps = AppState.uncoveredGaps(blocks,
                      fromMinute: 8 * 60, toMinute: nowMin, minMinutes: 30);
                  if (gaps.isEmpty) return const SizedBox.shrink();
                  final totalMin = gaps.fold<int>(0, (s, g) => s + (g.$2 - g.$1));
                  return Container(
                    margin: const EdgeInsets.only(top: 10),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.help_outline, size: 15, color: scheme.error),
                          const SizedBox(width: 5),
                          Text('这些时间还没有记录（共 ${(totalMin / 60).toStringAsFixed(1)} 小时）',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.error)),
                        ]),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 10,
                          children: [
                            for (final (gs, ge) in gaps)
                              Text('${AppState.fmtMin(gs)}~${AppState.fmtMin(ge)}',
                                  style: TextStyle(fontSize: 11, color: scheme.outline)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text('去沟通页告诉 AI 刚才做了什么（如"10点到12点其实在刷视频"），它会补上记录。',
                            style: TextStyle(fontSize: 10.5, color: scheme.outline, height: 1.5)),
                      ],
                    ),
                  );
                }(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),

        // —— 闹铃（M-081：设置历史+响铃状态，跟日历切换日期）——
        Builder(builder: (ctx) {
          // 所选日期的闹钟（按应响时刻过滤）
          final dayAlarms = app.alarmHistory.where((a) {
            final w = DateTime.tryParse(a.wakeAt);
            return w != null &&
                '${w.month.toString().padLeft(2, '0')}-${w.day.toString().padLeft(2, '0')}' ==
                    dateKey.substring(5); // dateKey=YYYY-MM-DD
          }).toList();
          // 待响的（未来时刻）也显示在当天
          final upcoming = app.alarmHistory.where((a) {
            final w = DateTime.tryParse(a.wakeAt);
            return w != null && w.isAfter(DateTime.now());
          }).toList();
          final show = dayAlarms.isEmpty && upcoming.isNotEmpty && viewingToday
              ? upcoming.take(3).toList()
              : dayAlarms;
          if (show.isEmpty) return const SizedBox.shrink();
          return Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.alarm, size: 18, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(viewingToday ? '闹铃' : '$dateKey 的闹铃',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 6),
                  for (final a in show)
                    () {
                      final w = DateTime.tryParse(a.wakeAt) ?? DateTime.now();
                      final passed = DateTime.now().isAfter(w);
                      final hm = '${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(children: [
                          Icon(
                            a.done
                                ? Icons.check_circle
                                : (passed ? Icons.error_outline : Icons.schedule),
                            size: 15,
                            color: a.done
                                ? Colors.green
                                : (passed ? scheme.error : scheme.primary),
                          ),
                          const SizedBox(width: 6),
                          Text('$hm 响 · 铃声${a.slot}${a.wantBrief ? " · 晨报" : ""}',
                              style: const TextStyle(fontSize: 12.5)),
                          const Spacer(),
                          if (a.userPhrase.isNotEmpty)
                            Flexible(
                              child: Text('「${a.userPhrase}」',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 10, color: scheme.outline)),
                            ),
                        ]),
                      );
                    }(),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 8),

        // —— 四维状态 ——
        Card(
          elevation: 0,
          color: scheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.bolt, size: 18, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                        viewingToday ? '今日状态（四维电量）' : '$dateKey 的状态',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    // M-096：人工写入状态（与 AI 写入区分，manual 标记）
                    IconButton(
                      icon: Icon(Icons.edit_note, size: 18, color: scheme.primary),
                      tooltip: '人工写入',
                      onPressed: () => _showManualStateEditor(context),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (todayState == null ||
                    (todayState.body.value.isEmpty &&
                        todayState.cognition.value.isEmpty &&
                        todayState.emotion.value.isEmpty &&
                        todayState.motivation.value.isEmpty))
                  Text('尚未积累——去沟通模式聊聊你的状态，会自动填充。',
                      style: TextStyle(fontSize: 12, color: scheme.outline))
                else
                  Row(
                    children: [
                      _dimChip(context, '身体', todayState.body.value,
                          dim: todayState.body, onTap: () => _showDimHistory(context, '身体', todayState.body)),
                      _dimChip(context, '认知', todayState.cognition.value,
                          dim: todayState.cognition, onTap: () => _showDimHistory(context, '认知', todayState.cognition)),
                      _dimChip(context, '情绪', todayState.emotion.value,
                          dim: todayState.emotion, onTap: () => _showDimHistory(context, '情绪', todayState.emotion)),
                      _dimChip(context, '动机', todayState.motivation.value,
                          dim: todayState.motivation, onTap: () => _showDimHistory(context, '动机', todayState.motivation)),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),

        // —— 在办事项 ——
        Card(
          elevation: 0,
          color: scheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.checklist, size: 18, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text('在办事项（${onMatters.length}）',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 4),
                if (onMatters.isEmpty)
                  Text('还没有在办事项',
                      style: TextStyle(fontSize: 12, color: scheme.outline))
                else
                  // M-045 UI-01：独立卡片 + 属性默认收起（点行内小箭头展开）
                  for (final m in onMatters)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: GestureDetector(
                        onLongPress: () => _manageMatter(context, app, m.id, m.name),
                        child: Container(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Theme(
                          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                          child: ExpansionTile(
                            dense: true,
                            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                            title: Text(m.name,
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                            subtitle: Text(
                              // 收起状态的一行摘要：只显示时间要求（最关键的信号）
                              m.core.timeReq.isNotEmpty ? '⏰ ${m.core.timeReq}' : '点开看详情',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: scheme.outline),
                            ),
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final line in _matterSubtitleLines(m))
                                    Text(line,
                                        style: const TextStyle(fontSize: 11, height: 1.6)),
                                  // M-096：累计投入展示（时间条块自动累计+人工补记）
                                  if (m.investLog.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      '⏱ 累计投入 ${_totalInvestHours(m)} 小时',
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: scheme.primary),
                                    ),
                                    for (final l in m.investLog.take(8))
                                      Text(
                                          '　${l['date']} · ${l['hours']}h${(l['note'] ?? '').isNotEmpty && l['note'] != '时间条自动累计' ? ' · ${l['note']}' : ''}',
                                          style: TextStyle(
                                              fontSize: 10.5, color: scheme.outline)),
                                    if (m.investLog.length > 8)
                                      Text('　…共 ${m.investLog.length} 条记录',
                                          style: TextStyle(
                                              fontSize: 10, color: scheme.outline)),
                                  ],
                                  const SizedBox(height: 4),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton.icon(
                                      icon: const Icon(Icons.info_outline, size: 14),
                                      label: const Text('完整详情', style: TextStyle(fontSize: 11)),
                                      onPressed: () => _showMatterDetail(context, app, m),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      ),
                    ),
                // —— 归档（仅名称）——
                if (app.matters.any((m) => !m.active)) ...[
                  const Divider(height: 16),
                  Text('已归档（仅存名称）',
                      style: TextStyle(fontSize: 11, color: scheme.outline)),
                  for (final m in app.matters.where((m) => !m.active))
                    InkWell(
                      onTap: () => _showMatterDetail(context, app, m),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text('· ${m.name}',
                            style: TextStyle(
                                fontSize: 12, color: scheme.outline, height: 1.8)),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 事项详情弹窗（REQ-003"深入了解时才展开"的入口，M-017）
  /// M-069：事项人工管理菜单（长按）
  Future<void> _manageMatter(
      BuildContext context, AppState app, String id, String name) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(name,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined, size: 20),
              title: const Text('改名', style: TextStyle(fontSize: 13)),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            // M-096：人工编辑全属性（名字/内核三属性/ext 键值——老大要求 AI 之外人也能改）
            ListTile(
              leading: const Icon(Icons.tune, size: 20),
              title: const Text('编辑属性', style: TextStyle(fontSize: 13)),
              onTap: () => Navigator.pop(ctx, 'editAll'),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline, size: 20),
              title: const Text('归档（完成或搁置）', style: TextStyle(fontSize: 13)),
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
              title: const Text('彻底删除', style: TextStyle(fontSize: 13, color: Colors.redAccent)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'editAll':
        _showMatterEditor(context, id);
        return;
      case 'rename':
        final c = TextEditingController(text: name);
        final v = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('事项改名', style: TextStyle(fontSize: 16)),
            content: TextField(controller: c, autofocus: true),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('保存')),
            ],
          ),
        );
        if (v != null && v.trim().isNotEmpty) await app.renameMatter(id, v.trim());
      case 'archive':
        await app.archiveMatter(id);
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('彻底删除？'),
            content: Text('「$name」将被删除（目标挂靠一并解除）。'),
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
        if (ok == true) await app.deleteMatter(id);
    }
  }

  void _showMatterDetail(BuildContext context, AppState app, Matter m) {
    final scheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Expanded(child: Text(m.name)),
            if (!m.active)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('已归档',
                    style: TextStyle(fontSize: 10, color: scheme.outline)),
              ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv(ctx, '时间要求', m.core.timeReq),
            _kv(ctx, '精力要求', m.core.energyReq),
            _kv(ctx, '独占性', m.core.exclusive ? '需独占（不可并行）' : '可并行'),
            if (m.ext.isNotEmpty) ...[
              const Divider(height: 20),
              Text('扩展属性',
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
              for (final e in m.ext.entries)
                _kv(ctx, e.key, e.value.toString()),
            ],
            const Divider(height: 20),
            Text('创建于 ${m.createdAt.substring(0, m.createdAt.length > 19 ? 16 : m.createdAt.length)}'
                ' · 更新于 ${m.updatedAt.substring(0, m.updatedAt.length > 19 ? 16 : m.updatedAt.length)}',
                style: TextStyle(fontSize: 10, color: scheme.outline)),
            if (!m.active)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('归档事项仅存名称与内核摘要（REQ-003 瘦身口径）',
                    style: TextStyle(fontSize: 10, color: scheme.outline)),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          if (m.active)
            FilledButton.tonal(
              onPressed: () {
                app.repo.applyMatterOps([MatterOp(op: 'archive', id: m.id, name: m.name)]);
                app.reloadFromRepo();
                Navigator.pop(ctx);
              },
              child: const Text('归档'),
            )
          else
            FilledButton.tonal(
              onPressed: () {
                app.repo.applyMatterOps([MatterOp(op: 'restore', id: m.id, name: m.name)]);
                app.reloadFromRepo();
                Navigator.pop(ctx);
              },
              child: const Text('恢复'),
            ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    if (v.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(k, style: TextStyle(fontSize: 12, color: scheme.outline)),
          ),
          Expanded(
            child: Text(v, style: const TextStyle(fontSize: 13, height: 1.4)),
          ),
        ],
      ),
    );
  }

  Widget _dimChip(BuildContext context, String label, String value,
      {DimState? dim, VoidCallback? onTap}) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Text(label,
                  style: TextStyle(fontSize: 11, color: scheme.primary)),
              const SizedBox(height: 4),
              Text(
                value.isEmpty ? '—' : value,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, height: 1.3),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              if (dim != null && dim.history.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Icon(Icons.history, size: 11, color: scheme.outline),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 四维当日轨迹弹窗（M-018：REQ-007"一天各时段状态描述"入口）
  void _showDimHistory(BuildContext context, String label, DimState dim) {
    final scheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('今日「$label」轨迹'),
        content: dim.history.isEmpty
            ? Text('今天只有当前值，还没有变化轨迹。\n多说几次状态（早/午/晚）就会积累出时段曲线。',
                style: TextStyle(fontSize: 13, color: scheme.outline, height: 1.6))
            : SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final h in dim.history)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 48,
                              child: Text(h['time'] ?? '',
                                  style: TextStyle(
                                      fontSize: 12, color: scheme.outline)),
                            ),
                            Expanded(
                              child: Text(h['value'] ?? '',
                                  style: const TextStyle(
                                      fontSize: 13, height: 1.3)),
                            ),
                          ],
                        ),
                      ),
                    const Divider(height: 16),
                    Row(
                      children: [
                        Text('当前',
                            style: TextStyle(
                                fontSize: 12, color: scheme.primary)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(dim.value,
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// M-041 属性分行展示（老大 03:47 反馈：堆一行混乱）——
  /// 每类属性独立一行：内核三属性 + 掌握度 + 目标 + 扩展键值逐行
  List<String> _matterSubtitleLines(Matter m) {
    // M-042（老大 04:05）：内核属性一项一行——表达长不挤行
    final lines = <String>[];
    if (m.core.timeReq.isNotEmpty) lines.add('⏰ 时间：${m.core.timeReq}');
    if (m.core.energyReq.isNotEmpty) lines.add('⚡ 精力：${m.core.energyReq}');
    if (m.core.exclusive) lines.add('🔒 独占（需专注，不并行）');
    final mastery = switch (m.core.mastery) {
      'familiar' => '📖 掌握度：熟悉',
      'average' => '📖 掌握度：一般',
      'unfamiliar' => '📖 掌握度：生疏',
      _ => '',
    };
    if (mastery.isNotEmpty) lines.add(mastery);
    if (m.goalRef.isNotEmpty) {
      final goal = widget.app.goals.where((g) => g.id == m.goalRef).firstOrNull;
      if (goal != null) lines.add('🎯 目标：${goal.title}');
    }
    for (final e in m.ext.entries) {
      lines.add('${e.key}：${e.value}');
    }
    return lines;
  }

  static String _todayStr() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  /// M-034 日历回看：弹月历（selectableDayYesterday 起全可选），选中即切到那天
  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(_viewingDate ?? _todayStr()) ?? now,
      firstDate: DateTime(2020),
      lastDate: now,
      helpText: '选择要回看的日期',
      cancelText: '取消',
      confirmText: '查看',
    );
    if (picked == null) return;
    final key =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    setState(() => _viewingDate = key);
  }
}

/// 24 小时水平时间条：安排块着色 + 当前时间指示线
/// M-096：事项累计投入小时数（investLog 汇总）
double _totalInvestHours(Matter m) {
  return m.investLog.fold<double>(
      0, (sum, l) => sum + (double.tryParse(l['hours'] ?? '') ?? 0));
}

class TimeBar extends StatelessWidget {
  final List<ScheduleBlock> blocks;
  const TimeBar({super.key, required this.blocks});

  // UI-11（老大 16:21）：5 色→12 色——同日撞色基本消灭；色相轮转+深浅交错
  // UI-11/14（老大两轮反馈）：5→12→24 色——一天 24 个事项不撞色
  // UI-15（老大 19:01）：跳色排列——相邻编号强制不同色系（蓝↔橙↔紫↔绿↔红交替），
  // 相邻事项对比度最大化；明度错开，同色系复活时也有深浅差。
  static const _palette = [
    Color(0xFF3D6EB4), // 1 蓝（亮）
    Color(0xFFC4662A), // 2 橙（亮）——与1互补
    Color(0xFF8E4AB8), // 3 紫
    Color(0xFF3E9E52), // 4 绿（亮）
    Color(0xFFC93A5E), // 5 红粉
    Color(0xFF2E8C94), // 6 青
    Color(0xFFA9842E), // 7 金
    Color(0xFF5A5ED2), // 8 靛蓝（亮紫蓝）
    Color(0xFF6E8C2E), // 9 黄绿
    Color(0xFFB8547A), // 10 玫瑰
    Color(0xFF2F7F5F), // 11 深绿松
    Color(0xFF8C5E2E), // 12 棕橙
    Color(0xFF4A6E9E), // 13 灰蓝
    Color(0xFFD0783C), // 14 亮橙
    Color(0xFF7A4C8C), // 15 深紫
    Color(0xFF52B87E), // 16 薄荷绿
    Color(0xFFCC4A44), // 17 砖红
    Color(0xFF3A7A8C), // 18 钢青
    Color(0xFFB8A03A), // 19 芥末
    Color(0xFF6E5AB8), // 20 亮紫
    Color(0xFF5E8C4A), // 21 橄榄
    Color(0xFFE07090), // 22 浅玫瑰
    Color(0xFF2E6E5E), // 23 墨绿
    Color(0xFF9C7A4E), // 24 驼
  ];

  /// UI-08：按事项名稳定取色（同名同色——下方列表的色块与时间条颜色严格一致）
  static Color colorOf(List<ScheduleBlock> blocks, ScheduleBlock b) {
    final names = blocks.map((x) => x.matterRef).toSet().toList();
    final idx = names.indexOf(b.matterRef);
    return _palette[(idx < 0 ? 0 : idx) % _palette.length];
  }

  /// UI-13：事项短名（前 4 字）——色块内嵌文字用
  static String _shortName(String ref) {
    if (ref.length <= 4) return ref;
    return ref.substring(0, 4);
  }

  /// UI-14（老大 18:14）：点击色块看详情——起点/终点/时长/标题/理由/并行轨
  void _showBlockDetail(BuildContext context, ScheduleBlock b) {
    final app = InheritedAppState.of(context);
    final now = DateTime.now();
    final bDate = b.date.isNotEmpty
        ? b.date
        : '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final dur = (b.endMinutes ?? 0) - (b.startMinutes ?? 0);
    final durStr = dur >= 60
        ? '${dur ~/ 60}小时${dur % 60 > 0 ? '${dur % 60}分' : ''}'
        : '$dur分钟';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(b.matterRef, style: const TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('起止：${b.start} ~ ${b.end}（$durStr）',
                style: const TextStyle(fontSize: 13)),
            if (b.review.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('你的回评：${b.review == 'done' ? '✓ 照做了' : (b.review == 'moved' ? '⏱ 改时间做了' : '✗ 没做')}',
                    style: const TextStyle(fontSize: 12, color: Colors.green)),
              ),
            if (b.isParallel)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('并行轨 ${b.track}（与同时段其他事并行）',
                    style: const TextStyle(fontSize: 12)),
              ),
            if (b.reason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('安排理由：', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              Text(b.reason, style: const TextStyle(fontSize: 12, height: 1.5)),
            ],
          ],
        ),
        actions: [
          // M-089：安排效果回评——AI 排程的学习信号
          TextButton(
            onPressed: () { app.reviewBlock(bDate, b.start, b.matterRef, 'done'); Navigator.pop(ctx); },
            child: const Text('✓照做', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: () { app.reviewBlock(bDate, b.start, b.matterRef, 'moved'); Navigator.pop(ctx); },
            child: const Text('⏱改时做', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: () { app.reviewBlock(bDate, b.start, b.matterRef, 'skipped'); Navigator.pop(ctx); },
            child: const Text('✗没做', style: TextStyle(fontSize: 12)),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;

      // UI-12（老大 16:21）：双条——0~12 一条、12~24 一条，各撑满屏宽（块宽翻倍不拥挤）
      return Column(
        children: [
          _halfBar(context, blocks, w,
              fromMin: 0, toMin: 720, nowMin: nowMin, startLabel: '0时', midLabel: '6时', endLabel: '12时'),
          const SizedBox(height: 6),
          _halfBar(context, blocks, w,
              fromMin: 720, toMin: 1440, nowMin: nowMin, startLabel: '12时', midLabel: '18时', endLabel: '24时'),
        ],
      );
    });
  }

  /// 半天条（UI-12）：fromMin~toMin 共 720 分钟映射全宽
  Widget _halfBar(BuildContext context, List<ScheduleBlock> blocks, double w,
      {required int fromMin,
      required int toMin,
      required int nowMin,
      required String startLabel,
      required String midLabel,
      required String endLabel}) {
    final scheme = Theme.of(context).colorScheme;
    final span = (toMin - fromMin).toDouble();

    // 本半天的块（跨 12 点的块切两段：夹在本条内的部分，同色延续）
    final visible = <(ScheduleBlock, int, int)>[];
    for (final b in blocks) {
      final s = b.startMinutes;
      final e = b.endMinutes;
      if (s == null || e == null || e <= s) continue;
      final cs = s < fromMin ? fromMin : s; // clip 到本条
      final ce = e > toMin ? toMin : e;
      if (ce > cs) visible.add((b, cs, ce));
    }

    return Column(
      children: [
        SizedBox(
          height: 42,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 底槽
              Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              // 安排块
              for (final (b, cs, ce) in visible)
                () {
                  final left = (cs - fromMin) / span * w;
                  final width = (ce - cs) / span * w;
                  final isParallel = b.isParallel;
                  final canShowText = width > 28; // UI-14：阈值放宽（双条后更多块能放字）
                  return Positioned(
                    left: left,
                    width: width,
                    top: isParallel ? 42 - 4 - 11 - (b.track - 1) * 5 : 4,
                    bottom: isParallel ? 4 + (b.track - 1) * 5 : 4,
                    // UI-14（老大 18:14）：块可点——窄块放不下字也能点开看
                    // 起点/终点/事项标题/理由详情
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _showBlockDetail(context, b),
                      child: Tooltip(
                      message:
                          '${isParallel ? "[并行·轨${b.track}] " : ""}${b.start}~${b.end} ${b.matterRef}\n${b.reason}',
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: colorOf(blocks, b)
                              .withOpacity(isParallel ? 0.55 : 1.0),
                          borderRadius: BorderRadius.circular(isParallel ? 3 : 5),
                          border: isParallel
                              ? Border.all(color: scheme.outline.withOpacity(0.4), width: 0.5)
                              : null,
                        ),
                        child: canShowText
                            ? FittedBox(
                                // UI-13：块内嵌事项短名（≤4字），自适应缩放
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _shortName(b.matterRef),
                                  maxLines: 1,
                                  style: TextStyle(
                                      fontSize: isParallel ? 8 : 10,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w500),
                                ),
                              )
                            : null,
                      ),
                      ),
                    ),
                  );
                }(),
              // 当前时间线（仅当天条内且在本半条范围时显示）
              if (nowMin >= fromMin && nowMin < toMin)
                Positioned(
                  left: (nowMin - fromMin) / span * w - 1,
                  top: -2,
                  bottom: -2,
                  child: Container(width: 2, color: scheme.error),
                ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(startLabel, style: const TextStyle(fontSize: 9)),
            Text(midLabel, style: const TextStyle(fontSize: 9)),
            Text(endLabel, style: const TextStyle(fontSize: 9)),
          ],
        ),
      ],
    );
  }
}
