# Boss Pepe state sprites (Live Activity / Dynamic Island)

Eight 512x512 RGBA PNGs, transparent background, character centred and 85 % of the height (width-limited to 95 % for the
lying pose). Rendered from the same model and clips the web demo uses (`web/pepe_mr_fm.web.glb` + `web/clips_boss.json`,
`out/wip/web_boss/clips_v2/boss_<clip>.anim.glb`) by `web/sprite.html` in headless Chrome, so he looks like the demo Pepe.
`sheet.png` is the contact sheet (each sprite at 220 px and at 60 px, the lock-screen size).

| state | file | clip @ time | yaw / pitch | why this frame |
|---|---|---|---|---|
| idle | `idle.png` | `idle_standing_a` @ 4.0 s (mid-clip) | 25 / 6 | neutral stand, arms down |
| thinking | `thinking.png` | `think` @ 2.1 s (chin hold 1.29–2.67 s) | **40** / 6 | right hand under the chin; at yaw 25 the green hand merges with the face, at 40 it is in profile |
| working | `working.png` | `typing` @ 2.0 s | 25 / 6 | seated keyboard pose, both hands up mid-stroke |
| waiting | `waiting.png` | `standing_angry` @ 4.8 s | 25 / 6 | arms folded, looking at the wrist ("checking the watch"); `look_around` 4.3 s and `bored` 3.75 s were rendered too but read as idle at 60 px |
| celebrating | `celebrating.png` | `very_happy` @ 1.0 s | 25 / 6 | both arms straight up (V); `fist_pump`'s peak (1.0 s) is a chest-high pump that does not read at 60 px, `cheering` 0.25 s is the runner-up |
| failing | `failing.png` | `crying` @ 3.75 s | 25 / 6 | head bowed to the camera, both hands up; `standing_angry` 8.6 s (hands on hips) reads as annoyed, `shaking_head_no` is a subtle head turn only |
| smoking | `smoking.png` | `smoke_exhale` @ 3.0 s (drag; exhale starts at 4.33 s) | **50** / 6 | cigar at the lips; at yaw 25 the cigar points at the camera and hides behind the fingers, at 50 the orange tip shows |
| sleeping | `sleeping.png` | `faint` @ 5.5 s | **10 / 35** | flat on his back (no head-down idle exists: `bored`, `idle_breathing` keep the head up; `stretching` 4 s is a standing slump) |

Yaw is the character's turn (positive = his right side toward the camera, he faces screen-right); pitch is the camera
looking down. One lens for all: fov 22°, the standing height (1.0 m) = 60 % of a 1024 px viewport, then cropped to the alpha
bbox and scaled (PIL, Lanczos). Lighting: hemisphere 2.6 + key 2.8 (front-right-top) + fill 1.7 + rim 1.0, brighter than the
demo, no tone mapping (same colour space as the demo). No smoke cloud is rendered: overlay the app's puff sprite if wanted.

## Regenerate
```
# serve ~/pepe_lab on 127.0.0.1:8765 (python3 -m http.server), then:
export SPRITE_URL="http://127.0.0.1:8765/web/sprite.html?fill=0.6&hemi=2.6&fillL=1.7&key=2.8"
python3 out/wip/sprites/drive_sprites.py shoot idle=idle_standing_a@4.0@25 thinking=think@2.1@40 working=typing@2.0@25 \
  waiting=standing_angry@4.8@25 celebrating=very_happy@1.0@25 failing=crying@3.75@25 smoking=smoke_exhale@3.0@50 \
  sleeping=faint@5.5@10@35            # NAME=CLIP@T[@YAW[@PITCH]] -> out/wip/sprites/final/NAME.png (512) + raw/NAME.png (1024)
python3 out/wip/sprites/drive_sprites.py scan think 0 4.2 0.3 25 6   # frame hunt: labelled sheet raw/scan_think.png
python3 out/wip/sprites/make_sheet.py sheet.png --cols 4 --big 220 idle.png ...   # contact sheet
```
`sprite.html` params: `?clip=&t=&yaw=&pitch=&fov=&fill=&cigar=0|1&hemi=&key=&fillL=&rim=`; JS `window.sprite.seek(clip, t,
yaw, pitch)` returns the screen bbox and a `clipped` flag. The driver captures with `Page.captureScreenshot` (`fromSurface`)
after `Emulation.setDefaultBackgroundColorOverride {0,0,0,0}` at a 1024x1024 viewport (swiftshader; `CDP_GPU=1` for the GPU).
