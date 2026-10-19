import XCTest

@testable import VoiceType

final class DevGlossaryTests: XCTestCase {
    func testGlossaryContainsCommonTerms() {
        for term in ["Kubernetes", "CI/CD", "GraphQL", "WebSocket"] {
            XCTAssertTrue(
                DevGlossary.terms.contains(term), "内置术语表缺少 \(term)")
        }
    }

    func testMergedDedup() {
        // 用户词条与内置表大小写不敏感去重：用户的保留，内置的被覆盖
        let merged = DevGlossary.merged(withUser: ["kubernetes", "Vue"])
        XCTAssertEqual(merged.filter { $0.lowercased() == "kubernetes" }.count, 1)
        XCTAssertEqual(merged.first, "kubernetes")
    }

    func testMergedKeepsAllUser() {
        let user = ["自研平台", "TensorFlow"]
        let merged = DevGlossary.merged(withUser: user)
        // 用户词条全部保留且在前
        XCTAssertEqual(Array(merged.prefix(2)), user)
        // 内置词条追加在后
        XCTAssertTrue(merged.count > user.count)
    }
}
