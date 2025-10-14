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
