import Combine
import Foundation

@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [ColorGradePreset]
    private let storageKey = "com.lumaframe.custom-presets"

    init() {
        let stored = UserDefaults.standard.data(forKey: storageKey)
        let custom = stored.flatMap { try? JSONDecoder().decode([ColorGradePreset].self, from: $0) } ?? []
        presets = ColorGradePreset.builtIns + custom
    }

    func saveCustom(name: String, grade: GradeSettings) {
        let preset = ColorGradePreset(name: name.isEmpty ? "Custom Grade" : name, grade: grade)
        presets.append(preset)
        persist()
    }

    func delete(_ preset: ColorGradePreset) {
        guard !preset.isBuiltIn else { return }
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    func replace(_ preset: ColorGradePreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        persist()
    }

    private func persist() {
        let custom = presets.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
