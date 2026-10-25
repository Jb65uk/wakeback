// Bluetooth LE: the way the app talks to the puck without any WiFi. One service, two characteristics:
//
//   command  (write)        a line: "status" | "set k=v&k=v" | "level" | "orient 1|2" | "rec start|stop" |
//                           "upload" | "sleep" | "reboot" | "ota begin <bytes>" | "ota end"
//   reply    (notify/read)  the answer, JSON for status, {"ok":true,"msg":"…"} or {"ok":false,"msg":"…"} otherwise.
//                           A long reply (status is ~1 KB) is sent in MTU-sized chunks; the app joins them until it
//                           has a complete JSON object.
//   ota      (write, no response)   raw firmware bytes after "ota begin", in order; "ota end" finishes and restarts.
//
// Advertised as "WakeBack puck N" with the service UUID, so the app can list every puck nearby.
// Nothing here changes what the web page does: both call the same functions in main.cpp.
#pragma once
#include <NimBLEDevice.h>

static const char *BLE_SVC = "7a4e0001-9b9d-4a3f-8e1a-3c2b1d0a5f01";
static const char *BLE_CMD = "7a4e0002-9b9d-4a3f-8e1a-3c2b1d0a5f01";
static const char *BLE_RSP = "7a4e0003-9b9d-4a3f-8e1a-3c2b1d0a5f01";
static const char *BLE_OTA = "7a4e0004-9b9d-4a3f-8e1a-3c2b1d0a5f01";

// main.cpp provides these (declared here so ble.h can be included near the top)
static String statusJson();
static String applySettings(const String &form);   // "k=v&k=v" as the web page sends; returns a message
static void calLevel();
static bool setOrientation(int o);
static void startRecording(bool manual);
static void stopRecording(const char *why);
static void goToSleep(const char *why);
static void wantDockNow();
static bool otaBegin(size_t bytes);
static bool otaWrite(const uint8_t *data, size_t len);
static bool otaEnd();
static void bleNote(const char *what);              // a line on the serial monitor

static NimBLEServer *bleServer = nullptr;
static NimBLECharacteristic *bleRsp = nullptr;
static bool bleConnected = false;
static uint32_t bleLastActivity = 0;
static size_t otaExpected = 0, otaGot = 0;

static String jsonMsg(bool ok, const String &msg) {
  String m = msg; m.replace("\\", "\\\\"); m.replace("\"", "\\\"");
  return String("{\"ok\":") + (ok ? "true" : "false") + ",\"msg\":\"" + m + "\"}";
}

// send a reply in chunks the link can carry (MTU minus 3), ending with a newline so the app knows it's complete
static void bleReply(const String &s) {
  if (!bleRsp || !bleConnected) return;
  const size_t mtu = bleServer->getPeerMTU(bleServer->getPeerInfo(0).getConnHandle());
  const size_t chunk = mtu > 23 ? mtu - 3 : 20;
  String out = s + "\n";
  for (size_t i = 0; i < out.length(); i += chunk) {
    bleRsp->setValue((uint8_t *)out.c_str() + i, min(chunk, out.length() - i));
    bleRsp->notify();
    delay(8);                                       // let the stack drain; without it chunks get dropped at 1 KB
  }
}

static void bleCommand(const String &line) {
  bleLastActivity = millis();
  String cmd = line; cmd.trim();
  const int sp = cmd.indexOf(' ');
  const String op = sp < 0 ? cmd : cmd.substring(0, sp);
  const String arg = sp < 0 ? "" : cmd.substring(sp + 1);
  bleNote(op.c_str());
  if (op == "status") bleReply(statusJson());
  else if (op == "set") bleReply(jsonMsg(true, applySettings(arg)));
  else if (op == "level") { calLevel(); bleReply(jsonMsg(true, "Level set: heel and pitch read 0 here.")); }
  else if (op == "orient") { const int o = arg.toInt(); bleReply(setOrientation(o) ? jsonMsg(true, o == 1 ? "Mounted on deck." : "Mounted under the thwart.") : jsonMsg(false, "1 (deck) or 2 (thwart)")); }
  else if (op == "rec") { if (arg == "start") startRecording(true); else stopRecording("app"); bleReply(jsonMsg(true, arg == "start" ? "Recording." : "Stopped.")); }
  else if (op == "upload") { wantDockNow(); bleReply(jsonMsg(true, "Looking for the hotspot now.")); }
  else if (op == "sleep") { bleReply(jsonMsg(true, "Sleeping.")); delay(300); goToSleep("app"); }
  else if (op == "reboot") { bleReply(jsonMsg(true, "Restarting.")); delay(300); ESP.restart(); }
  else if (op == "ota") {
    if (arg.startsWith("begin ")) {
      otaExpected = arg.substring(6).toInt(); otaGot = 0;
      bleReply(otaBegin(otaExpected) ? jsonMsg(true, "Ready for " + String(otaExpected) + " bytes.") : jsonMsg(false, "Couldn't start the update."));
    } else if (arg == "end") {
      const bool ok = otaGot == otaExpected && otaEnd();
      bleReply(ok ? jsonMsg(true, "Firmware written. Restarting.") : jsonMsg(false, "Update failed: got " + String(otaGot) + " of " + String(otaExpected) + " bytes."));
      if (ok) { delay(500); ESP.restart(); }
    } else if (arg == "status") bleReply(String("{\"ok\":true,\"got\":") + otaGot + ",\"expected\":" + otaExpected + "}");
    else bleReply(jsonMsg(false, "ota begin <bytes> | ota end | ota status"));
  }
  else bleReply(jsonMsg(false, "Unknown command: " + op));
}

class BleCmdCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &) override { bleCommand(String(c->getValue().c_str())); }
};
class BleOtaCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &) override {
    bleLastActivity = millis();
    const std::string &v = c->getValue();
    if (otaExpected && otaWrite((const uint8_t *)v.data(), v.size())) otaGot += v.size();
  }
};
class BleServerCb : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *, NimBLEConnInfo &) override { bleConnected = true; bleLastActivity = millis(); bleNote("connected"); }
  void onDisconnect(NimBLEServer *, NimBLEConnInfo &, int) override {
    bleConnected = false; otaExpected = 0; bleNote("disconnected");
    NimBLEDevice::startAdvertising();
  }
};

static void bleStart(int puck) {
  char name[24]; snprintf(name, sizeof name, "WakeBack puck %d", puck);
  NimBLEDevice::init(name);
  NimBLEDevice::setPower(ESP_PWR_LVL_P6);
  NimBLEDevice::setMTU(247);
  bleServer = NimBLEDevice::createServer();
  bleServer->setCallbacks(new BleServerCb());
  NimBLEService *svc = bleServer->createService(BLE_SVC);
  NimBLECharacteristic *cmd = svc->createCharacteristic(BLE_CMD, NIMBLE_PROPERTY::WRITE);
  cmd->setCallbacks(new BleCmdCb());
  bleRsp = svc->createCharacteristic(BLE_RSP, NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ);
  NimBLECharacteristic *ota = svc->createCharacteristic(BLE_OTA, NIMBLE_PROPERTY::WRITE_NR);
  ota->setCallbacks(new BleOtaCb());
  svc->start();
  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(BLE_SVC);
  adv->setName(name);
  adv->start();
}

static void bleSetName(int puck) {       // the puck number changed: advertise the new name
  char name[24]; snprintf(name, sizeof name, "WakeBack puck %d", puck);
  NimBLEDevice::setDeviceName(name);
  NimBLEDevice::getAdvertising()->setName(name);
}

static void bleStop() { NimBLEDevice::deinit(true); bleServer = nullptr; bleRsp = nullptr; bleConnected = false; }
