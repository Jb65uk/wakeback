// Offline maps: the phone's dock serves map tiles from a cache on the phone, filling it from the tile
// servers when there's signal. "Download this venue" in Setup fills it ahead of a trip to the lake.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

class TileLayer {
  final String id, url, ext; // url with {z} {x} {y}
  final int maxZoom;
  const TileLayer(this.id, this.url, this.ext, this.maxZoom);
  Uri at(int z, int x, int y) => Uri.parse(url.replaceAll('{z}', '$z').replaceAll('{x}', '$x').replaceAll('{y}', '$y'));
}

/// The same layers the viewer uses (viewer/index.html), by the short names in its in-app tile URLs.
const tileLayers = {
  'sat': TileLayer('sat', 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', 'jpg', 19),
  'osm': TileLayer('osm', 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', 'png', 19),
  'sea': TileLayer('sea', 'https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png', 'png', 18),
};

const _ua = 'WakeBack/1.0 (sailing tracker; github.com/Jb65uk/wakeback)';

class TileCache {
  final Directory dir;
  TileCache(this.dir);

  final _client = http.Client();

  File _file(String layer, int z, int x, int y) => File('${dir.path}/$layer/$z/$x/$y');

  /// The tile's bytes: from the cache, else fetched (and kept). Null when neither works.
  Future<List<int>?> get(String layer, int z, int x, int y) async {
    final l = tileLayers[layer];
    if (l == null || z < 0 || z > l.maxZoom || x < 0 || y < 0 || x >= (1 << z) || y >= (1 << z)) return null;
    final f = _file(layer, z, x, y);
    try {
      if (await f.exists()) return await f.readAsBytes();
    } catch (_) {}
    return _fetch(l, z, x, y, f);
  }

  Future<List<int>?> _fetch(TileLayer l, int z, int x, int y, File f) async {
    try {
      final r = await _client.get(l.at(z, x, y), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(r.bodyBytes, flush: true);
      await tmp.rename(f.path);
      return r.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// Which tiles cover a circle of [radiusM] round (lat, lon) at zooms [z0]..[z1].
  static List<(int, int, int)> tilesAround(double lat, double lon, double radiusM, int z0, int z1) {
    final out = <(int, int, int)>[];
    for (var z = z0; z <= z1; z++) {
      final n = 1 << z;
      double xOf(double lo) => (lo + 180) / 360 * n;
      double yOf(double la) {
        final r = la * math.pi / 180;
        return (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n;
      }
      final dLat = radiusM / 111320, dLon = radiusM / (111320 * math.cos(lat * math.pi / 180));
      final x0 = xOf(lon - dLon).floor(), x1 = xOf(lon + dLon).floor();
      final y0 = yOf(lat + dLat).floor(), y1 = yOf(lat - dLat).floor();
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          if (x >= 0 && y >= 0 && x < n && y < n) out.add((z, x, y));
        }
      }
    }
    return out;
  }

  /// Fill the cache for a venue. Reports (done, total); returns how many tiles couldn't be fetched.
  Future<int> download(double lat, double lon, {double radiusM = 2500, int z0 = 12, int z1 = 17, List<String> layers = const ['sat', 'osm'], void Function(int done, int total)? progress, bool Function()? cancelled}) async {
    final want = <(String, int, int, int)>[];
    for (final layer in layers) {
      final l = tileLayers[layer];
      if (l == null) continue;
      for (final (z, x, y) in tilesAround(lat, lon, radiusM, z0, math.min(z1, l.maxZoom))) {
        want.add((layer, z, x, y));
      }
    }
    var done = 0, failed = 0;
    progress?.call(0, want.length);
    // a few at a time: kind to the tile servers, quick enough for a venue (a couple of thousand tiles)
    const parallel = 4;
    for (var i = 0; i < want.length; i += parallel) {
      if (cancelled?.call() == true) break;
      final batch = want.sublist(i, math.min(i + parallel, want.length));
      final results = await Future.wait(batch.map((t) async {
        final (layer, z, x, y) = t;
        final f = _file(layer, z, x, y);
        if (await f.exists()) return true;
        return await _fetch(tileLayers[layer]!, z, x, y, f) != null;
      }));
      for (final ok in results) {
        done++;
        if (!ok) failed++;
      }
      progress?.call(done, want.length);
    }
    return failed;
  }

  /// Bytes on disk and tile count.
  Future<(int, int)> usage() async {
    var bytes = 0, n = 0;
    if (!await dir.exists()) return (0, 0);
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          bytes += await e.length();
          n++;
        } catch (_) {}
      }
    }
    return (bytes, n);
  }

  Future<void> clear() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
