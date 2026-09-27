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
4. **Puck setup from the app** (with the firmware) — TO DO, first once a puck is on the bench
   On first power-up (or holding the button) the puck puts up its own WiFi `wakeback-puck-N` for a couple of
   minutes; the app joins it and sends hotspot name + password, the owner, and a **puck key** (random,
   issued by the server, tied to the owner's account — club pucks to the club account). The puck sends the
   key with every upload; nobody types or remembers it. Lost/sold puck → revoke the key in /admin and set it
   up again. Lost hotspot password → change it on the phone and re-tell the puck the same way.
4b. **Firmware: calibrate itself, don't make the sailor do it** — TO DO (with the firmware)
   - Which way up: gravity at rest → deck cradle or hanging under the thwart; flip heel/pitch signs to suit.
   - Mounting twist: compass heading (BNO085) minus GPS course while sailing straight, averaged → the angle the
     puck is turned from the bow; re-learnt each time it's locked in, so the lid can stop at any angle.
   - Level: the "flat" heel/pitch offset from the first minutes at rest on the trolley/pontoon (and the cradle
     not being quite level on deck).
   - Magnetometer: run the BNO085's own calibration in the background; save it so it survives a power cycle.
   - GPS: nothing to calibrate, but do warm-start (save last fix + almanac) so it's ready when the boat hits the water.
   - Report all of it (orientation, twist, level, mag status) in the check-in so the app can show "puck 3 is
     under the thwart, calibrated" or warn when it isn't.
5. **Firmware from the dashboard → app → puck** — TO DO
   /admin: upload a `.bin` + version + notes; server serves `/api/firmware/latest`. The app shows
   "Puck 3 is on 1.2, 1.4 available — Update" on the Dock page and pushes it while the puck is on the pad /
   the hotspot (ESP32 OTA). Rule: keep the previous image and roll back if the new one doesn't check in
   within a minute — one bad build must not brick the club's pucks on a Saturday.
6. **App update button** — TO DO
   The app checks the GitHub release feed, shows "Update available", downloads the APK and hands it to
   Android's installer. Needs the `ANDROID_KEYSTORE_*` signing secrets on GitHub first (a build signed with a
   throwaway key won't install over the last one — what stuck on the tablet).
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

9. **Make it fun / useful — picked 27 Sep, in this order** — TO DO
   1. **Personal bests**: when a session lands, a toast + card — "Fastest average this year", "Longest sail
      ever", "New top speed". Stats already has the numbers; keep a small `bests.json` per person.
   2. **Offline maps**: cache map tiles for your venues (a few zoom levels round each) so the tablet works
      with no signal at the club; "Download this venue" in Setup.
   3. **Share card**: a PNG of the track on the map + date/venue/miles/top speed/average, straight to WhatsApp
      via the Android share sheet.
   4. **Streaks & badges**: sailed N weekends running, 100 nm month, first 6 kn, dawn sail, most miles at a
      new venue, first capsize (heel > 80° for 10 s — the IMU knows). All from data already logged.
   5. **Wind vs speed**: best average by wind strength, upwind vs downwind speed, best VMG, heel vs speed —
      from the day's weather (meta.weather), the wind direction set in the viewer, and the puck's heel.

Also still on you: add the GitHub signing secrets; scope Cloudflare Access to `/admin` only so the app can
create accounts.
