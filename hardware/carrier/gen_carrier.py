#!/usr/bin/env python3
"""WakeBack carrier board v1: generates JLCPCB-ready Gerbers + drill files, checks them, and renders previews.

A 60 mm round, 2-layer board that the off-the-shelf modules wire onto:
  top:    XIAO ESP32S3 (on its pins), BNO085 breakout (stuck down, 5 wires), 1206 resistors + LED
  bottom: TP4056 charger and Qi receiver modules (stuck down, short wires), battery below that
  lid:    BE-880 GPS, 4 wires to the GPS pads

Pins match firmware/bench_test: D0 battery sense, D1 pad sense, D3 LED, D4/D5 I2C, D6/D7 GPS, D8 IMU INT.
Run: python gen_carrier.py   (needs: pip install shapely matplotlib gerbonara)
"""
import math, os, zipfile, datetime
from shapely.geometry import Point, LineString, Polygon, MultiPolygon, box
from shapely.ops import unary_union
from shapely import affinity

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out')
os.makedirs(OUT, exist_ok=True)
R_BOARD = 30.0
BOARD = Point(0, 0).buffer(R_BOARD, 256)

CLEAR = 0.25          # copper to copper, different nets (JLCPCB minimum is 0.127)
EDGE = 0.5            # copper to board edge
SIG, PWR = 0.3, 0.5   # track widths
THT_PAD, THT_DRILL = 1.7, 1.0
VIA_PAD, VIA_DRILL = 0.7, 0.35

pads = []      # dict(net, x, y, shape: 'circle'|'rect', w, h, layers: {'F','B'}, drill or None, ref, label)
tracks = []    # dict(net, layer, pts, w)
vias = []      # dict(net, x, y)
holes = []     # NPTH: (x, y, d)
silk = {'F': [], 'B': []}   # shapely geoms (already stroked or filled)

def tht(ref, net, x, y, label=None, size=THT_PAD, drill=THT_DRILL, square=False):
    pads.append(dict(ref=ref, net=net, x=x, y=y, shape='rect' if square else 'circle', w=size, h=size, layers={'F', 'B'}, drill=drill, label=label))

def smd(ref, net, x, y, w, h, layer='F'):
    pads.append(dict(ref=ref, net=net, x=x, y=y, shape='rect', w=w, h=h, layers={layer}, drill=None, label=None))

def trk(net, layer, pts, w=SIG):
    tracks.append(dict(net=net, layer=layer, pts=pts, w=w))

def via(net, x, y):
    vias.append(dict(net=net, x=x, y=y))

# ---------------------------------------------------------------- XIAO ESP32S3 (USB to the left)
XC, YC = -13.0, 3.0
bottom_row = ['D0', 'D1', 'D2', 'D3', 'D4', 'D5', 'D6']            # left to right, y = YC - 7.62
top_row = ['5V', 'GND', '3V3', 'D10', 'D9', 'D8', 'D7']             # left to right, y = YC + 7.62
X = {}
for k, n in enumerate(bottom_row): X[n] = (XC - 7.62 + 2.54 * k, YC - 7.62)
for k, n in enumerate(top_row):    X[n] = (XC - 7.62 + 2.54 * k, YC + 7.62)
net_of_pin = {'D0': 'A0', 'D1': 'A1', 'D2': 'NC_D2', 'D3': 'LED', 'D4': 'SDA', 'D5': 'SCL', 'D6': 'GPS_RX',
              '5V': 'NC_5V', 'GND': 'GND', '3V3': '3V3', 'D10': 'NC_D10', 'D9': 'NC_D9', 'D8': 'IMU_INT', 'D7': 'GPS_TX'}
for n, (x, y) in X.items():
    tht('U1', net_of_pin[n], x, y, square=(n == 'D0'))

# ---------------------------------------------------------------- wire pad groups (2.54 mm)
GPS_Y = 19.5
GPS = [('3V3', '3V3', -7.62), ('GND', 'GND', -5.08), ('TX', 'GPS_TX', -2.54), ('RX', 'GPS_RX', 0.0)]
for lab, net, x in GPS: tht('J_GPS', net, x, GPS_Y, lab, square=(lab == '3V3'))

IMU_Y = -13.0
IMU = [('3V3', '3V3', 4.0), ('GND', 'GND', 6.54), ('SDA', 'SDA', 9.08), ('SCL', 'SCL', 11.62), ('INT', 'IMU_INT', 14.16)]
for lab, net, x in IMU: tht('J_IMU', net, x, IMU_Y, lab, square=(lab == '3V3'))

TP_Y = -19.0
TP = [('IN+', 'VQI', -15.24), ('IN-', 'QI_GND', -12.7), ('B+', 'BAT_P', -10.16), ('B-', 'BAT_N', -7.62), ('OUT+', 'VSYS', -5.08), ('OUT-', 'GND', -2.54)]
for lab, net, x in TP: tht('J_TP', net, x, TP_Y, lab, square=(lab == 'IN+'))

LOW_Y = -23.5
tht('J_QI', 'VQI', -15.24, LOW_Y, '5V', square=True)
tht('J_QI', 'QI_GND', -12.7, LOW_Y, 'GND')
# JST-PH 2-pin battery socket (B2B-PH-K-S), pin 1 = +
tht('J_BAT', 'BAT_P', -10.16, LOW_Y, None, size=1.4, drill=0.8, square=True)
tht('J_BAT', 'BAT_N', -8.16, LOW_Y, None, size=1.4, drill=0.8)
# to the XIAO's BAT pads (short flying wires)
tht('J_XB', 'VSYS', -5.08, LOW_Y, 'BAT+', square=True)
tht('J_XB', 'GND', -2.54, LOW_Y, 'BAT-')

# ---------------------------------------------------------------- 1206 parts (vertical: pads above/below)
R_PAD = (1.8, 1.4)   # hand-solder friendly
def r1206_v(ref, x, y, net_top, net_bot):
    smd(ref, net_top, x, y + 1.6, *R_PAD)
    smd(ref, net_bot, x, y - 1.6, *R_PAD)
def r1206_h(ref, x, y, net_l, net_r):
    smd(ref, net_l, x - 1.6, y, R_PAD[1], R_PAD[0])
    smd(ref, net_r, x + 1.6, y, R_PAD[1], R_PAD[0])

r1206_v('R1', -24.5, -10.0, 'A0', 'VSYS')     # 100k battery divider top
r1206_v('R2', -21.5, -10.0, 'A0', 'GND')      # 100k battery divider bottom
r1206_v('R3', -18.2, -10.0, 'A1', 'VQI')      # 100k pad sense top
r1206_v('R4', -15.2, -10.0, 'A1', 'GND')      # 100k pad sense bottom
r1206_v('R5', -12.7, -10.0, 'LED', 'LED_A')   # 300R (a JLCPCB basic part; 330R works the same)
# LED 0805 (a JLCPCB basic part), anode left, cathode right
smd('D1', 'LED_A', -13.7, -15.5, 1.1, 1.3)
smd('D1', 'GND', -11.7, -15.5, 1.1, 1.3)

# ---------------------------------------------------------------- NPTH mounting holes (M2.5)
for hx, hy in [(0.0, 26.0), (-22.5, 15.5), (21.0, -17.0)]:
    holes.append((hx, hy, 2.7))

# ---------------------------------------------------------------- tracks
# GPS (top)
trk('3V3', 'F', [X['3V3'], (X['3V3'][0], 16.0), (-9.0, 16.0), (-7.62, 17.4), (-7.62, GPS_Y)], PWR)
trk('GPS_TX', 'F', [X['D7'], (X['D7'][0], 15.0), (-2.54, 17.84), (-2.54, GPS_Y)])
trk('GPS_RX', 'F', [X['D6'], (-3.4, X['D6'][1]), (0.0, -1.2), (0.0, GPS_Y)])
# IMU I2C (top)
trk('SDA', 'F', [X['D4'], (X['D4'][0], -9.5), (9.08, -9.5), (9.08, IMU_Y)])
trk('SCL', 'F', [X['D5'], (X['D5'][0], -7.5), (11.62, -7.5), (11.62, IMU_Y)])
# IMU INT (bottom, between D5 and D6)
trk('IMU_INT', 'B', [X['D8'], (-6.65, X['D8'][1] - 1.27), (-6.65, -8.0), (14.16, -8.0), (14.16, IMU_Y)])
# 3V3 to the IMU (bottom, between the XIAO's D1 and D2 pins)
trk('3V3', 'B', [X['3V3'], (-16.81, X['3V3'][1] - 1.27), (-16.81, -11.2), (4.0, -11.2), (4.0, IMU_Y)], SIG)   # squeezes between XIAO pins, IMU draws ~20 mA
# battery divider: D0 -> R1/R2 tops
trk('A0', 'F', [X['D0'], (X['D0'][0], -6.9), (-24.5, -6.9), (-24.5, -8.4)])
trk('A0', 'F', [(-21.5, -6.9), (-21.5, -8.4)])
# pad divider: D1 -> R3/R4 tops
trk('A1', 'F', [X['D1'], (X['D1'][0], -6.9), (-15.2, -6.9), (-15.2, -8.4)])
trk('A1', 'F', [(-18.2, -6.9), (-18.2, -8.4)])
# LED: D3 -> R5 -> LED
trk('LED', 'F', [X['D3'], (-12.7, -6.0), (-12.7, -8.4)])
trk('LED_A', 'F', [(-12.7, -11.6), (-12.7, -13.2), (-13.7, -14.2), (-13.7, -15.5)])
# GND vias for the top-side parts
via('GND', -21.5, -13.6); trk('GND', 'F', [(-21.5, -11.6), (-21.5, -13.6)], PWR)
via('GND', -15.2, -13.4); trk('GND', 'F', [(-15.2, -11.6), (-15.2, -13.4)], PWR)
via('GND', -9.4, -15.5);  trk('GND', 'F', [(-11.7, -15.5), (-9.4, -15.5)], PWR)
# VQI: Qi 5V -> TP4056 IN+ and R3 bottom (top)
trk('VQI', 'F', [(-15.24, LOW_Y), (-15.24, TP_Y)], PWR)
trk('VQI', 'F', [(-15.24, TP_Y), (-18.2, -16.0), (-18.2, -11.6)], PWR)
trk('QI_GND', 'F', [(-12.7, LOW_Y), (-12.7, TP_Y)], PWR)
# battery socket -> TP4056 B+/B-
trk('BAT_P', 'F', [(-10.16, LOW_Y), (-10.16, TP_Y)], PWR)
trk('BAT_N', 'F', [(-8.16, LOW_Y), (-8.16, -21.5), (-7.62, -20.9), (-7.62, TP_Y)], PWR)
# VSYS: TP4056 OUT+ -> XIAO BAT+ pad (top) and R1 bottom (bottom layer, via at R1)
trk('VSYS', 'F', [(-5.08, TP_Y), (-5.08, LOW_Y)], PWR)
via('VSYS', -24.5, -13.6); trk('VSYS', 'F', [(-24.5, -11.6), (-24.5, -13.6)], PWR)
trk('VSYS', 'B', [(-5.08, TP_Y), (-5.08, -16.9), (-22.0, -16.9), (-24.5, -14.4), (-24.5, -13.6)], PWR)

# ---------------------------------------------------------------- geometry helpers
def pad_geom(p, grow=0.0):
    if p['shape'] == 'circle':
        return Point(p['x'], p['y']).buffer(p['w'] / 2 + grow, 32)
    return box(p['x'] - p['w'] / 2 - grow, p['y'] - p['h'] / 2 - grow, p['x'] + p['w'] / 2 + grow, p['y'] + p['h'] / 2 + grow)

def trk_geom(t, grow=0.0):
    return LineString(t['pts']).buffer(t['w'] / 2 + grow, 16)

def via_geom(v, grow=0.0):
    return Point(v['x'], v['y']).buffer(VIA_PAD / 2 + grow, 24)

def copper(layer):
    """[(net, geom)] of pads, tracks and vias on a layer."""
    items = [(p['net'], pad_geom(p)) for p in pads if layer in p['layers']]
    items += [(t['net'], trk_geom(t)) for t in tracks if t['layer'] == layer]
    items += [(v['net'], via_geom(v)) for v in vias]
    return items

# ---------------------------------------------------------------- bottom GND pour with thermal reliefs
def make_pour():
    area = BOARD.buffer(-EDGE)
    keep_out = [g.buffer(CLEAR + 0.05) for n, g in copper('B') if n != 'GND']
    keep_out += [Point(x, y).buffer(d / 2 + 0.6) for x, y, d in holes]
    pour = area.difference(unary_union(keep_out))
    spokes = []
    for p in pads:
        if p['net'] != 'GND' or 'B' not in p['layers']: continue
        ring = pad_geom(p, CLEAR + 0.05)
        pour = pour.difference(ring)
        r = p['w'] / 2 + CLEAR + 0.4
        for ang in (0, 90, 180, 270):
            dx, dy = math.cos(math.radians(ang)), math.sin(math.radians(ang))
            spokes.append(LineString([(p['x'], p['y']), (p['x'] + dx * r, p['y'] + dy * r)]).buffer(0.25, cap_style=2))
    sp = unary_union(spokes).intersection(area).difference(unary_union(keep_out))
    pour = unary_union([pour, sp])
    # keep only islands that touch a GND pad or via
    gnd_bits = unary_union([pad_geom(p) for p in pads if p['net'] == 'GND' and 'B' in p['layers']] + [via_geom(v) for v in vias if v['net'] == 'GND'])
    parts = list(pour.geoms) if isinstance(pour, MultiPolygon) else [pour]
    parts = [q for q in parts if q.intersects(gnd_bits) and q.area > 1.0]
    return unary_union(parts)

POUR = make_pour()

# ---------------------------------------------------------------- silkscreen (text via matplotlib glyph outlines)
from matplotlib.textpath import TextPath
from matplotlib.font_manager import FontProperties
FONT = FontProperties(family='DejaVu Sans', weight='bold')

def text(s, x, y, size=1.0, layer='F', anchor='c', mirror=None):
    tp = TextPath((0, 0), s, size=size, prop=FONT)
    geom = None
    for poly in tp.to_polygons():
        if len(poly) < 3: continue
        g = Polygon(poly).buffer(0)
        geom = g if geom is None else geom.symmetric_difference(g)
    if geom is None: return
    minx, miny, maxx, maxy = geom.bounds
    w, h = maxx - minx, maxy - miny
    dx = {'c': -w / 2, 'l': 0, 'r': -w}[anchor] - minx
    geom = affinity.translate(geom, dx, -h / 2 - miny)
    if mirror is None: mirror = (layer == 'B')
    if mirror: geom = affinity.scale(geom, -1, 1, origin=(0, 0))
    silk[layer].append(affinity.translate(geom, x, y))

def outline(pts, layer='F', w=0.15, closed=True):
    silk[layer].append(LineString(list(pts) + ([pts[0]] if closed else [])).buffer(w / 2, 8))

def rect_outline(cx, cy, w, h, layer='F', lw=0.15):
    outline([(cx - w / 2, cy - h / 2), (cx + w / 2, cy - h / 2), (cx + w / 2, cy + h / 2), (cx - w / 2, cy + h / 2)], layer, lw)

# board title and labels (top)
text('WAKEBACK', 12.5, 22.6, 1.6)
text('carrier v1', 12.5, 20.6, 1.0)
# XIAO outline, USB marker, pin names
rect_outline(XC - 0.81, YC, 22.48, 17.8)
text('XIAO ESP32S3', XC + 0.5, YC + 1.0, 1.1)
text('USB', XC - 9.3, YC - 1.2, 0.9)
text('<', XC - 11.6, YC - 1.2, 1.0)
for n, (x, y) in X.items():
    text(n, x, y + (1.55 if y > YC else -1.55), 0.8)
# GPS group
text('GPS on lid', -3.81, GPS_Y + 2.2, 0.9)
for lab, net, x in GPS: text(lab, x, GPS_Y - 1.6, 0.8)
# IMU group + where the breakout sits
rect_outline(13.5, 3.0, 22.7, 25.6)
text('BNO085', 13.5, 6.5, 1.3)
text('stick down here', 13.5, 4.5, 0.8)
text('arrow = bow', 13.5, -4.6, 0.8)
outline([(13.5, -2.6), (13.5, 2.2)], 'F', 0.2, closed=False)
outline([(12.5, 1.1), (13.5, 2.3), (14.5, 1.1)], 'F', 0.2, closed=False)
for lab, net, x in IMU: text(lab, x, IMU_Y - 1.6, 0.8)
text('IMU', 9.08, IMU_Y - 3.0, 0.9)
# power group
for k, (lab, net, x) in enumerate(TP): text(lab, x, TP_Y + (1.55 if k % 2 == 0 else -1.55), 0.8)   # staggered so OUT+/OUT- don't touch
text('TP4056', -19.6, TP_Y, 0.85)
text('5V', -15.24, LOW_Y - 1.55, 0.8); text('GND', -12.7, LOW_Y - 1.55, 0.8); text('Qi', -17.5, LOW_Y, 0.8)
text('BATT', -9.16, LOW_Y - 1.55, 0.8); text('+', -11.35, LOW_Y + 1.0, 0.9)
text('BAT+', -5.08, LOW_Y - 1.55, 0.8); text('BAT-', -2.54, LOW_Y - 1.55, 0.8)
text('to XIAO BAT', -3.81, LOW_Y - 2.9, 0.8)
# 1206 refs sit between each part's pads
for ref, x in [('R1', -24.5), ('R2', -21.5), ('R3', -18.2), ('R4', -15.2), ('R5', -12.7)]:
    text(ref, x, -10.0, 0.8)
text('LED', -12.7, -17.1, 0.8); text('A', -15.0, -15.5, 0.8); text('K', -10.4, -16.6, 0.8)
# bottom side: the same pad labels, readable from underneath
text('WAKEBACK carrier v1', 0, 24.0, 1.3, 'B')
for k, (lab, net, x) in enumerate(TP): text(lab, x, TP_Y + (1.55 if k % 2 == 0 else -1.55), 0.8, 'B')   # staggered so OUT+/OUT- don't touch
text('TP4056', -19.6, TP_Y, 0.85, 'B')
text('5V', -15.24, LOW_Y - 1.55, 0.8, 'B'); text('GND', -12.7, LOW_Y - 1.55, 0.8, 'B'); text('Qi', -17.5, LOW_Y, 0.8, 'B')
text('BATT', -9.16, LOW_Y - 1.55, 0.8, 'B'); text('+', -11.35, LOW_Y + 1.0, 0.9, 'B')
text('BAT+', -5.08, LOW_Y - 1.55, 0.8, 'B'); text('BAT-', -2.54, LOW_Y - 1.55, 0.8, 'B')
for lab, net, x in GPS: text(lab, x, GPS_Y - 1.6, 0.8, 'B')
text('GPS', -3.81, GPS_Y + 2.0, 0.85, 'B')
for lab, net, x in IMU: text(lab, x, IMU_Y - 1.6, 0.8, 'B')
text('IMU', 9.08, IMU_Y - 3.0, 0.85, 'B')
rect_outline(12.0, 3.0, 26.0, 16.0, 'B')
text('TP4056 module here', 12.0, 4.2, 1.0, 'B'); text('USB end to the edge', 12.0, 2.3, 0.8, 'B')
text('R1-R4 100k  R5 300R  LED 0805', 0, -27.0, 0.8, 'B')
text('Qi receiver: next to the battery, coil under it', 0, 16.0, 0.8, 'B')
text(datetime.date.today().isoformat(), -25.0, 3.0, 0.8, 'B')

# clip silk away from pads and holes, keep on board
def silk_final(layer):
    g = unary_union(silk[layer])
    clear = [pad_geom(p, 0.15) for p in pads if layer in p['layers']] + [Point(x, y).buffer(d / 2 + 0.3) for x, y, d in holes]
    clear += [Point(v['x'], v['y']).buffer(VIA_PAD / 2 + 0.1) for v in vias]
    return g.difference(unary_union(clear)).intersection(BOARD.buffer(-0.3))

SILK = {'F': silk_final('F'), 'B': silk_final('B')}

# ================================================================ checks
problems = []
# 1. clearances between different nets, per layer (pour counts as GND on the bottom)
for layer in ('F', 'B'):
    items = copper(layer)
    if layer == 'B': items = items + [('GND', POUR)]
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            (na, ga), (nb, gb) = items[i], items[j]
            if na == nb: continue
            d = ga.distance(gb)
            if d < CLEAR - 1e-6: problems.append(f'{layer}: {na} vs {nb} only {d:.3f} mm apart near {ga.centroid.x:.1f},{ga.centroid.y:.1f}')
    # 2. edge clearance
    for n, g in items:
        if not g.within(BOARD.buffer(-EDGE + 1e-6)): problems.append(f'{layer}: {n} copper within {EDGE} mm of the edge')
# 3. NPTH holes clear of copper
for x, y, d in holes:
    h = Point(x, y).buffer(d / 2)
    for layer in ('F', 'B'):
        for n, g in copper(layer):
            if g.distance(h) < 0.5: problems.append(f'hole at {x},{y} too close to {n} on {layer}')
# 4. connectivity: every net's copper forms one connected piece
from collections import defaultdict
nodes = []
for p in pads: nodes.append((p['net'], p['layers'], pad_geom(p)))
for t in tracks: nodes.append((t['net'], {t['layer']}, trk_geom(t)))
for v in vias: nodes.append((v['net'], {'F', 'B'}, via_geom(v)))
nodes.append(('GND', {'B'}, POUR))
by_net = defaultdict(list)
for k, nd in enumerate(nodes): by_net[nd[0]].append(k)
for net, idx in by_net.items():
    if net.startswith('NC_'): continue
    parent = {k: k for k in idx}
    def find(a):
        while parent[a] != a: parent[a] = parent[parent[a]]; a = parent[a]
        return a
    for a in idx:
        for b in idx:
            if a < b and nodes[a][1] & nodes[b][1] and nodes[a][2].intersects(nodes[b][2]):
                parent[find(a)] = find(b)
    comps = {find(k) for k in idx}
    if len(comps) > 1: problems.append(f'net {net} is in {len(comps)} unconnected pieces')

# expected connections (the schematic), checked against the copper
expected = {
    '3V3': ['U1:3V3', 'J_GPS:3V3', 'J_IMU:3V3'], 'GND': ['U1:GND', 'J_GPS:GND', 'J_IMU:GND', 'J_TP:OUT-', 'J_XB:BAT-', 'R2', 'R4', 'D1'],
    'GPS_TX': ['U1:D7', 'J_GPS:TX'], 'GPS_RX': ['U1:D6', 'J_GPS:RX'], 'SDA': ['U1:D4', 'J_IMU:SDA'], 'SCL': ['U1:D5', 'J_IMU:SCL'],
    'IMU_INT': ['U1:D8', 'J_IMU:INT'], 'A0': ['U1:D0', 'R1', 'R2'], 'A1': ['U1:D1', 'R3', 'R4'], 'LED': ['U1:D3', 'R5'], 'LED_A': ['R5', 'D1'],
    'VSYS': ['J_TP:OUT+', 'J_XB:BAT+', 'R1'], 'VQI': ['J_QI:5V', 'J_TP:IN+', 'R3'], 'QI_GND': ['J_QI:GND', 'J_TP:IN-'],
    'BAT_P': ['J_BAT', 'J_TP:B+'], 'BAT_N': ['J_BAT', 'J_TP:B-'],
}
def who(p):
    if p['ref'] == 'U1':
        return 'U1:' + next(n for n, xy in X.items() if xy == (p['x'], p['y']))
    return p['ref'] + (':' + p['label'] if p['label'] else '')
for net, members in expected.items():
    have = {who(p) for p in pads if p['net'] == net}
    for m in members:
        if not any(h == m or h.startswith(m + ':') or h == m.split(':')[0] and ':' not in m for h in have):
            problems.append(f'net {net}: {m} missing')

print('DRC / connectivity:', 'PASS' if not problems else f'{len(problems)} problem(s)')
for p in problems: print('  -', p)

# ================================================================ Gerber output
def fmt(v): return str(int(round(v * 1e6)))

class Gerber:
    def __init__(self, fname, func, polarity='Positive'):
        self.f = open(os.path.join(OUT, fname), 'w'); self.ap = {}; self.next = 10; self.body = []
        self.head = ['G04 WakeBack carrier v1*', '%TF.GenerationSoftware,WakeBack,gen_carrier.py,1*%', f'%TF.FileFunction,{func}*%',
                     f'%TF.FilePolarity,{polarity}*%', '%FSLAX46Y46*%', '%MOMM*%', '%LPD*%']
    def aperture(self, kind, *dims):
        key = (kind,) + tuple(round(d, 4) for d in dims)
        if key not in self.ap:
            self.ap[key] = self.next
            self.head.append(f'%ADD{self.next}{kind},' + 'X'.join(f'{d:.4f}' for d in dims) + '*%'); self.next += 1
        return self.ap[key]
    def pol(self, dark): self.body.append('%LPD*%' if dark else '%LPC*%')
    def flash(self, d, x, y): self.body += [f'D{d}*', f'X{fmt(x)}Y{fmt(y)}D03*']
    def stroke(self, d, pts):
        self.body.append(f'D{d}*'); self.body.append(f'X{fmt(pts[0][0])}Y{fmt(pts[0][1])}D02*')
        self.body += [f'X{fmt(x)}Y{fmt(y)}D01*' for x, y in pts[1:]]
    def ring(self, coords):
        c = list(coords)
        self.body += ['G36*', f'X{fmt(c[0][0])}Y{fmt(c[0][1])}D02*', 'G01*'] + [f'X{fmt(x)}Y{fmt(y)}D01*' for x, y in c[1:]] + ['G37*']
    def polys(self, geom):
        gs = list(geom.geoms) if hasattr(geom, 'geoms') else [geom]
        for g in gs:
            if g.is_empty or g.geom_type != 'Polygon': continue
            self.pol(True); self.ring(g.exterior.coords)
            for hole in g.interiors: self.pol(False); self.ring(hole.coords)
        self.pol(True)
    def close(self):
        self.f.write('\n'.join(self.head + self.body + ['M02*']) + '\n'); self.f.close()

def pad_flash(g, p, grow=0.0):
    if p['shape'] == 'circle': g.flash(g.aperture('C', p['w'] + 2 * grow), p['x'], p['y'])
    else: g.flash(g.aperture('R', p['w'] + 2 * grow, p['h'] + 2 * grow), p['x'], p['y'])

for layer, fname, func in [('F', 'wakeback-carrier-F_Cu.gtl', 'Copper,L1,Top'), ('B', 'wakeback-carrier-B_Cu.gbl', 'Copper,L2,Bot')]:
    g = Gerber(fname, func)
    if layer == 'B': g.polys(POUR)
    for t in tracks:
        if t['layer'] == layer: g.stroke(g.aperture('C', t['w']), t['pts'])
    for p in pads:
        if layer in p['layers']: pad_flash(g, p)
    for v in vias: g.flash(g.aperture('C', VIA_PAD), v['x'], v['y'])
    g.close()

for layer, fname, func in [('F', 'wakeback-carrier-F_Mask.gts', 'Soldermask,Top'), ('B', 'wakeback-carrier-B_Mask.gbs', 'Soldermask,Bot')]:
    g = Gerber(fname, func, 'Negative')
    for p in pads:
        if layer in p['layers']: pad_flash(g, p, 0.05)
    g.close()     # vias stay tented

for layer, fname, func in [('F', 'wakeback-carrier-F_Silkscreen.gto', 'Legend,Top'), ('B', 'wakeback-carrier-B_Silkscreen.gbo', 'Legend,Bot')]:
    g = Gerber(fname, func); g.polys(SILK[layer]); g.close()

# solder paste (only the top-side SMD pads) for JLCPCB's stencil when they assemble the resistors and LED
g = Gerber('wakeback-carrier-F_Paste.gtp', 'Paste,Top')
for p in pads:
    if p['drill'] is None and 'F' in p['layers']: pad_flash(g, p)
g.close()

g = Gerber('wakeback-carrier-Edge_Cuts.gm1', 'Profile,NP')
g.stroke(g.aperture('C', 0.1), list(BOARD.exterior.coords)); g.close()

def excellon(fname, entries, plated):
    tools = sorted({round(d, 3) for _, _, d in entries})
    with open(os.path.join(OUT, fname), 'w') as f:
        f.write('M48\n; WakeBack carrier v1\n' + f'; #@! TF.FileFunction,{"Plated,1,2,PTH" if plated else "NonPlated,1,2,NPTH"}\nFMAT,2\nMETRIC\n')
        for k, d in enumerate(tools, 1): f.write(f'T{k}C{d:.3f}\n')
        f.write('%\nG90\nG05\n')
        for k, d in enumerate(tools, 1):
            f.write(f'T{k}\n')
            for x, y, dd in entries:
                if round(dd, 3) == d: f.write(f'X{x:.3f}Y{y:.3f}\n')
        f.write('T0\nM30\n')

excellon('wakeback-carrier-PTH.drl', [(p['x'], p['y'], p['drill']) for p in pads if p['drill']] + [(v['x'], v['y'], VIA_DRILL) for v in vias], True)
excellon('wakeback-carrier-NPTH.drl', holes, False)

zpath = os.path.join(OUT, 'wakeback-carrier-v1-gerbers.zip')
with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED) as z:
    for fn in sorted(os.listdir(OUT)):
        if fn.startswith('wakeback-carrier') and not fn.endswith(('.zip', '.png', '.csv')): z.write(os.path.join(OUT, fn), fn)
print('wrote', zpath)

# ================================================================ JLCPCB assembly files (top-side SMD parts only)
# Parts are JLCPCB "basic" parts (no loading fee). Rotations follow JLCPCB's standard footprints; check the LED in
# their placement preview: its cathode mark must sit on the K pad (right-hand pad).
ASSY = {  # ref: (comment, footprint, LCSC part, rotation)
    'R1': ('100k', 'R_1206', 'C17900', 90), 'R2': ('100k', 'R_1206', 'C17900', 90),
    'R3': ('100k', 'R_1206', 'C17900', 90), 'R4': ('100k', 'R_1206', 'C17900', 90),
    'R5': ('300R', 'R_1206', 'C17887', 90), 'D1': ('LED red', 'LED_0805', 'C84256', 180),
}
import csv
centres = {}
for p in pads:
    if p['ref'] in ASSY: centres.setdefault(p['ref'], []).append((p['x'], p['y']))
with open(os.path.join(OUT, 'wakeback-carrier-v1-BOM.csv'), 'w', newline='') as f:
    w = csv.writer(f); w.writerow(['Comment', 'Designator', 'Footprint', 'JLCPCB Part #'])
    groups = {}
    for ref, (cmt, fp, lcsc, rot) in ASSY.items(): groups.setdefault((cmt, fp, lcsc), []).append(ref)
    for (cmt, fp, lcsc), refs in groups.items(): w.writerow([cmt, ','.join(refs), fp, lcsc])
with open(os.path.join(OUT, 'wakeback-carrier-v1-CPL.csv'), 'w', newline='') as f:
    w = csv.writer(f); w.writerow(['Designator', 'Mid X', 'Mid Y', 'Layer', 'Rotation'])
    for ref, (cmt, fp, lcsc, rot) in ASSY.items():
        pts = centres[ref]; cx = sum(x for x, y in pts) / len(pts); cy = sum(y for x, y in pts) / len(pts)
        w.writerow([ref, f'{cx:.3f}mm', f'{cy:.3f}mm', 'Top', rot])
print('wrote BOM and CPL for JLCPCB assembly')

# ================================================================ previews
import matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import PathPatch
from matplotlib.path import Path as MPath

def draw(ax, geom, **kw):
    gs = list(geom.geoms) if hasattr(geom, 'geoms') else [geom]
    for g in gs:
        if g.is_empty or g.geom_type != 'Polygon': continue
        verts, codes = [], []
        for ring in [g.exterior] + list(g.interiors):
            c = list(ring.coords); verts += c; codes += [MPath.MOVETO] + [MPath.LINETO] * (len(c) - 2) + [MPath.CLOSEPOLY]
        ax.add_patch(PathPatch(MPath(verts, codes), **kw))

def render(side, fname):
    fig, ax = plt.subplots(figsize=(8, 8), dpi=150)
    ax.set_facecolor('#0b0f14')
    draw(ax, BOARD, facecolor='#1f5c3a', edgecolor='none')
    other = 'B' if side == 'F' else 'F'
    cu_other = unary_union([g for n, g in copper(other)] + ([POUR] if other == 'B' else []))
    draw(ax, cu_other, facecolor='#2c6e4a', edgecolor='none')
    cu = unary_union([g for n, g in copper(side)] + ([POUR] if side == 'B' else []))
    draw(ax, cu, facecolor='#3f8f5c', edgecolor='none')
    padg = unary_union([pad_geom(p) for p in pads if side in p['layers']])
    draw(ax, padg, facecolor='#d4a84a', edgecolor='none')
    for x, y, d in holes: draw(ax, Point(x, y).buffer(d / 2), facecolor='#0b0f14', edgecolor='none')
    for p in pads:
        if p['drill']: draw(ax, Point(p['x'], p['y']).buffer(p['drill'] / 2), facecolor='#0b0f14', edgecolor='none')
    for v in vias: draw(ax, Point(v['x'], v['y']).buffer(VIA_DRILL / 2), facecolor='#0b0f14', edgecolor='none')
    draw(ax, SILK[side], facecolor='#f2f2f2', edgecolor='none')
    ax.set_xlim(-32, 32); ax.set_ylim(-32, 32); ax.set_aspect('equal'); ax.axis('off')
    if side == 'B': ax.invert_xaxis()      # seen from underneath
    ax.set_title(f'WakeBack carrier v1, {"top" if side == "F" else "bottom (seen from below)"}, 60 mm', color='white', fontsize=12)
    fig.savefig(os.path.join(OUT, fname), facecolor='#0b0f14', bbox_inches='tight'); plt.close(fig)

render('F', 'preview-top.png'); render('B', 'preview-bottom.png')
print('previews written')
