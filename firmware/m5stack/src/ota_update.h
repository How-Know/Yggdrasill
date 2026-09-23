#ifndef OTA_UPDATE_H
#define OTA_UPDATE_H

#include <Arduino.h>

// OTA 업데이트 상태 콜백
typedef void (*OtaProgressCallback)(int percent, const char* status);

// GitHub Releases에서 최신 버전 확인
// 반환: 새 버전이 있으면 true
bool checkForUpdate(String& outLatestVersion, String& outDownloadUrl);

// OTA 업데이트 수행
// downloadUrl: firmware.bin 직접 다운로드 URL
// progressCallback: 진행률 콜백 (0-100%, 상태 메시지)
// 반환: 성공 시 true (자동 재부팅)
bool performOtaUpdate(const String& downloadUrl, OtaProgressCallback progressCallback = nullptr);

// 학습앱이 보낸 예약(action=schedule, http URL)을 저장한다. 지금 당장은 받지 않는다.
bool ota_schedule_from_payload(const uint8_t* payload, size_t len);
bool ota_has_pending_update(void);

// 저장된 예약이 있으면 메인 PC에서 받아 설치하고 재부팅한다.
// 예약이 없거나 실패하면 false. 성공 시 재부팅하므로 반환되지 않는다.
bool ota_apply_pending_update(void);

#endif // OTA_UPDATE_H

