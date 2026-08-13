#!/usr/bin/env bash
# lib/merge.sh — stage 1: thousands of per-minute clips -> one file per date.
#
# Lossless. The compressed bitstream is copied, never decoded and re-encoded,
# so the output is bit-for-bit the camera's own encoding. On the reference
# archive this ran at roughly 3,500x realtime.

cmd_merge() {
  require_ffmpeg
  local dates=("$@")
  [ -d "$SRC" ] || die "SRC does not exist: $SRC"
  mkdir -p "$OUT/daily"

  if [ ${#dates[@]} -eq 0 ]; then
    # every YYYYMMDDHH folder collapses to its YYYYMMDD prefix
    while IFS= read -r d; do dates+=("$d"); done < <(
      find "$SRC" -maxdepth 1 -type d -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' \
        | while IFS= read -r p; do basename "$p" | cut -c1-8; done | sort -u)
  fi
  [ ${#dates[@]} -eq 0 ] && die "no YYYYMMDDHH folders under $SRC"

  step "merging ${#dates[@]} date(s) from $SRC"

  local skiplog="$OUT/skipped_clips.csv"
  [ -f "$skiplog" ] || echo "date,hour_folder,filename,size_bytes,reason" > "$skiplog"

  local d
  for d in "${dates[@]}"; do _merge_one_date "$d" "$skiplog"; done
  step "merge complete. excluded clips logged in $skiplog"
}

# Health check for a single clip.
#
# WHY THIS EXISTS AT ALL: the ffmpeg concat demuxer aborts the entire job on
# one malformed input. A camera that loses power mid-clip leaves an mdat box
# with no moov index, which is unreadable and fatal. On the reference archive
# 2.03% of clips were in that state, so an unfiltered run had essentially zero
# chance of completing. This probe is the difference between working and not.
_probe_clip() {
  local f="$1" v
  v=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,width,height,pix_fmt \
        -of csv=p=0:nk=1 "$f" 2>/dev/null | paste -sd, -)
  if [ -z "$v" ]; then printf 'BAD|%s|\n' "$f"; else printf 'OK|%s|%s\n' "$f" "$v"; fi
}
export -f _probe_clip 2>/dev/null || true

_merge_one_date() {
  local d="$1" skiplog="$2"
  local work="$TMPROOT/merge-$d"; rm -rf "$work"; mkdir -p "$work"
  local list="$work/list" probe="$work/probe" concat="$work/concat"
  local out="$OUT/daily/$d.mp4"

  find "$SRC" -maxdepth 2 -type f -name '*.mp4' -path "*/$d*/*" | LC_ALL=C sort > "$list"
  local total; total=$(wc -l < "$list" | tr -d ' ')
  [ "$total" -eq 0 ] && { warn "$d: no clips, skipped"; return; }

  printf '  %s  probing %s clips ... ' "$d" "$total" >&2
  parallel_lines _probe_clip "$JOBS" < "$list" > "$probe"
  local good bad
  good=$(grep -c '^OK'  "$probe" || true)
  bad=$(grep -c  '^BAD' "$probe" || true)
  printf 'ok=%s bad=%s\n' "$good" "$bad" >&2
  [ "$good" -eq 0 ] && { warn "$d: every clip unreadable, skipped"; return; }

  # nothing disappears silently
  grep '^BAD' "$probe" | cut -d'|' -f2 | while IFS= read -r f; do
    printf '%s,%s,%s,%s,unreadable_no_moov_atom\n' \
      "$d" "$(basename "$(dirname "$f")")" "$(basename "$f")" "$(fsize "$f")" >> "$skiplog"
  done

  # Order on the epoch embedded in the filename (MMmSSs_<epoch>.mp4) rather than
  # on the path. The epoch is absolute; lexical path order only happens to work.
  grep '^OK' "$probe" | cut -d'|' -f2 \
    | awk -F/ '{n=$NF; split(n,a,"_"); split(a[2],b,"."); print b[1]"\t"$0}' \
    | LC_ALL=C sort -k1,1n | cut -f2- \
    | sed "s/'/'\\\\''/g; s/^/file '/; s/\$/'/" > "$concat"

  local audio; if [ "${KEEP_AUDIO:-0}" -eq 1 ]; then audio=(-map 0:a? -c:a copy); else audio=(-an); fi

  # -tag:v hvc1  : Apple's AVFoundation refuses to play hev1-tagged HEVC, so
  #                without this the output will not open in QuickTime at all.
  # +faststart   : moves the moov index to the front of the file so playback
  #                and seeking start instantly instead of after a full read.
  ffmpeg -nostdin -hide_banner -v error -stats \
    -f concat -safe 0 -fflags +genpts -i "$concat" \
    -map 0:v:0 -c:v copy "${audio[@]}" \
    -tag:v hvc1 -movflags +faststart -y "$out" || { warn "$d: merge failed"; return; }

  local dur; dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out")
  info "  $d  -> $(basename "$out")  $(hms "${dur%.*}")  $(( $(fsize "$out") / 1048576 )) MiB"
}
