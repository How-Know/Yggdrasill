// Think 채팅의 작업 제안(ai_actions). AI는 제안만 남기고, 실행은 사람이 승인할 때 서버 RPC가 한다.
// 설계: docs/architecture/ai-think-actions.md

import 'think_models.dart';

enum ThinkActionKind {
  codeRequest('code_request', '코드 조사'),
  codeChange('code_change', '코드 수정'),

  /// Think가 승인 없이 시작한 Cursor 조율(읽기 전용). 처음부터 applied로 남고 카드는 요청 진행을 보여 준다.
  codePlan('code_plan', 'Cursor와 조율'),
  placeConversation('place_conversation', '대화 분류'),
  deleteCodeRequest('delete_code_request', '코드 요청 삭제'),
  deleteFolder('delete_folder', '폴더 삭제'),
  deleteConversation('delete_conversation', '대화 삭제'),

  /// 승인하면 이번 질문과 답변만 새 대화에 복사하고 새 대화로 넘어간다. 원본은 그대로 둔다.
  splitConversation('split_conversation', '대화 나누기'),

  /// Think가 확정된 결론·원칙을 기억으로 남기자고 낸 카드. 승인하면 바로 확정 기억(active)이 된다.
  /// 기억 카드는 서로 대체하지 않고, 사용자가 처리할 때까지 대기한다.
  saveMemory('save_memory', '기억 저장'),

  /// 대기 중인 기억 저장 카드를 수정·대체·삭제하자는 카드. 승인 전에는 대상 카드가 그대로다.
  memoryCardChange('memory_card_change', '기억 카드 변경'),

  /// Think가 이 대화를 다른 부서가 맡자고 제안. 승인하면 대화 역할이 바뀌고 그 부서의 미분류로 옮겨진다.
  handoverDepartment('handover_department', '부서 넘기기'),

  /// 정정·폐기된 메시지를 이후 답변 맥락에서 빼자는 제안. 메시지는 지우지 않고, 되돌릴 수 있다.
  excludeContext('exclude_context', '맥락 제외'),

  /// 중요한 결정·할 일·미결 문제가 나온 메시지에 표시하자는 제안. 화면 표시일 뿐 AI 지시가 아니다.
  markImportant('mark_important', '중요 표시'),

  /// 이 대화의 진행 요약(목적·확정·미결·상태·다음 행동). 승인해도 작업이 시작되지 않는다.
  progressSummary('progress_summary', '진행 요약'),

  /// 부서 기준(먼저 확인할 질문·위험·우선 기억)을 바꾸자는 제안.
  departmentCriteriaChange('department_criteria_change', '부서 기준'),

  /// 개념 초안 검토 대화의 카드. 승인은 검토 창에서 한다(concept_draft_action_apply·다시 정리는 Edge).
  conceptDraftChange('concept_draft_change', '개념 초안 변경'),
  conceptCriterionChange('concept_criterion_change', '정리 기준 고치기'),
  conceptDraftRerun('concept_draft_rerun', '다시 정리'),

  /// 과정 탐색도·개념 라이브러리 카드. 승인은 course_think_action_apply 한 번이고, 항목 카드는 고른 항목만 반영한다.
  /// 설계: docs/architecture/course-map.md "Think 카드"
  courseMapChange('course_map_change', '과정 탐색도 고치기'),
  courseMapCreate('course_map_create', '새 과정'),
  conceptPlacementChange('concept_placement_change', '개념 배치'),
  conceptLibraryChange('concept_library_change', '개념 고치기'),

  /// 범위별 개념 검토 기록. 승인하면 기록만 남고 개념 본문·폴더·관계는 바뀌지 않는다.
  /// 설계: docs/architecture/concept-library.md "범위별 개념 검토"
  conceptReviewRecord('concept_review_record', '개념 검토 기록'),

  /// 개념 관계 넣기·바꾸기·빼기. 승인한 항목만 반영하고, 빼기는 관계만 지운다(개념은 그대로).
  /// 설계: docs/architecture/concept-library.md "관계 유형"
  conceptRelationChange('concept_relation_change', '개념 관계 고치기');

  const ThinkActionKind(this.db, this.label);
  final String db;
  final String label;

  static ThinkActionKind? parse(String? raw) {
    for (final k in values) {
      if (k.db == raw) return k;
    }
    return null;
  }

  bool get isCode => this == codeRequest || this == codeChange || this == codePlan;
  bool get isDelete => this == deleteCodeRequest || this == deleteFolder || this == deleteConversation;
  bool get isMemory => this == saveMemory || this == memoryCardChange;
  bool get isConceptDraft => this == conceptDraftChange || this == conceptCriterionChange || this == conceptDraftRerun;
  bool get isCourseThink =>
      this == courseMapChange ||
      this == courseMapCreate ||
      this == conceptPlacementChange ||
      this == conceptLibraryChange ||
      this == conceptReviewRecord ||
      this == conceptRelationChange;

  /// 항목마다 빼고 고를 수 있는 카드.
  bool get hasItems =>
      this == conceptPlacementChange ||
      this == conceptLibraryChange ||
      this == conceptReviewRecord ||
      this == conceptRelationChange;

  /// 정리 패널에 모이는 제안. 코드·삭제 제안은 각자 카드로만 처리한다. Edge `ORGANIZE_KINDS`와 같다.
  bool get isOrganize => switch (this) {
        placeConversation ||
        splitConversation ||
        saveMemory ||
        memoryCardChange ||
        handoverDepartment ||
        excludeContext ||
        markImportant ||
        progressSummary ||
        departmentCriteriaChange =>
          true,
        _ => false,
      };

  /// 자동 정리 기능과 함께 생긴 종류. 그 기능이 있는 서버만 만든다.
  bool get isOrganizeOnly =>
      this == excludeContext || this == markImportant || this == progressSummary || this == departmentCriteriaChange;

  /// 승인 뒤 되돌릴 수 있는 종류(서버 ai_action_undo).
  bool get isUndoable => this == placeConversation || this == excludeContext || this == markImportant;
}

enum ThinkActionStatus {
  proposed('proposed', '승인 대기'),
  applied('applied', '실행함'),
  rejected('rejected', '거절함'),
  failed('failed', '실패'),
  undone('undone', '되돌림'),

  /// 제안 뒤 대화가 이어져(새 질문) 승인할 수 없다. 대화 나누기 제안만 쓴다.
  expired('expired', '만료됨');

  const ThinkActionStatus(this.db, this.label);
  final String db;
  final String label;

  static ThinkActionStatus parse(String? raw) =>
      values.firstWhere((s) => s.db == raw, orElse: () => ThinkActionStatus.proposed);
}

String _str(dynamic v) => v == null ? '' : v.toString().trim();

Map<String, dynamic> _map(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

DateTime? _date(dynamic v) => v is String && v.isNotEmpty ? DateTime.tryParse(v)?.toLocal() : null;

class ThinkAction {
  const ThinkAction({
    required this.id,
    required this.conversationId,
    required this.kind,
    required this.status,
    required this.createdAt,
    this.messageId,
    this.payload = const {},
    this.preview = const {},
    this.result,
    this.error,
    this.superseded = false,
    this.decidedAt,
  });

  final String id;
  final String conversationId;

  /// 제안을 낸 답변. 답변이 저장되기 전(스트리밍 중)에는 null이다.
  final String? messageId;
  final ThinkActionKind kind;
  final ThinkActionStatus status;
  final Map<String, dynamic> payload;

  /// 서버가 제안 때 만든 요약. 카드는 이것만 보여 준다(원본 대상은 승인 시 서버가 다시 확인한다).
  final Map<String, dynamic> preview;
  final Map<String, dynamic>? result;
  final String? error;

  /// 같은 대화에서 같은 종류의 새 제안이 나와 닫혔다.
  final bool superseded;
  final DateTime createdAt;
  final DateTime? decidedAt;

  static const String columns =
      'id,conversation_id,message_id,kind,status,payload,preview,result,error,superseded,decided_at,created_at';

  /// 알 수 없는 kind(서버가 먼저 배포된 경우)는 null.
  static ThinkAction? fromRow(Map<String, dynamic> r) {
    final kind = ThinkActionKind.parse(r['kind']?.toString());
    if (kind == null) return null;
    final message = _str(r['message_id']);
    final error = _str(r['error']);
    return ThinkAction(
      id: _str(r['id']),
      conversationId: _str(r['conversation_id']),
      messageId: message.isEmpty ? null : message,
      kind: kind,
      status: ThinkActionStatus.parse(r['status']?.toString()),
      payload: _map(r['payload']),
      preview: _map(r['preview']),
      result: r['result'] is Map ? Map<String, dynamic>.from(r['result'] as Map) : null,
      error: error.isEmpty ? null : error,
      superseded: r['superseded'] == true,
      createdAt: _date(r['created_at']) ?? DateTime.now(),
      decidedAt: _date(r['decided_at']),
    );
  }

  ThinkAction copyWith({String? messageId, ThinkActionStatus? status, bool? superseded}) => ThinkAction(
        id: id,
        conversationId: conversationId,
        messageId: messageId ?? this.messageId,
        kind: kind,
        status: status ?? this.status,
        payload: payload,
        preview: preview,
        result: result,
        error: error,
        superseded: superseded ?? this.superseded,
        createdAt: createdAt,
        decidedAt: decidedAt,
      );

  bool get pending => status == ThinkActionStatus.proposed;

  String get title => _str(preview['title'] ?? payload['title']);

  /// 코드 제안을 승인하면 만들어진 요청.
  String? get codeRequestId {
    final id = _str(result?['code_request_id']);
    return id.isEmpty ? null : id;
  }

  // ---- 대화 분류
  String? get folderId {
    final id = _str(payload['folder_id']);
    return id.isEmpty ? null : id;
  }

  String? get newFolderTitle {
    final t = _str(payload['new_folder_title']);
    return t.isEmpty ? null : t;
  }

  String? get newFolderParentId {
    final id = _str(payload['new_folder_parent_id']);
    return id.isEmpty ? null : id;
  }

  /// 승인 뒤 실제로 넣은 폴더(다른 폴더를 고른 경우 포함).
  String? get placedFolderId {
    final id = _str(result?['folder_id']);
    return id.isEmpty ? null : id;
  }

  // ---- 삭제
  String? get targetId {
    final id = _str(payload['target_id']);
    return id.isEmpty ? null : id;
  }

  bool get deletedSelf => result?['deleted_self'] == true;

  // ---- 대화 나누기
  ThinkSplitSummary get splitSummary => ThinkSplitSummary.fromJson(payload['summary']);

  String get splitReason => _str(payload['reason'] ?? preview['reason']);

  /// 나누기 시작 메시지(이번 질문)의 앞부분. 서버가 제안 때 저장한 메시지에서 만든다.
  String get splitStartPreview => _str(preview['start_preview']);

  /// 제안 때 폴더 경로. 폴더가 없어졌을 때 보여 준다.
  String get splitFolderPath => _str(preview['folder_path']);

  /// 승인으로 만든 새 대화.
  String? get splitConversationId {
    final id = _str(result?['conversation_id']);
    return id.isEmpty ? null : id;
  }

  // ---- 기억 저장 제안·기억 카드 변경
  /// 제안된 기억 내용. 변경 카드의 삭제(withdraw)면 비어 있다.
  ThinkMemoryProposal get memoryProposal => ThinkMemoryProposal.fromJson(payload['memory']);

  /// Think가 왜 지금 저장(변경)을 제안하는지.
  String get memoryReason => _str(payload['reason'] ?? preview['reason']);

  /// 비교 분류. 서버가 조회 기록으로 남긴 값이다.
  String get memoryRelation => _str(_map(payload['basis'])['relation']);

  String get memoryRelationLabel => switch (memoryRelation) {
        'duplicate' => '중복',
        'supplement' => '보완',
        'conflict' => '충돌',
        'distinct' => '별개',
        'hold' => '보류',
        'retire' => '내리기',
        _ => '',
      };

  /// 검색이 성공(결과 있음·0건)한 기록이 카드에 있다. 없으면 승인하지 않는다.
  bool get memoryBasisReady {
    final searches = _map(payload['basis'])['searches'];
    if (searches is! List || searches.isEmpty) return false;
    return searches.any((s) => s is Map && (s['status'] == 'ok' || s['status'] == 'empty'));
  }

  /// 비교에 쓴 원문 판. 지금 원문과 다를 수 있다.
  List<Map<String, dynamic>> get memoryBasisReads {
    final reads = _map(payload['basis'])['reads'];
    if (reads is! List) return const [];
    return reads.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Map<String, dynamic> get _memoryFlow => _map(payload['flow']);

  String get memoryFlowKey => _str(_memoryFlow['key']);

  int get memoryFlowStep => _memoryFlow['step'] is num ? (_memoryFlow['step'] as num).toInt() : 0;

  int get memoryFlowSteps => _memoryFlow['steps'] is num ? (_memoryFlow['steps'] as num).toInt() : 0;

  /// 확정 기억을 보관으로 내리는 제안. 행은 지우지 않는다.
  bool get memoryRetire => payload['op'] == 'retire' || preview['op'] == 'retire';

  /// 대체하려는 확정 기억의 제목. 서버가 제안 때 확인한 값이다.
  String get supersedesTitle => _str(preview['supersedes_title']);

  /// 승인으로 만든 확정 기억.
  String? get savedMemoryId {
    final id = _str(result?['memory_id']);
    return id.isEmpty ? null : id;
  }

  bool get memoryEdited => result?['edited'] == true;

  /// 변경 카드 승인으로 고쳐진 대기 카드.
  bool get memoryRevised => preview['revised'] == true;

  /// 삭제 제안 승인으로 닫혔다.
  bool get memoryWithdrawn => _str(result?['withdrawn_by_action_id']).isNotEmpty;

  /// 대체 제안 승인으로 닫히고 새 카드가 생겼다.
  bool get memoryReplaced => _str(result?['replaced_by_action_id']).isNotEmpty;

  /// revise / replace / withdraw
  String get memoryCardOp => _str(payload['op'] ?? preview['op']);

  String? get memoryTargetActionId {
    final id = _str(payload['target_action_id']);
    return id.isEmpty ? null : id;
  }

  String get memoryTargetTitle => _str(preview['target_title']);

  String? get memoryTargetConversationId {
    final id = _str(preview['target_conversation_id']);
    return id.isEmpty ? null : id;
  }

  /// 부서 넘기기: 받을 부서. payload를 먼저 본다(승인 때 서버가 쓰는 값).
  ThinkRoleId? get handoverTo {
    final raw = _str(payload['to_department']).isNotEmpty ? _str(payload['to_department']) : _str(preview['to_department']);
    return raw.isEmpty ? null : ThinkRoleId.parse(raw);
  }

  ThinkRoleId? get handoverFrom {
    final raw = _str(result?['from_department']).isNotEmpty ? _str(result?['from_department']) : _str(preview['from_department']);
    return raw.isEmpty ? null : ThinkRoleId.parse(raw);
  }

  String get handoverReason => _str(payload['reason']).isNotEmpty ? _str(payload['reason']) : _str(preview['reason']);

  /// 새 대화에 복사하지 않고 원본에만 남은 것의 수(actions, code_requests, tree_nodes, other_messages).
  Map<String, int> get splitNotCopied {
    final raw = _map(result?['not_copied']);
    return {
      for (final e in raw.entries)
        if (e.value is num) e.key: (e.value as num).toInt(),
    };
  }

  /// 분류 제안이 같은 답변의 부서 넘기기 뒤에 적용될 때 받을 부서.
  ThinkRoleId? get placeAfterHandover {
    final raw = _str(preview['after_handover']);
    return raw.isEmpty ? null : ThinkRoleId.parse(raw);
  }

  // ---- 정리 제안 공통
  /// Think가 왜 지금 이 정리를 제안하는지.
  String get organizeReason => _str(payload['reason']).isNotEmpty ? _str(payload['reason']) : _str(preview['reason']);

  // ---- 맥락 제외·중요 표시
  List<String> get organizeMessageIds => _ids(payload['message_ids']);

  /// 제안 때 서버가 확인한 대상 메시지(역할·발췌).
  List<ThinkOrganizeTarget> get organizeTargets =>
      (preview['targets'] is List ? preview['targets'] as List : const [])
          .whereType<Map>()
          .map((m) => ThinkOrganizeTarget.fromJson(Map<String, dynamic>.from(m)))
          .toList();

  /// 빼면 이후 답변이 무엇을 참고하지 않게 되는지.
  String get exclusionImpact => _str(payload['impact']).isNotEmpty ? _str(payload['impact']) : _str(preview['impact']);

  /// 대상 메시지에서 만든 발췌·종합 문서.
  List<ThinkOrganizeLink> get linkedDocuments => _links(_map(preview['linked'])['documents']);

  /// 대상 메시지에서 승인된 기억.
  List<ThinkOrganizeLink> get linkedMemories => _links(_map(preview['linked'])['memories']);

  /// 이 대화에 승인된 진행 요약이 있어, 빼도 요약에 내용이 남을 수 있다.
  bool get exclusionHasSummary => preview['has_summary'] == true || result?['summary_may_include'] == true;

  List<String> get excludedIds => _ids(result?['excluded_ids']);
  List<String> get markedIds => _ids(result?['marked_ids']);

  // ---- 진행 요약
  ThinkProgressSummary get progressSummaryProposal => ThinkProgressSummary.fromJson(payload['summary']);

  /// 제안 때 승인돼 있던 요약. 없으면 첫 요약.
  ThinkProgressSummary? get previousProgressSummary {
    final s = ThinkProgressSummary.fromJson(preview['previous']);
    return s.isEmpty ? null : s;
  }

  /// 제안 때 승인돼 있던 요약을 만든 제안. 지금 요약이 다른 제안에서 왔으면 승인이 충돌로 멈춘다.
  String? get progressSummaryBaseActionId {
    final raw = _str(payload['base_action_id']);
    return raw.isEmpty ? null : raw;
  }

  // ---- 부서 기준
  ThinkRoleId? get criteriaDepartment {
    final raw = _str(payload['department']).isNotEmpty ? _str(payload['department']) : _str(preview['department']);
    return raw.isEmpty ? null : ThinkRoleId.parse(raw);
  }

  ThinkCriteriaView get criteriaBefore => ThinkCriteriaView.fromJson(preview['before']);
  ThinkCriteriaView get criteriaAfter => ThinkCriteriaView.fromJson(preview['after']);

  /// 제안 때 기준의 판. 승인 시 판이 바뀌었으면 충돌로 멈춘다.
  int get criteriaBaseVersion => (payload['base_version'] as num?)?.toInt() ?? 0;

  /// 승인 때 고칠 수 있는 기준 원문(우선 기억은 id).
  Map<String, dynamic> get criteriaPayload => _map(payload['criteria']);

  // ---- 과정 탐색도·개념 배치·개념 고치기
  String? get courseId {
    final id = _str(payload['course_id']).isNotEmpty ? _str(payload['course_id']) : _str(result?['course_id']);
    return id.isEmpty ? null : id;
  }

  /// 미리보기 항목(i는 1부터). 승인 때 overrides.skip·units가 이 번호를 쓴다.
  List<Map<String, dynamic>> get courseItems => (preview['items'] is List ? preview['items'] as List : const [])
      .whereType<Map>()
      .map((m) => Map<String, dynamic>.from(m))
      .toList();

  /// 승인 결과의 항목별 상태(applied·skipped·failed). 번호 → 결과.
  Map<int, Map<String, dynamic>> get courseItemResults => {
        for (final m in (result?['items'] is List ? result!['items'] as List : const []).whereType<Map>())
          if ((m['i'] as num?) != null) (m['i'] as num).toInt(): Map<String, dynamic>.from(m),
      };

  int courseResultCount(String key) => (result?[key] as num?)?.toInt() ?? 0;

  static List<String> _ids(dynamic v) =>
      v is List ? v.map((e) => _str(e)).where((e) => e.isNotEmpty).toList() : const [];

  static List<ThinkOrganizeLink> _links(dynamic v) => v is List
      ? v.whereType<Map>().map((m) => ThinkOrganizeLink.fromJson(Map<String, dynamic>.from(m))).toList()
      : const [];
}

/// 정리 제안의 대상 메시지. 발췌는 제안 때 서버가 160자로 자른 것이다.
class ThinkOrganizeTarget {
  const ThinkOrganizeTarget({required this.id, required this.role, this.excerpt = '', this.createdAt});

  final String id;
  final String role;
  final String excerpt;
  final DateTime? createdAt;

  bool get isUser => role == 'user';

  factory ThinkOrganizeTarget.fromJson(Map<String, dynamic> j) => ThinkOrganizeTarget(
        id: _str(j['id']),
        role: _str(j['role']),
        excerpt: _str(j['excerpt']),
        createdAt: _date(j['created_at']),
      );
}

/// 맥락 제외 대상과 연결된 문서·기억(경고용).
class ThinkOrganizeLink {
  const ThinkOrganizeLink({required this.id, required this.title, this.kind = ''});

  final String id;
  final String title;
  final String kind;

  factory ThinkOrganizeLink.fromJson(Map<String, dynamic> j) =>
      ThinkOrganizeLink(id: _str(j['id']), title: _str(j['title']), kind: _str(j['kind']));
}

/// 일괄 승인 순서(서버 ai_action_apply_batch와 같다). 부서를 먼저 넘겨야 그 부서 폴더로 분류할 수 있다.
const List<ThinkActionKind> kThinkOrganizeOrder = [
  ThinkActionKind.handoverDepartment,
  ThinkActionKind.placeConversation,
  ThinkActionKind.excludeContext,
  ThinkActionKind.markImportant,
  ThinkActionKind.splitConversation,
  ThinkActionKind.saveMemory,
  ThinkActionKind.memoryCardChange,
  ThinkActionKind.progressSummary,
  ThinkActionKind.departmentCriteriaChange,
];

/// "기억 1건 저장 · 분류 완료"처럼 종류별로 묶은 처리 결과.
String thinkOrganizeSummary(Iterable<ThinkAction> applied) {
  final counts = <ThinkActionKind, int>{};
  final units = <ThinkActionKind, int>{};
  for (final a in applied) {
    counts[a.kind] = (counts[a.kind] ?? 0) + 1;
    units[a.kind] = (units[a.kind] ?? 0) +
        switch (a.kind) {
          ThinkActionKind.excludeContext => a.excludedIds.length,
          ThinkActionKind.markImportant => a.markedIds.length,
          _ => 1,
        };
  }
  final order = [...kThinkOrganizeOrder, ...ThinkActionKind.values.where((k) => !kThinkOrganizeOrder.contains(k))];
  return [
    for (final k in order)
      if (counts[k] case final n?)
        switch (k) {
          ThinkActionKind.handoverDepartment => '부서 넘기기 완료',
          ThinkActionKind.placeConversation => '분류 완료',
          ThinkActionKind.splitConversation => '대화 나누기 완료',
          ThinkActionKind.saveMemory => '기억 $n건 저장',
          ThinkActionKind.memoryCardChange => '기억 카드 $n건 정리',
          ThinkActionKind.excludeContext =>
            units[k] == 0 ? '맥락 제외(이미 빠져 있던 메시지)' : '메시지 ${units[k]}개 맥락에서 제외',
          ThinkActionKind.markImportant => units[k] == 0 ? '중요 표시(이미 표시된 메시지)' : '메시지 ${units[k]}개 중요 표시',
          ThinkActionKind.progressSummary => '진행 요약 저장',
          ThinkActionKind.departmentCriteriaChange => '부서 기준 변경',
          _ => '${k.label} $n건',
        },
  ].join(' · ');
}

/// 정리 패널 일괄 승인 한 번의 결과. 일부만 처리됐으면 [failed]를 함께 보여, 전부 된 것처럼 보이지 않게 한다.
class ThinkOrganizeOutcome {
  const ThinkOrganizeOutcome({this.applied = const [], this.failed = const [], this.error});

  /// 이번에 승인된 제안(재시도로 이미 승인돼 있던 것 포함).
  final List<ThinkAction> applied;

  /// 처리하지 못한 항목. 대기 상태로 남아 패널에 다시 보인다.
  final List<ThinkBatchItemResult> failed;

  /// 요청 자체가 실패했다. 아무것도 처리되지 않았다.
  final String? error;

  bool get partial => applied.isNotEmpty && failed.isNotEmpty;

  String get summary => thinkOrganizeSummary(applied);

  /// 이번에 나눠 만든 대화(열기 버튼).
  String? get splitConversationId {
    for (final a in applied) {
      final id = a.splitConversationId;
      if (id != null) return id;
    }
    return null;
  }
}

/// 일괄 승인(ai_action_apply_batch) 항목 하나의 결과. 실패한 항목만 다시 보여 준다.
class ThinkBatchItemResult {
  const ThinkBatchItemResult({required this.id, required this.ok, this.already = false, this.code, this.message, this.action});

  final String id;
  final bool ok;

  /// 이미 승인돼 있었다(네트워크 재시도 등). 다시 실행하지 않았다.
  final bool already;
  final String? code;
  final String? message;

  /// 처리 뒤 제안 상태. 실패해도 대기 상태 그대로 돌아온다.
  final ThinkAction? action;

  factory ThinkBatchItemResult.fromJson(Map<String, dynamic> j) {
    final code = _str(j['code']);
    final message = _str(j['message']);
    return ThinkBatchItemResult(
      id: _str(j['id']),
      ok: j['ok'] == true,
      already: j['already'] == true,
      code: code.isEmpty ? null : code,
      message: message.isEmpty ? null : message,
      action: j['action'] is Map ? ThinkAction.fromRow(Map<String, dynamic>.from(j['action'] as Map)) : null,
    );
  }
}

/// 기억 저장 카드의 내용. 승인할 때 고친 값은 [toJson]으로 overrides.memory에 실어 보낸다(서버가 다시 검사한다).
class ThinkMemoryProposal {
  const ThinkMemoryProposal({
    this.kind = 'decision',
    this.title = '',
    this.content = '',
    this.decisionContext = '',
    this.decisionReason = '',
    this.alternatives = const [],
    this.tags = const [],
    this.memoryScope = 'common',
    this.scopeDepartment,
    this.supersedesId,
  });

  /// decision / principle
  final String kind;
  final String title;
  final String content;
  final String decisionContext;
  final String decisionReason;
  final List<String> alternatives;
  final List<String> tags;

  /// common / department
  final String memoryScope;
  final String? scopeDepartment;
  final String? supersedesId;

  bool get isEmpty => title.isEmpty && content.isEmpty;
  bool get isDecision => kind == 'decision';
  String get kindLabel => isDecision ? '결정' : '원칙';

  static List<String> _list(dynamic v) =>
      v is List ? v.map((e) => _str(e)).where((e) => e.isNotEmpty).toList() : const [];

  factory ThinkMemoryProposal.fromJson(dynamic raw) {
    final m = _map(raw);
    final dept = _str(m['scope_department']);
    final sup = _str(m['supersedes_id']);
    return ThinkMemoryProposal(
      kind: _str(m['kind']) == 'principle' ? 'principle' : 'decision',
      title: _str(m['title']),
      content: _str(m['content']),
      decisionContext: _str(m['decision_context']),
      decisionReason: _str(m['decision_reason']),
      alternatives: _list(m['alternatives']),
      tags: _list(m['tags']),
      memoryScope: _str(m['memory_scope']) == 'department' ? 'department' : 'common',
      scopeDepartment: dept.isEmpty ? null : dept,
      supersedesId: sup.isEmpty ? null : sup,
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'title': title,
        'content': content,
        'decision_context': isDecision ? decisionContext : null,
        'decision_reason': isDecision ? decisionReason : null,
        'alternatives': isDecision ? alternatives : const <String>[],
        'tags': tags,
        'memory_scope': memoryScope,
        'scope_department': memoryScope == 'department' ? scopeDepartment : null,
        'supersedes_id': supersedesId,
      };

  ThinkMemoryProposal copyWith({
    String? kind,
    String? title,
    String? content,
    String? decisionContext,
    String? decisionReason,
    List<String>? alternatives,
    String? memoryScope,
    String? scopeDepartment,
    bool clearDepartment = false,
  }) =>
      ThinkMemoryProposal(
        kind: kind ?? this.kind,
        title: title ?? this.title,
        content: content ?? this.content,
        decisionContext: decisionContext ?? this.decisionContext,
        decisionReason: decisionReason ?? this.decisionReason,
        alternatives: alternatives ?? this.alternatives,
        tags: tags,
        memoryScope: memoryScope ?? this.memoryScope,
        scopeDepartment: clearDepartment ? null : (scopeDepartment ?? this.scopeDepartment),
        supersedesId: supersedesId,
      );
}
