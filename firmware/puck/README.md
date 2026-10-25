# Puck firmware

The firmware for a puck, on the breadboard (BUILD.md) or the carrier board in its case. It's the only firmware now: the old bench sketch is gone.

What it does on its own:

- **Records when the boat moves off.** It remembers where it sat still for 20 s (trolley, pontoon, start line); once it's 30 m away and has held more than 0.5 kn for 5 s it starts a track, including the minute before, so the start isn't lost. The held speed is what keeps indoor GPS wander (which drifts 30 m but never holds a speed) from starting a track on the bench. After 10 minutes without moving 20 m the sail is over and the file closes. A tap of the button starts or stops a track by hand instead; a track started by hand ends the same way.
- **5 Hz while moving, 1 Hz while still.** Points are stored in a compact binary form (`src/track.h`: a full record every 64 points, small deltas between, about 12 bytes a point) so about **18 hours** of actual sailing fits in the 4.5 MB track store. The puck turns it back into the usual CSV (`t_ms,lat,lon,sog_kn,hdg,heel,pitch`) as it uploads or serves a track, so the docks and the viewer never see anything else. A short track (under 10 points) is binned.
- **Uploads to a dock**: on the pad it joins the WiFi it's been given (default `wakeback`), finds the dock at the gateway on port 5000 (the dock Pi or the WakeBack app on a phone, `docs/PHONE_DOCK.md`), checks in about once a minute and posts each finished track, deleting it from the puck once the dock says ok. Between check-ins on the pad the radio is off and, after the first minute, the GPS rests too — so the pad's few hundred mA go into the battery rather than the electronics. With no dock answering it has another look every 2 minutes (every minute while the dock was seen in the last 10 minutes). Off the pad with tracks waiting it has a 25 s look every minute for a quarter of an hour after a sail, then every 5 minutes, so a sail reaches your phone's hotspot without a pad. If the dock refuses the key (401/403) it stands off for 10 minutes (2 on the pad) and says so on its page.
- **Calibrates itself**: which way up it's mounted (on deck or under the thwart) from gravity while it sits still; the twist from the bow from the compass against the GPS course while you sail straight (saved once it agrees for a minute); level is one button on the page with the boat sat level.
- **Sleeps** after 30 minutes without the boat under way, off the pad (hold the button 2 s to sleep now); a press, or being put on the pad, wakes it. GPS goes to backup mode so it gets a fix quickly on waking. Sent to sleep while it's on the pad it stays asleep until the button.
- **Firmware updates** from its own page, or pushed by the dock once the server offers `/api/firmware/latest` (roadmap stage 5): only a newer version, and never onto a puck flashed from VS Code (version `1.0.0` or `dev`). A new image runs on probation and is rolled back unless it checks in with a dock (or runs two minutes with the sensors alive).

## Flashing it the first time

Either open this folder in VS Code with PlatformIO and **Upload** over USB, or take `puck-full.bin` from the latest `puck-N` release on GitHub and write it at address `0x0` with any ESP32 flasher (for example https://espressif.github.io/esptool-js/ in Chrome: connect, address `0x0`, Program). Later updates go through the puck's own page. The first boot of this firmware clears any calibration left by the old bench sketch; WiFi settings and the puck number are kept.

## The button and the LED

This table is the one place these are written down.

| Press | Does |
|---|---|
| tap | start / stop recording by hand |
| hold 2 s, let go after three blinks | sleep |
| keep holding to 6 s, five quick blinks | setup WiFi on (or off) |
| press when asleep | wake (a knock shorter than 0.3 s doesn't). The press that wakes it doesn't count as a tap |

| LED | Means |
|---|---|
| slow blink | no GPS fix yet |
| one blink a second | fix, waiting for the boat to move |
| double blink | recording |
| fast blink | setup WiFi is on |
| steady on | talking to the dock (upload or firmware) |
| five quick blinks then a pause | flash full, nothing being recorded |

On the pad the ring LED breathes while charging and is solid when full.

## Setup page

Until it's been set up (from the app or the page), after holding the button for 6 s, or on a USB lead, the puck puts up an open WiFi called **`wakeback-puck-N`**. Join it on your phone; the page opens by itself (or go to http://192.168.4.1/). It shows speed, heading, heel, pitch, GPS (Searching… / Ready), battery, storage, and has:

- **On the boat**: *Boat is level* (boat sat level), *Mounted on deck* / *Mounted under the thwart* (or let it work that out).
- **Settings**: puck number, the dock / phone hotspot WiFi name and password, record on its own or button only, switch itself off.
- **Tracks**: what's on the puck, download or delete.
- **Firmware**: choose `puck.bin` from a release and Update.
- **Advanced** (folded away): GPS detail, compass state, the twist (type it or let it learn), level offsets, *Heel sign is backwards*, reset calibration.

Setup mode switches itself off after 10 minutes with nobody looking at the page (on USB too), or tap *Done*. The same page is also served on the dock WiFi at the puck's address (the check-in reports it).

## Serial monitor (115200)

A status line every 5 s, and: `h` help, `s` status now, `q` pause/resume the status line, `i` start-up report (with what to check if the GPS or IMU wasn't found), `r` start/stop recording, `l` list tracks, `erase` (the whole word) erase all tracks, `w` setup WiFi on/off, `u` look for the dock now, `x` sleep. Everything else (puck number, level, heel sign, twist) is on the setup page.

## Partitions

Two 1.7 MB app slots (so an update can roll back) and 4.5 MB for tracks on the 8 MB XIAO. The 16 MB XIAO Plus for the v2 board gets a bigger table later.

## Not done yet

- Setting which boat a puck is in (stage 4): lives in the dock's `pucks.json`, nothing needed on the puck.
- Dock-pushed firmware (stage 5) needs `/api/firmware/latest` on the server and the Dock page in the app.
