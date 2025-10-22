# M5Stack 펌웨어 설치 가이드

## 준비물
- M5Stack Core2 기기
- USB-C 케이블
- PlatformIO (VS Code 확장 또는 CLI)

## 설정

### 1. WiFi 및 MQTT 설정
`platformio.ini`의 `build_flags` 수정:
```ini
-DWIFI_SSID=\"실제WiFi이름\"
-DWIFI_PASSWORD=\"실제WiFi비밀번호\"
-DMQTT_BROKER=\"mqtt://브로커주소:1883\"
-DACADEMY_ID=\"학원UUID\"
-DDEVICE_ID=\"기기ID\"
```

### 2. 빌드 및 업로드

#### VS Code (PlatformIO 확장)
1. VS Code에서 `firmware/m5stack` 폴더 열기
2. PlatformIO 아이콘 클릭
3. `Build` → `Upload` 클릭
4. 시리얼 모니터로 로그 확인

#### 명령줄
```bash
cd C:\Users\harry\Yggdrasill\firmware\m5stack
pio run -t upload
pio device monitor
```

## 현재 기능 (간단 버전)

### 화면 표시
- MQTT 메시지 수신 시 화면 갱신
- 학생 목록
- 과제 목록

### 버튼
- A: 과제 시작
- B: 과제 제출  
- C: 과제 대기

### MQTT
- 자동 재연결
- LWT (Last Will Testament)
- 15초마다 presence 전송

## 다음 단계 (LVGL UI 통합)

시뮬레이터에서 완성한 UI를 M5Stack에 포팅:
1. LVGL 초기화 (M5.Display 연동)
2. 터치 입력 연동
3. 한글 폰트 SPIFFS 저장
4. 아이콘 파일 통합

자세한 내용은 `README_LVGL.md` 참고

## 문제 해결

### 연결 안 됨
- WiFi SSID/비밀번호 확인
- MQTT 브로커 주소 확인
- 시리얼 모니터로 오류 확인

### 업로드 실패
- USB 포트 확인
- 드라이버 설치 (CH340, CP210x)
- 다른 프로그램이 포트 사용 중인지 확인
