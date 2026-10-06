# LumaFrame — Photography Engine Plan

**Status: planning.** The old look system is deleted (October 2026) and nothing here
is implemented. This document is the design the implementation will be held to, and
code that contradicts it is a bug in the code.

## 1. Why an engine, and why the old system could not become one

The deleted system applied a LUT as a **side path**: parse a `.cube` into samples,
build a filter at the call site, dissolve against the original for intensity, and
blend by subject in a stage that only existed for looks. Every one of those
decisions was made locally, and the record of what that cost is in
`docs/ARCHITECTURE.md` 3.1:

- the table's colour space was *inferred from domain values* rather than declared;
- the buffer was three floats per sample where Core Image documents four;
- a required filter input (`extrapolate`) was never set, and the test helper that
  should have caught it built its own buffer instead of sharing the code;
- intensity was a dissolve between two renders rather than a property of the grade.

None of that was a bad filter. It was the absence of an engine: there was no single
owner of colour, so each stage guessed what the others had done. The engine is that
owner. **A user-imported LUT is ingestion into the engine, not a second pipeline.**

## 2. What the engine owns

Everything that turns working-space light into the pixels of the file, in one
place, as data:

| Concern | Owner | Notes |
| --- | --- | --- |
| Working space | engine | Linear sRGB, stated on every context, as today |
| Tone | engine op | Exposure, contrast, highlights/shadows/whites/blacks, lift — linear light |
| Custom colour | engine ops | Temperature/tint, per-channel mixer, curves — the photographer's controls |
| Imported LUT | engine op | A table *plus* its declared space, evaluated by the engine, never by callers |
| Finish | engine ops | Sharpen (after denoise thinking), grain (gamma), vignette |
| Output transform | engine | To the file's own space; a P3 capture is never tagged sRGB |

What the engine explicitly does **not** own: capture (AVFoundation), preview
plumbing (the `MTKView` renderer), masks (a future subject pipeline feeds the
engine; it does not live inside it), and file I/O (PhotoStore).

## 3. The recipe is the engine's program

`ProcessingSettings` today holds tone/grain/sharpen. The engine grows it into an
ordered list of ops, each `Codable`, each with a strength:

```text
recipe = [ exposure, contrast, colourBalance, channelMixer, curves, lut?, grain, sharpen ]
```

Rules, carried over and tightened:

- **Preview and file run the same program.** The invariant that survived the
  deletion (`ProcessingPipeline`'s reason to exist) stays: one `render`, two callers.
- **Old files still open.** `Decodable` ignores unknown keys, so look-era recipes
  decode to toneless originals, and engine-era readers accept every recipe at or
  below their own version. New optional op keys are a **MINOR** contract bump with
  a byte-exact fixture (`docs/ARCHITECTURE.md` 9.5) — no silent format drift.
- **A correction runs only when asked.** The native pipeline already applied WB and
  tone mapping; engine ops default to identity, and identity is a fast path, not
  just a correctness one.

## 4. LUT ingestion, done once and properly

Import is the engine's front door for tables, and it is strict where the old
parser was generous-by-accident:

1. **Parse** (`.cube` grammar): red-varies-fastest order preserved, `DOMAIN_MIN/MAX`
   honoured, every malformed file rejected with a named error. The old parser's
   error taxonomy was good; its surroundings were not.
2. **Declare, never infer.** A table without a stated colour space is refused with
   the reason shown to the user — the domain-values inference that caused the
   washed-out era is banned by this document, not just by code review.
3. **Widen to RGBA at the boundary.** Core Image documents premultiplied RGBA;
   the alpha-1 widening happens in one function, asserted by byte count
   (`size³ × 4 × 4`) and by alpha value, at 2³ and at shipped sizes.
4. **Evaluate colour-managed.** The typed `colorCubeWithColorSpace` accessor (all
   five inputs set — `extrapolate` included), with the table's declared space as
   `inputColorSpace` and the context's working space stated. The invariant
   `CIColorCube` path is never a fallback; a missing filter is an error, not a
   quieter render.
5. **Intensity is an op property.** What 0…1 *means* (table interpolation vs
   result blend, and where it sits relative to the mixer and curves) is decided
   here, once, and tested as arithmetic — not discovered per call site.

## 5. Custom colour, parametric

The photographer's controls are engine ops with real ranges, each a pure function
of its settings (assertable in CI without rendering a pixel):

- temperature/tint (Kelvin round-trips through `temperatureAndTintValues` when
  Phase 3.2 lands; until then offsets, honestly labelled);
- per-channel mixer and curves, evaluated in the working space;
- saturation/vibrance that hold skin hue (the colourimetric guard from the old
  skin-tone work, rebuilt as an op rather than a kernel string).

No control ships until its range comes from the device or the format. The Pro-dial
rule — detents at real min/max, never a synthetic range — applies to every engine
control.

## 6. Performance and capability gating

- One `CIContext` per destination, bounded frame queues, preview-first scheduling:
  unchanged from today.
- Engine ops degrade by measured tier, never by model string. Heavy ops (curves at
  full resolution, large tables) step down under thermal pressure before frames drop.
- No compute-unit claims. There is no public API that reports ANE execution, so
  the engine never asserts where it ran — only how long it took, in the log.

## 7. Verification (the part the old system skipped)

Each phase below ends with a device check against a **reference tool**, because
CI cannot compare pixels and the old system proved that green CI plus unverified
colour ships washed-out photos:

- [ ] identity recipe is pixel-identical to the capture;
- [ ] a 2³ identity table leaves a known flat image unchanged;
- [ ] an obvious table (all red) changes it visibly;
- [ ] strength 0…1 blends monotonically, 0 an exact no-op;
- [ ] the result matches the same `.cube` in a reference tool on the same file —
      the only check that byte order and colour space agree;
- [ ] preview and saved file are the same image, by eye against the reference.

## 8. Build order

| # | Work | Gate | Status |
| --- | --- | --- | --- |
| E0 | Engine skeleton: typed filter construction (the display-name lookups resolved to nil and rendered nothing), colour conversion through the working space | Existing tests green, no behaviour change | **Built** — every tone run before this was a silent fallback to the original; all logged recipes were identity, which is why the field never caught it |
| E1 | Parametric colour ops (highlights, shadows, vibrance) + Tune sliders | Dials move real ranges; identity still exact | **Built** |
| E2 | LUT ingestion (§4) + import UI, as an engine op | §7 checklist passes on device against a reference tool | **Built except the device half of §7** — parser, interpolation, upload shape and recipe round trip pinned in CI; pixel comparison against a reference tool still needs a phone |
| E3 | Custom presets over engine recipes (MINOR contract bump + fixture) | Old files open; new files round-trip byte-exact | Open |
| E4 | Masks feed the engine per-region (subject pipeline returns first) | Blend edge invisible on a face; no-person scenes global with no seam | **Built except the device half** — Vision person segmentation (no bundled model) behind a seam, 0.5 s cadence, full-strength subject against 35% background, preview/file parity by recompute; blend-edge invisibility still needs eyes on a phone |

Pro mode, which this engine serves, is finished alongside: constituent binding
per mode and per lens pill (session rebind without stopping), diallable Kelvin
through device gains, and manual writes off the main thread.

## 9. Open questions (for the photographer, not the code)

1. LUT intensity semantics: interpolate the table, or blend the result?
   **Decided: interpolate the table toward identity.** One filter pass instead of
   two, and the math is CI-testable arithmetic rather than a second render to keep
   in step.
2. P3-authored tables: Adobe `.cube` cannot declare P3 — refuse, or take a
   user-side declaration at import?
3. Preset sharing format: stay inside the recipe string, or a sidecar file?
4. Which custom-colour controls are launch (mixer? curves?) and which wait?
   Highlights, shadows and vibrance shipped in E1; mixer and curves wait.

Nothing in E0–E2 needs these answered. E3 does.
