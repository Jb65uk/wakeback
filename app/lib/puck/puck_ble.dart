// Talking to a puck over Bluetooth LE — the only way anything talks to a puck. It just has to be awake
// (on the pad, or press its button). Protocol in firmware/puck/src/ble.h:
//
//   command  (write)         one text line: "hello", "auth <hmac>", "status", "set puck=3&key=…", "level",
//                            "orient 1", "tracks", "get <name> [offset]", "done <name>", "rec start", "sleep", "ota …"
//   reply    (notify)        the answer as JSON, sent in MTU-sized chunks and finished with "\n"
//   data     (notify)        the raw bytes of a track while a "get" runs
//   ota      (write, no response)   raw firmware bytes between "ota begin <bytes>" and "ota end"
//
// Every puck advertises as "WakeBack puck N" with two bytes of a hash of its key, so the app can list the ones
// that are yours and connect to one by number. A puck with a key only talks after the app proves it holds that
// key: "hello" gives a nonce, "auth" answers with HMAC-SHA256(key, nonce). The key never goes over the air.
// Errors come out as [PuckException] with a sentence a sailor can act on.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'wbt.dart';

class PuckException implements Exception {
  final String message;
  const PuckException(this.message);
  @override
  String toString() => message;
}

/// A puck seen in a scan: its number (from the name), signal strength, the device it was, and whose it looks
/// to be (the owner hash from its advert matched against the keys this phone holds).
class PuckSeen {
  final int puck;
  final int rssi;
  final String id;

  /// 0x0000 = the puck has no key yet (anyone can set it up); else two bytes of SHA-256 of its key.
  final int ownerHash;

  /// Finished tracks waiting on it, from its advert (0 for firmware that doesn't say).
  final int pending;
  const PuckSeen({required this.puck, required this.rssi, required this.id, required this.ownerHash, this.pending = 0});

  bool get unpaired => ownerHash == 0;

  /// One of this phone's pucks (the hash matches a key we hold)?
  bool get mine => unpaired ? false : PuckBle.keyForHash(ownerHash) != null;

  /// "good" / "fair" / "weak", from the signal strength.
  String get signal => rssi >= -65 ? 'good signal' : rssi >= -80 ? 'fair signal' : 'weak signal';

  @override
  String toString() => 'WakeBack puck $puck ($signal)';
}

/// What a puck says about itself to "status" (the bits the app shows; shape from firmware/puck statusJson()).
class PuckStatus {
  final int puck;
  final String fw;
  final int batteryPct, tracks, pending, recHz, stopMin, sleepMin, mag;
  final bool autoRec, autoOff, onPad, charging, batteryFull, recording, locked, pairing, twistLearned, flip;
  final double heel, pitch, sogKn, twist, zeroHeel, zeroPitch;
  final int gpsFix, sats;
  final String orientation; // "deck", "thwart" or "unknown"
  final Map<String, dynamic> raw;

  PuckStatus.fromMap(this.raw)
      : puck = _i(raw['puck']) ?? 0,
        fw = '${raw['fw'] ?? ''}',
        batteryPct = _i(_m(raw['batt'])['pct']) ?? -1,
        onPad = _m(raw['batt'])['on_pad'] == true,
        charging = _m(raw['batt'])['charging'] == 'charging',
        batteryFull = _m(raw['batt'])['charging'] == 'full',
        recording = _m(raw['rec'])['on'] == true,
        autoRec = raw['autorec'] != false,
        autoOff = raw['autooff'] != false,
        recHz = _i(raw['rec_hz']) ?? 5,
        stopMin = _i(raw['stop_min']) ?? 10,
        sleepMin = _i(raw['sleep_min']) ?? 30,
        twist = _d(_m(raw['imu'])['twist']),
        twistLearned = _m(raw['imu'])['twist_learned'] == true,
        orientation = '${_m(raw['imu'])['orientation'] ?? 'unknown'}',
        mag = _i(_m(raw['imu'])['mag']) ?? 0,
        zeroHeel = _d(_m(raw['imu'])['zero_heel']),
        zeroPitch = _d(_m(raw['imu'])['zero_pitch']),
        flip = _m(raw['imu'])['flip'] == true,
        locked = raw['locked'] == true,
        pairing = raw['pairing'] == true,
        tracks = _i(_m(raw['store'])['files']) ?? 0,
        pending = _i(_m(raw['store'])['pending']) ?? 0,
        heel = _d(_m(raw['imu'])['heel']),
        pitch = _d(_m(raw['imu'])['pitch']),
        sogKn = _d(_m(raw['gps'])['sog']),
        gpsFix = _i(_m(raw['gps'])['fix']) ?? 0,
        sats = _i(_m(raw['gps'])['sats']) ?? 0;

  static int? _i(Object? v) => v is num ? v.toInt() : int.tryParse('$v');
  static double _d(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
  static Map<String, dynamic> _m(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};

  bool get isPuck => raw.containsKey('puck') && raw.containsKey('fw');
}

/// A track on the puck, from "tracks".
class PuckTrack {
  final String name;
  final int bytes;
  final bool open; // still being recorded: can't be pulled yet
  const PuckTrack(this.name, this.bytes, this.open);
}

class PuckBle {
  static const _svc = '7a4e0001-9b9d-4a3f-8e1a-3c2b1d0a5f01';
  static const _cmd = '7a4e0002-9b9d-4a3f-8e1a-3c2b1d0a5f01';
  static const _rsp = '7a4e0003-9b9d-4a3f-8e1a-3c2b1d0a5f01';
  static const _ota = '7a4e0004-9b9d-4a3f-8e1a-3c2b1d0a5f01';
  static const _dat = '7a4e0005-9b9d-4a3f-8e1a-3c2b1d0a5f01';

  static const namePrefix = 'WakeBack puck ';
  static String nameOf(int puck) => '$namePrefix$puck';

  /// The puck number from an advertised name, or null if it isn't one of ours.
  static int? puckFromName(String name) {
    if (!name.startsWith(namePrefix)) return null;
    final n = int.tryParse(name.substring(namePrefix.length).trim());
    return n != null && n >= 1 && n <= 99 ? n : null;
  }

  // ---------------------------------------------------------------- keys this phone holds

  /// Puck number → key, for the pucks set up from this phone (AppState keeps it current). The owner hash in a
  /// puck's advert is matched against these, and the key is what "auth" is answered with.
  static final Map<int, String> keys = {};
  static final Map<int, String> _byHash = {};

  static void setKeys(Map<int, String> k) {
    keys
      ..clear()
      ..addAll(k);
    _byHash.clear();
    for (final key in k.values) {
      if (key.isNotEmpty) _byHash[hashOf(key)] = key;
    }
  }

  /// The two-byte owner hash a puck advertises for [key]: the first two bytes of SHA-256(key).
  static int hashOf(String key) {
    final d = sha256.convert(utf8.encode(key)).bytes;
    return (d[0] << 8) | d[1];
  }

  static String? keyForHash(int h) => _byHash[h];

  static const _bluetoothOff = 'Turn Bluetooth on';
  static String _notFound(int puck) => 'Couldn\'t find puck $puck nearby. Is it awake? (press its button, or put it on the pad)';

  /// Does this phone have Bluetooth, and is it on? (The phone asks for the Bluetooth permissions itself the
  /// first time the app scans or connects.)
  static Future<bool> available() async {
    try {
      if (!await FlutterBluePlus.isSupported) return false;
      var state = FlutterBluePlus.adapterStateNow;
      if (state == BluetoothAdapterState.unknown) {
        state = await FlutterBluePlus.adapterState.where((s) => s != BluetoothAdapterState.unknown).first.timeout(const Duration(seconds: 3), onTimeout: () => BluetoothAdapterState.unknown);
      }
      return state == BluetoothAdapterState.on;
    } catch (_) {
      return false;
    }
  }

  /// Bluetooth must be on, or this throws "Turn Bluetooth on".
  static Future<void> _requireOn() async {
    if (!await FlutterBluePlus.isSupported) throw const PuckException('This phone has no Bluetooth, and that\'s the only way to talk to a puck.');
    if (!await available()) throw const PuckException(_bluetoothOff);
  }

  /// A readable sentence for whatever the Bluetooth stack threw.
  static PuckException _readable(Object e, {int? puck}) {
    if (e is PuckException) return e;
    final d = e is FlutterBluePlusException ? e.description ?? '$e' : '$e';
    final l = d.toLowerCase();
    if (l.contains('permission')) return const PuckException('Bluetooth permission was refused. Allow "Nearby devices" for WakeBack in your phone\'s settings and try again.');
    if (l.contains('bluetooth must be turned on') || (l.contains('adapter') && l.contains('off'))) return const PuckException(_bluetoothOff);
    if (l.contains('timeout') || l.contains('timed out')) return PuckException(puck == null ? 'The puck didn\'t answer in time. Is it awake and close by?' : _notFound(puck));
    if (l.contains('disconnected') || l.contains('not connected')) return const PuckException('Lost the Bluetooth link to the puck. Is it still awake and close by?');
    return PuckException('Bluetooth trouble: $d');
  }

  /// Something else is on the link right now (the puck screen, or the background pull): callers wait their turn.
  static bool busy = false;

  /// The pucks nearby, as they're seen (the same puck again when its signal changes). Stops after [timeout];
  /// cancelling the subscription stops it sooner. Every WakeBack puck in range is reported; [PuckSeen.mine]
  /// says whether it's one of this phone's.
  static Stream<PuckSeen> scan({Duration timeout = const Duration(seconds: 8)}) {
    late StreamController<PuckSeen> out;
    StreamSubscription<List<ScanResult>>? results;
    StreamSubscription<bool>? scanning;
    final seen = <String, int>{}; // device id -> last rssi reported, so the list isn't spammed
    Future<void> stop() async {
      await results?.cancel();
      await scanning?.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }

    out = StreamController<PuckSeen>(
      onListen: () async {
        try {
          await _requireOn();
          results = FlutterBluePlus.onScanResults.listen((list) {
            for (final r in list) {
              final p = _asPuck(r);
              if (p == null) continue;
              final last = seen[p.id];
              if (last != null && (last - p.rssi).abs() < 6) continue;
              seen[p.id] = p.rssi;
              if (!out.isClosed) out.add(p);
            }
          });
          var started = false;
          scanning = FlutterBluePlus.isScanning.listen((on) {
            if (on) {
              started = true;
            } else if (started && !out.isClosed) {
              out.close();
            }
          });
          await FlutterBluePlus.startScan(timeout: timeout, withServices: [Guid(_svc)], androidUsesFineLocation: false);
        } catch (e) {
          if (!out.isClosed) {
            out.addError(_readable(e));
            await out.close();
          }
        }
      },
      onCancel: stop,
    );
    return out.stream;
  }

  static PuckSeen? _asPuck(ScanResult r) {
    var name = r.advertisementData.advName;
    if (name.isEmpty) name = r.device.platformName;
    final n = puckFromName(name);
    if (n == null) return null;
    var hash = 0, pending = 0;
    final mfg = r.advertisementData.manufacturerData[0xFFFF];
    if (mfg != null && mfg.length >= 2) hash = (mfg[0] << 8) | mfg[1];
    if (mfg != null && mfg.length >= 3) pending = mfg[2];
    return PuckSeen(puck: n, rssi: r.rssi, id: r.device.remoteId.str, ownerHash: hash, pending: pending);
  }

  /// Find "WakeBack puck N" nearby, connect and (when it has a key) prove this phone holds it. Throws a readable
  /// [PuckException] if it isn't about or isn't ours. With [key] given, that key is used instead of the stored one
  /// (setting a puck up again with a fresh key).
  static Future<PuckBle> connect(int puck, {Duration timeout = const Duration(seconds: 12), String? key}) async {
    await _requireOn();
    PuckSeen? found;
    try {
      found = await scan(timeout: timeout).firstWhere((p) => p.puck == puck);
    } on StateError {
      found = null; // the scan ended without it
    } catch (e) {
      throw _readable(e, puck: puck);
    }
    if (found == null) throw PuckException(_notFound(puck));
    return connectTo(found, key: key);
  }

  /// Connect to a puck a scan just found, and authenticate if it's locked and we hold its key (or [key]).
  /// A locked puck we have no key for connects but stays [authed] = false: only "hello" works; the caller
  /// says so, or (in the pairing window) hands it a key with [settings].
  static Future<PuckBle> connectTo(PuckSeen seen, {String? key}) async {
    final dev = BluetoothDevice.fromId(seen.id);
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      await dev.connect(timeout: const Duration(seconds: 15), mtu: 247);
      final services = await dev.discoverServices();
      BluetoothCharacteristic? cmd, rsp, ota, dat;
      for (final s in services) {
        if (s.uuid != Guid(_svc)) continue;
        for (final c in s.characteristics) {
          if (c.uuid == Guid(_cmd)) cmd = c;
          if (c.uuid == Guid(_rsp)) rsp = c;
          if (c.uuid == Guid(_ota)) ota = c;
          if (c.uuid == Guid(_dat)) dat = c;
        }
      }
      if (cmd == null || rsp == null || ota == null) {
        await dev.disconnect();
        throw const PuckException('That isn\'t a WakeBack puck (no puck service), or its firmware is too old for Bluetooth.');
      }
      if (dat == null) {
        await dev.disconnect();
        throw const PuckException('That puck\'s firmware is too old for this app (no track stream). Update it from the PC once, then it updates from here.');
      }
      final b = PuckBle._(seen.puck, dev, cmd, rsp, ota, dat);
      await b._listen();
      await b._hello(key ?? keys[seen.puck] ?? keyForHash(seen.ownerHash));
      return b;
    } catch (e) {
      try {
        await dev.disconnect();
      } catch (_) {}
      throw _readable(e, puck: seen.puck);
    }
  }

  // ---------------------------------------------------------------- one connection

  final int puck;
  final BluetoothDevice _dev;
  final BluetoothCharacteristic _cmdC, _rspC, _otaC, _datC;
  StreamSubscription<List<int>>? _notify, _data;
  final _buf = <int>[];
  Completer<Map<String, dynamic>>? _waiting;
  BytesBuilder? _sink; // where track bytes go while a "get" runs
  void Function(int)? _onData;
  PuckBle._(this.puck, this._dev, this._cmdC, this._rspC, this._otaC, this._datC);

  /// What "hello" said: the puck's firmware, whether it has a key, whether its pairing window is open.
  String fw = '';
  bool locked = false, pairing = false;

  /// This phone proved it holds the puck's key (or the puck has none yet: nothing to prove).
  bool authed = false;

  /// Bytes a single write-without-response can carry (the puck's firmware chunks are this size).
  int get chunkSize {
    final mtu = _dev.mtuNow;
    return mtu > 23 ? mtu - 3 : 20;
  }

  bool get isConnected => _dev.isConnected;

  /// True while connected, then false when the link drops (the puck went to sleep, walked out of range…).
  Stream<bool> get connected => _dev.connectionState.map((s) => s == BluetoothConnectionState.connected);

  Future<void> _listen() async {
    await _rspC.setNotifyValue(true);
    _notify = _rspC.onValueReceived.listen((chunk) {
      _buf.addAll(chunk);
      final nl = _buf.indexOf(10);
      if (nl < 0) return;
      final line = utf8.decode(_buf.sublist(0, nl), allowMalformed: true);
      _buf.removeRange(0, nl + 1);
      final w = _waiting;
      if (w == null || w.isCompleted) return;
      try {
        final j = jsonDecode(line);
        if (j is Map) {
          w.complete(j.cast<String, dynamic>());
        } else {
          w.completeError(const PuckException('The puck sent something the app didn\'t understand.'));
        }
      } catch (_) {
        w.completeError(const PuckException('The puck sent something the app didn\'t understand.'));
      }
    });
    await _datC.setNotifyValue(true);
    _data = _datC.onValueReceived.listen((chunk) {
      final s = _sink;
      if (s == null) return;
      s.add(chunk);
      _onData?.call(s.length);
    });
  }

  /// "hello", then "auth" with [key] if the puck is locked and we have one.
  Future<void> _hello(String? key) async {
    final h = await command('hello');
    fw = '${h['fw'] ?? ''}';
    locked = h['locked'] == true;
    pairing = h['pairing'] == true;
    if (!locked) {
      authed = true;
      return;
    }
    if (key == null || key.isEmpty) return;
    final nonce = _unhex('${h['nonce'] ?? ''}');
    if (nonce.length != 16) throw const PuckException('The puck sent a bad hello. Try again.');
    final mac = Hmac(sha256, utf8.encode(key)).convert(nonce).bytes;
    try {
      await command('auth ${_hex(mac)}');
      authed = true;
    } on PuckException catch (e) {
      if (e.message.contains('Not your puck')) {
        authed = false;
        return;
      }
      rethrow;
    }
  }

  /// Throws if the puck won't talk to this phone: not set up from here, or set up again elsewhere since.
  void _needAuth() {
    if (!authed) {
      throw PuckException(pairing
          ? 'Puck $puck has a key this phone doesn\'t hold, but its pairing window is open: Set up a puck gives it yours.'
          : 'Puck $puck isn\'t yours on this phone (set up from another phone, or set up again since). Hold its button 6 seconds, then Set up a puck here.');
    }
  }

  /// Send one command line and wait for its JSON reply. A reply with "ok": false becomes a [PuckException]
  /// carrying the puck's own message.
  Future<Map<String, dynamic>> command(String line, {Duration timeout = const Duration(seconds: 10)}) async {
    if (!_dev.isConnected) throw const PuckException('Not connected to the puck any more. Is it still awake and close by?');
    if (_waiting != null && !_waiting!.isCompleted) throw const PuckException('Still waiting for the puck\'s last answer.');
    final w = _waiting = Completer<Map<String, dynamic>>();
    _buf.clear();
    try {
      await _cmdC.write(utf8.encode(line), timeout: math.max(5, math.min(120, timeout.inSeconds)));
      final j = await w.future.timeout(timeout, onTimeout: () => throw const PuckException('The puck didn\'t answer. Is it still awake and close by?'));
      if (j['ok'] == false) throw PuckException('${j['msg'] ?? 'The puck said no.'}');
      return j;
    } catch (e) {
      throw _readable(e, puck: puck);
    } finally {
      if (identical(_waiting, w)) _waiting = null;
    }
  }

  /// What the puck says about itself.
  Future<PuckStatus> status() async {
    _needAuth();
    final st = PuckStatus.fromMap(await command('status'));
    if (!st.isPuck) throw const PuckException('That isn\'t a WakeBack puck (unexpected reply).');
    return st;
  }

  /// Puck number, the key, auto-record, auto-off, logging rate (1, 2, 5 or 10 points a second while moving).
  /// Allowed without auth only while the puck's pairing window is open (or it has no key yet); the puck decides.
  /// Giving it a key makes this link authed.
  Future<void> settings({int? puck, String? key, bool? autoRec, bool? autoOff, int? rate, int? stopMin, int? sleepMin}) async {
    if (!authed && !pairing && locked) _needAuth();
    final form = {
      if (puck != null) 'puck': '$puck',
      if (key != null && key.isNotEmpty) 'key': key,
      if (autoRec != null) 'autorec': autoRec ? '1' : '0',
      if (autoOff != null) 'autooff': autoOff ? '1' : '0',
      if (rate != null) 'rate': '$rate',
      if (stopMin != null) 'stopmin': '$stopMin',
      if (sleepMin != null) 'sleepmin': '$sleepMin',
    };
    final enc = form.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
    await command('set $enc');
    if (key != null && key.isNotEmpty) {
      authed = true;
      locked = true;
      pairing = false;
    }
  }

  /// Heel and pitch read 0 as the boat sits now.
  Future<void> level() => _authed('level');

  /// 1 = mounted on deck, 2 = under the thwart.
  Future<void> orient(int o) => _authed('orient $o');

  Future<void> startRecording() => _authed('rec start');
  Future<void> stopRecording() => _authed('rec stop');

  /// The puck goes to sleep; the link drops straight after.
  Future<void> sleep() => _authed('sleep');

  Future<void> reboot() => _authed('reboot');

  Future<Map<String, dynamic>> _authed(String line, {Duration timeout = const Duration(seconds: 10)}) {
    _needAuth();
    return command(line, timeout: timeout);
  }

  // ---------------------------------------------------------------- tracks

  /// The tracks on the puck.
  Future<List<PuckTrack>> tracks() async {
    final j = await _authed('tracks');
    return [
      for (final t in (j['tracks'] as List? ?? const []))
        if (t is Map) PuckTrack('${t['name']}', (t['bytes'] as num?)?.toInt() ?? 0, t['open'] == true),
    ];
  }

  /// Pull one track's raw bytes. The puck streams them on the data characteristic, then answers with the byte
  /// count and CRC-32; a short or corrupt transfer is asked for again from where it stopped, a few times.
  /// [progress] gets bytes so far and the total.
  Future<Uint8List> getTrack(PuckTrack t, {void Function(int got, int total)? progress}) async {
    _needAuth();
    var whole = BytesBuilder(copy: false);
    var have = 0;
    for (var attempt = 0; attempt < 6; attempt++) {
      final part = BytesBuilder(copy: false);
      _sink = part;
      _onData = (n) => progress?.call(have + n, t.bytes);
      Map<String, dynamic> j;
      try {
        // generous: a 1.4 MB track at a slow 10 kB/s is well under this
        j = await command('get ${t.name} $have', timeout: Duration(seconds: 30 + (t.bytes - have) ~/ 5000));
      } finally {
        _sink = null;
        _onData = null;
      }
      final got = part.takeBytes();
      final total = (j['bytes'] as num?)?.toInt() ?? t.bytes;
      final want = total - have;
      if (got.length >= want) {
        // all of the remainder arrived (CRC of the part and of the whole file both have to agree)
        whole.add(got.length == want ? got : got.sublist(0, want));
        final all = whole.takeBytes();
        final partOk = got.length == want && Crc32.of(got) == ((j['crc'] as num?)?.toInt() ?? -1);
        final fileOk = Crc32.of(all) == ((j['crc_file'] as num?)?.toInt() ?? -1);
        if (partOk && fileOk) return all;
        // something went missing in the middle somewhere: start again from the top
        whole = BytesBuilder(copy: false);
        have = 0;
        continue;
      }
      // short: notifications dropped; what arrived is in order, so keep it and carry on from there (the
      // whole-file CRC at the end catches a gap in the middle)
      whole.add(got);
      have += got.length;
      progress?.call(have, total);
    }
    throw PuckException('Track ${t.name} didn\'t come over cleanly. Keep the phone next to the puck and try again.');
  }

  /// The puck can delete it: the phone has it safely.
  Future<void> done(String name) => _authed('done $name');

  /// Every track off the puck, fetched or not.
  Future<void> erase() => _authed('erase');

  /// The mounting twist by hand (degrees clockwise from the bow); normally it learns this itself.
  Future<void> setTwist(double deg) => _authed('twist ${deg.toStringAsFixed(1)}');

  /// Level, twist, heel sign and which way up: all back to nothing known.
  Future<void> calReset() => _authed('calreset');

  // ---------------------------------------------------------------- firmware

  /// Push a firmware image (puck.bin) over Bluetooth: "ota begin", the bytes in link-sized chunks, "ota end".
  /// The puck checks it got every byte, writes it and restarts. [progress] gets 0..1 as it goes.
  Future<void> flash(List<int> bin, {void Function(double)? progress}) async {
    _needAuth();
    final chunk = chunkSize;
    await command('ota begin ${bin.length}', timeout: const Duration(seconds: 20));
    var sent = 0, writes = 0, lastCheck = 0;
    progress?.call(0);
    try {
      while (sent < bin.length) {
        final end = math.min(sent + chunk, bin.length);
        await _otaC.write(bin.sublist(sent, end), withoutResponse: true);
        sent = end;
        writes++;
        if (writes % 20 == 0) await Future<void>.delayed(const Duration(milliseconds: 15));
        if (sent - lastCheck >= 50 * 1024 || sent == bin.length) {
          lastCheck = sent;
          await _waitCaughtUp(sent);
        }
        progress?.call(sent / bin.length);
      }
    } catch (e) {
      throw _readable(e, puck: puck);
    }
    await command('ota end', timeout: const Duration(seconds: 60));
    progress?.call(1);
  }

  /// "ota status" until the puck has every byte sent so far (it can lag behind the phone's writes).
  Future<void> _waitCaughtUp(int sent) async {
    for (var i = 0; i < 40; i++) {
      final j = await command('ota status');
      final got = (j['got'] as num?)?.toInt() ?? 0;
      if (got >= sent) return;
      if (got == 0 && i > 3) throw const PuckException('The puck isn\'t taking the update. Try again with the phone right next to it.');
      await Future<void>.delayed(Duration(milliseconds: 100 + 50 * i));
    }
    throw const PuckException('The puck fell behind and didn\'t catch up. Try again with the phone right next to it.');
  }

  Future<void> disconnect() async {
    await _notify?.cancel();
    await _data?.cancel();
    _notify = null;
    _data = null;
    try {
      await _dev.disconnect();
    } catch (_) {}
  }

  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  static List<int> _unhex(String s) {
    if (s.length % 2 != 0) return const [];
    final out = <int>[];
    for (var i = 0; i < s.length; i += 2) {
      final v = int.tryParse(s.substring(i, i + 2), radix: 16);
      if (v == null) return const [];
      out.add(v);
    }
    return out;
  }
}
