import XCTest

@testable import VoiceType

final class HotwordCorrectorTests: XCTestCase {
    func testPinyinConversion() {
        XCTAssertEqual(HotwordCorrector.pinyin(of: "朗诗德"), "langshide")
        XCTAssertEqual(HotwordCorrector.pinyin(of: "狼视得"), "langshide")
    }

    func testCorrectsHomophone() {
        let corrector = HotwordCorrector(hotwords: ["朗诗德"])
        let result = corrector.correct("我买了一台狼视得净水器")
        XCTAssertEqual(result, "我买了一台朗诗德净水器")
    }

    func testNearMissWithinThreshold() {
        // 「森派」vs「盛派」：senpai vs shengpai，编辑距离在阈值内应纠正
        let corrector = HotwordCorrector(hotwords: ["盛派"])
        let result = corrector.correct("森派公司发布了新品")
        XCTAssertEqual(result, "盛派公司发布了新品")
    }

    func testDoesNotTouchUnrelatedText() {
        let corrector = HotwordCorrector(hotwords: ["朗诗德"])
        let text = "今天天气很好，我们去公园散步。"
        XCTAssertEqual(corrector.correct(text), text)
    }

    func testDoesNotTouchEnglishAndDigits() {
        let corrector = HotwordCorrector(hotwords: ["朗诗德"])
        let text = "The price is 123 dollars."
        XCTAssertEqual(corrector.correct(text), text)
    }

    func testEmptyHotwordsNoOp() {
        let corrector = HotwordCorrector(hotwords: [])
        XCTAssertEqual(corrector.correct("随便什么文本"), "随便什么文本")
    }

    func testExactMatchUnchanged() {
        let corrector = HotwordCorrector(hotwords: ["朗诗德"])
        XCTAssertEqual(corrector.correct("朗诗德净水器很好"), "朗诗德净水器很好")
    }
}
