# A2 — review result: returned

**Verdict: not merged.** Gate §5 of `docs/ORCHESTRATION.md` — "the first failure sends the
branch back". Findings 1 and 2 are behavioural defects in the code this task exists to fix,
so they are not mergeable as they stand.

Branch: `agent/a2-manual-exposure` (commit `c8325de`), based on the pre-wave main `66243c8`.

## What passed

Genuinely good work, and it should survive the re-review:

- `photoQualityPrioritization` is now decided once in `prioritization(for:)` and both the
  settings and the recipe string read it. Closing the settings/says-balanced drift is the
  right shape and the reasoning is right.
- Every device write is gated on its own `is*Supported` check and wrapped in
  `LumaFrameSafety`, which is the containment the task required.
- The fixture tests are real: they construct a composite-like capability set and assert
  the values are withdrawn, which is the assertion that would have caught defect 2.
- `canLockFocus` now also requires `isLockingFocusWithCustomLensPositionSupported`, which
  is a correct and previously-missed distinction.
- The commit message cites Apple for the composite restriction and for
  `photoQualityPrioritization`, and is honest about what is unverified.

## Blocking

### 1. An ISO-only setting writes a shutter the user never chose

`App/Sources/Camera/CaptureSessionController.swift:407-415`

```swift
if let iso = manual.iso {
    ...
    device.setExposureModeCustom(
        duration: CMTime(seconds: 1.0 / 60.0, preferredTimescale: 1_000_000_000),
        iso: clamped,
        completionHandler: nil)
```

`ManualSettings.shutterSeconds` is `Optional` and `nil` means "let the camera decide". The
ISO branch supplies a hardcoded `1.0 / 60.0` anyway, because `setExposureModeCustom` takes
duration and ISO as one pair and there is no partial call.

So a user who dials only ISO gets a 1/60 s shutter they did not ask for. This is the same
defect the task was written to close — a control that does not mean what it says — in a
new place, and it is worse than the original because it now looks implemented.

**Fix:** when `manual.shutterSeconds == nil`, pass `device.exposureDuration` — the value the
device is actually running — not a literal. The comment above `applyExposure` already
argues that the two values must be written together, so the intent was right; the constant
is the bug.

### 2. The exposure-bias write can discard the ISO and shutter just written

`App/Sources/Camera/CaptureSessionController.swift:442`

```swift
setExposureMode(.custom, on: device, name: "exposure")
```

This runs after the ISO and shutter branches, and it uses the `exposureMode` **property
setter**. Entering `.custom` through the property is not the documented way to do it —
`setExposureModeCustom(duration:iso:)` is — and it can reset ISO and duration to values the
caller never chose. With `manual.exposureTargetOffset != 0` and no ISO or shutter set, this
is the whole write path.

**Fix:** enter `.custom` through the same `setExposureModeCustom` call the other branches
use, carrying the live duration and ISO, and do it *before* the bias is applied rather than
after the other two writes.

## Non-blocking, but fix them in the same commit

### 3. The user is told a hardware fact the code never checked

`App/Sources/Camera/ProCapabilities.swift:132,148`

`availabilitySummary` returns `compositeReason` whenever `supportsCustomExposure` is false.
That condition is "the device does not support `.custom`", not "the device is a composite".
On any device that lacks `.custom` for another reason the app states a specific,
documented-sounding falsehood about the hardware.

It is also currently unfalsifiable in the test:
`testTheSummaryExplainsWhyACompositeDeviceHasNoManualControls` asserts
`summary.contains("composite")`, so the claim is locked in by a test that can only be
satisfied by asserting the unverified thing.

`device.deviceType` is available and is already logged at
`CaptureSessionController.swift:399`. Branch the message on the actual device type, or
state only what was actually checked.

### 4. Focus lock is a control over nothing

`ManualSettings` has no lens-position field, so `applyFocus` reads `device.lensPosition` and
locks the position the lens is already in. The A2 task's "Done when" says "ISO, shutter,
EV, focus and gains reach the device", and focus does not: the user cannot move focus.

Either add the field (which means touching the Pro panel — check the ownership bound first)
or say plainly in the commit message that focus position is not implemented and why. It is
currently a Pro-panel control that cannot move the image, which is the defect this wave
exists to remove.

### 5. Dead branch

`App/Sources/Camera/CaptureSessionController.swift:438-440`

```swift
let clamped = manual.exposureTargetOffset > lower
    && manual.exposureTargetOffset < upper
    ? manual.exposureTargetOffset
    : min(max(manual.exposureTargetOffset, lower), upper)
```

Both arms produce the same value; the ternary is a no-op. `min(max(...))` alone is correct.

## Scope: a decision, not a bug — the main model must sign this off

`docs/tasks/A2-manual-exposure.md` §Defect 2a says the design is **already made** in
`docs/IOS_PLAN.md` 3.2, and "implement this, do not re-litigate it": in Pro mode bind a
**constituent** device; in Auto mode keep the composite; hide manual controls when the bound
device reports `isExposureModeSupported(.custom) == false`.

This commit implements the third clause only. It does not bind a constituent. The stated
reason is that it is a session reconfiguration and that constituent `.custom` support is
inferred from Apple's wording about the composite rather than measured.

The reasoning is sound and the honesty is good. It is still a re-litigation of a decision
the plan had already made, and the consequence is concrete: because
`CaptureSessionController` binds a composite, `supportsCustomExposure` is false on every Pro
iPhone, so **the Pro panel is now empty on the exact hardware the Pro mode exists for**.

Three ways this can go, and the main model has to pick one:

- **Bind a constituent in Pro mode**, as 3.2 says. A session reconfiguration per lens
  change, which the plan already accepts as the cost. Unverifiable without a device, but so
  is most of this wave.
- **Ship the honest empty panel** and carry the constituent work into wave 2 explicitly, with
  `docs/IOS_PLAN.md` 3.2 updated to record that it was deferred rather than done.
- **Land findings 1-5 and hold the whole task** until the constituent work can be verified
  on a Pro device together with the writes.

Whatever is chosen, the commit message should stop describing the panel as working.

## Also

- `App/Tests/CameraStep1Tests.swift` — the comment explaining that the mode switcher's order
  is chrome which `DESIGN_SPEC.md` requires not to move was deleted. It was load-bearing and
  nothing replaced it. Restore it.
- `App/Sources/Camera/ProCapabilities.swift` — stray double blank lines after
  `isExposureManual` and at the top of `summarise`. The repo has a commit
  (`66243c8`, "Do not collapse blank lines when consolidating") that establishes blank lines
  are deliberate; adding new ones is not tidying.

## Re-review gate

Findings 1-5 plus the scope decision, then the §5 checks again — in particular
`generate-pbxproj.mjs --check`, `validate-pbxproj.mjs`, and a test that fails before the
fix and passes after for finding 1, since a defect fix without a failing test is a hope.

A2 must still not be merged by the agent. Push the branch and open a PR; the main model
merges.
