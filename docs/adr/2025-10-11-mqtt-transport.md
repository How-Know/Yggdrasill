# ADR: MQTT 기반 M5Stack↔앱 연동 선택

상태: accepted

문맥:
- M5Stack(ESP32) 디바이스와 태블릿/웹 앱 간 실시간 상호작용 필요
- 저전력·간헐 연결·확장성·모바일 확장 고려

결정:
- 전송계층으로 MQTT를 채택
- 브로커(EMQX/HiveMQ/Mosquitto) + 게이트웨이(bridge) 서비스 + Supabase RPC 연계
- 주제/ACL/스키마/상태머신을 마이그레이션으로 관리

근거:
- QoS/Retain/Clean Session/양방향 Pub/Sub/저전력에 강함
- 주제·권한 분리로 사업장(academy) 단위 격리 용이

결과:
- infra/messaging/{migrations,schemas,specs} 버전드 관리
- tools/mqctl.ps1로 validate/plan/apply/rollback 작업
- gateway 서비스는 현재 spec/schemas를 읽어 라우팅 수행

관련 항목:
- 0001_init_mqtt.yml
- homework_command.v1.json
- homework_phase.v1.yml



