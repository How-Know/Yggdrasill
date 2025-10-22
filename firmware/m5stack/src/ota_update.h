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

#endif // OTA_UPDATE_H

