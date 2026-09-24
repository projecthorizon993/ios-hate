import SwiftUI

struct GradeControlsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GradeSlider(title: "Exposure", value: binding(\.exposure), range: -2...2, format: "%+.2f")
                    GradeSlider(title: "Contrast", value: binding(\.contrast), range: 0.5...1.5, format: "%.2f")
                    GradeSlider(title: "Highlights", value: binding(\.highlights), range: 0...1, format: "%.2f")
                    GradeSlider(title: "Shadows", value: binding(\.shadows), range: 0...1, format: "%.2f")
                    GradeSlider(title: "Whites", value: binding(\.whites), range: 0...1, format: "%.2f")
                    GradeSlider(title: "Blacks", value: binding(\.blacks), range: 0...1, format: "%.2f")
                    GradeSlider(title: "Temperature", value: binding(\.temperature), range: -1...1, format: "%+.2f")
                    GradeSlider(title: "Tint", value: binding(\.tint), range: -1...1, format: "%+.2f")
                    GradeSlider(title: "Saturation", value: binding(\.saturation), range: 0...1.5, format: "%.2f")
                    GradeSlider(title: "Vibrance", value: binding(\.vibrance), range: -1...1, format: "%+.2f")
                    GradeSlider(title: "Sharpen", value: binding(\.sharpen), range: 0...1, format: "%.2f")
                    GradeSlider(title: "Halation", value: binding(\.halation), range: 0...1, format: "%.2f")
                    GradeSlider(title: "Vignette", value: binding(\.vignette), range: 0...1, format: "%.2f")
                    Button {
                        viewModel.savePreset()
                    } label: {
                        Label("Save as custom preset", systemImage: "plus.circle.fill")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }
            .navigationTitle("Live grade")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<GradeSettings, Double>) -> Binding<Double> {
        Binding(
            get: { viewModel.grade[keyPath: keyPath] },
            set: { viewModel.grade[keyPath: keyPath] = $0 }
        )
    }
}

private struct GradeSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .tint(.white)
        }
    }
}
