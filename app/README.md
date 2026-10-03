# WakeBack app (Android phone / tablet)

**The dock in your pocket.** The app runs the same API as `server/app.py` on the phone and shows the
**real viewer** (`viewer/index.html`) — races, marks, start/finish lines, tacks & gybes, wind, big screen,
crew names, venues, weather, the Dock page — all saved on the phone. Every session is a date + venue, and everything
your phone records is marked as yours (the You tab).

- **No dock Pi yet?** Turn on the phone's hotspot. Pucks join it and upload to the phone exactly as they
  would to the Pi (same `/api/pucks/checkin` and `/api/upload`).
- **Your server** (`app.py` at home or on the Pi): the **Sync** tab copies each day's tracks, names,
  races and course both ways. **Invite a mate** sends the server link.
- Works at the lake with no signal (Leaflet is bundled; only the map background needs internet).

```
app/
  lib/dock/store.dart         the dock's storage + rules, ported line for line from server/app.py
  lib/dock/pocket_dock.dart   the dock's HTTP API on port 5000 + serves the viewer pages
  lib/dock/stats.dart         miles / hours / speeds / wind / heel per track, totals and the league (= server/stats.py)
  lib/dock/badges.dart        personal bests ("new record") and badges, from your tracks
  lib/dock/tiles.dart         map tile cache: the dock serves /tiles/... so Replay works offline
  lib/share_card.dart         the picture of a session for WhatsApp
  lib/updates.dart            checks GitHub releases, downloads + installs a newer build
  lib/sync/server_sync.dart   two-way sync with your server (existing endpoints only)
  lib/demo/                   fake_pucks.py + gen_fake_data.py, ported
  lib/screens/                three tabs: Sails (list, Stats, League), Record, You. Replay (the viewer) opens when you tap a sail; Sync is behind the cloud on Sails
  assets/web/                 viewer pages (copied from ..\viewer by setup.ps1) + Leaflet
  test/dock_test.dart         checks the phone dock answers like app.py (incl. stats), and sync between two docks
  test/fixtures/              two small tracks whose numbers were taken from server/stats.py
```

## 1. Install Flutter (once, ~15 min)

1. Download the Flutter SDK zip for Windows (docs.flutter.dev → Get started → Windows → Android),
   extract to `C:\dev\flutter`, add `C:\dev\flutter\bin` to your user PATH, open a new terminal.
2. Install **Android Studio**, open it once to finish setup, then:
   ```
   flutter doctor --android-licenses
   flutter doctor
   ```
   Ticks for *Flutter* and *Android toolchain* are what matter.

## 2. Set up and test

```powershell
cd <wakeback folder>\app
.\setup.ps1
.\setup.ps1 -Test        # "All tests passed!"
```

## 3. Run it

- **Emulator on the PC:** Android Studio → Virtual Device Manager → + → Pixel 8 → newest image → ▶. Then `.\setup.ps1 -Run`.
- **Your phone (USB):** Developer options → USB debugging on, plug in, `.\setup.ps1 -Run`.
- **Mate's phone:** `.\setup.ps1 -Build` → send `WakeBack.apk`.

Press `r` in the terminal to reload after a change, `q` to quit.

## 4. Try it

1. **You → Advanced → Try the demo → Add a demo race morning.** Back on **Sails**, tap the day to replay it; in Replay open the panel (on a phone: the
   panel button) → today's date → it's the full viewer: suggested races, Race 1, Estimate wind, tacks & gybes,
   start results, **Big screen**, **Full screen**.
2. **You → Demo pucks** on, then **Advanced → See your pucks**: five pucks charging; P4 comes back after
   ~20 s and uploads a session that appears in the list.
3. **Sync:** run your server on the PC (`python server\app.py`), then in the emulator use
   `http://10.0.2.2:5000` (the emulator's name for your PC) → **Check** → **Sync**. Open
   `http://localhost:5000` on the PC: the demo day's there with its races and course.
   On a real phone use the PC's LAN address, e.g. `http://192.168.1.20:5000`.

## Pucks uploading to the phone (no dock)

1. Android Settings → Hotspot: name **wakeback** (or whatever you set in You → Advanced) and the password your
   pucks use. Turn it on.
2. Open WakeBack and keep it open (screen on is safest) while pucks sit on their charging pads.
3. Pucks join, check in every ~30 s and upload. Watch them on the viewer's **Dock** tab.

The firmware side is in `docs/PHONE_DOCK.md`: pucks look for the dock at their WiFi **gateway** on
port 5000, which is the Pi on its own WiFi and the phone on its hotspot — one code path for both.

## Troubleshooting

| Problem | Fix |
|---|---|
| `flutter` not recognised | PATH not set, or terminal opened before you set it |
| Build asks for a different NDK version | copy the `ndkVersion = "…"` line it prints into `android\app\build.gradle.kts` under `android {` |
| You → Advanced shows "Couldn't open port 5000" | another app has it; restart the phone. Replays still work, pucks can't upload until then |
| Sync: "Can't reach the server" | check the address (include `http://` or `https://`); from the emulator the PC is `10.0.2.2` |
| Map background blank | no internet for tiles — tracks, marks and lines still draw |

Anything else — paste the error.
