import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'concept_book_service.dart';
import 'concept_draft_compare.dart';
import 'concept_draft_models.dart';
import 'concept_relation_service.dart';
import 'concept_topic.dart';

/// 개념책 소단원 → 개념 초안. 쪽 전사·정리·폴더 제안은 Edge 함수(서버 키)가 하고 결과를 서버에 저장한다.
/// 이 앱은 쪽 이미지를 그려 보내고, 저장된 초안을 읽고, 운영자 검토를 저장·확정·버린다(RPC).
/// 라이브러리(폴더·개념·출처)에는 확정 RPC만 쓴다. 설계: docs/architecture/concept-library.md §7
class ConceptDraftException implements Exception {
  ConceptDraftException(this.code, this.message, {this.pages = const []});

  final String code;
  final String message;

  /// transcripts_missing 일 때 전사가 없는 쪽.
  final List<int> pages;

  @override
  String toString() => message;
}

const Map<String, String> _messages = {
  'unauthorized': '로그인이 필요합니다.',
  'forbidden': '운영자(슈퍼관리자)만 쓸 수 있습니다.',
  'book_forbidden': '이 교재의 학원에 소속되어 있지 않아 쓸 수 없습니다.',
  'masks_mismatch': '문항 기록이 바뀌어 가림 영역이 서버와 다릅니다. 창을 다시 열어 주세요.',
  'rate_limited': '요청이 많습니다. 1분 뒤 다시 시도하세요.',
  'budget_exceeded': '이번 달 AI 예산을 넘었습니다.',
  'ai_not_configured': '서버에 AI 설정이 없습니다.',
  'transcripts_missing': '전사가 없는 쪽이 있습니다.',
  'too_many_pages': '한 번에 $kConceptDraftMaxPages쪽까지 정리할 수 있습니다.',
  'draft_closed': '이미 확정했거나 버렸거나 다시 정리한 초안입니다.',
  'no_roots': '라이브러리에 영역(최상위 폴더)이 없습니다.',
  'concept_draft_stale': '다른 곳에서 검토를 저장했습니다. 다시 열어 주세요.',
  'concept_draft_closed': '이미 확정했거나 버렸거나 다시 정리한 초안입니다.',
  'concept_draft_forbidden': '운영자(슈퍼관리자)만 쓸 수 있습니다.',
  'concept_draft_book_forbidden': '이 교재의 학원에 소속되어 있지 않아 확정할 수 없습니다.',
  'concept_draft_review_required': '검토를 저장한 뒤 확정할 수 있습니다.',
  'concept_draft_nothing_kept': '넣을 개념이 없습니다.',
  'concept_draft_text_required': '이름이나 내용이 빈 개념이 있습니다.',
  'concept_draft_bad_folder': '폴더 경로가 올바르지 않은 개념이 있습니다(영역 아래 폴더여야 합니다).',
  'concept_draft_unknown_root': '없는 영역으로 시작하는 폴더 경로가 있습니다.',
  'concept_draft_too_long': '이름이나 내용이 너무 깁니다.',
  'concept_draft_bad_review': '검토 내용 형식이 올바르지 않습니다.',
  'concept_draft_type_required': '유형을 정하지 않은 개념이 있습니다.',
  'concept_draft_unknown_type': '유형 목록에 없거나 거절한 유형을 쓰는 개념이 있습니다.',
  'concept_draft_bad_type': '새 유형의 이름·설명·기존 구분이 올바르지 않습니다.',
  'types_read_failed': '개념 유형 목록을 읽지 못했습니다.',
  'concept_draft_change_stale': '제안한 뒤 그 개념을 고쳤습니다. 지금 내용으로 다시 물어보세요.',
  'concept_draft_change_unknown_item': '제안한 개념이 검토에 없습니다. 다시 물어보세요.',
  'concept_draft_change_bad_type': '쓸 수 없는 유형이 들어 있습니다. 다시 물어보세요.',
  'concept_draft_change_type_exists': '이미 있는 유형을 새 유형으로 제안했습니다.',
  'concept_draft_change_bad_folder': '폴더 경로가 올바르지 않습니다.',
  'concept_draft_change_bad_blocks': '근거 블록이 이 초안에 없습니다.',
  'concept_draft_change_dropped': '뺀 개념은 나누거나 합칠 수 없습니다.',
  'concept_draft_change_bad_op': '변경 형식이 올바르지 않습니다.',
  'concept_draft_change_bad_text': '이름이나 내용이 비었거나 너무 깁니다.',
  'concept_draft_review_not_saved': '검토를 한 번 저장해야 바꿀 수 있습니다.',
  'concept_draft_not_found': '초안을 찾지 못했습니다.',
  'concept_draft_rerun_use_organize': '다시 정리는 검토 창에서 승인하세요.',
  'concept_criteria_stale': '제안한 뒤 기준이 바뀌었습니다. 다시 물어보세요.',
  'concept_criteria_not_found': '기준을 찾지 못했습니다.',
  'action_not_pending': '이미 처리한 카드입니다.',
  'action_not_found': '카드를 찾지 못했습니다.',
  'action_kind_invalid': '다시 정리 카드가 아닙니다.',
  'rerun_finish_failed': '새 초안은 만들었지만 지금 초안을 닫지 못해 새 초안을 버렸습니다. 다시 시도하세요.',
  'transcripts_read_failed': '저장된 전사를 읽지 못했습니다.',
  'response_cut': '서버 응답이 중간에 끊겼습니다(서버 실행 시간 한도에 걸렸을 수 있습니다). 초안 목록에 만들어졌는지 확인하세요.',
  'ai_timeout': '정리가 너무 오래 걸려(20분 넘음) 멈췄습니다. 다시 시도하세요.',
  'ai_stalled': 'AI가 5분 넘게 정리를 시작하지 않아 멈췄습니다. 잠시 뒤 다시 시도하세요.',
  'ai_poll_failed': '정리 결과를 확인하지 못했습니다. 잠시 뒤 다시 시도하세요.',
  'response_missing': '정리 결과를 찾지 못했습니다. 다시 시도하세요.',
  'job_not_found': '정리 작업을 찾지 못했습니다.',
  'job_forbidden': '다른 사람이 시작한 정리 작업입니다.',
  'cancelled': '정리가 취소되었습니다. 다시 시도하세요.',
  'criterion_not_found': '기준을 찾지 못했습니다.',
  'invalid_folder': '폴더를 찾지 못했습니다.',
  'folder_not_found': '폴더를 찾지 못했습니다.',
  'too_few_concepts': '개념이 둘 이상인 폴더에서만 묶음을 제안받을 수 있습니다.',
  'too_many_concepts': '개념이 너무 많은 폴더입니다(120개까지). 폴더를 나눈 뒤 제안받으세요.',
  'library_read_failed': '라이브러리를 읽지 못했습니다.',
  'concept_anchor_bad_request': '묶음 요청 형식이 올바르지 않습니다.',
  'concept_anchor_not_found': '개념을 찾지 못했습니다. 트리를 다시 읽어 주세요.',
  'concept_anchor_other_folder': '같은 폴더의 개념에만 붙일 수 있습니다.',
  'concept_anchor_cycle': '서로 가리키는 묶음이 생겨 저장하지 않았습니다.',
  'concept_draft_bad_relation': '기존 개념과의 관계 형식이 올바르지 않은 항목이 있습니다.',
  'concept_draft_relation_target_required': '다른 서술·출처만 연결·수정안·확장·특수한 경우로 둔 항목은 기존 개념을 골라야 합니다.',
  'concept_draft_relation_target_not_found': '고른 기존 개념을 찾지 못했습니다(지워졌을 수 있습니다). 다시 고르세요.',
  'concept_draft_relation_statement_not_found': '출처를 이을 서술을 그 개념에서 찾지 못했습니다(지워졌을 수 있습니다). 다시 고르세요.',
  'concept_draft_revise_draft_exists': '수정안으로 둔 기존 개념에 이미 저장된 수정안이 있어 확정하지 않았습니다. 그 개념 창에서 기존 수정안을 먼저 확정하거나 버리세요.',
  'concept_content_concept_not_found': '수정안으로 둔 기존 개념을 찾지 못했습니다(지워졌을 수 있습니다). 다시 고르세요.',
  'concept_draft_no_holds': '다시 검토할 보류 항목이 없습니다(이미 처리했을 수 있습니다).',
  'concept_draft_hold_closed': '이미 처리한 보류 항목입니다.',
  'concept_compare_too_many': '한 번에 비교할 개념이 너무 많습니다.',
  'no_candidates': '비교할 기존 개념 후보가 없습니다. 같은 이름·겹침 제안이 없거나, 관계에서 기존 개념을 고르지 않았습니다.',
  'compare_not_ready': 'DB에 비교 기능이 아직 반영되지 않았습니다(마이그레이션 필요).',
  'no_concepts': '비교할 항목이 없습니다.',
  'concept_relation_reverse_exists': '두 개념 사이에 반대 방향 관계가 이미 있습니다. 상세에서 확인하세요.',
};

const String kConceptRelationsNotReady = 'DB에 개념 관계 저장소가 아직 없어 기존 개념과의 관계를 고른 항목은 확정할 수 없습니다. '
    '마이그레이션을 반영한 뒤 확정하거나, 관계를 "정하지 않음"으로 두세요.';

const String kConceptCompareNotReady = 'DB에 출처만 연결·수정안·보류 기능이 아직 없어 그렇게 둔 항목은 확정할 수 없습니다. '
    '마이그레이션을 반영한 뒤 확정하거나, 다른 관계로 바꾸세요.';

/// 3단계 마이그레이션(20261020180000)이 있어야 확정할 수 있는 관계.
bool needsCompareMigration(Iterable<ReviewItem> items) => items.any((it) =>
    it.kept &&
    (it.relation?.kind == ReviewRelationKind.source ||
        it.relation?.kind == ReviewRelationKind.revise ||
        it.relation?.kind == ReviewRelationKind.hold));

String conceptDraftErrorMessage(String code, [String? fallback]) => _messages[code] ?? fallback ?? '처리하지 못했습니다($code).';

typedef ConceptDraftProgress = void Function(String step, int done, int total);

/// 서버가 AI 응답을 기다리다 끊은 실패. 내용과 상관없이 응답이 멈춘 것이라 한 번 더 하면 대개 된다.
bool isConceptDraftTimeout(ConceptDraftException e) =>
    e.code.toLowerCase().contains('timed out') || e.code == 'response_cut';

/// 백그라운드 정리를 기다린 시간.
typedef ConceptDraftWait = void Function(Duration elapsed);

/// 서버가 멈춘 정리 작업을 끊어 같은 쪽으로 새로 시작할 때 알리는 글.
typedef ConceptDraftRestart = void Function(String note);

/// 서버가 정리 작업을 끊은 이유 중 같은 입력으로 다시 시작하면 대개 되는 것. 앱이 기다리다 멈춘 것은 넣지 않는다
/// (서버 작업이 아직 돌 수 있어 다시 시작하면 초안이 둘 생길 수 있다).
const Set<String> kConceptDraftRestartCodes = {'ai_stalled', 'ai_timeout'};

class _ServerStoppedJob implements Exception {
  _ServerStoppedJob(this.error);
  final ConceptDraftException error;
}

/// 정리 진행 글. 기다린 시간이 있으면 붙인다.
String conceptDraftWaitText(String base, Duration? elapsed) {
  if (elapsed == null) return '$base (보통 1~5분)';
  final m = elapsed.inMinutes;
  final s = elapsed.inSeconds % 60;
  return '$base (${m > 0 ? '$m분 ' : ''}$s초 지남)';
}

/// Isolate.run에 넘기는 함수는 감싼 함수의 변수까지 함께 보낸다. 화면 콜백이 섞이지 않게 따로 둔다.
Future<Uint8List> _drawMasksInIsolate(Uint8List png, List<ConceptPageMask> masks) =>
    Isolate.run(() => drawConceptPageMasks(png, masks));

class ConceptDraftService {
  ConceptDraftService({
    SupabaseClient? client,
    ConceptBookService? books,
    this.pollInterval = const Duration(seconds: 5),
    this.maxWait = const Duration(minutes: 25),
    this.maxPollMisses = 5,
  })  : _client = client,
        _books = books ?? ConceptBookService(client: client);

  final SupabaseClient? _client;
  final ConceptBookService _books;

  /// 백그라운드 정리 결과를 물어보는 간격, 앱이 기다리는 최대 시간(서버는 20분 넘으면 취소한다),
  /// 결과 확인이 연달아 실패해도 계속 물어볼 횟수.
  final Duration pollInterval;
  final Duration maxWait;
  final int maxPollMisses;

  SupabaseClient get _db => _client ?? Supabase.instance.client;

  static const int renderLongEdge = 1900;

  /// 긴 정리(create·rerun)는 200을 먼저 받고 결과에 원래 상태 코드(http_status)가 붙어 온다.
  Future<Map<String, dynamic>> _invoke(String fn, Map<String, dynamic> body) async {
    final FunctionResponse res;
    try {
      res = await _db.functions.invoke(fn, body: body);
    } on FunctionException catch (e) {
      final d = e.details is Map ? Map<String, dynamic>.from(e.details as Map) : const <String, dynamic>{};
      throw _failure(d, e.status);
    } on FormatException {
      throw _cut();
    } on http.ClientException {
      throw _cut();
    }
    final data = res.data;
    if (data is! Map) throw ConceptDraftException('invalid_response', '서버 응답을 해석하지 못했습니다.');
    final d = Map<String, dynamic>.from(data);
    if (d['ok'] == false) throw _failure(d, (d['http_status'] as num?)?.toInt() ?? res.status);
    return d;
  }

  ConceptDraftException _failure(Map<String, dynamic> d, int status) {
    final code = '${d['error'] ?? 'http_$status'}';
    final pages = d['pages'] is List
        ? [
            for (final p in d['pages'] as List)
              if (p is num) p.toInt()
          ]
        : const <int>[];
    return ConceptDraftException(code, conceptDraftErrorMessage(code, '서버 오류($status): ${d['message'] ?? code}'),
        pages: pages);
  }

  ConceptDraftException _cut() => ConceptDraftException('response_cut', conceptDraftErrorMessage('response_cut'));

  Never _rpcError(PostgrestException e) {
    final m = RegExp(r'concept_(?:draft|anchor|content|compare)_[a-z_]+').firstMatch(e.message);
    final code = m?.group(0) ?? 'db_error';
    throw ConceptDraftException(code, conceptDraftErrorMessage(code, e.message));
  }

  /// 쪽마다 이미 저장된 읽기 회차(1·2).
  Future<Map<int, Set<int>>> transcribedReads(ConceptBookEntry book, List<int> pages) async {
    if (pages.isEmpty) return const {};
    final rows = await _db
        .from('concept_page_transcripts')
        .select('raw_page,read_index')
        .eq('academy_id', book.academyId)
        .eq('book_id', book.bookId)
        .eq('grade_label', book.gradeLabel)
        .eq('prompt_version', kConceptPagePromptVersion)
        .inFilter('raw_page', pages);
    final out = <int, Set<int>>{};
    for (final r in rows as List) {
      final m = r as Map;
      final raw = (m['raw_page'] as num?)?.toInt();
      final read = (m['read_index'] as num?)?.toInt();
      if (raw != null && read != null) out.putIfAbsent(raw, () => {}).add(read);
    }
    return out;
  }

  Future<Map<int, List<Map<String, dynamic>>>> _crops(ConceptBookEntry book, List<int> pages) async {
    final rows = await _db
        .from('textbook_problem_crops')
        .select('raw_page,problem_number,item_region_1k,bbox_1k')
        .eq('academy_id', book.academyId)
        .eq('book_id', book.bookId)
        .eq('grade_label', book.gradeLabel)
        .inFilter('raw_page', pages)
        .limit(1000);
    final out = <int, List<Map<String, dynamic>>>{};
    for (final r in rows as List) {
      final m = Map<String, dynamic>.from(r as Map);
      final raw = (m['raw_page'] as num?)?.toInt();
      if (raw != null) out.putIfAbsent(raw, () => []).add(m);
    }
    return out;
  }

  /// 쪽마다 두 번 읽어 서버에 저장한다. 이미 저장된 회차는 건너뛴다. 실패하면 그 자리에서 멈춘다.
  Future<void> transcribe({
    required ConceptBookEntry book,
    required List<String> unitPath,
    required List<int> pages,
    ConceptDraftProgress? onProgress,
  }) async {
    final done = await transcribedReads(book, pages);
    final todo = <({int page, int read})>[
      for (final p in pages)
        for (final read in const [1, 2])
          if (!(done[p]?.contains(read) ?? false)) (page: p, read: read),
    ];
    if (todo.isEmpty) return;
    final todoPages = {for (final t in todo) t.page}.toList()..sort();
    onProgress?.call('쪽 이미지를 만드는 중', 0, todoPages.length);
    final paths = await _books.renderPages(
      book,
      todoPages,
      longEdgePx: renderLongEdge,
      onProgress: (d, t) => onProgress?.call('쪽 이미지를 만드는 중', d, t),
    );
    final crops = await _crops(book, todoPages);
    final images = <int, String>{};
    final masks = <int, List<ConceptPageMask>>{};
    for (var i = 0; i < todoPages.length; i += 1) {
      final page = todoPages[i];
      final m = conceptPageMasks(crops[page] ?? const []);
      final png = await File(paths[i]).readAsBytes();
      final masked = await _drawMasksInIsolate(png, m);
      images[page] = base64Encode(masked);
      masks[page] = m;
    }
    for (var i = 0; i < todo.length; i += 1) {
      final t = todo[i];
      onProgress?.call('${t.page}쪽 ${t.read}번째 읽는 중', i, todo.length);
      final body = {
        'save': true,
        'academy_id': book.academyId,
        'book_id': book.bookId,
        'grade_label': book.gradeLabel,
        'read_index': t.read,
        'raw_page': t.page,
        'unit_path': unitPath,
        'image_base64': images[t.page],
        'mime_type': 'image/png',
        'masks': [for (final m in masks[t.page]!) m.toJson()],
      };
      try {
        await _invoke('concept_page_read', body);
      } on ConceptDraftException catch (e) {
        if (!isConceptDraftTimeout(e)) rethrow;
        onProgress?.call('${t.page}쪽 ${t.read}번째 다시 읽는 중(응답이 멈춰 한 번 더)', i, todo.length);
        await _invoke('concept_page_read', body);
      }
    }
    onProgress?.call('전사 완료', todo.length, todo.length);
  }

  /// 저장된 전사로 초안을 만든다. 돌려주는 값은 초안 id.
  /// 서버가 백그라운드로 정리하면 끝날 때까지 [pollInterval]마다 물어보고, 기다린 시간을 [onWait]로 알린다.
  Future<String> createDraft({
    required ConceptBookEntry book,
    required List<String> unitPath,
    required List<int> pages,
    List<String> criterionIds = const [],
    ConceptDraftWait? onWait,
    ConceptDraftRestart? onRestart,
  }) async {
    Future<String> start() async {
      final res = await _invoke('concept_draft_organize', {
        'task': 'create',
        'background': true,
        'academy_id': book.academyId,
        'book_id': book.bookId,
        'grade_label': book.gradeLabel,
        'unit_path': unitPath,
        'pages': pages,
        if (criterionIds.isNotEmpty) 'criterion_ids': criterionIds,
      });
      return _draftIdOf(res, onWait, '초안 id를 받지 못했습니다.', restartable: true);
    }

    try {
      return await start();
    } on _ServerStoppedJob catch (first) {
      onRestart?.call('${first.error.message.split('.').first}. 같은 쪽으로 한 번 다시 정리합니다.');
      try {
        return await start();
      } on _ServerStoppedJob catch (second) {
        throw second.error;
      }
    }
  }

  /// 백그라운드 작업이면 결과를 기다린다. 옛 서버는 바로 초안 id를 준다.
  Future<String> _draftIdOf(Map<String, dynamic> res, ConceptDraftWait? onWait, String missing,
      {bool restartable = false}) async {
    final job = res['job_id'];
    final d = job is String && job.isNotEmpty ? await _collect(job, onWait, restartable: restartable) : res;
    final id = d['draft_id'];
    if (id is! String || id.isEmpty) throw ConceptDraftException('invalid_response', missing);
    return id;
  }

  static const _transientCodes = {
    'ai_poll_failed',
    'response_cut',
    'job_read_failed',
    'job_save_failed',
    'invalid_response'
  };

  Future<Map<String, dynamic>> _collect(String jobId, ConceptDraftWait? onWait, {bool restartable = false}) async {
    final watch = Stopwatch()..start();
    var misses = 0;
    while (true) {
      await Future<void>.delayed(pollInterval);
      try {
        final d = await _invoke('concept_draft_organize', {'task': 'collect', 'job_id': jobId});
        misses = 0;
        if (d['status'] != 'running') return d;
        final ms = (d['elapsed_ms'] as num?)?.toInt();
        onWait?.call(ms == null ? watch.elapsed : Duration(milliseconds: ms));
      } on ConceptDraftException catch (e) {
        if (restartable && kConceptDraftRestartCodes.contains(e.code)) throw _ServerStoppedJob(e);
        final transient = _transientCodes.contains(e.code) || e.code.startsWith('http_5');
        if (!transient || ++misses > maxPollMisses) rethrow;
      }
      if (watch.elapsed > maxWait) throw ConceptDraftException('ai_timeout', conceptDraftErrorMessage('ai_timeout'));
    }
  }

  /// 초안 개념을 넣을 폴더 제안(서버가 초안에 저장).
  Future<void> proposeFolders(String draftId) async {
    await _invoke('concept_draft_organize', {'task': 'folders', 'draft_id': draftId});
  }

  /// 승인한 "다시 정리" 카드로 같은 쪽을 다시 정리한다. 서버가 새 초안을 만들고 지금 초안을 '다시 정리함'으로 닫는다.
  /// 돌려주는 값은 새 초안 id.
  Future<String> rerun(String actionId, {ConceptDraftWait? onWait}) async {
    final res = await _invoke('concept_draft_organize', {'task': 'rerun', 'background': true, 'action_id': actionId});
    return _draftIdOf(res, onWait, '새 초안 id를 받지 못했습니다.');
  }

  Future<List<ConceptDraftSummary>> listDrafts({bool openOnly = true, int limit = 50}) async {
    var q = _db.from('concept_drafts').select(
        'id,book_name,grade_label,unit_path,pages,status,created_at,review_saved_at,plan_at:folder_plan->>created_at,concepts:draft->concepts');
    if (openOnly) q = q.eq('status', 'open');
    final rows = await q.order('created_at', ascending: false).limit(limit);
    return [
      for (final r in rows as List)
        () {
          final m = Map<String, dynamic>.from(r as Map);
          m['concept_count'] = m['concepts'] is List ? (m['concepts'] as List).length : 0;
          m['has_folder_plan'] = m['plan_at'] != null;
          return ConceptDraftSummary.fromRow(m);
        }(),
    ];
  }

  /// 개념책 창의 소단원별 초안 표시·진행률. 검토 중·확정 초안의 위치만 읽는다(본문은 읽지 않는다).
  Future<ConceptDraftCoverage> coverage() async {
    final rows = await _db
        .from('concept_drafts')
        .select('id,academy_id,book_id,grade_label,unit_path,status')
        .inFilter('status', ['open', 'confirmed'])
        .order('created_at', ascending: false)
        .limit(5000);
    return ConceptDraftCoverage.fromRows([for (final r in rows as List) Map<String, dynamic>.from(r as Map)]);
  }

  Future<ConceptDraftRecord> fetchDraft(String id) async {
    final row = await _db.from('concept_drafts').select().eq('id', id).maybeSingle();
    if (row == null) throw ConceptDraftException('not_found', '초안을 찾지 못했습니다.');
    return ConceptDraftRecord.fromRow(Map<String, dynamic>.from(row));
  }

  /// 검토를 저장하고 새 저장 시각을 돌려준다.
  Future<String> saveReview(
    String id,
    List<ReviewItem> items,
    String? expectedSavedAt, {
    List<ReviewNewType> newTypes = const [],
  }) async {
    try {
      final res = await _db.rpc('concept_draft_save_review', params: {
        'p_id': id,
        'p_review': {
          'concepts': [for (final it in items) it.toJson()],
          'new_types': [for (final t in newTypes) t.toJson()],
        },
        'p_expected_review_saved_at': expectedSavedAt,
      });
      final saved = res is Map ? res['review_saved_at'] : null;
      if (saved is! String) throw ConceptDraftException('invalid_response', '저장 시각을 받지 못했습니다.');
      return saved;
    } on PostgrestException catch (e) {
      _rpcError(e);
    }
  }

  /// 저장된 검토로 폴더·개념·출처를 만든다. 결과: {concepts: [{index, id, category_id}], folders: [...], sources: n}
  Future<Map<String, dynamic>> confirm(String id, String savedAt) async {
    try {
      final res = await _db.rpc('concept_draft_confirm', params: {'p_id': id, 'p_expected_review_saved_at': savedAt});
      final result = res is Map ? res['result'] : null;
      return result is Map ? Map<String, dynamic>.from(result) : const {};
    } on PostgrestException catch (e) {
      _rpcError(e);
    }
  }

  /// 개념 추가하기: 다른 서술(statement)도 바로 확정 서술(version = 1)로 저장하며 확정한다.
  Future<Map<String, dynamic>> confirmWithStatements(String id, String savedAt) async {
    try {
      final res = await _db.rpc('concept_draft_confirm', params: {
        'p_id': id,
        'p_expected_review_saved_at': savedAt,
        'p_confirm_statements': true,
      });
      final result = res is Map ? res['result'] : null;
      return result is Map ? Map<String, dynamic>.from(result) : const {};
    } on PostgrestException catch (e) {
      _rpcError(e);
    }
  }

  Future<void> discard(String id, String? savedAt) async {
    try {
      await _db.rpc('concept_draft_discard', params: {'p_id': id, 'p_expected_review_saved_at': savedAt});
    } on PostgrestException catch (e) {
      _rpcError(e);
    }
  }

  /// 확정된 개념 유형 목록(목록 순서).
  Future<List<ConceptTypeInfo>> conceptTypes() async {
    final rows = await _db
        .from('concept_types')
        .select('name,description,legacy_sub_type')
        .order('sort_order')
        .order('created_at')
        .limit(200);
    return [
      for (final r in rows as List)
        if ('${(r as Map)['name'] ?? ''}'.trim().isNotEmpty) ConceptTypeInfo.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  /// 트리에 붙일 유형·주제 묶음. 묶음 표를 읽지 못하면 유형만 돌려준다(anchorsUnavailable).
  Future<ConceptTreeMeta> treeMeta(List<String> conceptIds) async {
    final typeRows =
        await _db.from('concept_types').select('id,name').order('sort_order').order('created_at').limit(200);
    final typeName = <String, String>{};
    final typeRank = <String, int>{};
    for (final r in typeRows as List) {
      final m = r as Map;
      final name = '${m['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      typeName['${m['id']}'] = name;
      typeRank.putIfAbsent(name, () => typeRank.length);
    }
    final typeOf = <String, String>{};
    final anchorOf = <String, String>{};
    final statementCount = <String, int>{};
    var anchorsUnavailable = false;
    var statementsUnavailable = false;
    const chunk = 150;
    for (var i = 0; i < conceptIds.length; i += chunk) {
      final ids = conceptIds.sublist(i, (i + chunk).clamp(0, conceptIds.length));
      final links = await _db.from('concept_type_links').select('concept_id,type_id').inFilter('concept_id', ids);
      for (final r in links as List) {
        final m = r as Map;
        final name = typeName['${m['type_id']}'];
        if (name != null) typeOf['${m['concept_id']}'] = name;
      }
      if (!statementsUnavailable) {
        try {
          final rows = await _db
              .from('concept_statements')
              .select('concept_id')
              .eq('role', 'statement')
              .inFilter('concept_id', ids);
          for (final r in rows as List) {
            final id = '${(r as Map)['concept_id']}';
            statementCount[id] = (statementCount[id] ?? 0) + 1;
          }
        } on PostgrestException {
          statementsUnavailable = true;
          statementCount.clear();
        }
      }
      if (anchorsUnavailable) continue;
      try {
        final anchors =
            await _db.from('concept_anchor_links').select('concept_id,anchor_id').inFilter('concept_id', ids);
        for (final r in anchors as List) {
          final m = r as Map;
          anchorOf['${m['concept_id']}'] = '${m['anchor_id']}';
        }
      } on PostgrestException {
        anchorsUnavailable = true;
        anchorOf.clear();
      }
    }
    return ConceptTreeMeta(
      typeOf: typeOf,
      typeRank: typeRank,
      anchorOf: anchorOf,
      anchorsUnavailable: anchorsUnavailable,
      statementCount: statementCount,
    );
  }

  /// 폴더 하나의 주제 묶음 제안(저장하지 않음). 개념은 서버가 읽는다.
  Future<ConceptAnchorProposal> proposeAnchors(String folderId) async {
    final res = await _invoke('concept_draft_organize', {'task': 'anchors', 'folder_id': folderId});
    return ConceptAnchorProposal.fromJson(res);
  }

  /// 서술 하나(null = 기본 서술)의 출처마다 근거 범위 제안. 서술 글·근거 블록은 서버가 읽고, 제안은 저장하지 않는다.
  Future<Map<String, dynamic>> proposeEvidenceScopes(String conceptId, String? statementId) => _invoke(
      'concept_draft_organize', {'task': 'evidence_scope', 'concept_id': conceptId, 'statement_id': statementId});

  /// 개념 id → 붙일 개념 id(null = 묶음에서 빼기). origin: 'proposal'(제안에서 고름) | 'manual'.
  Future<void> setAnchors(Map<String, String?> links, {required String origin}) async {
    if (links.isEmpty) return;
    try {
      await _db.rpc('concept_anchor_set', params: {
        'p_links': [
          for (final e in links.entries) {'concept_id': e.key, 'anchor_id': e.value},
        ],
        'p_origin': origin,
      });
    } on PostgrestException catch (e) {
      _rpcError(e);
    }
  }

  /// 라이브러리 폴더 경로(영역 이름부터). 바로가기 폴더는 뺀다.
  /// 확정 RPC가 검토 항목의 관계를 읽는지(관계 마이그레이션 반영). 표가 없다고 확실할 때만 false.
  /// 반영 전 확정 RPC는 관계를 무시해 "다른 서술"로 고른 항목도 새 개념으로 넣는다.
  Future<bool> relationsReady() async {
    try {
      await _db.from('concept_relations').select('id').limit(1);
      return true;
    } catch (e) {
      return !ConceptRelationException.from(e).notReady;
    }
  }

  /// 확정 RPC가 출처만 연결·수정안·보류를 읽는지(3단계 마이그레이션 반영). 표가 없다고 확실할 때만 false.
  Future<bool> compareReady() async {
    try {
      await _db.from('concept_draft_holds').select('id').limit(1);
      return true;
    } catch (e) {
      final m = '$e';
      return !(m.contains('concept_draft_holds') && (m.contains('does not exist') || m.contains('schema cache')));
    }
  }

  /// 비교할 기존 개념의 본문·서술·출처 수·수정안 유무. 읽기만 한다.
  Future<List<ConceptCompareTarget>> compareTargets(List<String> ids) async {
    if (ids.isEmpty) return const [];
    try {
      final res = await _db.rpc('concept_compare_targets', params: {'p_ids': ids});
      return [
        for (final r in (res as List?) ?? const [])
          if (r is Map) ConceptCompareTarget.fromJson(Map<String, dynamic>.from(r)),
      ];
    } on PostgrestException catch (e) {
      _rpcError(e);
    }
  }

  /// 저장된 검토 항목을 기존 개념과 비교한 AI 제안. 서버가 저장된 검토를 읽고, 아무것도 저장하지 않는다.
  Future<ConceptCompareProposal> proposeCompare(String draftId, {List<String>? keys}) async {
    final d = await _invoke('concept_draft_organize', {
      'task': 'compare',
      'draft_id': draftId,
      if (keys != null) 'keys': keys,
    });
    final p = d['proposal'];
    if (p is! Map) throw ConceptDraftException('invalid_response', '서버 응답을 해석하지 못했습니다.');
    return ConceptCompareProposal.fromJson(Map<String, dynamic>.from(p));
  }

  /// 교재 개념 추가하기의 자동 묶음 검수 한 회차 실행.
  Future<Map<String, dynamic>> runBookReview({
    required ConceptBookEntry book,
    String? jobId,
    String? conversationId,
  }) async {
    return await _invoke('ai_think', {
      'action': 'book_review',
      'sub_action': 'run',
      'book_id': book.bookId,
      'book_name': '${book.bookName ?? ''} ${book.gradeLabel}'.trim(),
      if (jobId != null) 'job_id': jobId,
      if (conversationId != null) 'conversation_id': conversationId,
    });
  }

  /// 교재 개념 추가하기에서 나온 검수·배치·고치기 대기 카드를 일괄 승인하고 의존 범위를 재확인한다.
  Future<Map<String, dynamic>> approveBookReview({
    required String jobId,
    required String conversationId,
  }) async {
    return await _invoke('ai_think', {
      'action': 'book_review',
      'sub_action': 'approve',
      'job_id': jobId,
      'conversation_id': conversationId,
    });
  }

  Future<List<ConceptDraftHold>> openHolds() async {
    try {
      final res = await _db.rpc('concept_draft_holds_open');
      return [
        for (final r in (res as List?) ?? const [])
          if (r is Map) ConceptDraftHold.fromJson(Map<String, dynamic>.from(r)),
      ];
    } on PostgrestException catch (e) {
      _rpcError(e);
    }
  }

  /// 한 초안 기록의 보류 항목으로 새 검토 초안을 만든다. 새 초안 id.
  Future<String> reopenHolds(String draftId) async {
    try {
      final res = await _db.rpc('concept_draft_hold_reopen', params: {'p_draft_id': draftId});
      return '${(res as Map)['draft_id']}';
    } on PostgrestException catch (e) {
      _rpcError(e);
    }
  }

  Future<void> dropHold(String holdId, {String? note}) async {
    try {
      await _db.rpc('concept_draft_hold_drop', params: {'p_hold_id': holdId, 'p_note': note});
    } on PostgrestException catch (e) {
      _rpcError(e);
    }
  }

  /// 검토 카드에서 "기존 개념"을 고를 때 라이브러리 개념 찾기.
  Future<List<ConceptPick>> searchLibraryConcepts(String query) => SupabaseConceptRelationBackend(_db).search(query);

  /// 이름이 같은 라이브러리 개념. 이름 열쇠([conceptNameKey]) → 개념(만든 순).
  Future<Map<String, List<ConceptPick>>> libraryConceptsNamed(Iterable<String> names) =>
      SupabaseConceptRelationBackend(_db).named(names);

  Future<List<List<String>>> libraryFolderPaths() async {
    final rows = await _db.from('concept_categories').select('id,name,parent_id,code').limit(5000);
    return libraryPathsFromRows([for (final r in rows as List) Map<String, dynamic>.from(r as Map)]);
  }

  /// 검토 화면의 출처 잘라 보기용 쪽 이미지(가리지 않은 원본).
  Future<Map<int, ConceptPageImage>> pageImages(ConceptDraftRecord r,
      {void Function(int done, int total)? onProgress}) async {
    final book = ConceptBookEntry(
      academyId: r.academyId,
      bookId: r.bookId,
      bookName: r.bookName,
      gradeLabel: r.gradeLabel,
      textbookType: null,
      units: const [],
    );
    final paths = await _books.renderPages(book, r.pages, onProgress: onProgress);
    final out = <int, ConceptPageImage>{};
    for (var i = 0; i < r.pages.length; i += 1) {
      final head = await File(paths[i]).openRead(0, 24).fold<List<int>>([], (a, b) => a..addAll(b));
      final size = pngSize(head);
      if (size != null) out[r.pages[i]] = ConceptPageImage(path: paths[i], width: size.$1, height: size.$2);
    }
    return out;
  }
}
