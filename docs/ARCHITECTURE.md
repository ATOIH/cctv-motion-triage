# Architecture

Why this is shaped the way it is. Every number here was measured on the reference archive, not estimated. `BENCHMARKS.md` has the raw figures.

## Context

A fixed indoor camera writing one MP4 per minute to an SD card. Thirteen days retrieved: **16,294 clips, 277 hours, 47.7 GiB**, HEVC 1920x1088 at a nominal 20 fps, with PCM A-law audio nobody needs.

The goal was never "watch this footage". It was "find the ninety seconds where something happened". Those are different problems and they have different solutions, which is the single most important thing in this repo.

## Data flow

```
  SD card / archive
        |
        |  YYYYMMDDHH/MMmSSs_<epoch>.mp4
        v
  [1] PROBE          ffprobe every clip, reject the ones with no index
        |            2.03% of the reference archive. One of them aborts the job.
        v
  [2] MERGE          concat demuxer + stream copy -> one file per date
        |            ~3,500x realtime. Bit-for-bit identical to the source.
        v
  [3] SCAN           -discard nokey: keyframes only, 590x realtime
        |            scale -> greyscale -> blur -> signalstats -> scene score
        v
  [4] GATE           illumination / persistence / hysteresis  (lib/gate.awk)
        |            the only place a judgement call is encoded, so the only
        |            place with unit tests
        v
  [5] RENDER         surviving frames -> 6 fps reel + contact sheets + CSV index
```

## Key decisions

### Stream copy, never re-encode

Re-encoding 22 million frames of 1080p with a software encoder is roughly **8.5 days of CPU**. Copying the compressed stream is **20 seconds per day of footage** and is lossless.

This holds because concatenation only requires that the *decoder configuration* match across inputs — codec, resolution, profile, chroma format, bit depth — which live in the parameter sets. Frame timing is container metadata and gets rewritten anyway. The reference archive turned out to be variable frame rate, with **28 distinct measured rates in a single day**, and it concatenated cleanly regardless. Verify before assuming:

```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,pix_fmt -of csv=p=0 clip.mp4
```

If that string is identical across your archive, stream copy is safe.

### `-discard nokey`, not `-skip_frame nokey`

Both sound like "skip non-keyframes". Measured on the same one-hour slice:

| Method | Level | Speed | Full 277 hours |
|---|---|---|---|
| full decode | — | 59.7x realtime | ~5.2 hrs |
| `-skip_frame nokey` | decoder | 157x | ~2.0 hrs |
| **`-discard nokey`** | **demuxer** | **590x** | **~28 min** |

`-skip_frame` sets `AVCodecContext.skip_frame`: packets still reach the decoder, headers are still parsed, only reconstruction is skipped. `-discard` sets `AVStream.discard = AVDISCARD_NONKEY` and the demuxer drops those packets so the decoder never sees them.

That distinction is worth 3.8x, and it is the difference between this being a practical tool and a weekend job.

**The cost:** temporal resolution is pinned to the keyframe interval, 3.0 seconds on the reference camera. `TUNING.md` covers when to pay for full decode instead.

### Order inside the filtergraph

```
crop -> scale -> format=gray -> gblur -> signalstats -> select -> metadata
```

Not arbitrary:

- **crop first** so nothing downstream wastes work on pixels you have excluded
- **scale before differencing** because it is the cheapest noise rejection available: small high-frequency detail (insects, rain, sensor grain) disappears at a quarter resolution while a person survives intact
- **greyscale** because scene detection reads luma anyway
- **blur** to finish what the downscale started
- **signalstats before select** so mean luma is attached to every candidate frame, which is what the illumination gate needs
- **select last**, and deliberately permissive: it uses `SCENE_LO`, not `SCENE_HI`. Real decisions happen in the gate, where they can be tested.

### One decode pass, not two

The scan writes JPEGs in the same order it prints metadata, so frame *N* of the sequence is line *N* of the CSV. The gate returns indices; rendering is then a file copy.

The alternative — decide first, then seek back to extract each frame — means thousands of seeks into a multi-gigabyte file. This way the expensive operation happens exactly once.

It also means the contact sheets come free: the frames are already on disk.

### Gates in awk, not in the filtergraph

`ffmpeg` can threshold. It cannot express "this frame scored high but so did mean luma, so it is a light switching on, not a person". Once logic needs memory of previous frames and a rule over the sequence, it belongs outside the filtergraph.

Putting it in a separate `awk` program means it is testable without any video at all. `test/test-gate.sh` runs 12 assertions in under a second, including cases that would take hours to reproduce with real footage.

### Bash, not Python

One dependency: `ffmpeg`. No virtualenv, no lockfile, no version drift. Anyone who can run `brew install ffmpeg` can run this today and in five years. The whole thing is short enough to read before trusting it, which for a tool that watches your premises is the point.

## Portability

macOS BSD userland first, GNU second. The traps that actually bit during development:

- **`xargs -d` does not exist on BSD.** Use `tr '\n' '\0' | xargs -0`.
- **`stat -f` means `--file-system` on GNU.** It exits 0 and prints text that is not a number, so an exit-status-only fallback silently poisons downstream arithmetic. `fsize()` validates the output rather than trusting the exit code.
- **`-vsync` became `-fps_mode` in ffmpeg 5.0.** Build strings range from `6.1.1-3ubuntu5` to `N-113455-g8a3f8b1`, so rather than parse a version, `fps_passthrough_flag()` runs a one-frame null encode and sees whether the binary complains.
- **Bash `RETURN` traps are not function-scoped.** A trap set inside a function fires again when its caller returns, referencing a variable that no longer exists. Under `set -u` that surfaces as "unbound variable" pointing at an unrelated line. One scratch root with a single `EXIT` trap, created in `common.sh`.

## What is deliberately absent

- **No object detection.** A model would classify person vs cat vs trolley, and would need weights, a runtime, and a GPU to be quick. The gates get most of the value for none of that cost. If you need classification, this is the right pre-filter to put in front of it: run the model on 7,238 frames instead of 22 million.
- **No database.** A CSV that opens in Excel is the correct interface for 1,841 rows.
- **No daemon, no watch mode.** This is a batch tool for footage that already exists.
- **No cloud, no upload, no telemetry.** Footage of your premises never leaves your machine.
