// The guide: what a sailor needs to know, in the app so it's to hand at the lake. Plain words, no internals.
// Keep it in step with firmware/puck/README.md (button and LED table) when the puck changes.
import 'package:flutter/material.dart';

import '../app_state.dart';

/// Which section to open the guide on (from a "How does this work?" link elsewhere).
enum GuideTopic { start, puck, button, sailing, phone, sails, maps, fixes }

class GuideScreen extends StatefulWidget {
  final GuideTopic? open;
  const GuideScreen({super.key, this.open});
  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  final _keys = {for (final t in GuideTopic.values) t: GlobalKey()};

  @override
  void initState() {
    super.initState();
    if (widget.open != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _keys[widget.open]!.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300), alignment: 0.05);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hotspot = app.hotspotName;
    return Scaffold(
      appBar: AppBar(title: const Text('Guide')),
      body: ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 32), children: [
        _Section(
          key: _keys[GuideTopic.start],
          icon: Icons.flag_outlined,
          title: 'Starting out',
          open: widget.open == GuideTopic.start || widget.open == null,
          steps: const [
            ('Log in or create an account', 'You → Log in or create account. Your sails then sync to the server and show on every device you sign in on. New accounts wait for the admin to approve them (or are approved at once if that\'s turned on).'),
            ('Add your boat', 'You → Boats. "Solo 5843", "Mirror" — the first one is the one you usually sail. Every sail is filed against a boat, so stats and the league can compare like with like.'),
            ('Add friends', 'You → Friends → enter their email. Once they accept, you see each other\'s sails (unless one is made private) and share a league.'),
            ('Either record with the phone, or set up a puck', 'No puck? The Record tab turns the phone into the tracker. With a puck, see the next section — it records every sail by itself and the phone just collects the tracks.'),
          ],
        ),
        _Section(
          key: _keys[GuideTopic.puck],
          icon: Icons.sensors,
          title: 'Setting up a puck',
          open: widget.open == GuideTopic.puck,
          steps: [
            ('Give your phone a hotspot', 'Settings → Hotspot. Any name and password; 2.4 GHz (the puck can\'t see 5 GHz). Turn off "switch off hotspot automatically" so it\'s still up when you come ashore. This is the only WiFi the puck will ever use, so it works at the lake, the car park, anywhere.'),
            ('Put the puck in setup mode', 'A brand-new puck is already in setup mode. Otherwise hold its button for 6 seconds until the light gives five quick blinks.'),
            ('You → Pucks → Set up a puck', 'Type the hotspot name and password, give the puck a number, tap Connect to the puck, and tap Connect when the phone asks. The app hands the puck the hotspot details and a key tied to your account, so everything it records is yours.'),
            ('Turn the hotspot on, puck on the pad', 'Within a minute You → Pucks → See them check in shows it on the dock with its battery. Done. Wrong hotspot password later? Change it on the phone and do Set up again.'),
            ('Settings and firmware', 'Tap the puck under You → Pucks. Open the puck\'s page for Boat is level, which way it\'s mounted, the tracks on it. Update appears there when new puck firmware is out — one tap, the app sends it. Puck on the pad with hotspot "$hotspot" on: it answers within a minute.'),
          ],
        ),
        _Section(
          key: _keys[GuideTopic.button],
          icon: Icons.radio_button_checked,
          title: 'The button and the light',
          open: widget.open == GuideTopic.button,
          table: const [
            ('Press when asleep', 'Wakes it. (On the pad wakes it too.)'),
            ('Tap', 'Start or stop recording by hand. You rarely need this: it starts itself when the boat moves off and stops after 10 minutes still.'),
            ('Hold 2 s — three blinks, let go', 'Sleep now.'),
            ('Keep holding to 6 s — five quick blinks', 'Setup WiFi on (or off again). Only needed off the pad.'),
          ],
          table2: const [
            ('Slow blink', 'Awake, no GPS fix yet'),
            ('One blink a second', 'GPS fix, waiting for the boat to move'),
            ('Double blink', 'Recording'),
            ('Fast blink', 'Setup WiFi is on'),
            ('Steady on', 'Talking to the phone (uploading or updating)'),
            ('Five quick blinks, pause', 'Storage full — nothing being recorded'),
            ('Breathing / solid (on the pad)', 'Charging / full'),
          ],
        ),
        _Section(
          key: _keys[GuideTopic.sailing],
          icon: Icons.sailing,
          title: 'A sailing day',
          open: widget.open == GuideTopic.sailing,
          steps: const [
            ('Before', 'Take the puck off the pad and clip it in. Nothing to press. It wakes when you pick it up and is ready once the light blinks once a second (a GPS fix — give it a minute outdoors the first time).'),
            ('On the water', 'It starts recording by itself as the boat moves off and keeps going through the day. Stopped for lunch? After 10 minutes still it closes that track; the next move-off starts another. All of a day lands in one session.'),
            ('Ashore', 'Hotspot on, WakeBack open on the phone. The puck looks for the hotspot every minute for a quarter of an hour, then every five, and hands over the tracks as soon as it finds it (the light goes steady). The Sails tab shows them straight away. No signal needed for any of this.'),
            ('At home', 'Puck on the pad. It charges, and anything still on it comes over whenever WakeBack is open on screen. It sleeps by itself after half an hour still off the pad.'),
          ],
        ),
        _Section(
          key: _keys[GuideTopic.phone],
          icon: Icons.radio_button_unchecked,
          title: 'Recording with the phone',
          open: widget.open == GuideTopic.phone,
          steps: const [
            ('Record tab', 'Pick the boat, tap Start. Works with the screen off — the notification shows it running. Put the phone in a dry bag; the GPS is fine through it.'),
            ('Stop and save', 'Tap Stop → Save. It lands in the Sails tab like a puck track, filed to the venue and your boat.'),
            ('Mates with iPhones', 'They can use the web recorder at /record on the server, or import a GPX from any sailing app (You → Import tracks).'),
          ],
        ),
        _Section(
          key: _keys[GuideTopic.sails],
          icon: Icons.map_outlined,
          title: 'Your sails, stats and friends',
          open: widget.open == GuideTopic.sails,
          steps: const [
            ('Sessions', 'One per day and venue. Tap one to replay: every boat on the map, speed and heel, races picked out automatically (accept or adjust them). Lay marks and start lines; they\'re kept.'),
            ('Friends or private', 'Each sail is visible to your friends unless you switch it to private on the session. Private sails stay off everyone\'s league, including the admin\'s.'),
            ('Stats and League', 'Miles, hours, top speed, best averages, badges; the league ranks you and your friends by class. Tap a sail → Share for a picture of the track to send on WhatsApp.'),
            ('Sync', 'Happens by itself when you\'re signed in and have signal. The cloud icon on Sails shows where it\'s up to; tap it for details.'),
          ],
        ),
        _Section(
          key: _keys[GuideTopic.maps],
          icon: Icons.download_for_offline_outlined,
          title: 'Maps with no signal',
          open: widget.open == GuideTopic.maps,
          steps: const [
            ('Download your venue', 'You → Maps → the venue → download (30–50 MB, do it on WiFi). Replays then work at the lake with no signal.'),
          ],
        ),
        _Section(
          key: _keys[GuideTopic.fixes],
          icon: Icons.build_outlined,
          title: 'If something\'s not right',
          open: widget.open == GuideTopic.fixes,
          steps: [
            ('Puck never shows on the dock', 'Hotspot on, 2.4 GHz, name and password exactly as given to the puck, and WakeBack open on screen — the phone only listens while the app is in front. Still nothing? You → Pucks → the puck → Set up again.'),
            ('Puck says "dock refused the key"', 'Its key was revoked (forgotten in the app, or by the admin). Set up again gives it a new one.'),
            ('Tracks on the puck but not coming over', 'The puck only hands over finished tracks: if it\'s still recording (double blink), tap the button once to stop. Then it looks for hotspot "$hotspot" within a minute.'),
            ('Battery not charging on the pad', 'Make sure the puck sits centred on the pad (the light should breathe). Sitting there all day is fine; it rests its GPS and radio on the pad.'),
            ('Wrong venue or date on a sail', 'Open the session → the menu → Move. New venues are named "New venue near…" until you give them a name.'),
            ('"No internet" errors', 'The phone is on a network with no internet — usually the hotspot or a puck\'s setup WiFi. Hop off it (or just turn WiFi off) and the app uses mobile data.'),
            ('App update', 'You → About → Check. Updates install over the top; nothing is lost.'),
          ],
        ),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool open;
  final List<(String, String)>? steps, table, table2;
  const _Section({super.key, required this.icon, required this.title, required this.open, this.steps, this.table, this.table2});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(icon),
        title: Text(title, style: t.textTheme.titleMedium),
        initiallyExpanded: open,
        shape: const Border(),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (steps != null)
            for (final (h, body) in steps!) ...[
              Text(h, style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary)),
              const SizedBox(height: 2),
              Text(body, style: t.textTheme.bodyMedium?.copyWith(height: 1.35)),
              const SizedBox(height: 10),
            ],
          if (table != null) _table(t, 'Button', table!),
          if (table2 != null) ...[const SizedBox(height: 8), _table(t, 'Light', table2!)],
        ],
      ),
    );
  }

  Widget _table(ThemeData t, String heading, List<(String, String)> rows) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(heading, style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary)),
        const SizedBox(height: 4),
        for (final (a, b) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 150, child: Text(a, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
              const SizedBox(width: 8),
              Expanded(child: Text(b, style: t.textTheme.bodyMedium)),
            ]),
          ),
      ]);
}
