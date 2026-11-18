"""Assemble the game-ready robot runner from the Meshy rig and animation downloads.

  blender --background --python-exit-code 1 --python tools/build_runner.py

Reads tools/meshy-source/robot/{anims_core,anims_extra}.glb and the textures
written by tools/runner_textures.py; writes assets/meshy/runner.glb with one
skinned mesh, a 24-bone skeleton and the clips listed in CLIPS.

Meshy's library clips are re-baked at 30 fps into game clips: travel is removed
(the runners run in place on a moving belt), ground poses are snapped to the
floor, and the jump keeps only its pose: the game adds the jump arc itself from
the simulation's jump clock, so the clip is seeked by normalised jump time.

Meshy's automatic skin weights bend the robot's boxes like rubber, so the shell
parts (head, torso, hands, boots) are re-bound rigidly to one bone each; only
the dark joint tubes keep smooth weights.
"""
from pathlib import Path
import math
import bpy
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'tools/meshy-source/robot'
DEST = ROOT / 'assets/meshy/runner.glb'
FPS = 30

# name: (source action, first frame, last frame, output seconds, options)
#   in_place   pin the hips' horizontal position to the rest pose
#   ground     lift the pose so the lowest vertex rests on the floor
#   airborne   remove the ballistic rise of the hips (jump arc comes from code)
#   pingpong   play the range forwards then backwards (seamless hold loops)
CLIPS = {
    'idle': ('Idle_02', 0, 56, 56 / 30, {'in_place'}),
    'jog': ('Run_02', 0, 21, 21 / 30, {'in_place'}),
    'run': ('RunFast', 0, 14, 14 / 30, {'in_place'}),
    'jump': ('Jump_Over_Obstacle_2', 4, 17, 1.0, {'in_place', 'airborne'}),
    'duck': ('slide_right', 19, 25, 0.8, {'in_place', 'ground', 'pingpong'}),
    'hit': ('Hit_Reaction', 1, 26, 25 / 30, {'in_place'}),
    'hit_low': ('Hit_Reaction_to_Waist', 4, 34, 30 / 30, {'in_place'}),
    'victory': ('Cheer_with_Both_Hands_Up', 0, 56, 56 / 30, {'in_place'}),
    'knockdown': ('Knock_Down', 0, 75, 75 / 30, {'ground_soft'}),
}


def import_glb(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    return [o for o in bpy.data.objects if o not in before]


def assign(arm, action):
    arm.animation_data_create()
    arm.animation_data.action = action
    if action is not None and getattr(action, 'slots', None):
        arm.animation_data.action_slot = action.slots[0]


def lowest(scene, mesh):
    dg = bpy.context.evaluated_depsgraph_get()
    ev = mesh.evaluated_get(dg)
    data = ev.to_mesh()
    low = min((ev.matrix_world @ v.co).z for v in data.vertices)
    ev.to_mesh_clear()
    return low


MERGE = {'Spine': 'Spine02', 'Spine01': 'Spine02', 'LeftShoulder': 'Spine02', 'RightShoulder': 'Spine02',
         'LeftToeBase': 'LeftFoot', 'RightToeBase': 'RightFoot', 'head_end': 'Head', 'headfront': 'Head'}
RIGID = ['Head', 'Spine02', 'LeftHand', 'RightHand', 'LeftFoot', 'RightFoot']


def rigidify(mesh):
    """Bind shell vertices to a single bone so boxes stay boxes."""
    import numpy as np
    image = bpy.data.images.load(str(SRC / 'out/runner_mask.png'))
    w, h = image.size
    pixels = np.array(image.pixels[:], dtype=np.float32).reshape(h, w, 4)
    data = mesh.data
    uv_layer = data.uv_layers.active.data
    shell = [0.0] * len(data.vertices)
    for loop in data.loops:
        uv = uv_layer[loop.index].uv
        x = min(w - 1, max(0, int(uv.x * w)))
        y = min(h - 1, max(0, int(uv.y * h)))
        shell[loop.vertex_index] = max(shell[loop.vertex_index], float(pixels[y, x, 0]))
    names = {g.index: g.name for g in mesh.vertex_groups}
    groups = {g.name: g for g in mesh.vertex_groups}
    rigid = 0
    for v in data.vertices:
        weights = {}
        is_shell = shell[v.index] > 0.5
        for g in v.groups:
            name = MERGE.get(names[g.group], names[g.group])
            # The torso box is one moulded piece: its lower half must not
            # stay behind with the hips while the chest turns.
            if is_shell and name == 'Hips':
                name = 'Spine02'
            weights[name] = weights.get(name, 0.0) + g.weight
        total = sum(weights.values()) or 1.0
        weights = {k: x / total for k, x in weights.items()}
        best = max(RIGID, key=lambda n: weights.get(n, 0.0))
        top = weights.get(best, 0.0)
        if top >= 0.5 or (is_shell and top >= 0.25):
            weights = {best: 1.0}
            rigid += 1
        for g in list(v.groups):
            mesh.vertex_groups[g.group].remove([v.index])
        for name, x in weights.items():
            if x > 0.001:
                groups[name].add([v.index], x, 'REPLACE')
    bpy.data.images.remove(image)
    print('RIGID', rigid, 'of', len(data.vertices), 'vertices')


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.fps = FPS
    core = import_glb(SRC / 'anims_core.glb')
    arm = next(o for o in core if o.type == 'ARMATURE')
    mesh = max((o for o in core if o.type == 'MESH'), key=lambda o: len(o.data.polygons))
    for obj in core:
        if obj not in (arm, mesh):
            bpy.data.objects.remove(obj, do_unlink=True)
    for obj in import_glb(SRC / 'anims_extra.glb'):
        bpy.data.objects.remove(obj, do_unlink=True)
    rigidify(mesh)
    sources = {a.name: a for a in bpy.data.actions}
    print('SOURCES', sorted(sources))
    bones = list(arm.pose.bones)
    hips = arm.pose.bones['Hips']
    for pb in bones:
        pb.rotation_mode = 'QUATERNION'
    scale = arm.matrix_world.to_scale().z
    rest_hips = arm.data.bones['Hips'].head_local.copy()  # armature space

    rest = {pb.name: pb.bone.matrix_local.copy() for pb in bones}
    baked = {}
    for name, (source, first, last, seconds, flags) in CLIPS.items():
        assign(arm, sources[source])
        count = max(2, int(round(seconds * FPS)) + 1)
        frames = []
        for i in range(count):
            u = i / (count - 1)
            if 'pingpong' in flags:
                u = 1.0 - abs(2.0 * u - 1.0)
                u = u * u * (3 - 2 * u)
            f = first + (last - first) * u
            scene.frame_set(int(math.floor(f)), subframe=f - math.floor(f))
            bpy.context.view_layer.update()
            pose = {pb.name: pb.matrix.copy() for pb in bones}
            low = lowest(scene, mesh) if ('ground' in flags or 'ground_soft' in flags) else 0.0
            frames.append({'u': i / (count - 1), 'pose': pose, 'hips': hips.matrix.copy(), 'low': low})
        # Root adjustments happen in armature space on the hips matrix.
        zs = [fr['hips'].translation.z for fr in frames]
        if 'airborne' in flags:
            line = [zs[0] + (zs[-1] - zs[0]) * fr['u'] for fr in frames]
            peak = max(z - l for z, l in zip(zs, line))
            for fr, l in zip(frames, line):
                fr['hips'].translation.z -= math.sin(fr['u'] * math.pi) * peak
        if 'in_place' in flags:
            for fr in frames:
                fr['hips'].translation.x = rest_hips.x
                fr['hips'].translation.y = rest_hips.y
        for fr in frames:
            if 'ground' in flags or ('ground_soft' in flags and fr['low'] < 0.0):
                fr['hips'].translation.z -= fr['low'] / scale
        baked[name] = (frames, flags)

    # Drop the importer's stashed source tracks before writing game clips.
    assign(arm, None)
    for track in list(arm.animation_data.nla_tracks):
        arm.animation_data.nla_tracks.remove(track)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)
    scene.frame_set(0)

    # Write each clip as a fresh action. Local channels are computed directly
    # from the sampled matrices and keyed at once: nothing re-evaluates the
    # half-written action in between.
    final = {}
    for name, (frames, flags) in baked.items():
        action = bpy.data.actions.new(name)
        arm.animation_data.action = action
        previous = {}
        for i, fr in enumerate(frames):
            for pb in bones:
                if pb.parent is None:
                    target = fr['hips'] if pb.name == 'Hips' else fr['pose'][pb.name]
                    basis = rest[pb.name].inverted() @ target
                else:
                    local = fr['pose'][pb.parent.name].inverted() @ fr['pose'][pb.name]
                    rest_local = rest[pb.parent.name].inverted() @ rest[pb.name]
                    basis = rest_local.inverted() @ local
                q = basis.to_quaternion()
                if pb.name in previous and previous[pb.name].dot(q) < 0.0:
                    q.negate()
                previous[pb.name] = q
                pb.rotation_quaternion = q
                pb.keyframe_insert('rotation_quaternion', frame=i)
                if pb.name == 'Hips':
                    pb.location = basis.to_translation()
                    pb.keyframe_insert('location', frame=i)
        final[name] = action
        if getattr(action, 'slots', None):
            arm.animation_data.action_slot = action.slots[0]
        print('CLIP', name, len(frames), 'frames')

    arm.animation_data.action = None
    for pb in bones:
        pb.matrix_basis = Matrix.Identity(4)
    for name, action in final.items():
        track = arm.animation_data.nla_tracks.new()
        track.name = name
        strip = track.strips.new(name, 0, action)
        strip.name = name
        track.mute = False

    # One material carrying the tintable albedo and the mask map; the game
    # replaces it with its own shader but reads both textures from it.
    material = bpy.data.materials.new('runner')
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    bsdf = next(n for n in nodes if n.type == 'BSDF_PRINCIPLED')
    albedo = nodes.new('ShaderNodeTexImage')
    albedo.image = bpy.data.images.load(str(SRC / 'out/runner_albedo.png'))
    links.new(albedo.outputs['Color'], bsdf.inputs['Base Color'])
    mask = nodes.new('ShaderNodeTexImage')
    mask.image = bpy.data.images.load(str(SRC / 'out/runner_mask.png'))
    mask.image.colorspace_settings.name = 'Non-Color'
    links.new(mask.outputs['Color'], bsdf.inputs['Emission Color'])
    bsdf.inputs['Emission Strength'].default_value = 1.0
    bsdf.inputs['Roughness'].default_value = 0.5
    bsdf.inputs['Metallic'].default_value = 0.0
    mesh.data.materials.clear()
    mesh.data.materials.append(material)
    mesh.name = 'Runner'
    mesh.data.name = 'Runner'
    arm.name = 'Rig'
    for polygon in mesh.data.polygons:
        polygon.use_smooth = True
    triangles = sum(len(p.vertices) - 2 for p in mesh.data.polygons)
    DEST.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=str(DEST), export_format='GLB', export_image_format='AUTO',
        export_animations=True, export_animation_mode='NLA_TRACKS', export_force_sampling=True,
        export_optimize_animation_size=True, export_anim_slide_to_zero=True,
        export_skins=True, export_all_influences=False, export_def_bones=False,
        export_cameras=False, export_lights=False, export_yup=True, export_apply=False,
        export_tangents=False, export_morph=False)
    print('RUNNER', triangles, 'triangles', len(mesh.data.vertices), 'vertices', DEST.stat().st_size, 'bytes')


main()
