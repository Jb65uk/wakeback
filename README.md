# WakeBack

GPS WakeBack pucks for dinghy racing: log where you sailed, how fast and how heeled, then overlay everyone's tracks and replay the race on a projector or train against yourself.

```
wakeback/
├── viewer/index.html     the whole viewer, one file, works offline or served by the dock
├── app/                  Android phone/tablet app: the dock in your pocket, runs this same viewer (see app/README.md)
├── docs/PHONE_DOCK.md    how pucks upload to a phone hotspot instead of the dock (firmware notes)
├── server/app.py         dock server (Flask) — runs on the dock Pi, or your laptop for dev
├── tools/gen_fake_data.py    makes demo sessions in the exact puck CSV format
├── tools/fake_puck_upload.py pretends to be a puck landing on the dock
├── tools/fake_pucks.py       a dock full of pretend pucks checking in (for the Dock page)
├── data/sessions/<date>/     one folder per sailing day, one file per boat
├── BUILD.md              build one puck on a breadboard: shopping list, wiring in stages, first track
├── hardware/carrier/     60 mm carrier PCB: Gerbers for JLCPCB, previews, assembly notes, generator
├── hardware/case/        3D-printed puck case: base, screw lid (O-ring), GPS shelf, deck cradle. STLs + generator
├── firmware/bench_test/  PlatformIO bench test: checks GPS, IMU, battery, Qi, records a test track
├── tools/pull_track.py   copies a recorded track off the puck over USB
└── firmware/             (next) the real puck firmware
```

## Quick start (VS Code)

1. Open this folder in VS Code. Install the recommended extensions when prompted.
2. `Terminal > Run Task > Install requirements` (or `pip install -r server/requirements.txt`).
3. Press F5 with **Run dock server** selected, then open http://localhost:5000.
4. The panel shows two demo sessions from the fake data: click **2026-09-20** to load Sunday (three pucks plus Steve's phone, two races back to back in one log), press **Play**, then **B** for the big-screen projector view.
5. The course is already laid for the demo day (three marks, left to starboard). Click **Auto split** under Races: it finds the gap between the races. Pick **Race 1**, then **Estimate** next to Wind. Tap **Tacks & gybes** under a boat, then filter to Tacks or Gybes, sort Worst first, and tap any one to jump the replay there.
6. `Run Task > Fake puck upload` to watch a session appear on the dock as a puck would post it.

No server? Just open `viewer/index.html` in a browser and drag files from `data/sessions/` onto it. Everything works except the sessions list and shared puck names.

## Dock page

Open **Dock** (tab at the top, or http://localhost:5000/dock). To see it with pucks in it on a laptop, run the **Fake pucks** task while the server's running: P1 full, P2/P3 charging, P4 comes back from sailing after ~20 s and uploads a session, P5 is on the pad but not charging, P6 has never checked in.

- Every puck: on the dock or away, battery % with charging / full / not charging, last upload (when, which day, how big, who sailed it), last seen, storage free, firmware (flags ones behind)
- Warnings up top: pucks not charging on the pad, low batteries
- Internet: online or not, and through what. "Connect to WiFi" scans for networks and joins one (club WiFi, a phone hotspot at an away venue). On the Pi this is real (NetworkManager, the default on Raspberry Pi OS); on a laptop it runs in demo mode with made-up networks so you can try it. The dock's own `wakeback` WiFi stays up regardless
- Dock health: disk space, clock, uptime, sessions stored, NAS backup (not set up yet)

Dock settings (environment variables):

| Variable | What | Default |
|---|---|---|
| `WAKEBACK_FLEET` | how many pucks the club has, so ones never seen still get a row | 0 |
| `WAKEBACK_WIFI` / `WAKEBACK_WIFI_PASS` | the dock's own WiFi, shown to phones | wakeback / none |
| `WAKEBACK_UPLINK_IF` | WiFi adapter used to reach the internet (USB dongle; onboard wlan0 runs the dock WiFi) | wlan1 |
| `WAKEBACK_PIN` | PIN needed to change the dock's WiFi | none |
| `WAKEBACK_URL` | address phones should use, e.g. http://wakeback.local | whatever the browser used |

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
- Races: split a day into time windows by hand (11:00–12:00, 12:00–13:30) or with Auto split (gaps where nobody moved for 5 min); stats, tacks, chart and replay all follow the selected race, and races are saved on the dock per day
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
| GET | `/api/sessions` | list sessions (one per day) and their files |
| GET | `/api/sessions/<day>/<file>` | fetch one track |
| POST | `/api/upload` | multipart `file` (+ optional `puck`); filed by the first timestamp in the file |
| DELETE | `/api/sessions/<day>/<file>` | remove a track |
| GET / PUT | `/api/sessions/<day>/races` | race windows for that day: `[{"name","start","end","gun","marks":[...],"lines":[{"kind":"start"/"finish"/"both","a":{lat,lon},"b":{lat,lon}}]}]`, times in epoch ms, a = committee boat end, b = pin |
| GET / PUT | `/api/sessions/<day>/meta` | whole-session marks, your corrections and the day's weather: `{"marks":[{"name","lat","lon","side":"port"/"stbd"}],"fixes":[...],"weather":{"src","lat","lon","got","pts":[[t_ms,dir,kn,gust],...]}}` |
| GET / PUT | `/api/sessions/<day>/crew` | who had which puck that day: `{"puck3": "Dave"}` |
| GET | `/api/sailors` | every name used in any session (for the name picker) |
| POST | `/api/pucks/checkin` | puck check-in every ~30 s on the pad: `{"puck":3,"battery_mv":4012,"charging":"charging"/"full"/"not","on_pad":true,"free_kb":12000,"total_kb":14336,"fw":"0.3.1","pending":1}`; reply carries dock time |
| GET | `/api/pucks` | every puck's status for the Dock page |
| GET | `/api/dock/status` | internet, disk, clock, uptime |
| GET / POST | `/api/wifi/scan`, `/api/wifi/connect` | find and join a WiFi network (on the Pi) |
| GET | `/api/hello` | dock time, used by pucks to confirm they're talking to the right box |

## On the Pi

Same server. Set the Pi up as a WiFi access point (`wakeback`, no internet needed), run `app.py` under systemd, and point Chromium in kiosk mode at `http://localhost:5000` for the projector. Pucks join the AP when they sit on the charging pad and POST to `/api/upload`.

## Later list

Agreed, not built yet. Roughly in the order they'd make sense.

1. **Puck firmware** (ESP32-S3): 10 Hz GPS + IMU logging to the CSV format above, auto start/stop (see below), Dock check-in every ~30 s on the pad (and one as it's lifted off), upload to `/api/upload` when on the pad. The dock is found at the WiFi gateway, port 5000 — the Pi on its own WiFi, or a phone running the app on its hotspot (`docs/PHONE_DOCK.md`).
   - **Auto on/off:** asleep on the pad (never records there). Lifted → IMU wakes it → GPS fix. Records after >1.5 kn for 20 s; stops after ~10 min still, then sleeps.
   - **Travel-proof:** (a) over ~25 kn for a minute = not sailing, stop and discard; (b) needs boat-like heel/pitch rocking, not car motion; (c) only records near known venues (Southport + clubs added on the dock; dock asks "new venue?" first time somewhere new); (d) travel mode, set by triple-tap or from the dock page, sleeps until next put on a pad (use for long trips and flying).
   - Dock double-checks on upload and drops anything with road speeds or no boat motion.
   - GPS off while asleep, so a full charge lasts weeks in a bag.
2. **Phone upload via QR codes**: code is in (`/upload` page, QR codes from the dock, new tracks appear on the projector by themselves) but paused; needs a proper test on real phones.
3. **Home viewing, read-only**: dock syncs sessions to the home server (NAS/Tower) when online; published through a Cloudflare tunnel (e.g. puck.bridgesolutions.uk). Public copy runs the viewer locked: replay, races, colours, chart, focus a boat, tack list, big/full screen, download a track. No editing of names, races, marks or corrections; server refuses all changes. Choose per session whether it's published. Decide: club members only (Cloudflare Access email code) or anyone with the link.
4. **Up to 16 pucks**: 16 distinct colours (no red/green), compact one-row-per-boat projector view, stress test with a fake 16-boat race, bigger pad tray and power supply.
5. **Weather data**: ~~Open-Meteo~~ done — **Get weather** fills in wind direction, speed and gusts per race (hourly model). Next: the SSC weather station when it's running (log direction/speed every few seconds with a timestamp) for real shifts, lifts and headers — same `meta.weather.pts` format, just finer.
6. **Offline map backgrounds**: dock keeps the satellite/chart tiles for each venue it's been online at, so away venues work without internet.
7. **Leg analysis**: with marks placed, split each race into legs and show who gained or lost on each beat and run.
8. **NAS backup** of sessions from the dock.
