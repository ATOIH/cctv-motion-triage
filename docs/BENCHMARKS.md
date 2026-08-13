# Benchmarks

Every figure measured on the reference archive, on the hardware named below. Nothing here is estimated. Where a number is derived rather than timed, it says so.

## Reference archive

| | |
|---|---|
| Camera | Xiaomi / Mijia `chuangmi.camera.ipc009`, fixed indoor |
| Video | HEVC Main, Level 4.1, 1920x1088, `yuvj420p` |
| Frame rate | variable, nominal 20 fps, **28 distinct measured rates in one day** |
| GOP | 1 keyframe per 59.2 frames = **3.0 s** |
| Audio | PCM A-law (G.711), 8 kHz mono, discarded |
| Container | MP4 (ISOBMFF), one file per minute |
| Span | 13 days, 28 Jul – 9 Aug 2026 |
| Volume | **16,294 clips · 277 hours · ~22 million frames** |

`1088` rather than `1080` because HEVC codes in 64x64 CTUs and 1080 is not a multiple of 64. The encoder pads to 17x64 and this camera does not signal a crop, so those 8 rows are real pixels.

## Hardware

4 cores, software decode only. **No GPU, no VideoToolbox, no NVENC.** Every figure below is CPU-bound; Apple Silicon with hardware decode is materially faster, particularly on the full-decode path.

## Throughput

| Operation | Rate | Notes |
|---|---|---|
| `ffprobe` health check | **177 clips/s** | 8 workers, I/O bound, oversubscribed on purpose |
| Merge, stream copy | **~3,500x realtime** | 4.17 GB in 19.9 s |
| Full decode | 59.7x realtime (1,175 fps) | the baseline to beat |
| `-skip_frame nokey` | 157x realtime | decoder-level skip |
| **`-discard nokey`** | **590x realtime** | demuxer-level discard |

The last three are the same one-hour slice, same machine, same run. `-discard nokey` is **3.8x faster than the decoder-level flag and 10x faster than full decode**, which is what makes scanning 277 hours a 28-minute job rather than a 5-hour one.

## Storage I/O

Measured across the bridge to an external drive, which was the binding constraint:

| | |
|---|---|
| Read | ~830 MB/s |
| Write | 46.1 MB/s |
| Write, 2 parallel writers | 43 MB/s (no gain; slightly worse) |
| Internal scratch disk write | 3.0 GB/s |

Reads were **18x faster than writes**. Parallelism did not move the write ceiling, so it is a limit in the path rather than disk contention. If you hit something similar, build on fast local scratch and copy the finished artifact once.

## Merge results

| Date | Clips | Merged | Rejected | Size | Duration |
|---|---|---|---|---|---|
| 20260728 | 636 | 590 | 46 | 1.39 GiB | 14:43:16 |
| 20260729 | 736 | 723 | 13 | 1.78 GiB | 17:43:11 |
| 20260730 | 1,112 | 1,107 | 5 | 2.60 GiB | 18:55:42 |
| 20260731 | 1,258 | 1,251 | 7 | 2.91 GiB | 20:50:07 |
| 20260801 | 1,318 | 1,310 | 8 | 3.41 GiB | 21:30:41 |
| 20260802 | 1,405 | 1,402 | 3 | 4.44 GiB | 23:16:24 |
| 20260803 | 1,437 | 1,383 | 54 | 4.64 GiB | 23:04:35 |
| 20260804 | 1,439 | 1,402 | 37 | 4.68 GiB | 23:22:48 |
| 20260805 | 1,439 | 1,423 | 16 | 4.68 GiB | 23:43:16 |
| 20260806 | 1,440 | 1,438 | 2 | 4.93 GiB | 23:58:02 |
| 20260807 | 1,439 | 1,403 | 36 | 4.81 GiB | 23:22:54 |
| 20260808 | 1,439 | 1,373 | 66 | 4.51 GiB | 22:53:16 |
| 20260809 | 1,196 | 1,159 | 37 | 3.88 GiB | 19:19:02 |
| **Total** | **16,294** | **15,964** | **330** | **47.7 GiB** | **~277 hrs** |

**330 clips (2.03%) were unreadable** — an `mdat` box with video data but no `moov` index, the signature of losing power mid-write. 86 were sub-200 KB stubs; 244 held substantial data. Any single one of them aborts an unfiltered concat, which is the entire reason the health check exists.

## Digest results

Threshold `scene > 0.015`, analysis at 480 px, output at 960x544.

| | |
|---|---|
| Frames retained | **7,238** |
| Events after grouping (30 s gap) | **1,841** |
| Reel duration, all 13 days | **20 min 06 s** at 6 fps |
| Output size | 313 MiB |
| **Reduction** | **827x** |

Per-day detections ranged from **161** (a quiet Monday) to **1,020** (the busiest day). Do not extrapolate a day from a daytime sample: an 08:00–14:00 window ran at roughly **4x the daily average rate**, which produced a 4x over-estimate on the first pass.

**Precision, sampled:** 30 tiles drawn evenly across 361 detections in a 6-hour window, inspected by eye. **26 contained a person — roughly 87%.** The four misses were door-position changes with nobody visible.

## Verification

| Check | Result |
|---|---|
| Merged files byte-identical after transfer (md5) | 13 / 13 |
| Digest files byte-identical after transfer (md5) | 15 / 15 |
| Container integrity, `-c copy -f null` | 0 warnings across all 13 |
| Digest full decode | 0 errors |
| Gate unit tests | 12 / 12 |

**One caveat worth stating.** The container-level check (`-c copy -f null`) validates the index and timestamps but never decodes, so it cannot see corruption inside the compressed payload. A later full decode surfaced **166 HEVC bitstream errors** — damaged NAL units in clips whose `moov` was perfectly valid, so they passed the health filter. They were concentrated in the first week; the last five days were clean. `ffmpeg` resynchronises at the next NAL and nothing is structurally broken, but "verified" at the container level is a narrower claim than it sounds.

## Reproducing

The pipeline runs end to end on synthetic footage with no archive of your own:

```bash
./test/make-fixture.sh /tmp/fixture   # 8 clips, 2 hour-folders, HEVC, 2 s GOP
SRC=/tmp/fixture OUT=/tmp/out ./bin/gullak run
./test/test-gate.sh                   # 12 assertions, runs in under a second
```

The fixture deliberately contains one clip of each failure class — an empty scene, a crossing subject, a whole-frame brightness flash, and a single-frame speck — so each gate has something to act on.
