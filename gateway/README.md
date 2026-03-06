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
