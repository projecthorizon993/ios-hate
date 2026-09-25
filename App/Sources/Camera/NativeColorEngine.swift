import CoreImage
import Foundation
import MetalKit

enum NativeColorPreset: String, CaseIterable, Identifiable {
    case natural
    case cinematic
    case vivid
    case warm
    case cool
    case mono

    var id: String { rawValue }
}

struct NativeColorSettings: Equatable {
    var preset: NativeColorPreset = .natural
    var intensity: CGFloat = 1
    var exposure: CGFloat = 0
    var contrast: CGFloat = 1
    var saturation: CGFloat = 1
    var temperature: CGFloat = 0
    var tint: CGFloat = 0
    var vignette: CGFloat = 0
    var grain: CGFloat = 0

    static let natural = NativeColorSettings()
}

enum NativeColorEngine {
    static func apply(_ image: CIImage, settings: NativeColorSettings) -> CIImage {
        let intensity = min(max(settings.intensity, 0), 1)
        var output = image

        if settings.preset == .mono {
            if let filter = CIFilter(name: "CIPhotoEffectMono") {
                filter.setValue(output, forKey: kCIInputImageKey)
                output = filter.outputImage ?? output
            }
        }

        let controls = CIFilter(name: "CIColorControls")
        let presetContrast: CGFloat
        let presetSaturation: CGFloat
        switch settings.preset {
        case .cinematic:
            presetContrast = 1.10
            presetSaturation = 0.90
        case .vivid:
            presetContrast = 1.08
            presetSaturation = 1.25
        default:
            presetContrast = 1
            presetSaturation = 1
        }
        controls?.setValue(output, forKey: kCIInputImageKey)
        controls?.setValue(1 + (settings.exposure * 0.35), forKey: kCIInputEVKey)
        controls?.setValue(1 + ((settings.contrast - 1) * intensity) + ((presetContrast - 1) * intensity), forKey: kCIInputContrastKey)
        controls?.setValue(1 + ((settings.saturation - 1) * intensity) + ((presetSaturation - 1) * intensity), forKey: kCIInputSaturationKey)
        output = controls?.outputImage ?? output

        let temperature = CGFloat(settings.temperature)
        let tint = CGFloat(settings.tint)
        let presetTemperature: CGFloat
        switch settings.preset {
        case .warm: presetTemperature = -900
        case .cool: presetTemperature = 900
        default: presetTemperature = 0
        }
        if abs(temperature) > 0.001 || abs(tint) > 0.001 || presetTemperature != 0 {
            let filter = CIFilter(name: "CITemperatureAndTint")
            let sourceTemperature = 6500 + Double((temperature + presetTemperature) * 1800 * intensity)
            let targetTemperature = 6500 - Double((temperature + presetTemperature) * 900 * intensity)
            let source = CIVector(x: sourceTemperature, y: Double(tint * 120 * intensity))
            let target = CIVector(x: targetTemperature, y: Double(-tint * 120 * intensity))
            filter?.setValue(output, forKey: kCIInputImageKey)
            filter?.setValue(source, forKey: "inputNeutral")
            filter?.setValue(target, forKey: "inputTargetNeutral")
            output = filter?.outputImage ?? output
        }

        if abs(settings.vignette) > 0.001 {
            let filter = CIFilter(name: "CIVignette")
            filter?.setValue(output, forKey: kCIInputImageKey)
            filter?.setValue(2.0, forKey: kCIInputRadiusKey)
            filter?.setValue(Double(settings.vignette * intensity), forKey: kCIInputIntensityKey)
            output = filter?.outputImage ?? output
        }

        if abs(settings.grain) > 0.001 {
            let filter = CIFilter(name: "CINoiseReduction")
            filter?.setValue(output, forKey: kCIInputImageKey)
            filter?.setValue(Double(settings.grain * intensity * 0.04), forKey: "inputNoiseLevel")
            filter?.setValue(0.4, forKey: "inputSharpness")
            output = filter?.outputImage ?? output
        }

        return output
    }
}

final class NativeColorRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    private let lock = NSLock()
    private var latestImage: CIImage?
    private var latestSettings = NativeColorSettings.natural
    private var frameVersion: UInt64 = 0
    private var submittedVersion: UInt64 = 0
    private var isRendering = false
    private var isActive = true

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("Metal is unavailable")
        }
        self.device = device
        self.commandQueue = commandQueue
        self.context = CIContext(mtlDevice: device, options: [.cacheIntermediates: true])
        super.init()
    }

    func configure(_ view: MTKView) {
        view.device = device
        view.delegate = self
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.02, 0.02, 0.02, 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.autoResizeDrawable = true
        view.contentMode = .scaleAspectFill
    }

    func setActive(_ active: Bool) {
        lock.lock()
        isActive = active
        lock.unlock()
    }

    func submit(_ image: CIImage, settings: NativeColorSettings) {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        latestImage = image
        latestSettings = settings
        frameVersion &+= 1
        lock.unlock()
    }

    func clear() {
        lock.lock()
        latestImage = nil
        frameVersion &+= 1
        lock.unlock()
    }

    func draw(in view: MTKView) {
        guard view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }

        lock.lock()
        guard isActive,
              !isRendering,
              frameVersion != submittedVersion,
              let image = latestImage else {
            lock.unlock()
            return
        }
        let settings = latestSettings
        submittedVersion = frameVersion
        isRendering = true
        lock.unlock()

        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            lock.lock()
            isRendering = false
            lock.unlock()
            return
        }

        let target = CGRect(origin: .zero, size: view.drawableSize)
        let output = NativeColorEngine.apply(aspectFill(image, into: target), settings: settings)
        context.render(
            output,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: target,
            colorSpace: colorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.isRendering = false
            self.lock.unlock()
        }
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func aspectFill(_ image: CIImage, into target: CGRect) -> CIImage {
        let source = image.extent
        let targetRatio = target.width / target.height
        let sourceRatio = source.width / source.height
        var crop = source
        if sourceRatio > targetRatio {
            crop.size.width = source.height * targetRatio
            crop.origin.x = source.midX - crop.width / 2
        } else {
            crop.size.height = source.width / targetRatio
            crop.origin.y = source.midY - crop.height / 2
        }

        let cropped = image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        return cropped.transformed(by: CGAffineTransform(
            scaleX: target.width / crop.width,
            y: target.height / crop.height
        ))
    }
}
