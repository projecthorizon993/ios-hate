import Foundation

/// The built-in look tables, generated in code rather than shipped as `.cube` assets.
///
/// Three reasons this is not a folder of asset files:
///
/// - The app has working looks on first launch with nothing to download and no asset
///   pipeline to get wrong.
/// - A generated table can be exactly the size the pipeline wants and exactly the sample
///   order `CIColorCube` wants, so there is no byte-order question to get wrong per file.
/// - It is testable. "Warmth actually warms" is an assertion; "the asset is present" is
///   not.
///
/// All of them are 3D tables over the **unit sRGB domain**, which is what `LUTProcessor`
/// accepts. A generator that produced a non-unit domain would be refused at apply time,
/// so none of them do.
enum GeneratedLooks {

    /// Small enough to be free at preview rate, large enough not to band. 17 is the
    /// size the .cube format's own tooling defaults to.
    static let size = 17

    /// Builds the table for a generated look.
    static func table(for which: Look.Generated) -> CubeLUT? {
        let size = self.size
        var samples: [Float] = []
        samples.reserveCapacity(size * size * size * CubeLUT.channelsPerSample)
        let denominator = Float(max(1, size - 1))

        // Red varies fastest, which is the order `CIColorCube` expects and the order the
        // parser preserves. Getting this wrong produces a plausible-looking image with
        // the channels transposed, so it is stated here rather than left to the loops.
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let red = Float(r) / denominator
                    let green = Float(g) / denominator
                    let blue = Float(b) / denominator
                    samples.append(contentsOf: transform(red, green, blue, which))
                }
            }
        }

        let table = CubeLUT(size: size,
                            kind: .threeDimensional,
                            title: which.displayName,
                            domainMin: [0, 0, 0],
                            domainMax: [1, 1, 1],
                            domainWasDeclared: true,
                            samples: samples)
        return table.isUsable ? table : nil
    }

    /// The per-pixel transform, in gamma-encoded sRGB because that is the unit domain the
    /// table is declared over and the space `LUTProcessor` will apply it in.
    ///
    /// Every intermediate is a named `Float` with an explicit type. Written as nested
    /// expressions these are `Float` / `CGFloat` literals being multiplied by inferred
    /// doubles, and the compiler's type checker gives up on them — the error is
    /// "unable to type-check this expression in reasonable time" pointing at arithmetic
    /// that is arithmetically trivial. Naming the intermediates is also what makes the
    /// intent of each look readable.
    private static func transform(_ red: Float, _ green: Float, _ blue: Float,
                                  _ which: Look.Generated) -> [Float] {
        switch which {
        case .warmth:
            let r: Float = red + 0.045
            let g: Float = green + 0.012
            let b: Float = blue - 0.030
            return [clamp01(r), clamp01(g), clamp01(b)]

        case .coolness:
            let r: Float = red - 0.030
            let g: Float = green + 0.005
            let b: Float = blue + 0.050
            return [clamp01(r), clamp01(g), clamp01(b)]

        case .fadedFilm:
            // Pulled toward mid grey, which is what "lifted blacks, softened contrast"
            // means, plus a small warmth so it does not go dead.
            let lift: Float = 0.07
            let keep: Float = 1 - lift
            let r: Float = red * keep + lift + 0.012
            let g: Float = green * keep + lift + 0.004
            let b: Float = blue * keep + lift - 0.006
            return [clamp01(r), clamp01(g), clamp01(b)]

        case .noColour:
            // Rec. 709 luma, then a touch of lift so it is not crushed.
            let luma: Float = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            let value: Float = clamp01(luma * 0.94 + 0.03)
            return [value, value, value]

        case .liftedShadows:
            // Shadows lifted, highlights rolled off rather than clipped.
            let shadow: Float = shadowWeight(red, green, blue) * 0.10
            let highlight: Float = highlightWeight(red, green, blue) * 0.16
            let r: Float = red + shadow - highlight
            let g: Float = green + shadow - highlight
            let b: Float = blue + shadow - highlight
            return [clamp01(r), clamp01(g), clamp01(b)]
        }
    }

    /// 1 in the deepest shadows, 0 in the midtones and above.
    private static func shadowWeight(_ red: Float, _ green: Float, _ blue: Float) -> Float {
        let luma: Float = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let scaled: Float = luma / 0.35
        return max(0, 1 - scaled)
    }

    /// 1 in the highlights, 0 below the midpoint.
    private static func highlightWeight(_ red: Float, _ green: Float, _ blue: Float) -> Float {
        let luma: Float = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let scaled: Float = (luma - 0.55) / 0.45
        return max(0, scaled)
    }

    /// Samples must land inside 0…1. `CIColorCube` does not clamp, and an out-of-range
    /// table produces a black or blown frame rather than an error.
    private static func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
