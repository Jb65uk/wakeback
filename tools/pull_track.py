#!/usr/bin/env python3
"""Copy the recorded track off a bench-test puck over USB and save it as a CSV the viewer opens.

Usage:  python tools/pull_track.py              # finds the puck's USB port by itself
        python tools/pull_track.py --port COM5  # or name it (Windows COMx, Mac /dev/cu.usbmodem..., Linux /dev/ttyACM0)
        python tools/pull_track.py --upload     # also send it to the dock server running on this computer

Needs:  pip install pyserial
Close the PlatformIO serial monitor first: only one program can use the port at a time.
"""
import argparse, os, sys, time
try:
    import serial, serial.tools.list_ports
except ImportError:
    sys.exit('Needs pyserial: pip install pyserial')

ap = argparse.ArgumentParser()
ap.add_argument('--port')
ap.add_argument('--out', default='.')
ap.add_argument('--upload', action='store_true', help='also upload to the dock (default http://localhost:5000)')
ap.add_argument('--dock', default='http://localhost:5000')
a = ap.parse_args()

port = a.port
if not port:
    esp = [p for p in serial.tools.list_ports.comports() if p.vid == 0x303A]   # Espressif USB (XIAO ESP32S3)
    if not esp: sys.exit('No puck found on USB. Plug it in, close the serial monitor, or pass --port.')
    port = esp[0].device
print(f'Talking to the puck on {port}…')
with serial.Serial(port, 115200, timeout=2) as s:
    time.sleep(0.5)
    s.reset_input_buffer()
    s.write(b'd\n')           # status lines before the download are skipped below
    name, lines, deadline = None, [], time.time() + 10
    while True:
        raw = s.readline()
        if not raw:
            if name is None and time.time() > deadline: sys.exit('The puck didn\'t answer. Is the bench test firmware on it?')
            if name is not None: sys.exit('The download stopped part way. Try again.')
            continue
        line = raw.decode(errors='replace').rstrip('\r\n')
        if name is None:
            if line.startswith('No track'): sys.exit('The puck has no recorded track yet. Type r in the serial monitor to record one.')
            if line.startswith('---BEGIN '): name = line[9:].rstrip('-').strip()
            continue
        if line.startswith('---END'): break
        lines.append(line)

if len(lines) < 2: sys.exit('The track is empty. Record with the GPS showing a fix.')
os.makedirs(a.out, exist_ok=True)
path = os.path.join(a.out, name)
with open(path, 'w') as f: f.write('\n'.join(lines) + '\n')
print(f'Saved {path}: {len(lines) - 1} points, about {(len(lines) - 1) / 600:.1f} minutes. Drop it on the viewer to see it.')

if a.upload:
    import subprocess
    here = os.path.dirname(os.path.abspath(__file__))
    subprocess.run([sys.executable, os.path.join(here, 'fake_puck_upload.py'), path, '--dock', a.dock])
