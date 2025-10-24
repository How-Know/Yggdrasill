#include "ota_update.h"
#include "version.h"
#include <HTTPClient.h>
#include <Update.h>
#include <ArduinoJson.h>
#include <WiFi.h>

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
        if (percent != lastPercent && percent % 5 == 0) {
          Serial.printf("[OTA] Progress: %d%%\n", percent);
          if (progressCallback) progressCallback(percent, "Downloading...");
          lastPercent = percent;
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
  ESP.restart();
  return true;
}

