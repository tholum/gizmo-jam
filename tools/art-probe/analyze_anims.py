"""Throwaway: per-frame hips/feet/top heights for each clip of a Meshy animation GLB."""
import sys
import bpy
from mathutils import Vector
src = sys.argv[sys.argv.index('--') + 1]
only = sys.argv[sys.argv.index('--') + 2:]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
scene = bpy.context.scene
arm = next(o for o in scene.objects if o.type == 'ARMATURE')
mesh = max((o for o in scene.objects if o.type == 'MESH'), key=lambda o: len(o.data.polygons))
print('FPS', scene.render.fps, 'ARM scale', tuple(arm.scale), 'rot', tuple(arm.rotation_euler), 'mesh parent', mesh.parent.name if mesh.parent else None, tuple(mesh.scale))
print('ROOTS', [(c.name, c.type, tuple(c.scale)) for c in scene.objects if c.parent is None])
hips = arm.pose.bones['Hips']
print('HIPS rest head', tuple(arm.matrix_world @ arm.data.bones['Hips'].head_local), 'rotation mode', hips.rotation_mode)
for action in bpy.data.actions:
    if only and action.name not in only: continue
    arm.animation_data.action = action
    try: arm.animation_data.action_slot = action.slots[0]
    except Exception as e: print('slot', e)
    start, end = action.frame_range
    print('ACTION', action.name, start, end)
    f = start
    while f <= end + 0.01:
        scene.frame_set(int(f), subframe=f - int(f))
        dg = bpy.context.evaluated_depsgraph_get()
        ev = mesh.evaluated_get(dg)
        me = ev.to_mesh()
        zs = [(ev.matrix_world @ v.co) for v in me.vertices]
        top = max(p.z for p in zs); low = min(p.z for p in zs)
        miny = min(p.y for p in zs); maxy = max(p.y for p in zs)
        ev.to_mesh_clear()
        h = arm.matrix_world @ hips.head
        print(f'  f{f:5.1f} hips=({h.x:+.2f},{h.y:+.2f},{h.z:.2f}) low={low:.2f} top={top:.2f} y=[{miny:+.2f},{maxy:+.2f}]')
        f += 2.0
