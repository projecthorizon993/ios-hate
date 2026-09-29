import SwiftUI

/// The Looks mode's contextual controls: one compact chip, which expands in place into
/// the style carousel and the strength slider.
///
/// Same reasoning as `ProChipBar`: this belongs in the bottom stack, not in a sheet. A
/// look is chosen by looking, and a sheet that covers the viewfinder means choosing
/// without seeing. The panel covers the lower part of the viewfinder only, and the
/// processed preview keeps running behind it.
struct LooksChipBar: View {

    @ObservedObject var model: CameraViewModel
    @Binding var expanded: Bool

    /// The chip's label. The look's name when there is one, "Original" when there is not -
    /// which is a real choice the user makes, not an absence.
    private var currentLabel: String {
        model.settings.look?.name ?? "Original"
    }

    private var isActive: Bool { model.settings.look != nil }

    var body: some View {
        // The chip only. The carousel is drawn by `CameraScreen.dockedPanel` over the
        // viewfinder, so this type must not also draw it — the same control appearing
        // twice is worse than one appearing in the wrong place.
        chip
    }

    private var chip: some View {
        Button {
            Haptics.selection()
            expanded.toggle()
        } label: {
            HStack(spacing: Theme.Space.xs) {
                if isActive {
                    Circle()
                        .fill(Theme.ColorToken.accentActive)
                        .frame(width: 6, height: 6)
                }
                Text(currentLabel)
                    .font(.system(size: Theme.TypeSize.label))
                    .foregroundStyle(isActive
                                     ? Theme.ColorToken.textPrimary
                                     : Theme.ColorToken.textSecondary)
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: Theme.TypeSize.caption))
                    .foregroundStyle(Theme.ColorToken.textDisabled)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: Theme.Space.xl + Theme.Space.s)
            .background(Theme.ColorToken.surfaceRaised)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Look, \(currentLabel)")
        .accessibilityValue(isActive
                            ? "\(Int(model.settings.lookIntensity * 100)) percent"
                            : "No look applied")
        .accessibilityHint(expanded ? "Collapses the looks" : "Expands the looks in place")
    }
}

/// The carousel, sized to dock under the chip.
///
/// The `ToneField` and slider controls are **not** here. They were in the sheet, and they
/// are the part of the Looks screen that most needed to be somewhere else: they are for a
/// longer, less frequent adjustment than a look, and they do not need the viewfinder to
/// see. They are on a separate, deliberate gesture away.
struct LooksCarousel: View {

    @ObservedObject var model: CameraViewModel
    @Binding var expanded: Bool

    /// Thumbnail per look, as `UIImage` because that is what the thumbnailer returns.
    @State private var thumbnails: [Look: UIImage] = [:]
    /// A hold, not a toggle, so it has to end when the finger leaves as well as lifts.
    @State private var previewing: Look?

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            strip
            strength
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.ColorToken.surfaceBase)
    }

    // MARK: - Strip

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                tile(look: nil, title: "Original")
                ForEach(model.looks) { look in
                    tile(look: look, title: look.name)
                }
            }
            .padding(.vertical, Theme.Space.xs)
        }
        .frame(height: 68)
    }

    private func tile(look: Look?, title: String) -> some View {
        let isSelected: Bool = look == nil
            ? model.settings.look == nil
            : model.settings.look?.id == look?.id
        let isPreviewing = previewing?.id == look?.id
        let image = look.flatMap { thumbnails[$0] } ?? LookThumbnailer.placeholder()
        return tileBody(image: image, title: title, isSelected: isSelected, isPreviewing: isPreviewing)
            .scaleEffect(isSelected ? 1.0 : 0.85)
            .animation(.spring(response: Theme.Motion.mode, dampingFraction: 0.8), value: isSelected)
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.selection()
                model.select(look: look)
                requestThumbnails()
            }
            // Hold to preview without applying. Tapping applies, and a hold that also
            // applied would mean every "let me just look" changed the photo.
            .onLongPressGesture(minimumDuration: Theme.Motion.tap, maximumDistance: 40) {
                endPreviewing()
            } onPressingChanged: { pressing in
                if pressing { beginPreviewing(look) } else { endPreviewing() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(isSelected ? "Selected" : "")
            .accessibilityHint("Double tap to apply. Touch and hold to preview.")
    }

    private func tileBody(image: UIImage,
                          title: String,
                          isSelected: Bool,
                          isPreviewing: Bool) -> some View {
        // A ZStack rather than stacked `overlay` calls: `overlay(alignment:)` resolves
        // against the concrete view type, which is erased behind a `some View` return.
        let side: CGFloat = 48
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control)
        let border: Color = isSelected
            ? Theme.ColorToken.accentActive
            : Theme.ColorToken.strokeSubtle

        return VStack(spacing: Theme.Space.xxs) {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(shape)
                    .overlay(shape.stroke(border, lineWidth: isSelected ? 2 : 1))
                if isPreviewing {
                    Circle()
                        .fill(Theme.ColorToken.accentCompare)
                        .frame(width: 8, height: 8)
                        .padding(Theme.Space.xxs)
                }
            }
            Text(title)
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(isSelected
                                 ? Theme.ColorToken.textPrimary
                                 : Theme.ColorToken.textSecondary)
                .lineLimit(1)
                .frame(width: side)
        }
    }

    // MARK: - Strength

    @ViewBuilder
    private var strength: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Strength")
                .font(.system(size: Theme.TypeSize.caption))
                .foregroundStyle(Theme.ColorToken.textDisabled)
                .frame(width: 52, alignment: .leading)

            Slider(value: Binding(get: { model.settings.lookIntensity },
                                  set: { model.setLookIntensity($0) }),
                   in: 0...1)
                .tint(Theme.ColorToken.accentActive)
                .accessibilityLabel("Look strength")
                .accessibilityValue("\(Int(model.settings.lookIntensity * 100)) percent")

            Text("\(Int(model.settings.lookIntensity * 100))")
                .font(.system(size: Theme.TypeSize.caption, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.textSecondary)
                .frame(width: 24, alignment: .trailing)
        }
        // A strength slider with nothing to be the strength of is a control that does
        // nothing, so it is absent rather than disabled.
        .opacity(model.settings.look == nil ? 0.35 : 1)
        .disabled(model.settings.look == nil)
        .accessibilityHidden(model.settings.look == nil)
    }

    // MARK: - Preview and thumbnails

    private func beginPreviewing(_ look: Look?) {
        previewing = look
        var temporary = model.settings
        temporary.look = look
        if look == nil { temporary.lookIntensity = 0 }
        model.previewOnly(temporary)
        Haptics.selection()
    }

    private func endPreviewing() {
        guard previewing != nil else { return }
        previewing = nil
        model.previewOnly(model.settings)
    }

    private func requestThumbnails() {
        guard !model.looks.isEmpty else { return }
        guard let frame = model.processedPreview.lastStill() else { return }
        LookThumbnailer.render(looks: model.looks, source: frame, recipe: model.settings) {
            thumbnails = $0
        }
    }
}
