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
| Sources | 28 Swift files under `App/Sources`, 4 under `App/Tests` |
| Third-party deps | **none** — Apple frameworks only |
| CI | `.github/workflows/ios.yml`: unit tests + unsigned IPA, on `macos-15` |
| Android | a separate branch, `android-step0`. Not your problem. |

### Merge status — read this, it is not what the git log suggests

| Branch | Status |
| --- | --- |
| `agent/a3-ui-consolidation` (`3ed828d`) | **merged** |
| `agent/a4-looks-storage` (`1074c68`) | **merged** |
| `agent/a5-diagnostics` (`e3cf9de`) | **merged** |
| `agent/a1-lut-colour` (`29a7c01`) | original commit merged; the **trap fix `29a7c01` is not** |
| `agent/a2-manual-exposure` (`cb2cdc0`) | **not merged at all** |

Worktrees for all five live under `C:\Users\Admin\AppData\Local\Temp\opencode\lf-a1..a5`.
`lf-a1` is stale — it predates the tooling in `scripts/`. Trust `main`, not the worktrees.

---

## 3. PHASE 0 — make it build

**Goal: `main` compiles, CI green, zero outstanding compile errors. Claim nothing about
behaviour.** This is the only thing that matters until it is done.

### 0.1 Merge A1's trap fix

```bash
git merge --no-ff agent/a1-lut-colour -m "Merge a1: LUT colour management and the Int(Float) trap fix"
```

Why: `LUTProcessor.shortest(_:)` used `String(Int(value))` on a parsed `DOMAIN_MIN` /
`DOMAIN_MAX`. `Int(_: Float)` **traps** on overflow and non-finite values, and the parser
bounds sample data but not domain values. A `.cube` declaring `DOMAIN_MAX 1e40 1e40 1e40`
parses fine, is correctly identified as log-encoded, then kills the app while being
formatted into the error message written to explain that. Reachable from a user picking a
file in Files.app. Fixed in `29a7c01`.

**Verify it applied:** `git grep -n "isFinite" -- App/Sources/Processing/LUTProcessor.swift`
must show the guard inside `shortest(_:)`.

### 0.2 Merge A2

```bash
git merge --no-ff agent/a2-manual-exposure -m "Merge a2: manual exposure write-back and photoQualityPrioritization"
```

**This branch has never compiled.** It was reviewed, three compile errors were found and
fixed in `cb2cdc0`, and CI has still never seen it. Merge it, then watch CI. If it fails,
fix on `main` — do not debug inside a merge.

A2 does three things: it writes manual ISO/shutter/bias and focus/WB locks to the device
(previously it clamped the values and dropped them, so the Pro dial controlled nothing);
it sets `photoQualityPrioritization = .speed` when a manual exposure is active, because
Apple documents that the default `.balanced` lets the system **override** a manual ISO in
low light; and it gates the Pro panel on `isExposureModeSupported(.custom)`.

### 0.3 Gate the white-balance lock on the composite restriction

A2 withdrew ISO, shutter and bias when the bound device cannot do `.custom`, but left
`canLockWhiteBalance` ungated. Apple documents that `.builtInTripleCamera` and
`.builtInDualWideCamera` do not allow locking AWB to new gains. So on a Pro iPhone the
user still gets a WB lock chip that cannot work — the exact defect 0.2's gating was meant
to close.

```
App/Sources/Camera/ProCapabilities.swift
    capabilities.canLockWhiteBalance = device.isWhiteBalanceModeSupported(.locked)
```

There is no separate "can the gains change" query, so the honest options are to gate it
on the same composite check used for exposure, or to record explicitly that it is an
uncertain answer and suppress the chip. Either is acceptable. What is not acceptable is
leaving it as-is and calling the panel gated.

**Accept when:** a composite-like capability set offers no WB lock, and a test asserts it.

### 0.4 Make the capability model and the session agree

Two halves of the same fact currently disagree:

- `CaptureSessionController.pickDevice(facing:)` (`CaptureSessionController.swift`) prefers
  a **composite** device, with a comment saying this keeps one session alive.
- `CameraCapabilities.attachBackCameras` filters composites **out** of the capability model.

So the UI offers physical lens chips while the session runs a different device. No test
covers the session half, which is why CI is green on a contradiction.

Two acceptable resolutions, and the choice is yours to make and record:

- **(a)** Bind a constituent device in Pro mode, so manual exposure works. Cost: a session
  reconfiguration per lens change. This is the real fix but it is Phase 3 work and needs a
  device.
- **(b)** Make both halves agree that Auto uses a composite and Pro uses a constituent, and
  fall back to hiding Pro when no constituent is available.

**Accept when:** a test fails if the two disagree. Whatever you choose, write down which.

### 0.5 One derivation for quality prioritisation

`PhotoCaptureController` has three independent `preferQuality ? ...` expressions. A2 added
`prioritization(for:)` and `name(for:)` on the branch; if any survived the merge or any
duplicate remains, every one of them must read from the single function. A manual capture
whose recipe says `"balanced"` while `.speed` was applied is a file lying about itself.

```
App/Sources/Camera/PhotoCaptureController.swift
    git grep -n "preferQuality ?" -- App
```

**Accept when:** `git grep "preferQuality ?"` returns nothing in `App/Sources`.

### 0.6 Working colour space on every CIContext

The LUT is now applied with `CIColorCubeWithColorSpace`, which takes the table's authored
space and converts into the context's working space. The default working space is linear
sRGB, so this is behaviourally inert *until it is not* — which is why it should be stated
rather than inherited. Four contexts were missed:

```
App/Sources/Camera/PreviewSurface.swift     (3 sites: CIContext(mtlDevice:), CIContext(), and one more)
App/Sources/Looks/Looks.swift               (LookThumbnailer's context, after the a4 merge)
```

`ProcessingPipeline.encodeJPEG` already has it. Add `.workingColorSpace` to the others
using `ColorSpace.linearSRGB.cgColorSpace`.

### 0.7 Phase 0 gate

```bash
node scripts/audit-sources.mjs      # must print "no structural errors"
node scripts/generate-pbxproj.mjs --check
node scripts/validate-pbxproj.mjs
```

Then push and require **both** `Unit tests` and `Build unsigned IPA` green on `main`.

**Do not proceed to Phase 1 until that is true.** If CI is red, stop and fix it. Everything
below assumes a building app.

---

## 4. PHASE 1 — put it on a phone

**This phase has never happened. It is the most valuable thing you can do and it needs no
new code.** Produce a written record; that artefact does not exist and is worth more than
any further implementation.

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
| MAJOR | `CaptureSessionController.pickDevice` | Prefers a composite, so the Pro panel is empty on every Pro iPhone. Honest, but a worse product. Phase 3. |
| MAJOR | `ProCapabilities` | `isEmpty` is dead code — only a test reads it. The panel renders an **empty strip of the same height** rather than hiding. |
| MAJOR | `ProCapabilities.availabilitySummary` | Reaches only an `AppLog.note`. The reason a control is missing is written to a log file the user must go and find. |
| MAJOR | `CubeLUT.authoredSpace` | Defaults to `.sRGB`. A future non-unit construction site gets a false claim for free. |
| MAJOR | `apply(manual:to:)` | Runs on the main thread: `lockForConfiguration` plus up to four AVFoundation writes, in the frame-rate-sensitive path. |
| MAJOR | tests | `testColorManagedCubeFilterIsAvailable` **cannot fail** if `LUTProcessor` reverts to the invariant filter — it asserts a string it also owns. Make it assert on the processor. |
| MAJOR | tests | `testACompositeDeviceWithdrawsEveryManualExposureValue` exercises a function that was not changed, and would have passed on the parent commit. **The composite-exposure defect has no executing regression test.** |
| MINOR | A1 commit message | Asserts as fact that headless CI returns `nil` for Metal-backed filter lookups, while shipping a test asserting the opposite. One is wrong; it was never run. |
| MINOR | tests | A1's rendering path has **zero executed assertions in CI** — both rendering tests skip headless. Availability is asserted; pixels are not. |
| MINOR | `RuntimeCapabilities` (now `CapabilityReport.swift`) | Still uses the old focus rule, so the capability report and the Pro panel disagree about focus on a composite. |

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
| `docs/IOS_PLAN.md` | the three live defects, the wide device matrix, the open-source survey |
| `docs/ARCHITECTURE.md` | platform contract: Step-1 decisions, Android rules, repository topology |
| `docs/DESIGN_SPEC.md` | visual tokens; unchanged and authoritative for the UI |
| `docs/ORCHESTRATION.md`, `docs/tasks/*` | **retired.** Kept only as a record. |

Two platform facts that are load-bearing and were wrong before, so check them before
trusting any code that contradicts them:

- `isAppleProRAWSupported` is on **`AVCapturePhotoOutput`**, not `AVCaptureDevice`.
- Apple documents that **composite camera devices** (`.builtInTripleCamera`,
  `.builtInDualWideCamera`) do **not** support `ExposureMode.custom`, and do not allow
  locking focus to a new lens position or AWB to new gains.
