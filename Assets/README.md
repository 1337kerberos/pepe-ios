# ios/Assets

`pepe.glb` (9.7 MB): the boss character (`retarget_lab/models/pepe_mr_fm` as Godot's `bake.gd` exports it: metres, humanoid
bone names, 64 joints, 1k JPEG textures) with 19 clips embedded as glTF animations, **no** `EXT_meshopt_compression`,
**no** `KHR_mesh_quantization`, the PROP skin reduced to the cigar (3 primitives on PROP_cigar; zippo/flame/puffs dropped), hand-relative PROP_cigar tracks baked into every non-smoke clip. Built by `../tools/make_pepe_glb.py` from

- model: `out/wip/web_exhale.glb` (the `vid_smoke_exhale` bake, carries the mesh)
- clips: `out/wip/web_boss/clips_v2/boss_<name>.anim.raw.glb` (the pre-gltfpack output of `web/make_clips_boss.py`)

Clips: idle_standing_a, shifting_weight, look_around, idle_breathing, think, typing, explain, talking_funny, acknowledging,
head_nod_yes, fist_pump, very_happy, cheering, shaking_head_no, standing_angry, wave_hello, talking_on_phone, bored, smoke_exhale, walk
(walk = boss_walk made in place: Hips horizontal travel removed, 1.0643 m/s, see make_pepe_glb.py IN_PLACE)
(smoke_light: no boss bake yet, skipped).

Textures (backdrops, floor shadow, glow, smoke puff) are drawn in code: `PepePiP/Backdrops.swift`.

Regenerate: `python3 ios/tools/make_pepe_glb.py` (pure Python; no Godot, no gltfpack).
