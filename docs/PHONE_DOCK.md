# Phone as the dock — what the puck firmware needs

No new protocol. A phone running the WakeBack app answers every dock URL the same way
`server/app.py` does, on port **5000**. So the firmware has one upload path, and only
needs to know *where* the dock is:

**The dock is the WiFi gateway, port 5000.**

| Where | Puck joins | Gateway = | Dock URL |
|---|---|---|---|
| Club, dock Pi | the Pi's own AP `wakeback` | the Pi | `http://<gateway>:5000` |
| No dock | the phone's hotspot `wakeback` | the phone | `http://<gateway>:5000` |

Firmware flow when on the pad (unchanged, just the address lookup):

1. Join SSID `wakeback` (password in NVS).
2. `GET http://<gateway>:5000/api/hello` → `{"dock":"wakeback","time_ms":…}` confirms it's a dock
   (and sets the clock if there's no GPS time yet). No reply → try again later.
3. `POST /api/pucks/checkin` every ~30 s (and once as it's lifted off the pad), header `X-Puck-Key` when a
   key is set. The JSON body (from `firmware/puck/src/main.cpp` `checkin()`): `puck` (number), `battery_mv`,
   `charging` (`"not"` / `"charging"` / `"full"`), `on_pad`, `free_kb`, `total_kb`, `fw`, `pending` (tracks
   waiting), `rssi`, `recording`, `orientation` (`"deck"` / `"thwart"` / `"unknown"`), `twist` (degrees),
   `mag` (compass 0–3), `gps_fix`, `ip`. The reply is `{"ok":true,"time_ms":…}`; a 401/403 means the key
   was refused and the puck backs off (10 min off the pad, 2 min on it) and says so on its page.
4. `POST /api/upload` (multipart `file`, plus `puck=puckN`) for each finished session;
   delete from flash only after a `200` with `{"ok":true}`.

On the ESP32: `WiFi.gatewayIP()` after connecting.

Things that differ with a phone, and the app handles:

- The phone only accepts uploads while WakeBack is open (Android may pause it in the
  background). Pucks just retry on their next check-in.
- `/api/dock/status` reports `can_manage_wifi: false` and `phone: true`; the Dock page hides
  "Connect to WiFi" and says to use the phone's hotspot.
- Android hotspots often use `192.168.43.1` or `10.x.x.1`, never assume the address — use the gateway.
