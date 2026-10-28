DateTime? _date(dynamic v) => v is String && v.isNotEmpty ? DateTime.tryParse(v)?.toLocal() : null;

String _str(dynamic v) => v == null ? '' : v.toString();

List<String> _strList(dynamic v) =>
    v is List ? v.map((e) => e?.toString().trim() ?? '').where((e) => e.isNotEmpty).toList() : const <String>[];

List<Map<String, dynamic>> _mapList(dynamic v) =>
    v is List ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : const <Map<String, dynamic>>[];

double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '') ?? 0;

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
  bool get isSpreadsheet =>
      mime == 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' || mime == 'text/csv';

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
    this.origin = 'owner',
    this.thinkRoleId = ThinkRoleId.lead,
  });

  final String id;
  final String title;
  final String status;
  final int messageCount;
  final DateTime? lastMessageAt;
  final DateTime? createdAt;

  /// owner(운영자가 시작) 또는 cursor(Cursor가 Think에게 물으며 시작). 커서 문의는 cursor 대화에만 이어진다.
  final String origin;

  /// 대화를 맡은 부서. 역할 마이그레이션 전 DB에서는 총괄.
  final ThinkRoleId thinkRoleId;

  bool get archived => status == 'archived';
  bool get fromCursor => origin == 'cursor';
  DateTime? get sortTime => lastMessageAt ?? createdAt;

  factory ThinkConversation.fromRow(Map<String, dynamic> r) => ThinkConversation(
        id: _str(r['id']),
        title: _str(r['title']).isEmpty ? '새 대화' : _str(r['title']),
        status: _str(r['status']),
        messageCount: (r['message_count'] as num?)?.toInt() ?? 0,
        lastMessageAt: _date(r['last_message_at']),
        createdAt: _date(r['created_at']),
        origin: _str(r['origin']) == 'cursor' ? 'cursor' : 'owner',
        thinkRoleId: ThinkRoleId.parse(r['think_role_id'] as String?),
      );

  ThinkConversation copyWith({String? title, String? status, DateTime? lastMessageAt, ThinkRoleId? thinkRoleId}) =>
      ThinkConversation(
        id: id,
        title: title ?? this.title,
        status: status ?? this.status,
        messageCount: messageCount,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
        createdAt: createdAt,
        origin: origin,
        thinkRoleId: thinkRoleId ?? this.thinkRoleId,
      );
}

/// 대화 나누기 요약(나누기 제안의 payload.summary, 나눈 대화의 split_summary). 다섯 칸으로 고정한다.
/// [decided]에는 사용자가 확정한 것만 들어간다. AI의 제안·추정은 [open]·[next]에 둔다.
class ThinkSplitSummary {
  const ThinkSplitSummary({
    this.purpose = '',
    this.background = '',
    this.decided = const [],
    this.open = const [],
    this.next = const [],
  });

  final String purpose;
  final String background;
  final List<String> decided;
  final List<String> open;
  final List<String> next;

  bool get isEmpty => purpose.isEmpty;

  factory ThinkSplitSummary.fromJson(dynamic raw) {
    final j = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return ThinkSplitSummary(
      purpose: _str(j['purpose']).trim(),
      background: _str(j['background']).trim(),
      decided: _strList(j['decided']),
      open: _strList(j['open']),
      next: _strList(j['next']),
    );
  }

  Map<String, dynamic> toJson() => {
        'purpose': purpose,
        'background': background,
        'decided': decided,
        'open': open,
        'next': next,
      };
}

/// 대화 한 개의 나누기 정보. 목록 조회와 달리 열 이름을 고정하지 않고 읽어(select *),
/// 나누기 마이그레이션 전 DB에서는 기본값이 된다.
class ThinkConversationDetail {
  const ThinkConversationDetail({
    required this.id,
    this.splitFromConversationId,
    this.splitSummary,
    this.autoSplitSuggestions = true,
    this.splitColumns = false,
    this.progressSummary,
    this.contextFromConversationId,
    this.contextColumns = false,
  });

  final String id;

  /// 이 대화를 나눠 온 원본 대화. 원본을 지우면 null이 된다.
  final String? splitFromConversationId;

  /// 나눌 때 사용자가 승인한 요약. 새 대화의 AI 맥락에 참고 자료로 들어간다.
  final ThinkSplitSummary? splitSummary;

  /// false면 이 대화에서 나누기 제안을 거절해, Think가 먼저 나누자고 하지 않는다.
  final bool autoSplitSuggestions;

  /// DB에 나누기 열이 있다(마이그레이션 반영). 없으면 제안 켜기·끄기를 보여 주지 않는다.
  final bool splitColumns;

  /// 사용자가 승인한 이 대화의 진행 요약. 다음 답변부터 AI 맥락에 참고 자료로 들어간다.
  final ThinkProgressSummary? progressSummary;

  /// 사용자가 고른 다른 대화. 그 대화의 요약 본문은 여기 복사되지 않는다.
  final String? contextFromConversationId;

  /// DB에 맥락 출처 열이 있다.
  final bool contextColumns;

  bool get isSplit => splitFromConversationId != null || splitSummary != null;

  factory ThinkConversationDetail.fromRow(Map<String, dynamic> r) {
    final from = _str(r['split_from_conversation_id']);
    final summary = ThinkSplitSummary.fromJson(r['split_summary']);
    final progress = ThinkProgressSummary.fromJson(r['progress_summary']);
    return ThinkConversationDetail(
      id: _str(r['id']),
      splitFromConversationId: from.isEmpty ? null : from,
      splitSummary: summary.isEmpty ? null : summary,
      autoSplitSuggestions: r['auto_split_suggestions'] != false,
      splitColumns: r.containsKey('auto_split_suggestions'),
      progressSummary: progress.isEmpty ? null : progress,
      contextFromConversationId: _str(r['context_from_conversation_id']).isEmpty ? null : _str(r['context_from_conversation_id']),
      contextColumns: r.containsKey('context_from_conversation_id'),
    );
  }

  ThinkConversationDetail copyWith({
    bool? autoSplitSuggestions,
    ThinkProgressSummary? progressSummary,
    String? contextFromConversationId,
    bool clearContextFrom = false,
  }) =>
      ThinkConversationDetail(
        id: id,
        splitFromConversationId: splitFromConversationId,
        splitSummary: splitSummary,
        autoSplitSuggestions: autoSplitSuggestions ?? this.autoSplitSuggestions,
        splitColumns: splitColumns,
        progressSummary: progressSummary ?? this.progressSummary,
        contextFromConversationId: clearContextFrom ? null : (contextFromConversationId ?? this.contextFromConversationId),
        contextColumns: contextColumns,
      );
}

/// 고른 대화의 승인 요약·작업 상태 조회. 실패·없음·권한·빈 결과를 구분한다.
class ThinkContextLookup {
  const ThinkContextLookup({
    required this.status,
    this.title = '',
    this.summary,
    this.actionCount = 0,
    this.pendingCount = 0,
    this.codeCount = 0,
  });

  /// ok, empty, not_found, forbidden, error
  final String status;
  final String title;
  final ThinkProgressSummary? summary;
  final int actionCount;
  final int pendingCount;
  final int codeCount;

  bool get ok => status == 'ok';

  String get message => switch (status) {
        'ok' => '승인된 진행 요약과 작업 상태를 읽었습니다. 대기 카드는 확정 지침이 아닙니다.',
        'empty' => '이 대화에는 승인된 진행 요약과 작업 상태가 없습니다.',
        'not_found' => '그 대화를 찾지 못했습니다.',
        'forbidden' => '그 대화를 볼 수 없습니다. 작업이 없는 것이 아닙니다.',
        _ => '작업 상태를 읽지 못했습니다. 작업이 없는 것이 아닙니다.',
      };
}

/// 진행 요약의 다음 행동. 담당·전제·완료 기준은 사용자가 말한 것만 들어간다(비면 정하지 않은 것).
class ThinkNextAction {
  const ThinkNextAction({required this.what, this.owner = '', this.prerequisite = '', this.doneWhen = ''});

  final String what;
  final String owner;
  final String prerequisite;
  final String doneWhen;

  factory ThinkNextAction.fromJson(dynamic raw) {
    if (raw is String) return ThinkNextAction(what: raw.trim());
    final j = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return ThinkNextAction(
      what: _str(j['what']).trim(),
      owner: _str(j['owner']).trim(),
      prerequisite: _str(j['prerequisite']).trim(),
      doneWhen: _str(j['done_when']).trim(),
    );
  }

  Map<String, dynamic> toJson() => {'what': what, 'owner': owner, 'prerequisite': prerequisite, 'done_when': doneWhen};
}

/// 대화 하나의 진행 요약(진행 요약 제안의 payload.summary, 승인된 ai_conversations.progress_summary).
/// [decided]는 사용자가 확정한 것만. AI 제안·계획은 [open]·[next]에 있고 승인돼도 실행되지 않는다.
class ThinkProgressSummary {
  const ThinkProgressSummary({
    this.purpose = '',
    this.decided = const [],
    this.open = const [],
    this.status = '',
    this.next = const [],
    this.approvedAt,
    this.actionId,
    this.edited = false,
  });

  final String purpose;
  final List<String> decided;
  final List<String> open;
  final String status;
  final List<ThinkNextAction> next;

  /// 승인된 요약에만 있다.
  final DateTime? approvedAt;
  final String? actionId;

  /// 승인할 때 사용자가 고쳤다.
  final bool edited;

  bool get isEmpty => purpose.isEmpty;

  factory ThinkProgressSummary.fromJson(dynamic raw) {
    final j = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    final action = _str(j['action_id']);
    return ThinkProgressSummary(
      purpose: _str(j['purpose']).trim(),
      decided: _strList(j['decided']),
      open: _strList(j['open']),
      status: _str(j['status']).trim(),
      next: (j['next'] is List ? j['next'] as List : const [])
          .map(ThinkNextAction.fromJson)
          .where((n) => n.what.isNotEmpty)
          .toList(),
      approvedAt: _date(j['approved_at']),
      actionId: action.isEmpty ? null : action,
      edited: j['edited'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'purpose': purpose,
        'decided': decided,
        'open': open,
        'status': status,
        'next': next.map((n) => n.toJson()).toList(),
      };
}

/// 부서 기준이 가리키는 우선 기억(제목만 보여 준다).
class ThinkCriteriaMemoryRef {
  const ThinkCriteriaMemoryRef({required this.id, required this.title});

  final String id;
  final String title;

  factory ThinkCriteriaMemoryRef.fromJson(Map<String, dynamic> j) =>
      ThinkCriteriaMemoryRef(id: _str(j['id']), title: _str(j['title']).trim());
}

/// 부서 기준의 한 상태(제안 카드의 전·후). 접근 권한과 별개로, 그 부서가 먼저 살필 것을 정한다.
class ThinkCriteriaView {
  const ThinkCriteriaView({this.questions = const [], this.risks = const [], this.priorityMemories = const []});

  final List<String> questions;
  final List<String> risks;
  final List<ThinkCriteriaMemoryRef> priorityMemories;

  bool get isEmpty => questions.isEmpty && risks.isEmpty && priorityMemories.isEmpty;

  /// 승인·저장 때 보내는 형태(우선 기억은 id만).
  Map<String, dynamic> toCriteriaJson() => {
        'questions': questions,
        'risks': risks,
        'priority_memory_ids': [for (final m in priorityMemories) m.id],
      };

  factory ThinkCriteriaView.fromJson(dynamic raw) {
    final j = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return ThinkCriteriaView(
      questions: _strList(j['questions']),
      risks: _strList(j['risks']),
      priorityMemories: _mapList(j['priority_memories']).map(ThinkCriteriaMemoryRef.fromJson).toList(),
    );
  }
}

/// ai_department_criteria 한 행. [version]으로 동시 수정을 막는다(판이 다르면 저장·승인이 충돌로 멈춘다).
class ThinkDepartmentCriteria {
  const ThinkDepartmentCriteria({
    required this.department,
    this.questions = const [],
    this.risks = const [],
    this.priorityMemoryIds = const [],
    this.version = 0,
    this.updatedVia,
    this.updatedAt,
  });

  final ThinkRoleId department;
  final List<String> questions;
  final List<String> risks;
  final List<String> priorityMemoryIds;
  final int version;

  /// `owner`(직접 수정) 또는 `action:<id>`(제안 승인).
  final String? updatedVia;
  final DateTime? updatedAt;

  bool get isEmpty => questions.isEmpty && risks.isEmpty && priorityMemoryIds.isEmpty;

  factory ThinkDepartmentCriteria.fromRow(Map<String, dynamic> r) {
    final via = _str(r['updated_via']);
    return ThinkDepartmentCriteria(
      department: ThinkRoleId.parse(_str(r['department'])),
      questions: _strList(r['questions']),
      risks: _strList(r['risks']),
      priorityMemoryIds: _strList(r['priority_memory_ids']),
      version: (r['version'] as num?)?.toInt() ?? 0,
      updatedVia: via.isEmpty ? null : via,
      updatedAt: _date(r['updated_at']),
    );
  }
}

/// 커서 문의 답변의 판정(ai_messages.relay). 서버가 근거 기억을 다시 확인해 정한다.
/// answered: 승인된 기억이 근거. needs_owner: 사장님 확인 필요(커서는 근거로 쓰지 않는다).
class ThinkRelayVerdict {
  const ThinkRelayVerdict({
    required this.answered,
    this.basis = const [],
    this.ownerQuestions = const [],
  });

  final bool answered;

  /// 근거 기억 제목.
  final List<String> basis;
  final List<String> ownerQuestions;

  static ThinkRelayVerdict? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final verdict = _str(j['verdict']);
    if (verdict != 'answered' && verdict != 'needs_owner') return null;
    return ThinkRelayVerdict(
      answered: verdict == 'answered',
      basis: [
        for (final b in _mapList(j['basis']))
          if (_str(b['title']).trim().isNotEmpty) _str(b['title']).trim(),
      ],
      ownerQuestions: _strList(j['owner_questions']),
    );
  }
}

/// Edge `ROLE_PROFILE_VERSION`과 맞춘다. 역할 프로필 문구만 바뀔 때 갱신.
const kThinkRoleProfileVersion = 'think-role-2026-10-12';

/// 부서. DB 값 'product'는 그대로 두고 이름만 '문제 풀이'로 바꿨다(2026-10-12).
enum ThinkRoleId {
  lead('lead', '총괄'),
  education('education', '교육'),
  product('product', '문제 풀이'),
  engineering('engineering', '개발');

  const ThinkRoleId(this.db, this.label);
  final String db;
  final String label;

  static ThinkRoleId parse(String? raw) => values.firstWhere((r) => r.db == raw, orElse: () => ThinkRoleId.lead);

  /// 부서 역할이면 그 부서. 총괄은 없음.
  ThinkDepartmentId? get department => ThinkDepartmentId.parse(db);
}

/// 마지막 글자 받침에 따라 조사를 붙인다(개발과, 문제 풀이와). 한글이 아니면 [withoutFinal].
String thinkWithJosa(String word, String withFinal, String withoutFinal) {
  if (word.isEmpty) return word;
  final code = word.codeUnitAt(word.length - 1);
  final hangul = code >= 0xAC00 && code <= 0xD7A3;
  return '$word${hangul && (code - 0xAC00) % 28 != 0 ? withFinal : withoutFinal}';
}

/// 대화·부서의 진행 상태. 트리의 부서 캐릭터와 대화 줄에 보인다.
enum ThinkActivity {
  idle('쉬는 중'),
  answering('답하는 중'),
  waiting('승인 대기'),
  coding('Cursor 작업 중'),
  consulting('협의 중');

  const ThinkActivity(this.label);
  final String label;

  bool get busy => this == answering || this == coding || this == consulting;
}

class ThinkDepartmentActivity {
  const ThinkDepartmentActivity(this.activity, {this.consultWith, this.count = 0});

  final ThinkActivity activity;

  /// 협의 중이면 상대 부서.
  final ThinkRoleId? consultWith;

  /// 승인 대기 제안 수 또는 진행 중인 Cursor 작업 수.
  final int count;

  String get label => switch (activity) {
        ThinkActivity.consulting => '↔ ${thinkWithJosa(consultWith?.label ?? '다른 부서', '과', '와')} 협의 중',
        ThinkActivity.waiting => '승인 대기 $count',
        ThinkActivity.coding => count > 1 ? 'Cursor 작업 $count' : 'Cursor 작업 중',
        _ => activity.label,
      };
}

enum ThinkMemoryScope {
  legacyUnscoped('legacy_unscoped', '공통(레거시)'),
  common('common', '공통'),
  department('department', '부서');

  const ThinkMemoryScope(this.db, this.label);
  final String db;
  final String label;

  static ThinkMemoryScope parse(String? raw) =>
      values.firstWhere((s) => s.db == raw, orElse: () => ThinkMemoryScope.legacyUnscoped);
}

enum ThinkDepartmentId {
  education('education', '교육'),
  product('product', '문제 풀이'),
  engineering('engineering', '개발');

  const ThinkDepartmentId(this.db, this.label);
  final String db;
  final String label;

  static ThinkDepartmentId? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    for (final d in values) {
      if (d.db == raw) return d;
    }
    return null;
  }
}

class ThinkConversationRoleSettings {
  const ThinkConversationRoleSettings({
    this.thinkRoleId = ThinkRoleId.lead,
    this.extraRefDepartments = const [],
    this.roleProfileVersion,
    this.roleColumns = false,
  });

  final ThinkRoleId thinkRoleId;
  final List<ThinkDepartmentId> extraRefDepartments;
  final String? roleProfileVersion;
  final bool roleColumns;

  factory ThinkConversationRoleSettings.fromRow(Map<String, dynamic> r) {
    final refs = _strList(r['extra_ref_departments']);
    return ThinkConversationRoleSettings(
      thinkRoleId: ThinkRoleId.parse(r['think_role_id']?.toString()),
      extraRefDepartments: refs.map((e) => ThinkDepartmentId.parse(e)).whereType<ThinkDepartmentId>().toList(),
      roleProfileVersion: _str(r['role_profile_version']).isEmpty ? null : _str(r['role_profile_version']),
      roleColumns: r.containsKey('think_role_id'),
    );
  }
}

class ThinkMessageMaterialRef {
  const ThinkMessageMaterialRef({
    required this.kind,
    required this.id,
    this.title,
    this.delivered = true,
    this.truncated = false,
  });

  final String kind;
  final String id;
  final String? title;
  final bool delivered;

  /// 문서 본문을 예산 때문에 앞부분만 보냈다.
  final bool truncated;

  bool get isDocument => kind == 'document';

  factory ThinkMessageMaterialRef.fromJson(Map<String, dynamic> j) => ThinkMessageMaterialRef(
        kind: _str(j['kind']),
        id: _str(j['id']),
        title: _str(j['title']).isEmpty ? null : _str(j['title']),
        delivered: j['delivered'] != false,
        truncated: j['truncated'] == true,
      );
}

class ThinkMessageContextSnapshot {
  const ThinkMessageContextSnapshot({
    required this.messageId,
    required this.thinkRoleId,
    this.roleProfileVersion,
    this.materials = const [],
  });

  final String messageId;
  final ThinkRoleId thinkRoleId;
  final String? roleProfileVersion;
  final List<ThinkMessageMaterialRef> materials;

  factory ThinkMessageContextSnapshot.fromRow(Map<String, dynamic> r) {
    final mats = _mapList(r['materials']).map(ThinkMessageMaterialRef.fromJson).where((m) => m.delivered).toList();
    return ThinkMessageContextSnapshot(
      messageId: _str(r['message_id']),
      thinkRoleId: ThinkRoleId.parse(r['think_role_id']?.toString()),
      roleProfileVersion: _str(r['role_profile_version']).isEmpty ? null : _str(r['role_profile_version']),
      materials: mats,
    );
  }
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
    this.markedImportant = false,
    this.sourceMessageId,
    this.askedBy,
    this.relay,
  });

  String? id;
  final String role;
  String content;
  ThinkMessageStatus status;
  List<ThinkAttachment> attachments;
  List<ThinkSource> sources;
  List<ThinkToolTrace> toolCalls;
  String? commentary;
  String? model;
  final DateTime? createdAt;
  String? errorText;

  /// 기록과 트리에는 남지만 AI가 읽는 대화 기록·결정 초안·스펙에서는 빠진다.
  bool contextExcluded;

  /// 화면에서 눈여겨볼 메시지 표시. AI 지시나 원칙이 아니다(자동 정리 제안, 2026-10-12).
  bool markedImportant;

  /// 대화를 나눌 때 복사해 온 원본 메시지.
  final String? sourceMessageId;

  /// 운영자 대신 Cursor가 보낸 질문. cursor_ide(운영자 PC 작업창) 또는 cursor_worker(작업자).
  final String? askedBy;

  /// 커서 문의에 대한 답변의 판정.
  final ThinkRelayVerdict? relay;

  bool get isUser => role == 'user';

  String? get askedByLabel => switch (askedBy) {
        'cursor_ide' => '커서가 물음',
        'cursor_worker' => '작업자 커서가 물음',
        _ => null,
      };

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
        markedImportant: r['marked_important'] == true,
        sourceMessageId: _str(r['source_message_id']).isEmpty ? null : _str(r['source_message_id']),
        askedBy: _str(r['asked_by']).isEmpty ? null : _str(r['asked_by']),
        relay: ThinkRelayVerdict.fromJson(r['relay']),
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
  excerpt('excerpt'),
  document('document');

  const ThinkTreeKind(this.db);
  final String db;

  static ThinkTreeKind parse(String raw) => values.firstWhere((k) => k.db == raw, orElse: () => ThinkTreeKind.folder);
}

/// 대화 정리 트리의 노드. 폴더(주제), 대화 배치, 발췌(요약), 종합 문서(본문+출처) 중 하나.
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
    this.body,
    this.conversationId,
    this.createdVia = 'user',
    this.sourceMessageIds = const [],
    this.createdAt,
    this.updatedAt,
    this.department,
  });

  final String id;
  final String? parentId;
  final ThinkTreeKind kind;

  /// 폴더의 부서. 폴더가 아니거나 부서 마이그레이션 전 DB면 null.
  final ThinkRoleId? department;
  final String title;
  final String? summary;
  final String? body;
  final int sortOrder;
  final String? conversationId;
  final String createdVia;
  final int version;
  final List<String> sourceMessageIds;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isFolder => kind == ThinkTreeKind.folder;

  factory ThinkTreeNode.fromRow(Map<String, dynamic> r) {
    final sources = _mapList(r['ai_tree_node_sources'])
      ..sort((a, b) {
        final o = ((a['sort_order'] as num?)?.toInt() ?? 0).compareTo((b['sort_order'] as num?)?.toInt() ?? 0);
        if (o != 0) return o;
        return _str(a['message_id']).compareTo(_str(b['message_id']));
      });
    return ThinkTreeNode(
      id: _str(r['id']),
      parentId: r['parent_id'] as String?,
      kind: ThinkTreeKind.parse(_str(r['kind'])),
      title: _str(r['title']),
      summary: _str(r['summary']).trim().isEmpty ? null : _str(r['summary']).trim(),
      body: _str(r['body']).trim().isEmpty ? null : _str(r['body']).trim(),
      sortOrder: (r['sort_order'] as num?)?.toInt() ?? 0,
      conversationId: r['conversation_id'] as String?,
      createdVia: _str(r['created_via']).isEmpty ? 'user' : _str(r['created_via']),
      version: (r['version'] as num?)?.toInt() ?? 1,
      sourceMessageIds: sources.map((s) => _str(s['message_id'])).where((s) => s.isNotEmpty).toList(),
      createdAt: _date(r['created_at']),
      updatedAt: _date(r['updated_at']),
      department: r['department'] is String ? ThinkRoleId.parse(r['department'] as String) : null,
    );
  }
}

class ThinkDocumentDetail {
  const ThinkDocumentDetail({
    required this.id,
    required this.title,
    required this.body,
    required this.version,
    required this.conversationId,
    this.parentId,
    this.sourceMessageIds = const [],
  });

  final String id;
  final String title;
  final String body;
  final int version;
  final String conversationId;
  final String? parentId;
  final List<String> sourceMessageIds;

  factory ThinkDocumentDetail.fromRow(Map<String, dynamic> r) => ThinkDocumentDetail(
        id: _str(r['id']),
        title: _str(r['title']),
        body: _str(r['body']),
        version: (r['version'] as num?)?.toInt() ?? 1,
        conversationId: _str(r['conversation_id']),
        parentId: r['parent_id'] as String?,
        sourceMessageIds: _strList(r['source_message_ids']),
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

  static ThinkMemoryKind parse(String raw) => values.firstWhere((k) => k.db == raw, orElse: () => ThinkMemoryKind.note);
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
    this.memoryScope = ThinkMemoryScope.legacyUnscoped,
    this.scopeDepartment,
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
  final ThinkMemoryScope memoryScope;
  final ThinkDepartmentId? scopeDepartment;

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
        memoryScope: ThinkMemoryScope.parse(r['memory_scope']?.toString()),
        scopeDepartment: ThinkDepartmentId.parse(r['scope_department']?.toString()),
      );

  String get scopeLabel =>
      memoryScope == ThinkMemoryScope.department ? '${scopeDepartment?.label ?? '?'} 부서' : memoryScope.label;
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
    this.memoryScope = ThinkMemoryScope.common,
    this.scopeDepartment,
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
  ThinkMemoryScope memoryScope;
  ThinkDepartmentId? scopeDepartment;

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
        memoryScope: m.memoryScope,
        scopeDepartment: m.scopeDepartment,
      );

  /// 부서 범위인데 부서를 고르지 않았으면 안내 문구. 저장 전에 확인한다.
  String? get scopeError =>
      memoryScope == ThinkMemoryScope.department && scopeDepartment == null ? '부서 범위는 부서를 골라야 합니다.' : null;

  /// [withScope]: 역할 기능이 준비된 DB에만 범위 열을 보낸다(마이그레이션 전 DB는 열이 없어 저장이 실패한다).
  /// 보내지 않으면 새 기억은 DB 기본값(레거시 공통)이 되고, 수정은 기존 범위를 그대로 둔다.
  Map<String, dynamic> toRow({bool withScope = false}) {
    final isDecision = kind == ThinkMemoryKind.decision;
    String? nullIfBlank(String v) => v.trim().isEmpty ? null : v.trim();
    return {
      'kind': kind.db,
      'status': status.db,
      'title': title.trim(),
      'content': content.trim(),
      'decision_context': isDecision ? nullIfBlank(decisionContext) : null,
      'decision_reason': isDecision ? nullIfBlank(decisionReason) : null,
      'alternatives': isDecision ? alternatives.map((e) => e.trim()).where((e) => e.isNotEmpty).toList() : <String>[],
      'tags': tags.map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
      'sort_order': sortOrder,
      'source_conversation_id': sourceConversationId,
      'supersedes_id': supersedesId,
      if (withScope) ...{
        'memory_scope': memoryScope.db,
        'scope_department': memoryScope == ThinkMemoryScope.department ? scopeDepartment?.db : null,
      },
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
        snapshot: r['snapshot'] is Map ? Map<String, dynamic>.from(r['snapshot'] as Map) : const {},
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

/// 문서·RPC probe 결과. 조회 성공만으로 생성·수정까지 ‘사용 가능’으로 표시하지 않는다.
enum ThinkProbeOutcome {
  confirmed('확인됨'),
  missing('없음'),
  permissionDenied('권한 없음'),
  failed('실패'),
  partial('부분 확인'),
  unknown('확인 불가'),
  notRun('미실행');

  const ThinkProbeOutcome(this.label);
  final String label;
}

class ThinkDocumentProbe {
  const ThinkDocumentProbe({
    required this.bodyColumn,
    required this.getDocumentRpc,
    required this.createRpc,
    this.detail = const {},
  });

  final ThinkProbeOutcome bodyColumn;
  final ThinkProbeOutcome getDocumentRpc;
  final ThinkProbeOutcome createRpc;
  final Map<String, String> detail;

  bool get anyConfirmed =>
      bodyColumn == ThinkProbeOutcome.confirmed ||
      getDocumentRpc == ThinkProbeOutcome.confirmed ||
      createRpc == ThinkProbeOutcome.confirmed;
}

/// 서버(ai_think)가 요청마다 Edge·DB·앱 버전과 권한으로 계산한 기능 상태. 앱은 보여 주기만 하고,
/// Think에 도구를 줄지는 서버가 정한다.
enum ThinkFeatureState {
  ready('ready'),
  dbRequired('db_required'),
  appUpdateRequired('app_update_required'),
  unknown('unknown'),

  /// 응답에 기능 상태가 없다. 연결된 ai_think가 이 기능 전 버전이다.
  edgeMissing('');

  const ThinkFeatureState(this.db);
  final String db;

  static ThinkFeatureState parse(String? raw) =>
      values.firstWhere((s) => s != edgeMissing && s.db == raw, orElse: () => ThinkFeatureState.unknown);
}

class ThinkFeatureStatus {
  const ThinkFeatureStatus({required this.state, this.edge = 0, this.db, this.app = 0});

  static const ThinkFeatureStatus edgeMissing = ThinkFeatureStatus(state: ThinkFeatureState.edgeMissing);

  final ThinkFeatureState state;
  final int edge;

  /// DB에 반영된 버전. 서버가 확인하지 못했으면 null.
  final int? db;
  final int app;

  bool get ready => state == ThinkFeatureState.ready;

  factory ThinkFeatureStatus.fromJson(Map<String, dynamic> j) => ThinkFeatureStatus(
        state: ThinkFeatureState.parse(j['state']?.toString()),
        edge: (j['edge'] as num?)?.toInt() ?? 0,
        db: (j['db'] as num?)?.toInt(),
        app: (j['app'] as num?)?.toInt() ?? 0,
      );
}

Map<String, ThinkFeatureStatus> parseThinkFeatures(dynamic raw) => raw is Map
    ? {
        for (final e in raw.entries)
          if (e.value is Map) e.key.toString(): ThinkFeatureStatus.fromJson(Map<String, dynamic>.from(e.value as Map)),
      }
    : const {};

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
    this.promptVersion = '',
    this.features = const {},
    this.featuresDbError,
    this.capabilities = const {},
  });

  final bool configured;
  final String provider;
  final Map<String, String> models;
  final bool webSearchEnabled;
  final double? budgetLimitUsd;
  final String budgetMode;
  final double spentUsd;
  final bool budgetExceeded;
  final String promptVersion;
  final Map<String, ThinkFeatureStatus> features;

  /// 서버가 DB 기능 확인에 실패한 이유(함수 없음은 제외). 비밀값은 들어 있지 않다.
  final String? featuresDbError;

  /// DB·앱 버전과 무관한 Edge 기능 버전(예: concept_reference). 없으면 옛 Edge다.
  final Map<String, int> capabilities;

  /// 개념 탭 참고(concept_id로 저장본 다시 읽기)를 아는 Edge다. 옛 Edge는 concept_id를 말없이 버린다.
  bool get conceptReference => (capabilities['concept_reference'] ?? 0) >= 1;

  /// 개념 상세에서 고른 서술(statement_id)도 다시 읽는 Edge다. 옛 Edge는 statement_id를 버리고 개념 본문만 읽는다.
  bool get conceptStatementReference => (capabilities['concept_reference'] ?? 0) >= 3;

  /// 개념 탭 정리 기준 참고(criterion_id로 확정본·초안 다시 읽기)를 아는 Edge다.
  bool get criterionReference => (capabilities['criterion_reference'] ?? 0) >= 1;

  /// 개념 초안 검토 창 대화(draft_id로 초안 저장본 다시 읽기·변경 카드)를 아는 Edge다.
  bool get conceptDraftReference => (capabilities['concept_draft_reference'] ?? 0) >= 1;

  /// 응답에 없으면 연결된 Edge가 이 기능을 모르는 버전이다.
  ThinkFeatureStatus get conversationSplit => features['conversation_split'] ?? ThinkFeatureStatus.edgeMissing;

  ThinkFeatureStatus get thinkRoles => features['think_roles'] ?? ThinkFeatureStatus.edgeMissing;

  ThinkFeatureStatus get memoryProposals => features['memory_proposals'] ?? ThinkFeatureStatus.edgeMissing;

  ThinkFeatureStatus get departmentWork => features['department_work'] ?? ThinkFeatureStatus.edgeMissing;

  ThinkFeatureStatus get autoOrganize => features['auto_organize'] ?? ThinkFeatureStatus.edgeMissing;

  ThinkStatus withFeatures(Map<String, ThinkFeatureStatus> next) => ThinkStatus(
        configured: configured,
        provider: provider,
        models: models,
        webSearchEnabled: webSearchEnabled,
        budgetLimitUsd: budgetLimitUsd,
        budgetMode: budgetMode,
        spentUsd: spentUsd,
        budgetExceeded: budgetExceeded,
        promptVersion: promptVersion,
        features: next,
        featuresDbError: featuresDbError,
        capabilities: capabilities,
      );

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
      promptVersion: _str(j['prompt_version']),
      features: parseThinkFeatures(j['features']),
      featuresDbError: _str(j['features_db_error']).isEmpty ? null : _str(j['features_db_error']),
      capabilities: j['capabilities'] is Map
          ? {
              for (final e in (j['capabilities'] as Map).entries)
                if (e.value is num) e.key.toString(): (e.value as num).toInt(),
            }
          : const {},
    );
  }
}

class ThinkMemoryFeedbackCandidate {
  ThinkMemoryFeedbackCandidate({
    required this.kind,
    required this.title,
    required this.content,
    this.decisionContext = '',
    this.decisionReason = '',
    List<String>? alternatives,
    List<String>? tags,
    this.updateMemoryId,
  })  : alternatives = alternatives ?? [],
        tags = tags ?? [];

  ThinkMemoryKind kind;
  String title;
  String content;
  String decisionContext;
  String decisionReason;
  List<String> alternatives;
  List<String> tags;
  String? updateMemoryId;

  factory ThinkMemoryFeedbackCandidate.fromJson(Map<String, dynamic> j) => ThinkMemoryFeedbackCandidate(
        kind: ThinkMemoryKind.parse(_str(j['kind'])),
        title: _str(j['title']),
        content: _str(j['content']),
        decisionContext: _str(j['decision_context']),
        decisionReason: _str(j['decision_reason']),
        alternatives: _strList(j['alternatives']),
        tags: _strList(j['tags']),
        updateMemoryId: j['update_memory_id']?.toString(),
      );
}

class ThinkMemoryFeedbackDuplicate {
  const ThinkMemoryFeedbackDuplicate({
    required this.candidateIndex,
    required this.memoryId,
    required this.memoryTitle,
    required this.reason,
  });

  final int candidateIndex;
  final String memoryId;
  final String memoryTitle;
  final String reason;

  factory ThinkMemoryFeedbackDuplicate.fromJson(Map<String, dynamic> j) => ThinkMemoryFeedbackDuplicate(
        candidateIndex: (j['candidate_index'] as num?)?.toInt() ?? 0,
        memoryId: _str(j['memory_id']),
        memoryTitle: _str(j['memory_title']),
        reason: _str(j['reason']),
      );
}

class ThinkMemoryFeedbackUpdateBaseline {
  const ThinkMemoryFeedbackUpdateBaseline({required this.memoryId, required this.version});

  final String memoryId;
  final int version;

  factory ThinkMemoryFeedbackUpdateBaseline.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const ThinkMemoryFeedbackUpdateBaseline(memoryId: '', version: 0);
    return ThinkMemoryFeedbackUpdateBaseline(
      memoryId: _str(j['memory_id']),
      version: (j['version'] as num?)?.toInt() ?? 0,
    );
  }

  bool get isValid => memoryId.isNotEmpty && version > 0;
}

class ThinkMemoryFeedbackDraftResult {
  const ThinkMemoryFeedbackDraftResult({required this.draft, this.updateBaseline});

  final ThinkMemoryFeedbackDraft draft;
  final ThinkMemoryFeedbackUpdateBaseline? updateBaseline;
}

class ThinkMemoryFeedbackDraft {
  const ThinkMemoryFeedbackDraft({
    required this.candidates,
    required this.duplicateWarnings,
    required this.insufficientEvidence,
    required this.notes,
  });

  final List<ThinkMemoryFeedbackCandidate> candidates;
  final List<ThinkMemoryFeedbackDuplicate> duplicateWarnings;
  final bool insufficientEvidence;
  final String notes;

  factory ThinkMemoryFeedbackDraft.fromJson(Map<String, dynamic> j) => ThinkMemoryFeedbackDraft(
        candidates: _mapList(j['candidates']).map(ThinkMemoryFeedbackCandidate.fromJson).toList(),
        duplicateWarnings: _mapList(j['duplicate_warnings']).map(ThinkMemoryFeedbackDuplicate.fromJson).toList(),
        insufficientEvidence: j['insufficient_evidence'] == true,
        notes: _str(j['notes']),
      );
}

class ThinkSettings {
  const ThinkSettings({
    this.monthlyBudgetUsd,
    this.budgetMode = 'warn',
    this.webSearchEnabled = true,
    this.codeRequestDailyLimit = 10,
    this.autoOrganizeEnabled = true,
    this.autoOrganizeColumn = false,
  });

  final double? monthlyBudgetUsd;
  final String budgetMode;
  final bool webSearchEnabled;
  final int codeRequestDailyLimit;

  /// 자동 정리 제안. 끄면 사용자가 직접 정리를 요청할 때만 Think가 분류·기억·정리 제안을 한다.
  final bool autoOrganizeEnabled;

  /// DB에 자동 정리 설정 열이 있다(마이그레이션 반영). 없으면 켜기·끄기를 보여 주지 않는다.
  final bool autoOrganizeColumn;

  factory ThinkSettings.fromRow(Map<String, dynamic>? r) => r == null
      ? const ThinkSettings()
      : ThinkSettings(
          monthlyBudgetUsd: r['monthly_budget_usd'] == null ? null : _num(r['monthly_budget_usd']),
          budgetMode: _str(r['budget_mode']) == 'block' ? 'block' : 'warn',
          webSearchEnabled: r['web_search_enabled'] != false,
          codeRequestDailyLimit:
              r['code_request_daily_limit'] == null ? 10 : _num(r['code_request_daily_limit']).toInt(),
          autoOrganizeEnabled: r['auto_organize_enabled'] != false,
          autoOrganizeColumn: r.containsKey('auto_organize_enabled'),
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
  'think_relay': '커서 문의 답변',
  'think_title': '대화 제목',
  'decision_draft': '결정 초안',
  'memory_feedback_draft': '답변 피드백 기억 초안',
  'spec_export': '스펙 내보내기',
  'memo_summarize': '메모 요약',
  'memo_summarize_sentence': '메모 한 문장 요약',
  'memo_extract_datetime': '메모 일정 추출',
  'memo_extract_phone': '메모 연락처 추출',
  'memo_extract_name': '메모 이름 추출',
  'trait_report': '성향 리포트',
  'code_request': '코드 조사 (Cursor)',
};
