// 懂我页 · 个人说明书展示（REQ-014 / M-032）
// 「AI 眼中的我」：四板块结构化呈现，每条带依据/可信度/来源——用户随时查看并借对话纠正。

import 'package:flutter/material.dart';

import '../app_state_scope.dart';

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
            // ============ 身份卡（M-033：当前身份+时间线）============
            if (profile.nickname.isNotEmpty || profile.currentIdentity.isNotEmpty)
              Card(
                elevation: 0,
                color: scheme.primaryContainer.withOpacity(0.3),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(Icons.badge_outlined, size: 18, color: scheme.primary),
                        const SizedBox(width: 6),
                        Text('我是谁',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: scheme.primary)),
                      ]),
                      if (profile.nickname.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text('称呼：${profile.nickname}',
                            style: const TextStyle(fontSize: 13)),
                      ],
                      for (final p in profile.identityTimeline)
                        Padding(
                          padding: const EdgeInsets.only(top: 6, left: 4),
                          child: Row(children: [
                            Container(
                              width: 8, height: 8,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: p.isCurrent ? scheme.primary : scheme.outline,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                '${p.identity}（${p.from.isEmpty ? '?' : p.from} ~ ${p.isCurrent ? '至今' : p.to}）'
                                '${p.note.isNotEmpty ? ' · ${p.note}' : ''}',
                                style: TextStyle(
                                    fontSize: 12.5,
                                    height: 1.4,
                                    color: p.isCurrent ? null : scheme.outline),
                              ),
                            ),
                          ]),
                        ),
                      if (profile.items.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8, left: 4),
                          child: Text(
                            profile.items.entries.map((e) => '${e.key}：${e.value}').join(' · '),
                            style: TextStyle(fontSize: 11.5, color: scheme.outline),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              '下面的说明书由 AI 随对话自动维护——它怎么理解你、怎么伺候你，全在这里，明账可查。'
              '任何一条不对，直接在沟通页告诉它（如"我其实不怕吵"），它会当场改。',
              style: TextStyle(fontSize: 11, color: scheme.outline, height: 1.6),
            ),
            const SizedBox(height: 12),
            _section(context, '画像', '我是什么样的人', pb.traits, Icons.person_outline),
            _section(context, '规律', '什么导致什么', pb.patterns, Icons.insights_outlined),
            _section(context, '充电法', '什么能恢复我', pb.recharges, Icons.battery_charging_full_outlined),
            _section(context, '偏好', '我想被怎么对待', pb.preferences, Icons.tune),
            if (pb.isEmpty && profile.identityTimeline.isEmpty)
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

  Widget _section(
      BuildContext context, String title, String subtitle, List entries, IconData icon) {
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
            for (final e in entries) _entryTile(context, e),
          ],
        ),
      ),
    );
  }

  Widget _entryTile(BuildContext context, dynamic e) {
    final scheme = Theme.of(context).colorScheme;
    final confLabel = switch (e.confidence) {
      'high' => '高',
      'low' => '低',
      _ => '中',
    };
    final confColor = switch (e.confidence) {
      'high' => scheme.primary,
      'low' => scheme.outline,
      _ => scheme.tertiary,
    };
    final originLabel = e.origin == 'user' ? '亲述' : (e.origin == 'review' ? '复盘' : 'AI观察');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(e.content as String,
              style: const TextStyle(fontSize: 13, height: 1.5)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              _chip('$originLabel · 可信度$confLabel', confColor),
              if ((e.evidence as String).isNotEmpty)
                Text('依据：${e.evidence}',
                    style: TextStyle(fontSize: 10.5, color: scheme.outline, height: 1.4)),
            ],
          ),
          const Divider(height: 8),
        ],
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
