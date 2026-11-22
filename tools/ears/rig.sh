#!/bin/bash
# StudioSync "ears" on the test rig (docs/rt/rt-ears.md): desktop (d), laptop (l), LinuxBox (x), each REAPER's dev eval hook.
#   rig.sh setup                     ears.jsfx into each REAPER's Effects/StudioSync Ears/, the pattern into a scratch folder on each
#   rig.sh run d|l|x 'EARS={...}'    one ears.lua call on that computer (tagged result; retried if a shared hook hands back another's)
#   rig.sh live TAG SENDER [HUB]     polls on all three, the pattern fired on SENDER, the poll files fetched into $OUT
#                                    TAP="l x" (receivers): also each one's ears tap of SENDER's Play (its hub mix with HUB) and SENDER's
#                                    own, started after the polls and right before the fire, so the taps hold the sound (rt-r1's r6: a
#                                    tap started by hand 39 s before the fire ended before the sound); the WAVs and .json fetched too
#   rig.sh cleanup                   ears.jsfx and the scratch folders off all three
# Before "live": the sender needs `track add=true`, `load`, `live role=send`; the receivers `live role=recv volume=0` (0.01 through a hub).
# Afterwards: `live role=restore` everywhere (Deafen back on), `hub peer='' serve=0`, `track add=false`.
# Never a microphone; never audio on a speaker above -40 dB (receivers at volume 0, or 0.01 for a hub's mix); only the song Cross Test.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HERE/out}"                                     # (local results; keep it outside the repo: OUT=/some/scratch rig.sh ...)
D_HOOK="J:/Portable Workstation/DAW/REAPER/Scripts/MIDI Control Center/midi_control_center/dev"
D_FX="J:/Portable Workstation/DAW/REAPER/Effects/StudioSync Ears"
L_HOOK="D:/Portable Workstation/DAW/REAPER/Scripts/MIDI Control Center/midi_control_center/dev"
L_FX="D:/Portable Workstation/DAW/REAPER/Effects/StudioSync Ears"
L_TMP="C:/Users/FMSJa/AppData/Local/Temp/rt-ears"
X="studio@192.168.86.129"; X_FX="/home/studio/REAPER/Effects/StudioSync Ears"; X_TMP="/tmp/rt-ears"
declare -A PEER=([d]=james-main.tail99132c.ts.net:47281 [l]=james-laptop.tail99132c.ts.net:47281 [x]=linuxbox.tail99132c.ts.net:47281)
declare -A TMP=([d]="$(cygpath -m "$OUT" 2>/dev/null || echo "$OUT")" [l]="$L_TMP" [x]="$X_TMP")

run() { # run d|l|x 'EARS={...}' [seconds]
  local w="$1" pre="$2" t="${3:-30}" src="$OUT/.ears_$1.lua" out=""
  mkdir -p "$OUT"; { printf '%s\n' "$pre"; cat "$HERE/ears.lua"; } > "$src"
  for try in 1 2 3; do
    case "$w" in
      d) # (the desktop's hook takes a lock folder, as the bandtest helpers do)
         until mkdir "$D_HOOK/.evallock" 2>/dev/null; do sleep 1; done
         while [ -f "$D_HOOK/eval.lua" ]; do sleep 1; done
         rm -f "$D_HOOK/result.txt"; printf 'return dofile([[%s]])' "$(cygpath -m "$src")" > "$D_HOOK/eval.tmp" && mv "$D_HOOK/eval.tmp" "$D_HOOK/eval.lua"
         for i in $(seq 1 "$t"); do [ -f "$D_HOOK/result.txt" ] && break; sleep 1; done
         out=$(cat "$D_HOOK/result.txt" 2>/dev/null); rmdir "$D_HOOK/.evallock" ;;
      l) scp -q "$src" "laptop:$L_HOOK/rtears_src.lua"
         ssh laptop "Remove-Item -ErrorAction SilentlyContinue '$L_HOOK/result.txt'; Set-Content -NoNewline -Encoding ascii -Path '$L_HOOK/rtears.tmp' -Value 'return dofile([[$L_HOOK/rtears_src.lua]])'; Move-Item -Force '$L_HOOK/rtears.tmp' '$L_HOOK/eval.lua'" 2>/dev/null
         for i in $(seq 1 "$t"); do out=$(ssh laptop "if (Test-Path '$L_HOOK/result.txt') { Get-Content -Raw '$L_HOOK/result.txt' }" 2>/dev/null); [ -n "$out" ] && break; sleep 1; done ;;
      x) scp -q "$src" "$X:/tmp/rtears_x.lua" && out=$(ssh "$X" '~/reval.sh "$(cat /tmp/rtears_x.lua)" '"$((t * 4))" 2>/dev/null) ;;
    esac
    case "$out" in *EARS*) printf '%s\n' "$out" | grep EARS; return 0 ;; esac
    echo "(not this call's result, try $try)" >&2; sleep 2
  done
  return 1
}

case "${1:-}" in
  setup)
    python "$HERE/ears.py" pattern "$OUT/pattern" >/dev/null
    mkdir -p "$D_FX" && cp "$HERE/ears.jsfx" "$D_FX/"
    ssh laptop "New-Item -ItemType Directory -Force '$L_FX','$L_TMP' | Out-Null" && scp -q "$HERE/ears.jsfx" "laptop:$L_FX/" && scp -q "$OUT/pattern/pattern.f32" "laptop:$L_TMP/"
    ssh "$X" "mkdir -p '$X_FX' $X_TMP" && scp -q "$HERE/ears.jsfx" "$X:$X_FX/" && scp -q "$OUT/pattern/pattern.f32" "$X:$X_TMP/"
    echo "pattern.f32 is at ${TMP[d]}/pattern/pattern.f32 (desktop), $L_TMP/pattern.f32, $X_TMP/pattern.f32" ;;
  run) run "$2" "$3" "${4:-30}" ;;
  live) # live TAG SENDER [HUB]
    T="$2"; S="$3"; HB="${4:-}"; WAIT="${WAIT:-12}"
    hubarg() { [ -z "$HB" ] && return; if [ "$1" = "$HB" ]; then printf ", hub_peer='', hub_serve=1"; else printf ", hub_peer='%s', hub_serve=0" "${PEER[$HB]}"; fi; }
    TAP="${TAP:-}"; EXTRA=0; [ -n "$TAP" ] && EXTRA=40 # (the polls also cover the tap calls, a few seconds each)
    for w in l x d; do run "$w" "EARS={mode='poll', out=[[${TMP[$w]}/${T}_$w.jsonl]], secs=$((32 + WAIT + EXTRA))$(hubarg "$w")}"; done
    sleep "$WAIT"
    for r in $TAP; do # (receivers first, then the sender's own, then the fire: each tap's 30 s hold the 10 s pattern and its delay)
      st=play; [ -n "$HB" ] && [ "$r" != "$HB" ] && st=hub
      run "$r" "EARS={mode='tap', peer='$([ "$st" = hub ] && echo "${PEER[$HB]}" || echo "${PEER[$S]}")', stream='$st', secs=30, out=[[${TMP[$r]}/${T}_$r.wav]]}"
    done
    [ -n "$TAP" ] && run "$S" "EARS={mode='tap', peer='', stream='play', secs=30, out=[[${TMP[$S]}/${T}_$S.wav]]}"
    run "$S" "EARS={mode='fire', slot=0}"
    sleep 32
    scp -q "laptop:$L_TMP/${T}_l.jsonl" "$OUT/"; scp -q "$X:$X_TMP/${T}_x.jsonl" "$OUT/"
    for w in $TAP $([ -n "$TAP" ] && echo "$S"); do
      case "$w" in l) scp -q "laptop:$L_TMP/${T}_l.wav" "laptop:$L_TMP/${T}_l.wav.json" "$OUT/" ;; x) scp -q "$X:$X_TMP/${T}_x.wav" "$X:$X_TMP/${T}_x.wav.json" "$OUT/" ;; esac
    done
    [ -n "$TAP" ] && echo "taps: python $HERE/ears.py wav $OUT/${T}_$S.wav $OUT/${T}_<receiver>.wav --pattern $OUT/pattern --stamps (speed, steady, no_gaps)"
    echo "compare: python $HERE/ears.py env $OUT/pattern $OUT/${T}_$S.jsonl $OUT/${T}_<receiver>.jsonl --peer <sender name> (or --hub --gain 0.01)" ;;
  cleanup)
    rm -rf "$D_FX"
    ssh laptop "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue '$L_FX','$L_TMP','$L_HOOK/rtears_src.lua'" 2>/dev/null
    ssh "$X" "rm -rf '$X_FX' $X_TMP /tmp/rtears_x.lua" ;;
  *) sed -n 2,9p "$0" ;;
esac
