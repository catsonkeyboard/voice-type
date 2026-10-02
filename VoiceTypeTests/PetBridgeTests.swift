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

    func testAcceptsSessionsAtTheLimitsAndInTheUsualShapes() {
        let sessions = [
            String(repeating: "a", count: 64),  // 长度上限
            "A-b-9",  // 大小写字母、连字符、数字
            "0123456789abcdef0123456789abcdef",  // 桌宠生成的 32 位十六进制
        ]
        for session in sessions {
            XCTAssertEqual(
                PetRequest.parse(URL(string: "voicetype://stop?session=\(session)")!),
                .stop(session: session), session)
        }
    }

    func testRejectsASessionMadeOfMultiByteCharacters() {
        // 「你」是 3 个字节：长度在范围内，但不是字母、数字或连字符
        XCTAssertNil(PetRequest.parse(URL(string: "voicetype://stop?session=%E4%BD%A0")!))
        XCTAssertNil(PetRequest.parse(URL(string: "voicetype://stop?session=ab%E4%BD%A0cd")!))
    }

    // MARK: - 回传 URL

    func testEncodeLeavesUnreservedCharactersAlone() {
        XCTAssertEqual(PetCallback.encode("a-b_c.d~e"), "a-b_c.d~e")
    }

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
        // 接收方若按表单规则解码，裸的 + 会被当成空格：文字里的加号和空格都必须编码
        XCTAssertFalse(url.absoluteString.contains("+"))
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

    func testDictateStartsOnlyWhenFullyIdleInAllEightStates() {
        let request = PetRequest.dictate(session: "s1", callback: callback)
        let start = PetAction.start(session: "s1", callback: callback)
        let busy = PetAction.refuse(session: "s1", callback: callback, reason: .busy)
        var checked = 0
        for idle in [false, true] {
            for recording in [false, true] {
                for meetingRecording in [false, true] {
                    // 只有「空闲、没在录音（含启动中）、没有会议录音」这一种状态会开始；
                    // 其余七种不打断正在进行的事，立刻回传 busy
                    let expected =
                        (idle, recording, meetingRecording) == (true, false, false) ? start : busy
                    XCTAssertEqual(
                        request.action(
                            idle: idle, recording: recording, meetingRecording: meetingRecording,
                            target: .cursor),
                        expected,
                        "idle: \(idle), recording: \(recording), meetingRecording: \(meetingRecording)"
                    )
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 8)
    }

    func testStopAndCancelActOnlyOnTheirOwnRecordingInAllCombinations() {
        let targets: [(label: String, target: DictationTarget)] = [
            ("pet s1", .pet(session: "s1", callback: callback)),
            ("pet s2", .pet(session: "s2", callback: callback)),
            ("cursor", .cursor),
        ]
        let requests: [(label: String, request: PetRequest, effect: PetAction)] = [
            ("stop", .stop(session: "s1"), .finish),
            ("cancel", .cancel(session: "s1"), .cancel),
        ]
        var checked = 0
        for (requestLabel, request, effect) in requests {
            for recording in [false, true] {
                for (targetLabel, target) in targets {
                    // 只有「正在录音，且这次听写就是 s1 自己的会话」才动手；
                    // 别的 session、光标听写、已经不在录音：全部忽略
                    let expected: PetAction =
                        (recording, targetLabel) == (true, "pet s1") ? effect : .ignore
                    XCTAssertEqual(
                        request.action(
                            idle: !recording, recording: recording, meetingRecording: false,
                            target: target),
                        expected,
                        "\(requestLabel) s1, recording: \(recording), target: \(targetLabel)")
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 12)
    }

    // MARK: - 启动期间的结束请求

    func testPendingEndMergeLetsACancelWin() {
        XCTAssertEqual(PendingEnd.merge(nil, .finish), .finish)
        XCTAssertEqual(PendingEnd.merge(nil, .cancel), .cancel)
        XCTAssertEqual(PendingEnd.merge(.finish, .cancel), .cancel)
        // 已经取消的会话，之后到达的结束请求不能把它改回去
        XCTAssertEqual(PendingEnd.merge(.cancel, .finish), .cancel)
        XCTAssertEqual(PendingEnd.merge(.finish, .finish), .finish)
        XCTAssertEqual(PendingEnd.merge(.cancel, .cancel), .cancel)
    }
}
