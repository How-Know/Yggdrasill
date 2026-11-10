import 'package:supabase_flutter/supabase_flutter.dart';

import 'textbook_problem_review_service.dart';

/// 소단원 하나에서 돌릴 본문(문제은행) 추출 런.
class TextbookWorkflowExtractRun {
  const TextbookWorkflowExtractRun({
    required this.subKey,
    this.subIndex = 0,
    this.subName = '',
    this.rawPageFrom,
    this.rawPageTo,
    this.displayPageFrom,
    this.displayPageTo,
  });

  factory TextbookWorkflowExtractRun.fromJson(Map<String, dynamic> m) => TextbookWorkflowExtractRun(
        subKey: '${m['sub_key'] ?? ''}',
        subIndex: _int(m['sub_index']) ?? 0,
        subName: '${m['sub_name'] ?? ''}',
        rawPageFrom: _int(m['raw_page_from']),
        rawPageTo: _int(m['raw_page_to']),
        displayPageFrom: _int(m['display_page_from']),
        displayPageTo: _int(m['display_page_to']),
      );

  final String subKey;
  final int subIndex;
  final String subName;
  final int? rawPageFrom;
  final int? rawPageTo;
  final int? displayPageFrom;
  final int? displayPageTo;

  Map<String, dynamic> toJson() => {
        'sub_key': subKey,
        'sub_index': subIndex,
        'sub_name': subName,
        'raw_page_from': rawPageFrom,
        'raw_page_to': rawPageTo,
        'display_page_from': displayPageFrom,
        'display_page_to': displayPageTo,
      };
}

/// 소단원 하나에서 정답·해설 위치를 찾을 범위(sub_key 단위).
class TextbookWorkflowStageRun {
  const TextbookWorkflowStageRun({
    required this.subKey,
    this.subIndex = 0,
    this.answerStartPage,
    this.answerEndPage,
    this.solutionStartPage,
    this.solutionEndPage,
    this.bodyPageFrom,
    this.bodyPageTo,
  });

  factory TextbookWorkflowStageRun.fromJson(Map<String, dynamic> m) => TextbookWorkflowStageRun(
        subKey: '${m['sub_key'] ?? ''}',
        subIndex: _int(m['sub_index']) ?? 0,
        answerStartPage: _int(m['answer_start_page']),
        answerEndPage: _int(m['answer_end_page']),
        solutionStartPage: _int(m['solution_start_page']),
        solutionEndPage: _int(m['solution_end_page']),
        bodyPageFrom: _int(m['body_page_from']),
        bodyPageTo: _int(m['body_page_to']),
      );

  final String subKey;

  /// 이 sub_key 크롭의 실제 sub_index
  final int subIndex;
  final int? answerStartPage;
  final int? answerEndPage;
  final int? solutionStartPage;
  final int? solutionEndPage;

  /// 중단원 전체가 sub_index 를 함께 쓰는 슬롯이면 이 소단원 본문 쪽 범위만 본다.
  final int? bodyPageFrom;
  final int? bodyPageTo;

  Map<String, dynamic> toJson() => {
        'sub_key': subKey,
        'sub_index': subIndex,
        'answer_start_page': answerStartPage,
        'answer_end_page': answerEndPage,
        'solution_start_page': solutionStartPage,
        'solution_end_page': solutionEndPage,
        'body_page_from': bodyPageFrom,
        'body_page_to': bodyPageTo,
      };
}

/// 크롭 확정 때 만든 2단계 작업 지시. 단원 트리를 다시 읽지 않고도 실행기가 그대로 돌 수 있게 필요한 값을 모두 담는다.
class TextbookSubunitWorkOrder {
  const TextbookSubunitWorkOrder({
    required this.academyId,
    required this.bookId,
    required this.bookName,
    required this.gradeLabel,
    required this.seriesKey,
    required this.bigOrder,
    required this.midOrder,
    required this.bigName,
    required this.midName,
    required this.scopeKey,
    required this.label,
    this.bodyLinkId,
    this.supportsExtraction = true,
    this.extractRuns = const [],
    this.stageRuns = const [],
    this.reviewSubKeys = const [],
    this.indexedSubKeys = const [],
    this.reviewSubIndex = 0,
    this.rawPageFrom,
    this.rawPageTo,
  });

  factory TextbookSubunitWorkOrder.fromJson(Map<String, dynamic> m) => TextbookSubunitWorkOrder(
        academyId: '${m['academy_id'] ?? ''}',
        bookId: '${m['book_id'] ?? ''}',
        bookName: '${m['book_name'] ?? ''}',
        gradeLabel: '${m['grade_label'] ?? ''}',
        seriesKey: '${m['series_key'] ?? ''}',
        bigOrder: _int(m['big_order']) ?? 0,
        midOrder: _int(m['mid_order']) ?? 0,
        bigName: '${m['big_name'] ?? ''}',
        midName: '${m['mid_name'] ?? ''}',
        scopeKey: '${m['scope_key'] ?? ''}',
        label: '${m['label'] ?? ''}',
        bodyLinkId: _int(m['body_link_id']),
        supportsExtraction: m['supports_extraction'] != false,
        extractRuns: [
          for (final r in (m['extract_runs'] as List?) ?? const [])
            if (r is Map) TextbookWorkflowExtractRun.fromJson(Map<String, dynamic>.from(r)),
        ],
        stageRuns: [
          for (final r in (m['stage_runs'] as List?) ?? const [])
            if (r is Map) TextbookWorkflowStageRun.fromJson(Map<String, dynamic>.from(r)),
        ],
        reviewSubKeys: [for (final k in (m['review_sub_keys'] as List?) ?? const []) '$k'],
        indexedSubKeys: [for (final k in (m['indexed_sub_keys'] as List?) ?? const []) '$k'],
        reviewSubIndex: _int(m['review_sub_index']) ?? 0,
        rawPageFrom: _int(m['raw_page_from']),
        rawPageTo: _int(m['raw_page_to']),
      );

  final String academyId;
  final String bookId;
  final String bookName;
  final String gradeLabel;
  final String seriesKey;
  final int bigOrder;
  final int midOrder;
  final String bigName;
  final String midName;

  /// 단원·크롭 창의 작업 단위 키. 일반 교재는 슬롯(A~F), 개념서는 소단원 행(W0, W1 …).
  final String scopeKey;
  final String label;
  final int? bodyLinkId;
  final bool supportsExtraction;
  final List<TextbookWorkflowExtractRun> extractRuns;
  final List<TextbookWorkflowStageRun> stageRuns;

  /// 이 소단원 문항의 sub_key
  final List<String> reviewSubKeys;

  /// 크롭을 소단원 순번(sub_index)으로 나눠 저장하는 sub_key. 나머지는 본문 쪽 범위로 가린다.
  final List<String> indexedSubKeys;
  final int reviewSubIndex;
  final int? rawPageFrom;
  final int? rawPageTo;

  String get workflowKey => textbookWorkflowKey(bookId, gradeLabel, bigOrder, midOrder, scopeKey);

  bool matches(TextbookProblemReviewItem it) {
    if (reviewSubKeys.isNotEmpty && !reviewSubKeys.contains(it.subKey)) return false;
    if (indexedSubKeys.contains(it.subKey)) return it.subIndex == reviewSubIndex;
    final from = rawPageFrom;
    final to = rawPageTo;
    if (from != null && to != null) return it.rawPage >= from && it.rawPage <= to;
    return true;
  }

  TextbookReviewUnitScope get reviewScope => TextbookReviewUnitScope(
        academyId: academyId,
        bookId: bookId,
        bookName: bookName,
        gradeLabel: gradeLabel,
        bigOrder: bigOrder,
        midOrder: midOrder,
        bigName: bigName,
        midName: midName,
        problemCount: 0,
        analyzedCount: 0,
        mathCleanCount: 0,
        mathIssueCount: 0,
        mathApprovedCount: 0,
        qualityCleanCount: 0,
        qualityIssueCount: 0,
        qualityApprovedCount: 0,
      );

  Map<String, dynamic> toJson() => {
        'academy_id': academyId,
        'book_id': bookId,
        'book_name': bookName,
        'grade_label': gradeLabel,
        'series_key': seriesKey,
        'big_order': bigOrder,
        'mid_order': midOrder,
        'big_name': bigName,
        'mid_name': midName,
        'scope_key': scopeKey,
        'label': label,
        'body_link_id': bodyLinkId,
        'supports_extraction': supportsExtraction,
        'extract_runs': [for (final r in extractRuns) r.toJson()],
        'stage_runs': [for (final r in stageRuns) r.toJson()],
        'review_sub_keys': reviewSubKeys,
        'indexed_sub_keys': indexedSubKeys,
        'review_sub_index': reviewSubIndex,
        'raw_page_from': rawPageFrom,
        'raw_page_to': rawPageTo,
      };
}

String textbookWorkflowKey(String bookId, String gradeLabel, int bigOrder, int midOrder, String scopeKey) =>
    '$bookId|$gradeLabel|$bigOrder|$midOrder|$scopeKey';

/// `textbook_subunit_workflows` 한 행. 크롭 확정·2단계 진행 단계·소단원 확정을 앱을 껐다 켜도 이어갈 수 있게 남긴다.
class TextbookSubunitWorkflow {
  const TextbookSubunitWorkflow({
    required this.id,
    required this.academyId,
    required this.bookId,
    required this.gradeLabel,
    required this.bigOrder,
    required this.midOrder,
    required this.scopeKey,
    required this.cropStatus,
    required this.pipelineStatus,
    required this.pipelinePhase,
    required this.pipelineDetail,
    required this.pipelineError,
    this.cropConfirmedAt,
    this.pipelineStartedAt,
    this.pipelineFinishedAt,
    this.confirmedAt,
    this.workOrder,
  });

  factory TextbookSubunitWorkflow.fromJson(Map<String, dynamic> m) {
    final rawOrder = m['work_order'];
    final order = rawOrder is Map && rawOrder.isNotEmpty
        ? TextbookSubunitWorkOrder.fromJson(Map<String, dynamic>.from(rawOrder))
        : null;
    return TextbookSubunitWorkflow(
      id: '${m['id'] ?? ''}',
      academyId: '${m['academy_id'] ?? ''}',
      bookId: '${m['book_id'] ?? ''}',
      gradeLabel: '${m['grade_label'] ?? ''}',
      bigOrder: _int(m['big_order']) ?? 0,
      midOrder: _int(m['mid_order']) ?? 0,
      scopeKey: '${m['scope_key'] ?? ''}',
      cropStatus: '${m['crop_status'] ?? 'none'}',
      pipelineStatus: '${m['pipeline_status'] ?? 'idle'}',
      pipelinePhase: '${m['pipeline_phase'] ?? ''}',
      pipelineDetail: '${m['pipeline_detail'] ?? ''}',
      pipelineError: '${m['pipeline_error'] ?? ''}',
      cropConfirmedAt: _date(m['crop_confirmed_at']),
      pipelineStartedAt: _date(m['pipeline_started_at']),
      pipelineFinishedAt: _date(m['pipeline_finished_at']),
      confirmedAt: _date(m['confirmed_at']),
      workOrder: order != null && order.academyId.isNotEmpty ? order : null,
    );
  }

  final String id;
  final String academyId;
  final String bookId;
  final String gradeLabel;
  final int bigOrder;
  final int midOrder;
  final String scopeKey;

  /// none | draft | confirmed
  final String cropStatus;

  /// idle | queued | running | done | failed
  final String pipelineStatus;
  final String pipelinePhase;
  final String pipelineDetail;
  final String pipelineError;
  final DateTime? cropConfirmedAt;
  final DateTime? pipelineStartedAt;
  final DateTime? pipelineFinishedAt;
  final DateTime? confirmedAt;
  final TextbookSubunitWorkOrder? workOrder;

  String get key => textbookWorkflowKey(bookId, gradeLabel, bigOrder, midOrder, scopeKey);

  /// 단원·크롭 창 상태 키(`대/중/작업 단위`)
  String get stateKey => '$bigOrder/$midOrder/$scopeKey';
  bool get cropConfirmed => cropStatus == 'confirmed';
  bool get isConfirmed => confirmedAt != null;

  /// 크롭 확정으로 새 2단계에 한 번이라도 들어갔다(크롭을 다시 열어도 작업 지시가 남는다).
  bool get startedNewFlow => cropConfirmed || isConfirmed || workOrder != null;

  /// 이 앱이 돌리고 있지 않은데 DB 에는 진행 중으로 남은 상태(앱을 닫았거나 중간에 멈춤)
  bool get pipelineUnfinished => pipelineStatus == 'queued' || pipelineStatus == 'running';
}

/// 새 기준(본문·정답·해설·AI 풀이·검수)으로 본 소단원 상태.
/// 단원·크롭 창, 작업 화면, 교재 탭이 같은 규칙으로 센다.
enum TextbookSubunitStage {
  /// 아직 본문을 뽑지 않았다.
  none,

  /// 예전 원스톱으로 본문(+정답)만 뽑아 두고 새 2단계를 거치지 않았다.
  legacy,

  /// 예전 흐름이지만 본문이 붙은 문항을 모두 문항 검수(정답·품질 승인)까지 마쳤다. 크롭 확인 뒤 확정만 남았다.
  reviewed,

  /// 크롭을 확정해 2단계 중이거나, 크롭을 다시 열어 손보는 중.
  inProgress,

  /// 3단계에서 확정했다.
  confirmed;

  /// 새 2단계를 거치지 않은 예전 추출(검수 여부 무관). "이어서 마무리" 대상.
  bool get isLegacy => this == legacy || this == reviewed;

  static TextbookSubunitStage of({
    TextbookSubunitWorkflow? workflow,
    required int extractedBodies,
    int reviewedBodies = 0,
  }) {
    if (workflow?.isConfirmed ?? false) return confirmed;
    if (workflow?.startedNewFlow ?? false) return inProgress;
    if (extractedBodies <= 0) return none;
    return reviewedBodies >= extractedBodies ? reviewed : legacy;
  }
}

/// 소단원 하나의 본문이 붙은 크롭 수와 그중 문항 검수(정답·품질 모두 승인)를 마친 수.
typedef TextbookSubunitBodyCount = ({int bodies, int reviewed});

/// 크롭 행에 붙여 읽은 `textbook_problem_analyses` 가 정답·품질 모두 승인인가.
bool textbookCropReviewApproved(Map<String, dynamic> crop) {
  var an = crop['textbook_problem_analyses'];
  if (an is List) an = an.isEmpty ? null : an.first;
  return an is Map && an['math_status'] == 'approved' && an['quality_status'] == 'approved';
}

class TextbookWorkflowService {
  TextbookWorkflowService({SupabaseClient? client}) : _db = client ?? Supabase.instance.client;

  final SupabaseClient _db;

  static const _table = 'textbook_subunit_workflows';
  static const _conflict = 'academy_id,book_id,grade_label,big_order,mid_order,scope_key';

  Future<List<TextbookSubunitWorkflow>> fetchForBook({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    int? bigOrder,
    int? midOrder,
  }) async {
    var query = _db.from(_table).select().eq('academy_id', academyId).eq('book_id', bookId).eq('grade_label', gradeLabel);
    if (bigOrder != null) query = query.eq('big_order', bigOrder);
    if (midOrder != null) query = query.eq('mid_order', midOrder);
    final rows = await query;
    return [
      for (final r in (rows as List).whereType<Map>()) TextbookSubunitWorkflow.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  Map<String, Object> _identity({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required int bigOrder,
    required int midOrder,
    required String scopeKey,
  }) =>
      {
        'academy_id': academyId,
        'book_id': bookId,
        'grade_label': gradeLabel,
        'big_order': bigOrder,
        'mid_order': midOrder,
        'scope_key': scopeKey,
      };

  /// 분석 결과를 크롭으로 임시저장했다. 이미 확정한 소단원은 그대로 둔다.
  Future<void> markCropDraft({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required int bigOrder,
    required int midOrder,
    required String scopeKey,
  }) async {
    final id = _identity(
      academyId: academyId,
      bookId: bookId,
      gradeLabel: gradeLabel,
      bigOrder: bigOrder,
      midOrder: midOrder,
      scopeKey: scopeKey,
    );
    final existing = await _db.from(_table).select('crop_status').match(id).maybeSingle();
    if (existing != null && '${existing['crop_status']}' == 'confirmed') return;
    await _db.from(_table).upsert(<String, dynamic>{...id, 'crop_status': 'draft'}, onConflict: _conflict);
  }

  /// 크롭 확정 → 2단계 대기열에 넣을 작업 지시를 저장한다.
  Future<void> confirmCrop(TextbookSubunitWorkOrder order) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.from(_table).upsert(<String, dynamic>{
      ..._identity(
        academyId: order.academyId,
        bookId: order.bookId,
        gradeLabel: order.gradeLabel,
        bigOrder: order.bigOrder,
        midOrder: order.midOrder,
        scopeKey: order.scopeKey,
      ),
      'crop_status': 'confirmed',
      'crop_confirmed_at': now,
      'pipeline_status': 'queued',
      'pipeline_phase': 'queued',
      'pipeline_detail': '',
      'pipeline_error': '',
      'pipeline_started_at': null,
      'pipeline_finished_at': null,
      'confirmed_at': null,
      'confirmed_by': null,
      'work_order': order.toJson(),
    }, onConflict: _conflict);
  }

  /// 크롭 확정을 풀어 다시 손볼 수 있게 한다(2단계 결과는 남는다).
  Future<void> reopenCrop({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required int bigOrder,
    required int midOrder,
    required String scopeKey,
  }) async {
    await _db.from(_table).update({
      'crop_status': 'draft',
      'crop_confirmed_at': null,
      'pipeline_status': 'idle',
      'pipeline_phase': '',
      'pipeline_detail': '',
      'pipeline_error': '',
      'confirmed_at': null,
      'confirmed_by': null,
    }).match(_identity(
      academyId: academyId,
      bookId: bookId,
      gradeLabel: gradeLabel,
      bigOrder: bigOrder,
      midOrder: midOrder,
      scopeKey: scopeKey,
    ));
  }

  Future<void> updatePipeline(
    TextbookSubunitWorkOrder order, {
    String? status,
    String? phase,
    String? detail,
    String? error,
    bool markStarted = false,
    bool markFinished = false,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final patch = <String, dynamic>{
      if (status != null) 'pipeline_status': status,
      if (phase != null) 'pipeline_phase': phase,
      if (detail != null) 'pipeline_detail': detail.length > 500 ? detail.substring(0, 500) : detail,
      if (error != null) 'pipeline_error': error.length > 1000 ? error.substring(0, 1000) : error,
      if (markStarted) 'pipeline_started_at': now,
      if (markStarted) 'pipeline_finished_at': null,
      if (markFinished) 'pipeline_finished_at': now,
    };
    if (patch.isEmpty) return;
    await _db.from(_table).update(patch).match(_identity(
          academyId: order.academyId,
          bookId: order.bookId,
          gradeLabel: order.gradeLabel,
          bigOrder: order.bigOrder,
          midOrder: order.midOrder,
          scopeKey: order.scopeKey,
        ));
  }

  /// 3단계: 모든 카드가 준비됨인 소단원을 확정한다.
  Future<void> confirmSubunit(TextbookSubunitWorkflow workflow, {required bool confirmed}) async {
    await _db.from(_table).update({
      'confirmed_at': confirmed ? DateTime.now().toUtc().toIso8601String() : null,
      'confirmed_by': confirmed ? _db.auth.currentUser?.id : null,
    }).eq('id', workflow.id);
  }

  /// 소단원별로 본문(문제은행 문항)이 연결된 크롭 수와 그중 검수를 마친 수. 키는 `대/중/작업 단위`.
  /// [scopes] 는 `TextbookUnitProgressService.stageScopesFromPayload` 결과(개념서 W행 쪽 범위 포함).
  Future<Map<String, TextbookSubunitBodyCount>> fetchExtractedBodyCounts({
    required String academyId,
    required String bookId,
    required String gradeLabel,
    required List<Map<String, dynamic>> scopes,
  }) async {
    const pageSize = 1000;
    final rows = <Map<String, dynamic>>[];
    for (var from = 0;; from += pageSize) {
      final page = await _db
          .from('textbook_problem_crops')
          .select('big_order, mid_order, sub_key, raw_page, textbook_problem_analyses(math_status, quality_status)')
          .eq('academy_id', academyId)
          .eq('book_id', bookId)
          .eq('grade_label', gradeLabel)
          .eq('is_set_header', false)
          .not('pb_question_uid', 'is', null)
          .order('id', ascending: true)
          .range(from, from + pageSize - 1);
      final list = [for (final r in (page as List).whereType<Map>()) Map<String, dynamic>.from(r)];
      rows.addAll(list);
      if (list.length < pageSize) break;
    }
    return countCropsByScope(rows, scopes);
  }

  /// 크롭 행을 소단원 키(`대/중/작업 단위`)로 센다. 개념서 소단원 행(W)은 쪽 범위로 가른다.
  static Map<String, TextbookSubunitBodyCount> countCropsByScope(
    List<Map<String, dynamic>> crops,
    List<Map<String, dynamic>> scopes,
  ) {
    final wonriRows = <String, List<(String, int, int)>>{};
    for (final s in scopes) {
      if ('${s['scope_kind'] ?? ''}' != 'wonri_sub_unit') continue;
      final start = _int(s['body_start_page']);
      final end = _int(s['body_end_page']);
      if (start == null || end == null) continue;
      wonriRows.putIfAbsent('${s['big_order']}/${s['mid_order']}', () => []).add(('${s['sub_key']}', start, end));
    }
    final out = <String, TextbookSubunitBodyCount>{};
    for (final c in crops) {
      final big = _int(c['big_order']);
      final mid = _int(c['mid_order']);
      if (big == null || mid == null) continue;
      final midKey = '$big/$mid';
      final rows = wonriRows[midKey];
      String? scopeKey;
      if (rows != null) {
        final page = _int(c['raw_page']);
        if (page == null) continue;
        for (final (key, start, end) in rows) {
          if (page >= start && page <= end) {
            scopeKey = key;
            break;
          }
        }
      } else {
        scopeKey = '${c['sub_key'] ?? ''}'.trim().toUpperCase();
      }
      if (scopeKey == null || scopeKey.isEmpty) continue;
      final ok = textbookCropReviewApproved(c) ? 1 : 0;
      out.update(
        '$midKey/$scopeKey',
        (v) => (bodies: v.bodies + 1, reviewed: v.reviewed + ok),
        ifAbsent: () => (bodies: 1, reviewed: ok),
      );
    }
    return out;
  }

  /// 아직 문제은행 문항이 붙지 않은 크롭만 지운다. 지웠으면 true.
  Future<bool> deleteDraftCrop(String cropId) async {
    final rows = await _db.from('textbook_problem_crops').delete().eq('id', cropId).isFilter('pb_question_uid', null).select('id');
    return (rows as List).isNotEmpty;
  }
}

int? _int(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v');
}

DateTime? _date(dynamic v) {
  final s = '${v ?? ''}'.trim();
  if (s.isEmpty || s == 'null') return null;
  return DateTime.tryParse(s);
}
