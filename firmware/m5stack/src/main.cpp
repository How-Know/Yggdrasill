#include <M5Unified.h>
#include <WiFi.h>
#include <AsyncMqttClient.h>
#include <ArduinoJson.h>
#include "esp_wifi.h"
#include <lvgl.h>
#include <LittleFS.h>
#include <Preferences.h>
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
String studentId = "";
static String deviceId;

AsyncMqttClient mqtt;
String ackFilterPrefix;
String todayListTopic;
String homeworksTopic;
String updateTopic;
String studentInfoTopic;
String unboundTopic;
static String deviceAckTopic;
static uint32_t nextMqttReconnectMs = 0;
static const char* kMqttHosts[] = { CFG_MQTT_HOST, "test.mosquitto.org", "broker.hivemq.com" };
static int mqttHostIndex = 0;
static uint8_t mqttConsecutiveDisconnects = 0;
static char willPayloadBuf[128];
static char willTopicBuf[128];

// MQTT stale watchdog states
static uint32_t g_last_mqtt_connect_ms = 0;
static uint32_t g_last_mqtt_rx_any_ms = 0;
static uint32_t g_last_mqtt_rx_ack_ms = 0;
static uint32_t g_last_mqtt_rx_homeworks_ms = 0;
static uint32_t g_last_mqtt_rx_student_info_ms = 0;
static uint32_t g_last_watchdog_soft_ms = 0;
static uint32_t g_last_watchdog_hard_ms = 0;
static const uint32_t MQTT_STALE_SOFT_MS = 45000;
static const uint32_t MQTT_STALE_HARD_MS = 180000;
static const uint32_t MQTT_STALE_SOFT_COOLDOWN_MS = 15000;
static const uint32_t MQTT_STALE_HARD_COOLDOWN_MS = 90000;

// Deferred homework update (MQTT callback -> main loop)
static portMUX_TYPE g_hw_mux = portMUX_INITIALIZER_UNLOCKED;
static volatile bool g_hw_pending = false;
static String g_hw_pending_json;

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
  lv_obj_set_style_bg_color(scr, lv_color_hex(0x0B1112), 0);
  lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);
  lv_obj_set_style_radius(scr, 0, 0);

  // 내장 카카오 비트맵 폰트 16px 전역 적용
  // (상세 교재명은 ui_port.cpp에서 kakao_kr_24를 개별 적용)
  extern const lv_font_t kakao_kr_16; // src/fonts/kakao_kr_16.c
  ui_port_set_global_font(&kakao_kr_16);

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

void fw_publish_list_homeworks(const char* studentIdArg);

// 서버 하원(unbound) 또는 로컬 로그아웃 시 공통: NVS 추적용 studentId + LittleFS 정리 (MQTT 송신 없음)
void fw_clear_local_binding_state(void) {
  if (LittleFS.begin()) {
    if (LittleFS.exists("/student_id.txt")) {
      LittleFS.remove("/student_id.txt");
      Serial.println("[BIND] Cleared student_id.txt (local binding cleared)");
    }
    LittleFS.end();
  }
  studentId = "";
}

void onMqttConnect(bool sessionPresent) {
  g_last_mqtt_connect_ms = millis();
  g_last_mqtt_rx_any_ms = g_last_mqtt_connect_ms;
  mqttConsecutiveDisconnects = 0;
  ackFilterPrefix = String("academies/") + academyId + "/ack/";
  String ackTopic = ackFilterPrefix + "+";
  mqtt.subscribe(ackTopic.c_str(), 1);
  todayListTopic = String("academies/") + academyId + "/devices/" + deviceId + "/students_today";
  mqtt.subscribe(todayListTopic.c_str(), 1);
  homeworksTopic = String("academies/") + academyId + "/devices/" + deviceId + "/homeworks";
  mqtt.subscribe(homeworksTopic.c_str(), 1);
  studentInfoTopic = String("academies/") + academyId + "/devices/" + deviceId + "/student_info";
  mqtt.subscribe(studentInfoTopic.c_str(), 1);
  unboundTopic = String("academies/") + academyId + "/devices/" + deviceId + "/unbound";
  mqtt.subscribe(unboundTopic.c_str(), 1);
  updateTopic = String("academies/") + academyId + "/devices/" + deviceId + "/update";
  mqtt.subscribe(updateTopic.c_str(), 1);
  deviceAckTopic = String("academies/") + academyId + "/devices/" + deviceId + "/ack";
  mqtt.subscribe(deviceAckTopic.c_str(), 1);
  Serial.printf("MQTT connected & subscribed (sessionPresent=%d)\n", sessionPresent ? 1 : 0);

  // Presence (retain)
  {
    DynamicJsonDocument pres(128);
    pres["online"] = true;
    pres["at"] = "";
    String p; serializeJson(pres, p);
    String presTopic = String("academies/") + academyId + "/devices/" + deviceId + "/presence";
    mqtt.publish(presTopic.c_str(), 1, true, p.c_str());
  }
  
  // Request initial data: 바인딩된 학생이 있으면 student_info 요청, 없으면 list_today 요청
  String cmdTopic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
  if (studentId.length() > 0) {
    Serial.printf("[MQTT] Requesting student_info + list_homeworks for: %s\n", studentId.c_str());
    fw_publish_student_info(studentId.c_str());
    fw_publish_list_homeworks(studentId.c_str());
  } else {
    // 바인딩 없으면 학생 리스트 요청
    DynamicJsonDocument cmd(64);
    cmd["action"] = "list_today";
    String payload; serializeJson(cmd, payload);
    mqtt.publish(cmdTopic.c_str(), 1, false, payload.c_str());
    Serial.println("[MQTT] Requested list_today");
  }
  
  // Optionally also check for updates once
  {
    DynamicJsonDocument doc(64);
    doc["action"] = "check_update";
    String payload; serializeJson(doc, payload);
    mqtt.publish(cmdTopic.c_str(), 1, false, payload.c_str());
  }
}

void onMqttDisconnect(AsyncMqttClientDisconnectReason reason) {
  M5.Display.setCursor(0, 40);
  M5.Display.printf("MQTT disconnect: %d\n", (int)reason);
  Serial.print("MQTT disconnect reason: "); Serial.println((int)reason);
  // 3초 후 재시도
  nextMqttReconnectMs = millis() + 3000;
  // 짧은 끊김마다 호스트를 바꾸지 않고, 연속 실패가 누적될 때만 라운드로빈
  mqttConsecutiveDisconnects++;
  if (mqttConsecutiveDisconnects >= 3) {
    mqttConsecutiveDisconnects = 0;
    mqttHostIndex = (mqttHostIndex + 1) % (sizeof(kMqttHosts) / sizeof(kMqttHosts[0]));
    Serial.println("[MQTT] rotating host after repeated disconnects");
    configureMqttServer();
  }
}

void onMqttMessage(char* topic, char* payload, AsyncMqttClientMessageProperties properties, size_t len, size_t index, size_t total) {
  (void)properties; (void)index; (void)total;
  String t = String(topic);
  const uint32_t nowMs = millis();
  g_last_mqtt_rx_any_ms = nowMs;
  Serial.print("MSG "); Serial.print(t); Serial.print(" len="); Serial.println((int)len);
  if (t.startsWith(ackFilterPrefix)) {
    g_last_mqtt_rx_ack_ms = nowMs;
    String body; body.reserve(len + 1);
    for (size_t i = 0; i < len; ++i) body += (char)payload[i];
    Serial.print("ACK: "); Serial.println(body);
  }
  if (t == deviceAckTopic) {
    static String da_acc;
    static size_t da_expected = 0;
    static size_t da_received = 0;
    if (index == 0) {
      da_acc.remove(0);
      da_acc.reserve(total ? total : (len + 256));
      da_expected = total ? total : len;
      da_received = 0;
    }
    da_acc.concat(String(payload).substring(0, (int)len));
    da_received += len;
    if (total && da_received < total) { return; }
    g_last_mqtt_rx_ack_ms = nowMs;
    Serial.print("DEV_ACK: "); Serial.println(da_acc);
    ui_port_on_device_ack_json(da_acc.c_str());
    da_acc.remove(0);
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
    static String hw_acc; static size_t hw_expected = 0; static size_t hw_received = 0;
    if (index == 0) { hw_acc.remove(0); hw_acc.reserve(total ? total : (len + 512)); hw_expected = total ? total : len; hw_received = 0; }
    hw_acc.concat(String(payload).substring(0, (int)len));
    hw_received += len;
    if (total && hw_received < total) { return; }
    portENTER_CRITICAL(&g_hw_mux);
    g_hw_pending_json = hw_acc;
    g_hw_pending = true;
    portEXIT_CRITICAL(&g_hw_mux);
    g_last_mqtt_rx_homeworks_ms = nowMs;
    hw_acc.remove(0);
  }
  if (t == updateTopic) {
    String body; body.reserve(len + 1);
    for (size_t i = 0; i < len; ++i) body += (char)payload[i];
    // settings 화면에서 표시할 수 있도록 유지 (필요 시 별도 라벨 연결)
    Serial.print("UPDATE resp: "); Serial.println(body);
  }
  if (t == studentInfoTopic) {
    g_last_mqtt_rx_student_info_ms = nowMs;
    DynamicJsonDocument doc(1024);
    DeserializationError err = deserializeJson(doc, payload, len);
    if (!err && doc.containsKey("info")) {
      JsonObject info = doc["info"].as<JsonObject>();
      ui_port_update_student_info(info);
    }
  }
  if (t == unboundTopic) {
    Serial.println("[MQTT] unbound received – returning to student list");
    fw_clear_local_binding_state();
    ui_port_force_unbind();
  }
}

void sendCommand(const char* action, const char* itemId) {
  Serial.printf("[CMD] >>> sendCommand action=%s itemId=%s heap=%u\n", action, itemId, (unsigned)esp_get_free_heap_size());
  DynamicJsonDocument doc(256);
  doc["action"] = action;
  doc["academy_id"] = academyId;
  doc["student_id"] = studentId;
  doc["item_id"] = itemId;
  doc["idempotency_key"] = String((uint32_t)esp_random(), HEX);
  doc["at"] = "";
  String payload; serializeJson(doc, payload);
  String topic = String("academies/") + academyId + "/students/" + studentId + "/homework/" + itemId + "/command";
  Serial.printf("[CMD] publish topic=%s len=%d\n", topic.c_str(), (int)payload.length());
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
  Serial.println("[CMD] <<< sendCommand done");
}

// ===== UI publish bridge implementations =====
void fw_publish_bind(const char* studentIdArg) {
  if (!studentIdArg || !*studentIdArg) return;
  studentId = studentIdArg; // track bound student on device
  
  // LittleFS에 바인딩된 학생 ID 저장 (재시작 후 복원용)
  if (LittleFS.begin()) {
    File f = LittleFS.open("/student_id.txt", "w");
    if (f) {
      f.print(studentIdArg);
      f.close();
      Serial.printf("[BIND] Saved student_id: %s\n", studentIdArg);
    }
    LittleFS.end();
  }
  
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
  fw_clear_local_binding_state();
  Serial.println("[UNBIND] local binding cleared after publish");
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

void fw_publish_list_homeworks(const char* studentIdArg) {
  if (!studentIdArg || !*studentIdArg) return;
  DynamicJsonDocument doc(128);
  doc["action"] = "list_homeworks";
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

void fw_publish_group_transition(const char* groupId, int from_phase) {
  if (!groupId || !*groupId || !studentId.length()) return;
  DynamicJsonDocument doc(256);
  doc["action"] = "group_transition";
  doc["academy_id"] = academyId;
  doc["student_id"] = studentId;
  doc["item_id"] = "GROUP";
  doc["group_id"] = groupId;
  if (from_phase > 0) doc["from_phase"] = from_phase;
  doc["idempotency_key"] = String((uint32_t)esp_random(), HEX);
  doc["at"] = "";
  doc["updated_by"] = studentId;
  String payload;
  serializeJson(doc, payload);
  String topic =
      String("academies/") + academyId + "/students/" + studentId + "/homework/GROUP/command";
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

void fw_publish_raise_question() {
  if (!studentId.length()) return;
  DynamicJsonDocument doc(192);
  doc["action"] = "raise_question";
  doc["academy_id"] = academyId;
  doc["student_id"] = studentId;
  String payload;
  serializeJson(doc, payload);
  String topic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
}

void fw_publish_create_descriptive_writing() {
  if (!studentId.length()) return;
  DynamicJsonDocument doc(192);
  doc["action"] = "create_descriptive_writing";
  doc["academy_id"] = academyId;
  doc["student_id"] = studentId;
  String payload;
  serializeJson(doc, payload);
  String topic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
}

void fw_publish_check_update() {
  DynamicJsonDocument doc(64);
  doc["action"] = "check_update";
  String payload; serializeJson(doc, payload);
  String topic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
}

void fw_publish_list_today() {
  DynamicJsonDocument cmd(64);
  cmd["action"] = "list_today";
  String payload; serializeJson(cmd, payload);
  String topic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
  Serial.println("[MQTT] Requested list_today (manual)");
}

void setup() {
  auto cfg = M5.config(); M5.begin(cfg);
  M5.Display.setTextSize(2);
  Serial.begin(115200);

  // NVS에서 device_id 로드 (OTA 후에도 유지)
  {
    Preferences prefs;
    prefs.begin("m5cfg", false);
#ifdef PROVISION_DEVICE_ID
    // USB 업로드: CFG_DEVICE_ID로 NVS를 강제 갱신
    deviceId = CFG_DEVICE_ID;
    prefs.putString("device_id", deviceId);
    Serial.printf("[NVS] device_id provisioned: %s\n", deviceId.c_str());
#else
    // OTA 업로드: NVS에서 읽기 (없으면 CFG_DEVICE_ID 폴백)
    String stored = prefs.getString("device_id", "");
    if (stored.length() > 0) {
      deviceId = stored;
      Serial.printf("[NVS] device_id loaded: %s\n", deviceId.c_str());
    } else {
      deviceId = CFG_DEVICE_ID;
      prefs.putString("device_id", deviceId);
      Serial.printf("[NVS] device_id fallback: %s\n", deviceId.c_str());
    }
#endif
    prefs.end();
  }

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
  configTime(9 * 3600, 0, "pool.ntp.org", "time.google.com");
  Serial.println("MQTT connecting...");
  
  screensaver_init(20000);
  screensaver_attach_activity(lv_scr_act());
}

void loop() {
  M5.update();
  screensaver_notify_touch(M5.Touch.getCount() > 0);
  // LVGL ticking
  static uint32_t lastTick = 0;
  uint32_t nowTick = millis();
  lv_tick_inc(nowTick - lastTick);
  lastTick = nowTick;

  // homeworks 토픽은 단일 슬롯에 덮어쓰기 → 처리 중·직후에 또 도착한 페이로드를 같은 루프에서 연속 소비
  for (int hw_drain = 0; hw_drain < 12 && g_hw_pending; hw_drain++) {
    String json_copy;
    portENTER_CRITICAL(&g_hw_mux);
    json_copy = g_hw_pending_json;
    g_hw_pending_json.remove(0);
    g_hw_pending = false;
    portEXIT_CRITICAL(&g_hw_mux);
    if (json_copy.length() == 0) break;
    DynamicJsonDocument doc(json_copy.length() + 4096);
    DeserializationError err = deserializeJson(doc, json_copy.c_str(), json_copy.length());
    if (!err) {
      JsonArray arr = doc["groups"].as<JsonArray>();
      ui_port_update_homeworks(arr);
    }
  }

  lv_timer_handler();
  screensaver_poll();
  screensaver_check_shake();
  
  // Safe vibration handling (3 second interval) using PMIC vibration (LDO3/DLDO1)
  static uint32_t lastVibMs = 0;
  // 주기 20% 감소: 3000ms -> 2400ms
  if (g_should_vibrate_phase4 && nowTick - lastVibMs >= 2400) {
    Serial.println("[VIB] setVibration: pulse start");
    screensaver_dismiss();
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
  // Physical buttons disabled (no longer needed with touch UI)

  // Periodic online retained presence
  static uint32_t lastPresence = 0;
  uint32_t now = millis();
  if (WiFi.status() == WL_CONNECTED && !mqtt.connected() && nextMqttReconnectMs && now >= nextMqttReconnectMs) {
    nextMqttReconnectMs = 0;
    mqtt.connect();
    Serial.println("MQTT reconnect...");
  }

  // MQTT stale watchdog: 바인딩된 상태에서 수신 정체를 감지하면 재요청/재연결
  if (mqtt.connected() && studentId.length() > 0) {
    uint32_t lastInboundMs = g_last_mqtt_rx_any_ms;
    if (g_last_mqtt_rx_homeworks_ms > lastInboundMs) lastInboundMs = g_last_mqtt_rx_homeworks_ms;
    if (g_last_mqtt_rx_student_info_ms > lastInboundMs) lastInboundMs = g_last_mqtt_rx_student_info_ms;
    if (g_last_mqtt_rx_ack_ms > lastInboundMs) lastInboundMs = g_last_mqtt_rx_ack_ms;
    if (lastInboundMs == 0) lastInboundMs = g_last_mqtt_connect_ms;

    if (lastInboundMs > 0) {
      uint32_t staleMs = (now >= lastInboundMs) ? (now - lastInboundMs) : 0;
      bool canSoftRecover =
          (g_last_watchdog_soft_ms == 0) || ((now - g_last_watchdog_soft_ms) >= MQTT_STALE_SOFT_COOLDOWN_MS);
      bool canHardRecover =
          (g_last_watchdog_hard_ms == 0) || ((now - g_last_watchdog_hard_ms) >= MQTT_STALE_HARD_COOLDOWN_MS);

      if (staleMs >= MQTT_STALE_HARD_MS && canHardRecover) {
        g_last_watchdog_hard_ms = now;
        Serial.printf("[MQTT][WATCHDOG] hard stale %lu ms -> disconnect/reconnect\n", (unsigned long)staleMs);
        mqtt.disconnect();
        nextMqttReconnectMs = now + 500;
      } else if (staleMs >= MQTT_STALE_SOFT_MS && canSoftRecover) {
        g_last_watchdog_soft_ms = now;
        Serial.printf("[MQTT][WATCHDOG] soft stale %lu ms -> request student_info + list_homeworks\n", (unsigned long)staleMs);
        fw_publish_student_info(studentId.c_str());
        fw_publish_list_homeworks(studentId.c_str());
      }
    }
  }

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


