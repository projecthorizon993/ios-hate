# Phase 1 device record — first run

**Device:** `iPhone12,5` — iPhone 11 Pro, iOS 27.0. Three lenses, composite device, so this
is the "Pro" case. The SE was not tested.
**Build:** CI artifact from `main` at `d0431cf`, the first green run.
**Log:** `LumaFrame-log.txt` at the repo root, 92 KB.

**Verdict: the app cannot take a photo.** Everything else on this list is secondary to
that. Nothing was fixed while investigating, per the Phase 1 rule.

---

## Findings

### 1. BLOCKER — the capture output is rejected by the session

Every single configuration, with no exceptions:

```
! output rejected by the session: AVCapturePhotoOutput
photo codecs available:                       (empty)
photo codec will be: output default
camera ready: facing=back lenses=3 flash=true hdr=HDR ready
```

and on every shutter press:

```
x capture rejected: This camera offers no photo codec the app can request
```

`camera ready` is logged anyway, which is the second half of the bug: the app reports
itself ready with no way to capture.

**Cause — two competing `AVCapturePhotoOutput`s, one of which is the one used to capture.**

- `CaptureSessionController.reconfigureLocked` (line 260) creates its own
  `AVCapturePhotoOutput`, checks `canAddOutput`, and adds it. This one always succeeds.
- `CameraViewModel` then passes `photo.output` — a *different* instance, owned by
  `PhotoCaptureController` and the one `capturePhoto` is actually called on — into
  `extraOutputs: [photo.output, meter.output]`.
- The `extraOutputs` loop runs second, so `canAddOutput` returns false for it, it is
  skipped, and the app continues.

The consequence is exact: the output that was rejected is the only one that can capture,
and an `AVCapturePhotoOutput` that was never added to a session has no
`availablePhotoCodecTypes` — so the empty codec list is not a platform quirk, it is the
direct result of the output not being attached.

**Why CI could not catch it.** It is a session-negotiation failure, not a logic error.
Every test in the suite passes on a simulator, which has no camera at all. There is no
test that asserts the session actually contains the output the capture path uses.

### 2. MAJOR — lens selection does nothing

```
lens -> 1.0x (ultraWide)
lens -> 1.0x (wide)
lens -> 1.0x (telephoto)
lens -> 1.0x (ultraWide)
```

Every lens resolves to 1.0x. `selectLens` clamps the destination against
`device.minAvailableVideoZoomFactor`, and with the active format being 4032x3024 — the
full-resolution still format `CaptureFormatChooser` picks — that minimum is 1.0. So the
ultra wide's 0.5 is clamped straight up to 1x, and the app logs success.

`camera ready: lenses=3` is true, so the chips are correct; the control behind them is not.

**Secondary.** The same line logs a lens name and a zoom factor that disagree. The log is
the only place that disagreement is visible, and it was written as a success.

### 3. MAJOR — the Pro panel is empty, and cannot say why

Expected on a composite device. But `availabilitySummary` still reaches only
`AppLog.note`, and the summary is not in this log, so the user is left with an empty strip
and no reason. This is the MAJOR already carried in `HANDOFF.md` section 6, now observed.

### 4. MINOR — preview is grainy

Reported by eye. Not yet attributable. The plausible cause is the same format choice as
finding 2: the session runs the 4032x3024 still format, and the preview is a scaled video
stream from it. **Unconfirmed** — needs a look at whether the processed preview was active
at the time, which the log does not record.

### 5. NOT TESTABLE — looks

`look selected: Coolness / Faded Film / No Colour / Lifted Shadows` all appear in the log,
so the looks carousel works. But no photo was ever saved, so **there is no evidence about
colour management yet.** This is the one thing Phase 1 exists to find out, and finding 1
blocks it entirely.

---

## What the user reported vs what the log shows

| Reported | In the log |
| --- | --- |
| camera runs | Yes — session reaches `running` |
| can't change | Confirmed: lens and Pro both inert (findings 2, 3) |
| quality is grainy | Not logged; needs a device repro (finding 4) |
| stuck on ultra wide | Confirmed, and worse than reported: nothing works, not just ultra wide |
| no crash | Confirmed — no crash in 92 KB of log across many sessions |
| can log | Yes |
| colours seem the same | Untestable — no photo ever saved (finding 5) |
| can't capture, no codec | Confirmed, root cause found (finding 1) |

## Next step

Finding 1 makes every other finding untestable. It is a small, well-understood fix — pass
the one output rather than adding a second — and it is worth doing before the SE run,
because otherwise the SE is equally uninformative.

The rule that this breaks: **never add a second instance of something the session already
has.** `reconfigureLocked` owns the photo output; `PhotoCaptureController` must be given
that instance rather than manufacturing its own.
