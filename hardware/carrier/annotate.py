"""Step-by-step assembly pictures for the build guide: the board with each step's area highlighted."""
import runpy, os, io, contextlib
with contextlib.redirect_stdout(io.StringIO()):
    G = runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'gen_carrier.py'))
import matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
from shapely.geometry import Point, box
from shapely.ops import unary_union
draw, BOARD, POUR, copper, pads, pad_geom, holes, vias, SILK, OUT = (G[k] for k in ['draw', 'BOARD', 'POUR', 'copper', 'pads', 'pad_geom', 'holes', 'vias', 'SILK', 'OUT'])
VIA_DRILL = G['VIA_DRILL']

def board(ax, side, dim=False):
    ax.set_facecolor('white')
    draw(ax, BOARD, facecolor='#1f5c3a', edgecolor='none')
    cu = unary_union([g for n, g in copper(side)] + ([POUR] if side == 'B' else []))
    draw(ax, cu, facecolor='#3f8f5c', edgecolor='none')
    draw(ax, unary_union([pad_geom(p) for p in pads if side in p['layers']]), facecolor='#d4a84a', edgecolor='none')
    for x, y, d in holes: draw(ax, Point(x, y).buffer(d / 2), facecolor='white', edgecolor='none')
    for p in pads:
        if p['drill']: draw(ax, Point(p['x'], p['y']).buffer(p['drill'] / 2), facecolor='#222', edgecolor='none')
    draw(ax, SILK[side], facecolor='#f4f4f4', edgecolor='none')
    if dim: draw(ax, BOARD, facecolor=(1, 1, 1, 0.55), edgecolor='none')

def fig(name, side, boxes, title):
    f, ax = plt.subplots(figsize=(6, 6.4), dpi=130)
    board(ax, side)
    focus = unary_union([box(x0, y0, x1, y1) for x0, y0, x1, y1 in boxes])
    draw(ax, BOARD.difference(focus), facecolor=(1, 1, 1, 0.6), edgecolor='none')
    for x0, y0, x1, y1 in boxes:
        ax.add_patch(plt.Rectangle((x0, y0), x1 - x0, y1 - y0, fill=False, lw=3, ec='#e8590c', zorder=10))
    ax.set_xlim(-32, 32); ax.set_ylim(-32, 32); ax.set_aspect('equal'); ax.axis('off')
    if side == 'B': ax.invert_xaxis()
    ax.set_title(title, fontsize=15, fontweight='bold', color='#e8590c', pad=6)
    f.savefig(os.path.join(OUT, name), bbox_inches='tight', facecolor='white'); plt.close(f)

fig('step-parts.png', 'F', [(-26, -17.4, -10.2, -5.6)], 'Step 1: resistors and LED (top)')
fig('step-xiao.png', 'F', [(-25.6, -6.6, -0.4, 12.6)], 'Step 2: XIAO (top)')
fig('step-gps.png', 'F', [(-9.6, 17.4, 1.9, 22.8)], 'Step 4: GPS pads (top)')
fig('step-imu.png', 'F', [(1.4, -15.2, 26.0, 16.2)], 'Step 5: IMU (top)')
fig('step-power.png', 'F', [(-21.8, -27.2, -0.4, -15.9)], 'Steps 6-7: power pads (top)')
fig('step-bottom.png', 'B', [(-1.5, -5.4, 25.5, 11.4), (-21.8, -27.2, -0.4, -15.9)], 'Underneath: TP4056 spot and power pads')
print('annotated images written')
