# 홈 실시간 복구 후속 계획

## 현재 적용 범위

2026-08-21 기준으로 다음 복구 안전장치를 먼저 적용한다.

1. `HomeworkStore` 재연결 시 실제 서버 스냅샷을 다시 읽는다.
2. 단순 재구독은 homework poll cursor를 현재 시각으로 초기화하지 않는다.
3. 활성 assignment 조회 실패 시 마지막 성공 캐시를 유지한다.
4. 학생별 assignment 조회에 generation guard를 적용해 늦은 과거 응답을 버린다.
5. 앱 복귀와 Windows 창 포커스 시 `HomeRealtimeSyncCoordinator`가 출석·과제
   스냅샷을 함께 갱신한다. 동시 호출은 합치고 완료 후 15초 동안 중복 실행을 막는다.

이 단계에서는 주기적 폴링 확대, 출석 UI 상태 구조 변경, M5 RPC 변경을 하지 않는다.
운영 중 네트워크 단절 후 복구 상태를 먼저 확인한 뒤 아래 항목을 순서대로 검토한다.

## 4. 경량 보조 폴링

### 필요한 상황

- WebSocket이 `subscribed`로 보이지만 이벤트만 오지 않는 half-open 상태
- 앱에 lifecycle/window focus 이벤트가 발생하지 않은 채 네트워크만 복구된 경우
- assignment 전용 변경을 Realtime에서 놓친 경우

### 제안

- 출석은 오늘 또는 선택 날짜 전후의 좁은 범위만 조회한다.
- Realtime 정상 시 15~30초, degraded 시 1~3초 후 지수 백오프를 적용한다.
- homework items/groups/group runtime뿐 아니라 group items, assignments, checks도
  변경 감지 범위에 포함한다.
- `updated_at` cursor는 2~5초 overlap, 안정적인 ID tie-breaker, 페이지네이션을
  사용한다.
- 삭제는 timestamp delta만으로 찾을 수 없으므로 주기적인 좁은 스냅샷 비교가 필요하다.

### 주의점

- 과거 2년~미래 1년 출석 전체를 주기적으로 읽지 않는다.
- Realtime·poll·focus resync가 동시에 실행돼도 하나의 요청으로 합쳐야 한다.

## 5. 출석 로컬 overlay 정합성과 실패 롤백

### 현재 위험

`MainScreen`의 `_attendedSetIds`, `_leavedSetIds`, 시간 Map은 서버 데이터의
낙관적 보조 상태다. 저장 실패 또는 다른 기기에서 등원 취소가 발생하면 서버와
다른 상태가 화면에 남을 수 있다.

### 제안

- 등원/하원 저장 실패 시 직전 UI 상태로 되돌리고 사용자에게 재시도 가능 오류를 표시한다.
- 서버 스냅샷 성공 후 로컬 overlay를 서버 기준으로 재구축한다.
- 아직 저장 중인 mutation은 별도 pending 상태로 보존해 스냅샷이 덮지 않게 한다.
- `sessionOverridesNotifier`, 학생 수업시간 변경도 사이드시트 캐시를 무효화한다.
- 홈 중앙 목록과 사이드시트가 동일한 출석 판정 함수를 사용하도록 통합한다.

## 6. M5 다회수업 매칭

### 현재 위험

M5 등원 RPC는 날짜 기준으로 출석 행 하나를 선택한다. 같은 학생이 하루에 여러
수업을 듣는 경우 다른 `set_id`의 planned 행이 갱신될 수 있다.

### 제안

1. 가능하면 M5 요청에 `set_id` 또는 수업 식별자를 포함한다.
2. 구형 펌웨어 호환을 위해 식별자가 없으면 현재 시각에 가장 가까운 미등원 planned
   수업을 서버에서 선택한다.
3. 후보가 모호하면 임의의 첫 행을 갱신하지 말고 진단 로그와 명시적 fallback을 남긴다.
4. RPC 변경은 기존 15대 기기 payload와 호환되는 DB migration으로 배포한다.

## 7. 장기 단일 Sync Coordinator

현재 coordinator는 lifecycle/focus 스냅샷을 묶는 얇은 계층이다. 문제가 계속되면
다음 책임까지 확장한다.

- Realtime 상태, poll 상태, 마지막 성공 시각을 한곳에서 관리
- 출석·homework·assignment를 학생별 단일 snapshot으로 publish
- optimistic mutation과 서버 snapshot의 결정적 merge
- per-table cursor와 삭제 tombstone 처리
- 채널 장기 degraded 시 안전한 채널 재생성
- 구조화 로그: reason, generation, latency, changed student 수, retry 횟수
- UI에 오프라인/동기화 지연 상태 표시

## 적용 판단 기준

다음 중 하나라도 반복되면 4번부터 추가 적용한다.

- 네트워크 복구 또는 창 포커스 후 15초가 지나도 과제 카드가 다른 기기와 다름
- 등원/하원 변경이 재실행 전까지 반영되지 않음
- 활성 과제 카드가 사라졌다가 다시 나타남
- 다른 기기에서 취소한 등원이 현재 PC에 계속 남음
- 하루 두 수업 학생이 M5 등원 시 잘못된 수업으로 이동함

## 필수 회귀 시나리오

- 네트워크를 5초, 30초, 2분 차단한 동안 다른 기기에서 과제·출석 변경
- 오프라인으로 앱을 시작한 뒤 온라인 전환
- WebSocket만 차단하고 REST는 정상인 상태
- 앱 최소화 및 Windows 창 포커스 복귀
- 과제 조회 두 요청의 응답 순서 역전
- 등원/하원 저장 실패
- 하루 두 수업 학생의 M5 등원
