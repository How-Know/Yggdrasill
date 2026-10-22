import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_book_order_dialog.dart';
import 'package:yggdrasill_manager/services/concept_book_order.dart';
import 'package:yggdrasill_manager/services/concept_book_service.dart';

const _unitA = ['소인수분해', '소인수분해', '소수와 합성수'];
const _unitB = ['소인수분해', '소인수분해', '거듭제곱'];

Map<String, dynamic> _src(String concept, String name, String folder, int page,
        {int? order, List<String> unit = _unitA}) =>
    {
      'concept_id': concept,
      'raw_page': page,
      'display_page': page + 2,
      'unit_path': unit,
      'page_order': order,
      'concepts': {'name': name, 'version_label': '기본', 'main_category_id': folder},
    };

ConceptBookEntry _book() => ConceptBookEntry.fromMetadataRow({
      'academy_id': 'a1',
      'book_id': 'b1',
      'grade_label': '1-1',
      'textbook_type': '개념서',
      'payload': {'units': []},
    }, bookName: '개념+유형');

void main() {
  group('교재 순서', () {
    test('라이브러리 순서와 달라도 처음 나온 쪽 → 쪽 안 순서로 다시 나열한다', () {
      final paths = conceptFolderPaths([
        {'id': 'r', 'name': '대수', 'parent_id': null},
        {'id': 'f1', 'name': '1 소수', 'parent_id': 'r'},
        {'id': 'f4', 'name': '4 소인수', 'parent_id': 'r'},
      ]);
      expect(paths['f4'], ['대수', '4 소인수']);
      final order = buildConceptBookOrder(
        sources: [
          _src('c1', '소수', 'f1', 8, order: 3),
          _src('c2', '합성수', 'f1', 9, order: 1),
          _src('c3', '거듭제곱', 'f1', 12, unit: _unitB),
          _src('c3', '거듭제곱', 'f1', 10, unit: _unitB),
          _src('c4', '소인수', 'f4', 8, order: 1),
          _src('c5', '1의 분류', 'f1', 9),
          _src('c6', '약수', 'f1', 9),
        ],
        folderPaths: paths,
        draftOrders: {'c6\u00019': 2},
      );
      expect([for (final e in order.entries) e.name], ['소인수', '소수', '합성수', '약수', '1의 분류', '거듭제곱']);
      final c3 = order.entries.last;
      expect(c3.rawPage, 10, reason: '여러 쪽이면 처음 나온 쪽');
      expect(c3.pages, [10, 12]);
      expect(c3.unitPath, _unitB);
      expect(order.entries.first.folderPath, ['대수', '4 소인수']);
      expect([for (final e in order.entries) e.orderFrom.name],
          ['stored', 'stored', 'stored', 'draft', 'unknown', 'unknown']);
      expect(order.computedFromDrafts, 1);
      expect(order.unknownOrder, 2);
      expect([for (final g in order.byUnit) g.unit.last], ['소수와 합성수', '거듭제곱']);
    });

    test('초안 기록으로 계산: 검토 항목 blocks가 있으면 그것, 없으면 AI 근거 블록. 쪽마다 1부터 센다', () {
      final orders = conceptPageOrdersFromDrafts([
        {
          'result': {
            'concepts': [
              {'index': 0, 'key': 'c0', 'id': 'X'},
              {'index': 1, 'key': 'c1', 'id': 'Y'},
              {'index': 1, 'key': 'c1.2', 'id': 'Z'},
            ],
          },
          'review_concepts': [
            {
              'index': 0,
              'key': 'c0',
              'blocks': ['p8-a1']
            },
            {'index': 1, 'key': 'c1'},
            {
              'index': 1,
              'key': 'c1.2',
              'blocks': ['p9-b3', 'nope']
            },
          ],
          'draft_concepts': [
            {
              'source_blocks': ['p8-a0']
            },
            {
              'source_blocks': ['p8-a0', 'p9-a0']
            },
          ],
          'blocks': [
            {'id': 'p8-a0', 'raw_page': 8},
            {'id': 'p8-a1', 'raw_page': 8},
            {'id': 'p9-a0', 'raw_page': 9},
            {'id': 'p9-b3', 'raw_page': 9},
          ],
        },
      ]);
      expect(orders, {'X\u00018': 2, 'Y\u00018': 1, 'Y\u00019': 1, 'Z\u00019': 2});
    });
  });

  test('같은 쪽이 기본 서술과 다른 서술의 출처로 함께 있어도 개념은 한 번, 쪽도 한 번이고 아는 쪽 안 순서를 쓴다', () {
    for (final rows in [
      [_src('c1', '소수', 'f1', 8), _src('c1', '소수', 'f1', 8, order: 2), _src('c1', '소수', 'f1', 9)],
      [_src('c1', '소수', 'f1', 9), _src('c1', '소수', 'f1', 8, order: 2), _src('c1', '소수', 'f1', 8)],
    ]) {
      final order = buildConceptBookOrder(sources: rows);
      expect(order.entries, hasLength(1));
      expect(order.entries.single.pages, [8, 9]);
      expect(order.entries.single.pageOrder, 2);
      expect(order.entries.single.orderFrom, ConceptPageOrderFrom.stored);
    }
  });

  group('교재 순서 창', () {
    testWidgets('단원별로 번호를 이어 매기고, 폴더와 쪽, 모르는 순서를 보인다', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final order = buildConceptBookOrder(
        sources: [
          _src('c4', '소인수', 'f4', 8, order: 1),
          _src('c1', '소수', 'f1', 8),
          _src('c3', '거듭제곱', 'f1', 10, unit: _unitB),
          _src('c3', '거듭제곱', 'f1', 11, unit: _unitB),
        ],
        folderPaths: const {
          'f1': ['대수', '1 소수'],
          'f4': ['대수', '4 소인수'],
        },
      );
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showConceptBookOrderDialog(context, book: _book(), load: (_) async => order),
            child: const Text('열기'),
          ),
        ),
      ));
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      expect(find.text('교재 순서로 보기'), findsOneWidget);
      expect(find.text('소인수분해 > 소인수분해 > 소수와 합성수'), findsOneWidget);
      expect(find.text('소인수분해 > 소인수분해 > 거듭제곱'), findsOneWidget);
      expect(find.text('3'), findsOneWidget, reason: '단원이 바뀌어도 번호는 이어진다');
      expect(find.text('대수 > 4 소인수'), findsOneWidget);
      expect(find.text('PDF 10쪽 (책 12쪽) 외 1쪽'), findsOneWidget);
      expect(find.text('쪽 안 순서 모름'), findsNWidgets(2));
      expect(find.textContaining('같은 쪽 개념 뒤에'), findsOneWidget);
    });

    testWidgets('출처가 없으면 안내하고, 읽기 실패는 다시 읽을 수 있다', (tester) async {
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ConceptBookOrderDialog(
            book: _book(),
            load: (_) async {
              calls += 1;
              if (calls == 1) throw StateError('끊김');
              return const ConceptBookOrder([]);
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('교재 순서를 읽지 못했습니다'), findsOneWidget);
      await tester.tap(find.text('다시 읽기'));
      await tester.pumpAndSettle();
      expect(find.textContaining('이 교재를 출처로 이은 개념이 없습니다'), findsOneWidget);
    });
  });
}
