# lib/gate.awk — turns raw per-keyframe scores into events.
#
# Input : idx,pts_time,scene_score,yavg   (one line per candidate keyframe)
# Output: two files
#           keep   -> frame indices that survive, one per line
#           events -> date,event,src_start,src_end,frames,digest_pos
#
# Three gates, in order. Each exists because of a specific false positive that
# frame differencing alone cannot tell from a person.
#
#   1. ILLUMINATION. A light switching on, a car's headlights sweeping a wall,
#      an auto-exposure correction: every pixel changes at once, so the scene
#      score spikes hard. The tell is that MEAN LUMA moves with it. A person
#      walking through occupies a fraction of the frame and barely shifts the
#      mean. So: big score AND big mean-luma jump means light, not intruder.
#
#   2. PERSISTENCE. An insect crossing the lens, a rain streak, a shadow edge
#      flickering: these trip exactly one keyframe. A human crossing a space
#      is present for several seconds and therefore several keyframes. Requiring
#      MIN_HITS keyframes in one event discards the transient class wholesale.
#      Cost: raising MIN_HITS above 1 will also discard a genuinely fast transit.
#      See docs/TUNING.md before you touch it.
#
#   3. HYSTERESIS. One threshold produces fragmented events, because a person
#      mid-stride can dip below it for a frame. Two thresholds fix that: HI to
#      open an event, LO to keep it open. Standard edge-detection practice,
#      borrowed wholesale.

BEGIN {
    FS = ","
    if (HI    == "") HI    = 0.015
    if (LO    == "") LO    = 0.008
    if (MINH  == "") MINH  = 1
    if (YMAX  == "") YMAX  = 12
    if (GAP   == "") GAP   = 30
    if (FPS   == "") FPS   = 6
    n = 0
}

{
    n++
    idx[n] = $1 + 0
    t[n]   = $2 + 0
    s[n]   = $3 + 0
    y[n]   = $4 + 0
}

END {
    if (n == 0) { print "gate: no candidate frames" > "/dev/stderr"; exit 0 }

    # ---- gate 1: illumination ------------------------------------------
    dropped_lum = 0
    for (i = 1; i <= n; i++) {
        lum_ok[i] = 1
        if (i > 1) {
            dy = y[i] - y[i-1]; if (dy < 0) dy = -dy
            if (dy > YMAX) { lum_ok[i] = 0; dropped_lum++ }
        }
    }

    # ---- gate 3: hysteresis grouping ------------------------------------
    # walk forward; HI opens, LO sustains, GAP seconds of silence closes
    ev = 0; open = 0
    for (i = 1; i <= n; i++) {
        if (!lum_ok[i]) continue
        qualifies = (open ? (s[i] >= LO) : (s[i] >= HI))
        if (!qualifies) continue

        if (open && (t[i] - last_t) > GAP) open = 0

        if (!open) { ev++; open = 1; e_start[ev] = t[i]; e_count[ev] = 0 }
        e_end[ev]  = t[i]
        e_count[ev]++
        member[i]  = ev
        last_t     = t[i]
    }

    # ---- gate 2: persistence -------------------------------------------
    kept_ev = 0; dropped_ev = 0
    for (k = 1; k <= ev; k++) {
        if (e_count[k] >= MINH) { alive[k] = ++kept_ev } else { dropped_ev++ }
    }

    # ---- emit ------------------------------------------------------------
    pos = 0
    for (i = 1; i <= n; i++) {
        k = member[i]
        if (k == "" || !(k in alive)) continue
        print idx[i] > KEEP
        if (!(alive[k] in seen_pos)) { ev_pos[alive[k]] = pos; seen_pos[alive[k]] = 1 }
        pos++
    }
    for (k = 1; k <= ev; k++) {
        if (!(k in alive)) continue
        a = alive[k]
        printf "%s,%d,%s,%s,%d,%s\n", DATE, a, hms(e_start[k]), hms(e_end[k]),
               e_count[k], hms(ev_pos[a] / FPS) > EVENTS
    }

    printf "  gate: %d candidates -> %d frames in %d events (dropped %d on luma, %d events under %d hits)\n",
           n, pos, kept_ev, dropped_lum, dropped_ev, MINH > "/dev/stderr"
}

function hms(x,   h, m, sec) {
    sec = int(x); h = int(sec / 3600); m = int((sec % 3600) / 60); sec = sec % 60
    return sprintf("%02d:%02d:%02d", h, m, sec)
}
