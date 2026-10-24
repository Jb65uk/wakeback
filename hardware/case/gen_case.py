#!/usr/bin/env python3
"""WakeBack puck case: generates print-ready STLs, checks every part fits, and renders previews.

Parts (all in out/):
  wakeback-base.stl    the cup: battery, carrier board and TP4056 inside; bayonet lugs round the bottom
  wakeback-lid.stl     screw-on lid, O-ring face seal (70 x 2 mm nitrile O-ring, or the printed TPU gasket)
  wakeback-gasket-tpu.stl   printed TPU gasket for the same groove, instead of the O-ring
  wakeback-bridge.stl  GPS shelf, held by the same two screws that hold the board down
  wakeback-cradle.stl  deck mount: drop the puck in, twist clockwise, it locks with the arrow to the bow
  wakeback-lid-mount.stl    second lid with bayonet lugs round its rim, for hanging the puck under a thwart
  wakeback-cradle-lid.stl   the cradle for that lid: screws to the underside of the thwart, puck twists in upside down

Frame: same as the carrier board. Origin = board centre, +Y = bow (the IMU arrow), Z up, base underside at z = 0.
Run: python gen_case.py   (needs: pip install manifold3d trimesh numpy matplotlib)
"""
import math, os
import numpy as np
import manifold3d as mf
from manifold3d import Manifold as M, CrossSection as CS

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'out'); os.makedirs(OUT, exist_ok=True)
SEG = 180

# ------------------------------------------------------------------ what goes inside (mm)
BATT = dict(l=62, w=35, t=5.3)       # 1200 mAh LiPo (Pi Hut / Adafruit 34 x 62 x 5)
BATT_ANGLE = 27.7                    # battery turned so it misses all three board standoffs
COIL = dict(l=48, w=32, t=0.9)       # Qi receiver coil on its shield sticker
QI_BOARD = dict(l=19, w=12, t=2.0, x=8.15, y=-23.05)   # beside the battery, clear of the standoffs
PCB_R, PCB_T = 30.0, 1.6
HOLES = [(0.0, 26.0), (-22.5, 15.5), (21.0, -17.0)]   # M2.5 holes in the carrier board
TP = dict(cx=12.0, cy=3.0, l=26.0, w=16.0, h=5.5)      # TP4056 hanging under the board
XIAO = dict(cx=-13.81, cy=3.0, l=22.48, w=17.8, h=13.0)  # on 8.5 mm female headers
IMU = dict(cx=13.5, cy=3.0, l=17.8, w=25.4, h=5.7)     # BNO085 on foam tape, STEMMA sockets on top
GPS = dict(cx=12.5, cy=2.0, s=28.0, h=11.0)            # Beitian BE-880, 28 x 28 x 11

# ------------------------------------------------------------------ case dimensions
FLOOR = 1.4              # thin, so the Qi coil is close to the pad
R_IN = 37.0              # inside radius (battery corners are at 35.5)
WALL = 2.6
R_BODY = R_IN + WALL     # 39.6
Z_PCB = FLOOR + 12.5     # underside of the board
Z_PCB_TOP = Z_PCB + PCB_T
Z_BRIDGE = 22.5          # underside of the GPS shelf
BRIDGE_T = 1.6
Z_GPS = Z_BRIDGE + BRIDGE_T
Z_TOP = 35.6             # top of the base rim (O-ring face)
R_NECK_IN = 33.5         # inside radius at the rim, leaves room for the O-ring groove
NECK_H = 8.0             # thread length
PITCH, THREAD_E = 3.0, 0.45       # sinusoidal thread, 0.9 mm deep
THREAD_CLR = 0.35
ORING_R, ORING_W, ORING_D = 36.0, 2.6, 1.5   # groove for a 70 x 2 mm O-ring (compressed 25 %)
LID_TOP = 1.8
LID_WALL = 2.4
R_LID = R_BODY + THREAD_E + THREAD_CLR + LID_WALL + 0.35
LUGS = [(90.0, 16.0), (210.0, 10.0), (330.0, 10.0)]   # (angle, width deg). The wide one marks the bow
LUG_OUT, LUG_Z0, LUG_Z1 = 2.0, 2.2, 5.2
TWIST = 20.0             # cradle: drop in 20 deg anticlockwise of locked, twist clockwise
CR_FLOOR, CR_CLR = 3.0, 0.3
CR_WALL = 3.0
CR_H = CR_FLOOR + 9.0
# the snap: how the cradle grips the puck once it's twisted home
CR_END_GAP = 0.3         # deg the lug can still turn past home before it meets the end wall (was 1.5)
CR_PRELOAD = 0.15        # mm the lock-zone ceiling sits *below* the lug top, so the lug wedges the puck down on the floor
CR_RAMP = 8.0            # deg over which the ceiling comes down from free (+0.5) to the preload, so it tightens progressively
CR_TONGUE_T = 2.0        # the spring tongue: a strip of the outer wall, this thick, free top and bottom
CR_TONGUE_GAP = 0.5      # air between the tongue and the lug channel, so it can flex out
CR_TONGUE_EXT = 9.0      # deg a 10-deg lug's tongue carries on past the end wall (longer tongue = softer spring)
CR_NIB = 0.5             # mm the nib on the tongue stands into the lug's path: the click
CR_NIB_IN, CR_NIB_OUT = 40.0, 60.0   # ramp angles (deg from the tongue face): going in / coming back out
CR_SLIT = 1.0            # mm gap over the tongue's top, and the width of the slit at its free end
SCREW_PILOT, SCREW_CLEAR = 2.2, 2.8   # M2.5 self-tapping into plastic / clearance


def cyl(r, h, z=0.0, x=0.0, y=0.0, r2=None, seg=SEG):
    return M.cylinder(h, r, r if r2 is None else r2, seg).translate([x, y, z])


def box(l, w, h, cx=0.0, cy=0.0, z=0.0, ang=0.0):
    return M.cube([l, w, h], True).translate([0, 0, h / 2]).rotate([0, 0, ang]).translate([cx, cy, z])


def ring(r0, r1, h, z=0.0, seg=SEG):
    return cyl(r1, h, z, seg=seg) - cyl(r0, h + 0.02, z - 0.01, seg=seg)


def sector(r0, r1, z0, z1, a0, a1):
    """Solid between radii r0..r1, heights z0..z1, angles a0..a1 (deg, anticlockwise)."""
    prof = CS([[(r0, z0), (r1, z0), (r1, z1), (r0, z1)]])
    return M.revolve(prof, SEG, a1 - a0).rotate([0, 0, a0])


def thread(r_mid, z0, h, grow=0.0):
    """Right-hand single-start thread: an off-centre circle twisted once per pitch."""
    c = CS.circle(r_mid + grow, SEG).translate([THREAD_E, 0]).rotate(360.0 * z0 / PITCH)
    turns = h / PITCH
    return M.extrude(c, h, int(turns * 72) + 1, 360.0 * turns).translate([0, 0, z0])


def text_cs(s, size, cx=0.0, cy=0.0):
    from matplotlib.textpath import TextPath
    from matplotlib.font_manager import FontProperties
    tp = TextPath((0, 0), s, size=size, prop=FontProperties(family='DejaVu Sans', weight='bold'))
    polys = [p for p in tp.to_polygons() if len(p) > 2]
    cs = CS([np.asarray(p) for p in polys], mf.FillRule.EvenOdd)
    (x0, y0), (x1, y1) = cs.bounds()[:2], cs.bounds()[2:]
    return cs.translate([cx - (x0 + x1) / 2, cy - (y0 + y1) / 2])


# ================================================================== BASE
R_THREAD = R_BODY    # thread mid radius on the neck
Z_NECK = Z_TOP - NECK_H
base = cyl(R_BODY, Z_NECK)
base += thread(R_THREAD, Z_NECK - 0.01, NECK_H + 0.01)
# lead-in: trim the first half turn of thread with a cone so the lid starts easily
base -= (cyl(R_BODY + 3, 1.2, Z_TOP - 1.2) - cyl(R_BODY + THREAD_E + 0.01, 1.2, Z_TOP - 1.2, r2=R_BODY - THREAD_E - 0.2))
# hollow: straight up to the neck, 45 deg in to the rim radius (prints without support)
cav = cyl(R_IN, Z_NECK - 1.0 - FLOOR, FLOOR)
cav += cyl(R_IN, R_IN - R_NECK_IN, Z_NECK - 1.0, r2=R_NECK_IN)
cav += cyl(R_NECK_IN, Z_TOP - Z_NECK + 2, Z_NECK - 1.0 + (R_IN - R_NECK_IN) - 0.01)
base -= cav
# O-ring groove in the rim face
base -= ring(ORING_R - ORING_W / 2, ORING_R + ORING_W / 2, ORING_D + 0.01, Z_TOP - ORING_D)
# board standoffs (floor to board) with ribs back to the wall
for hx, hy in HOLES:
    a = math.degrees(math.atan2(hy, hx)); r = math.hypot(hx, hy)
    post = cyl(3.2, Z_PCB - FLOOR + 0.01, FLOOR - 0.01, hx, hy, seg=48)
    rib = box(R_IN - r + 0.5, 1.6, Z_PCB - 2.0 - FLOOR, cx=0, cy=0, z=FLOOR - 0.01)
    rib = rib.translate([(R_IN + r) / 2 - 0.2, 0, 0]).rotate([0, 0, a])
    base += post + rib
    base -= cyl(SCREW_PILOT / 2, 10.5, Z_PCB - 10.0, hx, hy, seg=32)
# battery locators: an L-shaped stop just outside each corner, turned with the battery
for sx in (-1, 1):
    for sy in (-1, 1):
        cx, cy = sx * (BATT['l'] / 2 + 0.4), sy * (BATT['w'] / 2 + 0.4)
        bar_x = box(5.0, 1.2, 2.5, cx - sx * 2.5 + sx * 1.2, cy + sy * 0.6, FLOOR - 0.01)
        bar_y = box(1.2, 5.0, 2.5, cx + sx * 0.6, cy - sy * 2.5 + sy * 1.2, FLOOR - 0.01)
        base += (bar_x + bar_y).rotate([0, 0, BATT_ANGLE]) ^ cyl(R_IN + 0.3, 10, 0)
# bayonet lugs with a 45 deg chamfer underneath (no support)
for a, w in LUGS:
    prof = CS([[(R_BODY - 0.3, LUG_Z0 - LUG_OUT), (R_BODY + LUG_OUT, LUG_Z0), (R_BODY + LUG_OUT, LUG_Z1), (R_BODY - 0.3, LUG_Z1)]])
    base += M.revolve(prof, SEG, w).rotate([0, 0, a - w / 2])
# bow arrow engraved on the outside above the key lug
arrow = CS([[(-3, 0), (3, 0), (0, 5)]]).extrude(3).rotate([90, 0, 0]).rotate([0, 0, 180]).translate([0, R_BODY + 1.4, 11])
base -= arrow
# name on the underside (mirrored so it reads from below)
base -= text_cs('WAKEBACK', 6.5, 0, -8).mirror([1, 0]).extrude(0.5).translate([0, 0, -0.01])
base -= text_cs('bow ^', 4.0, 0, 8).mirror([1, 0]).extrude(0.5).translate([0, 0, -0.01])

# ================================================================== LID (modelled in place, printed top-down)
Z_LID_TOP = Z_TOP + LID_TOP
Z_LID_BOT = Z_NECK + 0.3
lid = cyl(R_LID, Z_LID_TOP - Z_LID_BOT, Z_LID_BOT)
# internal thread: the base's neck, grown by the running clearance, cut out of the lid
lid -= thread(R_THREAD, Z_LID_BOT - 0.01, Z_TOP - Z_LID_BOT + 0.01, grow=THREAD_CLR)
# chamfered entry
lid -= cyl(R_THREAD + THREAD_E + THREAD_CLR + 1.0, 1.0, Z_LID_BOT - 0.01, r2=R_THREAD + THREAD_E + THREAD_CLR)
# grip flutes
for i in range(30):
    lid -= cyl(1.1, Z_LID_TOP - Z_LID_BOT - 1.2, Z_LID_BOT + 0.6, seg=24).translate([R_LID + 0.4, 0, 0]).rotate([0, 0, i * 12])
# name on top
lid -= text_cs('WAKEBACK', 8.0, 0, 0).extrude(0.6).translate([0, 0, Z_LID_TOP - 0.6])

# ================================================================== GPS BRIDGE (modelled in place, printed upside down)
PL = GPS['s'] + 1.0
plate = box(PL, PL, BRIDGE_T, GPS['cx'], GPS['cy'], Z_BRIDGE)
legs = [HOLES[0], HOLES[2]]
bridge = plate
for hx, hy in legs:
    bridge += cyl(3.2, Z_BRIDGE - Z_PCB_TOP + BRIDGE_T, Z_PCB_TOP, hx, hy, seg=48)
    bridge += M.hull(cyl(2.6, BRIDGE_T, Z_BRIDGE, hx, hy, seg=32) + cyl(2.6, BRIDGE_T, Z_BRIDGE,
                     min(max(hx, GPS['cx'] - PL / 2 + 3), GPS['cx'] + PL / 2 - 3), min(max(hy, GPS['cy'] - PL / 2 + 3), GPS['cy'] + PL / 2 - 3), seg=32))
    bridge -= cyl(SCREW_CLEAR / 2, 30, Z_PCB_TOP - 1, hx, hy, seg=32)
# lightening/wire window in the middle of the shelf
bridge -= box(12, 12, 5, GPS['cx'], GPS['cy'], Z_BRIDGE - 1)
bridge ^= cyl(R_NECK_IN - 0.6, 60, 0)

# ================================================================== LID-MOUNT (the same lid, plus bayonet lugs round the rim)
# For hanging the puck under a thwart: this lid twists into its own cradle, so the base (and its charging coil)
# hangs downwards. The lugs sit just under the top face, mirroring the base's lugs, with the chamfer on the
# top-face side so it still prints top-down without support.
# The lugs are placed mirrored (angle -a): turned upside down, the puck's port side becomes starboard, and the
# mirrored lugs then land in the cradle's windows at the same angles as the base's lugs do in the deck cradle.
lid_mount = lid
for a, w in LUGS:
    za, zb = Z_LID_TOP - LUG_Z1, Z_LID_TOP - LUG_Z0
    prof = CS([[(R_LID - 0.3, za), (R_LID + LUG_OUT, za), (R_LID + LUG_OUT, zb), (R_LID - 0.3, zb + LUG_OUT)]])
    lid_mount += M.revolve(prof, SEG, w).rotate([0, 0, -a - w / 2])
# a bow mark on the top face above the key lug (points to the bow once the puck is hung)
lid_mount -= CS([[(-2.5, 0), (0, -4), (2.5, 0)]]).extrude(0.8).translate([0, -(R_LID - 6.5), Z_LID_TOP - 0.8])


# ================================================================== CRADLE (a ring the puck drops into, lugs lock under windows)
def make_cradle(r_body, arrow=True, eye=True, preload=CR_PRELOAD, nib=True):
    """The puck's floor (or, upside down, the lid-mount's top face) rests on the floor ring; the three lugs go down
    the entry slots, TWIST deg anticlockwise of locked, and are twisted clockwise along a channel inside the wall.

    What makes it snap in rather than sit loose:
    - the channel ceiling ramps down over the last CR_RAMP deg to `preload` mm below the lug top, so the lug
      wedges the puck down onto the floor as it goes home (no up-and-down rattle);
    - the lug is stopped by the end wall only CR_END_GAP deg past home;
    - the outer wall along each channel is a spring tongue: a strip standing on the print bed, free at its top and
      along both faces, hanging off the solid wall past the end wall, with a ramped nib on its inside. The lug's
      corner pushes the tongue out as it goes home, the nib drops in behind it with a click, and the steeper back
      ramp holds it there, pressed against the end wall. The slit at the tongue's free end doubles as a drain.
    Everything prints as it comes: the tongue grows from the bed, the wall over it bridges between solid ends.
    Returns (cradle, nibs): the nibs separately so the twist sweep can measure how much they push."""
    r_in = r_body + CR_CLR                     # the puck body turns in here
    r_lug = r_body + LUG_OUT                   # outside of the lug
    r_ch = r_lug + CR_CLR                      # outside of the lug channel
    r_out = r_ch + CR_WALL                     # outside of the cradle
    r_face = r_ch + CR_TONGUE_GAP              # inside face of the spring tongue
    r_tip = r_lug - CR_NIB                     # the nib reaches this far into the lug
    cr = ring(20.0, r_out, CR_FLOOR) + ring(r_in, r_out, CR_H - CR_FLOOR, CR_FLOOR)
    nibs = M()
    lug_zlo = CR_FLOOR + LUG_Z0 - LUG_OUT - 0.4
    lug_zhi = CR_FLOOR + LUG_Z1 + 0.5
    z_lug_top = CR_FLOOR + LUG_Z1
    slit = math.degrees(CR_SLIT / (r_face + CR_TONGUE_T / 2))     # the end slit, as an angle
    for a, w in LUGS:
        wa = w + 2.0                                                # entry slot: 1 deg clear each side of the lug
        a_end = a - w / 2 - CR_END_GAP                              # end wall: twisted home, the lug stops here
        a_in0, a_in1 = a + TWIST - wa / 2, a + TWIST + wa / 2       # entry slot
        a_lock1 = a + w / 2 + 0.2                                   # lock zone runs from the end wall to here
        ramp = min(CR_RAMP, a_in0 - a_lock1 - 0.3)                  # the wide key lug leaves less room for the ramp
        a_root = a_end - (CR_TONGUE_EXT + 10 - w)                   # tongue root: same lever on every lug, wide or narrow
        # vertical entry slot through the inner wall (the lug never reaches the outer wall, which stays whole)
        cr -= sector(r_in - 1, r_ch, lug_zlo, CR_H + 1, a_in0, a_in1)
        # the channel the lug slides along, closed on the outside
        cr -= sector(r_in - 1, r_ch, lug_zlo, lug_zhi, a_end, a_in1)
        # lock zone ceiling, then the ramp up to the free channel in steps smaller than a print layer
        cr += sector(r_in, r_ch, z_lug_top - preload, lug_zhi + 0.01, a_end - 0.01, a_lock1)
        n = 6
        for i in range(n):
            zc = z_lug_top - preload + (i + 1) * (0.5 + preload) / (n + 1)
            cr += sector(r_in, r_ch, zc, lug_zhi + 0.01, a_lock1 + i * ramp / n - 0.01, a_lock1 + (i + 1) * ramp / n)
        # spring tongue: clear the outer wall from the bed up to CR_SLIT above the channel, from the root to just
        # past the entry edge (the end slit), then stand the tongue back up in the middle of that space
        cr -= sector(r_ch - 0.01, r_out + 1, -1, lug_zhi + CR_SLIT, a_root, a_in0 + slit)
        cr += sector(r_face, r_face + CR_TONGUE_T, 0, lug_zhi, a_root - 0.01, a_in0)
        if nib:
            # the nib, drawn with the tongue face along x = r_face and y along the channel (+y = towards the entry).
            # Its back ramp crosses the lug's outer radius at y = 0, which is placed on the lug's trailing corner at
            # home, so the ramp leans on that corner and holds the lug against the end wall.
            t_in, t_out = math.tan(math.radians(CR_NIB_IN)), math.tan(math.radians(CR_NIB_OUT))
            yb0 = -(r_face - r_lug) / t_out
            yb1 = yb0 + (r_face - r_tip) / t_out
            yf1 = yb1 + 0.4
            yf0 = yf1 + (r_face - r_tip) / t_in
            root = 0.6   # how far the nib's base runs into the tongue
            poly = CS([[(r_face + root, yf0 + root / t_in), (r_tip, yf1), (r_tip, yb1), (r_face + root, yb0 - root / t_out)]])
            z0, z1 = CR_FLOOR + LUG_Z0 - 0.4, z_lug_top - preload - 0.3   # clear of the lug's chamfer below, the ceiling above
            # 45 deg underneath so it prints: the full nib from z0 up, hulled with its base strip from (z0 - height) up
            base_strip = CS([[(r_face + root, yf0 + root / t_in), (r_face - 0.01, yf0), (r_face - 0.01, yb0), (r_face + root, yb0 - root / t_out)]])
            n3 = M.hull(poly.extrude(z1 - z0).translate([0, 0, z0]) + base_strip.extrude(z1 - z0 + (r_face - r_tip)).translate([0, 0, z0 - (r_face - r_tip)]))
            nibs += n3.rotate([0, 0, a + w / 2 - CR_END_GAP])
    cr += nibs
    # countersunk screw holes (No.6 / M3.5) and a strap slot either side
    rs = r_in - 9.0
    for a in (30, 150, 270):
        x, y = rs * math.cos(math.radians(a)), rs * math.sin(math.radians(a))
        cr -= cyl(2.0, CR_FLOOR + 1, -0.5, x, y, seg=32)
        cr -= cyl(2.0, 2.0, CR_FLOOR - 2.0 + 0.01, x, y, r2=4.0, seg=32)
    for a in (0, 180):
        cr -= box(4.0, 22.0, CR_FLOOR + 2, rs * math.cos(math.radians(a)), 0, -1)
    if eye:
        # lanyard eye on the stern side
        e = box(8, 6, 7, 0, -(r_out + 1.5), 0) - M.cylinder(10, 1.8, 1.8, 32).rotate([0, 90, 0]).translate([-5, -(r_out + 2.2), 3.5])
        cr += e
    if arrow:
        # bow arrow on the cradle rim
        cr -= CS([[(-3, 0), (3, 0), (0, 5)]]).extrude(1.0).translate([0, r_in + (r_out - r_in) / 2 - 2.5, CR_H - 0.6])
    return cr, nibs


cr, cr_nibs = make_cradle(R_BODY)
cr_lid, cr_lid_nibs = make_cradle(R_LID)
# the same cradles with no preload and no nibs: the twist sweep checks the lug runs freely along the channel
cr_free, _ = make_cradle(R_BODY, preload=0.0, nib=False)
cr_lid_free, _ = make_cradle(R_LID, preload=0.0, nib=False)
CR_R_IN, CR_R_OUT = R_BODY + CR_CLR, R_BODY + LUG_OUT + CR_CLR + CR_WALL   # (kept for the renders)


def hung(m):
    """A part of the closed puck, upside down with the lid-mount's top face on the lid cradle's floor."""
    return m.rotate([180, 0, 0]).translate([0, 0, CR_FLOOR + Z_LID_TOP])


# ================================================================== the insides, for fit checks
inside = {
    'battery': box(BATT['l'], BATT['w'], BATT['t'], 0, 0, FLOOR + COIL['t'], BATT_ANGLE),
    'Qi coil': box(COIL['l'], COIL['w'], COIL['t'], 0, 0, FLOOR, BATT_ANGLE),
    'Qi board': box(QI_BOARD['l'], QI_BOARD['w'], QI_BOARD['t'], QI_BOARD['x'], QI_BOARD['y'], FLOOR, BATT_ANGLE),
    'board': cyl(PCB_R, PCB_T, Z_PCB) - sum((cyl(1.35, 5, Z_PCB - 1, hx, hy, seg=24) for hx, hy in HOLES), M()),
    'TP4056': box(TP['l'], TP['w'], TP['h'], TP['cx'], TP['cy'], Z_PCB - TP['h']),
    'XIAO': box(XIAO['l'], XIAO['w'], XIAO['h'], XIAO['cx'], XIAO['cy'], Z_PCB_TOP),
    'IMU': box(IMU['l'], IMU['w'], IMU['h'], IMU['cx'], IMU['cy'], Z_PCB_TOP),
    'GPS': box(GPS['s'], GPS['s'], GPS['h'], GPS['cx'], GPS['cy'], Z_GPS),
}
# ================================================================== TPU GASKET (instead of the 70 x 2 O-ring)
# Flat ring that fills the groove, with a raised bead on top that the lid crushes. Printed in TPU, as modelled.
GK_CLR = 0.2             # gap each side in the groove, room for the squashed bead to go
GK_BEAD_H = 0.4          # bead stands this far above the rim face (two 0.2 mm layers)
GK_BEAD_W0, GK_BEAD_W1 = 1.6, 0.8
_g0, _g1 = ORING_R - ORING_W / 2 + GK_CLR, ORING_R + ORING_W / 2 - GK_CLR
gasket = M.revolve(CS([[(_g0, 0), (_g1, 0), (_g1, ORING_D), (ORING_R + GK_BEAD_W0 / 2, ORING_D),
                        (ORING_R + GK_BEAD_W1 / 2, ORING_D + GK_BEAD_H), (ORING_R - GK_BEAD_W1 / 2, ORING_D + GK_BEAD_H),
                        (ORING_R - GK_BEAD_W0 / 2, ORING_D)]]), SEG).translate([0, 0, Z_TOP - ORING_D])

parts = {'base': base, 'lid': lid, 'bridge': bridge, 'cradle': cr, 'lid_mount': lid_mount, 'cradle_lid': cr_lid}


def snap_report(name, puck_at, cradle, cradle_free, nibs, r_body):
    """How the cradle grips: ceiling preload on the lugs at home, and how far the nibs push as the lug twists past."""
    lug_top_area = sum(math.radians(w) * (r_body + LUG_OUT / 2 - 0.15) * (LUG_OUT + 0.3) for _, w in LUGS)
    home = (puck_at(0) ^ (cradle - nibs)).volume()
    print(f'  {name}: lugs wedged ~{home / lug_top_area:.2f} mm into the ceiling at home (preload {CR_PRELOAD} mm)')
    push = {t: (puck_at(t) ^ nibs).volume() for t in (TWIST, 6, 4, 3, 2, 1, 0.5, 0, -CR_END_GAP)}
    t_max = max(push, key=push.get)
    print(f'  {name}: nibs clear at entry ({push[TWIST]:.2f} mm3) and home against the end wall ({push[-CR_END_GAP]:.2f} mm3); '
          f'they overlap the lugs most at {t_max:g} deg before home ({push[t_max]:.1f} mm3, each tongue flexes ~{CR_NIB:.1f} mm)')
    return push[TWIST] < 0.05 and push[-CR_END_GAP] < 0.05 and push[t_max] > 1.0


def check():
    ok = True
    def clash(a, b, name, tol=0.05):
        nonlocal ok
        v = (a ^ b).volume()
        if v > tol:
            ok = False; print(f'  CLASH {name}: {v:.2f} mm3')
    for n, p in inside.items():
        for pn in ('base', 'lid', 'bridge'):
            if n == 'board' and pn == 'bridge':
                continue
            clash(p, parts[pn], f'{n} / {pn}')
    names = list(inside)
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            if {names[i], names[j]} in ({'Qi coil', 'battery'}, {'board', 'TP4056'}, {'board', 'XIAO'}, {'board', 'IMU'}):
                continue
            clash(inside[names[i]], inside[names[j]], f'{names[i]} / {names[j]}')
    clash(base, lid, 'base / lid')
    clash(base, bridge, 'base / bridge')
    clash(lid, bridge, 'lid / bridge')
    # puck in the cradle: drops in at the entry angle, twists freely along the channel, and the lock zone
    # (ceiling preload + nib) only bites in the last few degrees
    clash(base.rotate([0, 0, TWIST]).translate([0, 0, CR_FLOOR]), cr, 'base / cradle (entry)')
    for dz in (8, 4, 1):
        clash(base.rotate([0, 0, TWIST]).translate([0, 0, CR_FLOOR + dz]), cr, f'cradle drop-in at +{dz} mm')
    for t in (15, 10, 5, 0):
        clash(base.rotate([0, 0, t]).translate([0, 0, CR_FLOOR]), cr_free, f'cradle twist at {t} deg (free channel)')
    ok &= snap_report('deck cradle', lambda t: base.rotate([0, 0, t]).translate([0, 0, CR_FLOOR]), cr, cr_free, cr_nibs, R_BODY)
    # the lid must unscrew along its thread (anticlockwise = open) without hitting the base
    for th in (60, 180, 360, 720):
        clash(lid.rotate([0, 0, th]).translate([0, 0, th / 360 * PITCH]), base, f'lid unscrewed {th} deg')
        clash(lid_mount.rotate([0, 0, th]).translate([0, 0, th / 360 * PITCH]), base, f'lid-mount unscrewed {th} deg')
    for n, p in inside.items():
        clash(p, lid_mount, f'{n} / lid-mount')
    clash(base, lid_mount, 'base / lid-mount')
    # under the thwart: the closed puck hangs from the lid-mount in its own cradle
    clash(hung(base), cr_lid, 'base / lid cradle (locked)')
    clash(hung(lid_mount.rotate([0, 0, -TWIST])), cr_lid, 'lid-mount / lid cradle (entry)')
    for dz in (8, 4, 1):
        clash(hung(lid_mount.rotate([0, 0, -TWIST])).translate([0, 0, dz]), cr_lid, f'lid cradle drop-in at +{dz} mm')
    for t in (15, 10, 5, 0):
        clash(hung(lid_mount.rotate([0, 0, -t])), cr_lid_free, f'lid cradle twist at {t} deg (free channel)')
    ok &= snap_report('lid cradle', lambda t: hung(lid_mount.rotate([0, 0, -t])), cr_lid, cr_lid_free, cr_lid_nibs, R_LID)
    # the plain lid must not lock into the lid cradle's lug windows by accident (it just sits there), and the
    # lid-mount must still clear the deck cradle when the puck is used the normal way up
    clash(lid_mount.translate([0, 0, CR_FLOOR]), cr, 'lid-mount / deck cradle (puck locked, right way up)')
    gap = Z_TOP - (Z_GPS + GPS['h'])
    print(f'  GPS top to lid: {gap:.2f} mm (use a 1 mm foam pad)')
    print(f'  board underside to battery top: {Z_PCB - (FLOOR + COIL["t"] + BATT["t"]):.2f} mm (TP4056 is {TP["h"]} mm)')
    print(f'  O-ring squeeze: {2.0 - ORING_D:.2f} mm of 2.0 ({(2.0 - ORING_D) / 2 * 100:.0f} %)')
    clash(gasket, base, 'TPU gasket / base')
    ok = bool(ok)
    print(f'  TPU gasket: {_g1 - _g0:.1f} wide x {ORING_D + GK_BEAD_H:.1f} high, bead crushed {GK_BEAD_H:.1f} mm by the lid '
          f'({(gasket ^ lid).volume():.0f} mm3 squeezed, {(ring(_g0 - GK_CLR, _g1 + GK_CLR, ORING_D, Z_TOP - ORING_D) - gasket).volume():.0f} mm3 free in the groove)')
    return ok


def export(m, name, flip=False, lift=True):
    if flip:
        m = m.rotate([180, 0, 0])
    b = m.bounding_box()
    m = m.translate([0, 0, -b[2]]) if lift else m
    mesh = m.to_mesh()
    import trimesh
    t = trimesh.Trimesh(np.asarray(mesh.vert_properties)[:, :3], np.asarray(mesh.tri_verts), process=False)
    assert t.is_watertight, name
    t.export(os.path.join(OUT, name))
    return t


if __name__ == '__main__':
    for n, p in parts.items():
        assert p.status() == mf.Error.NoError, n
    print('fit checks:')
    good = check()
    print('  PASS' if good else '  FAIL')
    meshes = {
        'base': export(base, 'wakeback-base.stl'),
        'lid': export(lid, 'wakeback-lid.stl', flip=True),
        'bridge': export(bridge, 'wakeback-bridge.stl', flip=True),
        'cradle': export(cr, 'wakeback-cradle.stl'),
        'lid_mount': export(lid_mount, 'wakeback-lid-mount.stl', flip=True),
        'cradle_lid': export(cr_lid, 'wakeback-cradle-lid.stl'),
    }
    export(gasket, 'wakeback-gasket-tpu.stl')
    for n, p in parts.items():
        bb = p.bounding_box()
        print(f'  {n:7s} {bb[3]-bb[0]:.1f} x {bb[4]-bb[1]:.1f} x {bb[5]-bb[2]:.1f} mm, {p.volume()/1000:.1f} cm3 (~{p.volume()/1000*1.27:.0f} g PETG)')
    tot = (M.hull(base) + M.hull(lid)).volume()
    print(f'  closed puck displaces ~{tot/1000:.0f} cm3, so it floats with up to ~{tot/1000:.0f} g inside')
    import sys; sys.path.insert(0, HERE); import render; render.all(parts, inside, OUT, dict(Z_PCB=Z_PCB, Z_TOP=Z_TOP, TWIST=TWIST, CR_FLOOR=CR_FLOOR, Z_LID_TOP=Z_LID_TOP))
