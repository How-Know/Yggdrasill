import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_draft_build_dialog.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_draft_review_dialog.dart';
import 'package:yggdrasill_manager/services/concept_book_service.dart';
import 'package:yggdrasill_manager/services/concept_draft_models.dart';
import 'package:yggdrasill_manager/services/concept_draft_service.dart';
import 'package:yggdrasill_manager/services/textbook_pdf_service.dart';
import 'package:yggdrasill_manager/services/think/think_concept_chat_controller.dart';

final _noHttp = MockClient((_) async => http.Response('', 404));

const _newTypeProposal = {
  'name': '판정',
  'description': '어떤 수가 소수인지 가리는 기준',
  'legacy_sub_type': '연산',
  'closest_existing': '주의',
  'reason': '주의와 달리 절차다',
};

Map<String, dynamic> _row({
  Map<String, dynamic>? review,
  String? savedAt,
  bool plan = true,
  String status = 'open',
  bool v1 = false,
  bool newType = false,
  bool anchored = false,
}) =>
    {
      'id': 'd1',
      'academy_id': 'a1',
      'book_id': 'b1',
      'grade_label': '1-1',
      'book_name': '개념+유형 중1-1',
      'unit_path': ['소인수분해', '소인수분해', '소수와 합성수'],
      'pages': [8, 9],
      'page_meta': [
        {'raw_page': 8, 'display_page': 8},
        {'raw_page': 9, 'display_page': null},
      ],
      'status': status,
      'model': 'gpt',
      'prepared': {
        'blocks': [
          {
            'id': 'p8-a0',
            'raw_page': 8,
            'read': 'a',
            'kind': 'concept_box',
            'title': '',
            'text': '소수: 1보다 큰…',
            'bbox_1k': [100, 100, 200, 900]
          },
          {
            'id': 'p9-b1',
            'raw_page': 9,
            'read': 'b',
            'kind': 'note',
            'title': '참고',
            'text': '1은 소수가 아니다',
            'bbox_1k': null
          },
        ],
        'disagreements': [
          {'id': 'p9-b1', 'type': 'only_in_b', 'similarity': null, 'a_text': '', 'b_text': '1은 소수가 아니다'},
        ],
      },
      'draft': {
        'summary': '개념 2개를 만들었습니다.',
        'concepts': [
          {
            'title': '소수',
            'concept_type': v1 ? 'definition' : '정의',
            'content': r'$1$보다 큰 자연수',
            'source_blocks': ['p8-a0'],
            'criterion_notes': '',
            'needs_check': ''
          },
          {
            'title': '1의 분류',
            'concept_type': v1 ? 'caution' : (newType ? '판정' : '주의'),
            'content': '1은 소수가 아니다',
            'source_blocks': ['p9-b1', 'p8-a0'],
            'criterion_notes': '',
            'needs_check': '두 번째 읽기에만 있음',
            if (anchored) 'anchor': 0,
          },
        ],
        if (!v1) 'new_types': [if (newType) _newTypeProposal],
        'excluded': [],
        'questions': ['약수 단원과 합칠까요?'],
      },
      'checks': {'unknown_ids': [], 'unaccounted': [], 'formula_warnings': [], 'concepts_without_source': []},
      'criteria': [],
      'folder_plan': plan
          ? {
              'notes': '수와 연산 아래에 둡니다.',
              'folders': [
                {
                  'path': ['대수', '수와 연산', '소인수분해'],
                  'reason': '약수와 같은 대상'
                },
              ],
              'placements': [
                {
                  'concept': 0,
                  'path': ['대수', '수와 연산', '소인수분해'],
                  'reason': '정의'
                },
                {
                  'concept': 1,
                  'path': ['없는 영역', '폴더'],
                  'reason': ''
                },
              ],
              'roots': ['대수', '기하'],
              'checks': {
                'unknown_root': [1],
                'unplaced': [1],
                'duplicate': [],
                'new_folders': []
              },
            }
          : null,
      'review': review ?? {},
      'review_saved_at': savedAt,
      'created_at': '2026-10-16T14:00:00Z',
    };

class _FakeDraftService extends ConceptDraftService {
  _FakeDraftService({Map<String, dynamic>? row})
      : _rowData = row ?? _row(),
        super(books: ConceptBookService(pdf: TextbookPdfService(httpClient: _noHttp), httpClient: _noHttp));

  Map<String, dynamic> _rowData;
  final List<List<ReviewItem>> saved = [];
  final List<List<ReviewNewType>> savedTypes = [];
  final List<String> confirmed = [];
  final List<String> calls = [];
  bool failFolders = false;
  Map<int, Set<int>> reads = {
    8: {1, 2}
  };

  @override
  Future<ConceptDraftRecord> fetchDraft(String id) async => ConceptDraftRecord.fromRow(_rowData);

  @override
  Future<List<List<String>>> libraryFolderPaths() async => const [
        ['대수'],
        ['기하'],
        ['대수', '수와 연산'],
      ];

  @override
  Future<List<ConceptTypeInfo>> conceptTypes() async => const [
        ConceptTypeInfo(name: '정의', description: '뜻', legacySubType: '정의'),
        ConceptTypeInfo(name: '성질', description: '사실', legacySubType: '정리'),
        ConceptTypeInfo(name: '방법', description: '절차', legacySubType: '연산'),
        ConceptTypeInfo(name: '표현', description: '기호', legacySubType: '정의'),
        ConceptTypeInfo(name: '주의', description: '예외', legacySubType: '정리'),
      ];

  @override
  Future<String> saveReview(
    String id,
    List<ReviewItem> items,
    String? expectedSavedAt, {
    List<ReviewNewType> newTypes = const [],
  }) async {
    saved.add(items);
    savedTypes.add(newTypes);
    final at = '2026-10-16T15:00:0${saved.length}.123456+00:00';
    _rowData = {
      ..._rowData,
      'review': {
        'concepts': [for (final it in items) it.toJson()],
        'new_types': [for (final t in newTypes) t.toJson()],
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
  Future<Map<int, Set<int>>> transcribedReads(ConceptBookEntry book, List<int> pages) async => reads;

  @override
  Future<void> transcribe({
    required ConceptBookEntry book,
    required List<String> unitPath,
    required List<int> pages,
    ConceptDraftProgress? onProgress,
  }) async {
    calls.add('transcribe:${pages.join(',')}');
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
    return 'd1';
  }

  @override
  Future<void> proposeFolders(String draftId) async {
    calls.add('folders:$draftId');
    if (failFolders) throw ConceptDraftException('rate_limited', '요청이 많습니다.');
  }
}

Future<void> _pumpReview(
  WidgetTester tester,
  _FakeDraftService svc, {
  ValueChanged<bool>? onDone,
  ConceptChatController? chat,
}) async {
  tester.view.physicalSize = const Size(1600, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              final ok = await showConceptDraftReviewDialog(
                context,
                draftId: 'd1',
                service: svc,
                chat: chat ?? ConceptChatController.forTest(draftMode: true),
              );
              onDone?.call(ok);
            },
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

void main() {
  group('가림 영역', () {
    test('왼쪽 단부터 위에서 아래로 M1… 을 붙인다(서버와 같은 순서)', () {
      final masks = conceptPageMasks([
        {
          'item_region_1k': [600, 520, 800, 950],
          'problem_number': '0003'
        },
        {
          'item_region_1k': null,
          'bbox_1k': [100, 50, 300, 480],
          'problem_number': '0001'
        },
        {
          'item_region_1k': [400, 50, 500, 480],
          'problem_number': ''
        },
        {
          'item_region_1k': [500, 50, 400, 480]
        },
      ]);
      expect([for (final m in masks) m.label], ['M1', 'M2', 'M3']);
      expect(masks[0].bbox1k, [100, 50, 300, 480]);
      expect(masks[0].toJson()['problem_number'], '0001');
      expect(masks[1].toJson().containsKey('problem_number'), isFalse);
      expect(masks[2].bbox1k, [600, 520, 800, 950]);
    });

    test('회색 상자를 그리고 PNG 크기를 읽는다', () {
      final base = img.Image(width: 200, height: 100);
      img.fill(base, color: img.ColorRgb8(255, 255, 255));
      final png = Uint8List.fromList(img.encodePng(base));
      expect(pngSize(png), (200, 100));
      final out = img.decodePng(drawConceptPageMasks(png, const [
        ConceptPageMask(label: 'M1', bbox1k: [0, 500, 1000, 1000]),
      ]))!;
      expect(out.getPixel(190, 90).r, 0xBD);
      expect(out.getPixel(10, 10).r, 255);
    });
  });

  group('초안 기록과 검토 계산', () {
    test('폴더 제안으로 처음 검토를 만들고, 영역 밖 제안은 비워 둔다', () {
      final r = ConceptDraftRecord.fromRow(_row());
      final items = initialReview(r);
      expect(items[0].folder, ['대수', '수와 연산', '소인수분해']);
      expect(items[0].type, '정의');
      expect(items[1].folder, isEmpty);
      expect(items[1].type, '주의');
      expect(r.sourcePages(1), [8, 9]);
      expect(r.pageLabel(9), 'PDF 9쪽');
      expect(r.disagreementsFor(1).single.type, 'only_in_b');
      const types = [
        ConceptTypeInfo(name: '정의', description: '', legacySubType: '정의'),
        ConceptTypeInfo(name: '주의', description: '', legacySubType: '정리'),
      ];
      expect(reviewProblem(items, r.folderPlan!.roots, types: types), contains('"1의 분류"을 넣을 폴더'));
    });

    test('저장된 검토가 있으면 그것을 쓰고, 유형 없이 저장된 줄은 AI 유형으로 채운다', () {
      final r = ConceptDraftRecord.fromRow(_row(
        review: {
          'concepts': [
            {
              'index': 0,
              'mark': 'keep',
              'title': '소수',
              'content': 'c',
              'type': '성질',
              'folder': ['대수', 'a']
            },
            {
              'index': 1,
              'mark': 'drop',
              'title': 'x',
              'content': 'y',
              'sub_type': '연산',
              'folder': ['기하', 'a']
            },
          ],
        },
        savedAt: '2026-10-16T15:00:00+00:00',
      ));
      final items = initialReview(r);
      expect(items[0].type, '성질');
      expect(items[1].mark, ReviewMark.drop);
      expect(items[1].type, '주의');
      expect(sameReview(items, r.review), isFalse, reason: '채운 유형은 저장해야 확정할 수 있다');
      expect(r.reviewSavedAt, '2026-10-16T15:00:00+00:00');
    });

    test('첫 판 초안의 영어 종류는 기본 유형 이름으로 읽고, other 는 미정으로 둔다', () {
      final r = ConceptDraftRecord.fromRow(_row(v1: true));
      expect(initialReview(r).map((it) => it.type), ['정의', '주의']);
      expect(r.newTypes, isEmpty);
      expect(draftTypeName('notation'), '표현');
      expect(draftTypeName('other'), '');
      expect(draftTypeName(' 판정 '), '판정');
    });

    test('새 유형: 거절하면 가장 가까운 유형으로 바꾸고, 다시 받아들이면 되돌리며, 기존 구분은 유형에서 정해진다', () {
      final r = ConceptDraftRecord.fromRow(_row(newType: true));
      const types = [
        ConceptTypeInfo(name: '정의', description: '', legacySubType: '정의'),
        ConceptTypeInfo(name: '주의', description: '', legacySubType: '정리'),
      ];
      final items = [
        for (final it in initialReview(r)) it.copyWith(folder: ['대수', '수'])
      ];
      var newTypes = initialNewTypes(r);
      expect(newTypes.single.accept, isNull);
      expect(items[1].type, '판정');
      expect(newTypeUseCount(items, '판정'), 1);
      expect(reviewProblem(items, ['대수'], types: types, newTypes: newTypes), contains('새 유형 "판정"을 받아들일지'));
      expect(legacySubTypeOf('판정', types, newTypes), '연산');

      final rejected = decideNewType(r, items, newTypes, '판정', false);
      expect(rejected.items[1].type, '주의');
      expect(rejected.newTypes.single.accept, isFalse);
      expect(legacySubTypeOf('판정', types, rejected.newTypes), isNull);
      expect(reviewProblem(rejected.items, ['대수'], types: types, newTypes: rejected.newTypes), isNull);
      expect(sameReview(rejected.items, rejected.items, newTypes, rejected.newTypes), isFalse);

      final accepted = decideNewType(r, rejected.items, rejected.newTypes, '판정', true);
      expect(accepted.items[1].type, '판정');
      expect(reviewProblem(accepted.items, ['대수'], types: types, newTypes: accepted.newTypes), isNull);

      final manual = [accepted.items[0], accepted.items[1].copyWith(type: '정의')];
      expect(decideNewType(r, manual, accepted.newTypes, '판정', false).items[1].type, '정의', reason: '직접 고른 유형은 그대로 둔다');
      expect(reviewProblem([manual[0].copyWith(type: '')], ['대수'], types: types), contains('유형을 정하세요'));
      expect(reviewProblem([manual[0].copyWith(type: '없는 것')], ['대수'], types: types), contains('유형 목록에 없습니다'));
      newTypes = [newTypes.single.copyWith(accept: false)];
      expect(reviewProblem([manual[0].copyWith(type: '판정')], ['대수'], types: types, newTypes: newTypes),
          contains('거절한 유형'));
    });

    test('저장된 새 유형 결정을 다시 입힌다', () {
      final r = ConceptDraftRecord.fromRow(_row(
        newType: true,
        review: {
          'concepts': [],
          'new_types': [
            {..._newTypeProposal, 'legacy_sub_type': '정리', 'accept': true},
          ],
        },
        savedAt: '2026-10-16T15:00:00+00:00',
      ));
      final t = initialNewTypes(r).single;
      expect([t.accept, t.legacySubType, t.reason], [true, '정리', '주의와 달리 절차다']);
    });

    test('폴더 이름을 바꾸면 그 아래 개념 경로가 모두 바뀌고, 영역은 바꾸지 않는다', () {
      const items = [
        ReviewItem(index: 0, mark: ReviewMark.keep, title: 'a', content: 'b', type: '정의', folder: ['대수', '수', '소인수분해']),
        ReviewItem(index: 1, mark: ReviewMark.keep, title: 'a', content: 'b', type: '정의', folder: ['대수', '수']),
        ReviewItem(index: 2, mark: ReviewMark.keep, title: 'a', content: 'b', type: '정의', folder: ['대수', '수식']),
      ];
      final next = renameReviewFolder(items, ['대수', '수'], '수와 연산');
      expect(next[0].folder, ['대수', '수와 연산', '소인수분해']);
      expect(next[1].folder, ['대수', '수와 연산']);
      expect(next[2].folder, ['대수', '수식']);
      expect(renameReviewFolder(items, ['대수'], '해석'), same(items));
      expect(reviewFolderPaths(next).map((p) => p.join('>')), ['대수', '대수>수식', '대수>수와 연산', '대수>수와 연산>소인수분해']);
      expect(sameReview(items, next), isFalse);
      expect(sameReview(items, [...items]), isTrue);
    });

    test('확정 전 검사: 넣을 것이 없거나 폴더·영역이 맞지 않으면 막는다', () {
      const ok =
          ReviewItem(index: 0, mark: ReviewMark.keep, title: '소수', content: 'c', type: '정의', folder: ['대수', '수']);
      const types = [ConceptTypeInfo(name: '정의', description: '', legacySubType: '정의')];
      expect(reviewProblem([ok], ['대수'], types: types), isNull);
      expect(reviewProblem([ok.copyWith(mark: ReviewMark.drop)], ['대수'], types: types), contains('넣을 개념이 없습니다'));
      expect(
          reviewProblem([
            ok.copyWith(folder: ['해석', '수'])
          ], [
            '대수'
          ], types: types),
          contains('영역'));
      expect(reviewProblem([ok.copyWith(content: ' ')], ['대수'], types: types), contains('이름과 내용'));
    });

    test('라이브러리 폴더 경로: 바로가기·끊긴 폴더는 뺀다', () {
      final paths = libraryPathsFromRows([
        {'id': 'r', 'name': '대수', 'parent_id': null},
        {'id': 'c', 'name': '수와 연산', 'parent_id': 'r'},
        {'id': 's', 'name': '바로가기', 'parent_id': 'r', 'code': 'SHORTCUT'},
        {'id': 'o', 'name': '고아', 'parent_id': 'gone'},
      ]);
      expect(paths, [
        ['대수'],
        ['대수', '수와 연산'],
      ]);
    });
  });

  group('검토 화면', () {
    testWidgets('요약·질문·폴더 제안을 보이고, 새 폴더를 표시한다', (tester) async {
      await _pumpReview(tester, _FakeDraftService());
      expect(find.text('개념 2개를 만들었습니다.'), findsOneWidget);
      expect(find.textContaining('약수 단원과 합칠까요?'), findsOneWidget);
      expect(find.text('수와 연산 아래에 둡니다.'), findsOneWidget);
      expect(find.text('새 폴더'), findsOneWidget);
      expect(find.text('폴더를 정하지 않음'), findsOneWidget);
      expect(find.textContaining('확인 필요: 두 번째 읽기에만 있음'), findsOneWidget);
      expect(find.textContaining('출처: PDF 8쪽, PDF 9쪽'), findsOneWidget);
    });

    testWidgets('폴더 제안의 겹침은 그 개념 카드에만 안내하고, 다른 초안을 본 제안임을 알린다', (tester) async {
      final row = _row();
      row['folder_plan'] = {
        ...row['folder_plan'] as Map<String, dynamic>,
        'pending_drafts': 2,
        'overlaps': [
          {'concept': 1, 'other': '초안 거듭제곱: 1의 분류', 'reason': '같은 주의'},
        ],
      };
      await _pumpReview(tester, _FakeDraftService(row: row));
      expect(find.byKey(const ValueKey('draft-overlap-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('draft-overlap-0')), findsNothing);
      expect(find.textContaining('겹칠 수 있음: 초안 거듭제곱: 1의 분류 (같은 주의)'), findsOneWidget);
      expect(find.textContaining('다른 초안 2개의 폴더도 보고'), findsOneWidget);
    });

    testWidgets('폴더를 정하지 않은 개념이 있으면 확정을 막는다', (tester) async {
      final svc = _FakeDraftService();
      await _pumpReview(tester, svc);
      await tester.tap(find.textContaining('확정하고 라이브러리에 넣기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('넣을 폴더를 정하세요'), findsOneWidget);
      expect(svc.confirmed, isEmpty);
    });

    testWidgets('이름을 고치면 "고쳐서"가 되고, 저장한 뒤 확정은 저장된 시각으로 한다', (tester) async {
      final svc = _FakeDraftService();
      bool? result;
      await _pumpReview(tester, svc, onDone: (ok) => result = ok);
      await tester.tap(find.byKey(const ValueKey('draft-mark-1-drop')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('draft-title-0')), '소수(素數)');
      await tester.pump();
      expect(find.text('저장하지 않은 편집이 있습니다.'), findsOneWidget);

      await tester.tap(find.text('검토 저장'));
      await tester.pumpAndSettle();
      expect(svc.saved.single[0].title, '소수(素數)');
      expect(svc.saved.single[0].mark, ReviewMark.edit);
      expect(svc.saved.single[1].mark, ReviewMark.drop);
      expect(find.text('검토를 저장했습니다.'), findsOneWidget);

      await tester.tap(find.textContaining('확정하고 라이브러리에 넣기 (1개)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('새로 만드는 폴더 1개'), findsOneWidget);
      await tester.tap(find.text('확정'));
      await tester.pumpAndSettle();
      expect(svc.saved.length, 1, reason: '저장된 그대로면 다시 저장하지 않는다');
      expect(svc.confirmed.single, '2026-10-16T15:00:01.123456+00:00');
      expect(result, isTrue);
    });

    testWidgets('폴더 바꾸기: 경로를 직접 쓰면 영역으로 시작해야 한다', (tester) async {
      final svc = _FakeDraftService();
      await _pumpReview(tester, svc);
      await tester.tap(find.text('폴더 정하기'));
      await tester.pumpAndSettle();
      final pathField = find.widgetWithText(TextField, '경로 직접 쓰기(영역 > 폴더 > …)');
      await tester.enterText(pathField, '수 > 소수');
      await tester.tap(find.text('이 경로로'));
      await tester.pumpAndSettle();
      expect(find.textContaining('영역(대수·기하) 이름으로 시작해야'), findsOneWidget);
      await tester.enterText(pathField, '대수 > 수와 연산 > 소수의 분류');
      await tester.tap(find.text('이 경로로'));
      await tester.pumpAndSettle();
      expect(find.text('폴더를 정하지 않음'), findsNothing);
      expect(find.text('소수의 분류'), findsWidgets);
    });

    testWidgets('새 유형: 정하기 전엔 확정을 막고, 거절하면 가까운 유형으로, 받아들이면 확정 창에 보인다', (tester) async {
      final svc = _FakeDraftService(row: _row(newType: true));
      await _pumpReview(tester, svc);
      final typeOf1 = find.byKey(const ValueKey('draft-type-1'));
      expect(find.text('새 유형 · 결정 전'), findsOneWidget);
      expect(find.descendant(of: typeOf1, matching: find.text('판정 · 새 유형')), findsOneWidget);
      expect(find.textContaining('확정된 유형: 정의 · 성질 · 방법 · 표현 · 주의'), findsOneWidget);

      await tester.tap(find.textContaining('확정하고 라이브러리에 넣기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('새 유형 "판정"을 받아들일지 정하세요'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('draft-newtype-0-reject')));
      await tester.pumpAndSettle();
      expect(find.descendant(of: typeOf1, matching: find.text('주의')), findsOneWidget);
      expect(find.textContaining('"주의"(으)로 바꿨습니다'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('draft-newtype-0-accept')));
      await tester.pumpAndSettle();
      expect(find.descendant(of: typeOf1, matching: find.text('판정 · 새 유형')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('draft-mark-1-drop')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('확정하고 라이브러리에 넣기 (1개)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('유형 목록에 더하는 새 유형 1개'), findsOneWidget);
      expect(find.textContaining('판정 (기존 구분 연산)'), findsOneWidget);
      await tester.tap(find.text('확정'));
      await tester.pumpAndSettle();
      expect(svc.savedTypes.single.single.accept, isTrue);
      expect(svc.saved.single[0].type, '정의');
      expect(svc.confirmed, hasLength(1));
    });

    testWidgets('붙일 개념: AI 묶음을 보여 주고, 고리가 되는 쪽은 막고, 바꾼 것을 저장한다', (tester) async {
      final svc = _FakeDraftService(row: _row(anchored: true));
      await _pumpReview(tester, svc);
      final anchor1 = find.byKey(const ValueKey('draft-anchor-1'));
      expect(find.descendant(of: anchor1, matching: find.text('c0 소수')), findsOneWidget);
      expect(find.textContaining('폴더가 달라 확정할 때 잇지 않습니다'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('draft-anchor-0')));
      await tester.pumpAndSettle();
      final looped = find.text('c1 1의 분류 · 이 개념에 붙어 있음').last;
      expect(
          tester
              .widget<DropdownMenuItem<String>>(
                  find.ancestor(of: looped, matching: find.byType(DropdownMenuItem<String>)))
              .enabled,
          isFalse);
      await tester.tap(find.text('묶지 않음').last);
      await tester.pumpAndSettle();

      await tester.tap(anchor1);
      await tester.pumpAndSettle();
      await tester.tap(find.text('묶지 않음').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('폴더가 달라'), findsNothing);
      await tester.tap(find.text('검토 저장'));
      await tester.pumpAndSettle();
      expect(svc.saved.single[1].anchor, isNull);
      expect(initialReview(ConceptDraftRecord.fromRow(_row(anchored: true)))[1].anchor, 'c0');
    });

    testWidgets('유형 없이 저장된 검토는 확정 전에 유형을 채워 다시 저장한다', (tester) async {
      final svc = _FakeDraftService(
        row: _row(
          v1: true,
          review: {
            'concepts': [
              {
                'index': 0,
                'mark': 'keep',
                'title': '소수',
                'content': 'c',
                'sub_type': '정의',
                'folder': ['대수', '수와 연산']
              },
              {'index': 1, 'mark': 'drop', 'title': '1의 분류', 'content': 'd', 'sub_type': '정리', 'folder': []},
            ],
          },
          savedAt: '2026-10-16T15:00:00+00:00',
        ),
      );
      await _pumpReview(tester, svc);
      expect(find.text('저장하지 않은 편집이 있습니다.'), findsOneWidget);
      await tester.tap(find.textContaining('확정하고 라이브러리에 넣기 (1개)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('확정'));
      await tester.pumpAndSettle();
      expect(svc.saved.single.map((it) => it.type), ['정의', '주의']);
      expect(svc.confirmed.single, '2026-10-16T15:00:01.123456+00:00');
    });

    testWidgets('확정한 초안은 고치거나 다시 확정할 수 없다', (tester) async {
      await _pumpReview(tester, _FakeDraftService(row: _row(status: 'confirmed')));
      expect(find.text('이미 확정한 초안입니다.'), findsOneWidget);
      expect(find.textContaining('확정하고 라이브러리에 넣기'), findsNothing);
      expect(find.text('검토 저장'), findsNothing);
    });
  });

  group('초안 만들기', () {
    const book = ConceptBookEntry(
      academyId: 'a1',
      bookId: 'b1',
      bookName: '개념+유형 중1-1',
      gradeLabel: '1-1',
      textbookType: '개념서',
      units: [],
    );
    const unit = ConceptBookUnitPages(
      path: ['소인수분해', '소인수분해', '소수와 합성수'],
      isExercise: false,
      startPage: 8,
      endPage: 9,
      extracted: true,
      pages: [ConceptBookPage(rawPage: 8, problems: 0), ConceptBookPage(rawPage: 9, problems: 3)],
    );

    Future<String?> pumpBuild(WidgetTester tester, _FakeDraftService svc) async {
      String? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                result = await showConceptDraftBuildDialog(context,
                    book: book, unit: unit, criteria: const [], service: svc);
              },
              child: const Text('열기'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('읽을 횟수 2번 남음'), findsOneWidget);
      await tester.tap(find.text('초안 만들기'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('전사 → 정리 → 폴더 제안 순서로 하고 초안 id를 돌려준다', (tester) async {
      final svc = _FakeDraftService();
      final id = await pumpBuild(tester, svc);
      expect(svc.calls, ['transcribe:8,9', 'create:소수와 합성수', 'folders:d1']);
      expect(id, 'd1');
      expect(find.text('개념 초안 만들기'), findsNothing);
    });

    testWidgets('폴더 제안이 실패하면 초안은 남고, 다시 하면 폴더 제안만 한다', (tester) async {
      final svc = _FakeDraftService()..failFolders = true;
      await pumpBuild(tester, svc);
      expect(find.text('폴더 제안 없이 검토하기'), findsOneWidget);
      expect(find.text('요청이 많습니다.'), findsOneWidget);
      svc.failFolders = false;
      await tester.tap(find.text('이어서 다시 하기'));
      await tester.pumpAndSettle();
      expect(svc.calls, ['transcribe:8,9', 'create:소수와 합성수', 'folders:d1', 'folders:d1']);
    });
  });
}
