# Yggdrasill Gateway

MQTT to Supabase RPC bridge service

## Env (.env)

SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-anon-key
MQTT_URL=mqtts://broker.example.com:8883
MQTT_USERNAME=your-user
MQTT_PASSWORD=your-pass
MQTT_CA_PATH=./ca.crt
MQTT_CLIENT_ID=ygg-gateway-yourpc  # 선택사항(미설정 시 자동 생성)

## Run

pnpm i
pnpm dev

## Topic

- academies/+/students/+/homework/+/command (QoS1)
- academies/+/devices/+/presence (QoS1 retained)
- academies/+/devices/+/command (QoS1)
- academies/+/devices/+/students_today (QoS1) ← gateway publishes

## Actions → RPC

- start → homework_start
- pause → homework_pause
- submit → homework_submit
- confirm → homework_confirm
- wait → homework_wait
- complete → homework_complete
- presence → m5_device_presence
- command.bind → m5_bind_device
- command.unbind → m5_unbind_device
- command.list_today → m5_get_students_today_basic

## Notes
- TLS: MQTT_CA_PATH 지정 시 CA로 서버 인증
- Idempotency: idempotency_key로 중복 처리 방지(메모리 TTL 간이 처리; 운영 시 Redis 권장)

## Attendance AlimTalk Worker

고정 IP 서버(Lightsail/VPS)에서 비즈뿌리오 알림톡 발송만 전담하는 워커입니다.

### Required env

SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
BIZPPURIO_ACCOUNT=your-biz-account
BIZPPURIO_PASSWORD=your-biz-password

### Optional env

BIZPPURIO_DOMAIN=api.bizppurio.com
ALIMTALK_BATCH_SIZE=20
ALIMTALK_MAX_ATTEMPTS=5
WORKER_INTERVAL_MS=60000
ALIMTALK_ONLY_TODAY=1

### Run worker

npm run worker:alimtalk

### Run one batch only

npm run worker:alimtalk:once

### Consent filter

학생 탭 "알림 동의" 체크는 `student_basic_info.notification_consent`에 저장됩니다.
워커는 `notification_consent = true`인 학생에게만 알림톡을 발송합니다.
`student_payment_info`의 알림 플래그 값은 발송 대상 판정에 사용하지 않습니다.

## Makeup reservation AlimTalk Worker (별도 프로세스)

보강 예약(`session_overrides` INSERT, planned) 시 전용 큐 `makeup_notification_queue`를 처리합니다. 출결 워커와 **코드·PM2 프로세스를 분리**해 운영 영향을 줄입니다.

### Required env (보강 워커 가동 시)

위 출결 워커와 동일하게 `SUPABASE_*`, `BIZPPURIO_*` 필요.

- **`MAKEUP_ALIMTALK_ENABLED=1`** — 없거나 `1`이 아니면 프로세스가 즉시 종료합니다(기본 안전).

### Optional env

- `MAKEUP_ALIMTALK_BATCH_SIZE` (기본: `ALIMTALK_BATCH_SIZE` 또는 20)
- `MAKEUP_ALIMTALK_MAX_ATTEMPTS` (기본: `ALIMTALK_MAX_ATTEMPTS` 또는 5)
- `MAKEUP_WORKER_INTERVAL_MS` (기본: `WORKER_INTERVAL_MS` 또는 60000)
- `MAKEUP_ALIMTALK_ONLY_TODAY_QUEUE=1` (기본) — KST 당일 생성 큐만 처리. `0`으로 전체 pending 처리(백필 시 주의).
- `MAKEUP_ALIMTALK_PROCESS_ONCE=1` 또는 인자 `--once`

### Run

```bash
MAKEUP_ALIMTALK_ENABLED=1 npm run worker:makeup:alimtalk
MAKEUP_ALIMTALK_ENABLED=1 npm run worker:makeup:alimtalk:once
```

학원별로 `academy_alimtalk_settings.makeup_alimtalk_enabled` 및 템플릿 컬럼을 채운 뒤에만 실제 발송됩니다. 자세한 절차는 [docs/makeup_alimtalk_setup.md](../docs/makeup_alimtalk_setup.md) 참고.
