import AVFoundation
import CoreMedia
import Foundation

/// Picks the session preset, the active format, and the preview frame rate.
///
/// This is explicit rather than left to `sessionPreset`, for one reason: Step 1's
/// promise is **native HDR**, and native HDR for stills is a property of the *format*.
/// If the preset chooses the format, the badge can claim a capability the active
/// format does not have, which is the one thing `docs/ARCHITECTURE.md` section 2.4
/// says never to do.
enum CaptureFormatChooser {

    /// Below this the viewfinder feels broken, so a format that cannot sustain it is
    /// not worth the still quality it buys.
    static let minimumPreviewFrameRate: Double = 30

    /// Formats supporting the top of that rate range, best still quality first.
    ///
    /// Ranking, in order, with the reason each level exists:
    ///
    /// 1. `isHighestPhotoQualitySupported` — this is the format that can actually do
    ///    the multi-frame / long-exposure still fusion. If none has it, the quality
    ///    badge degrades to "ready" and never claims a fusion.
    /// 2. Not binned. A binned format is a lower-resolution readout of a larger sensor
    ///    and reads as a soft photo.
    /// 3. Largest still area. What the user gets out of the app.
    /// 4. Longest exposure. This is the low-light product; on two formats of equal
    ///    still size, the one that can hold the shutter open wins.
    /// 5. Largest video area. Ties only.
    static func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let usable = device.formats.filter { supportsPreviewRate($0, fps: minimumPreviewFrameRate) }
        guard !usable.isEmpty else {
            AppLog.warn(AppLog.camera, "no format sustains \(Int(minimumPreviewFrameRate))fps; "
                      + "falling back to the device default")
            return device.activeFormat
        }
        return usable.max { score($0) < score($1) }
    }

    /// Ordering key, descending. Kept separate from `bestFormat` so the ranking is
    /// readable in one place.
    private static func score(_ format: AVCaptureDevice.Format) -> (Int, Int, Int, Int, Int) {
        let quality = format.isHighestPhotoQualitySupported ? 1 : 0
        let unBinned = format.isVideoBinned ? 0 : 1
        let still = stillPixelCount(format)
        let exposure = Int((CMTimeGetSeconds(format.maxExposureDuration) * 1_000_000).rounded())
        let video = videoPixelCount(format)
        return (quality, unBinned, still, exposure, video)
    }

    static func supportsPreviewRate(_ format: AVCaptureDevice.Format, fps: Double) -> Bool {
        format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
    }

    /// Frame duration to request, clamped to what the format actually supports.
    ///
    /// `activeVideoMinFrameDuration` / `activeVideoMaxFrameDuration` both have to be
    /// written, and writing a value outside the format's supported range raises
    /// `NSInvalidArgumentException` inside AVFoundation.
    static func previewFrameDuration(for format: AVCaptureDevice.Format,
                                     preferredFPS: Double = minimumPreviewFrameRate) -> CMTime {
        let supported = format.videoSupportedFrameRateRanges
            .filter { $0.maxFrameRate >= preferredFPS }
            .max { $0.maxFrameRate < $1.maxFrameRate }
            ?? format.videoSupportedFrameRateRanges.max { $0.maxFrameRate < $1.maxFrameRate }
        guard let supported else { return CMTime(value: 1, timescale: 30) }
        let fps = min(max(preferredFPS, supported.minFrameRate), supported.maxFrameRate)
        return CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
    }

    // MARK: - Dimensions

    /// Largest still the format can produce, in pixels.
    ///
    /// `supportedMaxPhotoDimensions` is iOS 16+ and is the only way to know the still
    /// size; the video dimensions are a different number and are not a substitute.
    static func stillPixelCount(_ format: AVCaptureDevice.Format) -> Int {
        // `CMVideoDimensions` uses Int32, so the product is widened before it is used as
        // an Int sort key.
        let dimensions = format.supportedMaxPhotoDimensions
        if let largest = dimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            return Int(largest.width) * Int(largest.height)
        }
        return videoPixelCount(format)
    }

    static func videoPixelCount(_ format: AVCaptureDevice.Format) -> Int {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return Int(dimensions.width) * Int(dimensions.height)
    }

    /// One-line description for the log, so a capture can be traced back to the exact
    /// format that produced it. Never used in the UI.
    static func describe(_ format: AVCaptureDevice.Format) -> String {
        let largest = format.supportedMaxPhotoDimensions.max {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }
        let stillText = largest.map { "\($0.width)x\($0.height)" } ?? "n/a"
        let fourCC = ReportFormat.fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        let maxShutter = ReportFormat.shutter(CMTimeGetSeconds(format.maxExposureDuration))
        return "\(stillText) still | \(fourCC) video | "
            + "highQuality=\(format.isHighPhotoQualitySupported) "
            + "highest=\(format.isHighestPhotoQualitySupported) "
            + "hdr=\(format.isVideoHDRSupported) "
            + "binned=\(format.isVideoBinned) "
            + "maxShutter=\(maxShutter)"
    }
}
