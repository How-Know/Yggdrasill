#include <M5Unified.h>
#include <WiFi.h>
#include <AsyncMqttClient.h>
#include <ArduinoJson.h>

// ENV placeholders (replace via build flags or secrets)
static const char* WIFI_SSID = "YOUR_WIFI";
static const char* WIFI_PASS = "YOUR_PASS";
static const char* MQTT_HOST = "broker.example.com";
static const uint16_t MQTT_PORT = 8883; // use TLS capable lib if needed
static String academyId = "academy-uuid";
static String studentId = "student-id";
static String deviceId = "m5-001";

AsyncMqttClient mqtt;
String ackFilterPrefix;
String todayListTopic;
String homeworksTopic;

void onMqttConnect(bool sessionPresent) {
  (void)sessionPresent;
  ackFilterPrefix = String("academies/") + academyId + "/ack/";
  String ackTopic = ackFilterPrefix + "+";
  mqtt.subscribe(ackTopic.c_str(), 1);
  todayListTopic = String("academies/") + academyId + "/devices/" + deviceId + "/students_today";
  mqtt.subscribe(todayListTopic.c_str(), 1);
  homeworksTopic = String("academies/") + academyId + "/devices/" + deviceId + "/homeworks";
  mqtt.subscribe(homeworksTopic.c_str(), 1);
  M5.Display.println("MQTT connected & subscribed");
}

void onMqttMessage(char* topic, char* payload, AsyncMqttClientMessageProperties properties, size_t len, size_t index, size_t total) {
  (void)properties; (void)index; (void)total;
  String t = String(topic);
  if (t.startsWith(ackFilterPrefix)) {
    String body; body.reserve(len + 1);
    for (size_t i = 0; i < len; ++i) body += (char)payload[i];
    M5.Display.fillRect(0, 30, 320, 20, BLACK);
    M5.Display.setCursor(0, 30);
    M5.Display.printf("ACK: %s", body.c_str());
  }
  if (t == todayListTopic) {
    DynamicJsonDocument doc(2048);
    DeserializationError err = deserializeJson(doc, payload, len);
    if (!err) {
      M5.Display.fillRect(0, 60, 320, 180, BLACK);
      M5.Display.setCursor(0, 60);
      M5.Display.println("오늘 등원 예정:");
      JsonArray arr = doc["students"].as<JsonArray>();
      int y = 80;
      for (JsonObject s : arr) {
        const char* name = s["name"] | "";
        M5.Display.setCursor(0, y); M5.Display.println(name);
        y += 16; if (y > 220) break;
      }
    }
  }
  if (t == homeworksTopic) {
    DynamicJsonDocument doc(4096);
    DeserializationError err = deserializeJson(doc, payload, len);
    if (!err) {
      M5.Display.fillRect(0, 60, 320, 180, BLACK);
      M5.Display.setCursor(0, 60);
      M5.Display.println("과제 목록:");
      JsonArray arr = doc["items"].as<JsonArray>();
      int y = 80;
      for (JsonObject it : arr) {
        const char* title = it["title"] | "";
        int phase = it["phase"] | 1;
        // 간단 표기: [수행/대기/제출/확인]
        const char* phaseTxt = phase==2?"수행":(phase==3?"제출":(phase==4?"확인":"대기"));
        M5.Display.setCursor(0, y); M5.Display.printf("[%s] %s\n", phaseTxt, title);
        y += 16; if (y > 220) break;
      }
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

void setup() {
  auto cfg = M5.config(); M5.begin(cfg);
  M5.Display.setTextSize(2);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) { delay(200); }
  mqtt.setServer(MQTT_HOST, MQTT_PORT);
  mqtt.setKeepAlive(30);
  mqtt.onConnect(onMqttConnect);
  mqtt.onMessage(onMqttMessage);
  // LWT: offline retained
  {
    DynamicJsonDocument doc(128);
    doc["online"] = false;
    doc["at"] = "";
    String willPayload; serializeJson(doc, willPayload);
    String willTopic = String("academies/") + academyId + "/devices/" + deviceId + "/presence";
    mqtt.setWill(willTopic.c_str(), 1, true, willPayload.c_str(), willPayload.length());
  }
  mqtt.connect();
  M5.Display.println("MQTT connecting...");
}

void loop() {
  M5.update();
  // Example: A button to submit, B to confirm, C to wait
  if (M5.BtnA.wasPressed()) { sendCommand("start", "item-1"); }
  if (M5.BtnB.wasPressed()) { sendCommand("submit", "item-1"); }
  if (M5.BtnC.wasPressed()) { sendCommand("wait", "item-1"); }

  // Periodic online retained presence
  static uint32_t lastPresence = 0;
  uint32_t now = millis();
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


