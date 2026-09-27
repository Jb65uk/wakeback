# Build one puck on a breadboard

Goal: one working puck on the bench, then a first real track off the water, before any PCB or case.
Build it in stages and check each one before adding the next. If something doesn't work, you'll know which part it is.

**Two ways to build it:** on a breadboard (below), or on the **carrier board**: a 60 mm round PCB the same modules solder onto, about £5 for five from JLCPCB. See `hardware/carrier/README.md`. The stages and checks below are the same either way.

## Shopping list

Prices checked 26 Sept 2026, including VAT. Stock moves, so check before ordering.

| Part | Where | Price | Notes |
|---|---|---|---|
| Seeed XIAO ESP32S3, **pre-soldered headers** | [The Pi Hut](https://thepihut.com/products/seeed-studio-xiao-esp32s3) | £8.20 | For the breadboard. The PCB later uses the Plus (16 MB); this one has 8 MB, plenty for testing |
| Adafruit BNO085 9-DOF IMU (heel/pitch) | [SB Components](https://shop.sb-components.co.uk/products/adafruit-9-dof-orientation-imu-fusion-breakout-bno085-bno080-stemma-qt-qwiic) (in stock) or [The Pi Hut](https://thepihut.com/products/adafruit-9-dof-orientation-imu-fusion-breakout-bno085-bno080-stemma-qt-qwiic) (sold out today) | £27 | Comes with header pins to solder on |
| Beitian **BE-880** GPS (u-blox M10) | Amazon UK / AliExpress, search "BE-880 GPS M10" | about £15–20 | Make sure it says **BE-880** or M10. The older **BN-880** (M8) works but isn't as good. Ignore its compass wires |
| LiPo 1200 mAh, JST-PH, with protection | [The Pi Hut](https://thepihut.com/products/1200mah-3-7v-lipo-battery) | £8 | 62 × 35 × 5 mm. Any 1000–1200 mAh single-cell with protection will do |
| TP4056 charger boards **with protection** (DW01), USB-C, pack of 5+ | Amazon UK, search "TP4056 USB-C protection" | about £6 | The ones with 6 pads: IN+ IN− B+ B− OUT+ OUT− |
| Qi receiver, 5 V 1 A, with coil | [Amazon UK (VBESTLIFE)](https://www.amazon.co.uk/Vbestlife-Wireless-Charging-Receiver-Standard-default/dp/B08H8LL341) | about £5–8 | Any "Qi receiver module 5V 1A" |
| Qi charging pad | any phone pad | about £10 | Or one you already have |
| Breadboard, jumper wires, 4 × 100 kΩ, 1 × 330 Ω, 1 LED | any starter kit | about £10 | Skip what you already have |
| JST-PH 2-pin sockets / pigtails | Amazon UK | about £5 | So the battery plugs in rather than being soldered |

For the **carrier board** instead of a breadboard, add: a JST-PH 2-pin through-hole socket (B2B-PH-K-S), and two 7-pin 2.54 mm female headers for the XIAO. The resistors and LED can be fitted by JLCPCB when you order (about £8–10 extra); to solder them yourself, add 100 kΩ ×4 and 300–330 Ω ×1 in **1206** size and an **0805** LED.

About **£85–95** with the pad and breadboard, **about £70** for the puck parts alone.

Tools: soldering iron (IMU headers, two wires on the XIAO's battery pads, TP4056 wires), multimeter (to check battery polarity).

### Before you start: LiPo safety
- **Check the battery polarity with a multimeter before plugging it in anywhere.** Cheap LiPos swap red and black on the JST plug more often than you'd think. Reversed = dead charger, possibly a hot battery.
- Never short the battery leads, and never leave a LiPo charging unattended on a bench.
- For now, don't leave it on the Qi pad **and** plugged into USB at the same time (two chargers on one cell). A minute for testing is fine.
- The TP4056 boards charge at 1 A out of the box. That's quicker than this battery likes (it recommends about 0.6 A). For bench tests it's OK; before real use, swap the small resistor marked R3 (or R-prog) for **2.2 kΩ** (about 550 mA).

## Software

1. Install the **PlatformIO** extension in VS Code.
2. Open the folder `firmware/bench_test` (just that folder) in VS Code.
3. Plug the XIAO in with a USB-C data cable. Click **Upload** (→ on the blue bar). First time takes a few minutes while it downloads the tools.
4. Click the **Serial Monitor** (plug icon). Type `h` and Enter for the commands.

Every second it prints a status line like:

```
GPS 3D fix, 14 sats, 10 Hz, +/-1.8 m | 3.21 kn 045 deg | heel +12.3 pitch  -1.0 | batt 3.98 V 78% | off the pad
```

## Stage 1: the XIAO on its own

Push the XIAO into the breadboard across the middle gap, USB end at the edge. Upload the bench test.

**Check:** the monitor says `GPS: NOT FOUND` and `IMU: NOT FOUND` (nothing's connected yet) and the LED blinks slowly. Storage says ok with about 6 MB free.

## Stage 2: GPS

| BE-880 wire | goes to XIAO |
|---|---|
| VCC (red) | 3V3 |
| GND (black) | GND |
| TX (from the GPS) | **D7** |
| RX (to the GPS) | **D6** |
| SDA / SCL (compass) | leave unconnected |

Wire colours vary between sellers: go by the labels on the board. TX goes to the XIAO's receive pin (D7), and RX to D6. Crossed is correct.

Press the XIAO's reset button (or re-open the monitor). Put the GPS on a window sill or outside, antenna (the square ceramic side) facing the sky.

**Check:** `GPS: found at 38400 baud, set to 10 Hz`. Within a minute or two outside: `3D fix`, 10+ sats, `10 Hz`, accuracy under 3 m. Indoors it may never get a fix; that's normal.

If it says NOT FOUND: swap D6/D7, check 3V3 and GND.

## Stage 3: heel and pitch (BNO085)

Solder the header pins onto the BNO085 first.

| BNO085 pin | goes to XIAO |
|---|---|
| VIN | 3V3 |
| GND | GND |
| SDA | **D4** |
| SCL | **D5** |

Reset. **Check:** `IMU: found`. Put the breadboard flat and type `z` (zero). Heel and pitch read about 0.

Now decide which way the puck will sit on the boat, and tip the board the way the boat heels **to starboard**: heel should go **positive**.
- If tipping sideways changes *pitch* instead: type `a` (swap axes), sit it level, `z` again.
- If heel goes negative: type `f` (flip).

These settings are remembered.

## Stage 4: status LED

D3 → 330 Ω → LED long leg; LED short leg → GND.

**Check:** slow blink with no GPS fix, one blink a second with a fix, double blink when recording.

## Stage 5: battery and charger

**Unplug the USB first.**

1. **Check the battery polarity** with the multimeter.
2. Battery → TP4056 **B+ / B−**.
3. TP4056 **OUT+ / OUT−** → the XIAO's **BAT+ / BAT−** pads underneath (solder two short wires). Nothing goes to the XIAO's 5V pin.
4. Battery sense: TP4056 OUT+ → 100 kΩ → **A0** (D0) → 100 kΩ → GND.

Unplug USB: the XIAO should run from the battery (LED blinking). Plug USB back in to see the monitor.

**Check:** `batt 3.9x V nn%`. The reading should be within about 0.05 V of the multimeter across the battery.

## Stage 6: wireless charging

1. Qi receiver 5 V out → TP4056 **IN+ / IN−** (the pads beside its USB socket).
2. Pad sense: Qi 5 V → 100 kΩ → **A1** (D1) → 100 kΩ → GND.
3. Lay the Qi coil flat on the pad.

**Check:** the TP4056 red LED lights (charging), the monitor says `on the pad, charging`. Lift the coil: `off the pad`. When full the TP4056 LED goes blue/green and the monitor says `full`.

If the pad doesn't start: centre the coil, and try another pad. Some are fussy with small coils.

## Stage 7: first real track

1. In the monitor type `p1` (this is puck 1), then `r` to start recording.
2. Unplug USB, put the breadboard in a food box, and go for a walk, a bike ride, or better, a sail. It records whenever it has a fix.
3. Back home: plug in, **close the serial monitor**, then in a terminal in the project folder:

```
pip install pyserial
python tools/pull_track.py
```

It saves `puck1_HHMMSS.csv`. Drop it on the viewer (or add `--upload` with the dock server running and it lands in the right session).

About 3 hours fits on the 8 MB XIAO (about 1.9 MB an hour as text). The real firmware stores it more compactly.

## What's not on the breadboard (yet)

- The AO3401 GPS power switch (only matters for sleeping for weeks).
- Wake-on-movement, auto start/stop, dock check-ins and uploads. That's the real firmware, next.
