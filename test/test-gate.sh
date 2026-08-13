#!/usr/bin/env bash
# test/test-gate.sh — assertions for lib/gate.awk.
#
# The gates are the only place in this repo where a judgement call is encoded,
# so they are the only place that genuinely needs tests. Each case below maps
# to a false positive seen in real footage.
#
#   run:  ./test/test-gate.sh
set -uo pipefail
cd "$(dirname "$0")/.."
GATE="lib/gate.awk"
pass=0; fail=0

# run_gate <csv> <HI> <LO> <MINH> <YMAX> <GAP>  -> prints "<frames> <events>"
run_gate() {
  local csv="$1" hi="$2" lo="$3" minh="$4" ymax="$5" gap="$6"
  local k="$TMPD/keep" e="$TMPD/events"
  : > "$k"; : > "$e"
  printf '%s\n' "$csv" | awk -v HI="$hi" -v LO="$lo" -v MINH="$minh" \
      -v YMAX="$ymax" -v GAP="$gap" -v FPS=6 -v DATE=T \
      -v KEEP="$k" -v EVENTS="$e" -f "$GATE" 2>/dev/null
  printf '%s %s' "$(wc -l < "$k" | tr -d ' ')" "$(wc -l < "$e" | tr -d ' ')"
}

check() { # check <name> <got> <want>
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s   got [%s] want [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
echo "gate.awk"

# --- 1. a person: four consecutive strong frames, steady light -------------
CSV='1,10.0,0.400,120
2,13.0,0.380,120
3,16.0,0.360,121
4,19.0,0.350,120'
check "person: 4 frames -> 1 event"            "$(run_gate "$CSV" 0.015 0.008 1 12 30)" "4 1"
check "person: survives MIN_HITS=3"            "$(run_gate "$CSV" 0.015 0.008 3 12 30)" "4 1"

# --- 2. an insect / rain streak: one isolated frame ------------------------
CSV='1,10.0,0.002,120
2,13.0,0.400,120
3,16.0,0.004,120
4,19.0,0.003,120'
check "blip: kept when MIN_HITS=1"             "$(run_gate "$CSV" 0.015 0.008 1 12 30)" "1 1"
check "blip: killed when MIN_HITS=2"           "$(run_gate "$CSV" 0.015 0.008 2 12 30)" "0 0"

# --- 3. lights on: score spikes AND mean luma jumps ------------------------
CSV='1,10.0,0.002,60
2,13.0,0.900,180
3,16.0,0.002,181
4,19.0,0.001,180'
check "lights on: killed by luma gate"         "$(run_gate "$CSV" 0.015 0.008 1 12 30)" "0 0"
check "lights on: kept if luma gate disabled"  "$(run_gate "$CSV" 0.015 0.008 1 999 30)" "1 1"

# --- 4. a person under a light that is also changing ----------------------
# luma drifts gently (auto-exposure) while a real subject crosses. The gate
# must not eat this: each step is under YMAX even though the total drift is not.
CSV='1,10.0,0.300,120
2,13.0,0.310,128
3,16.0,0.320,136
4,19.0,0.330,144'
check "drift: gentle exposure ramp survives"   "$(run_gate "$CSV" 0.015 0.008 1 12 30)" "4 1"

# --- 5. hysteresis: a mid-stride dip must stay in the reel -----------------
# Event boundaries are governed by EVENT_GAP, not by the threshold, so both
# settings yield one event. What the second threshold buys is FRAME retention:
# with LO the dip frame stays in the reel and the motion plays continuously;
# with a single threshold it is dropped and the subject visibly jumps.
CSV='1,10.0,0.400,120
2,13.0,0.009,120
3,16.0,0.400,120'
check "hysteresis: dip frame retained"         "$(run_gate "$CSV" 0.015 0.008 1 12 30)" "3 1"
check "single threshold: dip frame lost"       "$(run_gate "$CSV" 0.015 0.015 1 12 30)" "2 1"

# --- 6. two separate visits, far apart ------------------------------------
CSV='1,10.0,0.400,120
2,13.0,0.380,120
3,300.0,0.400,120
4,303.0,0.390,120'
check "gap: 287s apart -> 2 events"            "$(run_gate "$CSV" 0.015 0.008 1 12 30)" "4 2"
check "gap: raise EVENT_GAP -> 1 event"        "$(run_gate "$CSV" 0.015 0.008 1 12 400)" "4 1"

# --- 7. an empty corridor produces nothing --------------------------------
CSV='1,10.0,0.001,120
2,13.0,0.002,120
3,16.0,0.001,120'
check "empty scene: no events"                 "$(run_gate "$CSV" 0.015 0.008 1 12 30)" "0 0"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
