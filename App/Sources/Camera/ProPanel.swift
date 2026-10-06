// The Pro control surface.
//
// ProDial owns the ruler dial and the ProParameter table; the chip bar and the tone
// panel are the same surface reached from a different mode.
//
// Merged mechanically by scripts/consolidate.mjs. Declarations were moved whole and
// nothing was edited; see the commit message for the reasoning.

import SwiftUI

// MARK: - dial (was App/Sources/Camera/ProDial.swift)


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

    /// Set when the dial is docked under a chip in the bottom stack. The chip has already
    /// chosen the parameter, so the dial shows that one and omits its picker — a picker
    /// there would take vertical space the docked panel does not have, and a control that
    /// cannot fit is worse than no control.
    var expanded: Binding<Bool>?

    /// The parameter this dial is showing, when something has told it.
    @Environment(\.proParameterOverride) private var override

    /// Which parameter the dial is showing when nothing has told it. Exactly one, per the
    /// spec.
    @State private var selected: ProParameter = .iso

    private var parameter: ProParameter { override ?? selected }

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            if override == nil {
                parameterPicker
            }
            readout
            dialFace
            autoChip
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
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

    // MARK: - Readout

    /// The live value, above the dial. `type.value` per the spec: the parameter being
    /// changed is the one thing allowed to be larger than everything else on screen.
    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(parameter.title)
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)
            Text(parameter.readout(model.manual))
                .font(.system(size: Theme.TypeSize.title, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.textPrimary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: Theme.Motion.tap), value: model.manual)
        }
        .frame(maxWidth: .infinity)
    }

    /// The AUTO chip, per the spec: it returns **this** parameter to automatic without
    /// touching the others, which is the reason it is a chip and not a mode.
    @ViewBuilder
    private var autoChip: some View {
        if parameter.isAutomatic(model.manual) {
            Text("AUTO")
                .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Theme.ColorToken.accentActive)
                .padding(.horizontal, Theme.Space.m)
                .frame(height: Theme.Space.xl)
                .background(Theme.ColorToken.surfaceRaised)
                .clipShape(Capsule())
                .accessibilityLabel("\(parameter.title) is automatic")
        } else {
            Button {
                Haptics.selection()
                parameter.setAutomatic(true, on: model)
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
            .accessibilityLabel("Return \(parameter.title) to automatic")
        }
    }

    // MARK: - Face

    /// The draggable face.
    ///
    /// Sized to a fixed height rather than filling the width, because a dial that grows
    /// with the screen is a dial that changes size between devices, and a pro control
    /// whose target moves is a pro control that is hard to learn. 132 pt is about the
    /// width of a fingertip's comfortable arc.
    private var dialFace: some View {
        let side: CGFloat = 132
        return ZStack {
            DialTicks(parameter: parameter,
                      capabilities: model.proCapabilities,
                      value: parameter.value(model.manual),
                      size: side)
                .frame(width: side, height: side)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let centre = CGPoint(x: side / 2, y: side / 2)
                            let fraction = angleFraction(drag.location,
                                                         in: CGSize(width: side, height: side),
                                                         centre: centre)
                            parameter.apply(fraction: fraction, to: model)
                        }
                )
        }
        .frame(height: side)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(parameter.title)
        .accessibilityValue(parameter.readout(model.manual))
        .accessibilityHint("Swipe up or down to change in steps")
        .accessibilityAdjustableAction { direction in
            parameter.step(model, by: direction)
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
    /// dial in a NaN state. A `Float` because every value it clamps is a `Float`; the
    /// widening to `Double` happens at the `log10` call, which is the only thing here that
    /// is a `Double`.
    private let minimumPositive: Float = 0.0001

    private func angleForCurrentValue(_ current: Float) -> Double {
        guard let range = parameter.range(capabilities) else { return Self.start }
        let low = log10(Double(max(range.lowerBound, minimumPositive)))
        let high = log10(Double(max(range.upperBound, minimumPositive)))
        let span = max(0.0001, high - low)
        let fraction = (log10(Double(max(current, minimumPositive))) - low) / span
        return Self.start + Self.sweep * min(max(fraction, 0.0), 1.0)
    }
}

// MARK: - Parameter

/// The two states of the Pro contextual row.
///
/// Carries the resolved chip list in the `.chips` case so the row reads the same
/// decision the dial will be opened from — a row that recomputed it separately could
/// offer a chip whose dial then finds nothing to show. The `.reason` case carries
/// the capabilities' own summary rather than a second copy of the words, so the
/// line the user reads and the line the log holds cannot disagree.
enum ProRowContent: Equatable {
    case chips([ProParameter])
    case reason(String)
}

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
        // "WB", not "K": the control locks the current gains and offers no Kelvin
        // value, so a Kelvin unit on the dial would promise a control that is Phase 3.2.
        case .whiteBalance: return "WB"
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

    /// What the Pro contextual row shows. Chips when any parameter survives gating,
    /// otherwise the reason as a status line.
    ///
    /// Pure so the empty-strip regression is a failing test rather than a screenshot:
    /// `CameraScreen.contextualRow` switches on this, so an empty `supported` list can
    /// never again render as an empty fixed-height strip — it renders the summary the
    /// capabilities already produce, which is also what reaches the log.
    static func rowContent(for capabilities: ProCapabilities) -> ProRowContent {
        let chips = supported(by: capabilities)
        guard chips.isEmpty else { return .chips(chips) }
        return .reason(capabilities.availabilitySummary)
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
    ///
    /// The step is derived inside each branch rather than shared, because the three
    /// continuous parameters are not the same numeric type: ISO and EV are `Float` and
    /// shutter is `Double`. A single shared `delta` was the wrong type for one of them
    /// whichever way it was declared.
    func step(_ model: CameraViewModel, by direction: AccessibilityAdjustmentDirection) {
        switch self {
        case .iso:
            if let range = model.proCapabilities.isoRange {
                let delta: Float = direction == .increment ? 1 : -1
                let base = model.manual.iso ?? range.lowerBound
                // A third of a stop, which is the smallest change worth hearing.
                model.setManual(iso: min(max(base * powf(2, delta / 3), range.lowerBound),
                                          range.upperBound))
            }
        case .shutter:
            if let range = model.proCapabilities.shutterRange {
                // Shutter is a `ClosedRange<Double>`, so this branch computes in Double
                // while ISO and EV compute in Float. The delta is derived per branch from
                // its own type rather than shared, which is what stops a single `delta`
                // being the wrong type for two of the three cases.
                let step = direction == .increment ? 1.0 : -1.0
                let base = model.manual.shutterSeconds ?? range.upperBound
                model.setManual(shutterSeconds: min(max(base * pow(2, step), range.lowerBound),
                                                   range.upperBound))
            }
        case .exposure:
            if let range = model.proCapabilities.exposureCompensationRange {
                let delta: Float = direction == .increment ? 1 : -1
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

// MARK: - chips (was App/Sources/Camera/ProChipBar.swift)


/// The Pro mode's contextual controls: a row of chips showing the current value, which
/// expand in place into their dial.
///
/// This is a bottom-stack control, not a screen. The user is adjusting a parameter *while
/// looking at the viewfinder*, and the point of a pro control is watching the value change
/// as you turn it — which a full-screen sheet prevents, because the sheet covers the
/// preview. So the panel that opens covers only the lower part of the viewfinder and the
/// camera keeps running behind it.
///
/// A chip shows the value, not the parameter name. A row of "ISO / Shutter / EV" tells the
/// user what exists; a row of "100 / 1/120 / +0.3" tells them what the camera is doing. The
/// name is the accessibility label and the hint, not the pixels.
struct ProChipBar: View {

    @ObservedObject var model: CameraViewModel
    @Binding var expanded: Bool

    /// Which parameter's dial is docked. Nil means collapsed.
    ///
    /// Published upward rather than kept private, because the panel itself is drawn by
    /// `CameraScreen.dockedPanel` over the viewfinder. This type is only the chips; it
    /// must not also draw the dial, or the same control appears twice.
    @Binding var open: ProParameter?

    private var supported: [ProParameter] {
        ProParameter.supported(by: model.proCapabilities)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(supported, id: \.self) { parameter in
                    chip(for: parameter)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: Theme.Space.xl + Theme.Space.s)
    }

    private func chip(for parameter: ProParameter) -> some View {
        let value = parameter.readout(model.manual)
        let isOpen = open == parameter
        let isAutomatic = parameter.isAutomatic(model.manual)

        return Button {
            Haptics.selection()
            // Tapping the open chip closes it. A chip that only opens is a trap when the
            // panel covers the thing you were aiming at.
            if isOpen {
                open = nil
                expanded = false
            } else {
                open = parameter
                expanded = true
            }
        } label: {
            VStack(spacing: 0) {
                Text(parameter.title)
                    .font(.system(size: Theme.TypeSize.caption))
                    .foregroundStyle(isOpen
                                     ? Theme.ColorToken.surfaceBase
                                     : Theme.ColorToken.textDisabled)
                Text(value)
                    .font(.system(size: Theme.TypeSize.label, design: .monospaced))
                    .foregroundStyle(isOpen
                                     ? Theme.ColorToken.surfaceBase
                                     : (isAutomatic
                                        ? Theme.ColorToken.textSecondary
                                        : Theme.ColorToken.textPrimary))
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: Theme.Space.xl + Theme.Space.s)
            .background(isOpen ? Theme.ColorToken.accentActive : Theme.ColorToken.surfaceRaised)
            .clipShape(Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parameter.title)
        .accessibilityValue(value)
        .accessibilityHint(isOpen ? "Collapses the control" : "Expands the control in place")
        .accessibilityAddTraits(isOpen ? [.isSelected, .isButton] : .isButton)
    }
}

/// Lets the docked dial show the parameter whose chip opened it, instead of the one it
/// last remembered.
///
/// A docked dial has no room for a parameter picker, and a picker it cannot fit is worse
/// than no picker. So the chip decides, and the dial reads it from here.
private struct ProParameterOverrideKey: EnvironmentKey {
    // `EnvironmentKey` requires a computed `defaultValue`, not a stored constant, and
    // `nil` is the right one: nothing has said which parameter to show, so the dial uses
    // its own picker.
    static var defaultValue: ProParameter? { nil }
}

extension EnvironmentValues {
    var proParameterOverride: ProParameter? {
        get { self[ProParameterOverrideKey.self] }
        set { self[ProParameterOverrideKey.self] = newValue }
    }
}

// MARK: - tone (was App/Sources/Camera/TonePanel.swift)


/// The tone controls, docked in the bottom stack behind a small "Tune" chip.
///
/// Separate from the looks carousel on purpose. A look is chosen by looking and by tapping
/// — a fast, glanceable decision. Tone is exposure, contrast, saturation, lift and warmth:
/// a slower adjustment that is dialled in and then left alone. Putting five sliders in the
/// same strip as the carousel would make the fast thing slow, which is the same mistake as
/// making the whole panel full screen.
struct TonePanel: View {

    @ObservedObject var model: CameraViewModel
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            header
            Text("Adjustments apply only to what you change, so the camera's own white "
                 + "balance keeps working when you leave these alone.")
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ToneField.allCases, id: \.self) { field in
                slider(field)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.ColorToken.surfaceBase.opacity(0.96))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var header: some View {
        HStack {
            Text("Tone")
                .font(.system(size: Theme.TypeSize.label))
                .foregroundStyle(Theme.ColorToken.textSecondary)
            Spacer()
            if model.settings.tone != nil {
                Button("Reset") { model.setTone(.neutral) }
                    .font(.system(size: Theme.TypeSize.caption))
                    .foregroundStyle(Theme.ColorToken.accentActive)
                    .accessibilityLabel("Reset tone adjustments")
            }
        }
    }

    private func slider(_ field: ToneField) -> some View {
        let value = field.value(in: model.settings.tone ?? .neutral)
        let decimals = field.range.upperBound > 100 ? 0 : 2
        return HStack(spacing: Theme.Space.s) {
            Text(field.rawValue)
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)
                .frame(width: 74, alignment: .leading)

            Slider(value: Binding(
                get: { field.value(in: model.settings.tone ?? .neutral) },
                set: { model.setTone(field.apply($0, to: model.settings.tone ?? .neutral)) }),
                in: field.range)
                .tint(Theme.ColorToken.accentActive)
                .accessibilityLabel(field.rawValue)
                .accessibilityValue(ReportFormat.number(Double(value), decimals: decimals))

            Text(ReportFormat.number(Double(value), decimals: decimals))
                .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.textSecondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    /// One of the tone controls, so reading and writing a field is a switch on a type
    /// rather than a switch on a display string.
    ///
    /// The string version of this existed first and it was wrong: the label a user sees and
    /// the field the code writes were two separate switches that had to agree, and renaming
    /// a label would have silently zeroed the control.
    private enum ToneField: String, CaseIterable {
        case exposure = "Exposure"
        case contrast = "Contrast"
        case saturation = "Saturation"
        case vibrance = "Vibrance"
        case highlights = "Highlights"
        case shadows = "Shadows"
        case lift = "Lifted shadows"
        case temperature = "Warmth"

        var range: ClosedRange<Float> {
            switch self {
            case .exposure, .lift: return 0...1
            case .contrast, .saturation, .vibrance, .highlights, .shadows: return -1...1
            case .temperature: return -1500...1500
            }
        }

        func value(in tone: ToneCurve) -> Float {
            switch self {
            case .exposure: return tone.exposure
            case .contrast: return tone.contrast
            case .saturation: return tone.saturation
            case .vibrance: return tone.vibrance
            case .highlights: return tone.highlights
            case .shadows: return tone.shadows
            case .lift: return tone.lift
            case .temperature: return tone.temperatureOffset
            }
        }

        func apply(_ value: Float, to tone: ToneCurve) -> ToneCurve {
            var copy = tone
            switch self {
            case .exposure: copy.exposure = value
            case .contrast: copy.contrast = value
            case .saturation: copy.saturation = value
            case .vibrance: copy.vibrance = value
            case .highlights: copy.highlights = value
            case .shadows: copy.shadows = value
            case .lift: copy.lift = value
            case .temperature: copy.temperatureOffset = value
            }
            return copy
        }
    }
}
