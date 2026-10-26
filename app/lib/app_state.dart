import 'dart:convert';
import 'dart:io';

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
import 'puck/puck_ble.dart';
import 'puck/puck_watcher.dart';
import 'sync/server_sync.dart';
import 'updates.dart';
import 'widgets/common.dart' show friendly;

/// Your WakeBack server. Change in You → Advanced if you run your own.
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

  /// Listens for your pucks over Bluetooth while the app is open and pulls their tracks by itself.
  late final PuckWatcher watcher;

  /// The viewer asked for full screen (projector / tablet): hide the app's own bars.
  final ValueNotifier<bool> fullscreen = ValueNotifier(false);

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    _docs = await getApplicationDocumentsDirectory();
    store = await _openStore(demoMode);
    dock = PocketDock(store, _asset);
    tiles = TileCache(Directory('${_docs.path}/wakeback-tiles'));
    dock.tiles = tiles;
    dock.me = () => {'name': profileName, 'email': profileEmail};
    dock.demoMode = () => demoMode;
    dock.onUpload = tracksChanged; // a track just landed (demo pucks, the import page): the Sails tab reloads and it syncs
    // the local server only serves the viewer inside the app now (pucks talk Bluetooth): loopback, any free port
    await dock.start(port: 0, address: InternetAddress.loopbackIPv4);
    demo = DemoPucks(dock.localUrl);
    PuckBle.setKeys({for (final p in myPucks) p.puck: p.key});
    watcher = PuckWatcher(store: () => store, enabled: () => !demoMode && myPucks.any((p) => p.key.isNotEmpty));
    watcher.onPulled = (r, puck) {
      if (r.tracks > 0) tracksChanged();
    };
    watcher.start();
  }

  /// Real data lives in wakeback/; the demo in its own folder so leaving the demo can wipe it cleanly.
  Future<DockStore> _openStore(bool demo) async {
    final s = DockStore(Directory('${_docs.path}/${demo ? 'wakeback-demo' : 'wakeback'}'));
    await s.init();
    s.myPucks = myPucks.map((p) => p.puck).toSet();
    s.fleet = _fleet;
    s
      ..ownerName = profileName
      ..ownerEmail = profileEmail
      ..ownerIsPerson = true
      ..defaultBoat = defaultBoat;
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

  // ------------------------------------------------------------------ app updates

  /// A newer build on GitHub than the one running, from the last check (kept until installed).
  AppUpdate? get pendingUpdate {
    try {
      return AppUpdate.fromJson(jsonDecode(_p.getString('pendingUpdate') ?? 'null'));
    } catch (_) {
      return null;
    }
  }

  /// Ask GitHub, at most every 6 hours unless [force]. Returns the update, null if up to date; throws if offline.
  Future<AppUpdate?> checkForUpdate({bool force = false}) async {
    final last = _p.getInt('lastUpdateCheck') ?? 0;
    if (!force && DateTime.now().millisecondsSinceEpoch - last < 6 * 3600 * 1000) return pendingUpdate;
    final u = await Updates.instance.check();
    await _p.setInt('lastUpdateCheck', DateTime.now().millisecondsSinceEpoch);
    if (u == null) {
      await _p.remove('pendingUpdate');
    } else {
      await _p.setString('pendingUpdate', jsonEncode(u.toJson()));
    }
    notifyListeners();
    return u;
  }

  Future<void> dismissUpdate() async {
    await _p.remove('pendingUpdate');
    notifyListeners();
  }

  // ------------------------------------------------------------------ settings

  // Typed into a text field, so it doesn't notify on every keystroke: the screens that show it read it when they build.

  /// You: owner of everything this phone records or imports (your account when signed in).
  String get profileName => _p.getString('profileName') ?? '';
  set profileName(String v) {
    _p.setString('profileName', v.trim());
    store.ownerName = v.trim();
  }

  String get profileEmail => _p.getString('profileEmail') ?? '';

  /// Rows on the Dock page: one per puck set up from this phone, so one never seen still shows.
  int get _fleet => myPucks.fold(0, (m, p) => p.puck > m ? p.puck : m);

  // ------------------------------------------------------------------ your pucks (set up from this app)

  /// Pucks you've set up from this phone: number, when, firmware seen, the server key id (0 = none, set up
  /// without an account) and the key itself, which is what lets this phone talk to the puck over Bluetooth.
  List<MyPuck> get myPucks {
    final l = _p.getStringList('myPucks') ?? const [];
    final out = <MyPuck>[];
    for (final s in l) {
      try {
        out.add(MyPuck.fromJson((jsonDecode(s) as Map).cast<String, dynamic>()));
      } catch (_) {}
    }
    out.sort((a, b) => a.puck.compareTo(b.puck));
    return out;
  }

  Future<void> putMyPuck(MyPuck p) async {
    final l = myPucks.where((x) => x.puck != p.puck).toList()..add(p);
    await _p.setStringList('myPucks', l.map((x) => jsonEncode(x.toJson())).toList());
    store
      ..myPucks = l.map((x) => x.puck).toSet()
      ..fleet = _fleet;
    PuckBle.setKeys({for (final x in l) x.puck: x.key});
    notifyListeners();
  }

  Future<void> removeMyPuck(int puck) async {
    await _p.setStringList('myPucks', myPucks.where((x) => x.puck != puck).map((x) => jsonEncode(x.toJson())).toList());
    store
      ..myPucks = myPucks.map((x) => x.puck).toSet()
      ..fleet = _fleet;
    PuckBle.setKeys({for (final x in myPucks) x.puck: x.key});
    notifyListeners();
  }

  // ------------------------------------------------------------------ boats
  /// The boats you sail ("Solo 5843", "Laser"), first is the one you usually sail.
  List<String> get boats => _p.getStringList('boats') ?? const [];
  String get defaultBoat => boats.isEmpty ? '' : boats.first;
  Future<void> setBoats(List<String> v) async {
    final clean = <String>[];
    for (final b in v) {
      final t = b.trim();
      if (t.isNotEmpty && !clean.contains(t) && clean.length < 12) clean.add(t.length > 40 ? t.substring(0, 40) : t);
    }
    await _p.setStringList('boats', clean);
    store.defaultBoat = defaultBoat;
    notifyListeners();
  }

  /// The boat the next recording is for: the one you picked on the Record tab (it stays picked for next
  /// time), else your usual boat. '' = none.
  String get recordBoat {
    final b = _p.getString('recordBoat');
    if (b == null) return defaultBoat;
    return b.isEmpty || boats.contains(b) ? b : defaultBoat; // a boat since removed from your list
  }

  Future<void> setRecordBoat(String b) async {
    await _p.setString('recordBoat', b.trim());
    notifyListeners();
  }

  /// A boat named on a session that isn't in the list yet: keep it, so it's there next time.
  Future<void> rememberBoat(String b) async {
    if (b.trim().isEmpty || boats.contains(b.trim())) return;
    await setBoats([...boats, b.trim()]);
  }

  // ------------------------------------------------------------------ recording with the phone
  /// GPS fixes worse than this many metres are left out of a phone recording.
  int get recordMaxAcc => _p.getInt('recordMaxAcc') ?? 30;
  set recordMaxAcc(int v) {
    _p.setInt('recordMaxAcc', v.clamp(5, 100));
    notifyListeners();
  }

  /// A track was added outside the dock (e.g. a phone recording): lists reload, and it's sent up soon.
  void tracksChanged() {
    _lastSync = 0;
    notifyListeners();
  }

  // ------------------------------------------------------------------ sync on its own
  bool _syncing = false;
  int _lastSync = 0;

  /// How the last sync went, for the cloud on the Sails tab:
  /// 'idle' (not run yet) | 'syncing' | 'ok' | 'attention' (a course differs) | 'offline' | 'error'.
  final ValueNotifier<String> syncStatus = ValueNotifier('idle');

  /// What went wrong last time, in plain English (null when it went fine).
  String? syncProblem;

  /// Signed in: bring this device and the server level (new sails up, yours and your friends' down)
  /// without being asked. At most every 5 minutes unless [force]. Null = didn't run. Throws
  /// SyncException if the server can't be reached.
  Future<SyncReport?> autoSync({bool force = false}) async {
    if (!signedIn || demoMode || _syncing) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastSync < 5 * 60 * 1000) return null;
    _syncing = true;
    _lastSync = now;
    syncStatus.value = 'syncing';
    try {
      final r = await ServerSync(serverUrl, store, token: token).syncNew();
      syncWent(r);
      if (r.up + r.down > 0) notifyListeners();
      return r;
    } catch (e) {
      await syncFailed(e);
      rethrow;
    } finally {
      _syncing = false;
    }
  }

  /// A sync (automatic or from the Sync page) finished: the cloud on the Sails tab shows how it went.
  void syncWent(SyncReport r) {
    syncProblem = null;
    syncStatus.value = r.conflictDays.isEmpty ? 'ok' : 'attention';
  }

  /// A sync failed. If the server no longer knows our sign-in, sign out here too so nothing keeps trying.
  Future<void> syncFailed(Object e) async {
    if (e is SyncException) {
      syncProblem = e.signedOut ? 'Signed out: log in again' : e.message;
      syncStatus.value = e.offline ? 'offline' : 'error';
      if (e.signedOut && signedIn) await signOut(tellServer: false);
    } else {
      syncProblem = friendly(e);
      syncStatus.value = 'error';
    }
  }
}

AppState get app => AppState.instance;

/// A puck set up from this phone (see AppState.myPucks).
class MyPuck {
  final int puck, keyId, setUpMs;
  final String fw;

  /// The account key the puck holds (empty: set up without one, or before keys were kept on the phone — Set up
  /// again gives it a fresh one). The puck only talks to a phone that can prove it has this.
  final String key;
  const MyPuck({required this.puck, this.keyId = 0, required this.setUpMs, this.fw = '', this.key = ''});
  MyPuck copyWith({String? fw}) => MyPuck(puck: puck, keyId: keyId, setUpMs: setUpMs, fw: fw ?? this.fw, key: key);
  static MyPuck fromJson(Map<String, dynamic> j) => MyPuck(
      puck: (j['puck'] as num).toInt(), keyId: (j['keyId'] as num?)?.toInt() ?? 0, setUpMs: (j['setUpMs'] as num?)?.toInt() ?? 0, fw: '${j['fw'] ?? ''}', key: '${j['key'] ?? ''}');
  Map<String, dynamic> toJson() => {'puck': puck, 'keyId': keyId, 'setUpMs': setUpMs, 'fw': fw, 'key': key};
}
