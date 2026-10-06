import Foundation

/// A parsed 3D lookup table plus the colour space it is declared to live in.
///
/// The space is **declared at import**, never inferred from the file: Adobe `.cube`
/// has no colour-space directive, and the old system's habit of inferring sRGB from
/// unit domain values is what washed out every look. The importer states the space
/// (sRGB unless the user says otherwise) and it travels with the table from then on.
struct LutTable: Equatable, Sendable {

    /// Edge length. Samples number `size³`, red varying fastest (the Adobe order,
    /// preserved verbatim by the parser).
    var size: Int
    /// RGB triples, `size³ × 3`, each 0…1.
    var samples: [Float]
    /// The declared space the samples are encoded in.
    var space: ColorSpace

    var isUsable: Bool {
        size >= LutParser.minimumSize && size <= LutParser.maximumSize
            && samples.count == size * size * size * 3
    }

    /// The table interpolated toward identity at strength `t`.
    ///
    /// Pure, and the whole of the engine's intensity semantics: `t == 0` is the
    /// identity lattice, `t == 1` is the table, and anything between is the lerp.
    /// Interpolating the table rather than dissolving two renders means intensity is
    /// a property of the grade (decided here, in `docs/ENGINE_PLAN.md` §4) and costs
    /// one filter pass instead of two.
    func interpolated(at t: Float) -> [Float] {
        let strength = min(max(t.isFinite ? t : 0, 0), 1)
        guard strength > 0, samples.count == size * size * size * 3, size > 1 else {
            return identityLattice()
        }
        guard strength < 1 else { return samples }
        let lattice = identityLattice()
        return zip(samples, lattice).map { sample, id in id + (sample - id) * strength }
    }

    /// The upload buffer Core Image documents: premultiplied RGBA floats.
    ///
    /// The table is RGB, so alpha 1 is added here — opaque, making premultiplication
    /// a no-op. Returns `nil` rather than a short buffer: a buffer 25% short of
    /// `size³ × 4 × 4` bytes fails the texture upload and the filter yields nothing,
    /// which is the no-op-look saga verbatim.
    func rgbaData(intensity: Float) -> Data? {
        let rgb = interpolated(at: intensity)
        let count = size * size * size
        guard size > 1, rgb.count == count * 3 else { return nil }
        var rgba = [Float](repeating: 1, count: count * 4)
        for i in 0..<count {
            rgba[i * 4] = rgb[i * 3]
            rgba[i * 4 + 1] = rgb[i * 3 + 1]
            rgba[i * 4 + 2] = rgb[i * 3 + 2]
        }
        return rgba.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return nil }
            return Data(bytes: base, count: buffer.count * MemoryLayout<Float>.size)
        }
    }

    /// The identity lattice in file order: sample `i` holds its own coordinates.
    func identityLattice() -> [Float] {
        guard size > 1 else { return [] }
        let denom = Float(size - 1)
        var lattice = [Float]()
        lattice.reserveCapacity(size * size * size * 3)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    lattice.append(Float(r) / denom)
                    lattice.append(Float(g) / denom)
                    lattice.append(Float(b) / denom)
                }
            }
        }
        return lattice
    }
}

/// What a recipe records about an imported table.
///
/// A **reference**, not the table: the samples live in `Documents/LUTs/` and are
/// resolved at render time, so a recipe stays small and survives the file being
/// replaced. Intensity rides along because the same table at different strengths on
/// different photos is the normal case, not an edge.
struct LutReference: Equatable, Codable, Sendable {

    /// The file name inside the store directory, as sanitised at import.
    var filename: String
    /// 0…1, clamped at the recipe boundary.
    var intensity: Float
    /// The space declared at import.
    var space: ColorSpace

    func clamped() -> LutReference {
        var copy = self
        copy.intensity = min(max(intensity.isFinite ? intensity : 0, 0), 1)
        return copy
    }
}
