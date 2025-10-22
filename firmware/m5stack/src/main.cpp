#include <M5Unified.h>
#include <WiFi.h>
#include <AsyncMqttClient.h>
#include <ArduinoJson.h>
#include "esp_wifi.h"
#include <lvgl.h>
#include <LittleFS.h>
#include "ui_port.h"
#include "screensaver.h"
#if LV_USE_TINY_TTF
#include "extra/libs/tiny_ttf/lv_tiny_ttf.h"
#endif

// Build flags로 주입되는 설정(없으면 기본값)
#ifndef CFG_WIFI_SSID
#define CFG_WIFI_SSID "CHANGE_ME_WIFI"
#endif
#ifndef CFG_WIFI_PASSWORD
#define CFG_WIFI_PASSWORD "CHANGE_ME_PASS"
#endif
#ifndef CFG_MQTT_HOST
#define CFG_MQTT_HOST "localhost"
#endif
#ifndef CFG_MQTT_PORT
#define CFG_MQTT_PORT 1883
#endif
#ifndef CFG_ACADEMY_ID
#define CFG_ACADEMY_ID "test-academy"
#endif
#ifndef CFG_DEVICE_ID
#define CFG_DEVICE_ID "m5-001"
#endif

static const char* WIFI_SSID = CFG_WIFI_SSID;
static const char* WIFI_PASS = CFG_WIFI_PASSWORD;
static const char* MQTT_HOST = CFG_MQTT_HOST;
static const uint16_t MQTT_PORT = CFG_MQTT_PORT;
static String academyId = CFG_ACADEMY_ID;
static String studentId = "student-id"; // 서버 바인딩 후 업데이트 예정
static String deviceId = CFG_DEVICE_ID;

AsyncMqttClient mqtt;
String ackFilterPrefix;
String todayListTopic;
String homeworksTopic;
String updateTopic;
String studentInfoTopic;
static uint32_t nextMqttReconnectMs = 0;
static const char* kMqttHosts[] = { CFG_MQTT_HOST, "test.mosquitto.org", "broker.hivemq.com" };
static int mqttHostIndex = 0;
static char willPayloadBuf[128];
static char willTopicBuf[128];

// LVGL objects
static lv_disp_draw_buf_t g_lv_draw_buf;
static lv_color_t* g_lv_buf1 = nullptr;
static lv_color_t* g_lv_buf2 = nullptr;
static lv_disp_drv_t g_lv_disp_drv;
static lv_indev_drv_t g_lv_indev_drv;
static lv_indev_t* g_lv_indev = nullptr;
static void lvgl_touch_read_cb(lv_indev_drv_t* drv, lv_indev_data_t* data) {
  (void)drv;
  auto d = M5.Touch.getDetail();
  if (d.isPressed()) {
    data->state = LV_INDEV_STATE_PRESSED;
    data->point.x = d.x;
    data->point.y = d.y;
  } else {
    data->state = LV_INDEV_STATE_RELEASED;
  }
  data->continue_reading = 0;
}
static lv_obj_t* g_lblTitle = nullptr;
static lv_obj_t* g_lblUpdate = nullptr;
static lv_obj_t* g_lblStudents = nullptr;

static void lvgl_flush_cb(lv_disp_drv_t* disp, const lv_area_t* area, lv_color_t* color_p) {
  int32_t w = area->x2 - area->x1 + 1;
  int32_t h = area->y2 - area->y1 + 1;
  // Push 16-bit RGB565
  M5.Display.startWrite();
  M5.Display.setAddrWindow(area->x1, area->y1, w, h);
  M5.Display.pushPixels((uint16_t*)&color_p->full, w * h);
  M5.Display.endWrite();
  lv_disp_flush_ready(disp);
}

static void initLvgl() {
  lv_init();
  // Ensure color order matches LVGL buffer (RGB565)
  M5.Display.setColorDepth(16);
  M5.Display.setSwapBytes(true);
  // Allocate 2 draw buffers (320x40 lines)
  const int hor = 320;
  const int ver_lines = 40;
  g_lv_buf1 = (lv_color_t*)heap_caps_malloc(sizeof(lv_color_t) * hor * ver_lines, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  g_lv_buf2 = (lv_color_t*)heap_caps_malloc(sizeof(lv_color_t) * hor * ver_lines, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  lv_disp_draw_buf_init(&g_lv_draw_buf, g_lv_buf1, g_lv_buf2, hor * ver_lines);

  lv_disp_drv_init(&g_lv_disp_drv);
  g_lv_disp_drv.hor_res = 320;
  g_lv_disp_drv.ver_res = 240;
  g_lv_disp_drv.flush_cb = lvgl_flush_cb;
  g_lv_disp_drv.draw_buf = &g_lv_draw_buf;
  lv_disp_drv_register(&g_lv_disp_drv);

  // Root screen style: solid black, no radius
  lv_obj_t* scr = lv_scr_act();
  lv_obj_set_style_bg_color(scr, lv_color_hex(0x000000), 0);
  lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);
  lv_obj_set_style_radius(scr, 0, 0);

  // 내장 카카오 비트맵 폰트 22px 선언 및 전역 적용
  extern const lv_font_t kakao_kr_22; // src/fonts/kakao_kr_22.c
  ui_port_set_global_font(&kakao_kr_22);

  // Touch input device
  lv_indev_drv_init(&g_lv_indev_drv);
  g_lv_indev_drv.type = LV_INDEV_TYPE_POINTER;
  g_lv_indev_drv.read_cb = lvgl_touch_read_cb;
  g_lv_indev = lv_indev_drv_register(&g_lv_indev_drv);

  // KakaoSmallSans TTF를 LittleFS에서 로드하여 글로벌 폰트로 설정
  // 성능 유지 위해 런타임 TTF는 사용하지 않음
  // Build app UI skeleton
  ui_port_init();
  
  Serial.println("LVGL UI initialized");
}

static void configureMqttServer() {
  const char* host = kMqttHosts[mqttHostIndex % (sizeof(kMqttHosts)/sizeof(kMqttHosts[0]))];
  mqtt.setServer(host, MQTT_PORT);
  Serial.print("MQTT host: "); Serial.println(host);
}

void onMqttConnect(bool sessionPresent) {
  (void)sessionPresent;
  ackFilterPrefix = String("academies/") + academyId + "/ack/";
  String ackTopic = ackFilterPrefix + "+";
  mqtt.subscribe(ackTopic.c_str(), 1);
  todayListTopic = String("academies/") + academyId + "/devices/" + deviceId + "/students_today";
  mqtt.subscribe(todayListTopic.c_str(), 1);
  homeworksTopic = String("academies/") + academyId + "/devices/" + deviceId + "/homeworks";
  mqtt.subscribe(homeworksTopic.c_str(), 1);
  studentInfoTopic = String("academies/") + academyId + "/devices/" + deviceId + "/student_info";
  mqtt.subscribe(studentInfoTopic.c_str(), 1);
  updateTopic = String("academies/") + academyId + "/devices/" + deviceId + "/update";
  mqtt.subscribe(updateTopic.c_str(), 1);
  Serial.println("MQTT connected & subscribed");

  // Presence (retain)
  {
    DynamicJsonDocument pres(128);
    pres["online"] = true;
    pres["at"] = "";
    String p; serializeJson(pres, p);
    String presTopic = String("academies/") + academyId + "/devices/" + deviceId + "/presence";
    mqtt.publish(presTopic.c_str(), 1, true, p.c_str());
  }
  // Request initial data: list_today
  {
    DynamicJsonDocument cmd(64);
    cmd["action"] = "list_today";
    String payload; serializeJson(cmd, payload);
    String cmdTopic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
    mqtt.publish(cmdTopic.c_str(), 1, false, payload.c_str());
    Serial.println("Requested list_today");
  }
  // Optionally also check for updates once
  {
    DynamicJsonDocument doc(64);
    doc["action"] = "check_update";
    String payload; serializeJson(doc, payload);
    String cmdTopic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
    mqtt.publish(cmdTopic.c_str(), 1, false, payload.c_str());
  }
}

void onMqttDisconnect(AsyncMqttClientDisconnectReason reason) {
  M5.Display.setCursor(0, 40);
  M5.Display.printf("MQTT disconnect: %d\n", (int)reason);
  Serial.print("MQTT disconnect reason: "); Serial.println((int)reason);
  // 3초 후 재시도
  nextMqttReconnectMs = millis() + 3000;
  // 다음 호스트로 라운드로빈
  mqttHostIndex = (mqttHostIndex + 1) % (sizeof(kMqttHosts)/sizeof(kMqttHosts[0]));
  configureMqttServer();
}

void onMqttMessage(char* topic, char* payload, AsyncMqttClientMessageProperties properties, size_t len, size_t index, size_t total) {
  (void)properties; (void)index; (void)total;
  String t = String(topic);
  Serial.print("MSG "); Serial.print(t); Serial.print(" len="); Serial.println((int)len);
  if (t.startsWith(ackFilterPrefix)) {
    String body; body.reserve(len + 1);
    for (size_t i = 0; i < len; ++i) body += (char)payload[i];
    Serial.print("ACK: "); Serial.println(body);
  }
  if (t == todayListTopic) {
    static String acc; static size_t expected = 0; static size_t received = 0;
    if (index == 0) { acc.remove(0); acc.reserve(total ? total : (len + 512)); expected = total ? total : len; received = 0; }
    acc.concat(String(payload).substring(0, (int)len));
    received += len;
    Serial.printf("students_today chunk: idx=%u len=%u total=%u recv=%u\n", (unsigned)index, (unsigned)len, (unsigned)total, (unsigned)received);
    if (total && received < total) { return; }
    // parse when complete
    DynamicJsonDocument doc(expected + 2048);
    DeserializationError err = deserializeJson(doc, acc.c_str(), acc.length());
    if (err) { Serial.print("students_today parse error: "); Serial.println(err.c_str()); return; }
    JsonArray arr;
    if (doc.containsKey("students") && doc["students"].is<JsonArray>()) {
      arr = doc["students"].as<JsonArray>();
    } else if (doc.is<JsonArray>()) {
      arr = doc.as<JsonArray>();
    } else if (doc.containsKey("items") && doc["items"].is<JsonArray>()) {
      arr = doc["items"].as<JsonArray>();
    } else if (doc.containsKey("data") && doc["data"].is<JsonArray>()) {
      arr = doc["data"].as<JsonArray>();
    }
    Serial.print("students_today count="); Serial.println((int)arr.size());
    ui_port_update_students(arr);
  }
  if (t == homeworksTopic) {
    DynamicJsonDocument doc(4096);
    DeserializationError err = deserializeJson(doc, payload, len);
    if (!err) {
      JsonArray arr = doc["items"].as<JsonArray>();
      ui_port_update_homeworks(arr);
    }
  }
  if (t == updateTopic) {
    String body; body.reserve(len + 1);
    for (size_t i = 0; i < len; ++i) body += (char)payload[i];
    // settings 화면에서 표시할 수 있도록 유지 (필요 시 별도 라벨 연결)
    Serial.print("UPDATE resp: "); Serial.println(body);
  }
  if (t == studentInfoTopic) {
    DynamicJsonDocument doc(1024);
    DeserializationError err = deserializeJson(doc, payload, len);
    if (!err && doc.containsKey("info")) {
      JsonObject info = doc["info"].as<JsonObject>();
      ui_port_update_student_info(info);
    }
  }
}

void sendCommand(const char* action, const char* itemId) {
  DynamicJsonDocument doc(256);
  doc["action"] = action;
  doc["academy_id"] = academyId;
  doc["student_id"] = studentId;
  doc["item_id"] = itemId;
  doc["idempotency_key"] = String((uint32_t)esp_random(), HEX);
  doc["at"] = ""; // optional
  String payload; serializeJson(doc, payload);
  String topic = String("academies/") + academyId + "/students/" + studentId + "/homework/" + itemId + "/command";
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
}

// ===== UI publish bridge implementations =====
void fw_publish_bind(const char* studentIdArg) {
  if (!studentIdArg || !*studentIdArg) return;
  studentId = studentIdArg; // track bound student on device
  DynamicJsonDocument doc(128);
  doc["action"] = "bind";
  doc["student_id"] = studentIdArg;
  String payload; serializeJson(doc, payload);
  String topic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
}

void fw_publish_unbind() {
  DynamicJsonDocument doc(128);
  doc["action"] = "unbind";
  doc["student_id"] = studentId;
  String payload; serializeJson(doc, payload);
  String topic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
  studentId = ""; // clear tracked student
}

void fw_publish_student_info(const char* studentIdArg) {
  if (!studentIdArg || !*studentIdArg) return;
  DynamicJsonDocument doc(128);
  doc["action"] = "student_info";
  doc["student_id"] = studentIdArg;
  String payload; serializeJson(doc, payload);
  String topic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
}

void fw_publish_homework_action(const char* action, const char* itemId) {
  if (!action || !*action || !itemId || !*itemId) return;
  DynamicJsonDocument doc(256);
  doc["action"] = action;
  doc["academy_id"] = academyId;
  doc["student_id"] = studentId;
  doc["item_id"] = itemId;
  doc["idempotency_key"] = String((uint32_t)esp_random(), HEX);
  doc["at"] = "";
  doc["updated_by"] = studentId;
  String payload; serializeJson(doc, payload);
  String topic = String("academies/") + academyId + "/students/" + studentId + "/homework/" + itemId + "/command";
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
}

void fw_publish_pause_all() {
  if (!studentId.length()) return;
  DynamicJsonDocument doc(192);
  doc["action"] = "pause_all";
  doc["academy_id"] = academyId;
  doc["student_id"] = studentId;
  doc["item_id"] = "ALL";
  doc["idempotency_key"] = String((uint32_t)esp_random(), HEX);
  doc["at"] = "";
  String payload; serializeJson(doc, payload);
  String topic = String("academies/") + academyId + "/students/" + studentId + "/homework/ALL/command";
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
}

void fw_publish_check_update() {
  DynamicJsonDocument doc(64);
  doc["action"] = "check_update";
  String payload; serializeJson(doc, payload);
  String topic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
}

void setup() {
  auto cfg = M5.config(); M5.begin(cfg);
  M5.Display.setTextSize(2);
  // 디스플레이 폰트는 LVGL이 담당하므로 기본 폰트 유지
  Serial.begin(115200);
  // Initialize LVGL UI (aligned text rendering)
  initLvgl();
  // 영문 기본 폰트 사용 (한글 비표시 깨짐 방지). 한글 폰트는 추후 내장 폰트로 교체 예정
  M5.Display.setFont(&fonts::Font0);
  // 2.4GHz만 사용, 채널 자동
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
  // 채널 12/13 사용을 위해 국가 코드 설정 (KR)
  wifi_country_t kr = {"KR", 1, 13, WIFI_COUNTRY_POLICY_AUTO};
  esp_wifi_set_country(&kr);
  // SSID가 한글인 경우도 안전하게 스캔 후 채널로 접속 시도
  int targetChannel = 0;
  const char* configuredSsid = WIFI_SSID;
  const char* fallbackUtf8Ssid = u8"정현"; // UTF-8 리터럴(플래그 인코딩 이슈 대비)
  const char* ssidToUse = configuredSsid;
  bool foundMatch = false;
  uint8_t targetBssid[6] = {0};
  {
    Serial.println("WiFi scanning...");
    int n = WiFi.scanNetworks();
    for (int i = 0; i < n; ++i) {
      String s = WiFi.SSID(i);
      int ch = WiFi.channel(i);
      if (i < 6) { Serial.printf("%d) %s (ch%d)\n", i + 1, s.c_str(), ch); }
      if (s == String(configuredSsid)) { targetChannel = ch; ssidToUse = configuredSsid; foundMatch = true; memcpy(targetBssid, WiFi.BSSID(i), 6); }
      else if (s == String(fallbackUtf8Ssid)) { targetChannel = ch; ssidToUse = fallbackUtf8Ssid; foundMatch = true; memcpy(targetBssid, WiFi.BSSID(i), 6); }
    }
    WiFi.scanDelete();
  }
  if (targetChannel > 0) {
    if (foundMatch) {
      WiFi.begin(ssidToUse, WIFI_PASS, targetChannel, targetBssid);
    } else {
      WiFi.begin(ssidToUse, WIFI_PASS, targetChannel);
    }
  } else {
    WiFi.begin(ssidToUse, WIFI_PASS);
  }

  uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 8000) { delay(200); }

  // Fallback: SSID 인코딩 문제로 실패 시, 스캔 결과를 이용해 순차 접속 시도
  if (WiFi.status() != WL_CONNECTED) {
    M5.Display.println("Fallback connect trials...");
    int n2 = WiFi.scanNetworks();
    for (int i = 0; i < n2; ++i) {
      String ss = WiFi.SSID(i);
      int ch = WiFi.channel(i);
      const uint8_t* bssid = WiFi.BSSID(i);
      M5.Display.printf("Try %d: %s (ch%d)\n", i + 1, ss.c_str(), ch);
      WiFi.begin(ss.c_str(), WIFI_PASS, ch, bssid);
      uint32_t t0 = millis();
      while (WiFi.status() != WL_CONNECTED && millis() - t0 < 6000) { delay(200); }
      if (WiFi.status() == WL_CONNECTED) break;
    }
    WiFi.scanDelete();
  }
  configureMqttServer();
  mqtt.setKeepAlive(30);
  mqtt.setCleanSession(true);
  mqtt.onConnect(onMqttConnect);
  mqtt.onDisconnect(onMqttDisconnect);
  mqtt.onMessage(onMqttMessage);
  // 고유 clientId는 최초 연결 전에 설정해야 함(브로커 즉시 종료 방지)
  {
    char cid[40];
    uint64_t mac = ESP.getEfuseMac();
    snprintf(cid, sizeof(cid), "m5-%llx", (unsigned long long)mac);
    mqtt.setClientId(cid);
    Serial.print("ClientId: "); Serial.println(cid);
  }
  // LWT: offline retained (버퍼에 영속 저장하여 수명 문제 방지)
  snprintf(willPayloadBuf, sizeof(willPayloadBuf), "{\"online\":false,\"at\":\"\"}");
  snprintf(willTopicBuf, sizeof(willTopicBuf), "academies/%s/devices/%s/presence", academyId.c_str(), deviceId.c_str());
  mqtt.setWill(willTopicBuf, 1, true, willPayloadBuf, strlen(willPayloadBuf));
  mqtt.connect();
  Serial.print("WiFi connected, IP: "); Serial.println(WiFi.localIP());
  Serial.println("MQTT connecting...");
  
  // Initialize screensaver after MQTT setup (60 seconds timeout)
  screensaver_init(60000);
  screensaver_attach_activity(lv_scr_act());
}

void loop() {
  M5.update();
  // LVGL ticking
  static uint32_t lastTick = 0;
  uint32_t nowTick = millis();
  lv_tick_inc(nowTick - lastTick);
  lastTick = nowTick;
  lv_timer_handler();
  screensaver_poll();
  screensaver_check_shake();
  
  // Safe vibration handling (3 second interval) using PMIC vibration (LDO3/DLDO1)
  static uint32_t lastVibMs = 0;
  // 주기 20% 감소: 3000ms -> 2400ms
  if (g_should_vibrate_phase4 && nowTick - lastVibMs >= 2400) {
    Serial.println("[VIB] setVibration: pulse start");
    // 세기 30% 감소 (기존 200 -> 140)
    M5.Power.setVibration(140);
    // 짧은 펄스 종료 예약 (non-blocking): 다음 틱에서 0으로
    // 즉시 끄지 않도록 최소 80ms 유지
    static uint32_t vibOnSince = 0;
    vibOnSince = nowTick;
    lastVibMs = nowTick;
  }
  // turn-off window (keep ~120ms)
  static uint32_t lastVibOn = 0;
  if (lastVibOn == 0) { lastVibOn = lastVibMs; }
  if (M5.Power.getType() != m5::Power_Class::pmic_unknown) {
    uint32_t since = (nowTick >= lastVibMs) ? (nowTick - lastVibMs) : 0;
    // 요청: 지속시간 2배 (기존 ~180ms -> ~360ms)
    if (since > 360 && since < 700) {
      // ensure off after short duration
      M5.Power.setVibration(0);
    }
  }
  // Example: A button to submit, B to confirm, C to wait
  if (M5.BtnA.wasPressed()) { sendCommand("start", "item-1"); }
  if (M5.BtnB.wasPressed()) { sendCommand("submit", "item-1"); }
  if (M5.BtnC.wasPressed()) { sendCommand("wait", "item-1"); }

  // Periodic online retained presence
  static uint32_t lastPresence = 0;
  uint32_t now = millis();
  if (WiFi.status() == WL_CONNECTED && !mqtt.connected() && nextMqttReconnectMs && now >= nextMqttReconnectMs) {
    nextMqttReconnectMs = 0;
    mqtt.connect();
    Serial.println("MQTT reconnect...");
  }
  // no periodic re-requests
  if (now - lastPresence > 15000) {
    lastPresence = now;
    DynamicJsonDocument doc(128);
    doc["online"] = true;
    doc["at"] = "";
    String payload; serializeJson(doc, payload);
    String topic = String("academies/") + academyId + "/devices/" + deviceId + "/presence";
    mqtt.publish(topic.c_str(), 1, true, payload.c_str());
  }
}


