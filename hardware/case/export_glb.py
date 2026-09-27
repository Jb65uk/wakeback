"""Write the assembled case and its contents as one GLB for the 3D viewer page."""
import os, sys, base64
import numpy as np, trimesh
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_case as g

COL = {'base': '#3f7fa8', 'lid': '#e0a800', 'bridge': '#d9534f', 'cradle': '#707a84',
       'battery': '#5b8c3a', 'Qi coil': '#b87333', 'Qi board': '#8e44ad', 'board': '#1f5c3a',
       'TP4056': '#2c3e50', 'XIAO': '#3b4a5a', 'IMU': '#8a9699', 'GPS': '#b03a2e'}

def tm(m, simplify=None):
    if simplify: m = m.simplify(simplify)
    x = m.to_mesh()
    return trimesh.Trimesh(np.asarray(x.vert_properties)[:, :3], np.asarray(x.tri_verts), process=True)

scene = trimesh.Scene()
items = dict(g.parts); items['cradle'] = g.cr.translate([0, 0, -g.CR_FLOOR])
items.update(g.inside)
for name, m in items.items():
    t = tm(m, 0.02 if name in ('base', 'lid') else None)
    c = [int(COL[name][i:i + 2], 16) for i in (1, 3, 5)] + [255]
    t.visual = trimesh.visual.TextureVisuals(material=trimesh.visual.material.PBRMaterial(
        baseColorFactor=c, metallicFactor=0.0, roughnessFactor=0.75))
    scene.add_geometry(t, node_name=name, geom_name=name)
data = scene.export(file_type='glb')
out = os.path.join(g.OUT, 'wakeback-case.glb')
open(out, 'wb').write(data)
print(len(data) / 1e6, 'MB')
