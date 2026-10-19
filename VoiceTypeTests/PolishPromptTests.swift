import XCTest

@testable import VoiceType

final class PolishPromptTests: XCTestCase {
    func testCommonRulesContainTermProtection() {
        for template in [PromptTemplates.clean, PromptTemplates.formal] {
            XCTAssertTrue(template.contains("原样保留"), "缺少术语原样保留规则: \(template)")
            XCTAssertTrue(template.contains("禁止翻译"), "缺少禁止翻译规则: \(template)")
        }
    }

    func testPromptMentionsCodeSwitching() {
        for template in [PromptTemplates.clean, PromptTemplates.formal] {
            XCTAssertTrue(template.contains("中英混合"), "未声明中英混合输入: \(template)")
        }
    }

    func testPromptHasCodeSwitchExamples() {
        // commonRules 是两模板的公共子串，从中取示例断言
        let common = PromptTemplates.clean
        XCTAssertTrue(common.contains("refactor"), "缺少 refactor 混说示例")
        XCTAssertTrue(common.contains("replicas"), "缺少 replicas 混说示例")
    }
}
