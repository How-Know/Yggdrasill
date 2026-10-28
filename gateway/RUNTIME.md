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

## 7) 단일 문항 PDF 캐시 워커

`question-renders` private bucket에 학생 교재용 XeLaTeX v2 단일 문항 PDF를
영구 캐시합니다. 운영 서버에는 `SUPABASE_URL`,
`SUPABASE_SERVICE_ROLE_KEY`와 XeLaTeX 실행 환경이 필요합니다.

```bash
npm run worker:question-render:once
pm2 start ecosystem.config.cjs --only ygg-question-render
pm2 logs ygg-question-render --lines 200
```

환경 변수:

- `QUESTION_RENDER_WORKER_BATCH_SIZE=4`: 한 poll에서 claim할 작업 수
- `QUESTION_RENDER_WORKER_INTERVAL_MS=1500`: poll 간격
- `QUESTION_RENDER_WORKER_STALE_MS=600000`: rendering 작업 회수 기준
- `QUESTION_RENDER_WORKER_NAME`: 선택적 worker 식별자
- `QUESTION_RENDER_WARM_BATCH_MAX=100`: Edge Function warm 요청 상한

배포 순서는 migration 적용 → Edge Function 배포 → worker 시작입니다.
작업은 priority `0`(현재 문항), `1`(이웃), `2`(warm) 순으로 처리되며,
stale 작업은 retry 한도 내에서 자동 재큐잉됩니다.

## 8) Think 개념 출처 원본 쪽 이미지

`ygg-pb-api` 안에서 함께 돕니다(별도 pm2 프로세스 없음). Think가 요청한 개념책 PDF 쪽 하나를
`concept_source_page_images` 대기열에서 가져와 긴 변 1600px PNG로 그리고 private 버킷
`concept-source-pages`에 올립니다. 원본 PDF는 기존 본문 PDF 캐시(`TEXTBOOK_PDF_CACHE_DIR`)를 함께 씁니다.
poppler(`pdfinfo`, `pdftoppm`)가 PATH에 있어야 합니다. 설계: `docs/architecture/concept-library.md` §4.7.

```bash
pm2 restart ygg-pb-api
pm2 logs ygg-pb-api --lines 200   # "[concept-page] worker started", 처리마다 ready/failed 와 실패 코드
```

환경 변수:

- `CONCEPT_PAGE_WORKER=0`: 끄기(기본 켜짐)
- `CONCEPT_PAGE_WORKER_NAME`: 선택적 worker 식별자(기본 `pb-api@<호스트>`)

15초마다 `concept_source_page_workers`에 하트비트를 남기며, 60초 넘게 없으면 Think는 "원본 준비 서버 응답 없음"으로 알립니다.
migration 적용 전에는 `[concept-page] poll_failed:<코드>`가 한 번 찍히고 30초 간격으로 다시 봅니다(서버는 그대로 동작).
배포 순서는 migration 적용 → `pm2 restart ygg-pb-api` → `ai_think` 배포입니다.
