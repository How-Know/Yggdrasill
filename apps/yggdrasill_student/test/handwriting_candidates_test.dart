// 필기 인식 후보 재랭킹 재생 테스트.
//
// ML Kit(en-US)이 실제로 돌려주는 형태의 후보 목록을 그대로 재생해,
// 신고된 "첫 후보가 답이 아닌" 사례들이 재랭킹으로 복구되는지 확인한다.
import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_student/services/handwriting_candidates.dart';

void main() {
  group('pickHandwritingCandidate — 주관식(수학 답)', () {
    test('첫 후보가 이미 답 형태면 그대로 쓴다', () {
      expect(
        pickHandwritingCandidate(
          ['12', 'l2', 'iz'],
          answerKind: 'subjective',
        ),
        '12',
      );
    });

    test('"12"를 쓴 필기: 1순위 "l2" 대신 뒤쪽 후보 "12"를 고른다', () {
      expect(
        pickHandwritingCandidate(
          ['l2', 'lz', '12', 'iz', 'l 2'],
          answerKind: 'subjective',
        ),
        '12',
      );
    });

    test('답 형태 후보가 없으면 혼동 글자 보정으로 복구한다 (l2 → 12)', () {
      expect(
        pickHandwritingCandidate(
          ['l2', 'lz', 'iz'],
          answerKind: 'subjective',
        ),
        '12',
      );
    });

    test('"-5"를 쓴 필기: "-S" 를 보정한다', () {
      expect(
        pickHandwritingCandidate(
          ['-S', '-s', '~5'],
          answerKind: 'subjective',
        ),
        '-5',
      );
    });

    test('분수 표기 "3/4" 는 그대로 인정한다', () {
      expect(
        pickHandwritingCandidate(
          ['3/4', '314'],
          answerKind: 'subjective',
        ),
        '3/4',
      );
    });

    test('획 사이 공백은 정리한다 ("1 2" → "12")', () {
      expect(
        pickHandwritingCandidate(
          ['1 2', 'iz'],
          answerKind: 'subjective',
        ),
        '12',
      );
    });

    test('변수가 섞인 답 "x=3" 을 인정한다', () {
      expect(
        pickHandwritingCandidate(
          ['x=3', 'X=3'],
          answerKind: 'subjective',
        ),
        'x=3',
      );
    });

    test('숫자가 전혀 없는 후보뿐이면 기존처럼 첫 후보를 쓴다', () {
      expect(
        pickHandwritingCandidate(
          ['hello', 'hallo'],
          answerKind: 'subjective',
        ),
        'hello',
      );
    });

    test('빈 목록이면 빈 문자열', () {
      expect(
        pickHandwritingCandidate(const [], answerKind: 'subjective'),
        '',
      );
    });
  });

  group('pickHandwritingCandidate — 객관식(보기 번호 1~5)', () {
    test('여러 글자 후보를 제치고 한 자리 보기 번호를 고른다', () {
      expect(
        pickHandwritingCandidate(
          ['31', '3', '37'],
          answerKind: 'objective',
        ),
        '3',
      );
    });

    test('"S" 로 인식된 5를 보정한다', () {
      expect(
        pickHandwritingCandidate(
          ['S', 's', '8'],
          answerKind: 'objective',
        ),
        '5',
      );
    });

    test('보기 범위(1~5) 밖 숫자는 고르지 않는다', () {
      expect(
        pickHandwritingCandidate(
          ['7', '2'],
          answerKind: 'objective',
        ),
        '2',
      );
    });
  });

  group('pickPlausibleHandwritingCandidate — VLM 폴백 트리거', () {
    test('답 형태 후보가 있으면 그 후보를 돌려준다 (폴백 안 탐)', () {
      expect(
        pickPlausibleHandwritingCandidate(
          ['l2', '12'],
          answerKind: 'subjective',
        ),
        '12',
      );
    });

    test('신고 #1~#3 유형: 긴 다항식이 문자 뭉치로 인식되면 null (폴백 탐)', () {
      // "3x^2+2x-1" 필기를 ML Kit 이 영단어처럼 읽은 사례 재생.
      expect(
        pickPlausibleHandwritingCandidate(
          ['3xrtrx-l', 'zwtw', 'hello'],
          answerKind: 'subjective',
        ),
        isNull,
      );
    });

    test('숫자 없는 후보뿐이면 null (폴백 탐)', () {
      expect(
        pickPlausibleHandwritingCandidate(
          ['hello', 'hallo'],
          answerKind: 'subjective',
        ),
        isNull,
      );
    });

    test('빈 목록이면 null', () {
      expect(
        pickPlausibleHandwritingCandidate(const [], answerKind: 'subjective'),
        isNull,
      );
    });

    test('객관식: 보기 번호로 보정 가능한 후보가 없으면 null', () {
      expect(
        pickPlausibleHandwritingCandidate(
          ['79', 'A'],
          answerKind: 'objective',
        ),
        isNull,
      );
    });
  });

  group('normalizeHandwritingConfusions', () {
    test('혼동 글자를 숫자로 치환하고 공백을 제거한다', () {
      expect(normalizeHandwritingConfusions('l O S z'), '1052');
      expect(normalizeHandwritingConfusions('|2'), '12');
    });
  });
}
