# Phased delivery (replaces the parallel-agent model)

`docs/ORCHESTRATION.md` and `docs/tasks/A1..A5` are retired. This file replaces them.

## Why the parallel model was wrong

It was tried, and the failure is worth recording rather than quietly discarding.

Five agents, disjoint file ownership, no shared compiler. Four branches were fine. One —
the one touching `AVCaptureSession` — **did not compile**: `lockForConfiguration() != nil`
on a `Void`-returning `throws` method, plus two AVFoundation setters that do not exist
(`setExposureTargetOffset`, `setWhiteBalanceModeLocked(mode:gains:)`). None of that was
caught by the gate, because **the gate had no compiler either**. It surfaced only when a
reviewer read the diff with fresh eyes.

Worse, the *review* was the thing that broke the process: the reviewing agents were told to
be read-only and instead merged four branches into `main` and added a commit to a fifth.
A review that mutates is not a review, and it means the record of who changed what is now
wrong.

The lesson is not "agents are bad". It is: **five agents working on unverified code with no
compiler between them is a way to accumulate unverified code faster, not a way to avoid it.**
What was actually valuable — the structural audit, the mechanical consolidator, the
relocation verifier — is not parallel at all. It is tooling, and it should be built once.

## The rule that replaces it

> **One line of work at a time. Each phase ends in a hard gate. Nothing starts until the
> previous gate is green.**

A gate is a commit that provably passed, not a reviewer's opinion. Until the app compiles,
the gate is CI. Until it runs correctly, the gate is a device.

## Phases

### Phase 0 — Make it build, and prove the gate works

The app has never compiled with the current code. Nothing else is safe to start.

| # | Work | Gate |
| --- | --- | --- |
| 0.1 | Merge A1's `Int(Float)` trap fix (`29a7c01`) | `Unit tests` green |
| 0.2 | Merge A2's compile fixes (`cb2cdc0`) | `Build unsigned IPA` green |
| 0.3 | Fix the two remaining review MAJORs: WB lock not gated on the composite restriction; `pickDevice` still prefers a composite while `attachBackCameras` filters composites out | new fixture test that fails if the two disagree |
| 0.4 | Fix the remaining MINORs: second `preferQuality` derivation at `PhotoCaptureController:225`; `availabilitySummary` reaching only a log; `authoredSpace` default footgun; `workingColorSpace` on the four CIContexts A1 was told to do and could not | CI green |

**Exit:** CI green on `main`, and the log shows zero compile errors. Nothing about
behaviour is claimed at this point.

### Phase 1 — Put it on a phone, and find out what it does

This is the phase the whole project has been missing. Five steps of the app have been
written, CI-green, and never observed.

| # | Work | Gate |
| --- | --- | --- |
| 1.1 | Install on one single-camera device (iPhone SE 3rd gen) and one multi-lens Pro | App launches, viewfinder live, one photo saved |
| 1.2 | Check the LUT colour fix with a real look — is a look plausible, are skin tones plausible, is anything washed out | Answer recorded, pass or fail |
| 1.3 | Check the Pro panel on both devices. Expect it **empty** on the Pro, because A2 correctly refuses to offer what a composite cannot do | Confirmed empty-with-a-reason, not a broken screen |
| 1.4 | Ten rapid shots; five minutes without thermal throttling; rotate; background and return; a phone call during capture | No crash, session recovers |
| 1.5 | Write down every symptom, even the boring ones | The list is the input to Phase 2 |

**Exit:** a written record of what the app does on two devices. This artefact does not
exist yet and is worth more than any further code.

### Phase 2 — A formal UI, decided before it is built

The brief asks for a polished camera UI and `docs/DESIGN_SPEC.md` exists, but the screen
was built without a screenshot to work from, and the review found the Pro panel rendering
an **empty strip of the same height** rather than hiding. That is what "not a formal UI"
looks like in code.

| # | Work | Gate |
| --- | --- | --- |
| 2.1 | Attach a screenshot of a camera app whose look is wanted. Two without it means guessing twice | Screenshot in the repo |
| 2.2 | Decide the capability-driven layout matrix: single lens, composite, iPad, external, no-camera | A table, reviewed, before any view code |
| 2.3 | Wire `availabilitySummary` and `isEmpty` to the view. A control that cannot work is hidden; a panel with nothing in it does not occupy space | Empty-state review on a real device |
| 2.4 | Build the Settings screen, which does not exist: format, grid, ML on/off, log export | — |
| 2.5 | Formalise the debug overlay from `DESIGN_SPEC.md` | One line, readable at arm's length |

**Exit:** a UI that hides rather than lies, verified on the same two devices.

### Phase 3 — Fix what Phase 1 and 2 found, in the core

Only now, with real numbers, is it worth spending on the parts Phase 0 could only guess at.

| # | Work | Gate |
| --- | --- | --- |
| 3.1 | Bind a **constituent** device in Pro mode, so manual exposure actually works on a Pro iPhone. Session reconfiguration per lens change, accepted as the cost | EXIF matches the dialled ISO and shutter |
| 3.2 | Manual Kelvin white balance, which needs `temperatureAndTintValues` | Kelvin round-trips |
| 3.3 | Calibrate `DeviceTier` from the render benchmark, which has never been read off hardware | Tier changes are visible and explained |
| 3.4 | Multi-frame fusion, if `.speed` proves too costly a trade | — |

**Exit:** Pro mode usable on a multi-lens device, which it is not today.

### Phase 4 — Settings and refinement

| # | Work | Gate |
| --- | --- | --- |
| 4.1 | Shareable capability report. The verification loop in every phase above depends on pasting a report back, and it is currently a log file | Report text copyable from the device |
| 4.2 | Restore a safe benchmark path, behind a flag, with bounded allocation | — |
| 4.3 | Performance: the review flagged AVFoundation writes on the main thread in `apply(manual:to:)` | Frame rate holds while dialling |
| 4.4 | The 15-minute manual checklist from `IOS_PLAN.md` section 5.3, run and signed off | — |

## Carried forward from the review, unfixed

Not in the phase tables because they are unknown-cost until Phase 1, but they are real:

- `testColorManagedCubeFilterIsAvailable` cannot fail if `LUTProcessor` reverts to the
  invariant filter. It asserts a string it also owns. It needs to assert on the processor,
  not on Core Image.
- `testACompositeDeviceWithdrawsEveryManualExposureValue` exercises a function A2 did not
  change, and would have passed on the parent commit. The defect it names has **no
  executing regression test at all**.
- A1's commit message asserts as established fact that headless CI returns `nil` for
  Metal-backed filter lookups, while shipping a test asserting the opposite. One of the two
  is wrong and it was never run. Until CI runs, that sentence is not known to be true.
- A1's rendering path has **zero executed assertions in CI**, because both rendering tests
  skip. Availability is asserted; pixels are not.
- `workingColorSpace` was required for five CIContexts and applied to one. The stated
  rationale was false for the four that render preview and thumbnails, and no wave is
  currently going to do it, because those files belong to other phases.
- The A4 commit's "336 lines" is CaptureMetadata + PhotoStore combined, not CaptureMetadata
  alone. The commit message reads as if it were the latter.

## What must not happen again

- A reviewer mutates the repository. Read-only means read-only, and if a review needs a fix
  applied, the fix is a separate, separately-committed change by someone who is not
  reviewing.
- A branch merges because it looked right. It merges because it passed a gate.
- "Verified" is never used for anything a compiler has not seen.
