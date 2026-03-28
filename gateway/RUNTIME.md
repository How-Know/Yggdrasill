# Gateway Runtime Guide

## 목적

- `node --watch` 개발 실행 대신 PM2 상시 실행으로 게이트웨이 세션 안정성을 높입니다.
- MQTT 세션 단절/정체 발생 시 재시작, 로그 확인, 복구 절차를 표준화합니다.

## 1) 최초 실행

`gateway` 디렉터리에서 실행:

```bash
npm install
npm run pm2:start
npm run pm2:save
```

상태 확인:

```bash
pm2 status ygg-gateway
pm2 logs ygg-gateway --lines 200
```

## 2) 부팅 자동 시작

```bash
pm2 startup
npm run pm2:save
```

`pm2 startup` 결과로 출력되는 관리자 권한 명령을 1회 실행해야 자동 시작이 활성화됩니다.

## 3) 운영 중 자주 쓰는 명령

```bash
npm run pm2:restart
npm run pm2:logs
pm2 monit
```

## 4) 장애 점검 순서 (5분 내 판별용)

1. PM2 프로세스 상태 확인
   - `pm2 status ygg-gateway`
2. MQTT 연결 이벤트 확인
   - `connected`, `reconnecting`, `offline`, `close` 로그 확인
3. watchdog 복구 로그 확인
   - `watchdog soft recover`
   - `watchdog hard recover`
4. 헬스 로그 확인
   - `lastMessageAgeMs`, `lastPublishAgeMs`, `lastInboundTopic`

## 5) 권장 환경 변수

- `MQTT_CLEAN_SESSION=false`
- `MQTT_KEEPALIVE_SEC=15`
- `MQTT_RECONNECT_PERIOD_MS=3000`
- `MQTT_CONNECT_TIMEOUT_MS=30000`
- `GW_HEALTH_INTERVAL_MS=10000`
- `GW_STALE_WARN_MS=90000`
- `GW_STALE_HARD_RESET_MS=180000`
- `GW_STALE_ACTIVITY_WINDOW_MS=600000`
- `GW_RECOVERY_COOLDOWN_MS=60000`

## 6) 검증 체크리스트

- 10분 idle 후 앱↔M5 상태 반영이 5초 내 복구되는지 확인
- 1시간 절전 후 M5 복귀 시 수동 재바인딩 없이 자동 복구되는지 확인
- 장애 시 watchdog 로그(soft/hard)와 reconnect 로그가 순서대로 남는지 확인
