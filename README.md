# WakeBack

GPS WakeBack pucks for dinghy racing: log where you sailed, how fast and how heeled, then overlay everyone's tracks and replay the race on a projector or train against yourself.

```
wakeback/
├── viewer/index.html     the replay viewer, one file; works on its own or served by the server (and inside the app)
├── viewer/dock.html      the Dock page: puck status, internet, WiFi (on a Pi)
├── viewer/admin.html     the admin page (/admin): users, tracks, puck keys, log of changes
├── viewer/record.html    record a sail with the phone's own GPS in the browser (/record)
├── app/                  Android phone/tablet app: the dock in your pocket, runs this same viewer (see app/README.md)
├── docs/PHONE_DOCK.md    how pucks upload to a phone hotspot instead of the dock (firmware notes)
├── docs/ROADMAP.md       where this is heading: your own sailing, friends, events
├── server/app.py         the server (Flask): sessions, uploads, venues, pucks, dock
├── server/accounts.py    accounts, friends, sharing, puck keys, admin (SQLite)
├── server/stats.py       per-track numbers, your totals and the league
├── Dockerfile, docker-compose.yml, .dockerignore   the server as a container (NAS), with updater and backup
├── tools/gen_fake_data.py    makes demo sessions in the exact puck CSV format (data/sessions is generated, not in git)
├── tools/fake_puck_upload.py pretends to be a puck landing on the dock (the other tools share its upload())
├── tools/fake_pucks.py       a dock full of pretend pucks checking in (for the Dock page)
├── tools/test_server.py      end-to-end checks of the server on a throwaway copy
├── tools/test_race_suggest.mjs  checks the viewer's race suggestions against made-up fleets
├── data/sessions/<date>_<venue>/  one folder per session (sailing date + venue), one file per boat
├── BUILD.md              build one puck on a breadboard: shopping list, wiring in stages, first track
├── hardware/carrier/     60 mm carrier PCB: Gerbers for JLCPCB, previews, assembly notes, generator
├── hardware/case/        3D-printed puck case: base, screw lid (O-ring), GPS shelf, deck cradle. STLs + generator
└── firmware/puck/        the puck firmware: setup WiFi page, auto-record, upload, sleep
```

## Quick start (VS Code)

1. Open this folder in VS Code. Install the recommended extensions when prompted.
2. `Terminal > Run Task > Install requirements` (or `pip install -r server/requirements.txt`).
3. `Run Task > Generate fake data`: `data/sessions` isn't in git, this makes the two demo days.
4. Press F5 with **Run dock server** selected, then open http://localhost:5000.
5. The panel shows two demo sessions from the fake data: click **Sun 20 Sep, Southport SC** to load Sunday (three pucks plus Steve's phone, two races back to back in one log), press **Play**, then **B** for the big-screen projector view.
6. The course is already laid for the demo day (three marks, left to starboard). Under Races, WakeBack offers the likely races it found in the tracks: tick them and press **Add selected** (or press **Suggest races** to look again). Pick **Race 1**, then **Estimate** next to Wind. Tap **Tacks & gybes** under a boat, then filter to Tacks or Gybes, sort Worst first, and tap any one to jump the replay there.
7. `Run Task > Fake puck upload` to watch a session appear on the dock as a puck would post it.

Checks: `python tools/test_server.py` and `node tools/test_race_suggest.mjs`.

No server? Just open `viewer/index.html` in a browser and drag files from `data/sessions/` onto it. Everything works except the sessions list and shared puck names.

No puck? Open **/record** on a phone: it records a sail with the phone's GPS in the browser, saves it on the phone, and sends it to the server (sign in on the viewer first when accounts are on). The viewer's sign-in box links to it.

## Dock page

Open **Dock** (tab at the top, or http://localhost:5000/dock). To see it with pucks in it on a laptop, run the **Fake pucks** task while the server's running: P1 full, P2/P3 charging, P4 comes back from sailing after ~20 s and uploads a session, P5 is on the pad but not charging, P6 has never checked in.

- Every puck: on the dock or away, battery % with charging / full / not charging, last upload (when, which day, how big, who sailed it), last seen, storage free, firmware (flags ones behind)
- Warnings up top: pucks not charging on the pad, low batteries
- Internet: online or not, and through what. "Connect to WiFi" scans for networks and joins one (club WiFi, a phone hotspot at an away venue). It only appears where the server can change WiFi: a Pi with NetworkManager (the default on Raspberry Pi OS), or a laptop with `WAKEBACK_DEMO_WIFI=1` (made-up networks, so the flow can be tried; the VS Code tasks set it). With accounts on, only the admin may change WiFi. The dock's own `wakeback` WiFi stays up regardless
- Dock health: disk space, clock, uptime, sessions stored

Settings (environment variables):

| Variable | What | Default |
|---|---|---|
| `WAKEBACK_ADMIN` | your email: turns accounts on, and the account with this email is the admin (`/admin`) | off |
| `WAKEBACK_ADMIN_RESET` | locked out? a new admin password, applied once at start-up; then remove it | none |
| `WAKEBACK_FLEET` | how many pucks the club has, so ones never seen still get a row | 0 |
| `WAKEBACK_WIFI` | the dock Pi's own WiFi name, shown on the Dock page | wakeback |
| `WAKEBACK_OWNER` | owner of tracks from pucks with no owner set, e.g. `Southport SC` | none |
| `WAKEBACK_UPLINK_IF` | WiFi adapter the Pi uses to reach the internet (USB dongle; onboard wlan0 runs the dock WiFi) | wlan1 |
| `WAKEBACK_DEMO_WIFI` | `1`: made-up WiFi networks on the Dock page (laptop demo) | 0 |
| `WAKEBACK_DEBUG` | `1`: Flask's debugger and auto-reload when run as `python server/app.py` (dev only) | 0 |
| `PORT` | the port `python server/app.py` listens on | 5000 |

## Phone / tablet app

`app/` is an Android app that runs the dock's API on the phone and shows this same viewer, so
everything above works on a phone or tablet, saved on the device, with no dock Pi:

- **No dock?** Turn on the phone's hotspot (`wakeback`): pucks join it and upload to the phone exactly as
  they would to the Pi — the dock is always the WiFi gateway on port 5000 (`docs/PHONE_DOCK.md`).
- **Sync** tab: copies each day's tracks, names, races and course both ways with this server
  (at home or on the Pi), using the API below — nothing extra on the server. **Invite a mate** sends the link.
- Build it on Windows with `app/setup.ps1` (see `app/README.md`).

The viewer knows when it's inside the app (`window.WakeBackApp`) and hands full screen and the GPX
download to the app; in a browser or on the Pi it behaves exactly as before.

## Viewer features

- Replay all boats on one clock, live speed/heel/pitch/VMG cards, 60 s trails, heading arrows
- Colour tracks by boat or by speed; satellite or OpenSeaMap chart base
- Races: split a day into time windows by hand (11:00–12:00, 12:00–13:30) or from the suggestions WakeBack works out from the tracks (boats milling about, then setting off together, then stopping; nothing is added until you tick it); stats, tacks, chart and replay all follow the selected race, and races are saved on the dock per day
- Wind direction typed in, estimated from the beating headings, or from **Get weather** (Open-Meteo: direction, speed and gusts for where and when you sailed, saved with the day, set per race, live on the map and big screen) → VMG, true wind angle, upwind/downwind averages, wind arrow on the map
- Tacks, gybes and mark roundings told apart, each with speed before/min, time back up to speed and metres lost; averages for each (tack loss, gybe loss, mark loss); click any one to jump the replay there
- Course marks: add them on the map, drag to adjust, set each to port (red) or starboard (green). Set per race, so a moved windward mark between races is fine. With marks placed, roundings are found at the real marks on any course shape (reaches included), and a rounding the wrong way is flagged
- Start and finish lines: tap the committee boat end then the pin end, drag to adjust; a line can be start, finish or both. With the gun time (typed, or estimated from the fleet) you get each boat's start: seconds late, distance back and speed at the gun, which end, and OCS (over early, and whether they went back). The finish gives order, elapsed time and gap to first. Saved per race with the marks
- Port tack red, starboard tack green: colour tracks "By tack", wind-angle chart and cards use the same colours, and the list shows which tack each manoeuvre ended on
- Wrong call? Change any tack/gybe/mark to something else, or "Not one"; corrections are saved with the session
- Align starts to race a mate from a different day or yourself from last week
- Big screen mode (B) for the projector: per-boat cards with your choice of data, loop replay, full screen (F)
- Puck numbers are fixed IDs (P3 is always P3, always the same colour); who sailed each puck is set per session, since pucks get handed out differently each time. Names you've used before pop up as suggestions
- Download all loaded tracks as one GPX to share

## Puck log format (what the firmware writes)

CSV, 10 Hz, one file per session, filename `puck<N>_<HHMMSS>.csv`:

```
t_ms,lat,lon,sog_kn,hdg,heel,pitch
1758364200000,53.6503120,-3.0101890,4.62,067,-11.3,-0.8
```

- `t_ms` UTC epoch milliseconds from the GPS
- `sog_kn` speed over ground in knots (GPS Doppler)
- `hdg` degrees true; fused IMU heading when available, otherwise course over ground
- `heel` degrees, positive to starboard
- `pitch` degrees, positive bow up

Phone/watch GPX files are accepted too; they just lack heel and pitch.

## Dock API

| Method | Path | What |
|---|---|---|
With accounts on, every route below except `/api/hello` and `/api/pucks/checkin` needs a sign-in (bearer token or cookie) or a puck key; errors come back as `{"error": "..."}`.

| Method | Path | What |
|---|---|---|
| GET | `/api/sessions` | list the sessions you can see: `[{"id":"2026-09-20_southport-sc","date","venue","venue_name","venue_new","files","count","races","owners":{"file":"name"},"sharing","boats","mine","stats"}]` (owners' emails are listed only for the admin, as `owner_emails`) |
| GET | `/api/sessions/<session>/<file>` | fetch one track (`.csv`/`.gpx` only; 404 if you can't see it) |
| POST | `/api/upload` | multipart `file` (+ optional `puck`, `owner_name`, `owner_email`, `visibility`, `boat`); filed under the date of its first timestamp and the venue of its first position → `{session, file, venue, venue_name}` |
| DELETE | `/api/sessions/<session>/<file>` | remove a track (its owner or the admin) |
| POST | `/api/sessions/<session>/tracks/<file>` | `{visibility: "friends"/"private", boat}` (owner or admin); the admin may also set `owner_email` |
| GET / PUT | `/api/sessions/<session>/races` | race windows for that day: `[{"name","start","end","gun","marks":[...],"lines":[{"kind":"start"/"finish"/"both","a":{lat,lon},"b":{lat,lon}}]}]`, times in epoch ms, a = committee boat end, b = pin |
| GET / PUT | `/api/sessions/<session>/meta` | whole-session marks, your corrections and the day's weather: `{"marks":[{"name","lat","lon","side":"port"/"stbd"}],"fixes":[...],"weather":{"src","lat","lon","got","pts":[[t_ms,dir,kn,gust],...]}}` |
| GET / PUT | `/api/sessions/<session>/crew` | who had which puck that day: `{"puck3": "Dave"}` |
| | | races, meta and crew: 404 unless the session exists and you can see a track in it; PUT needs you to own a track in it (or be the admin) |
| POST | `/api/sessions/<session>/move` | `{"venue": id}`: a session filed at the wrong venue; merges into that venue's session for the day (every track's owner, or the admin) |
| GET / POST | `/api/venues` | list venues / add one `{"name","lat","lon","radius_m"}` (an `id` that already exists is returned as-is, for sync) |
| PUT | `/api/venues/<id>` | name an automatic "New venue near …" (anyone); rename or move a named venue (admin, when accounts are on) |
| GET | `/api/sailors` | every name used in a session you can see (for the name picker) |
| GET | `/api/stats` | your totals: `?period=month/year/all`, `?boat=Solo 5843` |
| GET | `/api/league` | you and your friends ranked: `?period=`, `?cls=Solo` |
| GET / DELETE | `/api/me/export`, `/api/me` | your data as a zip / delete your account and tracks (`{password}`) |
| POST | `/api/auth/signup`, `/login`, `/logout`, `/status`, `/password`, `/forgot`, `/reset` | accounts (see `server/accounts.py`); 404 when accounts are off |
| GET | `/api/auth/me` | `{accounts, user, friends, pending_in, pending_out}` |
| GET / POST / DELETE | `/api/friends`, `/api/friends/request`, `/api/friends/<id>/accept`, `/decline`, `/api/friends/<id>` | friends |
| GET / POST / DELETE | `/api/pucks/keys`, `/api/pucks/keys/<id>` | your puck keys: issue one for puck N (shown once), revoke one |
| POST | `/api/pucks/checkin` | puck check-in every ~30 s on the pad: `{"puck":3,"battery_mv":4012,"charging":"charging"/"full"/"not","on_pad":true,"free_kb":12000,"total_kb":14336,"fw":"0.3.1","pending":1}` (+ `X-Puck-Key` header); reply carries dock time |
| GET | `/api/pucks` | every puck's status for the Dock page (last uploads only from tracks you can see) |
| GET | `/api/dock/status` | internet, disk, clock, uptime, `can_manage_wifi` |
| GET / POST | `/api/wifi/scan`, `/api/wifi/connect` | find and join a WiFi network (a Pi with NetworkManager; admin only with accounts on) |
| GET / POST / PUT / DELETE | `/api/admin/users`, `/api/admin/users/<id>`, `/api/admin/settings`, `/api/admin/audit`, `/api/admin/resets`, `/api/admin/pucks` | the admin page's routes |
| GET | `/api/hello` | server time, used by pucks to confirm they're talking to the right box |

## On a NAS (or any Docker box): accounts, friends, admin

GitHub builds the server as a container on every change: `ghcr.io/jb65uk/wakeback-server:latest`.
Use `docker-compose.yml` from this repo (on a Ugreen NAS: Docker → Project → Create, paste it). It
listens on port 5090 and keeps everything in a `data` folder next to the compose file. Put it on the
internet with a Cloudflare tunnel public hostname pointing at `http://<nas-ip>:5090`. The compose file also
runs Watchtower, which checks GitHub every 30 minutes and swaps in a newer server image by itself, so the
NAS keeps up with the app without you touching it (put Cloudflare Access in front of `/admin` only, not the
whole site, or the app can't sign in), and a nightly backup container that writes `backups/wakeback-<date>.tar.gz`
(last 14 kept) — point the NAS's own backup or cloud sync at that folder so a copy leaves the building.
Password guessing is braked: 8 wrong tries on an email or 20 from one address in 10 minutes and that
login is refused for a while (a 429; the app says "Too many tries").

Set **`WAKEBACK_ADMIN`** to your email and accounts switch on:

- Everyone signs in (the app, or the viewer in a browser). New sign-ups wait for approval unless
  **Auto-approve** is on. The account with the admin email is the admin.
- **`/admin`** (admin only): approve/disable users, reset passwords, the auto-approve switch, every
  track (owner, sharing, remove), and a log of changes. Put Cloudflare Access on just this path if you like.
- Friends see each other's sails unless a sail is set **private**; tracks with no owner (a club
  dock's) are visible to all. The admin sees everything.
- Storage: `data/wakeback.db` (users, friends, tokens, log); who owns each track and its sharing
  live in the session's `owners.json`, so the phone app and a dock Pi keep the same files.

A dock Pi or the phone app runs without `WAKEBACK_ADMIN`: no logins, everything visible, as before.

## On the Pi

Same server. Set the Pi up as a WiFi access point (`wakeback`, no internet needed), run it under systemd with gunicorn as the Dockerfile does (`gunicorn --workers 1 --threads 8 --bind 0.0.0.0:5000 --chdir server app:app`; or the container itself), never `python server/app.py` with `WAKEBACK_DEBUG=1`, and point Chromium in kiosk mode at `http://localhost:5000` for the projector. Pucks join the AP when they sit on the charging pad and POST to `/api/upload`. `WAKEBACK_WIFI`, `WAKEBACK_OWNER`, `WAKEBACK_FLEET` and `WAKEBACK_UPLINK_IF` are for the Pi; they do nothing on the NAS.

## Later list

Agreed, not built yet. Roughly in the order they'd make sense. The bigger direction (your own puck and phone, friends, events) is in `docs/ROADMAP.md`.

1. **Puck firmware** (ESP32-S3): 10 Hz GPS + IMU logging to the CSV format above, auto start/stop (see below), Dock check-in every ~30 s on the pad (and one as it's lifted off), upload to `/api/upload` when on the pad. The dock is found at the WiFi gateway, port 5000 — the Pi on its own WiFi, or a phone running the app on its hotspot (`docs/PHONE_DOCK.md`).
   - **Auto on/off:** asleep on the pad (never records there). Lifted → IMU wakes it → GPS fix. Records after >1.5 kn for 20 s; stops after ~10 min still, then sleeps.
   - **Travel-proof:** (a) over ~25 kn for a minute = not sailing, stop and discard; (b) needs boat-like heel/pitch rocking, not car motion; (c) only records near known venues (Southport + clubs added on the dock; dock asks "new venue?" first time somewhere new); (d) travel mode, set by triple-tap or from the dock page, sleeps until next put on a pad (use for long trips and flying).
   - Dock double-checks on upload and drops anything with road speeds or no boat motion.
   - GPS off while asleep, so a full charge lasts weeks in a bag.
2. **Up to 16 pucks**: 16 distinct colours (no red/green), compact one-row-per-boat projector view, stress test with a fake 16-boat race, bigger pad tray and power supply.
3. **Weather from the SSC station** when it's running (log direction/speed every few seconds with a timestamp) for real shifts, lifts and headers — same `meta.weather.pts` format as Open-Meteo, just finer.
4. **Offline map backgrounds**: dock keeps the satellite/chart tiles for each venue it's been online at, so away venues work without internet.
5. **Leg analysis**: with marks placed, split each race into legs and show who gained or lost on each beat and run.

Done and gone from this list: weather (Open-Meteo, **Get weather**), the home server with accounts and friends (the NAS section above, which replaced the read-only public copy idea), nightly backups (the compose file's backup container).
