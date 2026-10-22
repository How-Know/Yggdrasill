import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_draft_list_dialog.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_draft_review_dialog.dart';
import 'package:yggdrasill_manager/services/concept_book_service.dart';
import 'package:yggdrasill_manager/services/concept_draft_compare.dart';
import 'package:yggdrasill_manager/services/concept_draft_models.dart';
import 'package:yggdrasill_manager/services/concept_draft_service.dart';
import 'package:yggdrasill_manager/services/concept_relation_service.dart';
import 'package:yggdrasill_manager/services/textbook_pdf_service.dart';
import 'package:yggdrasill_manager/services/think/think_concept_chat_controller.dart';
import 'package:yggdrasill_manager/services/think/think_send_lock.dart';

final _noHttp = MockClient((_) async => http.Response('', 404));

const _a = '6f1d2c3b-4a5e-4f60-8a7b-9c0d1e2f3a4b';
const _b = '7a2e3d4c-5b6f-4a71-9b8c-0d1e2f3a4b5c';
const _st = '8b3f4e5d-6c7a-4b82-8c9d-1e2f3a4b5c6d';

const _pa = ConceptPick(id: _a, name: '확률', versionLabel: '기본', folder: ['확률과 통계', '확률']);
const _pb = ConceptPick(id: _b, name: '여사건', versionLabel: '기본', folder: ['확률과 통계', '확률']);

const _types = [
  ConceptTypeInfo(name: '정의', description: '뜻', legacySubType: '정의'),
  ConceptTypeInfo(name: '성질', description: '사실', legacySubType: '정리'),
];

ConceptCompareTarget _target(String id, String name, {bool draft = false}) => ConceptCompareTarget.fromJson({
      'id': id,
      'name': name,
      'folder': ['확률과 통계', '확률'],
      'content': '$name 기본 본문',
      'statements': [
        {'id': _st, 'confirmed': false, 'text': '다른 교재 설명\n자세한 글'},
      ],
      'sources': 3,
      'books': ['쎈'],
      'content_draft': draft,
    });

Map<String, dynamic> _draftRow() => {
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
        'overlaps': [],
        'roots': ['확률과 통계'],
        'checks': {},
      },
      'review': {},
      'review_saved_at': null,
      'created_at': '2026-10-20T09:00:00Z',
    };

class _Svc extends ConceptDraftService {
  _Svc() : super(books: ConceptBookService(pdf: TextbookPdfService(httpClient: _noHttp), httpClient: _noHttp));

  Map<String, dynamic> row = _draftRow();
  bool ready = true;
  Map<String, ConceptCompareTarget> targets = {_a: _target(_a, '확률'), _b: _target(_b, '여사건')};
  ConceptCompareProposal? proposal;
  final List<List<ReviewItem>> saved = [];
  final List<String> confirmed = [];
  final List<String> proposedFor = [];
  List<ConceptDraftHold> holds = [];
  final List<String> reopened = [];
  final List<(String, String?)> dropped = [];

  @override
  Future<ConceptDraftRecord> fetchDraft(String id) async => ConceptDraftRecord.fromRow(row);

  @override
  Future<List<List<String>>> libraryFolderPaths() async => const [
        ['확률과 통계'],
        ['확률과 통계', '확률'],
      ];

  @override
  Future<List<ConceptTypeInfo>> conceptTypes() async => _types;

  @override
  Future<bool> relationsReady() async => true;

  @override
  Future<bool> compareReady() async => ready;

  @override
  Future<List<ConceptPick>> searchLibraryConcepts(String query) async => const [_pa, _pb];

  @override
  Future<Map<String, List<ConceptPick>>> libraryConceptsNamed(Iterable<String> names) async => const {};

  @override
  Future<List<ConceptCompareTarget>> compareTargets(List<String> ids) async => [
        for (final id in ids)
          if (targets[id] != null) targets[id]!
      ];

  @override
  Future<ConceptCompareProposal> proposeCompare(String draftId, {List<String>? keys}) async {
    proposedFor.add(draftId);
    return proposal!;
  }

  @override
  Future<String> saveReview(String id, List<ReviewItem> items, String? expectedSavedAt,
      {List<ReviewNewType> newTypes = const []}) async {
    saved.add(items);
    final at = '2026-10-20T10:00:0${saved.length}+00:00';
    row = {
      ...row,
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

  @override
  Future<List<ConceptDraftSummary>> listDrafts({bool openOnly = true, int limit = 50}) async => const [];

  @override
  Future<List<ConceptDraftHold>> openHolds() async => holds;

  @override
  Future<String> reopenHolds(String draftId) async {
    reopened.add(draftId);
    return 'd-new';
  }

  @override
  Future<void> dropHold(String holdId, {String? note}) async {
    dropped.add((holdId, note));
    holds = [
      for (final h in holds)
        if (h.id != holdId) h
    ];
  }
}

Future<void> _pumpReview(WidgetTester tester, _Svc svc) async {
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

Future<void> _chooseKind(WidgetTester tester, int item, String label) async {
  await tester.tap(find.byKey(ValueKey('draft-relation-kind-$item')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

ReviewItem _ri(int i, String title, {ReviewRelation? relation, String type = '정의', List<String>? folder}) => ReviewItem(
      index: i,
      mark: ReviewMark.keep,
      title: title,
      content: '$title 내용',
      type: type,
      folder: folder ?? const ['확률과 통계', '확률'],
      relation: relation,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ThinkSendLock.instance.resetForTest();
  });

  group('비교 관계 모델', () {
    test('출처만 연결은 이을 서술을 함께 저장하고, 다른 관계에서는 서술을 읽지 않는다', () {
      const rel = ReviewRelation(
          kind: ReviewRelationKind.source,
          conceptId: _a,
          conceptName: '확률 (기본)',
          statementId: _st,
          statementLabel: '다른 교재 설명');
      final back = ReviewItem.fromJson(_ri(0, '확률', relation: rel).toJson());
      expect(back.relation, rel);
      expect(
          ReviewRelation.fromJson({'kind': 'statement', 'concept_id': _a, 'statement_id': _st})!.statementId, isNull);
      expect(ReviewRelation.fromJson({'kind': 'hold', 'concept_id': _a})!.conceptId, isNull, reason: '보류는 대상을 남기지 않는다');
      expect(ReviewRelationKind.source.needsTarget && ReviewRelationKind.revise.needsTarget, isTrue);
      expect(ReviewRelationKind.hold.needsTarget, isFalse);
    });

    test('출처만·수정안·보류는 유형·폴더를 묻지 않고, 같은 개념에 수정안 둘은 막는다', () {
      ReviewItem bare(int i, ReviewRelationKind k, [String? target]) =>
          _ri(i, '항목$i', type: '', folder: const [], relation: ReviewRelation(kind: k, conceptId: target));
      expect(
          reviewProblem([
            bare(0, ReviewRelationKind.source, _a),
            bare(1, ReviewRelationKind.revise, _b),
            bare(2, ReviewRelationKind.hold),
          ], const [
            '확률과 통계'
          ], types: _types),
          isNull);
      expect(reviewProblem([bare(0, ReviewRelationKind.source)], const ['확률과 통계']), contains('기존 개념을 고르세요'));
      expect(
          reviewProblem(
              [bare(0, ReviewRelationKind.revise, _a), bare(1, ReviewRelationKind.revise, _a)], const ['확률과 통계']),
          contains('수정안은 개념마다 하나'));
      final items = [
        _ri(0, '확률', relation: const ReviewRelation(kind: ReviewRelationKind.source, conceptId: _a)),
        _ri(1, '여사건', folder: const ['확률과 통계', '사건'], relation: const ReviewRelation(kind: ReviewRelationKind.hold)),
        _ri(2, '조건부'),
      ];
      expect(reviewFolderPaths(items).map((p) => p.join('>')), ['확률과 통계', '확률과 통계>확률']);
      expect(needsCompareMigration(items), isTrue);
      expect(needsCompareMigration([items[2]]), isFalse);
    });

    test('확정 안내와 한 번에 확정 계획이 출처만·수정안·보류를 알린다', () {
      final r = ConceptDraftRecord.fromRow(_draftRow());
      final s = reviewRelationSummary(r, [
        _ri(0, '확률', relation: const ReviewRelation(kind: ReviewRelationKind.source, conceptId: _a)),
        _ri(1, '여사건', relation: const ReviewRelation(kind: ReviewRelationKind.revise, conceptId: _b)),
        _ri(1, '여사건2', relation: const ReviewRelation(kind: ReviewRelationKind.hold)),
      ]);
      final text = reviewRelationSentence(s)!;
      expect(text, contains('기존 개념에 출처만 연결 1개'));
      expect(text, contains('본문을 바꾸지 않고 수정안으로 저장합니다'));
      expect(text, contains('"보류한 항목" 목록에 남깁니다'));

      final row = _draftRow()
        ..['review'] = {
          'concepts': [
            _ri(0, '확률', relation: const ReviewRelation(kind: ReviewRelationKind.hold)).toJson(),
            _ri(1, '여사건의 확률', type: '성질').toJson(),
          ],
          'new_types': [],
        }
        ..['review_saved_at'] = '2026-10-20T10:00:00Z';
      final plan = planDraftBatchConfirm(
        [
          ConceptDraftRecord.fromRow(row),
          ConceptDraftRecord.fromRow({..._draftRow(), 'id': 'd2'})
        ],
        libraryPaths: const [
          ['확률과 통계'],
          ['확률과 통계', '확률'],
        ],
        types: _types,
        compareBlocked: '비교 기능 없음',
      );
      expect(plan.blocked.single.reason, '비교 기능 없음');
      expect(plan.ready.single.id, 'd2');
    });

    test('AI 비교 제안: 모르는 선택·대상 없는 줄은 버리고, 수정안이 있는 개념의 수정안 제안은 반영하지 않는다', () {
      final p = ConceptCompareProposal.fromJson({
        'summary': '요약',
        'items': [
          {
            'key': 'c0',
            'choice': 'source',
            'concept_id': _a,
            'concept_name': '확률',
            'statement_id': _st,
            'reason': '같음'
          },
          {'key': 'c1', 'choice': 'revise', 'concept_id': _b, 'concept_name': '여사건', 'draft_exists': true},
          {'key': 'c2', 'choice': 'statement', 'concept_id': null},
          {'key': 'c3', 'choice': 'merge', 'concept_id': _a},
          {'key': 'c4', 'choice': 'hold', 'concept_id': _a},
        ],
        'checks': {
          'no_candidates': ['c5'],
          'over_limit': [],
          'unanswered': ['c6']
        },
      });
      expect(p.items.keys, ['c0', 'c1', 'c4']);
      expect(p.items['c0']!.relation(statementLabel: '다른 교재 설명').statementId, _st);
      expect(p.items['c1']!.applicable, isFalse);
      expect(p.items['c4']!.relation().conceptId, isNull);
      expect(p.items['c0']!.sameAs(p.items['c0']!.relation()), isTrue);
      expect(p.notice, contains('비교할 기존 개념이 없어 보내지 않은 항목 1개'));
      expect(p.without('c0').items.keys, ['c1', 'c4']);
    });

    test('보류 항목은 초안 기록별로 묶는다', () {
      final holds = [
        for (final (id, draft) in [('h1', 'd1'), ('h2', 'd2'), ('h3', 'd1')])
          ConceptDraftHold.fromJson({'id': id, 'draft_id': draft, 'item_key': id, 'title': id, 'status': 'open'}),
      ];
      expect(groupHoldsByDraft(holds).map((g) => g.map((h) => h.id).toList()), [
        ['h1', 'h3'],
        ['h2'],
      ]);
    });
  });

  group('초안 검토 카드의 비교', () {
    testWidgets('출처만 연결: 개념과 서술을 고르고, 비교 칸에 기존 본문·서술·출처 수를 보인 뒤 관계를 넘겨 확정한다', (tester) async {
      final svc = _Svc();
      await _pumpReview(tester, svc);

      await _chooseKind(tester, 0, '기존 개념에 출처만 연결');
      await tester.tap(find.byKey(const ValueKey('concept-pick-$_a')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft-type-0')), findsNothing, reason: '새 개념이 아니라 유형을 묻지 않는다');
      expect(find.byKey(const ValueKey('draft-relation-statement-0')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('draft-relation-statement-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('다른 서술: 다른 교재 설명').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('draft-compare-toggle-0')));
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('draft-compare-panel-0'));
      expect(panel, findsOneWidget);
      expect(find.descendant(of: panel, matching: find.textContaining('확률 기본 본문', findRichText: true)), findsOneWidget);
      expect(find.descendant(of: panel, matching: find.textContaining('출처 3줄 · 쎈')), findsOneWidget);

      await tester.tap(find.textContaining('확정하고 라이브러리에 넣기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('새 개념 1개를 넣고, 1개는 새 개념 없이'), findsOneWidget);
      expect(find.textContaining('출처만 연결하는 항목은'), findsOneWidget);
      await tester.tap(find.text('확정'));
      await tester.pumpAndSettle();

      final rel = svc.saved.single[0].relation!;
      expect([rel.kind, rel.conceptId, rel.statementId], [ReviewRelationKind.source, _a, _st]);
      expect(svc.confirmed, hasLength(1));
    });

    testWidgets('대표 서술 수정안: 그 개념에 수정안이 이미 있으면 확정하지 않고 먼저 정리하라고 알린다', (tester) async {
      final svc = _Svc()..targets[_b] = _target(_b, '여사건', draft: true);
      await _pumpReview(tester, svc);
      await _chooseKind(tester, 1, '기존 개념의 대표 서술 수정안');
      await tester.tap(find.byKey(const ValueKey('concept-pick-$_b')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('draft-compare-toggle-1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('지금은 "대표 서술 수정안"으로 확정할 수 없습니다'), findsOneWidget);

      await tester.tap(find.textContaining('확정하고 라이브러리에 넣기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('이미 저장된 수정안이 있습니다: 여사건'), findsOneWidget);
      expect(find.text('라이브러리에 넣을까요?'), findsNothing);
      expect(svc.confirmed, isEmpty);
    });

    testWidgets('3단계 마이그레이션 전이면 보류를 고른 검토는 확정하지 않는다', (tester) async {
      final svc = _Svc()..ready = false;
      await _pumpReview(tester, svc);
      await _chooseKind(tester, 1, '보류(이번에 넣지 않음)');
      expect(find.byKey(const ValueKey('draft-type-1')), findsNothing);
      await tester.tap(find.textContaining('확정하고 라이브러리에 넣기'));
      await tester.pumpAndSettle();
      expect(find.text(kConceptCompareNotReady), findsOneWidget);
      expect(svc.confirmed, isEmpty);
    });

    testWidgets('AI 비교 제안: 저장한 검토로만 받고, 고른 줄만 관계(저장 전)에 반영한다', (tester) async {
      final svc = _Svc()
        ..proposal = ConceptCompareProposal.fromJson({
          'summary': '하나는 같은 설명입니다.',
          'items': [
            {
              'key': 'c0',
              'choice': 'source',
              'concept_id': _a,
              'concept_name': '확률 (기본)',
              'statement_id': null,
              'reason': '정의가 같음',
              'differences': '',
            },
            {'key': 'c1', 'choice': 'hold', 'concept_id': null, 'reason': '판단 어려움', 'differences': '조건이 다름'},
          ],
          'checks': {'no_candidates': [], 'over_limit': [], 'unanswered': []},
        });
      await _pumpReview(tester, svc);

      await tester.tap(find.byKey(const ValueKey('draft-compare-propose')));
      await tester.pumpAndSettle();
      expect(find.textContaining('먼저 "검토 저장"을 누르세요'), findsOneWidget);
      expect(svc.proposedFor, isEmpty);

      await tester.tap(find.text('검토 저장'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('draft-compare-propose')));
      await tester.pumpAndSettle();
      expect(svc.proposedFor, ['d1']);
      expect(find.textContaining('하나는 같은 설명입니다.'), findsOneWidget);
      expect(find.byKey(const ValueKey('draft-compare-suggest-0')), findsOneWidget);
      expect(find.textContaining('다른 점: 조건이 다름'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('draft-compare-apply-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('draft-compare-dismiss-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft-compare-suggest-0')), findsNothing);
      expect(find.byKey(const ValueKey('draft-compare-suggest-1')), findsNothing);
      expect(find.text('저장하지 않은 편집이 있습니다.'), findsOneWidget, reason: '반영은 저장 전 편집이다');

      await tester.tap(find.text('검토 저장'));
      await tester.pumpAndSettle();
      final last = svc.saved.last;
      expect([last[0].relation?.kind, last[0].relation?.conceptId], [ReviewRelationKind.source, _a]);
      expect(last[1].relation, isNull, reason: '무시한 제안은 넣지 않는다');
    });
  });

  group('보류한 항목', () {
    testWidgets('초안 기록별로 보이고, 다시 검토하면 새 초안을 열며, 버리면 이유와 함께 닫는다', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final svc = _Svc()
        ..holds = [
          for (final (id, draft, title) in [('h1', 'd1', '확률'), ('h2', 'd1', '여사건'), ('h3', 'd2', '조건부')])
            ConceptDraftHold.fromJson({
              'id': id,
              'draft_id': draft,
              'item_key': id,
              'title': title,
              'content': '$title 글',
              'status': 'open',
              'book_name': '개념+유형',
              'grade_label': '1-1',
              'unit_path': ['확률', draft],
            }),
        ];
      String? opened;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async => opened = await showConceptDraftListDialog(context, service: svc),
                child: const Text('목록'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('목록'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('draft-list-holds')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('hold-group-d1')), findsOneWidget);
      expect(find.byKey(const ValueKey('hold-group-d2')), findsOneWidget);
      expect(find.text('2개 다시 검토'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('hold-drop-h3')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('hold-drop-note')), '다른 책에 있음');
      await tester.tap(find.byKey(const ValueKey('hold-drop-confirm')));
      await tester.pumpAndSettle();
      expect(svc.dropped, [('h3', '다른 책에 있음')]);
      expect(find.byKey(const ValueKey('hold-group-d2')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('hold-reopen-d1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('다시 검토').last);
      await tester.pumpAndSettle();
      expect(svc.reopened, ['d1']);
      expect(opened, 'd-new');
    });
  });
}
