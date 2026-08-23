# Touch Demo

A small letter tracing app that reproduces a multi-touch bug I ran into in
LetterSchool on iPad, plus a version that handles it correctly. Both sit behind
a toggle so you can compare them on device.

## The bug

If a finger is already resting on the screen, tracing with a second finger does
nothing. Do it in the other order and it works.

| Order | Result |
| --- | --- |
| Rest a finger, then trace with another | Nothing happens |
| Trace first, then rest a second finger | Trace keeps working |

The resting finger isn't on the letter and isn't trying to draw anything. It
only has to get there first.

### Reproducing in LetterSchool

1. Open any letter tracing exercise
2. Rest a finger anywhere on the screen and hold it still
3. Trace the letter with a second finger
4. Nothing registers
5. Lift both. Trace first, then rest a second finger. Now it works, and keeps
   working.

Worth flagging because kids hold the iPad steady with one hand while writing
with the other. Testing with a single finger or a stylus never hits it.

## What the demo does

Trace the A. The part you've covered fills in at full width, so one pass down
the middle finishes that stretch. It marks progress rather than painting.

Every finger on screen gets a ring: green if the app is tracking it, grey if
it isn't. In the broken case you can watch the idle finger sit there holding
the green ring while the finger doing the work gets grey.

The toggle switches between:

- **Buggy**, which reproduces the behaviour above
- **Fixed**, which works regardless of how many fingers are down or what order
  they landed in

## Running it

Open `Touch Demo.xcodeproj` and run on a real device. The Simulator can't
produce the input this is about.

## The fix

Two parts.

**Turn multi-touch on.** `isMultipleTouchEnabled` is `false` by default on
`UIView`. With it off, UIKit gives the view one touch and drops the rest, so the
second finger never arrives. Nothing looks wrong in the code because there's
nothing there to find.

**Track touches by identity, and choose them by where they started.** Key state
on the `UITouch` object itself rather than a single "current touch" field. A
touch only starts a stroke if it begins on the letter; anything else is ignored
and takes up no state at all. That second half is what makes it survive a palm
or a steadying hand instead of just working for two fingers.

Both are in the `Fixed path` section of `TraceCanvasView.swift`.

## Guesses at the cause

From the outside, so these are guesses:

- Touches tracked by index rather than identity. `Input.GetTouch(0)`,
  `touches[0]`, that sort of thing. The resting finger is index 0, so the
  tracing finger never gets read.
- `isMultipleTouchEnabled` left at its default.
- A single `activeTouch` field, claimed by whichever touch arrives first. That's
  what the buggy mode here does. Grep for `BUG` in `TraceCanvasView.swift`.

A SwiftUI `DragGesture` gives the same result, since it only models one drag.

### Narrowing it down without the source

Hold a finger down, start tracing with a second so that it fails, then lift the
resting finger while the tracing one stays down and keeps moving.

If the stroke comes to life mid-trace, touches are being tracked by index and
the tracing finger has just become index 0. If it stays dead until you lift and
press again, something rejected that touch earlier and is still holding state.

Also worth trying: rest the finger outside the tracing area, on a margin or
some chrome. If it still breaks, input is being read globally rather than per
view.

## Files

- `Touch Demo/TraceCanvasView.swift`, the canvas, both touch implementations and
  the letter progress model
- `Touch Demo/ContentView.swift`, the toggle, legend and clear button
