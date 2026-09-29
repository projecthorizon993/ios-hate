# A4 — Looks and Storage consolidation

**Moves only.** Same rules as A3, and they are not negotiable.

## Owns

```
App/Sources/Looks/Look.swift
App/Sources/Looks/LookLibrary.swift
App/Sources/Looks/GeneratedLooks.swift
App/Sources/Looks/LookThumbnailer.swift
App/Sources/Storage/CaptureMetadata.swift
App/Sources/Storage/PhotoStore.swift
```

These are your files alone. No other agent touches them.

## The task

Two consolidations, 6 files → 2.

**`Looks/Looks.swift`** (4 files, ~20 KB)
Order: `Look` (the value type, which everything else depends on) → `LookLibrary` →
`GeneratedLooks` → `LookThumbnailer`.

**`Storage/PhotoStore.swift`** (2 files, ~16 KB)
`CaptureMetadata` is written into the file header and by the capture path;
`PhotoStore` reads and writes it. They are one concern — the on-disk representation and
its owner — and splitting them means every reader of the recipe format has to know which
file to open.

## Rules

- Pure relocation. No rename, no signature change, no behaviour change, no tidying.
- Preserve every doc comment verbatim. `CaptureMetadata` documents the `v<N>;key=value`
  recipe format, and that format is what already-written photos on users' devices depend
  on. **Do not touch the serialisation code, the key names, or the version handling** — it
  is not yours and it is load-bearing for files already on disk.
- Do not add an import that the merged parts did not already have.

## Known interactions — report, do not resolve

- A3 is folding `Camera/LooksChipBar.swift` into `Camera/ProPanel.swift`. That file draws
  from `Looks/`. **Your consolidation must not change any type name it calls**, or A3's
  branch will fail to compile after merge. Moving declarations is safe; renaming is not.
- `LookThumbnailer` uses a `CIContext`. A1 is changing `CIContext` construction for
  `workingColorSpace` in the files A1 owns. **You must not touch `LookThumbnailer`'s
  context creation** — if you move the declaration, move it verbatim. A1 will handle the
  working space in a follow-up; if you think it must happen now, stop and report.

## Done when

- 6 files are now 2.
- `git diff -M main...` shows renames; every non-rename hunk is a deletion matching a block
  added elsewhere.
- The recipe format code is byte-identical to `main`.
- `git diff main... -- App/Sources/Looks/GeneratedLooks.swift App/Sources/Storage/CaptureMetadata.swift`
  shows deletion only — no modification.

## Commands

```bash
node scripts/generate-pbxproj.mjs
node scripts/validate-pbxproj.mjs
git add -A && git commit -m "a4: consolidate the looks and storage modules"
```
