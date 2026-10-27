#!/bin/bash
# Boot an iPhone simulator, install the simulator build of PepePiP, launch it in test mode (TestMode.swift) once per
# configuration and capture screenshots at 3 s, 8 s and 15 s after each launch, plus the app's stdout/stderr and the
# unified log. Fails (exit 1) when SceneKit/Metal reports a shader compile error, or when the app never loaded its scene.
# Usage (CI): tools/sim_shots.sh <path/to/PepePiP.app> <out dir>
set -uo pipefail
APP="$1"; OUT="${2:-simout}"
mkdir -p "$OUT/shots" "$OUT/logs"
BID=lab.pepe.pip

# newest iOS runtime, iPhone 16 Pro if present (else any iPhone Pro, else any iPhone)
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys,re
d=json.load(sys.stdin)["devices"]
rts=sorted([r for r in d if "iOS" in r], key=lambda r:[int(x) for x in re.findall(r"\d+", r.split("iOS")[-1])])
for pref in ("iPhone 16 Pro", "iPhone 17 Pro", "Pro", "iPhone"):
    for r in reversed(rts):
        for dev in d[r]:
            if (dev["name"]==pref) if pref.startswith("iPhone ") else (pref in dev["name"] and "iPhone" in dev["name"]):
                print(dev["udid"]); sys.exit(0)
')
[ -n "$UDID" ] || { echo "::error::no iPhone simulator"; xcrun simctl list devices available; exit 1; }
xcrun simctl list devices | grep "$UDID" | tee "$OUT/logs/device.txt"
xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 2>/dev/null || true
xcrun simctl install "$UDID" "$APP" || { echo "::error::install failed"; exit 1; }

xcrun simctl spawn "$UDID" log stream --level debug --style compact \
  --predicate 'process == "PepePiP" OR subsystem CONTAINS "scenekit" OR subsystem CONTAINS "metal"' > "$OUT/logs/oslog.txt" 2>&1 &
LOGPID=$!
sleep 2

run() {
  local name="$1"; shift
  xcrun simctl terminate "$UDID" "$BID" 2>/dev/null
  sleep 1
  echo "== $name: $*"
  local t0=$(python3 -c 'import time;print(time.time())')
  xcrun simctl launch --terminate-running-process --stdout="$PWD/$OUT/logs/$name.out" --stderr="$PWD/$OUT/logs/$name.err" \
    "$UDID" "$BID" -uiTest 1 "$@" >/dev/null || echo "::warning::launch failed for $name"
  for s in 3 8 15; do
    python3 -c "import time;d=$t0+$s-time.time();time.sleep(max(0,d))"
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/shots/${name}_${s}s.png" >/dev/null 2>&1 || echo "::warning::screenshot $name $s failed"
  done
}

run ops_idle      -background ops    -streetTime day
run street_day    -background street -streetTime day
run street_night  -background street -streetTime night
run smoke_early   -background office -exhaleAt 6.8
run smoke_late    -background office -exhaleAt 5.9
run smoke_debug   -background plain  -exhaleAt 6.0 -smokeDebug 1
run smoke_street  -background street -streetTime day -exhaleAt 6.2
run smoke_parts   -background office -exhaleAt 6.8 -bakedSmoke 0
run celebrating   -background ops    -testState celebrating -stateAt 6.5 -bubble "all 42 tests passed, shipping it"
run sleep_dim     -background street -streetTime dusk -reaction sleep -reactAt 5
run nebula        -background nebula
run nebula_player -background nebula -nebulaVideo player
run nebula_still  -background nebula -nebulaVideo still
run nebula_916    -background nebula -cardSize nineSixteen -testState celebrating -stateAt 6.5 -bubble "nebula, 9:16 card"
run nebula_smoke  -background nebula -exhaleAt 6.8

xcrun simctl terminate "$UDID" "$BID" 2>/dev/null
sleep 2; kill $LOGPID 2>/dev/null
ls -la "$OUT/shots"

# ---- assertions ----
fail=0
PAT='MTLLibraryErrorDomain|program_source:[0-9]+:[0-9]+: error|failed compiling shader|failed to compile|Compiler error|SCNShaderModifier|SceneKit\] Error'
if grep -hiE "$PAT" "$OUT"/logs/*.txt "$OUT"/logs/*.out "$OUT"/logs/*.err 2>/dev/null | grep -v "^== " | head -40 | tee "$OUT/logs/shader_errors.txt" | grep -q .; then
  echo "::error::SceneKit/Metal shader errors (see logs/shader_errors.txt)"; cat "$OUT/logs/shader_errors.txt"; fail=1
fi
for f in "$OUT"/logs/*.err; do        # the app logs to stderr in test mode (unbuffered)
  n=$(basename "$f" .err)
  grep -q "TEST MODE (scene loaded" "$f" || { echo "::error::$n: scene never loaded"; fail=1; }
done
grep -h "baked smoke" "$OUT"/logs/smoke_early.err | head -5
grep -q "baked smoke: ready" "$OUT/logs/smoke_early.err" || { echo "::error::baked smoke atlases did not load"; fail=1; }
grep -q "baked exhale at" "$OUT/logs/smoke_early.err" || { echo "::error::no baked exhale in smoke_early"; fail=1; }
grep -h "nebula" "$OUT"/logs/nebula.err | head -12
grep -q "nebula: first video frame" "$OUT/logs/nebula.err" || { echo "::error::nebula: no video frame reached the backdrop (output mode)"; fail=1; }
grep -q "baked exhale at" "$OUT/logs/nebula_smoke.err" || { echo "::error::no baked exhale on the nebula"; fail=1; }
grep -h "nebula" "$OUT"/logs/nebula_player.err | head -6
echo "--- SceneKit error lines (all, deduplicated) ---"
grep -h "SceneKit\]" "$OUT/logs/oslog.txt" | sed 's/^.*\] //' | sort | uniq -c | sort -rn | head -20
echo "--- app log excerpt (smoke_early) ---"; head -60 "$OUT/logs/smoke_early.err"
exit $fail
