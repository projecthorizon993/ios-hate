import AVFoundation
import Foundation
import MijickCameraView
import SwiftUI

struct IntegratedCameraView: MCameraView {
    @ObservedObject var cameraManager: CameraManager
    let namespace: Namespace.ID
    let closeControllerAction: () -> Void

    @State private var professionalControlsVisible = false
    @State private var manualExposure = false
    @State private var selectedISO: Float = 400
    @State private var selectedShutter: Double = 1.0 / 60.0
    @State private var selectedBias: Float = 0
    @State private var selectedZoom: CGFloat = 1

    var body: some View {
        ZStack {
            createCameraView()
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.6), .clear, .black.opacity(0.78)],
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
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .background(Color.black)
        .statusBarHidden()
        .onAppear {
            selectedISO = iso
            selectedShutter = max(exposureDuration.seconds, 0.001)
            selectedBias = exposureTargetBias
            selectedZoom = zoomFactor
        }
        .onChange(of: zoomFactor) { _, value in
            selectedZoom = value
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LUMA FRAME")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(cameraPosition == .back ? "PHOTO · AUTO" : "SELFIE · AUTO")
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

    private var bottomBar: some View {
        HStack {
            Button {
                try? changeTorchMode(torchMode == .on ? .off : .on)
            } label: {
                Image(systemName: torchMode == .on ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(.black.opacity(0.5), in: Circle())
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
        let seconds = max(exposureDuration.seconds, 0.001)
        return "1/\(Int((1 / seconds).rounded()))"
    }
}
