// WakeBack bench test
// ---------------------
// Checks each part of a breadboard puck and records a test track in the same CSV the viewer reads.
// Open a serial monitor at 115200 and type h for the commands.
//
// Wiring (XIAO ESP32S3), see BUILD.md:
//   GPS  (BE-880)   VCC 3V3, GND, GPS TX -> D7 (GPIO44), GPS RX -> D6 (GPIO43)
//   IMU  (BNO085)   VIN 3V3, GND, SDA -> D4 (GPIO5), SCL -> D5 (GPIO6)
//   LED             D3 (GPIO4) -> 330R -> LED -> GND
//   Battery sense   TP4056 OUT+ -> 100k -> A0 (GPIO1) -> 100k -> GND
//   Pad sense       Qi 5V       -> 100k -> A1 (GPIO2) -> 100k -> GND

#include <Arduino.h>
#include <Wire.h>
#include <LittleFS.h>
#include <Preferences.h>
#include <SparkFun_u-blox_GNSS_v3.h>
#include <Adafruit_BNO08x.h>

// ---------- pins ----------
static const int PIN_GPS_RX = 44;   // D7: data from the GPS
static const int PIN_GPS_TX = 43;   // D6: data to the GPS
static const int PIN_SDA = 5;       // D4
static const int PIN_SCL = 6;       // D5
static const int PIN_LED = 4;       // D3
static const int PIN_BATT = 1;      // A0, through a 100k/100k divider
static const int PIN_PAD = 2;       // A1, through a 100k/100k divider from the Qi receiver's 5 V

static const char *TRACK = "/track.csv";

SFE_UBLOX_GNSS_SERIAL gnss;
Adafruit_BNO08x bno(-1);
Preferences prefs;

bool gpsOk = false, imuOk = false, fsOk = false;
uint32_t gpsBaud = 0;

// latest readings
struct {
  uint8_t fix = 0, sats = 0;
  int32_t lat = 0, lon = 0;         // degrees * 1e7
  float sogKn = 0, cogDeg = 0, hAccM = 0;
  uint64_t tMs = 0;                 // UTC epoch ms, 0 until the GPS has the date and time
  uint32_t pvtThisSecond = 0;
  float rateHz = 0;
} gps;
float rollRaw = 0, pitchRaw = 0;    // from the IMU, degrees
float heel = 0, pitchDeg = 0;       // after zeroing and mounting corrections

// settings kept across power cycles
int puckNum = 1;
float zeroRoll = 0, zeroPitch = 0;
bool swapAxes = false, flipHeel = false;

// recording
bool recording = false, quiet = false;
File rec;
uint32_t recStarted = 0, lastFlush = 0, recLines = 0;

// ---------- helpers ----------
static int64_t daysFromCivil(int y, unsigned m, unsigned d) {   // Howard Hinnant's algorithm
  y -= m <= 2;
  const int64_t era = (y >= 0 ? y : y - 399) / 400;
  const unsigned yoe = (unsigned)(y - era * 400);
  const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + (int64_t)doe - 719468;
}

static float readMilliVolts(int pin) {
  uint32_t sum = 0;
  for (int i = 0; i < 8; i++) sum += analogReadMilliVolts(pin);
  return sum / 8.0f * 2.0f;            // undo the 100k/100k divider
}

static int batteryPct(float mv) {      // resting single-cell LiPo, rough
  static const float V[] = {4200, 4100, 4000, 3900, 3800, 3750, 3700, 3650, 3600, 3500, 3300};
  static const int P[] = {100, 90, 78, 62, 45, 35, 22, 12, 6, 2, 0};
  if (mv >= V[0]) return 100;
  for (int i = 1; i < 11; i++)
    if (mv >= V[i]) return (int)(P[i] + (P[i - 1] - P[i]) * (mv - V[i]) / (V[i - 1] - V[i]));
  return 0;
}

static void savePrefs() {
  prefs.putInt("puck", puckNum);
  prefs.putFloat("zr", zeroRoll);
  prefs.putFloat("zp", zeroPitch);
  prefs.putBool("swap", swapAxes);
  prefs.putBool("flip", flipHeel);
}

// ---------- GPS ----------
static bool startGps() {
  static const uint32_t bauds[] = {38400, 115200, 9600, 57600, 230400};   // BE-880 usually ships at 38400
  Serial1.setRxBufferSize(4096);
  for (uint32_t b : bauds) {
    Serial1.begin(b, SERIAL_8N1, PIN_GPS_RX, PIN_GPS_TX);
    delay(50);
    if (gnss.begin(Serial1, 1200)) { gpsBaud = b; break; }
    Serial1.end();
  }
  if (!gpsBaud) return false;
  gnss.setUART1Output(COM_TYPE_UBX);        // binary only: NMEA text would crowd the link at 10 Hz
  gnss.setDynamicModel(DYN_MODEL_SEA);      // tuned for boats
  gnss.setNavigationFrequency(10);
  gnss.setAutoPVT(true);
  return true;
}

static void pollGps() {
  if (!gpsOk || !gnss.getPVT()) return;
  gps.fix = gnss.getFixType();
  gps.sats = gnss.getSIV();
  gps.lat = gnss.getLatitude();
  gps.lon = gnss.getLongitude();
  gps.sogKn = gnss.getGroundSpeed() / 1000.0f * 1.943844f;   // mm/s -> knots
  gps.cogDeg = gnss.getHeading() / 1e5f;
  gps.hAccM = gnss.getHorizontalAccEst() / 1000.0f;
  if (gnss.getDateValid() && gnss.getTimeValid()) {
    const int64_t days = daysFromCivil(gnss.getYear(), gnss.getMonth(), gnss.getDay());
    gps.tMs = (uint64_t)((days * 86400 + gnss.getHour() * 3600 + gnss.getMinute() * 60 + gnss.getSecond()) * 1000LL + gnss.getMillisecond());
  }
  gps.pvtThisSecond++;

  if (recording && gps.fix >= 2 && gps.tMs) {
    char line[112];
    const int n = snprintf(line, sizeof line, "%llu,%.7f,%.7f,%.2f,%.0f,%.1f,%.1f\n",
                           (unsigned long long)gps.tMs, gps.lat / 1e7, gps.lon / 1e7, gps.sogKn, gps.cogDeg, heel, pitchDeg);
    if (rec.write((const uint8_t *)line, n) != (size_t)n) {
      Serial.println("\n!! Flash full, recording stopped.");
      rec.close(); recording = false;
    } else recLines++;
  }
}

// ---------- IMU ----------
static bool startImu() {
  Wire.begin(PIN_SDA, PIN_SCL);
  Wire.setClock(100000);                    // the BNO08x stretches the clock; 100 kHz is the safe choice on ESP32
  if (!bno.begin_I2C(BNO08x_I2CADDR_DEFAULT, &Wire)) return false;
  // game rotation vector: gyro + accelerometer only, so metal on the boat can't upset heel and pitch
  return bno.enableReport(SH2_GAME_ROTATION_VECTOR, 20000);   // 50 Hz
}

static void pollImu() {
  if (!imuOk) return;
  if (bno.wasReset()) bno.enableReport(SH2_GAME_ROTATION_VECTOR, 20000);
  sh2_SensorValue_t v;
  while (bno.getSensorEvent(&v)) {
    if (v.sensorId != SH2_GAME_ROTATION_VECTOR) continue;
    const float w = v.un.gameRotationVector.real, x = v.un.gameRotationVector.i,
                y = v.un.gameRotationVector.j, z = v.un.gameRotationVector.k;
    rollRaw = atan2f(2 * (w * x + y * z), 1 - 2 * (x * x + y * y)) * RAD_TO_DEG;
    float s = 2 * (w * y - z * x);
    s = s > 1 ? 1 : s < -1 ? -1 : s;
    pitchRaw = asinf(s) * RAD_TO_DEG;
  }
  const float r = (swapAxes ? pitchRaw : rollRaw) - zeroRoll;
  const float p = (swapAxes ? rollRaw : pitchRaw) - zeroPitch;
  heel = flipHeel ? -r : r;
  pitchDeg = p;
}

// ---------- recording ----------
static void startRecording() {
  if (!fsOk) { Serial.println("Flash storage isn't working, can't record."); return; }
  if (recording) { Serial.println("Already recording."); return; }
  LittleFS.remove(TRACK);
  rec = LittleFS.open(TRACK, FILE_WRITE);
  if (!rec) { Serial.println("Couldn't create the track file."); return; }
  rec.print("t_ms,lat,lon,sog_kn,hdg,heel,pitch\n");
  recording = true; recStarted = millis(); recLines = 0;
  Serial.println(gps.fix >= 2 ? "Recording. Type r again to stop." : "Recording will start writing as soon as the GPS has a fix. Type r to stop.");
}

static void stopRecording() {
  if (!recording) return;
  rec.close(); recording = false;
  Serial.printf("Stopped. %lu points (%.1f minutes at 10 Hz). Type d to download it.\n", (unsigned long)recLines, recLines / 600.0f);
}

static void dumpTrack() {
  if (recording) stopRecording();
  File f = LittleFS.open(TRACK, FILE_READ);
  if (!f) { Serial.println("No track recorded yet. Type r to record one."); return; }
  char name[40] = "puck";
  // name it like a real puck file: puck<N>_<HHMMSS of the first point>.csv
  f.readStringUntil('\n');
  String first = f.readStringUntil('\n');
  uint64_t t0 = strtoull(first.c_str(), nullptr, 10);
  const uint32_t secOfDay = (uint32_t)((t0 / 1000) % 86400);
  snprintf(name, sizeof name, "puck%d_%02lu%02lu%02lu.csv", puckNum, (unsigned long)(secOfDay / 3600), (unsigned long)(secOfDay / 60 % 60), (unsigned long)(secOfDay % 60));
  f.seek(0);
  const bool wasQuiet = quiet; quiet = true;
  Serial.printf("\n---BEGIN %s---\n", name);
  uint8_t buf[512];
  size_t n;
  while ((n = f.read(buf, sizeof buf)) > 0) { Serial.write(buf, n); delay(1); }
  Serial.println("---END---");
  f.close();
  quiet = wasQuiet;
}

// ---------- status ----------
static void printStatus() {
  const float batt = readMilliVolts(PIN_BATT), pad = readMilliVolts(PIN_PAD);
  const bool onPad = pad > 4000;
  const char *chg = !onPad ? "off the pad" : batt >= 4150 ? "on the pad, full" : "on the pad, charging";
  const char *fixTxt[] = {"no fix", "dead reckoning", "2D fix", "3D fix", "GNSS+DR", "time only"};
  Serial.printf("GPS %s", gpsOk ? (gps.fix < 6 ? fixTxt[gps.fix] : "?") : "NOT FOUND");
  if (gpsOk) Serial.printf(", %u sats, %.0f Hz, +/-%.1f m | %.2f kn %03.0f deg", gps.sats, gps.rateHz, gps.hAccM, gps.sogKn, gps.cogDeg);
  if (imuOk) Serial.printf(" | heel %+5.1f pitch %+5.1f", heel, pitchDeg);
  else Serial.print(" | IMU NOT FOUND");
  if (batt > 2500) Serial.printf(" | batt %.2f V %d%%", batt / 1000, batteryPct(batt));
  else Serial.print(" | no battery");
  Serial.printf(" | %s", chg);
  if (recording) Serial.printf(" | REC %lus %lu pts", (unsigned long)((millis() - recStarted) / 1000), (unsigned long)recLines);
  Serial.println();
}

static void help() {
  Serial.printf(
    "\nWakeBack bench test, puck %d\n"
    "  h      this help\n"
    "  s      one status line now\n"
    "  q      pause/resume the status lines\n"
    "  r      start/stop recording a track\n"
    "  d      download the recorded track (copy it with tools/pull_track.py)\n"
    "  e      erase the recorded track\n"
    "  z      zero heel and pitch (sit the puck level first)\n"
    "  f      flip heel sign (heel should be + when tipped to starboard)\n"
    "  a      swap the heel and pitch axes (if tipping sideways shows as pitch)\n"
    "  p<N>   set the puck number, e.g. p3\n"
    "  i      what was found at start-up\n\n", puckNum);
}

static void report() {
  Serial.printf("GPS:     %s", gpsOk ? "found" : "NOT FOUND. Check VCC/GND, and that GPS TX goes to D7 and GPS RX to D6.\n");
  if (gpsOk) Serial.printf(" at %lu baud, set to 10 Hz, sea mode\n", (unsigned long)gpsBaud);
  Serial.printf("IMU:     %s\n", imuOk ? "found (BNO085, game rotation vector at 50 Hz)" : "NOT FOUND. Check VIN/GND, SDA to D4, SCL to D5.");
  Serial.printf("Storage: %s", fsOk ? "ok, " : "NOT WORKING\n");
  if (fsOk) Serial.printf("%.1f MB free\n", (LittleFS.totalBytes() - LittleFS.usedBytes()) / 1048576.0);
  Serial.printf("Settings: puck %d, zero roll %.1f pitch %.1f, axes %s, heel %s\n", puckNum, zeroRoll, zeroPitch, swapAxes ? "swapped" : "normal", flipHeel ? "flipped" : "normal");
}

static void command(String c) {
  c.trim();
  if (!c.length()) return;
  const char k = tolower(c[0]);
  switch (k) {
    case 'h': help(); break;
    case 's': printStatus(); break;
    case 'q': quiet = !quiet; Serial.println(quiet ? "Status lines paused (q to resume)." : "Status lines on."); break;
    case 'r': recording ? stopRecording() : startRecording(); break;
    case 'd': dumpTrack(); break;
    case 'e': if (recording) stopRecording(); LittleFS.remove(TRACK); Serial.println("Track erased."); break;
    case 'z': zeroRoll = swapAxes ? pitchRaw : rollRaw; zeroPitch = swapAxes ? rollRaw : pitchRaw; savePrefs(); Serial.println("Zeroed. Heel and pitch now read 0 in this position."); break;
    case 'f': flipHeel = !flipHeel; savePrefs(); Serial.println(flipHeel ? "Heel sign flipped." : "Heel sign normal."); break;
    case 'a': swapAxes = !swapAxes; zeroRoll = zeroPitch = 0; savePrefs(); Serial.println("Axes swapped. Sit it level and type z."); break;
    case 'p': { int n = c.substring(1).toInt(); if (n >= 1 && n <= 99) { puckNum = n; savePrefs(); Serial.printf("This is now puck %d.\n", n); } else Serial.println("Use p then a number, e.g. p3"); } break;
    case 'i': report(); break;
    default: Serial.println("Unknown command. Type h for help.");
  }
}

// ---------- LED: slow blink = no fix, steady blink = fix, double blink = recording ----------
static void led() {
  const uint32_t m = millis();
  bool on;
  if (recording) { const uint32_t p = m % 1000; on = p < 80 || (p > 200 && p < 280); }
  else if (gps.fix >= 3) on = m % 1000 < 100;
  else on = m % 2000 < 60;
  digitalWrite(PIN_LED, on);
}

void setup() {
  pinMode(PIN_LED, OUTPUT);
  digitalWrite(PIN_LED, HIGH);
  analogReadResolution(12);
  Serial.begin(115200);
  const uint32_t t = millis();
  while (!Serial && millis() - t < 3000) delay(10);   // wait briefly for the USB serial monitor

  prefs.begin("puck", false);
  puckNum = prefs.getInt("puck", 1);
  zeroRoll = prefs.getFloat("zr", 0); zeroPitch = prefs.getFloat("zp", 0);
  swapAxes = prefs.getBool("swap", false); flipHeel = prefs.getBool("flip", false);

  Serial.println("\nWakeBack bench test starting…");
  fsOk = LittleFS.begin(true);
  gpsOk = startGps();
  imuOk = startImu();
  digitalWrite(PIN_LED, LOW);
  report();
  help();
}

void loop() {
  static String in;
  static uint32_t lastStatus = 0, lastRate = 0;
  while (Serial.available()) {
    const char ch = Serial.read();
    if (ch == '\n' || ch == '\r') { command(in); in = ""; }
    else if (in.length() < 32) in += ch;
  }
  pollGps();
  pollImu();
  const uint32_t m = millis();
  if (m - lastRate >= 1000) { gps.rateHz = gps.pvtThisSecond * 1000.0f / (m - lastRate); gps.pvtThisSecond = 0; lastRate = m; }
  if (recording && m - lastFlush >= 1000) { rec.flush(); lastFlush = m; }   // a flat battery or a swim loses a second, not the track
  if (!quiet && m - lastStatus >= 1000) { printStatus(); lastStatus = m; }
  led();
}
