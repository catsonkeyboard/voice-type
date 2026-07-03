import XCTest

@testable import VoiceType

/// URLProtocol mock：拦截 PolishService 的所有请求
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    static func reset() {
        handler = nil
        recordedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordedRequests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// URLSession 会把 httpBody 转为 stream，断言请求体必须从这里读
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

final class PolishServiceTests: XCTestCase {
    private var service: PolishService!

    private static let config = PolishConfig(
        enabled: true, baseURL: "http://localhost:11434/v1", apiKey: "",
        model: "test-model", style: .clean)

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        service = PolishService(
            session: URLSession(configuration: cfg),
            configProvider: { Self.config })
    }

    private func stubSuccess(content: String) {
        MockURLProtocol.handler = { request in
            let json = [
                "choices": [["message": ["role": "assistant", "content": content]]]
            ]
            let data = try JSONSerialization.data(withJSONObject: json)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }
    }

    func testShortInputSkipsWithoutNetwork() async {
        stubSuccess(content: "不应到达")
        let result = await service.polish("好的")
        XCTAssertNil(result)
        XCTAssertTrue(MockURLProtocol.recordedRequests.isEmpty)
    }

    func testRequestFormat() async throws {
        stubSuccess(content: "润色结果。")
        _ = await service.polish("嗯这是一段测试文本")

        let request = try XCTUnwrap(MockURLProtocol.recordedRequests.first)
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("/chat/completions"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.timeoutInterval, 15)

        let body = try JSONSerialization.jsonObject(
            with: XCTUnwrap(request.bodyData)) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["temperature"] as? Double, 0.2)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["keep_alive"] as? String, "30m")
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        let messages = body["messages"] as! [[String: String]]
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertTrue(messages[0]["content"]!.contains("口头禅"))
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(messages[1]["content"], "嗯这是一段测试文本")
    }

    func testAPIKeyAddsAuthorizationHeader() async throws {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let cloudService = PolishService(
            session: URLSession(configuration: cfg),
            configProvider: {
                PolishConfig(
                    enabled: true, baseURL: "https://api.example.com/v1", apiKey: "sk-test",
                    model: "m", style: .clean)
            })
        stubSuccess(content: "结果")
        _ = await cloudService.polish("嗯这是一段测试文本")
        let request = try XCTUnwrap(MockURLProtocol.recordedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testSuccessReturnsTrimmedContent() async {
        stubSuccess(content: "\n  明天上午九点开会。  \n")
        let result = await service.polish("明天下午呃不对是明天上午九点开会")
        XCTAssertEqual(result, "明天上午九点开会。")
    }

    func testStripsThinkTags() async {
        stubSuccess(content: "<think>用户想清理文本…\n多行思考</think>\n明天上午九点开会。")
        let result = await service.polish("明天下午呃不对是明天上午九点开会")
        XCTAssertEqual(result, "明天上午九点开会。")
    }

    func testHTTPErrorReturnsNil() async {
        MockURLProtocol.handler = { request in
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let result = await service.polish("嗯这是一段测试文本")
        XCTAssertNil(result)
    }

    func testNetworkErrorReturnsNil() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let result = await service.polish("嗯这是一段测试文本")
        XCTAssertNil(result)
    }

    func testEmptyContentReturnsNil() async {
        stubSuccess(content: "   ")
        let result = await service.polish("嗯这是一段测试文本")
        XCTAssertNil(result)
    }

    func testOverlongContentReturnsNil() async {
        stubSuccess(content: String(repeating: "废", count: 200))
        let result = await service.polish("嗯这是一段测试文本")  // 9 字，3 倍上限 27
        XCTAssertNil(result)
    }

    func testProbeParsesOllamaTags() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/tags")
            let json = ["models": [["name": "qwen3.5:4b-nvfp4"], ["name": "other:1b"]]]
            let data = try JSONSerialization.data(withJSONObject: json)
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, data)
        }
        let result = await service.probe()
        XCTAssertTrue(result.reachable)
        XCTAssertEqual(result.models, ["qwen3.5:4b-nvfp4", "other:1b"])
    }

    func testProbeConnectionRefused() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let result = await service.probe()
        XCTAssertFalse(result.reachable)
        XCTAssertTrue(result.models.isEmpty)
        XCTAssertNotNil(result.errorMessage)
    }
}
