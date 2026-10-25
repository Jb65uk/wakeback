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
  static String ssidFor(int puck) => '$prefix$puck';

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

  /// Join a puck's setup WiFi: any "wakeback-puck-*" (the phone's dialog lists them; the user picks one),
  /// or exactly [ssid] when given. Resolves once the phone is on it and this app's traffic is routed there;
  /// throws with a readable message if the user said no or no puck's WiFi is about.
  static Future<void> join({String ssid = ''}) async {
    final what = ssid.isEmpty ? 'the puck\'s WiFi ($prefix…)' : '"$ssid"';
    try {
      await _ch.invokeMethod<bool>('join', {'ssid': ssid, 'prefix': prefix});
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
  final String fw, ssid, wifiMode, orientation;
  final int batteryPct, gpsFix, sats, tracks;
  final bool onPad, recording, autoRec, twistLearned;
  final Map<String, dynamic> raw;

  PuckStatus._(this.raw)
      : puck = _i(raw['puck']) ?? 0,
        fw = '${raw['fw'] ?? ''}',
        ssid = '${_m(raw['wifi'])['ssid'] ?? ''}',
        wifiMode = '${_m(raw['wifi'])['mode'] ?? ''}',
        orientation = '${_m(raw['imu'])['orientation'] ?? 'unknown'}',
        batteryPct = _i(_m(raw['batt'])['pct']) ?? -1,
        gpsFix = _i(_m(raw['gps'])['fix']) ?? 0,
        sats = _i(_m(raw['gps'])['sats']) ?? 0,
        onPad = _m(raw['batt'])['on_pad'] == true,
        recording = _m(raw['rec'])['on'] == true,
        autoRec = raw['autorec'] != false,
        twistLearned = _m(raw['imu'])['twist_learned'] == true,
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
