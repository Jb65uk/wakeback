// WakeBack puck firmware
// ----------------------
// The puck records a sail by itself (GPS at 5 Hz while moving, heel and pitch from the IMU) into flash, then hands the tracks
// to a dock: the club's dock Pi or the WakeBack app on a phone, over WiFi, exactly as docs/PHONE_DOCK.md says.
// It also puts up its own WiFi with a setup page (http://192.168.4.1/) for calibration, settings, tracks and
// firmware updates.
//
// Wiring (XIAO ESP32S3 on the carrier board, hardware/carrier/README.md):
//   GPS  (BE-880)   VCC 3V3, GND, GPS TX -> D7 (GPIO44), GPS RX -> D6 (GPIO43)
//   IMU  (BNO085)   VIN 3V3, GND, SDA -> D4 (GPIO5), SCL -> D5 (GPIO6)
//   LED             D3 (GPIO4) -> 330R -> LED -> GND
//   Battery sense   TP4056 OUT+ -> 100k -> A0 (GPIO1) -> 100k -> GND
//   Pad sense       Qi 5V       -> 100k -> A1 (GPIO2) -> 100k -> GND
//   Push button     D2 (GPIO3) -> switch -> GND
//   Ring LED        D9 (GPIO8) -> 100R -> ring LED+ ; ring LED- -> GND   (only if the button has one)
//
// The button and the LED patterns are in README.md (the one place they're written down).
//
// Serial monitor at 115200: type h for the few commands that are handy on the bench (q pauses the status line).

#include <Arduino.h>
#include <Wire.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WebServer.h>
#include <DNSServer.h>
#include <HTTPClient.h>
#include <Update.h>
#include <SparkFun_u-blox_GNSS_v3.h>
#include <Adafruit_BNO08x.h>
#include <esp_sleep.h>
#include <esp_ota_ops.h>
#include <driver/rtc_io.h>
#include "page.h"
#include "ble.h"

#ifndef WB_FW_VERSION
#define WB_FW_VERSION "dev"
#endif
static const char *FW = WB_FW_VERSION;

// Arduino-ESP32 confirms a freshly flashed image as good before setup() runs unless this says otherwise. We want
// the probation to really happen (a build that boots but can't talk to the dock should roll back), so hold it off:
// the image is confirmed in wifiTick after a good check-in, or in everySecond after two minutes with the sensors alive.
extern "C" bool verifyRollbackLater() { return true; }

// ---------- pins ----------
static const int PIN_GPS_RX = 44, PIN_GPS_TX = 43;
static const int PIN_SDA = 5, PIN_SCL = 6;
static const int PIN_LED = 4, PIN_RING = 8;
static const int PIN_BATT = 1, PIN_PAD = 2;
static const int PIN_BTN = 3;

// ---------- timing and thresholds ----------
static const uint32_t HOLD_SLEEP_MS = 2000, HOLD_SETUP_MS = 6000, WAKE_HOLD_MS = 300;
static const uint32_t AUTO_OFF_MS = 30UL * 60 * 1000;
static const uint32_t SETUP_IDLE_MS = 10UL * 60 * 1000;      // leave setup mode after this long with no page open
static const float    STILL_KN = 0.5f;                       // below this the boat counts as still
static const uint32_t PAD_HOLD_MS = 2UL * 60 * 60 * 1000;    // still "on the pad" this long after the Qi 5 V drops (full battery, pad in standby)
static const uint32_t PAD_HOLD_NO_IMU_MS = 10UL * 60 * 1000; // ...or this long if there's no IMU to tell us it was picked up
static const float    PAD_TILT_DEG = 8.0f;                   // tilted this much from how it lay on the pad = picked up
static const uint32_t STILL_FOR_MS = 20000;                  // still this long = "at rest", the start point is remembered
static const float    START_M = 30;                          // moved this far from rest = sailing, start recording
static const uint32_t START_MOVING_MS = 5000;                // ...and been above STILL_KN for this long: indoor GPS wander moves 30 m but never holds a speed
static const float    MOVE_M = 20;                           // while recording, must move this far every...
static const uint32_t STOP_AFTER_MS = 10UL * 60 * 1000;      // ...10 minutes, or the sail is over
static const uint32_t CHECKIN_MS = 30000;
static const uint32_t OFFPAD_RETRY_MS = 5UL * 60 * 1000, OFFPAD_TRY_FOR_MS = 25000;   // off the pad with tracks waiting: short tries
static const uint32_t FW_CHECK_MS = 60UL * 60 * 1000;
static const uint32_t FLASH_RESERVE = 96 * 1024;             // stop writing when this little is left
static const int      REC_HZ = 5;                            // points a second while moving (1 while still): plenty for a dinghy, about 4.5 h of sailing in 4.5 MB

static const char *TRK_DIR = "/trk";
static const int DOCK_PORT = 5000;

SFE_UBLOX_GNSS_SERIAL gnss;
Adafruit_BNO08x bno(-1);
Preferences prefs;
WebServer web(80);
DNSServer dns;

bool gpsOk = false, imuOk = false, fsOk = false;
uint32_t gpsBaud = 0;

// ---------- latest readings ----------
struct {
  uint8_t fix = 0, sats = 0;
  int32_t lat = 0, lon = 0;          // degrees * 1e7
  float sogKn = 0, cogDeg = 0, hAccM = 0;
  uint64_t tMs = 0;                  // UTC epoch ms from the GPS, 0 until it has date and time
  uint32_t pvtThisSecond = 0;
  float rateHz = 0;
  bool fresh = false;                // a new fix arrived since last looked
} gps;

struct {
  float upX = 0, upY = 0, upZ = 1;   // world "up" seen from the puck (from the game rotation vector)
  float headingX = NAN;              // compass heading of the puck's X axis (from the rotation vector, needs the magnetometer)
  uint8_t magStatus = 0;             // 0 unreliable .. 3 good
  float heel = 0, pitch = 0;         // boat frame, after mounting + level corrections
  float restUpZ = 0; int restN = 0;  // learning which way up
} imu;

// ---------- settings (kept in NVS) ----------
struct Settings {
  int puck = 1;
  String ssid = "wakeback", pass = "", key = "";
  float zeroHeel = 0, zeroPitch = 0, twist = 0;
  bool twistLearned = false, flipHeel = false;
  int orientation = 0;               // 0 unknown, 1 deck (IMU up), 2 under the thwart (IMU down)
  bool autoRec = true, autoOff = true;
  bool configured = false;           // someone has set it up (page or app): only then does the setup WiFi stay down at power-up
} S;

static const int NVS_SCHEMA = 1;     // bump when the meaning of a stored key changes

static void loadSettings() {
  prefs.begin("puck", false);
  // The bench firmware used the same NVS namespace with its own calibration keys (and an older puck firmware
  // kept a few more). The first boot of this firmware clears just those, so a stale zero or flip from the
  // breadboard days can't skew the heel. The WiFi settings and the puck number are kept.
  if (!prefs.isKey("wbv")) {
    static const char *const old[] = {"zh", "zp", "zr", "flip", "flipp", "twist", "twl", "orient", "swap", "atw"};
    for (const char *k : old) if (prefs.isKey(k)) prefs.remove(k);
    prefs.putInt("wbv", NVS_SCHEMA);
  }
  // "configured" used to be guessed from the ssid key being there; a puck set up before this flag existed stays set up
  if (!prefs.isKey("cfg") && prefs.isKey("ssid")) prefs.putBool("cfg", true);
  S.configured = prefs.getBool("cfg", false);
  S.puck = prefs.getInt("puck", 1);
  S.ssid = prefs.getString("ssid", "wakeback");
  S.pass = prefs.getString("pass", "");
  S.key = prefs.getString("key", "");
  S.zeroHeel = prefs.getFloat("zh", 0); S.zeroPitch = prefs.getFloat("zp", 0);
  S.twist = prefs.getFloat("twist", 0);
  S.twistLearned = prefs.getBool("twl", false);
  S.flipHeel = prefs.getBool("flip", false);
  S.orientation = prefs.getInt("orient", 0);
  S.autoRec = prefs.getBool("arec", true); S.autoOff = prefs.getBool("auto", true);
  if (prefs.isKey("rate")) prefs.remove("rate");       // the rate setting is gone: 5 Hz moving, 1 Hz still, always
}

static void saveSettings() {
  prefs.putInt("puck", S.puck);
  prefs.putString("ssid", S.ssid); prefs.putString("pass", S.pass); prefs.putString("key", S.key);
  prefs.putFloat("zh", S.zeroHeel); prefs.putFloat("zp", S.zeroPitch);
  prefs.putFloat("twist", S.twist);
  prefs.putBool("twl", S.twistLearned);
  prefs.putBool("flip", S.flipHeel);
  prefs.putInt("orient", S.orientation);
  prefs.putBool("arec", S.autoRec); prefs.putBool("auto", S.autoOff);
  if (S.configured) prefs.putBool("cfg", true);
}

// ---------- state ----------
bool onPad = false, battFull = false;
float battMv = 0;
uint32_t lastActive = 0;             // last movement, button press, command or page view: the auto-off clock
bool flashFull = false;

enum WifiMode { W_OFF, W_JOINING, W_DOCK, W_SETUP };
WifiMode wmode = W_OFF;
uint32_t wSince = 0, lastCheckin = 0, lastHello = 0, lastFwCheck = 0, lastOffPadTry = 0, setupLastSeen = 0, sailEnded = 0;
bool dockOk = false, wantLiftCheckin = false, uploading = false, webOn = false;
bool usbPlugged = false, usbSetupDone = false;   // on a USB lead the setup WiFi comes up by itself
bool dockRefused = false;                        // the dock answered 401/403: the key is wrong, retrying is pointless until it's set up again
uint32_t lastJoinOk = 0;                         // when a join + hello last worked, so a pad retry can be keen only while the dock is really about
static void webStart(); static void webStop(); static void pollButton();
bool appPendingVerify = false;

// how often to try the dock, by situation
static const uint32_t PAD_RETRY_MS = 60000;              // on the pad, dock seen recently: once a minute (radio off in between, so the pad can actually charge it)
static const uint32_t PAD_GPS_NAP_MS = 60000;
static const uint32_t HOLD_MS = 5UL * 60 * 1000;         // the app asked (in a check-in reply) to keep WiFi up: this long, checking in every 10 s
uint32_t holdUntil = 0;            // on the pad for this long = indoors on the charger: GPS to standby until it's lifted
static const uint32_t PAD_RETRY_SLOW_MS = 2UL * 60 * 1000;   // on the pad, dock not seen for a while: two minutes
static const uint32_t PAD_RECENT_MS = 10UL * 60 * 1000;  // "seen recently" = a join worked in the last ten minutes
static const uint32_t AFTER_SAIL_RETRY_MS = 60000, AFTER_SAIL_FOR_MS = 15UL * 60 * 1000;   // tracks waiting: every minute for 15 min after a sail, then OFFPAD_RETRY_MS
static const uint32_t JOIN_TIMEOUT_MS = 15000;           // give the hotspot this long to let us on
static const uint32_t HELLO_EVERY_MS = 5000, PAD_HELLO_FOR_MS = 30000;   // once joined, ask for the dock every 5 s, for this long on the pad (OFFPAD_TRY_FOR_MS off it)
static const uint32_t REFUSED_PAD_MS = 2UL * 60 * 1000, REFUSED_OFFPAD_MS = 10UL * 60 * 1000;   // after a 401/403, leave it alone this long

// the clock: epoch ms = millis() + clockOffset. GPS beats the dock.
int64_t clockOffset = 0; bool clockFromGps = false, clockSet = false;
static uint64_t nowMs() { return clockSet ? (uint64_t)((int64_t)millis() + clockOffset) : 0; }
static void setClock(uint64_t epochMs, bool fromGps) {
  if (clockFromGps && !fromGps) return;
  clockOffset = (int64_t)epochMs - (int64_t)millis(); clockSet = true; clockFromGps = fromGps;
}

// recording
bool recording = false;
File rec; String recName;
uint32_t recStarted = 0, recLines = 0, lastPointMs = 0, lastFlush = 0;
// where the boat was last at rest, to spot it moving off; and where it last was, to spot it stopping
bool haveRest = false; int32_t restLat = 0, restLon = 0; uint32_t stillSince = 0, movingSince = 0;
int32_t moveLat = 0, moveLon = 0; uint32_t lastMoveMs = 0;
// the minute before the boat moved off, so the start isn't lost
static const size_t PRE_BYTES = 40 * 1024;
char *pre = nullptr; size_t preHead = 0, preLen = 0;

// ---------- small helpers ----------
static int64_t daysFromCivil(int y, unsigned m, unsigned d) {   // Howard Hinnant's algorithm
  y -= m <= 2;
  const int64_t era = (y >= 0 ? y : y - 399) / 400;
  const unsigned yoe = (unsigned)(y - era * 400);
  const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + (int64_t)doe - 719468;
}
static void civilFromDays(int64_t z, int &y, unsigned &m, unsigned &d) {
  z += 719468;
  const int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  const unsigned doe = (unsigned)(z - era * 146097);
  const unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  const int64_t yy = (int64_t)yoe + era * 400;
  const unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  const unsigned mp = (5 * doy + 2) / 153;
  d = doy - (153 * mp + 2) / 5 + 1; m = mp < 10 ? mp + 3 : mp - 9; y = (int)(yy + (m <= 2));
}
static float wrap180(float a) { while (a > 180) a -= 360; while (a <= -180) a += 360; return a; }
static float distM(int32_t lat1, int32_t lon1, int32_t lat2, int32_t lon2) {
  const float dlat = (lat2 - lat1) * 1e-7f * 111320.0f;
  const float dlon = (lon2 - lon1) * 1e-7f * 111320.0f * cosf(lat1 * 1e-7f * DEG_TO_RAD);
  return sqrtf(dlat * dlat + dlon * dlon);
}
static float readMilliVolts(int pin) {
  uint32_t sum = 0;
  for (int i = 0; i < 8; i++) sum += analogReadMilliVolts(pin);
  return sum / 8.0f * 2.0f;            // undo the 100k/100k divider
}
static int batteryPct(float mv) {
  static const float V[] = {4200, 4100, 4000, 3900, 3800, 3750, 3700, 3650, 3600, 3500, 3300};
  static const int P[] = {100, 90, 78, 62, 45, 35, 22, 12, 6, 2, 0};
  if (mv >= V[0]) return 100;
  for (int i = 1; i < 11; i++)
    if (mv >= V[i]) return (int)(P[i] + (P[i - 1] - P[i]) * (mv - V[i]) / (V[i - 1] - V[i]));
  return 0;
}
static String jsonStr(const String &s) {     // escape for a JSON string
  String o; o.reserve(s.length() + 4);
  for (char c : s) { if (c == '"' || c == '\\') o += '\\'; if ((uint8_t)c < 32) continue; o += c; }
  return o;
}
// LittleFS has to walk the whole partition to count what's used (slow), so the figure is refreshed every 10 s, not on every ask
static size_t fsFree = 0, fsTotal = 0, fsUnmeasured = 0;   // fsUnmeasured: track bytes written since the last measure
static void measureFs() { if (fsOk) { fsTotal = LittleFS.totalBytes(); fsFree = fsTotal - LittleFS.usedBytes(); fsUnmeasured = 0; } }
static String baseName(File &f) { String n = f.name(); if (n.startsWith("/")) n = n.substring(n.lastIndexOf('/') + 1); return n; }
static String trackPath(const String &name) { return String(TRK_DIR) + "/" + name; }
// every track file in turn (not folders), by bare name and size; the callback mustn't delete while we walk the folder
template <typename F> static void forEachTrack(F fn) {
  File d = LittleFS.open(TRK_DIR);
  if (!d) return;
  for (File f = d.openNextFile(); f; f = d.openNextFile()) if (!f.isDirectory()) fn(baseName(f), (size_t)f.size());
  d.close();
}
static int nTracks = 0;                      // counted once a second and after changes, not every loop
static int countTracks() { int n = 0; forEachTrack([&](const String &, size_t) { n++; }); nTracks = n; return n; }
static int pendingCount() { return nTracks - (recording ? 1 : 0); }
// the names, one per line, so a caller can delete as it goes (deleting while walking the folder isn't safe)
static String trackNames() { String names; forEachTrack([&](const String &n, size_t) { names += n + "\n"; }); return names; }

// words for the status line, the check-in and the page, so they can't drift apart
static const char *B(bool b) { return b ? "true" : "false"; }
static const char *orientName() { return S.orientation == 1 ? "deck" : S.orientation == 2 ? "thwart" : "unknown"; }
static const char *chargeName() { return !onPad ? "not" : battFull ? "full" : "charging"; }
static const char *wifiName() { return wmode == W_SETUP ? "setup" : wmode == W_DOCK ? "dock" : wmode == W_JOINING ? "joining" : "off"; }

// ---------- GPS ----------
static bool startGps() {
  static const uint32_t bauds[] = {38400, 115200, 9600, 57600, 230400};
  Serial1.setRxBufferSize(4096);
  for (uint32_t b : bauds) {
    Serial1.begin(b, SERIAL_8N1, PIN_GPS_RX, PIN_GPS_TX);
    delay(50);
    if (gnss.begin(Serial1, 1200)) { gpsBaud = b; break; }
    Serial1.end();
  }
  if (!gpsBaud) return false;
  gnss.setUART1Output(COM_TYPE_UBX);
  gnss.setDynamicModel(DYN_MODEL_SEA);
  gnss.setNavigationFrequency(10);
  gnss.setAutoPVT(true);
  return true;
}

// On the pad the GPS is pointless (it's on a charger indoors) and it's the biggest draw after WiFi: with
// everything running the Qi pad could barely keep up and the battery didn't gain. So after a minute on the
// pad the GPS goes to standby, and any byte on its UART wakes it the moment the puck is lifted off.
bool gpsNapping = false;
static void gpsNap() {
  if (!gpsOk || gpsNapping) return;
  gnss.powerOffWithInterrupt(0, VAL_RXM_PMREQ_WAKEUPSOURCE_UARTRX);
  gpsNapping = true; gps.fix = 0; gps.sats = 0; gps.sogKn = 0;
  Serial.println("GPS resting while on the pad.");
}
static void gpsWake() {
  if (!gpsOk || !gpsNapping) return;
  Serial1.write(0xFF); delay(100);           // any byte wakes it; its settings are kept in RAM
  gnss.setNavigationFrequency(10);
  gpsNapping = false;
  Serial.println("GPS awake.");
}

static void pollGps() {
  if (!gpsOk || gpsNapping || !gnss.getPVT()) return;
  gps.fix = gnss.getFixType();
  gps.sats = gnss.getSIV();
  gps.lat = gnss.getLatitude();
  gps.lon = gnss.getLongitude();
  gps.sogKn = gnss.getGroundSpeed() / 1000.0f * 1.943844f;
  gps.cogDeg = gnss.getHeading() / 1e5f;
  gps.hAccM = gnss.getHorizontalAccEst() / 1000.0f;
  if (gnss.getDateValid() && gnss.getTimeValid()) {
    const int64_t days = daysFromCivil(gnss.getYear(), gnss.getMonth(), gnss.getDay());
    gps.tMs = (uint64_t)((days * 86400 + gnss.getHour() * 3600 + gnss.getMinute() * 60 + gnss.getSecond()) * 1000LL + gnss.getMillisecond());
    setClock(gps.tMs, true);
  }
  gps.pvtThisSecond++; gps.fresh = true;
  // the auto-off clock is kept going by onFix, once the speed has held: one jittery reading indoors must not keep the puck awake
}

// ---------- IMU ----------
static bool enableImuReports() {
  bool ok = bno.enableReport(SH2_GAME_ROTATION_VECTOR, 20000);        // 50 Hz, gyro + accel: heel and pitch
  bno.enableReport(SH2_ROTATION_VECTOR, 100000);                      // 10 Hz, with the magnetometer: heading, so the twist can be learnt
  return ok;
}
static bool startImu() {
  Wire.begin(PIN_SDA, PIN_SCL);
  Wire.setClock(100000);
  // the BNO085 is slow to wake after power-up and sometimes misses the first hello: ask a few times
  for (int i = 0; i < 5; i++) {
    if (bno.begin_I2C(BNO08x_I2CADDR_DEFAULT, &Wire)) return enableImuReports();
    delay(300);
  }
  return false;
}

// heel and pitch in the boat's frame from "up" seen in the puck's frame, the mounting twist and which way up it is
static void boatAngles() {
  const float t = S.twist * DEG_TO_RAD;
  const bool inv = S.orientation == 2;
  // the bow and starboard directions in the puck's own frame
  const float bowX = cosf(t), bowY = inv ? -sinf(t) : sinf(t);
  const float stbX = sinf(t), stbY = inv ? cosf(t) : -cosf(t);
  const float upZ = inv ? -imu.upZ : imu.upZ;
  const float upBow = imu.upX * bowX + imu.upY * bowY;
  const float upStb = imu.upX * stbX + imu.upY * stbY;
  float heel = atan2f(-upStb, upZ) * RAD_TO_DEG;        // + = heeled to starboard
  float pitch = atan2f(-upBow, upZ) * RAD_TO_DEG;       // + = bow up
  if (S.flipHeel) heel = -heel;
  imu.heel = wrap180(heel - S.zeroHeel);
  imu.pitch = wrap180(pitch - S.zeroPitch);
}

static void pollImu() {
  if (!imuOk) return;
  if (bno.wasReset()) enableImuReports();
  sh2_SensorValue_t v;
  while (bno.getSensorEvent(&v)) {
    if (v.sensorId == SH2_GAME_ROTATION_VECTOR) {
      const float w = v.un.gameRotationVector.real, x = v.un.gameRotationVector.i,
                  y = v.un.gameRotationVector.j, z = v.un.gameRotationVector.k;
      imu.upX = 2 * (x * z - w * y);
      imu.upY = 2 * (y * z + w * x);
      imu.upZ = 1 - 2 * (x * x + y * y);
    } else if (v.sensorId == SH2_ROTATION_VECTOR) {
      const float w = v.un.rotationVector.real, x = v.un.rotationVector.i,
                  y = v.un.rotationVector.j, z = v.un.rotationVector.k;
      // the puck's X axis in the world (east, north): first column of the rotation matrix
      const float east = 1 - 2 * (y * y + z * z), north = 2 * (x * y + w * z);
      imu.headingX = fmodf(atan2f(east, north) * RAD_TO_DEG + 360, 360);
      imu.magStatus = v.status & 3;
    }
  }
  boatAngles();
}

// the page and the serial monitor both calibrate, through these
static void calLevel() {          // the current heel and pitch (before zeroing) become the new zero
  S.zeroHeel = wrap180(S.zeroHeel + imu.heel); S.zeroPitch = wrap180(S.zeroPitch + imu.pitch); saveSettings();
}
static void calFlipHeel() {       // starboard reads as port: flip the sign (and the zero with it)
  S.flipHeel = !S.flipHeel; S.zeroHeel = -S.zeroHeel; saveSettings();
}

// which way up (at rest) and the mounting twist (while sailing straight): learnt in the background, once a second
static void learnMounting() {
  const bool still = gps.fix >= 2 ? gps.sogKn < STILL_KN : true;
  if (still) {
    imu.restUpZ += imu.upZ; imu.restN++;
    if (imu.restN >= 30) {                                    // half a minute still
      const float avg = imu.restUpZ / imu.restN;
      const int o = avg > 0.5f ? 1 : avg < -0.5f ? 2 : 0;
      if (o && o != S.orientation) { S.orientation = o; saveSettings(); }
      imu.restUpZ = 0; imu.restN = 0;
    }
  } else { imu.restUpZ = 0; imu.restN = 0; }

  static float lastCog = 0; static uint32_t lastSave = 0; static int goingFor = 0;
  // only a boat really under way counts: 2 kn or more for 15 s running, with a clean fix (GPS jitter on the bench can spike to 4 kn)
  const bool underWay = gps.fix >= 3 && gps.sogKn > 2.0f && gps.hAccM < 3;
  goingFor = underWay ? goingFor + 1 : 0;
  if (!isnan(imu.headingX) && imu.magStatus >= 2 && goingFor >= 15) {
    const float turn = fabsf(wrap180(gps.cogDeg - lastCog));
    if (turn < 3) {                                           // sailing straight: the puck's X is twist degrees clockwise of the course
      const float err = wrap180((imu.headingX - gps.cogDeg) - S.twist);
      S.twist = wrap180(S.twist + err * (S.twistLearned ? 0.02f : 0.2f));
      static int settled = 0;
      if (fabsf(err) < 5) settled++; else settled = 0;
      if (settled > 60 && !S.twistLearned) { S.twistLearned = true; saveSettings(); }
      if (millis() - lastSave > 120000) { lastSave = millis(); saveSettings(); }
    }
  }
  lastCog = gps.cogDeg;
}

// ---------- recording ----------
static void preAdd(const char *line, int n) {       // ring buffer of the latest points
  if (!pre) return;
  for (int i = 0; i < n; i++) { pre[preHead] = line[i]; preHead = (preHead + 1) % PRE_BYTES; if (preLen < PRE_BYTES) preLen++; }
}
static void preDrain(File &f) {                      // write out the ring from the first whole line
  if (!pre || !preLen) return;
  size_t start = (preHead + PRE_BYTES - preLen) % PRE_BYTES;
  if (preLen == PRE_BYTES) {                         // the oldest line is probably cut: skip to the next newline
    while (preLen && pre[start] != '\n') { start = (start + 1) % PRE_BYTES; preLen--; }
    if (preLen) { start = (start + 1) % PRE_BYTES; preLen--; }
  }
  while (preLen) {
    const size_t chunk = min(preLen, PRE_BYTES - start);
    f.write((const uint8_t *)pre + start, chunk);
    start = (start + chunk) % PRE_BYTES; preLen -= chunk;
  }
  preLen = 0; preHead = 0;
}

static void startRecording(bool manual) {
  if (!fsOk || recording) return;
  if (fsFree < FLASH_RESERVE) { flashFull = true; return; }
  const uint64_t t = nowMs() ? nowMs() : gps.tMs;
  char name[48];
  if (t) {
    int y; unsigned mo, d; civilFromDays((int64_t)(t / 1000 / 86400), y, mo, d);
    const uint32_t s = (uint32_t)((t / 1000) % 86400);
    snprintf(name, sizeof name, "%s/puck%d_%04d%02u%02u_%02lu%02lu%02lu.csv", TRK_DIR, S.puck, y, mo, d,
             (unsigned long)(s / 3600), (unsigned long)(s / 60 % 60), (unsigned long)(s % 60));
  } else snprintf(name, sizeof name, "%s/puck%d_notime_%lu.csv", TRK_DIR, S.puck, (unsigned long)(millis() / 1000));
  rec = LittleFS.open(name, FILE_WRITE);
  if (!rec) { Serial.println("Couldn't create the track file."); return; }
  rec.print("t_ms,lat,lon,sog_kn,hdg,heel,pitch\n");
  if (!manual) preDrain(rec); else { preLen = 0; preHead = 0; }
  recName = String(name).substring(strlen(TRK_DIR) + 1);
  recording = true; recStarted = millis(); recLines = 0; lastFlush = millis();
  countTracks();
  moveLat = gps.lat; moveLon = gps.lon; lastMoveMs = millis();
  Serial.printf("Recording %s (%s).\n", recName.c_str(), manual ? "button" : "the boat moved off");
}

static void stopRecording(const char *why) {
  if (!recording) return;
  rec.close(); recording = false;
  Serial.printf("Stopped (%s): %lu points in %s.\n", why, (unsigned long)recLines, recName.c_str());
  // a track with nothing in it is no use to anyone
  if (recLines < 10) { LittleFS.remove(trackPath(recName)); Serial.println("Too short, binned."); }
  countTracks();
  haveRest = false; stillSince = 0;
  sailEnded = millis(); lastOffPadTry = 0;      // go looking for the phone straight away, and keenly for a while
}

// one GPS fix: log it (at the full rate while moving, once a second while still), and watch for moving off / stopping
static void onFix() {
  const uint32_t m = millis();
  const uint64_t t = clockSet ? nowMs() : gps.tMs;
  const bool moving = gps.sogKn > STILL_KN;
  const uint32_t gap = moving ? 1000 / REC_HZ : 1000;
  if (gps.fix >= 2 && t && (m - lastPointMs >= gap - 5)) {
    lastPointMs = m;
    char line[112];
    const int n = snprintf(line, sizeof line, "%llu,%.7f,%.7f,%.2f,%.0f,%.1f,%.1f\n",
                           (unsigned long long)t, gps.lat / 1e7, gps.lon / 1e7, gps.sogKn, gps.cogDeg, imu.heel, imu.pitch);
    if (recording) {
      if (rec.write((const uint8_t *)line, n) != (size_t)n) { Serial.println("!! Flash full, recording stopped."); flashFull = true; stopRecording("flash full"); }
      else {
        recLines++; fsUnmeasured += n;
        // the free-space figure is measured every 10 s by everySecond (walking the flash is slow); between times, estimate from what's been written
        if (m - lastFlush > 5000) { rec.flush(); lastFlush = m; if (fsFree < fsUnmeasured + FLASH_RESERVE) { flashFull = true; stopRecording("flash full"); } }
      }
    } else preAdd(line, n);
  }

  // movement from rest
  if (gps.fix < 3 || gps.hAccM > 15) return;
  if (!moving) { if (!stillSince) stillSince = m; movingSince = 0; }
  else { stillSince = 0; if (!movingSince) movingSince = m; }
  // a speed that's held, not one jittery reading (on the bench 25 Oct it started recording on 0.5-2 kn of indoor
  // GPS noise and then wouldn't talk to the dock). The same rule keeps the auto-off clock honest.
  const bool underWay = movingSince && m - movingSince > START_MOVING_MS;
  if (underWay) lastActive = m;
  if (!recording) {
    if (stillSince && m - stillSince > STILL_FOR_MS) { haveRest = true; restLat = gps.lat; restLon = gps.lon; }
    // start: far enough from rest to beat the fix accuracy, and under way
    const bool farEnough = distM(restLat, restLon, gps.lat, gps.lon) > fmaxf(START_M, 4 * gps.hAccM);
    if (S.autoRec && !onPad && !flashFull && haveRest && farEnough && underWay) startRecording(false);
  } else {
    if (distM(moveLat, moveLon, gps.lat, gps.lon) > MOVE_M) { moveLat = gps.lat; moveLon = gps.lon; lastMoveMs = m; }
    // a track started by the button ends the same way as an automatic one: ten minutes without going anywhere
    if (m - lastMoveMs > STOP_AFTER_MS) stopRecording("still for 10 minutes");
  }
}

// ---------- LEDs ----------
static void leds(bool on) { digitalWrite(PIN_LED, on); analogWrite(PIN_RING, on ? 255 : 0); }
static void blinkN(int n, uint32_t ms = 80) { for (int i = 0; i < n; i++) { leds(true); delay(ms); leds(false); delay(ms); } }

static void led() {
  const uint32_t m = millis();
  bool on;
  if (uploading) on = true;
  else if (flashFull) { const uint32_t p = m % 2000; on = p < 1000 && (p % 200) < 80; }
  else if (wmode == W_SETUP) on = m % 500 < 120;
  else if (recording) { const uint32_t p = m % 1000; on = p < 80 || (p > 200 && p < 280); }
  else if (gps.fix >= 3) on = m % 1000 < 100;
  else on = m % 2000 < 60;
  digitalWrite(PIN_LED, on);
  if (!onPad) analogWrite(PIN_RING, on ? 255 : 0);
  else if (battFull) analogWrite(PIN_RING, 255);
  else { const float ph = (m % 3000) / 3000.0f * 6.2832f; analogWrite(PIN_RING, (int)(8 + 120 * (1 - cosf(ph)))); }
}

// ---------- sleep ----------
static void armWakeAndSleep() {
  rtc_gpio_pullup_en((gpio_num_t)PIN_BTN);
  rtc_gpio_pulldown_dis((gpio_num_t)PIN_BTN);
  esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_PERIPH, ESP_PD_OPTION_ON);
  esp_sleep_enable_ext0_wakeup((gpio_num_t)PIN_BTN, 0);                        // the button
  // ...or being put on the pad. Not armed while the pad's 5 V is already there: "any high" would wake it at
  // once, so a puck sent to sleep on the pad stays asleep until the button is pressed.
  rtc_gpio_pulldown_en((gpio_num_t)PIN_PAD);
  if (readMilliVolts(PIN_PAD) < 4000) esp_sleep_enable_ext1_wakeup(1ULL << PIN_PAD, ESP_EXT1_WAKEUP_ANY_HIGH);
  esp_deep_sleep_start();
}

static void goToSleep(const char *why) {
  if (recording) stopRecording("sleeping");
  saveSettings();
  Serial.printf("Sleeping (%s). Press the button or put it on the pad to wake it.\n", why);
  Serial.flush();
  WiFi.mode(WIFI_OFF);
  bleStop();
  blinkN(3);
  if (gpsOk) gnss.powerOffWithInterrupt(0, VAL_RXM_PMREQ_WAKEUPSOURCE_UARTRX);
  if (imuOk) { bno.enableReport(SH2_GAME_ROTATION_VECTOR, 0); bno.enableReport(SH2_ROTATION_VECTOR, 0); }
  delay(50);
  analogWrite(PIN_RING, 0); pinMode(PIN_RING, INPUT);
  armWakeAndSleep();
}

// ---------- WiFi: setup AP, and the dock as a client ----------
// Switching the radio off and straight back on in another mode (setup AP -> hotspot client, or the other
// way) crashed the puck: the driver was still stopping ("netstack cb reg failed with 12308"), the new
// mode came up without its network stack, and the first packet jumped to address 0 (seen 25 Oct, the
// first time a puck went setup -> phone hotspot for real). So: after WIFI_OFF, wait for the driver to
// finish, and don't start the next mode for a moment.
uint32_t wifiOffAt = 0;
static const uint32_t WIFI_SETTLE_MS = 600;
static void radioOff() {
  WiFi.mode(WIFI_OFF);
  for (int i = 0; i < 20 && WiFi.getMode() != WIFI_OFF; i++) delay(10);
  delay(150);
  wifiOffAt = millis();
}
static bool radioSettled() { return millis() - wifiOffAt >= WIFI_SETTLE_MS; }
static void enterSetup() {
  if (wmode == W_DOCK || wmode == W_JOINING) { webStop(); WiFi.disconnect(true); radioOff(); }
  while (!radioSettled()) delay(10);
  WiFi.mode(WIFI_AP);
  char ap[32]; snprintf(ap, sizeof ap, "wakeback-puck-%d", S.puck);
  WiFi.softAP(ap);
  WiFi.setSleep(false);
  dns.start(53, "*", WiFi.softAPIP());
  webStart();
  wmode = W_SETUP; wSince = millis(); setupLastSeen = millis(); dockOk = false;
  Serial.printf("Setup WiFi \"%s\" is on: join it and open http://%s/\n", ap, WiFi.softAPIP().toString().c_str());
}
static void leaveSetup() {
  dns.stop(); webStop(); WiFi.softAPdisconnect(true); radioOff();
  wmode = W_OFF; lastOffPadTry = millis();
  Serial.println("Setup mode off.");
}
static void joinDock() {
  if (!S.ssid.length()) return;
  WiFi.mode(WIFI_STA); WiFi.setSleep(false);
  WiFi.begin(S.ssid.c_str(), S.pass.length() ? S.pass.c_str() : nullptr);
  wmode = W_JOINING; wSince = millis(); dockOk = false; lastHello = 0;
}
static void wifiOff() {
  if (wmode == W_SETUP) { leaveSetup(); return; }
  webStop(); WiFi.disconnect(true); radioOff();
  wmode = W_OFF; dockOk = false;
}
static String dockUrl(const char *path) { return "http://" + WiFi.gatewayIP().toString() + ":" + String(DOCK_PORT) + path; }

// one HTTP exchange with the dock: GET when body is null, else a JSON POST. Returns the status code (0 = no connection)
// and leaves the body in reply. The key goes with every request; the dock ignores it where it doesn't apply.
static int dockRequest(const char *path, const char *body, uint32_t timeoutMs, String &reply) {
  WiFiClient c; HTTPClient h; h.setTimeout(timeoutMs);
  reply = "";
  if (!h.begin(c, dockUrl(path))) return 0;
  if (S.key.length()) h.addHeader("X-Puck-Key", S.key);
  int code;
  if (body) { h.addHeader("Content-Type", "application/json"); code = h.POST((uint8_t *)body, strlen(body)); }
  else code = h.GET();
  if (code > 0) reply = h.getString();
  h.end();
  return code;
}
// the value of a top-level JSON field as text, "" when absent (enough for the dock's small flat replies)
static String jsonField(const String &reply, const char *key) {
  const int i = reply.indexOf(String("\"") + key + "\"");
  if (i < 0) return "";
  int p = reply.indexOf(':', i); if (p < 0) return "";
  p++;
  while (p < (int)reply.length() && reply[p] == ' ') p++;
  if (p < (int)reply.length() && reply[p] == '"') { const int e = reply.indexOf('"', p + 1); return e > p ? reply.substring(p + 1, e) : ""; }
  int e = p; while (e < (int)reply.length() && reply[e] != ',' && reply[e] != '}' && reply[e] != ' ') e++;
  return reply.substring(p, e);
}
static bool replyOk(const String &reply) { return jsonField(reply, "ok") == "true"; }
// the dock sends its clock with hello and check-in: use it unless the GPS already has the time
static void takeDockTime(const String &reply) {
  const uint64_t t = strtoull(jsonField(reply, "time_ms").c_str(), nullptr, 10);
  if (t > 1600000000000ULL) setClock(t, false);
}

static bool hello() {
  String reply;
  if (dockRequest("/api/hello", nullptr, 3000, reply) != 200) return false;
  if (reply.indexOf("\"wakeback\"") < 0) return false;
  takeDockTime(reply);
  return true;
}

// the dock answered 401 or 403: the key doesn't match. Retrying every half minute just burns the battery, so stand off.
static void dockRefusedKey(const char *what) {
  dockRefused = true; lastOffPadTry = millis();
  Serial.printf("The dock refused the key (%s). Set the puck up again from the app. Trying again in %lu min.\n", what,
                (unsigned long)((onPad ? REFUSED_PAD_MS : REFUSED_OFFPAD_MS) / 60000));
}

static bool checkin() {
  char body[400];
  snprintf(body, sizeof body,
           "{\"puck\":%d,\"battery_mv\":%d,\"charging\":\"%s\",\"on_pad\":%s,\"free_kb\":%u,\"total_kb\":%u,\"fw\":\"%s\","
           "\"pending\":%d,\"rssi\":%d,\"recording\":%s,\"orientation\":\"%s\",\"twist\":%.0f,\"mag\":%d,\"gps_fix\":%d,\"ip\":\"%s\"}",
           S.puck, (int)battMv, chargeName(), B(onPad),
           (unsigned)(fsFree / 1024), (unsigned)(fsTotal / 1024), FW, pendingCount(), WiFi.RSSI(),
           B(recording), orientName(),
           S.twist, imu.magStatus, gps.fix, WiFi.localIP().toString().c_str());
  String reply;
  const int code = dockRequest("/api/pucks/checkin", body, 4000, reply);
  if (code == 401 || code == 403) { dockRefusedKey("check-in"); return false; }
  if (code != 200) return false;
  takeDockTime(reply);
  dockRefused = false;
  // the app wants to open our page: keep the radio up for a while and check in more often, so it can find us
  if (reply.indexOf("\"hold\":true") >= 0 || reply.indexOf("\"hold\": true") >= 0) { holdUntil = millis() + HOLD_MS; Serial.println("Dock asked us to stay on."); }
  return replyOk(reply);
}

// multipart POST of one track straight from flash; true when the dock said ok
static bool uploadFile(const String &name) {
  File f = LittleFS.open(trackPath(name), FILE_READ);
  if (!f) return false;
  WiFiClient c; c.setTimeout(10);
  if (!c.connect(WiFi.gatewayIP(), DOCK_PORT)) { f.close(); return false; }
  const char *BOUNDARY = "----WakeBackPuck";
  char puckField[16]; snprintf(puckField, sizeof puckField, "puck%d", S.puck);
  String head = String("--") + BOUNDARY + "\r\nContent-Disposition: form-data; name=\"puck\"\r\n\r\n" + puckField + "\r\n--" + BOUNDARY +
                "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"" + name + "\"\r\nContent-Type: text/csv\r\n\r\n";
  String tail = String("\r\n--") + BOUNDARY + "--\r\n";
  const size_t len = head.length() + f.size() + tail.length();
  c.printf("POST /api/upload HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\nContent-Type: multipart/form-data; boundary=%s\r\n",
           WiFi.gatewayIP().toString().c_str(), DOCK_PORT, BOUNDARY);
  if (S.key.length()) c.printf("X-Puck-Key: %s\r\n", S.key.c_str());
  c.printf("Content-Length: %u\r\n\r\n", (unsigned)len);
  c.print(head);
  uint8_t buf[1024]; size_t n;
  // the button and the LED keep working while a big track streams out, so a 2 s hold still sends it to sleep
  // (GPS isn't polled here: the fix handler could open or close a track file while this one is being read)
  while ((n = f.read(buf, sizeof buf)) > 0) { if (c.write(buf, n) != n) { f.close(); c.stop(); return false; } pollButton(); led(); }
  f.close();
  c.print(tail);
  const uint32_t t0 = millis(); String status, body; bool inBody = false;
  while (c.connected() || c.available()) {
    if (millis() - t0 > 20000) break;
    if (!c.available()) { pollButton(); led(); delay(5); continue; }
    String line = c.readStringUntil('\n');
    if (!status.length()) status = line;
    else if (!inBody && line.length() <= 1) inBody = true;
    else if (inBody) body += line;
  }
  c.stop();
  if (status.indexOf(" 401") > 0 || status.indexOf(" 403") > 0) dockRefusedKey("upload");
  return status.indexOf(" 200") > 0 && replyOk(body);
}

static void uploadPending() {
  const String names = trackNames();
  uploading = true;
  int sent = 0;
  for (int s = 0; s < (int)names.length();) {
    const int e = names.indexOf('\n', s); const String name = names.substring(s, e); s = e + 1;
    if (recording && name == recName) continue;
    Serial.printf("Uploading %s… ", name.c_str());
    if (uploadFile(name)) { LittleFS.remove(trackPath(name)); Serial.println("done, deleted from the puck."); sent++; flashFull = false; }
    else { if (!dockRefused) Serial.println("the dock didn't take it, will try later."); break; }
    if (webOn) web.handleClient();
  }
  uploading = false; countTracks(); measureFs();
  if (sent) lastCheckin = 0;        // tell the dock the new numbers straight away
}

// "1.0.12" -> 1*1000000 + 0*1000 + 12, so versions compare as numbers; anything unparseable is 0
static long versionNum(const String &v) {
  long n = 0; int part = 0, val = 0;
  for (size_t i = 0; i <= v.length(); i++) {
    const char c = i < v.length() ? v[i] : '.';
    if (c >= '0' && c <= '9') val = val * 10 + (c - '0');
    else if (c == '.') { if (part < 3) n = n * 1000 + val; part++; val = 0; }
    else break;
  }
  while (part < 3) { n *= 1000; part++; }
  return n;
}

// firmware the dock is offering (roadmap stage 5): GET /api/firmware/latest -> {"version":"1.1.0","url":"/api/firmware/puck.bin"}
static void checkDockFirmware() {
  // a puck flashed from VS Code says "1.0.0" or "dev": the dock mustn't overwrite the build someone is working on
  const String me = FW;
  if (me == "1.0.0" || me.indexOf("dev") >= 0) return;
  String reply;
  if (dockRequest("/api/firmware/latest", nullptr, 4000, reply) != 200) return;
  const String ver = jsonField(reply, "version");
  String url = jsonField(reply, "url");
  // only a newer release goes on: a dock that's behind must never downgrade a puck
  if (!ver.length() || !url.length() || versionNum(ver) <= versionNum(me)) return;
  if (!url.startsWith("http")) url = dockUrl(url.c_str());
  Serial.printf("Dock has firmware %s (this is %s): updating from %s\n", ver.c_str(), FW, url.c_str());
  if (recording) stopRecording("firmware update");
  WiFiClient gc; HTTPClient g; g.setTimeout(30000);
  if (!g.begin(gc, url) || g.GET() != 200) { g.end(); return; }
  const int size = g.getSize();
  uploading = true; led();
  if (size > 0 && Update.begin(size)) {
    const size_t got = Update.writeStream(g.getStream());
    if (got == (size_t)size && Update.end(true)) { Serial.println("Updated, restarting."); g.end(); delay(200); ESP.restart(); }
    Serial.printf("Update failed: %s\n", Update.errorString());
  }
  uploading = false; g.end();
}

// one pass of the WiFi state machine, called often
static void wifiTick() {
  const uint32_t m = millis();
  if (wmode == W_SETUP) {
    dns.processNextRequest();
    // nobody has looked at the page for a while: back to normal. That includes a puck charging off a laptop's USB;
    // on the bench the serial 'w' command brings it back.
    if (m - setupLastSeen > SETUP_IDLE_MS) leaveSetup();
    return;
  }
  // a reason to talk to the dock?
  uint32_t retry;
  if (dockRefused) retry = onPad ? REFUSED_PAD_MS : REFUSED_OFFPAD_MS;                   // wrong key: stand well off
  else if (onPad) retry = (lastJoinOk && m - lastJoinOk < PAD_RECENT_MS) ? PAD_RETRY_MS : PAD_RETRY_SLOW_MS;   // on the pad: keen while the dock's about, otherwise gently (radio off between tries)
  else retry = (sailEnded && m - sailEnded < AFTER_SAIL_FOR_MS) ? AFTER_SAIL_RETRY_MS : OFFPAD_RETRY_MS;       // tracks waiting after a sail: look for the phone keenly for a while
  const bool wantDock = S.ssid.length() && !recording &&
                        ((wantLiftCheckin && !dockRefused) || ((onPad || pendingCount() > 0) && m - lastOffPadTry > retry));
  if (wmode == W_OFF) { if (wantDock && radioSettled()) { joinDock(); lastOffPadTry = m; } return; }
  if (wmode == W_JOINING) {
    if (WiFi.status() == WL_CONNECTED) { wmode = W_DOCK; wSince = m; webStart(); Serial.printf("Joined %s, dock should be at %s\n", S.ssid.c_str(), dockUrl("").c_str()); }
    else if (m - wSince > JOIN_TIMEOUT_MS) { wifiOff(); wantLiftCheckin = false; }      // no hotspot about: radio off, try again later
    return;
  }
  // W_DOCK
  if (WiFi.status() != WL_CONNECTED) { wifiOff(); return; }
  if (!dockOk) {
    if (m - lastHello > HELLO_EVERY_MS) { lastHello = m; dockOk = hello(); if (dockOk) { lastCheckin = 0; lastJoinOk = m; Serial.println("Dock found."); } }
    if (!dockOk && m - wSince > (onPad ? PAD_HELLO_FOR_MS : OFFPAD_TRY_FOR_MS)) { wifiOff(); wantLiftCheckin = false; }
    return;
  }
  const bool held = holdUntil && (int32_t)(holdUntil - m) > 0;
  if (m - lastCheckin > (held ? 10000UL : CHECKIN_MS) || lastCheckin == 0) {
    lastCheckin = m;
    if (checkin()) {
      wantLiftCheckin = false;
      if (appPendingVerify) { esp_ota_mark_app_valid_cancel_rollback(); appPendingVerify = false; Serial.println("New firmware confirmed."); }
      if (pendingCount() > 0) uploadPending();
      if (m - lastFwCheck > FW_CHECK_MS || lastFwCheck == 0) { lastFwCheck = m; checkDockFirmware(); }
    } else dockOk = false;
  }
  // the key was refused: radio off, and leave the dock alone for a while (dockRefusedKey set lastOffPadTry)
  if (dockRefused) { wifiOff(); wantLiftCheckin = false; return; }
  // nothing left to say: let the radio go. On the pad that's most of the time: a check-in a minute with the
  // radio off in between leaves the pad's few hundred mA for charging.
  if (!wantLiftCheckin && pendingCount() == 0 && !uploading && !(holdUntil && (int32_t)(holdUntil - m) > 0)) wifiOff();
}

// ---------- the web page and its API ----------
static void sendJson(const String &s) { web.send(200, "application/json", s); }
static void okMsg(const char *msg) { sendJson(String("{\"ok\":true,\"msg\":\"") + jsonStr(msg) + "\"}"); }

static String statusJson() {
  String j; j.reserve(1800);
  char b[700];
  snprintf(b, sizeof b, "{\"fw\":\"%s\",\"puck\":%d,\"uptime_s\":%lu,\"time_ms\":%llu,\"autorec\":%s,\"autooff\":%s,",
           FW, S.puck, (unsigned long)(millis() / 1000), (unsigned long long)nowMs(), B(S.autoRec), B(S.autoOff));
  j += b;
  snprintf(b, sizeof b, "\"gps\":{\"ok\":%s,\"fix\":%d,\"sats\":%d,\"lat\":%.7f,\"lon\":%.7f,\"sog\":%.2f,\"cog\":%.1f,\"hacc\":%.1f,\"hz\":%.0f},",
           B(gpsOk), gps.fix, gps.sats, gps.lat / 1e7, gps.lon / 1e7, gps.sogKn, gps.cogDeg, gps.hAccM, gps.rateHz);
  j += b;
  snprintf(b, sizeof b, "\"imu\":{\"ok\":%s,\"heel\":%.1f,\"pitch\":%.1f,\"heading\":%.0f,\"twist\":%.1f,\"twist_learned\":%s,\"orientation\":\"%s\",\"mag\":%d,\"zero_heel\":%.1f,\"zero_pitch\":%.1f,\"flip\":%s},",
           B(imuOk), imu.heel, imu.pitch, isnan(imu.headingX) ? -1.0f : fmodf(imu.headingX - S.twist + 720, 360), S.twist, B(S.twistLearned),
           orientName(), imu.magStatus, S.zeroHeel, S.zeroPitch, B(S.flipHeel));
  j += b;
  snprintf(b, sizeof b, "\"batt\":{\"mv\":%d,\"pct\":%d,\"on_pad\":%s,\"charging\":\"%s\"},\"rec\":{\"on\":%s,\"secs\":%lu,\"lines\":%lu,\"file\":\"%s\"},",
           (int)battMv, batteryPct(battMv), B(onPad), chargeName(),
           B(recording), (unsigned long)(recording ? (millis() - recStarted) / 1000 : 0), (unsigned long)recLines, recording ? recName.c_str() : "");
  j += b;
  snprintf(b, sizeof b, "\"store\":{\"free_kb\":%u,\"total_kb\":%u,\"files\":%d,\"full\":%s},",
           (unsigned)(fsFree / 1024), (unsigned)(fsTotal / 1024), nTracks, B(flashFull));
  j += b;
  j += "\"wifi\":{\"mode\":\"" + String(wifiName()) + "\",\"ssid\":\"" + jsonStr(S.ssid) + "\",\"ip\":\"" +
       (wmode == W_DOCK ? WiFi.localIP().toString() : WiFi.softAPIP().toString()) + "\",\"dock_ok\":" + B(dockOk) + ",\"dock_refused\":" + B(dockRefused) + "},";
  j += "\"tracks\":[";
  bool first = true;
  forEachTrack([&](const String &name, size_t size) {
    if (!first) j += ','; first = false;
    j += "{\"name\":\"" + jsonStr(name) + "\",\"kb\":" + String((unsigned)(size / 1024)) + ",\"open\":" + B(recording && name == recName) + "}";
  });
  j += "]}";
  return j;
}

static bool captive() {       // phones probing for internet: send them to the page
  const String host = web.hostHeader();
  if (wmode == W_SETUP && host != WiFi.softAPIP().toString()) {
    web.sendHeader("Location", "http://" + WiFi.softAPIP().toString() + "/", true);
    web.send(302, "text/plain", ""); return true;
  }
  return false;
}

// ---------- shared by the web page and Bluetooth ----------
static String urlDecode(const String &v) {
  String out; out.reserve(v.length());
  for (size_t i = 0; i < v.length(); i++) {
    const char c = v[i];
    if (c == '+') out += ' ';
    else if (c == '%' && i + 2 < v.length()) { out += (char)strtol(v.substring(i + 1, i + 3).c_str(), nullptr, 16); i += 2; }
    else out += c;
  }
  return out;
}
static String urlEncode(const String &v) {
  String out; out.reserve(v.length() * 3);
  for (size_t i = 0; i < v.length(); i++) {
    const char c = v[i];
    if (isalnum((unsigned char)c) || c == '-' || c == '_' || c == '.' || c == '~') out += c;
    else { char b[4]; snprintf(b, sizeof b, "%%%02X", (unsigned char)c); out += b; }
  }
  return out;
}
// "puck=3&ssid=James%20Phone&pass=…&key=…&autorec=1": the settings the app or the page sends
static String applySettings(const String &form) {
  int start = 0; const int oldPuck = S.puck;
  while (start <= (int)form.length()) {
    int amp = form.indexOf('&', start); if (amp < 0) amp = form.length();
    const String kv = form.substring(start, amp); start = amp + 1;
    const int eq = kv.indexOf('='); if (eq < 0) continue;
    const String k = kv.substring(0, eq), v = urlDecode(kv.substring(eq + 1));
    if (k == "puck") { const int n = v.toInt(); if (n >= 1 && n <= 99) S.puck = n; }
    else if (k == "ssid") { String t = v; t.trim(); if (t.length() && t.length() < 33) S.ssid = t; }
    else if (k == "pass") { if (v.length()) S.pass = v.substring(0, 63); }
    else if (k == "key") S.key = v.substring(0, 64);
    else if (k == "autorec") S.autoRec = v == "1";
    else if (k == "autooff") S.autoOff = v == "1";
  }
  S.configured = true;                        // someone has been here: no more setup WiFi at power-up
  saveSettings();
  if (S.puck != oldPuck && bleServer) bleSetName(S.puck);
  dockRefused = false; lastOffPadTry = 0;     // new WiFi or key: have another go at the dock straight away
  return "Saved.";
}
// told which way up it is: the learner still corrects it later if gravity says otherwise for half a minute
static bool setOrientation(int o) {
  if (o != 1 && o != 2) return false;
  S.orientation = o; saveSettings(); return true;
}
// the app is here and listening: go and find the hotspot now, whatever the retry timers say
static void wantDockNow() { if (wmode == W_SETUP) leaveSetup(); lastOffPadTry = 0; wantLiftCheckin = true; dockRefused = false; lastActive = millis(); }
// firmware over Bluetooth, in pieces
static bool otaBegin(size_t bytes) { if (recording) stopRecording("firmware update"); uploading = true; led(); return Update.begin(bytes); }
static bool otaWrite(const uint8_t *data, size_t len) { return Update.write((uint8_t *)data, len) == len; }
static bool otaEnd() { uploading = false; return Update.end(true); }
static void bleNote(const char *what) { Serial.printf("BLE: %s\n", what); }

static void startWeb() {
  web.on("/", HTTP_GET, [] { if (captive()) return; web.send_P(200, "text/html", PAGE_HTML); });
  web.on("/api/status", HTTP_GET, [] { setupLastSeen = millis(); lastActive = millis(); sendJson(statusJson()); });
  web.on("/api/settings", HTTP_POST, [] {
    String form;
    for (int i = 0; i < web.args(); i++) { if (i) form += '&'; form += web.argName(i) + "=" + urlEncode(web.arg(i)); }
    okMsg(applySettings(form).c_str());
  });
  web.on("/api/cal/level", HTTP_POST, [] { calLevel(); okMsg("Level set: heel and pitch read 0 here."); });
  web.on("/api/cal/flip", HTTP_POST, [] { calFlipHeel(); okMsg(S.flipHeel ? "Heel sign flipped." : "Heel sign back to normal."); });
  web.on("/api/cal/orient", HTTP_POST, [] {
    const int o = web.arg("o").toInt();
    if (!setOrientation(o)) { web.send(400, "text/plain", "o must be 1 (deck) or 2 (thwart)"); return; }
    okMsg(o == 1 ? "Mounted on deck." : "Mounted under the thwart.");
  });
  web.on("/api/cal/twist", HTTP_POST, [] { S.twist = wrap180(web.arg("deg").toFloat()); S.twistLearned = true; saveSettings(); okMsg("Twist set."); });
  web.on("/api/cal/reset", HTTP_POST, [] { S.zeroHeel = S.zeroPitch = S.twist = 0; S.twistLearned = false; S.flipHeel = false; S.orientation = 0; saveSettings(); okMsg("Calibration cleared."); });
  web.on("/api/rec", HTTP_POST, [] {
    if (web.arg("op") == "start") { startRecording(true); okMsg(recording ? "Recording." : flashFull ? "Flash is full." : "Couldn't start."); }
    else { stopRecording("page"); okMsg("Stopped."); }
  });
  web.on("/api/tracks/delete", HTTP_POST, [] {
    String n = web.arg("name"); if (n.indexOf('/') >= 0 || n.indexOf("..") >= 0 || !n.length()) { web.send(400, "text/plain", "bad name"); return; }
    if (recording && n == recName) stopRecording("deleted from the page");
    LittleFS.remove(trackPath(n)); countTracks(); measureFs(); flashFull = fsFree < FLASH_RESERVE; okMsg("Deleted.");
  });
  web.on("/api/setup/done", HTTP_POST, [] { okMsg("Leaving setup mode."); delay(300); usbSetupDone = true; if (wmode == W_SETUP) leaveSetup(); });
  web.on("/api/reboot", HTTP_POST, [] { okMsg("Restarting."); delay(300); if (recording) stopRecording("restart"); ESP.restart(); });
  web.on("/api/sleep", HTTP_POST, [] { okMsg("Sleeping."); delay(300); goToSleep("page"); });
  web.on("/update", HTTP_POST,
    [] {
      const bool ok = !Update.hasError();
      web.sendHeader("Connection", "close");
      web.send(200, "text/plain", ok ? "Firmware written." : String("Update failed: ") + Update.errorString());
      if (ok) { delay(500); ESP.restart(); }
    },
    [] {
      HTTPUpload &up = web.upload();
      if (up.status == UPLOAD_FILE_START) {
        if (recording) stopRecording("firmware update");
        uploading = true; led();
        Serial.printf("Firmware upload %s\n", up.filename.c_str());
        if (!Update.begin(UPDATE_SIZE_UNKNOWN)) Serial.println(Update.errorString());
      } else if (up.status == UPLOAD_FILE_WRITE) {
        if (Update.write(up.buf, up.currentSize) != up.currentSize) Serial.println(Update.errorString());
      } else if (up.status == UPLOAD_FILE_END) {
        uploading = false;
        if (Update.end(true)) Serial.printf("Firmware ok, %u bytes.\n", up.totalSize); else Serial.println(Update.errorString());
      } else if (up.status == UPLOAD_FILE_ABORTED) { uploading = false; Update.abort(); }
    });
  web.onNotFound([] {
    if (captive()) return;
    const String u = web.uri();
    if (u.startsWith("/tracks/")) {
      String n = u.substring(8); if (n.indexOf("..") >= 0) { web.send(400, "text/plain", "bad name"); return; }
      File f = LittleFS.open(trackPath(n), FILE_READ);
      if (!f) { web.send(404, "text/plain", "no such track"); return; }
      web.sendHeader("Content-Disposition", "attachment; filename=\"" + n + "\"");
      web.streamFile(f, "text/csv"); f.close(); return;
    }
    web.send(404, "text/plain", "not found");
  });
}
static void webStart() { if (!webOn) { web.begin(); webOn = true; } }
static void webStop() { if (webOn) { web.stop(); webOn = false; } }

// ---------- button ----------
static void pollButton() {
  static bool down = false, seenUp = false; static int holdStage = 0;
  static uint32_t tDown = 0, tChange = 0;
  const bool pressed = digitalRead(PIN_BTN) == LOW;
  const uint32_t m = millis();
  // the press that woke the puck is still going when this first runs: it mustn't count as a tap (or a 2 s hold!)
  if (!seenUp) { if (pressed) return; seenUp = true; }
  if (pressed != down && m - tChange > 30) {
    down = pressed; tChange = m; lastActive = m;
    if (down) { tDown = m; holdStage = 0; }
    else {
      if (holdStage == 0) { if (recording) stopRecording("button"); else startRecording(true); }   // a tap
      else if (holdStage == 1) goToSleep("button held");                                           // let go after the 2 s blinks
      // holdStage 2: setup mode already started while held
    }
  }
  if (down && holdStage == 0 && m - tDown >= HOLD_SLEEP_MS) { holdStage = 1; blinkN(3); }
  if (down && holdStage == 1 && m - tDown >= HOLD_SETUP_MS) { holdStage = 2; blinkN(5, 50); if (wmode == W_SETUP) leaveSetup(); else enterSetup(); }
}

// ---------- once a second ----------
static void everySecond() {
  gps.rateHz = gps.pvtThisSecond; gps.pvtThisSecond = 0;
  battMv = readMilliVolts(PIN_BATT);
  // On the pad = 5 V from the Qi receiver. But once the battery is full the charger stops drawing and most Qi
  // pads drop into standby (LED blinking), so the 5 V goes away while the puck is still sitting there. Keep
  // "on the pad" until it's actually picked up: a tilt from how it lay when the 5 V was last seen, GPS
  // movement, or two hours (ten minutes with no IMU), whichever comes first.
  const bool padMv = readMilliVolts(PIN_PAD) > 4000;
  static uint32_t padLastMv = 0; static float padHeel = 0, padPitch = 0;
  bool padNow = padMv;
  if (padMv) { padLastMv = millis(); padHeel = imu.heel; padPitch = imu.pitch; }
  else if (padLastMv && millis() - padLastMv < (imuOk ? PAD_HOLD_MS : PAD_HOLD_NO_IMU_MS)) {
    const bool tilted = imuOk && (fabsf(imu.heel - padHeel) > PAD_TILT_DEG || fabsf(imu.pitch - padPitch) > PAD_TILT_DEG);
    const bool moving = gps.fix >= 2 && gps.sogKn > STILL_KN;
    if (tilted || moving) padLastMv = 0; else padNow = true;
  } else padLastMv = 0;
  static uint32_t padSince = 0;
  if (padNow != onPad) {
    onPad = padNow; lastActive = millis(); padSince = millis();
    if (onPad) { if (recording) stopRecording("on the pad"); }
    else { gpsWake(); wantLiftCheckin = lastJoinOk && millis() - lastJoinOk < PAD_RECENT_MS; haveRest = false; stillSince = 0; }
  }
  if (onPad && !gpsNapping && !recording && millis() - padSince > PAD_GPS_NAP_MS) gpsNap();
  battFull = onPad && battMv >= 4150;

  // on a USB lead (the bench): put the setup WiFi up without being asked, once per plug-in
  const bool plugged = Serial.isPlugged();
  if (plugged && !usbPlugged) usbSetupDone = false;
  usbPlugged = plugged;
  if (usbPlugged && !usbSetupDone && wmode == W_OFF && !recording) { usbSetupDone = true; enterSetup(); }

  // battery nearly flat: close the track properly and sleep before the protection board cuts the power mid-write
  static int lowFor = 0;
  lowFor = (!onPad && battMv > 2500 && battMv < 3400) ? lowFor + 1 : 0;
  if (lowFor >= 10) goToSleep("battery flat");

  learnMounting();
  static int tick = 0; if (++tick % 10 == 0) { measureFs(); countTracks(); }
  if (flashFull && fsFree > FLASH_RESERVE * 2) flashFull = false;
  if (bleConnected) lastActive = millis();      // the app is talking to us: not idle
  if (S.autoOff && !onPad && !recording && wmode != W_SETUP && millis() - lastActive > AUTO_OFF_MS) goToSleep("still for 30 minutes");
  // new firmware that has run a couple of minutes with the sensors alive counts as good even with no dock about
  if (appPendingVerify && millis() > 120000 && (gpsOk || imuOk)) { esp_ota_mark_app_valid_cancel_rollback(); appPendingVerify = false; }
}

// ---------- serial ----------
static void printStatus() {
  const char *fixTxt[] = {"no fix", "DR", "2D", "3D", "3D+DR", "time"};
  Serial.printf("GPS %s", gpsOk ? (gps.fix < 6 ? fixTxt[gps.fix] : "?") : "NONE");
  if (gpsOk) Serial.printf(" %u sats %.0f Hz +/-%.1f m | %.2f kn %03.0f", gps.sats, gps.rateHz, gps.hAccM, gps.sogKn, gps.cogDeg);
  if (imuOk) Serial.printf(" | heel %+5.1f pitch %+5.1f twist %.0f %s mag %d", imu.heel, imu.pitch, S.twist, orientName(), imu.magStatus);
  Serial.printf(" | batt %.2f V %d%% %s", battMv / 1000, batteryPct(battMv), !onPad ? "off pad" : chargeName());
  Serial.printf(" | wifi %s%s", wifiName(), dockOk ? " ok" : "");
  if (recording) Serial.printf(" | REC %lus %lu pts", (unsigned long)((millis() - recStarted) / 1000), (unsigned long)recLines);
  Serial.printf(" | %d track(s), %.1f MB free\n", nTracks, fsFree / 1048576.0);
}
static bool statusPaused = false;     // 'q' stops the 5 s status line so other output can be read
static void help() {
  Serial.printf("\nWakeBack puck %d, firmware %s\n  h help  s status  q pause/resume the status line  i start-up report  r start/stop recording\n"
                "  l list tracks  erase (the whole word) erase all tracks  w setup WiFi on/off  u talk to the dock now  x sleep\n"
                "  Puck number, level, heel sign and the rest are on the setup page (w, then http://192.168.4.1/).\n\n", S.puck, FW);
}
static void report() {
  // what to check when a part is missing: the same hints the old bench sketch gave
  Serial.printf("GPS: %s", gpsOk ? "found" : "NOT FOUND. Check VCC/GND, and that GPS TX goes to D7 and GPS RX to D6.\n");
  if (gpsOk) Serial.printf(" at %lu baud, 10 Hz, sea mode\n", (unsigned long)gpsBaud);
  Serial.printf("IMU: %s\n", imuOk ? "found (BNO085)" : "NOT FOUND. Check VIN/GND, SDA to D4, SCL to D5.");
  Serial.printf("Storage: %s %.1f MB free, %d track(s)\n", fsOk ? "ok," : "NOT WORKING", fsFree / 1048576.0, nTracks);
  Serial.printf("Dock WiFi: \"%s\"%s. Auto-record %s. Twist %.0f%s, mounted %s.\n", S.ssid.c_str(), S.pass.length() ? "" : " (no password)",
                S.autoRec ? "on" : "off", S.twist, S.twistLearned ? "" : " (not learnt yet)", S.orientation == 2 ? "under the thwart" : S.orientation == 1 ? "on deck" : "not known yet");
}
static void command(String c) {
  c.trim(); if (!c.length()) return;
  lastActive = millis();
  if (c.equalsIgnoreCase("erase")) {
    if (recording) stopRecording("erase");
    const String names = trackNames();
    for (int s = 0; s < (int)names.length();) { const int e = names.indexOf('\n', s); LittleFS.remove(trackPath(names.substring(s, e))); s = e + 1; }
    countTracks(); measureFs(); flashFull = false; Serial.println("All tracks erased.");
    return;
  }
  if (c.length() > 1) { Serial.println("Unknown command. Type h."); return; }
  switch (tolower(c[0])) {
    case 'h': help(); break;
    case 's': printStatus(); break;
    case 'q': statusPaused = !statusPaused; Serial.println(statusPaused ? "Status line paused (q again to resume)." : "Status line back on."); break;
    case 'i': report(); break;
    case 'r': recording ? stopRecording("serial") : startRecording(true); break;
    case 'l': forEachTrack([](const String &n, size_t size) { Serial.printf("  %s  %u KB\n", n.c_str(), (unsigned)(size / 1024)); }); if (!nTracks) Serial.println("  no tracks"); break;
    case 'e': Serial.println("To erase every track type the whole word: erase"); break;
    case 'w': wmode == W_SETUP ? leaveSetup() : enterSetup(); break;
    case 'u': wantDockNow();
              Serial.println(recording ? "Recording: the puck won't talk to the dock until that stops (r, or the button)." : "Looking for the dock…"); break;
    case 'x': goToSleep("x typed"); break;
    default: Serial.println("Unknown command. Type h.");
  }
}

// ---------- setup and loop ----------
void setup() {
  pinMode(PIN_LED, OUTPUT); pinMode(PIN_RING, OUTPUT);
  rtc_gpio_deinit((gpio_num_t)PIN_BTN); rtc_gpio_deinit((gpio_num_t)PIN_PAD);
  pinMode(PIN_BTN, INPUT_PULLUP);
  const esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
  const bool woken = cause == ESP_SLEEP_WAKEUP_EXT0 || cause == ESP_SLEEP_WAKEUP_EXT1;
  if (cause == ESP_SLEEP_WAKEUP_EXT0) {
    const uint32_t t = millis();
    while (digitalRead(PIN_BTN) == LOW && millis() - t < WAKE_HOLD_MS) delay(5);
    if (millis() - t < WAKE_HOLD_MS) armWakeAndSleep();     // a knock, not a press
  }
  leds(true);
  analogReadResolution(12);
  Serial.begin(115200);
  Serial.setTxTimeoutMs(0);                     // a USB host that's attached but not reading must never stall the loop
  const uint32_t t = millis();
  while (!woken && !Serial && millis() - t < 2500) delay(10);

  loadSettings();
  pre = (char *)malloc(PRE_BYTES);
  Serial.printf("\nWakeBack puck %d, firmware %s%s\n", S.puck, FW, woken ? " (woken)" : "");
  fsOk = LittleFS.begin(true);
  if (fsOk && !LittleFS.exists(TRK_DIR)) LittleFS.mkdir(TRK_DIR);
  gpsOk = startGps();
  imuOk = startImu();
  measureFs(); countTracks();
  flashFull = fsOk && fsFree < FLASH_RESERVE;

  // after an over-the-air update the new image runs once on probation; it's confirmed after a good check-in (or 2 min alive)
  const esp_partition_t *run = esp_ota_get_running_partition();
  esp_ota_img_states_t st;
  if (run && esp_ota_get_state_partition(run, &st) == ESP_OK && st == ESP_OTA_IMG_PENDING_VERIFY) appPendingVerify = true;

  WiFi.persistent(false);
  startWeb();                                   // routes only; the server itself starts with the WiFi
  bleStart(S.puck);                             // Bluetooth is how the app talks to the puck; WiFi only carries the tracks
  leds(false);
  lastActive = millis();
  battMv = readMilliVolts(PIN_BATT); onPad = readMilliVolts(PIN_PAD) > 4000;
  report();
  if (!S.configured && !woken) { Serial.println("Not set up yet: setup WiFi is on so you can set it up from your phone."); enterSetup(); }
  help();
}

void loop() {
  static String in; static uint32_t lastSec = 0, lastStatus = 0;
  while (Serial.available()) {
    const char ch = Serial.read();
    if (ch == '\n' || ch == '\r') { command(in); in = ""; } else if (in.length() < 48) in += ch;
  }
  pollGps();
  if (gps.fresh) { gps.fresh = false; onFix(); }
  pollImu();
  pollButton();
  if (webOn) web.handleClient();
  wifiTick();
  led();
  const uint32_t m = millis();
  if (m - lastSec >= 1000) { lastSec = m; everySecond(); }
  if (m - lastStatus >= 5000 && Serial && !statusPaused) { lastStatus = m; printStatus(); }
  delay(2);
}
