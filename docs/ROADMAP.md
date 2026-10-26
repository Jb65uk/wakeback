# WakeBack roadmap: sailing's version of a running app

Everyone records their own sailing, looks back at it, and shares it with friends or an event.
The club base station (dock + projector) is one more way of recording, for training days with lots of people.

```
own puck ─► own phone (the app is a pocket dock) ─┐
                                                   ├─► WakeBack server (app.py, at home behind Cloudflare)
club pucks ─► dock Pi at the club ─────────────────┘        accounts · friends · events · venues
```

## Decisions (27 Sep 2026)

- **Accounts:** invite-only for now (you add people); can open up later without a rebuild.
- **Sign-in:** email + password (no email service needed); the admin resets passwords from /admin. The app stays signed in.
- **Privacy:** a new sail is visible to **friends** by default; any one can be made private or public.
- **Clean-up:** the QR phone-upload page is gone (mates use the app instead); old Bluetooth design dropped.

## Words

- **Session:** a sailing date + venue (`2026-09-20_southport-sc`). Everything replayed together.
- **Track:** one boat's log in a session. Has an **owner** (whose puck/phone sent it: can edit/delete it)
  and a **sailor** (who was in the boat; pucks get lent, so this is set per session).
- **Venue:** where you sailed. Found from the first position; somewhere new gets "New venue near …" until named.
- **Event** (stage 3): a set of tracks replayed together across owners: "Solo open, West Kirby", "Tuesday training".

## Stages

1. **Venues + owner/sailor** ✅ (this change)
   Sessions by date + venue; venue detection, naming, "wrong venue?" move; owner recorded on every track
   (phone profile, puck's owner, or the club); your old date-only folders are converted automatically;
   the app has a "You" profile; sync keeps venues and owners.
2. **Accounts and sharing** ✅
   Email + password accounts on the server (SQLite), approval or auto-approve, admin dashboard at /admin,
   friends, friends/private per track, only the owner (or admin) edits or deletes, the app signs in and
   keeps demo data separate. Not yet: a public read-only link, email "forgot password".
2b. **Sessions tab, stats and the league** ✅
   The app opens on a native Sessions list (tap to replay, Friends/Private switch per session), with Stats
   (miles, hours, sessions, average, top speed, fastest average, longest sail, favourite venue, miles by
   month, a fun comparison) and a friends' League (miles, hours, top speed, best average; this month / year /
   all time; medals). Numbers come from `server/stats.py` (`/api/stats`, `/api/league`, `stats` in
   `/api/sessions`, cached per session in `stats.json`) and the identical Dart port `app/lib/dock/stats.dart`
   for what's on the phone. Private sails stay off everyone's board, including the admin's.
3. **Events and "who else was there?"**
   Create an event, share a link/code, everyone adds their track; the server spots other WakeBack sailors at
   the same venue and time and offers to ask them; a feed of your and your friends' sailing.
4. **Puck setup from the app** (with the firmware) — firmware side ✅ (24 Oct, `firmware/puck`); app + server TO DO
   The puck puts up its own WiFi `wakeback-puck-N` (first power-up, or hold the button 6 s) with a setup page:
   live numbers, calibration, the dock/hotspot WiFi name + password, puck number, auto-record, tracks, firmware
   update. It records by itself on movement-from-rest (no speed threshold), uploads to the dock or the app over
   WiFi and deletes once accepted, sleeps after 30 min still (button or the pad wakes it). Sends
   `X-Puck-Key` if one is set; the server issues keys (`/api/pucks/keys`) and checks them on every check-in
   and upload, for the puck number they were issued to.
   **Push button on mk1** ✅ (21 Oct): the first case has a 12 mm waterproof momentary button (ring LED) in the
   side wall instead of the magnet idea: tap = record on/off, hold 2 s = sleep, press = wake, 30 min still = sleeps
   itself. `hardware/case` (flat boss, hole, shorter lid thread, 2 mm taller overall) and `firmware/puck` (D2 button, D9 ring LED).
   On first power-up (or holding the button) the puck puts up its own WiFi `wakeback-puck-N` for a couple of
   minutes; the app joins it and sends hotspot name + password, the owner, and a **puck key** (random,
   issued by the server, tied to the owner's account — club pucks to the club account). The puck sends the
   key with every upload; nobody types or remembers it. Lost/sold puck → revoke the key in /admin and set it
   up again. Lost hotspot password → change it on the phone and re-tell the puck the same way.
4b. **Firmware: calibrate itself, don't make the sailor do it** — ✅ in `firmware/puck` (which way up from gravity at
   rest; twist from the BNO085 compass vs GPS course while sailing straight; level = one tap on the page; mag
   status, orientation and twist reported in the check-in). Still to do: show it on the app's Dock page.
   - Which way up: gravity at rest → deck cradle or hanging under the thwart; flip heel/pitch signs to suit.
   - Mounting twist: compass heading (BNO085) minus GPS course while sailing straight, averaged → the angle the
     puck is turned from the bow; re-learnt each time it's locked in, so the lid can stop at any angle.
   - Level: the "flat" heel/pitch offset from the first minutes at rest on the trolley/pontoon (and the cradle
     not being quite level on deck).
   - Magnetometer: run the BNO085's own calibration in the background; save it so it survives a power cycle.
   - GPS: nothing to calibrate, but do warm-start (save last fix + almanac) so it's ready when the boat hits the water.
   - Report all of it (orientation, twist, level, mag status) in the check-in so the app can show "puck 3 is
     under the thwart, calibrated" or warn when it isn't.
5. **Firmware from the dashboard → app → puck** — puck side ✅; server + app TO DO
   CI (`build-firmware.yml`) publishes `puck.bin` + `firmware.json` on every release `puck-N`. The puck asks the dock
   for `GET /api/firmware/latest` → `{"version","url"}` once an hour and updates itself, with rollback (a new image
   is only kept after it checks in with a dock). To do: the server serves that from an /admin upload, the app's
   pocket dock relays it.
   /admin: upload a `.bin` + version + notes; server serves `/api/firmware/latest`. The app shows
   "Puck 3 is on 1.2, 1.4 available — Update" on the Dock page and pushes it while the puck is on the pad /
   the hotspot (ESP32 OTA). Rule: keep the previous image and roll back if the new one doesn't check in
   within a minute — one bad build must not brick the club's pucks on a Saturday.
6. **App update button** ✅ (28 Sep)
   Every build is signed with the permanent key (GitHub secrets) and its build number is the run number, so
   the release tag `app-N` and the installed build match. The app checks the public releases feed (every 6 h,
   or Setup → About → Check), shows an "Update available" card with the release notes (the commit message)
   on Sessions and in Setup, downloads the APK and hands it to Android's installer (`app/lib/updates.dart`).
   One-off: phones with a throwaway-key build must uninstall once.
7. **2FA (TOTP) on accounts** — TO DO
   Authenticator-app codes, no SMS/email service; optional for sailors, on for the admin; admin can turn it
   off for someone who's lost their phone (from /admin, like a password reset).

8. **GDPR / keeping personal data tight** — TO DO
   The server holds names, emails, password hashes and GPS tracks (which are personal data too: where
   someone was, when). To do: a short privacy note in the app and on the server (what's kept, why, who sees
   it); emails never leave the server (already: the API only sends names) and never appear in the viewer,
   logs or the audit trail beyond what the admin needs; **delete my account** in the app and /admin that
   removes the account *and* their tracks (or hands club tracks to the club); **export my data** (a zip of
   your tracks + account details); a friend can only see your email if you've accepted them; keep the
   Cloudflare-fronted server HTTPS-only, back-ups encrypted, and the SQLite/data folder off any shared NAS
   share. No third-party analytics or trackers, so nothing to consent to beyond the account itself.

9. **Make it fun / useful — picked 27 Sep, in this order** ✅ (28 Sep; all five, phone side; server computes the same stats)
   1. **Personal bests**: when a session lands, a toast + card — "Fastest average this year", "Longest sail
      ever", "New top speed". Stats already has the numbers; keep a small `bests.json` per person.
   2. **Offline maps**: cache map tiles for your venues (a few zoom levels round each) so the tablet works
      with no signal at the club; "Download this venue" in Setup.
   3. **Share card**: a PNG of the track on the map + date/venue/miles/top speed/average, straight to WhatsApp
      via the Android share sheet.
   4. **Streaks & badges**: sailed N weekends running, 100 nm month, first 6 kn, dawn sail, most miles at a
      new venue, first capsize (heel > 80° for 10 s — the IMU knows). All from data already logged.
   5. **Wind vs speed**: upwind / downwind averages and bests, best 30-s VMG, most heel and capsizes (heel > 80°
      for 10 s), and a table by wind strength — from the day's weather (meta.weather, so pull it in on Replay)
      and the puck's heading and heel. `server/stats.py` and `app/lib/dock/stats.dart` compute it identically.
   Also: `app/lib/dock/badges.dart` (bests + 17 badges), `app/lib/dock/tiles.dart` (tile cache served at
   `/tiles/<layer>/z/x/y` by the phone's dock; the in-app viewer uses it), `app/lib/share_card.dart`.

Done 28 Sep, security: login/sign-up rate limits (accounts.py), Watchtower auto-updates the server image,
nightly backups to ./backups on the NAS (still to do: a copy off the NAS — the NAS's own backup app to the
PC or cloud). Still open: the update button needs the repo public (or a separate public releases repo).

Also still on you: add the GitHub signing secrets; scope Cloudflare Access to `/admin` only so the app can
create accounts.

## 26 Oct — Bluetooth only (firmware + app 0.18.0)

Decision: a puck belongs to one person and talks to that person's phone over Bluetooth, full stop. No WiFi in the
puck (no hotspot, no setup AP, no dock check-in); the club dock Pi is out of scope (a tablet running the app does
the same job). Sharing still goes phone → server as before.

- **Firmware** (`firmware/puck`): WiFi, web server, captive portal and `page.h` gone (main.cpp 1180 → ~815 lines).
  `ble.h`: `hello` carries a nonce, `auth` = HMAC-SHA256(key, nonce) — the key never goes over the air; everything
  but hello is refused (and the link dropped) until then. `tracks` / `get <name> [offset]` streams the raw `.wbt` on a
  new data characteristic with CRC-32 of the part and of the whole file; `done <name>` deletes. Pairing window: no key
  = open; 6 s hold = open 10 min (`p` on serial); a different key wipes the tracks. The advert carries 2 bytes of
  SHA-256(key) and the number of tracks waiting, name in the scan response (the 128-bit UUID fills the 31-byte advert —
  this is why the first BLE build was invisible). Commands run on `loop()` (the NimBLE task's 4 KB stack overflowed on
  `statusJson()` and crashed the puck on first connect). 7.5–15 ms connection interval. `forget` on serial drops the key.
- **App 0.18.0** (`app/lib/puck/`): `wbt.dart` decodes `.wbt` to the CSV the dock writes; `puck_ble.dart` scans by
  service UUID, matches the owner hash against the keys this phone holds (`MyPuck.key`, kept now), does hello/auth,
  pulls tracks with resume + CRC; `puck_pull.dart` empties a puck into Sessions and clears it; `puck_watcher.dart`
  does that by itself every 90 s while the app is in front (only connects when the advert says tracks are waiting).
  Set up a puck is number + auto-record + Connect; the puck screen has Get its tracks, live speed/heel/pitch, flip.
  Hotspot settings, `puck_wifi.dart`, `android_src/MainActivity.kt`, the Dock page and "See them check in" are gone;
  the pocket dock is loopback-only and only serves the viewer (and the demo pucks).
- **Same phone, set up again**: the existing key is kept (no wipe). **New phone / new owner**: hold 6 s, Set up a
  puck, new key, tracks wiped. **Lost / sold**: Forget in the app revokes the key on the server; the puck keeps the
  dead key until someone re-pairs it.
- Still to prove on the bench: first auth, a 1 MB track over BLE (expect 20–40 kB/s), the watcher picking a puck up
  on the pad, a BLE firmware update onto this build.
