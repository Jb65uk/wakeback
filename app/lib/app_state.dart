import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'demo/demo_pucks.dart';
import 'dock/pocket_dock.dart';
import 'dock/store.dart';

class AppState extends ChangeNotifier {
  AppState._();
  static final AppState instance = AppState._();

  late final SharedPreferences _p;
  late final DockStore store;
  late final PocketDock dock;
  late final DemoPucks demo;
  final DockSettings dockSettings = DockSettings();

  /// Set if port 5000 couldn't be opened (pucks then can't reach the phone; replays still work).
  String? dockError;

  /// The viewer asked for full screen (projector / tablet): hide the app's own bars.
  final ValueNotifier<bool> fullscreen = ValueNotifier(false);

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    final docs = await getApplicationDocumentsDirectory();
    store = DockStore(Directory('${docs.path}/wakeback'));
    await store.init();
    store.fleet = fleet;
    store
      ..ownerName = profileName
      ..ownerEmail = profileEmail
      ..ownerIsPerson = true;
    dockSettings.wifi = hotspotName;
    dock = PocketDock(store, _asset, dockSettings);
    try {
      await dock.start(port: 5000);
    } catch (e) {
      dockError = 'Couldn\'t open port 5000 ($e). Replays work, but pucks can\'t upload to this phone until the app restarts.';
      await dock.start(port: 0, address: InternetAddress.loopbackIPv4);
    }
    demo = DemoPucks(dock.localUrl);
  }

  static Future<Uint8List?> _asset(String name) async {
    try {
      final bd = await rootBundle.load('assets/web/$name');
      return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
    } catch (_) {
      return null;
    }
  }

  // ---- settings
  String get serverUrl => _p.getString('serverUrl') ?? '';
  set serverUrl(String v) {
    var u = v.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.isNotEmpty && !u.startsWith('http://') && !u.startsWith('https://')) {
      // the dock Pi / a PC on the LAN is plain http; a public server name gets https
      final host = u.split('/').first;
      final lan = RegExp(r'^\d{1,3}(\.\d{1,3}){3}(:\d+)?$').hasMatch(host) || host.contains('.local') || host.contains(':') || !host.contains('.');
      u = '${lan ? 'http' : 'https'}://$u';
    }
    _p.setString('serverUrl', u);
    notifyListeners();
  }

  /// The phone hotspot pucks and mates join (shown on the Dock page and in its WiFi QR code).
  String get hotspotName => _p.getString('hotspotName') ?? 'wakeback';
  set hotspotName(String v) {
    final s = v.trim().isEmpty ? 'wakeback' : v.trim();
    _p.setString('hotspotName', s);
    dockSettings.wifi = s;
    notifyListeners();
  }

  /// Kept for setting up pucks to join this phone's hotspot (stage 4).
  String get hotspotPass => _p.getString('hotspotPass') ?? '';
  set hotspotPass(String v) {
    _p.setString('hotspotPass', v);
    notifyListeners();
  }

  /// You: owner of everything this phone records or imports. Your email is never shown to other sailors.
  String get profileName => _p.getString('profileName') ?? '';
  set profileName(String v) {
    _p.setString('profileName', v.trim());
    store.ownerName = v.trim();
    notifyListeners();
  }

  String get profileEmail => _p.getString('profileEmail') ?? '';
  set profileEmail(String v) {
    _p.setString('profileEmail', v.trim());
    store.ownerEmail = v.trim();
    notifyListeners();
  }

  /// How many pucks you have, so ones never seen still get a row on the Dock page.
  int get fleet => _p.getInt('fleet') ?? 0;
  set fleet(int v) {
    _p.setInt('fleet', v.clamp(0, 16));
    store.fleet = v.clamp(0, 16);
    notifyListeners();
  }
}

AppState get app => AppState.instance;
