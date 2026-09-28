import SwiftUI

/// Renders one report section. Kept separate from `ReportScreen` so a report with
/// nine sections does not produce a nine-hundred-line view body.
struct ReportSectionView: View {
    let section: ReportSection

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(section.title)
                .font(.system(size: Theme.TypeSize.title, weight: .semibold))
                .foregroundStyle(Theme.ColorToken.textPrimary)
                .accessibilityAddTraits(.isHeader)

            if section.entries.isEmpty {
                Text("No entries")
                    .font(.system(size: Theme.TypeSize.label))
                    .foregroundStyle(Theme.ColorToken.textDisabled)
            } else {
                ForEach(section.entries) { entry in
                    ReportEntryRow(entry: entry)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .background(Theme.ColorToken.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
    }
}

/// One line. Monospaced and selectable so individual values can be copied by hand if
/// the share sheet is inconvenient.
struct ReportEntryRow: View {
    let entry: ReportEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            if !entry.level.marker.isEmpty {
                Text(entry.level.marker)
                    .font(.system(size: Theme.TypeSize.mono, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                    .frame(width: Theme.Space.m, alignment: .leading)
                    .accessibilityHidden(true)
            }
            Text(entry.label)
                .font(.system(size: Theme.TypeSize.mono, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            Text(entry.value)
                .font(.system(size: Theme.TypeSize.mono, design: .monospaced))
                .foregroundStyle(Theme.ColorToken.textPrimary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.label), \(entry.value)")
    }

    private var color: Color {
        switch entry.level {
        case .info: return Theme.ColorToken.textSecondary
        case .good: return Theme.ColorToken.accentActive
        case .note: return Theme.ColorToken.accentCompare
        case .warn: return Theme.ColorToken.stateWarn
        case .fail: return Theme.ColorToken.stateError
        }
    }
}
