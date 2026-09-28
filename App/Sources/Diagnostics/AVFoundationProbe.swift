import AVFoundation
import CoreMedia
import Foundation

/// Enumerates every capture device and every photo-output capability that can only be
/// read from a live session.
///
/// Two things force a live session here, and both are documented Apple behaviour
/// rather than guesswork:
///
/// 1. `AVCapturePhotoOutput.availableRawPhotoPixelTypes` and `isAppleProRAWSupported`
///    are **output** properties. Apple's own documentation says to add the output to
///    a session with a connected video source and query it there. There is no
///    equivalent on `AVCaptureDevice`, so `isAppleProRAWSupported` cannot be answered
///    by reading the device alone.
/// 2. `AVCaptureSession.canSetSessionPreset(_:)` is meaningless before the session has
///    inputs and outputs.
///
/// There is **no public API that reports whether the system chose a multi-frame or
/// long-exposure HDR path for a given still.** This probe therefore reports only
/// hardware and pipeline capability. See `docs/ARCHITECTURE.md` section 2.4.
enum AVFoundationProbe {

    /// Cap on formats listed per device, so the shareable text stays readable.
    static let formatLimit = 40

    static func sections() -> [ReportSection] {
        var sections: [ReportSection] = []
        let devices = discoverDevices()

        sections.append(discoverySection(devices))
        for device in devices {
            sections.append(deviceSection(device))
        }
        return sections
    }

    // MARK: - Discovery

    /// Uses `DiscoverySession` because `AVCaptureDevice.devices(for:)` is deprecated
    /// from iOS 16.
    ///
    /// Note there is no public "quad camera" device type. The iPhone 11 Pro Max
    /// reports its three back cameras through `.builtInTripleCamera`; the Galaxy S21
    /// Ultra's four back cameras are a Camera2 concept with no iOS equivalent, which is
    /// exactly why lens UI must come from a capability list rather than a device name.
    static func discoverDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera,
            .builtInWideAngleCamera,
            .builtInTelephotoCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInTripleCamera
        ]
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                       mediaType: .video,
                                                       position: .unspecified)
        var seen = Set<String>()
        return session.devices.filter { seen.insert($0.uniqueID).inserted }
    }

    private static func discoverySection(_ devices: [AVCaptureDevice]) -> ReportSection {
        var section = ReportSection("Camera discovery")

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let statusText: String
        switch status {
        case .authorized: statusText = "authorized"
        case .denied: statusText = "denied"
        case .restricted: statusText = "restricted"
        case .notDetermined: statusText = "not determined"
        @unknown default: statusText = "unknown"
        }
        section.add(ReportEntry("camera permission", statusText,
                                status == .authorized ? .good : .fail))

        section.add(ReportEntry("video devices found", devices.count,
                                devices.isEmpty ? .fail : .good))

        if devices.isEmpty {
            section.add(ReportEntry("note",
                                    "no capture devices. On the simulator this is expected; the "
                                    + "render benchmark and Core ML sections are still valid.",
                                    .warn))
        }

        var backCount = 0
        for device in devices where device.position == .back {
            backCount += 1
            section.add(ReportEntry("back device \(backCount)",
                                    describeType(device.deviceType),
                                    .note))
        }
        section.add(ReportEntry("back camera count", backCount))
        section.add(ReportEntry("lens switching UI needed",
                                backCount > 1 ? "yes" : "no",
                                backCount > 1 ? .good : .note))

        var frontCount = 0
        for device in devices where device.position == .front {
            frontCount += 1
        }
        section.add(ReportEntry("front camera count", frontCount))
        return section
    }

    // MARK: - Per device

    private static func deviceSection(_ device: AVCaptureDevice) -> ReportSection {
        let title = "Device " + describeType(device.deviceType) + " [\(device.position)]"
        var section = ReportSection(title)

        // Five of the properties below live on `AVCaptureDevice.Format`, not on
        // `AVCaptureDevice`. The probe reads them off the active format, which is the
        // honest answer anyway: a capability like white-balance locking is a property
        // of a format, and the same lens can have it on one format and not another.
        let format = device.activeFormat

        section.add(ReportEntry("deviceType raw", device.deviceType.rawValue))
        section.add(ReportEntry("position", "\(device.position)"))
        section.add(ReportEntry("uniqueID", device.uniqueID, .note))
        section.add(ReportEntry("format count", device.formats.count))
        section.add(ReportEntry("is flash available", device.isFlashAvailable))
        section.add(ReportEntry("is smooth auto focus supported", device.isSmoothAutoFocusSupported))
        section.add(ReportEntry("is focus distance locking supported",
                               device.isLockingFocusWithCustomLensPositionSupported))
        section.add(ReportEntry("minimum focus distance",
                               device.minimumFocusDistance >= 0
                                   ? "\(device.minimumFocusDistance) mm"
                                   : "n/a"))
        // `nominalFocalLengthIn35mmFilm`, `isLensStabilizationDuringBracketedCaptureSupported`
        // and `isWhiteBalanceLockSupported` are deliberately not probed. The first is not
        // exposed by the iOS SDK at all, and the other two are properties of the
        // `AVCapturePhotoOutput` rather than of the device or its format, so they are
        // reported in the session section below where a real output exists. Printing a
        // fabricated value here would be worse than printing nothing.
        section.add(ReportEntry("nominal focal length (35mm equiv)", notMeasured, .note))
        section.add(ReportEntry("is externally synchronized", notMeasured, .note))

        // Current configuration. Without a running session these are the format
        // defaults, which is still the correct answer for "what can this do".
        section.add(ReportEntry("active format fourCC",
                               ReportFormat.fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription))))
        section.add(ReportEntry("active format", describeFormat(format)))
        section.add(ReportEntry("iso range",
                               ReportFormat.range(Double(format.minISO), Double(format.maxISO))))
        section.add(ReportEntry("iso (current)", ReportFormat.number(Double(device.iso))))
        section.add(ReportEntry("exposure duration range",
                               ReportFormat.shutter(CMTimeGetSeconds(format.minExposureDuration))
                                + " ... " + ReportFormat.shutter(CMTimeGetSeconds(format.maxExposureDuration))))
        section.add(ReportEntry("exposure duration (current)",
                               ReportFormat.shutter(CMTimeGetSeconds(device.exposureDuration))))
        // The offset range is a property of the device, and only when the active format
        // has one; a device without it reports -1 on both bounds, which is a real answer
        // rather than a missing measurement.
        let offsets = device.supportedExposureTargetOffsetRange
        section.add(ReportEntry("exposure target offset range",
                               offsets.lowerBound >= 0
                                   ? ReportFormat.range(Double(offsets.lowerBound), Double(offsets.upperBound))
                                   : notMeasured))
        section.add(ReportEntry("exposure target offset (current)",
                               ReportFormat.number(Double(device.exposureTargetOffset))))
        section.add(ReportEntry("exposure modes",
                               ReportFormat.list(exposureModes(device).map { "\($0)" })))
        section.add(ReportEntry("focus modes",
                               ReportFormat.list(focusModes(device).map { "\($0)" })))
        section.add(ReportEntry("white balance modes",
                               ReportFormat.list(whiteBalanceModes(device).map { "\($0)" })))
        section.add(ReportEntry("is white balance lock supported", notMeasured, .note))
        section.add(ReportEntry("is exposure mode custom supported",
                               device.isExposureModeSupported(.custom), .good))
        section.add(ReportEntry("is focus mode locked (lens position) supported",
                               device.isFocusModeSupported(.locked), .good))
        section.add(ReportEntry("automatically adjusts video HDR",
                               device.automaticallyAdjustsVideoHDREnabled, .note))

        section.add(entries: sessionCapabilityEntries(device))
        section.add(entries: formatEntries(device))

        return section
    }

    /// Everything that requires inputs and outputs to be attached.
    private static func sessionCapabilityEntries(_ device: AVCaptureDevice) -> [ReportEntry] {
        var entries: [ReportEntry] = []

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .photo
        let presetAccepted = session.sessionPreset == .photo
        session.commitConfiguration()

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                entries.append(ReportEntry("session", "input rejected for this device", .fail))
                return entries
            }
            session.addInput(input)

            let output = AVCapturePhotoOutput()
            guard session.canAddOutput(output) else {
                entries.append(ReportEntry("session", "photo output rejected", .fail))
                return entries
            }
            session.addOutput(output)

            // Apple documents ProRAW and RAW as properties to query "in the current
            // environment", with an output attached to a session that has a connected
            // video source. Inputs and outputs alone satisfy that wording, but starting
            // the session is what actually resolves the active device, so it is started
            // briefly and the result is reported either way rather than assumed.
            let startFailure = LumaFrameSafety.perform { session.startRunning() }
            let isRunning = session.isRunning
            entries.append(ReportEntry("session started", isRunning, isRunning ? .good : .warn))
            if let startFailure {
                entries.append(ReportEntry("session start", startFailure, .fail))
            }

            entries.append(ReportEntry("session preset .photo accepted", presetAccepted,
                                       presetAccepted ? .good : .fail))
            entries.append(ReportEntry("max photo dimensions",
                                       "\(output.maxPhotoDimensions.width)x\(output.maxPhotoDimensions.height)"))

            // RAW. Output-level, so a session is required. The property is
            // `availableRawPhotoPixelFormatTypes` — "PixelTypes" is the name people
            // remember, and it does not exist.
            let rawTypes = output.availableRawPhotoPixelFormatTypes
            entries.append(ReportEntry("RAW available", !rawTypes.isEmpty,
                                       rawTypes.isEmpty ? .fail : .good))
            for type in rawTypes {
                entries.append(ReportEntry("RAW pixel type", fourCCHex(type.ostValue), .note))
            }
            if rawTypes.isEmpty {
                entries.append(ReportEntry("RAW note",
                                           "no RAW pixel types on this device. Step 1 must hide RAW here.",
                                           .warn))
            }

            // ProRAW. Output-level and documented as requiring a connected source.
            let proRAW = output.isAppleProRAWSupported
            entries.append(ReportEntry("Apple ProRAW supported", proRAW,
                                       proRAW ? .good : .info))
            if !proRAW {
                entries.append(ReportEntry("ProRAW note",
                                           "not supported. Standard RAW above is independent of this "
                                           + "and may still be available.", .note))
            }

            // Lens stabilisation during bracketed capture is a property of the *output*,
            // not of the device or its format.
            let bracketedStabilization = output.isLensStabilizationDuringBracketedCaptureSupported
            entries.append(ReportEntry("is lens stabilization during bracketed capture supported",
                                       bracketedStabilization,
                                       bracketedStabilization ? .good : .info))
            entries.append(ReportEntry("max bracketed capture photo count",
                                       output.maxBracketedCapturePhotoCount))

            let codecs = output.availablePhotoCodecTypes
            entries.append(ReportEntry("photo codecs", ReportFormat.list(
                codecs.map { $0 == .hevc ? "HEVC" : $0 == .heif ? "HEIF" : $0 == .jpeg ? "JPEG" : "\($0.rawValue)" },
                empty: "none")))
            entries.append(ReportEntry("is Apple ProRAW enabled (default)", output.isAppleProRAWEnabled, .note))

            // ProRAW cannot be requested for a format that is not the active one, so
            // only the currently selected format is meaningful here.
            let active = device.activeFormat
            if proRAW {
                entries.append(ReportEntry("ProRAW vs active format",
                                           active.isHighestPhotoQualitySupported
                                               ? "highest photo quality supported"
                                               : "highest photo quality NOT supported on this format",
                                           active.isHighestPhotoQualitySupported ? .good : .warn))
            }

            if isRunning {
                _ = LumaFrameSafety.perform { session.stopRunning() }
            }
        } catch {
            entries.append(ReportEntry("session", "input creation failed: \(error.localizedDescription)", .fail))
        }

        return entries
    }

    private static func formatEntries(_ device: AVCaptureDevice) -> [ReportEntry] {
        var entries: [ReportEntry] = []
        var formats = device.formats

        // Largest first, so the truncation below drops the least interesting formats.
        formats.sort { pixelCount($0.formatDescription) > pixelCount($1.formatDescription) }
        let shown = Array(formats.prefix(formatLimit))
        if formats.count > shown.count {
            entries.append(ReportEntry("formats listed", "\(shown.count) of \(formats.count) (largest first)",
                                       .note))
        }

        var highQualityFormats = 0
        var hdrFormats = 0
        for format in device.formats {
            if format.isHighestPhotoQualitySupported || format.isHighPhotoQualitySupported { highQualityFormats += 1 }
            if format.isVideoHDRSupported { hdrFormats += 1 }
        }
        entries.append(ReportEntry("formats with video HDR support", hdrFormats,
                                   hdrFormats > 0 ? .good : .info))
        entries.append(ReportEntry("formats with high photo quality support", highQualityFormats,
                                   highQualityFormats > 0 ? .good : .info))

        for (index, format) in shown.enumerated() {
            entries.append(ReportEntry("format \(index + 1)", describeFormat(format), .note))
            let description = format.formatDescription
            entries.append(ReportEntry("  color primaries", colorPrimaries(description), .note))
            entries.append(ReportEntry("  transfer function", transferFunction(description), .note))
            entries.append(ReportEntry("  video HDR", format.isVideoHDRSupported,
                                    format.isVideoHDRSupported ? .good : .info))
            entries.append(ReportEntry("  high photo quality", format.isHighPhotoQualitySupported, .note))
            entries.append(ReportEntry("  highest photo quality", format.isHighestPhotoQualitySupported, .note))
            entries.append(ReportEntry("  binned", format.isVideoBinned, .note))
            entries.append(ReportEntry("  max photo dimension",
                                    format.supportedMaxPhotoDimensions
                                        .map { "\($0.width)x\($0.height)" }
                                        .joined(separator: ","), .note))
            let ranges = format.videoSupportedFrameRateRanges
                .map { String(format: "%.0f", $0.maxFrameRate) }
            entries.append(ReportEntry("  max frame rates", ReportFormat.list(Array(Set(ranges)), empty: "n/a"), .note))
        }
        return entries
    }

    // MARK: - Description helpers

    private static func describeType(_ type: AVCaptureDevice.DeviceType) -> String {
        switch type {
        case .builtInUltraWideCamera: return "ultra wide"
        case .builtInWideAngleCamera: return "wide"
        case .builtInTelephotoCamera: return "telephoto"
        case .builtInDualWideCamera: return "dual wide"
        case .builtInDualCamera: return "dual"
        case .builtInTripleCamera: return "triple"
        case .builtInTrueDepthCamera: return "true depth"
        case .builtInLiDARDepthCamera: return "LiDAR depth"
        case .external: return "external"
        case .externalWideAngle: return "external wide"
        case .continuityCamera: return "continuity"
        @unknown default: return "unknown (\(type.rawValue))"
        }
    }

    static func describeFormat(_ format: AVCaptureDevice.Format) -> String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let fourCC = ReportFormat.fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        let rates = Set(format.videoSupportedFrameRateRanges.map { String(format: "%.0f", $0.maxFrameRate) })
        let rateText = rates.isEmpty ? "" : "@" + rates.sorted().joined(separator: "/")
        return "\(dimensions.width)x\(dimensions.height) \(fourCC)\(rateText)"
    }

    private static func exposureModes(_ device: AVCaptureDevice) -> [AVCaptureDevice.ExposureMode] {
        var modes: [AVCaptureDevice.ExposureMode] = []
        // The three real cases are `locked`, `continuousAutoExposure` and `custom`.
        // There is no `continuousLocked`.
        for mode in [AVCaptureDevice.ExposureMode.custom, .continuousAutoExposure, .locked] {
            if device.isExposureModeSupported(mode) { modes.append(mode) }
        }
        return modes
    }

    private static func focusModes(_ device: AVCaptureDevice) -> [AVCaptureDevice.FocusMode] {
        var modes: [AVCaptureDevice.FocusMode] = []
        for mode in [AVCaptureDevice.FocusMode.locked, .autoFocus, .continuousAutoFocus] {
            if device.isFocusModeSupported(mode) { modes.append(mode) }
        }
        return modes
    }

    private static func whiteBalanceModes(_ device: AVCaptureDevice) -> [AVCaptureDevice.WhiteBalanceMode] {
        var modes: [AVCaptureDevice.WhiteBalanceMode] = []
        for mode in [AVCaptureDevice.WhiteBalanceMode.locked, .autoWhiteBalance] {
            if device.isWhiteBalanceModeSupported(mode) { modes.append(mode) }
        }
        return modes
    }

    private static func pixelCount(_ description: CMFormatDescription) -> Int {
        // `CMVideoDimensions` uses Int32, so the product is widened before it is compared
        // against the Int sort keys above.
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        return Int(dimensions.width) * Int(dimensions.height)
    }

    /// Colour information from the format description, rather than the deprecated
    /// `AVCaptureDevice.Format.videoSupportedColorSpaces`.
    private static func colorPrimaries(_ description: CMFormatDescription) -> String {
        guard let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any],
              let value = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        else { return "unknown" }
        return value
    }

    private static func transferFunction(_ description: CMFormatDescription) -> String {
        guard let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any],
              let value = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        else { return "unknown" }
        return value
    }

    /// `OSType` is a `UInt32` FourCC; the report prints it as hex because these codes
    /// have no public Swift names, and Step 1 maps them to real pixel buffer formats.
    private static func fourCCHex(_ type: OSType) -> String {
        let text = ReportFormat.fourCC(type)
        let sanitised = text.unicodeScalars.map { scalar -> String in
            scalar.properties.isAlphabetic ? String(scalar).uppercased() : "?"
        }.joined()
        return "0x" + String(type, radix: 16, uppercase: true) + " '" + sanitised + "'"
    }
}
