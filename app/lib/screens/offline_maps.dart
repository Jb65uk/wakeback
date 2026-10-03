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
  final Map<String, (int, int, int)> _per = {}; // venue id -> (bytes, tiles here, tiles in full download)
  String? _busyVenue;
  int _done = 0, _total = 0;
  bool _cancel = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static double _radius(Map<String, dynamic> v) => ((v['radius_m'] as num?)?.toDouble() ?? 1500.0).clamp(1500.0, 4000.0).toDouble();

  Future<void> _load() async {
    final vs = (await app.store.venues()).where((v) => v['lat'] is num && v['lon'] is num).toList();
    final u = await app.tiles.usage();
    final per = <String, (int, int, int)>{};
    for (final v in vs) {
      per['${v['id']}'] = await app.tiles.venueUsage((v['lat'] as num).toDouble(), (v['lon'] as num).toDouble(), radiusM: _radius(v));
    }
    if (mounted) {
      setState(() {
        _venues = vs;
        _usage = u;
        _per
          ..clear()
          ..addAll(per);
      });
    }
  }

  Future<void> _deleteVenue(Map<String, dynamic> v) async {
    final u = _per['${v['id']}'];
    if (!await confirm(context, 'Delete offline map?', '${v['name']}: ${((u?.$1 ?? 0) / 1048576).toStringAsFixed(0)} MB comes off this phone. Replay there needs signal until you download it again.', ok: 'Delete', danger: true)) return;
    final n = await app.tiles.deleteVenue((v['lat'] as num).toDouble(), (v['lon'] as num).toDouble(), radiusM: _radius(v));
    if (mounted) toast(context, 'Deleted $n tile${n == 1 ? '' : 's'} for ${v['name']}');
    await _load();
  }

  Future<void> _download(Map<String, dynamic> v) async {
    setState(() {
      _busyVenue = v['id'] as String;
      _cancel = false;
      _done = 0;
      _total = 0;
    });
    final failed = await app.tiles.download((v['lat'] as num).toDouble(), (v['lon'] as num).toDouble(),
        radiusM: _radius(v),
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
          Builder(builder: (context) {
            final u = _per['${v['id']}'];
            final have = u?.$2 ?? 0, full = u?.$3 ?? 0;
            final complete = full > 0 && have >= full * 0.98; // a tile or two that never came down still counts
            final sub = _busyVenue == v['id']
                ? Padding(padding: const EdgeInsets.only(top: 6), child: LinearProgressIndicator(value: _total > 0 ? _done / _total : null))
                : have == 0
                    ? null
                    : Text(complete ? 'Saved · ${(u!.$1 / 1048576).toStringAsFixed(0)} MB' : 'Part saved · $have of $full tiles, ${(u!.$1 / 1048576).toStringAsFixed(0)} MB');
            return ListTile(
              dense: true,
              leading: Icon(complete ? Icons.offline_pin : Icons.map_outlined, size: 20, color: complete ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
              title: Text('${v['name']}'),
              subtitle: sub,
              trailing: _busyVenue == v['id']
                  ? TextButton(onPressed: () => setState(() => _cancel = true), child: Text(_total > 0 ? '$_done / $_total  Stop' : 'Stop'))
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      if (have > 0)
                        IconButton(
                          tooltip: 'Delete this venue\'s offline map',
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: _busyVenue != null ? null : () => _deleteVenue(v),
                        ),
                      if (!complete) FilledButton.tonal(onPressed: _busyVenue != null ? null : () => _download(v), child: Text(have > 0 ? 'Finish' : 'Download')),
                    ]),
            );
          }),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Hint('Download a venue\'s map to replay there with no signal. About 30–50 MB each, so do it on WiFi.'),
        ),
        if (_venues.isEmpty) const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 12), child: Hint('Venues appear here once you have sailed somewhere (or synced).')),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: Text('Map data © OpenStreetMap contributors, imagery © Esri', style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant))),
      ]),
    );
  }
}
