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

    func testFirstCharInitialMismatchStillCorrected() {
        // 首字声母平翘舌误识（z↔c）：「张涛」(zhangtao) 误识为「仓涛」(cangtao)，
        // 编辑距离 2 恰在阈值内，应纠正——保护首字误识不被任何前置剪枝跳过
        let corrector = HotwordCorrector(hotwords: ["张涛"])
        let result = corrector.correct("明天上午找仓涛开会")
        XCTAssertEqual(result, "明天上午找张涛开会")
    }

    func testRetroflexAndDentalInterchange() {
        // 「诗」(shi) vs 「思」(si)：sh/s 平翘舌互换
        let corrector = HotwordCorrector(hotwords: ["诗涵"])
        let result = corrector.correct("她叫思涵")
        XCTAssertEqual(result, "她叫诗涵")
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

    // MARK: - v7 中英混合与别名（latin 模糊匹配 + alias 语法）

    func testLatinExactMatch() {
        let corrector = HotwordCorrector(hotwords: ["Kubernetes"])
        XCTAssertEqual(corrector.correct("kubernetes 集群"), "Kubernetes 集群")
    }

    func testLatinFuzzyMatch() {
        // kubernets → kubernetes：编辑距离 1，长度 10 容差 2
        let corrector = HotwordCorrector(hotwords: ["Kubernetes"])
        XCTAssertEqual(corrector.correct("kubernets 集群"), "Kubernetes 集群")
    }

    func testShortLatinOnlyExact() {
        // 短词（<6 字符）禁模糊：API 不应误伤 apiary
        let corrector = HotwordCorrector(hotwords: ["API"])
        XCTAssertEqual(corrector.correct("apiary 文档"), "apiary 文档")
        XCTAssertEqual(corrector.correct("api 网关"), "API 网关")
    }

    func testLatinWithSeparators() {
        let corrector = HotwordCorrector(hotwords: ["CI/CD", "Next.js"])
        XCTAssertEqual(corrector.correct("ci/cd 流水线"), "CI/CD 流水线")
        XCTAssertEqual(corrector.correct("next.js 项目"), "Next.js 项目")
    }

    func testAliasCJK() {
        // 别名条目：识别出拼音近似「库伯内提斯」时替换为 Kubernetes
        let corrector = HotwordCorrector(hotwords: ["Kubernetes|库伯内提斯"])
        XCTAssertEqual(corrector.correct("部署到库伯内提斯"), "部署到 Kubernetes")
    }

    func testAliasLatin() {
        let corrector = HotwordCorrector(hotwords: ["PostgreSQL|postgres"])
        XCTAssertEqual(corrector.correct("连 postgres 数据库"), "连 PostgreSQL 数据库")
    }

    func testMixedEntry() {
        // 混合条目（拉丁+CJK）：滑窗按 CJK 段拼音纠正 + 拉丁段模糊纠正
        let corrector = HotwordCorrector(hotwords: ["Vue 组件"])
        XCTAssertEqual(corrector.correct("vue组建渲染失败"), "Vue 组件渲染失败")
    }

    func testLatinNotTouchUnrelated() {
        // 目标词内的分隔符是词条一部分；独立单词 "graph ql"（带空格）不匹配 "GraphQL"
        let corrector = HotwordCorrector(hotwords: ["GraphQL"])
        XCTAssertEqual(corrector.correct("graph ql 笔记"), "graph ql 笔记")
    }
}
