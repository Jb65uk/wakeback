# Puck firmware

The firmware for a puck, on the breadboard (BUILD.md) or the carrier board in its case. There is no WiFi in the puck:
everything goes over Bluetooth LE to the WakeBack app on the owner's phone (`src/ble.h` has the protocol).

What it does on its own:

- **Records when the boat moves off.** It remembers where it sat still for 20 s (trolley, pontoon, start line); once it's 30 m away and has held more than 0.5 kn for 5 s it starts a track, including the minute before, so the start isn't lost. The held speed is what keeps indoor GPS wander (which drifts 30 m but never holds a speed) from starting a track on the bench. After 10 minutes (a setting) without moving 20 m the sail is over and the file closes. A tap of the button starts or stops a track by hand instead; a track started by hand ends the same way.
- **5 Hz while moving (1, 2, 5 or 10 from the app), 1 Hz while still.** Points are stored in a compact binary form (`src/track.h`: a full record every 64 points, small deltas between, about 12 bytes a point) so about **18 hours** of actual sailing fits in the 4.5 MB track store at 5 Hz (9 h at 10, 45 h at 2). The app pulls the raw `.wbt` files over Bluetooth and decodes them itself (`app/lib/puck/wbt.dart`). A short track (under 10 points) is binned.
- **Belongs to one person.** When it's set up, the app gives it a key the server issued to the owner's account. From then on an app has to prove it holds that key (HMAC of a fresh nonce, the key never goes over the air) before the puck will say anything beyond "hello". Hold the button 6 s to open a 10-minute pairing window for a new owner; giving it a different key erases the tracks on it. The advert carries two bytes of a hash of the key, so the app only lists your own pucks.
- **Calibrates itself**: which way up it's mounted (on deck or under the thwart) from gravity while it sits still; the twist from the bow from the compass against the GPS course while you sail straight (saved once it agrees for a minute); level is one button in the app with the boat sat level.
- **Sleeps** after 30 minutes (a setting, or off) without the boat under way, off the pad (hold the button 2 s to sleep now); a press, or being put on the pad, wakes it. GPS goes to backup mode so it gets a fix quickly on waking. Sent to sleep while it's on the pad it stays asleep until the button. On the pad the GPS rests after a minute so the pad's few hundred mA go into the battery.
- **Firmware updates** from the app over Bluetooth. A new image runs on probation and is rolled back unless the app authenticates with it (or it runs two minutes with the sensors alive).

## Flashing it the first time

Either open this folder in VS Code with PlatformIO and **Upload** over USB, or take `puck-full.bin` from the latest `puck-N` release on GitHub and write it at address `0x0` with any ESP32 flasher (for example https://espressif.github.io/esptool-js/ in Chrome: connect, address `0x0`, Program). Later updates come from the app.

## The button and the LED

This table is the one place these are written down.

| Press | Does |
|---|---|
| tap | start / stop recording by hand |
| hold 2 s, let go after three blinks | sleep |
| keep holding to 6 s, five quick blinks | pairing window open for 10 minutes (or closed again) |
| press when asleep | wake (a knock shorter than 0.3 s doesn't). The press that wakes it doesn't count as a tap |

| LED | Means |
|---|---|
| slow blink | no GPS fix yet |
| one blink a second | fix, waiting for the boat to move |
| double blink | recording |
| fast blink | pairing window open (or the puck has no key yet) |
| steady on | sending a track or taking a firmware update |
| five quick blinks then a pause | flash full, nothing being recorded |

On the pad the ring LED breathes while charging and is solid when full.

## Bluetooth

Always on while the puck is awake, advertising as `WakeBack puck N`. The app (You → Pucks) finds it, authenticates, and from its page shows live numbers, sets level / mounted on deck / under the thwart, starts and stops recording, pulls the tracks (and tells the puck to delete each one once it has it), and pushes firmware. Commands, replies and the data stream are in `src/ble.h`.

## Serial monitor (115200)

A status line every 5 s, and: `h` help, `s` status now, `q` pause/resume the status line, `i` start-up report (with what to check if the GPS or IMU wasn't found), `r` start/stop recording, `l` list tracks, `erase` (the whole word) erase all tracks, `p` pairing window on/off, `forget` (the whole word) drop the key so any app can set it up, `x` sleep. Everything else (puck number, level, heel sign, twist) is set from the app.

## Partitions

Two 1.7 MB app slots (so an update can roll back) and 4.5 MB for tracks on the 8 MB XIAO. The 16 MB XIAO Plus for the v2 board gets a bigger table later.
