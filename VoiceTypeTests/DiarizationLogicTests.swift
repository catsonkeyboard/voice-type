import XCTest

@testable import VoiceType

final class DiarizationLogicTests: XCTestCase {
    // MARK: - 段合并

    func testMergeSameSpeakerSmallGap() {
        let merged = DiarizationService.mergeAdjacent([
            SpeakerSegment(speaker: 0, start: 0, end: 2),
            SpeakerSegment(speaker: 0, start: 2.5, end: 4),
        ])
        XCTAssertEqual(merged, [SpeakerSegment(speaker: 0, start: 0, end: 4)])
    }

    func testNoMergeDifferentSpeaker() {
        let segs = [
            SpeakerSegment(speaker: 0, start: 0, end: 2),
            SpeakerSegment(speaker: 1, start: 2.1, end: 4),
        ]
        XCTAssertEqual(DiarizationService.mergeAdjacent(segs), segs)
    }

    func testNoMergeLargeGap() {
        let segs = [
            SpeakerSegment(speaker: 0, start: 0, end: 2),
            SpeakerSegment(speaker: 0, start: 4, end: 6),
        ]
        XCTAssertEqual(DiarizationService.mergeAdjacent(segs), segs)
    }

    func testMergeSortsInput() {
        let merged = DiarizationService.mergeAdjacent([
            SpeakerSegment(speaker: 0, start: 2.5, end: 4),
            SpeakerSegment(speaker: 0, start: 0, end: 2),
        ])
        XCTAssertEqual(merged, [SpeakerSegment(speaker: 0, start: 0, end: 4)])
    }

    func testMergeEmpty() {
        XCTAssertEqual(DiarizationService.mergeAdjacent([]), [])
    }

    // MARK: - Markdown 与 JSON

    private var sample: MeetingTranscript {
        MeetingTranscript(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 65,
            audioFile: "test.wav",
            segments: [
                SpeakerSegment(speaker: 0, start: 5, end: 10, text: "这个方案可以。"),
                SpeakerSegment(speaker: 1, start: 65, end: 70, text: "下周出原型。"),
            ],
            speakerNames: [0: "张三"])
    }

    func testMarkdownWithRename() {
        let md = sample.markdown()
        XCTAssertTrue(md.contains("**张三 [00:05]** 这个方案可以。"))
        XCTAssertTrue(md.contains("**说话人2 [01:05]** 下周出原型。"))
    }

    func testJSONRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try sample.save(to: url)
        let loaded = try MeetingTranscript.load(from: url)
        XCTAssertEqual(loaded.segments, sample.segments)
        XCTAssertEqual(loaded.speakerNames, [0: "张三"])
        XCTAssertEqual(loaded.audioFile, "test.wav")
    }

    func testSpeakerIds() {
        XCTAssertEqual(sample.speakerIds, [0, 1])
    }

    func testMinutesPromptContainsTranscript() {
        XCTAssertTrue(MinutesPrompt.system.contains("待办事项"))
        XCTAssertTrue(MinutesPrompt.system.contains("决议"))
        let user = MinutesPrompt.user(transcript: sample)
        XCTAssertTrue(user.contains("张三"))
        XCTAssertTrue(user.contains("这个方案可以。"))
    }
}
