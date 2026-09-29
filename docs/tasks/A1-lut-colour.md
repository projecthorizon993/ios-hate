> **RETIRED.** Superseded by docs/HANDOFF.md, which is the entry point. Kept only as a record of what the parallel-agent approach was and why it was dropped. Do not work from this file.

# A1 — LUT colour management (defect 1)

**Priority: highest in this wave.** This corrupts the output of every photo with a look
applied, and it is cheap to fix.

## Owns

```
App/Sources/Processing/CubeLUT.swift
App/Sources/Processing/CubeLUTError.swift
App/Sources/Processing/CubeLUTParser.swift
App/Sources/Processing/ColorSpace.swift
App/Sources/Processing/LUTProcessor.swift
App/Sources/Processing/ProcessingPipeline.swift
App/Tests/LUTProcessorTests.swift
App/Tests/ProcessingPipelineTests.swift
```

**Do not touch any other file.** Do not touch `Processing/ProcessingSettings.swift`,
`Processing/SubjectMask.swift`, `Processing/ToneCurve.swift`, or
`Tests/CubeLUTParserTests.swift` — another agent or a later wave needs them intact.

## The defect

`LUTProcessor.swift:99`:

```swift
guard let cube = CIFilter(name: "CIColorCube") else { return }
```

`CIColorCube` applies its table with **no colour management at all** — it is invariant,
like `CIPhotoEffect`. `CIContext`'s working space is **linear sRGB**, and a colourist's
`.cube` file is **gamma-encoded sRGB**. Applying one to the other in that combination
mis-renders every look.

The existing comment at `LUTProcessor.swift:73-77` claims `CIColorCubeWithColorSpace` is
absent from the SDK, which is **false**. It is a documented Core Image filter with a typed
static, `CIFilter.colorCubeWithColorSpace(colorSpace:)`. The wrong conclusion came from
running `CIFilter(name:)` in a **headless CI process**, where Metal-backed filters return
nil. Delete that comment and replace it with the real reason for any headless test skip.

## The task

1. **Use `CIFilter.colorCubeWithColorSpace(colorSpace:)`**, passing the LUT's *authored*
   colour space. Not the image's space.
2. **Record the authored space as data.** Today `CubeLUT` infers a space from the numeric
   *domain* (unit ⇒ sRGB, non-unit ⇒ linear) and `ProcessingPipeline.swift:193` hardcodes
   the answer:
   ```swift
   private func lutDomainSpace(for look: Look) -> ColorSpace { .sRGB }
   ```
   Replace the hardcode with the LUT's own declared space. Domain values remain an
   accept/reject gate, not a space inference.
3. **A space mismatch is a logged error, not a silent conversion.** A P3-authored LUT
   applied to sRGB pixels must fail loudly, per `docs/IOS_PLAN.md` 3.1. The existing
   `LUTApplicationError.domainMismatch` is the right shape.
4. **Create the `CIContext` with an explicit `workingColorSpace`.** `workingColorSpace`
   currently appears nowhere in `App/Sources`. Pick one, document why in a comment, and
   use it consistently for preview, save and thumbnails.
5. **Fix the tests so they can fail.** `LUTProcessorTests` gates two tests behind
   `XCTSkipUnless(coreImageCanRenderACube())`, which is why CI passed while the wrong
   filter shipped. The test must **assert the correct filter exists and returns a usable
   cube**, and skip only the pixel-comparison part, with a comment saying that a headless
   CI process cannot evaluate a Metal-backed filter and why that is not evidence about its
   existence.

## Preserve — do not regress these

- **Intensity 0% short-circuits** at `LUTProcessor.swift:56`, returning before the filter
  is built, so 0% is provably the original. It is tested. Keep it.
- The 0 < t < 1 path is a `CIDissolveTransition` blend, and the file documents why a
  table-space lerp would be wrong. Keep it and that reasoning.
- Cube byte order (red varies fastest) and the parser's error surface.

## Bound

Do not rename or change the signature of any `Processing/` type used outside
`Processing/`. If the colour-management fix appears to require it, **stop and report it**
rather than making it — a wave-2 agent may need to touch a consumer too, and two agents
editing one file is how this goes wrong.

## Done when

- `CIFilter(name: "CIColorCube")` appears nowhere.
- `lutDomainSpace` reads the LUT's space, and the `.sRGB` literal is gone from
  `ProcessingPipeline.swift:193`.
- `workingColorSpace:` appears on every `CIContext` in the files you own.
- A test named for the colour space exists and asserts the filter resolves.
- Commit message cites the Apple documentation for
  `CIColorCubeWithColorSpace` and for `CIContext.workingColorSpace`, and explains what the
  headless-CI symptom actually was.

## Commands

```bash
node scripts/generate-pbxproj.mjs --check
node scripts/validate-pbxproj.mjs
git add -A && git commit -m "a1: apply LUTs with explicit colour management"
```

You cannot compile. CI will. Do not claim otherwise.
