"""ios/Assets/pepe.glb for the iPhone prototype: ONE uncompressed glb = boss model + the clips the app uses, embedded.

Why a separate file: web/pepe_mr_fm.web.glb is gltfpack'd (-cc: EXT_meshopt_compression + KHR_mesh_quantization) and its
clips live in separate animation-only glbs. GLTFKit2's README lists EXT_meshopt_compression as supported, but the iOS path
is unverified, so the iOS asset is plain float32 glTF with the animations inside (GLTFKit2 -> SCNAnimationPlayer per clip).

Inputs (all exist after bake_queue.sh + make_clips_boss.py; nothing is baked here):
  model : out/wip/web_exhale.glb                      (the exhale bake: carries the skinned mesh + textures, 30 MB)
  clips : out/wip/web_boss/clips_v2/boss_<name>.anim.raw.glb   (animation-only, faced +Z, written BEFORE gltfpack)
Run:    python3 ios/tools/make_pepe_glb.py [out.glb]        (default ios/Assets/pepe.glb; ~6-9 MB)

Equivalent one-line change in web/make_clips_boss.py if you prefer to generate it there: in make_model() and make_clip()
drop '-cc' from the gltfpack argv (keep '-kn' so node names survive; '-ac -af 24' are fine) -> no meshopt, no quantization;
then merge the clips in with merge_clips() below. The merge is by NODE NAME (the clips carry Godot's node list), so it
also works on any future bake of the same character.
"""
import json, os, struct, sys
import numpy as np
LAB = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(LAB, 'web'))
from make_clips_boss import read_glb, write_glb, acc, rebuild, prune_accessors, GLB_BIN   # noqa: E402
from PIL import Image                                                                     # noqa: E402
import io                                                                                  # noqa: E402

MODEL = os.path.join(LAB, 'out/wip/web_exhale.glb')
CLIP_DIR = os.path.join(LAB, 'out/wip/web_boss/clips_v2')
# the app's clip set (names = clips_boss.json keys; ios/PepePiP/Director.swift maps brain events onto these)
CLIPS = ['idle_standing_a', 'shifting_weight', 'look_around', 'idle_breathing', 'think', 'typing', 'explain', 'talking_funny',
         'acknowledging', 'head_nod_yes', 'fist_pump', 'very_happy', 'cheering', 'shaking_head_no', 'standing_angry',
         'wave_hello', 'talking_on_phone', 'bored']


def strip_model(J, BIN, maxs=1024, q=85):
    """model without animation and without the PROP skin (cigar/puffs: not used on the phone), textures -> 1k JPEG"""
    J.pop('animations', None)
    J['extensionsUsed'] = [e for e in J.get('extensionsUsed', []) if e != 'GODOT_single_root']
    if not J['extensionsUsed']: J.pop('extensionsUsed')
    # drop the prop mesh (skin 1) and its mesh entry
    drop_mesh = set()
    for n in J['nodes']:
        if n.get('skin', 0) == 1 and 'mesh' in n: drop_mesh.add(n.pop('mesh')); n.pop('skin')
    if len(J.get('skins', [])) > 1: J['skins'] = J['skins'][:1]
    if drop_mesh:
        keep = [i for i in range(len(J['meshes'])) if i not in drop_mesh]; remap = {old: new for new, old in enumerate(keep)}
        J['meshes'] = [J['meshes'][i] for i in keep]
        for n in J['nodes']:
            if 'mesh' in n: n['mesh'] = remap[n['mesh']]
    used = set()
    for m in J['meshes']:
        for p in m['primitives']:
            used.update(p['attributes'].values()); used.add(p.get('indices', -1)); [used.update(t.values()) for t in p.get('targets', [])]
    for s in J.get('skins', []): used.add(s.get('inverseBindMatrices', -1))
    used.discard(-1); prune_accessors(J, used); [A.pop('_old', None) for A in J['accessors']]
    keep = set(A['bufferView'] for A in J['accessors'] if 'bufferView' in A); rep = {}
    for im in J.get('images', []):
        bv = J['bufferViews'][im['bufferView']]; data = BIN[bv.get('byteOffset', 0):bv.get('byteOffset', 0) + bv['byteLength']]
        img = Image.open(io.BytesIO(data)).convert('RGB'); s = min(1.0, maxs / max(img.size))
        if s < 1: img = img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
        b = io.BytesIO(); img.save(b, 'JPEG', quality=q, optimize=True); rep[im['bufferView']] = b.getvalue(); im['mimeType'] = 'image/jpeg'; keep.add(im['bufferView'])
    return rebuild(J, BIN, keep, rep)


def merge_clips(J, BIN, clip_paths):
    """append each clip's animation to the model: channel targets remapped by node name, accessors appended to the buffer"""
    byname = {}
    for i, n in enumerate(J['nodes']):
        byname.setdefault(n.get('name'), []).append(i)
    out = bytearray(BIN); J.setdefault('animations', [])
    for name, path in clip_paths:
        CJ, CB = read_glb(path); anim = CJ['animations'][0]; amap = {}
        def add_acc(ci):
            if ci in amap: return amap[ci]
            A = dict(CJ['accessors'][ci]); data = acc(CJ, CB, ci).astype(np.float32)
            while len(out) % 4: out.append(0)
            J['bufferViews'].append({'buffer': 0, 'byteOffset': len(out), 'byteLength': data.nbytes}); out.extend(data.tobytes())
            A['bufferView'] = len(J['bufferViews']) - 1; A.pop('byteOffset', None); A['componentType'] = 5126; A['count'] = len(data)
            if A['type'] == 'SCALAR': A['min'] = [float(data.min())]; A['max'] = [float(data.max())]
            else: A.pop('min', None); A.pop('max', None)
            J['accessors'].append(A); amap[ci] = len(J['accessors']) - 1; return amap[ci]
        channels, samplers, dropped = [], [], []
        for ch in anim['channels']:
            nm = CJ['nodes'][ch['target']['node']].get('name'); tgt = byname.get(nm)
            if not tgt: dropped.append(nm); continue
            if len(tgt) > 1: raise SystemExit(f'{name}: node name {nm!r} is not unique in the model')
            s = anim['samplers'][ch['sampler']]
            samplers.append({'input': add_acc(s['input']), 'output': add_acc(s['output']), 'interpolation': s.get('interpolation', 'LINEAR')})
            channels.append({'sampler': len(samplers) - 1, 'target': {'node': tgt[0], 'path': ch['target']['path']}})
        J['animations'].append({'name': name, 'channels': channels, 'samplers': samplers})
        secs = max(float(J['accessors'][s['input']]['max'][0]) for s in samplers)
        print(f'  {name:18s} {len(channels):3d} channels {secs:5.2f} s' + (f'  (no such node in model: {sorted(set(dropped))})' if dropped else ''))
    J['buffers'] = [{'byteLength': len(out)}]
    return out


if __name__ == '__main__':
    dst = sys.argv[1] if len(sys.argv) > 1 else os.path.join(LAB, 'ios/Assets/pepe.glb')
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    J, BIN = read_glb(MODEL)
    BIN = strip_model(J, BIN)
    print(f'model: {len(J["nodes"])} nodes, meshes {len(J["meshes"])}, joints {[len(s["joints"]) for s in J["skins"]]}, bin {len(BIN)/1e6:.2f} MB')
    paths = []
    for c in CLIPS:
        p = os.path.join(CLIP_DIR, f'boss_{c}.anim.raw.glb')
        if not os.path.exists(p): print('MISSING clip', p, '(run make_clips_boss.py; the .raw.glb is its pre-gltfpack output)'); continue
        paths.append((c, p))
    BIN = merge_clips(J, BIN, paths)
    J['asset'] = {'version': '2.0', 'generator': 'pepe_lab ios/tools/make_pepe_glb.py (uncompressed, clips embedded)'}
    write_glb(dst, J, BIN)
    print(f'{dst}: {os.path.getsize(dst)/1e6:.2f} MB, {len(J["animations"])} animations, extensions {J.get("extensionsUsed")}')
