// Setup → Offline maps: download the map round each venue so Replay works at the lake with no signal.
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../widgets/common.dart';

class OfflineMapsCard extends StatefulWidget {
  const OfflineMapsCard({super.key});
  @override
  State<OfflineMapsCard> createState() => _OfflineMapsCardState();
}

class _OfflineMapsCardState extends State<OfflineMapsCard> {
  List<Map<String, dynamic>> _venues = const [];
  (int, int) _usage = (0, 0);
  String? _busyVenue;
  int _done = 0, _total = 0;
  bool _cancel = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final vs = await app.store.venues();
    final u = await app.tiles.usage();
    if (mounted) {
      setState(() {
        _venues = vs.where((v) => v['lat'] is num && v['lon'] is num).toList();
        _usage = u;
      });
    }
  }

  Future<void> _download(Map<String, dynamic> v) async {
    setState(() {
      _busyVenue = v['id'] as String;
      _cancel = false;
      _done = 0;
      _total = 0;
    });
    final failed = await app.tiles.download((v['lat'] as num).toDouble(), (v['lon'] as num).toDouble(),
        radiusM: ((v['radius_m'] as num?)?.toDouble() ?? 1500.0).clamp(1500.0, 4000.0).toDouble(),
        progress: (d, t) {
          if (mounted) {
            setState(() {
              _done = d;
              _total = t;
            });
          }
        },
        cancelled: () => _cancel);
    if (mounted) {
      setState(() => _busyVenue = null);
      toast(context, _cancel ? 'Stopped; what came down is kept' : failed == 0 ? '${v['name']} saved for offline' : '${v['name']}: $failed tile${failed == 1 ? '' : 's'} didn\'t come down — try again with better signal', error: failed > 0 && !_cancel);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mb = _usage.$1 / 1048576;
    return Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ListTile(
          leading: const Icon(Icons.map_outlined),
          title: const Text('Offline maps'),
          subtitle: Text(_usage.$2 == 0 ? 'Nothing saved yet. Replay shows a blank map with no signal.' : '${_usage.$2} tiles, ${mb.toStringAsFixed(0)} MB on this phone'),
          trailing: _usage.$2 == 0
              ? null
              : TextButton(
                  onPressed: _busyVenue != null
                      ? null
                      : () async {
                          if (await confirm(context, 'Clear offline maps?', 'They download again next time you ask, or as you look at them with signal.', ok: 'Clear')) {
                            await app.tiles.clear();
                            await _load();
                          }
                        },
                  child: const Text('Clear')),
        ),
        for (final v in _venues)
          ListTile(
            dense: true,
            leading: const SizedBox(width: 24),
            title: Text('${v['name']}'),
            subtitle: _busyVenue == v['id']
                ? Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(value: _total > 0 ? _done / _total : null),
                  )
                : null,
            trailing: _busyVenue == v['id']
                ? TextButton(onPressed: () => setState(() => _cancel = true), child: Text(_total > 0 ? '$_done / $_total  Stop' : 'Stop'))
                : FilledButton.tonal(onPressed: _busyVenue != null ? null : () => _download(v), child: const Text('Download')),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Hint('Satellite and street map for about 2.5 km round the venue, zoomed right in: roughly 30–50 MB each. '
              'Do it on WiFi. Anything you look at in Replay with signal is kept too.'),
        ),
        if (_venues.isEmpty) const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 12), child: Hint('Venues appear here once you have sailed somewhere (or synced).')),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: Text('Map data © OpenStreetMap contributors, imagery © Esri', style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant))),
      ]),
    );
  }
}
