// "Find pucks nearby": a sheet that scans over Bluetooth and lists every WakeBack puck it can hear, with its
// signal. Tap one to pick it. Used by Set up a puck and by Your pucks.
import 'dart:async';

import 'package:flutter/material.dart';

import '../puck/puck_ble.dart';
import 'common.dart';

/// Scan and let the user pick a puck. Returns the one tapped, or null if they closed the sheet.
/// [exclude]: puck numbers to leave off the list (ones already set up), shown greyed instead.
Future<PuckSeen?> pickPuckNearby(BuildContext context, {Set<int> exclude = const {}, String title = 'Pucks nearby'}) {
  return showModalBottomSheet<PuckSeen>(
    context: context,
    showDragHandle: true,
    builder: (_) => _PuckPickerSheet(exclude: exclude, title: title),
  );
}

class _PuckPickerSheet extends StatefulWidget {
  final Set<int> exclude;
  final String title;
  const _PuckPickerSheet({required this.exclude, required this.title});
  @override
  State<_PuckPickerSheet> createState() => _PuckPickerSheetState();
}

class _PuckPickerSheetState extends State<_PuckPickerSheet> {
  final _seen = <int, PuckSeen>{};
  StreamSubscription<PuckSeen>? _sub;
  bool _scanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _scan() {
    _sub?.cancel();
    setState(() {
      _scanning = true;
      _error = null;
      _seen.clear();
    });
    _sub = PuckBle.scan(timeout: const Duration(seconds: 10)).listen(
      (p) {
        if (mounted) setState(() => _seen[p.puck] = p);
      },
      onError: (Object e) {
        if (mounted) {
          setState(() {
            _error = friendly(e);
            _scanning = false;
          });
        }
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final pucks = _seen.values.toList()..sort((a, b) => a.puck.compareTo(b.puck));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(widget.title, style: t.textTheme.titleLarge)),
            if (_scanning) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) else IconButton(tooltip: 'Look again', icon: const Icon(Icons.refresh), onPressed: _scan),
          ]),
          const SizedBox(height: 4),
          const Hint('A puck shows up here while it\'s awake: on the pad, or press its button once.'),
          const SizedBox(height: 8),
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.red.shade900.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(8)),
              child: Text(_error!, style: t.textTheme.bodyMedium),
            )
          else if (pucks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(_scanning ? 'Listening…' : 'No pucks heard. Wake one up and tap the arrow to look again.', style: t.textTheme.bodyMedium),
            )
          else
            for (final p in pucks)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(radius: 16, backgroundColor: t.colorScheme.primary, child: Text('${p.puck}', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700))),
                title: Text('WakeBack puck ${p.puck}'),
                subtitle: Text(widget.exclude.contains(p.puck) ? '${p.signal} · already in your list' : p.signal),
                trailing: Icon(p.rssi >= -65
                    ? Icons.signal_cellular_alt
                    : p.rssi >= -80
                        ? Icons.signal_cellular_alt_2_bar
                        : Icons.signal_cellular_alt_1_bar),
                enabled: !widget.exclude.contains(p.puck),
                onTap: widget.exclude.contains(p.puck) ? null : () => Navigator.pop(context, p),
              ),
        ]),
      ),
    );
  }
}
