"""Reconstruct a continuous cortex from the licensed HRA segmented anatomy.
Asset preparation only. This is geometry processing, not a medical model.
"""
import io
from pathlib import Path
from urllib.request import urlopen
import numpy as np
import trimesh
from scipy.ndimage import gaussian_filter, binary_fill_holes
from skimage.measure import marching_cubes

root=Path(__file__).resolve().parents[1]
url='https://raw.githubusercontent.com/hubmapconsortium/hra-kg/main/digital-objects/ref-organ/brain-male/v1.3/raw/3d-vh-m-allen-brain.glb'
scene=trimesh.load(io.BytesIO(urlopen(url).read()),file_type='glb',force='scene')
for name in list(scene.geometry):
 if 'optic_chiasm' in name:scene.delete_geometry(name)
mesh=scene.to_mesh()
print('Bounds',mesh.extents,flush=True)
print('Original',len(mesh.faces),'faces',flush=True)
# Volumetric reconstruction removes intersecting segmentation boundaries and gives
# the rendering a continuous, smooth silhouette. Preserve sulci at sub-mm scale.
pitch=.00105
voxels=mesh.voxelized(pitch=pitch)
field=binary_fill_holes(voxels.matrix).astype(np.float32)
field=np.pad(field,3)
field=gaussian_filter(field,sigma=1.0)
verts,faces,normals,_=marching_cubes(field,level=.4,spacing=(pitch,pitch,pitch))
verts=verts+voxels.translation-3*pitch
smooth=trimesh.Trimesh(vertices=verts,faces=faces,process=True)
smooth.fix_normals()
print('Before smoothing',smooth.extents,flush=True)
# Light tangential smoothing removes voxel stepping while retaining gyri.
offset=smooth.bounds.mean(axis=0);smooth.vertices-=offset
trimesh.smoothing.filter_taubin(smooth,lamb=.35,nu=.37,iterations=4)
print('After smoothing',smooth.extents,flush=True)
smooth.vertices+=offset
(root/'.data').mkdir(exist_ok=True)
(root/'.data/brain-smooth.glb').write_bytes(smooth.export(file_type='glb'))
print('Reconstructed',len(smooth.faces),'faces',flush=True)
