# WakeBack app (Android phone / tablet)

**Your pucks, your sails.** The app talks to your pucks over Bluetooth (`lib/puck/`): sets them up, pulls their
tracks and pushes firmware. It runs the same API as `server/app.py` on the phone (loopback only) and shows the
**real viewer** (`viewer/index.html`) — races, marks, start/finish lines, tacks & gybes, wind, big screen,
crew names, venues, weather — all saved on the phone. Every session is a date + venue, and everything
your phone records is marked as yours (the You tab).

- **Pucks**: a puck belongs to one account. Set up a puck gives it a key from the server; from then on only a
  phone holding that key can talk to it (`firmware/puck/src/ble.h`). While WakeBack is open the app listens for
  your pucks and pulls any waiting tracks by itself (`lib/puck/puck_watcher.dart`); the puck screen does it on demand.
- **Your server** (`app.py` at home or on the Pi): the **Sync** tab copies each day's tracks, names,
  races and course both ways. **Invite a mate** sends the server link.
- Works at the lake with no signal (Leaflet is bundled; only the map background needs internet).

```
app/
  lib/dock/store.dart         the dock's storage + rules, ported line for line from server/app.py
  lib/dock/pocket_dock.dart   the dock's HTTP API on loopback + serves the viewer pages (demo pucks use it; real ones talk Bluetooth)
  lib/puck/puck_ble.dart      Bluetooth to a puck: scan (own pucks by owner hash), hello/auth (HMAC), commands, tracks, firmware
  lib/puck/wbt.dart           the puck's compact .wbt track format decoded to CSV (port of firmware/puck/src/track.h)
  lib/puck/puck_pull.dart     pull every finished track off a puck into Sessions, then clear it off the puck
  lib/puck/puck_watcher.dart  does that by itself every 90 s while the app is open
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

**First:** run `setup.ps1` (or let the GitHub build do it) before building, because it copies the viewer pages from `..\viewer` into `assets/web/`; they aren't in git.

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

## Pucks and the phone

1. You → Pucks → Set up a puck, with the puck awake (on the pad, or press its button). The app hands it a key
   from your account over Bluetooth. A puck that already has a key needs its pairing window open first (hold its
   button 6 s).
2. After a sail: open WakeBack near the puck. Every 90 s the app listens; a puck of yours advertising tracks
   waiting gets emptied into Sessions and cleared. Or tap the puck → Get its tracks.
3. Everything about the puck (live numbers, level, which way up, record, sleep, firmware) is on its screen.

## Troubleshooting

| Problem | Fix |
|---|---|
| `flutter` not recognised | PATH not set, or terminal opened before you set it |
| Build asks for a different NDK version | copy the `ndkVersion = "…"` line it prints into `android\app\build.gradle.kts` under `android {` |
| "Isn't yours on this phone" | the puck answers only to the phone that set it up: hold its button 6 s and Set up again |
| Sync: "Can't reach the server" | check the address (include `http://` or `https://`); from the emulator the PC is `10.0.2.2` |
| Map background blank | no internet for tiles — tracks, marks and lines still draw |

Anything else — paste the error.
