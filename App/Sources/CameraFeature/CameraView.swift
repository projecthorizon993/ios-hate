import AVFoundation
import SwiftUI
import UIKit

private let lumaAccent = Color(red: 0.22, green: 0.95, blue: 0.68)

struct CameraView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var showingGallery = false
    @State private var showingPresets = false
    @State private var showingSettings = false
    @State private var showingGradeControls = false
    @State private var pinchStartZoom: CGFloat?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isAuthorized {
                cameraInterface
            } else {
                PermissionOnboardingView {
                    viewModel.start()
                } openSettings: {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
        .alert("Camera", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(isPresented: $showingGallery) {
            GalleryView(library: viewModel.library)
        }
        .sheet(isPresented: $showingPresets) {
            PresetBrowserView(store: viewModel.presetStore, selected: viewModel.selectedPreset) { preset in
                viewModel.applyPreset(preset)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingGradeControls) {
            GradeControlsView(viewModel: viewModel)
        }
    }

    private var cameraInterface: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreviewView(session: viewModel.coordinator.session, image: viewModel.processedFrame)
                    .ignoresSafeArea()
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let startZoom = pinchStartZoom ?? viewModel.zoomFactor
                                pinchStartZoom = startZoom
                                viewModel.setZoom(startZoom * value)
                            }
                            .onEnded { _ in
                                pinchStartZoom = nil
                            }
                    )

                LinearGradient(
                    colors: [.black.opacity(0.65), .clear, .black.opacity(0.8)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                ViewfinderOverlay(
                    mode: viewModel.mode,
                    aspectRatio: viewModel.aspectRatio,
                    isFocusLocked: viewModel.focusLocked,
                    bracketFrameCount: viewModel.bracketFrameCount,
                    isProcessing: viewModel.isProcessing
                )

                if viewModel.showPerformanceOverlay {
                    PerformanceOverlayView(monitor: viewModel.performanceMonitor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, 62)
                        .padding(.leading, 18)
                        .allowsHitTesting(false)
                }

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    Spacer()
                    bottomControls
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 12)

                if viewModel.mode == .manual && viewModel.showManualControls {
                    manualPanel
                        .frame(maxWidth: 360)
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 180)
                }

                if viewModel.isProcessing {
                    ProgressView()
                        .tint(.white)
                        .padding(14)
                        .background(.black.opacity(0.55), in: Circle())
                        .position(x: geometry.size.width - 34, y: 100)
                }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.slash.fill")
                .font(.title3.weight(.medium))
            Image(systemName: "timer")
                .font(.title3.weight(.medium))
            Menu {
                ForEach(CaptureAspectRatio.allCases) { ratio in
                    Button(ratio.title) {
                        viewModel.aspectRatio = ratio
                    }
                }
            } label: {
                Text(viewModel.aspectRatio == .original ? "3:4" : viewModel.aspectRatio.title)
                    .font(.headline.weight(.semibold))
            }
            Text(viewModel.rawEnabled ? "DNG" : "12M")
                .font(.headline.weight(.semibold))
            Text(String(format: "%+.1f", viewModel.exposureCompensation))
                .font(.headline.weight(.bold))
                .foregroundStyle(lumaAccent)
            Button {
                showingPresets = true
            } label: {
                Image(systemName: "camera.filters")
                    .font(.title3.weight(.medium))
            }
            .accessibilityLabel("Color presets")
            Image(systemName: "face.smiling")
                .font(.title3.weight(.medium))
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.bold))
            }
            .accessibilityLabel("Camera settings")
            Text("A")
                .font(.headline.weight(.bold))
                .foregroundStyle(.yellow)
                .frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.yellow, lineWidth: 1.5))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(.black)
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(CaptureMode.allCases) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.selectMode(mode)
                    }
                } label: {
                    Text(mode.shortTitle)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(viewModel.mode == mode ? .white : .white.opacity(0.45))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            if viewModel.mode == mode {
                                Capsule()
                                    .fill(lumaAccent)
                                    .frame(width: 22, height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 3)
        .background(.black.opacity(0.22), in: Capsule())
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isBracketCapturing ? lumaAccent : .white.opacity(0.72))
                        .frame(width: 6, height: 6)
                    Text(viewModel.mode == .bracket ? "NIGHT BRACKET \(viewModel.bracketFrameCount)/3" : viewModel.activeLensName.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(1)
                }
                Spacer()
                Text(viewModel.capabilities.supportsRAW ? "RAW" : "JPG")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.58))
            }

            HStack(spacing: 6) {
                ForEach(CaptureAspectRatio.allCases) { ratio in
                    Button {
                        viewModel.aspectRatio = ratio
                    } label: {
                        Text(ratio.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(viewModel.aspectRatio == ratio ? .black : .white)
                            .frame(width: 44, height: 34)
                            .background(viewModel.aspectRatio == ratio ? lumaAccent : Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 5) {
                ForEach([CGFloat(0.5), 1, 2], id: \.self) { factor in
                    Button {
                        viewModel.setZoom(factor)
                    } label: {
                        Text(factor == 0.5 ? "0.5" : factor == 1 ? "1×" : "2×")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(viewModel.zoomFactor == factor ? .black : .white)
                            .frame(width: 44, height: 34)
                            .background(viewModel.zoomFactor == factor ? lumaAccent : Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                Button {
                    showingGallery = true
                } label: {
                    Group {
                        if let item = viewModel.library.items.first,
                           let image = viewModel.library.image(for: item, enhanced: true) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo.on.rectangle")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 52, height: 52)
                    .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .accessibilityLabel("Open gallery")
                Spacer()
                Button {
                    viewModel.capture()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(lumaAccent, lineWidth: 3)
                            .frame(width: 96, height: 96)
                        Circle()
                            .fill(.white)
                            .frame(width: viewModel.isCapturing ? 58 : 76, height: viewModel.isCapturing ? 58 : 76)
                        if viewModel.mode == .bracket {
                            Image(systemName: "moon.stars.fill")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.black)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.isConfigured)
                .accessibilityLabel(viewModel.mode == .bracket ? "Capture night bracket" : "Take photo")
                Spacer()
                Button {
                    showingGradeControls = true
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.headline.weight(.semibold))
                        .frame(width: 52, height: 52)
                        .background(.black.opacity(0.34), in: Circle())
                }
                .accessibilityLabel("Open live grade")
            }
        }
        .padding(.top, 4)
    }

    private var manualPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Text("MANUAL")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                Spacer()
                Button("Done") { viewModel.showManualControls = false }
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            ControlSlider(title: "ISO", value: Binding(
                get: { Double(viewModel.iso) },
                set: { viewModel.iso = Float($0); viewModel.applySettings() }
            ), range: Double(viewModel.capabilities.minimumISO)...Double(viewModel.capabilities.maximumISO), format: "%.0f")
            ControlSlider(title: "SHUTTER", value: Binding(
                get: { 1 / viewModel.shutterDuration },
                set: { viewModel.shutterDuration = 1 / $0; viewModel.applySettings() }
            ), range: 30...4000, format: "1/%.0f s")
            ControlSlider(title: "EV", value: Binding(
                get: { Double(viewModel.exposureCompensation) },
                set: { viewModel.exposureCompensation = Float($0); viewModel.applySettings() }
            ), range: -3...3, format: "%+.1f")
            ControlSlider(title: "KELVIN", value: Binding(
                get: { Double(viewModel.kelvin) },
                set: { viewModel.kelvin = Float($0); viewModel.applySettings() }
            ), range: 2500...7500, format: "%.0f K")
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ViewfinderOverlay: View {
    let mode: CaptureMode
    let aspectRatio: CaptureAspectRatio
    let isFocusLocked: Bool
    let bracketFrameCount: Int
    let isProcessing: Bool

    var body: some View {
        ZStack {
            if aspectRatio != .original {
                aspectGuides
            }
            if mode == .bracket {
                bracketGuide
            }
            focusReticle
            if isProcessing {
                processingBadge
            }
        }
        .allowsHitTesting(false)
    }

    private var aspectGuides: some View {
        GeometryReader { geometry in
            let ratio = aspectRatio.value ?? 2.39
            let guideWidth = min(geometry.size.width * 0.9, geometry.size.height * 0.9 * ratio)
            let guideHeight = guideWidth / ratio
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: max((geometry.size.height - guideHeight) / 2, 0))
                Rectangle()
                    .fill(.white.opacity(0.42))
                    .frame(height: 1)
                Color.clear
                    .frame(height: max(guideHeight - 1, 0))
                Rectangle()
                    .fill(.white.opacity(0.42))
                    .frame(height: 1)
                Color.clear
                    .frame(height: max((geometry.size.height - guideHeight) / 2, 0))
            }
            .frame(width: guideWidth)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    private var bracketGuide: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                Text("BRACKET \(bracketFrameCount)/3")
            }
            .font(.caption2.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(lumaAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(.bottom, 250)
        }
    }

    private var focusReticle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isFocusLocked ? lumaAccent : lumaAccent.opacity(0.75), lineWidth: isFocusLocked ? 2 : 1)
                .frame(width: 70, height: 70)
            Circle()
                .fill(isFocusLocked ? lumaAccent : lumaAccent.opacity(0.8))
                .frame(width: 4, height: 4)
            Rectangle()
                .fill(lumaAccent.opacity(0.8))
                .frame(width: 18, height: 1)
            Rectangle()
                .fill(lumaAccent.opacity(0.8))
                .frame(width: 1, height: 18)
        }
        .shadow(color: .black.opacity(0.45), radius: 3)
    }

    private var processingBadge: some View {
        VStack {
            HStack {
                Spacer()
                Label("ENHANCING", systemImage: "wand.and.stars")
                    .font(.caption2.weight(.bold))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.48), in: Capsule())
            }
            .padding(.horizontal, 18)
            .padding(.top, 58)
            Spacer()
        }
    }
}

private struct PerformanceOverlayView: View {
    @ObservedObject var monitor: PerformanceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(monitor.thermalState == .serious || monitor.thermalState == .critical ? Color.red : lumaAccent)
                    .frame(width: 5, height: 5)
                Text(String(format: "FPS %.1f", monitor.framesPerSecond))
            }
            Text(String(format: "%.1f ms/frame", monitor.frameTimeMilliseconds))
            Text(String(format: "PROC %.1f ms", monitor.averageProcessingMilliseconds))
            Text(String(format: "WAIT %.1f ms", monitor.averageQueueWaitMilliseconds))
            Text("DROPS \(monitor.droppedFrameCount)")
            Text("MEM \(monitor.memoryUsageMB) MB")
            Text("ADAPT \(Int(monitor.recommendedPreviewDimension))px")
            Text("THERMAL \(monitor.thermalLabel.uppercased())")
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ControlSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            Slider(value: $value, in: range)
                .tint(.white)
        }
    }
}

struct PermissionOnboardingView: View {
    let requestPermission: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Image(systemName: "camera.aperture")
                .font(.system(size: 76, weight: .thin))
                .foregroundStyle(.white)
            VStack(spacing: 10) {
                Text("LumaFrame")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                Text("Cinematic low-light capture, built for the moment after dark.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 30)
            }
            Spacer()
            VStack(spacing: 12) {
                Text("Camera access is used only while you are shooting. Originals stay on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Button(action: requestPermission) {
                    Text("Enable Camera")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white, in: Capsule())
                }
                .padding(.horizontal, 30)
                Button("Open Settings", action: openSettings)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 28)
        }
        .foregroundStyle(.white)
    }
}

struct PresetBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PresetStore
    let selected: ColorGradePreset
    let onSelect: (ColorGradePreset) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(store.presets) { preset in
                        Button {
                            onSelect(preset)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(preset.grade == selected.grade ? Color.white : Color(white: 0.14))
                                    .overlay {
                                        Image(systemName: preset.grade.saturation == 0 ? "circle.lefthalf.filled" : "camera.filters")
                                            .foregroundStyle(preset.grade == selected.grade ? .black : .white)
                                    }
                                    .frame(height: 100)
                                Text(preset.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if preset.isBuiltIn {
                                    Text("Built-in")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Looks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct GalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: MediaLibrary

    var body: some View {
        NavigationStack {
            Group {
                if library.items.isEmpty {
                    ContentUnavailableView("No captures", systemImage: "camera", description: Text("Your original and enhanced captures will appear here."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(library.items) { item in
                                if let image = library.image(for: item, enhanced: true) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(height: 210)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(alignment: .bottomLeading) {
                                            Text(item.metadata["mode"]?.capitalized ?? "Photo")
                                                .font(.caption2.weight(.bold))
                                                .padding(8)
                                                .foregroundStyle(.white)
                                                .background(.black.opacity(0.55), in: Capsule())
                                                .padding(8)
                                        }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Gallery")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var performanceMonitor: PerformanceMonitor

    init(viewModel: CameraViewModel) {
        self.viewModel = viewModel
        _performanceMonitor = ObservedObject(wrappedValue: viewModel.performanceMonitor)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Capture") {
                    LabeledContent("Lens", value: viewModel.activeLensName)
                    LabeledContent("Optical range", value: String(format: "%.1f×–%.1f×", viewModel.minimumZoomFactor, viewModel.capabilities.maximumZoomFactor))
                    LabeledContent("RAW", value: viewModel.capabilities.supportsRAW ? "Available" : "Unavailable")
                    LabeledContent("Aspect ratio", value: viewModel.aspectRatio.title)
                    Toggle("Capture DNG/RAW", isOn: $viewModel.rawEnabled)
                        .disabled(!viewModel.capabilities.supportsRAW)
                }
                Section("Processing") {
                    LabeledContent("Preview", value: viewModel.processedFrame == nil ? "Waiting" : "Active")
                    LabeledContent("Enhancement", value: "Core Image")
                    LabeledContent("Storage", value: "On device")
                }
                Section("Developer") {
                    Toggle("Show FPS overlay", isOn: $viewModel.showPerformanceOverlay)
                    LabeledContent("FPS", value: String(format: "%.1f", performanceMonitor.framesPerSecond))
                    LabeledContent("Frame time", value: String(format: "%.1f ms", performanceMonitor.frameTimeMilliseconds))
                    LabeledContent("Thermal state", value: performanceMonitor.thermalLabel)
                    LabeledContent("Processed frames", value: String(performanceMonitor.processedFrameCount))
                    LabeledContent("Frame processing", value: String(format: "%.1f ms avg", performanceMonitor.averageProcessingMilliseconds))
                    LabeledContent("Queue wait", value: String(format: "%.1f ms avg", performanceMonitor.averageQueueWaitMilliseconds))
                    LabeledContent("Dropped frames", value: String(performanceMonitor.droppedFrameCount))
                    LabeledContent("Memory", value: "\(performanceMonitor.memoryUsageMB) MB")
                    LabeledContent("Adaptive preview", value: "\(Int(performanceMonitor.recommendedPreviewDimension)) px")
                    Text("CPU/GPU utilization: use Instruments with Time Profiler, Core Animation, or Metal System Trace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Diagnostics") {
                    if viewModel.diagnostics.events.isEmpty {
                        Label("No recent camera events", systemImage: "checkmark.shield")
                    } else {
                        ForEach(Array(viewModel.diagnostics.events.prefix(5))) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.message)
                                    .font(.caption.weight(.semibold))
                                Text(event.date, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Clear log", role: .destructive) {
                            viewModel.diagnostics.clear()
                        }
                    }
                    if let logURL = viewModel.diagnostics.exportURL() {
                        ShareLink(item: logURL) {
                            Label("Share diagnostics log", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                Section("Privacy") {
                    Label("Originals remain on this device", systemImage: "lock.shield")
                    Label("No server required", systemImage: "wifi.slash")
                }
            }
            .navigationTitle("Camera settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
