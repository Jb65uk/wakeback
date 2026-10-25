// App updates from the GitHub releases page: every push builds an APK there (app-N). The app checks the
// public releases feed, and if the build number is newer than its own, offers to download and install it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

// The repo publishes app (app-N) and puck firmware (puck-N) releases, so "latest" could be either: list them
// and pick the newest of the kind wanted.
const kReleasesApi = 'https://api.github.com/repos/Jb65uk/wakeback/releases?per_page=20';
const kReleasesPage = 'https://github.com/Jb65uk/wakeback/releases';

class AppUpdate {
  final int build; // app-N
  final String version, notes, apkUrl, page;
  const AppUpdate(this.build, this.version, this.notes, this.apkUrl, this.page);
  Map<String, dynamic> toJson() => {'build': build, 'version': version, 'notes': notes, 'apk': apkUrl, 'page': page};
  static AppUpdate? fromJson(Object? j) {
    if (j is! Map) return null;
    return AppUpdate((j['build'] as num).toInt(), '${j['version']}', '${j['notes']}', '${j['apk']}', '${j['page']}');
  }
}

class Updates {
  Updates._();
  static final instance = Updates._();

  int? _installedBuild;
  String? _installedVersion;

  /// "0.6.1 (build 16)"
  Future<String> installed() async {
    await _info();
    return '$_installedVersion (build $_installedBuild)';
  }

  Future<void> _info() async {
    if (_installedBuild != null) return;
    try {
      final p = await PackageInfo.fromPlatform();
      _installedBuild = int.tryParse(p.buildNumber) ?? 0;
      _installedVersion = p.version;
    } catch (_) {
      _installedBuild = 0;
      _installedVersion = '?';
    }
  }

  static const _offline = 'Couldn\'t reach GitHub — try on WiFi with internet, or mobile data.';

  /// The releases list from GitHub, newest first. Throws a plain Exception, in words for the sailor,
  /// when GitHub can't be reached or says no.
  Future<List<Map<String, dynamic>>> _releases() async {
    http.Response r;
    try {
      r = await http.get(Uri.parse(kReleasesApi), headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'WakeBack-app'}).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw Exception(_offline);
    } on SocketException {
      throw Exception(_offline);
    } on http.ClientException {
      throw Exception(_offline);
    }
    if (r.statusCode == 403) throw Exception('GitHub is rate-limiting update checks; try again later.');
    if (r.statusCode != 200) throw Exception('GitHub said HTTP ${r.statusCode}');
    return ((jsonDecode(utf8.decode(r.bodyBytes)) as List?) ?? const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  Map<String, dynamic>? _newest(List<Map<String, dynamic>> rels, String prefix) {
    Map<String, dynamic>? best;
    var bestN = -1;
    for (final j in rels) {
      final tag = '${j['tag_name'] ?? ''}';
      if (!tag.startsWith(prefix) || j['draft'] == true) continue;
      final n = int.tryParse(tag.substring(prefix.length)) ?? -1;
      if (n > bestN) {
        bestN = n;
        best = j;
      }
    }
    return best;
  }

  /// The newest app build on GitHub, or null if it's not newer than this one.
  Future<AppUpdate?> check() async {
    await _info();
    final j = _newest(await _releases(), 'app-');
    if (j == null) return null;
    final tag = '${j['tag_name'] ?? ''}';
    final build = int.tryParse(tag.replaceFirst('app-', '')) ?? 0;
    String? apk;
    var version = '';
    var notes = '${j['body'] ?? ''}';
    for (final a in (j['assets'] as List? ?? const [])) {
      if (a is Map && '${a['name']}' == 'WakeBack.apk') apk = '${a['browser_download_url']}';
    }
    // the build writes what's new into the release name: "WakeBack 0.7.0 (build 17)"
    final m = RegExp(r'WakeBack (\S+) \(build (\d+)\)').firstMatch('${j['name'] ?? ''}');
    if (m != null) version = m.group(1)!;
    // strip the boilerplate line the release page carries for people installing by hand
    notes = notes.split('\n').where((l) => !l.startsWith('Open this page on your phone')).join('\n').trim();
    if (apk == null || build <= (_installedBuild ?? 0)) return null;
    return AppUpdate(build, version, notes, apk, '${j['html_url'] ?? kReleasesPage}');
  }

  /// The newest puck firmware on GitHub: its version ("1.0.29") and the puck.bin URL. Null if none published.
  Future<PuckFirmware?> latestPuckFirmware() async {
    final j = _newest(await _releases(), 'puck-');
    if (j == null) return null;
    String? bin;
    for (final a in (j['assets'] as List? ?? const [])) {
      if (a is Map && '${a['name']}' == 'puck.bin') bin = '${a['browser_download_url']}';
    }
    if (bin == null) return null;
    final m = RegExp(r'(\d+\.\d+\.\d+)').firstMatch('${j['name'] ?? ''}');
    return PuckFirmware(m?.group(1) ?? '${j['tag_name']}', bin, '${j['body'] ?? ''}'.trim());
  }

  /// Fetch a puck.bin. Needs the internet, so do it before joining the puck's WiFi.
  Future<List<int>> downloadPuckFirmware(PuckFirmware f) async {
    http.Response r;
    try {
      r = await http.get(Uri.parse(f.binUrl), headers: {'User-Agent': 'WakeBack-app'}).timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw Exception(_offline);
    } on SocketException {
      throw Exception(_offline);
    } on http.ClientException {
      throw Exception(_offline);
    }
    if (r.statusCode != 200) throw Exception('GitHub said HTTP ${r.statusCode} for the firmware');
    if (r.bodyBytes.length < 100000 || r.bodyBytes[0] != 0xE9) throw Exception('That download isn\'t a puck firmware image.');
    return r.bodyBytes;
  }

  /// Download the APK and hand it to Android's installer. Progress is 0..1.
  Future<void> install(AppUpdate u, {void Function(double)? progress}) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/WakeBack-${u.build}.apk');
    final req = http.Request('GET', Uri.parse(u.apkUrl))..headers['User-Agent'] = 'WakeBack-app';
    http.StreamedResponse res;
    try {
      res = await http.Client().send(req).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw Exception(_offline);
    } on SocketException {
      throw Exception(_offline);
    } on http.ClientException {
      throw Exception(_offline);
    }
    if (res.statusCode != 200) throw Exception('Download failed (HTTP ${res.statusCode})');
    final total = res.contentLength ?? 0;
    var got = 0;
    final sink = f.openWrite();
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) progress?.call(got / total);
      }
    } finally {
      await sink.close();
    }
    if (got < 1000000) throw Exception('That download is too small to be the app');
    if (!Platform.isAndroid) return;
    final r = await OpenFilex.open(f.path, type: 'application/vnd.android.package-archive');
    if (r.type != ResultType.done) {
      throw Exception(r.message.isEmpty ? 'Android would not open the installer' : r.message);
    }
    if (kDebugMode) debugPrint('installer opened for ${f.path}');
  }
}

class PuckFirmware {
  final String version, binUrl, notes;
  const PuckFirmware(this.version, this.binUrl, this.notes);

  /// Is [version] ("1.0.29") newer than [installed] ("1.0.27")? Local builds ("1.0.0", "dev") always count as older.
  bool newerThan(String installed) {
    List<int> parts(String v) => RegExp(r'\d+').allMatches(v).map((m) => int.parse(m.group(0)!)).toList();
    final a = parts(version), b = parts(installed);
    if (b.isEmpty || installed.contains('dev') || installed == '1.0.0') return true;
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}
