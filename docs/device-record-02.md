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

Two separate things are wrong, and they have different causes. Both are now resolved, and
**neither cause was the one originally recorded below** — the minimum-focus-distance and
fallback theory was disproven on device. The original reasoning is kept because the way it was
wrong is the useful part.

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

### RESOLVED on device — the telephoto now works

**Confirmed on an iPhone 11 Pro running `f0458c7`.** Tapping 4x reaches the telephoto.

**The cause was not the one this record originally hypothesised.** Everything above about
minimum focus distance and fallback was a reasonable reading of Apple's documentation and it
was **wrong**. The log disproved it directly: the restriction had been applied correctly and
changed nothing.

```
lens fallback restricted: behavior=2 conditions=0
camera source: … switching=2 fallback=wide minFocus(ultraWide:-1 wide:120 telephoto:400)
zoom -> 4.0x asked 4.0x, switch points [2.0, 4.0]
sensor hand-over: now single (bound …TripleCamera, zoom 4.000x)
```

`behavior=2` is `.restricted` and `conditions=0` is the empty set, so fallback *was* disallowed
— and the telephoto still never appeared. Minimum focus distance was a red herring.

The real cause is in the last two lines. Apple documents that a lens becomes eligible only
when the zoom factor "increases and **crosses**" its switch-over factor. The chips asked for
exactly 4.0 and the camera settled at exactly `4.000x` — touching the reported switch point
without ever crossing it. Every chip sat precisely on a boundary.

**Fix:** a destination that lands on a reported switch-over point now asks 2% past it, so the
boundary is unambiguously crossed. 1.0 is not a switch-over point, so 1x is unaffected. Which
chip is active is now a band question rather than an equality test, because the camera rests at
4.08 rather than 4.0 and an equality test would have turned a second tap on the same chip into
a new destination instead of a return to 1x.

---

## KNOWN — do not "fix" this: 1x is the ultra wide

**This is the platform's zoom scale, not a defect. Leave it alone.**

| | this app (composite) | Apple Camera (physical lenses) |
| --- | --- | --- |
| lowest stop | 1x | 0.5x |
| 1x | **ultra wide** | wide |
| 2x | wide | telephoto |
| 4x | telephoto | telephoto + crop |

The device reports:

```
zoom: 1…189, below 1x false
switch-over points 2            (i.e. [2.0, 4.0])
```

`minAvailableVideoZoomFactor` is **1.0**, so the composite's zoom range has no 0.5x stop to
offer at all. That forces the chips to begin at 1, and since the switch points are 2 and 4,
each doubling lands on the next lens. The result is Apple's 0.5/1/2 mapping shifted up one
stop, because the app drives the composite rather than the lenses.

**No relabelling can fix it.** The composite's factor-to-lens mapping is fixed by the platform,
so on the composite 1.0 will always be the ultra wide. There is no set of labels that makes 1x
mean "the wide" while staying on the composite.

### Why it still matters, and why it is not being changed now

1x being the ultra wide is the widest, noisiest and most distorted of the three lenses, so the
app **opens on its worst lens**. That is the most likely explanation for the original "grainy
at the outside" report in `device-record-01.md`, which was previously attributed only to the
preview format cap. The format cap was a real fix; it was not the whole cause.

The only way to get Apple's semantics is to **bind the physical constituent devices**. All
three are already enumerated — `ultraWide@3168.0`, `wide@3168.0`, `telephoto@3168.0` — and
`CameraPlan` has the unique IDs. That is Phase 3.1 work, and it was deliberately **not** started
here because:

- the current behaviour is correct and every lens is reachable;
- it costs a session reconfiguration per lens change, trading the smooth ramp for a visible
  cut — a real UX regression to buy a labelling change;
- per `docs/HANDOFF.md` rule 3, one line of work at a time.

**Decide it as a product question, not a bug fix.** The chips are honest zoom factors and the
readout reports the true sensor, so nothing here is misleading today.

### One caveat, left open rather than assumed

`minAvailableVideoZoomFactor` is a property of the **active format**, and every log so far only
shows the one format in use. If some other format on this hardware reports below 1.0, a 0.5x
stop might be reachable on the composite after all and none of this would be necessary. The
capability report already prints `below 1x`; it currently reads `false`. Unverified across
formats.

---

## Also open

**Looks are still broken and the first diagnosis was wrong.** `fef57c8` set all five of
`CIColorCubeWithColorSpace`'s required inputs — including `extrapolate`, which had never been
set — and the device still reported:

```
x cube produced no output; all inputs set (space=sRGB dimension=17 bytes=58956)
```

So `extrapolate` was not the cause. The useful part is what the fixed test helper established:
the **same filter, built the same way, produces output in the CI simulator**. So the filter,
the cube and the colour space are known good, and the only thing that differs between the two
runs is the input image.

`f314b6b` adds a device-side control for exactly that — the same cube applied to a synthetic
grey image of the same extent — and logs `controlSynthesisedImage=`. Control passing means the
image is at fault; control failing means the filter is, on device only. Awaiting a run.

Remember that this bug also had a CI test **skip itself**: `coreImageCanRenderACube` built the
filter incompletely, got the same `nil`, concluded headless Core Image could not render it, and
skipped the only two tests that would have caught it. A wrong platform claim, written by the
bug, and then cited as evidence in `docs/ARCHITECTURE.md`.
