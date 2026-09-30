// Records a sail with the phone's own GPS. Runs as an Android foreground service (a "WakeBack is
// recording" notification), so it carries on with the screen off or another app open. Every kept fix
// is appended to a draft file straight away, so a crash or a flat battery loses nothing: the next
// start offers to carry on or save it.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import 'track_log.dart';

enum RecState { idle, recording, paused }

class Recorder extends ChangeNotifier {
  Recorder._();
  static final Recorder instance = Recorder._();

  RecState state = RecState.idle;
  TrackLog log = TrackLog();
  double? accuracy; // last fix's accuracy, metres (null = no fix yet)
  DateTime? lastFixAt;
  String? problem; // why GPS isn't working, in words for the sailor
  bool recovered = false; // the current track came back from a draft after a restart

  /// The last finished sail (so the screen can offer Replay / Share GPX).
  Map<String, dynamic>? lastSaved;
  TrackLog? lastSavedLog;

  StreamSubscription<Position>? _sub;
  IOSink? _draft;
  Timer? _ticker;
  int _segStart = 0, _accum = 0; // wall-clock time recording, pauses left out

  bool get active => state != RecState.idle;

  int get elapsedMs => _accum + (state == RecState.recording && _segStart > 0 ? DateTime.now().millisecondsSinceEpoch - _segStart : 0);
  double get avgKn => elapsedMs > 0 ? log.distNm / (elapsedMs / 3600000) : 0;

  Future<File> _draftFile() async => File('${(await getApplicationDocumentsDirectory()).path}/wakeback-recording.draft');

  /// At app start: a recording that was cut off (app killed, phone died) comes back paused.
  Future<void> recover() async {
    try {
      final f = await _draftFile();
      if (!await f.exists()) return;
      final fixes = (await f.readAsLines()).map(Fix.fromDraftLine).whereType<Fix>().toList();
      if (fixes.length < 2) {
        await f.delete();
        return;
      }
      log = TrackLog(maxAcc: app.recordMaxAcc.toDouble())..restore(fixes);
      _accum = log.sailedMs;
      _segStart = 0;
      state = RecState.paused;
      recovered = true;
      notifyListeners();
    } catch (_) {}
  }

  /// Ask for location, then start the GPS. Returns false (with [problem] set) if it can't.
  Future<bool> _startGps() async {
    if (_sub != null) return true;
    problem = null;
    if (!await Geolocator.isLocationServiceEnabled()) {
      problem = 'Location is turned off on this phone. Turn it on, then tap Start.';
      notifyListeners();
      return false;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      problem = perm == LocationPermission.deniedForever
          ? 'WakeBack isn\'t allowed to use location. Open app settings and allow Location.'
          : 'WakeBack needs location to record your track.';
      notifyListeners();
      return false;
    }
    final settings = defaultTargetPlatform == TargetPlatform.android
        ? AndroidSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
            intervalDuration: const Duration(seconds: 1),
            foregroundNotificationConfig: ForegroundNotificationConfig(
              notificationTitle: 'WakeBack is recording',
              notificationText: 'Your sail is being logged. Open WakeBack to pause or finish.',
              notificationChannelName: 'Recording',
              enableWakeLock: true,
              setOngoing: true,
            ),
          )
        : LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 0);
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(_onPosition, onError: (Object e) {
      problem = 'GPS stopped: $e';
      notifyListeners();
    });
    return true;
  }

  Future<void> _stopGps() async {
    await _sub?.cancel();
    _sub = null;
    accuracy = null;
  }

  void _onPosition(Position p) {
    // Android reports 0 for "don't know" speed/heading; only trust them with an accuracy attached
    final speed = p.speed > 0 || p.speedAccuracy > 0 ? p.speed : null;
    final heading = p.headingAccuracy > 0 || p.heading > 0 ? p.heading : null;
    accuracy = p.accuracy;
    lastFixAt = DateTime.now();
    final raw = RawFix(p.timestamp.toUtc().millisecondsSinceEpoch, p.latitude, p.longitude, p.accuracy, speedMs: speed, heading: heading);
    final r = log.add(raw, recording: state == RecState.recording);
    if (r == FixResult.recorded) _draft?.writeln(log.fixes.last.draftLine);
    notifyListeners();
  }

  Future<void> _openDraft({bool append = false}) async {
    final f = await _draftFile();
    _draft = f.openWrite(mode: append ? FileMode.append : FileMode.write);
  }

  Future<void> _closeDraft() async {
    try {
      await _draft?.flush();
      await _draft?.close();
    } catch (_) {}
    _draft = null;
  }

  void _tick(bool on) {
    _ticker?.cancel();
    _ticker = on ? Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners()) : null;
  }

  // ------------------------------------------------------------------ controls

  Future<bool> start() async {
    if (active) return true;
    log = TrackLog(maxAcc: app.recordMaxAcc.toDouble());
    recovered = false;
    lastSaved = null;
    lastSavedLog = null;
    if (!await _startGps()) return false;
    await _openDraft();
    _accum = 0;
    _segStart = DateTime.now().millisecondsSinceEpoch;
    state = RecState.recording;
    _tick(true);
    notifyListeners();
    return true;
  }

  Future<void> pause() async {
    if (state != RecState.recording) return;
    _accum += DateTime.now().millisecondsSinceEpoch - _segStart;
    _segStart = 0;
    state = RecState.paused;
    await _draft?.flush();
    _tick(false);
    notifyListeners();
  }

  Future<bool> resume() async {
    if (state != RecState.paused) return true;
    if (!await _startGps()) return false;
    if (_draft == null) await _openDraft(append: true);
    log.newSegment();
    _segStart = DateTime.now().millisecondsSinceEpoch;
    state = RecState.recording;
    recovered = false;
    _tick(true);
    notifyListeners();
    return true;
  }

  /// Finish: the track goes into the phone's sessions like any upload (venue, owner, stats, sync).
  /// Returns the store's answer ({session, file, venue_name…}), or null if nothing was recorded.
  Future<Map<String, dynamic>?> finish() async {
    if (!active) return null;
    if (state == RecState.recording) await pause();
    await _stopGps();
    await _closeDraft();
    final done = log;
    Map<String, dynamic>? res;
    if (done.fixes.length >= 2) {
      res = await app.store.upload('${done.fileBase()}.csv', Uint8List.fromList(done.toCsv().codeUnits));
      lastSaved = res;
      lastSavedLog = done;
    }
    try {
      await (await _draftFile()).delete();
    } catch (_) {}
    _tick(false);
    state = RecState.idle;
    recovered = false;
    _accum = 0;
    log = TrackLog(maxAcc: app.recordMaxAcc.toDouble());
    notifyListeners();
    app.tracksChanged();
    return res;
  }

  /// Throw the current recording away.
  Future<void> discard() async {
    await _stopGps();
    await _closeDraft();
    try {
      await (await _draftFile()).delete();
    } catch (_) {}
    _tick(false);
    state = RecState.idle;
    recovered = false;
    _accum = 0;
    log = TrackLog(maxAcc: app.recordMaxAcc.toDouble());
    notifyListeners();
  }

  /// Share the last finished sail as a GPX file (Strava, a mate's app, WhatsApp…).
  Future<void> shareGpx(TrackLog l, {String title = 'Sail'}) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/${l.fileBase()}.gpx');
    await f.writeAsString(l.toGpx(name: title));
    await Share.shareXFiles([XFile(f.path, mimeType: 'application/gpx+xml')], text: 'WakeBack · $title');
  }

  Future<void> openSettings() => Geolocator.openAppSettings();
}

Recorder get recorder => Recorder.instance;
