// Hosts the real viewer (or your server's copy of it) and fills the gaps an Android
// WebView has on its own: file pickers, confirm()/alert(), GPX "download", full screen, back button.
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../app_state.dart';

class WakeWebView extends StatefulWidget {
  final String url;

  /// Handle the Android back button itself (a pushed page). The home screen handles it for Replay.
  final bool ownBack;
  const WakeWebView({super.key, required this.url, this.ownBack = true});

  @override
  State<WakeWebView> createState() => WakeWebViewState();
}

class WakeWebViewState extends State<WakeWebView> with AutomaticKeepAliveClientMixin {
  late final WebViewController _c;
  bool _loading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF13293A))
      ..addJavaScriptChannel('WakeBackApp', onMessageReceived: _onMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) {
            setState(() {
              _error = null;
              _loading = true;
            });
          }
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
          // belt and braces for the Load demo button: the page reads ?demo=1, and we tell it too
          _c.runJavaScript('window.wbSetDemo && wbSetDemo(${app.demoMode})').catchError((_) {});
        },
        onWebResourceError: (e) {
          if ((e.isForMainFrame ?? true) && mounted) {
            setState(() {
              _loading = false;
              _error = e.description;
            });
          }
        },
      ));
    _setup();
  }

  Future<void> _setup() async {
    try {
      final ua = await _c.getUserAgent();
      await _c.setUserAgent('${ua ?? 'Mozilla/5.0 (Linux; Android)'} WakeBackApp');
    } catch (_) {}
    await _c.setOnJavaScriptAlertDialog((req) async {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(req.message),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    });
    await _c.setOnJavaScriptConfirmDialog((req) async {
      if (!mounted) return false;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(req.message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
          ],
        ),
      );
      return ok ?? false;
    });
    final p = _c.platform;
    if (p is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(kDebugMode); // chrome://inspect while developing
      await p.setOnShowFileSelector(_pickFiles);
    }
    await _c.loadRequest(Uri.parse(widget.url));
  }

  /// <input type="file"> in the viewer ("Add tracks") and the phone-upload page.
  Future<List<String>> _pickFiles(FileSelectorParams params) async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: params.mode == FileSelectorMode.openMultiple, type: FileType.any);
    if (r == null) return <String>[];
    return [
      for (final f in r.files)
        if (f.path != null) Uri.file(f.path!).toString(),
    ];
  }

  /// Messages from the viewer (only sent when it's running inside this app).
  Future<void> _onMessage(JavaScriptMessage m) async {
    Map<String, dynamic> msg;
    try {
      msg = (jsonDecode(m.message) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'save': // "Download GPX" -> share sheet
        final name = '${msg['name'] ?? 'wakeback.gpx'}'.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/$name');
        await f.writeAsString('${msg['data'] ?? ''}');
        await Share.shareXFiles([XFile(f.path, mimeType: '${msg['mime'] ?? 'application/octet-stream'}')], subject: name);
      case 'fullscreen':
        await _setFullscreen(msg['on'] == true);
    }
  }

  Future<void> _setFullscreen(bool on) async {
    app.fullscreen.value = on;
    await SystemChrome.setEnabledSystemUIMode(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  @override
  void dispose() {
    // a pushed page (server viewer) mustn't leave the app stuck in full screen
    if (widget.ownBack && app.fullscreen.value) {
      app.fullscreen.value = false;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  Future<void> reload() => _c.reload();

  @override
  void didUpdateWidget(covariant WakeWebView old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      setState(() => _loading = true);
      _c.loadRequest(Uri.parse(widget.url));
    }
  }

  /// Open a session's replay. Uses the page's own hook when the viewer is up; otherwise loads it with ?session=.
  Future<void> openSession(String id) async {
    final js = jsonEncode(id);
    try {
      final r = await _c.runJavaScriptReturningResult('typeof wbOpenSession === "function" ? (wbOpenSession($js), true) : false');
      if (r == true || '$r' == 'true') return;
    } catch (_) {}
    final u = Uri.parse(widget.url);
    setState(() => _loading = true);
    await _c.loadRequest(u.replace(queryParameters: {...u.queryParameters, 'session': id}));
  }

  /// Back button: leave full screen, else go back a page (Dock -> Replay). Returns false if there's nowhere to go.
  Future<bool> handleBack() async {
    if (app.fullscreen.value) {
      await _c.runJavaScript("document.body.classList.contains('appfs') && document.getElementById('fs') && document.getElementById('fs').click()");
      await _setFullscreen(false); // in case the page didn't answer
      return true;
    }
    if (await _c.canGoBack()) {
      await _c.goBack();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final body = Stack(children: [
        WebViewWidget(controller: _c),
        if (_loading) const Center(child: CircularProgressIndicator()),
        if (_error != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.cloud_off, size: 48),
                const SizedBox(height: 12),
                Text('Couldn\'t load ${widget.url}\n$_error', textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _error = null;
                      _loading = true;
                    });
                    _c.loadRequest(Uri.parse(widget.url));
                  },
                  child: const Text('Try again'),
                ),
              ]),
            ),
          ),
      ]);
    if (!widget.ownBack) return body;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!await handleBack() && context.mounted) Navigator.of(context).pop();
      },
      child: body,
    );
  }
}

/// Full-screen page for a viewer page: your server's (from Sync) or this phone's Dock page (from You).
class ServerViewerPage extends StatelessWidget {
  final String url;
  final String? title;
  const ServerViewerPage({super.key, required this.url, this.title});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title ?? Uri.parse(url).host), toolbarHeight: 44),
        body: SafeArea(top: false, child: WakeWebView(url: url)),
      );
}
