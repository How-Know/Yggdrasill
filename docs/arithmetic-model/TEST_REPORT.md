# 테스트 기록

2026-11-26. 운영 DB에는 마이그레이션을 적용하지 않았다.

## 명령과 결과

- `dart analyze` in `packages/ygg_arithmetic`: 문제 없음
- `dart test` in `packages/ygg_arithmetic`: 31개 통과
- `flutter analyze` on the changed manager files: 문제 없음
- `flutter test test/arithmetic_model_lab_test.dart`: 1개 통과

자연수 덧셈 전환 (같은 날):

- `dart test test/addition_golden_test.dart`: 9개 통과. 명세 4.5의 식 전부, 378+245 = 0.383점·3710ms 포함
- `flutter analyze` on the addition screen: 문제 없음
- `flutter test test/natural_addition_lab_test.dart`: 1개 통과

운영 DB 마이그레이션은 적용하지 않았다.

## 자동 출제 v3 (2026-11-26)

- `dart analyze` in `packages/ygg_arithmetic`: 문제 없음
- `dart test test/addition_golden_test.dart test/addition_v3_test.dart`: 19개 통과. v3 할인 제거, 다항 덧셈, 효율, Hamilton, 데모 규칙 6개, 큰 범위의 구간 경계가 시드·문항 수와 분리됨
- `flutter test test/natural_addition_lab_test.dart` (매니저): 1개 통과. 0.383점·3.710초, 출제 칸의 균등 배정과 4+5 허용
- `flutter test test/addition_training_panel_test.dart` (학습 앱): 2개 통과. 30문항 균등 6개, 1자리 10문항 적용, 2+3 정답 시 정확도 100
- 학습 앱 `flutter run -d windows`가 이미 켜져 있어 Windows 전체 빌드는 다시 돌리지 않았다. 같은 빌드 폴더를 쓰면 실행 중인 앱과 부딪힌다.

확인한 동작: 받아올림·받아내림·나눗셈 예시, 37개 시드 분류, 초안은 기존 유형을 바꾸지 않음, 속도 66.7과 숙련도 63.3, 후보 880ms와 12% 차단, 사고 점수에 5를 다시 곱하지 않음, 297+8이 2.49초, 화면에서 그 숫자와 잠긴 발행 버튼.

## 하지 않은 검사

- 마이그레이션을 실제 Postgres에 적용한 검사
- 로그인한 매니저에서 정책 발행
- 학생 앱을 따로 둔 측정. 덧셈 훈련은 학습 앱 과제 카드에서 풀고, 결과는 과제 내용에 남긴다. 로그인된 저장까지는 이 기록에서 확인하지 않았다.
