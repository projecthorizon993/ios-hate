# iOS Low-Light Cinematic Camera App

## 1. Product Definition

Build a professional iOS camera application focused on:

- Real-time low-light enhancement
- Exposure and ISO bracketing
- Manual and professional camera controls
- Cinematic capture presets
- Seamless multi-camera lens switching
- High-quality zoom within the capabilities of the device hardware
- Live color grading and custom presets
- Full custom UI and custom visual assets
- Efficient use of CPU, GPU, memory, battery, and thermal resources

The primary experience is a fast camera viewfinder with a non-destructive processing pipeline. Users can switch between automatic, low-light bracket, manual, and cinematic modes without restarting the capture session.

## 2. Reference Strategy

The repository at:

`https://github.com/zhihongz/awesome-low-light-image-enhancement`

is a research and model-selection resource. It is not an iOS SDK and must not be treated as an application backend.

Use it to evaluate and select enhancement techniques, not to copy its entire catalog into the app.

Recommended evaluation order:

1. Establish a native Core Image and Metal baseline.
2. Add exposure-aware local tone mapping and denoising.
3. Add a small, mobile-friendly Core ML or Metal model only if it improves real-device results.
4. Compare candidate approaches such as Zero-DCE, EnlightenGAN, SCI, Retinexformer, and newer lightweight models.
5. Prefer models that support iPhone-specific RAW or camera data, real-time inference, stable colors, and acceptable memory use.

The first release must work without a server. A backend is optional and is used only for account features, preset synchronization, model distribution, and analytics.

## 3. Product Goals

### 3.1 Primary goals

- Produce a usable image in very low light without excessive lag.
- Reduce noise, color shifts, blur, and crushed shadows.
- Preserve highlights and natural skin tones.
- Provide predictable manual controls for advanced users.
- Provide a one-tap cinematic look.
- Use every available optical lens before using digital crop.
- Make grading responsive while the user is shooting.
- Preserve the original capture for non-destructive editing.
- Work across supported iPhones with capability-based behavior.
- Avoid draining the battery or overheating the device.

### 3.2 Non-goals for the first release

- Replacing the native iPhone camera sensor pipeline
- Creating a physical lens-switching mechanism
- Claiming digital zoom quality beyond the hardware resolution
- Running large diffusion models on the device
- Making a cloud connection mandatory
- Adding cloud editing, social features, or collaborative projects before the camera is stable

## 4. Core User Modes

### 4.1 Auto mode

- Automatic exposure, focus, white balance, and lens selection
- Automatic low-light detection
- Automatic enhancement strength based on brightness, noise, motion, and thermal state
- Standard still capture and video capture
- Minimal controls with an expandable professional panel

### 4.2 Low-light bracket mode

- Meter the scene and select a short exposure sequence.
- Capture multiple exposures with increasing ISO or exposure time according to scene stability.
- Preserve the RAW or highest-quality source for each exposure.
- Align frames by homography or feature matching.
- Merge highlights, midtones, and shadows after denoising.
- Use temporal consistency for video.
- Preserve motion quality by reducing ISO when movement is detected.
- Show a progress indicator and frame count during the bracket.

Recommended initial bracket strategy:

- Capture three or five frames.
- Keep exposure time within the camera's practical range first.
- Increase ISO only when additional exposure time would create motion blur.
- Use the device's RAW sensor data when available.
- Limit bracket duration to prevent battery and thermal problems.

### 4.3 Manual mode

Expose these controls:

- ISO
- Shutter speed
- Exposure compensation
- Focus distance or autofocus lock
- White balance Kelvin
- Tint
- Lens selection
- Stabilization mode
- RAW, HEVC, ProRes, or other supported output format
- Resolution and frame rate
- Codec and bitrate where the system allows control
- AE lock
- AF lock
- AWB lock
- Histogram, waveform, and focus peaking

Controls must use the camera capabilities reported by the device. Unsupported ranges must be disabled or clearly marked, never simulated.

### 4.4 Cinematic mode

Provide a curated starting point, not a fixed camera setting in every situation.

Default profile:

- 24 fps
- Approximately 1/48 second shutter where supported
- Automatic ISO within a user-selected range
- Log-capable color pipeline where supported
- Wide-gamut working color space
- Neutral highlight roll-off
- Adjustable black level
- Cinematic contrast curve
- Optional grain and subtle halation
- Optional 2.39:1 or 16:9 framing guides
- Optional waveform and safe-area overlays

The app must warn the user when a requested combination is not supported, such as Log, 24 fps, ProRes, and a specific resolution on a particular device.

## 5. Low-Light Enhancement Pipeline

### 5.1 Still-image pipeline

```text
Capture
  -> RAW or YUV conversion
  -> exposure and white-balance normalization
  -> black-level and noise estimation
  -> motion estimation
  -> denoise
  -> highlight recovery
  -> shadow detail recovery
  -> local contrast and illumination correction
  -> optional learned enhancement
  -> color correction
  -> tone mapping
  -> user grading
  -> sRGB, Display P3, or HDR output
```

### 5.2 Video pipeline

```text
Video frame
  -> color conversion
  -> temporal stabilization
  -> temporal denoise
  -> low-light enhancement
  -> detail and sharpness restoration
  -> live color grading
  -> tone mapping
  -> preview or encoded output
```

Temporal processing must avoid flicker. Use frame history, motion estimation, and confidence-based blending rather than applying an independent enhancement to every frame.

### 5.3 Sharpness and detail improvement

Implement detail restoration as a controlled stage after denoising:

- Edge-aware sharpening
- Local contrast enhancement
- Detail mask generation
- Noise suppression before sharpening
- Subject, face, sky, and texture-aware masks
- Optional AI super-resolution only when device quality mode is selected
- Detail amount, radius, and noise-protection controls

Never sharpen before denoising. The enhancement must avoid halos around bright light sources, amplified sensor noise, and unnatural skin texture.

### 5.4 New rendering approach

Use a layered renderer rather than a single filter stack:

1. **Scene layer:** exposure, highlight, shadow, and local illumination.
2. **Quality layer:** denoise, deblur, detail restoration, and optional model inference.
3. **Look layer:** cinematic contrast, color science, grain, halation, and LUT.
4. **Output layer:** display transform, sharpening for the target display, dithering, and export transform.

Each layer must be independently adjustable, cached where possible, and capable of being disabled for comparison.

## 6. Lens Switching and Zoom

### 6.1 Capability detection

At launch and whenever the camera configuration changes:

- Discover wide, ultra-wide, and tele cameras.
- Discover supported focal lengths and optical zoom ranges.
- Discover minimum focus distances.
- Discover supported frame rates, formats, and stabilization modes.
- Discover RAW support and active format limitations.
- Build a capability model instead of hard-coding device names.

### 6.2 Lens orchestration

- Use the native multi-camera configuration when available.
- Keep the capture session active while switching compatible lenses.
- Coordinate focus, exposure, white balance, and stabilization before presenting a frame as ready.
- Align the old and new lens outputs during a transition.
- Use a short crossfade or crop transition only when the hardware cannot provide a native continuous transition.
- Do not claim a seamless physical lens change when the device requires a visible cut.

### 6.3 Zoom strategy

Implement zoom as a staged process:

1. Use the native optical zoom range when the device provides it.
2. Select the best available physical lens for the requested field of view.
3. Use sensor crop only after the optical limit.
4. Apply resize or super-resolution only in high-quality mode.
5. Display the active lens, optical zoom factor, and crop factor.
6. Prevent misleading UI that presents digital crop as optical zoom.

The zoom UI should show a continuous control while internally selecting valid hardware states. The user can choose between Smooth, Optical, and Detailed zoom modes.

## 7. Live Color Grading

### 7.1 Grading controls

Provide:

- Exposure
- Contrast
- Highlights
- Shadows
- Whites
- Blacks
- Temperature
- Tint
- Saturation
- Vibrance
- Hue
- Per-channel color mixer
- Curve controls
- Sharpen
- Grain
- Halation
- Vignette
- LUT selection
- Blend amount
- Bypass comparison

### 7.2 Built-in styles

Initial presets:

- Natural
- Cinematic
- Portrait
- Vivid
- Noir
- Warm Film
- Cool Night
- Urban Contrast
- Soft Pastel
- Black and White

Each preset must define all supported parameters and include a preview thumbnail. A preset must never overwrite the original image.

### 7.3 Custom presets

- Create, rename, duplicate, delete, and reorder presets.
- Save the current grade as a preset.
- Reset individual parameters to the active preset defaults.
- Import and export `.cube` LUTs where licensing and validation allow it.
- Show LUT validation errors without crashing the camera.
- Store preset metadata, version, and compatible color spaces.
- Provide a before/after split view and a neutral comparison state.

## 8. UI and Custom Asset Kit

### 8.1 Application screens

- Permission onboarding
- Camera permission recovery
- Camera main screen
- Capture mode selector
- Manual control panel
- Cinematic control panel
- Preset browser
- Live grading editor
- Gallery
- Photo review and comparison
- Video review
- Export and share flow
- Capture settings
- Device capability diagnostics
- About and model information
- Privacy and data controls

### 8.2 Camera UI components

- Custom shutter control
- Mode dial
- Zoom control
- Lens selector
- Exposure and ISO controls
- Focus reticle
- Level and grid overlays
- Histogram
- Waveform
- Zebra clip indicator
- Focus peaking
- Recording timer
- Storage and thermal indicators
- Bracket progress indicator
- Processing indicator
- Tracking status
- Audio and microphone indicators
- Lock badges for AE, AF, and AWB
- Before/after grading split control

### 8.3 Custom assets to create

- App icon and launch assets
- Custom camera and gallery icons
- Custom mode icons
- Custom control glyphs
- Film-grain textures
- Light-leak textures
- Lens-flare overlays, if legally and technically appropriate
- Preset preview thumbnails
- Onboarding illustrations
- Placeholder and empty-state illustrations
- Color grading wheel and curve assets
- Haptic and sound assets
- Help and diagnostic icons

Use vector assets for controls and raster textures for grain, light effects, and previews. Keep assets in a native asset catalog where possible.

### 8.4 Visual direction

- Dark studio interface suitable for low-light shooting
- High-contrast typography with large touch targets
- Minimal visual noise around the viewfinder
- Consistent spacing, icon sizing, motion, and haptics
- Clear distinction between automatic, manual, and cinematic state
- Color-coded warnings for unsupported settings
- Dynamic Type and VoiceOver support
- Reduced Motion support
- High-contrast and color-blind-friendly overlays

## 9. System Architecture

### 9.1 Technology baseline

- SwiftUI for application screens and controls
- AVFoundation for capture, format configuration, and video recording
- Core Image for composable image operations
- Metal for custom real-time shaders and performance-critical stages
- Core ML for approved on-device models
- Photos framework for media integration
- Swift Concurrency for background work and structured cancellation
- Instruments for profiling thermal, GPU, CPU, memory, and battery behavior

Use UIKit only where a mature UIKit camera or system control provides a clear advantage. Keep rendering and capture logic independent from the UI layer.

### 9.2 Core modules

```text
CameraApp
  App
  Onboarding
  CameraFeature
    CameraView
    CameraViewModel
    CameraCoordinator
    CaptureControls
    ManualControls
    CinematicControls
    Tools
  Capture
    CaptureEngine
    CaptureSession
    DeviceCapabilities
    LensOrchestrator
    PhotoCaptureCoordinator
    VideoCaptureCoordinator
  Processing
    FrameScheduler
    ImagePipeline
    VideoPipeline
    LowLightEnhancer
    Denoiser
    DetailEnhancer
    ToneMapper
    MotionEstimator
    FrameAligner
    BracketMerger
  Grading
    GradeEngine
    ColorSpaceConverter
    LUTProcessor
    PresetStore
  Resources
    Assets
    LUTs
    Presets
    Localizations
  Media
    MediaLibrary
    MediaExporter
    PhotoEditor
    VideoExporter
  Diagnostics
    PerformanceMonitor
    CapabilityDiagnostics
    CrashAndErrorReporter
```

### 9.3 Capture engine responsibilities

- Configure and own the AVCapture session.
- Expose supported camera and format capabilities.
- Coordinate photo and video outputs.
- Manage orientation and device rotation.
- Handle interruptions, backgrounding, and thermal changes.
- Deliver frames to the processing scheduler with bounded queues.
- Avoid blocking the capture queue with expensive enhancement work.

### 9.4 Processing scheduler responsibilities

- Prioritize preview frames over background exports.
- Drop stale preview frames when processing falls behind.
- Limit frame buffering to a bounded number.
- Use a small number of concurrent GPU jobs.
- Reuse pixel buffers, textures, and command buffers.
- Cancel obsolete bracket or export work safely.
- Publish quality and thermal decisions to the UI.

## 10. Suggested Source Layout

```text
App/
  Sources/
    App/
    CameraFeature/
    Capture/
    Processing/
    Grading/
    Media/
    Resources/
      Assets.xcassets/
      LUTs/
      Presets/
    Diagnostics/
  Tests/
    CaptureTests/
    ProcessingTests/
    GradingTests/
    UI Tests/
  Scripts/
  Configuration/
  Documentation/
```

The implementation agent should create the smallest practical project structure first and avoid generating empty placeholder modules.

## 11. Performance and Resource Budgets

Initial targets for a supported mid-range and recent iPhone:

- Maintain preview cadence appropriate to the selected frame rate.
- Keep camera interaction responsive while processing.
- Avoid unbounded frame queues.
- Keep memory growth stable during a long video session.
- Reduce processing resolution before dropping frames.
- Degrade gracefully when thermal state becomes serious.
- Pause nonessential background work during active recording.
- Avoid CPU readback when GPU processing is possible.
- Reuse expensive resources such as LUT textures and masks.
- Use a low-power profile when the user selects battery priority.
- Use a high-quality profile only when the device is thermally comfortable.

Quality profiles:

| Profile | Preview | Still processing | Video processing | AI inference |
| --- | --- | --- | --- | --- |
| Battery | Adaptive lower resolution | Optional | Optional | Off by default |
| Balanced | Native preview with bounded scale | Full quality | Real-time | Limited or lightweight |
| High | Native preview | Full bracketing and merge | Highest available | Enabled when supported |
| Diagnostic | Full instrumentation | Full quality | Full quality | Benchmark mode |

## 12. Data Model

### 12.1 Capture settings

- Camera identifier
- Lens identifier
- ISO
- Shutter duration
- Exposure compensation
- Focus mode
- Focus distance
- White balance mode
- Kelvin
- Tint
- Frame rate
- Resolution
- Codec
- Bitrate
- Stabilization
- RAW preference
- Log preference
- Color space
- Bracket configuration

### 12.2 Preset model

- Stable identifier
- Name
- Version
- Creation date
- All grade parameters
- Optional LUT identifier
- Color-space compatibility
- Optional strength limits
- Optional device-specific optimization
- Optional creator or source metadata

### 12.3 Media model

- Local identifier
- Capture timestamp
- Original file reference
- Processing recipe
- Active preset version
- Lens and camera metadata
- ISO, shutter, focus, and white-balance metadata
- Export settings
- Optional original thumbnail and enhanced thumbnail
- Optional user rating and favorite state

Preserve the original capture and store processing instructions as a recipe so processing can be re-rendered without destructive edits.

## 13. Optional Backend

The first release must be usable offline. If a backend is added, keep it optional and separate from capture.

Potential backend responsibilities:

- User accounts and authentication
- Preset synchronization
- Preset sharing between devices
- Model version distribution
- Remote model download
- Feature flags
- Crash and performance telemetry
- Content moderation for shared presets
- Optional cloud export jobs

Do not send original photos or videos to the backend without explicit user consent and a documented retention policy.

Suggested service boundaries:

```text
Identity service
Preset service
Model registry
Telemetry service
Export job service
```

Use signed URLs for media, encrypted transport, strict authorization, rate limiting, and deletion workflows.

## 14. Security and Privacy

- Request camera, microphone, photo-library, and local-network permissions only when required.
- Explain why each permission is needed.
- Do not record audio unless the user enables it.
- Keep original media local by default.
- Do not log image contents, EXIF, file names, or user identifiers in debug logs.
- Redact credentials and tokens from diagnostics.
- Use Keychain for credentials and secure local storage where appropriate.
- Use ATS and certificate validation for backend traffic.
- Validate imported LUTs and preset files.
- Provide a one-step way to clear local media, caches, and account data.
- Document model and dataset licenses before shipping.

## 15. Development Phases

### Phase 0: Product and capability baseline

- Confirm minimum iOS version and Xcode baseline.
- Confirm target devices and minimum camera capabilities.
- Create a capability matrix for every supported device.
- Define quality profiles and fallback behavior.
- Define the first supported capture formats.
- Select an initial baseline enhancement algorithm.
- Review licenses for all third-party models, datasets, and assets.

Exit criteria: a device matrix and baseline architecture are documented, and unsupported behavior is explicitly defined.

### Phase 1: Application shell and onboarding

- Create the SwiftUI application shell.
- Add permission onboarding and recovery states.
- Add the custom design system.
- Add app icon, launch assets, and primary navigation.
- Add accessibility foundations and dynamic type support.

Exit criteria: the app launches, explains permissions, and presents a polished empty camera state.

### Phase 2: Camera capture

- Implement the capture session and preview.
- Implement orientation handling.
- Implement photo capture.
- Implement device capability discovery.
- Implement permission, interruption, and backgrounding behavior.
- Add a stable capture state machine.

Exit criteria: reliable preview and still capture work on the minimum supported device.

### Phase 3: Manual controls

- Add ISO, shutter, exposure compensation, focus, and white balance controls.
- Add AE, AF, and AWB locks.
- Add histogram, waveform, zebras, and focus peaking.
- Add supported format and frame-rate settings.
- Add clear unsupported-state messaging.

Exit criteria: users can make predictable manual changes without the capture session becoming unstable.

### Phase 4: Low-light processing

- Add brightness and noise estimation.
- Add denoise and local tone mapping.
- Add shadow and highlight protection.
- Add sharpness and detail restoration after denoising.
- Add a neutral comparison mode.
- Add a performance-aware quality scheduler.

Exit criteria: low-light processing improves measurable image quality while maintaining a stable frame budget.

### Phase 5: Bracket capture and merge

- Add multi-frame low-light bracket capture.
- Add frame alignment.
- Add multi-frame denoise and exposure merge.
- Add motion detection and fallback behavior.
- Add bracket progress and cancellation.
- Add original-versus-enhanced comparison.

Exit criteria: bracket mode produces aligned, natural-looking stills without losing source data.

### Phase 6: Lens orchestration and zoom

- Add multi-camera capability discovery.
- Add lens selection and coordinated switching.
- Add optical, smooth, and crop zoom modes.
- Add transition alignment and fallback cuts.
- Add active-lens and zoom-factor indicators.

Exit criteria: supported devices switch between available lenses without session failures, and the UI accurately distinguishes optical and digital zoom.

### Phase 7: Cinematic mode

- Add cinematic capture profiles.
- Add 24 fps and shutter defaults where supported.
- Add Log and wide-gamut handling where supported.
- Add black level, contrast curve, grain, halation, and guides.
- Add warnings for unsupported combinations.
- Add video export in the supported codecs.

Exit criteria: a user can select a cinematic profile and obtain a consistent, editable look without losing the original capture.

### Phase 8: Live grading and custom presets

- Add real-time grade controls.
- Add built-in presets and preview thumbnails.
- Add custom preset creation, editing, duplication, and deletion.
- Add LUT import and export.
- Add split-screen comparison and bypass.
- Persist recipes and preset versions.

Exit criteria: grading remains responsive, saves correctly, and can be reapplied to the original capture.

### Phase 9: Media, editing, and export

- Build the gallery and capture review flow.
- Add non-destructive recipe editing.
- Add still image export in SDR, P3, and supported HDR formats.
- Add video export with grading and audio settings.
- Add share sheets and save-to-Photos flows.
- Add progress, cancellation, and failure recovery.

Exit criteria: users can capture, edit, compare, export, save, and share without losing the original.

### Phase 10: Optimization and hardening

- Profile CPU, GPU, memory, battery, and thermal behavior.
- Reduce allocations and buffer copies.
- Tune frame scheduling and cancellation.
- Test long recordings and repeated bracket sessions.
- Test interruptions, calls, backgrounding, and storage pressure.
- Add diagnostics and error reporting.
- Complete accessibility, localization, privacy, and security review.

Exit criteria: the app meets its performance budgets and recovers cleanly from runtime failures.

### Phase 11: Release preparation

- Test all supported device and OS combinations.
- Validate App Store privacy declarations.
- Review model, dataset, font, icon, and texture licenses.
- Create release build configuration.
- Add crash-free-session and performance dashboards if a backend exists.
- Prepare screenshots and camera capability disclosures.
- Run a final regression suite.

Exit criteria: the app is release-ready for the defined device and OS support matrix.

## 16. Testing Strategy

### 16.1 Unit tests

- Exposure and ISO clamping
- Device capability mapping
- White-balance conversion
- Color-space conversion
- LUT parsing and validation
- Preset serialization and versioning
- Bracket sequence generation
- Motion and brightness thresholds
- Frame scheduling and drop behavior
- Export recipe generation

### 16.2 Image and video quality tests

- Very dark indoor scenes
- Backlit subjects
- Direct light sources
- Mixed indoor and outdoor lighting
- Faces and skin tones
- Textures, foliage, and reflective surfaces
- Moving subjects
- Long-exposure bracket scenes
- Camera shake during capture
- Lens transitions
- Low-light video flicker
- Preset comparison and LUT correctness

Measure:

- Brightness and exposure stability
- Highlight clipping
- Shadow detail
- Color cast
- Noise level
- Detail retention
- Halting artifacts
- Flicker
- Processing latency
- Frame drops
- Memory growth
- Battery and thermal impact

Use paired reference captures and a fixed evaluation set. Do not rely only on visual inspection.

### 16.3 UI tests

- Permission onboarding
- Mode switching
- Manual controls
- Bracket cancellation
- Lens switching
- Zoom interaction
- Cinematic preset selection
- Live grading
- Custom preset persistence
- Gallery and export
- Error recovery

### 16.4 Device tests

Test every supported device class:

- Ultra-wide, wide, and tele camera combinations
- Devices without tele cameras
- Devices with native optical zoom
- Devices without RAW support
- Devices with Log and ProRes support
- Devices with limited thermal headroom
- Older supported devices

## 17. Acceptance Criteria

The first release is accepted when:

- The app can launch without a backend connection.
- The camera preview is stable and orientation-correct.
- Manual controls honor the device's actual capabilities.
- Low-light mode improves dark scenes without excessive noise or color casts.
- Detail enhancement does not create unacceptable halos or over-sharpening.
- Bracket mode can merge aligned frames and preserve the source.
- Supported devices can change lenses without camera-session failure.
- The UI clearly distinguishes optical zoom from digital crop.
- Cinematic mode exposes a usable curated profile and warns about unsupported combinations.
- Live grading works during preview and can be saved as a custom preset.
- Imported LUTs are validated and failures are recoverable.
- Long recordings have bounded memory usage and no unbounded frame queue.
- Thermal warnings cause graceful quality reduction.
- Original media remains available after grading or enhancement.
- Export includes the selected recipe and metadata.
- Accessibility, privacy, and model/data licensing requirements are complete.
- Unit, integration, UI, and device quality tests pass.

## 18. Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| iOS camera capabilities vary by device | Use runtime capability discovery and graceful fallbacks |
| High ISO introduces noise and blur | Prefer motion-aware exposure, bracket merge, and conservative denoising |
| Learned models cause color shifts or flicker | Evaluate on real iPhone footage and preserve a non-learned fallback |
| Processing increases heat | Adaptive resolution, frame dropping, thermal monitoring, and quality profiles |
| Lens switching causes exposure jumps | Coordinate settings and provide a short transition state |
| Digital zoom is mistaken for optical zoom | Show active lens and crop factor in the UI |
| Presets export incorrectly | Version and validate all recipes and color spaces |
| Imported LUTs are malformed | Parse in an isolated operation and reject invalid data safely |
| Third-party licensing is incompatible | Maintain a license inventory and approved-source policy |
| Backend privacy concerns | Keep capture local and require explicit consent for upload |
| Custom assets consume storage | Use optimized raster assets and load them by demand |

## 19. Agent Execution Rules

The implementation agent should work through the phases in order unless a dependency requires a smaller vertical slice first.

For every task:

1. Read this file and the relevant existing source before changing code.
2. Inspect neighboring components and follow existing naming, layout, and error-handling conventions.
3. Keep capture, processing, grading, and UI responsibilities separated.
4. Add or update tests with every behavior change.
5. Run the project formatter, lint, typecheck/build, and focused tests available in the repository.
6. Do not add third-party dependencies without checking the project first and documenting the reason.
7. Do not commit secrets, API keys, private user data, or licensed assets that are not approved.
8. Do not silently substitute unsupported camera behavior with a fake or simulated result.
9. Keep all media processing non-destructive and preserve the original capture.
10. Record unsupported features in the capability diagnostics and UI.
11. Use bounded queues and cancellation for every real-time processing path.
12. Update this plan when architecture, supported devices, or acceptance criteria change.

Recommended implementation order for the first vertical slice:

1. SwiftUI shell and design tokens
2. Permission onboarding
3. AVCapture preview
4. Photo capture
5. Core Image low-light baseline
6. Manual ISO and shutter controls
7. Denoise plus sharpness pipeline
8. Preset model and live grading controls
9. Gallery and non-destructive export
10. Bracket capture
11. Lens orchestration and zoom
12. Cinematic mode
13. Advanced diagnostics and optimization

## 20. Definition of Done

The project is complete when the supported-device camera experience is stable, the processing pipeline is measurable and adaptive, custom presets and assets are integrated into the native UI, media can be exported non-destructively, the app works offline, performance is profiled on real hardware, and the acceptance criteria have been verified with automated and manual tests.
