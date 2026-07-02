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
// 전용 로컬 브로커만 사용한다. 공용 브로커 폴백은 게이트웨이가 접속하지 않은
// 브로커로 M5가 붙는 split-brain을 유발하므로 제거(모두 로컬 브로커로 고정).
static const char* kMqttHosts[] = { CFG_MQTT_HOST };
static int mqttHostIndex = 0;
static uint8_t mqttConsecutiveDisconnects = 0;
static char willPayloadBuf[128];
static char willTopicBuf[128];

// [WIFI-DIAG] 무선 연결 진단 누적 버퍼. setup()의 WiFi 연결 과정(스캔/RSSI/첫 시도/
// fallback/최종 결과/소요시간)을 모았다가 onMqttConnect에서 diag 토픽으로 발행한다.
// USB를 꽂으면 증상이 사라져 시리얼로는 무선 문제를 재현할 수 없으므로 원격 수집한다.
static String g_wifi_diag;
static uint32_t g_wifi_connect_start_ms = 0;
static uint32_t g_wifi_connected_ms = 0;
static bool g_wifi_diag_sent = false;
static bool g_list_diag_sent = false;

// MQTT stale watchdog states
static uint32_t g_last_mqtt_connect_ms = 0;
static uint32_t g_last_mqtt_rx_any_ms = 0;
static uint32_t g_last_mqtt_rx_ack_ms = 0;
static uint32_t g_last_mqtt_rx_homeworks_ms = 0;
static uint32_t g_last_mqtt_rx_student_info_ms = 0;
static uint32_t g_last_watchdog_soft_ms = 0;
static uint32_t g_last_watchdog_hard_ms = 0;
// LittleFS 복원 등으로 studentId만 있고 bind MQTT를 아직 안 보낸 상태 — 첫 연결에서 등원(m5_record_arrival) 처리되도록 함
static bool g_mqtt_bind_announced = false;
static const uint32_t MQTT_STALE_SOFT_MS = 45000;
static const uint32_t MQTT_STALE_HARD_MS = 180000;
static const uint32_t MQTT_STALE_SOFT_COOLDOWN_MS = 15000;
static const uint32_t MQTT_STALE_HARD_COOLDOWN_MS = 90000;
// MQTT 연결은 AsyncMqttClient 내부에서 비동기로 진행된다. connected()==false인 동안에도
// CONNECTING 상태일 수 있으므로, 연결 실패 콜백이 오기 전 새 connect/disconnect를 겹치면
// 같은 clientId가 서로 session takeover를 일으킨다.
static uint32_t g_mqtt_connect_attempt_ms = 0;
static bool g_mqtt_connect_in_flight = false;
static uint8_t g_mqtt_connect_stall_count = 0;
static uint32_t g_last_mqtt_connect_stall_ms = 0;
static uint32_t g_mqtt_reconnect_backoff_ms = 2000;
static const uint32_t MQTT_CONNECT_STALL_MS = 20000;
// 안정성 우선: 재시도가 너무 뜸해지지 않도록 상한을 낮게 유지한다.
static const uint32_t MQTT_RECONNECT_BACKOFF_MIN_MS = 2000;
static const uint32_t MQTT_RECONNECT_BACKOFF_MAX_MS = 8000;
static bool g_last_tcp_probe_ok = false;
static uint32_t g_last_tcp_probe_ms = 0;
static uint32_t g_last_tcp_probe_elapsed_ms = 0;
static uint16_t g_tcp_probe_fail_count = 0;
// 느린 경로에서 핸드셰이크 직전 오탐으로 끊기지 않도록 넉넉히 준다.
static const uint32_t MQTT_TCP_PROBE_TIMEOUT_MS = 4000;
static bool g_wifi_loop_connected = false;
static const uint8_t ALERT_VIBRATION_STRENGTH = 102; // 약 4/10 기준(0-255 스케일)
static uint32_t g_last_boot_status_ui_ms = 0;

// Deferred homework update (MQTT callback -> main loop)
static portMUX_TYPE g_hw_mux = portMUX_INITIALIZER_UNLOCKED;
static volatile bool g_hw_pending = false;
static String g_hw_pending_json;

// Deferred UI work from MQTT (async-tcp) task -> executed in loop() (LVGL thread).
// LVGL is not thread-safe; building UI directly in the MQTT callback races with
// lv_timer_handler() and can overflow the async-tcp stack, causing freeze/reset.
static volatile bool g_bind_ack_pending = false;
static bool g_bind_ack_ok = false;
static char g_bind_ack_reason[32] = {0};
static int g_bind_ack_attempts_left = -1;
static int g_bind_ack_locked_seconds = -1;
static volatile bool g_students_pending = false;
static String g_students_pending_json;
static volatile bool g_student_info_pending = false;
static String g_student_info_pending_json;
static volatile bool g_force_unbind_pending = false;

// 초기 연결 안정화 보강 상태
//  - 미바인딩(학생 리스트) 화면에서 list_today 응답이 늦거나 유실될 때 자동 재요청
//  - 첫 데이터(학생 리스트/학생 정보) 수신 전까지는 절전 진입을 막아
//    "연결 중"이 빈/꺼진 화면처럼 보이지 않게 함
static volatile bool g_students_received = false;
static uint32_t g_last_list_request_ms = 0;
static const uint32_t LIST_REQUEST_RETRY_MS = 6000;
static bool g_first_ui_data_ready = false;
// 부팅 때 NVS에서 복원된 바인딩이 학생 정보/숙제 데이터를 못 받으면
// "학생" 기본명 화면에 갇히지 않도록 등원 리스트로 자동 복귀한다.
static bool g_restored_binding_guard_active = false;
static uint32_t g_restored_binding_guard_start_ms = 0;
static const uint32_t RESTORED_BINDING_DATA_TIMEOUT_MS = 30000;
// 바인딩을 당일까지만 유지하고 날짜가 바뀌면 자동 정리(좀비 바인딩 방지)
static uint32_t g_last_bind_day_check_ms = 0;
static const uint32_t BIND_DAY_CHECK_INTERVAL_MS = 60000;

// GROUP_CMD_V2 (server-authoritative group transition) states
static const char* GROUP_CMD_V2_TARGET_DEVICE = "m5-device-001";
static const uint32_t GROUP_CMD_V2_ACK_TIMEOUT_MS = 2500;
static const uint32_t GROUP_CMD_V2_TAP_LOCK_MS = 1200;
static bool g_group_transition_pending = false;
static String g_group_transition_pending_group_id;
static String g_group_transition_pending_request_id;
static uint32_t g_group_transition_pending_since_ms = 0;
static String g_group_transition_lock_group_id;
static uint32_t g_group_transition_lock_until_ms = 0;

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

// 미바인딩(학생 리스트) 화면에서 오늘 학생 목록을 요청한다.
// onMqttConnect와 loop()의 재요청 워치독에서 공통으로 사용.
static void fw_request_list_today() {
  String cmdTopic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
  DynamicJsonDocument cmd(64);
  cmd["action"] = "list_today";
  String payload; serializeJson(cmd, payload);
  mqtt.publish(cmdTopic.c_str(), 1, false, payload.c_str());
  g_last_list_request_ms = millis();
  Serial.println("[MQTT] Requested list_today");
}

static void update_boot_status_ui(bool force = false) {
  if (g_first_ui_data_ready) {
    ui_port_hide_boot_status();
    return;
  }

  uint32_t now = millis();
  if (!force && g_last_boot_status_ui_ms > 0 && (now - g_last_boot_status_ui_ms) < 1000) return;
  g_last_boot_status_ui_ms = now;

  bool wifiOk = WiFi.status() == WL_CONNECTED;
  bool mqttOk = mqtt.connected();
  unsigned long upSec = (unsigned long)(now / 1000);
  unsigned long wifiAgeSec = (wifiOk && g_wifi_connected_ms > 0 && now >= g_wifi_connected_ms)
      ? (unsigned long)((now - g_wifi_connected_ms) / 1000)
      : 0UL;
  unsigned long mqttAgeSec = (g_mqtt_connect_attempt_ms > 0 && now >= g_mqtt_connect_attempt_ms)
      ? (unsigned long)((now - g_mqtt_connect_attempt_ms) / 1000)
      : 0UL;

  String wifiLine = wifiOk
      ? "WiFi  OK  " + WiFi.localIP().toString() + " / RSSI " + String((int)WiFi.RSSI())
      : "WiFi  연결 중...";
  String mqttLine;
  if (mqttOk) {
    mqttLine = "MQTT  OK";
  } else if (!wifiOk) {
    mqttLine = "MQTT  WiFi 대기";
  } else if (!g_last_tcp_probe_ok && g_last_tcp_probe_ms > 0) {
    mqttLine = "TCP  FAIL  " + String((unsigned long)g_last_tcp_probe_elapsed_ms) +
        "ms / fail " + String((unsigned)g_tcp_probe_fail_count);
  } else if (g_mqtt_connect_in_flight) {
    mqttLine = "MQTT  연결 중... " + String(mqttAgeSec) + "초";
  } else {
    mqttLine = "MQTT  재시도 대기... " + String(wifiAgeSec) + "초";
  }
  String listLine = g_students_received
      ? "List  OK"
      : (mqttOk ? "List  등원학생 목록 대기" : "List  MQTT 대기");
  String detail =
      "broker=" + String(kMqttHosts[mqttHostIndex]) + ":" + String(MQTT_PORT) +
      "\nssid=" + String(WIFI_SSID) +
      "\nboot=" + String(upSec) + "s wifi_age=" + String(wifiAgeSec) +
      "s mqtt_try=" + String(mqttAgeSec) + "s" +
      "\ntcp=" + String(g_last_tcp_probe_ok ? "OK" : "FAIL") +
      " " + String((unsigned long)g_last_tcp_probe_elapsed_ms) + "ms" +
      " fail=" + String((unsigned)g_tcp_probe_fail_count) +
      "\nstall=" + String(g_mqtt_connect_stall_count) +
      " backoff=" + String((unsigned long)g_mqtt_reconnect_backoff_ms) + "ms";

  ui_port_update_boot_status(wifiLine.c_str(), mqttLine.c_str(), listLine.c_str(), detail.c_str());
}

void fw_publish_list_homeworks(const char* studentIdArg);

static void persist_student_id_nvs(const String& sid) {
  Preferences prefs;
  prefs.begin("m5cfg", false);
  if (sid.length() > 0) {
    prefs.putString("student_id", sid);
  } else {
    prefs.remove("student_id");
  }
  prefs.end();
}

static String load_student_id_nvs() {
  Preferences prefs;
  prefs.begin("m5cfg", true);
  String sid = prefs.getString("student_id", "");
  prefs.end();
  sid.trim();
  return sid;
}

static void persist_bind_date_nvs(uint32_t ymd) {
  Preferences prefs;
  prefs.begin("m5cfg", false);
  if (ymd > 0) {
    prefs.putUInt("bind_date", ymd);
  } else {
    prefs.remove("bind_date");
  }
  prefs.end();
}

static uint32_t load_bind_date_nvs() {
  Preferences prefs;
  prefs.begin("m5cfg", true);
  uint32_t ymd = prefs.getUInt("bind_date", 0);
  prefs.end();
  return ymd;
}

// 현재 KST 날짜를 YYYYMMDD로 반환. NTP 미동기화 시 0.
static uint32_t current_kst_yyyymmdd() {
  time_t now = time(nullptr);
  if (now < 1700000000) return 0; // 2023-11 이전이면 시간 미동기화로 간주
  struct tm tmv;
  localtime_r(&now, &tmv); // configTime(9h)로 KST 반영됨
  return (uint32_t)((tmv.tm_year + 1900) * 10000u + (tmv.tm_mon + 1) * 100u + tmv.tm_mday);
}

static bool is_group_cmd_v2_enabled() {
  return deviceId == GROUP_CMD_V2_TARGET_DEVICE;
}

static String make_group_transition_request_id(const char* groupId) {
  uint16_t gidHash = 0;
  if (groupId) {
    for (size_t i = 0; groupId[i] != '\0'; ++i) {
      gidHash = (uint16_t)((gidHash * 131u) ^ (uint8_t)groupId[i]);
    }
  }
  char buf[56];
  uint32_t r1 = (uint32_t)esp_random();
  uint32_t r2 = (uint32_t)esp_random();
  uint32_t tick = millis();
  snprintf(
      buf,
      sizeof(buf),
      "%08lx%08lx%08lx%04x",
      (unsigned long)r1,
      (unsigned long)r2,
      (unsigned long)tick,
      (unsigned int)gidHash);
  return String(buf);
}

static void set_group_transition_lock(const char* groupId, uint32_t nowMs) {
  if (!groupId || !*groupId) return;
  g_group_transition_lock_group_id = groupId;
  g_group_transition_lock_until_ms = nowMs + GROUP_CMD_V2_TAP_LOCK_MS;
}

static void clear_group_transition_pending(const char* reason, bool requestRefresh) {
  if (g_group_transition_pending) {
    Serial.printf(
        "[GROUP_CMD_V2] clear pending reason=%s group=%s request_id=%s refresh=%d\n",
        reason ? reason : "unknown",
        g_group_transition_pending_group_id.c_str(),
        g_group_transition_pending_request_id.c_str(),
        requestRefresh ? 1 : 0);
  }
  g_group_transition_pending = false;
  g_group_transition_pending_group_id.remove(0);
  g_group_transition_pending_request_id.remove(0);
  g_group_transition_pending_since_ms = 0;

  if (requestRefresh && studentId.length() > 0) {
    fw_publish_list_homeworks(studentId.c_str());
  }
}

static bool should_block_group_transition(const char* groupId, uint32_t nowMs) {
  if (!groupId || !*groupId) return true;

  if (g_group_transition_pending &&
      g_group_transition_pending_group_id == groupId) {
    uint32_t age = (nowMs >= g_group_transition_pending_since_ms)
        ? (nowMs - g_group_transition_pending_since_ms)
        : 0;
    if (age < GROUP_CMD_V2_ACK_TIMEOUT_MS) return true;
    clear_group_transition_pending("stale_before_send", true);
  }

  if (g_group_transition_lock_until_ms > nowMs &&
      g_group_transition_lock_group_id == groupId) {
    return true;
  }

  return false;
}

static void handle_group_transition_device_ack(const char* body) {
  if (!is_group_cmd_v2_enabled()) return;
  if (!body || !body[0]) return;

  StaticJsonDocument<384> doc;
  DeserializationError err = deserializeJson(doc, body);
  if (err) return;

  const char* action = doc["action"] | "";
  if (strcmp(action, "group_transition") != 0) return;

  const char* requestId = doc["request_id"] | "";
  if (!requestId || !requestId[0]) {
    Serial.println("[GROUP_CMD_V2] ack missing request_id");
    return;
  }

  if (!g_group_transition_pending) return;
  if (g_group_transition_pending_request_id != String(requestId)) {
    Serial.printf(
        "[GROUP_CMD_V2] ack ignored request_id=%s pending=%s\n",
        requestId,
        g_group_transition_pending_request_id.c_str());
    return;
  }

  const bool ok = doc["ok"] | false;
  const bool dedup = doc["dedup"] | false;
  const int changed = doc.containsKey("changed") ? (int)doc["changed"] : 0;
  Serial.printf(
      "[GROUP_CMD_V2] ack matched request_id=%s ok=%d dedup=%d changed=%d\n",
      requestId,
      ok ? 1 : 0,
      dedup ? 1 : 0,
      changed);

  clear_group_transition_pending("ack", !ok);
}

// 서버 하원(unbound) 또는 로컬 로그아웃 시 공통: NVS 추적용 studentId + LittleFS 정리 (MQTT 송신 없음)
void fw_clear_local_binding_state(void) {
  if (LittleFS.begin(true)) {
    if (LittleFS.exists("/student_id.txt")) {
      LittleFS.remove("/student_id.txt");
      Serial.println("[BIND] Cleared student_id.txt (local binding cleared)");
    }
    LittleFS.end();
  }
  persist_student_id_nvs("");
  persist_bind_date_nvs(0);
  studentId = "";
  g_mqtt_bind_announced = false;
  g_group_transition_pending = false;
  g_group_transition_pending_group_id.remove(0);
  g_group_transition_pending_request_id.remove(0);
  g_group_transition_pending_since_ms = 0;
  g_group_transition_lock_group_id.remove(0);
  g_group_transition_lock_until_ms = 0;
}

void onMqttConnect(bool sessionPresent) {
  g_last_mqtt_connect_ms = millis();
  uint32_t mqttAttemptStartedMs = g_mqtt_connect_attempt_ms;
  uint8_t mqttStallsBeforeConnect = g_mqtt_connect_stall_count;
  uint32_t lastMqttStallMs = g_last_mqtt_connect_stall_ms;
  uint16_t tcpProbeFailBeforeConnect = g_tcp_probe_fail_count;
  g_last_mqtt_rx_any_ms = g_last_mqtt_connect_ms;
  g_mqtt_connect_attempt_ms = 0;
  g_mqtt_connect_in_flight = false;
  g_mqtt_connect_stall_count = 0;
  g_mqtt_reconnect_backoff_ms = MQTT_RECONNECT_BACKOFF_MIN_MS;
  g_tcp_probe_fail_count = 0;
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

  // [WIFI-DIAG] WiFi 연결 진단을 원격 수집(최초 1회). 무선 상태에서만 재현되는
  // fallback/멈춤 증상의 근본 원인(RSSI 약화/AP 다중/연결 지연)을 확인하기 위함.
  if (!g_wifi_diag_sent) {
    g_wifi_diag_sent = true;
    String diag = g_wifi_diag;
    diag += "mqtt_connect_after_wifi_ms=" + String((unsigned long)(g_last_mqtt_connect_ms - g_wifi_connected_ms)) + "\n";
    if (mqttAttemptStartedMs > 0 && g_last_mqtt_connect_ms >= mqttAttemptStartedMs) {
      diag += "mqtt_connect_attempt_ms=" + String((unsigned long)(g_last_mqtt_connect_ms - mqttAttemptStartedMs)) + "\n";
    }
    diag += "boot_to_mqtt_ms=" + String((unsigned long)(g_last_mqtt_connect_ms - g_wifi_connect_start_ms)) + "\n";
    diag += "connected_ssid=" + WiFi.SSID() + "\n";
    diag += "connected_bssid=" + WiFi.BSSIDstr() + "\n";
    diag += "connected_ch=" + String(WiFi.channel()) + "\n";
    diag += "connected_rssi=" + String((int)WiFi.RSSI()) + "\n";
    diag += "local_ip=" + WiFi.localIP().toString() + "\n";
    diag += "gateway_ip=" + WiFi.gatewayIP().toString() + "\n";
    diag += "subnet=" + WiFi.subnetMask().toString() + "\n";
    diag += "mac=" + WiFi.macAddress() + "\n";
    diag += "mqtt_host=" + String(kMqttHosts[mqttHostIndex]) + "\n";
    diag += "mqtt_port=" + String(MQTT_PORT) + "\n";
    diag += "mqtt_connect_stalls=" + String((unsigned)mqttStallsBeforeConnect) + "\n";
    diag += "last_mqtt_connect_stall_ms=" + String((unsigned long)lastMqttStallMs) + "\n";
    diag += "tcp_probe_ok=" + String(g_last_tcp_probe_ok ? 1 : 0) + "\n";
    diag += "tcp_probe_elapsed_ms=" + String((unsigned long)g_last_tcp_probe_elapsed_ms) + "\n";
    diag += "tcp_probe_fail_count=" + String((unsigned)tcpProbeFailBeforeConnect) + "\n";
    diag += "free_heap=" + String((unsigned)esp_get_free_heap_size()) + "\n";
    String diagTopic = String("academies/") + academyId + "/devices/" + deviceId + "/diag";
    mqtt.publish(diagTopic.c_str(), 1, false, diag.c_str());
    Serial.println("[WIFI-DIAG] published:\n" + diag);
  }

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
    if (g_restored_binding_guard_active && g_restored_binding_guard_start_ms == 0) {
      g_restored_binding_guard_start_ms = millis();
      Serial.printf("[BIND][GUARD] restored binding data wait start sid=%s timeout=%lums\n",
                    studentId.c_str(),
                    (unsigned long)RESTORED_BINDING_DATA_TIMEOUT_MS);
    }
    // bind가 서버에 도달해야 m5_bind_device + m5_record_arrival(등원)이 실행됨. LittleFS 복원만 한 경우 첫 연결에서 bind 필요.
    if (!g_mqtt_bind_announced) {
      Serial.printf("[MQTT] Re-announcing bind (등원/바인딩 동기화) for: %s\n", studentId.c_str());
      fw_publish_bind(studentId.c_str());
    } else {
      Serial.printf("[MQTT] Requesting student_info + list_homeworks for: %s\n", studentId.c_str());
      fw_publish_list_homeworks(studentId.c_str());
    }
    fw_publish_student_info(studentId.c_str());
  } else {
    // 바인딩 없으면 학생 리스트 요청. 응답 수신 추적을 리셋해, 응답이 늦거나
    // 유실되면 loop()의 워치독이 자동 재요청하도록 한다.
    g_students_received = false;
    g_list_diag_sent = false;
    fw_request_list_today();
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
  // 화면 직접 출력은 async-tcp 스레드에서 LVGL flush와 경합하고,
  // 사용자에게 "MQTT disconnect: 0"이 그대로 노출되므로 제거. 시리얼 로그만 남김.
  Serial.print("MQTT disconnect reason: "); Serial.println((int)reason);
  Serial.printf("[MQTT] disconnect diag wifi=%d ip=%s rssi=%d bssid=%s ch=%d\n",
                WiFi.status() == WL_CONNECTED ? 1 : 0,
                WiFi.localIP().toString().c_str(),
                WiFi.status() == WL_CONNECTED ? (int)WiFi.RSSI() : 0,
                WiFi.status() == WL_CONNECTED ? WiFi.BSSIDstr().c_str() : "-",
                WiFi.status() == WL_CONNECTED ? WiFi.channel() : 0);
  g_mqtt_connect_in_flight = false;
  g_mqtt_connect_attempt_ms = 0;
  // 3초 후 재시도
  nextMqttReconnectMs = millis() + g_mqtt_reconnect_backoff_ms;
  // 짧은 끊김마다 호스트를 바꾸지 않고, 연속 실패가 누적될 때만 라운드로빈
  mqttConsecutiveDisconnects++;
  if (mqttConsecutiveDisconnects >= 3) {
    mqttConsecutiveDisconnects = 0;
    mqttHostIndex = (mqttHostIndex + 1) % (sizeof(kMqttHosts) / sizeof(kMqttHosts[0]));
    Serial.println("[MQTT] rotating host after repeated disconnects");
    configureMqttServer();
  }
}

static void start_mqtt_connect(const char* reason) {
  if (WiFi.status() != WL_CONNECTED) return;
  if (mqtt.connected()) return;
  if (g_mqtt_connect_in_flight) {
    Serial.printf("[MQTT] connect skipped; already in flight (%s, age=%lums)\n",
                  reason ? reason : "?",
                  g_mqtt_connect_attempt_ms > 0 ? (unsigned long)(millis() - g_mqtt_connect_attempt_ms) : 0UL);
    return;
  }
  const char* host = kMqttHosts[mqttHostIndex];
  {
    WiFiClient probe;
    probe.setTimeout(MQTT_TCP_PROBE_TIMEOUT_MS);
    uint32_t t0 = millis();
    bool tcpOk = probe.connect(host, MQTT_PORT, MQTT_TCP_PROBE_TIMEOUT_MS);
    uint32_t elapsed = millis() - t0;
    probe.stop();
    g_last_tcp_probe_ok = tcpOk;
    g_last_tcp_probe_ms = millis();
    g_last_tcp_probe_elapsed_ms = elapsed;
    if (tcpOk) {
      Serial.printf("[MQTT][TCP-PROBE] ok host=%s:%u elapsed=%lums ip=%s rssi=%d\n",
                    host,
                    (unsigned)MQTT_PORT,
                    (unsigned long)elapsed,
                    WiFi.localIP().toString().c_str(),
                    (int)WiFi.RSSI());
    } else {
      g_tcp_probe_fail_count++;
      Serial.printf("[MQTT][TCP-PROBE] fail host=%s:%u elapsed=%lums fails=%u ip=%s rssi=%d bssid=%s ch=%d\n",
                    host,
                    (unsigned)MQTT_PORT,
                    (unsigned long)elapsed,
                    (unsigned)g_tcp_probe_fail_count,
                    WiFi.localIP().toString().c_str(),
                    (int)WiFi.RSSI(),
                    WiFi.BSSIDstr().c_str(),
                    WiFi.channel());
      nextMqttReconnectMs = millis() + g_mqtt_reconnect_backoff_ms;
      g_mqtt_reconnect_backoff_ms = min(g_mqtt_reconnect_backoff_ms * 2, MQTT_RECONNECT_BACKOFF_MAX_MS);
      if (g_tcp_probe_fail_count > 0 && (g_tcp_probe_fail_count % 3) == 0) {
        Serial.println("[MQTT][TCP-PROBE] repeated failures -> keep WiFi, retry TCP with backoff");
      }
      update_boot_status_ui(true);
      return;
    }
  }
  g_mqtt_connect_in_flight = true;
  g_mqtt_connect_attempt_ms = millis();
  mqtt.connect();
  Serial.printf("[MQTT] connecting (%s)\n", reason ? reason : "?");
}

static void handle_mqtt_connect_stall(uint32_t now) {
  if (WiFi.status() != WL_CONNECTED) {
    g_mqtt_connect_in_flight = false;
    g_mqtt_connect_attempt_ms = 0;
    return;
  }
  if (mqtt.connected() || !g_mqtt_connect_in_flight || g_mqtt_connect_attempt_ms == 0) return;

  uint32_t ageMs = (now >= g_mqtt_connect_attempt_ms) ? (now - g_mqtt_connect_attempt_ms) : 0;
  if (ageMs < MQTT_CONNECT_STALL_MS) return;

  g_mqtt_connect_stall_count++;
  g_last_mqtt_connect_stall_ms = now;
  Serial.printf("[MQTT][CONNECT-STALL] age=%lums stalls=%u -> reset mqtt client, retry in %lums\n",
                (unsigned long)ageMs,
                (unsigned)g_mqtt_connect_stall_count,
                (unsigned long)g_mqtt_reconnect_backoff_ms);
  Serial.printf("[MQTT][CONNECT-STALL] wifi ip=%s rssi=%d bssid=%s ch=%d host=%s:%u\n",
                WiFi.localIP().toString().c_str(),
                (int)WiFi.RSSI(),
                WiFi.BSSIDstr().c_str(),
                WiFi.channel(),
                kMqttHosts[mqttHostIndex],
                (unsigned)MQTT_PORT);

  mqtt.disconnect(true);
  g_mqtt_connect_in_flight = false;
  g_mqtt_connect_attempt_ms = 0;
  nextMqttReconnectMs = now + g_mqtt_reconnect_backoff_ms;
  g_mqtt_reconnect_backoff_ms = min(g_mqtt_reconnect_backoff_ms * 2, MQTT_RECONNECT_BACKOFF_MAX_MS);

  // WiFi 재협상은 사용 중 화면을 계속 흔들어 더 나쁜 체감을 만든다.
  // 연결 경로가 막혔더라도 WiFi는 유지하고 MQTT/TCP만 백오프로 재시도한다.
  if (g_mqtt_connect_stall_count >= 3) {
    Serial.println("[MQTT][CONNECT-STALL] repeated stalls -> keep WiFi, retry MQTT with backoff");
    g_mqtt_connect_stall_count = 0;
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
    handle_group_transition_device_ack(da_acc.c_str());
    ui_port_on_device_ack_json(da_acc.c_str());
    {
      StaticJsonDocument<256> ackDoc;
      if (deserializeJson(ackDoc, da_acc.c_str()) == DeserializationError::Ok) {
        const char* ackAction = ackDoc["action"] | "";
        if (strcmp(ackAction, "bind") == 0) {
          bool ok = ackDoc["ok"] | false;
          const char* reason = ackDoc["reason"] | "";
          int attempts_left = ackDoc["attempts_left"] | -1;
          int locked_seconds = ackDoc["locked_seconds"] | -1;
          // Defer UI work to loop() (LVGL thread) — see g_bind_ack_pending notes.
          portENTER_CRITICAL(&g_hw_mux);
          g_bind_ack_ok = ok;
          strncpy(g_bind_ack_reason, reason ? reason : "", sizeof(g_bind_ack_reason) - 1);
          g_bind_ack_reason[sizeof(g_bind_ack_reason) - 1] = '\0';
          g_bind_ack_attempts_left = attempts_left;
          g_bind_ack_locked_seconds = locked_seconds;
          g_bind_ack_pending = true;
          portEXIT_CRITICAL(&g_hw_mux);
        }
      }
    }
    da_acc.remove(0);
  }
  if (t == todayListTopic) {
    static String acc; static size_t expected = 0; static size_t received = 0;
    if (index == 0) { acc.remove(0); acc.reserve(total ? total : (len + 512)); expected = total ? total : len; received = 0; }
    acc.concat(String(payload).substring(0, (int)len));
    received += len;
    Serial.printf("students_today chunk: idx=%u len=%u total=%u recv=%u\n", (unsigned)index, (unsigned)len, (unsigned)total, (unsigned)received);
    if (total && received < total) { return; }
    // Defer parse + UI render to loop() (LVGL thread).
    portENTER_CRITICAL(&g_hw_mux);
    g_students_pending_json = acc;
    g_students_pending = true;
    portEXIT_CRITICAL(&g_hw_mux);
    acc.remove(0);
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
    Serial.printf("[M5SYNC][rx] device=%s student=%s len=%u\n",
                  deviceId.c_str(),
                  studentId.c_str(),
                  (unsigned)hw_acc.length());
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
    // Defer parse + UI render to loop() (LVGL thread).
    String body; body.reserve(len + 1);
    for (size_t i = 0; i < len; ++i) body += (char)payload[i];
    portENTER_CRITICAL(&g_hw_mux);
    g_student_info_pending_json = body;
    g_student_info_pending = true;
    portEXIT_CRITICAL(&g_hw_mux);
  }
  if (t == unboundTopic) {
    Serial.println("[MQTT] unbound received – returning to student list");
    // Defer local-state clear + UI unbind to loop() (LVGL thread).
    portENTER_CRITICAL(&g_hw_mux);
    g_force_unbind_pending = true;
    portEXIT_CRITICAL(&g_hw_mux);
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
// bind ack 성공 후에만 로컬 바인딩 상태를 확정한다 (NVS + LittleFS).
void fw_commit_bind(const char* studentIdArg) {
  if (!studentIdArg || !*studentIdArg) return;
  studentId = studentIdArg; // track bound student on device
  persist_student_id_nvs(studentId);
  persist_bind_date_nvs(current_kst_yyyymmdd());

  // LittleFS에 바인딩된 학생 ID 저장 (재시작 후 복원용)
  if (LittleFS.begin(true)) {
    File f = LittleFS.open("/student_id.txt", "w");
    if (f) {
      f.print(studentIdArg);
      f.close();
      Serial.printf("[BIND] Saved student_id: %s\n", studentIdArg);
    }
    LittleFS.end();
  }
  g_mqtt_bind_announced = true;
}

// 재접속 재announce 전용: 이미 바인딩된 학생을 서버에 다시 알림 (서버는 same-device를 ok로 처리)
void fw_publish_bind(const char* studentIdArg) {
  if (!studentIdArg || !*studentIdArg) return;
  fw_commit_bind(studentIdArg);

  DynamicJsonDocument doc(128);
  doc["action"] = "bind";
  doc["student_id"] = studentIdArg;
  String payload; serializeJson(doc, payload);
  String topic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
}

// 인터랙티브 로그인: 로컬 상태를 바꾸지 않고 bind 커맨드만 발행. ack 성공 시 fw_commit_bind로 확정.
void fw_request_bind(const char* studentIdArg, const char* pin) {
  if (!studentIdArg || !*studentIdArg) return;
  DynamicJsonDocument doc(192);
  doc["action"] = "bind";
  doc["student_id"] = studentIdArg;
  if (pin && *pin) doc["pin"] = pin;
  String payload; serializeJson(doc, payload);
  String topic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
  Serial.printf("[BIND] request bind (await ack) student=%s pin=%s\n", studentIdArg, (pin && *pin) ? "set" : "none");
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

// 바인딩을 당일까지만 유지: 날짜가 바뀌면 자동으로 서버 unbind + 등원 리스트 복귀.
// 서버에 unbind를 확실히 전달하기 위해 MQTT 연결 상태에서만 정리한다.
static void handle_bind_day_expiry(uint32_t nowTick) {
  if (studentId.length() == 0) return;
  if (!mqtt.connected()) return;
  if (g_last_bind_day_check_ms != 0 && (nowTick - g_last_bind_day_check_ms) < BIND_DAY_CHECK_INTERVAL_MS) return;
  g_last_bind_day_check_ms = nowTick;

  uint32_t today = current_kst_yyyymmdd();
  if (today == 0) return; // 시간 미동기화

  uint32_t bindDate = load_bind_date_nvs();
  if (bindDate == 0) {
    // 구버전/시간 미동기 상태에서 저장된 바인딩 -> 오늘로 채택(오탐 방지)
    persist_bind_date_nvs(today);
    return;
  }
  if (bindDate != today) {
    Serial.printf("[BIND][DAY] stale binding %lu != today %lu -> auto unbind\n",
                  (unsigned long)bindDate, (unsigned long)today);
    g_students_received = false;
    g_first_ui_data_ready = false;
    g_last_list_request_ms = 0;
    g_restored_binding_guard_active = false;
    g_restored_binding_guard_start_ms = 0;
    fw_publish_unbind();
    ui_port_force_unbind();
  }
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

bool fw_publish_group_transition(const char* groupId, int from_phase) {
  if (!groupId || !*groupId || !studentId.length()) return false;

  const bool useV2 = is_group_cmd_v2_enabled();
  const uint32_t nowMs = millis();
  if (useV2 && should_block_group_transition(groupId, nowMs)) {
    Serial.printf(
        "[GROUP_CMD_V2] blocked duplicate group=%s pending=%d lock_until=%lu\n",
        groupId,
        g_group_transition_pending ? 1 : 0,
        (unsigned long)g_group_transition_lock_until_ms);
    return false;
  }

  DynamicJsonDocument doc(320);
  doc["action"] = "group_transition";
  doc["academy_id"] = academyId;
  doc["student_id"] = studentId;
  doc["item_id"] = "GROUP";
  doc["group_id"] = groupId;
  if (from_phase > 0) doc["from_phase"] = from_phase;
  doc["at"] = "";
  doc["updated_by"] = studentId;

  String topic;
  String requestId;
  if (useV2) {
    requestId = make_group_transition_request_id(groupId);
    doc["request_id"] = requestId;
    doc["idempotency_key"] = requestId;
    topic = String("academies/") + academyId + "/devices/" + deviceId + "/command";
  } else {
    doc["idempotency_key"] = String((uint32_t)esp_random(), HEX);
    topic = String("academies/") + academyId + "/students/" + studentId + "/homework/GROUP/command";
  }

  String payload;
  serializeJson(doc, payload);
  uint16_t pkt = mqtt.publish(topic.c_str(), 1, false, payload.c_str());
  if (pkt == 0) {
    Serial.printf("[GROUP_CMD_V2] publish failed group=%s topic=%s\n", groupId, topic.c_str());
    return false;
  }

  if (useV2) {
    g_group_transition_pending = true;
    g_group_transition_pending_group_id = groupId;
    g_group_transition_pending_request_id = requestId;
    g_group_transition_pending_since_ms = nowMs;
    set_group_transition_lock(groupId, nowMs);
    Serial.printf(
        "[GROUP_CMD_V2] sent request_id=%s group=%s phase=%d packet=%u\n",
        requestId.c_str(),
        groupId,
        from_phase,
        (unsigned)pkt);
  }

  return true;
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

static void publish_homeworks_sync_ack(JsonObject meta, unsigned int groupCount) {
  const char* syncFp = meta["sync_fp"] | "";
  if (!syncFp || !syncFp[0]) return;

  DynamicJsonDocument doc(320);
  doc["type"] = "homeworks_apply";
  doc["ok"] = true;
  doc["device_id"] = deviceId;
  doc["student_id"] = studentId;
  doc["meta_student_id"] = meta["student_id"] | "";
  doc["sync_seq"] = meta["sync_seq"] | 0;
  doc["sync_fp"] = syncFp;
  doc["source"] = meta["source"] | "";
  doc["group_count"] = groupCount;
  doc["at"] = "";

  String payload;
  serializeJson(doc, payload);
  String topic = String("academies/") + academyId + "/devices/" + deviceId + "/sync_ack";
  mqtt.publish(topic.c_str(), 1, false, payload.c_str());
  Serial.printf("[M5SYNC][ack] device=%s student=%s sync_seq=%lu sync_fp=%s groups=%u\n",
                deviceId.c_str(),
                studentId.c_str(),
                (unsigned long)(meta["sync_seq"] | 0),
                syncFp,
                groupCount);
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
  {
    String restoredStudentId = load_student_id_nvs();
    if (restoredStudentId.length() > 0) {
      studentId = restoredStudentId;
      g_mqtt_bind_announced = false;
      g_restored_binding_guard_active = true;
      g_restored_binding_guard_start_ms = 0;
      Serial.printf("[NVS] restored student_id: %s\n", studentId.c_str());
    }
  }

  initLvgl();
  ui_port_show_boot_status();
  ui_port_update_boot_status("WiFi  스캔 준비", "MQTT  WiFi 대기", "List  MQTT 대기", "부팅 진단 화면");
  lv_timer_handler();
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
  g_wifi_connect_start_ms = millis();
  int targetRssi = 0;
  {
    Serial.println("WiFi scanning...");
    ui_port_update_boot_status("WiFi  AP 스캔 중", "MQTT  WiFi 대기", "List  MQTT 대기", "주변 AP/RSSI/채널 기록 중");
    lv_timer_handler();
    int n = WiFi.scanNetworks();
    g_wifi_diag += "scan_nets=" + String(n) + "\n";
    for (int i = 0; i < n; ++i) {
      String s = WiFi.SSID(i);
      int ch = WiFi.channel(i);
      int rssi = WiFi.RSSI(i);
      if (i < 6) { Serial.printf("%d) %s (ch%d rssi%d)\n", i + 1, s.c_str(), ch, rssi); }
      // 진단: 스캔된 AP 목록(최대 12개) — 단일/다중 AP, 신호세기 확인용
      if (i < 12) {
        g_wifi_diag += "ap[" + String(i) + "]=" + s + " ch" + String(ch) + " rssi" + String(rssi) + "\n";
      }
      // 같은 SSID가 여러 개여도 RSSI가 가장 강한 AP를 선택(약한 AP 고정으로 인한 첫 연결 실패 방지)
      if (s == String(configuredSsid) || s == String(fallbackUtf8Ssid)) {
        if (!foundMatch || rssi > targetRssi) {
          targetChannel = ch; ssidToUse = (s == String(configuredSsid)) ? configuredSsid : fallbackUtf8Ssid;
          foundMatch = true; targetRssi = rssi; memcpy(targetBssid, WiFi.BSSID(i), 6);
        }
      }
    }
    WiFi.scanDelete();
  }
  g_wifi_diag += "first_attempt ssid=" + String(ssidToUse) + " ch" + String(targetChannel) + " rssi" + String(targetRssi) + " matched=" + String(foundMatch ? 1 : 0) + "\n";
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
  while (WiFi.status() != WL_CONNECTED && millis() - start < 8000) {
    update_boot_status_ui(true);
    lv_timer_handler();
    delay(200);
  }
  g_wifi_diag += "first_result connected=" + String(WiFi.status() == WL_CONNECTED ? 1 : 0) + " elapsed_ms=" + String((unsigned long)(millis() - start)) + " status=" + String((int)WiFi.status()) + "\n";

  // Fallback: SSID 인코딩 문제로 실패 시, 스캔 결과를 이용해 순차 접속 시도
  if (WiFi.status() != WL_CONNECTED) {
    g_wifi_diag += "fallback entered=1\n";
    M5.Display.println("Fallback connect trials...");
    int n2 = WiFi.scanNetworks();
    for (int i = 0; i < n2; ++i) {
      String ss = WiFi.SSID(i);
      int ch = WiFi.channel(i);
      const uint8_t* bssid = WiFi.BSSID(i);
      M5.Display.printf("Try %d: %s (ch%d)\n", i + 1, ss.c_str(), ch);
      WiFi.begin(ss.c_str(), WIFI_PASS, ch, bssid);
      uint32_t t0 = millis();
      while (WiFi.status() != WL_CONNECTED && millis() - t0 < 6000) {
        update_boot_status_ui(true);
        lv_timer_handler();
        delay(200);
      }
      g_wifi_diag += "fallback_try[" + String(i) + "]=" + ss + " connected=" + String(WiFi.status() == WL_CONNECTED ? 1 : 0) + "\n";
      if (WiFi.status() == WL_CONNECTED) break;
    }
    WiFi.scanDelete();
  }
  g_wifi_connected_ms = millis();
  if (WiFi.status() == WL_CONNECTED) {
    g_wifi_diag += "final connected=1 rssi=" + String((int)WiFi.RSSI()) + " total_ms=" + String((unsigned long)(g_wifi_connected_ms - g_wifi_connect_start_ms)) + "\n";
  } else {
    g_wifi_diag += "final connected=0 total_ms=" + String((unsigned long)(g_wifi_connected_ms - g_wifi_connect_start_ms)) + "\n";
  }
  update_boot_status_ui(true);
  lv_timer_handler();
  configureMqttServer();
  mqtt.setKeepAlive(30);
  mqtt.setCleanSession(true);
  mqtt.onConnect(onMqttConnect);
  mqtt.onDisconnect(onMqttDisconnect);
  mqtt.onMessage(onMqttMessage);
  // 고유 clientId는 최초 연결 전에 설정해야 함(브로커 즉시 종료 방지)
  // setClientId()는 포인터만 저장(_clientId = clientId)하고 복사하지 않으므로
  // 버퍼 수명이 프로그램 전체여야 한다. 지역 변수로 두면 setup() 종료/재연결 시
  // 스택이 덮여 clientId가 깨지고("2","U" 등), 같은 깨진 값을 가진 기기끼리
  // session takeover 핑퐁이 발생해 등원 리스트를 못 불러오는 버그가 생긴다.
  static char cid[40];
  {
    uint64_t mac = ESP.getEfuseMac();
    snprintf(cid, sizeof(cid), "m5-%llx", (unsigned long long)mac);
    mqtt.setClientId(cid);
    Serial.print("ClientId: "); Serial.println(cid);
  }
  // LWT: offline retained (버퍼에 영속 저장하여 수명 문제 방지)
  snprintf(willPayloadBuf, sizeof(willPayloadBuf), "{\"online\":false,\"at\":\"\"}");
  snprintf(willTopicBuf, sizeof(willTopicBuf), "academies/%s/devices/%s/presence", academyId.c_str(), deviceId.c_str());
  mqtt.setWill(willTopicBuf, 1, true, willPayloadBuf, strlen(willPayloadBuf));
  start_mqtt_connect("setup");
  update_boot_status_ui(true);
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

  // [HB] 진단용 하트비트: loop() 생존 여부로 "멈춤"이 진짜 hang(영구 정지)인지
  // 단순 데이터 대기(렌더는 도는데 변화만 없음)인지 구분한다.
  {
    static uint32_t s_hb_last = 0;
    if (s_hb_last == 0 || (nowTick - s_hb_last) >= 3000) {
      s_hb_last = nowTick;
      Serial.printf("[HB] up=%lus heap=%u sid=%d srecv=%d ready=%d mqtt=%d\n",
                    (unsigned long)(nowTick / 1000),
                    (unsigned)esp_get_free_heap_size(),
                    studentId.length() > 0 ? 1 : 0,
                    g_students_received ? 1 : 0,
                    g_first_ui_data_ready ? 1 : 0,
                    mqtt.connected() ? 1 : 0);
      Serial.flush();
    }
  }

  bool wifiNowConnected = WiFi.status() == WL_CONNECTED;
  if (wifiNowConnected && (!g_wifi_loop_connected || g_wifi_connected_ms == 0)) {
    g_wifi_connected_ms = nowTick;
    g_wifi_loop_connected = true;
    Serial.printf("[WiFi] loop connected ip=%s rssi=%d bssid=%s ch=%d\n",
                  WiFi.localIP().toString().c_str(),
                  (int)WiFi.RSSI(),
                  WiFi.BSSIDstr().c_str(),
                  WiFi.channel());
    if (!mqtt.connected() && nextMqttReconnectMs == 0) {
      nextMqttReconnectMs = nowTick + 1000;
    }
  } else if (!wifiNowConnected && g_wifi_loop_connected) {
    g_wifi_loop_connected = false;
    g_wifi_connected_ms = 0;
    g_mqtt_connect_in_flight = false;
    g_mqtt_connect_attempt_ms = 0;
    nextMqttReconnectMs = nowTick + 5000;
    Serial.println("[WiFi] loop disconnected -> wait for reconnect");
  }
  update_boot_status_ui(false);

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
      JsonObject meta = doc["meta"].as<JsonObject>();
      const char* syncFp = meta["sync_fp"] | "";
      const char* source = meta["source"] | "";
      const char* metaStudentId = meta["student_id"] | "";
      const unsigned long syncSeq = meta["sync_seq"] | 0;
      Serial.printf("[M5SYNC][apply] device=%s student=%s meta_student=%s sync_seq=%lu sync_fp=%s source=%s groups=%u len=%u\n",
                    deviceId.c_str(),
                    studentId.c_str(),
                    metaStudentId,
                    syncSeq,
                    syncFp,
                    source,
                    (unsigned)arr.size(),
                    (unsigned)json_copy.length());
      ui_port_update_homeworks(arr);
      g_first_ui_data_ready = true;
      g_restored_binding_guard_active = false;
      publish_homeworks_sync_ack(meta, (unsigned)arr.size());
    } else {
      Serial.printf("[M5SYNC][parse_error] device=%s student=%s err=%s len=%u\n",
                    deviceId.c_str(),
                    studentId.c_str(),
                    err.c_str(),
                    (unsigned)json_copy.length());
    }
  }

  // Deferred UI work from MQTT (async-tcp) task, run here on the LVGL thread.
  if (g_bind_ack_pending) {
    bool ok; char reason[sizeof(g_bind_ack_reason)]; int attemptsLeft; int lockedSeconds;
    portENTER_CRITICAL(&g_hw_mux);
    ok = g_bind_ack_ok;
    strncpy(reason, g_bind_ack_reason, sizeof(reason));
    reason[sizeof(reason) - 1] = '\0';
    attemptsLeft = g_bind_ack_attempts_left;
    lockedSeconds = g_bind_ack_locked_seconds;
    g_bind_ack_pending = false;
    portEXIT_CRITICAL(&g_hw_mux);
    ui_port_on_bind_ack(ok, reason, attemptsLeft, lockedSeconds);
  }

  if (g_students_pending) {
    String json_copy;
    portENTER_CRITICAL(&g_hw_mux);
    json_copy = g_students_pending_json;
    g_students_pending_json.remove(0);
    g_students_pending = false;
    portEXIT_CRITICAL(&g_hw_mux);
    if (json_copy.length() > 0) {
      DynamicJsonDocument doc(json_copy.length() + 2048);
      DeserializationError err = deserializeJson(doc, json_copy.c_str(), json_copy.length());
      if (err) {
        Serial.print("students_today parse error: "); Serial.println(err.c_str());
      } else {
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
        g_students_received = true;
        g_first_ui_data_ready = true;
        if (!g_list_diag_sent && mqtt.connected()) {
          g_list_diag_sent = true;
          String diag;
          uint32_t nowMs = millis();
          diag += "list_today_received=1\n";
          diag += "list_today_count=" + String((int)arr.size()) + "\n";
          if (g_last_list_request_ms > 0 && nowMs >= g_last_list_request_ms) {
            diag += "list_today_after_request_ms=" + String((unsigned long)(nowMs - g_last_list_request_ms)) + "\n";
          }
          diag += "list_today_after_mqtt_ms=" + String(g_last_mqtt_connect_ms > 0 && nowMs >= g_last_mqtt_connect_ms ? (unsigned long)(nowMs - g_last_mqtt_connect_ms) : 0UL) + "\n";
          String diagTopic = String("academies/") + academyId + "/devices/" + deviceId + "/diag";
          mqtt.publish(diagTopic.c_str(), 1, false, diag.c_str());
          Serial.println("[LIST-DIAG] published:\n" + diag);
        }
      }
    }
  }

  if (g_student_info_pending) {
    String json_copy;
    portENTER_CRITICAL(&g_hw_mux);
    json_copy = g_student_info_pending_json;
    g_student_info_pending_json.remove(0);
    g_student_info_pending = false;
    portEXIT_CRITICAL(&g_hw_mux);
    if (json_copy.length() > 0) {
      DynamicJsonDocument doc(json_copy.length() + 1024);
      DeserializationError err = deserializeJson(doc, json_copy.c_str(), json_copy.length());
      if (!err && doc.containsKey("info")) {
        JsonObject info = doc["info"].as<JsonObject>();
        ui_port_update_student_info(info);
        g_first_ui_data_ready = true;
        g_restored_binding_guard_active = false;
      }
    }
  }

  if (g_force_unbind_pending) {
    portENTER_CRITICAL(&g_hw_mux);
    g_force_unbind_pending = false;
    portEXIT_CRITICAL(&g_hw_mux);
    fw_clear_local_binding_state();
    ui_port_force_unbind();
    g_restored_binding_guard_active = false;
    g_restored_binding_guard_start_ms = 0;
  }

  handle_bind_day_expiry(nowTick);

  if (g_restored_binding_guard_active && studentId.length() > 0
      && !g_first_ui_data_ready && g_restored_binding_guard_start_ms > 0) {
    uint32_t ageMs = (nowTick >= g_restored_binding_guard_start_ms)
        ? (nowTick - g_restored_binding_guard_start_ms)
        : 0;
    if (ageMs >= RESTORED_BINDING_DATA_TIMEOUT_MS) {
      Serial.printf("[BIND][GUARD] restored binding stale %lums -> clear local binding and list_today\n",
                    (unsigned long)ageMs);
      g_restored_binding_guard_active = false;
      g_restored_binding_guard_start_ms = 0;
      g_students_received = false;
      g_first_ui_data_ready = false;
      g_last_list_request_ms = 0;
      fw_clear_local_binding_state();
      ui_port_force_unbind();
    }
  }

  lv_timer_handler();
  // 첫 데이터(학생 리스트/학생 정보/과제) 수신 전에는 절전 진입을 막아
  // "연결 중" 상태가 빈 화면/꺼진 화면처럼 보이지 않게 한다.
  if (!g_first_ui_data_ready) {
    screensaver_keep_awake();
  }
  screensaver_poll();
  screensaver_check_shake();
  
  // Safe vibration handling (3 second interval) using PMIC vibration (LDO3/DLDO1)
  static uint32_t lastVibMs = 0;
  // 주기 20% 감소: 3000ms -> 2400ms
  if ((g_should_vibrate_phase4 || g_should_vibrate_test_end) && nowTick - lastVibMs >= 2400) {
    Serial.println("[VIB] setVibration: pulse start");
    screensaver_dismiss();
    M5.Power.setVibration(ALERT_VIBRATION_STRENGTH);
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
  handle_mqtt_connect_stall(now);
  if (WiFi.status() == WL_CONNECTED && !mqtt.connected() && nextMqttReconnectMs && now >= nextMqttReconnectMs) {
    nextMqttReconnectMs = 0;
    start_mqtt_connect("reconnect_timer");
  }

  if (is_group_cmd_v2_enabled() && g_group_transition_pending && g_group_transition_pending_since_ms > 0) {
    uint32_t pendingAge = (now >= g_group_transition_pending_since_ms)
        ? (now - g_group_transition_pending_since_ms)
        : 0;
    if (pendingAge >= GROUP_CMD_V2_ACK_TIMEOUT_MS) {
      clear_group_transition_pending("timeout", true);
    }
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

  // 미바인딩(학생 리스트) 화면 워치독: 연결됐는데 학생 리스트가 아직 안 왔으면
  // 일정 주기로 list_today를 재요청한다(초기 요청 유실/타이밍 누락 대비).
  if (mqtt.connected() && studentId.length() == 0 && !g_students_received) {
    if (g_last_list_request_ms == 0 || (now - g_last_list_request_ms) >= LIST_REQUEST_RETRY_MS) {
      Serial.println("[MQTT][WATCHDOG] students list not received -> re-request list_today");
      fw_request_list_today();
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


