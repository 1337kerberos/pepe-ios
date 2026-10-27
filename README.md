# Pepe in Picture-in-Picture (iPhone prototype)

A native Swift app whose PiP card shows the 3D Pepe reacting live to the agent brain (`brain/pepe_brain.py`): a pocket
window into your agents that floats over any app. iOS has no overlay API, so the card is the ceiling (see
`research/IPHONE_PATH.md`): opaque, draggable, pinch-sized, no touch on the character; with the sample-buffer path the
system play/pause and skip buttons are repurposed (play/pause = "give me a one-line status", skip = next/previous card).

**Not compiled here** (no Mac). The code is written against the current APIs (checked against Apple's docs and
GLTFKit2 0.5.15 headers on 2026-10-27) but the first CI build will almost certainly need one or two small fixes; see
"First build: what is most likely to break" below.

## Tree

```
ios/
  README.md                         this file
  project.yml                       XcodeGen spec: app target, iOS 17+, Swift language mode 5, GLTFKit2 via SPM
  project-widget.yml                same + the PepeWidget Live Activity extension (optional, second App ID)
  .github/workflows/ios.yml         macos-14 runner: xcodegen -> xcodebuild archive (unsigned) -> Payload zip -> .ipa artifact
  Assets/pepe.glb                   9.7 MB: boss model + cigar + 19 clips embedded, no meshopt/quantization (tools/make_pepe_glb.py)
  Assets/README.md                  what is in the glb and how to regenerate it
  tools/make_pepe_glb.py            builds Assets/pepe.glb from the existing bakes (pure Python, no Godot, no gltfpack)
  PepePiP/
    PepeApp.swift                   @main App, AppDelegate (audio session), AudioKeepAlive (silent loop while in PiP), Log
    PepeModel.swift                 ObservableObject hub: settings (host/port/PiP mode), status, bubble, cards, summary request
    BrainClient.swift               URLSessionWebSocketTask client: JSON events in, {"type":"chat"} out, reconnect + pings
    Director.swift                  brain events -> clip (idle/think/typing/explain/celebrate/fail...), status line, bubble, cards
    AppResources.swift              loose-file lookup that survives LiveContainer (Bundle(for:) / main / exe dir / argv0) + asset inventory log
    Backdrops.swift                 procedural textures (lounge/office/neon backdrops, floor shadow, glow, puff) drawn with Core Graphics
    PepeScene.swift                 SceneKit scene from pepe.glb (GLTFKit2), SCNAnimationPlayer crossfades, 3/4 camera,
                                    soft lights, bubble + status as textured planes inside the 3D frame (visible in PiP)
    FrameFeeder.swift               PepeMetalView (MTKView drawn by SCNRenderer, iOS 18 PiP source) and PixelBufferFeeder
                                    (SCNRenderer -> CVPixelBuffer -> CMSampleBuffer -> AVSampleBufferDisplayLayer, 30 fps)
    PiPManager.swift                AVPictureInPictureController for both content sources + the 6 playback-delegate callbacks
    PepeViewController.swift        UIKit host: on-screen view, mode switch, auto-PiP, MTKView -> sample-buffer fallback
    ContentView.swift               SwiftUI shell: Pepe view, status, chat box, Float/Summary/cards buttons, Settings + log
    LiveActivityManager.swift       ActivityKit start/update/end (throttled), optional
    Info.plist                      UIBackgroundModes audio, NSSupportsLiveActivities, ATS allow ws://, local network text
  Shared/PepeActivityAttributes.swift   ActivityAttributes shared by app + widget
  PepeWidget/                       WidgetBundle + Live Activity views (Lock Screen + Dynamic Island), Info.plist
```

About 1,100 lines of Swift in total (about 1,000 in the app, the rest the optional widget).

## How it works

- **Brain protocol** (`brain/pepe_brain.py`): the app connects to `ws://<host>:8777` and consumes `hello`, `state`,
  `text`, `tool`, `point`, `result`, `ask`, `user_chat` and `beat`. It sends `{"type":"chat","text":...}`.
  `Director.swift` is a compact port of `brain/director_rules.json` onto the 18 clips in `pepe.glb`: raw events pick the
  base loop (idle -> `idle_standing_a` + idle-life variations, thinking -> `think`, exec tools -> `typing`, reads ->
  `look_around`, web/agents -> `talking_on_phone`, text -> `explain`/`talking_funny` + bubble, result ok -> `fist_pump` or
  `head_nod_yes`, error -> `standing_angry` then `bored`, tool fail -> `shaking_head_no`, ask -> `think` + "? ..." bubble,
  hello -> `wave_hello`). `beat` events are used only for one-shot reactions we have a clip for (via the alias table), so
  the two sources never fight over the loop.
- **Rendering**: GLTFKit2 loads the glb into an `SCNScene`; each glTF animation becomes a `GLTFSCNAnimation` whose
  `animationPlayer` is attached to the root node (Fox 2 pattern: `play()` / `stop(withBlendOutDuration:)`, 0.3 s blends).
  The bubble and status line are `SCNPlane`s with a UIKit-drawn texture and a billboard constraint, so they appear in
  any renderer (SCNView, MTKView, pixel buffers), unlike an `overlaySKScene`.
- **PiP paths** (Settings > Path):
  - *video-call + MTKView* (iOS 18+): `AVPictureInPictureVideoCallViewController` hosting `PepeMetalView`; no buttons.
  - *sample buffer*: `PixelBufferFeeder` renders 540x720 frames with `SCNRenderer` into IOSurface-backed
    `CVPixelBuffer`s on a 30 fps dispatch timer and enqueues them on an `AVSampleBufferDisplayLayer` that is also the
    on-screen view; the PiP controller takes that layer as its content source. Play/pause -> `PepeModel.requestSummary()`
    (sends a chat asking for a one-liner when idle; while the brain is busy a chat would be swallowed as an answer to a
    pending `ask`, so it shows the local status card instead); skip +/- -> next/previous card.
  - *auto*: MTKView on iOS 18+, else sample buffer. If the MTKView path fails to start, the app switches to the
    sample-buffer path by itself (`PiPManager.onFailed`).
- **Auto-PiP**: `canStartPictureInPictureAutomaticallyFromInline = true` (Settings toggle): swipe home and the card appears.
- **Keep-alive**: `UIBackgroundModes = audio` + a playback session + a looping silent `AVAudioEngine` buffer while PiP is
  active. App Store caveat: Apple rejects silent-audio keep-alives (2.5.4) and non-video PiP is a grey area; irrelevant
  for a sideloaded prototype.
- **Live Activity** (optional): emoji per state + last line in the Dynamic Island / Lock Screen; needs the widget target.
- **Card size** (Settings > Card): 3:4 (540x720, default), 9:16 portrait (540x960, a narrower card on iOS) or 1:1
  (540x540); sets the sample-buffer frame size and the video-call `preferredContentSize`. iOS derives the on-screen size
  from the aspect; **pinch the card** to toggle between the two system sizes, drag it to a corner, or swipe it off the
  edge to stash it.
- **Brightness** (Settings > Look): a 0.5-2.0 slider (default 1.4) scaling the key (warm 1200), fill (cool 400), rim (600)
  and ambient (350) lights; the clear colour is a lighter slate (0.16, 0.18, 0.24).
- **Cigar + smoke** (Settings > Look > Cigar, default on): the glb keeps the skinned cigar (PROP_mesh, PROP_cigar bone)
  and `tools/make_pepe_glb.py` bakes hand-relative `PROP_cigar` tracks into every non-smoke clip (grip sampled at frame 0
  of the exhale take, the trick `web/smoke.js` does per frame), so the cigar stays in the right hand in every clip and
  blends like any bone. A tip wisp (`SCNParticleSystem`, 12/s, 2.5 s, soft `Assets/puff.png` sprite) sits at the cigar tip;
  the exhale take fires an 80-particle burst from the lips (Head-space midpoint of `Lip_T_C`/`Lip_B_C`) at 4.33 s, blown
  forward, up and to his right. `Director` plays the take after 45-120 s of idle (and on the brain's `vid_smoke_*` beats);
  "Exhale now" in Settings triggers it by hand. Budget: ~110 live particles max.
  `smoke_light` is wired in but **absent from the glb**: there is no boss bake of `vid_smoke_light` yet
  (`out/wip/web_boss/baked/` has none; `retarget_lab/anims/vid_smoke_light.glb` is only the source). Bake it with
  `PEPE_CHAR=pepe_mr_fm PEPE_PROPS=smoke bake.gd`, add `'smoke_light': ('vid_smoke_light', ...)` to NAMES in
  `web/make_clips_boss.py`, rerun it and `tools/make_pepe_glb.py`; the app then plays light -> exhale automatically.
- **Background** (Settings > Look > Background, default lounge): a 7.5 m textured plane 2.6 m behind Pepe + a floor
  contact-shadow plane + per-preset light colours/intensities (`PepeScene.setBackground`): *lounge* (dark warm room,
  warm spot upper-left, cool rim glow, vignette; key 1300 warm, rim 800 cool), *office* (blue-grey, blurred window and
  desk silhouette; neutral key 1150, ambient 450), *neon* (near-black + two additive green/purple glow sprites drifting
  on `SCNAction`s; green-tinted key, purple rim), *plain* (no backdrop, the clear colour). Textures come from
  `tools/make_backgrounds.py` (`Assets/bg_*.png` 1024x1024, `floor_shadow.png`, `glow.png`). The camera drifts +-2 deg of
  yaw on an 8 s `SCNAction` so the card never looks frozen. All renderers set `isPlaying = true`: SceneKit only advances
  particle systems and actions on a playing renderer, which is the likeliest reason the 0.2 smoke was invisible.
- **Smoke at card size** (0.3): burst 150/s x 0.8 s (~120 particles), size 0.1 -> 0.6 m, alpha 0.7 -> 0, colour
  (0.85, 0.85, 0.9), alpha blend; wisp size 0.04 -> 0.16, alpha 0.4 -> 0. One exhale fires 8 s after launch when the cigar
  is on; the log prints the puff texture size at scene setup ("puff texture 64x64").
- **LiveContainer / guest-app resource lookup** (0.4): inside LiveContainer `Bundle.main` is the host's bundle, so loose
  files looked up through it are missing (black backdrop, no smoke sprite). Every loose file (glb, PNGs) now goes
  through `AppResources.url(_:)` (`PepePiP/AppResources.swift`), which tries `Bundle(for: PepeScene.self)`, `Bundle.main`,
  the class's and main executable directories and `argv[0]`'s directory, logs which one answered the first time, and at
  scene setup logs once the resolved paths and an ok/MISSING line per asset. The version line also reads the app's own
  Info.plist rather than the host's.
- **0.5: procedural textures + bbox framing.** All backdrop/floor/glow/puff textures are drawn with Core Graphics at
  runtime (`PepePiP/Backdrops.swift`: linear + radial gradients, plusLighter glows, shadow-blurred shapes), so no loose
  PNG can be missing (the 0.3/0.4 grey card inside LiveContainer); the glb is the only loose file (`AppResources`).
  The camera is computed from the character's bounding box (`PepeScene.measureCharacter` / `setFraming`): look-at the
  chest (bbox centre y x 0.95), distance so the body fills 85 % of the card height for the current feed aspect (vertical
  36 deg FOV, never wider than the card), 3/4 view at 18 deg; `Settings > Look > Pepe scale` (0.6-1.2) scales the
  distance. The drift is an absolute function of time (+-2 deg yaw around the target, 8 s) evaluated in
  `renderer(_:updateAtTime:)` on every renderer; the old `SCNAction.moveBy` drift could accumulate when several
  renderers advanced the same action, which is the likely cause of the 0.3/0.4 "small Pepe in the corner". The neon
  blobs are placed the same way. The log prints the bbox and the computed camera once per framing change.
- **Build tag**: Settings > Build shows `PepePiP <version> (<build>) · <BuildInfo.tag>` (`PepeModel.swift`); it is also the
  first line of the in-app log. Bump `BuildInfo.tag` / `CFBundleVersion` to tell builds apart.

## The glb (why a new one, and the one-line export change)

`web/pepe_mr_fm.web.glb` is `gltfpack -cc` output (EXT_meshopt_compression + KHR_mesh_quantization) and its clips live in
separate animation-only glbs. GLTFKit2's README lists `EXT_meshopt_compression` and `KHR_mesh_quantization` as supported,
but the iOS path is untested, so the app ships a plain float32 glb with the clips embedded:
`tools/make_pepe_glb.py` = `web/make_clips_boss.py`'s model step **without** gltfpack + a by-name merge of the clips'
raw (pre-gltfpack) animation glbs + baked in-hand cigar tracks. It was run here; `Assets/pepe.glb` is ready (9.73 MB,
19 animations incl. `smoke_exhale`, extensions used: only `KHR_materials_emissive_strength`).

If you would rather produce it from `web/make_clips_boss.py`: in `make_model()` and `make_clip()` remove `'-cc'` from the
gltfpack argv (keep `-kn`, `-ac -af 24`); that drops meshopt and quantization. Then merge the resulting clip glbs into the
model with `merge_clips()` from `tools/make_pepe_glb.py`.

Baked clips merged (from `out/wip/web_boss/clips_v2/boss_<name>.anim.raw.glb`; bakes in `out/wip/web_boss/baked/`):
idle_standing_a (mx_idle_standing_a), shifting_weight (mx_idle_weight_shift), look_around (mx_idle_look_around),
idle_breathing (mx_idle_breathing), think (mx_thinking), typing (mx_typing@0-8), explain (cmu_explain),
talking_funny (mx_talking_funny), acknowledging (mx_acknowledging), head_nod_yes (mx_head_nod_yes),
fist_pump (mx_standing_fist_pump), very_happy (mx_victory_idle), cheering (mx_cheering), shaking_head_no
(mx_shaking_head_no), standing_angry (mx_standing_angry@0-9), wave_hello (cmu_wave_hello), talking_on_phone
(mx_talking_on_phone@0-12), bored (mx_bored), smoke_exhale (vid_smoke_exhale, with its own PROP tracks).

## Build on GitHub Actions (free for public repos)

1. Make `ios/` its own repo (the workflow lives at its root) and push it to a **public** GitHub repo:
   ```bash
   cd ~/pepe_lab/ios
   git init -b main && git add -A && git commit -m "pepe pip prototype"
   gh repo create pepe-pip --public --source=. --push      # or add the remote by hand and push
   ```
   Public repos get unlimited Actions minutes; a private repo burns the 2,000 free minutes at 10x on macOS (~200 min).
2. The `ios` workflow runs on push (or Actions > ios > Run workflow; tick `widget` for the Live Activity build).
   Expect 8-15 minutes (brew xcodegen + package resolve + archive).
3. Download the artifact `PepePiP-unsigned-ipa` (a zip containing `PepePiP-unsigned.ipa`) from the run page, or
   `gh run download -n PepePiP-unsigned-ipa`.

### Reading the CI log
- The "Archive (unsigned)" step prints only `error:` lines, deprecation warnings and the `** ARCHIVE ... **` banner; the
  full `xcodebuild.log` is uploaded as the `xcodebuild-log` artifact even when the step fails.
- Swift errors look like `PepePiP/PiPManager.swift:71:10: error: ...`: file, line, column. Fix, commit, push, re-run.
- "no such module 'GLTFKit2'": package resolve failed (network hiccup or checksum); re-run the job first.
- A failure in "Generate the Xcode project" is a YAML/XcodeGen problem (`project.yml`), not Swift.

### First build: what is most likely to break (in order), and the fix
1. **GLTFKit2 Swift names.** Written from the headers: `GLTFAsset.load(with:options:handler:)` (README snippet),
   `GLTFSCNSceneSource(asset:)`, `.defaultScene`, `.animations` -> `GLTFSCNAnimation.name/.animationPlayer`,
   `GLTFAssetStatus.complete`. If the compiler complains about `load(with:` try `GLTFAsset.load(withURL:options:handler:)`
   or the synchronous `try GLTFAsset(url: url, options: [:])`. (`PepeScene.swift`)
2. **AVKit delegate signatures** (`PiPManager.swift`). The six `AVPictureInPictureSampleBufferPlaybackDelegate` methods
   are all required on current SDKs; if Xcode reports a missing/extra requirement, use its fix-it (Editor > "Add
   protocol stubs"-style messages appear in the log as `error: type 'PiPManager' does not conform ...`).
3. **CoreMedia/CoreVideo C API in Swift** (`FrameFeeder.swift`: `CMSampleBufferCreateReadyWithImageBuffer`,
   `CVMetalTextureCacheCreateTextureFromImage`, the attachment `CFDictionarySetValue`). Argument labels changed across
   SDKs; the log names the exact label it wants.
4. **Combine tuple closure** in `PepeViewController.configure` subscription (`sink { loaded, mode, auto in ... }`); if
   rejected, change to `sink { tuple in let (loaded, mode, auto) = tuple ... }`.
5. **XcodeGen resource entry** `Assets/pepe.glb` with `buildPhase: resources`; if XcodeGen objects, replace with
   `- path: Assets` + `type: folder`-style syntax from the XcodeGen docs, or list the glb under a `resources:` key.
6. **Unsigned archive + embedded binary framework**: if the archive fails at "Embed Frameworks" with a signing error,
   add `CODE_SIGNING_ALLOWED=NO` to the resolve step too, or set `EMBEDDED_CONTENT_CONTAINS_SWIFT=NO`; a last resort is
   `-destination 'generic/platform=iOS' build` + `-derivedDataPath` and zipping `Build/Products/Release-iphoneos/PepePiP.app`.
7. **Runner**: `macos-14` may lack an Xcode 16+ (needed for the iOS 18 SDK, i.e. the MTKView PiP path). The workflow picks
   the newest `Xcode_*.app`; if `xcodebuild -version` in the log says 15.x, switch `runs-on` to `macos-15`.

Runtime unknowns (need the phone): whether Metal rendering keeps running while backgrounded with PiP (if the MTKView
card freezes, pick the sample-buffer path; if that also freezes after a few seconds, the GPU is being throttled and the
answer is pre-rendered sprite clips), the achievable fps, and the visual size of the card (`preferredContentSize` /
the 540x720 buffer control the aspect ratio only). The in-app Settings sheet shows the log (PiP start/stop/fail,
feeder frames, WebSocket state) so these can be diagnosed without a Mac.

## Install from Linux: Dadoum's Sideloader (free Apple ID, 7-day certificate)

1. On the iPhone: Settings > Privacy & Security > Developer Mode > on (reboot). Trust the computer when plugged in.
2. Build Sideloader (https://github.com/Dadoum/Sideloader): install `ldc2`/`dmd`, `dub`, `libimobiledevice`,
   `usbmuxd`, then `dub build -c cli` (or the GTK `gui`) and use `bin/sideloader`. A prebuilt Linux binary is on the
   releases page when available.
3. Log in with a throwaway Apple ID (it becomes the "developer"; credentials go to Apple only):
   `sideloader login`.
4. Install: `sideloader install PepePiP-unsigned.ipa` (add `-i` to also set up a pairing file). Sideloader registers the
   App ID `lab.pepe.pip` (free accounts: 10 App IDs per 7 days, 3 apps installed), signs the app and its embedded
   `GLTFKit2.framework`, and pushes it over USB.
5. The certificate lasts 7 days: run the install again before it expires (or use the `splice` fork's daemon to re-sign
   automatically). On first launch iOS may ask to trust the developer profile under Settings > General > VPN & Device
   Management.

## Connect the phone to the brain over Tailscale

`pepe_brain.py` listens on `127.0.0.1:8777` only. Two ways to reach it from the phone (both machines on your tailnet):

- Expose the local port on the tailnet without touching the brain:
  `tailscale serve --bg --tcp 8777 tcp://127.0.0.1:8777` (then `tailscale serve status`; `tailscale serve reset` to undo).
- Or run the brain bound to all interfaces: change the `websockets.serve(handle, "127.0.0.1", a.port)` line in
  `brain/pepe_brain.py` to `"0.0.0.0"` (Tailscale ACLs still gate who can reach it).

Then in the app: Settings > host = the Linux box's Tailscale IP (`tailscale ip -4`, e.g. `100.x.y.z`), port 8777,
Reconnect. The green dot = connected; Pepe waves on `hello`. Start the brain with
`brain/.venv/bin/python brain/pepe_brain.py --cwd <dir>` and talk to it from the phone's chat box or any other body.

## Next steps
1. Push `ios/` to a public repo, run the workflow, fix the first compile errors from the log (see the list above).
2. Sideload, open the app once (model loads from the bundle), set the host, tap Float or swipe home.
3. Device tests from `research/IPHONE_PATH.md` section 5: background Metal, fps, card size. Pick the PiP path accordingly.
4. If you want the Dynamic Island mirror: re-run the workflow with `widget` ticked and sideload that IPA (two App IDs).
5. Later: more clips (smoke take needs the PROP skin kept in `make_pepe_glb.py`), a Shortcut on the Action Button to
   open the app ("summon Pepe"), RealityKit if SceneKit's deprecation in iOS 26 starts to bite (it still ships).
