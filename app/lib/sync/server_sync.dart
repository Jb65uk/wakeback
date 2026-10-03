// Two-way sync between the phone's dock and your WakeBack server (server/app.py),
// using only the server's existing endpoints — nothing new needed on the server.
//
// Venues first (so both sides file tracks under the same venue), then per session (date + venue):
//   tracks  — anything missing on either side is copied across (same file names), with their owner
//   crew    — merged; where both named the same puck differently, the phone wins
//   races / course (marks, lines, gun, corrections) — copied to whichever side has none;
//             if both sides have a different one, you choose which to keep
//
// Your own sails follow you: one you recorded on your phone comes down to your tablet as yours (not as
// a mate's), and syncNew() does all of this without being asked, for the days whose tracks differ.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../dock/store.dart';

class SyncException implements Exception {
  final String message;
  final bool signedOut; // the server no longer accepts our token
  /// This device has no internet (as opposed to the server being down or saying no).
  final bool offline;

  /// The technical error behind a plain-English message, for the Details line.
  final String? detail;
  const SyncException(this.message, {this.signedOut = false, this.offline = false, this.detail});
  @override
  String toString() => message;

  /// A network failure in plain English: your sails are safe either way.
  factory SyncException.network(Object e) {
    final d = '$e';
    final noNet = d.contains('Failed host lookup') || d.contains('Network is unreachable') || d.contains('No address associated') || d.contains('errno = 101') || d.contains('errno = 7)');
    return SyncException(
      noNet ? 'No internet on this device. Your sails are safe and will sync when you\'re back online.' : 'The WakeBack server isn\'t answering. Your sails are safe; it will try again later.',
      offline: noNet,
      detail: d,
    );
  }
}

class DayCompare {
  final String day;

  /// The sailing date ('2026-10-03') and venue name, for showing the day to a person.
  final String date, venueName;
  final List<String> phoneOnly, serverOnly, both;

  /// Who sent each of the server's tracks (names only) and how they're shared, so downloads keep both.
  final Map<String, String> serverOwners, serverSharing, serverBoats;

  /// The server's tracks it counts as the signed-in person's own.
  final Set<String> serverMine;
  const DayCompare(this.day, this.phoneOnly, this.serverOnly, this.both,
      {this.serverOwners = const {}, this.serverSharing = const {}, this.serverBoats = const {}, this.serverMine = const {}, this.date = '', this.venueName = ''});
  bool get onPhone => phoneOnly.isNotEmpty || both.isNotEmpty;
  bool get onServer => serverOnly.isNotEmpty || both.isNotEmpty;
  bool get tracksInSync => phoneOnly.isEmpty && serverOnly.isEmpty;
}

class SyncReport {
  int up = 0, down = 0;
  final List<String> changed = []; // human-readable notes
  final List<String> conflicts = []; // 'races' / 'meta' that differ and need a choice

  /// Days whose course differs on both sides (syncNew leaves those for the Sync page).
  final List<String> conflictDays = [];
}

/// Deep equality for decoded JSON, comparing numbers by value (5 == 5.0).
bool jsonEq(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !jsonEq(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEq(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

bool _metaEmpty(Map m) =>
    ((m['marks'] as List?)?.isEmpty ?? true) &&
    ((m['lines'] as List?)?.isEmpty ?? true) &&
    ((m['fixes'] as List?)?.isEmpty ?? true) &&
    !pyTruthy(m['gun']) &&
    m['weather'] == null;

class ServerSync {
  final String base;
  final DockStore store;
  final String? token;
  ServerSync(String url, this.store, {this.token}) : base = url.trim().replaceAll(RegExp(r'/+$'), '');

  Uri _u(String p) => Uri.parse('$base$p');
  Map<String, String> get _auth => token == null ? const {} : {'Authorization': 'Bearer $token'};
  Map<String, String> get _authJson => {..._auth, 'Content-Type': 'application/json'};

  Future<http.Response> _go(Future<http.Response> f, {Duration timeout = const Duration(seconds: 20)}) async {
    try {
      final r = await f.timeout(timeout);
      if (r.statusCode == 401) throw const SyncException('Please sign in to your WakeBack account (You tab)', signedOut: true);
      if (r.statusCode == 301 || r.statusCode == 302) {
        throw const SyncException('Something in front of the server (Cloudflare Access?) is asking for its own login. Limit it to /admin.');
      }
      if (r.statusCode >= 400) {
        String msg;
        try {
          msg = '${(jsonDecode(utf8.decode(r.bodyBytes)) as Map)['error']}';
        } catch (_) {
          msg = 'HTTP ${r.statusCode}';
        }
        throw SyncException('Server said: $msg');
      }
      return r;
    } on TimeoutException {
      throw const SyncException('The WakeBack server didn\'t answer in time. Your sails are safe; it will try again later.', detail: 'timed out');
    } on SyncException {
      rethrow;
    } catch (e) {
      throw SyncException.network(e);
    }
  }

  Future<Object?> _getJson(String p) async => jsonDecode(utf8.decode((await _go(http.get(_u(p), headers: _auth))).bodyBytes));

  Future<Object?> _putJson(String p, Object value) async =>
      jsonDecode(utf8.decode((await _go(http.put(_u(p), headers: _authJson, body: jsonEncode(value)))).bodyBytes));

  /// Your totals on the server (?period=month|year|all).
  Future<Map<String, dynamic>> myStats(String period) async =>
      ((await _getJson('/api/stats?period=$period')) as Map).cast<String, dynamic>();

  /// The friends' league from the server: people ranked, 'me' flagged.
  Future<List<Map<String, dynamic>>> league(String period) async {
    final j = ((await _getJson('/api/league?period=$period')) as Map).cast<String, dynamic>();
    return ((j['people'] as List?) ?? const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// Change how one of your tracks on the server is shared ('friends' / 'private').
  Future<void> setSharing(String day, String file, String visibility) => setTrack(day, file, {'visibility': visibility});

  /// Change a track's settings on the server (visibility, boat).
  Future<void> setTrack(String day, String file, Map<String, dynamic> settings) async {
    await _go(http.post(_u('/api/sessions/$day/tracks/$file'), headers: _authJson, body: jsonEncode(settings)));
  }

  /// Remove one of my tracks from the server (the owner or the admin only; 404 = it was never there).
  Future<void> deleteTrack(String day, String file) async {
    await _go(http.delete(_u('/api/sessions/${Uri.encodeComponent(day)}/${Uri.encodeComponent(file)}'), headers: _auth));
  }

  /// Is this a WakeBack dock/server? Returns its session list.
  Future<List<Map<String, dynamic>>> serverSessions() async {
    final j = await _getJson('/api/sessions');
    if (j is! List) throw const SyncException('That address answered, but it isn\'t a WakeBack server');
    return j.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// Make the phone's and the server's venue lists match. Returns how many changed.
  /// Missing on either side: copied across (same id). Both have it: a named venue beats an automatic
  /// "New venue near…"; if both are named differently, the server's name wins.
  Future<int> syncVenues() async {
    final sj = await _getJson('/api/venues');
    if (sj is! List) throw const SyncException('That address answered, but it isn\'t a WakeBack server');
    final server = {for (final v in sj.whereType<Map>()) '${v['id']}': v.cast<String, dynamic>()};
    final phone = {for (final v in await store.venues()) '${v['id']}': v};
    var changed = 0;
    for (final v in phone.values) {
      final s = server[v['id']];
      if (s == null) {
        await _go(http.post(_u('/api/venues'), headers: _authJson, body: jsonEncode(v)));
        changed++;
      } else if (s['name'] != v['name']) {
        if (s['auto'] == true && v['auto'] != true) {
          await _putJson('/api/venues/${Uri.encodeComponent('${v['id']}')}', {'name': v['name']});
        } else {
          await store.upsertVenue(s);
        }
        changed++;
      }
    }
    for (final s in server.values) {
      if (!phone.containsKey(s['id'])) {
        await store.upsertVenue(s);
        changed++;
      }
    }
    return changed;
  }

  Future<List<DayCompare>> compare() async {
    await syncVenues();
    final ss = await serverSessions();
    final server = {for (final s in ss) '${s['id']}': ((s['files'] as List?) ?? const []).map((e) => '$e').toSet()};
    final owners = {
      for (final s in ss) '${s['id']}': {for (final e in ((s['owners'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'}
    };
    final sharing = {
      for (final s in ss) '${s['id']}': {for (final e in ((s['sharing'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'}
    };
    final boats = {
      for (final s in ss) '${s['id']}': {for (final e in ((s['boats'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'}
    };
    final mine = {for (final s in ss) '${s['id']}': ((s['mine'] as List?) ?? const []).map((e) => '$e').toSet()};
    final ps = await store.sessions();
    final phone = {for (final s in ps) '${s['id']}': ((s['files'] as List?) ?? const []).map((e) => '$e').toSet()};
    final dates = {for (final s in [...ss, ...ps]) '${s['id']}': '${s['date'] ?? ''}'};
    final venueNames = {for (final s in [...ss, ...ps]) '${s['id']}': '${s['venue_name'] ?? ''}'};
    final days = {...server.keys, ...phone.keys}.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final d in days)
        DayCompare(
          d,
          ((phone[d] ?? <String>{}).difference(server[d] ?? <String>{})).toList()..sort(),
          ((server[d] ?? <String>{}).difference(phone[d] ?? <String>{})).toList()..sort(),
          ((phone[d] ?? <String>{}).intersection(server[d] ?? <String>{})).toList()..sort(),
          serverOwners: owners[d] ?? const {},
          serverSharing: sharing[d] ?? const {},
          serverBoats: boats[d] ?? const {},
          serverMine: mine[d] ?? const {},
          date: dates[d] ?? '',
          venueName: venueNames[d] ?? '',
        ),
    ];
  }

  /// Returns where the track ended up (session, file) once the server has filed it.
  Future<(String, String)> _uploadTrack(String day, String name) async {
    final f = await store.trackFile(day, name);
    final owner = await store.ownerOf(day, name);
    final req = http.MultipartRequest('POST', _u('/api/upload'))
      ..headers.addAll(_auth)
      ..files.add(http.MultipartFile.fromBytes('file', await f.readAsBytes(), filename: name));
    if (owner != null && '${owner['name'] ?? ''}'.isNotEmpty) {
      req.fields['owner_name'] = '${owner['name']}';
      if ('${owner['email'] ?? ''}'.isNotEmpty) req.fields['owner_email'] = '${owner['email']}';
      if (owner['visibility'] == 'private') req.fields['visibility'] = 'private';
      if ('${owner['boat'] ?? ''}'.isNotEmpty) req.fields['boat'] = '${owner['boat']}';
    }
    final r = await _go(req.send().then(http.Response.fromStream), timeout: const Duration(minutes: 3));
    // The server files by the track's own timestamp; if it put it somewhere else (e.g. a track with no
    // timestamp lands on "today"), move ours to match so it isn't uploaded again next time.
    try {
      final j = (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, dynamic>();
      final sDay = '${j['session'] ?? day}', sFile = '${j['file'] ?? name}';
      if (sDay != day || sFile != name) {
        await store.moveTrack(day, name, sDay, sFile);
        return (sDay, sFile);
      }
    } catch (_) {}
    return (day, name);
  }

  /// Is this one of the server's tracks my own (my account's, under my name)?
  bool _mineOnServer(DayCompare c, String f) => store.ownerName.isNotEmpty && c.serverMine.contains(f) && c.serverOwners[f] == store.ownerName;

  /// The owner record for a track that came from the server: mine stays mine on every device I sign in
  /// on; anyone else's is marked remote, so it's never uploaded back as ours.
  Map<String, dynamic> _ownerFromServer(DayCompare c, String f) {
    final boat = c.serverBoats[f];
    final common = {'visibility': c.serverSharing[f] ?? 'friends', if (boat != null && boat.isNotEmpty) 'boat': boat};
    if (_mineOnServer(c, f)) {
      return {'name': store.ownerName, if (store.ownerEmail.isNotEmpty) 'email': store.ownerEmail, ...common, 'synced': true};
    }
    return {'name': c.serverOwners[f] ?? '', ...common, 'remote': true};
  }

  /// A track here that the server has had (it came from there, or we sent it): if the server no longer
  /// has it, it was deleted on another device and mustn't be sent back up.
  static bool _serverHadIt(Map<String, dynamic>? o) => o != null && (o['remote'] == true || o['synced'] == true);

  /// Tracks on both sides: note that the server has them, and take back any of my own that an older
  /// version of the app filed as a mate's when it came down.
  Future<void> _settleOwners(DayCompare c) async {
    for (final f in c.both) {
      final o = await store.ownerOf(c.day, f);
      if (o == null) continue;
      if (o['remote'] == true) {
        if (_mineOnServer(c, f)) await store.setOwner(c.day, f, _ownerFromServer(c, f));
      } else if (o['synced'] != true) {
        await store.setOwner(c.day, f, {...o, 'synced': true});
      }
    }
  }

  /// Sync without being asked: every day whose tracks differ, both ways. A course that differs on both
  /// sides is left alone (conflictDays) for the Sync page to ask about.
  Future<SyncReport> syncNew({void Function(String)? progress}) async {
    final total = SyncReport();
    for (final c in await compare()) {
      var need = c.serverOnly.isNotEmpty;
      for (final f in c.phoneOnly) {
        if (need) break;
        need = !_serverHadIt(await store.ownerOf(c.day, f));
      }
      if (!need) {
        await _settleOwners(c);
        continue;
      }
      final r = await syncDay(c, progress: progress);
      total.up += r.up;
      total.down += r.down;
      total.changed.addAll(r.changed);
      if (r.conflicts.isNotEmpty) total.conflictDays.add(c.day);
    }
    return total;
  }

  Future<Uint8List> _downloadTrack(String day, String name) async =>
      (await _go(http.get(_u('/api/sessions/${Uri.encodeComponent(day)}/${Uri.encodeComponent(name)}'), headers: _auth), timeout: const Duration(minutes: 3))).bodyBytes;

  /// Sync one day. [resolve] picks a side for a course that differs: {'races': 'phone'|'server', 'meta': ...}.
  Future<SyncReport> syncDay(DayCompare c, {Map<String, String> resolve = const {}, void Function(String)? progress}) async {
    final day = c.day;
    final rep = SyncReport();

    // ---- tracks
    var gone = 0;
    for (final f in c.phoneOnly) {
      final o = await store.ownerOf(day, f);
      if (o != null && o['remote'] == true) continue; // a friend's track we downloaded: theirs to manage, not ours to re-upload
      if (_serverHadIt(o)) {
        gone++; // deleted from the server on another device: don't bring it back
        continue;
      }
      progress?.call('Uploading $f');
      final (uDay, uFile) = await _uploadTrack(day, f);
      final uo = await store.ownerOf(uDay, uFile);
      if (uo != null) await store.setOwner(uDay, uFile, {...uo, 'synced': true});
      rep.up++;
    }
    if (gone > 0) rep.changed.add('$gone no longer on the server (deleted on another device), kept here');
    await _settleOwners(c);
    for (final f in c.serverOnly) {
      progress?.call('Downloading $f');
      if (await store.putTrack(day, f, await _downloadTrack(day, f))) {
        rep.down++;
        await store.setOwner(day, f, _ownerFromServer(c, f));
      }
    }

    progress?.call('Names and course');
    // ---- crew: merge, phone wins on a clash
    final sCrew = ((await _getJson('/api/sessions/$day/crew')) as Map?)?.cast<String, dynamic>() ?? {};
    final pCrew = await store.getCrew(day);
    final merged = {...sCrew, ...pCrew};
    if (!jsonEq(merged, sCrew)) {
      await _putJson('/api/sessions/$day/crew', merged);
      rep.changed.add('names sent to server');
    }
    if (!jsonEq(merged, pCrew)) {
      await store.putRaw(day, 'crew', merged);
      rep.changed.add('names updated on phone');
    }

    // ---- races and course
    for (final what in ['races', 'meta']) {
      final label = what == 'races' ? 'races' : 'course';
      final s = await _getJson('/api/sessions/$day/$what');
      final p = what == 'races' ? await store.getRaces(day) : await store.getMeta(day);
      final sEmpty = what == 'races' ? (s is! List || s.isEmpty) : (s is! Map || _metaEmpty(s));
      final pEmpty = what == 'races' ? (p as List).isEmpty : _metaEmpty(p as Map);
      if (jsonEq(s, p) || (sEmpty && pEmpty)) continue;
      final pick = resolve[what] ?? (sEmpty ? 'phone' : pEmpty ? 'server' : null);
      if (pick == 'phone') {
        final clean = await _putJson('/api/sessions/$day/$what', p);
        if (clean != null) await store.putRaw(day, what, clean);
        rep.changed.add('$label sent to server');
      } else if (pick == 'server') {
        await store.putRaw(day, what, s ?? (what == 'races' ? <Object>[] : <String, Object>{}));
        rep.changed.add('$label copied to phone');
      } else {
        rep.conflicts.add(what);
      }
    }
    return rep;
  }
}
