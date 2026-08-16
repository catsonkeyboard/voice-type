import XCTest

@testable import VoiceType

final class LocalAsrModelSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "localAsrModel")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "localAsrModel")
        super.tearDown()
    }

    func testDefaultIsFunasrNano() {
        XCTAssertEqual(SettingsStore.localAsrModel, .funasrNano, "v5 默认模型应为 Fun-ASR-Nano")
    }

    func testRoundTrip() {
        SettingsStore.localAsrModel = .qwen3Asr
        XCTAssertEqual(SettingsStore.localAsrModel, .qwen3Asr)
        SettingsStore.localAsrModel = .senseVoice
        XCTAssertEqual(SettingsStore.localAsrModel, .senseVoice)
    }

    func testInvalidRawValueFallsBackToDefault() {
        UserDefaults.standard.set("gpt-asr", forKey: "localAsrModel")
        XCTAssertEqual(SettingsStore.localAsrModel, .funasrNano, "未知档位回退默认而非崩溃")
    }

    func testAllPresentReflectsSelectedModel() {
        // 三个已知档位：allPresent 必须跟随选择，而非固定检测某一个文件
        let anyInstalled = LocalAsrModel.allCases.contains { ModelPaths.isPresent($0) }
        if anyInstalled {
            for m in LocalAsrModel.allCases {
                SettingsStore.localAsrModel = m
                XCTAssertEqual(ModelPaths.allPresent, ModelPaths.isPresent(m))
            }
        }
    }
}
