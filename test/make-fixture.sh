#!/usr/bin/env bash
# test/make-fixture.sh — build a tiny synthetic archive that mimics the real
# camera's layout, so the pipeline can be exercised end to end without needing
# anyone's actual footage.
#
#   YYYYMMDDHH/MMmSSs_<epoch>.mp4   HEVC, 20 fps, keyframe every 2 s
#
# Four kinds of clip, chosen to exercise each gate:
#   static     empty scene                       -> must produce nothing
#   person     a box crossing the frame slowly   -> must be detected
#   flash      a whole-frame brightness jump     -> must be killed by gate 1
#   blip       a single-frame speck              -> must be killed by gate 2
set -euo pipefail

DEST="${1:-./fixture}"
mkdir -p "$DEST"
EPOCH=1786000000

mk() { # mk <folder> <minute> <kind>
  local folder="$1" minute="$2" kind="$3"
  local dir="$DEST/$folder"; mkdir -p "$dir"
  local ep=$(( EPOCH + minute * 60 ))
  local name; name=$(printf '%02dM00S_%d.mp4' "$minute" "$ep")
  local vf

  case "$kind" in
    static) vf="null" ;;
    person) vf="drawbox=x='mod(t*70,700)-70':y=140:w=64:h=150:color=white@0.95:t=fill" ;;
    flash)  vf="eq=brightness='if(between(t,4,6),0.45,0)'" ;;
    blip)   vf="drawbox=x=300:y=180:w=7:h=7:color=white:t=fill:enable='between(t,4.0,4.06)'" ;;
  esac

  ffmpeg -nostdin -hide_banner -v error \
    -f lavfi -i "color=c=0x4a4a4a:s=640x360:r=20:d=10" \
    -vf "$vf,format=yuv420p" \
    -c:v libx265 -x265-params "keyint=40:min-keyint=40:scenecut=0:log-level=none" \
    -tag:v hvc1 -crf 28 -y "$dir/$name" 2>/dev/null
  printf '  %s/%s  (%s)\n' "$folder" "$name" "$kind"
}

echo "building fixture in $DEST"
mk 2026081410 0 static
mk 2026081410 1 person
mk 2026081410 2 static
mk 2026081410 3 flash
mk 2026081411 0 static
mk 2026081411 1 blip
mk 2026081411 2 person
mk 2026081411 3 static
echo "done. 8 clips across 2 hour-folders."
