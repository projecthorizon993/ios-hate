# LumaFrame — Architecture

Native camera app for **iOS 18+ (Swift/SwiftUI)** and **Android 14+ (Kotlin/Compose)**.

This document is the contract for Steps 1–7. Step 0 (Capability Report) is already
implemented. Read this before writing any feature.

---

## 1. Delivery status

| Step | Scope | Status |
| --- | --- | --- |
| 0 | Architecture + Capability Report (both platforms) | **Code done, device data still missing** |
| 1 | Auto mode with native HDR + camera screen UI (iOS) | **Code done + CI green; on-device unverified** |
| 2 | LUT engine (`.cube` parser, GPU 3D LUT, intensity) | In progress |
| 3 | Style system + Styles screen | Pending |
| 4 | Pro mode, RAW, Pro panel | Pending |
| 5 | ML layer + mask-based style blending | Pending |
| 6 | CI, lean tests, manual checklist | Partially done (CI green on iOS, Android red) |

**Nothing in Steps 1–5 is verified until the Step 0 report is collected from the
iPhone 11 Pro Max, the iPhone SE 2022 and the Galaxy S21 Ultra.** The gate is still
open: the report has never completed a run on a device, and the three-device
comparison that every capability-gated decision below rests on does not exist yet.
Code for Step 1 is written and compiles; nothing about it has been observed working.

### 1.0 Where Step 1 actually stands

Stated precisely so Step 2 is not built on a false assumption:

- `Unit tests` and `Build unsigned IPA` are both **green** on `main`.
- The app has **never run to completion on a device.** The first attempt to open the
  capability report hung the main thread for ~600 ms and was killed by the watchdog.
  Two causes were found and fixed — main-thread-only UIKit read from the detached
  probe, and a second `AVCaptureSession` contending with the live one — but **that fix
  has itself never been run on a device.**
- The reports collected from the three devices before this rewrite came from a
  **pre-rewrite binary that no longer exists**, so none of the values in them describe
  the current code.
- Android has never been built. It is red for reasons unrelated to iOS and has not
  been looked at since the `sdkmanager` fix.

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
- **Zoom chips are measured ratios** against the reported wide lens, and are hidden
  entirely when the ratio cannot be established.
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
- **Apple ProRAW is a separate capability**, `AVCaptureDevice.isAppleProRAWSupported`
  (iOS 14.3+). It is `true` on iPhone 11 Pro / 11 Pro Max and later Pro models, and
  `false` on the iPhone SE 2022. Do not hard-code either answer.
- Ultra HDR JPEG requires `photoQualityPrioritization = .quality` and the format's
  `isHighestPhotoQualitySupported`.

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

### 2.5 iOS CI: use `macos-15`, not `macos-14`

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

### Android — `android/app/src/main/java/com/example/lumaframe/`

```text
MainActivity.kt
design/     Theme.kt
support/    AppLog.kt
camera/     Step 1 — SessionState (plain | extended), gating
processing/ Step 2/5
styles/     Step 3
ml/         Step 5 — MlProcessor interface, LiteRtProcessor, BackendCache
storage/    Step 1
diagnostics/ Step 0 — DONE. Report model, probes, ViewModel, screen, exporter
```

`Diagnostics/` is the one module that already exists on both sides, and it is
deliberately **self-contained**: it has no dependency on the camera, processing or
ML layers, so the app can show a report even if those layers are broken.

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

### Android — `android/gradle/libs.versions.toml`

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

## 9. Testing

Lean and high-value only. The list is in the original brief; the constraint is that
**CI tests run without a device** (`xcodebuild test` needs a simulator destination,
Gradle unit tests need no device).

Do not write tests for rare edge cases or pixel-exact UI.
