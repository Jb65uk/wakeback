// The compact track format (.wbt): about four times smaller than the CSV, so the same flash holds four
// times the sailing. The puck only ever writes this; it turns it back into exactly the CSV the docks and
// the viewer expect as it uploads or serves a track, so nothing outside the puck changes.
//
// Layout: 8-byte header "WBT1" + puck number (u8) + 3 spare, then records:
//   key    (0x01, 24 bytes)  t_ms u64, lat i32, lon i32 (1e-7 deg), sog u16 (0.01 kn), cog u16 (0.1 deg),
//                            heel i16 (0.1 deg), pitch i16 (0.1 deg)   — the absolute values, every KEY_EVERY points
//   delta  (0x02, 10 bytes)  dt u16 (ms), dlat i16, dlon i16 (1e-7 deg), sog u16, cog u16 (0.1 deg) — heel and pitch
//                            packed as i8 each (0.5 deg steps, clamped ±63°) in the last 2 bytes → actually 12 bytes:
//                            dt u16, dlat i16, dlon i16, sog u16, cog u16, heel i8, pitch i8
// A delta that won't fit (big jump, long gap) is written as a key instead. Average ~12.2 bytes/point.
#pragma once
#include <Arduino.h>
#include <LittleFS.h>

static const uint8_t WBT_KEY = 0x01, WBT_DELTA = 0x02;
static const int KEY_EVERY = 64;

struct TrackPoint { uint64_t tMs; int32_t lat, lon; float sogKn, cogDeg, heel, pitch; };

// ---- writing ----
struct TrackWriter {
  bool have = false; int sinceKey = 0;
  uint64_t tMs = 0; int32_t lat = 0, lon = 0;
  void reset() { have = false; sinceKey = 0; }
  static void put16(uint8_t *b, int v) { b[0] = v & 0xFF; b[1] = (v >> 8) & 0xFF; }
  static void put32(uint8_t *b, int32_t v) { for (int i = 0; i < 4; i++) b[i] = (v >> (8 * i)) & 0xFF; }
  static void put64(uint8_t *b, uint64_t v) { for (int i = 0; i < 8; i++) b[i] = (v >> (8 * i)) & 0xFF; }
  static uint8_t clamp8(float v) { int i = lroundf(v * 2); if (i > 127) i = 127; if (i < -127) i = -127; return (uint8_t)(int8_t)i; }

  // encode one point into buf (≤ 25 bytes); returns the length
  int encode(const TrackPoint &p, uint8_t *buf) {
    const int64_t dt = (int64_t)p.tMs - (int64_t)tMs, dlat = (int64_t)p.lat - lat, dlon = (int64_t)p.lon - lon;
    const bool fits = have && sinceKey < KEY_EVERY && dt >= 0 && dt < 65536 && dlat > -32768 && dlat < 32768 && dlon > -32768 && dlon < 32768;
    tMs = p.tMs; lat = p.lat; lon = p.lon; have = true;
    const uint16_t sog = (uint16_t)constrain(lroundf(p.sogKn * 100), 0, 65535), cog = (uint16_t)(lroundf(fmodf(p.cogDeg + 360, 360) * 10) % 3600);
    if (fits) {
      sinceKey++;
      buf[0] = WBT_DELTA; put16(buf + 1, (int)dt); put16(buf + 3, (int)dlat); put16(buf + 5, (int)dlon);
      put16(buf + 7, sog); put16(buf + 9, cog); buf[11] = clamp8(p.heel); buf[12] = clamp8(p.pitch);
      return 13;
    }
    sinceKey = 0;
    buf[0] = WBT_KEY; put64(buf + 1, p.tMs); put32(buf + 9, p.lat); put32(buf + 13, p.lon);
    put16(buf + 17, sog); put16(buf + 19, cog);
    put16(buf + 21, (int)constrain(lroundf(p.heel * 10), -32768, 32767)); put16(buf + 23, (int)constrain(lroundf(p.pitch * 10), -32768, 32767));
    return 25;
  }
};

static void wbtHeader(uint8_t *b, int puck) { memcpy(b, "WBT1", 4); b[4] = (uint8_t)puck; b[5] = b[6] = b[7] = 0; }

// ---- reading back as CSV ----
static const char *CSV_HEAD = "t_ms,lat,lon,sog_kn,hdg,heel,pitch\n";

struct TrackReader {
  File f; bool ok = false, have = false;
  uint64_t tMs = 0; int32_t lat = 0, lon = 0;
  static int get16(const uint8_t *b) { return (int16_t)(b[0] | (b[1] << 8)); }
  static uint16_t getu16(const uint8_t *b) { return (uint16_t)(b[0] | (b[1] << 8)); }
  static int32_t get32(const uint8_t *b) { return (int32_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24)); }
  static uint64_t get64(const uint8_t *b) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = (v << 8) | b[i]; return v; }

  bool open(const String &path) {
    f = LittleFS.open(path, FILE_READ);
    uint8_t h[8];
    ok = f && f.read(h, 8) == 8 && memcmp(h, "WBT1", 4) == 0;
    have = false;
    return ok;
  }
  void close() { if (f) f.close(); ok = false; }
  bool isWbt() const { return ok; }

  // next point as a CSV line; false at the end. line must hold 112 bytes.
  bool next(char *line, int &n) {
    uint8_t b[25];
    if (!ok || f.read(b, 1) != 1) return false;
    TrackPoint p;
    if (b[0] == WBT_KEY) {
      if (f.read(b + 1, 24) != 24) return false;
      p.tMs = get64(b + 1); p.lat = get32(b + 9); p.lon = get32(b + 13);
      p.sogKn = getu16(b + 17) / 100.0f; p.cogDeg = getu16(b + 19) / 10.0f; p.heel = get16(b + 21) / 10.0f; p.pitch = get16(b + 23) / 10.0f;
    } else if (b[0] == WBT_DELTA && have) {
      if (f.read(b + 1, 12) != 12) return false;
      p.tMs = tMs + getu16(b + 1); p.lat = lat + get16(b + 3); p.lon = lon + get16(b + 5);
      p.sogKn = getu16(b + 7) / 100.0f; p.cogDeg = getu16(b + 9) / 10.0f; p.heel = (int8_t)b[11] / 2.0f; p.pitch = (int8_t)b[12] / 2.0f;
    } else return false;                                  // corrupt or cut short: stop here, keep what we had
    tMs = p.tMs; lat = p.lat; lon = p.lon; have = true;
    n = snprintf(line, 112, "%llu,%.7f,%.7f,%.2f,%.0f,%.1f,%.1f\n", (unsigned long long)p.tMs, p.lat / 1e7, p.lon / 1e7, p.sogKn, p.cogDeg, p.heel, p.pitch);
    return true;
  }
};

// the CSV length a .wbt file decodes to (for Content-Length): one pass, no output
static size_t wbtCsvLength(const String &path) {
  TrackReader r; if (!r.open(path)) return 0;
  size_t total = strlen(CSV_HEAD); char line[112]; int n;
  while (r.next(line, n)) total += n;
  r.close();
  return total;
}

// stream a track as CSV to any Print (a WiFiClient, the web server's client); calls tick() between chunks
template <typename F>
static bool wbtStreamCsv(const String &path, Print &out, F tick) {
  TrackReader r; if (!r.open(path)) return false;
  out.print(CSV_HEAD);
  char buf[1024]; int used = 0; char line[112]; int n; int count = 0;
  while (r.next(line, n)) {
    if (used + n > (int)sizeof buf) { if (out.write((uint8_t *)buf, used) != (size_t)used) { r.close(); return false; } used = 0; tick(); }
    memcpy(buf + used, line, n); used += n;
    if (++count % 500 == 0) tick();
  }
  if (used && out.write((uint8_t *)buf, used) != (size_t)used) { r.close(); return false; }
  r.close();
  return true;
}
