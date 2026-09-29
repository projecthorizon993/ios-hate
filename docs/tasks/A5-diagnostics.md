# A5 — Diagnostics consolidation

**Moves only, with one named exception.** The exception is stated below; there are no
others.

## Owns

```
App/Sources/Support/RuntimeCapabilities.swift
App/Sources/Support/ReportFormat.swift
App/Sources/Support/DeveloperPanel.swift
App/Sources/Support/MemoryProbe.swift
App/Sources/Camera/CameraRelease.swift
```

The `Support/` directory. Note that `AppLog.swift`, `Haptics.swift`,
`LumaFrameLogFile.swift` and `LumaFrameSafety.*` are **not** yours — leave them.

## The task

4 files → 1: **`Support/CapabilityReport.swift`**

Not `Support/Diagnostics.swift`. The old `App/Sources/Diagnostics/` module was deleted
when the report was abandoned; do not resurrect a path with that history, or `git` will
read your new file as a resurrection of the deleted one and the diff will lie.

Contents, in order:
- `CameraRelease` (currently in `Camera/`, 1.6 KB) — it is a capability datum that
  belongs with the capability snapshot, and it is the only reason this task touches
  `Camera/`.
- `RuntimeCapabilities` — the snapshot type.
- `ReportFormat` — its rendering.
- `DeveloperPanel` — the SwiftUI view that presents it.
- `MemoryProbe` — the measurement it reads.

`MemoryProbe` is the one to be careful with. The old report crashed the app three ways and
one of them was a ~300 MB autorelease leak attributed to the render benchmark. **Move
`MemoryProbe` verbatim and change nothing about how it allocates.** If you believe it needs
fixing, that is a finding to report, not a change to make — an unbounded-allocation fix
inside a file-move commit cannot be reviewed.

## The one exception you are allowed

`RuntimeCapabilities.swift:262` stores `neuralEngineFamily9` and **nothing ever reads it**.
`docs/IOS_PLAN.md` 3.4 calls it out as dead. Delete the stored property and its
initialisation.

Before you delete it, prove it with:

```bash
git grep -n neuralEngineFamily9
```

and paste the result into the commit message. If the grep shows any read, **do not delete
it** — report instead. Also note the plan flags that it is a `MTLDevice.supportsFamily`
query, which is a GPU/SoC family check and not a Neural Engine claim, so deleting it also
removes a misleading name.

## Rules

- Pure relocation otherwise. No rename, no signature change, no behaviour change.
- Preserve doc comments verbatim. `RuntimeCapabilities` opens with an account of why the
  old report was abandoned — **that account is load-bearing documentation and must survive
  the move intact.** It is the reason the design is shaped the way it is.
- Do not touch `Camera/CameraScreen.swift` even though it hosts `DeveloperPanel`.

## Out of scope, deliberately

Restoring a shareable text export of the capability report. It is genuinely needed — the
verification loop in `docs/IOS_PLAN.md` section 5 depends on the user pasting a report back
— but it is new behaviour, and this wave is explicitly **no new features**. It is wave 2.
Flagging it here so nobody mistakes its absence for an oversight.

## Done when

- 5 files are now 1, at `App/Sources/Support/CapabilityReport.swift`.
- `git grep -n neuralEngineFamily9` returns nothing, and the commit message shows the
  grep that proved it.
- The "why the report was abandoned" comment is present in the new file.
- `git diff -M main...` shows one rename and deletions that match the added blocks.
- `App/Sources/Diagnostics/` does not reappear.

## Commands

```bash
node scripts/generate-pbxproj.mjs
node scripts/validate-pbxproj.mjs
git add -A && git commit -m "a5: consolidate diagnostics into a capability report module"
```
