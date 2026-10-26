// The guide: what a sailor needs to know, in the app so it's to hand at the lake. Plain words, no internals.
// Keep it in step with firmware/puck/README.md (button and LED table) when the puck changes.
import 'package:flutter/material.dart';


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
            ('Wake the puck', 'Put it on the pad, or press its button once (the light blinks). That\'s all: the phone talks to it over Bluetooth, so there\'s nothing to hold and no WiFi anywhere. Keep the phone next to it.'),
            ('You → Pucks → Set up a puck', 'Give the puck a number, tap Connect to the puck. Not sure which puck is which? Find pucks nearby lists every puck it can hear. The app hands the puck a key tied to your account: from then on only your phone can talk to it, and everything it records is yours.'),
            ('Someone else\'s puck, or yours on a new phone', 'A puck that already has a key only takes a new one while its pairing window is open: hold its button 6 seconds until the light gives five quick blinks, then Set up a puck. A new key wipes the tracks still on it.'),
            ('Tracks, settings and firmware', 'Tap the puck under You → Pucks. With the puck awake it shows its battery, GPS, live speed and heel, whether it\'s calibrated, and the buttons do the everyday things over Bluetooth: Get its tracks, Boat is level, which way it\'s mounted, record, sleep. Settings: points a second, record on its own, how long still before a sail ends, whether and when it switches itself off. Update appears there when new puck firmware is out — one tap, the app sends it over Bluetooth.'),
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
            ('Keep holding to 6 s — five quick blinks', 'Pairing window open for 10 minutes (or shut again). Only needed to give the puck a new owner or a new phone.'),
          ],
          table2: const [
            ('Slow blink', 'Awake, no GPS fix yet'),
            ('One blink a second', 'GPS fix, waiting for the boat to move'),
            ('Double blink', 'Recording'),
            ('Fast blink', 'Pairing window open (or the puck has no key yet)'),
            ('Steady on', 'Sending a track or taking a firmware update'),
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
            ('Ashore', 'Open WakeBack with the phone next to the puck. Every minute or so the app listens for your pucks; one with tracks waiting hands them over by itself (the light goes steady) and they land in Sessions. In a hurry? Tap the puck under You → Pucks → Get its tracks. No signal needed for any of this.'),
            ('At home', 'Puck on the pad. It charges, and anything still on it comes over whenever WakeBack is open on screen nearby. It sleeps by itself after half an hour still off the pad.'),
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
            ('The app can\'t find the puck', 'It has to be awake: on the pad, or press its button once. Bluetooth on, on the phone, and WakeBack allowed to use "Nearby devices". Stand next to it. Asleep pucks don\'t answer — and after half an hour still off the pad it goes to sleep.'),
            ('"Isn\'t yours on this phone"', 'The puck answers only to the phone that set it up. On a new phone, or after someone else set it up: hold its button 6 seconds (five quick blinks) and Set up again here.'),
            ('Tracks on the puck but not coming over', 'The puck only hands over finished tracks: if it\'s still recording (double blink), tap the button once to stop. Then You → Pucks → Check for tracks now, or the puck → Get its tracks.'),
            ('Battery not charging on the pad', 'Make sure the puck sits centred on the pad (the light should breathe). Sitting there all day is fine; it rests its GPS and radio on the pad.'),
            ('Wrong venue or date on a sail', 'Open the session → the menu → Move. New venues are named "New venue near…" until you give them a name.'),
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
