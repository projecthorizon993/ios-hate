import CoreML
import Foundation
import Vision

/// Core ML and Vision capability probe.
///
/// **There is no bundled model in Step 0**, so this reports what can be measured
/// without one and says so plainly rather than reporting a made-up inference time.
/// Real timing starts in Step 5, when a model exists.
///
/// Two things that matter for the design:
///
/// - Whether the Neural Engine was actually used **is not observable through public
///   API**. `MLComputeUnits` is an input, not an output. The practical signal is a
///   timing comparison across compute-unit variants, plus the Core ML log stream in
///   the device console. This report gives the first and tells the user where the
///   second is.
/// - Vision's **person segmentation request is a built-in model**. It needs no
///   bundled weights, which makes subject segmentation free. Skin-tone protection does
///   not need ML at all — see `docs/ARCHITECTURE.md` Step 5.
enum CoreMLProbe {

    /// Name of the optional model the report will benchmark when one is added.
    static let modelResourceName = "benchmark"
    static let modelResourceExtension = "mlmodelc"
    static let benchmarkIterations = 10

    // MARK: - Core ML

    static func coreMLSection(modelURL: URL?) -> ReportSection {
        var section = ReportSection("Core ML")

        section.add(ReportEntry("framework", "available"))
        section.add(ReportEntry("compute units accepted as input",
                               ReportFormat.list([
                                   "cpuOnly", "cpuAndGPU", "cpuAndNeuralEngine", "all"
                               ]),
                               .note))
        section.add(ReportEntry("ANE usage observable via public API", false, .warn))
        section.add(ReportEntry("ANE note",
                               "MLComputeUnits is an input only. Compare the timings below across "
                               + "variants, and look for \"Neural Engine\" in the Core ML log stream "
                               + "(subsystem com.apple.coreml) in the device console.", .note))

        guard let url = modelURL else {
            section.add(ReportEntry("benchmark model", "not present in bundle", .warn))
            section.add(ReportEntry("benchmark note",
                                   "Step 0 ships without a model on purpose. Add a compiled "
                                   + "\(modelResourceName).mlmodelc to the target and rerun; the report "
                                   + "then times every compute unit variant.", .note))
            return section
        }

        section.add(ReportEntry("benchmark model", url.lastPathComponent, .good))

        let variants: [(String, MLComputeUnits)] = [
            ("cpuOnly", .cpuOnly),
            ("cpuAndGPU", .cpuAndGPU),
            ("cpuAndNeuralEngine", .cpuAndNeuralEngine),
            ("all", .all)
        ]

        for (name, units) in variants {
            let loadStart = DispatchTime.now().uptimeNanoseconds
            do {
                // Compute units are configured through `MLModelConfiguration`, not as a
                // second argument to the initialiser.
                let configuration = MLModelConfiguration()
                configuration.computeUnits = units
                let model = try MLModel(contentsOf: url, configuration: configuration)
                let loadMs = elapsedMs(since: loadStart)
                describeInputs(of: model, into: &section)

                var samples: [Double] = []
                var failure: Error?
                do {
                    for _ in 0..<benchmarkIterations {
                        let start = DispatchTime.now().uptimeNanoseconds
                        // `prediction(from:)` throws, and so does `makeZeroInput`. Both
                        // are caught by this `do` block.
                        _ = try model.prediction(from: makeZeroInput(for: model))
                        samples.append(elapsedMs(since: start))
                    }
                } catch {
                    failure = error
                }

                if let failure {
                    section.add(ReportEntry("\(name) inference",
                                            "failed: \(failure.localizedDescription)", .fail))
                } else if let median = median(samples) {
                    let level: ReportLevel = median < 10 ? .good : .warn
                    section.add(ReportEntry("\(name) inference",
                                            "\(ReportFormat.number(median)) ms median of \(samples.count) "
                                            + "(load \(ReportFormat.number(loadMs)) ms)", level))
                    section.add(ReportEntry("  min / max",
                                            "\(ReportFormat.number(samples.min() ?? 0)) / "
                                            + "\(ReportFormat.number(samples.max() ?? 0)) ms", .note))
                }
            } catch {
                let loadMs = elapsedMs(since: loadStart)
                section.add(ReportEntry("\(name) load",
                                        "failed after \(ReportFormat.number(loadMs)) ms: "
                                        + error.localizedDescription, .fail))
            }
        }

        section.add(ReportEntry("recommended variant",
                                recommendedVariantHint(in: section), .note))
        return section
    }

    private static func recommendedVariantHint(in section: ReportSection) -> String {
        let timed = section.entries
            .filter { $0.label.hasSuffix("inference") }
            .compactMap { entry -> (String, Double)? in
                guard let first = entry.value.split(separator: " ").first,
                      let value = Double(first) else { return nil }
                return (entry.label.replacingOccurrences(of: " inference", with: ""), value)
            }
        guard let best = timed.min(by: { $0.1 < $1.1 }) else {
            return "no successful inference; see failures above"
        }
        return "\(best.0) at \(ReportFormat.number(best.1)) ms"
    }

    private static func describeInputs(of model: MLModel, into section: inout ReportSection) {
        let description = model.modelDescription
        // `author`, `license` and `versionDescription` are not part of
        // `MLModelDescription` in the iOS SDK, so they are not reported. What is
        // available is the free-form metadata dictionary, which is printed verbatim.
        section.add(ReportEntry("model metadata keys",
                               ReportFormat.list(description.metadata.keys.map { String(describing: $0) },
                                                empty: "none"), .note))
        section.add(ReportEntry("model metadata",
                               description.metadata.isEmpty
                                   ? "empty; no license or author recorded in the model"
                                   : description.metadata
                                       .map { "\(String(describing: $0.key))=\(String(describing: $0.value))" }
                                       .sorted()
                                       .joined(separator: ", "),
                               description.metadata.isEmpty ? .warn : .note))
        section.add(ReportEntry("model inputs", describeShapes(description.inputDescriptionsByName), .note))
        section.add(ReportEntry("model outputs", describeShapes(description.outputDescriptionsByName), .note))
    }

    private static func describeShapes(_ descriptions: [String: MLFeatureDescription]) -> String {
        guard !descriptions.isEmpty else { return "none" }
        return descriptions.keys.sorted().map { name -> String in
            guard let description = descriptions[name] else { return name }
            // The constraint type is `MLMultiArrayConstraint`; there is no
            // `...ConstraintDescription` in Swift.
            guard let multiArray = description.multiArrayConstraint else {
                return "\(name) (non-array)"
            }
            let shape = multiArray.shape.map { "\($0)" }.joined(separator: "x")
            return "\(name) [\(shape)] \(multiArray.dataType.rawValue)"
        }.joined(separator: ", ")
    }

    /// Builds a zero-filled input provider matching the model's declared inputs. Any
    /// numeric dtype is supported, so this works for a classification or a
    /// segmentation model without hard-coding a shape.
    private static func makeZeroInput(for model: MLModel) throws -> MLDictionaryFeatureProvider {
        var features: [String: MLFeatureValue] = [:]
        for (name, description) in model.modelDescription.inputDescriptionsByName {
            guard let constraint = description.multiArrayConstraint else {
                throw ProbeError.unsupportedInput(name)
            }
            // `MLMultiArray(shape:dataType:)` allocates its own zeroed buffer, so there
            // is no need to size one by hand and no way to pass one in.
            let array = try MLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
            features[name] = MLFeatureValue(multiArray: array)
        }
        return try MLDictionaryFeatureProvider(dictionary: features)
    }

    // MARK: - Vision

    /// Built-in models, so this section is fully populated on every device today.
    static func visionSection() -> ReportSection {
        var section = ReportSection("Vision (built-in models)")

        section.add(ReportEntry("person segmentation request", "available", .good))
        // `supportedQualityLevels` is not exposed on this class. The request is still
        // constructible, which is the fact that actually matters for Step 5, so that is
        // what is reported rather than a list of constants that does not exist.
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        section.add(ReportEntry("default quality level accepted",
                               "\(request.qualityLevel.rawValue)"))
        // `supportedOutputPixelFormats()` is a throwing method available from iOS 18,
        // which is why the deployment target is 18.0. Its elements are `NSNumber`, not
        // `OSType`, so each one is unboxed before being printed.
        let formats = (try? request.supportedOutputPixelFormats()) ?? []
        section.add(ReportEntry("output pixel format count", formats.count))
        section.add(ReportEntry("output pixel formats",
                               ReportFormat.list(formats.map { fourCCHex($0.ostValue) },
                                                empty: "none"),
                               .note))
        section.add(ReportEntry("attention saliency request", "available", .good))
        section.add(ReportEntry("note",
                               "subject segmentation needs no bundled model. Skin-tone protection is a "
                               + "colorimetric transform, not a neural network. This is why Step 5 starts "
                               + "with Vision rather than a .mlpackage.", .note))
        return section
    }

    // MARK: - Helpers

    enum ProbeError: LocalizedError {
        case unsupportedInput(String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedInput(name):
                return "input \"\(name)\" is not a multi-array; this probe only fills numeric arrays"
            }
        }
    }

    private static func elapsedMs(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }

    private static func median(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    private static func fourCCHex(_ type: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((type >> 24) & 0xFF),
            UInt8((type >> 16) & 0xFF),
            UInt8((type >> 8) & 0xFF),
            UInt8(type & 0xFF)
        ]
        let text = bytes.map { byte -> String in
            let scalar = UnicodeScalar(byte)
            return (scalar.value >= 0x20 && scalar.value < 0x7F) ? String(scalar) : "?"
        }.joined()
        return "0x" + String(type, radix: 16, uppercase: true) + " '" + text + "'"
    }
}
