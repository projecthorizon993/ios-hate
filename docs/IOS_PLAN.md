# LumaFrame iOS — Plan (rewrite 3)

Written 29 September 2026 against the **current** repository, not against a greenfield
assumption. This replaces `docs/IOS_PLAN.md` rewrite 2, which was written before the last
85 commits and described a build order for work that is mostly already written.

Companion documents: `docs/ARCHITECTURE.md` (Android constraints, repository topology,
the Step-1 decision record) and `docs/DESIGN_SPEC.md` (visual contract).

---

## 1. Read this first: the app has never run on a device

This is the most important fact in the repository and every plan that ignored it was
useless.

- Unit tests and the unsigned IPA build are **green on `main`**.
- **No step has been executed on any device.** Steps 1–5 compile, pass CI, and have never
  been observed working.
- The Step 0 capability report **was abandoned, not fixed**. It hung the main thread, then
  crashed the app after 6–7 seconds, then hung again. Three candidate causes were
  identified and patched by reading code — an unsynchronised camera handover, a ~300 MB
  autorelease leak in the render benchmark, and a probe that started and stopped the one
  physical camera three or four times in a row. **None is established as the cause.** A
  jetsam kill writes no crash log and Apple's Analytics sync work was never obtained.
- The reports collected from the three test devices came from a **binary that no longer
  exists**, so no number in them describes the current code.
- `DeviceTier` is `nil` in the capability model, deliberately, pending a benchmark that
  has never been read off hardware.

**Therefore the plan's centre of gravity is not "add features". It is: get this thing
running, find out what actually happens, and fix what breaks.** Feature work before
verification is how the current situation arose — five steps of unverified UI.

The user's brief asks for support across a wide range of devices rather than three. With
no measurements at all, that request is not "add more test devices". It is "stop depending
on knowing which device it is, and make the device incapable of lying to us". Section 4
is how.

---

## 2. Current state, verified by audit

Verdicts are from a read of the code, not from the documentation.

| Area | Verdict | Evidence |
| --- | --- | --- |
| ProRAW as an output property | **Correct** | `CameraCapabilities.swift:233`, `RuntimeCapabilities.swift:221` both read `photoOutput.isAppleProRAWSupported`; `ProCapabilities.swift:67` states the rule explicitly |
| Model-name / `hw.machine` branching that gates behaviour | **None** | `hw.machine` is read once for a report row and printed; never in a conditional |
| RAW and ProRAW kept independent | **Correct** | `CameraCapabilities.swift:189`, tested at `CameraStep1Tests.swift:80` |
| Subject segmentation | **Correct** | `SubjectSegmentation.swift:64` uses Vision's built-in `VNGeneratePersonSegmentationRequest`; no bundled model, no licence question |
| ANE claims | **Correct** — none made | `MLComputeUnits` appears nowhere; the code never asserts a backend |
| LUT intensity 0% | **Correct** | `LUTProcessor.swift:56` returns before constructing the filter, so 0% is provably the original; tested |
| `.cube` parsing | **Correct** | `CubeLUTParser.swift` plus `CubeLUTParserTests`, including red-varies-fastest ordering and every error case |
| Capability gating tests | **Good, but only the pure half** | Nine gating tests in `CameraStep1Tests`, all fixture-injected; no live AVFoundation anywhere in the suite |
| **LUT colour management** | **Wrong** | See 3.1 |
| **Composite device + manual exposure** | **Unhandled** | See 3.2 |
| **`photoQualityPrioritization` vs manual** | **Ignored** | See 3.3 |
| **Manual exposure write-back** | **Missing** | `CaptureSessionController.swift:314` sets `.continuousAutoExposure` unconditionally, with the comment "Pro (Step 4) is the mode that writes custom values here" |
| Capability report | **Dead** | Reachable only behind a triple-tap; export is a log file, no share sheet |

Module boundaries are **holding**. `CameraViewModel.swift` is 37 KB but is a coordinator
that injects the session, photo controller, meter and pipeline as `private let`, and holds
no parsing, rendering or disk I/O. `CaptureSessionController.swift` is the single owner of
`AVCaptureSession`. `ProDial.swift` contains a view and a parameter table and no device
knowledge. Roughly a third of the larger files is documentation explaining *why*, which is
the right proportion. One misplaced declaration: `CameraMode` lives inside
`CameraViewModel.swift:6` and belongs at file scope.

The architectural weakness is not size. It is that `CaptureSessionController.Configuration`
hands callers a **live `AVCaptureDevice`**, and `ProCapabilities.probe(device:format:)`
takes live AVFoundation values with no protocol seam — which is exactly why 3.2 and 3.3
cannot be caught by the existing test suite.

---

## 3. Correctness defects, ranked

Ranked by how much damage they do to a real user's photograph.

### 3.1 The LUT is applied without colour management — highest priority

`LUTProcessor.swift:99`:

```swift
guard let cube = CIFilter(name: "CIColorCube") else { return }
```

The code is aware that `CIColorCubeWithColorSpace` would be correct, and `LUTProcessor.swift:73`
gives a reason for not using it: *"absent from the SDK CI builds against: both
`CIFilter(name:)` and the typed `CIFilter.colorCubeWithColorSpace()` fail to find it, the
first returning nil and the second not compiling."*

**That reason is wrong.** `CIColorCubeWithColorSpace` is a documented, long-standing Core
Image filter, and `CIFilter.colorCubeWithColorSpace()` is a typed static on `CIFilter`. The
correct call is:

```swift
let cube = CIFilter.colorCubeWithColorSpace(colorSpace: lutAuthoredColorSpace)
```

What went wrong is diagnosable: in a headless CI unit-test process, `CIFilter(name:)`
returns nil for filters whose implementation is backed by Metal, and the code concluded the
filter did not exist. The assertion in the comment is **believed, not measured** — and no
test verifies it. The same headless-CI weakness is why the two rendering-dependent tests
in `LUTProcessorTests` are gated behind `XCTSkipUnless(coreImageCanRenderACube())`, so CI
passes while the wrong filter ships.

Consequences while this stands:

- `CIContext`'s working space is **linear sRGB**; a colourist's `.cube` is **gamma-encoded
  sRGB**. `CIColorCube` is invariant — it applies the table with no colour management at
  all, like `CIPhotoEffect`. Every look is therefore applied in the wrong space.
- `ProcessingPipeline.swift:193` hardcodes `private func lutDomainSpace(for look: Look) -> ColorSpace { .sRGB }`,
  so the space is decided unilaterally by the pipeline.
- `CubeLUT` infers its space from *domain values* (unit ⇒ sRGB, non-unit ⇒ linear) rather
  than from an authored-space declaration, and the domain is only ever used as a
  reject/accept gate.

This is the single most likely cause of "washed out or over-saturated", and it corrupts
every photo with a look applied. **Fix before anything else.**

Fix, in order: use `CIFilter.colorCubeWithColorSpace`; record the LUT's authored space as
data (not inferred from domain); make a P3-authored LUT against sRGB pixels a **logged
error**, not a silent conversion; create `CIContext` with an explicit
`workingColorSpace`; and change the CI test so it asserts the filter *exists* rather than
skipping when Core Image cannot render in a headless process.

### 3.2 Pro mode cannot work, and the UI does not say so

`CaptureSessionController.swift:368-384` prefers the composite device:

```swift
// A composite (triple/dual) device is preferred because switching its virtual
// devices keeps one session alive; a single-lens device is a valid fallback.
if let composite = discovery.devices.first,
   BackCameraCapabilities.kind(of: composite.deviceType) == .composite {
    return composite
}
```

Apple documents that `.builtInTripleCamera` and `.builtInDualWideCamera` do **not** support
`ExposureMode.custom`, do not allow locking focus to a new lens position, and do not allow
locking AWB to new gains. `.builtInDualWideCamera` may additionally change exposure, ISO
and gains when it switches constituent cameras. The code binds exactly that device. The
comment shows the trade-off was made for session liveness with the exposure consequence
not considered.

Two further facts make this worse than one bug:

1. **Nothing writes manual values anyway.** `setExposureModeCustom`, `device.iso =` and
   `device.exposureDuration =` appear nowhere in the tree. `ManualSettings` is a clamped
   value type, the dial edits it, and it is discarded. So Pro mode is currently a UI over a
   no-op. That is the "never simulate" rule from the original brief being broken in the one
   place it matters most.
2. **The capability model and the session disagree.**
   `CameraCapabilities.attachBackCameras:252` filters composites out — *"Physical lenses
   win over composites"* — while `pickDevice` binds the composite. The UI offers physical
   lens chips; the session runs a different device. A test asserts the UI half
   (`testPhysicalLensesWinOverCompositeDevices`) and nothing asserts the session half, so
   CI is green on a contradiction.

Design decision, unchanged from rewrite 2 and now urgent: **lens selection is active
`AVCaptureDevice` selection, not zoom on a composite.** Discovery for
`[.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]` yields
constituents as separate devices. Bind a constituent in Pro mode; realises ISO, shutter,
EV, focus lock and AWB lock. Keep the composite in Auto mode, where its automatic
lens switching is an advantage and no manual control is claimed. Hide manual controls
entirely when the bound device reports `isExposureModeSupported(.custom) == false`.

There is a real cost, and it should be stated rather than discovered: binding a
constituent means a session reconfiguration on every lens change, which is the session
liveness the current comment was protecting. That is a deliberate trade — a working Pro
mode against a smoother Auto-mode lens switch — and it is reversible per mode.

### 3.3 `photoQualityPrioritization` will discard manual exposure

`PhotoCaptureController.swift:159`:

```swift
settings.photoQualityPrioritization = request.preferQuality ? .quality : .balanced
```

`.speed` appears nowhere. Apple documents that `.balanced`, which is the default,
*allows photo capture to temporarily override the capture device's exposure duration and
ISO if the scene is dark enough to require multi-image fusion.* So the moment manual
exposure is actually written back per 3.2, the values the user dialled in will be
discarded in exactly the low light where a manual camera matters.

The condition is also wired to the wrong thing. `HDRStatus.requestedQuality`
(`CameraCapabilities.swift:386`) is `hasPhotoQualitySupport ? true : false` and never
inspects manual state; `makeRequest()` (`CameraViewModel.swift:571`) does not reference
`manual` at all. `Request` (`PhotoCaptureController.swift:36`) has no field for it. The two
are structurally unable to be linked as written.

Fix: `Request` gains a `manualExposureActive: Bool`; when true, set `.speed` and tell the
user in the UI that multi-frame fusion is unavailable in manual mode. This does not
conflict with the existing Step-1 decision to request `.quality` for native HDR — the two
are different modes, and a capture is either Auto or manual.

### 3.4 Smaller items

- `neuralEngineFamily9` (`RuntimeCapabilities.swift:262`) is stored and never read. Delete
  it, or surface it. Dead capability data misleads the next reader.
- `CameraMode` should move out of `CameraViewModel.swift`.
- The capability report has no share sheet. Once it works again it must be exportable as
  text, because the entire verification loop of section 5 depends on the user pasting it
  back. `Documents/LumaFrame-log.txt` plus `UIFileSharingEnabled` is necessary and not
  sufficient.

---

## 4. Supporting a wide range of devices — the actual strategy

The brief asks for support beyond the current three phones. Here is the honest position
and the plan that answers it.

**The previous approach does not scale and cannot be repaired in place.** It was: probe the
live device on demand, render a report, let a human read it and infer a matrix. That
requires every new device to be visited by a human, and it crashed. Two properties made it
fragile: it started and stopped the capture session repeatedly, and the render benchmark
allocated unboundedly.

**The replacement has three layers, none of which requires visiting a device to be
correct.**

### 4.1 Layer one — capability is a value, computed from session state

`RuntimeCapabilities` and `CameraCapabilities` already do the right thing structurally: they
read from state the session already holds, and `attachingOutput(_:)` runs once when the
photo output is attached to a *running* session, because the output properties are
meaningless before that. Keep that discipline and tighten it:

- No probe may create, start or stop an `AVCaptureSession`. The report's crash is the
  lesson; it must be structurally impossible to repeat.
- No render benchmark may allocate per iteration without a bound. If a benchmark is
  retained, it renders into a reused texture and runs a fixed iteration count.
- `attachingOutput` stays the single place output-level capabilities are read.

### 4.2 Layer two — the capability matrix is a test fixture, not a table

Every device class in section 6 becomes a JSON snapshot. The capability model consumes the
snapshot; the ViewModel, the UI gating and the tier logic are all pure functions of it.
CI then covers the whole matrix with **no camera and no device**, which is the only way to
support a wide range from a machine with no Mac and no phone farm.

This is not a proposal; the suite is already 100% fixture-injected, which is why it is
fast and why it is currently blind. The work is to extend the existing pattern from nine
gating tests to a fixture per device class, and to put a protocol seam in front of
`ProCapabilities.probe(device:format:)` and `pickDevice` so the 3.2 contradiction becomes a
failing test instead of a comment nobody notices.

### 4.3 Layer three — export a record, once, safely

A capability snapshot is cheap, bounded and safe. The crashed report also did a render
benchmark, started sessions, and accumulated autoreleased buffers. Separate those
concerns:

| Exported | Cost | Risk | When |
| --- | --- | --- | --- |
| `RuntimeCapabilities` snapshot | trivial | none | Any time |
| Lens/format/range table | trivial | none | Any time |
| Session start/stop probes | moderate | **the crash** | Only behind a flag, off by default, with the previous breadcrumb trace kept |
| Render benchmark | memory | jetsam risk | Behind a flag, bounded allocation, never on a first run |

The report returns as a **shareable text file**, because the verification loop in
section 5 is "run it, paste it back". A log file on disk is not enough when the goal is
cross-device comparison.

### 4.4 What "wider support" does and does not mean

It does not mean a device database. `hw.machine` → marketing name is a display lookup; the
code's own comment in `CameraCapabilities.swift:48` — *"No device name or model string
appears anywhere in this type"* — is the rule and should stay.

It means: a device nobody has ever held still gets correct behaviour, because every feature
is gated on what the session reports, and the gating logic is tested against fixtures
covering every device class.

---

## 5. Verification, before features

Nothing further is built until the app has been run. This is the whole remaining critical
path.

### 5.1 Device verification matrix

Minimum: **one single-camera device** (iPhone SE 3rd gen) and **one multi-lens device**
(iPhone 11 Pro Max or newer Pro). The 11 Pro Max is now the *least* interesting device
because it is old; a current Pro is needed to see the composite and ProRAW paths at their
best. A current non-Pro with a 48MP sensor is worth one run, since it is the case where the
"2x" crop must not be presented as a lens.

### 5.2 Order of work

1. **Install and run the existing build.** Record what happens, including the crash. This
   costs nothing and everything depends on it.
2. **Fix 3.1** (LUT colour space). It corrupts output and is cheap.
3. **Restore the capability export** as a shareable text file, using only the safe layer
   4.3 items. Re-establish the three-device record — this time from the current binary.
4. **Fix 3.2 and 3.3 together**, since they are one change: manual write-back plus
   `.speed`. Gate on `isExposureModeSupported(.custom)`. Decide explicitly whether Pro mode
   binds a constituent and accepts a session reconfiguration per lens change.
5. **Add the fixture matrix** for every device class in section 6, including the composite
   and single-camera classes that make 3.2 catchable.
6. **Then** continue features.

### 5.3 Manual checklist, revised

Adds to the original fifteen-minute list:

- Does the saved photo match the preview, in the same colour space, with a look applied?
- Is a look's colour visibly different from the stock camera, and are skin tones plausible?
  **This is the test for 3.1.**
- Set ISO and shutter manually in a dim room. Does the EXIF match the dialled values, and
  does the system override them? **This is the test for 3.2 and 3.3.**
- On a multi-lens device, does the lens chip reflect the device actually bound?
- On a single-camera device, are lens chips and zoom steps absent?
- Is RAW/ProRAW offered only where the output reports it, and does the file appear?
- Ten rapid shots; five minutes without thermal throttling; rotate; background and return.

---

## 6. Device matrix

Runtime-detected, per `docs/ARCHITECTURE.md` 1.1. Marked with what the current code does
versus what it must do.

| Class | Examples | Composite type | Manual exposure | Notes |
| --- | --- | --- | --- | --- |
| Single rear | iPhone SE (2nd/3rd gen) | none | **works** — single wide supports `.custom` | No lens UI, no zoom steps. No Dolby Vision capture; ProRes unavailable. Both SE generations are the oldest devices on current iOS, so they define the tier floor |
| Dual wide | iPhone 11, 12, 13, 14, 15, 16, 17, iPhone Air | `.builtInDualWideCamera` | **does not work on the composite** | The "2x" on 48MP models is a **crop of the main sensor** and must never be shown as a hardware lens |
| Triple | iPhone 11 Pro and later Pro, 18 Pro | `.builtInTripleCamera` | **does not work on the composite** | Reference device for lens switching *and* for 3.2 |
| iPad | iPad Pro legacy (2 cameras), iPad Pro M4/M5 (1), Air, mini, 10th gen | **unconfirmed** | unknown | Not currently supported — `TARGETED_DEVICE_FAMILY = 1`. Requires an explicit decision, section 8 |
| External | UVC webcams, Continuity Camera | `.external`, `.continuityCamera`, iOS 17+ | depends | Hot-plug must rebuild inputs; treat the device list as volatile |
| Simulator | — | — | — | **No camera hardware at all.** All capability paths are unexercisable in CI |

OS: deployment target is **iOS 18.0**. Current shipping is iOS 26; iOS 27 is in beta. iOS 27.1
adds `.builtInInnerUltraWideCamera` and `.builtInOuterUltraWideCamera`, so **every `switch`
over `DeviceType` needs a `default` arm** or the app will not compile against a 27.1 SDK.

Unconfirmed and therefore to be measured, not asserted: ProRAW on non-Pro 48MP models; which
`DeviceType` each iPad reports; `AVCaptureMultiCamSession` on iPadOS; per-SoC Neural Engine
core counts; the minimum device for iOS 27.

Region: no regional camera **sensor** differences are assumed — the premise has no evidence.
The SIM tray, mmWave and Japan's non-muteable shutter sound are real, and the last one is a
design rule: **never gate an audio affordance or accessibility cue on mute state.**

---

## 7. Open-source references, and what they change here

The rewrite-2 survey is corrected below. The most useful result is negative: **there is no
open-source iOS app that does what this project wants.** Halide is closed source, so no
architectural claim may be sourced to it. SDAVICamera is closed. The iOS NightCamera never
existed — the one that does is Android, unlicensed, dead since 2018. LibreCamera is
GPL-3.0 **Android/Flutter** and has no ISO, shutter, white balance or lens control at all.
GPUImage 2 is dead since 2019 and OpenGL ES.

| Reference | Status | Applied here |
| --- | --- | --- |
| **AVCam** (Apple sample) | Restricted licence, actively maintained | Already the shape of `CaptureSessionController`: one owner, output services behind a seam, every property gated at set time, `RotationCoordinator`, `mediaServicesWereReset` handling. The exception containment shim follows it. **It has no Pro controls**, so it cannot answer 3.2 |
| **MetalPetal** | MIT, 2.2k stars, last commit Feb 2023 | The only real reference for the processing half. The `transient` vs `persistent` cache distinction is the correct model for LUT texture lifetime. Its Obj-C core and stale concurrency are not worth copying |
| Core Image vs vImage | — | LUTs belong in Core Image, roughly 100+ FPS at 12MP against ~20 FPS for vImage. Current choice is right |
| `.cube` loaders in Swift | No maintained MIT package | Already written in-house at `CubeLUTParser`. The known bugs in the floating packages — rejecting `TITLE` with spaces, a `>= 3` token check that accepts malformed sizes — are the ones to check ours against |
| **DeviceKit** | MIT, 4.7k stars, active | A maintained `hw.machine` → SoC table, if a friendly display name is ever wanted. **Never a capability source** |
| Simulation camera tooling (CMIOExtension) | Third-party, MIT / commercial | Gives the Simulator a camera with no app-side change. Useful for pipeline smoke tests. **It reports one generic device, so it proves nothing about the matrix.** CI must not report green on capability branches because of it |

The honest conclusion, unchanged: the capture-and-manual half has **no adequate reference**
and is original work. Budget accordingly. The ISP reality stands too —
`AVCaptureVideoDataOutput` frames have already passed Apple's demosaic, denoise, tone map,
sharpen and Deep Fusion, and no post-process recovers what a tone curve destroyed. If
non-computational output is ever a goal, the requirement is to capture RAW and run our own
ISP.

---

## 8. Delivery, from the current state

| # | Work | Gate |
| --- | --- | --- |
| 1 | **Run the existing build on a device.** Record everything, including any crash | A log exists |
| 2 | Fix 3.1: `CIFilter.colorCubeWithColorSpace`, authored-space data, explicit `CIContext` working space, test that asserts the filter exists | A look's colour is visibly plausible; CI no longer skips to hide the wrong filter |
| 3 | Restore capability export as a shareable text file, safe layer only | Three-device record from the current binary |
| 4 | Fix 3.2 + 3.3: manual write-back, constituent binding in Pro, `.speed`, gate on `.custom` | EXIF matches the dialled values in dim light |
| 5 | Fixture matrix per device class + protocol seams at `pickDevice` and `ProCapabilities.probe` | 3.2's contradiction is a failing test that then passes |
| 6 | Decide iPad: `TARGETED_DEVICE_FAMILY` and the layout work, or an explicit no | Recorded, not implied |
| 7 | Tier calibration from a bounded, flagged benchmark | `DeviceTier` stops being `nil` |
| 8 | Only then: remaining feature work per the original delivery order | — |

Step 6 is a decision, not a chore. "Wider" in the brief can reasonably mean iPhone models
and OS versions without meaning iPad. Landscape is likewise still portrait-only, with the
trailing-edge layout from `DESIGN_SPEC.md` outstanding.

---

## 9. Risks

| Risk | Evidence | Mitigation |
| --- | --- | --- |
| Every look is applied in the wrong colour space | `CIColorCube` is invariant; the working space is linear | 3.1, first, with a test that fails if the correct filter is missing |
| Pro mode cannot work on any multi-lens device | Apple documents the restriction on both composite types; the code binds the composite | 3.2, constituent binding, gated on `.custom` |
| Manual exposure silently discarded in low light | Apple's documented `.balanced` behaviour; `.speed` absent | 3.3 |
| The UI simulates a control that does nothing | Manual values are clamped and displayed but never written | 3.2, or hide Pro until it is real |
| Capability model and running session disagree | `attachBackCameras` filters composites; `pickDevice` prefers them | 3.2, plus a fixture test that fails on the contradiction |
| The capability report crashes again | It already crashed three ways, cause never established | 4.3: no session start/stop in any probe, bounded allocation, shareable export of the safe layer only |
| Wide support assumed from a device table | Tables describe marketing, not hardware | 4.1–4.2: runtime detection plus fixtures |
| CI green while the app is broken | Already true for five steps | 5.2: verify on device before building; the fixture matrix only guards the pure logic, never the device |
| Nothing may be claimed about the Neural Engine | No public per-inference compute-unit API | Backend selection is a differential benchmark; never assert ANE usage |
| `DeviceType` switch breaks on an iOS 27.1 SDK | Apple added two device types | `default` arm in every switch |
| Composite-manual-exposure is only half-fixed | Constituent support for `.custom` is inferred from Apple's wording about the composite | Verify on a Pro device in step 4; if constituents also refuse, hide manual controls entirely |
