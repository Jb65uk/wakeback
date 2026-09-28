import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth/auth_api.dart';
import 'demo/demo_pucks.dart';
import 'dock/pocket_dock.dart';
import 'dock/store.dart';
import 'dock/tiles.dart';

/// Your WakeBack server. Change in Setup → Advanced if you run your own.
const String kDefaultServer = 'https://wakeback.bridgesolutions.uk';

class AppState extends ChangeNotifier {
  AppState._();
  static final AppState instance = AppState._();

  late final SharedPreferences _p;
  late Directory _docs;
  late DockStore store;
  late final PocketDock dock;
  late final TileCache tiles;
  late final DemoPucks demo;
  final DockSettings dockSettings = DockSettings();

  /// Set if port 5000 couldn't be opened (pucks then can't reach the phone; replays still work).
  String? dockError;

  /// The viewer asked for full screen (projector / tablet): hide the app's own bars.
  final ValueNotifier<bool> fullscreen = ValueNotifier(false);

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    _docs = await getApplicationDocumentsDirectory();
    store = await _openStore(demoMode);
    dockSettings.wifi = hotspotName;
    dock = PocketDock(store, _asset, dockSettings);
    tiles = TileCache(Directory('${_docs.path}/wakeback-tiles'));
    dock.tiles = tiles;
    dock.me = () => {'name': profileName, 'email': profileEmail};
    dock.demoMode = () => demoMode;
    try {
      await dock.start(port: 5000);
    } catch (e) {
      dockError = 'Couldn\'t open port 5000 ($e). Replays work, but pucks can\'t upload to this phone until the app restarts.';
      await dock.start(port: 0, address: InternetAddress.loopbackIPv4);
    }
    demo = DemoPucks(dock.localUrl);
  }

  /// Real data lives in wakeback/; the demo in its own folder so leaving the demo can wipe it cleanly.
  Future<DockStore> _openStore(bool demo) async {
    final s = DockStore(Directory('${_docs.path}/${demo ? 'wakeback-demo' : 'wakeback'}'));
    await s.init();
    s.fleet = fleet;
    s
      ..ownerName = profileName
      ..ownerEmail = profileEmail
      ..ownerIsPerson = true;
    return s;
  }

  static Future<Uint8List?> _asset(String name) async {
    try {
      final bd = await rootBundle.load('assets/web/$name');
      return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------ demo mode

  bool get demoMode => _p.getBool('demoMode') ?? false;

  Future<void> setDemoMode(bool on) async {
    if (on == demoMode) return;
    final old = store;
    if (!on) demo.stop();
    await _p.setBool('demoMode', on);
    store = await _openStore(on);
    dock.store = store; // new requests go to the right data from here on
    notifyListeners();
    if (!on) {
      // leaving the demo: throw the demo data away once anything in flight on the old store has finished
      await old.locked(() async {
        final d = Directory('${_docs.path}/wakeback-demo');
        if (await d.exists()) await d.delete(recursive: true);
      });
    }
  }

  // ------------------------------------------------------------------ account

  String get serverUrl => _p.getString('serverUrl') ?? kDefaultServer;
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
    _p.setString('serverUrl', u.isEmpty ? kDefaultServer : u);
    notifyListeners();
  }

  String? get token => _p.getString('token');
  Account? get account {
    final s = _p.getString('account');
    if (s == null) return null;
    try {
      return Account.fromJson((jsonDecode(s) as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  bool get signedIn => token != null && account != null;

  /// Seen the welcome screen (signed in, or chose demo / no account)?
  bool get welcomed => _p.getBool('welcomed') ?? false;
  Future<void> setWelcomed() async {
    await _p.setBool('welcomed', true);
    notifyListeners();
  }

  AuthApi get auth => AuthApi(serverUrl, token: token);

  Future<void> signedInAs(String token, Account user) async {
    await _p.setString('token', token);
    await _p.setString('account', jsonEncode(user.toJson()));
    await _p.setBool('welcomed', true);
    // your account is who owns what this phone records
    await _p.setString('profileName', user.name);
    await _p.setString('profileEmail', user.email);
    store
      ..ownerName = user.name
      ..ownerEmail = user.email;
    notifyListeners();
  }

  Future<void> signOut({bool tellServer = true}) async {
    if (tellServer && token != null) unawaited(auth.logout()); // best effort, never blocks the button
    await _p.remove('token');
    await _p.remove('account');
    await _p.remove('profileEmail');
    store.ownerEmail = '';
    notifyListeners();
  }

  // ------------------------------------------------------------------ personal bests

  /// Tracks the Sessions tab has already looked at for records ('session/file'). Null = never looked (first run).
  Set<String>? get seenTracks {
    final l = _p.getStringList('seenTracks');
    return l?.toSet();
  }

  Future<void> setSeenTracks(Set<String> s) => _p.setStringList('seenTracks', s.toList());

  /// The "new record" card until it's dismissed: JSON list of {title, value, when}.
  List<Map<String, dynamic>> get recordCard {
    try {
      return ((jsonDecode(_p.getString('recordCard') ?? '[]') as List).cast<Map>()).map((m) => m.cast<String, dynamic>()).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> setRecordCard(List<Map<String, dynamic>> v) async {
    await _p.setString('recordCard', jsonEncode(v));
    notifyListeners();
  }

  // ------------------------------------------------------------------ settings

  /// The phone hotspot pucks join (shown on the Dock page).
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

  /// You: owner of everything this phone records or imports (your account when signed in).
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
