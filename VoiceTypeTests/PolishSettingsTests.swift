import XCTest

@testable import VoiceType

final class PolishSettingsTests: XCTestCase {
    private let keys = ["polishEnabled", "polishBaseURL", "polishModel", "polishStyle"]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testDefaults() {
        XCTAssertTrue(SettingsStore.polishEnabled)
        XCTAssertEqual(SettingsStore.polishBaseURL, "http://localhost:11434/v1")
        XCTAssertEqual(SettingsStore.polishModel, "qwen3.5:4b-nvfp4")
        XCTAssertEqual(SettingsStore.polishStyle, .clean)
    }

    func testRoundTrip() {
        SettingsStore.polishEnabled = false
        SettingsStore.polishStyle = .formal
        SettingsStore.polishModel = "qwen3.5:9b-nvfp4"
        XCTAssertFalse(SettingsStore.polishEnabled)
        XCTAssertEqual(SettingsStore.polishStyle, .formal)
        XCTAssertEqual(SettingsStore.polishConfig.model, "qwen3.5:9b-nvfp4")
        XCTAssertFalse(SettingsStore.polishConfig.enabled)
    }

    func testPromptTemplatesCoverGoldenScenarios() {
        for template in [PromptTemplates.system(for: .clean), PromptTemplates.system(for: .formal)] {
            XCTAssertTrue(template.contains("口头禅") || template.contains("填充词"))
            XCTAssertTrue(template.contains("自我纠正") || template.contains("纠正"))
            XCTAssertTrue(template.contains("列表"))
            XCTAssertTrue(template.contains("只输出"))
        }
    }
}
