import XCTest

@testable import VoiceType

final class AppBridgeTests: XCTestCase {
    private let callback = URL(string: "testapp://voicetype-result")!
    private let encodedCallback = "testapp%3A%2F%2Fvoicetype-result"

    // MARK: - 请求解析

    func testParsesDictate() {
        let url = URL(string: "voicetype://dictate?session=abc123&callback=\(encodedCallback)")!
        XCTAssertEqual(BridgeRequest.parse(url), .dictate(session: "abc123", callback: callback))
    }

    func testParsesStopAndCancel() {
        XCTAssertEqual(
            BridgeRequest.parse(URL(string: "voicetype://stop?session=abc123")!),
            .stop(session: "abc123"))
        XCTAssertEqual(
            BridgeRequest.parse(URL(string: "voicetype://cancel?session=abc123")!),
            .cancel(session: "abc123"))
    }

    func testDictateWithoutAUsableCallbackIsRejected() {
        XCTAssertNil(BridgeRequest.parse(URL(string: "voicetype://dictate?session=abc123")!))
        let url = URL(string: "voicetype://dictate?session=abc123&callback=https%3A%2F%2Fexample.com%2F")!
        XCTAssertNil(BridgeRequest.parse(url))
    }

    func testRejectsBadSessionsSchemesAndCommands() {
        XCTAssertNil(BridgeRequest.parse(URL(string: "voicetype://stop")!))
        XCTAssertNil(BridgeRequest.parse(URL(string: "voicetype://stop?session=")!))
        XCTAssertNil(BridgeRequest.parse(URL(string: "voicetype://stop?session=a%20b")!))
        let long = String(repeating: "a", count: 65)
        XCTAssertNil(BridgeRequest.parse(URL(string: "voicetype://stop?session=\(long)")!))
        XCTAssertNil(BridgeRequest.parse(URL(string: "other://stop?session=abc123")!))
        XCTAssertNil(BridgeRequest.parse(URL(string: "voicetype://record?session=abc123")!))
    }

    func testAcceptsSessionsAtTheLimitsAndInTheUsualShapes() {
        let sessions = [
            String(repeating: "a", count: 64),  // 长度上限
            "A-b-9",  // 大小写字母、连字符、数字
            "0123456789abcdef0123456789abcdef",  // 32 位十六进制
        ]
        for session in sessions {
            XCTAssertEqual(
                BridgeRequest.parse(URL(string: "voicetype://stop?session=\(session)")!),
                .stop(session: session), session)
        }
    }

    func testRejectsASessionMadeOfMultiByteCharacters() {
        // 「你」是 3 个字节：长度在范围内，但不是字母、数字或连字符
        XCTAssertNil(BridgeRequest.parse(URL(string: "voicetype://stop?session=%E4%BD%A0")!))
        XCTAssertNil(BridgeRequest.parse(URL(string: "voicetype://stop?session=ab%E4%BD%A0cd")!))
    }

    // MARK: - 回调地址校验

    func testAcceptsCustomSchemeCallbacks() {
        for raw in [
            "testapp://voicetype-result", "com.example.notes://dictation/result",
            "my-app+beta://cb", "notesapp:result",
        ] {
            XCTAssertEqual(BridgeCallback.validate(raw)?.absoluteString, raw, raw)
        }
    }

    func testCallbackSchemeIsLowercased() {
        // 授权按回调地址记忆：同一个地址不能因为 scheme 大小写不同变成两条
        XCTAssertEqual(
            BridgeCallback.validate("TestApp://voicetype-result")?.absoluteString,
            "testapp://voicetype-result")
    }

    func testRejectsCallbacksThatWouldLeaveTheDeviceOrLoopBack() {
        // 网页、文件、邮件短信电话：一旦允许，识别出的文字会被送进浏览器或别的系统应用
        for raw in [
            "http://example.com/cb", "https://example.com/cb", "HTTPS://example.com/cb",
            "file:///tmp/x", "ftp://example.com/", "mailto:a@example.com", "sms:10086",
            "tel:10086", "facetime:a@example.com", "voicetype://dictate",
        ] {
            XCTAssertNil(BridgeCallback.validate(raw), raw)
        }
    }

    func testRejectsMalformedCallbacks() {
        let tooLong = "testapp://" + String(repeating: "a", count: 250)
        for raw in [
            "", "voicetype-result", "://x",
            "testapp://result?x=1",  // 回传要在后面拼 ?session=…，已有查询会弄乱参数
            "testapp://result#frag", "testapp://user:pass@host", tooLong,
        ] {
            XCTAssertNil(BridgeCallback.validate(raw), raw)
        }
        XCTAssertNotNil(BridgeCallback.validate("testapp://" + String(repeating: "a", count: 246)))
    }

    // MARK: - 回传 URL

    func testEncodeLeavesUnreservedCharactersAlone() {
        XCTAssertEqual(BridgeCallback.encode("a-b_c.d~e"), "a-b_c.d~e")
    }

    func testCallbackURLEncodesText() {
        let url = BridgeCallback.url(
            callback: callback, session: "abc123", outcome: .text("你好 a+b&c=d#e\n100%"))
        XCTAssertEqual(
            url?.absoluteString,
            "testapp://voicetype-result?session=abc123&text=%E4%BD%A0%E5%A5%BD%20a%2Bb%26c%3Dd%23e%0A100%25"
        )
    }

    func testCallbackURLRoundTripsThroughURLComponents() {
        // 接收方按查询参数解码后应得到原文
        let text = "明天上午 9 点 + 下午 3 点；50% & more = ok 😀"
        let url = BridgeCallback.url(callback: callback, session: "abc123", outcome: .text(text))!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "text" }?.value, text)
        XCTAssertEqual(items.first { $0.name == "session" }?.value, "abc123")
        // 接收方若按表单规则解码，裸的 + 会被当成空格：文字里的加号和空格都必须编码
        XCTAssertFalse(url.absoluteString.contains("+"))
    }

    func testCallbackURLCarriesFailures() {
        let cases: [(BridgeFailure, String)] = [
            (.empty, "empty"), (.micDenied, "mic_denied"), (.notReady, "not_ready"),
            (.busy, "busy"), (.notAllowed, "not_allowed"), (.failed, "failed"),
        ]
        for (failure, code) in cases {
            let url = BridgeCallback.url(
                callback: callback, session: "abc123", outcome: .failure(failure))
            XCTAssertEqual(
                url?.absoluteString, "testapp://voicetype-result?session=abc123&error=\(code)")
        }
    }

    func testLongTextStaysInTheURL() {
        // 5 分钟听写约 1500 字：不写临时文件，全部放进 URL（每个汉字编码后 9 个字符）
        let text = String(repeating: "字", count: 1500)
        let url = BridgeCallback.url(callback: callback, session: "abc123", outcome: .text(text))
        XCTAssertEqual(
            url?.absoluteString.count,
            "testapp://voicetype-result?session=abc123&text=".count + 1500 * 9)
    }

    // MARK: - 请求该做什么

    func testDictateInAllStatesAndPermissions() {
        let request = BridgeRequest.dictate(session: "s1", callback: callback)
        let start = BridgeAction.start(session: "s1", callback: callback)
        let ask = BridgeAction.askPermission(session: "s1", callback: callback)
        let busy = BridgeAction.refuse(session: "s1", callback: callback, reason: .busy)
        let notAllowed = BridgeAction.refuse(session: "s1", callback: callback, reason: .notAllowed)
        var checked = 0
        for permission in [BridgePermission.allowed, .denied, .unknown] {
            for idle in [false, true] {
                for recording in [false, true] {
                    for meetingRecording in [false, true] {
                        // 只有「空闲、没在录音（含启动中）、没有会议录音」才会开始或询问；
                        // 已拒绝的应用不论忙不忙都回 not_allowed；忙的时候不弹窗，直接回 busy
                        let free = (idle, recording, meetingRecording) == (true, false, false)
                        let expected: BridgeAction
                        switch permission {
                        case .denied: expected = notAllowed
                        case .unknown: expected = free ? ask : busy
                        case .allowed: expected = free ? start : busy
                        }
                        XCTAssertEqual(
                            request.action(
                                idle: idle, recording: recording,
                                meetingRecording: meetingRecording, target: .cursor,
                                permission: permission),
                            expected,
                            "\(permission) idle: \(idle), recording: \(recording), meeting: \(meetingRecording)"
                        )
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, 24)
    }

    func testStopAndCancelActOnlyOnTheirOwnRecordingInAllCombinations() {
        let targets: [(label: String, target: DictationTarget)] = [
            ("external s1", .external(session: "s1", callback: callback)),
            ("external s2", .external(session: "s2", callback: callback)),
            ("cursor", .cursor),
        ]
        let requests: [(label: String, request: BridgeRequest, effect: BridgeAction)] = [
            ("stop", .stop(session: "s1"), .finish),
            ("cancel", .cancel(session: "s1"), .cancel),
        ]
        var checked = 0
        for (requestLabel, request, effect) in requests {
            for recording in [false, true] {
                for (targetLabel, target) in targets {
                    // 只有「正在录音，且这次听写就是 s1 自己的会话」才动手；
                    // 别的 session、光标听写、已经不在录音：全部忽略
                    let expected: BridgeAction =
                        (recording, targetLabel) == (true, "external s1") ? effect : .ignore
                    XCTAssertEqual(
                        request.action(
                            idle: !recording, recording: recording, meetingRecording: false,
                            target: target, permission: .unknown),
                        expected,
                        "\(requestLabel) s1, recording: \(recording), target: \(targetLabel)")
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 12)
    }

    func testOnlyDictateCarriesACallback() {
        XCTAssertEqual(BridgeRequest.dictate(session: "s1", callback: callback).callback, callback)
        XCTAssertNil(BridgeRequest.stop(session: "s1").callback)
        XCTAssertNil(BridgeRequest.cancel(session: "s1").callback)
    }

    // MARK: - 启动期间的结束请求

    func testCancelWhileTranscribingDropsOnlyThatSessionsReply() {
        // 结束录音后、结果回传前，第三方应用退出时发来的取消：识别完不回传（2026-10-24）
        let cancel = BridgeRequest.cancel(session: "s1")
        XCTAssertEqual(
            cancel.action(
                idle: false, recording: false, meetingRecording: false, target: .cursor,
                permission: .unknown, transcribing: "s1"),
            .dropReply)
        XCTAssertEqual(
            BridgeRequest.cancel(session: "s2").action(
                idle: false, recording: false, meetingRecording: false, target: .cursor,
                permission: .unknown, transcribing: "s1"),
            .ignore)
        // 结束请求在识别阶段没有意义
        XCTAssertEqual(
            BridgeRequest.stop(session: "s1").action(
                idle: false, recording: false, meetingRecording: false, target: .cursor,
                permission: .unknown, transcribing: "s1"),
            .ignore)
        // 不在识别时一切照旧
        XCTAssertEqual(
            cancel.action(
                idle: true, recording: false, meetingRecording: false, target: .cursor,
                permission: .unknown),
            .ignore)
    }

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

/// 授权记录的存取（UserDefaults）
final class BridgePermissionStoreTests: XCTestCase {
    private let a = URL(string: "testapp://voicetype-result")!
    private let b = URL(string: "otherapp://cb")!
    private var saved: [String: Bool] = [:]

    override func setUp() {
        super.setUp()
        saved = SettingsStore.bridgePermissions
        SettingsStore.bridgePermissions = [:]
    }

    override func tearDown() {
        SettingsStore.bridgePermissions = saved
        super.tearDown()
    }

    func testUnknownUntilDecided() {
        XCTAssertEqual(SettingsStore.bridgePermission(for: a), .unknown)
    }

    func testRemembersAllowAndDenyPerCallback() {
        SettingsStore.setBridgePermission(true, for: a)
        SettingsStore.setBridgePermission(false, for: b)
        XCTAssertEqual(SettingsStore.bridgePermission(for: a), .allowed)
        XCTAssertEqual(SettingsStore.bridgePermission(for: b), .denied)
    }

    func testRemoveForgetsTheDecision() {
        SettingsStore.setBridgePermission(false, for: a)
        SettingsStore.removeBridgePermission(forCallback: a.absoluteString)
        XCTAssertEqual(SettingsStore.bridgePermission(for: a), .unknown)
    }
}
