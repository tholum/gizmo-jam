#!/usr/bin/env python3
"""Turn the Meshy robot base colour into a tintable albedo plus a mask map.

The robot was generated with one strongly keyed body colour (pure red) on
otherwise neutral parts, so team colours are a per-instance shader tint:

  albedo.rgb  neutral colours; keyed body texels are replaced by their value
  mask.r      body shell: multiplied by the team colour at runtime
  mask.g      emissive: the screen eyes, and (with mask.r) the antenna tip
  mask.b      glossy face-screen glass

UV islands are dilated before downsampling so mipmaps do not bleed across the
fragmented atlas. Usage (system Python, numpy + Pillow + scipy):

  python3 -I tools/runner_textures.py
"""
import json
import struct
import sys
from pathlib import Path

import site
site.addsitedir(site.getusersitepackages())  # -I hides the user site; scipy may live there
import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'tools/meshy-source/robot'
OUT = SRC / 'out'
SIZE = 2048
FINAL = 1024
TIP_HEIGHT = 0.945  # fraction of the model height where the antenna ball starts


def read_glb(path):
    raw = path.read_bytes()
    length = struct.unpack_from('<I', raw, 12)[0]
    doc = json.loads(raw[20:20 + length])
    binary = raw[28 + length:]
    dtypes = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
    widths = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}

    def accessor(index):
        acc = doc['accessors'][index]
        view = doc['bufferViews'][acc['bufferView']]
        dtype = np.dtype(dtypes[acc['componentType']])
        width = widths[acc['type']]
        offset = view.get('byteOffset', 0) + acc.get('byteOffset', 0)
        stride = view.get('byteStride', dtype.itemsize * width)
        if stride == dtype.itemsize * width:
            data = np.frombuffer(binary, dtype, acc['count'] * width, offset)
        else:
            data = np.concatenate([np.frombuffer(binary, dtype, width, offset + i * stride) for i in range(acc['count'])])
        data = data.reshape(acc['count'], width).astype(np.float64 if dtype == np.float32 else np.int64)
        if acc.get('normalized'):
            data = data / np.iinfo(dtype).max
        return data

    best = max((p for m in doc['meshes'] for p in m['primitives']),
               key=lambda p: doc['accessors'][p['attributes']['POSITION']]['count'])
    pos = accessor(best['attributes']['POSITION'])
    uv = accessor(best['attributes']['TEXCOORD_0'])
    idx = accessor(best['indices']).reshape(-1, 3).astype(np.int64)
    return pos, uv, idx


def rasterise(pos, uv, idx):
    """Per-texel rest position and coverage for the UV atlas."""
    posmap = np.zeros((SIZE, SIZE, 3), np.float32)
    cover = np.zeros((SIZE, SIZE), bool)
    px = uv.copy()
    px[:, 0] = uv[:, 0] * SIZE - 0.5
    px[:, 1] = uv[:, 1] * SIZE - 0.5  # glTF UV origin is top-left, like image rows
    for tri in idx:
        a, b, c = px[tri]
        lo = np.floor(np.minimum(np.minimum(a, b), c)).astype(int) - 1
        hi = np.ceil(np.maximum(np.maximum(a, b), c)).astype(int) + 1
        lo = np.clip(lo, 0, SIZE - 1)
        hi = np.clip(hi, 0, SIZE - 1)
        xs, ys = np.meshgrid(np.arange(lo[0], hi[0] + 1), np.arange(lo[1], hi[1] + 1))
        d = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
        if abs(d) < 1e-12:
            continue
        w0 = ((b[1] - c[1]) * (xs - c[0]) + (c[0] - b[0]) * (ys - c[1])) / d
        w1 = ((c[1] - a[1]) * (xs - c[0]) + (a[0] - c[0]) * (ys - c[1])) / d
        w2 = 1.0 - w0 - w1
        eps = -0.6 / max(np.sqrt(abs(d)), 1.0)  # conservative: half a texel of slack
        inside = (w0 >= eps) & (w1 >= eps) & (w2 >= eps)
        if not inside.any():
            continue
        p = w0[inside, None] * pos[tri[0]] + w1[inside, None] * pos[tri[1]] + w2[inside, None] * pos[tri[2]]
        posmap[ys[inside], xs[inside]] = p
        cover[ys[inside], xs[inside]] = True
    return posmap, cover


def dilate(image, cover, rounds=24):
    """Flood colours outward from covered texels (nearest covered texel wins)."""
    nearest = ndimage.distance_transform_edt(~cover, return_distances=False, return_indices=True)
    return image[nearest[0], nearest[1]]


def main():
    OUT.mkdir(exist_ok=True)
    pos, uv, idx = read_glb(SRC / 'anims_core.glb')
    base = np.asarray(Image.open(SRC / 'base_color.png').convert('RGB').resize((SIZE, SIZE), Image.LANCZOS), np.float32) / 255.0
    posmap, cover = rasterise(pos, uv, idx)
    lo, hi = pos.min(0), pos.max(0)
    rel = (posmap - lo) / (hi - lo)  # x: side, y: up, z: front (glTF)
    print('bounds', lo, hi, 'coverage', cover.mean())
    r, g, b = base[..., 0], base[..., 1], base[..., 2]
    value = base.max(-1)
    chroma = value - base.min(-1)
    sat = chroma / np.maximum(value, 1e-4)
    # Keyed suit: strongly red-dominant texels.
    redness = np.clip((r - np.maximum(g, b)) / np.maximum(r, 1e-4), 0, 1)
    team = np.clip((redness - 0.25) / 0.45, 0, 1) * np.clip((value - 0.12) / 0.2, 0, 1)
    # Visor glass: near-black texels on the front of the head.
    head = rel[..., 1] > 0.60
    glass = (value < 0.13) & head & cover
    glass_soft = ndimage.binary_dilation(glass, iterations=3)
    if glass.any():
        gp = rel[glass]
        vis_lo = np.percentile(gp, 1, axis=0)
        vis_hi = np.percentile(gp, 99, axis=0)
    else:
        vis_lo = np.array([0.3, 0.7, 0.8]); vis_hi = np.array([0.7, 0.9, 1.0])
    print('visor box', vis_lo, vis_hi)
    in_visor = np.all((rel[..., :2] > vis_lo[:2] - 0.01) & (rel[..., :2] < vis_hi[:2] + 0.01), axis=-1) & (rel[..., 2] > vis_lo[2] - 0.03)
    # Screen eyes: bright, non-keyed texels inside the glass.
    eyes = in_visor & (value > 0.45) & (redness < 0.2) & cover
    eyes = ndimage.binary_opening(eyes, iterations=1)
    # Antenna ball: the very top of the model glows in the team colour.
    tip = cover & (rel[..., 1] > TIP_HEIGHT)
    team = np.maximum(team, ndimage.gaussian_filter(tip.astype(np.float32), 0.8))
    chest = tip
    emissive = (eyes | chest).astype(np.float32)
    emissive = ndimage.gaussian_filter(emissive, 0.8)
    # Neutralise the keyed suit so the shader can multiply in any team colour.
    ref = np.percentile(value[(team > 0.9) & cover], 80) if ((team > 0.9) & cover).any() else 0.9
    neutral = np.clip(value / ref, 0, 1.08)[..., None] * np.ones(3, np.float32)
    neutral[tip] = 1.0
    albedo = base * (1 - team[..., None]) + neutral * team[..., None]
    # Clean, flat toy colours: push near-whites to a soft white and keep charcoal dark.
    mask = np.stack([team, np.clip(emissive, 0, 1), glass_soft.astype(np.float32)], -1)
    albedo = dilate(albedo, cover)
    mask = dilate(mask, cover)
    def write(array, name):
        image = Image.fromarray((np.clip(array, 0, 1) * 255 + 0.5).astype(np.uint8))
        image.resize((FINAL, FINAL), Image.BOX).save(OUT / name, optimize=True)
    write(albedo, 'runner_albedo.png')
    write(mask, 'runner_mask.png')
    # QA: orthographic front splat of the classified texels.
    front = cover & (rel[..., 2] > 0.45)
    qa = np.zeros((700, 500, 3), np.float32) + 0.2
    ys = ((1 - rel[..., 1][front]) * 660 + 20).astype(int)
    xs = (rel[..., 0][front] * (hi[0] - lo[0]) / (hi[1] - lo[1]) * 660 + 250 - 330 * (hi[0] - lo[0]) / (hi[1] - lo[1])).astype(int)
    order = np.argsort(rel[..., 2][front])
    colours = (albedo * (1 - mask[..., :1]) + mask[..., :1] * albedo * np.array([0.2, 0.6, 1.0]))
    colours = colours * (1 - mask[..., 1:2]) + mask[..., 1:2] * np.array([0.2, 1.0, 0.3])
    colours = colours * (1 - 0.5 * mask[..., 2:3]) + 0.5 * mask[..., 2:3] * np.array([1.0, 0.0, 1.0])
    cf = colours[front]
    qa[np.clip(ys[order], 0, 699), np.clip(xs[order], 0, 499)] = cf[order]
    Image.fromarray((np.clip(qa, 0, 1) * 255).astype(np.uint8)).save(OUT / 'qa_front.png')
    print('ref value', ref, 'team texels', (team > 0.5).mean(), 'eye texels', eyes.sum(), 'tip texels', tip.sum())


if __name__ == '__main__':
    main()
