import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_problem_review_service.dart';

void main() {
  const common = '다음 수의 약수를 모두 구하고, 소수인지 합성수인지 ([공백:2]) 안에 써넣어라.';

  test('공통 발문이 개별 발문 앞머리에 중복되면 공통 부분을 뗀 본문을 돌려준다', () {
    expect(
      stripCommonStem(common, '다음 수의 약수를 모두 구하고, 소수인지 합성수인지 ([공백:2]) 안에 써넣어라.\n[문단]\n9\n약수: box(~~)'),
      '9\n약수: box(~~)',
    );
  });

  test('공백·[문단] 차이는 무시한다', () {
    expect(stripCommonStem('다음을 구하여라.', '다음을  구하여라.[문단]7'), '7');
  });

  test('중복이 없거나 떼어내면 비는 경우는 null', () {
    expect(stripCommonStem(common, '9\n약수: box(~~)'), isNull);
    expect(stripCommonStem('', '9'), isNull);
    expect(stripCommonStem('다음을 구하여라.', '다음을 구하여라.'), isNull);
  });

  test('앞머리가 아니어도 정확히 같은 문자열이면 제거한다', () {
    expect(stripCommonStem('다음을 구하여라.', '[문단]7\n다음을 구하여라.'), '7');
  });

  test('서술형 표현과 답 비교 정규화', () {
    expect(kEssayPattern.hasMatch('풀이 과정을 쓰시오.'), isTrue);
    expect(kEssayPattern.hasMatch('그 이유를 설명하시오.'), isTrue);
    expect(kEssayPattern.hasMatch('다음 수를 소인수분해하여라.'), isFalse);
    expect(normalizeAnswerForCompare(r'$2^4 \times 3$'), normalizeAnswerForCompare('2^4×3'));
    expect(normalizeAnswerForCompare(r'2^{4}\cdot 3'), normalizeAnswerForCompare('2^4×3'));
    expect(normalizeAnswerForCompare(r'$-3 \leq x < 4$'), normalizeAnswerForCompare('-3 ≤ x < 4'));
    expect(normalizeAnswerForCompare(r'$x \geq 2$'), normalizeAnswerForCompare('x ≥ 2'));
  });

  test('진행률 퍼센트는 반올림하고 분모가 0이면 0이다', () {
    expect(percentOf(0, 0), 0);
    expect(percentOf(1, 3), 33);
    expect(percentOf(2, 3), 67);
    expect(percentOf(202, 202), 100);
  });

  test('formatAnswerForCard 는 소문항 번호(1) 2) 3)) 사이를 줄바꿈([문단])하고 번호 뒤에 고정 공백 마커를 넣는다', () {
    expect(
      formatAnswerForCard('1) 1, 2, 4, 8 2) 1, 2, 3, 4, 6, 12 3) 1, 2, 4 4) 4'),
      '1)[공백:0.4]1, 2, 4, 8[문단]2)[공백:0.4]1, 2, 3, 4, 6, 12[문단]3)[공백:0.4]1, 2, 4[문단]4)[공백:0.4]4',
    );
  });

  test('페이지·문항번호 흐름순 정렬(compareItemsByPageAndNumber) 및 누락 문항 감지(detectMissingProblemGaps)', () {
    final i1 = TextbookProblemReviewItem.fromJson({
      'crop_id': 'c1',
      'problem_number': '01',
      'raw_page': 25,
      'sub_key': 'A',
      'sub_index': 0,
    });
    final i2 = TextbookProblemReviewItem.fromJson({
      'crop_id': 'c2',
      'problem_number': '02',
      'raw_page': 25,
      'sub_key': 'A',
      'sub_index': 0,
    });
    final i4 = TextbookProblemReviewItem.fromJson({
      'crop_id': 'c4',
      'problem_number': '04',
      'raw_page': 25,
      'sub_key': 'A',
      'sub_index': 0,
    });
    final i10 = TextbookProblemReviewItem.fromJson({
      'crop_id': 'c10',
      'problem_number': '10',
      'raw_page': 26,
      'sub_key': 'A',
      'sub_index': 0,
    });
    final list = [i10, i4, i1, i2]..sort(compareItemsByPageAndNumber);
    expect(list.map((e) => e.problemNumber).toList(), ['01', '02', '04', '10']);

    final gaps = detectMissingProblemGaps(list);
    expect(gaps, hasLength(1));
    expect(gaps.single.missingNumber, '03');
    expect(gaps.single.rawPage, 25);
    expect(gaps.single.afterCropId, 'c2');
  });

  test('해설지에 답만 인쇄된 문항(isAnswerOnlyOriginalSolution)과 [image] 자리표시자 정답 처리', () {
    final answerOnlyItem = TextbookProblemReviewItem.fromJson({
      'crop_id': 'c1',
      'problem_number': '02',
      'raw_page': 44,
      'has_solution_ref': true,
      'solution_raw_page': 3,
      'solution_transcribed': null,
      'solution_answer': r'$-4$',
      'ai_answer': r'$-4$',
      'ai_solution': '풀이',
      'existing_answer': '[image]',
      'fix_proposal': {'proposed_answer': '-4'},
      'quality_checks': {
        'solution_vision': {'found': true, 'confidence': 'high'},
      },
    });
    expect(answerOnlyItem.hasOriginalSolution, isFalse);
    expect(answerOnlyItem.isAnswerOnlyOriginalSolution, isTrue);
    expect(answerOnlyItem.solutionVisionFailed, isFalse);
    expect(answerOnlyItem.displayAnswer, '-4');

    final failedVisionItem = TextbookProblemReviewItem.fromJson({
      'crop_id': 'c2',
      'problem_number': '19',
      'raw_page': 45,
      'has_solution_ref': true,
      'solution_raw_page': 3,
      'solution_transcribed': null,
      'solution_answer': null,
      'ai_answer': '5',
      'ai_solution': '풀이',
      'quality_checks': {
        'solution_vision': {'found': false, 'confidence': 'low', 'note': '번호 불일치'},
      },
    });
    expect(failedVisionItem.isAnswerOnlyOriginalSolution, isFalse);
    expect(failedVisionItem.solutionVisionFailed, isTrue);
  });

  group('computeCommonStemFix', () {
    const full = '$common\n[문단]\n9\n약수: box(~~)';

    test('common_stem == stem 이면 공통 발문은 지시문만, 개별 발문은 나머지만', () {
      final fix = computeCommonStemFix(full, full)!;
      expect(fix.stem, '9\n약수: box(~~)');
      expect(fix.commonStem, common);
    });

    test('지시문만 중복이면 공통 발문은 그대로(null)', () {
      final fix = computeCommonStemFix('다음을 구하여라.', '다음을 구하여라.[문단]7')!;
      expect(fix.stem, '7');
      expect(fix.commonStem, isNull);
    });

    test('여러 문단으로 된 정당한 공통 발문(조건 상자)은 건드리지 않는다', () {
      expect(computeCommonStemFix('다음 물음에 답하여라.[문단][박스시작]a>0[박스끝]', '12'), isNull);
    });

    test('[문단] 없이 줄바꿈·한 줄로 붙어 있어도 지시문을 찾는다', () {
      const one = '다음 수를 소인수분해하여라. 48';
      final fix = computeCommonStemFix(one, one)!;
      expect(fix.stem, '48');
      expect(fix.commonStem, '다음 수를 소인수분해하여라.');
      final fix2 = computeCommonStemFix('다음 수를 소인수분해하여라.\n48', '다음 수를 소인수분해하여라.\n48')!;
      expect(fix2.stem, '48');
      expect(fix2.commonStem, '다음 수를 소인수분해하여라.');
      // 한 문장짜리 정상 공통 발문은 건드리지 않는다
      expect(computeCommonStemFix('다음 수를 소인수분해하여라.', '48'), isNull);
    });

    test('공통 발문이 다른 문항의 본문을 담고 있으면 이 문항에서는 판단하지 않는다', () {
      expect(computeCommonStemFix(full, '$common\n[문단]\n12\n약수: box(~~)'), isNull);
    });
  });
}
