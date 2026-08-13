# gullak

**Turn an unwatchable pile of CCTV clips into the few minutes that actually matter.**

My son's piggy bank went missing on a Sunday morning. Finding it meant going through 16,294 one-minute clips from a six-year-old Xiaomi camera. 277 hours of footage.

The obvious move is to play it faster. That does not work: at 16x you are still committing 17 hours to watching an empty corridor, and a 60Hz screen throws away four frames in five before your eye gets them.

So the question changed. Not *how do I watch 277 hours quickly*, but *which 20 minutes contain anything at all*.

This repo is the answer to the second question. On the archive it was built for:

| | |
|---|---|
| Input | 16,294 clips · 277 hours · 47.7 GiB |
| Output | one 20-minute reel · 1,841 indexed events · 313 MiB |
| Reduction | **827x** |
| Time to find the piggy bank, once the reel existed | 15 minutes |

Full write-up: [the LinkedIn post](#the-story) · the measurement record is in `docs/BENCHMARKS.md`.

---

## Is this for you

It is, if you have a fixed camera and more footage than anyone will ever watch:

- a warehouse aisle, a loading bay, a stock room
- a shop floor, a till, a back door
- a lobby, a lift landing, a corridor

It is not a person detector or a re-identification system. There is no model here and nothing is uploaded anywhere. It is frame differencing plus three noise gates, and it runs entirely on your machine using `ffmpeg`. That is the point: it is small enough to read in an afternoon and change to fit your scene.

---

## Quick start

```bash
brew install ffmpeg          # the only dependency
git clone https://github.com/ATOIH/cctv-motion-triage && cd cctv-motion-triage

cp config.example.env config.env
$EDITOR config.env           # set SRC and OUT

./bin/gullak doctor          # checks ffmpeg, config, and your keyframe interval
./bin/gullak run             # merge, then digest, every date found
```

Outputs land under `OUT`:

```
daily/     YYYYMMDD.mp4              one lossless file per date
digest/    YYYYMMDD_motion.mp4       only the moments something moved
digest/    ALL_DAYS_motion.mp4       every day, one reel
collage/   YYYYMMDD_sheetNN.jpg      contact sheets of every motion frame
motion_events_index.csv              every event, in both timebases
skipped_clips.csv                    every clip excluded, and why
```

Try it without any footage of your own:

```bash
./test/make-fixture.sh /tmp/fixture
SRC=/tmp/fixture OUT=/tmp/out ./bin/gullak run
./test/test-gate.sh          # 12 assertions on the detection gates
```

### How you actually use the output

Scan `ALL_DAYS_motion.mp4`. Most cameras burn a clock into the frame, so when you see the moment you care about you read the timestamp straight off the picture, open the matching `daily/YYYYMMDD.mp4`, and seek there for full resolution. `motion_events_index.csv` maps every event to its position in **both** files, so you can jump either way:

```csv
date,event,source_file_start,source_file_end,frames,digest_position
20260806,42,11:41:14,11:41:29,6,00:02:18
```

---

## What it does

Three stages. Each is independently useful and each is one command.

### 1. Merge — thousands of clips to one file per date

Lossless. The compressed bitstream is copied, never decoded and re-encoded, so the output is bit-for-bit the camera's own encoding. Roughly 3,500x realtime.

The step that makes this work at all is the health check. The `ffmpeg` concat demuxer aborts the whole job on one malformed input, and a camera that loses power mid-clip leaves a file with video data but no index. **2.03% of the reference archive was in that state**, so an unfiltered run had essentially no chance of finishing. Every clip is probed first and every exclusion is logged.

### 2. Digest — one file per date to only the moments something moved

Reads **keyframes only**, via `-discard nokey`. That one flag is the difference between a 5-hour scan and a 28-minute one. See `docs/ARCHITECTURE.md` for why it beats the more obvious `-skip_frame nokey` by 3.8x.

Each surviving keyframe is compared to the last. A static corridor scores near zero; a person does not. What survives is re-timed into a continuous 6 fps reel.

### 3. Collage — every motion frame as a contact sheet

Tiled JPEG sheets of every detected frame. Faster to scan by eye than any timeline, and each tile carries the camera's own burnt-in clock, so a hit on a sheet is directly addressable in the full-resolution file.

---

## The three noise gates

Frame differencing on its own is naive. It cannot tell a person from a cloud crossing the sun. Three gates handle the classes of false positive that actually show up, and all three are configurable because the right setting depends on your scene:

| Gate | Kills | How |
|---|---|---|
| **Illumination** | Lights switching on, headlights sweeping, auto-exposure corrections | A whole-frame brightness change moves *mean luma*. A person occupies a fraction of the frame and barely moves it. Big score plus big luma jump means light, not intruder. |
| **Persistence** | Insects on the lens, rain streaks, a shadow edge flickering | Transients trip exactly one keyframe. A human crossing a space is present for several. `MIN_HITS` sets the floor. |
| **Hysteresis** | Motion that visibly stutters in the reel | Two thresholds: a high one to open an event, a low one to keep frames in it. Stops a subject vanishing for a frame mid-stride. |

They are unit tested. `./test/test-gate.sh` runs 12 assertions, including the case that matters most: a gentle auto-exposure ramp must *not* be eaten by the illumination gate even though its total drift exceeds the threshold.

`docs/TUNING.md` covers how to set these for an outdoor camera, a busy aisle, or a scene with a swinging door.

---

## Configuration

Everything is environment variables, settable in `config.env` or inline. Full list: `./bin/gullak help`. The ones that change results:

```bash
SCENE_HI=0.015        # score that opens an event. Raise for fewer, surer hits
SCENE_LO=0.008        # score that sustains one. Keep well below SCENE_HI
MIN_HITS=1            # keyframes an event must span. 2+ kills transients
YAVG_MAX_DELTA=12     # mean-luma jump treated as a lighting change
ROI=800:600:100:200   # w:h:x:y — analyse only the part of frame you care about
EVENT_GAP=30          # seconds of quiet that closes an event
```

`ROI` is the highest-leverage setting for an outdoor camera. Cropping out sky, trees and a busy road before differencing removes more false positives than any threshold change.

---

## Known limits

Stated plainly, because they matter more than the features:

- **Temporal resolution is your keyframe interval.** The reference camera writes one keyframe every 3.0 seconds, so anyone crossing faster than that can be missed entirely. `./bin/gullak doctor` measures yours. `docs/TUNING.md` explains the full-decode path that closes this gap, and what it costs.
- **This is motion, not people.** A swinging door, a cat, a delivery trolley all register. The gates reduce noise; they do not classify.
- **Tuned on one scene.** The defaults come from a fixed indoor landing under constant artificial light, which is close to the easiest possible case. An outdoor camera needs `ROI` and a higher `MIN_HITS` before the defaults mean anything.
- **No re-identification, no faces, no tracking.** Out of scope by choice.

---

## The story

This was built to find a child's piggy bank, and it worked. The wider point is that the same shape of problem sits in a lot of warehouses: footage nobody has time to watch, an event nobody can find, and a review cost that scales with hours rather than with incidents.

The consulting pitch in the mid-2010s was that one day video analytics would flag a till opening while the cashier walked out of shot. That capability is now four hundred lines of shell and a tool that ships with your operating system.

Take it, fork it, make it better.

---

## Contributing

Issues and pull requests welcome. Two asks:

1. Run `./test/test-gate.sh` before opening a PR. If you change gate behaviour, add the assertion that proves it.
2. Keep it BSD-safe. This targets macOS first, so no `xargs -d`, no `stat -c` without a fallback, no `readlink -f`. `lib/common.sh` has the helpers.

MIT licensed. See `LICENSE`.
