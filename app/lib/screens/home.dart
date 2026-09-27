import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import 'sessions_screen.dart';
import 'setup_screen.dart';
import 'sync_screen.dart';
import 'web_page.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  final _viewer = GlobalKey<WakeWebViewState>();

  static const _sessions = 0, _replay = 1, _setup = 3;

  Future<void> _back() async {
    if (_tab == _replay && (await _viewer.currentState?.handleBack() ?? false)) return; // full screen / Dock page
    if (_tab != _sessions) {
      setState(() => _tab = _sessions);
      return;
    }
    await SystemNavigator.pop();
  }

  /// A session tapped in the Sessions tab (or a record in Stats): replay it.
  void _open(String id) {
    setState(() => _tab = _replay);
    _viewer.currentState?.openSession(id);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => ValueListenableBuilder<bool>(
        valueListenable: app.fullscreen,
        builder: (context, full, _) => PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _back();
          },
          child: Scaffold(
            body: SafeArea(
              top: !full,
              bottom: false,
              child: Column(children: [
                if (app.demoMode && !full)
                  Material(
                    color: t.colorScheme.primary,
                    child: InkWell(
                      onTap: () => setState(() => _tab = _setup),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        child: Row(children: [
                          const Icon(Icons.science_outlined, size: 18, color: Colors.black),
                          const SizedBox(width: 8),
                          const Expanded(child: Text('Demo mode: pretend pucks and demo data', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w600))),
                          Text('Exit in Setup', style: TextStyle(color: Colors.black.withValues(alpha: 0.7), fontSize: 12)),
                        ]),
                      ),
                    ),
                  ),
                Expanded(
                  child: IndexedStack(index: _tab, children: [
                    SessionsScreen(onOpen: _open),
                    // the real viewer, served by the phone's own dock (its Replay / Dock tabs are inside).
                    // The URL changes with demo mode (?demo=1), and the web view reloads on a URL change.
                    WakeWebView(
                      key: _viewer,
                      url: '${app.dock.localUrl}/${app.demoMode ? '?demo=1' : ''}',
                      ownBack: false,
                    ),
                    const SyncScreen(),
                    const SetupScreen(),
                  ]),
                ),
              ]),
            ),
            bottomNavigationBar: full
                ? null
                : NavigationBar(
                    height: 60,
                    selectedIndex: _tab,
                    onDestinationSelected: (i) => setState(() => _tab = i),
                    destinations: const [
                      NavigationDestination(icon: Icon(Icons.list_alt_outlined), selectedIcon: Icon(Icons.list_alt), label: 'Sessions'),
                      NavigationDestination(icon: Icon(Icons.sailing_outlined), selectedIcon: Icon(Icons.sailing), label: 'Replay'),
                      NavigationDestination(icon: Icon(Icons.cloud_sync_outlined), selectedIcon: Icon(Icons.cloud_sync), label: 'Sync'),
                      NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Setup'),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
