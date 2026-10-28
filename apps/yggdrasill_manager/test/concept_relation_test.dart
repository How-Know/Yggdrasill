import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_draft_review_dialog.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_library_pane.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_relation_section.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_type_chip.dart';
import 'package:yggdrasill_manager/services/concept_book_service.dart';
import 'package:yggdrasill_manager/services/concept_draft_models.dart';
import 'package:yggdrasill_manager/services/concept_draft_service.dart';
import 'package:yggdrasill_manager/services/concept_library_controller.dart';
import 'package:yggdrasill_manager/services/concept_library_service.dart';
import 'package:yggdrasill_manager/services/concept_relation_service.dart';
import 'package:yggdrasill_manager/services/concept_relation_store.dart';
import 'package:yggdrasill_manager/services/concept_service.dart';
import 'package:yggdrasill_manager/services/textbook_pdf_service.dart';
import 'package:yggdrasill_manager/services/think/think_concept_chat_controller.dart';
import 'package:yggdrasill_manager/services/think/think_send_lock.dart';

final _noHttp = MockClient((_) async => http.Response('', 404));

const _a = '6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b';
const _b = '7a2e3d4c-5b6f-4a71-9b8c-0d1e2f3a4b5c';
const _c = '8b3f4e5d-6c7a-4b82-8c9d-1e2f3a4b5c6d';

const _pa = ConceptPick(id: _a, name: '확률', versionLabel: '기본', folder: ['확률과 통계', '확률']);
const _pb = ConceptPick(id: _b, name: '확률', versionLabel: '기본-2', folder: ['확률과 통계', '경우의 수']);
const _pc = ConceptPick(id: _c, name: '조건부확률', versionLabel: '기본', folder: ['확률과 통계', '확률']);

/// RPC와 같은 규칙(같은 쌍의 열린 검토는 하나, 확장·특수한 경우로 닫으면 관계 한 줄, 반대 방향 관계는 막음)을 흉내 낸다.
class _MemRelations implements ConceptRelationBackend {
  final Map<String, ConceptPick> pickRows = {
    for (final p in [_pa, _pb, _pc]) p.id: p
  };
  final List<ConceptRelation> relations = [];
  final List<ConceptReview> reviews = [];
  final List<String> calls = [];
  int _seq = 0;

  ConceptReview _closed(ConceptReview v, ConceptReviewResolution res, String from, String? to, String? note) =>
      ConceptReview(
        id: v.id,
        conceptId: from,
        otherId: to,
        reason: v.reason,
        note: v.note,
        open: false,
        resolution: res,
        resolutionNote: note,
        createdAt: v.createdAt,
        resolvedAt: DateTime(2026, 10, 20),
      );

  final List<ConceptRelationEvent> events = [];

  static bool _legacy(ConceptRelationKind k) =>
      k == ConceptRelationKind.extendsOf || k == ConceptRelationKind.specialCase;
  static String _ctx(String? v) => (v ?? '').trim().toLowerCase();

  /// RPC가 올리는 것과 같은 오류(메시지에 코드).
  static PostgrestException _rpc(String code) => PostgrestException(message: code, code: 'P0001');

  void _put(String from, String to, ConceptRelationKind kind, String origin) {
    if (relations.any((r) => _legacy(r.kind) && r.conceptId == to && r.relatedId == from)) {
      throw ConceptRelationException('concept_relation_reverse_exists', '반대 방향');
    }
    relations.removeWhere((r) => _legacy(r.kind) && r.conceptId == from && r.relatedId == to);
    relations
        .add(ConceptRelation(id: 'rel-${++_seq}', conceptId: from, relatedId: to, kind: kind, origin: origin, rev: 1));
  }

  void _event(String event, ConceptRelation r) => events.insert(
      0,
      ConceptRelationEvent(
        event: event,
        relationId: r.id,
        conceptName: pickRows[r.conceptId]?.name ?? '?',
        relatedName: pickRows[r.relatedId]?.name ?? '?',
        via: 'manual',
        kind: r.kind,
        context: r.context,
      ));

  @override
  Future<ConceptRelationSheet> relationsFor(String conceptId) async => ConceptRelationSheet(
        relations: [
          for (final r in relations)
            if (r.conceptId == conceptId || r.relatedId == conceptId) r
        ],
        events: List.of(events),
        eventCount: events.length,
      );

  @override
  Future<ConceptRelation> saveRelation({
    String? id,
    int? rev,
    required String conceptId,
    required String relatedId,
    required ConceptRelationKind kind,
    String? context,
    String? basis,
    String? note,
  }) async {
    calls.add('save:${id ?? 'new'}:$conceptId>$relatedId:${kind.db}:${context ?? '-'}');
    ConceptRelation? old;
    if (id != null) {
      old = relations.firstWhere((r) => r.id == id, orElse: () => throw _rpc('concept_relation_not_found'));
      if (rev != old.rev) throw _rpc('concept_relation_stale');
    }
    if (kind.contextRequired && _ctx(context).isEmpty) throw _rpc('concept_relation_context_required');
    final others = [
      for (final r in relations)
        if (r.id != id) r
    ];
    final clash = _legacy(kind)
        ? others.any((r) => _legacy(r.kind) && r.conceptId == conceptId && r.relatedId == relatedId)
        : others.any((r) =>
            r.kind == kind && r.conceptId == conceptId && r.relatedId == relatedId && _ctx(r.context) == _ctx(context));
    if (clash) throw _rpc('concept_relation_exists');
    final reverse = others.any((r) =>
        r.conceptId == relatedId &&
        r.relatedId == conceptId &&
        (_legacy(kind)
            ? _legacy(r.kind)
            : r.kind == kind &&
                (kind == ConceptRelationKind.kindOf ||
                    kind == ConceptRelationKind.partOf ||
                    _ctx(r.context) == _ctx(context))));
    if (reverse) throw _rpc('concept_relation_reverse_exists');
    final next = ConceptRelation(
      id: old?.id ?? 'rel-${++_seq}',
      conceptId: conceptId,
      relatedId: relatedId,
      kind: kind,
      origin: old?.origin ?? 'manual',
      context: context,
      basis: basis,
      note: note,
      rev: (old?.rev ?? 0) + 1,
      decision: const ConceptRelationDecision(via: 'manual'),
    );
    relations
      ..removeWhere((r) => r.id == next.id)
      ..add(next);
    _event(old == null ? 'add' : 'change', next);
    return next;
  }

  @override
  Future<List<ConceptReview>> reviewsFor(String conceptId) async => [
        for (final v in reviews)
          if (v.conceptId == conceptId || v.otherId == conceptId) v
      ];

  @override
  Future<Set<String>> openReviewConceptIds() async => {
        for (final v in reviews)
          if (v.open) v.conceptId
      };

  @override
  Future<List<ConceptReview>> reviewsAmong(List<String> ids) async => [
        for (final v in reviews)
          if (ids.contains(v.conceptId) && v.otherId != null && ids.contains(v.otherId)) v
      ];

  @override
  Future<Map<String, ConceptPick>> picks(Iterable<String> ids) async => {
        for (final id in ids)
          if (pickRows[id] != null) id: pickRows[id]!
      };

  @override
  Future<List<ConceptPick>> search(String query) async => [
        for (final p in pickRows.values)
          if (p.name.contains(query.trim())) p
      ];

  @override
  Future<Map<String, List<ConceptPick>>> named(Iterable<String> names) async {
    final keys = {for (final n in names) conceptNameKey(n)};
    final out = <String, List<ConceptPick>>{};
    for (final p in pickRows.values) {
      if (keys.contains(conceptNameKey(p.name))) (out[conceptNameKey(p.name)] ??= []).add(p);
    }
    return out;
  }

  @override
  Future<List<List<ConceptPick>>> sameNameGroups() async {
    final out = <String, List<ConceptPick>>{};
    for (final p in pickRows.values) {
      (out[conceptNameKey(p.name)] ??= []).add(p);
    }
    return [
      for (final g in out.values)
        if (g.length > 1) g
    ];
  }

  @override
  Future<ConceptRelation> setRelation({
    required String conceptId,
    required String relatedId,
    required ConceptRelationKind kind,
    String? note,
  }) async {
    calls.add('set:$conceptId>$relatedId:${kind.db}');
    _put(conceptId, relatedId, kind, 'manual');
    return relations.last;
  }

  @override
  Future<void> removeRelation(String id, {int? rev}) async {
    calls.add('remove:$id');
    final r = relations.firstWhere((r) => r.id == id, orElse: () => throw _rpc('concept_relation_not_found'));
    if (rev != null && rev != r.rev) throw _rpc('concept_relation_stale');
    relations.remove(r);
    _event('remove', r);
  }

  @override
  Future<ConceptReview> openReview({required String conceptId, String? otherId, String? note}) async {
    calls.add('open:$conceptId>${otherId ?? '-'}');
    final v = ConceptReview(id: 'rv-${++_seq}', conceptId: conceptId, otherId: otherId, reason: 'manual', open: true);
    reviews.add(v);
    return v;
  }

  @override
  Future<ConceptReview> resolveReview(
    String id,
    ConceptReviewResolution resolution, {
    String? otherId,
    String? note,
    bool reverse = false,
  }) async {
    calls.add('resolve:$id:${resolution.db}${reverse ? ':reverse' : ''}');
    final i = reviews.indexWhere((v) => v.id == id);
    final v = reviews[i];
    if (!v.open) throw ConceptRelationException('concept_review_closed', '이미 판단함');
    final other = otherId ?? v.otherId;
    if ((resolution.needsOther || reverse) && other == null) {
      throw ConceptRelationException('concept_review_other_required', '비교할 개념을 고르세요.');
    }
    final from = reverse ? other! : v.conceptId;
    final to = reverse ? v.conceptId : other;
    if (resolution == ConceptReviewResolution.extendsOf) _put(from, to!, ConceptRelationKind.extendsOf, 'review');
    if (resolution == ConceptReviewResolution.specialCase) _put(from, to!, ConceptRelationKind.specialCase, 'review');
    reviews[i] = _closed(v, resolution, from, to, note);
    return reviews[i];
  }

  @override
  Future<ConceptReview> decidePair({
    required String conceptId,
    required String otherId,
    required ConceptReviewResolution resolution,
    String? note,
  }) async {
    calls.add('pair:$conceptId>$otherId:${resolution.db}');
    var i = reviews.indexWhere((v) => v.open && v.conceptId == conceptId && v.otherId == otherId);
    if (i < 0) {
      reviews.add(
          ConceptReview(id: 'rv-${++_seq}', conceptId: conceptId, otherId: otherId, reason: 'same_name', open: true));
      i = reviews.length - 1;
    }
    final out = await resolveReview(reviews[i].id, resolution, note: note);
    calls.removeLast();
    for (var j = 0; j < reviews.length; j++) {
      final v = reviews[j];
      if (v.open && v.conceptId == otherId && v.otherId == conceptId) {
        reviews[j] = _closed(v, resolution, v.conceptId, v.otherId, note);
      }
    }
    return out;
  }
}

class _Lib implements ConceptLibraryBackend {
  @override
  Future<List<ConceptSourceRef>> sourcesFor(String conceptId) async => const [];

  @override
  Future<List<String>> criterionIdsForConcept(String conceptId) async => const [];

  @override
  Future<String?> conceptTypeName(String conceptId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

ConceptItem _item() => ConceptItem(id: _a, kind: ConceptKind.definition, name: '확률', content: '경우의 수의 비율');

Future<void> _pumpDetail(WidgetTester tester, ConceptLibraryController c) async {
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 480,
          height: 1100,
          child: ConceptDetailView(controller: c, onEdit: (_) {}, onPickForChat: (_) {}),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

// ------------------------------------------------------------------ 초안 검토

Map<String, dynamic> _draftRow({List<Map<String, dynamic>> overlaps = const []}) => {
      'id': 'd1',
      'academy_id': 'a1',
      'book_id': 'b1',
      'grade_label': '1-1',
      'book_name': '개념+유형',
      'unit_path': ['확률', '확률의 뜻'],
      'pages': [8],
      'page_meta': [],
      'status': 'open',
      'model': 'gpt',
      'prepared': {
        'blocks': [
          {
            'id': 'p8-a0',
            'raw_page': 8,
            'read': 'a',
            'kind': 'concept_box',
            'title': '',
            'text': '확률',
            'bbox_1k': null
          },
        ],
        'disagreements': [],
      },
      'draft': {
        'summary': '',
        'concepts': [
          {
            'title': '확률',
            'concept_type': '정의',
            'content': '경우의 수의 비율',
            'source_blocks': ['p8-a0']
          },
          {
            'title': '여사건의 확률',
            'concept_type': '성질',
            'content': '1에서 뺀다',
            'source_blocks': ['p8-a0']
          },
        ],
        'new_types': [],
        'excluded': [],
        'questions': [],
      },
      'checks': {},
      'criteria': [],
      'folder_plan': {
        'notes': '',
        'folders': [],
        'placements': [
          {
            'concept': 0,
            'path': ['확률과 통계', '확률'],
            'reason': ''
          },
          {
            'concept': 1,
            'path': ['확률과 통계', '확률'],
            'reason': ''
          },
        ],
        'overlaps': overlaps,
        'roots': ['확률과 통계'],
        'checks': {},
      },
      'review': {},
      'review_saved_at': null,
      'created_at': '2026-10-20T09:00:00Z',
    };

class _DraftService extends ConceptDraftService {
  _DraftService(this.mem, {Map<String, dynamic>? row})
      : _row = row ?? _draftRow(),
        super(books: ConceptBookService(pdf: TextbookPdfService(httpClient: _noHttp), httpClient: _noHttp));

  final _MemRelations mem;
  Map<String, dynamic> _row;
  bool relationsTable = true;

  @override
  Future<bool> relationsReady() async => relationsTable;
  final List<List<ReviewItem>> saved = [];
  final List<String> confirmed = [];

  @override
  Future<ConceptDraftRecord> fetchDraft(String id) async => ConceptDraftRecord.fromRow(_row);

  @override
  Future<List<List<String>>> libraryFolderPaths() async => const [
        ['확률과 통계'],
        ['확률과 통계', '확률'],
      ];

  @override
  Future<List<ConceptTypeInfo>> conceptTypes() async => const [
        ConceptTypeInfo(name: '정의', description: '뜻', legacySubType: '정의'),
        ConceptTypeInfo(name: '성질', description: '사실', legacySubType: '정리'),
      ];

  @override
  Future<List<ConceptPick>> searchLibraryConcepts(String query) => mem.search(query);

  @override
  Future<Map<String, List<ConceptPick>>> libraryConceptsNamed(Iterable<String> names) => mem.named(names);

  @override
  Future<String> saveReview(String id, List<ReviewItem> items, String? expectedSavedAt,
      {List<ReviewNewType> newTypes = const []}) async {
    saved.add(items);
    final at = '2026-10-20T10:00:0${saved.length}+00:00';
    _row = {
      ..._row,
      'review': {
        'concepts': [for (final it in items) it.toJson()],
        'new_types': [],
      },
      'review_saved_at': at,
    };
    return at;
  }

  @override
  Future<Map<String, dynamic>> confirm(String id, String savedAt) async {
    confirmed.add(savedAt);
    return {'concepts': [], 'folders': [], 'sources': 0};
  }
}

Future<void> _pumpReview(WidgetTester tester, _DraftService svc) async {
  tester.view.physicalSize = const Size(1600, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => showConceptDraftReviewDialog(context,
                draftId: 'd1', service: svc, chat: ConceptChatController.forTest(draftMode: true)),
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

ReviewItem _ri(int i, String title,
        {ReviewRelation? relation, String type = '정의', List<String>? folder, String? anchor}) =>
    ReviewItem(
      index: i,
      mark: ReviewMark.keep,
      title: title,
      content: '$title 내용',
      type: type,
      folder: folder ?? const ['확률과 통계', '확률'],
      relation: relation,
      anchor: anchor,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThinkSendLock.instance.resetForTest();
  });

  group('검토 항목의 관계', () {
    test('저장 형식: 새 개념은 기존 개념을 남기지 않고, 고른 개념 이름은 표시용으로만 남긴다', () {
      const rel = ReviewRelation(kind: ReviewRelationKind.statement, conceptId: _a, conceptName: '확률 (기본)');
      final it = _ri(0, '확률', relation: rel);
      final back = ReviewItem.fromJson(it.toJson());
      expect(back.relation, rel);
      expect(it.toJson()['relation'], {'kind': 'statement', 'concept_id': _a, 'concept_name': '확률 (기본)'});
      expect(ReviewRelation.fromJson({'kind': 'new', 'concept_id': _a})!.conceptId, isNull);
      expect(ReviewRelation.fromJson({'kind': 'merge'}), isNull, reason: '모르는 관계는 정하지 않은 것으로 읽는다');
      expect(_ri(0, '확률').toJson().containsKey('relation'), isFalse);
      expect(sameReview([it], [it.copyWith(clearRelation: true)]), isFalse, reason: '관계만 바꿔도 저장 안 된 편집');
    });

    test('다른 서술로 붙이면 유형·폴더를 묻지 않고, 기존 개념이 필요한 관계는 개념을 골라야 확정할 수 있다', () {
      final statement = _ri(0, '확률',
          type: '',
          folder: const [],
          relation: const ReviewRelation(kind: ReviewRelationKind.statement, conceptId: _a));
      expect(reviewProblem([statement], const ['확률과 통계']), isNull);
      final noTarget = _ri(1, '조건부확률', relation: const ReviewRelation(kind: ReviewRelationKind.extendsOf));
      expect(reviewProblem([noTarget], const ['확률과 통계'], types: _types), contains('기존 개념을 고르세요'));
      final review = _ri(1, '조건부확률', relation: const ReviewRelation(kind: ReviewRelationKind.review));
      expect(reviewProblem([review], const ['확률과 통계'], types: _types), isNull, reason: '검토 필요는 상대 없이도 된다');
    });

    test('다른 서술로 붙는 항목은 주제 묶음·폴더 계산에서 빠진다', () {
      const st = ReviewRelation(kind: ReviewRelationKind.statement, conceptId: _a);
      final items = [
        _ri(0, '확률', relation: st),
        _ri(1, '여사건의 확률', anchor: 'c0'),
        _ri(2, '배반사건', folder: const ['확률과 통계', '사건'], relation: st),
      ];
      expect(reviewAnchorLinks(items), isEmpty);
      expect(reviewFolderPaths(items).map((p) => p.join('>')), ['확률과 통계', '확률과 통계>확률']);
    });

    test('정하지 않은 항목은 같은 이름·겹침이 있으면 검토 필요로 들어간다고 미리 센다', () {
      final r = ConceptDraftRecord.fromRow(_draftRow(overlaps: [
        {'concept': 1, 'other': '라이브러리 여사건', 'reason': '같은 성질'},
      ]));
      final items = [_ri(0, '확률'), _ri(1, '여사건의 확률')];
      final s = reviewRelationSummary(r, items, libraryNames: {'확률'});
      expect(s.sameName, ['확률']);
      expect(s.overlap, ['여사건의 확률']);
      final text = reviewRelationSentence(s)!;
      expect(text, contains('"검토 필요"로 표시합니다'));
      expect(text, contains('확률(같은 이름)'));

      final chosen = reviewRelationSummary(r, [
        _ri(0, '확률', relation: const ReviewRelation(kind: ReviewRelationKind.statement, conceptId: _a)),
        _ri(1, '여사건의 확률', relation: const ReviewRelation(kind: ReviewRelationKind.newConcept)),
      ], libraryNames: {
        '확률'
      });
      expect(chosen.autoReviews, 0, reason: '고른 관계는 자동 표시하지 않는다');
      expect(reviewRelationSentence(chosen), contains('기존 개념의 다른 서술 1개'));

      final unknown = reviewRelationSummary(r, items);
      expect(unknown.sameName, isEmpty);
      expect(reviewRelationSentence(unknown), contains('라이브러리 이름을 읽지 못했습니다'));
    });

    test('한 번에 확정 계획도 초안마다 관계를 센다', () {
      final plan = planDraftBatchConfirm(
        [ConceptDraftRecord.fromRow(_draftRow())],
        libraryPaths: const [
          ['확률과 통계'],
          ['확률과 통계', '확률'],
        ],
        types: _types,
        libraryNames: {'확률'},
      );
      expect(plan.ready, hasLength(1));
      expect(plan.relationTotal.sameName, ['확률']);
      expect(plan.namesKnown, isTrue);

      final row = _draftRow()
        ..['review'] = {
          'concepts': [
            _ri(0, '확률', relation: const ReviewRelation(kind: ReviewRelationKind.statement, conceptId: _a)).toJson(),
            _ri(1, '여사건의 확률', type: '성질').toJson(),
          ],
          'new_types': [],
        }
        ..['review_saved_at'] = '2026-10-20T10:00:00Z';
      final blocked = planDraftBatchConfirm(
        [
          ConceptDraftRecord.fromRow(row),
          ConceptDraftRecord.fromRow({..._draftRow(), 'id': 'd2'})
        ],
        libraryPaths: const [
          ['확률과 통계'],
          ['확률과 통계', '확률'],
        ],
        types: _types,
        relationsBlocked: '관계 저장소 없음',
      );
      expect(blocked.blocked.single.reason, '관계 저장소 없음', reason: '관계를 고른 초안만 막는다');
      expect(blocked.ready.single.id, 'd2');
    });
  });

  group('관계 저장소', () {
    test('검토 필요를 반대 방향 확장으로 닫으면 관계가 생기고 트리 표시가 사라진다', () async {
      final mem = _MemRelations()
        ..reviews.add(const ConceptReview(id: 'rv-0', conceptId: _a, otherId: _b, reason: 'same_name', open: true));
      final store = ConceptRelationStore(() => mem);
      await store.loadOpen();
      await store.load(_a);
      expect(store.reviewOpen(_a), isTrue);
      expect(store.pickOf(_b)?.label, '확률 (기본-2)');

      final err =
          await store.resolveReview(store.openReviewsOf(_a).single, ConceptReviewResolution.extendsOf, reverse: true);
      expect(err, isNull);
      expect(mem.relations.single.conceptId, _b, reason: '비교 개념 → 표시된 개념');
      expect(store.relationsOf(_a).single.kind, ConceptRelationKind.extendsOf);
      expect(store.reviewOpen(_a), isFalse);
      expect(store.closedReviewsOf(_a).single.resolution, ConceptReviewResolution.extendsOf);
    });

    test('반대 방향 관계가 있으면 이유를 돌려주고 아무것도 바꾸지 않는다', () async {
      final mem = _MemRelations();
      final store = ConceptRelationStore(() => mem);
      await store.load(_a);
      expect(await store.setRelation(conceptId: _a, relatedId: _c, kind: ConceptRelationKind.specialCase), isNull);
      final err = await store.setRelation(conceptId: _c, relatedId: _a, kind: ConceptRelationKind.extendsOf);
      expect(err, isNotNull);
      expect(mem.relations, hasLength(1));
    });

    test('직접 저장: 한 쌍에 다른 유형은 함께 두고, 같은 유형·맥락·막힌 반대 방향·맥락 없는 의존은 막는다', () async {
      final mem = _MemRelations();
      final store = ConceptRelationStore(() => mem);
      await store.load(_a);
      expect(
          await store.saveRelation(
              conceptId: _a, relatedId: _b, kind: ConceptRelationKind.dependsOn, context: '증명할 때'),
          isNull);
      expect(await store.saveRelation(conceptId: _a, relatedId: _b, kind: ConceptRelationKind.kindOf), isNull);
      expect(store.relationsOf(_a), hasLength(2));

      expect(
          await store.saveRelation(
              conceptId: _a, relatedId: _b, kind: ConceptRelationKind.dependsOn, context: ' 증명할 때 '),
          contains('이미 있습니다'));
      expect(
          await store.saveRelation(
              conceptId: _b, relatedId: _a, kind: ConceptRelationKind.dependsOn, context: '정의할 때'),
          isNull,
          reason: '학습 의존은 맥락이 다르면 반대 방향도 둔다');
      expect(await store.saveRelation(conceptId: _b, relatedId: _a, kind: ConceptRelationKind.kindOf), contains('반대 방향'));
      expect(await store.saveRelation(conceptId: _a, relatedId: _c, kind: ConceptRelationKind.derivedFrom), contains('맥락'));
      expect(mem.relations, hasLength(3));
    });

    test('읽은 판으로만 고치고 뺀다: 그사이 바뀐 관계는 덮어쓰거나 빼지 않는다', () async {
      final mem = _MemRelations();
      final store = ConceptRelationStore(() => mem);
      await store.load(_a);
      await store.saveRelation(conceptId: _a, relatedId: _b, kind: ConceptRelationKind.kindOf);
      final read = store.relationsOf(_a).single;
      await mem.saveRelation(
          id: read.id, rev: read.rev, conceptId: _a, relatedId: _b, kind: ConceptRelationKind.kindOf, basis: '다른 창');

      final err =
          await store.saveRelation(editing: read, conceptId: _a, relatedId: _b, kind: ConceptRelationKind.partOf);
      expect(err, contains('바뀌었습니다'));
      expect(mem.relations.single.kind, ConceptRelationKind.kindOf);
      expect(await store.removeRelation(read), contains('바뀌었습니다'));
      expect(mem.relations, hasLength(1));

      final fresh = store.relationsOf(_a).single;
      expect(fresh.basis, '다른 창');
      expect(await store.removeRelation(fresh), isNull);
      expect(mem.relations, isEmpty);
      expect(mem.pickRows, hasLength(3), reason: '관계만 뺀다');
    });
  });

  group('관계 유형', () {
    test('여섯 유형을 읽고, 맥락이 필요한 두 유형은 맥락 안에서만 성립한다고 읽는다', () {
      for (final k in ConceptRelationKind.values) {
        expect(ConceptRelationKindX.fromDb(k.db), k);
      }
      expect(ConceptRelationKindX.fromDb('prerequisite'), isNull);
      expect({
        for (final k in ConceptRelationKind.values)
          if (k.contextRequired) k
      }, {ConceptRelationKind.derivedFrom, ConceptRelationKind.dependsOn});

      expect(ConceptRelationKind.dependsOn.sentence('A', 'B', '넓이 공식을 증명할 때'),
          '맥락 "넓이 공식을 증명할 때"에서: "A"을(를) 배우거나 쓰려면 "B"이(가) 필요');
      expect(ConceptRelationKind.dependsOn.sentence('A', 'B'), contains('맥락이 기록되지 않음'));
      expect(ConceptRelationKind.derivedFrom.sentence('A', 'B'), contains('맥락 기록 없음'));
      expect(ConceptRelationKind.kindOf.sentence('A', 'B', '자연수 범위에서'), '"A"은(는) "B"의 한 종류 · 맥락: 자연수 범위에서');
      expect(ConceptRelationKind.extendsOf.sentence('A', 'B'), '"A"은(는) "B"을(를) 넓힌 개념', reason: '옛 문장 그대로');
      expect(ConceptRelationKind.specialCase.sentence('A', 'B'), '"A"은(는) "B"의 특수한 경우');
      expect(ConceptRelationKind.kindOf.label, isNot(ConceptRelationKind.specialCase.label));
    });

    test('관계 목록: 방향·생긴 곳과 결정·결정 기록 없음·다시 검토·승인 대기·이력을 읽는다', () {
      final sheet = conceptRelationSheetFromJson({
        'id': _a,
        'name': '확률',
        'relations': [
          {
            'id': 'r1',
            'direction': 'out',
            'from': {'id': _a, 'name': '확률', 'text_rev': 'aaa'},
            'to': {'id': _b, 'name': '확률', 'text_rev': 'bbb'},
            'kind': 'depends_on',
            'context': '여사건으로 계산할 때',
            'basis': '교재 풀이',
            'note': null,
            'origin': 'draft',
            'rev': 2,
            'created_at': '2026-10-20T01:00:00Z',
            'decision': {'recorded': true, 'via': 'think', 'at': '2026-10-23T01:00:00Z', 'action_id': 'act1'},
            'judged': {'recorded': true, 'from_changed': false, 'to_changed': true},
            'rereview': true,
          },
          {
            'id': 'r2',
            'direction': 'in',
            'from': {'id': _c, 'name': '조건부확률', 'text_rev': 'ccc'},
            'to': {'id': _a, 'name': '확률', 'text_rev': 'aaa'},
            'kind': 'extends',
            'context': null,
            'basis': null,
            'origin': 'manual',
            'rev': 1,
            'decision': {'recorded': false},
            'judged': {'recorded': false},
            'rereview': null,
          },
          {
            'id': 'r3',
            'from': {'id': _c},
            'to': {'id': _a},
            'kind': 'unknown_kind',
          },
        ],
        'pending': [
          {'action_id': 'act2', 'item': 1, 'op': 'change', 'relation_id': 'r1'},
          {'action_id': 'act2', 'item': 2, 'op': 'add', 'relation_id': null},
        ],
        'events': [
          {
            'event': 'remove',
            'relation_id': 'r0',
            'concept_name': '확률',
            'related_name': '지운 개념',
            'before': {'kind': 'part_of', 'context': null},
            'after': null,
            'via': 'think',
            'reason': '겹침',
            'at': '2026-10-22T01:00:00Z',
          },
        ],
        'event_count': 3,
      });

      expect(sheet.relations.map((r) => r.id), ['r1', 'r2'], reason: '모르는 유형은 보이지 않는다');
      final r1 = sheet.relations[0];
      expect([r1.conceptId, r1.relatedId], [_a, _b]);
      expect(r1.context, '여사건으로 계산할 때');
      expect(r1.rev, 2);
      expect(r1.originLabel, '초안 확정 때 생김');
      expect(r1.decisionLabel, 'Think 카드를 운영자가 승인', reason: '생긴 곳과 정한 길은 따로');
      expect(r1.decision!.actionId, 'act1');
      expect(r1.rereview, isTrue);
      expect(r1.pendingCards, 1);

      final r2 = sheet.relations[1];
      expect([r2.conceptId, r2.relatedId], [_c, _a], reason: '들어오는 관계는 상대 → 이 개념');
      expect(r2.decision, isNull);
      expect(r2.decisionLabel, contains('결정 기록 없음'));
      expect(r2.rereview, isNull);

      expect(sheet.pendingAdds, 1);
      expect(sheet.eventCount, 3);
      final e = sheet.events.single;
      expect([e.eventLabel, e.relatedName, e.kind, e.via], ['뺌', '지운 개념', ConceptRelationKind.partOf, 'think']);
    });
  });

  group('개념 상세 관계 칸', () {
    testWidgets('검토 필요 표시와 판단하기: 방향을 골라 기록하고, 개념은 합치거나 옮기지 않는다', (tester) async {
      final mem = _MemRelations()
        ..reviews.add(const ConceptReview(id: 'rv-0', conceptId: _a, otherId: _b, reason: 'same_name', open: true));
      final c = ConceptLibraryController.forTest(_Lib(), chat: ConceptChatController.forTest(), relationBackend: mem);
      c.selectConcept(_item());
      await _pumpDetail(tester, c);

      expect(find.byKey(const ValueKey('concept-review-rv-0')), findsOneWidget);
      expect(find.text('비교할 개념: "확률 (기본-2)"'), findsOneWidget);
      expect(find.text('검토 필요'), findsOneWidget, reason: '머리 배지');

      await tester.tap(find.byKey(const ValueKey('review-resolve-rv-0')));
      await tester.pumpAndSettle();
      expect(tester.widget<ElevatedButton>(find.byKey(const ValueKey('decision-save'))).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('decision-special_case')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decision-reverse')));
      await tester.pumpAndSettle();
      expect(find.textContaining('기록할 판단: "확률 (기본-2)"은(는) "확률"의 특수한 경우'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('decision-save')));
      await tester.pumpAndSettle();

      expect(mem.calls, ['resolve:rv-0:special_case:reverse']);
      expect(find.byKey(const ValueKey('concept-review-rv-0')), findsNothing);
      expect(find.text('검토 필요'), findsNothing);
      expect(find.byKey(ValueKey('concept-relation-${mem.relations.single.id}')), findsOneWidget);
      expect(find.text('지난 판단 1건'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('관계 더하기: 개념을 고르고 확장으로 잇는다', (tester) async {
      final mem = _MemRelations();
      final c = ConceptLibraryController.forTest(_Lib(), chat: ConceptChatController.forTest(), relationBackend: mem);
      c.selectConcept(_item());
      await _pumpDetail(tester, c);
      expect(find.textContaining('이은 관계가 없습니다'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('relation-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('concept-pick-$_a')), findsNothing, reason: '자기 자신은 고를 수 없다');
      await tester.tap(find.byKey(const ValueKey('concept-pick-$_b')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decision-extends')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decision-save')));
      await tester.pumpAndSettle();

      expect(mem.calls, ['save:new:$_a>$_b:extends:-']);
      expect(find.text('"확률"은(는) "확률 (기본-2)"을(를) 넓힌 개념'), findsOneWidget);
    });

    testWidgets('관계 더하기: 학습 의존은 맥락을 적어야 저장되고, 맥락 안에서만 필요하다고 읽는다', (tester) async {
      final mem = _MemRelations();
      final c = ConceptLibraryController.forTest(_Lib(), chat: ConceptChatController.forTest(), relationBackend: mem);
      c.selectConcept(_item());
      await _pumpDetail(tester, c);

      await tester.tap(find.byKey(const ValueKey('relation-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('concept-pick-$_c')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decision-depends_on')));
      await tester.pumpAndSettle();
      expect(find.text('맥락(필수)'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(find.byKey(const ValueKey('decision-save'))).onPressed, isNull,
          reason: '맥락 없이는 저장하지 않는다');

      await tester.tap(find.byKey(const ValueKey('decision-reverse')));
      await tester.enterText(find.byKey(const ValueKey('relation-context')), '여사건으로 계산할 때');
      await tester.enterText(find.byKey(const ValueKey('relation-basis')), '교재 풀이에서 확률의 덧셈정리를 씀');
      await tester.pumpAndSettle();
      expect(find.textContaining('기록할 관계: 맥락 "여사건으로 계산할 때"에서: "조건부확률 (기본)"을(를) 배우거나 쓰려면 "확률"이(가) 필요'),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('decision-save')));
      await tester.pumpAndSettle();

      expect(mem.calls, ['save:new:$_c>$_a:depends_on:여사건으로 계산할 때'], reason: '조건부확률 → 확률(기준)');
      final rel = mem.relations.single;
      expect(find.text('맥락 "여사건으로 계산할 때"에서: "조건부확률 (기본)"을(를) 배우거나 쓰려면 "확률"이(가) 필요'), findsOneWidget);
      expect(find.text('"조건부확률 (기본)"을(를) 배우거나 쓰려면 "확률"이(가) 필요'), findsNothing,
          reason: '조건 없는 선수 관계처럼 보이지 않는다');
      expect(find.text('근거: 교재 풀이에서 확률의 덧셈정리를 씀'), findsOneWidget);
      expect(find.text('학습 의존 · 운영자가 직접 저장'), findsOneWidget);
      expect(find.byKey(ValueKey('relation-edit-${rel.id}')), findsOneWidget);
      expect(find.text('관계 이력 1건'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('관계 더하기에서 판단만 기록하면 관계를 만들지 않는다', (tester) async {
      final mem = _MemRelations();
      final c = ConceptLibraryController.forTest(_Lib(), chat: ConceptChatController.forTest(), relationBackend: mem);
      c.selectConcept(_item());
      await _pumpDetail(tester, c);
      await tester.tap(find.byKey(const ValueKey('relation-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('concept-pick-$_b')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decision-different')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('relation-context')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('decision-save')));
      await tester.pumpAndSettle();
      expect(mem.calls, ['pair:$_a>$_b:different']);
      expect(mem.relations, isEmpty);
    });

    testWidgets('기록 없는 옛 관계: "결정 기록 없음"·다시 검토 표시, 고치면 읽은 판으로 보내고 그사이 바뀌었으면 덮어쓰지 않는다',
        (tester) async {
      final mem = _MemRelations()
        ..relations.add(const ConceptRelation(
            id: 'rel-old',
            conceptId: _a,
            relatedId: _b,
            kind: ConceptRelationKind.specialCase,
            origin: 'draft',
            rev: 1,
            rereview: true));
      final c = ConceptLibraryController.forTest(_Lib(), chat: ConceptChatController.forTest(), relationBackend: mem);
      c.selectConcept(_item());
      await _pumpDetail(tester, c);

      expect(find.text('특수한 경우 · 결정 기록 없음'), findsOneWidget);
      expect(find.text('다시 검토 필요'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('relation-edit-rel-old')));
      await tester.pumpAndSettle();
      expect(find.textContaining('판단한 뒤 두 개념 중 하나의 글이 바뀌었습니다'), findsOneWidget);
      expect(find.byKey(const ValueKey('decision-different')), findsNothing, reason: '고칠 때는 판단만 기록하는 길이 없다');
      expect(tester.widget<ElevatedButton>(find.byKey(const ValueKey('decision-save'))).onPressed, isNull,
          reason: '바꾼 것이 없으면 저장하지 않는다');
      await tester.tap(find.byKey(const ValueKey('decision-kind_of')));
      await tester.pumpAndSettle();

      // 창을 연 사이에 다른 곳에서 이 관계를 고쳤다.
      await mem.saveRelation(
          id: 'rel-old', rev: 1, conceptId: _a, relatedId: _b, kind: ConceptRelationKind.specialCase, basis: '다른 창');
      mem.calls.clear();
      await tester.tap(find.byKey(const ValueKey('decision-save')));
      await tester.pumpAndSettle();

      expect(mem.calls, ['save:rel-old:$_a>$_b:kind_of:-']);
      expect(find.textContaining('읽은 뒤 이 관계가 바뀌었습니다'), findsOneWidget);
      expect(mem.relations.single.kind, ConceptRelationKind.specialCase, reason: '옛 판으로는 덮어쓰지 않는다');
      expect(mem.relations.single.basis, '다른 창');
      expect(find.text('근거: 다른 창'), findsOneWidget, reason: '실패한 뒤 지금 것을 다시 읽는다');
      expect(tester.takeException(), isNull);
    });

    testWidgets('관계 빼기는 관계만 지우고 두 개념은 그대로 둔다', (tester) async {
      final mem = _MemRelations()
        ..relations.add(const ConceptRelation(
            id: 'rel-x', conceptId: _c, relatedId: _a, kind: ConceptRelationKind.partOf, origin: 'manual', rev: 3));
      final c = ConceptLibraryController.forTest(_Lib(), chat: ConceptChatController.forTest(), relationBackend: mem);
      c.selectConcept(_item());
      await _pumpDetail(tester, c);
      await tester.tap(find.byKey(const ValueKey('relation-remove-rel-x')));
      await tester.pumpAndSettle();
      expect(find.textContaining('두 개념과 다른 관계는 그대로 남고'), findsOneWidget);
      await tester.tap(find.text('빼기'));
      await tester.pumpAndSettle();
      expect(mem.calls, ['remove:rel-x']);
      expect(mem.relations, isEmpty);
      expect(mem.pickRows, hasLength(3), reason: '개념은 그대로');
      expect(find.textContaining('이은 관계가 없습니다'), findsOneWidget);
      expect(find.textContaining('· 뺌: "조건부확률"은(는) "확률"을(를) 이루는 요소'), findsOneWidget);
    });

    testWidgets('고칠 때 붙은 것을 센다', (tester) async {
      final mem = _MemRelations()
        ..relations.add(const ConceptRelation(
            id: 'rel-x', conceptId: _c, relatedId: _a, kind: ConceptRelationKind.specialCase, origin: 'manual'));
      final c = ConceptLibraryController.forTest(_Lib(), chat: ConceptChatController.forTest(), relationBackend: mem);
      c.selectConcept(_item());
      await _pumpDetail(tester, c);
      final text = conceptEditImpact(c, _item());
      expect(text, contains('다른 개념과의 관계 1개'));
      expect(text, contains('자동으로 바뀌거나 옮겨지지 않습니다'));
    });
  });

  group('같은 이름 검토 창', () {
    testWidgets('한 쌍씩 판단하고, 판단한 쌍은 "판단 전만"에서 빠진다', (tester) async {
      final mem = _MemRelations();
      final store = ConceptRelationStore(() => mem);
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => showSameNameReviewDialog(context, store: store), child: const Text('열기')),
          ),
        ),
      ));
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('same-name-확률')), findsOneWidget);
      expect(find.text('판단 전'), findsOneWidget);
      final pair = find.byKey(ValueKey('same-name-decide-$_a-$_b'));
      await tester.tap(pair);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decision-different')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decision-save')));
      await tester.pumpAndSettle();

      expect(mem.calls, ['pair:$_a>$_b:different']);
      expect(find.text('판단 전인 쌍이 없습니다.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('same-name-only-undecided')));
      await tester.pumpAndSettle();
      expect(find.text('"확률 (기본)"와(과) "확률 (기본-2)"은(는) 서로 다른 개념'), findsOneWidget);
      expect(mem.pickRows, hasLength(3), reason: '개념은 그대로');
      expect(tester.takeException(), isNull);
    });
  });

  group('트리 표시', () {
    testWidgets('검토 필요 개념은 칩에 깃발을 단다', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(children: [
            ConceptTypeChip(name: '확률', style: conceptTypeStyle('정의'), review: true),
            ConceptTypeChip(name: '조건부확률', style: conceptTypeStyle('정의')),
          ]),
        ),
      ));
      expect(find.byType(ConceptReviewMark), findsOneWidget);
    });
  });

  group('초안 검토 카드의 관계', () {
    testWidgets('같은 이름을 알려 주고, 다른 서술로 붙이면 유형·폴더를 감추고 저장·확정에 관계를 넘긴다', (tester) async {
      final svc = _DraftService(_MemRelations());
      await _pumpReview(tester, svc);

      expect(find.byKey(const ValueKey('draft-same-name-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('draft-same-name-1')), findsNothing);
      expect(find.byKey(const ValueKey('draft-type-0')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('draft-relation-kind-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('기존 개념의 다른 서술').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('concept-pick-$_b')));
      await tester.pumpAndSettle();

      expect(find.text('확률 (기본-2)'), findsOneWidget);
      expect(find.byKey(const ValueKey('draft-type-0')), findsNothing);
      expect(find.byKey(const ValueKey('draft-anchor-0')), findsNothing);
      expect(find.byKey(const ValueKey('draft-same-name-0')), findsNothing);

      await tester.tap(find.textContaining('확정하고 라이브러리에 넣기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('새 개념 1개를 넣고 기존 개념에 서술 1개를 더합니다'), findsOneWidget);
      expect(find.textContaining('기존 개념의 다른 서술 1개'), findsOneWidget);
      await tester.tap(find.text('확정'));
      await tester.pumpAndSettle();

      final rel = svc.saved.single[0].relation!;
      expect(rel.kind, ReviewRelationKind.statement);
      expect(rel.conceptId, _b);
      expect(svc.saved.single[1].relation, isNull);
      expect(svc.confirmed, hasLength(1));
    });

    testWidgets('관계 마이그레이션 전이면 관계를 고른 검토는 확정하지 않는다', (tester) async {
      final svc = _DraftService(_MemRelations())..relationsTable = false;
      await _pumpReview(tester, svc);
      await tester.tap(find.byKey(const ValueKey('draft-relation-kind-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('새 개념').last);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('확정하고 라이브러리에 넣기'));
      await tester.pumpAndSettle();
      expect(find.text(kConceptRelationsNotReady), findsOneWidget);
      expect(find.text('라이브러리에 넣을까요?'), findsNothing);
      expect(svc.confirmed, isEmpty);
    });

    testWidgets('관계를 정하지 않으면 확정 안내에 "검토 필요"로 들어갈 항목을 보인다', (tester) async {
      final svc = _DraftService(_MemRelations());
      await _pumpReview(tester, svc);
      await tester.tap(find.textContaining('확정하고 라이브러리에 넣기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('관계를 정하지 않은 1개는 새 개념으로 넣고 "검토 필요"로 표시합니다: 확률(같은 이름)'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(svc.confirmed, isEmpty);
    });
  });
}

const _types = [
  ConceptTypeInfo(name: '정의', description: '뜻', legacySubType: '정의'),
  ConceptTypeInfo(name: '성질', description: '사실', legacySubType: '정리'),
];
