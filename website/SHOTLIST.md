# Clip shot list

Eight clips cover the whole site. Each is silent, loops, and should make sense with no sound and no caption.
The home page reuses `parameters`, `extrude` and `export` as 4:3 tiles (cropped from the centre), so keep the action
near the middle of the frame in those three.

## How to record

- Size the SimplMaker window to **16:9** (for example 1600 × 900 points) and record only the window (⇧⌘5 → *Record Selected Portion*).
- Use **dark mode**: it sits well on the dark frames and makes the blue/orange handles pop. Hide the welcome window.
- Slow, deliberate mouse. Pause half a second before and after each action. No cursor wiggling.
- 6 to 12 seconds each. The end should look like the start (or be a clean cut), so the loop does not jump.
- Use one part throughout, so the clips feel like one product: the **box with a lid**, or a small bracket with a hole.
- Save each recording into `website/clips-raw/` named after the clip, then run `website/make-clips.sh`.

## The clips

| File | Where | What happens (≈ seconds) |
|---|---|---|
| `hero` | home hero | A condensed story: sketch a rectangle (2) → extrude it (2) → fillet the edges (2) → change `width` in Parameters and the part rebuilds (3) → end on the finished part (1). 12 s. |
| `parameters` | features 01, home tile | Select the width parameter, type a new value, press Return. The sketch, extrusion and fillet all follow. Do it twice (one bigger, one smaller). The best clip on the site: spend time on it. |
| `sketch` | features 02 | Draw a bracket profile with line and arc, add two dimensions, drag a corner and let the solver move the sketch. Show the constraint symbols. |
| `extrude` | features 03, home tile | Click a profile, drag the extrude arrow up, type a value, switch between join and cut. |
| `finish` | features 04 | Select edges → fillet; shell the body hollow; add a hole and a thread. Three quick beats. |
| `timeline` | features 05 | Click an early sketch in the timeline, change a dimension, watch every later feature rebuild. Show a red triangle on a failed feature if you can make one cleanly. |
| `export` | features 06, home tile | Import a STEP file, cut or fillet it, File → Export STL, then cut to the slicer opening it. |
| `mac` | features 07 | Orbit with the trackpad, switch to dark/light, open a recent part from the welcome window. |

## Poster images

`make-clips.sh` takes the poster (`<name>.jpg`) from the first second of each clip. If you would rather choose a frame,
export a JPEG yourself and drop it in `website/src/static/video/` after running the script.

## Still to make (not video)

- `og-image.jpg`, 1200 × 630, for link previews (a frame from `hero` with the headline).
- Real screenshots, if you want them on the Download page.
