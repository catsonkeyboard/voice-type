import Foundation
import SwiftData

@Model
final class TranscriptRecord {
    var text: String
    var createdAt: Date
    var durationSeconds: Double
    var source: String  // "dictation" | "file" | "pet"
    var rawText: String?  // 润色前原始转写；未润色为 nil

    init(
        text: String, createdAt: Date = .now, durationSeconds: Double = 0,
        source: String = "dictation", rawText: String? = nil
    ) {
        self.text = text
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.source = source
        self.rawText = rawText
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

    func add(text: String, durationSeconds: Double, source: String, rawText: String? = nil) {
        context.insert(
            TranscriptRecord(
                text: text, durationSeconds: durationSeconds, source: source, rawText: rawText))
        try? context.save()
        trim()
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

    /// 只保留最近 maxRecords 条：先 count 判断是否超限，
    /// 超限时仅 fetch 待删除的 offset 区间（倒序第 maxRecords 条之后），不全表拉取
    private func trim() {
        let count = (try? context.fetchCount(FetchDescriptor<TranscriptRecord>())) ?? 0
        guard count > maxRecords else { return }
        var descriptor = FetchDescriptor<TranscriptRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchOffset = maxRecords
        descriptor.fetchLimit = count - maxRecords
        let overflow = (try? context.fetch(descriptor)) ?? []
        for record in overflow {
            context.delete(record)
        }
        if !overflow.isEmpty {
            try? context.save()
        }
    }
}
