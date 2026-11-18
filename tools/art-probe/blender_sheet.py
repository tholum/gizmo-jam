"""Throwaway QA: render frames of a GLB's animations into a contact sheet.
blender --background --python tools/art-probe/blender_sheet.py -- in.glb out_dir [frames] [yaw_deg]
"""
import sys, math
import bpy
from mathutils import Vector
args = sys.argv[sys.argv.index('--') + 1:]
src, out = args[0], args[1]
count = int(args[2]) if len(args) > 2 else 8
yaw = float(args[3]) if len(args) > 3 else 35.0
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
scene = bpy.context.scene
meshes = [o for o in scene.objects if o.type == 'MESH']
for o in list(meshes):
    if o.name.startswith('Icosphere'):
        o.hide_render = True
body = [o for o in meshes if not o.name.startswith('Icosphere')]
arm = next((o for o in scene.objects if o.type == 'ARMATURE'), None)
print('MESHES', [(m.name, len(m.data.polygons), len(m.data.vertices)) for m in meshes])
if arm:
    print('BONES', len(arm.data.bones), [b.name for b in arm.data.bones])
print('ACTIONS', [(a.name, tuple(a.frame_range)) for a in bpy.data.actions])
lo = Vector((1e9,) * 3); hi = Vector((-1e9,) * 3)
for m in body:
    for c in m.bound_box:
        w = m.matrix_world @ Vector(c)
        lo = Vector(map(min, lo, w)); hi = Vector(map(max, hi, w))
print('BOUNDS', tuple(lo), tuple(hi))
size = max(hi - lo)
center = (lo + hi) / 2
cam_data = bpy.data.cameras.new('cam'); cam_data.type = 'ORTHO'; cam_data.ortho_scale = size * 1.5
cam = bpy.data.objects.new('cam', cam_data); scene.collection.objects.link(cam); scene.camera = cam
a = math.radians(yaw)
cam.location = center + Vector((math.sin(a) * 10 * size, -math.cos(a) * 10 * size, 3.0 * size))
cam_offset = cam.location - center
follow = True
only = args[4].split(',') if len(args) > 4 else None
direction = center - cam.location
cam.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
cam_data.clip_end = 1000 * size
sun = bpy.data.objects.new('sun', bpy.data.lights.new('sun', 'SUN')); scene.collection.objects.link(sun)
sun.rotation_euler = (math.radians(50), 0, math.radians(30)); sun.data.energy = 3
scene.render.engine = 'BLENDER_WORKBENCH'
scene.display.shading.light = 'STUDIO'
scene.display.shading.color_type = 'TEXTURE'
for mat in bpy.data.materials:
    if mat.use_nodes:
        for n in mat.node_tree.nodes:
            if n.type == 'TEX_IMAGE' and n.image and 'albedo' in n.image.name: mat.node_tree.nodes.active = n
scene.render.resolution_x = 320; scene.render.resolution_y = 320
scene.render.film_transparent = False
if scene.world is None: scene.world = bpy.data.worlds.new('w')
for action in (bpy.data.actions if bpy.data.actions else [None]):
    if only and action and action.name not in only: continue
    if action and arm:
        arm.animation_data_create()
        arm.animation_data.action = action
        try:
            arm.animation_data.action_slot = action.slots[0]
        except Exception as e:
            print('slot', e)
        start, end = action.frame_range
    else:
        start, end = 1, 1
    for i in range(count):
        frame = start + (end - start) * i / max(count - 1, 1)
        scene.frame_set(int(round(frame)))
        if arm and follow:
            h = arm.matrix_world @ arm.pose.bones['Hips'].head
            cam.location = Vector((h.x, h.y, center.z)) + cam_offset
        scene.render.filepath = f"{out}/{(action.name if action else 'rest').replace('|', '_').replace(' ', '_')}_{i:02d}.png"
        bpy.ops.render.render(write_still=True)
