import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_problem_review_service.dart';
import 'package:yggdrasill_manager/services/textbook_review_solution_image_service.dart';

void main() {
  group('buildAnswerSolutionCardContent', () {
    test('해설 [그림] 자리에 해설 그림을 넣고 남는 그림은 끝에 붙인다', () {
      final card = buildAnswerSolutionCardContent(
        answer: '3',
        solution: '그래프는 [그림: 직선] 과 같다.',
        solutionKind: 'textbook',
        solutionFigures: const [
          {'bucket': 'problem-previews', 'path': 'a/1.png', 'width_em': 8},
          {'bucket': 'problem-previews', 'path': 'a/2.png', 'width_em': 12},
        ],
      );
      expect(card.stem, startsWith('정답  3[문단][해설][문단]'));
      expect('[그림]'.allMatches(card.stem).length, 2);
      expect(card.stem, isNot(contains('직선')));
      final assets = card.meta['figure_assets'] as List;
      expect([for (final a in assets) (a as Map)['figure_index']], [1, 2]);
      final items = (card.meta['figure_layout'] as Map)['items'] as List;
      expect((items[1] as Map)['widthEm'], 12);
    });

    test('그림 정답은 정답 줄에 첫 그림으로 들어간다', () {
      final card = buildAnswerSolutionCardContent(
        answer: '(그림 정답)',
        solution: '풀이 [그림]',
        solutionKind: 'textbook',
        answerImageBucket: 'textbook-answers',
        answerImagePath: 'x/answer.png',
        solutionFigures: const [
          {'bucket': 'problem-previews', 'path': 'a/1.png', 'width_em': 8},
        ],
      );
      expect(card.stem, startsWith('정답[문단][그림]'));
      expect(card.stem, isNot(contains('그림 정답')));
      final assets = card.meta['figure_assets'] as List;
      expect((assets[0] as Map)['path'], 'x/answer.png');
      expect((assets[1] as Map)['path'], 'a/1.png');
    });

    test('그림 없는 표시는 지우고, AI 풀이에는 원본 해설 그림을 넣지 않는다', () {
      final card = buildAnswerSolutionCardContent(
        answer: '2',
        solution: '풀이 [그림]',
        solutionKind: 'ai',
        solutionFigures: const [
          {'bucket': 'problem-previews', 'path': 'a/1.png'},
        ],
      );
      expect(card.stem, isNot(contains('[그림]')));
      expect(card.meta, isEmpty);
    });

    test('원본에서 풀이 오른쪽에 있던 해설 그림은 글과 나란히(inline-right) 놓는다', () {
      final card = buildAnswerSolutionCardContent(
        answer: '57',
        solution: '삼각형의 세 내각의 합은 180이므로[그림]',
        solutionKind: 'textbook',
        solutionFigures: const [
          {'bucket': 'problem-previews', 'path': 'a/1.png', 'width_em': 10, 'placement': 'right'},
        ],
      );
      final item = ((card.meta['figure_layout'] as Map)['items'] as List).single as Map;
      expect(item['position'], 'inline-right');
      expect(item['anchor'], 'right');
    });

    test('해설이 오른쪽 그림 표시로 시작하면 표시를 뒤 풀이 글 끝으로 옮긴다', () {
      final card = buildAnswerSolutionCardContent(
        answer: '180',
        solution: '[그림]\n동위각은 같으므로\n답은 180',
        solutionKind: 'textbook',
        solutionFigures: const [
          {'path': 'a/1.png', 'placement': 'right'},
        ],
      );
      expect(card.stem, endsWith('[해설][문단]\n동위각은 같으므로\n답은 180[문단][그림][문단]'));
    });

    test('아래 그림은 align 쪽으로, 왼쪽 그림은 같은 줄 글과, 가로 묶음은 그림 밑 설명과 놓는다', () {
      final card = buildAnswerSolutionCardContent(
        answer: '①',
        solution: '[그림]⇒ 만난다.\n[그림]⇒ 평행하다.\n[그림]⇒ 평행하다.\n꼬인 위치일 수도 있다.\n[그림]',
        solutionKind: 'textbook',
        solutionFigures: const [
          {'path': 'a/1.png', 'row': 1},
          {'path': 'a/2.png', 'row': 1},
          {'path': 'a/3.png', 'placement': 'left'},
          {'path': 'a/4.png', 'align': 'left'},
        ],
      );
      expect(
        card.stem,
        '정답  ①[문단][해설][문단][문단][그림][문단]\n[문단][그림][문단]\n'
        '⇒ 평행하다.[문단][그림][문단]\n꼬인 위치일 수도 있다.\n[문단][그림][문단]',
      );
      final layout = card.meta['figure_layout'] as Map;
      final items = [for (final x in layout['items'] as List) x as Map];
      expect([for (final x in items) x['caption']], ['⇒ 만난다.', '⇒ 평행하다.', null, null]);
      expect([for (final x in items) x['position']], ['below-stem', 'below-stem', 'inline-left', 'below-stem']);
      expect(items[3]['anchor'], 'left');
      expect(layout['groups'], [
        {
          'type': 'horizontal',
          'members': ['idx:1', 'idx:2'],
          'gap': 1.0,
        },
      ]);
    });
  });

  test('해설 그림 정렬·가로 묶음은 해설 영역 안 원본 자리에서 정한다', () {
    final out = arrangeSolutionFigures(
      [
        {'raw_page': 5, 'crop_region_1k': [100, 110, 200, 300], 'placement': 'below'},
        {'raw_page': 5, 'crop_region_1k': [110, 400, 190, 600], 'placement': 'below'},
        {'raw_page': 5, 'crop_region_1k': [300, 700, 400, 890], 'placement': 'below'},
        {'raw_page': 5, 'crop_region_1k': [500, 400, 600, 600]},
        {'raw_page': 5, 'crop_region_1k': [700, 700, 800, 890], 'placement': 'right', 'align': 'left'},
      ],
      const [
        TextbookSolutionSegment(5, [50, 100, 900, 900]),
      ],
    );
    expect([for (final a in out) a['align']], ['left', 'center', 'right', 'center', null]);
    expect([for (final a in out) a['row']], [1, 1, null, null, null]);
  });

  test('해설 영역이 글 폭보다 넓게 잡혀도 가운데 그림은 가운데로 본다', () {
    // 수력충전 p.145 02: 영역 495~995, 그림 639~800(여백 144:195). 예전 규칙은 왼쪽으로 봤다.
    expect(solutionFigureAlign(495, 995, 639, 800), 'center');
    expect(solutionFigureAlign(495, 995, 612, 815), 'center');
    // p.134 20: 영역 514~819, 그림 600~820 → 오른쪽에 붙음
    expect(solutionFigureAlign(514, 819, 600, 820), 'right');
    expect(solutionFigureAlign(495, 995, 530, 700), 'left');
    expect(solutionFigureAlign(100, 200, 100, 200), 'center');
  });

  test('해설 그림 폭은 원본 해설 쪽 폭에 맞춘다', () {
    expect(solutionFigureWidthEm(const [0, 100, 300, 275]), 10);
    expect(solutionFigureWidthEm(const [0, 0, 300, 1000]), 20);
  });

  test('그림을 가리키는 해설만 해설 그림 찾기 대상이다', () {
    TextbookProblemReviewItem item(String sol) => TextbookProblemReviewItem.fromJson({
          'crop_id': 'c1',
          'solution_transcribed': sol,
          'has_solution_ref': true,
          'solution_source_kind': 'sol',
          'solution_raw_page': 3,
          'solution_region_1k': [0, 0, 300, 500],
        });
    expect(item('y=2x 의 그래프는 오른쪽과 같다.').needsSolutionFigures, isTrue);
    expect(item('x=3 이다.').needsSolutionFigures, isFalse);
  });
  test('공통 발문에 상자가 섞여 있으면 지시문만 떼고 상자는 개별 발문에 남긴다', () {
    const stem = '다음 조건을 모두 만족시키는 입체도형을 구하여라.\n[문단]\n[박스시작]\n(가) 밑면이 1개이다.\n[박스끝]';
    const common = '다음 조건을 모두 만족시키는 입체도형을 구하여라.\n[문단]\n[박스시작]\n(가) 밑면이 1개이다.';
    final fix = computeCommonStemFix(common, stem);
    expect(fix?.commonStem, '다음 조건을 모두 만족시키는 입체도형을 구하여라.');
    expect(fix?.stem, '[박스시작]\n(가) 밑면이 1개이다.\n[박스끝]');
    // 떼고 나면 구조 표시만 남는 경우는 떼지 않는다.
    expect(stripCommonStem('가나다라.\n[박스시작]\n마바', '가나다라.\n[박스시작]\n마바\n[박스끝]'), isNull);
  });  test('표를 한 장으로 자른 뒤 남은 칸 그림은 자리가 없으면 뺀다', () {
    final assets = <Map<String, dynamic>>[
      {'figure_index': 3, 'crop_region_1k': [144, 826, 196, 904]},
      {'figure_index': 2, 'crop_region_1k': [150, 744, 198, 826]},
      {'figure_index': 1, 'crop_region_1k': [137, 560, 309, 912]},
    ];
    expect([for (final a in pruneContainedFigureAssets(assets, 1)) a['figure_index']], [1]);
    // 자리가 충분하면 그대로 둔다.
    expect(pruneContainedFigureAssets(assets, 3).length, 3);
    // 서로 떨어진 그림은 자리가 모자라도 빼지 않는다.
    final apart = <Map<String, dynamic>>[
      {'figure_index': 1, 'crop_region_1k': [100, 100, 200, 200]},
      {'figure_index': 2, 'crop_region_1k': [300, 100, 400, 200]},
    ];
    expect(pruneContainedFigureAssets(apart, 1).length, 2);
  });}
