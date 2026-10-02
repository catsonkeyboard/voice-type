import XCTest

@testable import VoiceType

final class PetBridgeTests: XCTestCase {
    private let callback = URL(string: "pet://transcript")!

    // MARK: - 请求解析

    func testParsesDictate() {
        let url = URL(string: "voicetype://dictate?session=abc123&callback=pet%3A%2F%2Ftranscript")!
        XCTAssertEqual(PetRequest.parse(url), .dictate(session: "abc123", callback: callback))
    }

    func testParsesStopAndCancel() {
        XCTAssertEqual(
            PetRequest.parse(URL(string: "voicetype://stop?session=abc123")!),
            .stop(session: "abc123"))
        XCTAssertEqual(
            PetRequest.parse(URL(string: "voicetype://cancel?session=abc123")!),
            .cancel(session: "abc123"))
    }

    func testRejectsOtherCallbacks() {
        // 回调只认 pet://transcript：不能把识别结果发到别的地址
        let bad = [
            "https%3A%2F%2Fexample.com%2F", "pet%3A%2F%2Fother",
            "pet%3A%2F%2Ftranscript%3Fx%3D1", "",
        ]
        for callback in bad {
            let url = URL(string: "voicetype://dictate?session=abc123&callback=\(callback)")!
            XCTAssertNil(PetRequest.parse(url), callback)
        }
        XCTAssertNil(PetRequest.parse(URL(string: "voicetype://dictate?session=abc123")!))
    }

    func testRejectsBadSessionsSchemesAndCommands() {
        XCTAssertNil(PetRequest.parse(URL(string: "voicetype://stop")!))
        XCTAssertNil(PetRequest.parse(URL(string: "voicetype://stop?session=")!))
        XCTAssertNil(PetRequest.parse(URL(string: "voicetype://stop?session=a%20b")!))
        let long = String(repeating: "a", count: 65)
        XCTAssertNil(PetRequest.parse(URL(string: "voicetype://stop?session=\(long)")!))
        XCTAssertNil(PetRequest.parse(URL(string: "other://stop?session=abc123")!))
        XCTAssertNil(PetRequest.parse(URL(string: "voicetype://record?session=abc123")!))
    }

    // MARK: - 回传 URL

    func testCallbackURLEncodesText() {
        let url = PetCallback.url(
            callback: callback, session: "abc123", outcome: .text("你好 a+b&c=d#e\n100%"))
        XCTAssertEqual(
            url?.absoluteString,
            "pet://transcript?session=abc123&text=%E4%BD%A0%E5%A5%BD%20a%2Bb%26c%3Dd%23e%0A100%25")
    }

    func testCallbackURLRoundTripsThroughURLComponents() {
        // 接收方按查询参数解码后应得到原文
        let text = "明天上午 9 点 + 下午 3 点；50% & more = ok 😀"
        let url = PetCallback.url(callback: callback, session: "abc123", outcome: .text(text))!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "text" }?.value, text)
        XCTAssertEqual(items.first { $0.name == "session" }?.value, "abc123")
    }

    func testCallbackURLCarriesFailures() {
        let cases: [(PetFailure, String)] = [
            (.empty, "empty"), (.micDenied, "mic_denied"), (.notReady, "not_ready"),
            (.busy, "busy"), (.failed, "failed"),
        ]
        for (failure, code) in cases {
            let url = PetCallback.url(
                callback: callback, session: "abc123", outcome: .failure(failure))
            XCTAssertEqual(url?.absoluteString, "pet://transcript?session=abc123&error=\(code)")
        }
    }

    func testLongTextStaysInTheURL() {
        // 5 分钟听写约 1500 字：不写临时文件，全部放进 URL（每个汉字编码后 9 个字符）
        let text = String(repeating: "字", count: 1500)
        let url = PetCallback.url(callback: callback, session: "abc123", outcome: .text(text))
        XCTAssertEqual(
            url?.absoluteString.count, "pet://transcript?session=abc123&text=".count + 1500 * 9)
    }

    // MARK: - 请求该做什么

    func testDictateStartsOnlyWhenIdle() {
        let request = PetRequest.dictate(session: "s1", callback: callback)
        XCTAssertEqual(
            request.action(idle: true, recording: false, meetingRecording: false, target: .cursor),
            .start(session: "s1", callback: callback))
        // 正在录音、识别或润色：不打断，立刻回传 busy
        XCTAssertEqual(
            request.action(idle: false, recording: true, meetingRecording: false, target: .cursor),
            .refuse(session: "s1", callback: callback, reason: .busy))
        XCTAssertEqual(
            request.action(idle: false, recording: false, meetingRecording: false, target: .cursor),
            .refuse(session: "s1", callback: callback, reason: .busy))
        // 会议录音进行中
        XCTAssertEqual(
            request.action(idle: true, recording: false, meetingRecording: true, target: .cursor),
            .refuse(session: "s1", callback: callback, reason: .busy))
    }

    func testStopAndCancelOnlyTouchTheirOwnRecording() {
        let mine = DictationTarget.pet(session: "s1", callback: callback)
        XCTAssertEqual(
            PetRequest.stop(session: "s1").action(
                idle: false, recording: true, meetingRecording: false, target: mine),
            .finish)
        XCTAssertEqual(
            PetRequest.cancel(session: "s1").action(
                idle: false, recording: true, meetingRecording: false, target: mine),
            .cancel)
        // 别的 session、光标听写、已经不在录音：都不动
        XCTAssertEqual(
            PetRequest.stop(session: "s2").action(
                idle: false, recording: true, meetingRecording: false, target: mine),
            .ignore)
        XCTAssertEqual(
            PetRequest.stop(session: "s1").action(
                idle: false, recording: true, meetingRecording: false, target: .cursor),
            .ignore)
        XCTAssertEqual(
            PetRequest.cancel(session: "s1").action(
                idle: false, recording: false, meetingRecording: false, target: mine),
            .ignore)
    }
}
