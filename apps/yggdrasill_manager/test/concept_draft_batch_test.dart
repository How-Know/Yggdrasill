import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_draft_batch_dialog.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_draft_list_dialog.dart';
import 'package:yggdrasill_manager/services/concept_book_service.dart';
import 'package:yggdrasill_manager/services/concept_draft_models.dart';
import 'package:yggdrasill_manager/services/concept_draft_service.dart';
import 'package:yggdrasill_manager/services/textbook_pdf_service.dart';

final _noHttp = MockClient((_) async => http.Response('', 404));

const _types = [ConceptTypeInfo(name: '정의', description: '뜻', legacySubType: '정의')];
const _library = [
  ['대수'],
  ['대수', '수와 연산'],
];

Map<String, dynamic> _review(String title, List<String> folder,
        {String type = '정의', List<Map<String, dynamic>> newTypes = const []}) =>
    {
      'concepts': [
        {'index': 0, 'mark': 'keep', 'title': title, 'content': '$title 내용', 'type': type, 'folder': folder},
      ],
      'new_types': newTypes,
    };

Map<String, dynamic> _row(
  String id,
  String unit, {
  Map<String, dynamic>? review,
  String status = 'open',
  bool saved = true,
  bool placed = false,
}) =>
    {
      'id': id,
      'academy_id': 'a1',
      'book_id': 'b1',
      'grade_label': '1-1',
      'book_name': '개념+유형',
      'unit_path': ['수와 연산', '소인수분해', unit],
      'pages': [8],
      'page_meta': [],
      'status': status,
      'model': 'gpt',
      'prepared': {'blocks': [], 'disagreements': []},
      'draft': {
        'summary': '',
        'concepts': [
          {
            'title': unit,
            'concept_type': '정의',
            'content': placed ? '$unit 내용' : '',
            'source_blocks': [],
            'criterion_notes': '',
            'needs_check': ''
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
          if (placed)
            {
              'concept': 0,
              'path': ['대수', '수와 연산', '소인수분해'],
              'reason': ''
            },
        ],
        'roots': ['대수'],
        'checks': {},
      },
      'review': saved ? (review ?? _review(unit, ['대수', '수와 연산', '소인수분해'])) : {},
      'review_saved_at': saved ? '2026-10-17T10:00:00Z' : null,
      'created_at': '2026-10-17T09:00:00Z',
    };

ConceptBookEntry _book() => ConceptBookEntry.fromMetadataRow({
      'academy_id': 'a1',
      'book_id': 'b1',
      'grade_label': '1-1',
      'textbook_type': '개념서',
      'payload': {
        'units': [
          {
            'name': 'I. 수와 연산',
            'middles': [
              {
                'name': '1. 소인수분해',
                'smalls': [
                  {'name': '소수와 합성수', 'start_page': 8, 'end_page': 9},
                  {'name': '거듭제곱', 'start_page': 10, 'end_page': 11},
                  {'name': '소인수분해', 'start_page': 12, 'end_page': 13},
                ],
              },
            ],
          },
        ],
      },
    }, bookName: '개념+유형');

class _FakeService extends ConceptDraftService {
  _FakeService() : super(books: ConceptBookService(pdf: TextbookPdfService(httpClient: _noHttp), httpClient: _noHttp));

  final List<String> calls = [];
  final Map<String, List<ConceptDraftException>> failures = {};
  List<Map<String, dynamic>> coverageRows = [];
  Map<String, Map<String, dynamic>> rows = {};
  final List<String> confirmed = [];
  final Map<String, List<ReviewItem>> savedReviews = {};

  void _maybeFail(String key) {
    final queue = failures[key];
    if (queue != null && queue.isNotEmpty) throw queue.removeAt(0);
  }

  @override
  Future<Map<int, Set<int>>> transcribedReads(ConceptBookEntry book, List<int> pages) async => const {};

  @override
  Future<ConceptDraftCoverage> coverage() async => ConceptDraftCoverage.fromRows(coverageRows);

  @override
  Future<void> transcribe({
    required ConceptBookEntry book,
    required List<String> unitPath,
    required List<int> pages,
    ConceptDraftProgress? onProgress,
  }) async {
    calls.add('transcribe:${unitPath.last}');
    _maybeFail('transcribe:${unitPath.last}');
  }

  @override
  Future<String> createDraft({
    required ConceptBookEntry book,
    required List<String> unitPath,
    required List<int> pages,
    List<String> criterionIds = const [],
    ConceptDraftWait? onWait,
  }) async {
    calls.add('create:${unitPath.last}');
    _maybeFail('create:${unitPath.last}');
    return 'd-${unitPath.last}';
  }

  @override
  Future<void> proposeFolders(String draftId) async {
    calls.add('folders:$draftId');
    _maybeFail('folders:$draftId');
  }

  @override
  Future<List<ConceptDraftSummary>> listDrafts({bool openOnly = true, int limit = 50}) async => [
        for (final r in rows.values)
          if (!openOnly || r['status'] == 'open')
            ConceptDraftSummary.fromRow({...r, 'concept_count': 1, 'has_folder_plan': true}),
      ];

  @override
  Future<ConceptDraftRecord> fetchDraft(String id) async => ConceptDraftRecord.fromRow(rows[id]!);

  @override
  Future<List<ConceptTypeInfo>> conceptTypes() async => _types;

  @override
  Future<List<List<String>>> libraryFolderPaths() async => _library;

  @override
  Future<String> saveReview(String id, List<ReviewItem> items, String? expectedSavedAt,
      {List<ReviewNewType> newTypes = const []}) async {
    if (expectedSavedAt != rows[id]!['review_saved_at']) throw ConceptDraftException('stale', '다른 곳에서 검토를 저장했습니다.');
    savedReviews[id] = items;
    return 'saved-$id';
  }

  @override
  Future<Map<String, dynamic>> confirm(String id, String savedAt) async {
    confirmed.add('$id@$savedAt');
    rows[id] = {...rows[id]!, 'status': 'confirmed'};
    return {'concepts': [], 'folders': [], 'sources': 0};
  }
}

Future<void> _pumpBatch(WidgetTester tester, _FakeService svc, void Function(bool) onDone) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final book = _book();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async => onDone(await showConceptDraftBatchDialog(
            context,
            book: book,
            units: conceptBookUnitPages(book.units, const {}),
            criteria: const [],
            service: svc,
            rateLimitWait: Duration.zero,
          )),
          child: const Text('열기'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

Future<void> _start(WidgetTester tester) async {
  await tester.tap(find.text('차례로 만들기'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('시작'));
  await tester.pumpAndSettle();
}

void main() {
  group('한 번에 확정 계획', () {
    test('저장된 검토는 그대로, 저장 안 한 초안은 AI 초안 그대로 쓰고, 막힌 이유와 새 폴더·새 유형을 모아 보인다', () {
      final plan = planDraftBatchConfirm(
        [
          ConceptDraftRecord.fromRow(_row('a', '소수와 합성수')),
          ConceptDraftRecord.fromRow(_row('b', '거듭제곱', saved: false)),
          ConceptDraftRecord.fromRow(_row('g', '약수와 배수', saved: false, placed: true)),
          ConceptDraftRecord.fromRow(_row('c', '소인수분해', status: 'confirmed')),
          ConceptDraftRecord.fromRow(_row('d', '약수', review: _review('약수', ['대수']))),
          ConceptDraftRecord.fromRow(_row('e', '배수',
              review: _review('배수', ['대수', '수와 연산', '소인수분해'],
                  type: '판정',
                  newTypes: [
                    {'name': '판정', 'description': '가리는 기준', 'legacy_sub_type': '정리', 'accept': true},
                  ]))),
          ConceptDraftRecord.fromRow(_row('f', '공약수',
              review: _review('공약수', ['대수', '수와 연산'],
                  type: '판정',
                  newTypes: [
                    {'name': '판정', 'description': '가리는 기준', 'legacy_sub_type': '정리', 'accept': null},
                  ]))),
        ],
        libraryPaths: _library,
        types: _types,
      );
      expect([for (final r in plan.ready) r.id], ['a', 'g', 'e']);
      final reasons = {for (final b in plan.blocked) b.record.id: b.reason};
      expect(reasons.keys, ['b', 'c', 'd', 'f']);
      expect(reasons['b'], contains('AI 초안 그대로는 넣을 수 없습니다'));
      expect(reasons['b'], contains('이름과 내용'));
      expect(reasons['c'], contains('확정함'));
      expect(reasons['d'], contains('폴더'));
      expect(reasons['f'], contains('받아들일지'));
      expect(plan.asIs.keys, ['g'], reason: '검토를 저장한 초안은 저장된 검토로 확정한다');
      expect(plan.reviewOf(plan.ready[1]).single.folder, ['대수', '수와 연산', '소인수분해']);
      expect(plan.newFolders, ['대수 > 수와 연산 > 소인수분해'], reason: '여러 초안이 같은 새 폴더를 쓰면 하나로 센다');
      expect(plan.newTypes, ['판정']);
      expect(plan.conceptCount, 3);
    });

    test('폴더 제안의 겹침은 남기는 개념만, 같은 이름은 고른 초안끼리 찾아 알린다', () {
      Map<String, dynamic> withOverlap(Map<String, dynamic> row, String other) => {
            ...row,
            'folder_plan': {
              ...row['folder_plan'] as Map<String, dynamic>,
              'pending_drafts': 2,
              'overlaps': [
                {'concept': 0, 'other': other, 'reason': '같은 정의'},
                {'concept': 0, 'other': ' ', 'reason': ''},
              ],
            },
          };
      final dropped = _row('c', '소인수분해', review: {
        'concepts': [
          {'index': 0, 'mark': 'drop', 'title': '소수', 'content': '', 'type': '정의', 'folder': <String>[]},
          {
            'key': 'c1',
            'index': 1,
            'mark': 'keep',
            'title': '소인수',
            'content': '소인수 내용',
            'type': '정의',
            'folder': ['대수', '수와 연산']
          },
        ],
        'new_types': [],
      });
      final records = [
        ConceptDraftRecord.fromRow(
            withOverlap(_row('a', '소수와 합성수', review: _review('소수', ['대수', '수와 연산'])), '라이브러리 소수')),
        ConceptDraftRecord.fromRow(_row('b', '거듭제곱', review: _review('소수', ['대수', '수와 연산']))),
        ConceptDraftRecord.fromRow(withOverlap(dropped, '초안 소수와 합성수: 소수')),
      ];
      expect(records.first.folderPlan?.pendingDrafts, 2);
      expect(records.first.folderPlan?.overlaps[0]?.length, 1, reason: '상대 이름이 빈 겹침은 버린다');
      final plan = planDraftBatchConfirm(records, libraryPaths: _library, types: _types);
      expect([for (final r in plan.ready) r.id], ['a', 'b', 'c']);
      expect(plan.overlaps, [(unit: '소수와 합성수', title: '소수', other: '라이브러리 소수 (같은 정의)')], reason: '뺀 개념의 겹침은 보이지 않는다');
      expect(plan.sameTitles, [(title: '소수', drafts: 2)], reason: '뺀 개념은 세지 않는다');
    });
  });

  group('차례로 만들기', () {
    testWidgets('한 번에 하나씩 하고, 한 소단원이 실패해도 다음으로 넘어간다', (tester) async {
      final svc = _FakeService()..failures['create:거듭제곱'] = [ConceptDraftException('http_500', '서버 오류')];
      bool? made;
      await _pumpBatch(tester, svc, (v) => made = v);
      await _start(tester);
      expect(svc.calls, [
        'transcribe:소수와 합성수',
        'create:소수와 합성수',
        'folders:d-소수와 합성수',
        'transcribe:거듭제곱',
        'create:거듭제곱',
        'transcribe:소인수분해',
        'create:소인수분해',
        'folders:d-소인수분해',
      ]);
      expect(find.text('완료'), findsNWidgets(2));
      expect(find.text('실패'), findsOneWidget);
      expect(find.textContaining('초안 2개를 만들었습니다'), findsOneWidget);

      svc.calls.clear();
      svc.coverageRows = [
        for (final u in ['소수와 합성수', '소인수분해'])
          {
            'id': 'd-$u',
            'academy_id': 'a1',
            'book_id': 'b1',
            'grade_label': '1-1',
            'unit_path': ['I. 수와 연산', '1. 소인수분해', u],
            'status': 'open'
          },
      ];
      await tester.tap(find.text('남은 것 다시 하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('시작'));
      await tester.pumpAndSettle();
      expect(svc.calls, ['transcribe:거듭제곱', 'create:거듭제곱', 'folders:d-거듭제곱'], reason: '실패한 것만 다시 한다');

      await tester.tap(find.byTooltip('닫기'));
      await tester.pumpAndSettle();
      expect(made, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('시작 전에 이미 초안이 있는 소단원은 건너뛰고, 예산을 넘으면 남은 것을 하지 않는다', (tester) async {
      final svc = _FakeService()
        ..coverageRows = [
          {
            'id': 'x',
            'academy_id': 'a1',
            'book_id': 'b1',
            'grade_label': '1-1',
            'unit_path': ['I. 수와 연산', '1. 소인수분해', '소수와 합성수'],
            'status': 'confirmed'
          },
        ]
        ..failures['transcribe:거듭제곱'] = [ConceptDraftException('budget_exceeded', '이번 달 AI 예산을 넘었습니다.')];
      await _pumpBatch(tester, svc, (_) {});
      await _start(tester);
      expect(svc.calls, ['transcribe:거듭제곱'], reason: '같은 소단원을 두 번 만들지 않고, 예산 초과 뒤에는 멈춘다');
      expect(find.text('이미 초안이 있어 건너뛰었습니다.'), findsOneWidget);
      expect(find.text('멈춤'), findsOneWidget);
      expect(find.textContaining('남은 소단원은 하지 않았습니다'), findsOneWidget);
    });

    testWidgets('요청 제한에 걸리면 기다렸다가 같은 단계를 한 번 다시 한다', (tester) async {
      final svc = _FakeService()..failures['create:소수와 합성수'] = [ConceptDraftException('rate_limited', '요청이 많습니다.')];
      await _pumpBatch(tester, svc, (_) {});
      await _start(tester);
      expect(svc.calls.where((c) => c == 'create:소수와 합성수'), hasLength(2));
      expect(find.text('완료'), findsNWidgets(3));
    });

    testWidgets('다 만든 뒤 이번에 만든 초안만 한 번에 확정하고, 넣을 수 없는 초안은 남긴다', (tester) async {
      final svc = _FakeService()
        ..failures['folders:d-거듭제곱'] = [ConceptDraftException('http_500', '서버 오류')]
        ..rows = {
          'd-소수와 합성수': _row('d-소수와 합성수', '소수와 합성수', saved: false, placed: true),
          'd-거듭제곱': _row('d-거듭제곱', '거듭제곱', saved: false),
          'd-소인수분해': _row('d-소인수분해', '소인수분해', saved: false, placed: true),
          'old': _row('old', '약수', saved: false, placed: true),
        };
      var reloaded = 0;
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final book = _book();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showConceptDraftBatchDialog(
                context,
                book: book,
                units: conceptBookUnitPages(book.units, const {}),
                criteria: const [],
                service: svc,
                rateLimitWait: Duration.zero,
                onConfirmed: () => reloaded += 1,
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('batch-confirm-made')), findsNothing, reason: '만들기 전에는 확정 버튼이 없다');
      await _start(tester);

      await tester.tap(find.text('만든 초안 3개 한 번에 확정'));
      await tester.pumpAndSettle();
      expect(find.text('초안 2개를 라이브러리에 넣을까요?'), findsOneWidget);
      expect(find.textContaining('거듭제곱 — AI 초안 그대로는 넣을 수 없습니다'), findsOneWidget);
      await tester.tap(find.text('2개 확정'));
      await tester.pumpAndSettle();
      expect(svc.confirmed, ['d-소수와 합성수@saved-d-소수와 합성수', 'd-소인수분해@saved-d-소인수분해'], reason: '이 창에서 만들지 않은 초안은 넣지 않는다');
      expect(reloaded, 1);
      expect(find.textContaining('초안 2개를 확정해'), findsOneWidget);
      expect(find.text('만든 초안 1개 한 번에 확정'), findsOneWidget, reason: '확정한 초안은 다시 고르지 않는다');
      expect(tester.takeException(), isNull);
    });

    testWidgets('폴더 제안만 실패하면 초안은 남은 것으로 보고 다음으로 넘어간다', (tester) async {
      final svc = _FakeService()..failures['folders:d-소수와 합성수'] = [ConceptDraftException('http_500', '서버 오류')];
      await _pumpBatch(tester, svc, (_) {});
      await _start(tester);
      expect(find.text('폴더 제안 없음'), findsOneWidget);
      expect(find.text('완료'), findsNWidgets(2));
      expect(find.textContaining('초안 3개를 만들었습니다'), findsOneWidget);
    });
  });

  group('개념 초안 목록에서 한 번에 확정', () {
    testWidgets('검토 중인 초안을 모두 골라, 확인 창을 거쳐 저장된 검토는 그 시각으로, 저장 안 한 초안은 AI 초안을 저장한 뒤 확정한다', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final svc = _FakeService()
        ..rows = {
          'a': _row('a', '소수와 합성수'),
          'b': _row('b', '거듭제곱', saved: false, placed: true),
          'c': _row('c', '소인수분해'),
          'x': _row('x', '약수', status: 'confirmed'),
        };
      var reloaded = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showConceptDraftListDialog(context, service: svc, onConfirmed: () => reloaded += 1),
              child: const Text('열기'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('검토 중인 초안 모두 고르기'));
      await tester.pump();
      expect(find.text('고른 초안 3개 확정'), findsOneWidget, reason: '확정한 초안은 고르지 않는다');

      await tester.tap(find.text('고른 초안 3개 확정'));
      await tester.pumpAndSettle();
      expect(find.text('초안 3개를 라이브러리에 넣을까요?'), findsOneWidget);
      expect(find.text('· 거듭제곱 — 개념 1개 · AI 초안 그대로'), findsOneWidget);
      expect(find.text('검토 없이 넣는 초안 1개'), findsOneWidget);
      expect(find.text('· 대수 > 수와 연산 > 소인수분해'), findsOneWidget);
      expect(svc.confirmed, isEmpty, reason: '확인 창에서 누르기 전에는 확정하지 않는다');
      expect(svc.savedReviews, isEmpty, reason: '확인 창에서 누르기 전에는 검토도 저장하지 않는다');

      await tester.tap(find.text('3개 확정'));
      await tester.pumpAndSettle();
      expect(svc.savedReviews.keys, ['b']);
      expect(svc.savedReviews['b']!.single.title, '거듭제곱');
      expect(svc.confirmed, ['a@2026-10-17T10:00:00Z', 'b@saved-b', 'c@2026-10-17T10:00:00Z']);
      expect(reloaded, 1);
      expect(find.textContaining('초안 3개를 확정해 라이브러리에 넣었습니다(그중 1개는 AI 초안 그대로)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
