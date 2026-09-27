import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
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

  Future<void> _back() async {
    if (_tab != 0) {
      setState(() => _tab = 0);
      return;
    }
    if (await _viewer.currentState?.handleBack() ?? false) return;
    await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
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
          child: IndexedStack(index: _tab, children: [
            // the real viewer, served by the phone's own dock (its Replay / Dock tabs are inside)
            WakeWebView(key: _viewer, url: app.dock.localUrl, ownBack: false),
            const SyncScreen(),
            const SetupScreen(),
          ]),
        ),
        bottomNavigationBar: full
            ? null
            : NavigationBar(
                height: 60,
                selectedIndex: _tab,
                onDestinationSelected: (i) => setState(() => _tab = i),
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.sailing_outlined), selectedIcon: Icon(Icons.sailing), label: 'Replay'),
                  NavigationDestination(icon: Icon(Icons.cloud_sync_outlined), selectedIcon: Icon(Icons.cloud_sync), label: 'Sync'),
                  NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Setup'),
                ],
              ),
        ),
      ),
    );
  }
}
