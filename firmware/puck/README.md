# Puck firmware

The real firmware for a built puck (carrier board in its case). The bench test in `../bench_test` is for checking parts; this is what goes on the water.

What it does on its own:

- **Records when the boat moves off.** It remembers where it sat still for 20 s (trolley, pontoon, start line); once it's 30 m away it starts a track, including the minute before, so the start isn't lost. After 10 minutes without moving 20 m the sail is over and the file closes. No speed threshold, so light-wind days still record. A tap of the button starts or stops a track by hand instead.
- **10 Hz while moving, 1 Hz while still**, same CSV as the viewer and the server (`t_ms,lat,lon,sog_kn,hdg,heel,pitch`). About 5 hours of actual sailing fits; a short track (under 10 points) is binned.
- **Uploads to a dock**: on the pad it joins the WiFi it's been given (default `wakeback`), finds the dock at the gateway on port 5000 (the dock Pi or the WakeBack app on a phone, `docs/PHONE_DOCK.md`), checks in every 30 s and posts each finished track, deleting it from the puck once the dock says ok. Off the pad with tracks waiting it has a 25 s look for the dock every 5 minutes, so a sail reaches your phone's hotspot without a pad.
- **Calibrates itself**: which way up it's mounted (on deck or under the thwart) from gravity while it sits still; the twist from the bow from the compass against the GPS course while you sail straight (saved once it agrees for a minute); level is one button on the page with the boat sat level.
- **Sleeps** after 30 minutes still off the pad (hold the button 2 s to sleep now); a press, or being put on the pad, wakes it. GPS goes to backup mode so it gets a fix quickly on waking.
- **Firmware updates** from its own page, or pushed by the dock once the server offers `/api/firmware/latest` (roadmap stage 5). A new image runs on probation and is rolled back unless it checks in with a dock (or runs two minutes with the sensors alive).

## Flashing it the first time

Either open this folder in VS Code with PlatformIO and **Upload** over USB, or take `puck-full.bin` from the latest `puck-N` release on GitHub and write it at address `0x0` with any ESP32 flasher (for example https://espressif.github.io/esptool-js/ in Chrome: connect, address `0x0`, Program). Later updates go through the puck's own page.

## The button

| Press | Does |
|---|---|
| tap | start / stop recording by hand |
| hold 2 s, let go after three blinks | sleep |
| keep holding to 6 s, five quick blinks | setup WiFi on (or off) |
| press when asleep | wake (a knock shorter than 0.3 s doesn't) |

## The LED

| Pattern | Means |
|---|---|
| slow blink | no GPS fix yet |
| one blink a second | fix, waiting for the boat to move |
| double blink | recording |
| fast blink | setup WiFi is on |
| steady on | talking to the dock (upload or firmware) |
| five quick blinks then a pause | flash full, nothing being recorded |

On the pad the ring LED breathes while charging and is solid when full.

## Setup page

On first power-up, or after holding the button for 6 s, the puck puts up an open WiFi called **`wakeback-puck-N`**. Join it on your phone; the page opens by itself (or go to http://192.168.4.1/). It shows live speed, heading, heel, pitch, battery and storage, and has:

- **Calibration**: *Level now* (boat sat level), *Heel sign is backwards*, the twist (type it or let it learn), which way up it worked out, compass calibration state.
- **Settings**: puck number, the dock / phone hotspot WiFi name and password, record on its own or button only, points a second, auto-off.
- **Tracks**: what's on the puck, download or delete.
- **Firmware**: choose `puck.bin` from a release and Update.

Setup mode switches itself off after 10 minutes with nobody looking at the page, or tap *Done*. The same page is also served on the dock WiFi at the puck's address (the check-in reports it), which is how the app will reach it later.

## Serial monitor (115200)

`h` help, `s` status, `i` start-up report, `r` record, `l` list tracks, `e` erase all tracks, `w` setup WiFi on/off, `u` look for the dock now, `p3` puck number, `z` level, `f` flip heel, `x` sleep.

## Partitions

Two 1.7 MB app slots (so an update can roll back) and 4.5 MB for tracks on the 8 MB XIAO. The 16 MB XIAO Plus for the v2 board gets a bigger table later.

## Not done yet

- Puck key issued by the server (stage 4): the firmware already sends `X-Puck-Key` with check-ins and uploads if one is set; the server doesn't issue or check them yet.
- Setting which boat a puck is in (stage 4): lives in the dock's `pucks.json`, nothing needed on the puck.
- Dock-pushed firmware (stage 5) needs `/api/firmware/latest` on the server and the Dock page in the app.
