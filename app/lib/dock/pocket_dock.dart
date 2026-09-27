// The dock, on the phone. Same URLs and replies as server/app.py, so:
//   - the real viewer (index.html), Dock page and phone-upload page run unchanged in the app
//   - pucks on the phone's hotspot check in and upload exactly as they would to the Pi
//   - mates on the hotspot can open http://<phone>:5000/upload and send their phone GPX
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';
import 'package:qr/qr.dart';

import 'store.dart';

typedef AssetLoader = Future<Uint8List?> Function(String name);

class DockSettings {
  String wifi = 'wakeback'; // the phone hotspot name pucks/phones join
  String wifiPass = '';
  String hostname = 'WakeBack phone';
}

class PocketDock {
  final DockStore store;
  final AssetLoader assets;
  final DockSettings settings;
  HttpServer? _server;
  final DateTime _boot = DateTime.now();

  PocketDock(this.store, this.assets, this.settings);

  int get port => _server?.port ?? 0;
  bool get running => _server != null;
  String get localUrl => 'http://127.0.0.1:$port';

  /// Pucks expect the dock on port 5000. [address] defaults to every interface so the hotspot can reach it.
  Future<void> start({int port = 5000, InternetAddress? address}) async {
    _server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port, shared: true);
    _server!.autoCompress = true;
    _server!.listen((req) {
      _handle(req);
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  // ------------------------------------------------------------------ plumbing

  static const _types = {
    'html': 'text/html; charset=utf-8',
    'js': 'application/javascript; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'csv': 'text/csv; charset=utf-8',
    'gpx': 'application/gpx+xml',
    'svg': 'image/svg+xml',
    'png': 'image/png',
    'json': 'application/json',
  };

  String _typeFor(String name) => _types[name.split('.').last.toLowerCase()] ?? 'application/octet-stream';

  Future<void> _send(HttpRequest req, int status, List<int> body, String type, {bool noStore = false}) async {
    final res = req.response;
    res.statusCode = status;
    res.headers.set(HttpHeaders.contentTypeHeader, type);
    if (noStore) res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    res.add(body);
    await res.close();
  }

  Future<void> _json(HttpRequest req, Object? value, [int status = 200]) =>
      _send(req, status, utf8.encode(jsonEncode(value)), 'application/json', noStore: true);

  Future<Object?> _body(HttpRequest req) async {
    final mt = req.headers.contentType?.mimeType ?? '';
    final text = await utf8.decodeStream(req);
    if (mt != 'application/json' && !(mt.startsWith('application/') && mt.endsWith('+json'))) return null;
    if (text.trim().isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null; // like Flask's get_json(silent=True)
    }
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      await _route(req);
    } on DockError catch (e) {
      await _json(req, {'error': e.message}, e.status);
    } catch (e) {
      try {
        await _json(req, {'error': 'dock error: $e'}, 500);
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------------ pages

  static const _leafletCss = 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css';
  static const _leafletJs = 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js';
  static const _pages = {'index.html', 'dock.html', 'upload.html', 'leaflet.js', 'leaflet.css'};

  Future<void> _page(HttpRequest req, String name) async {
    if (!_pages.contains(name)) throw const DockError(404, 'not found');
    final bytes = await assets(name);
    if (bytes == null) throw const DockError(404, 'not found');
    if (name.endsWith('.html')) {
      // Leaflet from the app, not the CDN — so replays work at the lake with no signal
      final html = utf8.decode(bytes).replaceAll(_leafletCss, '/viewer/leaflet.css').replaceAll(_leafletJs, '/viewer/leaflet.js');
      return _send(req, 200, utf8.encode(html), _typeFor(name));
    }
    return _send(req, 200, bytes, _typeFor(name));
  }

  // ------------------------------------------------------------------ router

  Future<void> _route(HttpRequest req) async {
    final m = req.method.toUpperCase();
    final seg = req.uri.pathSegments.where((s) => s.isNotEmpty).toList();

    if (m == 'GET' && seg.isEmpty) return _page(req, 'index.html');
    if (m == 'GET' && seg.length == 1 && seg[0] == 'dock') return _page(req, 'dock.html');
    if (m == 'GET' && seg.length == 1 && seg[0] == 'upload') return _page(req, 'upload.html');
    if (m == 'GET' && seg.length == 2 && seg[0] == 'viewer') return _page(req, seg[1]);
    if (seg.isEmpty || seg[0] != 'api') throw const DockError(404, 'not found');

    final api = seg.sublist(1);
    final path = api.join('/');

    // sessions
    if (m == 'GET' && path == 'sessions') return _json(req, await store.sessions());
    if (api.length == 3 && api[0] == 'sessions') {
      final day = api[1], what = api[2];
      if (what == 'meta' || what == 'races' || what == 'crew') {
        if (m == 'GET') {
          if (!safeName.hasMatch(day)) throw const DockError(400, 'bad day');
          return _json(req, what == 'meta' ? await store.getMeta(day) : what == 'races' ? await store.getRaces(day) : await store.getCrew(day));
        }
        if (m == 'PUT') {
          final body = await _body(req);
          return _json(req, what == 'meta' ? await store.putMeta(day, body) : what == 'races' ? await store.putRaces(day, body) : await store.putCrew(day, body));
        }
      }
      if (m == 'GET') {
        final f = await store.trackFile(day, what);
        return _send(req, 200, await f.readAsBytes(), _typeFor(what));
      }
      if (m == 'DELETE') {
        await store.deleteTrack(day, what);
        return _json(req, {'ok': true});
      }
    }
    if (m == 'POST' && path == 'upload') return _upload(req);
    if (m == 'GET' && path == 'sailors') return _json(req, await store.sailors());

    // phone uploads
    if (m == 'GET' && path == 'dockinfo') {
      return _json(req, {'wifi': settings.wifi, 'password': settings.wifiPass, 'upload_url': await _uploadUrl(req)});
    }
    if (m == 'GET' && api.length == 2 && api[0] == 'qr') {
      final what = api[1];
      String data;
      if (what == 'wifi.svg') {
        data = _wifiQrText();
      } else if (what == 'upload.svg') {
        data = await _uploadUrl(req);
      } else {
        throw const DockError(404, 'not found');
      }
      return _send(req, 200, utf8.encode(qrSvg(data)), 'image/svg+xml', noStore: true);
    }

    // pucks
    if (m == 'POST' && path == 'pucks/checkin') return _json(req, await store.checkin(await _body(req)));
    if (m == 'GET' && path == 'pucks') return _json(req, await store.pucks());
    if (m == 'GET' && path == 'hello') return _json(req, {'dock': 'wakeback', 'time_ms': DateTime.now().millisecondsSinceEpoch});

    // dock health — a phone can't manage WiFi, so say so (the Dock page hides the WiFi button)
    if (m == 'GET' && path == 'dock/status') return _json(req, await _status());
    if (m == 'GET' && path == 'wifi/scan') return _json(req, {'available': false, 'networks': []});
    if (m == 'POST' && path == 'wifi/connect') {
      throw const DockError(400, 'The phone can\'t change WiFi from here — use Android\'s WiFi / hotspot settings.');
    }
    throw const DockError(404, 'not found');
  }

  Future<void> _upload(HttpRequest req) async {
    final ct = req.headers.contentType;
    final boundary = ct?.parameters['boundary'];
    if (ct == null || ct.mimeType != 'multipart/form-data' || boundary == null) {
      throw const DockError(400, 'no file');
    }
    final fields = <String, String>{};
    String? fileName;
    Uint8List? fileBytes;
    await for (final part in MimeMultipartTransformer(boundary).bind(req)) {
      final disp = part.headers['content-disposition'] ?? '';
      final name = RegExp(r'(?:^|;)\s*name="([^"]*)"').firstMatch(disp)?.group(1);
      final filename = RegExp(r'filename="([^"]*)"').firstMatch(disp)?.group(1);
      final bb = BytesBuilder(copy: false);
      await for (final chunk in part) {
        bb.add(chunk);
      }
      final bytes = bb.takeBytes();
      if (name == 'file' && filename != null) {
        fileName = filename;
        fileBytes = bytes;
      } else if (name != null) {
        fields[name] = utf8.decode(bytes, allowMalformed: true);
      }
    }
    if (fileName == null || fileName.isEmpty || fileBytes == null) throw const DockError(400, 'no file');
    return _json(req, await store.upload(fileName, fileBytes, puck: fields['puck'] ?? '', sailor: fields['sailor'] ?? ''));
  }

  // ------------------------------------------------------------------ phone-specific bits

  /// Addresses other devices can reach this phone on (hotspot first).
  static Future<List<String>> lanAddresses() async {
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      int rank(NetworkInterface i) {
        final n = i.name.toLowerCase();
        if (n.contains('ap') || n.contains('swlan') || n.contains('softap')) return 0; // hotspot
        if (n.startsWith('wlan')) return 1;
        if (n.startsWith('eth')) return 2;
        return 3; // mobile data etc.
      }

      ifs.sort((a, b) => rank(a).compareTo(rank(b)));
      final out = <String>[];
      for (final i in ifs) {
        if (rank(i) == 3) continue;
        for (final a in i.addresses) {
          if (!a.isLoopback) out.add(a.address);
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<String> _uploadUrl(HttpRequest req) async {
    final host = req.headers.host ?? '';
    // opened from another device (mate on the hotspot): use the address they used
    if (host.isNotEmpty && host != '127.0.0.1' && host != 'localhost') {
      return 'http://$host${req.headers.port != 80 ? ':${req.headers.port}' : ''}/upload';
    }
    final ips = await lanAddresses();
    return ips.isEmpty ? 'http://<phone>:$port/upload' : 'http://${ips.first}:$port/upload';
  }

  String _wifiQrText() {
    String esc(String v) => v.replaceAllMapped(RegExp(r'([\\;,:"])'), (m) => '\\${m[1]}');
    final pass = settings.wifiPass;
    return 'WIFI:T:${pass.isNotEmpty ? 'WPA' : 'nopass'};S:${esc(settings.wifi)};${pass.isNotEmpty ? 'P:${esc(pass)};' : ''};';
  }

  Future<bool> _online() async {
    try {
      final s = await Socket.connect('1.1.1.1', 53, timeout: const Duration(milliseconds: 1500));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _status() async {
    return {
      'online': await _online(),
      'networks': <Object>[],
      'can_manage_wifi': false,
      'demo': false,
      'uplink_if': '',
      'dock_wifi': settings.wifi,
      'pin_required': false,
      'hostname': settings.hostname,
      'time_ms': DateTime.now().millisecondsSinceEpoch,
      'uptime_s': DateTime.now().difference(_boot).inSeconds,
      'disk_free': null, // Android doesn't tell us cheaply; the Dock page shows "n/a"
      'disk_total': null,
      'sessions': await store.dayCount(),
      'nas': null,
      'phone': true,
    };
  }
}

/// A QR code as a standalone SVG (with xmlns, so an <img> shows it). Same colours as app.py.
String qrSvg(String data, {int scale = 8, int border = 2}) {
  final code = QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M);
  final img = QrImage(code);
  final n = img.moduleCount;
  final size = (n + border * 2) * scale;
  final sb = StringBuffer('<?xml version="1.0" encoding="utf-8"?>\n'
      '<svg xmlns="http://www.w3.org/2000/svg" width="$size" height="$size" viewBox="0 0 $size $size">'
      '<rect width="$size" height="$size" fill="#FFFFFF"/><path fill="#13293A" d="');
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (img.isDark(r, c)) sb.write('M${(c + border) * scale} ${(r + border) * scale}h${scale}v${scale}h-${scale}z');
    }
  }
  sb.write('"/></svg>');
  return sb.toString();
}
