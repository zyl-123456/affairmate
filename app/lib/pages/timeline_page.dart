// 展示页 · 24h 时间进度条 + 事项列表 + 四维状态 + 日历回看
// 对应设计：D-006（TECH-007）——REQ-007 三类信息；M-034 历史日程回看

import 'package:flutter/material.dart';

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
    final todayState = app.stateDays.where((d) => d.date == today).firstOrNull;

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
                if (blocks.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      children: [
                        for (final b in blocks)
                          Text(
                            '${b.isParallel ? "∥" : ""}${b.start}~${b.end} ${b.matterRef}',
                            style: TextStyle(fontSize: 11, color: scheme.outline),
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
                    const Text('今日状态（四维电量）',
                        style: TextStyle(fontWeight: FontWeight.w600)),
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
                  Text('还没有在办事项——去沟通模式说一句"下周三要交报表"试试。',
                      style: TextStyle(fontSize: 12, color: scheme.outline))
                else
                  for (final m in onMatters)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(m.name),
                      subtitle: _matterSubtitle(m).isEmpty ? null : Text(_matterSubtitle(m), style: const TextStyle(fontSize: 11)),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                      onTap: () => _showMatterDetail(context, app, m),
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

  String _matterSubtitle(Matter m) {
    final parts = <String>[];
    if (m.core.timeReq.isNotEmpty) parts.add('⏰${m.core.timeReq}');
    if (m.core.energyReq.isNotEmpty) parts.add('⚡${m.core.energyReq}');
    if (m.core.exclusive) parts.add('独占');
    if (m.ext.isNotEmpty) parts.add(m.ext.entries.map((e) => '${e.key}:${e.value}').join(' '));
    return parts.join(' · ');
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

/// M-035 空洞斜纹画笔：45° 细斜线，视觉上与实色块区分
class _GapPainter extends CustomPainter {
  final Color color;
  const _GapPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = -size.height; x < size.width; x += 5) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GapPainter oldDelegate) => color != oldDelegate.color;
}

/// 24 小时水平时间条：安排块着色 + 当前时间指示线
class TimeBar extends StatelessWidget {
  final List<ScheduleBlock> blocks;
  const TimeBar({super.key, required this.blocks});

  static const _palette = [
    Color(0xFF3F6C51), // 绿
    Color(0xFF4C6FA5), // 蓝
    Color(0xFF9C6B9E), // 紫
    Color(0xFFB07B3F), // 橙
    Color(0xFF4F8A8B), // 青
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;

      return Column(
        children: [
          SizedBox(
            height: 46,
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
                // M-035 空洞高亮：主轨未覆盖时段画斜纹条（一眼看到"时间哪去了"）
                for (final (gs, ge) in AppState.uncoveredGaps(blocks))
                  () {
                    final left = gs / 1440.0 * w;
                    final width = (ge - gs) / 1440.0 * w;
                    return Positioned(
                      left: left,
                      width: width,
                      top: 4,
                      bottom: 4,
                      child: Tooltip(
                        message: '${AppState.fmtMin(gs)}~${AppState.fmtMin(ge)} 未记录',
                        child: CustomPaint(
                          painter: _GapPainter(color: scheme.outline.withOpacity(0.25)),
                          size: Size(width, 38),
                        ),
                      ),
                    );
                  }(),
                // 安排块（M-034 多轨：主轨占满条高；伴随轨细条贴底、半透明）
                for (var i = 0; i < blocks.length; i++)
                  () {
                    final b = blocks[i];
                    final s = b.startMinutes;
                    final e = b.endMinutes;
                    if (s == null || e == null || e <= s) return const SizedBox.shrink();
                    final left = s / 1440.0 * w;
                    final width = (e - s) / 1440.0 * w;
                    final isParallel = b.isParallel;
                    return Positioned(
                      left: left,
                      width: width,
                      // 主轨满高；伴随轨：底部 1/3 细条，多伴随轨逐级上移（罕见）
                      top: isParallel ? 46 - 4 - 12 - (b.track - 1) * 5 : 4,
                      bottom: isParallel ? 4 + (b.track - 1) * 5 : 4,
                      child: Tooltip(
                        message:
                            '${isParallel ? "[并行·轨${b.track}] " : ""}${b.start}~${b.end} ${b.matterRef}\n${b.reason}',
                        child: Container(
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: _palette[i % _palette.length]
                                .withOpacity(isParallel ? 0.55 : 1.0),
                            borderRadius: BorderRadius.circular(isParallel ? 3 : 5),
                            border: isParallel
                                ? Border.all(color: scheme.outline.withOpacity(0.4), width: 0.5)
                                : null,
                          ),
                          child: Text(
                            b.matterRef,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: isParallel ? 7.5 : 9, color: Colors.white),
                          ),
                        ),
                      ),
                    );
                  }(),
                // 当前时间线
                Positioned(
                  left: nowMin / 1440.0 * w - 1,
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
              for (final h in [0, 6, 12, 18, 24]) Text('$h时', style: const TextStyle(fontSize: 9)),
            ],
          ),
        ],
      );
    });
  }
}
