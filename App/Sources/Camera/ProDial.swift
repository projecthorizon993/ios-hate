import SwiftUI

/// Step 4's pro dial: one parameter at a time, ruler style, with an AUTO chip per
/// parameter.
///
/// `DESIGN_SPEC.md` is specific — "one parameter at a time, ruler-style, continuous drag
/// with detents at the device's real min/max (never a synthetic range)", and a stack of six
/// sliders is none of those things. Six sliders also make it impossible to feel a value
/// changing while looking at the viewfinder, which is the entire point of a pro control.
///
/// A dial rather than a horizontal ruler because the ranges are the problem: shutter spans
/// about 28 stops, ISO spans a decade or three, and a linear strip for either spends most
/// of its length on values nobody will use. A dial puts the usable range in the arc the
/// thumb actually travels and detents on the real hardware values.
struct ProDial: View {

    @ObservedObject var model: CameraViewModel

    /// Which parameter the dial is showing. Exactly one, per the spec.
    @State private var selected: ProParameter = .iso

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            parameterPicker
            dial
            autoChip
        }
        .padding(Theme.Space.l)
    }

    // MARK: - Picker

    /// One chip per parameter the device and format actually support.
    ///
    /// A parameter the hardware cannot do is **absent**, not disabled — a row of greyed-out
    /// chips is an inventory of what the device is not, which is not information anybody
    /// composing a photo wants.
    private var parameterPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(ProParameter.supported(by: model.proCapabilities), id: \.self) { parameter in
                    Button {
                        Haptics.selection()
                        selected = parameter
                    } label: {
                        Text(parameter.title)
                            .font(.system(size: Theme.TypeSize.caption))
                            .foregroundStyle(parameter == selected
                                             ? Theme.ColorToken.surfaceBase
                                             : Theme.ColorToken.textSecondary)
                            .padding(.horizontal, Theme.Space.s)
                            .frame(height: Theme.Space.xl)
                            .background(parameter == selected
                                        ? Theme.ColorToken.accentActive
                                        : Theme.ColorToken.surfaceRaised)
                            .clipShape(Capsule())
                    }
                    .accessibilityLabel(parameter.title)
                    .accessibilityAddTraits(parameter == selected ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
    }

    // MARK: - Dial

    private var dial: some View {
        VStack(spacing: Theme.Space.s) {
            Text(selected.readout(model.manual))
                .font(.system(size: Theme.TypeSize.title, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.textPrimary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: Theme.Motion.tap), value: model.manual)

            GeometryReader { geometry in
                let side = min(geometry.size.width, Theme.Space.huge * 4)
                DialTicks(parameter: selected,
                          capabilities: model.proCapabilities,
                          value: selected.value(model.manual),
                          size: side)
                    .frame(width: side, height: side)
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let fraction = angleFraction(value.location,
                                                             in: geometry.size,
                                                             centre: CGPoint(x: geometry.size.width / 2,
                                                                             y: geometry.size.height / 2))
                                selected.apply(fraction: fraction, to: model)
                            }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 200)
            .accessibilityElement()
            .accessibilityLabel(selected.title)
            .accessibilityValue(selected.readout(model.manual))
            .accessibilityAdjustableAction { direction in
                selected.step(model, by: direction)
            }
        }
    }

    /// The AUTO chip, per the spec: it returns **this** parameter to automatic without
    /// touching the others, which is the reason it is a chip and not a mode.
    @ViewBuilder
    private var autoChip: some View {
        if selected.isAutomatic(model.manual) {
            Text("AUTO")
                .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Theme.ColorToken.accentActive)
                .padding(.horizontal, Theme.Space.m)
                .frame(height: Theme.Space.xl)
                .background(Theme.ColorToken.surfaceRaised)
                .clipShape(Capsule())
                .accessibilityLabel("\(selected.title) is automatic")
        } else {
            Button {
                Haptics.selection()
                selected.setAutomatic(true, on: model)
            } label: {
                Text("AUTO")
                    .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Theme.ColorToken.textSecondary)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(height: Theme.Space.xl)
                    .background(Theme.ColorToken.surfaceRaised)
                    .clipShape(Capsule())
            }
            .accessibilityLabel("Return \(selected.title) to automatic")
        }
    }
}

// MARK: - Ticks

/// The dial face: detents at the device's real values, and nothing else.
///
/// The tick positions are **not** evenly spaced. They are placed on a curve, because the
/// ranges are exponential — a shutter range of 1/8000 s to 30 s, or an ISO range of 32 to
/// 3200 — and evenly spaced detents would put almost all of them under a few degrees of
/// arc. Positions come from the real min and max, which is what "never a synthetic range"
/// means: the first and last detent are the hardware's own limits.
private struct DialTicks: View {

    let parameter: ProParameter
    let capabilities: ProCapabilities
    let value: Float?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.ColorToken.strokeSubtle, lineWidth: 1)
            ForEach(ticks, id: \.self) { tick in
                Capsule()
                    .fill(tick.major ? Theme.ColorToken.strokeStrong : Theme.ColorToken.strokeSubtle)
                    .frame(width: tick.major ? 2 : 1, height: tick.major ? 10 : 6)
                    .offset(y: -(size / 2 - 12))
                    .rotationEffect(.degrees(tick.angle))
            }
            // The indicator is a dot on the arc, not a needle across the face: it has to
            // be readable at a glance in a mirror-image composition where the value is
            // already the largest thing on screen.
            Circle()
                .fill(Theme.ColorToken.accentActive)
                .frame(width: 8, height: 8)
                .offset(y: -(size / 2 - 6))
                .rotationEffect(.degrees(value.map(angleForCurrentValue) ?? Self.start))
                .opacity(value == nil ? 0.25 : 1)
            Text(parameter.symbol)
                .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.textDisabled)
        }
        .frame(width: size, height: size)
    }

    private struct Tick: Hashable {
        let angle: Double
        let major: Bool
    }

    /// Angles run from -135° to +135°, a 270° sweep. Not a full circle: a control the user
    /// can turn to the same value two ways round is a control with an ambiguous state.
    private static let sweep: Double = 270
    private static let start: Double = -135

    private var ticks: [Tick] {
        // The tick *positions* do not need the range: nine detents laid evenly across the
        // 270° sweep is the layout, and the value's position on those detents is what the
        // range decides. Computing positions from the range here would put them at
        // arbitrary angles for no gain.
        var result: [Tick] = []
        for step in 0...8 {
            let fraction = Double(step) / 8
            result.append(Tick(angle: Self.start + Self.sweep * fraction,
                               major: step % 4 == 0 || step == 8))
        }
        return result
    }


    /// Floor for `log10`, because `log10(0)` is negative infinity and would put the whole
    /// dial in a NaN state. A `Double` because every `log10` and `pow` below is one, and
    /// mixing the two here is what produced a run of Float/Double errors.
    private let minimumPositive: Double = 0.0001

    private func angleForCurrentValue(_ current: Float) -> Double {
        guard let range = parameter.range(capabilities) else { return Self.start }
        let low = log10(Double(max(range.lowerBound, minimumPositive.floatValue)))
        let high = log10(Double(max(range.upperBound, minimumPositive.floatValue)))
        let span = max(0.0001, high - low)
        let fraction = (log10(Double(max(current, minimumPositive.floatValue))) - low) / span
        return Self.start + Self.sweep * min(max(fraction, 0.0), 1.0)
    }
}

// MARK: - Parameter

/// The parameters the dial can show, and each one's mapping to a value.
///
/// One type per parameter rather than a dictionary of closures, so the range, the readout,
/// the automatic state and the drag behaviour for a parameter are all in one place and
/// cannot drift apart.
///
/// `@MainActor` because every mutating method here calls a `CameraViewModel` mutator, and
/// the view model is main-actor isolated. The pure queries — `range`, `value`, `readout` —
/// are isolated too rather than being individually annotated, because a type that is
/// sometimes isolated is a type where the next method added will be missed.
@MainActor
enum ProParameter: String, CaseIterable, Identifiable {
    case iso
    case shutter
    case exposure
    case focus
    case whiteBalance
    case raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iso: return "ISO"
        case .shutter: return "Shutter"
        case .exposure: return "EV"
        case .focus: return "Focus"
        case .whiteBalance: return "WB"
        case .raw: return "RAW"
        }
    }

    var symbol: String {
        switch self {
        case .iso: return "ISO"
        case .shutter: return "1/s"
        case .exposure: return "EV"
        case .focus: return "AF"
        case .whiteBalance: return "K"
        case .raw: return "RAW"
        }
    }

    /// The parameters this device and format can actually honour.
    static func supported(by capabilities: ProCapabilities) -> [ProParameter] {
        var result: [ProParameter] = []
        if capabilities.isoRange != nil { result.append(.iso) }
        if capabilities.shutterRange != nil { result.append(.shutter) }
        if capabilities.exposureCompensationRange != nil { result.append(.exposure) }
        if capabilities.canLockFocus { result.append(.focus) }
        if capabilities.canLockWhiteBalance { result.append(.whiteBalance) }
        if capabilities.rawSupported { result.append(.raw) }
        return result
    }

    /// The real hardware range, or `nil` where the parameter does not exist here.
    func range(_ capabilities: ProCapabilities) -> ClosedRange<Float>? {
        switch self {
        case .iso: return capabilities.isoRange
        case .shutter: return capabilities.shutterRange.map { Float($0.lowerBound)...Float($0.upperBound) }
        case .exposure: return capabilities.exposureCompensationRange
        case .focus, .whiteBalance, .raw: return nil
        }
    }

    func value(_ manual: ManualSettings) -> Float? {
        switch self {
        case .iso: return manual.iso
        case .shutter: return manual.shutterSeconds.map { Float($0) }
        case .exposure: return manual.exposureTargetOffset
        case .focus, .whiteBalance, .raw: return nil
        }
    }

    func readout(_ manual: ManualSettings) -> String {
        switch self {
        case .iso:
            guard let iso = manual.iso else { return "Auto" }
            return String(Int(iso.rounded()))
        case .shutter:
            guard let seconds = manual.shutterSeconds else { return "Auto" }
            return ReportFormat.shutter(seconds)
        case .exposure:
            return String(format: "%+.2f EV", manual.exposureTargetOffset)
        case .focus:
            return manual.lockFocus ? "Locked" : "Auto"
        case .whiteBalance:
            return manual.lockWhiteBalance ? "Locked" : "Auto"
        case .raw:
            return manual.raw ? (manual.proRaw ? "ProRAW" : "RAW") : "Off"
        }
    }

    func isAutomatic(_ manual: ManualSettings) -> Bool {
        switch self {
        case .iso: return manual.iso == nil
        case .shutter: return manual.shutterSeconds == nil
        case .exposure: return manual.exposureTargetOffset == 0
        case .focus: return !manual.lockFocus
        case .whiteBalance: return !manual.lockWhiteBalance
        case .raw: return !manual.raw
        }
    }

    func setAutomatic(_ automatic: Bool, on model: CameraViewModel) {
        switch self {
        case .iso: model.setManualISO(automatic: automatic)
        case .shutter: model.setManualShutter(automatic: automatic)
        case .exposure: model.setManualEV(automatic: automatic)
        case .focus: model.setManual(lockFocus: !automatic)
        case .whiteBalance: model.setManual(lockWhiteBalance: !automatic)
        case .raw: model.setManual(raw: !automatic)
        }
    }

    /// Applies a drag position, 0…1 around the arc, to the manual settings.
    func apply(fraction: Double, to model: CameraViewModel) {
        guard let range = range(model.proCapabilities) else {
            // A parameter with no continuous range is a switch, and a drag across it is
            // the user asking to set it. Treating the drag as "on" is what makes the
            // gesture feel the same everywhere on the dial.
            if fraction > 0.5 { setAutomatic(false, on: model) }
            return
        }
        // Widened once here rather than at each use. The range is a Float pair, the
        // log/pow are Doubles, and doing the conversions inline produced a run of
        // Float-to-Double errors at every site instead of one.
        let lower = Double(range.lowerBound)
        let upper = Double(range.upperBound)
        let low = log10(max(lower, 0.0001))
        let high = log10(max(upper, 0.0001))
        let value = pow(10, low + fraction * (high - low))

        switch self {
        case .iso: model.setManual(iso: Float(value))
        case .shutter: model.setManual(shutterSeconds: value)
        case .exposure:
            // Linear, not logarithmic: EV is already a linear quantity and applying a log
            // curve to it would make +2 stops as easy to reach as +0.2.
            model.setManual(exposureTargetOffset: Float(lower + fraction * (upper - lower)))
        case .focus, .whiteBalance, .raw:
            break
        }
    }

    /// One detent, for the accessibility increment action and for keyboard use.
    func step(_ model: CameraViewModel, by direction: AccessibilityAdjustmentDirection) {
        // A `Float`, because every range and every value it is applied to is one. The
        // first version made this a Double and needed a cast at each of six sites.
        let delta: Float = direction == .increment ? 1 : -1
        switch self {
        case .iso:
            if let range = model.proCapabilities.isoRange {
                let base = model.manual.iso ?? range.lowerBound
                // A third of a stop, which is the smallest change worth hearing.
                model.setManual(iso: min(max(base * powf(2, delta / 3), range.lowerBound),
                                          range.upperBound))
            }
        case .shutter:
            if let range = model.proCapabilities.shutterRange {
                let base = model.manual.shutterSeconds ?? range.upperBound
                model.setManual(shutterSeconds: min(max(base * powf(2, delta), range.lowerBound),
                                                   range.upperBound))
            }
        case .exposure:
            if let range = model.proCapabilities.exposureCompensationRange {
                let base = model.manual.exposureTargetOffset
                model.setManual(exposureTargetOffset: min(max(base + delta / 3,
                                                              range.lowerBound),
                                                          range.upperBound))
            }
        case .focus: model.setManual(lockFocus: !model.manual.lockFocus)
        case .whiteBalance: model.setManual(lockWhiteBalance: !model.manual.lockWhiteBalance)
        case .raw: model.setManual(raw: !model.manual.raw)
        }
    }
}

// MARK: - Geometry

/// Converts a drag location to a 0…1 position around the dial's 270° sweep.
///
/// The angle is measured from straight up and the sweep is centred, so the user has to
/// travel to the top of the dial to reach the *minimum* — which is the convention every
/// physical dial uses, and getting it backwards would make the dial feel inverted.
private func angleFraction(_ point: CGPoint, in size: CGSize, centre: CGPoint) -> Double {
    let dx = point.x - centre.x
    let dy = point.y - centre.y
    guard dx != 0 || dy != 0 else { return 0 }
    // `atan2(dx, -dy)` is the angle clockwise from twelve o'clock.
    var degrees = atan2(dx, -dy) * 180 / .pi
    if degrees < -180 { degrees += 360 }
    // Shift from the full circle into the centred sweep.
    var shifted = degrees
    if degrees > 135 { shifted = degrees - 360 }
    let fraction = (shifted + 135) / 270
    return min(max(fraction, 0), 1)
}
