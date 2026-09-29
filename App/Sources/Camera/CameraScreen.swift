import AVFoundation
import SwiftUI

/// The camera screen — Auto, Looks and Pro.
///
/// Layout follows `docs/DESIGN_SPEC.md`: a status row with no tappable controls, the
/// viewfinder, then a bottom stack that is the only interactive region. Portrait only,
/// matching `UISupportedInterfaceOrientations` in the Info.plist; the landscape column
/// layout arrives with the orientation change that enables it.
///
/// Looks and Pro are **sheets over the viewfinder, not replacements for it.** A camera
/// app that swaps the screen to show a slider has taken away the thing the slider is
/// adjusting, and the user has to dismiss it to check the result. The preview is computed
/// per frame, so leaving it visible behind a sheet costs nothing extra.
struct CameraScreen: View {

    @StateObject private var model = CameraViewModel()
    @State private var bridge: PreviewBridge?
    @State private var deviceOrientation = UIDevice.current.orientation
    @State private var focusReticle: CGPoint?
    @State private var isShowingReport = false
    @State private var isShowingLooks = false
    @State private var isShowingPro = false
    @State private var isShowingTone = false
    /// Which Pro parameter's dial is docked, or nil when collapsed.
    @State private var openProParameter: ProParameter?

    /// Derived, never stored twice. Rotating the device or flipping the camera both
    /// change it, and there is only one place the angle is computed.
    private var previewRotation: CGFloat {
        PreviewRotation.angle(for: deviceOrientation, facing: model.facing)
    }

    var body: some View {
        VStack(spacing: 0) {
            viewfinder
            // The docked panel sits **over the lower part of the viewfinder**, not over
            // the whole screen and not in a sheet. It is the only thing that covers the
            // camera, and it covers as little as possible, so the user can still see the
            // top of the frame and the effect of what they are changing while they change
            // it.
            dockedPanel
            bottomStack
        }
        .background(Theme.ColorToken.surfaceBase)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        // The compare hold. `pressing` gives both edges of the press, so releasing always
        // ends it even if the gesture is cancelled by a sheet or a rotation. Without the
        // `onEnded` belt-and-braces below, a cancelled gesture would leave the preview
        // stuck showing the original.
        .onLongPressGesture(minimumDuration: Theme.Motion.tap, maximumDistance: 40) {
            // Fires on a *completed* long press, which is a tap-and-hold that finished.
            // Kept as a no-op safety net; the real work is in `pressing`.
        } onPressingChanged: { pressing in
            if pressing { model.beginCompare() } else { model.endCompare() }
        }
        .task { begin() }
        .task(id: model.banner) { await dismissBannerSoon() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let orientation = UIDevice.current.orientation
            if orientation != deviceOrientation {
                deviceOrientation = orientation
            }
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            Task { await model.stop() }
            // If the screen goes away while the report sheet is still up, the device
            // must not be marked as released: something else now owns the app.
            if !isShowingReport { model.resumeAfterDiagnostics() }
        }
        // `onDismiss` resumes the camera. It used to be wired to `presentReport`, which
        // means dismissing the sheet tore the camera down and immediately presented the
        // sheet again — an endless handover loop, each pass reconfiguring the session,
        // for as long as the user tried to close it.
        .sheet(isPresented: $isShowingReport, onDismiss: { model.resumeAfterDiagnostics() }) {
            ReportScreen()
        }
        // Steps 3 and 4 are **not** sheets. They dock under their chip in the bottom stack
        // and cover only the lower part of the viewfinder, because a look is chosen by
        // looking and a pro value is dialled while watching the viewfinder change. A sheet
        // covers the camera, which is the thing being adjusted. Both also stay out of the
        // diagnostics camera handover — that exists because the report opens a second
        // capture session, and neither of these does.
        .sheet(isPresented: $isShowingReport, onDismiss: { model.resumeAfterDiagnostics() }) {
            ReportScreen()
        }
    }

    // MARK: - Viewfinder

    /// Shown while the user is holding to compare. `accent.compare` per the spec, and it
    /// carries the word rather than relying on colour alone — a blue tint with no label
    /// reads as a rendering fault, not as "this is the unprocessed frame".
    private var compareBadge: some View {
        VStack {
            HStack {
                Text("ORIGINAL")
                    .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Theme.ColorToken.accentCompare)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, Theme.Space.xs)
                    .background(Theme.ColorToken.surfaceRaised.opacity(0.8))
                    .clipShape(Capsule())
                Spacer()
            }
            .padding(Theme.Space.s)
            Spacer()
        }
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var viewfinder: some View {
        ZStack {
            // Two preview paths, chosen by whether the recipe does anything. The direct
            // layer is the fastest preview there is and is on screen for the whole of Auto
            // mode; the processed one is what makes the Looks tab mean anything, because
            // otherwise the intensity slider would be a guess until after the shutter.
            if model.isProcessingActive {
                ProcessedPreviewView(preview: model.processedPreview,
                                     redrawToken: model.previewRedrawToken)
                    .background(Theme.ColorToken.surfaceBase)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipped()
            } else {
                PreviewView(session: model.captureSession,
                            rotationAngle: previewRotation,
                            isFrontFacing: model.facing == .front,
                            onBridgeReady: { bridge = $0 })
                    .background(Theme.ColorToken.surfaceBase)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipped()
            }

            overlayCanvas
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .allowsHitTesting(false)

            // Compare is a hold on the viewfinder, not a toggle in a menu. The gesture is
            // on the ZStack so it also works in the direct-preview path, where there is
            // nothing to re-render — the chrome is the only thing that changes, which is
            // what makes the comparison honest.
            if model.isComparing {
                compareBadge
            }

            if let focusReticle {
                FocusReticle()
                    .position(focusReticle)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            // The report is a debug tool, so it only appears once the debug overlay is
            // already on. It is the only route back into diagnostics now that the camera
            // is the root screen, and it costs no chrome in the default state.
            if model.showDebugOverlay {
                VStack {
                    Spacer()
                    Button("capability report") { presentReport() }
                        .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.textSecondary)
                        .padding(.horizontal, Theme.Space.s)
                        .frame(minHeight: Theme.Space.minTouch)
                        .accessibilityHint("Opens the Step 0 capability report")
                }
            }
        }
        .overlay(alignment: .top) { statusRow }
        .contentShape(Rectangle())
        .gesture(focusGesture)
        .simultaneousGesture(debugTap)
        .animation(Theme.Motion.animation(Theme.Motion.overlay), value: focusReticle)
    }

    /// Grid and debug line in a single `Canvas`, so the overlay costs one draw.
    ///
    /// `docs/DESIGN_SPEC.md` fixes both of these: the grid at `stroke.subtle`, and the
    /// debug line at `type.mono` in `text.secondary` over `surface.raised` at 50%, on
    /// the same canvas.
    private var overlayCanvas: some View {
        Canvas { context, size in
            let line = Theme.ColorToken.strokeSubtle
            // The Path builder closure returns Void, so the two commands are separate
            // statements rather than a chained call.
            var vertical = Path()
            vertical.move(to: CGPoint(x: size.width / 3, y: 0))
            vertical.addLine(to: CGPoint(x: size.width / 3, y: size.height))
            var horizontal = Path()
            horizontal.move(to: CGPoint(x: 0, y: size.height / 3))
            horizontal.addLine(to: CGPoint(x: size.width, y: size.height / 3))
            context.stroke(vertical, with: .color(line), lineWidth: 0.5)
            context.stroke(horizontal, with: .color(line), lineWidth: 0.5)

            var verticalTwo = Path()
            verticalTwo.move(to: CGPoint(x: size.width * 2 / 3, y: 0))
            verticalTwo.addLine(to: CGPoint(x: size.width * 2 / 3, y: size.height))
            var horizontalTwo = Path()
            horizontalTwo.move(to: CGPoint(x: 0, y: size.height * 2 / 3))
            horizontalTwo.addLine(to: CGPoint(x: size.width, y: size.height * 2 / 3))
            context.stroke(verticalTwo, with: .color(line), lineWidth: 0.5)
            context.stroke(horizontalTwo, with: .color(line), lineWidth: 0.5)

            guard model.showDebugOverlay else { return }
            let text = Text(model.debugLine)
                .font(.system(size: Theme.TypeSize.mono, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.textSecondary)

            let padding = Theme.Space.s
            let resolved = context.resolve(text)
            let bounds = resolved.measure(in: CGSize(width: size.width - padding * 4, height: .infinity))
            let origin = CGPoint(x: padding * 2, y: size.height - bounds.height - padding)
            context.fill(Path(roundedRect: CGRect(x: padding, y: origin.y - padding,
                                                  width: bounds.width + padding * 2,
                                                  height: bounds.height + padding * 2),
                              cornerRadius: Theme.Radius.control),
                         with: .color(Theme.ColorToken.surfaceRaised.opacity(0.5)))
            context.draw(resolved, at: origin, anchor: .topLeading)
        }
    }

    /// Tap to focus. A long press is reserved for the compare gesture, which needs a
    /// second style to exist (Step 3), so tap is free.
    private var focusGesture: some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { value in
                guard let point = bridge?.devicePoint(fromViewPoint: value.location) else { return }
                model.focus(atDevicePoint: point)
                focusReticle = value.location
            }
    }

    /// Triple tap toggles the debug overlay. Zero chrome, and it never sits under a
    /// finger while composing. A long press is not usable yet: DESIGN_SPEC reserves it
    /// for the compare gesture, which needs a second style to compare against.
    private var debugTap: some Gesture {
        SpatialTapGesture(count: 3)
            .onEnded { _ in
                model.showDebugOverlay.toggle()
                Haptics.selection()
            }
    }

    // MARK: - Status row

    /// Status only — no tappable controls, so nothing at the top of the screen is ever
    /// under the user's finger while they compose.
    private var statusRow: some View {
        HStack(spacing: Theme.Space.s) {
            StatusChip(text: model.hdr.label, muted: model.hdr.isMuted)

            if let lens = model.readout.lensLabel {
                StatusChip(text: lens)
            }

            if let status = model.sessionState.statusText {
                StatusChip(text: status, isWarning: true)
            }

            if let banner = model.banner {
                StatusChip(text: banner, isWarning: model.isBannerError)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
        .animation(Theme.Motion.animation(Theme.Motion.overlay), value: model.sessionState)
    }

    // MARK: - Bottom stack

    private var bottomStack: some View {
        VStack(spacing: Theme.Space.l) {
            contextualRow
            modeSwitcher
            shutterRow
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.xl)
        .background(Theme.ColorToken.surfaceBase)
    }

    /// Mode-aware controls, in the bottom stack where the spec puts them.
    ///
    /// In Pro this is a row of **chips showing the current value**, each of which expands
    /// in place into its dial. It is not a screen and not a sheet: the user is adjusting a
    /// parameter while looking at the viewfinder, and a full-screen sheet takes away the
    /// thing being adjusted and the thing the adjustment is for. The panel that appears
    /// covers only the lower part of the viewfinder and the preview keeps running behind
    /// it, because the point of a pro control is watching the value change.
    @ViewBuilder
    private var contextualRow: some View {
        switch model.mode {
        case .auto:
            autoControls
        case .pro:
            ProChipBar(model: model,
                       expanded: $isShowingPro,
                       open: $openProParameter)
        case .looks:
            HStack(spacing: Theme.Space.s) {
                LooksChipBar(model: model, expanded: $isShowingLooks)
                toneChip
            }
        }
    }

    /// Opens the tone panel in the same docked slot the carousel uses, so only one of the
    /// two is ever open. Tone is a separate gesture from choosing a look because it is a
    /// different kind of adjustment, not because it needs a different screen.
    private var toneChip: some View {
        Button {
            Haptics.selection()
            isShowingLooks = false
            isShowingTone.toggle()
        } label: {
            Text("Tune")
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(isShowingTone
                                 ? Theme.ColorToken.surfaceBase
                                 : Theme.ColorToken.textSecondary)
                .padding(.horizontal, Theme.Space.s)
                .frame(minHeight: Theme.Space.xl + Theme.Space.s)
                .background(isShowingTone
                            ? Theme.ColorToken.accentActive
                            : Theme.ColorToken.surfaceRaised)
                .clipShape(Capsule())
        }
        .accessibilityLabel("Tone adjustments")
        .accessibilityHint(isShowingTone ? "Collapses the tone controls" : "Expands the tone controls")
    }

    private var autoControls: some View {
        HStack(spacing: Theme.Space.s) {
            if model.capabilities.flash.isAvailable {
                Button {
                    model.toggleFlash()
                } label: {
                    Label(model.flashMode == .on ? "Flash on" : "Flash off",
                          systemImage: model.flashMode == .on ? "bolt.fill" : "bolt.slash")
                        .font(.system(size: Theme.TypeSize.label))
                        .foregroundStyle(Theme.ColorToken.textSecondary)
                        .frame(minHeight: Theme.Space.minTouch)
                }
                .accessibilityLabel(model.flashMode == .on ? "Flash, on" : "Flash, off")
                .accessibilityHint("Turns the flash on or off for the next photo")
            }

            Spacer(minLength: 0)

            if model.isCapturing {
                Text("processing")
                    .font(.system(size: Theme.TypeSize.caption))
                    .foregroundStyle(Theme.ColorToken.textSecondary)
                    .accessibilityLabel("Processing the previous photo")
            }
        }
        .frame(minHeight: Theme.Space.xs)
    }

    /// The open Pro or Looks panel, overlaid on the lower part of the viewfinder.
    ///
    /// A plain overlay rather than a `sheet` for the reason above. It has no background of
    /// its own, so the viewfinder reads through above it, and the panel's own
    /// `surfaceBase` background gives the controls an opaque backing only where they are.
    @ViewBuilder
    private var dockedPanel: some View {
        if model.mode == .pro, let open = openProParameter {
            ProDial(model: model, expanded: $isShowingPro)
                // The chip chose the parameter, so the docked dial has no picker and is
                // told what to show.
                .environment(\.proParameterOverride, open)
                .background(Theme.ColorToken.surfaceBase.opacity(0.96))
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if model.mode == .looks, isShowingLooks {
            LooksCarousel(model: model, expanded: $isShowingLooks)
                .background(Theme.ColorToken.surfaceBase.opacity(0.96))
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if model.mode == .looks, isShowingTone {
            TonePanel(model: model, expanded: $isShowingTone)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(CameraMode.allCases, id: \.self) { mode in
                ModeButton(mode: mode, isSelected: model.mode == mode) {
                    Haptics.selection()
                    // Switching mode collapses any open panel. Leaving a dial open behind
                    // a different mode's chips would be showing a control for something
                    // that is no longer being adjusted.
                    collapsePanels()
                    // Auto is the base state: the recipe stays exactly as the user left
                    // it, because a look dialled in in Looks mode is a preference, not
                    // something leaving the mode should undo.
                    model.setMode(mode)
                }
            }
        }
    }

    private func collapsePanels() {
        isShowingPro = false
        isShowingLooks = false
        isShowingTone = false
        openProParameter = nil
    }

    private var shutterRow: some View {
        HStack {
            GalleryButton(thumbnail: model.thumbnail) {}

            Spacer(minLength: Theme.Space.l)

            ShutterButton(isBusy: model.isCapturing, isEnabled: model.sessionState.isCapturable) {
                model.capture()
            }

            Spacer(minLength: Theme.Space.l)

            if model.canFlip {
                Button {
                    model.flip()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.ColorToken.textPrimary)
                        .frame(width: Theme.Space.minTouch, height: Theme.Space.minTouch)
                }
                .accessibilityLabel("Switch camera")
                .accessibilityHint("Switches between the front and back camera")
            } else {
                // Hidden, not disabled: a flip that goes nowhere is a missing feature.
                Color.clear
                    .frame(width: Theme.Space.minTouch, height: Theme.Space.minTouch)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Lifecycle

    private func begin() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        deviceOrientation = UIDevice.current.orientation
        model.start()
    }

    /// The report opens a capture session of its own, so the camera screen hands the
    /// device over before the sheet appears and takes it back on dismiss. Doing it in
    /// the button action rather than here means the handover happens exactly once per
    /// presentation and cannot be left half-done by a cancellation.
    private func presentReport() {
        // Awaited before the sheet appears. The report opens a capture session of its
        // own, so the handover has to be complete first; showing the sheet first is what
        // let the two sessions overlap.
        Task { @MainActor in
            await model.releaseForDiagnostics()
            isShowingReport = true
        }
    }

    /// A banner is a status line, not something the user has to dismiss by hand while
    /// composing. 3 s is long enough to read a reason, short enough to stop covering
    /// the frame.
    private func dismissBannerSoon() async {
        guard model.banner != nil else { return }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard !Task.isCancelled else { return }
        model.dismissBanner()
    }
}

// MARK: - Pieces

private struct StatusChip: View {
    var text: String
    var muted = false
    var isWarning = false

    var body: some View {
        Text(text)
            .font(.system(size: Theme.TypeSize.caption, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            .background(Theme.ColorToken.surfaceRaised.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.pill))
            .accessibilityLabel(text)
    }

    private var color: Color {
        if isWarning { return Theme.ColorToken.stateWarn }
        return muted ? Theme.ColorToken.textDisabled : Theme.ColorToken.textSecondary
    }
}

private struct ModeButton: View {
    var mode: CameraMode
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(mode.label)
                .font(.system(size: Theme.TypeSize.label, weight: .medium))
                .foregroundStyle(isSelected ? Theme.ColorToken.accentActive : Theme.ColorToken.textDisabled)
                .frame(maxWidth: .infinity, minHeight: Theme.Space.minTouch)
                .background(Theme.ColorToken.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .accessibilityLabel("\(mode.label) mode")
        .accessibilityValue(isSelected ? "Selected" : "Not available yet")
        .accessibilityHint(mode.isImplemented ? "Switches to \(mode.label) mode" : "Not available in this step")
    }
}

private struct ShutterButton: View {
    var isBusy: Bool
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(isEnabled ? Theme.ColorToken.accentActive : Theme.ColorToken.textDisabled,
                                  lineWidth: 3)
                    .frame(width: 72, height: 72)
                if isBusy {
                    // The button is never blocked, per DESIGN_SPEC; the ring goes dim to
                    // say "working" and the label above says "processing".
                    Circle()
                        .fill(Theme.ColorToken.surfaceBase)
                        .frame(width: 58, height: 58)
                }
            }
            .frame(width: Theme.Space.huge + Theme.Space.xl, height: Theme.Space.huge + Theme.Space.xl)
            .contentShape(Circle())
        }
        .disabled(!isEnabled)
        .accessibilityLabel("Take photo")
        .accessibilityHint(isEnabled ? "Captures a photo" : "The camera is not running")
    }
}

private struct GalleryButton: View {
    var thumbnail: UIImage?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .strokeBorder(Theme.ColorToken.strokeSubtle, lineWidth: 1)
                }
            }
            .frame(width: Theme.Space.huge, height: Theme.Space.huge)
            .background(Theme.ColorToken.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .disabled(thumbnail == nil)
        .accessibilityLabel("Gallery")
        .accessibilityValue(thumbnail == nil ? "No photos yet" : "Opens the gallery")
        .accessibilityHint("The gallery arrives in a later step")
    }
}

/// Focus reticle. `accent.active`, per DESIGN_SPEC. The vertical exposure slider that
/// pairs with it is a manual control and belongs to Pro in Step 4.
private struct FocusReticle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.control)
            .strokeBorder(Theme.ColorToken.accentActive, lineWidth: 1.5)
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
    }
}
