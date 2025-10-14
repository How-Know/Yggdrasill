# MQTT E2E Smoke Test

목표: 브로커→게이트웨이→Supabase RPC→Realtime→앱 반영을 M5 없이 검증

## 준비
- Supabase URL/Anon Key
- MQTT 브로커 접속 정보(TLS 권장)
- gateway/.env 설정(SUPABASE_URL, SUPABASE_ANON_KEY, MQTT_URL, USER/PASS)

## 게이트웨이 실행

cd gateway
pnpm i
pnpm dev

## 퍼블리시(샘플)

cd gateway
node scripts/publish_example.js --academy <academy_id> --student <student_id> --item <item_id> --action submit

연속 전이 예시:
1) start → 2) submit → 3) confirm → 4) wait(확인→대기 진입 시 자동완료 플래그가 있으면 complete 자동 호출)

## 앱 확인
- Flutter Windows 실행 후 수업내용관리/타임라인 다이얼로그에서 실시간 반영 확인

문제 시 체크
- 게이트웨이 로그 rpc error
- 브로커 ACL/토픽 권한
- idempotency_key 중복 여부

