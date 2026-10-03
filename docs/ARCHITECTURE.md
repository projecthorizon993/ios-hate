# LumaFrame — Architecture

> **Reading order, 29 September 2026.** This document is the **platform contract** —
> the verified constraints, the Step-1 decision record, repository topology and the
> Android rules. Keep working from it.
>
> `docs/IOS_PLAN.md` is the **iOS delivery plan**, and it records three live correctness
> defects in the current code that this file does not yet cover: the LUT is applied
> without colour management (3.1 there), composite camera devices cannot do manual
> exposure and the code binds one anyway (3.2), and `photoQualityPrioritization` will
> discard manual exposure (3.3). It also states that **no step has been run on a device**
> and that the Step 0 report was abandoned rather than fixed.
>
> Sections 2.1, 2.2, 8 (Android) and 9 remain current for Android. Section 2.3 has been
> corrected: `isAppleProRAWSupported` is an `AVCapturePhotoOutput` property, not an
> `AVCaptureDevice` one.

Native camera app for **iOS 18+ (Swift/SwiftUI)** and **Android 14+ (Kotlin/Compose)**.

This document is the contract for Steps 1–7. Step 0 (Capability Report) is already
implemented. Read this before writing any feature.

---

## 1. Delivery status

| Step | Scope | Status |
| --- | --- | --- |
| 0 | Architecture + Capability Report (both platforms) | **Code done; report crashes/hangs on device — abandoned** |
| 1 | Auto mode with native HDR + camera screen UI (iOS) | **Code done + CI green; on-device unverified** |
| 2 | LUT engine (`.cube` parser, GPU 3D LUT, intensity) | **Code done + CI green; renderer unverified on device** |
| 3 | Style system + Looks screen | **Code done + CI green; unverified on device** |
| 4 | Pro mode, RAW, ProRAW panel | **Code done + CI green; unverified on device** |
| 5 | ML layer + mask-based style blending | **Code done + CI green; unverified on device** |
| 6 | CI, lean tests, manual checklist | Partially done (CI green on iOS; Android red, on its own branch) |

**Nothing in Steps 1–5 is verified.** The Step 0 report has been abandoned — it crashed,
then hung, and was never made to complete on a device. The three-device comparison every
capability-gated decision below rests on does not exist. All of Steps 1–5 is written,
compiles, and passes CI; none of it has been observed running.

The consequence is narrower than it sounds. Capability gating happens **at runtime** from
what the device reports, so the app does not lie on an SE — it hides the controls that
cannot work. What is actually lost:

- **Device tiering.** The tier comes from measured GPU and memory numbers, not model
  strings, and there are no measurements. The render benchmark exists and runs; its numbers
  have never been read off a real device.
- **Any written record of what the three test devices do.** The `hw.machine` → marketing
  name and chip tables in `DeviceProbe` are a display-only lookup and are guesses about
  hardware, not measurements of it.
- **The `isProRAWSupported` expectation** for the 11 Pro Max. The code reads it at runtime
  and gates on it, so the app is correct either way, but the architecture's claim that it
  is `true` there is an assumption.

None of that blocks Steps 1–5 from working on whatever device they are installed on. It
means the tiering threshold in section 6 is uncalibrated and the report is not a record
anyone can rely on.

### 1.0 Where the app actually stands

Stated precisely so nothing downstream is built on a false assumption:

- `Unit tests` and `Build unsigned IPA` are both **green** on `main`.
- **No step has been run on a device.** Everything in Steps 1–5 compiles and passes CI.
- The capability report was **abandoned**, not fixed. It first hung the main thread, then
  crashed the app after 6–7 seconds, and then hung again. Three candidate causes were
  found and fixed by reading the code — a camera handover that was never synchronised, a
  300 MB autorelease leak in the render benchmark, and a probe that started and stopped
  the one physical camera three or four times in a row. None of them is established as
  the cause, because a jetsam kill writes no crash log and the sync work of Apple's
  Analytics was never obtained. The report is left in the app behind the debug overlay
  rather than deleted, because its on-disk breadcrumb trace is the right tool if it is
  ever picked up again.
- The app log **is** readable on device now: `Documents/LumaFrame-log.txt`, via
  Files.app. It is written and flushed per line, so the tail survives a crash. This
  requires `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` in the
  Info.plist, without which Documents is invisible in Files.app and the file is
  unreachable. An earlier version of this file claimed the log was available before
  either key existed; it was not.
- The reports collected from the three devices before this rewrite came from a
  **pre-rewrite binary that no longer exists**, so none of the values in them describe
  the current code.
- Android is on the `android-step0` branch and off main. Its Step 0 probe has never
  compiled: unresolved Camera2 keys and Kotlin type errors remain. It is finished
  there, on its own timeline, rather than on every commit to the iOS app.

### 1.1 What Step 1 settled on iOS

Recorded here because the next steps build on these decisions and should not relitigate
them:

- **Native HDR for stills is `photoQualityPrioritization = .quality`**, requested only
  where the chosen format reports `isHighPhotoQualitySupported`. The format is chosen
  explicitly by `CaptureFormatChooser` rather than left to the preset, because HDR for
  stills is a property of the format and a preset-chosen format cannot support the
  claim.
- **`isVideoHDREnabled` is never written.** It is the only writable HDR knob and it
  affects video streaming only, so setting it would make the badge claim something it
  cannot deliver (see 2.4).
- **`photoQualityPrioritization` carries a second, opposite requirement that is not yet
  implemented.** `.quality` is requested for native stills HDR, as above. But the other
  branch — `.balanced`, which is also the default — lets the system *override* a manual
  ISO and shutter when the scene is dark enough to require multi-image fusion. When Pro
  mode starts writing manual values, that branch must become `.speed` and the UI must say
  multi-frame fusion is unavailable. Today it is harmless only because nothing writes
  manual values yet. See `docs/IOS_PLAN.md` 3.3.
- **The badge has exactly three states** — `HDR n/a`, `HDR ready`, `HDR requested`.
  The third appears only after a quality-priority capture on a format that reports
  high photo quality. It says **requested**, not resolved, because
  `AVCaptureResolvedPhotoSettings` on this SDK exposes the resolved dimensions and
  the unique ID but **not** the resolved `photoQualityPrioritization` and not the
  resolved ProRAW flag. The outcome is simply not observable through public API, so
  there is no state that can honestly report it, and no "HDR frames" state because
  the app merges no frames itself.
- **There is no 35 mm equivalent focal length on iOS** — not on `AVCaptureDevice`,
  not on `AVCaptureDevice.Format`. Lens ordering and the zoom ratios are derived
  instead from the largest still each format can produce: still area scales with the
  square of the focal length, so the ratio of the square roots between two lenses
  **is** their focal length ratio, which is exactly what a `2x` chip claims. The
  value is stored as `relativeScale` and recorded in the recipe as `rs=`, never
  under a name that promises millimetres.
- **The optical-zoom switch-over points are not read in Step 1**, only their
  presence. The conversion out of `virtualDeviceSwitchOverVideoZoomFactors` is a
  boxed integer type whose element type is not part of any public contract, so the
  numbers wait for Step 6 and a real device.
- **Zoom is a continuous slider**, not a row of chips. The slider runs from the active
  format's `minAvailableVideoZoomFactor` to `min(maxAvailableVideoZoomFactor, 10)` — the
  device reports 189x on an iPhone 11 Pro, and a track spanning that packs 1x/2x/4x into
  its first fifth. The device's reported switch-over factors are drawn underneath as
  tappable labels, because those are the exact lens positions and a drag is not. Hidden
  entirely when the device reports no zoom steps at all.
- **Lens selection is left to iOS.** `primaryConstituentDeviceSwitchingBehavior` is
  `.automatic`. Restricting it — with an empty condition set, and then with
  `.videoZoomChanged`, which the device read back as accepted — kept 4x on the wide
  sensor across every attempt, and once on the ultra wide. See
  `CaptureSessionController.configureConstituentSwitching`.
- **`isVideoZoomEnabled` and pinch zoom are not in Step 1**; zoom is a Step 6 concern
  and the current factor is only carried into the recipe.
- **Captures are written to `Documents/Photos`, never to the photo library.** The
  gallery is Step 9, and the plan requires originals to stay local until the user asks
  otherwise.
- **The recipe travels in `Exif.UserComment` as `v<N>;key=value;…`.** Unknown keys are
  ignored and missing keys fall back, so later steps can add fields without
  invalidating files written now.
- **Landscape is not enabled yet.** `UISupportedInterfaceOrientations` is portrait
  only, so the screen implements the portrait layout from `DESIGN_SPEC.md`; the
  trailing-edge column arrives with the orientation change.
- **The capability report is reached from the debug overlay** (triple-tap the
  viewfinder), so the default screen has no diagnostic chrome.

---

## 2. Verified constraints (checked against official docs, Sept 2026)

These are not opinions. Each one changes the design, so each one is a hard rule.

### 2.1 Android: CameraX must be 1.6+, and Extensions block ImageAnalysis

- CameraX **≤ 1.5 loses OEM camera-extensions support on some devices from
  1 Nov 2026**. CameraX **1.6.0+ is required**. Using 1.6.2.
- **CameraX 1.6.0 removed `ImageAnalysis` support when an extension is enabled**
  (I2d926) because OEM extension implementations do not handle it reliably.

**Consequence — this is the single biggest architectural constraint in the app:**
you cannot have "CameraX HDR/Night/Auto extension" and "ImageAnalysis frames for
preview ML" bound on the same session. The design therefore splits into two session
states, and ML must work without `ImageAnalysis`:

| Session state | Use cases bound | ML frame source | Style in preview |
| --- | --- | --- | --- |
| `plain` | Preview + ImageCapture + ImageAnalysis | `ImageAnalysis` (cheap, 256×256) | Full LUT/style |
| `extended` | Preview + ImageCapture + extension selector | **None** — ML uses the previous mask, cached, and stops updating | LUT only, or frozen mask |

`extended` is entered when the user turns on native HDR/Night/Auto *and* the report
shows that extension is available. `plain` is the default and the safe fallback. The
UI must say "live look refinement paused" rather than silently freezing. See
`AppState.sessionState` in Step 1.

Do not try to work around this with reflection or a second session. Two concurrent
`CameraX` sessions on the same camera will fail on most devices.

### 2.2 Android: there is no general LiteRT NPU delegate

- **NNAPI is deprecated as of Android 15.** Do not target it.
- **Google Play services TFLite ships GPU + XNNPACK only.** There is no NPU delegate
  in the Play services package (confirmed by the LiteRT team, Oct 2025).
- NPU delegates are **vendor-specific**: Qualcomm AI Engine Direct, MediaTek
  NeuroPilot, Intel OpenVINO, Google Tensor. Samsung System LSI / Exynos AI LiteCore
  and Google Tensor were still listed as **"coming soon"** on the official NPU page
  as of 2 June 2026.
- LiteRT Maven **v2 (`litert:2.2.0`) exposes the Interpreter API as CPU-only**;
  GPU-via-Interpreter is a **v1-only** path. We pin the `1.4.2` line
  (`litert`, `litert-gpu`, `litert-gpu-api`) because that is the documented
  Interpreter + `GpuDelegate` path.

**Consequence:** on a **Galaxy S21 Ultra with Exynos 2100** (international model
SM-G996B) there is realistically **no NPU path today** — the report will say so, and
the ML layer uses the GPU delegate. On a **Snapdragon 888** variant (SM-G998B/U/N,
US/China/Korea) the Qualcomm AI Engine Direct delegate is the option to evaluate in
Step 5, and it needs an extra dependency plus per-device verification.

The ML backend is therefore **selected by detected SoC, never hard-coded.** The
report prints the SoC string, the vendor classification, and which delegate classes
are actually on the classpath.

### 2.3 iOS: RAW and ProRAW differ, and neither should be assumed

- Standard **RAW (DNG)** comes from
  `AVCapturePhotoOutput.availableRawPhotoPixelTypes` — this is the correct probe.
- **Apple ProRAW is an output-level capability**, `AVCapturePhotoOutput.isAppleProRAWSupported`
  (iOS 14.3+), *not* a device property. Apple documents querying it with the output
  attached to a session that has a connected video source. There is no
  `AVCaptureDevice.isAppleProRAWSupported`, and the Capability Report probe already
  starts a real session to read it.
- ProRAW is not available in Portrait mode, with Live Photos, or for video. Higher
  resolution RAW/HEIF Max is gated on `Format.supportedMaxPhotoDimensions`, not model
  name.
- Ultra HDR JPEG requires `photoQualityPrioritization = .quality` and the format's
  `isHighestPhotoQualitySupported`.
- `IOS_PLAN.md` section 5.2 records the flip side: `.balanced`, the default, lets the
  system **override a manual ISO and shutter**. Manual values require `.speed`.

### 2.4 iOS: there is no "Smart HDR fired" API

The prompt's expectation of a live HDR badge cannot be satisfied by a public API.
What is public and usable:

| Signal | API | Meaning |
| --- | --- | --- |
| Streaming HDR | `AVCaptureDevice.Format.isVideoHDRSupported` | Sensor-level HDR for video; a good proxy for the hardware's HDR ability. `AVCaptureDevice.isVideoHDREnabled` is **writable** and only affects video streaming. |
| Quality prioritization | `AVCaptureDevice.Format.isHighPhotoQualitySupported` / `isHighestPhotoQualitySupported` | Whether raising `photoQualityPrioritization` actually buys anything on this format. |
| Scene metering | our own preview histogram | The only way to know the *system* chose a multi-frame or long-exposure path. |

**Therefore the HDR badge is derived, not native:** `isVideoHDRSupported` on the
active format (hardware capability) combined with our own highlight-clipping meter on
the preview (scene need). The badge says "HDR ready" vs "HDR active (N frames)" only
where we genuinely merged frames ourselves. Never fake it — `IOS_CAMERA_APP_PLAN.md`
rule 8 and the app's own honesty requirement.

### 2.5 iOS: composite camera devices cannot do manual exposure

Apple documents, on **both** `.builtInTripleCamera` and `.builtInDualWideCamera`:

- no `AVCaptureDevice.ExposureMode.custom`, and no manual exposure bracketing
- no locking focus to a lens position other than the current one
- no locking AWB to gains other than the current ones
- on `.builtInDualWideCamera`, exposure duration, ISO, white balance gains and lens
  position may change when the device switches between its constituent cameras

**Consequence:** binding a composite device means the Pro dial is a control over nothing.
`CaptureSessionController.pickDevice` currently prefers the composite for session liveness,
while `CameraCapabilities.attachBackCameras` filters composites out of the capability
model — the UI and the session disagree, and no test covers the session half.

The resolution is that **lens selection is active `AVCaptureDevice` selection, not zoom on
a composite**: discovery for `[.builtInUltraWideCamera, .builtInWideAngleCamera,
.builtInTelephotoCamera]` yields constituents as separate devices. Pro mode binds a
constituent; Auto mode keeps the composite, where automatic lens switching is an advantage
and no manual control is claimed. Manual controls are hidden when the bound device reports
`isExposureModeSupported(.custom) == false`. The cost is a session reconfiguration per lens
change in Pro mode, which is a deliberate trade against Auto-mode smoothness.

Whether constituents genuinely support `.custom` is inferred from Apple's wording about the
composite, so it must be confirmed on a Pro device. See `docs/IOS_PLAN.md` 3.2.

### 2.6 iOS CI: use `macos-15`, not `macos-14`

- `macos-14` defaults to **Xcode 15.4** and is **deprecated 6 Jul 2026, unsupported
  2 Nov 2026**.
- `macos-15` defaults to **Xcode 16.4** and also has Xcode 26.3 installed.
- Swift language mode stays **v5** (`SWIFT_VERSION = 5.9`) — the project targets
  iOS 18 and strict concurrency is not worth the build risk at this stage.

---

## 3. Processing order (single source of truth)

Both platforms must implement **exactly** this order. Preview and saved photo use
the same code path with the same parameters, which is what makes them match.

```text
1. capture           native pipeline (AVCapturePhotoOutput / CameraX ImageCapture)
                     -> RAW/DNG or sRGB/P3/HEIF still
2. white balance     ONLY if manual WB was set by the user
                     (never re-apply WB the sensor already applied)
3. tone curve        tone curve + exposure/EV, in linear light
4. ml masks          subject / skin-tone / scene masks (Step 5)
5. lut + style       per-region blend using the masks from step 4
6. grain + sharpen   grain last, sharpen after denoise only
7. output transform  to the target color space, then save
```

Two rules that are easy to get wrong and produce the "washed out" look:

- **Do not apply a correction twice.** The native pipeline already applies WB and
  tone mapping. Our step 2 and 3 only run for values the user explicitly dialled in
  (`manualWB == true`). Otherwise they are identity passes.
- **The native pipeline and our processing must not both do highlight recovery.** If
  the report shows the native pipeline is doing HDR fusion, our tone curve runs in a
  constrained range (no hard highlight clip) and the native result is the input.

### 3.1 Color spaces — explicit, per stage

| Stage | Space | Why |
| --- | --- | --- |
| Input from sensor | Device-native (RAW = camera space, JPEG = sRGB or P3) | |
| WB / tone curve | Working space: **linear sRGB** | Curves in gamma space produce muddy shadows |
| LUT | LUT's own declared domain, usually 0–1 gamma | `.cube` `DOMAIN_MIN/MAX` must be honoured |
| Style blend | Working space | |
| Grain | Gamma space | Grain in linear space is invisible in shadows |
| Output | sRGB or **Display P3** if the capture was P3 | |

`ColorSpace` is an explicit parameter on every processor. The LUT and the image both
carry a space, and a mismatch is a **hard error with a log line**, never a silent
conversion. A `.cube` file with no `DOMAIN_*` directive is treated as sRGB domain and
the report logs that assumption.

Display P3 is a per-capture decision, not a global one: if the preview is P3 and the
photo is saved as sRGB, the photo will look different from the preview. The gallery
must show which space each photo is in.

#### What CI cannot check about the LUT

**This subsection was wrong for the lifetime of the app, and its error shipped.** It is kept
because the pattern is the lesson.

It used to say that headless Core Image "**accepts** `CIColorCube` — the filter is created and
all three parameters are set without raising — and then returns nil for `outputImage`", that
the apply stage was therefore untestable in CI, and that this was why two tests skipped. It
went on to conclude that `CIColorCubeWithColorSpace` was "absent from the SDK CI builds
against".

None of that was true. What was actually true:

- `CIColorCubeWithColorSpace` **does** resolve in the CI simulator. The availability test
  asserting exactly that has been passing the whole time, in this same file, four lines above
  the one that skipped.
- `outputImage` returned nil because **this app never set `extrapolate`**, one of the
  filter's five required properties. `CIFilter(name:)` populates no defaults, so an unset
  required input fails the filter's own validation and it yields nothing.
- The test helper `coreImageCanRenderACube()` built the filter *the same incomplete way*, got
  the same `nil`, concluded that headless Core Image could not render the filter, and used
  that conclusion to skip the only two tests that would have caught it. **The bug wrote its
  own blind spot, and then this document cited the blind spot as evidence.**

### 3.1z The second bug: the cube was three floats per sample, not four

Fixing `extrapolate` was necessary and not sufficient. On device the filter still returned
`nil` for every look — including for a synthetic grey image, and through plain `CIColorCube`
as well — which is the signature of a bad **buffer**, not a bad image and not colour
management.

Apple documents `cubeData` as "a 3-dimensional color table of floating-point **premultiplied
RGBA** values", so the buffer has to be exactly `dimension³ x 4 x sizeof(Float)` bytes. The
tables themselves are RGB — that is what a `.cube` file is, and what `CubeLUT.samples` holds —
so the alpha is **added when the upload is built**. It was not being added:

```
inputs: space=sRGB dimension=17 bytes=58956     <- 17^3 x 3 x 4
expected:                            78608     <- 17^3 x 4 x 4
```

A 17³ RGB buffer is 25% short of a 17³ RGBA one, the 3D texture cannot be built from it, and
`outputImage` is `nil`. `LUTProcessor.cubeData(for:)` now widens every RGB triple to RGBA with
alpha 1 — opaque tables, so premultiplication is a no-op, and a zero would premultiply the
colour to black.

This one was catchable in CI and was not, for a specific reason: `coreImageCanRenderACube()`
built its own buffer with `Data(repeating: 0, count: 8 * 4)` — a hand-rolled 2³ cube of the
*right* shape — while every other test asked `cubeData(for:)` for the *wrong* shape. A control
that does not share the code under suspicion cannot rule it out; it was a control of the
control. The helper now takes its buffer from `cubeData(for:)`, and
`testCubeDataIsFourFloatsPerSample` asserts `size³ x 4 x 4` bytes and a 1 in every alpha slot,
at 2³, at the parser's maximum, and at the shipped 17³.

So the answer to "what cannot CI check about the LUT" is: **whether the graded pixels are
correct.** CI *can* and now does check that the filter is constructible, that the upload is
the documented shape, and that it produces an output at all. Comparing pixel values against a
reference tool still needs a device.

`LUTProcessor` now builds the filter through the typed accessor `CIFilter.colorCubeWithColorSpace()`,
which sets all five required properties and makes a wrong type or a misspelled property a
**compile error** rather than a silent nil. The name `CIColorCubeWithColorSpace` remains a
constant in that file, used for the availability check, so the test that asserts the filter
resolves still guards production code rather than a string only the test owns.

Carried to the device, then — unchanged, because none of these are CI-checkable:

- [ ] A 2×2×2 identity table leaves a known flat image unchanged.
- [ ] A deliberately obvious table (all red, or an inverted ramp) changes it visibly.
- [ ] Intensity 0…1 blends monotonically, with 0 an exact no-op.
- [ ] The result matches what the same `.cube` produces in a reference tool on the same
      file, which is the only real check that byte order and colour space agree.

### 3.1a Why the colour-managed filter, and not `CIColorCube`

`CIColorCube` is **invariant**: it applies the table to whatever sample values it is given,
with no colour management at all — the same as `CIPhotoEffect`. `CIContext`'s working space
is linear sRGB, and a colourist's `.cube` is gamma-encoded, so an invariant cube is handed a
table authored in one space and evaluated in the other. That is not a subtle bias, it is the
wrong transfer function, and it is the washed-out / over-saturated look.

`CIColorCubeWithColorSpace` takes the table's own space as its working space and performs
the conversion. The "there is nothing to override because the domain guard already proved the
spaces match" argument that used to justify `CIColorCube` here was wrong on its own terms:
matching the *name* of a space is not the same as being in it, and the invariant filter
performs no conversion in either direction.

### 3.2 The whole pipeline, and what it costs

One `ProcessingSettings` value, one `ProcessingPipeline.render`, called by **both** the
preview and the saved photo. Two processing paths is how a look ends up correct on screen
and wrong in the file, and it is invisible in CI because each path can be individually
correct.

Stages, in order, and the order is the design:

| # | Stage | Space | Why there |
| --- | --- | --- | --- |
| 1 | exposure, white balance, lift/contrast/saturation | **linear sRGB** | A curve in gamma space makes muddy shadows |
| 2 | the look, at the user's intensity | gamma sRGB | A `.cube` table is authored over gamma-encoded values |
| 3 | per-region blend, if a subject mask is usable | gamma sRGB | Full look on the subject, 35% on the background |
| 4 | sharpen, then grain | gamma sRGB | Grain in linear light is invisible in shadows |
| 5 | output transform | the file's own space | A P3 capture must not be tagged sRGB |

Two rules enforced in code rather than trusted:

- **A correction only runs when the user asked for it.** The native pipeline has already
  applied white balance and tone mapping; applying ours unconditionally is what makes a
  photo look washed out.
- **Highlight recovery is not in this list.** If the native pipeline is already doing HDR
  fusion, doing it again is the other half of the same problem.

The identity recipe is a **fast path**, not just a correctness one: with nothing to do the
viewfinder uses `AVCaptureVideoPreviewLayer` directly and no Core Image frame is produced
at all. That is the state Auto mode sits in, so the expensive path only exists once the
user has asked for something.

The original bytes are always written untouched. A processed version is written beside
them as a separate file with `derivedFrom` pointing back, so any photo can be re-rendered
from its original rather than from a derived one. **RAW is deliberately not re-rendered**
— the recipe is recorded in its metadata instead, because processing a RAW would destroy
the reason the user asked for it.

### 3.3 What has to be checked on a device

CI now covers the things that can silently produce **no image at all** — the filter
resolves, every required input is set, and every shipped look yields an output. What is left
is whether the graded *pixels* are right, which needs a reference tool. Each line is a real
question, not a formality:

- [ ] Original is pixel-identical to the capture. A non-identity pipeline on an identity
      recipe would show up here and nowhere else.
- [ ] A 2×2×2 identity `.cube` leaves a known flat image unchanged.
- [ ] An obvious table (all red, or an inverted ramp) changes the image visibly.
- [ ] Strength 0…1 blends monotonically, with 0 an exact no-op.
- [ ] The result matches the same `.cube` in a reference tool on the same file. This is
      the only check that byte order and colour space agree, and it is the one that catches
      a transposed table.
- [ ] The processed preview and the saved file are the same image. Checked by eye against
      a reference tool, not by CI.
- [ ] Preview stays live with a look applied on an 11 Pro Max and on an SE 2022, and does
      not fall to single-digit frame rates.
- [ ] A RAW capture is byte-identical to what AVFoundation produced.
- [ ] The Pro panel on an SE shows "no manual controls" rather than dead switches.
- [ ] Person segmentation finds a face, and the blend edge is invisible on it.
- [ ] A scene with no person gets the look applied globally, with no visible seam.
- [ ] Skin tone holds its hue when a warm look is applied at full strength.
- [ ] The log file appears in Files.app and contains the lines the run produced.

---

## 4. Module layout

### iOS — `App/Sources/`

```text
App/          LumaFrameApp, RootView (permission gate)
DesignSystem/ Theme.swift  (tokens mirror docs/DESIGN_SPEC.md)
Support/      AppLog, Haptics, MemoryProbe, LumaFrameSafety (ObjC @try/@catch)
Camera/       Step 1 — DONE, pending device verification
              CameraCapabilities   capability model + FeatureAvailability gating
              CaptureFormatChooser active format and preview frame rate
              CaptureSessionController  session state machine, interruptions
              PhotoCaptureController    quality prioritisation, RAW/ProRAW
              PreviewMeter              bounded highlight/average meter
              CameraMode, CameraViewModel, CameraScreen, PreviewView
Processing/   Step 2/5 — LUT, tone curve, grain, blend, color space
Styles/       Step 3 — style model, bundled looks, strength
ML/           Step 5 — MLProcessor protocol, CoreMLProcessor, BenchmarkCache
Storage/      Step 1 — DONE. CaptureMetadata (EXIF + recipe), PhotoStore
Diagnostics/  Step 0 — DONE. Report model, probes, ViewModel, screen, exporter
```

### Android — a separate repository, on the `android-step0` branch

**Not in this repository any more.** The Android target lives on its own branch
pending the split described in section 9. It is recorded here because the design
constraints in section 2.1 and 2.2 were derived from it, and they still apply.

```text
MainActivity.kt
design/     Theme.kt
support/    AppLog.kt
camera/     Step 1 — SessionState (plain | extended), gating
processing/ Step 2/5
styles/     Step 3
ml/         Step 5 — MlProcessor interface, LiteRtProcessor, BackendCache
storage/    Step 1
diagnostics/ Step 0. Report model, probes, ViewModel, screen, exporter
```

Its Step 0 probe is **not finished**: it was written without ever compiling and still
has unresolved Camera2 keys. It is worked through on that branch rather than here, so
that a commit to the iOS app is not attached to an unrelated red check.

`Diagnostics/` is the one module that exists on both sides, and it is deliberately
**self-contained**: it has no dependency on the camera, processing or ML layers, so the
app can show a report even if those layers are broken. That self-containment is also
what makes it the right starting point for the format-contract fixtures in section 9.4.

---

## 5. Capability gating

There is exactly one capability model per platform, produced at launch and refreshed
when the configuration changes. **No feature reads a device name or model string.**

```swift
// iOS
struct CameraCapabilities {
    var backCameras: [BackCameraCapabilities]   // empty on iPhone SE 2022
    var rawPixelTypes: [OSType]
    var proRawSupported: Bool                   // runtime, not assumed
    var wideGamut: Bool
    var photoQualitySupported: Bool
    var suggestedDeviceTier: DeviceTier         // high | mid | low
}
```

The rule for the UI is: **hide what does not exist, disable what exists but is not
available right now, and never simulate.** A hidden control must not be reachable
through a stale state either — the ViewModel clamps to the capability set on every
mode change, not only at construction.

Consequences already known:

- **iPhone SE 2022**: one back camera → no lens buttons, no zoom steps, no Night
  option in the UI (there is no manual night control on iOS at all; the system
  applies it automatically, so we simply do not show one).
- **iPhone 11 Pro Max**: three back cameras → this is the reference device for lens
  switching, and `isAppleProRAWSupported` is expected `true` (verify in the report).
- **Galaxy S21 Ultra**: four back cameras listed by Camera2, but third-party access
  to every physical camera, to RAW, or to Samsung's Expert RAW tuning is **not**
  guaranteed. The report enumerates physical IDs and the RAW capability flag; the UI
  follows the report, not the sensor list.

---

## 6. Device tiering

`DeviceTier` (high / mid / low) is chosen from **measured** numbers in the report,
never from the model name. It controls preview ML frequency and ML resolution only:

| Tier | Preview ML | Resolution | Cadence |
| --- | --- | --- | --- |
| high | enabled | 256×256 | every 3rd frame |
| mid | enabled | 192×192 | every 5th frame |
| low | disabled by default | — | — |

Tier is recomputed from the render/inference benchmark on first launch and cached.
The user can override it in settings, and an override always wins.

---

## 7. Logging

The user debugs from logs, not a debugger. Every one of these emits a log line:

- capability detection (once per device, at launch)
- capture settings actually applied (ISO/shutter/EV/WB/lens/RAW/format)
- session state transitions `plain <-> extended`
- every ML load (model name, backend, input/output shapes) and **every 30th inference**
  with ms
- every error, with the domain and a human-readable reason

`Support/AppLog.swift` and `support/AppLog.kt` write to the platform log **and** to a
bounded in-memory ring buffer, which the Capability Report can dump. That is how the
user gets a full log out of a device with no debugger attached.

Never log image contents, file names, or user identifiers.

---

## 8. Dependencies (pinned)

### iOS

| | Version |
| --- | --- |
| Deployment target | iOS 18.0 | Raised from 17.0: Vision's `supportedOutputPixelFormats()` is 18.0+, and the app probes the real capability surface rather than a guessed one. Every device on the test matrix runs 18 or newer, so nothing is lost. |
| Swift language mode | 5 (`SWIFT_VERSION = 5.9`) |
| Xcode on CI | `macos-15` (Xcode 16.4) |
| 3rd party | **none** — Apple frameworks only, deliberately |

No SwiftPM dependencies. The old vendored `MijickCameraView` is no longer used; the
viewfinder is a plain `UIView` wrapped in `UIViewRepresentable`.

### Android — on the `android-step0` branch

Kept here because the versions are the reason for two of the hard rules above.

| | Version | Note |
| --- | --- | --- |
| Gradle | 8.14.3 | wrapper |
| AGP | 8.13.2 | last 8.x stable; keeps the standard `android {}` DSL |
| Kotlin | 2.3.21 | with `org.jetbrains.kotlin.plugin.compose` |
| compileSdk / targetSdk / minSdk | 36 / 35 / 34 | |
| Compose BOM | 2026.06.01 | newest BOM that does not force compileSdk 37 + AGP 9 |
| CameraX | 1.6.2 | **required**, see 2.1 |
| LiteRT | 1.4.2 | `litert`, `litert-gpu`, `litert-gpu-api` — the only line with the documented Interpreter+GPU path |
| activity-compose | 1.9.3 | |
| JUnit | 4.13.2 | |

Deliberately **not** adopted yet, and why:

- **AGP 9 + built-in Kotlin**: AGP 9.0+ enables built-in Kotlin by default and
  applying `org.jetbrains.kotlin.android` on top is a hard error unless you opt out
  with `android.builtInKotlin=false`. The opt-out is removed in AGP 10. Staying on
  AGP 8.13.2 keeps the standard setup and is not worth churning now.
- **Play services TFLite 16.5.0**: the "recommended path on Android" per Google, but
  it is GPU + XNNPACK only, and it requires Google Play services on the device. The
  standalone LiteRT artifacts give us a delegate-probing API
  (`CompatibilityList.isDelegateSupportedOnThisDevice`) that works without it. Revisit
  if Play services proves to matter.
- **Qualcomm AI Engine Direct delegate**: only added in Step 5, and only if the
  report shows a Snapdragon variant.
- **Coroutines Flow is not in the catalog yet** — Step 1 needs it and it will be
  added with the camera layer, not guessed at now.

---

## 9. Infrastructure and repository topology

Decided, and deliberately **not** a backend.

### 9.1 What is actually shared

**The file formats. Not the code, and not a server.**

There is one artefact both platforms must agree on byte for byte: the data a photo
carries and the rules for reading it. That is:

| Artefact | Where it is defined today | Notes |
| --- | --- | --- |
| Recipe string grammar | `Storage/CaptureMetadata.swift` | `v1;key=value;…` in `Exif.UserComment` |
| Preset JSON schema | does not exist yet (Step 3) | |
| `.cube` accept/reject rules | `Processing/CubeLUTParser.swift` | including the error taxonomy |
| Colour-space rules per stage | `Processing/ColorSpace.swift` | section 3.1 above |
| Reference fixtures | do not exist yet | see 9.4 |

The native pipeline in `docs/ARCHITECTURE.md` section 3 is a **second** shared thing
and is the more important of the two: the order of operations, and the rule that
preview and saved photo use the same code path with the same parameters. A preset
authored on one platform and applied on the other only matches if both follow the same
order, not merely the same file format.

### 9.2 Repositories

Three, each versioned and released on its own cadence.

| Repository | Contains | Version | Ships when |
| --- | --- | --- | --- |
| `ios-hate` (this one) | iOS app | semver + build number | App Store release |
| Android app | Android app | semver + `versionCode` | Play release |
| **format-contract** | the normative spec and fixtures | semver, own CHANGELOG | whenever the format changes |

A manifest of compatible versions lives in the contract repo, and each app records the
contract version it implements in exactly one place, and logs it at startup. That way a
photo taken by an old app declares which reader it needs, instead of relying on someone
remembering.

### 9.3 Why separate repos and not a shared library

The tempting design is a shared SwiftPM / Gradle package holding the parsers. It is
wrong here, for three reasons:

1. **A shared library couples the release cadences**, which is the thing being avoided.
   Every change to the recipe format would force both apps out together.
2. **Both platforms cannot share code anyway.** The format is text; the parsers are
   Swift and Kotlin. A shared library would have to be either Swift-only (so Android
   reimplements it and the contract drifts) or a C target (which is not worth a build
   system for a text format).
3. **A git submodule or a private package dependency makes every build need network
   access**, and the brief requires the first release to work with no backend and no
   network.

So: **data is shared, code is not.** The contract is a specification plus test
fixtures, and each platform implements it independently and is held to it by tests.

### 9.4 The contract, concretely

The contract repository holds:

- A **normative specification** in prose, not comments in somebody's source file. The
  grammar currently lives in `CaptureMetadata.swift` doc comments, which is not a
  specification — it is a description of one implementation.
- **JSON Schemas** for the preset file, so a third-party tool can validate one.
- **Fixtures**: a small, fixed set of files with byte-exact expected results.
  - recipe strings in, parsed field maps out
  - `.cube` files in, parsed tables and specific error cases out
  - at least one *invalid* fixture per rejection rule, because the rejection path is
    the half of a parser that is never tested
- A **conformance suite** each app can run in CI.

The fixtures are the enforcement. Two implementations that both pass the same
byte-exact fixtures produce the same files; two that only agree on prose will not.

### 9.5 Versioning rules

- **MAJOR** — an incompatible change. A reader must not silently misinterpret old
  files. Old files keep their own version marker, so this is a *new* reader path, never
  a reinterpretation.
- **MINOR** — additive. A new optional key. A reader that does not know the key ignores
  it, which is why unknown keys are skipped rather than rejected in `CubeLUTParser`.
- **PATCH** — editorial: clarifications, extra examples, no behaviour change.

Two hard rules:

1. **A reader must accept every version at or below its own.** A photo taken three app
   versions ago must still open. This is why the version is *in the file*
   (`v1;…` in the recipe, `version` in a preset) rather than implied by the app.
2. **No format change ships without a contract version bump and a fixture.** A change
   to parsing that is not accompanied by a new fixture is a bug, and CI should be
   arranged so it is caught before review rather than after.

### 9.6 What this rules out

- **No backend, and none is planned.** Preset sync, model distribution, accounts and
  telemetry all stay out. This supersedes the optional-backend sketch in
  `IOS_CAMERA_APP_PLAN.md` section 13; that section is retained only as the record of
  what was considered and why it was dropped.
- **No cross-repo source sharing.** No submodules, no private SwiftPM or Gradle
  dependencies, no generated clients from a shared schema.
- **No implicit contract.** If a rule is only in a source comment, it is not a rule
  yet. It becomes one when it is in the specification and has a fixture.

### 9.7 Privacy consequence

None, and that is the point: section 14 of the plan still holds in full. Media stays on
the device, there is no account, and nothing is uploaded. Separating the *contract* into
its own repository adds no network path and no data path.

### 9.8 Migration order

1. Create the contract repository with the specification, extracted from the doc
   comments in `CaptureMetadata.swift`, `CubeLUTParser.swift` and `ColorSpace.swift`.
2. Add the fixtures, and a conformance test target in this repository that runs them.
   Until this exists, the contract is prose and proves nothing.
3. Add the same conformance target to the Android repository against the same fixtures.
4. Only then change a format.

Step 2 before step 3, because the iOS side is the only implementation that exists, and
it is the one that should be measured against the fixtures first.

---

## 10. Testing

Lean and high-value only. The list is in the original brief; the constraint is that
**CI tests run without a device** (`xcodebuild test` needs a simulator destination,
Gradle unit tests need no device).

Do not write tests for rare edge cases or pixel-exact UI.
