import SwiftUI

/// Step 3's screen: the style carousel, its strength slider, and the tone controls.
///
/// `DESIGN_SPEC.md` asks for a horizontal carousel with live thumbnails, the selected item
/// scaled 1.0 and the rest 0.85, and a strength slider below. A vertical list of names
/// cannot show what a look *does*, and picking a look you cannot see is the whole problem
/// this screen exists to solve — so the thumbnails are rendered from the actual preview
/// frame rather than shipped as assets, and they are real.
///
/// The layout is a sheet over the viewfinder rather than a screen replacement, so the
/// frame being transformed stays visible while it is being changed.
struct LooksScreen: View {

    @ObservedObject var model: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    /// Thumbnail per look. Absent until the first render, so the strip shows placeholders
    /// rather than nothing.
    ///
    /// Stored as `UIImage` rather than `Image` because that is what the thumbnailer hands
    /// back. Converting at the boundary keeps the async hop from crossing a `Sendable`
    /// boundary with a SwiftUI view value in it.
    @State private var thumbnails: [Look: UIImage] = [:]
    /// A long press is a hold, not a toggle, and it has to be released when the finger
    /// leaves the screen as well as when it lifts.
    @State private var comparingLook: Look?

    var body: some View {
        VStack(spacing: 0) {
            carousel
            strength
            tone
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.l)
        .background(Theme.ColorToken.surfaceBase)
        .navigationTitle("Looks")
        .navigationBarTitleDisplayMode(.inline)
        .task { requestThumbnails() }
        .onChange(of: model.previewRedrawToken) { _, _ in requestThumbnails() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Looks")
    }

    // MARK: - Carousel

    private var carousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                // Original is first and is the way back. It is a tile like any other rather
                // than a separate control, because the user is choosing among looks and
                // the choice "none" belongs in the same list.
                carouselTile(look: nil, title: "Original")
                ForEach(model.looks) { look in
                    carouselTile(look: look, title: look.name)
                }
            }
            .padding(.horizontal, Theme.Space.l)
        }
        .scrollClipDisabled()
    }

    private func carouselTile(look: Look?, title: String) -> some View {
        // The selection and the thumbnail are worked out first, as plain values, rather
        // than inline in the view. The tile is a large expression tree over an optional
        // `Look`, and inlining it defeated the type checker's budget — the whole tile
        // failed to compile rather than one part of it being reported.
        let isSelected: Bool
        if let look {
            isSelected = model.settings.look?.id == look.id
        } else {
            isSelected = model.settings.look == nil
        }
        let isComparing: Bool = comparingLook?.id == look?.id
        let rendered: UIImage = look.flatMap { thumbnails[$0] } ?? LookThumbnailer.placeholder()
        let borderColour = isSelected ? Theme.ColorToken.accentActive : Theme.ColorToken.strokeSubtle
        let labelColour = isSelected ? Theme.ColorToken.textPrimary : Theme.ColorToken.textSecondary
        let side = LookThumbnailer.size

        return VStack(spacing: Theme.Space.xs) {
            rendered
                .resizable()
                .aspectRatio(1, contentMode: .fill)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .stroke(borderColour, lineWidth: isSelected ? 2 : 1))
                .overlay(alignment: .topTrailing) {
                    if isComparing {
                        Image(systemName: "eye")
                            .font(.system(size: Theme.TypeSize.caption))
                            .foregroundStyle(Theme.ColorToken.accentCompare)
                            .padding(Theme.Space.xs)
                            .background(Circle().fill(Theme.ColorToken.surfaceBase.opacity(0.7)))
                            .padding(Theme.Space.xs)
                    }
                }

            Text(title)
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(labelColour)
                .lineLimit(1)
                .frame(width: side)
        }
        // The scale is the selection affordance the spec calls for: 1.0 selected, 0.85
        // otherwise, so the eye finds the current look without reading the border.
        .scaleEffect(isSelected ? 1.0 : 0.85)
        .opacity(isSelected ? 1.0 : 0.75)
        .animation(.spring(response: Theme.Motion.mode, dampingFraction: 0.8), value: isSelected)
        .contentShape(Rectangle())
        .onTapGesture { select(look) }
        // Hold to preview this look without committing to it. A tap-to-select followed by
        // a separate preview control is two steps for one question.
        .onLongPressGesture(minimumDuration: Theme.Motion.tap, maximumDistance: 40) {
            // Completed long press: end the preview and leave the look selected.
            endComparing()
        } onPressingChanged: { pressing in
            if pressing { beginComparing(look) } else { endComparing() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Double tap to apply. Touch and hold to preview without applying.")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func select(_ look: Look?) {
        Haptics.selection()
        model.select(look: look)
        requestThumbnails()
    }

    private func beginComparing(_ look: Look?) {
        // A look preview is a temporary recipe, so it must not disturb the real one — the
        // user may be holding a look they have not chosen yet.
        comparingLook = look
        model.previewOnly(settingsFor(look))
        Haptics.selection()
    }

    private func endComparing() {
        guard comparingLook != nil else { return }
        comparingLook = nil
        model.previewOnly(model.settings)
    }

    private func settingsFor(_ look: Look?) -> ProcessingSettings {
        var one = model.settings
        one.look = look
        if look == nil { one.lookIntensity = 0 }
        return one
    }

    // MARK: - Strength

    @ViewBuilder
    private var strength: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text("Strength")
                    .font(.system(size: Theme.TypeSize.label))
                    .foregroundStyle(Theme.ColorToken.textSecondary)
                Spacer()
                Text("\(Int(model.settings.lookIntensity * 100))%")
                    .font(.system(size: Theme.TypeSize.value, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.textPrimary)
            }
            Slider(value: Binding(get: { model.settings.lookIntensity },
                                  set: { model.setLookIntensity($0) }),
                   in: 0...1)
                .tint(Theme.ColorToken.accentActive)
                .accessibilityLabel("Look strength")
                .accessibilityValue("\(Int(model.settings.lookIntensity * 100)) percent")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.m)
        // A strength slider with nothing to be the strength of is a control that does
        // nothing, so it is absent rather than disabled.
        .opacity(model.settings.look == nil ? 0.35 : 1)
        .disabled(model.settings.look == nil)
        .accessibilityHidden(model.settings.look == nil)
    }

    // MARK: - Tone

    /// One of the tone controls, so reading and writing a field is a switch on a type
    /// rather than a switch on a display string.
    ///
    /// The string version of this existed first and it was wrong: it meant the label a user
    /// sees and the field the code writes were two separate switches that had to agree, and
    /// renaming a label would have silently zeroed the control.
    private enum ToneField: String, CaseIterable {
        case exposure = "Exposure"
        case contrast = "Contrast"
        case saturation = "Saturation"
        case lift = "Lifted shadows"
        case temperature = "Warmth"

        var range: ClosedRange<Float> {
            switch self {
            case .exposure, .lift: return 0...1
            case .contrast, .saturation: return -1...1
            case .temperature: return -1500...1500
            }
        }

        /// The signed fields get a neutral midpoint; the unsigned ones do not, so the
        /// slider is drawn where the value actually lives rather than with a dead half.
        var isBipolar: Bool {
            switch self {
            case .contrast, .saturation, .temperature: return true
            case .exposure, .lift: return false
            }
        }

        func value(in tone: ToneCurve) -> Float {
            switch self {
            case .exposure: return tone.exposure
            case .contrast: return tone.contrast
            case .saturation: return tone.saturation
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
            case .lift: copy.lift = value
            case .temperature: copy.temperatureOffset = value
            }
            return copy
        }
    }

    private var tone: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
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

            Text("Adjustments apply only to what you change, so the camera's own white balance keeps working when you leave these alone.")
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ToneField.allCases, id: \.self) { field in
                toneSlider(field)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.m)
    }

    private func toneSlider(_ field: ToneField) -> some View {
        let value = field.value(in: model.settings.tone ?? .neutral)
        let decimals = field.range.upperBound > 100 ? 0 : 2

        return VStack(spacing: Theme.Space.xxs) {
            HStack {
                Text(field.rawValue)
                    .font(.system(size: Theme.TypeSize.caption))
                    .foregroundStyle(Theme.ColorToken.textDisabled)
                Spacer()
                Text(ReportFormat.number(Double(value), decimals: decimals))
                    .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                    .foregroundStyle(Theme.ColorToken.textSecondary)
            }
            Slider(value: Binding(
                get: { field.value(in: model.settings.tone ?? .neutral) },
                set: { model.setTone(field.apply($0, to: model.settings.tone ?? .neutral)) }),
                in: field.range)
                .tint(Theme.ColorToken.accentActive)
                .accessibilityLabel(field.rawValue)
                .accessibilityValue(ReportFormat.number(Double(value), decimals: decimals))
        }
    }

    // MARK: - Thumbnails

    /// Asks for thumbnails from the current preview frame.
    ///
    /// Rate-limited inside the thumbnailer, so calling this on every redraw token is cheap
    /// and there is no timer to own here. Returns nothing when there is no frame yet,
    /// which is why the strip shows placeholders rather than nothing.
    private func requestThumbnails() {
        guard !model.looks.isEmpty else { return }
        guard let frame = model.processedPreview.lastStill() else { return }

        LookThumbnailer.render(looks: model.looks,
                               source: frame,
                               recipe: model.settings) { result in
            thumbnails = result
        }
    }
}
