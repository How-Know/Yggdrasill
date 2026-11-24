import 'dart:typed_data';

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

  test('모의고사: 찾아 둔 해설 그림은 예전 계산값 그대로인 폭만 2단 기준으로 다시 계산한다', () {
    const segments = [TextbookSolutionSegment(12, [100, 372, 900, 632])];
    final res = recomputeSolutionFigureWidths(
      [
        // 예전 계산값(252‰ → 14.5em) 그대로: 3단 해설지 단(260‰) 기준으로 키운다.
        {'path': 'a/1.png', 'raw_page': 12, 'crop_region_1k': [300, 376, 420, 628], 'width_em': 14.5, 'placement': 'below'},
        // 렌더 검수가 맞춘 폭: 둔다.
        {'path': 'a/2.png', 'raw_page': 12, 'crop_region_1k': [500, 376, 620, 628], 'width_em': 12.0},
        // 이미 새 폭: 그대로.
        {'path': 'a/3.png', 'raw_page': 12, 'crop_region_1k': [700, 376, 820, 628], 'width_em': 19.5},
        // 자리를 모르는 그림: 그대로.
        {'path': 'a/4.png', 'width_em': 10.0},
      ],
      segments,
      isMockExam: true,
    );
    expect([for (final a in res.assets) a['width_em']], [19.5, 12.0, 19.5, 10.0]);
    expect(res.changed, 1);
    expect(res.kept, 1);
    expect(res.assets.first['placement'], 'below');

    // 교재는 단 폭을 보지 않으므로 바뀌지 않는다.
    final book = recomputeSolutionFigureWidths(
      [
        {'path': 'a/1.png', 'raw_page': 12, 'crop_region_1k': [300, 376, 420, 628], 'width_em': 14.5},
      ],
      segments,
      isMockExam: false,
    );
    expect(book.changed, 0);
    expect(book.assets.single['width_em'], 14.5);
  });

  test('같은 쪽의 다음 단으로 이어진 해설의 그림은 그 그림이 있는 단을 기준으로 정렬한다', () {
    // 2025 고3 3월 미적분 28: 가운데 단에서 시작해 오른쪽 단으로 이어지고 그림은 오른쪽 단 가운데에 있다.
    final out = arrangeSolutionFigures(
      [
        {'raw_page': 4, 'crop_region_1k': [294, 706, 392, 846], 'placement': 'below'},
      ],
      const [
        TextbookSolutionSegment(4, [608, 366, 901, 632]),
        TextbookSolutionSegment(4, [138, 634, 469, 901]),
      ],
    );
    expect(out.single['align'], 'center');
  });

  test('다른 단에 있는 해설 그림과 같은 자리를 두 번 자른 그림은 가로로 묶지 않는다', () {
    // 2022 고3 9월 기하 30: 왼쪽 단 그림과 오른쪽 단 그림의 높이가 겹친다. 나란히 놓인 그림이 아니다.
    const segments = [
      TextbookSolutionSegment(19, [118, 143, 880, 481]),
      TextbookSolutionSegment(19, [118, 514, 600, 856]),
    ];
    final columns = arrangeSolutionFigures(
      [
        {'raw_page': 19, 'crop_region_1k': [437, 138, 617, 411], 'placement': 'below'},
        {'raw_page': 19, 'crop_region_1k': [328, 514, 529, 839], 'placement': 'below'},
      ],
      segments,
    );
    expect(columns.map((a) => a['row']), [null, null]);

    // 같은 단 안에서 옆으로 나란한 두 그림은 그대로 묶는다.
    final sideBySide = arrangeSolutionFigures(
      [
        {'raw_page': 19, 'crop_region_1k': [300, 150, 400, 300], 'placement': 'below'},
        {'raw_page': 19, 'crop_region_1k': [305, 320, 395, 470], 'placement': 'below'},
      ],
      segments,
    );
    expect(sideBySide.map((a) => a['row']), [1, 1]);

    // 2020 수능 나형 20: 같은 자리를 겹쳐 자른 두 그림.
    final stacked = arrangeSolutionFigures(
      [
        {'raw_page': 19, 'crop_region_1k': [573, 559, 671, 736], 'placement': 'below'},
        {'raw_page': 19, 'crop_region_1k': [560, 558, 667, 838], 'placement': 'below'},
      ],
      segments,
    );
    expect(stacked.map((a) => a['row']), [null, null]);
  });

  test('조각을 따로 보낸 해설의 그림은 AI 가 준 조각 번호의 조각 좌표로 되돌린다', () {
    TextbookReviewRenderedRegion part(int page, List<int> region) => TextbookReviewRenderedRegion(
          bytes: Uint8List(0),
          widthPx: 1100,
          heightPx: 2000,
          region1k: region,
          rawPage: page,
        );
    final parts = [part(17, [587, 512, 892, 860]), part(18, [110, 136, 885, 484])];
    final located = solutionFigurePiece(parts, 2, [278, 169, 473, 847]);
    expect(located!.part.rawPage, 18);
    expect(cropBoxToPageRegion(located.part.region1k, located.box), [316, 190, 486, 435]);
    // 번호가 없거나 범위를 벗어나면 붙이지 않는다.
    expect(solutionFigurePiece(parts, null, [0, 0, 100, 100]), isNull);
    expect(solutionFigurePiece(parts, 3, [0, 0, 100, 100]), isNull);
    expect(solutionFigurePiece(parts, 0, [0, 0, 100, 100]), isNull);
  });

  test('다듬기용 그림 영역은 여유만큼 넓히되 해설 조각 밖으로 나가지 않는다', () {
    // 조각 안쪽: 위아래 40, 좌우 25.
    expect(expandSolutionFigureRegion([300, 600, 400, 700], [121, 558, 703, 798]), [260, 575, 440, 725]);
    // 조각 경계 근처: 경계에서 멈춘다.
    expect(expandSolutionFigureRegion([130, 570, 690, 790], [121, 558, 703, 798]), [121, 558, 703, 798]);
    // 처음 상자가 여유 때문에 조각보다 조금 나가 있으면 그 끝은 그대로 둔다.
    expect(expandSolutionFigureRegion([118, 600, 300, 700], [121, 558, 703, 798]), [118, 575, 340, 725]);
  });

  test('해설 영역이 글 폭보다 넓게 잡혀도 가운데 그림은 가운데로 본다', () {
    // 수력충전 p.145 02: 영역 495~995, 그림 639~800(여백 144:195). 예전 규칙은 왼쪽으로 봤다.
    expect(solutionFigureAlign(495, 995, 639, 800), 'center');
    expect(solutionFigureAlign(495, 995, 612, 815), 'center');
    // p.134 20: 영역 514~819, 그림 600~820 → 오른쪽에 붙음
    expect(solutionFigureAlign(514, 819, 600, 820), 'right');
    expect(solutionFigureAlign(495, 995, 530, 700), 'left');
    expect(solutionFigureAlign(100, 200, 100, 200), 'center');
    // 2021 수능 공통 22: 단 폭을 다 채운 그림(영역 512~867, 그림 514~867). 여백 2:0 으로 오른쪽이 되면 안 된다.
    expect(solutionFigureAlign(512, 867, 514, 867), 'center');
    expect(solutionFigureAlign(512, 867, 512, 865), 'center');
  });

  test('해설 그림 폭은 원본 해설 쪽 폭에 맞춘다', () {
    expect(solutionFigureWidthEm(const [0, 100, 300, 275]), 10);
    expect(solutionFigureWidthEm(const [0, 0, 300, 1000]), 20);
  });

  test('모의고사: 2단 해설지보다 좁은 단의 그림은 2단 기준으로 키운다', () {
    // 2026 고3 7월 미적분 30: 3단 해설지(단 폭 260)의 단을 꽉 채운 그래프(폭 252).
    const figure = [639, 371, 729, 623];
    expect(solutionFigureWidthEm(figure), 14.5);
    expect(solutionFigureWidthEm(figure, columnWidth1k: 260), 19.5);
    // 2단 해설지(단 폭 348~368)는 그대로다.
    expect(solutionFigureWidthEm(figure, columnWidth1k: 348), 14.5);
    expect(solutionFigureWidthEm(figure, columnWidth1k: 368), 14.5);
    // 넉넉하게 키워도 카드 폭(20em)은 넘지 않는다.
    expect(solutionFigureWidthEm(const [0, 100, 300, 360], columnWidth1k: 200), 20);

    final segments = [
      TextbookSolutionSegment(6, [194, 368, 892, 628]),
      TextbookSolutionSegment(6, [139, 638, 524, 905]),
    ];
    expect(mockSolutionColumnWidth1k(true, figure, 6, segments), 260);
    // 이어진 단의 그림은 그 단의 폭으로 잰다.
    expect(mockSolutionColumnWidth1k(true, const [200, 650, 300, 800], 6, segments), 267);
    // 교재 문항, 다른 쪽의 그림은 쪽 폭으로만 잰다.
    expect(mockSolutionColumnWidth1k(false, figure, 6, segments), isNull);
    expect(mockSolutionColumnWidth1k(true, figure, 7, segments), isNull);
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
