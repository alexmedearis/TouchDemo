# Touch Demo

A minimal letter-tracing app that reproduces a multi-touch bug observed in
**LetterSchool** on iPad, and demonstrates a fix. Two touch-handling
implementations sit behind a toggle, driving the exact same drawing surface, so
the two behaviours can be compared directly on a device.

## The bug

Tracing stops working when an unrelated finger is already touching the screen,
and whether it works depends on the order the fingers land.

| Order | Result |
| --- | --- |
| Rest a finger, **then** trace with another | Trace does nothing |
| Trace first, **then** rest a second finger | Trace continues working |

The resting finger is irrelevant to the task — it isn't on the letter and isn't
meant to draw anything. It only has to be touching the screen first.

### Reproducing in LetterSchool

1. Open any letter-tracing exercise.
2. Rest one finger anywhere on the screen and keep it still.
3. With a second finger, trace the letter as normal.
4. The trace does not register.
5. Lift both fingers. Trace the letter first, then rest a second finger down.
   Tracing now works, and keeps working.

Observed on: _iPad model / iPadOS version / LetterSchool version — fill in._

### Why it matters

This is a handwriting app for young children. A child resting a palm or spare
fingers on the screen while tracing is the most common real-world input it will
receive. It is also precisely the input that testing with a single careful
finger or a stylus never produces.

## What this demo shows

Trace the letter A with a finger. The portion you have covered fills in at full
width — the fill marks progress along the letter rather than painting it, so a
single pass down the middle completes that stretch.

Rings follow each finger on screen: **green** for a touch the app is tracking,
**grey** for one it is ignoring. This is what makes the bug visible rather than
merely describable — in the failing case you can watch the resting finger hold a
green ring while the finger doing the actual work wears a grey one.

The segmented control switches implementations:

- **Buggy** — reproduces the behaviour above.
- **Fixed** — rest any number of fingers anywhere, then trace; it works every
  time. Multiple traces can also run at once.

## Running it

Open `Touch Demo.xcodeproj` in Xcode and run on a device. **A real device is
required** — the Simulator cannot produce the two-finger input the demo is about.

## Likely causes

The app was examined only from the outside, so the following are ranked
hypotheses rather than findings. All three produce the observed order-dependence.

1. **Index-based touch tracking in a cross-platform engine layer** — e.g. Unity's
   `Input.GetTouch(0)` or `Input.mousePosition`, which maps to touch 0. A resting
   finger *is* touch 0, so the tracing finger at index 1 is never read.
2. **`isMultipleTouchEnabled` left at its default of `false`** on the drawing
   view, if the app is native UIKit. UIKit then delivers only one touch and the
   second finger is never seen at all.
3. **A single-touch state machine** — one `activeTouch` slot claimed by whichever
   touch arrives first and never reconsidered. This is what the demo's buggy mode
   implements; see the `BUG 0`–`BUG 4` comments in `TraceCanvasView.swift`.

A SwiftUI `DragGesture` produces the same signature and belongs in the same
family, since it models a single drag bound to the first finger down.

### Telling them apart without source access

- **Lift the resting finger mid-trace, keeping the tracing finger down.** If the
  trace springs to life mid-stroke, tracking is index-based — the tracing finger
  has just become index 0. Nothing else recovers without lifting both fingers.
- **Rest the finger outside the tracing canvas**, on chrome or a margin. If it
  still breaks, input is screen-global, pointing at an engine-level cause rather
  than a per-view one.
- **Tap and release elsewhere, then trace.** This should work, confirming the
  problem is concurrent touches rather than leftover state.

## The fix

Two rules, of which the second is the one usually missed:

1. **Key state by touch identity, not arrival order.** A map keyed by the touch
   itself (`ObjectIdentifier(UITouch)` in UIKit, `fingerId` rather than index in
   Unity) instead of a single "current touch" field. Note that Unity touch
   *indices* shift when a touch ends, while `fingerId` is stable.
2. **Decide relevance from where a touch began.** A touch matters only if it
   starts on the letter. Irrelevant touches claim nothing, so no number of them
   can block a trace. Without this rule the capacity has merely gone from one
   finger to N, and the same class of bug returns with N+1.

Both are implemented in the `Fixed path` section of `TraceCanvasView.swift`,
where each fix is commented against the specific defect it addresses.

## Layout

- `Touch Demo/TraceCanvasView.swift` — the canvas, both touch implementations,
  and the letter-progress model. Grep for `BUG` to find the annotated defects.
- `Touch Demo/ContentView.swift` — mode toggle, legend, and Clear button.
