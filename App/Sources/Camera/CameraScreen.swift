import AVFoundation
import SwiftUI

/// The camera screen. Auto mode only — that is Step 1.
///
/// Layout follows `docs/DESIGN_SPEC.md`: a status row with no tappable controls, the
/// viewfinder, then a bottom stack that is the only interactive region. Portrait only,
/// matching `UISupportedInterfaceOrientations` in the Info.plist; the landscape column
/// layout arrives with the orientation change that enables it.
struct CameraScreen: View {

    @StateObject private var model = CameraViewModel()
    @State private var bridge: PreviewBridge?
    @State private var deviceOrientation = UIDevice.current.orientation
    @State private var focusReticle: UnitPoint?
    @State private var isShowingReport = false

    /// Derived, never stored twice. Rotating the device or flipping the camera both
    /// change it, and there is only one place the angle is computed.
    private var previewRotation: CGFloat {
        PreviewRotation.angle(for: deviceOrientation, facing: model.facing)
    }

    var body: some View {
        VStack(spacing: 0) {
            viewfinder
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
            model.stop()
        }
        .sheet(isPresented: $isShowingReport) { ReportScreen() }
    }

    // MARK: - Viewfinder

    private var viewfinder: some View {
        ZStack {
            PreviewView(session: model.captureSession,
                        rotationAngle: previewRotation,
                        isFrontFacing: model.facing == .front,
                        onBridgeReady: { bridge = $0 })
                .background(Theme.ColorToken.surfaceBase)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipped()

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
                    Button("capability report") { isShowingReport = true }
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
        .animation(Theme.Motion.duration(Theme.Motion.overlay), value: focusReticle)
    }

    /// Grid and debug line in a single `Canvas`, so the overlay costs one draw.
    ///
    /// `docs/DESIGN_SPEC.md` fixes both of these: the grid at `stroke.subtle`, and the
    /// debug line at `type.mono` in `text.secondary` over `surface.raised` at 50%, on
    /// the same canvas.
    private var overlayCanvas: some View {
        Canvas { context, size in
            let line = Theme.ColorToken.strokeSubtle
            for index in 1...2 {
                let x = size.width * CGFloat(index) / 3
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0))
                                          .addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(line), lineWidth: 0.5)
                let y = size.height * CGFloat(index) / 3
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y))
                                          .addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(line), lineWidth: 0.5)
            }

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
                focusReticle = UnitPoint(x: value.location.x, y: value.location.y)
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
        .animation(Theme.Motion.duration(Theme.Motion.overlay), value: model.sessionState)
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

    /// Mode-aware controls. Step 1's only one is flash, and it disappears entirely on a
    /// device without a flash rather than showing a dead button.
    @ViewBuilder
    private var contextualRow: some View {
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

    private var modeSwitcher: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(CameraMode.allCases, id: \.self) { mode in
                ModeButton(mode: mode, isSelected: model.mode == mode) {
                    guard mode.isImplemented else {
                        model.present("\(mode.label) mode arrives in a later step", isError: false)
                        return
                    }
                    Haptics.selection()
                }
            }
        }
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
