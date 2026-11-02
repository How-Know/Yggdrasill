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

    test('공통 발문이 다른 문항의 본문을 담고 있으면 이 문항에서는 판단하지 않는다', () {
      expect(computeCommonStemFix(full, '$common\n[문단]\n12\n약수: box(~~)'), isNull);
    });
  });
}
