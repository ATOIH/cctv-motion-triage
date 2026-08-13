#!/usr/bin/env bash
# lib/digest.sh — stage 2: a day of footage -> only the moments something moved.
#
# The whole trick is one flag. `-discard nokey` drops non-key packets at the
# DEMUXER, so the decoder never receives them. Benchmarked on the reference
# archive against the two obvious alternatives:
#
#     full decode            59.7x realtime      ~5.2 hrs for 277 hours
#     -skip_frame nokey     157x realtime        ~2.0 hrs
#     -discard nokey        590x realtime        ~28 min      <- this
#
# `-skip_frame` is a DECODER hint: packets still arrive and headers are still
# parsed, it only skips reconstruction. `-discard` never sends them at all.
# That distinction is worth 3.8x.
#
# The cost is that temporal resolution is pinned to the keyframe interval,
# 3.0s on the reference camera. Anyone crossing faster than that can be missed.
# docs/TUNING.md covers when to spend the extra compute to close that gap.

cmd_digest() {
  require_ffmpeg
  local dates=("$@")
  mkdir -p "$OUT/digest" "$OUT/collage"

  if [ ${#dates[@]} -eq 0 ]; then
    while IFS= read -r f; do dates+=("$(basename "$f" .mp4)"); done < <(
      find "$OUT/daily" -maxdepth 1 -name '*.mp4' 2>/dev/null | LC_ALL=C sort)
  fi
  [ ${#dates[@]} -eq 0 ] && die "no daily files in $OUT/daily. Run 'gullak merge' first."

  step "scanning ${#dates[@]} day(s) for motion"
  local idx="$OUT/motion_events_index.csv"
  echo "date,event,source_file_start,source_file_end,frames,digest_position" > "$idx"

  local d
  for d in "${dates[@]}"; do _digest_one_day "$d" "$idx"; done

  # one reel across every day, for a single scan of the whole archive
  local all="$OUT/digest/ALL_DAYS_motion.mp4" cat="$OUT/digest/.all.txt"
  : > "$cat"
  find "$OUT/digest" -maxdepth 1 -name '*_motion.mp4' ! -name 'ALL_DAYS*' \
    | LC_ALL=C sort | while IFS= read -r f; do echo "file '$f'" >> "$cat"; done
  if [ -s "$cat" ]; then
    ffmpeg -nostdin -hide_banner -v error -f concat -safe 0 -i "$cat" \
      -c copy -fflags +genpts -movflags +faststart -y "$all" 2>/dev/null \
      && info "  combined reel -> $(basename "$all")"
  fi
  rm -f "$cat"
  step "digest complete. event index: $idx"
}

_digest_one_day() {
  local d="$1" idx="$2"
  local src="$OUT/daily/$d.mp4"
  [ -f "$src" ] || { warn "$d: no daily file, skipped"; return; }

  local work="$TMPROOT/digest-$d"; rm -rf "$work"; mkdir -p "$work"
  local meta="$work/meta.txt" raw="$work/raw.csv"
  local keep="$work/keep.txt" evs="$work/events.csv"
  mkdir -p "$work/f"

  # ---- filtergraph, in execution order --------------------------------
  #   crop      restrict analysis to the region that matters (optional)
  #   scale     shrink before differencing: cheaper, and small high-frequency
  #             noise (insects, rain, sensor grain) disappears while a person
  #             survives. This is the cheapest noise rejection available.
  #   gblur     same idea, explicitly. Kills what is left of the fine detail.
  #   signalstats  exposes mean luma (YAVG) so the illumination gate can run
  #   select    permissive threshold here (SCENE_LO); real decisions in gate.awk
  local vf=""
  [ -n "$ROI" ] && vf="crop=$ROI,"
  vf="${vf}scale=${DETECT_WIDTH}:-2,format=gray,gblur=sigma=${BLUR},signalstats"
  vf="${vf},select='gt(scene,${SCENE_LO})',metadata=print:file=${meta}"

  printf '  %s  scanning ... ' "$d" >&2

  # Frames are written full-size in the same order the metadata is printed, so
  # frame N of the JPEG sequence is line N of the metadata. That index is what
  # the gate returns, which is why no second decode pass is ever needed.
  local fps_flag; fps_flag=$(fps_passthrough_flag)
  # shellcheck disable=SC2086
  ffmpeg -nostdin -hide_banner -v error -discard nokey -i "$src" \
    -vf "$vf" $fps_flag -q:v 3 "$work/f/%06d.jpg" 2>/dev/null

  local vf2="" ; [ -n "$ROI" ] && vf2="crop=$ROI,"
  # second, cheap pass at render size for the frames we will actually publish
  # (the analysis pass above ran at DETECT_WIDTH and is greyscale)
  # shellcheck disable=SC2086
  ffmpeg -nostdin -hide_banner -v error -discard nokey -i "$src" \
    -vf "${vf2}scale=${DIGEST_WIDTH}:-2,select='gt(scene,${SCENE_LO})'" \
    $fps_flag -q:v 3 "$work/r_%06d.jpg" 2>/dev/null

  # ---- metadata -> csv --------------------------------------------------
  awk '
    /^frame:/ { n++; split($0,a,"pts_time:"); split(a[2],b," "); t=b[1] }
    /lavfi\.scene_score=/ { split($0,c,"="); sc=c[2] }
    /lavfi\.signalstats\.YAVG=/ { split($0,e,"="); ya=e[2];
                                  printf "%d,%s,%s,%s\n", n, t, sc, ya }
  ' "$meta" > "$raw"

  local cand; cand=$(wc -l < "$raw" | tr -d ' ')
  if [ "$cand" -eq 0 ]; then printf 'no motion\n' >&2; return; fi
  printf '%s candidate frames\n' "$cand" >&2

  # ---- gates ------------------------------------------------------------
  : > "$keep"; : > "$evs"
  awk -v HI="$SCENE_HI" -v LO="$SCENE_LO" -v MINH="$MIN_HITS" \
      -v YMAX="$YAVG_MAX_DELTA" -v GAP="$EVENT_GAP" -v FPS="$DIGEST_FPS" \
      -v DATE="$d" -v KEEP="$keep" -v EVENTS="$evs" \
      -f "$LIB/gate.awk" "$raw"

  local nkeep; nkeep=$(wc -l < "$keep" | tr -d ' ')
  [ "$nkeep" -eq 0 ] && { warn "  $d: nothing survived the gates"; return; }
  cat "$evs" >> "$idx"

  # ---- assemble the surviving frames -----------------------------------
  mkdir -p "$work/keep"
  local i=0
  while IFS= read -r n; do
    i=$((i+1))
    local srcf; srcf=$(printf '%s/r_%06d.jpg' "$work" "$n")
    [ -f "$srcf" ] && cp "$srcf" "$(printf '%s/keep/%06d.jpg' "$work" "$i")"
  done < "$keep"

  ffmpeg -nostdin -hide_banner -v error -framerate "$DIGEST_FPS" \
    -i "$work/keep/%06d.jpg" -c:v libx264 -preset veryfast -crf "$DIGEST_CRF" \
    -pix_fmt yuv420p -movflags +faststart -y "$OUT/digest/${d}_motion.mp4" 2>/dev/null

  local dur; dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 \
                    "$OUT/digest/${d}_motion.mp4" 2>/dev/null)
  info "  $d  -> ${d}_motion.mp4  $nkeep frames  $(hms "${dur%.*}")"

  # ---- contact sheets ---------------------------------------------------
  _build_collages "$d" "$work/keep"
}

# Every motion frame of the day, tiled into printable contact sheets. This is
# the artifact that lets you find an event by eye in seconds rather than
# scrubbing a timeline, and it is why the camera's burnt-in clock matters:
# each tile carries its own timestamp, so a hit on a sheet is directly
# addressable in the full-resolution daily file.
_build_collages() {
  local d="$1" dir="$2"
  local per=$(( COLLAGE_COLS * COLLAGE_ROWS ))
  local total; total=$(find "$dir" -name '*.jpg' | wc -l | tr -d ' ')
  [ "$total" -eq 0 ] && return
  local sheets=$(( (total + per - 1) / per ))

  local s
  for (( s=1; s<=sheets; s++ )); do
    local start=$(( (s-1) * per + 1 ))
    ffmpeg -nostdin -hide_banner -v error \
      -start_number "$start" -i "$dir/%06d.jpg" -frames:v 1 \
      -vf "scale=${COLLAGE_TILE_W}:-2,tile=${COLLAGE_COLS}x${COLLAGE_ROWS}:margin=8:padding=6:color=white" \
      -q:v 3 -y "$OUT/collage/${d}_sheet$(printf '%02d' "$s").jpg" 2>/dev/null
  done
  info "  $d  -> $sheets contact sheet(s), $total frames"
}
