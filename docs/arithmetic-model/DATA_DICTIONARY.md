# 데이터 사전

기존 `arithmetic_primitives`는 그대로다.

| 열 | 의미 | 이번 변경 |
|---|---|---|
| `code` | 기존 안정 코드. 예: `nat_add_1d_1d_nc` | 유지 |
| `unit_score` | 연산 비용. 한 자리 덧셈은 0.10 | 수정하지 않음 |
| `est_seconds` | 예전 예상 초. 기준 시간과 다른 칸 | 수정하지 않음 |

새 테이블은 마이그레이션 `20261126040000_arithmetic_model.sql`에 있다. 앱 역할에는 직접 쓰기를 주지 않고, 슈퍼관리자 RPC로만 읽거나 정책을 발행한다.

| 테이블 | 역할 |
|---|---|
| `arithmetic_measurement_protocols` | 기초 암산 / 메모 허용, 정수 답 / 몫·나머지. 계산기는 모두 금지 |
| `arithmetic_reference_seeds` | 기존 코드에 연결한 최초 기준 시간(ms). 시드 버전 1. 비용 열 없음 |
| `arithmetic_reference_revisions` | 나중 보정 적용을 넣을 빈 개정 표. 이번 앱은 행을 쓰지 않는다 |
| `arithmetic_type_candidates` | 신규 25개 후보. 상태는 draft. 기존 분류와 점수를 바꾸지 않는다 |
| `arithmetic_model_policies` | 정책 버전. 활성은 최대 하나. 파라미터는 jsonb |
| `arithmetic_model_events` | 발행 이력. 학생 이름을 넣지 않는다 |

시도 원본 테이블은 없다. 학생 앱 위치가 정해지고 탈퇴 삭제 목록에 올린 뒤에 만든다.

`arithmetic_model_publish_policy`는 기대 버전이 활성 버전과 같아야 새 버전을 넣는다. 다르면 `arithmetic_model_conflict`로 거절한다. 50점을 상한으로 두거나, 속성 시간을 숙련도에 넣거나, 사고 점수 의미를 이미 가중된 값이 아닌 것으로 발행하면 거절한다.
