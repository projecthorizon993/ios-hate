import CoreImage
import Foundation
import Metal
import UIKit

/// Device and OS identity, plus a GPU render micro-benchmark.
///
/// The `hw.machine` identifier is the only reliable device key on iOS; the SoC is
/// not publicly queryable, so the chip column is a small display-only lookup table.
/// **No feature may branch on any value produced by this file** — that is what the
/// capability model and the Step 0 report are for.
enum DeviceProbe {

    static func sections() -> [ReportSection] {
        var device = ReportSection("Device")
        let machine = hardwareMachine()
        device.add(ReportEntry("model (UIDevice.model)", UIDevice.current.model))
        device.add(ReportEntry("hw.machine", machine))
        device.add(ReportEntry("marketing name", marketingName(for: machine), .note))
        device.add(ReportEntry("chip", chip(for: machine), .note))
        device.add(ReportEntry("system", UIDevice.current.systemName))
        device.add(ReportEntry("system version", UIDevice.current.systemVersion))
        // `UIDevice.isSimulator` is a popular category extension that Apple never
        // shipped. This is the supported way to ask, and it is a compile-time constant.
        device.add(ReportEntry("simulator", isSimulator ? "yes" : "no",
                               isSimulator ? .warn : .good))

        var system = ReportSection("System")
        system.add(ReportEntry("thermal state", thermalDescription(ProcessInfo.processInfo.thermalState)))
        system.add(ReportEntry("low power mode", ProcessInfo.processInfo.isLowPowerModeEnabled))
        system.add(ReportEntry("active processor count", ProcessInfo.processInfo.activeProcessorCount))
        system.add(ReportEntry("physical memory",
                               ReportFormat.number(Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824, decimals: 1) + " GB"))
        system.add(ReportEntry("uptime",
                               ReportFormat.number(ProcessInfo.processInfo.systemUptime / 60, decimals: 1) + " min"))
        // `ProcessInfo.activationState` does not exist. The app's own lifecycle is the
        // only source that can answer this, so it is read from the scene phase.
        system.add(ReportEntry("app state", appState(), .note))
        system.add(ReportEntry("reduce motion enabled", UIAccessibility.isReduceMotionEnabled))
        // The preferred content size category is a property of the current trait
        // collection, not a static on the type.
        system.add(ReportEntry("content size category",
                               UITraitCollection.current.preferredContentSizeCategory.rawValue))

        var graphics = ReportSection("Color and display")
        let gamut = UIScreen.main.traitCollection.displayGamut
        // The cases are `.sRGB` and `.displayP3`; there is no `.p3`.
        let isP3 = gamut == .displayP3
        graphics.add(ReportEntry("display gamut",
                                 gamut == .sRGB ? "sRGB" : isP3 ? "display P3" : "unspecified (\(gamut.rawValue))",
                                 isP3 ? .good : .warn))
        graphics.add(ReportEntry("Display P3 color space available",
                                 CGColorSpace(name: CGColorSpace.displayP3) != nil))
        graphics.add(ReportEntry("extended range color space available",
                                 CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) != nil, .note))
        graphics.add(ReportEntry("sRGB color space available",
                                 CGColorSpace(name: CGColorSpace.sRGB) != nil))
        graphics.add(ReportEntry("Metal device", MTLCreateSystemDefaultDevice()?.name ?? "none",
                                 MTLCreateSystemDefaultDevice() == nil ? .fail : .info))
        // `MTLDevice.family` does not exist. GPU family support is queried with
        // `supportsFamily`, and the newest family this SDK knows about is listed below.
        graphics.add(ReportEntry("Metal family 9 (A14/15 and newer)",
                                 MTLCreateSystemDefaultDevice()?.supportsFamily(.apple9) ?? false, .note))
        graphics.add(ReportEntry("maximum frames per second",
                                 ReportFormat.number(Double(UIScreen.main.maximumFramesPerSecond), decimals: 0)))

        return [device, system, graphics]
    }

    /// A compile-time constant, not a runtime property.
    static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()

    /// The app's lifecycle, read from the connected scene rather than from a
    /// non-existent `ProcessInfo` property.
    private static func appState() -> String {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first else { return "no scene" }
        switch scene.activationState {
        case .foregroundActive: return "active"
        case .foregroundInactive: return "inactive"
        case .background: return "background"
        case .unattached: return "unattached"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Render benchmark

    /// GPU throughput proxy using Core Image on a Metal context.
    ///
    /// This is deliberately *not* a Core ML measurement — see `CoreMLProbe`. It gives
    /// a real ms number on a device with no model assets, which is enough to separate
    /// the SE 2022 from the 11 Pro Max for tiering. 2560x1440 is roughly the largest
    /// still-preview size the pipeline will touch.
    static func renderBenchmark(iterations: Int = 20) -> ReportSection {
        var section = ReportSection("Render benchmark (Core Image / Metal)")

        guard let device = MTLCreateSystemDefaultDevice() else {
            section.add(ReportEntry("result", "no Metal device", .fail))
            return section
        }

        let width = 2560
        let height = 1440
        let context = CIContext(mtlDevice: device)
        let source = makeTestImage(width: width, height: height)

        // One untimed warm-up so shader compilation and the first texture allocation
        // do not land in the measurement.
        _ = context.createCGImage(source, from: CGRect(x: 0, y: 0, width: width, height: height))

        var samples: [Double] = []
        for _ in 0..<max(1, iterations) {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = context.createCGImage(source, from: CGRect(x: 0, y: 0, width: width, height: height))
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / 1_000_000.0)
        }

        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let fastest = sorted.first ?? 0
        let slowest = sorted.last ?? 0

        section.add(ReportEntry("workload", "\(width)x\(height) full-frame, \(iterations) iterations"))
        section.add(ReportEntry("median ms", ReportFormat.number(median)))
        section.add(ReportEntry("min ms", ReportFormat.number(fastest)))
        section.add(ReportEntry("max ms", ReportFormat.number(slowest)))
        section.add(ReportEntry("tier hint", renderTierHint(median: median), .note))
        return section
    }

    /// Display-only tier hint. `medium` is the conservative middle: the report is the
    /// input to the real decision, this is just a readable summary.
    static func renderTierHint(median: Double) -> String {
        switch median {
        case ..<8: return "fast GPU (high tier candidate)"
        case ..<25: return "mid GPU (mid tier candidate)"
        default: return "slow GPU (low tier candidate)"
        }
    }

    // MARK: - Private

    private static func makeTestImage(width: Int, height: Int) -> CIImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                // A smooth gradient plus high-frequency detail, so the GPU is doing
                // real work and not just blitting a uniform buffer.
                pixels[offset] = UInt8(x & 0xFF)
                pixels[offset + 1] = UInt8(y & 0xFF)
                pixels[offset + 2] = UInt8((x & 0xFF) &+ (y & 0xFF))
                pixels[offset + 3] = 0xFF
            }
        }
        // `CGBitmapInfo` is a struct, not the raw UInt32, so it has to be constructed.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 32,
                                    bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: bitmapInfo,
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent)
        else {
            return CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return CIImage(cgImage: cgImage)
    }

    static func thermalDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// `uname` rather than `sysctlbyname("hw.machine")`, because the sysctl name is
    /// not part of the public iOS API surface.
    static func hardwareMachine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    /// Display-only. Covers the three test devices and the common neighbours; an
    /// unknown identifier is reported as such rather than guessed at.
    static func marketingName(for machine: String) -> String {
        let table: [String: String] = [
            "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone13,2": "iPhone 12 Pro",
            "iPhone13,3": "iPhone 12 Pro Max",
            "iPhone14,8": "iPhone 13 mini",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,3": "iPhone 16 Pro",
            "iPhone17,4": "iPhone 16 Pro Max",
            "iPhone17,5": "iPhone 16e",
            "iPhone12,8": "iPhone SE (2nd generation)"
        ]
        return table[machine] ?? "not in lookup table"
    }

    static func chip(for machine: String) -> String {
        let table: [String: String] = [
            "iPhone12,5": "A13 Bionic",
            "iPhone14,6": "A15 Bionic",
            "iPhone14,2": "A15 Bionic",
            "iPhone14,3": "A15 Bionic",
            "iPhone15,2": "A16 Bionic",
            "iPhone15,3": "A16 Bionic",
            "iPhone16,1": "A17 Pro",
            "iPhone16,2": "A17 Pro",
            "iPhone17,3": "A18 Pro",
            "iPhone17,4": "A18 Pro",
            "iPhone17,5": "A18",
            "iPhone12,8": "A13 Bionic"
        ]
        return table[machine] ?? "not in lookup table"
    }
}
