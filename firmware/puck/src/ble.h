// Bluetooth LE: the only way anything talks to the puck. One service, four characteristics:
//
//   command  (write)        a line: "hello" | "auth <hmac-hex>" | "status" | "set k=v&k=v" (puck, key, autorec, autooff, rate=1|2|5|10, stopmin=2..60, sleepmin=5..240) | "level" | "orient 1|2" |
//                           "flip" | "twist <deg>" | "calreset" | "rec start|stop" | "tracks" | "get <name> [offset]" | "done <name>" | "erase" | "sleep" | "reboot" |
//                           "ota begin <bytes>" | "ota status" | "ota end"
//   reply    (notify/read)  the answer, JSON, ending in "\n". A long reply (status is ~1 KB) goes in MTU-sized chunks;
//                           the app joins them until it sees the newline.
//   data     (notify)       the raw bytes of a track while a "get" runs; the "get" reply follows with the byte count,
//                           the CRC-32 of what was sent and of the whole file, so the app can check it got the lot
//                           (and ask again from an offset if not).
//   ota      (write, no response)   raw firmware bytes after "ota begin", in order; "ota end" finishes and restarts.
//
// Advertised as "WakeBack puck N" (name in the scan response: the 128-bit service UUID fills the 31-byte advert) with
// 3 bytes of manufacturer data: the first two bytes of SHA-256 of the puck's key (00 00 while it has no key), then how
// many finished tracks are waiting. The app only lists pucks whose hash matches a key it holds, so a club full of pucks
// shows you just yours, and it only bothers connecting by itself when there's something to fetch.
//
// Who may talk: the puck holds a key the server issued to its owner's account, and the owner's app holds the same key.
// After "hello" (which carries a fresh random nonce) the app must send "auth" = HMAC-SHA256(key, nonce) in hex. Until
// it does, every other command is refused and the link is dropped. The key itself never goes over the air.
// Pairing window: with no key at all, or for ten minutes after the button is held 6 s, "set" is accepted without auth
// so an app can give the puck its key (and number). Setting a different key to the one it had erases the tracks.
//
// Commands run on loop(), not on the NimBLE host task: a write just parks the line, blePoll() runs it. The host task
// has a 4 KB stack by default (8 KB here, platformio.ini) and statusJson() alone overflows it, and the GPS, IMU and
// flash belong to loop().
#pragma once
#include <NimBLEDevice.h>
#include <mbedtls/md.h>
#include <esp_system.h>                       // esp_fill_random

static const char *BLE_SVC = "7a4e0001-9b9d-4a3f-8e1a-3c2b1d0a5f01";
static const char *BLE_CMD = "7a4e0002-9b9d-4a3f-8e1a-3c2b1d0a5f01";
static const char *BLE_RSP = "7a4e0003-9b9d-4a3f-8e1a-3c2b1d0a5f01";
static const char *BLE_OTA = "7a4e0004-9b9d-4a3f-8e1a-3c2b1d0a5f01";
static const char *BLE_DAT = "7a4e0005-9b9d-4a3f-8e1a-3c2b1d0a5f01";

// main.cpp provides these (declared here so ble.h can be included near the top)
static String statusJson();
static String tracksJson();
static String applySettings(const String &form, bool &keyChanged);
static bool pairingOpen();
static void calLevel();
static void calFlipHeel();
static void calReset();
static void setTwist(float deg);
static bool setOrientation(int o);
static void startRecording(bool manual);
static void stopRecording(const char *why);
static bool deleteTrack(const String &name);
static void eraseTracks(const char *why);
static bool streamTrack(const String &name, size_t offset, size_t &total, uint32_t &crc, uint32_t &crcFile);   // sends the bytes with bleData()
static void goToSleep(const char *why);
static bool otaBegin(size_t bytes);
static bool otaWrite(const uint8_t *data, size_t len);
static bool otaEnd();
static void bleNote(const char *what);              // a line on the serial monitor
static void bleAuthed();                            // the app proved it holds the key (confirms a new firmware, etc.)
// S (settings) and FW are defined in main.cpp before this header is included

static NimBLEServer *bleServer = nullptr;
static NimBLECharacteristic *bleRsp = nullptr, *bleDat = nullptr;
static bool bleConnected = false, bleIsAuthed = false;
static uint16_t bleConn = 0;
static uint32_t bleLastActivity = 0;
static uint8_t bleNonce[16];
static size_t otaExpected = 0, otaGot = 0;

static String jsonMsg(bool ok, const String &msg) {
  String m = msg; m.replace("\\", "\\\\"); m.replace("\"", "\\\"");
  return String("{\"ok\":") + (ok ? "true" : "false") + ",\"msg\":\"" + m + "\"}";
}
static String hex(const uint8_t *b, size_t n) {
  static const char *H = "0123456789abcdef";
  String s; s.reserve(n * 2);
  for (size_t i = 0; i < n; i++) { s += H[b[i] >> 4]; s += H[b[i] & 15]; }
  return s;
}
static int unhex(const String &s, uint8_t *out, size_t max) {
  if (s.length() % 2) return -1;
  size_t n = 0;
  for (size_t i = 0; i + 1 < s.length() && n < max; i += 2) {
    char *e; char two[3] = {s[i], s[i + 1], 0};
    out[n++] = (uint8_t)strtol(two, &e, 16);
    if (*e) return -1;
  }
  return (int)n;
}
static size_t bleChunk() {
  const size_t mtu = bleServer ? bleServer->getPeerMTU(bleConn) : 23;
  return mtu > 23 ? mtu - 3 : 20;
}

// the first two bytes of SHA-256 of the key: the owner hash the advert carries
static void ownerHash(const String &key, uint8_t out[2]) {
  if (!key.length()) { out[0] = out[1] = 0; return; }
  uint8_t d[32];
  mbedtls_md(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), (const uint8_t *)key.c_str(), key.length(), d);
  out[0] = d[0]; out[1] = d[1];
}

// send a reply in chunks the link can carry, ending with a newline so the app knows it's complete
static void bleReply(const String &s) {
  if (!bleRsp || !bleConnected) return;
  const size_t chunk = bleChunk();
  String out = s + "\n";
  for (size_t i = 0; i < out.length(); i += chunk) {
    bleRsp->setValue((uint8_t *)out.c_str() + i, min(chunk, out.length() - i));
    bleRsp->notify();
    delay(8);                                       // let the stack drain; without it chunks get dropped at 1 KB
  }
}
// one chunk of track data; waits for a free buffer, gives up after half a second (the link has gone)
static bool bleData(const uint8_t *b, size_t n) {
  if (!bleDat || !bleConnected) return false;
  for (int tries = 0; tries < 250; tries++) {
    if (bleDat->notify(b, n)) return true;
    delay(2);
    if (!bleConnected) return false;
  }
  return false;
}

static void bleDrop(const char *why) {              // refuse and hang up
  bleReply(jsonMsg(false, why));
  delay(100);
  if (bleServer && bleConnected) bleServer->disconnect(bleConn);
}

static void bleCommand(const String &line) {
  bleLastActivity = millis();
  String cmd = line; cmd.trim();
  const int sp = cmd.indexOf(' ');
  const String op = sp < 0 ? cmd : cmd.substring(0, sp);
  String arg = sp < 0 ? "" : cmd.substring(sp + 1); arg.trim();
  bleNote(op.c_str());

  if (op == "hello") {                              // who are you, and here's a nonce to prove you hold my key
    esp_fill_random(bleNonce, sizeof bleNonce);
    bleReply(String("{\"ok\":true,\"puck\":") + S.puck + ",\"fw\":\"" + FW + "\",\"nonce\":\"" + hex(bleNonce, 16) + "\"," +
             "\"locked\":" + (S.key.length() ? "true" : "false") + ",\"pairing\":" + (pairingOpen() ? "true" : "false") + "}");
    return;
  }
  if (op == "auth") {
    uint8_t given[32], want[32];
    if (!S.key.length()) { bleReply(jsonMsg(false, "This puck has no key yet: set it up first.")); return; }
    if (unhex(arg, given, 32) != 32) { bleDrop("Bad auth."); return; }
    mbedtls_md_hmac(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), (const uint8_t *)S.key.c_str(), S.key.length(), bleNonce, 16, want);
    uint8_t diff = 0; for (int i = 0; i < 32; i++) diff |= given[i] ^ want[i];
    esp_fill_random(bleNonce, sizeof bleNonce);     // one go per nonce
    if (diff) { bleNote("auth failed"); bleDrop("Not your puck."); return; }
    bleIsAuthed = true; bleAuthed();
    bleReply(jsonMsg(true, "Hello."));
    return;
  }
  // the pairing window lets an app hand over a key without one; everything else needs auth once a key is set
  if (op == "set" && pairingOpen()) {
    bool keyChanged = false;
    const String msg = applySettings(arg, keyChanged);
    if (keyChanged) bleIsAuthed = true;             // it just gave us the key it holds
    bleReply(jsonMsg(true, msg));
    return;
  }
  if (S.key.length() && !bleIsAuthed) { bleDrop("Not your puck."); return; }

  if (op == "status") bleReply(statusJson());
  else if (op == "set") { bool kc; bleReply(jsonMsg(true, applySettings(arg, kc))); }
  else if (op == "level") { calLevel(); bleReply(jsonMsg(true, "Level set: heel and pitch read 0 here.")); }
  else if (op == "flip") { calFlipHeel(); bleReply(jsonMsg(true, "Heel sign flipped.")); }
  else if (op == "twist") { setTwist(arg.toFloat()); bleReply(jsonMsg(true, "Twist set.")); }
  else if (op == "calreset") { calReset(); bleReply(jsonMsg(true, "Calibration cleared.")); }
  else if (op == "orient") { const int o = arg.toInt(); bleReply(setOrientation(o) ? jsonMsg(true, o == 1 ? "Mounted on deck." : "Mounted under the thwart.") : jsonMsg(false, "1 (deck) or 2 (thwart)")); }
  else if (op == "rec") { if (arg == "start") startRecording(true); else stopRecording("app"); bleReply(jsonMsg(true, arg == "start" ? "Recording." : "Stopped.")); }
  else if (op == "tracks") bleReply(tracksJson());
  else if (op == "get") {
    const int sp2 = arg.indexOf(' ');
    const String name = sp2 < 0 ? arg : arg.substring(0, sp2);
    const size_t offset = sp2 < 0 ? 0 : (size_t)arg.substring(sp2 + 1).toInt();
    size_t total = 0; uint32_t crc = 0, crcFile = 0;
    if (streamTrack(name, offset, total, crc, crcFile))
      bleReply(String("{\"ok\":true,\"name\":\"") + name + "\",\"bytes\":" + (unsigned)total + ",\"offset\":" + (unsigned)offset + ",\"crc\":" + crc + ",\"crc_file\":" + crcFile + "}");
    else bleReply(jsonMsg(false, "Couldn't send that track."));
  }
  else if (op == "done") bleReply(deleteTrack(arg) ? jsonMsg(true, "Deleted.") : jsonMsg(false, "No such track."));
  else if (op == "erase") { eraseTracks("app"); bleReply(jsonMsg(true, "All tracks erased.")); }
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

// A command arrives on the NimBLE host task; the write just parks the line and loop() runs it via blePoll().
static String blePending;
static volatile bool bleHasPending = false;
class BleCmdCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &) override {
    if (bleHasPending) return;                    // one at a time; the app waits for each reply
    blePending = String(c->getValue().c_str()); bleHasPending = true;
  }
};
static void blePoll() {                           // called from loop()
  if (!bleHasPending) return;
  const String line = blePending; bleHasPending = false;
  bleCommand(line);
}
class BleOtaCb : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c, NimBLEConnInfo &) override {
    if (!bleIsAuthed) return;
    bleLastActivity = millis();
    const std::string &v = c->getValue();
    if (otaExpected && otaWrite((const uint8_t *)v.data(), v.size())) otaGot += v.size();
  }
};
class BleServerCb : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *s, NimBLEConnInfo &info) override {
    bleConnected = true; bleIsAuthed = false; bleConn = info.getConnHandle(); bleLastActivity = millis();
    esp_fill_random(bleNonce, sizeof bleNonce);
    s->updateConnParams(bleConn, 6, 12, 0, 400);  // 7.5-15 ms between packets: tracks and firmware move quickly
    bleNote("connected");
  }
  void onDisconnect(NimBLEServer *, NimBLEConnInfo &, int) override {
    bleConnected = false; bleIsAuthed = false; otaExpected = 0; bleNote("disconnected");
    NimBLEDevice::startAdvertising();
  }
};

static int blePendingAdvertised = -1;
static void bleAdvData(NimBLEAdvertising *adv, int puck, const String &key, int pending) {
  char name[24]; snprintf(name, sizeof name, "WakeBack puck %d", puck);
  uint8_t mfg[5] = {0xFF, 0xFF, 0, 0, (uint8_t)constrain(pending, 0, 255)};   // company id 0xFFFF (none), owner hash, tracks waiting
  ownerHash(key, mfg + 2);
  blePendingAdvertised = pending;
  NimBLEDevice::setDeviceName(name);
  adv->setManufacturerData(mfg, sizeof mfg);
  adv->setName(name);
}
static void bleStart(int puck, const String &key, int pending) {
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
  bleDat = svc->createCharacteristic(BLE_DAT, NIMBLE_PROPERTY::NOTIFY);
  NimBLECharacteristic *ota = svc->createCharacteristic(BLE_OTA, NIMBLE_PROPERTY::WRITE_NR);
  ota->setCallbacks(new BleOtaCb());
  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  adv->enableScanResponse(true);                  // the 128-bit UUID fills the 31-byte advert; the name goes in the scan response
  adv->addServiceUUID(BLE_SVC);
  adv->setMinInterval(160); adv->setMaxInterval(400);   // 100-250 ms: found within a second or two, cheap to keep up all day
  bleAdvData(adv, puck, key, pending);
  bleNote(adv->start() ? "advertising" : "advertising FAILED");
}
// the number, the key or the number of tracks waiting changed: advertise the new name, hash and count
static void bleAdvRefresh(int puck, const String &key, int pending) {
  if (!bleServer) return;
  NimBLEAdvertising *adv = NimBLEDevice::getAdvertising();
  adv->stop();
  bleAdvData(adv, puck, key, pending);
  if (!bleConnected) adv->start();                // while connected, onDisconnect starts it again
}
static void bleStop() { NimBLEDevice::deinit(true); bleServer = nullptr; bleRsp = nullptr; bleDat = nullptr; bleConnected = false; bleIsAuthed = false; }
