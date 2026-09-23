#include "ota_update.h"
#include "version.h"
#include "ui_port.h"
#include <HTTPClient.h>
#include <Update.h>
#include <ArduinoJson.h>
#include <WiFi.h>
#include <Preferences.h>
#include <cstring>

bool checkForUpdate(String& outLatestVersion, String& outDownloadUrl) {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[OTA] WiFi not connected");
    return false;
  }

  HTTPClient http;
  String apiUrl = String("https://api.github.com/repos/") + GITHUB_OWNER + "/" + GITHUB_REPO + "/releases/latest";
  
  Serial.printf("[OTA] Checking: %s\n", apiUrl.c_str());
  http.begin(apiUrl);
  http.setUserAgent("M5Stack-OTA");
  http.addHeader("Accept", "application/vnd.github.v3+json");
  
  int httpCode = http.GET();
  if (httpCode != 200) {
    Serial.printf("[OTA] HTTP error: %d\n", httpCode);
    http.end();
    return false;
  }

  String payload = http.getString();
  http.end();

  DynamicJsonDocument doc(8192);
  DeserializationError error = deserializeJson(doc, payload);
  if (error) {
    Serial.printf("[OTA] JSON parse error: %s\n", error.c_str());
    return false;
  }

  String tagName = doc["tag_name"].as<String>();
  outLatestVersion = tagName;
  
  // 현재 버전과 비교 (v 제거 후 비교)
  String currentVer = String(FIRMWARE_VERSION);
  String latestVer = tagName;
  if (latestVer.startsWith("v")) latestVer = latestVer.substring(1);
  if (currentVer.startsWith("v")) currentVer = currentVer.substring(1);
  
  Serial.printf("[OTA] Current: %s, Latest: %s\n", currentVer.c_str(), latestVer.c_str());
  
  if (latestVer == currentVer) {
    Serial.println("[OTA] Already up to date");
    return false;
  }

  // assets에서 m5stack_firmware.bin 찾기
  JsonArray assets = doc["assets"];
  for (JsonObject asset : assets) {
    String name = asset["name"].as<String>();
    if (name.indexOf("m5stack") >= 0 && name.endsWith(".bin")) {
      outDownloadUrl = asset["browser_download_url"].as<String>();
      Serial.printf("[OTA] Found update: %s → %s\n", name.c_str(), outDownloadUrl.c_str());
      return true;
    }
  }

  Serial.println("[OTA] No m5stack firmware found in release");
  return false;
}

bool performOtaUpdate(const String& downloadUrl, OtaProgressCallback progressCallback) {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[OTA] WiFi not connected");
    if (progressCallback) progressCallback(0, "WiFi disconnected");
    return false;
  }

  HTTPClient http;
  http.begin(downloadUrl);
  http.setUserAgent("M5Stack-OTA");
  http.setFollowRedirects(HTTPC_STRICT_FOLLOW_REDIRECTS);
  
  Serial.printf("[OTA] Downloading: %s\n", downloadUrl.c_str());
  if (progressCallback) progressCallback(0, "Connecting...");
  
  int httpCode = http.GET();
  Serial.printf("[OTA] Initial response: %d\n", httpCode);
  
  // 수동 리다이렉트 처리 (최대 5번)
  int redirectCount = 0;
  while ((httpCode == 301 || httpCode == 302 || httpCode == 303 || httpCode == 307 || httpCode == 308) && redirectCount < 5) {
    String newUrl = http.getLocation();
    Serial.printf("[OTA] Redirect(%d) Location header: %s\n", httpCode, newUrl.c_str());
    
    if (newUrl.length() == 0) {
      Serial.println("[OTA] Empty redirect location");
      break;
    }
    
    http.end();
    delay(100);
    
    Serial.printf("[OTA] Following redirect to: %s\n", newUrl.c_str());
    http.begin(newUrl);
    http.setUserAgent("M5Stack-OTA");
    http.setFollowRedirects(HTTPC_STRICT_FOLLOW_REDIRECTS);
    httpCode = http.GET();
    Serial.printf("[OTA] Redirected response: %d\n", httpCode);
    redirectCount++;
  }
  
  if (httpCode != 200) {
    Serial.printf("[OTA] Download error: %d\n", httpCode);
    if (progressCallback) progressCallback(0, "Download failed");
    http.end();
    return false;
  }

  int contentLength = http.getSize();
  if (contentLength <= 0) {
    Serial.println("[OTA] Invalid content length");
    if (progressCallback) progressCallback(0, "Invalid file size");
    http.end();
    return false;
  }

  Serial.printf("[OTA] Content-Length: %d bytes\n", contentLength);
  
  if (!Update.begin(contentLength)) {
    Serial.printf("[OTA] Not enough space: %d\n", contentLength);
    if (progressCallback) progressCallback(0, "Not enough space");
    http.end();
    return false;
  }

  WiFiClient* stream = http.getStreamPtr();
  uint8_t buff[512];
  int written = 0;
  int lastPercent = -1;

  if (progressCallback) progressCallback(0, "Downloading...");

  while (http.connected() && (written < contentLength)) {
    size_t available = stream->available();
    if (available) {
      int c = stream->readBytes(buff, min(available, sizeof(buff)));
      if (c > 0) {
        Update.write(buff, c);
        written += c;

        int percent = (written * 100) / contentLength;
        uint32_t nowMs = millis();
        static uint32_t lastTickMs = 0;
        static uint32_t lastPumpMs = 0;
        if (lastTickMs == 0) lastTickMs = nowMs;
        lv_tick_inc(nowMs - lastTickMs);
        lastTickMs = nowMs;
        if (percent != lastPercent || nowMs - lastPumpMs >= 80) {
          if (progressCallback && percent != lastPercent) {
            progressCallback(percent, "Downloading...");
          } else {
            lv_timer_handler();
          }
          lastPercent = percent;
          lastPumpMs = nowMs;
        }
      }
    }
    delay(1);
  }

  http.end();

  if (written != contentLength) {
    Serial.printf("[OTA] Write mismatch: %d != %d\n", written, contentLength);
    if (progressCallback) progressCallback(0, "Download incomplete");
    Update.abort();
    return false;
  }

  if (progressCallback) progressCallback(100, "Verifying...");
  
  if (!Update.end()) {
    Serial.printf("[OTA] Update.end() failed: %s\n", Update.errorString());
    if (progressCallback) progressCallback(0, "Verification failed");
    return false;
  }

  if (!Update.isFinished()) {
    Serial.println("[OTA] Update not finished");
    if (progressCallback) progressCallback(0, "Update failed");
    return false;
  }

  Serial.println("[OTA] Update successful! Rebooting...");
  if (progressCallback) progressCallback(100, "Success! Rebooting...");
  
  delay(1000);
  fw_prepare_update_restart();
  ESP.restart();
  return true;
}

static void ota_clear_pending(void) {
  Preferences prefs;
  prefs.begin("m5cfg", false);
  prefs.remove("ota_pending");
  prefs.remove("ota_url");
  prefs.remove("ota_ver");
  prefs.end();
}

bool ota_schedule_from_payload(const uint8_t* payload, size_t len) {
  if (payload == nullptr || len == 0 || len > 480) return false;
  char buf[481];
  memcpy(buf, payload, len);
  buf[len] = 0;

  DynamicJsonDocument doc(512);
  if (deserializeJson(doc, buf)) return false;
  const char* action = doc["action"] | "";
  if (strcmp(action, "schedule") != 0) return false;
  const char* url = doc["url"] | "";
  const char* version = doc["version"] | "";
  if (strncmp(url, "http://", 7) != 0) return false;

  Preferences prefs;
  prefs.begin("m5cfg", false);
  prefs.putString("ota_url", url);
  prefs.putString("ota_ver", version);
  prefs.putBool("ota_pending", true);
  prefs.end();
  ui_port_notify_ota_scheduled();
  Serial.printf("[OTA] scheduled version=%s url=%s\n", version, url);
  return true;
}

bool ota_has_pending_update(void) {
  Preferences prefs;
  prefs.begin("m5cfg", true);
  const bool pending = prefs.getBool("ota_pending", false);
  String url = prefs.getString("ota_url", "");
  prefs.end();
  return pending && url.length() > 0;
}

bool ota_apply_pending_update(void) {
  Preferences prefs;
  prefs.begin("m5cfg", true);
  const bool pending = prefs.getBool("ota_pending", false);
  String url = prefs.getString("ota_url", "");
  String version = prefs.getString("ota_ver", "");
  prefs.end();
  if (!pending || url.length() == 0) return false;

  // 실패한 주소로 부팅마다 반복하지 않는다. 다시 받으려면 학습앱에서 다시 예약한다.
  ota_clear_pending();

  Serial.printf("[OTA] applying on boot version=%s url=%s current=%s\n",
                version.c_str(), url.c_str(), FIRMWARE_VERSION);
  ui_port_update_boot_status(u8"업데이트 중입니다", 8);
  lv_timer_handler();

  const bool ok = performOtaUpdate(url, [](int percent, const char* status) {
    (void)status;
    int shown = percent;
    if (shown < 8) shown = 8;
    if (shown > 100) shown = 100;
    ui_port_update_boot_status(u8"업데이트 중입니다", shown);
    lv_timer_handler();
  });
  if (!ok) {
    Serial.println("[OTA] boot apply failed; continue normal boot");
    ui_port_update_boot_status(u8"펌웨어 업데이트 실패", 40);
    lv_timer_handler();
  }
  return ok;
}

