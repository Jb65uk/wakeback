// App updates from the GitHub releases page: every push builds an APK there (app-N). The app checks the
// public releases feed, and if the build number is newer than its own, offers to download and install it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

const kReleasesApi = 'https://api.github.com/repos/Jb65uk/wakeback/releases/latest';
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

  /// The newest build on GitHub, or null if it's not newer than this one (or GitHub can't be reached).
  Future<AppUpdate?> check() async {
    await _info();
    final r = await http.get(Uri.parse(kReleasesApi), headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'WakeBack-app'}).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('GitHub said HTTP ${r.statusCode}');
    final j = (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, dynamic>();
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

  /// Download the APK and hand it to Android's installer. Progress is 0..1.
  Future<void> install(AppUpdate u, {void Function(double)? progress}) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/WakeBack-${u.build}.apk');
    final req = http.Request('GET', Uri.parse(u.apkUrl))..headers['User-Agent'] = 'WakeBack-app';
    final res = await http.Client().send(req).timeout(const Duration(seconds: 30));
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
