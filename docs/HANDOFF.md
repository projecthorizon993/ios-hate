# LumaFrame iOS — coding handoff

**This is the entry point.** Everything else in `docs/` is subordinate to it. If you are
reading only one file, read this one.

You are picking up a SwiftUI camera app for iOS 18 that **has never been run on a device**.
Steps 1–5 of its feature plan are written, pass CI, and have never been observed working.
The capability report that was supposed to tell us what the devices do crashed on device
and was abandoned. Your job is not to add features. Your job is to make it build, then put
it on a phone, then write down what it does.

---

## 1. The rules

These exist because the previous approach broke them. Follow them literally.

1. **A phase ends in a gate, or it has not ended.** A gate is a commit that provably
   passed. Not a review, not an opinion, not "it looks right".
2. **Never write "verified" for anything a compiler has not seen.** There is no Xcode on
   the development machine. The only compiler is CI.
3. **One line of work at a time.** Do not start Phase 1 until Phase 0's gate is green.
4. **Never simulate a capability.** Hide what does not exist, disable what exists but is
   unavailable, and never show a control that does nothing. This project has already
   shipped one Pro dial that was connected to nothing.
5. **A reviewer does not edit.** If a review finds a problem, report it. Fixes are separate
   commits. Two reviewer agents were told to be read-only and instead merged branches and
   amended another; the history is currently wrong because of it.
6. **Never branch on a device name, marketing name, or `hw.machine`.** Runtime capability
   only. A name may be displayed and never tested against.
7. **Never claim a platform behaviour you have not observed.** An unverified claim about CI
   or the simulator is the same class of error as the ones already made in this repo.

---

## 2. Repository state

| | |
| --- | --- |
| Repo | `D:\project\app`, branch `main` |
| `main` | the tip. This file is committed on it, so read the state from the tables below rather than from a hash, which is always one commit stale. |
| Target | iOS 18.0, Swift 5.9, iPhone only (`TARGETED_DEVICE_FAMILY = 1`), portrait only |
| Sources | 29 Swift files under `App/Sources`, 4 under `App/Tests` |
| Third-party deps | **none** — Apple frameworks only |
| CI | `.github/workflows/ios.yml`: unit tests + unsigned IPA, on `macos-15` |
| Android | a separate branch, `android-step0`. Not your problem. |

### Merge status — all five are merged

| Branch | Status |
| --- | --- |
| `agent/a1-lut-colour` (`29a7c01`) | **merged**, including the trap fix |
| `agent/a2-manual-exposure` (`cb2cdc0`) | **merged** |
| `agent/a3-ui-consolidation` (`3ed828d`) | **merged** |
| `agent/a4-looks-storage` (`1074c68`) | **merged** |
| `agent/a5-diagnostics` (`e3cf9de`) | **merged** |

Worktrees for all five live under `C:\Users\Admin\AppData\Local\Temp\opencode\lf-a1..a5`.
`lf-a1` is stale — it predates the tooling in `scripts/`. Trust `main`, not the worktrees.

### What Phase 0 cost, and what it bought

Phase 0 took **eight CI runs**, and the reason is worth keeping: the gate had no
compiler, so eight compile errors surfaced one run at a time, each after a full build.
Seven were mechanical (`QualityPrioritization` is on the *output*; `MTLDevice.isLowPower`
is macOS-only; `UIDisplayGamut.P3` is capitalised; a static called without `Self.`; an
escaping Objective-C block capturing a mutating `self`; a `device.whiteBalanceGains`
property that does not exist). One was a test of mine that was simply wrong.

The single most expensive mistake was guessing a platform fact instead of looking it up.
Three runs went into one enum's spelling, and a fourth went into a claim this document
itself got wrong — see section 8.

---

## 3. PHASE 0 — make it build — **DONE, GATE GREEN**

`Unit tests` and `Build unsigned IPA` both pass on `main`. The app compiles and the test
suite executes for the first time. **Nothing about behaviour is claimed** — no code has
ever run on a phone. Proceed to Phase 1, which is where that starts.

What each item turned out to be:

| # | Item | What it was |
| --- | --- | --- |
| 0.1 | Merge A1's trap fix | Merged, but the commit carried a **stray `}` at EOF** that does not compile. Removed on `main`. |
| 0.2 | Merge A2 | Four compile errors. The branch had never been compiled, as documented. |
| 0.3 | Gate the WB lock | Fixed — but the handoff's own premise was wrong. See section 8. |
| 0.4 | Make the model and session agree | `CameraPlan.resolve` — one rule, two readers. |
| 0.5 | One quality derivation | The third derivation was still there. Now `git grep "preferQuality ?"` is empty in `App/Sources`. |
| 0.6 | Working colour space on every CIContext | Four contexts, plus the default on `CubeLUT.authoredSpace` removed. |
| 0.7 | The gate | Green, on the ninth push. |

**0.4 in detail.** `CameraPlan.resolve` takes `[BackCameraCapabilities]`, not
`AVCaptureDevice`, which is what makes the agreement testable in CI at all. Both
`pickDevice` and `attachBackCameras` read it. Binding a constituent in Pro mode is
deliberately *not* done — it is a session reconfiguration per lens change, it has never
run on a device, and it is Phase 3.1. `proRequiresRebinding` records the empty panel's
cause rather than leaving it a gap.

**0.6 in detail.** `CubeLUT.authoredSpace` defaulted to `.sRGB`. That default was a false
claim handed to `CIColorCubeWithColorSpace` as `inputColorSpace`. The default is gone and
all four construction sites state the space.

---

## 4. PHASE 1 — put it on a phone — **IN PROGRESS**

**This phase has never happened. It is the most valuable thing you can do and it needs no
new code.** Produce a written record; that artefact does not exist and is worth more than
any further implementation.

It is now *unblocked* — the app compiles, the tests run, and an unsigned IPA is built by
CI on every push. The IPA is a job artifact, so it is downloadable from the run page
without a local build. Nothing else stands in the way.

Two devices minimum:

- **iPhone SE (3rd gen)** — single rear camera, no telephoto, no Dolby Vision capture.
  Defines the floor.
- **One current Pro** (iPhone 16/17 Pro) — composite device, ProRAW, the case where Pro mode
  is currently expected to be *empty*.

For each, record what happens, in this order:

1. Launch. Viewfinder live? Any permission or black-screen problem?
2. **Apply a look, and look at the photo.** Is a look distinguishable from the stock
   camera? Are skin tones plausible? Is anything washed out or over-saturated? This is the
   only real test of the colour-management fix.
3. **Open the Pro panel.** On the Pro it is expected to be **empty**, because A2 refuses to
   offer what a composite cannot do. Confirm it says why, and that it is not a broken
   screen. On the SE, expect the same or a partial panel.
4. Ten rapid shots. Any crash?
5. Five minutes continuous. Thermal throttling? Frame rate drop?
6. Rotate. Background and return. **Place a phone call during capture** — the interruption
   path is the one the old crash history implicates.
7. SAVED PHOTO vs PREVIEW. Do they match? Same colour space?

**Exit:** a written list of every symptom, including boring ones. This is the input to
Phase 2. Do not fix anything in this phase.

---

## 5. Already done — do not redo

- **LUT colour management.** `CIColorCube` → `CIColorCubeWithColorSpace` with the table's
  authored space. The old comment claimed the colour-managed filter "is absent from the
  SDK" — that was a misdiagnosis: the typed accessor needs `import CoreImage.CIFilterBuiltins`
  and `CIFilter(name:)` returns `nil` headless for Metal-backed filters.
- **`.cube` parser.** Strict, total, red-varies-fastest, every error case tested.
- **LUT authored space.** `CubeLUT.authoredSpace`, set by the parser. A non-unit domain is
  recorded as *no colour space* and refused by name, instead of being relabelled linear
  sRGB.
- **Subject segmentation** via Vision's built-in `VNGeneratePersonSegmentationRequest` — no
  bundled model, no licence question.
- **ProRAW** correctly read from `AVCapturePhotoOutput`, which is an **output** property,
  not a device one.
- **Consolidations** (8→2, 6→2, 5→1 files). All verified byte-for-byte relocated.
- **Tooling:** `scripts/audit-sources.mjs` (duplicate declarations, orphan files, delimiter
  balance), `scripts/consolidate.mjs` (mechanical relocation), `scripts/generate-pbxproj.mjs`
  (the project file is **derived state** — never hand-merge it, regenerate it).

---

## 6. Outstanding findings not yet fixed

Carried from a review. Do not treat these as done.

| Severity | Where | Issue |
| --- | --- | --- |
| MAJOR | `CaptureSessionController.pickDevice` | Prefers a composite, so the Pro panel is empty on every Pro iPhone. Honest, and now *recorded* rather than accidental — `proRequiresRebinding` names the cause. The fix is Phase 3.1. |
| MAJOR | `ProCapabilities` | `isEmpty` is dead code — only a test reads it. The panel renders an **empty strip of the same height** rather than hiding. |
| MAJOR | `ProCapabilities.availabilitySummary` | Reaches only an `AppLog.note`. The reason a control is missing is written to a log file the user must go and find. |
| MAJOR | `apply(manual:to:)` | Runs on the main thread: `lockForConfiguration` plus up to four AVFoundation writes, in the frame-rate-sensitive path. |
| MAJOR | tests | A1's rendering path has **zero executed assertions in CI** — both rendering tests skip headless. Availability is asserted; pixels are not. |
| MINOR | A1 commit message | Asserts as fact that headless CI returns `nil` for Metal-backed filter lookups, while shipping a test asserting the opposite. One is wrong; it was never run. |
| MINOR | `RuntimeCapabilities` (now `CapabilityReport.swift`) | Still uses the old focus rule, so the capability report and the Pro panel disagree about focus on a composite. |

### Do not "fix" these — they are correct, and one is deliberate

| Where | Why it looks wrong | Why it is being left alone |
| --- | --- | --- |
| Zoom chips are 1x / 2x / 4x and there is no 0.5x | A three-lens iPhone is expected to offer 0.5x, 1x, 2x like Apple does | `minAvailableVideoZoomFactor` is **1.0**, so the composite's zoom range has no 0.5x to give. Each chip doubling lands on the next lens, so all three lenses *are* reachable. The mapping is Apple's shifted up one stop. Getting Apple's semantics means **binding physical constituent devices** (Phase 3.1), which costs a session reconfiguration per lens change instead of a smooth ramp — a UX regression to buy a label. A product decision, not a bug. See `docs/device-record-02.md`. |
| 1x shows the ultra wide | 1x is conventionally the "standard" wide lens | Same cause. The composite's factor-to-lens mapping is fixed by the platform, so 1.0 *is* the ultra wide's field of view and no relabelling can change it. Worth knowing because it means the app opens on the noisiest, most distorted lens, which is the likely root of the original "grainy at the outside" report. |

**Closed in Phase 0**, and worth keeping a list of because the pattern repeats:

- `CubeLUT.authoredSpace` defaulted to `.sRGB` — a free false claim for any site that
  forgot the field, handed to `CIColorCubeWithColorSpace` as `inputColorSpace`. Default
  removed; all four sites state it.
- `testColorManagedCubeFilterIsAvailable` asserted a string it also owned, so reverting
  `LUTProcessor` to the invariant filter would have left CI green. The filter name is now
  one constant read by both the processor and the test.
- `MTLDevice.isLowPower` is **macOS-only** and did not exist on iOS. The `lowPowerGPU`
  field it fed was never read, so it was removed rather than replaced.

---

## 7. Later phases — summary only, do not start

- **Phase 2 — formal UI.** Attach a screenshot of a camera app whose look is wanted
  *before* writing view code; the current screen was built without one. Decide the
  capability-driven layout matrix (single lens / composite / iPad / external / no camera),
  then wire `isEmpty` and `availabilitySummary` to the view. Build Settings, which does
  not exist.
- **Phase 3 — core.** Bind a constituent device in Pro mode. Manual Kelvin white balance via
  `temperatureAndTintValues`. Calibrate `DeviceTier`, which has never been read off hardware.
- **Phase 4 — settings and refinement.** Shareable capability report (the verification loop
  in every phase needs it; it is currently a log file). Restore a bounded, flagged
  benchmark. Run the manual checklist.

---

## 8. Document map

| File | Authority |
| --- | --- |
| **`docs/HANDOFF.md`** | **this file — the entry point** |
| `docs/PHASES.md` | phase rationale and the history of why the parallel model was dropped |
| `docs/device-record-01.md` | first device run: the capture blocker, the empty photo codec list |
| `docs/device-record-02.md` | second run: why 1x is the ultra wide and 4x never reaches the telephoto |
| `docs/IOS_PLAN.md` | the three live defects, the wide device matrix, the open-source survey |
| `docs/ARCHITECTURE.md` | platform contract: Step-1 decisions, Android rules, repository topology |
| `docs/DESIGN_SPEC.md` | visual tokens; unchanged and authoritative for the UI |
| `docs/ORCHESTRATION.md`, `docs/tasks/*` | **retired.** Kept only as a record. |

Two platform facts that are load-bearing and were wrong before, so check them before
trusting any code that contradicts them:

- `isAppleProRAWSupported` is on **`AVCapturePhotoOutput`**, not `AVCaptureDevice`.
- `photoQualityPrioritization` is typed **`AVCapturePhotoOutput.QualityPrioritization`**,
  even though the property being assigned is on `AVCapturePhotoSettings`. The intuitive
  spelling does not exist. Same shape of mistake as the line above.
- Apple documents that **composite camera devices** (`.builtInTripleCamera`,
  `.builtInDualWideCamera`) do **not** support `ExposureMode.custom`, and do not allow
  locking focus to a new lens position or AWB to new gains.

### Correction 2: the active-lens query this document said did not exist

During Phase 1 the app needed to say which physical lens a photo came from. It was
inferred three times and was wrong every time, and the conclusion drawn from that was
"iOS exposes no query for which constituent of a composite is active".

**That was wrong.** The query is:

```swift
var activePrimaryConstituent: AVCaptureDevice? { get }   // iOS 15+
```

> "A virtual device's active primary constituent device… may change when zoom, exposure, or
> focus changes. The value is `nil` for nonvirtual devices. **This property is key-value
> observable.**"

It has been available since iOS 15, and this project targets iOS 18. Alongside it:
`constituentDevices`, `isVirtualDevice`,
`setPrimaryConstituentDeviceSwitchingBehavior(_:restrictedSwitchingBehaviorConditions:)`,
and `supportedFallbackPrimaryConstituentDevices`.

Because it is key-value observable, a lens hand-over can be logged **when it happens**,
which is what caught the user's report that the viewfinder was on the ultra wide while the
app said otherwise.

### Correction 3: the composite chooses the lens, and can silently refuse to

`activePrimaryConstituent` answers *which* lens is active. These answer *why that one*:

```swift
var activePrimaryConstituentDeviceSwitchingBehavior: PrimaryConstituentDeviceSwitchingBehavior
var primaryConstituentDeviceRestrictedSwitchingBehaviorConditions:
    PrimaryConstituentDeviceRestrictedSwitchingBehaviorConditions
var fallbackPrimaryConstituentDevices: [AVCaptureDevice]
var constituentDevices: [AVCaptureDevice]
```

> "when the scene requires focus or exposure to go beyond the limits of the active primary
> constituent device, a camera with a shorter focal length may be able to deliver a better
> quality image. The system considers such a device a **fallback** primary constituent
> device."

This is why "4x still shows the wide" is not a zoom bug — see `docs/device-record-02.md`. The
telephoto becomes eligible and iOS declines it on focus or exposure grounds, with
`minAvailableVideoZoomFactor` and the switch points both reporting correctly throughout.
Reading `activePrimaryConstituent` alone would have shown a *correct* `wide` at 4x and left the
behaviour unexplained; the fallback properties are what make it explicable.

### The pattern, which is the point

Two claims in this document were confidently wrong about platform APIs, in opposite
directions, and both cost CI runs or device runs to discover:

| Claim | Reality | Cost |
| --- | --- | --- |
| "There is no separate query for can the gains change." | `isLockingWhiteBalanceWithCustomDeviceGainsSupported` exists | one CI run, and 0.3 was briefly built on a proxy |
| "iOS exposes no query for which constituent is active." | `activePrimaryConstituent` exists, iOS 15+ | three wrong inferences shipped, and the sensor name was removed from the UI and the photo metadata before being restored |

Both were recovered by reading Apple's documentation. **The rule that replaces both: look
the API up, every time, including when you are confident.** A confident claim about a
platform symbol is not knowledge; it is a guess that reads like knowledge, and this document
exists to stop the next person repeating it — so it does not get to be wrong either.
