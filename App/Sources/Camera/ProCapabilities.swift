import AVFoundation
import Foundation

/// The manual controls, and whether this device and format can honour each one.
///
/// Two separate questions, kept separate on purpose:
///
/// - **Does the device have the capability at all?** e.g. no ProRAW on any iPhone before
///   12 Pro, no RAW on an SE. Decided once, at configuration time.
/// - **Is it available right now?** e.g. locked exposure is unavailable while a long
///   exposure is running, or on a format whose range does not include the value.
///
/// The UI rule is "hide what does not exist, disable what exists but is not available now"
/// (`docs/ARCHITECTURE.md` section 5), so both facts are needed and conflating them is how
/// a control ends up looking available and then refusing.
struct ProCapabilities: Equatable {

    /// Whether the **bound** device can be put into `.custom` exposure at all.
    ///
    /// This is the gate the whole manual panel hangs off, and it is not a formality.
    /// Apple documents that the composite device types — `.builtInTripleCamera` and
    /// `.builtInDualWideCamera` — do **not** support `ExposureMode.custom`, do not allow
    /// locking focus to a new lens position, and do not allow locking white balance to
    /// new gains. A composite also states that its exposure duration, ISO, gains and lens
    /// position may change when it switches between its constituent cameras.
    ///
    /// So a Pro dial on a composite device is a control over nothing. Rather than let the
    /// panel show a full set of sliders that cannot move the image, everything that
    /// requires `.custom` is withdrawn when this is false.
    ///
    /// `CaptureSessionController` currently binds a composite, so on a Pro iPhone this
    /// is false and the panel is empty. Fixing that means binding a constituent device
    /// instead, which is a session reconfiguration and needs a device to verify;
    /// `docs/IOS_PLAN.md` 3.2 records it. Until then the honest state is an empty panel
    /// rather than a lying one.
    var supportsCustomExposure: Bool = false

    var isoRange: ClosedRange<Float>?
    var shutterRange: ClosedRange<Double>?
    var exposureCompensationRange: ClosedRange<Float>?
    var canLockExposure: Bool = false
    var canLockFocus: Bool = false
    var canLockWhiteBalance: Bool = false
    var rawSupported: Bool = false
    var proRawSupported: Bool = false
    var maxPhotoDimensions: String = ""

    /// Nothing available. Not the same as "all available", and the difference is why the
    /// panel decides what to show rather than assuming a worst case.
    static let none = ProCapabilities()

    /// Reads what the active format reports. `AVCaptureDevice.Format` is where these live
    /// on iOS — there is no equivalent on `AVCaptureDevice` — and a capability that belongs
    /// to a format is not a capability of the camera.
    static func probe(device: AVCaptureDevice, format: AVCaptureDevice.Format) -> ProCapabilities {
        var capabilities = ProCapabilities()

        // The single question everything else is conditioned on.
        capabilities.supportsCustomExposure = device.isExposureModeSupported(.custom)

        // A range whose minimum exceeds its maximum is not a range. Some formats report
        // that for a mode they cannot actually use, and an inverted `ClosedRange` would
        // trap rather than refuse.
        //
        // The ranges are only published when `.custom` is available. ISO, shutter duration
        // and exposure bias are all meaningless without it: there is nowhere to write
        // them. Publishing them anyway is what made the panel offer sliders that silently
        // did nothing.
        if capabilities.supportsCustomExposure, format.minISO <= format.maxISO {
            capabilities.isoRange = format.minISO...format.maxISO
        }
        let minShutter = CMTimeGetSeconds(format.minExposureDuration)
        let maxShutter = CMTimeGetSeconds(format.maxExposureDuration)
        if capabilities.supportsCustomExposure, minShutter > 0, maxShutter >= minShutter {
            capabilities.shutterRange = minShutter...maxShutter
        }

        if capabilities.supportsCustomExposure {
            let bias = device.minExposureTargetBias
            let scale = device.maxExposureTargetBias
            if bias <= scale {
                capabilities.exposureCompensationRange = bias...scale
            }
        }

        capabilities.canLockExposure = capabilities.supportsCustomExposure
            && device.isExposureModeSupported(.locked)

        // `.locked` focus is not the same as "can the lens be moved". A composite supports
        // the locked focus *mode* and refuses a new lens position, so the two have to be
        // asked separately or the slider lies.
        capabilities.canLockFocus = device.isFocusModeSupported(.locked)
            && device.isLockingFocusWithCustomLensPositionSupported

        // The same caveat applies to white balance on a composite, but there is no
        // separate query for "can the gains be changed", so this is the best available
        // answer rather than a certain one.
        capabilities.canLockWhiteBalance = device.isWhiteBalanceModeSupported(.locked)

        return capabilities
    }

    /// What the RAW controls can do, from the output rather than the device. RAW and
    /// ProRAW are `AVCapturePhotoOutput` properties and there is no way to read them off
    /// the device, so the caller passes in what the output reported.
    func withRaw(raw: Bool, proRaw: Bool, maxDimensions: String) -> ProCapabilities {
        var copy = self
        copy.rawSupported = raw
        copy.proRawSupported = proRaw
        copy.maxPhotoDimensions = maxDimensions
        return copy
    }

    /// `true` when the panel has nothing at all to show, which is a real state on an SE.
    var isEmpty: Bool {
        isoRange == nil && shutterRange == nil && exposureCompensationRange == nil
            && !canLockExposure && !canLockFocus && !canLockWhiteBalance
            && !rawSupported && !proRawSupported
    }

    /// A short description of what this device and format can do, for the mode switcher and
    /// the Pro panel to show rather than an empty panel of disabled switches.
    ///
    /// A property of the capabilities and not of the manual settings, because it describes
    /// the hardware, not what the user asked for.
    var availabilitySummary: String {
        var available: [String] = []
        if !supportsCustomExposure {
            // Said first and said plainly, because on a composite device it is the whole
            // answer, and a panel listing "RAW" and nothing else reads as a bug rather
            // than as the platform.
            return "no manual exposure on \(ProCapabilities.compositeReason)"
        }
        if isoRange != nil { available.append("ISO") }
        if shutterRange != nil { available.append("shutter") }
        if canLockExposure { available.append("exposure lock") }
        if canLockFocus { available.append("focus lock") }
        if canLockWhiteBalance { available.append("white balance lock") }
        if rawSupported { available.append("RAW") }
        if proRawSupported { available.append("ProRAW") }
        return available.isEmpty
            ? "no manual controls on this device and format"
            : available.joined(separator: ", ")
    }

    /// Named once so the reason is consistent wherever it is shown, and so it names the
    /// platform's reason rather than ours.
    static let compositeReason =
        "this camera, which reports itself as a composite multi-lens device. "
        + "Apple documents that composite devices do not support manual exposure."
}

/// What the user dialled in on the Pro panel.
///
/// Mirrors the architecture's rule that our corrections only run when explicitly asked
/// for: every field here is a request, and `AVFoundation` decides what actually happens.
struct ManualSettings: Equatable, Codable, Sendable {

    /// `nil` means "let the camera decide". Not a sentinel value, because a real ISO is a
    /// number and 0 is not one.
    var iso: Float?
    /// Seconds. `nil` means automatic.
    var shutterSeconds: Double?
    /// EV. Always meaningful: 0 is the neutral point and the default.
    var exposureTargetOffset: Float = 0
    var lockExposure = false
    var lockFocus = false
    var lockWhiteBalance = false
    var raw = false
    var proRaw = false

    static let none = ManualSettings()

    /// Whether the user has dialled in anything that makes this a manual exposure.
    ///
    /// Drives `photoQualityPrioritization`. Apple's documented behaviour for `.balanced`,
    /// which is the default and is what the app used unconditionally, is that photo
    /// capture *may override the capture device's exposure duration and ISO when the scene
    /// is dark enough to require multi-image fusion* — which would discard exactly the
    /// values the user set, in precisely the low light where a manual camera is being used
    /// deliberately. `.speed` is the mode that honours them.
    var isExposureManual: Bool { iso != nil || shutterSeconds != nil || lockExposure }


    /// What the user has actually asked to change, for the log and the metadata.
    ///
    /// Deliberately verbose: "user asked for a locked exposure at ISO 100" and "the device
    /// accepted a locked exposure at ISO 100" are different sentences and conflating them
    /// is how a badge ends up promising something the hardware refused.
    var summarise: String {

        var parts: [String] = []
        if let iso { parts.append("iso=\(Int(iso))") }
        if let shutterSeconds { parts.append("sh=\(String(format: "%.4f", shutterSeconds))") }
        if exposureTargetOffset != 0 { parts.append("ev=\(String(format: "%.2f", exposureTargetOffset))") }
        if lockExposure { parts.append("lockExposure") }
        if lockFocus { parts.append("lockFocus") }
        if lockWhiteBalance { parts.append("lockWB") }
        if raw { parts.append("raw") }
        if proRaw { parts.append("proRAW") }
        return parts.isEmpty ? "auto" : parts.joined(separator: " ")
    }

    /// Refuses anything the capabilities say does not exist.
    ///
    /// Called before a value reaches AVFoundation. `device.activeFormat = format` and the
    /// exposure setters all raise `NSInvalidArgumentException` for out-of-range values, and
    /// those raises are what `LumaFrameSafety` converts into a log line. Clamping first
    /// means the refusal happens in a place that can explain itself.
    func clamped(to capabilities: ProCapabilities) -> ManualSettings {
        var copy = self
        if let range = capabilities.isoRange, let iso {
            copy.iso = min(max(iso, range.lowerBound), range.upperBound)
        } else {
            copy.iso = nil
        }
        if let range = capabilities.shutterRange, let shutterSeconds {
            copy.shutterSeconds = min(max(shutterSeconds, range.lowerBound), range.upperBound)
        } else {
            copy.shutterSeconds = nil
        }
        if let range = capabilities.exposureCompensationRange {
            copy.exposureTargetOffset = min(max(exposureTargetOffset, range.lowerBound), range.upperBound)
        } else {
            copy.exposureTargetOffset = 0
        }
        if !capabilities.canLockExposure { copy.lockExposure = false }
        if !capabilities.canLockFocus { copy.lockFocus = false }
        if !capabilities.canLockWhiteBalance { copy.lockWhiteBalance = false }
        if !capabilities.rawSupported { copy.raw = false }
        if !capabilities.proRawSupported { copy.proRaw = false }
        // ProRAW is a RAW variant, so asking for it without RAW is a request that cannot
        // be honoured and is reduced rather than passed on to fail.
        if copy.proRaw && !copy.raw { copy.raw = true }
        return copy
    }
}
