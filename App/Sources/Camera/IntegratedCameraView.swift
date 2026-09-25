import AVFoundation
import SwiftUI

struct IntegratedCameraView: View {
    @ObservedObject var cameraManager: NativeCameraManager
    @State private var showsExposure = false
    @State private var showsColorPad = false
    @State private var standardLensMode = false
    @State private var zoomGestureStart: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black
                    .ignoresSafeArea()

                NativeCameraPreview(session: cameraManager.session)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .overlay {
                        if cameraManager.showGrid {
                            cameraGrid
                        }
                    }
                    .simultaneousGesture(cameraZoomGesture)
                    .onTapGesture(count: 2, perform: toggleStandardLens)

                LinearGradient(
                    colors: [.black.opacity(0.6), .clear, .black.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                bottomBar
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .onChange(of: cameraManager.activeLens) { _, _ in
            standardLensMode = false
        }
    }

    private var cameraGrid: some View {
        GeometryReader { proxy in
            Path { path in
                let x = proxy.size.width / 3
                let y = proxy.size.height / 3
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                path.move(to: CGPoint(x: x * 2, y: 0))
                path.addLine(to: CGPoint(x: x * 2, y: proxy.size.height))
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                path.move(to: CGPoint(x: 0, y: y * 2))
                path.addLine(to: CGPoint(x: proxy.size.width, y: y * 2))
            }
            .stroke(.white.opacity(0.32), lineWidth: 0.6)
        }
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            controlButton(cameraManager.flashMode == .auto ? "bolt.badge.a.fill" : cameraManager.flashMode == .on ? "bolt.fill" : "bolt.slash.fill") {
                try? cameraManager.changeFlashMode(nextFlashMode)
            }
            .disabled(!cameraManager.hasFlash)
            .opacity(cameraManager.hasFlash ? 1 : 0.35)

            Spacer()

            controlButton(cameraManager.showGrid ? "grid" : "square") {
                try? cameraManager.changeGridVisibility(!cameraManager.showGrid)
            }

            controlButton("arrow.triangle.2.circlepath.camera") {
                try? cameraManager.changeCamera(cameraManager.cameraPosition == .back ? .front : .back)
            }
            .disabled(cameraManager.isReconfiguring)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            lensSelector
                .opacity(cameraManager.cameraPosition == .back ? 1 : 0.35)

            if showsColorPad {
                colorPad
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }

            if showsExposure {
                exposureControl
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 18) {
                modeButton("PHOTO", systemImage: "camera", selected: cameraManager.outputType == .photo) {
                    try? cameraManager.changeOutputType(.photo)
                }
                modeButton("VIDEO", systemImage: "video", selected: cameraManager.outputType == .video) {
                    try? cameraManager.changeOutputType(.video)
                }
            }

            HStack {
                controlButton(cameraManager.torchMode == .on ? "flashlight.on.fill" : "flashlight.off.fill") {
                    try? cameraManager.changeTorchMode(cameraManager.torchMode == .on ? .off : .on)
                }
                .disabled(!cameraManager.hasTorch)
                .opacity(cameraManager.hasTorch ? 1 : 0.35)

                Spacer()

                shutterButton

                Spacer()

                controlButton("paintpalette") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsColorPad.toggle()
                    }
                }

                controlButton("plusminus.circle") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsExposure.toggle()
                    }
                }
            }
            .padding(.horizontal, 22)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 0.7)
                }
        }
    }

    private var lensSelector: some View {
        VStack(spacing: 4) {
            Text(String(format: "%.1f×", cameraManager.zoomFactor))
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.82))

            HStack(spacing: 7) {
                ForEach(cameraManager.availableLenses) { lens in
                    Button {
                        cameraManager.setLens(lens)
                    } label: {
                        Text(lens.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(cameraManager.activeLens == lens ? .black : .white.opacity(0.82))
                            .frame(minWidth: 38, minHeight: 30)
                            .background(
                                cameraManager.activeLens == lens ? Color.white : Color.white.opacity(0.10),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(cameraManager.isReconfiguring || cameraManager.cameraPosition != .back)
                }
            }
        }
        .padding(4)
        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var colorPad: some View {
        ColorPad(
            settings: cameraManager.colorSettings,
            onChange: updateColorSettings,
            onReset: resetColorPad
        )
        .frame(width: 190, height: 108)
    }

    private func updateColorSettings(_ settings: NativeColorSettings) {
        cameraManager.updateColorSettings(settings)
    }

    private func resetColorPad() {
        var settings = cameraManager.colorSettings
        settings.temperature = 0
        settings.contrast = 1
        cameraManager.updateColorSettings(settings)
    }

    private var exposureControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "minus")
            Slider(
                value: Binding(
                    get: { Double(cameraManager.exposureTargetBias) },
                    set: { value in
                        try? cameraManager.changeExposureTargetBias(Float(value))
                    }
                ),
                in: -2...2
            )
            .tint(.white)
            Image(systemName: "plus")
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(.black.opacity(0.28), in: Capsule())
    }

    private var shutterButton: some View {
        Button {
            cameraManager.captureOutput()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(cameraManager.outputType == .video ? Color.red : Color.white)
                    .frame(width: cameraManager.outputType == .video && cameraManager.isRecording ? 38 : 60)
                    .animation(.easeInOut(duration: 0.15), value: cameraManager.isRecording)
            }
        }
        .buttonStyle(.plain)
        .disabled(!cameraManager.isRunning || cameraManager.isReconfiguring)
        .opacity(cameraManager.isRunning ? 1 : 0.45)
    }

    private var cameraZoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if zoomGestureStart == nil {
                    zoomGestureStart = cameraManager.zoomFactor
                }
                cameraManager.setZoom((zoomGestureStart ?? cameraManager.zoomFactor) * value)
            }
            .onEnded { _ in
                zoomGestureStart = nil
            }
    }

    private func toggleStandardLens() {
        guard cameraManager.activeLens == .wide else { return }
        standardLensMode.toggle()
        cameraManager.setProfessionalZoom(standardLensMode ? 35.0 / 24.0 : 1)
    }

    private var nextFlashMode: NativeCameraFlashMode {
        switch cameraManager.flashMode {
        case .off: .on
        case .on: .auto
        case .auto: .off
        }
    }

    private func modeButton(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.76))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? Color.white : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func controlButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.32), in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.18), lineWidth: 0.7)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct ColorPad: View {
    let settings: NativeColorSettings
    let onChange: (NativeColorSettings) -> Void
    let onReset: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color.cyan.opacity(0.78), Color.white.opacity(0.72), Color.orange.opacity(0.82)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(
                    colors: [.clear, .black.opacity(0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Path { path in
                    let x = proxy.size.width / 2
                    let y = proxy.size.height / 2
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
                .stroke(.black.opacity(0.18), lineWidth: 0.7)

                Circle()
                    .stroke(.white.opacity(0.82), lineWidth: 1.2)
                    .frame(width: 7, height: 7)
                    .position(point(in: proxy.size))

                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Circle().stroke(.black.opacity(0.35), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .position(point(in: proxy.size))
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        update(with: value.location, in: proxy.size)
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    onReset()
                }
            )
        }
        .accessibilityLabel("Color pad")
        .accessibilityHint("Drag horizontally for temperature and vertically for contrast. Double-tap to reset.")
    }

    private func point(in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max((settings.temperature + 1) / 2, 0), 1) * size.width,
            y: min(max(1 - (settings.contrast - 0.75) / 0.5, 0), 1) * size.height
        )
    }

    private func update(with location: CGPoint, in size: CGSize) {
        let x = min(max(location.x / max(size.width, 1), 0), 1)
        let y = min(max(location.y / max(size.height, 1), 0), 1)
        var updated = settings
        updated.temperature = (x * 2) - 1
        updated.contrast = 1.25 - (y * 0.5)
        onChange(updated)
    }
}
