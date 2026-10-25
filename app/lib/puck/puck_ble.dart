// Talking to a puck over Bluetooth LE: no WiFi to join, no button to hold — the puck only has to be awake
// (on the pad, or press its button). Protocol in firmware/puck/src/ble.h:
//
//   command  (write)         one text line, e.g. "status", "set puck=3&ssid=…", "level", "orient 1", "upload"
//   reply    (notify)        the answer as JSON, sent in MTU-sized chunks and finished with "\n"
//   ota      (write, no response)   raw firmware bytes between "ota begin <bytes>" and "ota end"
//
// Every puck advertises as "WakeBack puck N", so the app can list the ones nearby and connect to one by number.
// Errors come out as [PuckException] with a sentence a sailor can act on, like the WiFi route.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'puck_wifi.dart';

/// A puck seen in a scan: its number (from the name), signal strength and the device it was.
class PuckSeen {
  final int puck;
  final int rssi;
  final String id;
  const PuckSeen({required this.puck, required this.rssi, required this.id});

  /// "good" / "fair" / "weak", from the signal strength.
  String get signal => rssi >= -65 ? 'good signal' : rssi >= -80 ? 'fair signal' : 'weak signal';

  @override
  String toString() => 'WakeBack puck $puck ($signal)';
}

class PuckBle {
  static const _svc = '7a4e0001-9b9d-4a3f-8e1a-3c2b1d0a5f01';
  static const _cmd = '7a4e0002-9b9d-4a3f-8e1a-3c2b1d0a5f01';
  static const _rsp = '7a4e0003-9b9d-4a3f-8e1a-3c2b1d0a5f01';
  static const _ota = '7a4e0004-9b9d-4a3f-8e1a-3c2b1d0a5f01';

  static const namePrefix = 'WakeBack puck ';
  static String nameOf(int puck) => '$namePrefix$puck';

  /// The puck number from an advertised name, or null if it isn't one of ours.
  static int? puckFromName(String name) {
    if (!name.startsWith(namePrefix)) return null;
    final n = int.tryParse(name.substring(namePrefix.length).trim());
    return n != null && n >= 1 && n <= 99 ? n : null;
  }

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
    if (!await FlutterBluePlus.isSupported) throw const PuckException('This phone has no Bluetooth, so the puck has to be set up over WiFi.');
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

  /// The pucks nearby, as they're seen (the same puck again when its signal changes). Stops after [timeout];
  /// cancelling the subscription stops it sooner.
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
          await FlutterBluePlus.startScan(timeout: timeout, androidUsesFineLocation: false);
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
    return PuckSeen(puck: n, rssi: r.rssi, id: r.device.remoteId.str);
  }

  /// Find "WakeBack puck N" nearby and connect to it: scan until it's seen, connect, find the service,
  /// listen for replies, ask for a bigger MTU. Throws a readable [PuckException] if it isn't about.
  static Future<PuckBle> connect(int puck, {Duration timeout = const Duration(seconds: 12)}) async {
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
    return connectTo(found);
  }

  /// Connect to a puck a scan just found.
  static Future<PuckBle> connectTo(PuckSeen seen) async {
    final dev = BluetoothDevice.fromId(seen.id);
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      await dev.connect(timeout: const Duration(seconds: 15), mtu: 247);
      final services = await dev.discoverServices();
      BluetoothCharacteristic? cmd, rsp, ota;
      for (final s in services) {
        if (s.uuid != Guid(_svc)) continue;
        for (final c in s.characteristics) {
          if (c.uuid == Guid(_cmd)) cmd = c;
          if (c.uuid == Guid(_rsp)) rsp = c;
          if (c.uuid == Guid(_ota)) ota = c;
        }
      }
      if (cmd == null || rsp == null || ota == null) {
        await dev.disconnect();
        throw const PuckException('That isn\'t a WakeBack puck (no puck service), or its firmware is too old for Bluetooth.');
      }
      final b = PuckBle._(seen.puck, dev, cmd, rsp, ota);
      await b._listen();
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
  final BluetoothCharacteristic _cmdC, _rspC, _otaC;
  StreamSubscription<List<int>>? _notify;
  final _buf = <int>[];
  Completer<Map<String, dynamic>>? _waiting;
  PuckBle._(this.puck, this._dev, this._cmdC, this._rspC, this._otaC);

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

  /// What the puck says about itself (the same JSON as its page shows).
  Future<PuckStatus> status() async {
    final st = PuckStatus.fromMap(await command('status'));
    if (!st.isPuck) throw const PuckException('That isn\'t a WakeBack puck (unexpected reply).');
    return st;
  }

  /// Hotspot name + password, puck number, the key, auto-record. Empty strings are left out (the puck keeps what it has).
  Future<void> settings({int? puck, String? ssid, String? pass, String? key, bool? autoRec, bool? autoOff}) {
    final form = {
      if (puck != null) 'puck': '$puck',
      if (ssid != null && ssid.isNotEmpty) 'ssid': ssid,
      if (pass != null && pass.isNotEmpty) 'pass': pass,
      if (key != null) 'key': key,
      if (autoRec != null) 'autorec': autoRec ? '1' : '0',
      if (autoOff != null) 'autooff': autoOff ? '1' : '0',
    };
    final enc = form.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
    return command('set $enc');
  }

  /// Heel and pitch read 0 as the boat sits now.
  Future<void> level() => command('level');

  /// 1 = mounted on deck, 2 = under the thwart.
  Future<void> orient(int o) => command('orient $o');

  Future<void> startRecording() => command('rec start');
  Future<void> stopRecording() => command('rec stop');

  /// Go and find the hotspot now (and hand over any tracks).
  Future<void> uploadNow() => command('upload');

  /// The puck goes to sleep; the link drops straight after.
  Future<void> sleep() => command('sleep');

  Future<void> reboot() => command('reboot');

  /// Push a firmware image (puck.bin) over Bluetooth: "ota begin", the bytes in link-sized chunks, "ota end".
  /// The puck checks it got every byte, writes it and restarts. [progress] gets 0..1 as it goes.
  Future<void> flash(List<int> bin, {void Function(double)? progress}) async {
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
    _notify = null;
    try {
      await _dev.disconnect();
    } catch (_) {}
  }
}
