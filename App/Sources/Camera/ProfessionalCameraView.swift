import AVFoundation
import MijickCameraView
import SwiftUI

struct ProfessionalCameraView: MCameraView {
    @ObservedObject var cameraManager: CameraManager
    let namespace: Namespace.ID
    let closeControllerAction: () -> Void

    @State private var automaticLens = true
    @State private var professionalControlsVisible = true
    @State private var manualExposure = false
    @State private var selectedISO: Float = 400
    @State private var selectedShutter: Double = 1.0 / 60.0
    @State private var selectedBias: Float = 0
    @State private var selectedZoom: CGFloat = 1
    @State private var standardLensMode = false

    var body: some View {
        ZStack {
            createCameraView()
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.62), .clear, .black.opacity(0.76)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer()
                if professionalControlsVisible {
                    professionalPanel
                }
                lensSelector
                zoomControl
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .background(Color.black)
        .statusBarHidden()
        .onAppear {
            selectedISO = cameraManager.professionalISO
            selectedShutter = max(cameraManager.professionalExposureDuration.seconds, 0.001)
            selectedBias = cameraManager.professionalExposureBias
            selectedZoom = defaultZoom(for: cameraManager.activeLens)
        }
        .onChange(of: cameraManager.activeLens) { _, lens in
            standardLensMode = false
            selectedZoom = defaultZoom(for: lens)
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LUMA FRAME")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                HStack(spacing: 7) {
                    Text(cameraManager.activeLens.name)
                    Text("·")
                    Text("\(cameraManager.professionalEquivalentFocalLength)mm")
                }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)

            Spacer()

            iconButton(cameraManager.hasFlash ? flashSymbol : "bolt.slash.fill") {
                cameraManager.setProfessionalFlash(nextFlashMode)
            }
            iconButton(showGrid ? "grid" : "grid") {
                try? changeGridVisibility(!showGrid)
            }
            iconButton("arrow.triangle.2.circlepath.camera") {
                try? changeCamera(cameraPosition == .back ? .front : .back)
            }
        }
    }

    private var professionalPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Text(manualExposure ? "MANUAL EXPOSURE" : "AUTO EXPOSURE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button(manualExposure ? "AUTO" : "MANUAL") {
                    manualExposure.toggle()
                    cameraManager.setProfessionalExposureMode(manualExposure ? .custom : .continuousAutoExposure)
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(manualExposure ? Color.yellow : Color.white)
            }

            if manualExposure {
                exposureSlider(title: "ISO", value: Binding(
                    get: { Double(selectedISO) },
                    set: { value in
                        selectedISO = Float(value)
                        cameraManager.setProfessionalISO(selectedISO)
                    }
                ), range: 50...6400, format: "%.0f")
                exposureSlider(title: "SHUTTER", value: Binding(
                    get: { selectedShutter },
                    set: { value in
                        selectedShutter = value
                        cameraManager.setProfessionalExposureDuration(CMTime(seconds: value, preferredTimescale: 1_000_000_000))
                    }
                ), range: 0.001...0.067, format: "1/%.0f s", reciprocal: true)
                exposureSlider(title: "EV", value: Binding(
                    get: { Double(selectedBias) },
                    set: { value in
                        selectedBias = Float(value)
                        cameraManager.setProfessionalExposureBias(selectedBias)
                    }
                ), range: -2...2, format: "%+.1f")
            } else {
                HStack(spacing: 8) {
                    metric("ISO", value: String(format: "%.0f", cameraManager.professionalISO))
                    metric("SHUTTER", value: shutterLabel)
                    metric("EV", value: String(format: "%+.1f", cameraManager.professionalExposureBias))
                }
            }
        }
        .padding(14)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var lensSelector: some View {
        HStack(spacing: 8) {
            Button {
                automaticLens.toggle()
            } label: {
                Label(automaticLens ? "AUTO" : "MANUAL", systemImage: automaticLens ? "wand.and.stars" : "hand.tap")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(automaticLens ? Color.yellow : Color.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.56), in: Capsule())
            }

            if cameraManager.availableLenses.isEmpty {
                Text("LENS UNAVAILABLE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(minWidth: 92)
            } else {
                ForEach(cameraManager.availableLenses) { lens in
                    Button {
                        automaticLens = false
                        standardLensMode = false
                        cameraManager.setLens(lens)
                        selectedZoom = defaultZoom(for: lens)
                    } label: {
                        VStack(spacing: 2) {
                            Text(lens.title)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                            Text(lens.name)
                                .font(.system(size: 6, weight: .bold, design: .monospaced))
                        }
                        .foregroundStyle(cameraManager.activeLens == lens ? Color.yellow : Color.white)
                        .frame(minWidth: 53)
                        .padding(.vertical, 6)
                        .background(.black.opacity(cameraManager.activeLens == lens ? 0.76 : 0.42), in: RoundedRectangle(cornerRadius: 11))
                    }
                }
            }
        }
    }

    private var zoomControl: some View {
        HStack(spacing: 12) {
            Text(activeZoomLabel)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.yellow)
                .frame(width: 42)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: toggleStandardLens)
            Slider(value: $selectedZoom, in: zoomRange, step: 0.1) { editing in
                if !editing {
                    applyZoom(selectedZoom)
                }
            }
            .tint(.yellow)
            Text(maxZoomLabel)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.46), in: Capsule())
    }

    private var bottomBar: some View {
        HStack {
            Button {
                cameraManager.setProfessionalTorch(torchMode == .on ? .off : .on)
            } label: {
                Image(systemName: torchMode == .on ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .foregroundStyle(cameraManager.hasTorch ? Color.white : Color.white.opacity(0.35))
            .disabled(!cameraManager.hasTorch)

            Spacer()

            Button {
                captureOutput()
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                    Circle().fill(.white).frame(width: 63, height: 63)
                }
            }

            Spacer()

            Button {
                professionalControlsVisible.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .foregroundStyle(professionalControlsVisible ? Color.yellow : Color.white)
        }
    }

    private func exposureSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        reciprocal: Bool = false
    ) -> some View {
        HStack(spacing: 9) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 48, alignment: .leading)
            Slider(value: value, in: range)
                .tint(.yellow)
            Text(reciprocal ? String(format: format, 1 / max(value.wrappedValue, 0.001)) : String(format: format, value.wrappedValue))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 32)
        }
        .foregroundStyle(.white)
    }

    private func applyZoom(_ value: CGFloat) {
        let preferredLens = automaticLens ? preferredLens(for: value) : cameraManager.activeLens
        if automaticLens {
            cameraManager.setLens(preferredLens)
        }
        let range = zoomRange(for: preferredLens)
        let clampedValue = min(max(value, range.lowerBound), range.upperBound)
        standardLensMode = false
        selectedZoom = clampedValue
        cameraManager.setProfessionalZoom(max(1, clampedValue))
    }

    private func toggleStandardLens() {
        guard cameraManager.activeLens == .wide, cameraManager.availableLenses.contains(.wide) else { return }
        standardLensMode.toggle()
        if standardLensMode {
            cameraManager.setProfessionalZoom(35.0 / 24.0)
            selectedZoom = 35.0 / 24.0
        } else {
            cameraManager.setProfessionalZoom(1)
            selectedZoom = 1
        }
    }

    private func preferredLens(for value: CGFloat) -> CameraLens {
        let lenses = cameraManager.availableLenses
        if value < 0.8, lenses.contains(.ultraWide) { return .ultraWide }
        if value > 1.8, lenses.contains(.telephoto) { return .telephoto }
        if lenses.contains(.wide) { return .wide }
        return lenses.first ?? cameraManager.activeLens
    }

    private func defaultZoom(for lens: CameraLens) -> CGFloat {
        switch lens {
        case .ultraWide: 0.5
        case .wide, .telephoto: 1
        }
    }

    private var zoomRange: ClosedRange<CGFloat> {
        zoomRange(for: cameraManager.activeLens)
    }

    private func zoomRange(for lens: CameraLens) -> ClosedRange<CGFloat> {
        let upperBound: CGFloat
        if lens == .telephoto {
            upperBound = max(1, cameraManager.professionalMaxZoom)
        } else {
            upperBound = 1
        }
        return 0.5...max(1, upperBound)
    }

    private var maxZoomLabel: String {
        cameraManager.availableLenses.contains(.telephoto) ? "3×" : "1×"
    }

    private var activeZoomLabel: String {
        if standardLensMode, cameraManager.activeLens == .wide { return "1×" }
        if cameraManager.activeLens == .ultraWide { return "0.5×" }
        if cameraManager.activeLens == .wide && selectedZoom < 1 { return "1×" }
        if cameraManager.activeLens == .telephoto && selectedZoom < 1.8 { return "3×" }
        return String(format: "%.1f×", selectedZoom)
    }

    private var flashSymbol: String {
        switch flashMode {
        case .off: "bolt.slash.fill"
        case .on: "bolt.fill"
        case .auto: "bolt.badge.a.fill"
        }
    }

    private var nextFlashMode: CameraFlashMode {
        switch flashMode {
        case .off: .on
        case .on: .auto
        case .auto: .off
        }
    }

    private var shutterLabel: String {
        let seconds = max(cameraManager.professionalExposureDuration.seconds, 0.001)
        return "1/\(Int((1 / seconds).rounded()))"
    }
}
