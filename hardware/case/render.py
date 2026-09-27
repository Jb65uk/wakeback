"""Preview pictures for the WakeBack case: exploded 3D view, a cut through the middle, and two plan slices."""
import os
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon as MPoly
from mpl_toolkits.mplot3d.art3d import Poly3DCollection

CASE_COL = {'base': '#3d7ea6', 'lid': '#e0a800', 'bridge': '#d9534f', 'cradle': '#6c757d', 'lid_mount': '#c99700', 'cradle_lid': '#6c757d'}
IN_COL = {'battery': '#5b8c3a', 'Qi coil': '#b87333', 'Qi board': '#8e44ad', 'board': '#1f5c3a',
          'TP4056': '#2c3e50', 'XIAO': '#34495e', 'IMU': '#7f8c8d', 'GPS': '#c0392b'}


def _mesh(m, max_tris=60000):
    if m.num_tri() > max_tris:
        m = m.simplify(0.08)
    g = m.to_mesh()
    return np.asarray(g.vert_properties)[:, :3], np.asarray(g.tri_verts)


def _draw3d(ax, m, col, dz=0.0, alpha=1.0):
    v, t = _mesh(m)
    v = v + [0, 0, dz]
    tris = v[t]
    n = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-12
    light = np.array([0.4, -0.5, 0.75]); light /= np.linalg.norm(light)
    shade = 0.45 + 0.55 * np.clip(n @ light, 0, 1)
    base = np.array(matplotlib.colors.to_rgb(col))
    fc = np.clip(base[None, :] * shade[:, None], 0, 1)
    pc = Poly3DCollection(tris, facecolors=fc, edgecolors='none', alpha=alpha)
    ax.add_collection3d(pc)


def exploded(parts, inside, out, K):
    fig = plt.figure(figsize=(9, 10), dpi=110)
    ax = fig.add_subplot(111, projection='3d')
    _draw3d(ax, parts['cradle'], CASE_COL['cradle'], -30)
    _draw3d(ax, parts['base'], CASE_COL['base'], 0)
    for n in ('board', 'XIAO', 'IMU', 'battery'):
        _draw3d(ax, inside[n], IN_COL[n], 0)
    _draw3d(ax, parts['bridge'], CASE_COL['bridge'], 22)
    _draw3d(ax, inside['GPS'], IN_COL['GPS'], 22)
    _draw3d(ax, parts['lid'], CASE_COL['lid'], 45)
    ax.set_xlim(-50, 50); ax.set_ylim(-50, 50); ax.set_zlim(-35, 85)
    ax.set_box_aspect((1, 1, 1.2)); ax.view_init(24, -60); ax.set_axis_off()
    ax.set_title('WakeBack case, exploded: cradle, base (with board and battery), GPS shelf, lid', fontsize=11)
    fig.savefig(os.path.join(out, 'case-exploded.png'), bbox_inches='tight', facecolor='white'); plt.close(fig)


def _polys(ax, cs, col, alpha=1.0, z=1, ec='none'):
    """Fill a cross-section, holes included (even-odd compound path)."""
    from matplotlib.path import Path
    from matplotlib.patches import PathPatch
    verts, codes = [], []
    for p in cs.to_polygons():
        p = np.asarray(p)
        if len(p) < 3:
            continue
        verts += list(p) + [p[0]]
        codes += [Path.MOVETO] + [Path.LINETO] * (len(p) - 1) + [Path.CLOSEPOLY]
    if verts:
        ax.add_patch(PathPatch(Path(np.asarray(verts), codes), facecolor=col, edgecolor=ec, lw=0.4, alpha=alpha, zorder=z))


def section(parts, inside, out, K, y=3.0):
    """Vertical cut along the plane y = const (through the XIAO, IMU and GPS), viewed from the stern."""
    fig, ax = plt.subplots(figsize=(10, 5.4), dpi=120)
    def cut(m):
        # rotate so the plane y=const becomes z=0, then slice: result coords are (x, z)
        return m.translate([0, -y, 0]).rotate([-90, 0, 0]).slice(0.0)
    for n, m in inside.items():
        _polys(ax, cut(m), IN_COL[n], 0.9, 2)
    for n in ('base', 'lid', 'bridge'):
        _polys(ax, cut(parts[n]), CASE_COL[n], 1.0, 3)
    for n, (x, z) in {'battery': (-8, 5), 'board': (-28, K['Z_PCB'] + 0.3), 'XIAO': (-13.8, 22), 'IMU': (13.5, 18.5),
                      'GPS': (12.5, 30), 'TP4056': (12, 11), 'Qi coil': (26, 1.9)}.items():
        ax.annotate(n, (x, z), color='white' if n not in ('Qi coil',) else 'black', fontsize=8, ha='center', va='center', zorder=5)
    ax.annotate('O-ring', (36, K['Z_TOP']), xytext=(48, 40), fontsize=8, arrowprops=dict(arrowstyle='-', lw=0.6))
    ax.set_aspect('equal'); ax.set_xlim(-50, 50); ax.set_ylim(-3, 42)
    ax.set_xlabel('mm (port <-> starboard, looking forward)'); ax.set_ylabel('mm')
    ax.grid(alpha=0.25)
    ax.set_title(f'Cut through the closed puck at y = {y:g} mm: base (blue), lid (yellow), GPS shelf (red)', fontsize=10)
    fig.savefig(os.path.join(out, 'case-section.png'), bbox_inches='tight', facecolor='white'); plt.close(fig)


def plans(parts, inside, out, K):
    fig, axs = plt.subplots(1, 2, figsize=(12, 6.2), dpi=110)
    for ax, z, title, show in [(axs[0], 3.5, 'Floor level (z = 3.5): battery, Qi board, standoffs', ('battery', 'Qi board')),
                               (axs[1], K['Z_PCB'] - 2.0, f'Just under the board (z = {K["Z_PCB"] - 2:.1f}): TP4056', ('TP4056', 'battery'))]:
        for n in show:
            _polys(ax, inside[n].slice({'battery': min(z, 5.0), 'Qi board': 2.4}.get(n, z)), IN_COL[n], 0.55, 1)
        _polys(ax, parts['base'].slice(z), CASE_COL['base'], 1.0, 2)
        ax.add_patch(plt.Circle((0, 0), 30, fill=False, ls='--', lw=0.8, color='#1f5c3a'))
        ax.annotate('board outline', (0, -30), xytext=(0, -33.5), ha='center', fontsize=8, color='#1f5c3a')
        ax.arrow(-8, 30, 0, 6, width=0.6, color='k'); ax.text(-6.5, 33, 'bow', fontsize=8)
        ax.set_aspect('equal'); ax.set_xlim(-46, 46); ax.set_ylim(-46, 46); ax.set_title(title, fontsize=10); ax.grid(alpha=0.25)
    fig.savefig(os.path.join(out, 'case-plans.png'), bbox_inches='tight', facecolor='white'); plt.close(fig)


def cradle(parts, out, K):
    fig = plt.figure(figsize=(8, 6), dpi=110)
    ax = fig.add_subplot(111, projection='3d')
    _draw3d(ax, parts['cradle'], CASE_COL['cradle'])
    ax.set_xlim(-48, 48); ax.set_ylim(-48, 48); ax.set_zlim(-20, 30)
    ax.set_box_aspect((1, 1, 0.52)); ax.view_init(35, -65); ax.set_axis_off()
    ax.set_title(f'Deck cradle: drop the puck in {K["TWIST"]:g}° anticlockwise of the arrow, twist clockwise to lock', fontsize=10)
    fig.savefig(os.path.join(out, 'case-cradle.png'), bbox_inches='tight', facecolor='white'); plt.close(fig)


def thwart(parts, out, K):
    """Under the thwart: the lid cradle screwed to the underside, the puck hanging from its lid-mount."""
    fig = plt.figure(figsize=(8, 7), dpi=110)
    ax = fig.add_subplot(111, projection='3d')
    def hung(m): return m.rotate([180, 0, 0]).translate([0, 0, K['CR_FLOOR'] + K['Z_LID_TOP']])
    # draw it the way it hangs: flip the whole assembly so the cradle is at the top
    def flip(m): return m.rotate([180, 0, 0])
    _draw3d(ax, flip(parts['cradle_lid']), CASE_COL['cradle'])
    _draw3d(ax, flip(hung(parts['lid_mount'])), CASE_COL['lid_mount'])
    _draw3d(ax, flip(hung(parts['base'])), CASE_COL['base'])
    ax.set_xlim(-50, 50); ax.set_ylim(-50, 50); ax.set_zlim(-52, 8)
    ax.set_box_aspect((1, 1, 0.6)); ax.view_init(20, -60); ax.set_axis_off()
    ax.set_title('Under a thwart: lid cradle screwed to the underside, puck hangs by its lid-mount (lid up, coil down)', fontsize=9)
    fig.savefig(os.path.join(out, 'case-thwart.png'), bbox_inches='tight', facecolor='white'); plt.close(fig)


def all(parts, inside, out, K):
    exploded(parts, inside, out, K)
    section(parts, inside, out, K)
    plans(parts, inside, out, K)
    cradle(parts, out, K)
    thwart(parts, out, K)
    print('  previews written')
