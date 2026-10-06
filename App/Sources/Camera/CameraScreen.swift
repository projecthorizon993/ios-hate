import AVFoundation
import SwiftUI

/// The camera screen — Auto and Pro.
///
/// Layout follows `docs/DESIGN_SPEC.md`: a status row with no tappable controls, the
/// viewfinder, then a bottom stack that is the only interactive region. Portrait only,
/// matching `UISupportedInterfaceOrientations` in the Info.plist; the landscape column
/// layout arrives with the orientation change that enables it.
///
/// Pro panels are **docked over the viewfinder, not replacements for it.** A camera
/// app that swaps the screen to show a slider has taken away the thing the slider is
/// adjusting, and the user has to dismiss it to check the result. The preview is computed
/// per frame, so leaving it visible behind the panel costs nothing extra.
struct CameraScreen: View {

    @StateObject private var model = CameraViewModel()
    @State private var bridge: PreviewBridge?
    @State private var deviceOrientation = UIDevice.current.orientation
    @State private var focusReticle: CGPoint?
    @State private var isShowingDeveloper = false
    @State private var isShowingPro = false
    @State private var isShowingTone = false
    @State private var isShowingTables = false
    /// The zoom slider's position while it is being dragged, or `nil` when it is not.
    ///
    /// `nil` means "follow the camera". The readout only refreshes twice a second, so a drag
    /// that read from it would drag the knob backwards under the user's finger. Held only for
    /// the length of the gesture and dropped on release, when the device is the truth again.
    @State private var draggedZoom: Double?
    /// Which Pro parameter's dial is docked, or nil when collapsed.
    @State private var openProParameter: ProParameter?
    /// Whether the gallery is up. A sheet rather than a push, so the camera session is never
    /// rebuilt to go back to the viewfinder — the user returns to exactly the framing they
    /// left, which is the whole point of checking a photo straight after taking it.
    @State private var isShowingGallery = false

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
        }
        // The developer panel, replacing the capability report.
        //
        // It is a sheet because it is a read-only list of values and there is nothing to
        // adjust while it is open — unlike the Pro panels, which dock over the viewfinder so
        // the camera stays visible. It reads cached values and opens no second capture
        // session, so the camera never has to be handed over and the previous
        // release/resume pair is now a no-op.
        .sheet(isPresented: $isShowingDeveloper) {
            NavigationStack { DeveloperPanel(model: model) }
        }
    }

    // MARK: - Viewfinder

    private var viewfinder: some View {
        ZStack {
            // Two preview paths, chosen by whether the recipe does anything. The direct
            // layer is the fastest preview there is and is on screen for the whole of Auto
            // mode; the processed one carries the dialled tone, so what the shutter saves
            // is what was on screen.
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
                    Button("developer") { presentDeveloper() }
                        .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                        .foregroundStyle(Theme.ColorToken.textSecondary)
                        .padding(.horizontal, Theme.Space.s)
                        .frame(minHeight: Theme.Space.minTouch)
                        .accessibilityHint("Opens the developer panel: what this device reports it can do")
                }
            }
        }
        .overlay(alignment: .top) { statusRow }
        .contentShape(Rectangle())
        .gesture(focusGesture)
        .simultaneousGesture(debugTap)
        .animation(Theme.Motion.animation(Theme.Motion.overlay), value: focusReticle)
        .sheet(isPresented: $isShowingGallery) {
            GalleryView { isShowingGallery = false }
        }
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

    /// Tap to focus.
    private var focusGesture: some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { value in
                guard let point = bridge?.devicePoint(fromViewPoint: value.location) else { return }
                model.focus(atDevicePoint: point)
                focusReticle = value.location
            }
    }

    /// Triple tap toggles the debug overlay. Zero chrome, and it never sits under a
    /// finger while composing.
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
            zoomSlider
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
        case .photo:
            // Flash only, in the contextual row.
            autoControls
        case .pro:
            VStack(spacing: Theme.Space.xs) {
                // An empty chip list used to render as an empty strip of the same height —
                // a control that cannot do anything, occupying the space of one that can.
                // `rowContent` collapses that into the reason as a status line, so the panel
                // is hidden rather than vacant and the user is told why.
                switch ProParameter.rowContent(for: model.proCapabilities) {
                case .chips:
                    ProChipBar(model: model,
                               expanded: $isShowingPro,
                               open: $openProParameter)
                case .reason(let text):
                    Text(text)
                        .font(.system(size: Theme.TypeSize.caption))
                        .foregroundStyle(Theme.ColorToken.textDisabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.xs)
                        .accessibilityLabel("Manual controls unavailable")
                        .accessibilityValue(text)
                }
                // Grading lives with grading: the engine's tone and table panels are one
                // tap away in Pro too, below the capture controls.
                HStack(spacing: Theme.Space.xs) {
                    toneChip
                    tablesChip
                }
            }
            .onChange(of: openProParameter, initial: false) { _, opened in
                // The dial takes the docked slot, so opening one closes the panels.
                if opened != nil {
                    isShowingTone = false
                    isShowingTables = false
                }
            }
        case .video:
            // Unreachable while Video is disabled, but the switch must be exhaustive and
            // the mode is coming back with a recorder, so it is spelled out rather than
            // left to a `default` that would hide a fourth mode if one were ever added.
            EmptyView()
        }
    }

    /// The zoom control: a continuous slider, with the device's own optical stops as tappable
    /// labels underneath it.
    ///
    /// It sits in its own row directly under the viewfinder, above the contextual row,
    /// because it is the one control the thumb reaches for while composing — and because a
    /// slider needs the whole width. The flash button and the Pro chips keep the
    /// contextual row to themselves.
    ///
    /// **A device with one lens gets no slider at all**, not a disabled one. The spec:
    /// "a single-lens device has no zoom steps and no lens buttons at all."
    ///
    /// ## Why a slider rather than the chips it replaces
    ///
    /// The chips could only land on the reported stops — 1x, 2x, 4x — so everything between
    /// them was unreachable. 1.5x is a position people use, and on this hardware it is a plain
    /// crop of the wide with no hand-over, which is a perfectly good thing for a slider to do
    /// and a pointless thing for a chip to do.
    ///
    /// The stops stay as labels because they are the *precise* positions. A slider alone makes
    /// 2x a drag to within a few percent, and these labels are tappable, so the exact optical
    /// positions are one tap away as well as reachable by dragging near them. They are drawn
    /// from `zoomStops` rather than from the discovered lens list, for the reason below.
    @ViewBuilder
    private var zoomSlider: some View {
        if !model.capabilities.zoomStops.isEmpty {
            VStack(spacing: Theme.Space.xs) {
                Slider(value: zoomPositionBinding,
                       in: 0...1,
                       onEditingChanged: zoomEditingChanged)
                    .tint(Theme.ColorToken.accentActive)
                    .accessibilityLabel("Zoom")
                    .accessibilityValue(zoomAccessibilityValue)
                    .accessibilityHint("Drag to zoom. The labels below jump straight to a lens.")

                zoomStopLabels
            }
        }
    }

    /// Where the knob sits: the drag while there is one, the camera's own factor otherwise.
    ///
    /// Converted to and from a 0...1 position because the track is curved. The factor itself
    /// is what `draggedZoom` holds and what the camera is told, so nothing downstream has to
    /// know the track bends.
    private var zoomPositionBinding: Binding<Double> {
        let range = model.zoomSliderRange
        return Binding(
            get: {
                let value = draggedZoom ?? Double(model.readout.zoomFactor)
                return CameraViewModel.zoomPosition(forFactor: value, in: range)
            },
            set: { position in
                let factor = CameraViewModel.zoomFactor(forPosition: position, in: range)
                draggedZoom = factor
                model.setZoom(to: CGFloat(factor))
            }
        )
    }

    /// Ends the drag: the last value is ramped to, so the frame settles rather than stopping
    /// where the finger left it mid-ramp.
    private func zoomEditingChanged(_ isEditing: Bool) {
        guard !isEditing, let draggedZoom else { return }
        model.setZoom(to: CGFloat(draggedZoom), isFinal: true)
        self.draggedZoom = nil
    }

    /// What VoiceOver reads while the slider is focused.
    private var zoomAccessibilityValue: String {
        let zoom = draggedZoom ?? Double(model.readout.zoomFactor)
        return "\(String(format: "%.1f", zoom))x"
    }

    /// The reported switch-over factors, evenly spread under the slider.
    ///
    /// Evenly spread rather than positioned at their true place on the track: even on the
    /// curved track 2x sits about a fifth of the way along and 4x about a third, and cramming
    /// four labels into the left third of the slider makes them smaller than the target they
    /// need to be. This is also how the platform's own camera control is laid out.
    private var zoomStopLabels: some View {
        let minimum = model.capabilities.plan.bound?.minAvailableVideoZoomFactor ?? 1
        let stops = CameraViewModel.lensStops()
        let switchOver = model.capabilities.plan.bound?.switchOverZoomFactors ?? []
        // The zoom settles just *past* a switch-over point, so "which chip is lit" has to be a
        // band question, and on the device's own scale rather than the pill's.
        let current = CameraViewModel.band(containing: Double(model.readout.zoomFactor),
                                           switchOver: switchOver)

        return HStack(spacing: 0) {
            ForEach(stops) { stop in
                let asked = CameraViewModel.requestedFactor(forLens: stop.factor,
                                                             minimumAvailableFactor: minimum)
                Button {
                    draggedZoom = nil
                    model.selectZoom(ZoomStop(factor: asked))
                } label: {
                    Text(stop.label)
                        .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                        .foregroundStyle(abs(current - asked) < 0.005
                                         ? Theme.ColorToken.accentActive
                                         : Theme.ColorToken.textSecondary)
                        .frame(minHeight: Theme.Space.xl)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stop.label)
                .accessibilityValue(stop.label)
                .accessibilityHint("Jumps straight to the \(stop.label) lens")
                .accessibilityAddTraits(abs(current - asked) < 0.005
                                        ? [.isSelected, .isButton]
                                        : .isButton)
            }
        }
    }

    /// Opens the tone panel in its docked slot over the viewfinder. Tone is a slower,
    /// dialled-in adjustment, which is why it docks rather than living in the
    /// contextual row.
    private var toneChip: some View {
        Button {
            Haptics.selection()
            openProParameter = nil
            isShowingPro = false
            isShowingTables = false
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

    /// Opens the tables panel in its docked slot over the viewfinder. Imported color
    /// tables are engine inputs, so the chip sits with Tune: grading controls together,
    /// capture controls together.
    private var tablesChip: some View {
        Button {
            Haptics.selection()
            openProParameter = nil
            isShowingPro = false
            isShowingTone = false
            isShowingTables.toggle()
        } label: {
            Text("Tables")
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(isShowingTables
                                 ? Theme.ColorToken.surfaceBase
                                 : Theme.ColorToken.textSecondary)
                .padding(.horizontal, Theme.Space.s)
                .frame(minHeight: Theme.Space.xl + Theme.Space.s)
                .background(isShowingTables
                            ? Theme.ColorToken.accentActive
                            : Theme.ColorToken.surfaceRaised)
                .clipShape(Capsule())
        }
        .accessibilityLabel("Color tables")
        .accessibilityHint(isShowingTables ? "Collapses the color tables" : "Expands the color tables")
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

            toneChip
            tablesChip

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

    /// The open Pro panel, overlaid on the lower part of the viewfinder.
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
        } else if model.mode == .pro || model.mode == .photo, isShowingTone {
            TonePanel(model: model, expanded: $isShowingTone)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if model.mode == .pro || model.mode == .photo, isShowingTables {
            TablesPanel(model: model, expanded: $isShowingTables)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Three modes as one sliding track.
    ///
    /// A single selected pill that slides, rather than three separate buttons. It reads as
    /// one choice with three settings instead of three destinations, which is what it is,
    /// and it keeps the whole switcher to one tap target height and one background shape —
    /// so it costs the viewfinder less chrome than the row of buttons it replaces.
    private var modeSwitcher: some View {
        let modes = CameraMode.allCases
        return GeometryReader { geometry in
            let width = geometry.size.width
            let segment = width / CGFloat(modes.count)
            let index = modes.firstIndex(of: model.mode) ?? 0

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.ColorToken.surfaceRaised)
                    .frame(height: Theme.Space.minTouch)

                Capsule(style: .continuous)
                    .fill(Theme.ColorToken.accentActive.opacity(0.18))
                    .frame(width: segment, height: Theme.Space.minTouch)
                    .offset(x: segment * CGFloat(index))
                    .animation(Theme.Motion.animation(Theme.Motion.mode),
                               value: model.mode)

                HStack(spacing: 0) {
                    ForEach(modes, id: \.self) { mode in
                        ModeButton(mode: mode,
                                   isSelected: model.mode == mode) {
                            choose(mode: mode)
                        }
                        .frame(width: segment)
                    }
                }
            }
            .frame(height: Theme.Space.minTouch)
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: Theme.Space.minTouch)
    }

    /// Applies a mode tap.
    ///
    /// The animation is suppressed for the update itself, because the pill's offset reads
    /// `model.mode` and animating towards a value the model has not taken yet would slide
    /// the pill to the new segment while the old label was still selected under it. The
    /// switch itself is then instant and the next state change animates normally.
    private func choose(mode: CameraMode) {
        guard mode != model.mode else { return }
        Haptics.selection()
        // Switching mode collapses any open panel. Leaving a dial open behind a different
        // mode's chips would be showing a control for something that is no longer being
        // adjusted.
        collapsePanels()
        // Photo is the base state: the recipe stays exactly as the user left it, because a
        // grade dialled in under Pro is a preference, not something leaving the mode undoes.
        withAnimation(nil) { model.setMode(mode) }
    }

    private func collapsePanels() {
        isShowingPro = false
        isShowingTone = false
        isShowingTables = false
        openProParameter = nil
    }

    private var shutterRow: some View {
        HStack {
            GalleryButton(thumbnail: model.thumbnail) {
                isShowingGallery = true
            }

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

    /// Opens the developer panel.
    ///
    /// No camera handover, and no `Task` wrapping. The panel used to need both: the
    /// capability report opened a capture session of its own, so the camera was torn down
    /// and rebuilt around it, and that handover was a race before it was a fix. The panel
    /// reads cached values, so there is nothing to wait for.
    private func presentDeveloper() {
        isShowingDeveloper = true
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
                .foregroundStyle(isSelected
                                 ? Theme.ColorToken.accentActive
                                 : Theme.ColorToken.textDisabled)
                .frame(maxWidth: .infinity, minHeight: Theme.Space.minTouch)
        }
        // Disabled rather than removed, and the reason is in the hint: a mode that cannot
        // capture is a gap the user should be able to see, not a mystery.
        .disabled(!mode.isImplemented)
        .accessibilityLabel("\(mode.label) mode")
        .accessibilityValue(isSelected ? "Selected" : "Not available yet")
        .accessibilityHint(mode.isImplemented
                          ? "Switches to \(mode.label) mode"
                          : "Recording is not implemented yet")
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
        .accessibilityLabel("Photos")
        .accessibilityValue(thumbnail == nil ? "No photos yet" : "Opens your photos")
        .accessibilityHint("Browse, save to Photos, share or delete a capture")
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
