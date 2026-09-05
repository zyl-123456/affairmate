// 用户总档案 · 事务伴侣（M-033）
// 演进：M-031 名片册（nickname+items）+ M-032 说明书（playbook 四板块）
//      → 老大 2026-09-05 裁决合并为一本总档案 profile.json，不分权限区。
// 新增：身份时间线 identity_timeline（from/to 历史保留——身份会变，历史不丢）。
// 迁移：旧 playbook.json 自动并入（读后并入，原文件保留不动以防回滚）。

import 'dart:io';

import 'models.dart';
import 'safe_io.dart';

/// 身份时间段（如 2023-09~至今 控制工程研究生）
class IdentityPeriod {
  final String identity; // 身份描述
  final String from; // 起始（YYYY-MM，可粗略）
  final String to; // 结束（空=至今）
  final String note; // 附注（如"读研期间日常久坐用脑"）

  const IdentityPeriod({
    required this.identity,
    this.from = '',
    this.to = '',
    this.note = '',
  });

  bool get isCurrent => to.isEmpty;

  factory IdentityPeriod.fromJson(Map<String, dynamic> j) => IdentityPeriod(
        identity: (j['identity'] ?? '').toString(),
        from: (j['from'] ?? '').toString(),
        to: (j['to'] ?? '').toString(),
        note: (j['note'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'identity': identity,
        if (from.isNotEmpty) 'from': from,
        if (to.isNotEmpty) 'to': to,
        if (note.isNotEmpty) 'note': note,
      };

  IdentityPeriod copyWith(
          {String? identity, String? from, String? to, String? note}) =>
      IdentityPeriod(
        identity: identity ?? this.identity,
        from: from ?? this.from,
        to: to ?? this.to,
        note: note ?? this.note,
      );
}

/// 用户总档案：自述身份 + 说明书四板块（合并结构，M-033）
class UserProfile {
  final String nickname;
  final Map<String, String> items; // 简单键值（年龄等；身份走时间线）
  final List<IdentityPeriod> identityTimeline;
  final List<ProfileEntry> traits;
  final List<ProfileEntry> patterns;
  final List<ProfileEntry> recharges;
  final List<ProfileEntry> preferences;
  final String lastReviewAt;

  const UserProfile({
    this.nickname = '',
    this.items = const {},
    this.identityTimeline = const [],
    this.traits = const [],
    this.patterns = const [],
    this.recharges = const [],
    this.preferences = const [],
    this.lastReviewAt = '',
  });

  bool get isEmpty =>
      nickname.isEmpty &&
      items.isEmpty &&
      identityTimeline.isEmpty &&
      traits.isEmpty &&
      patterns.isEmpty &&
      recharges.isEmpty &&
      preferences.isEmpty;

  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
        nickname: (j['nickname'] ?? '').toString(),
        items: (j['items'] as Map? ?? {})
            .map((k, v) => MapEntry(k.toString(), v.toString())),
        identityTimeline: ((j['identity_timeline'] as List?) ?? [])
            .whereType<Map>()
            .map((m) => IdentityPeriod.fromJson(Map<String, dynamic>.from(m)))
            .toList(growable: false),
        traits: _entries(j['traits']),
        patterns: _entries(j['patterns']),
        recharges: _entries(j['recharges']),
        preferences: _entries(j['preferences']),
        lastReviewAt: (j['last_review_at'] ?? '').toString(),
      );

  static List<ProfileEntry> _entries(dynamic raw) => (raw as List? ?? [])
      .whereType<Map>()
      .map((m) => ProfileEntry.fromJson(Map<String, dynamic>.from(m)))
      .toList(growable: false);

  Map<String, dynamic> toJson() => {
        'nickname': nickname,
        'items': items,
        'identity_timeline': identityTimeline.map((p) => p.toJson()).toList(),
        'traits': traits.map((e) => e.toJson()).toList(),
        'patterns': patterns.map((e) => e.toJson()).toList(),
        'recharges': recharges.map((e) => e.toJson()).toList(),
        'preferences': preferences.map((e) => e.toJson()).toList(),
        'last_review_at': lastReviewAt,
      };

  UserProfile copyWith({
    String? nickname,
    Map<String, String>? items,
    List<IdentityPeriod>? identityTimeline,
    List<ProfileEntry>? traits,
    List<ProfileEntry>? patterns,
    List<ProfileEntry>? recharges,
    List<ProfileEntry>? preferences,
    String? lastReviewAt,
  }) =>
      UserProfile(
        nickname: nickname ?? this.nickname,
        items: items ?? this.items,
        identityTimeline: identityTimeline ?? this.identityTimeline,
        traits: traits ?? this.traits,
        patterns: patterns ?? this.patterns,
        recharges: recharges ?? this.recharges,
        preferences: preferences ?? this.preferences,
        lastReviewAt: lastReviewAt ?? this.lastReviewAt,
      );

  /// 当前身份（时间线最后一段；无则空）
  String get currentIdentity =>
      identityTimeline.isEmpty ? '' : identityTimeline.last.identity;

  /// 报文视图（M-033 合并口径：nickname+身份线+items+四板块浓缩）
  Map<String, dynamic> toWireJson() {
    if (isEmpty) return {};
    final hasPlaybook = traits.isNotEmpty ||
        patterns.isNotEmpty ||
        recharges.isNotEmpty ||
        preferences.isNotEmpty;
    return {
      if (nickname.isNotEmpty) 'nickname': nickname,
      if (currentIdentity.isNotEmpty) 'current_identity': currentIdentity,
      if (identityTimeline.length > 1)
        'identity_history': identityTimeline
            .take(identityTimeline.length - 1)
            .map((p) => '${p.from}~${p.to.isEmpty ? '?' : p.to} ${p.identity}')
            .join('；'),
      ...items,
      if (hasPlaybook)
        'playbook': {
          'traits': traits.map((e) => e.content).toList(),
          'patterns': patterns.map((e) => e.content).toList(),
          'recharges': recharges.map((e) => e.content).toList(),
          'preferences': preferences.map((e) => e.content).toList(),
        },
    };
  }
}

class ProfileStore {
  final File file;

  ProfileStore(this.file);

  /// 加载总档案；自动迁移：旧 playbook.json 四板块并入（M-033，原文件保留）
  UserProfile load() {
    final merged = <String, dynamic>{};
    if (file.existsSync()) {
      final d = readJsonWithFallback(file);
      if (d is Map) merged.addAll(Map<String, dynamic>.from(d));
    }
    final playbookFile =
        File('${file.parent.path}${Platform.pathSeparator}playbook.json');
    if (playbookFile.existsSync() && !merged.containsKey('traits')) {
      final pb = readJsonWithFallback(playbookFile);
      if (pb is Map) {
        for (final k in [
          'traits',
          'patterns',
          'recharges',
          'preferences',
          'last_review_at'
        ]) {
          if (pb.containsKey(k)) merged[k] = pb[k];
        }
      }
    }
    return merged.isEmpty ? const UserProfile() : UserProfile.fromJson(merged);
  }

  Future<void> save(UserProfile p) async {
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    safeWriteJson(file, p.toJson());
  }
}
