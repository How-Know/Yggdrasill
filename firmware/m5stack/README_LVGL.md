# M5Stack LVGL UI 포팅 가이드

## 완성된 기능

### 1. 하단 슬라이드 시트
- **위치**: 화면 하단 (Y=216)
- **핸들**: iPhone 스타일 (항상 표시)
- **버튼 3개**:
  - 볼륨 조절 (volume_mute 아이콘)
  - 홈 이동 (home 아이콘)
  - 설정 (settings 아이콘)

### 2. 설정 페이지
- **구조**: stage 자식 (HIDDEN 플래그로 전환)
- **내용**:
  - 제목: "설정"
  - 버전 표시
  - WiFi 버튼 (원형, 51x51)
  - 업데이트 버튼 (원형, 51x51)
  - 닫기 버튼

### 3. WiFi 설정 (TODO)
- 현재 시뮬레이터에서 불안정
- **권장**: 하드코딩 또는 Preferences 사용
- M5Stack에서는 `M5.WiFi.begin(ssid, password)` 직접 호출

### 4. 업데이트 확인
- 새로고침 버튼 클릭 → MQTT 업데이트 요청
- TODO: MQTT command 전송 구현

## M5Stack 포팅 체크리스트

### 필수 파일
```
firmware/m5stack/src/
  ├── main.cpp
  ├── ui/
  │   ├── main_ui.cpp        (시뮬레이터 main.c 참고)
  │   ├── settings_ui.cpp    (settings_ui.c 포팅)
  │   ├── wifi_ui.cpp        (간소화 또는 제거)
  │   └── screensaver.cpp    (screensaver.c 포팅)
  ├── icons/
  │   ├── icon_home.c
  │   ├── icon_volume.c
  │   ├── icon_settings.c
  │   ├── icon_wifi.c
  │   └── icon_refresh.c
  └── mqtt/
      └── mqtt_client.cpp
```

### 폰트 설정
- KakaoSmallSans TTF → SPIFFS에 저장
- `lv_tiny_ttf` 사용 (동일)

### WiFi 설정 (간단 방식)
```cpp
// platformio.ini 또는 코드 상단에 하드코딩
#define WIFI_SSID "YourSSID"
#define WIFI_PASSWORD "YourPassword"

void setup() {
  M5.begin();
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  while (WiFi.status() != WL_CONNECTED) {
    delay(100);
  }
}
```

### MQTT 브로커 연결
- 시뮬레이터와 동일한 구조
- `PubSubClient` 또는 `esp_mqtt_client` 사용

### 주요 차이점

| 항목 | 시뮬레이터 | M5Stack |
|------|-----------|---------|
| 디스플레이 | SDL | M5.Lcd |
| 입력 | SDL Mouse | M5.Touch |
| 폰트 로딩 | stdio FS | SPIFFS |
| MQTT | libmosquitto | PubSubClient |
| 루프 | while(1) SDL | loop() Arduino |

## 다음 단계

1. ✅ 시뮬레이터 UI 완성
2. ⏳ M5Stack 펌웨어 프로젝트 생성
3. ⏳ UI 코드 포팅 (C → C++)
4. ⏳ 하드웨어 연동 (터치, LCD, WiFi)
5. ⏳ MQTT 통합 테스트

## 참고
- 시뮬레이터: `simulator/lvgl/build/Release/m5_lvgl_sim.exe`
- 환경변수: BROKER_URL, ACADEMY_ID, DEVICE_ID





