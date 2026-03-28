# MQTT Session Recovery Validation

## 자동 검증 결과

- `node --check gateway/src/index.js` -> PASS
- `node -e "require('./ecosystem.config.cjs')"` -> PASS (`ecosystem ok`)
- `platformio run -e m5-device-001` -> PASS
  - RAM 2.6% (115604 / 4521984)
  - Flash 84.2% (3309821 / 3932160)

## 단기 시나리오 (10분 idle)

1. M5와 앱을 바인딩된 상태로 유지
2. M5를 10분 이상 유휴 상태로 둠
3. 앱에서 과제 상태 변경 -> M5 반영 시간 측정
4. M5에서 과제 상태 변경 -> 앱 반영 시간 측정
5. 게이트웨이 로그에서 아래 이벤트 확인
   - `health`
   - 필요 시 `watchdog soft recover`
   - 필요 시 `watchdog hard recover`

## 장기 시나리오 (1시간 절전)

1. M5를 절전/스크린세이버 상태로 1시간 이상 유지
2. 복귀 후 즉시 양방향 상태 변경 테스트
3. 수동 재바인딩 없이 자동 복구 여부 확인
4. 아래 로그 순서 확인
   - `connected` / `reconnecting` / `offline` / `close`
   - `watchdog soft recover` 또는 `watchdog hard recover`
   - 이후 `health.lastMessageAgeMs` 정상화

## 성공 기준

- 양방향 반영 지연: 3~5초 내 회복
- 수동 재바인딩 없이 상태 동기화 복구
- 로그만으로 복구 단계 및 원인 추적 가능
