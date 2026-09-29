import XCTest

@testable import VoiceType

final class DashScopeAsrProtocolTests: XCTestCase {
    // MARK: - 消息构造

    func testRunTaskMessage() throws {
        let json = DashScopeAsr.runTaskMessage(taskId: "abc123", model: "fun-asr-realtime")
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let header = obj["header"] as! [String: Any]
        XCTAssertEqual(header["action"] as? String, "run-task")
        XCTAssertEqual(header["task_id"] as? String, "abc123")
        XCTAssertEqual(header["streaming"] as? String, "duplex")
        let payload = obj["payload"] as! [String: Any]
        XCTAssertEqual(payload["task_group"] as? String, "audio")
        XCTAssertEqual(payload["task"] as? String, "asr")
        XCTAssertEqual(payload["function"] as? String, "recognition")
        XCTAssertEqual(payload["model"] as? String, "fun-asr-realtime")
        let params = payload["parameters"] as! [String: Any]
        XCTAssertEqual(params["format"] as? String, "pcm")
        XCTAssertEqual(params["sample_rate"] as? Int, 16000)
        XCTAssertNotNil(payload["input"])
    }

    func testFinishTaskMessage() throws {
        let json = DashScopeAsr.finishTaskMessage(taskId: "abc123")
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let header = obj["header"] as! [String: Any]
        XCTAssertEqual(header["action"] as? String, "finish-task")
        XCTAssertEqual(header["task_id"] as? String, "abc123")
    }

    func testNewTaskIdIs32HexNoDash() {
        let id = DashScopeAsr.newTaskId()
        XCTAssertEqual(id.count, 32)
        XCTAssertFalse(id.contains("-"))
    }

    // MARK: - 事件解析

    func testParseTaskStarted() {
        let event = DashScopeAsr.parseEvent(
            #"{"header":{"event":"task-started","task_id":"x","attributes":{}},"payload":{}}"#)
        XCTAssertEqual(event, .taskStarted)
    }

    func testParseResultGeneratedPartial() {
        let json = #"""
        {"header":{"event":"result-generated","task_id":"x"},
         "payload":{"output":{"sentence":{"begin_time":170,"end_time":null,"text":"明天上","sentence_end":false}},"usage":null}}
        """#
        XCTAssertEqual(
            DashScopeAsr.parseEvent(json),
            .resultGenerated(DashScopeAsr.Sentence(text: "明天上", sentenceEnd: false)))
    }

    func testParseResultGeneratedFinal() {
        let json = #"""
        {"header":{"event":"result-generated","task_id":"x"},
         "payload":{"output":{"sentence":{"begin_time":170,"end_time":2100,"text":"明天上午九点开会。","sentence_end":true}}}}
        """#
        XCTAssertEqual(
            DashScopeAsr.parseEvent(json),
            .resultGenerated(DashScopeAsr.Sentence(text: "明天上午九点开会。", sentenceEnd: true)))
    }

    func testParseTaskFinishedAndFailed() {
        XCTAssertEqual(
            DashScopeAsr.parseEvent(
                #"{"header":{"event":"task-finished","task_id":"x"},"payload":{"output":{}}}"#),
            .taskFinished)
        XCTAssertEqual(
            DashScopeAsr.parseEvent(
                #"{"header":{"event":"task-failed","task_id":"x","error_code":"InvalidApiKey","error_message":"Invalid API-key provided."},"payload":{}}"#),
            .taskFailed(code: "InvalidApiKey", message: "Invalid API-key provided."))
    }

    func testParseGarbageReturnsUnknown() {
        XCTAssertEqual(DashScopeAsr.parseEvent("not json"), .unknown)
        XCTAssertEqual(DashScopeAsr.parseEvent(#"{"header":{}}"#), .unknown)
    }

    // MARK: - PCM16

    func testPcm16Conversion() {
        let data = DashScopeAsr.pcm16Data(from: [0, 1.0, -1.0, 0.5, 2.0])
        XCTAssertEqual(data.count, 10)
        let values = data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) }
        }
        XCTAssertEqual(values[0], 0)
        XCTAssertEqual(values[1], 32767)
        XCTAssertEqual(values[2], -32767)
        XCTAssertEqual(values[3], 16383)
        XCTAssertEqual(values[4], 32767)  // 超界截断
    }

    // MARK: - 句子装配

    func testAssemblerPartialThenFinal() {
        var a = SentenceAssembler()
        a.ingest(.init(text: "明天", sentenceEnd: false))
        XCTAssertEqual(a.liveText, "明天")
        a.ingest(.init(text: "明天上午", sentenceEnd: false))
        XCTAssertEqual(a.liveText, "明天上午")
        a.ingest(.init(text: "明天上午九点开会。", sentenceEnd: true))
        a.ingest(.init(text: "记得带电脑", sentenceEnd: false))
        XCTAssertEqual(a.liveText, "明天上午九点开会。记得带电脑")
        XCTAssertEqual(a.finalText, "明天上午九点开会。记得带电脑")  // 残留 partial 并入终稿
    }

    func testAssemblerEmpty() {
        let a = SentenceAssembler()
        XCTAssertEqual(a.liveText, "")
        XCTAssertEqual(a.finalText, "")
    }
}

/// 会话终态语义（不依赖网络）：已断线/已取消的会话上
/// send 丢弃、finish 立即抛错（不空等 15s 超时）、onFailure 恰好触发一次
final class DashScopeSessionTerminalStateTests: XCTestCase {
    func testFinishAfterCancelThrowsImmediately() async {
        let session = DashScopeAsrSession(apiKey: "k", model: "m")
        var failureCount = 0
        session.onFailure = { _ in failureCount += 1 }
        session.cancel()

        let start = Date()
        do {
            _ = try await session.finish()
            XCTFail("取消后的会话 finish 应抛错")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "应立即抛错而非等超时")
        XCTAssertEqual(failureCount, 1, "onFailure 恰好触发一次")
    }

    func testSendAfterTerminalIsDropped() async {
        let session = DashScopeAsrSession(apiKey: "k", model: "m")
        session.cancel()
        // 不应崩溃/不应挂起；已终态直接丢弃
        session.send(samples: [0, 0, 0])
        let exp = expectation(description: "finish 立即抛错")
        Task {
            do { _ = try await session.finish(); XCTFail("应抛错") } catch {}
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 5)
    }

    func testFailAllIsExactlyOnce() {
        let session = DashScopeAsrSession(apiKey: "k", model: "m")
        var failureCount = 0
        session.onFailure = { _ in failureCount += 1 }
        session.cancel()
        session.cancel()  // 第二次触发路径（幂等）
        XCTAssertEqual(failureCount, 1)
    }
}
