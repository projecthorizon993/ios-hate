# Phase 1 device record — lens selection

**Device:** `iPhone12,5` — iPhone 11 Pro, three lenses, composite device.
**Source:** user report from the field, cross-checked against the shared log. **No new device
run has confirmed the change made in response** — see "Status" at the end.

---

## Observation

The user reported, by eye, on the running app:

| Chip | Lens actually shown |
| --- | --- |
| 1x | **ultra wide** |
| 2x | wide |
| 4x | **still wide** |

Two separate things are wrong, and they have different causes.

### 1. The telephoto is never reached

The device reported switch points at **2.0 and 4.0** all along, so this is not a zoom-range
or chip-derivation problem. A zoom past the switch-over factor is not producing a hand-over.

Apple documents the mechanism, and it is not a bug in the app:

> "When multiple constituent cameras can achieve a requested zoom factor, the virtual device
> chooses the best camera for the scene. The system makes this decision primarily using a
> camera's focal length… **Secondary conditions are focus and exposure.** …when the scene
> requires focus or exposure to go beyond the limits of the active primary constituent
> device, a camera with a shorter focal length may be able to deliver a better quality
> image. The system considers such a device a **fallback** primary constituent device. For
> example, a telephoto camera with a minimum focus distance of 40 cm isn't able to deliver a
> sharp image when the subject in the scene is closer than 40 cm. For such a scene, the
> virtual device switches to the wide-angle camera."

`AVCaptureDevice.minimumFocusDistance` is in tenths of a millimetre, and the shared log
records **`telephoto: … minFocus 400`** — 400 tenths, i.e. **40 cm**, Apple's own worked
example to the digit.

So the reading is: the telephoto *becomes eligible* at 4x, iOS decides focus will not allow
it for the subject being shot, and falls back to the wide. A photo taken at "4x" is then
really a wide-lens photo.

**This is a hypothesis, not an observation.** It matches the log and Apple's documented rule,
but nothing in the log records *why* iOS fell back. `CaptureSessionController` now logs
`fallback=` and `minFocus(` with every `camera source` line so the next run settles it.

### 2. 1x is the ultra wide

At 1x the composite is showing the ultra wide, which is a shorter focal length than the
wide. Apple prefers the *longest* lens that achieves the requested zoom, so this also looks
like a fallback. It has the same mechanism and the same open question.

This also explains an older unexplained report — **grainy at the outside** — which was
previously attributed only to the preview format cap. The ultra wide is the noisiest of the
three at the frame edges, so being on it is a plausible cause of its own.

---

## Change made

`CaptureSessionController.restrictPrimaryConstituentFallback(on:)`, called from
`applyConfiguration` and guarded by `device.isVirtualDevice`:

```swift
device.setPrimaryConstituentDeviceSwitchingBehavior(
    .restricted, restrictedSwitchingBehaviorConditions: [])
```

An **empty** condition set is the documented way to disallow switching to a fallback camera.

This does not override Apple's lens choice. Per Apple, omitting `videoZoomChanged` from the
restricted conditions means zoom still re-selects the primary constituent on its own:

> "Whenever `videoZoomChanged` isn't included in the restricted switching behavior
> conditions, `.restricted` still allows camera selection when a change in video zoom factor
> makes a camera eligible or ineligible for selection as the `activePrimaryConstituent`."

So Apple keeps choosing the longest lens that fits the requested zoom. Only the *downgrade* to
a shorter lens when focus or exposure is poor is refused.

**The tradeoff, stated plainly.** A subject closer than the telephoto's minimum focus
distance will now stay on the telephoto and **can come out soft**, where before iOS silently
protected the shot by dropping to the wide. For a camera app with explicit lens chips that is
the right default — a lens the user did not pick is a worse surprise than a soft frame — but
it is a real behaviour change, it is logged so a soft frame can be traced to this decision,
and it is worth a second opinion if it turns out to be objectionable in use.

Note also that Apple documents entry is still gated: "**If exposure and focus allow**, this
camera then becomes the new active primary constituent device… Otherwise the
`activePrimaryConstituent` remains unchanged." Restricting fallback stops iOS *abandoning* the
telephoto; it does not guarantee iOS *enters* it.

## Status

**Unverified.** The gates that passed are local source gates plus CI compilation. Per rule 2
of `HANDOFF.md`, nothing here may be called working until it is seen on a device.

To close this out, run the next build and check three lines:

1. `lens fallback restricted: behavior=… conditions=0` — did it apply, and is `conditions`
   empty?
2. `camera source: lens=telephoto … zoom=4.000x` — did 4x actually reach the telephoto?
3. `fallback=` and `minFocus(` on the 1x line — does the 1x ultra wide read as a fallback?

If `lens fallback still 0` appears, the device accepted the call but stayed on `.auto` and
the change did not work.
