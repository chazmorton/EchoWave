import Foundation

struct TranscriptRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let text: String
    let date: Date
    let duration: TimeInterval
}

/// Recent transcripts, stored locally in ~/Library/Application Support/EchoWave/history.json.
@MainActor
final class TranscriptHistory: ObservableObject {
    static let shared = TranscriptHistory()

    @Published private(set) var items: [TranscriptRecord] = []

    private let limit = 200
    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = support.appendingPathComponent("EchoWave", isDirectory: true).appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([TranscriptRecord].self, from: data) {
            items = saved
        }
    }

    func add(_ text: String, duration: TimeInterval) {
        items.insert(TranscriptRecord(id: UUID(), text: text, date: Date(), duration: duration), at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        save()
    }

    func remove(_ record: TranscriptRecord) {
        items.removeAll { $0.id == record.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("EchoWave: couldn't save history: \(error.localizedDescription)")
        }
    }
}
