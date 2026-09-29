# A3 — Camera view consolidation

**Moves only.** You are reducing the file count. You are not fixing anything, not
improving anything, and not changing behaviour.

## Owns

```
App/Sources/Camera/ProDial.swift
App/Sources/Camera/ProChipBar.swift
App/Sources/Camera/TonePanel.swift
App/Sources/Camera/LooksChipBar.swift
App/Sources/Camera/PreviewView.swift
App/Sources/Camera/ProcessedPreviewView.swift
App/Sources/Camera/PreviewMeter.swift
App/Sources/Camera/ProcessedPreview.swift
```

**Do not touch `Camera/CameraScreen.swift`.** It hosts these views. Moving a declaration
does not change its call sites, so you should not need it. **If you find yourself needing
to edit it, that is a finding to report, not a task to do** — a signal that a consolidation
boundary is wrong.

Also do not touch `Looks/*.swift` (A4), `Processing/*` (A1), or `DesignSystem/Theme.swift`.

## The task

Two consolidations, 8 files → 2.

**`Camera/ProPanel.swift`** — the Pro and Looks control surface:
- `ProDial.swift` (21 KB) already contains `ProDial`, a private `DialTicks`, and the
  `ProParameter` enum. Fold in `ProChipBar.swift` and `TonePanel.swift`.
- `LooksChipBar.swift` belongs with them: it is the same control surface reached from a
  different mode, and A4 is shrinking the `Looks/` module it draws from.
- Aim for one file, ordered top-down: `ProParameter`, `ProDial`, `DialTicks`,
  `ProChipBar`, `TonePanel`, `LooksChipBar`.

**`Camera/PreviewSurface.swift`** — the viewfinder:
- `ProcessedPreview.swift` (17 KB) is the real surface. Fold in `PreviewView.swift` and
  `ProcessedPreviewView.swift` (the UIKit wrappers), and `PreviewMeter.swift`.
- Order: the processing/measurement type first, then its view, then the representables.

## The rule that matters

> Every hunk you produce must be a **pure relocation**. A diff line that changes code
> rather than moving it is a rejection.

Concretely, this means:

- Do not rename a type, property or method.
- Do not change a signature, an access level, a default value, or an `accessibilityLabel`.
- Do not reorder logic, tidy whitespace inside a moved block, or "fix" a comment.
- Do not change an `import`. If a merged file needs an import the parts did not have, the
  consolidation is wrong — report it.
- Preserve the doc comments exactly, including any that explain a decision. They are
  currently about a third of the large files and that ratio is correct.

When merging, copy declarations across **whole**, including their doc comments, and delete
the original file. Do not retype a declaration and do not tidy it as you move it.

## Done when

- 8 files are now 2. Net line count drops only by genuinely duplicated comments or
  duplicated imports; anything more means you changed code.
- `git diff -M main...` shows renames, and every non-rename hunk is a deletion that exactly
  matches a block added elsewhere.
- `Camera/CameraScreen.swift` is untouched.
- Both new files have a leading comment stating what the file contains and which files it
  replaced, so the next reader does not re-split it.

## The one exception you are allowed

`ProcessedPreview.swift` and `PreviewMeter.swift` are both on the preview path. If, and only
if, you find a symbol declared in one and used only by the other, you may move it rather
than duplicate it. Say so explicitly in the commit message. Anything else, report it.

## Commands

```bash
node scripts/generate-pbxproj.mjs        # the file list changed
node scripts/validate-pbxproj.mjs
git add -A && git commit -m "a3: consolidate the camera control and preview surfaces"
```

You cannot compile. CI will. If the build fails, the most likely cause is a dropped import
or a moved declaration you retype — re-read the diff rather than patching.
