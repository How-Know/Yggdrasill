import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_kiosk/services/korean_matcher.dart';

void main() {
  group('KoreanMatcher', () {
    test('한글 이름에서 초성을 추출한다', () {
      expect(KoreanMatcher.initialsOf('홍길동'), 'ㅎㄱㄷ');
      expect(KoreanMatcher.initialsOf('김 민수'), 'ㄱ ㅁㅅ');
    });

    test('연속 초성으로 이름을 찾는다', () {
      expect(KoreanMatcher.matches('홍길동', 'ㅎㄱㄷ'), isTrue);
      expect(KoreanMatcher.matches('김민수', 'ㄱㅁ'), isTrue);
      expect(KoreanMatcher.matches('김민수', 'ㄴㅁ'), isFalse);
    });

    test('완성형과 공백 및 영문을 정규화한다', () {
      expect(KoreanMatcher.matches('김 민수', '민수'), isTrue);
      expect(KoreanMatcher.matches('Alice Kim', 'alicekim'), isTrue);
      expect(KoreanMatcher.matches('박서준', ''), isTrue);
    });
  });
}
