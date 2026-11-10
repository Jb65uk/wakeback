import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../record/recorder.dart';
import '../widgets/common.dart';
import 'record_screen.dart';
import 'sessions_screen.dart';
import 'setup_screen.dart';
import 'web_page.dart';

/// Three tabs: Sails (your sessions, stats, league), Record, You. Replay isn't a tab: it opens when you
/// tap a sail, and Sync lives behind the cloud on the Sails tab now that it happens on its own.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // pages in the stack; Replay is kept alive there but has no tab of its own
  static const _sails = 0, _record = 1, _replay = 2, _you = 3;
  static const _tabPages = [_sails, _record, _you];

  // a recording cut off last time: open straight on Record so it's the first thing you see
  int _page = recorder.active ? _record : _sails;
  final _viewer = GlobalKey<WakeWebViewState>();

  // tracks arriving from a puck in the background: say so once, whichever tab is showing
  int _pullsSeen = 0;

  @override
  void initState() {
    super.initState();
    _pullsSeen = app.watcher.pulls;
    app.watcher.addListener(_onWatcher);
  }

  @override
  void dispose() {
    app.watcher.removeListener(_onWatcher);
    super.dispose();
  }

  void _onWatcher() {
    final w = app.watcher;
    if (w.pulls == _pullsSeen || !mounted) return;
    _pullsSeen = w.pulls;
    final said = w.lastEvent;
    if (said != null) toast(context, said);
  }

  Future<void> _back() async {
    if (_page != _sails) {
      await _go(_sails);
      return;
    }
    await SystemNavigator.pop();
  }

  /// Show a page. Replay gets the whole screen (the app's bars and Android's go; the viewer has its own
  /// "← Sails" on the map, and the back button works); every other page gets them back.
  Future<void> _go(int page) async {
    await _viewer.currentState?.setFullscreen(page == _replay);
    if (mounted) setState(() => _page = page);
  }

  /// A sail tapped in the Sails tab (or a record in Stats): replay it.
  /// A sail in your server totals that isn't on this device yet (recorded on your other one) is fetched first.
  Future<void> _open(String id) async {
    try {
      if ((await app.store.trackFiles(id)).isEmpty && app.signedIn && !app.demoMode) {
        if (mounted) toast(context, 'Fetching that sail from the server…');
        await app.autoSync(force: true);
        if ((await app.store.trackFiles(id)).isEmpty) {
          if (mounted) toast(context, 'That sail isn\'t on this device yet. Tap the cloud to sync.', error: true);
          return;
        }
      }
    } catch (e) {
      if (mounted) toast(context, friendly(e), error: true);
      return;
    }
    if (!mounted) return;
    await _go(_replay);
    _viewer.currentState?.openSession(id);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // Room for a rail down the side (a tablet, or a phone on its side)? Then the tabs go there and the bottom
    // bar goes: on a wide, short screen the bar costs height the replay map wants.
    final wide = MediaQuery.sizeOf(context).width >= 720;
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
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (wide && !full)
                  NavigationRail(
                    backgroundColor: const Color(0xFF0F2230),
                    labelType: NavigationRailLabelType.all,
                    groupAlignment: -0.9,
                    selectedIndex: _page == _replay ? 0 : _tabPages.indexOf(_page),
                    onDestinationSelected: (i) => _go(_tabPages[i]),
                    destinations: const [
                      NavigationRailDestination(icon: Icon(Icons.sailing_outlined), selectedIcon: Icon(Icons.sailing), label: Text('Sails')),
                      NavigationRailDestination(icon: _RecordIcon(selected: false), selectedIcon: _RecordIcon(selected: true), label: Text('Record')),
                      NavigationRailDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: Text('You')),
                    ],
                  ),
                // keyed, so turning the phone (rail in, rail out) keeps the pages as they were
                Expanded(key: const ValueKey('pages'), child: Column(children: [
                if (!full) const _PullBanner(),
                if (app.demoMode && !full)
                  Material(
                    color: t.colorScheme.primary,
                    child: InkWell(
                      onTap: () => _go(_you),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        child: Row(children: [
                          const Icon(Icons.science_outlined, size: 18, color: Colors.black),
                          const SizedBox(width: 8),
                          const Expanded(child: Text('Demo mode', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w600))),
                          Text('Exit on the You tab', style: TextStyle(color: Colors.black.withValues(alpha: 0.7), fontSize: 12)),
                        ]),
                      ),
                    ),
                  ),
                // Replay's own slim bar: the way back to your sails
                if (_page == _replay && !full)
                  Material(
                    color: t.colorScheme.surface,
                    child: InkWell(
                      onTap: () => _go(_sails),
                      child: SizedBox(
                        height: 40,
                        child: Row(children: [
                          const SizedBox(width: 8),
                          Icon(Icons.arrow_back, size: 20, color: t.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Text('Sails', style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                        ]),
                      ),
                    ),
                  ),
                Expanded(
                  child: IndexedStack(index: _page, children: [
                    SessionsScreen(onOpen: _open),
                    RecordScreen(onOpen: _open),
                    // the real viewer, served by the phone's own dock.
                    // The URL changes with demo mode (?demo=1), and the web view reloads on a URL change.
                    WakeWebView(
                      key: _viewer,
                      url: '${app.dock.localUrl}/${app.demoMode ? '?demo=1' : ''}',
                      ownBack: false,
                      onBack: _back,
                    ),
                    const SetupScreen(),
                  ]),
                ),
              ])),
              ]),
            ),
            bottomNavigationBar: full || wide
                ? null
                : NavigationBar(
                    height: 60,
                    // in Replay, Sails stays lit: that's where you came from and where back goes
                    selectedIndex: _page == _replay ? 0 : _tabPages.indexOf(_page),
                    onDestinationSelected: (i) => _go(_tabPages[i]),
                    destinations: const [
                      NavigationDestination(icon: Icon(Icons.sailing_outlined), selectedIcon: Icon(Icons.sailing), label: 'Sails'),
                      NavigationDestination(icon: _RecordIcon(selected: false), selectedIcon: _RecordIcon(selected: true), label: 'Record'),
                      NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'You'),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// The Record tab's icon: a red dot on it while a sail is being recorded.
class _RecordIcon extends StatelessWidget {
  final bool selected;
  const _RecordIcon({required this.selected});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: recorder,
        builder: (context, _) => Badge(
          isLabelVisible: recorder.active,
          smallSize: 9,
          backgroundColor: recorder.state == RecState.recording ? const Color(0xFFFF6B6B) : const Color(0xFFFFC72C),
          child: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
        ),
      );
}

/// A slim strip across the top while a puck's tracks are coming over in the background, so it's plain something
/// is happening whichever tab is showing. Gone when it's done (a line at the bottom says what arrived).
class _PullBanner extends StatelessWidget {
  const _PullBanner();
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: app.watcher,
      builder: (context, _) {
        final w = app.watcher;
        if (w.pulling == null) return const SizedBox.shrink();
        return Material(
          color: t.colorScheme.surface,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
              child: Row(children: [
                Icon(Icons.bluetooth_connected, size: 16, color: t.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text('Getting tracks from puck ${w.pulling}…', style: t.textTheme.bodySmall)),
              ]),
            ),
            LinearProgressIndicator(value: w.progress > 0 ? w.progress : null, minHeight: 2),
          ]),
        );
      },
    );
  }
}
