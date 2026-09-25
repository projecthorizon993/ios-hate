import AVFoundation
import CoreImage
import Foundation
import SwiftUI

struct IntegratedCameraView: View {
    @ObservedObject var cameraManager: NativeCameraManager

    @State private var professionalControlsVisible = false
    @State private var manualExposure = false
    @State private var selectedISO: Float = 400
    @State private var selectedShutter: Double = 1.0 / 60.0
    @State private var selectedBias: Float = 0
    @State private var selectedZoom: CGFloat = 1
    @State private var standardLensMode = false
    @State private var showZoomWheel = false
    @State private var zoomWheelGeneration = 0
    @State private var professionalMode = false
    @State private var selectedPreset: ColorPreset = .natural
    @State private var quality: QualityPreset = .fullHD
    @State private var selectedFrameRate: Int32 = 30
    @State private var selectedHDRMode: NativeCameraHDRMode = .auto
    @State private var dragStartZoom: CGFloat?
    @State private var pendingZoomAfterLensChange: CGFloat?
    @State private var isSwitchingLens = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .frame(height: 76)
                    .background(Color.black)

                ZStack {
                    NativeCameraPreview(session: cameraManager.session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if cameraManager.showGrid {
                        cameraGridOverlay
                    }

                    if showZoomWheel {
                        zoomWheel
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomBar
                    .background(Color.black)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .onAppear {
            selectedISO = iso
            selectedShutter = max(exposureDuration.seconds, 0.001)
            selectedBias = exposureTargetBias
            selectedZoom = zoomFactor
        }
        .onChange(of: zoomFactor) { _, value in
            selectedZoom = value
            standardLensMode = abs(value - (35.0 / 24.0)) < 0.02
            presentZoomWheel()
        }
        .onChange(of: cameraManager.activeLens) { _, lens in
            isSwitchingLens = false
            standardLensMode = false
            if let pendingZoom = pendingZoomAfterLensChange {
                pendingZoomAfterLensChange = nil
                selectedZoom = pendingZoom
                cameraManager.setProfessionalZoom(max(1, pendingZoom))
            } else {
                selectedZoom = defaultZoom(for: lens)
            }
        }
    }

    private var cameraGridOverlay: some View {
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
            .stroke(.white.opacity(0.5), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LUMA FRAME")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("\(outputType == .photo ? "PHOTO" : "VIDEO") · AUTO")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .foregroundStyle(.white)

            Spacer()

            Text(String(format: "%.1f×", zoomFactor))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.yellow)

            iconButton(showGrid ? "grid" : "grid") {
                try? changeGridVisibility(!showGrid)
            }
            iconButton(flashSymbol) {
                try? changeFlashMode(nextFlashMode)
            }
            iconButton("arrow.triangle.2.circlepath.camera") {
                try? changeCamera(cameraPosition == .back ? .front : .back)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Professional Mode", isOn: $professionalMode)
                        .tint(.yellow)
                        .onChange(of: professionalMode) { _, enabled in
                            applyProfessionalMode(enabled)
                        }
                    Text("Uses a higher-resolution capture profile and a cinematic color profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Camera Profile")
                }

                Section("Color Preset") {
                    ForEach(ColorPreset.allCases) { preset in
                        Button {
                            applyPreset(preset)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: preset.icon)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.title)
                                        .foregroundStyle(.primary)
                                    Text(preset.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedPreset == preset {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.yellow)
                                }
                            }
                        }
                    }
                }

                Section("Image Quality") {
                    Picker("Resolution", selection: $quality) {
                        ForEach(QualityPreset.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: quality) { _, _ in applyQuality() }

                    Picker("Frame Rate", selection: $selectedFrameRate) {
                        Text("24 FPS").tag(Int32(24))
                        Text("30 FPS").tag(Int32(30))
                        Text("60 FPS").tag(Int32(60))
                    }
                    .onChange(of: selectedFrameRate) { _, _ in applyQuality() }

                    Picker("HDR", selection: $selectedHDRMode) {
                        Text("Auto").tag(NativeCameraHDRMode.auto)
                        Text("On").tag(NativeCameraHDRMode.on)
                        Text("Off").tag(NativeCameraHDRMode.off)
                    }
                    .onChange(of: selectedHDRMode) { _, _ in applyQuality() }
                }

                Section("Exposure") {
                    Toggle("Manual Exposure", isOn: $manualExposure)
                        .tint(.yellow)
                        .onChange(of: manualExposure) { _, enabled in
                            try? changeExposureMode(enabled ? .custom : .continuousAutoExposure)
                        }
                    if manualExposure {
                        LabeledContent("ISO", value: String(format: "%.0f", selectedISO))
                        Slider(value: Binding(
                            get: { Double(selectedISO) },
                            set: { value in
                                selectedISO = Float(value)
                                try? changeISO(selectedISO)
                            }
                        ), in: 50...6400)
                        LabeledContent("Shutter", value: "1/\(Int((1 / selectedShutter).rounded()))")
                        Slider(value: Binding(
                            get: { selectedShutter },
                            set: { value in
                                selectedShutter = value
                                try? changeExposureDuration(CMTime(seconds: value, preferredTimescale: 1_000_000_000))
                            }
                        ), in: 0.001...0.067)
                        LabeledContent("EV", value: String(format: "%+.1f", selectedBias))
                        Slider(value: Binding(
                            get: { Double(selectedBias) },
                            set: { value in
                                selectedBias = Float(value)
                                try? changeExposureTargetBias(selectedBias)
                            }
                        ), in: -2...2)
                    } else {
                        LabeledContent("ISO", value: String(format: "%.0f", iso))
                        LabeledContent("Shutter", value: shutterLabel)
                        LabeledContent("EV", value: String(format: "%+.1f", exposureTargetBias))
                    }
                }

                Section("Camera Tools") {
                    Toggle("Grid", isOn: Binding(
                        get: { showGrid },
                        set: { try? changeGridVisibility($0) }
                    ))
                    .tint(.yellow)
                    Toggle("Mirror Output", isOn: Binding(
                        get: { mirrorOutput },
                        set: { changeMirrorOutputMode($0) }
                    ))
                    .tint(.yellow)
                }

                Section {
                    Button("Reset Settings", role: .destructive) {
                        resetSettings()
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        professionalControlsVisible = false
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func applyProfessionalMode(_ enabled: Bool) {
        quality = enabled ? .ultraHD : .fullHD
        selectedFrameRate = 30
        selectedHDRMode = .auto
        applyQuality()
        applyPreset(enabled ? .cinematic : .natural)
    }

    private func applyPreset(_ preset: ColorPreset) {
        selectedPreset = preset
        try? changeCameraFilters(preset.filters)
    }

    private func applyQuality() {
        try? changeResolution(quality.sessionPreset)
        try? changeFrameRate(selectedFrameRate)
        try? changeHDRMode(selectedHDRMode)
    }

    private func resetSettings() {
        professionalMode = false
        selectedFrameRate = 30
        selectedHDRMode = .auto
        quality = .fullHD
        manualExposure = false
        selectedISO = 400
        selectedShutter = 1.0 / 60.0
        selectedBias = 0
        applyQuality()
        applyPreset(.natural)
        changeMirrorOutputMode(false)
        try? changeGridVisibility(true)
    }

    private var professionalPanel: some View {
        VStack(spacing: 11) {
            HStack {
                Text(manualExposure ? "MANUAL EXPOSURE" : "AUTO EXPOSURE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Button(manualExposure ? "AUTO" : "MANUAL") {
                    manualExposure.toggle()
                    try? changeExposureMode(manualExposure ? .custom : .continuousAutoExposure)
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(manualExposure ? Color.yellow : Color.white)
            }

            if manualExposure {
                exposureSlider(title: "ISO", value: Binding(
                    get: { Double(selectedISO) },
                    set: { value in
                        selectedISO = Float(value)
                        try? changeISO(selectedISO)
                    }
                ), range: 50...6400, format: "%.0f")
                exposureSlider(title: "SHUTTER", value: Binding(
                    get: { selectedShutter },
                    set: { value in
                        selectedShutter = value
                        try? changeExposureDuration(CMTime(seconds: value, preferredTimescale: 1_000_000_000))
                    }
                ), range: 0.001...0.067, format: "1/%.0f s", reciprocal: true)
                exposureSlider(title: "EV", value: Binding(
                    get: { Double(selectedBias) },
                    set: { value in
                        selectedBias = Float(value)
                        try? changeExposureTargetBias(selectedBias)
                    }
                ), range: -2...2, format: "%+.1f")
            } else {
                HStack(spacing: 8) {
                    metric("ISO", value: String(format: "%.0f", iso))
                    metric("SHUTTER", value: shutterLabel)
                    metric("EV", value: String(format: "%+.1f", exposureTargetBias))
                }
            }
        }
        .padding(14)
        .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var zoomDial: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.2), lineWidth: 2)
                .frame(width: 132, height: 132)
            Circle()
                .fill(.black.opacity(0.52))
                .frame(width: 112, height: 112)

            VStack(spacing: 2) {
                Text(zoomLabel)
                    .font(.system(size: 19, weight: .bold, design: .monospaced))
                    .foregroundStyle(.yellow)
                Text(focalLengthLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
            }

            ForEach(cameraManager.availableLenses) { lens in
                Button {
                    selectZoomPreset(lens, value: defaultZoom(for: lens))
                } label: {
                    Text(lens.title)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(cameraManager.activeLens == lens ? Color.yellow : Color.white.opacity(0.78))
                        .frame(width: 38, height: 28)
                        .background(.black.opacity(0.75), in: Capsule())
                }
                .offset(dialOffset(for: lens))
            }
        }
        .frame(width: 140, height: 140)
        .contentShape(Circle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if dragStartZoom == nil {
                        dragStartZoom = selectedZoom
                    }
                    let start = dragStartZoom ?? selectedZoom
                    applyZoomValue(start - value.translation.height / 100 + value.translation.width / 240)
                }
                .onEnded { _ in
                    dragStartZoom = nil
                }
        )
    }

    private var zoomWheel: some View {
        VStack {
            Spacer()
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 9)
                    .frame(width: 128, height: 128)
                Circle()
                    .trim(from: 0, to: min(max((zoomFactor - 1) / 2, 0.04), 1))
                    .stroke(.yellow, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 128, height: 128)
                VStack(spacing: 2) {
                    Text(zoomLabel)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                    Text(focalLengthLabel)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .foregroundStyle(.white)
            }
            .padding(.bottom, 150)
        }
        .transition(.opacity)
    }

    private func presentZoomWheel() {
        showZoomWheel = true
        zoomWheelGeneration += 1
        let generation = zoomWheelGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if generation == zoomWheelGeneration {
                showZoomWheel = false
            }
        }
    }

    private func applyZoomValue(_ value: CGFloat) {
        let clampedValue = min(max(value, 0.5), 3)
        let lens = preferredLens(for: clampedValue)
        let displayValue: CGFloat = lens == .telephoto ? 3 : clampedValue
        standardLensMode = false
        selectedZoom = displayValue
        presentZoomWheel()
        if cameraManager.activeLens == lens {
            cameraManager.setProfessionalZoom(lens == .telephoto ? 1 : max(1, clampedValue))
        } else if !isSwitchingLens {
            isSwitchingLens = true
            pendingZoomAfterLensChange = displayValue
            cameraManager.setLens(lens)
        }
    }

    private func preferredLens(for value: CGFloat) -> NativeCameraLens {
        let lenses = cameraManager.availableLenses
        if value < 0.8, lenses.contains(.ultraWide) { return .ultraWide }
        if value > 1.6, lenses.contains(.telephoto) { return .telephoto }
        if lenses.contains(.wide) { return .wide }
        return lenses.first ?? cameraManager.activeLens
    }

    private func dialOffset(for lens: NativeCameraLens) -> CGSize {
        switch lens {
        case .ultraWide: CGSize(width: -43, height: 29)
        case .wide: CGSize(width: 0, height: -49)
        case .telephoto: CGSize(width: 43, height: 29)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            zoomDial

            HStack(spacing: 8) {
                modeButton("PHOTO", systemImage: "camera", isActive: outputType == .photo) {
                    try? changeOutputType(.photo)
                }
                modeButton("VIDEO", systemImage: "video", isActive: outputType == .video) {
                    try? changeOutputType(.video)
                }
            }

            HStack {
                Button {
                    try? changeTorchMode(torchMode == .on ? .off : .on)
                } label: {
                    Image(systemName: torchMode == .on ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .foregroundStyle(hasTorch ? Color.white : Color.white.opacity(0.35))
                .disabled(!hasTorch)

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
                        .background(.white.opacity(0.12), in: Circle())
                }
                .foregroundStyle(professionalControlsVisible ? Color.yellow : Color.white)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func zoomPresetButton(_ lens: NativeCameraLens, value: CGFloat) -> some View {
        let available = cameraManager.availableLenses.contains(lens)
        let active = cameraManager.activeLens == lens && (lens != .wide || abs(selectedZoom - 1) < 0.05)
        return Button {
            selectZoomPreset(lens, value: value)
        } label: {
            Text(lens.title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(active ? Color.yellow : available ? Color.white.opacity(0.82) : Color.white.opacity(0.28))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.white.opacity(active ? 0.16 : 0.06), in: Capsule())
        }
        .disabled(!available)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if lens == .wide {
                toggleStandardLens()
            }
        })
    }

    private func selectZoomPreset(_ lens: NativeCameraLens, value: CGFloat) {
        guard cameraManager.availableLenses.contains(lens) else { return }
        applyZoomValue(value)
    }

    private func defaultZoom(for lens: NativeCameraLens) -> CGFloat {
        switch lens {
        case .ultraWide: 0.5
        case .wide: 1
        case .telephoto: 3
        }
    }

    private func modeButton(_ title: String, systemImage: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(isActive ? Color.yellow : Color.white.opacity(0.72))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(.white.opacity(isActive ? 0.16 : 0.07), in: Capsule())
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

    private func toggleStandardLens() {
        guard cameraManager.activeLens == .wide else { return }
        standardLensMode.toggle()
        let target: CGFloat = standardLensMode ? 35.0 / 24.0 : 1
        selectedZoom = target
        try? changeZoomFactor(target)
    }

    private var zoomLabel: String {
        if standardLensMode { return "1×" }
        if cameraManager.activeLens == .ultraWide { return "0.5×" }
        if cameraManager.activeLens == .telephoto { return "3×" }
        return String(format: "%.1f×", selectedZoom)
    }

    private var focalLengthLabel: String {
        if standardLensMode { return "35mm" }
        return "\(cameraManager.professionalEquivalentFocalLength)mm"
    }

    private var flashSymbol: String {
        switch flashMode {
        case .off: "bolt.slash.fill"
        case .on: "bolt.fill"
        case .auto: "bolt.badge.a.fill"
        }
    }

    private var nextFlashMode: NativeCameraFlashMode {
        switch flashMode {
        case .off: .on
        case .on: .auto
        case .auto: .off
        }
    }

    private var shutterLabel: String {
        let seconds = max(exposureDuration.seconds, 0.001)
        return "1/\(Int((1 / seconds).rounded()))"
    }

    private enum QualityPreset: String, CaseIterable, Identifiable {
        case fullHD
        case ultraHD

        var id: String { rawValue }
        var title: String { self == .fullHD ? "HD" : "4K" }
        var sessionPreset: AVCaptureSession.Preset {
            self == .fullHD ? .hd1920x1080 : .hd4K3840x2160
        }
    }

    private enum ColorPreset: String, CaseIterable, Identifiable {
        case natural
        case cinematic
        case mono
        case warm
        case cool

        var id: String { rawValue }
        var title: String {
            switch self {
            case .natural: "Natural"
            case .cinematic: "Cinematic"
            case .mono: "Mono"
            case .warm: "Warm"
            case .cool: "Cool"
            }
        }
        var subtitle: String {
            switch self {
            case .natural: "Balanced color"
            case .cinematic: "Contrast and muted color"
            case .mono: "Black and white"
            case .warm: "Golden highlights"
            case .cool: "Clean blue tone"
            }
        }
        var icon: String {
            switch self {
            case .natural: "circle.lefthalf.filled"
            case .cinematic: "film"
            case .mono: "circle.righthalf.filled"
            case .warm: "sun.max"
            case .cool: "snowflake"
            }
        }
        var filters: [CIFilter] {
            switch self {
            case .natural:
                return []
            case .cinematic:
                let controls = CIFilter(name: "CIColorControls")
                controls?.setValue(1.12, forKey: kCIInputContrastKey)
                controls?.setValue(0.88, forKey: kCIInputSaturationKey)
                return controls.map { [$0] } ?? []
            case .mono:
                return CIFilter(name: "CIPhotoEffectMono").map { [$0] } ?? []
            case .warm:
                let temperature = CIFilter(name: "CITemperatureAndTint")
                temperature?.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
                temperature?.setValue(CIVector(x: 5000, y: 0), forKey: "inputTargetNeutral")
                return temperature.map { [$0] } ?? []
            case .cool:
                let temperature = CIFilter(name: "CITemperatureAndTint")
                temperature?.setValue(CIVector(x: 4500, y: 0), forKey: "inputNeutral")
                temperature?.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
                return temperature.map { [$0] } ?? []
            }
        }
    }
}
