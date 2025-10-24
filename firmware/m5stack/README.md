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

## 배포 절차

### 1. 버전 업데이트
`src/version.h`에서 `FIRMWARE_VERSION` 수정:
```c
#define FIRMWARE_VERSION "1.0.5.1"  // 새 버전으로 변경
```

### 2. 빌드 및 로컬 테스트
```bash
cd firmware/m5stack
pio run --target upload  # COM3로 직접 업로드
```

### 3. 릴리스 자산 준비
```bash
# 빌드된 bin을 dist 폴더로 복사
Copy-Item .pio\build\m5stack-core2\firmware.bin ..\..\apps\yggdrasill\dist\m5stack-core2_firmware.bin -Force
```

### 4. GitHub Release 업로드
```bash
cd ../../apps/yggdrasill
gh release upload v1.0.5.1 dist\m5stack-core2_firmware.bin --clobber -R How-Know/Yggdrasill
```

### 5. OTA 업데이트 테스트
- M5 장치에서 설정 → 업데이트 버튼 클릭
- 다운로드 진행 확인 (0% → 100%)
- 재부팅 후 버전 확인 (설정 화면)

### 주의사항
- `platformio.ini`의 `GITHUB_OWNER`와 `GITHUB_REPO`가 올바른지 확인
- 릴리스 자산 파일명은 반드시 `m5stack-core2_firmware.bin` 유지
- OTA 업데이트 전 시리얼 모니터 닫기 (포트 충돌 방지)

## 문제 해결

### 연결 안 됨
- WiFi SSID/비밀번호 확인
- MQTT 브로커 주소 확인
- 시리얼 모니터로 오류 확인

### 업로드 실패
- USB 포트 확인
- 드라이버 설치 (CH340, CP210x)
- 다른 프로그램이 포트 사용 중인지 확인

### OTA 업데이트 실패
- GitHub Release에 bin 파일이 올바르게 업로드되었는지 확인
- M5 장치의 WiFi 연결 상태 확인
- 시리얼 모니터에서 `[OTA]` 로그 확인
