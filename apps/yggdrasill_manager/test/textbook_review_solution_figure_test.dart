import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_problem_review_service.dart';

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
}
