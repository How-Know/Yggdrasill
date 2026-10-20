import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/category_tree.dart';
import 'package:yggdrasill_manager/screens/curriculum/widgets/concept_anchor_dialogs.dart';
import 'package:yggdrasill_manager/services/concept_category_service.dart';
import 'package:yggdrasill_manager/services/concept_draft_models.dart';
import 'package:yggdrasill_manager/services/concept_service.dart';
import 'package:yggdrasill_manager/services/concept_topic.dart';

ConceptItem _c(String id, String name) =>
    ConceptItem(id: id, kind: ConceptKind.definition, name: name, content: '$name 본문');

const _rank = {'정의': 10, '표현': 20, '주의': 30, '성질': 40, '방법': 50};

ConceptTreeMeta _meta(Map<String, String> typeOf, [Map<String, String> anchorOf = const {}]) =>
    ConceptTreeMeta(typeOf: typeOf, typeRank: _rank, anchorOf: anchorOf);

List<String> _ids(List<ConceptTopicNode> nodes) => [for (final n in nodes) n.concept.id];

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SizedBox(width: 640, height: 900, child: child)),
    );

void main() {
  group('주제 묶음 순서', () {
    final concepts = [_c('m', '방법'), _c('p', '성질'), _c('d', '정의'), _c('n', '표현'), _c('x', '유형 없음'), _c('w', '주의')];
    final types = {'m': '방법', 'p': '성질', 'd': '정의', 'n': '표현', 'w': '주의'};

    test('묶음이 없으면 정의 → 표현 → 주의 → 성질 → 방법 → 유형 없음 순서', () {
      final forest = conceptTopicForest(concepts, _meta(types));
      expect(_ids(forest), ['d', 'n', 'w', 'p', 'm', 'x']);
    });

    test('여러 단계로 붙고, 형제도 유형 순서로 선다', () {
      final forest = conceptTopicForest(concepts, _meta(types, {'m': 'p', 'p': 'd', 'w': 'd', 'n': 'd'}));
      expect(_ids(forest), ['d', 'x']);
      expect(_ids(forest.first.children), ['n', 'w', 'p']);
      expect(_ids(forest.first.children.last.children), ['m']);
      expect(forest.first.size, 5);

      final lines = flattenTopicForest(forest);
      expect([for (final l in lines) '${l.node.concept.id}${l.depth}'], ['d0', 'n1', 'w1', 'p1', 'm2', 'x0']);
      final m = lines.firstWhere((l) => l.node.concept.id == 'm');
      expect(m.last, isTrue);
      expect(m.ancestorsHaveNext, [true, false]);
    });

    test('다른 폴더·자기 자신·고리를 가리키는 묶음은 뿌리로 둔다', () {
      final forest = conceptTopicForest(concepts, _meta(types, {'m': 'other-folder', 'n': 'n', 'p': 'w', 'w': 'p'}));
      expect(_ids(forest), ['d', 'n', 'w', 'p', 'm', 'x']);
    });

    test('같은 유형이면 저장 순서를 지킨다', () {
      final forest = conceptTopicForest([_c('b', 'B'), _c('a', 'A')], _meta({'a': '정의', 'b': '정의'}));
      expect(_ids(forest), ['b', 'a']);
    });

    test('고리 검사와 묶음 바꾸기', () {
      const links = {'b': 'a', 'c': 'b'};
      expect(anchorMakesCycle('a', 'c', links), isTrue);
      expect(anchorMakesCycle('a', 'a', links), isTrue);
      expect(anchorMakesCycle('c', 'a', links), isFalse);
      expect(anchorMakesCycle('a', null, links), isFalse);
      expect(anchorCycleMembers(links), isEmpty);
      expect(anchorCycleMembers({...links, 'a': 'c'})..sort(), ['a', 'b', 'c']);

      final meta = _meta({'a': '정의'}, links).withAnchors({'c': null, 'd': 'a'});
      expect(meta.anchorOf, {'b': 'a', 'd': 'a'});
      expect(meta.typeOrder, ['정의', '표현', '주의', '성질', '방법']);
      expect(meta.rankOf('a'), 10);
      expect(meta.rankOf('none'), greaterThan(meta.rankOf('a')));
    });

    test('제안 응답 읽기', () {
      final p = ConceptAnchorProposal.fromJson({
        'proposal': {
          'summary': ' 정의 뒤로 묶었습니다 ',
          'items': [
            {'concept_id': 'b', 'anchor_id': 'a', 'current_anchor_id': null, 'reason': '정의를 먼저 안다'},
            {'concept_id': 'a', 'anchor_id': null, 'current_anchor_id': null},
            'bad',
          ],
          'checks': {
            'unanswered': ['c'],
            'broken': []
          },
        },
        'cost_usd': 0.012,
      });
      expect(p.summary, '정의 뒤로 묶었습니다');
      expect([for (final i in p.items) '${i.conceptId}:${i.changed}'], ['b:true', 'a:false']);
      expect(p.unanswered, ['c']);
      expect(p.costUsd, closeTo(0.012, 1e-9));
    });
  });

  group('검토 창 묶음', () {
    const types = [ConceptTypeInfo(name: '정의', description: '', legacySubType: '정의')];
    ReviewItem item(int i,
            {List<String> folder = const ['대수', '수'],
            String? anchor,
            ReviewMark mark = ReviewMark.keep,
            String? merged}) =>
        ReviewItem(
            index: i,
            mark: mark,
            title: 't$i',
            content: 'b',
            type: '정의',
            folder: folder,
            anchor: anchor,
            mergedInto: merged);

    test('남긴 같은 폴더 항목만 잇고, 합친 항목은 합친 쪽을 따라간다', () {
      final items = [
        item(0),
        item(1, anchor: 'c0'),
        item(2, mark: ReviewMark.drop, merged: 'c0'),
        item(3, anchor: 'c2'),
        item(4, anchor: 'c1', folder: ['대수', '식']),
        item(5, anchor: 'c9'),
        item(6, mark: ReviewMark.drop),
        item(7, anchor: 'c6'),
      ];
      expect(reviewAnchorTarget(items, items[3])?.key, 'c0');
      expect(reviewAnchorTarget(items, items[7]), isNull);
      expect(reviewAnchorLinks(items), {'c1': 'c0', 'c3': 'c0'});
      expect(reviewAnchorCycle(items), isEmpty);
      expect(reviewProblem(items.where((x) => x.kept).toList(), ['대수'], types: types), isNull);

      final looped = [items[0].copyWith(anchor: 'c1'), ...items.skip(1)];
      expect(reviewAnchorCycle(looped)..sort(), ['c0', 'c1']);
      expect(reviewProblem(looped.where((x) => x.kept).toList(), ['대수'], types: types), contains('주제 묶음이 서로 가리킵니다'));
      expect(sameReview(items, looped), isFalse);
    });

    test('묶음은 저장·복원되고 지울 수 있다', () {
      final it = item(1, anchor: 'c0');
      final back = ReviewItem.fromJson(it.toJson());
      expect(back.anchor, 'c0');
      expect(item(1).toJson().containsKey('anchor'), isFalse);
      expect(it.copyWith(clearAnchor: true).anchor, isNull);
      expect(it.copyWith(title: 'x').anchor, 'c0');
    });
  });

  group('개념 트리', () {
    final folder = CategoryNode(id: 'f1', name: '소인수분해', concepts: [
      _c('m', '소인수분해하는 법'),
      _c('p', '소인수분해의 유일성'),
      _c('d', '소인수분해'),
      _c('n', '거듭제곱 표기'),
      _c('x', '옛 개념'),
    ]);
    final roots = [
      CategoryNode(id: 'r', name: '대수', children: [folder])
    ];
    final meta = _meta({'m': '방법', 'p': '성질', 'd': '정의', 'n': '표현'}, {'p': 'd', 'm': 'p'});

    Future<void> tapFolder(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(ValueKey('folder-$id')));
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    }

    Future<void> openFolder(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('concept-tree-view-chips')));
      await tester.pumpAndSettle();
      await tapFolder(tester, 'r');
      await tapFolder(tester, 'f1');
    }

    double y(WidgetTester tester, String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy;

    double opacityOf(WidgetTester tester, String chipKey) => tester
        .widget<AnimatedOpacity>(
            find.descendant(of: find.byKey(ValueKey(chipKey)), matching: find.byType(AnimatedOpacity)).first)
        .opacity;

    testWidgets('칩·목록 보기를 바꾸고, 목록은 유형·묶음 순서로 선다', (tester) async {
      await tester.pumpWidget(_host(CategoryTree(roots: roots, meta: meta)));
      await openFolder(tester);
      for (final id in ['m', 'p', 'd', 'n', 'x']) {
        expect(find.byKey(ValueKey('concept-chip-$id')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('concept-row-d')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('concept-tree-view-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('concept-chip-d')), findsNothing);
      final order = ['d', 'p', 'm', 'n', 'x'];
      for (var i = 1; i < order.length; i++) {
        expect(y(tester, 'concept-row-${order[i - 1]}'), lessThan(y(tester, 'concept-row-${order[i]}')));
      }
      double nameX(String id, String name) =>
          tester.getTopLeft(find.descendant(of: find.byKey(ValueKey('concept-row-$id')), matching: find.text(name))).dx;
      expect(nameX('m', '소인수분해하는 법'), greaterThan(nameX('p', '소인수분해의 유일성')));
      expect(nameX('p', '소인수분해의 유일성'), greaterThan(nameX('d', '소인수분해')));
      expect(nameX('n', '거듭제곱 표기'), nameX('d', '소인수분해'));
    });

    testWidgets('유형 거르기·찾기는 숨기지 않고 흐리게 한다', (tester) async {
      await tester.pumpWidget(_host(CategoryTree(roots: roots, meta: meta)));
      await openFolder(tester);
      expect(find.byKey(const ValueKey('concept-type-filter-정의')), findsOneWidget);
      expect(find.byKey(const ValueKey('concept-type-filter-유형 없음')), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(const ValueKey('concept-type-filter-정의'))).dx,
          lessThan(tester.getTopLeft(find.byKey(const ValueKey('concept-type-filter-방법'))).dx));

      await tester.tap(find.byKey(const ValueKey('concept-type-filter-정의')));
      await tester.pumpAndSettle();
      expect(find.text('맞는 개념 1개'), findsOneWidget);
      expect(find.byKey(const ValueKey('concept-chip-m')), findsOneWidget);
      expect(opacityOf(tester, 'concept-chip-d'), 1);
      expect(opacityOf(tester, 'concept-chip-m'), lessThan(1));

      await tester.tap(find.byKey(const ValueKey('concept-type-filter-정의')));
      await tester.enterText(find.byKey(const ValueKey('concept-tree-search')), '유일성');
      await tester.pumpAndSettle();
      expect(find.text('맞는 개념 1개'), findsOneWidget);
      expect(opacityOf(tester, 'concept-chip-p'), 1);
      expect(opacityOf(tester, 'concept-chip-d'), lessThan(1));
    });

    testWidgets('찾으면 맞는 개념이 든 폴더를 펼친다', (tester) async {
      await tester.pumpWidget(_host(CategoryTree(roots: roots, meta: meta)));
      expect(find.byKey(const ValueKey('folder-f1')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('concept-tree-search')), '표기');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('concept-chip-n')), findsOneWidget);
    });

    testWidgets('폴더 버튼은 마우스를 올렸을 때만 보이고, 메뉴에서 묶음 제안을 연다', (tester) async {
      CategoryNode? proposed;
      await tester.pumpWidget(_host(CategoryTree(
        roots: roots,
        meta: meta,
        onAddChild: (_) async {},
        onRename: (_) async {},
        onProposeAnchors: (n) async => proposed = n,
      )));
      await openFolder(tester);
      expect(find.byKey(const ValueKey('folder-menu-f1')), findsNothing);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('folder-f1'))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-menu-f1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('주제 묶음 제안받기'));
      await tester.pumpAndSettle();
      expect(proposed?.id, 'f1');
    });
  });

  group('묶음 창', () {
    final folder = CategoryNode(
        id: 'f1', name: '소인수분해', concepts: [_c('a', '소인수분해'), _c('b', '유일성'), _c('c', '나누는 법'), _c('d', '거듭제곱')]);
    final types = {'a': '정의', 'b': '성질', 'c': '방법', 'd': '표현'};

    Future<T?> open<T>(WidgetTester tester, Future<T?> Function(BuildContext) show) async {
      T? result;
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await show(context),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('개념 상세 고르기: 이 개념에 붙은 개념은 고를 수 없다', (tester) async {
      ConceptAnchorChoice? choice;
      var done = false;
      await open(tester, (context) async {
        choice = await showConceptAnchorPicker(context,
            concept: folder.concepts[0], folder: folder, meta: _meta(types, {'b': 'a', 'c': 'b'}));
        done = true;
        return null;
      });
      final save = find.widgetWithText(ElevatedButton, '저장');
      expect(tester.widget<ElevatedButton>(save).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('anchor-option-c')));
      await tester.pumpAndSettle();
      expect(tester.widget<ElevatedButton>(save).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('anchor-option-d')));
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(done, isTrue);
      expect(choice?.anchorId, 'd');
    });

    ConceptAnchorProposal proposal(List<(String, String?)> links) => ConceptAnchorProposal(summary: '정의 뒤로 묶음', items: [
          for (final (id, anchor) in links)
            ConceptAnchorProposalItem(conceptId: id, anchorId: anchor, currentAnchorId: null, reason: '이유 $id'),
        ]);

    testWidgets('묶음 제안: 체크한 바뀐 줄만 proposal로 저장한다', (tester) async {
      Map<String, String?>? saved;
      String? savedOrigin;
      await open(
          tester,
          (context) => showDialog<bool>(
                context: context,
                builder: (_) => ConceptAnchorProposalDialog(
                  folder: folder,
                  meta: _meta(types),
                  propose: (_) async => proposal([('a', null), ('b', 'a'), ('c', 'b'), ('d', 'a')]),
                  save: (links, {required String origin}) async {
                    saved = links;
                    savedOrigin = origin;
                  },
                ),
              ));
      expect(find.text('정의 뒤로 묶음'), findsOneWidget);
      expect(find.text('고른 줄 저장 (3)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('anchor-apply-d')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('anchor-proposal-save')));
      await tester.pumpAndSettle();
      expect(saved, {'b': 'a', 'c': 'b'});
      expect(savedOrigin, 'proposal');
    });

    testWidgets('묶음 제안: 서로 가리키면 저장을 막는다', (tester) async {
      var saves = 0;
      await open(
          tester,
          (context) => showDialog<bool>(
                context: context,
                builder: (_) => ConceptAnchorProposalDialog(
                  folder: folder,
                  meta: _meta(types),
                  propose: (_) async => proposal([('a', 'c'), ('c', 'a')]),
                  save: (links, {required String origin}) async => saves++,
                ),
              ));
      expect(find.textContaining('서로 가리키는 묶음'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(find.byKey(const ValueKey('anchor-proposal-save'))).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('anchor-apply-c')));
      await tester.pumpAndSettle();
      expect(find.textContaining('서로 가리키는 묶음'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('anchor-proposal-save')));
      await tester.pumpAndSettle();
      expect(saves, 1);
    });
  });
}
