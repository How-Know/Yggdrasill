# 연산 모델

자연수 덧셈은 이 문서보다 [NATURAL_ADDITION_MODEL.md](NATURAL_ADDITION_MODEL.md)가 우선이고, 출제는 [TRAINING_GENERATOR_IMPLEMENTATION.md](TRAINING_GENERATOR_IMPLEMENTATION.md)가 우선이다. 덧셈은 유형을 고르지 않고 식으로 비용과 시간을 계산한다. 나머지 연산은 아래 유형별 모델이다.

개념 탭 → 오른쪽 연산 손잡이 → 자연수 덧셈 → 자연수 덧셈 모델.

이 칸은 연산 비용, 학생 숙련도, 기준 시간을 서로 다른 숫자로 다룬다. 비용은 작업량이고, 기준 시간은 밀리초이며, 숙련도는 0~100이다. 셋은 바꾸어 쓰지 않는다.

계산식은 `packages/ygg_arithmetic`에 있다. 화면의 시뮬레이터와 보정 판정이 그 함수를 같이 쓴다. 시뮬레이터를 움직여도 운영 값, 학생 기록, 문항 점수는 바뀌지 않는다.

운영에 반영하려면 마이그레이션 `supabase/migrations/20261126040000_arithmetic_model.sql`을 적용한 뒤, 모델 칸의 설정에서 사유를 적고 발행한다. 발행은 정책 버전만 추가한다. `arithmetic_primitives`의 비용과 `est_seconds`, 이미 저장된 문항 난이도는 그대로다.

자연수 덧셈 훈련만 학습 앱에서 측정한다. 홈 → 과제 추가 → 연산 → 교재 선택의 자동 생성으로 과제를 만들고, 그 과제 카드를 누르면 풀이·채점·시간이 과제 내용에 남는다. 다른 연산의 시도 기록 테이블은 아직 없다. 보정 칸의 학생 수는 가상 입력이다. 교육과정 규칙은 [CURRICULUM_INTEGRATION.md](CURRICULUM_INTEGRATION.md).

자세한 식은 [MODEL_SPEC.md](MODEL_SPEC.md), 테이블은 [DATA_DICTIONARY.md](DATA_DICTIONARY.md), 조작은 [ADMIN_GUIDE.md](ADMIN_GUIDE.md), 남은 일은 [ROADMAP.md](ROADMAP.md).
