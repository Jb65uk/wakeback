// Talking to a puck in setup mode: join its WiFi ("wakeback-puck-N", no password) and use the same
// little HTTP API its setup page uses (firmware/puck/src/main.cpp, startWeb()).
//
// Joining is Android-only (android_src/MainActivity.kt): the system asks "Connect to device
// wakeback-puck-3?", the phone keeps its mobile data, and this app's traffic is pinned to the puck
// until [PuckWifi.leave]. On anything else (or if the user would rather), joining the network by hand
// in WiFi settings works too: the puck is always at http://192.168.4.1.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class PuckWifi {
  static const _ch = MethodChannel('wakeback/puck_wifi');

  static const prefix = 'wakeback-puck-';

  /// Can this phone join the puck's WiFi from the app (Android 10+)?
  static Future<bool> supported() async {
    try {
      return await _ch.invokeMethod<bool>('supported') ?? false;
    } on MissingPluginException {
      return false; // not Android, or a build without the native bit
    } catch (_) {
      return false;
    }
  }

  /// Join a puck's setup WiFi: any "wakeback-puck-*" (the phone's dialog lists them; the user picks one).
  /// Resolves once the phone is on it and this app's traffic is routed there; throws with a readable
  /// message if the user said no or no puck's WiFi is about.
  static Future<void> join() async {
    const what = 'the puck\'s WiFi ($prefix…)';
    try {
      await _ch.invokeMethod<bool>('join', {'prefix': prefix});
    } on PlatformException catch (e) {
      throw PuckException(switch (e.code) {
        'unavailable' => 'Couldn\'t find $what. Is the puck in setup mode (hold the button 6 s: five quick blinks), and did you tap Connect?',
        'lost' => 'Lost the puck\'s WiFi. Put it back in setup mode and try again.',
        'unsupported' => 'This phone can\'t join the puck from the app. Join $what in WiFi settings instead, then come back here.',
        _ => e.message ?? 'Couldn\'t join $what',
      });
    } on MissingPluginException {
      throw PuckException('Join $what in your phone\'s WiFi settings, then come back here.');
    }
  }

  /// Open Android's hotspot settings. False if that didn't work (the user finds it under Settings).
  static Future<bool> hotspotSettings() async {
    try {
      return await _ch.invokeMethod<bool>('hotspotSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> leave() async {
    try {
      await _ch.invokeMethod<bool>('leave');
    } catch (_) {}
  }
}

class PuckException implements Exception {
  final String message;
  const PuckException(this.message);
  @override
  String toString() => message;
}

/// What a puck says about itself on /api/status (the bits the app shows; shape from firmware/puck statusJson()).
class PuckStatus {
  final int puck;
  final String fw;
  final int batteryPct, tracks;
  final bool autoRec;
  final Map<String, dynamic> raw;

  PuckStatus._(this.raw)
      : puck = _i(raw['puck']) ?? 0,
        fw = '${raw['fw'] ?? ''}',
        batteryPct = _i(_m(raw['batt'])['pct']) ?? -1,
        autoRec = raw['autorec'] != false,
        tracks = raw['tracks'] is List ? (raw['tracks'] as List).length : 0;

  static int? _i(Object? v) => v is num ? v.toInt() : int.tryParse('$v');
  static Map<String, dynamic> _m(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};

  bool get isPuck => raw.containsKey('puck') && raw.containsKey('fw');
}

/// The puck's own HTTP API while it's in setup mode.
class PuckApi {
  final String base;
  PuckApi([this.base = 'http://192.168.4.1']);
  static const _timeout = Duration(seconds: 6);

  Future<PuckStatus> status() async {
    http.Response r;
    try {
      r = await http.get(Uri.parse('$base/api/status')).timeout(_timeout);
    } on TimeoutException {
      throw const PuckException('The puck didn\'t answer. Are you on its WiFi?');
    } catch (e) {
      throw PuckException('Can\'t reach the puck: $e');
    }
    if (r.statusCode != 200) throw PuckException('The puck answered HTTP ${r.statusCode}');
    try {
      return PuckStatus._((jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, dynamic>());
    } catch (_) {
      throw const PuckException('That isn\'t a WakeBack puck (unexpected reply).');
    }
  }

  /// POST /api/settings: hotspot name + password, puck number, the key, auto-record. Empty strings are left out.
  Future<void> settings({int? puck, String? ssid, String? pass, String? key, bool? autoRec}) => _post('/api/settings', {
        if (puck != null) 'puck': '$puck',
        if (ssid != null && ssid.isNotEmpty) 'ssid': ssid,
        if (pass != null && pass.isNotEmpty) 'pass': pass,
        if (key != null) 'key': key,
        if (autoRec != null) 'autorec': autoRec ? '1' : '0',
      });

  /// Leave setup mode now (the puck turns its WiFi off and goes looking for the hotspot/dock).
  Future<void> done() => _post('/api/setup/done', const {});

  /// Push a firmware image (puck.bin). The puck writes it and restarts; a bad image rolls back by itself.
  Future<void> flash(List<int> bin, {void Function(double)? progress}) async {
    final req = http.MultipartRequest('POST', Uri.parse('$base/update'))
      ..files.add(http.MultipartFile.fromBytes('firmware', bin, filename: 'puck.bin'));
    http.StreamedResponse res;
    try {
      res = await req.send().timeout(const Duration(minutes: 3));
    } on TimeoutException {
      throw const PuckException('The puck didn\'t finish taking the update. Are you still on its WiFi?');
    } catch (e) {
      throw PuckException('Couldn\'t send the update: $e');
    }
    final body = await res.stream.bytesToString();
    if (res.statusCode != 200 || !body.contains('written')) throw PuckException(body.isEmpty ? 'The puck refused the update (HTTP ${res.statusCode})' : body);
  }

  Future<void> _post(String path, Map<String, String> form) async {
    http.Response r;
    try {
      r = await http.post(Uri.parse('$base$path'), body: form).timeout(_timeout);
    } on TimeoutException {
      throw const PuckException('The puck didn\'t answer. Are you still on its WiFi?');
    } catch (e) {
      throw PuckException('Can\'t reach the puck: $e');
    }
    if (r.statusCode != 200) throw PuckException('The puck said no (HTTP ${r.statusCode})');
  }
}

/// How to get at a puck right now: over the hotspot if it's on the pad and checked in, else its setup WiFi.
class PuckReach {
  final String base; // http://host
  final bool viaSetupWifi;
  const PuckReach(this.base, this.viaSetupWifi);

  /// The puck's address on the hotspot, from the phone dock's last check-in (null if not docked now).
  static Future<String?> hotspotAddress(int puck) async {
    for (final p in await dockPucks()) {
      if ((p['puck'] as num?)?.toInt() == puck && p['docked'] == true && p['ip'] is String && (p['ip'] as String).isNotEmpty) return 'http://${p['ip']}';
    }
    return null;
  }

  static int dockPort = 5000;

  static Future<List<Map<String, dynamic>>> dockPucks() async {
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:$dockPort/api/pucks')).timeout(const Duration(seconds: 4));
      if (r.statusCode != 200) return const [];
      final j = (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, dynamic>();
      return ((j['pucks'] as List?) ?? const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    } catch (_) {
      return const [];
    }
  }

  static bool docked(List<Map<String, dynamic>> pucks, int puck) =>
      pucks.any((p) => (p['puck'] as num?)?.toInt() == puck && p['docked'] == true);

  /// Hotspot first (no buttons to hold), then the puck's own WiFi (the user is told to hold the button).
  /// [onStep] gets a line to show while it works.
  static Future<PuckReach> find(int puck, {void Function(String)? onStep, bool allowSetupWifi = true}) async {
    // On the pad the puck only has its radio on for a moment each minute, so: ask the dock to tell it (in
    // its next check-in reply) to stay on, then keep trying its address until it answers.
    onStep?.call('Looking for puck $puck on the hotspot…');
    try {
      await http.post(Uri.parse('http://127.0.0.1:$dockPort/api/pucks/$puck/hold')).timeout(const Duration(seconds: 3));
    } catch (_) {}
    final deadline = DateTime.now().add(const Duration(seconds: 80));
    var told = false;
    while (DateTime.now().isBefore(deadline)) {
      final addr = await hotspotAddress(puck);
      if (addr != null) {
        try {
          final st = await PuckApi(addr).status();
          if (st.isPuck) return PuckReach(addr, false);
        } catch (_) {}
      } else if (!docked(await dockPucks(), puck)) {
        break; // not on the pad as far as the dock knows: no point waiting for a check-in
      }
      if (!told) {
        told = true;
        onStep?.call('Puck $puck is on the pad. Waiting for its next check-in (up to a minute)…');
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    if (!allowSetupWifi) throw PuckException('Puck $puck didn\'t answer on the hotspot. Is it on the pad with the hotspot on?');
    onStep?.call('Not on the hotspot. Hold the puck\'s button 6 s (five quick blinks), then tap Connect when your phone asks…');
    await PuckWifi.join();
    final st = await PuckApi().status();
    if (!st.isPuck) throw const PuckException('That network isn\'t a WakeBack puck.');
    return const PuckReach('http://192.168.4.1', true);
  }

  Future<void> release() async {
    if (viaSetupWifi) await PuckWifi.leave();
  }
}
