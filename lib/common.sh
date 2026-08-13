#!/usr/bin/env bash
# lib/common.sh — shared helpers. Sourced by every command.
#
# Portability note: this repo targets BSD userland (macOS) first, GNU second.
# That rules out `xargs -d`, `stat -c`, `readlink -f` and GNU-only `date`
# arithmetic. Where a GNU-ism is unavoidable there is a BSD branch beside it.

set -uo pipefail

# ---------------------------------------------------------------- output ----

_c_red=$'\033[31m'; _c_dim=$'\033[2m'; _c_bold=$'\033[1m'; _c_off=$'\033[0m'
[ -t 2 ] || { _c_red=''; _c_dim=''; _c_bold=''; _c_off=''; }

# One scratch directory for the whole run, cleaned up on any exit.
#
# Deliberately NOT a per-function `trap ... RETURN`: bash RETURN traps are not
# scoped to the function that set them, so the trap fires again when the caller
# returns, by which point the variable it references is gone. Under `set -u`
# that turns into "unbound variable" from a line that looks unrelated.
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/gullak.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

log()  { printf '%s\n' "$*" >&2; }
info() { printf '%s%s%s\n' "$_c_dim" "$*" "$_c_off" >&2; }
step() { printf '%s==>%s %s\n' "$_c_bold" "$_c_off" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$_c_red" "$_c_off" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

# ------------------------------------------------------------ portability ---

# File size in bytes. Both spellings are tried AND the result is validated,
# because `stat -f` on GNU means --file-system: it exits 0 and prints a block
# of text that is not a number, so an exit-status-only fallback silently
# poisons any arithmetic downstream.
fsize() {
  local s
  s=$(stat -f %z "$1" 2>/dev/null || true)
  case "$s" in ''|*[!0-9]*) s=$(stat -c %s "$1" 2>/dev/null || true) ;; esac
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  printf '%s' "$s"
}

# run a function across stdin lines, N at a time, NUL-delimited so paths with
# spaces survive. BSD xargs has no -d, so we convert newlines ourselves.
parallel_lines() {
  local fn="$1" jobs="$2"
  tr '\n' '\0' | xargs -0 -P "$jobs" -I{} bash -c "$fn \"\$@\"" _ {}
}

# seconds -> HH:MM:SS
hms() {
  awk -v x="${1:-0}" 'BEGIN{
    s=int(x); printf "%02d:%02d:%02d", int(s/3600), int((s%3600)/60), s%60 }'
}

# --------------------------------------------------------------- preflight --

require_ffmpeg() {
  command -v ffmpeg  >/dev/null || die "ffmpeg not found. Install: brew install ffmpeg"
  command -v ffprobe >/dev/null || die "ffprobe not found. Install: brew install ffmpeg"
}

# ffmpeg 5.0 renamed -vsync to -fps_mode; 4.x rejects the new spelling and 8.x
# will eventually drop the old one. Rather than parse a version string (builds
# report everything from "6.1.1-3ubuntu5" to "N-113455-g8a3f8b1"), just ask the
# binary to do it once and see whether it complains.
_FPS_FLAG_CACHE=""
fps_passthrough_flag() {
  if [ -z "$_FPS_FLAG_CACHE" ]; then
    if ffmpeg -hide_banner -loglevel quiet -f lavfi -i nullsrc=s=16x16:d=0.1 \
         -fps_mode passthrough -frames:v 1 -f null - >/dev/null 2>&1; then
      _FPS_FLAG_CACHE='-fps_mode passthrough'
    else
      _FPS_FLAG_CACHE='-vsync 0'
    fi
  fi
  printf -- '%s' "$_FPS_FLAG_CACHE"
}

# ------------------------------------------------------------------ config --

# Load config.env if present, then allow environment overrides.
load_config() {
  local root="$1"
  [ -f "$root/config.env" ] && . "$root/config.env"

  : "${SRC:=}"                       # camera archive root
  : "${OUT:=}"                       # where outputs are written
  : "${JOBS:=8}"                     # parallel ffprobe workers

  # --- detection ---------------------------------------------------------
  : "${SCENE_HI:=0.015}"             # threshold to OPEN an event
  : "${SCENE_LO:=0.008}"             # threshold to EXTEND an open event
  : "${DETECT_WIDTH:=480}"           # analysis width; smaller = faster + less noise
  : "${BLUR:=1.2}"                   # gaussian sigma before differencing
  : "${ROI:=}"                       # crop as w:h:x:y, empty = whole frame
  : "${MIN_HITS:=1}"                 # keyframes an event must span to count
  : "${YAVG_MAX_DELTA:=12}"          # reject frames whose mean luma jumped this much
  : "${EVENT_GAP:=30}"               # seconds of quiet that ends an event

  # --- render ------------------------------------------------------------
  : "${DIGEST_WIDTH:=960}"
  : "${DIGEST_FPS:=6}"
  : "${DIGEST_CRF:=21}"
  : "${COLLAGE_COLS:=6}"
  : "${COLLAGE_ROWS:=5}"
  : "${COLLAGE_TILE_W:=320}"
}
