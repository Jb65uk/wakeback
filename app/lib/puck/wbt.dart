// The puck's compact track format (.wbt), decoded on the phone into exactly the CSV the dock writes.
// A Dart port of firmware/puck/src/track.h (TrackReader): keep the two in step.
//
//   header  8 bytes   "WBT1", puck number (u8), 3 spare
//   key     0x01 + 24 bytes   t_ms u64, lat i32, lon i32 (1e-7 deg), sog u16 (0.01 kn), cog u16 (0.1 deg), heel i16, pitch i16 (0.1 deg)
//   delta   0x02 + 12 bytes   dt u16 (ms), dlat i16, dlon i16, sog u16, cog u16, heel i8, pitch i8 (0.5 deg)
// All little-endian. A corrupt or cut-short record ends the track; what came before is kept.
import 'dart:convert';
import 'dart:typed_data';

class Wbt {
  static const csvHead = 't_ms,lat,lon,sog_kn,hdg,heel,pitch\n';

  static bool isWbt(Uint8List b) => b.length >= 8 && b[0] == 0x57 && b[1] == 0x42 && b[2] == 0x54 && b[3] == 0x31; // "WBT1"

  /// The puck number from the header, or null if it isn't a .wbt.
  static int? puckOf(Uint8List b) => isWbt(b) ? b[4] : null;

  /// Decode to CSV bytes (UTF-8). Returns null if [b] isn't a .wbt at all.
  static Uint8List? toCsv(Uint8List b) {
    if (!isWbt(b)) return null;
    final d = ByteData.sublistView(b);
    final out = StringBuffer(csvHead);
    var i = 8;
    var have = false;
    var tMs = 0, lat = 0, lon = 0;
    while (i < b.length) {
      final type = b[i];
      double sog, cog, heel, pitch;
      if (type == 0x01) {
        if (i + 25 > b.length) break;
        tMs = _u64(d, i + 1);
        lat = d.getInt32(i + 9, Endian.little);
        lon = d.getInt32(i + 13, Endian.little);
        sog = d.getUint16(i + 17, Endian.little) / 100;
        cog = d.getUint16(i + 19, Endian.little) / 10;
        heel = d.getInt16(i + 21, Endian.little) / 10;
        pitch = d.getInt16(i + 23, Endian.little) / 10;
        i += 25;
      } else if (type == 0x02 && have) {
        if (i + 13 > b.length) break;
        tMs += d.getUint16(i + 1, Endian.little);
        lat += d.getInt16(i + 3, Endian.little);
        lon += d.getInt16(i + 5, Endian.little);
        sog = d.getUint16(i + 7, Endian.little) / 100;
        cog = d.getUint16(i + 9, Endian.little) / 10;
        heel = d.getInt8(i + 11) / 2;
        pitch = d.getInt8(i + 12) / 2;
        i += 13;
      } else {
        break;
      }
      have = true;
      // the same formatting as the firmware's "%llu,%.7f,%.7f,%.2f,%.0f,%.1f,%.1f"
      out
        ..write(tMs)
        ..write(',')
        ..write((lat / 1e7).toStringAsFixed(7))
        ..write(',')
        ..write((lon / 1e7).toStringAsFixed(7))
        ..write(',')
        ..write(sog.toStringAsFixed(2))
        ..write(',')
        ..write(cog.round())
        ..write(',')
        ..write(heel.toStringAsFixed(1))
        ..write(',')
        ..write(pitch.toStringAsFixed(1))
        ..write('\n');
    }
    return Uint8List.fromList(utf8.encode(out.toString()));
  }

  /// How many points a .wbt holds (a track under 10 points isn't worth keeping, same as the puck).
  static int points(Uint8List b) {
    if (!isWbt(b)) return 0;
    var i = 8, n = 0, have = false;
    while (i < b.length) {
      if (b[i] == 0x01 && i + 25 <= b.length) {
        i += 25;
      } else if (b[i] == 0x02 && have && i + 13 <= b.length) {
        i += 13;
      } else {
        break;
      }
      have = true;
      n++;
    }
    return n;
  }

  // u64 as a Dart int: times are epoch ms, far below 2^53, so no precision lost
  static int _u64(ByteData d, int at) => d.getUint32(at, Endian.little) + d.getUint32(at + 4, Endian.little) * 4294967296;
}

/// CRC-32 (IEEE, the zlib one), what the puck reports for a track it sent.
class Crc32 {
  static final _table = _make();
  static List<int> _make() {
    final t = List<int>.filled(256, 0);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      t[n] = c;
    }
    return t;
  }

  static int of(List<int> bytes, [int crc = 0]) {
    var c = crc ^ 0xFFFFFFFF;
    for (final b in bytes) {
      c = _table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
