import SwiftData
import XCTest

@testable import VoiceType

@MainActor
final class HistoryStoreTests: XCTestCase {
    private func makeStore(maxRecords: Int = 200) throws -> HistoryStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TranscriptRecord.self, configurations: config)
        return HistoryStore(container: container, maxRecords: maxRecords)
    }

    func testAddAndFetch() throws {
        let store = try makeStore()
        store.add(text: "你好世界", durationSeconds: 1.2, source: "dictation")
        let records = store.recent(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.text, "你好世界")
    }

    func testRecentIsNewestFirst() throws {
        let store = try makeStore()
        store.add(text: "第一条", durationSeconds: 1, source: "dictation")
        store.add(text: "第二条", durationSeconds: 1, source: "dictation")
        XCTAssertEqual(store.recent(limit: 10).first?.text, "第二条")
    }

    func testTrimToMaxRecords() throws {
        let store = try makeStore(maxRecords: 5)
        for i in 1...8 { store.add(text: "记录\(i)", durationSeconds: 1, source: "dictation") }
        XCTAssertEqual(store.recent(limit: 100).count, 5)
        XCTAssertEqual(store.recent(limit: 100).first?.text, "记录8")
    }

    func testRawTextStored() throws {
        let store = try makeStore()
        store.add(text: "润色后", durationSeconds: 1, source: "dictation", rawText: "嗯润色前")
        store.add(text: "无润色", durationSeconds: 1, source: "dictation")
        let records = store.recent(limit: 10)
        XCTAssertEqual(records[0].rawText, nil)
        XCTAssertEqual(records[1].rawText, "嗯润色前")
    }

    func testDelete() throws {
        let store = try makeStore()
        store.add(text: "要删除", durationSeconds: 1, source: "file")
        store.delete(store.recent(limit: 1)[0])
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }
}
