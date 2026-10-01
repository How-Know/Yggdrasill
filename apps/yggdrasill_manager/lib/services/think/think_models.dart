DateTime? _date(dynamic v) =>
    v is String && v.isNotEmpty ? DateTime.tryParse(v)?.toLocal() : null;

String _str(dynamic v) => v == null ? '' : v.toString();

List<String> _strList(dynamic v) => v is List
    ? v.map((e) => e?.toString().trim() ?? '').where((e) => e.isNotEmpty).toList()
    : const <String>[];

List<Map<String, dynamic>> _mapList(dynamic v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

double _num(dynamic v) =>
    v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0;

class ThinkAttachment {
  const ThinkAttachment({
    required this.path,
    required this.name,
    required this.mime,
    this.size,
  });

  final String path;
  final String name;
  final String mime;
  final int? size;

  bool get isImage => mime.startsWith('image/');

  factory ThinkAttachment.fromJson(Map<String, dynamic> j) => ThinkAttachment(
        path: _str(j['path']),
        name: _str(j['name']),
        mime: _str(j['mime']),
        size: j['size'] is num ? (j['size'] as num).toInt() : null,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'mime': mime,
        if (size != null) 'size': size,
      };
}

class ThinkSource {
  const ThinkSource({required this.url, this.title});

  final String url;
  final String? title;

  String get label {
    final t = title?.trim() ?? '';
    if (t.isNotEmpty) return t;
    return Uri.tryParse(url)?.host ?? url;
  }

  factory ThinkSource.fromJson(Map<String, dynamic> j) {
    final title = _str(j['title']).trim();
    return ThinkSource(url: _str(j['url']), title: title.isEmpty ? null : title);
  }
}

/// 답변을 만들면서 AI가 쓴 도구(기억 검색, 웹 검색 등)의 기록.
class ThinkToolTrace {
  const ThinkToolTrace({
    required this.name,
    required this.label,
    required this.detail,
    required this.ok,
    this.running = false,
    this.callId,
  });

  final String name;
  final String label;
  final String detail;
  final bool ok;
  final bool running;
  final String? callId;

  factory ThinkToolTrace.fromJson(Map<String, dynamic> j) => ThinkToolTrace(
        name: _str(j['name']),
        label: _str(j['label']).isEmpty ? _str(j['name']) : _str(j['label']),
        detail: _str(j['detail']),
        ok: j['ok'] != false,
        running: j['status'] == 'running',
        callId: j['call_id']?.toString(),
      );
}

class ThinkConversation {
  const ThinkConversation({
    required this.id,
    required this.title,
    required this.status,
    required this.messageCount,
    this.lastMessageAt,
    this.createdAt,
  });

  final String id;
  final String title;
  final String status;
  final int messageCount;
  final DateTime? lastMessageAt;
  final DateTime? createdAt;

  bool get archived => status == 'archived';
  DateTime? get sortTime => lastMessageAt ?? createdAt;

  factory ThinkConversation.fromRow(Map<String, dynamic> r) => ThinkConversation(
        id: _str(r['id']),
        title: _str(r['title']).isEmpty ? '새 대화' : _str(r['title']),
        status: _str(r['status']),
        messageCount: (r['message_count'] as num?)?.toInt() ?? 0,
        lastMessageAt: _date(r['last_message_at']),
        createdAt: _date(r['created_at']),
      );

  ThinkConversation copyWith({String? title, String? status, DateTime? lastMessageAt}) =>
      ThinkConversation(
        id: id,
        title: title ?? this.title,
        status: status ?? this.status,
        messageCount: messageCount,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
        createdAt: createdAt,
      );
}

enum ThinkMessageStatus { complete, error, stopped, streaming }

class ThinkMessage {
  ThinkMessage({
    this.id,
    required this.role,
    required this.content,
    required this.status,
    this.attachments = const [],
    this.sources = const [],
    this.toolCalls = const [],
    this.commentary,
    this.model,
    this.createdAt,
    this.contextExcluded = false,
  });

  String? id;
  final String role;
  String content;
  ThinkMessageStatus status;
  final List<ThinkAttachment> attachments;
  List<ThinkSource> sources;
  List<ThinkToolTrace> toolCalls;
  String? commentary;
  String? model;
  final DateTime? createdAt;
  String? errorText;

  /// 기록과 트리에는 남지만 AI가 읽는 대화 기록·결정 초안·스펙에서는 빠진다.
  bool contextExcluded;

  bool get isUser => role == 'user';

  static ThinkMessageStatus _status(String raw) => switch (raw) {
        'error' => ThinkMessageStatus.error,
        'stopped' => ThinkMessageStatus.stopped,
        _ => ThinkMessageStatus.complete,
      };

  factory ThinkMessage.fromRow(Map<String, dynamic> r) => ThinkMessage(
        id: _str(r['id']),
        role: _str(r['role']),
        content: _str(r['content']),
        status: _status(_str(r['status'])),
        attachments: _mapList(r['attachments']).map(ThinkAttachment.fromJson).toList(),
        sources: _mapList(r['sources']).map(ThinkSource.fromJson).toList(),
        toolCalls: _mapList(r['tool_calls']).map(ThinkToolTrace.fromJson).toList(),
        commentary: r['commentary'] as String?,
        model: r['model'] as String?,
        createdAt: _date(r['created_at']),
        contextExcluded: r['context_excluded'] == true,
      );
}

/// 질문 하나와 그 답변(들)을 한 문답으로 묶는다. [index]가 가리키는 메시지가 속한 문답의 인덱스들.
List<int> thinkTurnIndices(List<ThinkMessage> messages, int index) {
  if (index < 0 || index >= messages.length) return const [];
  var start = index;
  if (!messages[index].isUser) {
    while (start > 0 && !messages[start].isUser) {
      start -= 1;
    }
    if (!messages[start].isUser) start = index;
  }
  var end = start;
  while (end + 1 < messages.length && !messages[end + 1].isUser) {
    end += 1;
  }
  if (end < index) end = index;
  return [for (var i = start; i <= end; i++) i];
}

enum ThinkTreeKind {
  folder('folder'),
  conversation('conversation'),
  excerpt('excerpt');

  const ThinkTreeKind(this.db);
  final String db;

  static ThinkTreeKind parse(String raw) =>
      values.firstWhere((k) => k.db == raw, orElse: () => ThinkTreeKind.folder);
}

/// 대화 정리 트리의 노드. 폴더(주제), 대화 배치, 발췌(원본 메시지를 가리키는 요약) 중 하나.
/// 트리는 정리용이며 AI 맥락에는 들어가지 않는다.
class ThinkTreeNode {
  const ThinkTreeNode({
    required this.id,
    required this.kind,
    required this.title,
    required this.sortOrder,
    required this.version,
    this.parentId,
    this.summary,
    this.conversationId,
    this.createdVia = 'user',
    this.sourceMessageIds = const [],
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? parentId;
  final ThinkTreeKind kind;
  final String title;
  final String? summary;
  final int sortOrder;
  final String? conversationId;
  final String createdVia;
  final int version;
  final List<String> sourceMessageIds;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isFolder => kind == ThinkTreeKind.folder;

  factory ThinkTreeNode.fromRow(Map<String, dynamic> r) => ThinkTreeNode(
        id: _str(r['id']),
        parentId: r['parent_id'] as String?,
        kind: ThinkTreeKind.parse(_str(r['kind'])),
        title: _str(r['title']),
        summary: _str(r['summary']).trim().isEmpty ? null : _str(r['summary']).trim(),
        sortOrder: (r['sort_order'] as num?)?.toInt() ?? 0,
        conversationId: r['conversation_id'] as String?,
        createdVia: _str(r['created_via']).isEmpty ? 'user' : _str(r['created_via']),
        version: (r['version'] as num?)?.toInt() ?? 1,
        sourceMessageIds: _mapList(r['ai_tree_node_sources']).map((s) => _str(s['message_id'])).where((s) => s.isNotEmpty).toList(),
        createdAt: _date(r['created_at']),
        updatedAt: _date(r['updated_at']),
      );
}

enum ThinkMemoryKind {
  identity('identity', '교육철학'),
  principle('principle', '원칙'),
  decision('decision', '결정'),
  note('note', '메모');

  const ThinkMemoryKind(this.db, this.label);
  final String db;
  final String label;

  static ThinkMemoryKind parse(String raw) =>
      values.firstWhere((k) => k.db == raw, orElse: () => ThinkMemoryKind.note);
}

enum ThinkMemoryStatus {
  draft('draft', '초안'),
  active('active', '확정'),
  superseded('superseded', '대체됨'),
  archived('archived', '보관');

  const ThinkMemoryStatus(this.db, this.label);
  final String db;
  final String label;

  static ThinkMemoryStatus parse(String raw) =>
      values.firstWhere((s) => s.db == raw, orElse: () => ThinkMemoryStatus.draft);
}

class ThinkMemory {
  const ThinkMemory({
    required this.id,
    required this.kind,
    required this.status,
    required this.title,
    required this.content,
    required this.version,
    this.decisionContext,
    this.decisionReason,
    this.alternatives = const [],
    this.tags = const [],
    this.sortOrder = 0,
    this.supersedesId,
    this.sourceConversationId,
    this.specPath,
    this.specExportedAt,
    this.approvedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final ThinkMemoryKind kind;
  final ThinkMemoryStatus status;
  final String title;
  final String content;
  final int version;
  final String? decisionContext;
  final String? decisionReason;
  final List<String> alternatives;
  final List<String> tags;
  final int sortOrder;
  final String? supersedesId;
  final String? sourceConversationId;
  final String? specPath;
  final DateTime? specExportedAt;
  final DateTime? approvedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory ThinkMemory.fromRow(Map<String, dynamic> r) => ThinkMemory(
        id: _str(r['id']),
        kind: ThinkMemoryKind.parse(_str(r['kind'])),
        status: ThinkMemoryStatus.parse(_str(r['status'])),
        title: _str(r['title']),
        content: _str(r['content']),
        version: (r['version'] as num?)?.toInt() ?? 1,
        decisionContext: r['decision_context'] as String?,
        decisionReason: r['decision_reason'] as String?,
        alternatives: _strList(r['alternatives']),
        tags: _strList(r['tags']),
        sortOrder: (r['sort_order'] as num?)?.toInt() ?? 0,
        supersedesId: r['supersedes_id'] as String?,
        sourceConversationId: r['source_conversation_id'] as String?,
        specPath: r['spec_path'] as String?,
        specExportedAt: _date(r['spec_exported_at']),
        approvedAt: _date(r['approved_at']),
        createdAt: _date(r['created_at']),
        updatedAt: _date(r['updated_at']),
      );
}

class ThinkMemoryDraft {
  ThinkMemoryDraft({
    required this.kind,
    required this.status,
    this.title = '',
    this.content = '',
    this.decisionContext = '',
    this.decisionReason = '',
    List<String>? alternatives,
    List<String>? tags,
    this.sortOrder = 0,
    this.sourceConversationId,
    this.supersedesId,
  })  : alternatives = alternatives ?? [],
        tags = tags ?? [];

  ThinkMemoryKind kind;
  ThinkMemoryStatus status;
  String title;
  String content;
  String decisionContext;
  String decisionReason;
  List<String> alternatives;
  List<String> tags;
  int sortOrder;
  String? sourceConversationId;
  String? supersedesId;

  factory ThinkMemoryDraft.fromMemory(ThinkMemory m) => ThinkMemoryDraft(
        kind: m.kind,
        status: m.status,
        title: m.title,
        content: m.content,
        decisionContext: m.decisionContext ?? '',
        decisionReason: m.decisionReason ?? '',
        alternatives: [...m.alternatives],
        tags: [...m.tags],
        sortOrder: m.sortOrder,
        sourceConversationId: m.sourceConversationId,
        supersedesId: m.supersedesId,
      );

  Map<String, dynamic> toRow() {
    final isDecision = kind == ThinkMemoryKind.decision;
    String? nullIfBlank(String v) => v.trim().isEmpty ? null : v.trim();
    return {
      'kind': kind.db,
      'status': status.db,
      'title': title.trim(),
      'content': content.trim(),
      'decision_context': isDecision ? nullIfBlank(decisionContext) : null,
      'decision_reason': isDecision ? nullIfBlank(decisionReason) : null,
      'alternatives': isDecision
          ? alternatives.map((e) => e.trim()).where((e) => e.isNotEmpty).toList()
          : <String>[],
      'tags': tags.map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
      'sort_order': sortOrder,
      'source_conversation_id': sourceConversationId,
      'supersedes_id': supersedesId,
    };
  }
}

class ThinkMemoryRevision {
  const ThinkMemoryRevision({
    required this.version,
    required this.changedAt,
    required this.snapshot,
  });

  final int version;
  final DateTime? changedAt;
  final Map<String, dynamic> snapshot;

  factory ThinkMemoryRevision.fromRow(Map<String, dynamic> r) => ThinkMemoryRevision(
        version: (r['version'] as num?)?.toInt() ?? 0,
        changedAt: _date(r['changed_at']),
        snapshot: r['snapshot'] is Map
            ? Map<String, dynamic>.from(r['snapshot'] as Map)
            : const {},
      );
}

class ThinkDecisionDraft {
  ThinkDecisionDraft({
    required this.title,
    required this.context,
    required this.decision,
    required this.reason,
    required this.alternatives,
    required this.conflicts,
    required this.openQuestions,
    required this.tags,
  });

  final String title;
  final String context;
  final String decision;
  final String reason;
  final List<String> alternatives;
  final List<String> conflicts;
  final List<String> openQuestions;
  final List<String> tags;

  factory ThinkDecisionDraft.fromJson(Map<String, dynamic> j) => ThinkDecisionDraft(
        title: _str(j['title']),
        context: _str(j['context']),
        decision: _str(j['decision']),
        reason: _str(j['reason']),
        alternatives: _strList(j['alternatives']),
        conflicts: _strList(j['conflicts']),
        openQuestions: _strList(j['open_questions']),
        tags: _strList(j['tags']),
      );
}

class ThinkStatus {
  const ThinkStatus({
    required this.configured,
    required this.provider,
    required this.models,
    required this.webSearchEnabled,
    this.budgetLimitUsd,
    this.budgetMode = 'warn',
    this.spentUsd = 0,
    this.budgetExceeded = false,
  });

  final bool configured;
  final String provider;
  final Map<String, String> models;
  final bool webSearchEnabled;
  final double? budgetLimitUsd;
  final String budgetMode;
  final double spentUsd;
  final bool budgetExceeded;

  factory ThinkStatus.fromJson(Map<String, dynamic> j) {
    final budget = j['budget'] is Map ? Map<String, dynamic>.from(j['budget'] as Map) : const <String, dynamic>{};
    final models = j['models'] is Map
        ? (j['models'] as Map).map((k, v) => MapEntry(k.toString(), v.toString()))
        : <String, String>{};
    return ThinkStatus(
      configured: j['configured'] == true,
      provider: _str(j['provider']),
      models: models,
      webSearchEnabled: j['web_search_enabled'] != false,
      budgetLimitUsd: budget['limit_usd'] == null ? null : _num(budget['limit_usd']),
      budgetMode: _str(budget['mode']).isEmpty ? 'warn' : _str(budget['mode']),
      spentUsd: _num(budget['spent_usd']),
      budgetExceeded: budget['exceeded'] == true,
    );
  }
}

class ThinkSettings {
  const ThinkSettings({
    this.monthlyBudgetUsd,
    this.budgetMode = 'warn',
    this.webSearchEnabled = true,
    this.codeRequestDailyLimit = 10,
  });

  final double? monthlyBudgetUsd;
  final String budgetMode;
  final bool webSearchEnabled;
  final int codeRequestDailyLimit;

  factory ThinkSettings.fromRow(Map<String, dynamic>? r) => r == null
      ? const ThinkSettings()
      : ThinkSettings(
          monthlyBudgetUsd: r['monthly_budget_usd'] == null ? null : _num(r['monthly_budget_usd']),
          budgetMode: _str(r['budget_mode']) == 'block' ? 'block' : 'warn',
          webSearchEnabled: r['web_search_enabled'] != false,
          codeRequestDailyLimit: r['code_request_daily_limit'] == null ? 10 : _num(r['code_request_daily_limit']).toInt(),
        );
}

class ThinkUsageRow {
  const ThinkUsageRow({
    required this.day,
    required this.feature,
    required this.model,
    required this.runs,
    required this.errors,
    required this.inputTokens,
    required this.cachedInputTokens,
    required this.outputTokens,
    required this.reasoningTokens,
    required this.webSearchCalls,
    required this.costUsd,
  });

  final DateTime day;
  final String feature;
  final String model;
  final int runs;
  final int errors;
  final int inputTokens;
  final int cachedInputTokens;
  final int outputTokens;
  final int reasoningTokens;
  final int webSearchCalls;
  final double costUsd;

  factory ThinkUsageRow.fromRow(Map<String, dynamic> r) => ThinkUsageRow(
        day: DateTime.tryParse(_str(r['day'])) ?? DateTime(1970),
        feature: _str(r['feature']),
        model: _str(r['model']),
        runs: _num(r['runs']).toInt(),
        errors: _num(r['errors']).toInt(),
        inputTokens: _num(r['input_tokens']).toInt(),
        cachedInputTokens: _num(r['cached_input_tokens']).toInt(),
        outputTokens: _num(r['output_tokens']).toInt(),
        reasoningTokens: _num(r['reasoning_tokens']).toInt(),
        webSearchCalls: _num(r['web_search_calls']).toInt(),
        costUsd: _num(r['cost_usd']),
      );
}

const Map<String, String> kThinkFeatureLabels = {
  'think_chat': 'Think 대화',
  'think_title': '대화 제목',
  'decision_draft': '결정 초안',
  'spec_export': '스펙 내보내기',
  'memo_summarize': '메모 요약',
  'memo_summarize_sentence': '메모 한 문장 요약',
  'memo_extract_datetime': '메모 일정 추출',
  'memo_extract_phone': '메모 연락처 추출',
  'memo_extract_name': '메모 이름 추출',
  'trait_report': '성향 리포트',
  'code_request': '코드 조사 (Cursor)',
};
