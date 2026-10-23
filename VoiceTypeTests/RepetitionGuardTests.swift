import XCTest

@testable import VoiceType

final class RepetitionGuardTests: XCTestCase {
    func testCollapsesARunawayLoopToOneCopy() {
        // 2026-10-23 实测：Fun-ASR-Nano 在「再按 ⌥⌘V」处卡住，输出上百个「CTRL、」
        let looped = "再按" + String(repeating: "CTRL、", count: 120) + "\n这时如果失败"
        XCTAssertEqual(RepetitionGuard.collapse(looped), "再按CTRL、\n这时如果失败")
    }

    func testKeepsShortRepeats() {
        XCTAssertEqual(RepetitionGuard.collapse("好的好的好的好的好的"), "好的好的好的好的好的")
        XCTAssertEqual(RepetitionGuard.collapse("对对对，就是这样"), "对对对，就是这样")
    }

    func testASingleCharacterKeepsThree() {
        XCTAssertEqual(RepetitionGuard.collapse("哈哈哈哈哈哈哈哈"), "哈哈哈")
        XCTAssertEqual(RepetitionGuard.collapse("好好好好好好好吧"), "好好好吧")
    }

    func testLongerUnits() {
        let looped = String(repeating: "abc", count: 7) + "d"
        XCTAssertEqual(RepetitionGuard.collapse(looped), "abcd")
        let words = String(repeating: "谢谢观看。", count: 6)
        XCTAssertEqual(RepetitionGuard.collapse(words), "谢谢观看。")
    }

    func testLeavesDigitsAlone() {
        XCTAssertEqual(RepetitionGuard.collapse("验证码是000000"), "验证码是000000")
        XCTAssertEqual(RepetitionGuard.collapse("1212121212121212"), "1212121212121212")
    }

    func testLeavesOrdinaryTextAlone() {
        let text = "帮我看看这个报错，重点关注表格和图表。"
        XCTAssertEqual(RepetitionGuard.collapse(text), text)
        XCTAssertEqual(RepetitionGuard.collapse(""), "")
    }
}
