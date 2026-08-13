# Tuning

The defaults were derived from one scene: a fixed indoor landing, artificial light 24 hours a day, no windows. That is close to the easiest case frame differencing can be given. **If your camera sees daylight, the defaults are a starting point and nothing more.**

Work in this order. Each step is worth more than the one after it.

---

## 1. Measure your keyframe interval first

Everything else depends on it.

```bash
./bin/gullak doctor
```

It reports something like `1 keyframe per 59.2 frames`. At 20 fps that is one sample every 3.0 seconds, which is the finest motion resolution this approach can give you.

**Ask yourself: how long is a person visible in my frame?** A doorway where someone approaches, opens and passes through gives you 4 to 10 seconds, so a 3-second sample catches it comfortably. A camera looking down a corridor that someone crosses in 1.5 seconds will miss people, and no threshold change fixes that. Go to section 6.

---

## 2. Set an ROI. This beats every other setting.

```bash
ROI=w:h:x:y      # e.g. ROI=1200:700:300:380
```

Cropping before differencing removes false positives at the source rather than filtering them afterwards. For an outdoor camera it is the difference between usable and useless. Exclude:

- sky and clouds
- trees, hedges, anything that moves in wind
- a public road or pavement
- a monitor or TV in shot
- any area with a repeating machine cycle

Find the numbers by exporting a frame and reading coordinates off it:

```bash
ffmpeg -i daily/20260806.mp4 -frames:v 1 -y frame.png
# then check your crop before committing to a full run
ffmpeg -i frame.png -vf "crop=1200:700:300:380" -y roi-check.png
```

A tight ROI can cut false positives by an order of magnitude and speeds the scan up at the same time.

---

## 3. Set MIN_HITS for your transient problem

```bash
MIN_HITS=1    # default. Keeps everything, including single-frame noise
MIN_HITS=2    # kills insects, rain streaks, single-frame shadow flicker
MIN_HITS=3    # aggressive. Only for very noisy outdoor scenes
```

An event must span this many keyframes to be reported. A fly crossing the lens trips exactly one. A person trips several.

**The trade-off is explicit and you should hold it consciously:** at a 3-second keyframe interval, `MIN_HITS=2` means an event must last at least ~3 seconds to be reported. Anyone faster is now invisible. On a doorway camera that is nearly free. On a corridor camera it may be unacceptable.

Spiders are the classic case. A web across the lens at night, lit by IR, produces motion on every frame for hours. `MIN_HITS` will not save you there; `ROI` and a lens clean will.

---

## 4. Then the thresholds

```bash
SCENE_HI=0.015    # opens an event
SCENE_LO=0.008    # sustains one
```

Change `SCENE_HI` only after ROI and `MIN_HITS` are set, because those two change what the distribution of scores even looks like.

| Symptom | Change |
|---|---|
| Too many empty frames in the reel | raise `SCENE_HI` to 0.025, then 0.04 |
| A person you know about is missing | lower `SCENE_HI` to 0.010, then 0.006 |
| Subject flickers in and out mid-walk | lower `SCENE_LO` (widen the gap to `SCENE_HI`) |
| Events fragment into many short ones | raise `EVENT_GAP` |

Keep `SCENE_LO` at roughly half of `SCENE_HI`. Setting them equal disables hysteresis and the reel gets visibly jumpy.

**Calibrate on evidence, not by feel.** Run a window you already know contains activity, then look at the contact sheets:

```bash
SCENE_HI=0.02 ./bin/gullak digest 20260806
open out/collage/20260806_sheet01.jpg
```

Count how many tiles contain a person. That number is your precision. The reference tuning was accepted at roughly 87%, which is 26 of 30 sampled tiles.

---

## 5. The illumination gate

```bash
YAVG_MAX_DELTA=12     # default
```

Mean luma is 0 to 255. If it moves more than this between consecutive candidate frames, the frame is treated as a lighting change and discarded.

| Scene | Setting |
|---|---|
| Constant artificial light, no windows | 12, or raise to 30 — it will rarely fire |
| Windows, daylight, changing cloud | 8 to 12 |
| IR cut-over at dusk and dawn | 6 to 8, and expect to lose those two transitions |
| Vehicle headlights sweeping the wall | 6 |

Set it to 999 to disable. Then run the reel and see whether the false positives you get are whole-frame brightness jumps. If they are, bring it back down.

**It cannot catch everything.** A light that ramps slowly — an auto-exposure correction over ten seconds — moves under the threshold on every individual step and survives. That behaviour is deliberate and tested (`drift: gentle exposure ramp survives`), because the same slow-ramp pattern is what a real subject entering a dim room looks like. Choosing to catch one means losing the other.

---

## 6. When 3-second sampling is not enough

If people genuinely cross your frame faster than the keyframe interval, keyframe-only scanning cannot see them and no parameter will change that. Two real options:

**Option A — re-encode with a shorter GOP.** If you control the camera, set a 1-second keyframe interval. Storage goes up perhaps 10 to 15%; motion resolution triples. This is the right fix and the cheapest one.

**Option B — full decode.** Drop `-discard nokey` and difference every frame. Roughly **10x the compute**: about 5.2 hours for 277 hours of footage on four software cores, or nearer 40 minutes on Apple Silicon with VideoToolbox hardware decode.

```bash
ffmpeg -hwaccel videotoolbox -i daily/20260806.mp4 \
  -vf "scale=480:-2,format=gray,gblur=sigma=1.2,signalstats,select='gt(scene,0.008)',metadata=print:file=raw.txt" \
  -an -f null -
```

Note the flag is gone, and add `-hwaccel` for your platform. At full frame rate you will want `MIN_HITS` around 6 to 10, since a person now spans dozens of frames rather than a few.

---

## Suggested starting points

**Indoor, constant light, doorway** (the reference case)

```bash
SCENE_HI=0.015; SCENE_LO=0.008; MIN_HITS=1; YAVG_MAX_DELTA=12; ROI=
```

**Warehouse aisle, high ceiling, fluorescent, forklifts**

```bash
SCENE_HI=0.020; SCENE_LO=0.010; MIN_HITS=2; YAVG_MAX_DELTA=15
ROI=<crop out the racking you do not care about>
EVENT_GAP=45
```

**Outdoor loading bay, daylight and weather**

```bash
SCENE_HI=0.030; SCENE_LO=0.015; MIN_HITS=3; YAVG_MAX_DELTA=8
ROI=<crop out sky, trees and the road>
```

**Till or cash register, close framing**

```bash
SCENE_HI=0.010; SCENE_LO=0.005; MIN_HITS=1; YAVG_MAX_DELTA=10
ROI=<tight on the drawer and the operator position>
EVENT_GAP=15
```

Whatever you land on, validate it against a window where you already know what happened. A tuning you have not checked against known ground truth is a guess.
