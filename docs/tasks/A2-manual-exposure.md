# A2 — Manual exposure, composite devices, photo quality (defects 2 + 3)

**The largest task in the wave and the one with the most unknowns.** Start it first.

## Owns

```
App/Sources/Camera/ProCapabilities.swift
App/Sources/Camera/CaptureSessionController.swift
App/Sources/Camera/PhotoCaptureController.swift
App/Sources/Camera/CameraCapabilities.swift
App/Sources/Camera/CameraViewModel.swift
App/Tests/CameraStep1Tests.swift
```

**Do not touch any other file.** In particular not `Camera/CameraScreen.swift`, not
`Camera/ProDial.swift` (A3 moves those), not anything in `Processing/`.

## Bound on CameraViewModel.swift

It is 37 KB and should be consolidated, but **not by you**. A3 and wave 2 will need it.
Make the **minimal** change to plumb manual state into the capture request. Do not
restructure it, do not move declarations out of it, do not rename anything. If you find
yourself editing more than about 30 lines in that file, you are doing someone else's task.

## Defect 2a — the composite device cannot do manual exposure

`CaptureSessionController.swift:368-384` prefers a composite device, with a comment saying
this keeps one session alive. Apple documents, on **both** `.builtInTripleCamera` and
`.builtInDualWideCamera`:

- no `AVCaptureDevice.ExposureMode.custom`
- no locking focus to a new lens position
- no locking AWB to new gains
- on `.builtInDualWideCamera`, exposure/ISO/gains may change when it switches constituent
  cameras

So the bound device is exactly the one where the Pro dial is a control over nothing.

**Design decision, already made in `docs/IOS_PLAN.md` 3.2 — implement this, do not
re-litigate it:**

> Lens selection is **active `AVCaptureDevice` selection**, not zoom on a composite. In Pro
> mode bind a **constituent**; in Auto mode keep the composite, where automatic lens
> switching is an advantage and no manual control is claimed. Hide manual controls
> entirely when the bound device reports `isExposureModeSupported(.custom) == false`.

The cost is a session reconfiguration per lens change in Pro mode. That trade is accepted
and must be noted in a comment, not discovered later.

## Defect 2b — nothing writes manual values

`CaptureSessionController.swift:314`:

```swift
// Pro (Step 4) is the mode that writes custom values here.
setExposureMode(.continuousAutoExposure, on: device, name: "exposure")
```

`setExposureModeCustom`, `device.iso =` and `device.exposureDuration =` appear nowhere in
the tree. `ManualSettings` is clamped, the dial edits it, and it is discarded. **The UI
currently simulates a control that does nothing**, which is the one thing the original
brief forbids.

Write ISO, exposure duration, exposure bias, focus lens position and AWB gains back to the
device, each gated at set time on its own `is*Supported` check — hardware state changes
under you. Values must come from the device's real ranges (`ProCapabilities` already
derives them). Never exceed a range; clamp, and log when clamping.

## Defect 2c — the capability model and the session disagree

`CameraCapabilities.attachBackCameras` (`:252`) filters composites out of the capability
model — *"Physical lenses win over composites"* — while `pickDevice` binds the composite.
The UI offers physical lens chips; the session runs a different device. A test asserts the
UI half and nothing asserts the session half, so CI is green on a contradiction.

Make both agree, and add a fixture test that fails if they ever diverge again.

## Defect 3 — `photoQualityPrioritization` will discard manual exposure

`PhotoCaptureController.swift:159`:

```swift
settings.photoQualityPrioritization = request.preferQuality ? .quality : .balanced
```

`.speed` appears nowhere. Apple documents that `.balanced` — also the default — *allows
photo capture to temporarily override the capture device's exposure duration and ISO if the
scene is dark enough to require multi-image fusion.* The moment 2b lands, the values the
user dialled in get discarded in exactly the low light where a manual camera matters.

`Request` (`PhotoCaptureController.swift:36`) has no field for manual state, and
`CameraViewModel.makeRequest()` (`:571`) never references `manual`, so the two are
structurally unable to be linked.

Add `manualExposureActive: Bool` to `Request`. When true, use `.speed` instead of
`.balanced`, and make the UI say multi-frame fusion is unavailable in manual mode. This
does **not** conflict with the existing Step-1 decision to request `.quality` for native
stills HDR — a capture is either Auto or manual.

## Known unknown

Whether a *constituent* device genuinely supports `.custom` is inferred from Apple's
wording about the composite, not measured. Implement so that **if a constituent also
refuses, manual controls are hidden and the app says why**. Do not assume it works.

## Done when

- `isExposureModeSupported(.custom)` is consulted before manual controls are offered, and
  again before each value is written.
- ISO, shutter, EV, focus and gains reach the device, clamped to real ranges.
- Manual active ⇒ `.speed`. Auto ⇒ unchanged.
- A fixture test covers: a composite-only device gets no manual controls; a constituent
  gets them; the two capability paths cannot disagree.
- Every write is wrapped in the existing `LumaFrameSafety` containment — Swift cannot
  catch `NSException`, and AVFoundation raises it for out-of-range configuration.
- Commit message cites Apple's documentation for the composite-device restriction and for
  the `photoQualityPrioritization` behaviour.

## Stop conditions — report, do not guess

- If making manual controls work requires a second concurrent session, stop. Two
  `AVCaptureSession`s on one camera fail on most devices.
- If constituent discovery does not yield separate devices on any type you can see in the
  code, stop and say so; the whole design rests on it.
- If a required change lives in a file you do not own, stop.
