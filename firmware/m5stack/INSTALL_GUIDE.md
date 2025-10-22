# M5Stack 펌웨어 설치 가이드

## 방법 1: VS Code + PlatformIO (권장)

### 설치
1. VS Code 실행
2. 확장 → "PlatformIO IDE" 검색 및 설치
3. VS Code 재시작

### 빌드 및 업로드
1. VS Code에서 `File → Open Folder` → `C:\Users\harry\Yggdrasill\firmware\m5stack`
2. `platformio.ini` 열기
3. WiFi/MQTT 설정 수정:
   ```ini
   -DWIFI_SSID=\"실제SSID\"
   -DWIFI_PASSWORD=\"실제비밀번호\"
   ```
4. 하단 상태바 → `Upload` 버튼 클릭 (→ 아이콘)
5. 업로드 완료 대기
6. `Serial Monitor` 버튼 클릭 (🔌 아이콘)

## 방법 2: Arduino IDE

### 준비
1. Arduino IDE 2.x 설치
2. `파일 → 환경설정 → 추가 보드 관리자 URLs`에 추가:
   ```
   https://m5stack.oss-cn-shenzhen.aliyuncs.com/resource/arduino/package_m5stack_index.json
   ```
3. `도구 → 보드 → 보드 관리자` → "M5Stack" 검색 및 설치
4. `도구 → 라이브러리 관리` → 설치:
   - M5Unified
   - AsyncMqttClient
   - ArduinoJson
   - lvgl (선택사항)

### 업로드
1. `src/main.cpp` 파일을 Arduino IDE로 열기
2. 상단에 WiFi/MQTT 정보 수정:
   ```cpp
   static const char* WIFI_SSID = "실제SSID";
   static const char* WIFI_PASS = "실제비밀번호";
   static const char* MQTT_HOST = "broker.example.com";
   ```
3. `도구 → 보드` → "M5Stack Core2" 선택
4. `도구 → 포트` → COM 포트 선택
5. `업로드` 버튼 (→) 클릭

## 시리얼 모니터

### 확인 사항
- "MQTT connecting..."
- "MQTT connected & subscribed"
- WiFi 연결 상태
- 수신 메시지

### 디버그
문제 발생 시 시리얼 모니터에서:
```
WiFi status: [상태코드]
MQTT error: [오류]
```

## WiFi 설정

현재 펌웨어는 **하드코딩** 방식입니다.
WiFi 변경 시:
1. `platformio.ini` 수정
2. 재빌드 및 업로드

## 다음 작업

### 시뮬레이터 UI → M5Stack 포팅
현재는 간단한 텍스트 기반 UI만 있습니다.
시뮬레이터에서 완성한 LVGL UI를 포팅하려면:

1. `lv_conf.h` 생성
2. M5.Display → LVGL 연동
3. M5.Touch → LVGL 입력 연동
4. 아이콘/폰트 파일 SPIFFS 저장
5. UI 코드 포팅 (C → C++)

자세한 가이드: `README_LVGL.md`

## 빠른 테스트

WiFi/MQTT 정보만 수정하면 바로 업로드하여:
- MQTT 연결
- 학생 목록 수신
- 과제 목록 수신
- 버튼으로 과제 상태 변경

테스트할 수 있습니다!






