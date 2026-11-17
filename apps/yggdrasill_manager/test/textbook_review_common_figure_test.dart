import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_problem_review_service.dart';

void main() {
  const own = {
    'version': 1,
    'items': [
      {'assetKey': 'idx:1', 'widthEm': 4},
    ],
  };
  const common = {
    'version': 1,
    'items': [
      {'assetKey': 'idx:1', 'widthEm': 20},
    ],
  };

  Map<String, dynamic> row({String stem = '(1) 넓이를 구하여라.', String commonStem = '그림을 보고 답하여라.\n[그림]'}) => {
        'crop_id': 'c1',
        'stem': stem,
        'common_stem': commonStem,
        'set_type': 'independent_set',
        'pb_figure_layout': own,
        'pb_common_figure_layout': common,
      };

  test('본문에 그림 자리가 없고 공통 발문에 있으면 실제로 그려지는 공통 배치를 기준으로 삼는다', () {
    final it = TextbookProblemReviewItem.fromJson(row());
    expect(it.usesCommonFigure, isTrue);
    expect(it.renderedFigureLayout, common);
  });

  test('본문에 그림 자리가 있으면 문항 배치를 쓴다', () {
    final it = TextbookProblemReviewItem.fromJson(row(stem: '(1) [그림] 넓이를 구하여라.'));
    expect(it.usesCommonFigure, isFalse);
    expect(it.renderedFigureLayout, own);
  });

  test('반영 대기 공통 배치는 미리보기 덮어쓰기 값에 실린다', () {
    final it = TextbookProblemReviewItem.fromJson({
      ...row(),
      'staged_changes': {'common_figure_layout': common},
    });
    expect(it.previewOverride, {'common_figure_layout': common});
  });
}
