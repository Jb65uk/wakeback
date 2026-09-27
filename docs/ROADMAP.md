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
- **Sign-in:** email sign-in link (needs an email-sending account, e.g. Brevo/SMTP). The app stays signed in.
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
2. **Accounts and sharing**
   Database (SQLite) on the server; invite, email sign-in link, the app signs in; owner = your account;
   friends; private / friends / public per track; only the owner edits or deletes; a read-only public viewer.
3. **Events and "who else was there?"**
   Create an event, share a link/code, everyone adds their track; the server spots other WakeBack sailors at
   the same venue and time and offers to ask them; a feed of your and your friends' sailing.
4. **Puck setup from the app** (with the firmware)
   The app gives your puck your hotspot name/password and its owner (USB, or the puck's own setup WiFi for a
   minute on first power-up). Travel-proofing uses the venue list.
