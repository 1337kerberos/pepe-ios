"""ios/Assets/pepe.glb for the iPhone prototype: ONE uncompressed glb = boss model + cigar + the clips the app uses, embedded.

Why a separate file: web/pepe_mr_fm.web.glb is gltfpack'd (-cc: EXT_meshopt_compression + KHR_mesh_quantization) and its
clips live in separate animation-only glbs. GLTFKit2's README lists EXT_meshopt_compression as supported, but the iOS path
is unverified, so the iOS asset is plain float32 glTF with the animations inside (GLTFKit2 -> SCNAnimationPlayer per clip).

Inputs (all exist after bake_queue.sh + make_clips_boss.py; nothing is baked here):
  model : out/wip/web_exhale.glb                      (the exhale bake: carries the skinned mesh + textures + PROP_mesh, 30 MB)
  clips : out/wip/web_boss/clips_v2/boss_<name>.anim.raw.glb   (animation-only, faced +Z, written BEFORE gltfpack)
Run:    python3 ios/tools/make_pepe_glb.py [out.glb]        (default ios/Assets/pepe.glb)

Cigar: PROP_mesh keeps only its cigar primitives (bound to the PROP_cigar bone, a child of Hips; tip = +Y * 0.133 m);
zippo / flame / puff spheres are dropped. Clips other than the smoke takes have no PROP tracks, so the cigar would sit at
the skeleton origin: the same trick as web/smoke.js is applied at build time instead of per frame: the grip (PROP_cigar
relative to RightHand) is sampled at frame 0 of the exhale take and PROP_cigar translation/rotation tracks are written into
every non-smoke clip by forward kinematics of the hand chain, so the cigar stays in the right hand in every clip and
blends like any bone.

Equivalent one-line change in web/make_clips_boss.py if you prefer to generate it there: in make_model() and make_clip()
drop '-cc' from the gltfpack argv (keep '-kn'; '-ac -af 24' are fine) -> no meshopt, no quantization; then merge_clips().
"""
import json, os, struct, sys, io
import numpy as np
LAB = os.environ.get('PEPE_LAB') or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))   # PEPE_LAB: run from a worktree
sys.path.insert(0, os.path.join(LAB, 'web'))
from make_clips_boss import read_glb, write_glb, rebuild, prune_accessors   # noqa: E402
from PIL import Image                                                        # noqa: E402

MODEL = os.path.join(LAB, 'out/wip/web_exhale.glb')
CLIP_DIR = os.path.join(LAB, 'out/wip/web_boss/clips_v2')
# the app's clip set (names = clips_boss.json keys; ios/PepePiP/Director.swift maps brain events onto these).
# smoke_light has no boss bake yet (only retarget_lab/anims/vid_smoke_light.glb): it is skipped until baked.
CLIPS = ['idle_standing_a', 'shifting_weight', 'look_around', 'idle_breathing', 'think', 'typing', 'explain', 'talking_funny',
         'acknowledging', 'head_nod_yes', 'fist_pump', 'very_happy', 'cheering', 'shaking_head_no', 'standing_angry',
         'wave_hello', 'talking_on_phone', 'bored', 'smoke_light', 'smoke_exhale', 'walk',
         'meshy_walk_normal', 'meshy_walk_boss']   # 0.17 (research/WALKS.md): Meshy walks, feet fix baked by make_clips_boss.py
SMOKE_CLIPS = {'smoke_light', 'smoke_exhale'}
# locomotion clips played IN PLACE on the phone (street treadmill, 0.10): the Hips' horizontal travel is removed linearly
# over the clip (the bob/sway stays); the world-space speed it had is printed so PepeScene.walkSpeed can match the set to it
IN_PLACE = {'walk'}
# 0.17: these clips arrive ALREADY in place from web/make_clips_boss.py (WALK_CLIPS: feet_level 'clips' deg baked, Hips drift
# removed); their stride speed comes from web/clips_boss.json `inplace` (= retarget_lab/walks.json speed_pepe_mps / rate) and
# is written into the animation's extras {speed_mps, rate} (PepeScene / StreetSet.walkSpeed should match the set to it)
PRE_IN_PLACE = {'meshy_walk_normal', 'meshy_walk_boss'}
CIGAR_BONE, HAND_BONE = 'PROP_cigar', 'RightHand'


def acc(J, BIN, i):
    A = J['accessors'][i]; bv = J['bufferViews'][A['bufferView']]; off = bv.get('byteOffset', 0) + A.get('byteOffset', 0)
    n = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}[A['type']]
    dt = {5126: np.float32, 5123: np.uint16, 5125: np.uint32, 5121: np.uint8}[A['componentType']]
    return np.frombuffer(BIN, dtype=dt, count=A['count'] * n, offset=off).reshape(A['count'], n).copy()


# ---------- model ----------
def strip_model(J, BIN, maxs=1024, q=85):
    """no animation, PROP_mesh reduced to the cigar primitives, textures -> 1k JPEG"""
    J.pop('animations', None)
    J['extensionsUsed'] = [e for e in J.get('extensionsUsed', []) if e != 'GODOT_single_root']
    if not J['extensionsUsed']: J.pop('extensionsUsed')
    names = [n.get('name') for n in J['nodes']]
    prop_node = next(n for n in J['nodes'] if n.get('name') == 'PROP_mesh')
    skin = J['skins'][prop_node['skin']]; cigar_j = skin['joints'].index(names.index(CIGAR_BONE))
    mesh = J['meshes'][prop_node['mesh']]; keep = []
    for p in mesh['primitives']:
        jn = acc(J, BIN, p['attributes']['JOINTS_0']); w = acc(J, BIN, p['attributes']['WEIGHTS_0'])
        used = set(int(j) for j, ww in zip(jn.ravel(), w.ravel()) if ww > 0)
        if used == {cigar_j}: keep.append(p)
    print(f'PROP_mesh: {len(mesh["primitives"])} primitives -> {len(keep)} cigar parts (bone {CIGAR_BONE})')
    mesh['primitives'] = keep
    used = set()
    for m in J['meshes']:
        for p in m['primitives']:
            used.update(p['attributes'].values()); used.add(p.get('indices', -1)); [used.update(t.values()) for t in p.get('targets', [])]
    for s in J.get('skins', []): used.add(s.get('inverseBindMatrices', -1))
    used.discard(-1); prune_accessors(J, used); [A.pop('_old', None) for A in J['accessors']]
    keep_bv = set(A['bufferView'] for A in J['accessors'] if 'bufferView' in A); rep = {}
    for im in J.get('images', []):
        bv = J['bufferViews'][im['bufferView']]; data = BIN[bv.get('byteOffset', 0):bv.get('byteOffset', 0) + bv['byteLength']]
        img = Image.open(io.BytesIO(data)).convert('RGB'); s = min(1.0, maxs / max(img.size))
        if s < 1: img = img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
        b = io.BytesIO(); img.save(b, 'JPEG', quality=q, optimize=True); rep[im['bufferView']] = b.getvalue(); im['mimeType'] = 'image/jpeg'; keep_bv.add(im['bufferView'])
    return rebuild(J, BIN, keep_bv, rep)


# ---------- maths ----------
def quat_to_mat(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])

def mat_to_quat(R):
    t = np.trace(R)
    if t > 0:
        s = np.sqrt(t + 1) * 2; w = 0.25 * s; x = (R[2, 1] - R[1, 2]) / s; y = (R[0, 2] - R[2, 0]) / s; z = (R[1, 0] - R[0, 1]) / s
    elif R[0, 0] > R[1, 1] and R[0, 0] > R[2, 2]:
        s = np.sqrt(1 + R[0, 0] - R[1, 1] - R[2, 2]) * 2; w = (R[2, 1] - R[1, 2]) / s; x = 0.25 * s; y = (R[0, 1] + R[1, 0]) / s; z = (R[0, 2] + R[2, 0]) / s
    elif R[1, 1] > R[2, 2]:
        s = np.sqrt(1 + R[1, 1] - R[0, 0] - R[2, 2]) * 2; w = (R[0, 2] - R[2, 0]) / s; x = (R[0, 1] + R[1, 0]) / s; y = 0.25 * s; z = (R[1, 2] + R[2, 1]) / s
    else:
        s = np.sqrt(1 + R[2, 2] - R[0, 0] - R[1, 1]) * 2; w = (R[1, 0] - R[0, 1]) / s; x = (R[0, 2] + R[2, 0]) / s; y = (R[1, 2] + R[2, 1]) / s; z = 0.25 * s
    q = np.array([x, y, z, w]); return q / np.linalg.norm(q)

def trs(t, r, s):
    M = np.eye(4); M[:3, :3] = quat_to_mat(r) * np.array(s)[None, :]; M[:3, 3] = t; return M


class Rig:
    """node tree of the model + a clip's tracks, sampled at the clip's key times (bakes key every frame)"""
    def __init__(self, J):
        self.J = J; self.names = [n.get('name') for n in J['nodes']]; self.parent = {}
        for i, n in enumerate(J['nodes']):
            for c in n.get('children', []): self.parent[c] = i
        self.byname = {n: i for i, n in enumerate(self.names)}

    def tracks(self, CJ, CB):
        """{(model node index, path): (times, values)} from a clip whose nodes are matched by name"""
        anim = CJ['animations'][0]; out = {}
        for ch in anim['channels']:
            nm = CJ['nodes'][ch['target']['node']].get('name')
            if nm not in self.byname: continue
            s = anim['samplers'][ch['sampler']]
            out[(self.byname[nm], ch['target']['path'])] = (acc(CJ, CB, s['input'])[:, 0].astype(float), acc(CJ, CB, s['output']).astype(float))
        return out

    def local(self, tr, i, t):
        n = self.J['nodes'][i]
        def samp(path, default, is_quat=False):
            tv = tr.get((i, path))
            if tv is None: return np.array(default, dtype=float)
            tm, v = tv
            if t <= tm[0]: return v[0]
            if t >= tm[-1]: return v[-1]
            k = np.searchsorted(tm, t) - 1; a = (t - tm[k]) / max(1e-9, tm[k + 1] - tm[k]); v0, v1 = v[k], v[k + 1]
            if is_quat and np.dot(v0, v1) < 0: v1 = -v1
            r = v0 + a * (v1 - v0); return r / np.linalg.norm(r) if is_quat else r
        return trs(samp('translation', n.get('translation', [0, 0, 0])), samp('rotation', n.get('rotation', [0, 0, 0, 1]), True), samp('scale', n.get('scale', [1, 1, 1])))

    def world(self, tr, i, t):
        M = self.local(tr, i, t)
        while i in self.parent:
            i = self.parent[i]; M = self.local(tr, i, t) @ M
        return M


# ---------- clips ----------
def merge_clips(J, BIN, clip_paths, grip_from):
    """append each clip's animation to the model (channel targets remapped by node name); non-smoke clips get PROP_cigar
    translation/rotation tracks = hand world * grip (grip sampled at frame 0 of `grip_from`)"""
    rig = Rig(J); out = bytearray(BIN); J.setdefault('animations', [])
    cig, hand = rig.byname[CIGAR_BONE], rig.byname[HAND_BONE]; cig_parent = rig.parent[cig]
    GJ, GB = read_glb(grip_from); gtr = rig.tracks(GJ, GB)
    grip = np.linalg.inv(rig.world(gtr, hand, 0.0)) @ rig.world(gtr, cig, 0.0)
    print(f'grip ({CIGAR_BONE} in {HAND_BONE} space, frame 0 of {os.path.basename(grip_from)}): offset {grip[:3, 3].round(3).tolist()}')

    def add_acc(data, typ):
        data = np.ascontiguousarray(data, dtype=np.float32)
        while len(out) % 4: out.append(0)
        J['bufferViews'].append({'buffer': 0, 'byteOffset': len(out), 'byteLength': data.nbytes}); out.extend(data.tobytes())
        A = {'bufferView': len(J['bufferViews']) - 1, 'componentType': 5126, 'count': len(data), 'type': typ}
        if typ == 'SCALAR': A['min'] = [float(data.min())]; A['max'] = [float(data.max())]
        J['accessors'].append(A); return len(J['accessors']) - 1

    for name, path in clip_paths:
        CJ, CB = read_glb(path); anim = CJ['animations'][0]; cache = {}
        channels, samplers, dropped = [], [], []
        for ch in anim['channels']:
            nm = CJ['nodes'][ch['target']['node']].get('name')
            if nm not in rig.byname: dropped.append(nm); continue
            s = anim['samplers'][ch['sampler']]
            strip = name in IN_PLACE and nm == 'Hips' and ch['target']['path'] == 'translation'
            for key in ('input', 'output'):
                ck = (s[key], strip and key == 'output')
                if ck not in cache:
                    data = acc(CJ, CB, s[key])
                    if ck[1]:
                        tm = acc(CJ, CB, s['input'])[:, 0].astype(float); frac = (tm - tm[0]) / max(1e-9, tm[-1] - tm[0])
                        drift = data[-1].astype(float) - data[0].astype(float); drift[1] = 0
                        tr0 = rig.tracks(CJ, CB); hips = rig.byname['Hips']
                        w0, w1 = rig.world(tr0, hips, tm[0])[:3, 3], rig.world(tr0, hips, tm[-1])[:3, 3]
                        print(f'  {name}: in place; Hips drift {drift.round(3).tolist()} (local) = {np.round(w1 - w0, 3).tolist()} m world over {tm[-1] - tm[0]:.3f} s'
                              f' -> walk speed {np.linalg.norm((w1 - w0)[[0, 2]]) / (tm[-1] - tm[0]):.4f} m/s (PepeScene.walkSpeed)')
                        data = data - frac[:, None] * drift[None, :]
                    cache[ck] = add_acc(data, CJ['accessors'][s[key]]['type'])
            samplers.append({'input': cache[(s['input'], False)], 'output': cache[(s['output'], strip)], 'interpolation': s.get('interpolation', 'LINEAR')})
            channels.append({'sampler': len(samplers) - 1, 'target': {'node': rig.byname[nm], 'path': ch['target']['path']}})
        has_cigar = any(c['target']['node'] == cig for c in channels)
        if name not in SMOKE_CLIPS and not has_cigar:
            tr = rig.tracks(CJ, CB); times = tr[(rig.byname['Hips'], 'rotation')][0]
            T, R = [], []
            for t in times:
                L = np.linalg.inv(rig.world(tr, cig_parent, t)) @ rig.world(tr, hand, t) @ grip
                T.append(L[:3, 3]); R.append(mat_to_quat(L[:3, :3] / np.linalg.norm(L[:3, :3], axis=0)[None, :]))
            ti = add_acc(times, 'SCALAR')
            for path, vals, typ in (('translation', np.array(T), 'VEC3'), ('rotation', np.array(R), 'VEC4')):
                samplers.append({'input': ti, 'output': add_acc(vals, typ), 'interpolation': 'LINEAR'})
                channels.append({'sampler': len(samplers) - 1, 'target': {'node': cig, 'path': path}})
        A_ = {'name': name, 'channels': channels, 'samplers': samplers}
        if name in PRE_IN_PLACE:
            ip = json.load(open(os.path.join(LAB, 'web/clips_boss.json')))['clips'][name].get('inplace', {})
            A_['extras'] = {'speed_mps': ip.get('speed_mps'), 'rate': ip.get('rate', 1.0), 'speed_pepe_mps': ip.get('speed_pepe_mps'), 'bake_speed_mps': (ip.get('bake') or {}).get('bake_speed_mps')}
            print(f'  {name}: in place (pre-stripped); stride speed {A_["extras"]} (PepeScene.walkSpeed)')
        J['animations'].append(A_)
        secs = max(float(J['accessors'][s['input']]['max'][0]) for s in samplers)
        print(f'  {name:18s} {len(channels):3d} channels {secs:5.2f} s' + ('  cigar: own tracks' if has_cigar else '  cigar: in hand (baked)')
              + (f'  (no such node in model: {sorted(set(dropped))})' if dropped else ''))
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
        if not os.path.exists(p): print(f'MISSING clip {c}: {p} (bake it with PEPE_CHAR=pepe_mr_fm bake.gd, then make_clips_boss.py)'); continue
        paths.append((c, p))
    BIN = merge_clips(J, BIN, paths, os.path.join(CLIP_DIR, 'boss_smoke_exhale.anim.raw.glb'))
    J['asset'] = {'version': '2.0', 'generator': 'pepe_lab ios/tools/make_pepe_glb.py (uncompressed, clips embedded, cigar in hand)'}
    write_glb(dst, J, BIN)
    print(f'{dst}: {os.path.getsize(dst)/1e6:.2f} MB, {len(J["animations"])} animations, extensions {J.get("extensionsUsed")}')
