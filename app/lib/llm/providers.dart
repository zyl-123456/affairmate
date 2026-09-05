// 多供应商 LLM 配置层 · 事务伴侣
// 对应设计：03 文档 D-004（供应商无关抽象 + Key 本地加密 + 白名单）
// 偏差登记（04 文档 M-008）：Windows 预览阶段 Key 用本地文件存储（软件私有目录，单用户机器）；
// Android APK 打包前恢复 flutter_secure_storage（SEC-002 硬口径届时生效）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../data/models.dart';
import '../data/safe_io.dart';
import 'prompt.dart';

/// 供应商配置（OpenAI 兼容口径：智谱/Kimi/DeepSeek 等主流国产供应商全兼容）
class ProviderConfig {
  final String id; // 本地唯一标识
  final String label; // 显示名（如"智谱 GLM"）
  final String baseUrl; // 如 https://open.bigmodel.cn/api/paas/v4
  final String model; // 如 glm-5.3 / deepseek-v4-flash
  final String apiKey; // 仅内存持有，落盘走加密存储

  const ProviderConfig({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.model,
    this.apiKey = '',
  });

  factory ProviderConfig.fromJson(Map<String, dynamic> j) => ProviderConfig(
        id: (j['id'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        baseUrl: (j['base_url'] ?? '').toString(),
        model: (j['model'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'base_url': baseUrl,
        'model': model,
      }; // 注意：apiKey 不入普通 JSON，走加密存储

  ProviderConfig copyWith({
    String? label,
    String? baseUrl,
    String? model,
    String? apiKey,
  }) =>
      ProviderConfig(
        id: id,
        label: label ?? this.label,
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        apiKey: apiKey ?? this.apiKey,
      );
}

/// 供应商无关的调用抽象（D-004）。
/// 发送接口只认三件套报文与系统提示词，返回统一解析为 D-002 ReceiveFile。
class LlmClient {
  final ProviderConfig config;
  final http.Client httpClient;

  LlmClient(this.config, {http.Client? client})
      : httpClient = client ?? http.Client();

  /// 发送会话：沟通/安排共用同一三件套报文（两库全量 + 用户的话），mode 区分意图。
  /// 安排模式同样必须携带两库全量认知（REQ-006），否则模型无法"基于全部认知规划"。
  /// recentDialogue：最近对话滑窗（M-011），供模型理解指代与 C2 反问续答。
  Future<ReceiveFile> chat({
    required List<Matter> matters,
    required List<StateDay> state,
    required String userMessage,
    bool arrangeMode = false,
    List<Map<String, dynamic>> recentDialogue = const [],
    Map<String, dynamic> userProfile = const {},
    UserPlaybook playbook = const UserPlaybook(),
  }) async {
    final mattersWire = wireMatters(matters);
    final userPayload = jsonEncode({
      'mode': arrangeMode ? 'arrange' : 'chat',
      if (userProfile.isNotEmpty) 'user_profile': userProfile,
      if (!playbook.isEmpty) 'user_playbook': playbook.toJson(),
      'matters_kb': mattersWire,
      'state_kb': wireState(state),
      if (recentDialogue.isNotEmpty)
        'recent_dialogue': recentDialogue,
      'user_said': userMessage,
    });

    final raw = await _chatCompletion(
      system: kAgentSystemPrompt,
      user: userPayload,
    );
    return ReceiveFile.parse(raw);
  }

  // ============ wire 层裁剪（M-014 报文瘦身，盘上数据不动）============

  /// M-036 复盘调用：近 N 天状态全量 + 日程 + 现说明书 + 画像 → 复盘模式提示词。
  /// 输出协议与日常一致（同一张工作单），解析复用 ReceiveFile.parse。
  Future<ReceiveFile> reviewChat({
    required List<StateDay> state,
    required Map<String, dynamic> scheduleAll,
    required UserPlaybook playbook,
    required Map<String, dynamic> userProfile,
    required int days,
  }) async {
    // 近 N 天状态（按日期倒序取）
    final sorted = [...state]..sort((a, b) => b.date.compareTo(a.date));
    final kept = sorted.length > days ? sorted.sublist(0, days) : sorted;

    final userPayload = jsonEncode({
      'mode': 'review',
      'days': days,
      if (userProfile.isNotEmpty) 'user_profile': userProfile,
      if (!playbook.isEmpty) 'user_playbook': playbook.toJson(),
      'state_history': kept.map((d) => d.toJson()).toList(),
      'schedule_history': scheduleAll,
    });

    final raw = await _chatCompletion(
      system: kReviewSystemPrompt,
      user: userPayload,
    );
    return ReceiveFile.parse(raw);
  }

  /// 发送口径的事项库：在办全量；归档仅名称且只发最近 30 个（长期使用防 token 膨胀）。
  static List<Map<String, dynamic>> wireMatters(List<Matter> matters) {
    final active = matters.where((m) => m.active).map((m) => m.toWireJson()).toList();
    final archivedNames = matters
        .where((m) => !m.active)
        .map((m) => m.toWireJson())
        .toList();
    final archivedKept =
        archivedNames.length > 30 ? archivedNames.sublist(archivedNames.length - 30) : archivedNames;
    return [...active, ...archivedKept];
  }

  /// 发送口径的状态库（M-032 两层策略）：底色层浓缩由 playbook 携带（chat 参数）；
  /// 实况层只发今天 + 昨天作参照（底色已含长期规律，7 天流水冗余——REQ-011）。
  static List<Map<String, dynamic>> wireState(List<StateDay> state) {
    final sorted = [...state]..sort((a, b) => b.date.compareTo(a.date));
    final kept = sorted.length > 2 ? sorted.sublist(0, 2) : sorted;
    return kept.map((d) => d.toJson()).toList();
  }

  /// OpenAI 兼容 /chat/completions
  Future<String> _chatCompletion({
    required String system,
    required String user,
  }) async {
    final uri = Uri.parse('${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions');
    // 90s 超时：大模型长回复常见 30~60s；无超时会让 sending 永久卡死（M-020 实测教训）
    final resp = await httpClient.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${config.apiKey}',
      },
      body: jsonEncode({
        'model': config.model,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
        'temperature': 0.3,
      }),
    ).timeout(const Duration(seconds: 90));
    if (resp.statusCode != 200) {
      throw LlmException(
          'HTTP ${resp.statusCode}: ${_clip(resp.body)}');
    }
    final body = jsonDecode(resp.body);
    final choices = body is Map ? body['choices'] : null;
    if (choices is List && choices.isNotEmpty) {
      final msg = choices.first is Map ? choices.first['message'] : null;
      if (msg is Map) {
        final content = (msg['content'] ?? '').toString();
        if (content.isNotEmpty) return content;
      }
    }
    throw LlmException('响应结构异常: ${_clip(resp.body)}');
  }

  /// 错误信息裁剪（防 substring 越界 + 防超长刷屏）
  static String _clip(String s, [int n = 200]) =>
      s.length <= n ? s : s.substring(0, n);

  /// 连通性测试：发一个最小请求，返回成功或抛 LlmException（Key/端点/模型名有效性）
  Future<String> testConnection() async {
    final raw = await _chatCompletion(
      system: 'You are a connectivity probe. Reply with the single word: pong',
      user: 'ping',
    );
    return raw.trim().isEmpty ? '(空响应但连通)' : raw.trim();
  }
}

class LlmException implements Exception {
  final String message;
  const LlmException(this.message);
  @override
  String toString() => message;
}

/// 供应商配置的持久化：配置明文（非敏感）+ Key 本地存储
/// （M-008 偏差：Windows 预览阶段为本地文件；APK 前恢复加密存储）
class ProviderStore {
  static File? _storeFile;

  /// 测试注入点：覆盖持久化文件路径，避免单元测试依赖 path_provider 平台实现（M-022）
  @visibleForTesting
  static void setStoreFile(File file) => _storeFile = file;

  static Future<File> _file() async {
    if (_storeFile != null) return _storeFile!;
    final dir = await getApplicationSupportDirectory();
    final d = Directory('${dir.path}${Platform.pathSeparator}config');
    if (!d.existsSync()) d.createSync(recursive: true);
    _storeFile = File('${d.path}${Platform.pathSeparator}providers.json');
    if (!_storeFile!.existsSync()) _storeFile!.writeAsStringSync('{}');
    return _storeFile!;
  }

  static Future<Map<String, dynamic>> _readAll() async {
    final f = await _file();
    final decoded = readJsonWithFallback(f);
    if (decoded is! Map) return {};
    return Map<String, dynamic>.from(decoded);
  }

  static Future<void> _writeAll(Map<String, dynamic> m) async {
    final f = await _file();
    safeWriteJson(f, m);
  }

  /// 预设模板（M-020 更新：2026-09 检索核实；均为 OpenAI 兼容端点）
  /// - 智谱 GLM-5.3（旗舰，当前限免）；4.7-flash 永久免费可作备选
  /// - Coding Plan 专属端点（M-021）：订阅额度只在 coding 通道生效，
  ///   配常规端点会报 1113 余额不足/扣账号余额（官方 FAQ 明示）
  /// - DeepSeek：deepseek-chat/reasoner 旧名 2026-07-24 已退役，现役 v4 系列
  /// - Kimi：kimi-k2 系（256K 上下文）
  static const presets = [
    ProviderConfig(
      id: 'zhipu_coding',
      label: '智谱 GLM Coding Plan（订阅专属通道）',
      baseUrl: 'https://open.bigmodel.cn/api/coding/paas/v4',
      model: 'glm-5.2',
    ),
    ProviderConfig(
      id: 'zhipu',
      label: '智谱 GLM-5.3',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'glm-5.3',
    ),
    ProviderConfig(
      id: 'zhipu_free',
      label: '智谱 GLM-4.7-flash（永久免费）',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'glm-4.7-flash',
    ),
    ProviderConfig(
      id: 'deepseek',
      label: 'DeepSeek V4 Flash',
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-v4-flash',
    ),
    ProviderConfig(
      id: 'deepseek_pro',
      label: 'DeepSeek V4 Pro',
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-v4-pro',
    ),
    ProviderConfig(
      id: 'moonshot',
      label: 'Kimi K2（月之暗面）',
      baseUrl: 'https://api.moonshot.cn/v1',
      model: 'kimi-k2-0905-preview',
    ),
  ];

  /// 保存配置（Key 与配置同文件，本地私有目录）
  static Future<void> save(ProviderConfig c) async {
    final all = await _readAll();
    final list = ((all['providers'] as List?) ?? [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    list.removeWhere((m) => m['id'] == c.id);
    list.add(c.toJson());
    all['providers'] = list;
    if (c.apiKey.isNotEmpty) {
      all['key_${c.id}'] = c.apiKey;
    }
    await _writeAll(all);
  }

  /// 读取全部配置（自动拼回 Key）
  static Future<List<ProviderConfig>> loadAll() async {
    final all = await _readAll();
    final list = ((all['providers'] as List?) ?? [])
        .whereType<Map>()
        .map((m) => ProviderConfig.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    return list
        .map((c) => c.copyWith(apiKey: (all['key_${c.id}'] ?? '').toString()))
        .toList();
  }

  static Future<void> delete(String id) async {
    final all = await _readAll();
    final list = ((all['providers'] as List?) ?? [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .where((m) => m['id'] != id)
        .toList();
    all['providers'] = list;
    all.remove('key_$id');
    await _writeAll(all);
  }

  /// 当前选中的供应商
  static Future<String?> activeId() async =>
      (await _readAll())['active_provider']?.toString();

  static Future<void> setActive(String id) async {
    final all = await _readAll();
    all['active_provider'] = id;
    await _writeAll(all);
  }

  /// 完整激活供应商（含 Key）——语音云端转写等单点消费方用（M-026）
  static Future<ProviderConfig?> activeProvider() async {
    final all = await _readAll();
    final activeId = all['active_provider']?.toString();
    if (activeId == null) return null;
    final list = ((all['providers'] as List?) ?? [])
        .whereType<Map>()
        .map((m) => ProviderConfig.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    final c = list.where((p) => p.id == activeId).firstOrNull;
    if (c == null) return null;
    return c.copyWith(apiKey: (all['key_${c.id}'] ?? '').toString());
  }

  /// 支持目录（语音模块复用同一路径规则，M-026）
  static Future<Directory> supportDir() async => _file().then((f) => f.parent);

  // ============ 备份导出/导入（M-027 换机迁移）============

  /// 导出全部供应商配置（含 Key）——备份用
  static Future<Map<String, dynamic>> exportAll() async => _readAll();

  /// 整体导入供应商配置（含 Key）——换机恢复用，原子替换
  static Future<void> importAll(Map<String, dynamic> data) async =>
      _writeAll(data);
}
