import Foundation
import SwiftData

@Model
final class TranscriptRecord {
    var text: String
    var createdAt: Date
    var durationSeconds: Double
    var source: String  // "dictation" | "file"

    init(text: String, createdAt: Date = .now, durationSeconds: Double = 0, source: String = "dictation") {
        self.text = text
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.source = source
    }
}

@MainActor
final class HistoryStore {
    private let container: ModelContainer  // 必须持有，否则 context 悬空
    private let context: ModelContext
    private let maxRecords: Int

    init(container: ModelContainer, maxRecords: Int = 200) {
        self.container = container
        self.context = container.mainContext
        self.maxRecords = maxRecords
    }

    func add(text: String, durationSeconds: Double, source: String) {
        context.insert(
            TranscriptRecord(text: text, durationSeconds: durationSeconds, source: source))
        try? context.save()
        trim()
        try? context.save()
    }

    func recent(limit: Int = 50) -> [TranscriptRecord] {
        var descriptor = FetchDescriptor<TranscriptRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    func delete(_ record: TranscriptRecord) {
        context.delete(record)
        try? context.save()
    }

    func clear() {
        try? context.delete(model: TranscriptRecord.self)
        try? context.save()
    }

    private func trim() {
        let all = (try? context.fetch(
            FetchDescriptor<TranscriptRecord>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        for record in all.dropFirst(maxRecords) {
            context.delete(record)
        }
    }
}
