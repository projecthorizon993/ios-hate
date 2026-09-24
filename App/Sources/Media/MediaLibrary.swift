import Combine
import Foundation
import UIKit

struct MediaItem: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    let originalURL: URL
    let enhancedURL: URL
    let sourceURLs: [URL]
    let metadata: [String: String]
}

@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    private let fileManager = FileManager.default
    private let rootURL: URL
    private let indexURL: URL

    init() {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootURL = applicationSupport.appendingPathComponent("LumaFrame/Media", isDirectory: true)
        indexURL = rootURL.appendingPathComponent("index.json")
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        load()
    }

    func savePhoto(data: Data, enhancedData: Data, grade: GradeSettings, metadata: [String: String]) {
        let id = UUID()
        var storedMetadata = metadata
        storedMetadata["grade"] = encodedGrade(grade)
        let originalURL = rootURL.appendingPathComponent("\(id.uuidString)-original.jpg")
        let enhancedURL = rootURL.appendingPathComponent("\(id.uuidString)-enhanced.jpg")
        try? data.write(to: originalURL, options: .atomic)
        try? enhancedData.write(to: enhancedURL, options: .atomic)
        let item = MediaItem(
            id: id,
            createdAt: Date(),
            originalURL: originalURL,
            enhancedURL: enhancedURL,
            sourceURLs: [originalURL],
            metadata: storedMetadata
        )
        items.insert(item, at: 0)
        persist()
    }

    func saveBracket(originals: [Data], enhancedData: Data, grade: GradeSettings, metadata: [String: String]) {
        let id = UUID()
        var storedMetadata = metadata
        storedMetadata["grade"] = encodedGrade(grade)
        let urls = originals.enumerated().map { index, data -> URL in
            let url = rootURL.appendingPathComponent("\(id.uuidString)-source-\(index + 1).jpg")
            try? data.write(to: url, options: .atomic)
            return url
        }
        let originalURL = urls.first ?? rootURL.appendingPathComponent("\(id.uuidString)-original.jpg")
        let enhancedURL = rootURL.appendingPathComponent("\(id.uuidString)-enhanced.jpg")
        try? enhancedData.write(to: enhancedURL, options: .atomic)
        items.insert(MediaItem(id: id, createdAt: Date(), originalURL: originalURL, enhancedURL: enhancedURL, sourceURLs: urls, metadata: storedMetadata), at: 0)
        persist()
    }

    func delete(_ item: MediaItem) {
        ([item.originalURL, item.enhancedURL] + item.sourceURLs).forEach { try? fileManager.removeItem(at: $0) }
        items.removeAll { $0.id == item.id }
        persist()
    }

    func image(for item: MediaItem, enhanced: Bool) -> UIImage? {
        UIImage(contentsOfFile: (enhanced ? item.enhancedURL : item.originalURL).path)
    }

    private func encodedGrade(_ grade: GradeSettings) -> String {
        guard let data = try? JSONEncoder().encode(grade) else { return "" }
        return data.base64EncodedString()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL), let stored = try? JSONDecoder().decode([MediaItem].self, from: data) else { return }
        items = stored.filter { fileManager.fileExists(atPath: $0.enhancedURL.path) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
