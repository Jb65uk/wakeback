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

Also still on you: add the GitHub signing secrets; scope Cloudflare Access to `/admin` only so the app can
create accounts.
