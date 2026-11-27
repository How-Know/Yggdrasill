# 조사와 구현 범위

## 저장소에서 확인한 것

- 연산 사전은 `arithmetic_primitives`다. 자연수 사칙 37개 코드가 있고, 그 위에 분수·소수·대수 유형이 더 있다. 비용 `unit_score`는 이미 1/10로 줄어 한 자리 덧셈이 0.10이다.
- `est_seconds`는 기준 시간이 아니다. 시드 당시 비용과 비슷하게 적힌 칸이 많아, 이번 최초 시간으로 덮지 않았다.
- 문항 난이도는 `개념 점수 + 사고 점수 + 연산 점수`다. 사고 점수는 `thinking_primitives.unit_score`의 합이라 이미 가중되어 있다.
- 학생 연산 측정 화면은 없다. 과제 풀이 기록 `learning_attempts`는 다른 프로토콜이라 섞지 않았다.
- 화면은 개념 탭 오른쪽 연산 시트다. 왼쪽 연산 메뉴는 남겨 두었다.

## 구현한 위치

- 계산: `packages/ygg_arithmetic`
- 화면: `apps/yggdrasill_manager/lib/screens/arithmetic/model_lab/`
- 진입: 연산 시트의 모델 탭. `ArithmeticScreen`이 연다
- DB: `supabase/migrations/20261126040000_arithmetic_model.sql`

## 운영 정책 반영

정확도 98, 속도 90, 자동 보정은 안전 조건을 통과할 때만, 비용은 제안만, 사고 가중치는 기존 합산, 앵커 50은 상한이 아니다. 목표 등급은 나중에 쓰도록 비워 두었다.
