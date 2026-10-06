import XCTest
@testable import HaiwangCore

final class TranslationStreamTests: XCTestCase {
    private func event(_ kind: String, text: String, id: String = "request", model: String = "model") throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: ["requestID": id, "modelID": model, "text": text])
        return Data("event: \(kind)\r\ndata: \(String(decoding: json, as: UTF8.self))\r\n\r\n".utf8)
    }
    func testEveryUTF8ByteBoundaryRetainsJapaneseArabicEmojiAndLineBreaks() throws {
        let text = "ご注文 DEMO-482\nمرحبا 👋🏽 e\u{301}"
        var stream = Data(": heartbeat\r\n\r\n".utf8)
        stream.append(try event("delta", text: text))
        stream.append(try event("done", text: text))
        var decoder = TranslationStreamDecoder(requestID: "request", modelID: "model")
        var previews: [String] = []
        for byte in stream { previews += try decoder.append(Data([byte])) }
        XCTAssertEqual(previews, [text])
        XCTAssertEqual(try decoder.finish(), text)
    }
    func testPartialOutputIsNotACompletedTranslation() throws {
        var decoder = TranslationStreamDecoder(requestID: "request", modelID: "model")
        XCTAssertEqual(try decoder.append(event("delta", text: "Bonjour")), ["Bonjour"])
        XCTAssertNil(decoder.completedText)
        XCTAssertThrowsError(try decoder.finish())
    }
    func testOnlyMatchingRequestAndModelCanProduceProgress() throws {
        for stream in [try event("delta", text: "old", id: "old"), try event("done", text: "old", model: "other")] {
            var decoder = TranslationStreamDecoder(requestID: "request", modelID: "model")
            XCTAssertThrowsError(try decoder.append(stream))
        }
    }
    func testDoneCannotReplaceStreamWithUnrelatedText() throws {
        var decoder = TranslationStreamDecoder(requestID: "request", modelID: "model")
        _ = try decoder.append(event("delta", text: "Bonjour"))
        XCTAssertThrowsError(try decoder.append(event("done", text: "Goodbye")))
    }
    func testErrorsAndBareProviderDoneNeverCommitAPreview() throws {
        for tail in [Data("event: error\ndata: {\"error\":{\"code\":\"translation_timeout\",\"message\":\"private provider detail\"}}\n\n".utf8), Data("data: [DONE]\n\n".utf8)] {
            var decoder = TranslationStreamDecoder(requestID: "request", modelID: "model")
            _ = try decoder.append(event("delta", text: "Bonjour"))
            do { _ = try decoder.append(tail); XCTFail("Invalid completion") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private provider")) }
            XCTAssertNil(decoder.completedText)
        }
    }
    func testMalformedUTF8IncompleteRecordsAndOversizedEventsAreRejected() throws {
        var invalid = TranslationStreamDecoder(requestID: "request", modelID: "model")
        XCTAssertThrowsError(try invalid.append(Data([0xFF, 0x0A])))
        var incomplete = TranslationStreamDecoder(requestID: "request", modelID: "model")
        _ = try incomplete.append(Data("event: done\ndata: {}\n".utf8))
        XCTAssertThrowsError(try incomplete.finish())
        var oversized = TranslationStreamDecoder(requestID: "request", modelID: "model")
        XCTAssertThrowsError(try oversized.append(Data(repeating: 65, count: 65_537)))
    }
    func testDuplicateAndTrailingEventsAreRejected() throws {
        var decoder = TranslationStreamDecoder(requestID: "request", modelID: "model")
        _ = try decoder.append(event("done", text: "Bonjour"))
        XCTAssertThrowsError(try decoder.append(event("delta", text: "later")))
    }
    func testFragmentedReasoningPrefixDoesNotAppearInPreviews() {
        for raw in ["", " ", "<", "<th", "<think>", "<think>private", "<think>private</thi"] {
            XCTAssertEqual(TranslationPreview.text(raw), "")
        }
        XCTAssertEqual(TranslationPreview.text("<think>private</think> Bonjour"), "Bonjour")
        XCTAssertEqual(TranslationPreview.text("Example: </think> is literal."), "Example: </think> is literal.")
        XCTAssertEqual(TranslationPreview.text("<product>"), "<product>")
    }
    func testStructuredStreamErrorCodesRemainActionableWithoutProviderDetails() throws {
        let cases: [(String, EngineError)] = [
            ("stream_not_supported", .streamingUnsupported),
            ("output_too_long", .outputTooLong),
            ("translation_too_long", .outputTooLong),
            ("authentication_required", .authenticationRequired),
            ("code_rate_limited", .rateLimited),
            ("unexpected_provider_failure", .serviceUnavailable)
        ]
        for (code, expected) in cases {
            var decoder = TranslationStreamDecoder(requestID: "request", modelID: "model")
            _ = try decoder.append(event("delta", text: "Provisional"))
            let body = try JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": "private provider diagnostics"]])
            let frame = Data("event: error\ndata: \(String(decoding: body, as: UTF8.self))\n\n".utf8)
            XCTAssertThrowsError(try decoder.append(frame)) { error in
                XCTAssertTrue(error is EngineError)
                XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("private provider"))
            }
            XCTAssertNil(decoder.completedText)
            XCTAssertThrowsError(try decoder.finish())
        }
    }
}

private final class StreamLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var stopped = false
    private var chunks = 0
    func didDeliver() { lock.withLock { chunks += 1 } }
    func didFinish() { lock.withLock { finished = true } }
    func didStop() { lock.withLock { stopped = true } }
    var snapshot: (finished: Bool, stopped: Bool, chunks: Int) {
        lock.withLock { (finished, stopped, chunks) }
    }
}

/// Only this serial queue invokes the protocol client. The small cancellation
/// lock protects the flag shared with URLSession's stopLoading callback.
private final class StreamDelivery: @unchecked Sendable {
    private weak var owner: URLProtocol?
    private let chunks: [Data]
    private let lifecycle: StreamLifecycle?
    private let queue = DispatchQueue(label: "HaiwangTests.StreamDelivery")
    private let lock = NSLock()
    private var cancelled = false
    init(owner: URLProtocol, chunks: [Data], lifecycle: StreamLifecycle?) {
        self.owner = owner
        self.chunks = chunks
        self.lifecycle = lifecycle
    }
    func start() { schedule(0) }
    func cancel() {
        lock.withLock { cancelled = true }
        // Ordering this marker on the delivery queue makes it possible to assert
        // that no further chunks arrive after URLSession cancellation settles.
        queue.async { self.lifecycle?.didStop() }
    }
    private func schedule(_ index: Int) {
        queue.asyncAfter(deadline: .now() + .milliseconds(index < chunks.count ? 50 : 100)) {
            guard !self.lock.withLock({ self.cancelled }), let owner = self.owner else { return }
            if index < self.chunks.count {
                self.lifecycle?.didDeliver()
                owner.client?.urlProtocol(owner, didLoad: self.chunks[index])
                self.schedule(index + 1)
            } else {
                self.lifecycle?.didFinish()
                owner.client?.urlProtocolDidFinishLoading(owner)
            }
        }
    }
}

private final class StreamProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String, [Data], StreamLifecycle?))?
    private let deliveryLock = NSLock()
    private var delivery: StreamDelivery?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, mime, chunks, lifecycle) = try Self.handler!(request)
            let pending = StreamDelivery(owner: self, chunks: chunks, lifecycle: lifecycle)
            deliveryLock.withLock { delivery = pending }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":mime])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            pending.start()
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {
        let pending = deliveryLock.withLock { let value = delivery; delivery = nil; return value }
        pending?.cancel()
    }
}

private final class PreviewCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var snapshots: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

final class CloudStreamingTests: XCTestCase, @unchecked Sendable {
    override func tearDown() {
        StreamProtocol.handler = nil
        super.tearDown()
    }
    private func client() -> CloudTranslationClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamProtocol.self]
        return CloudTranslationClient(session: URLSession(configuration: config))
    }
    private func input(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else {
            let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 10000)
            let count = stream.read(&bytes, maxLength: bytes.count)
            data = Data(bytes.prefix(count))
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    private func translate(_ collector: PreviewCollector) async throws -> String {
        try await client().translateStreaming(text: "Merci DEMO-482", source: "fr", target: "ja", market: "japan", modelID: "model", base: EnginePreferences().serviceURL, accessCode: "fixture-service-code", onUpdate: { collector.add($0) })
    }
    func testProgressArrivesBeforeTheResponseFinishes() async throws {
        let lifecycle = StreamLifecycle()
        StreamProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/app-api/haiwang/translate/stream")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-service-code")
            let id = try self.input(request)["requestID"] as! String
            func event(_ kind: String, _ text: String) throws -> Data {
                let data = try JSONSerialization.data(withJSONObject: ["requestID":id,"modelID":"model","text":text])
                return Data("event: \(kind)\ndata: \(String(decoding:data,as:UTF8.self))\n\n".utf8)
            }
            return (200, "text/event-stream; charset=utf-8", [try event("delta", "DEMO-482 "), try event("delta", "ありがとうございます"), try event("done", "DEMO-482 ありがとうございます")], lifecycle)
        }
        let collector = PreviewCollector()
        let operation = Task { try await self.translate(collector) }
        for _ in 0..<100 {
            if !collector.snapshots.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(collector.snapshots.first, "DEMO-482")
        XCTAssertFalse(lifecycle.snapshot.finished, "The first preview must be available before HTTP EOF")
        let result = try await operation.value
        XCTAssertEqual(result, "DEMO-482 ありがとうございます")
        XCTAssertEqual(collector.snapshots.last, "DEMO-482 ありがとうございます")
        XCTAssertTrue(lifecycle.snapshot.finished)
    }
    func testWrongContentTypeAndHTTPStatusDoNotExposeProviderBody() async {
        for status in [200,401,429,503] {
            StreamProtocol.handler = { _ in (status, "application/json", [Data("private diagnostics".utf8)], nil) }
            do { _ = try await translate(PreviewCollector()); XCTFail("Not SSE") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private diagnostics")) }
        }
    }
    func testHTTP502StreamingUnsupportedUsesSafeStructuredCode() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["error": ["code": "stream_not_supported", "message": "private provider diagnostics"]])
        StreamProtocol.handler = { _ in (502, "application/json", [body.prefix(11), body.dropFirst(11)], nil) }
        let collector = PreviewCollector()
        do { _ = try await translate(collector); XCTFail("Unsupported streaming must fail") }
        catch {
            guard case EngineError.streamingUnsupported = error else {
                return XCTFail("Expected the actionable streamingUnsupported error, got \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains("private provider"))
        }
        XCTAssertTrue(collector.snapshots.isEmpty)
    }
    func testHTTP502UnknownOrOversizedBodyCannotExposeProviderDetails() async throws {
        let unknown = try JSONSerialization.data(withJSONObject: ["error": ["code": "provider_private_failure", "message": "private provider diagnostics"]])
        for body in [unknown, Data("private provider diagnostics".utf8) + Data(repeating: 65, count: 16_384)] {
            let lifecycle = StreamLifecycle()
            StreamProtocol.handler = { _ in (502, "application/json", [body], lifecycle) }
            do { _ = try await translate(PreviewCollector()); XCTFail("HTTP 502 cannot produce a translation") }
            catch {
                guard case EngineError.serviceUnavailable = error else {
                    return XCTFail("Expected a safe serviceUnavailable error, got \(error)")
                }
                XCTAssertFalse(error.localizedDescription.contains("private provider"))
            }
        }
    }
    func testCancellationStopsAResponseBetweenEvents() async throws {
        let lifecycle = StreamLifecycle()
        StreamProtocol.handler = { request in
            let id = try self.input(request)["requestID"] as! String
            let json = try JSONSerialization.data(withJSONObject: ["requestID":id,"modelID":"model","text":"Bonjour"])
            return (200,"text/event-stream",[Data("event: delta\ndata: \(String(decoding:json,as:UTF8.self))\n\n".utf8)] + Array(repeating:Data(": heartbeat\n\n".utf8),count:100), lifecycle)
        }
        let collector = PreviewCollector()
        let operation = Task { try await self.translate(collector) }
        for _ in 0..<100 {
            if !collector.snapshots.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(collector.snapshots.first,"Bonjour")
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled stream cannot finish") }
        catch { XCTAssertTrue(error is CancellationError || (error as NSError).code == NSURLErrorCancelled) }
        for _ in 0..<100 {
            if lifecycle.snapshot.stopped { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(lifecycle.snapshot.stopped, "Cancellation must stop the underlying URLSession task")
        let delivered = lifecycle.snapshot.chunks
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(lifecycle.snapshot.chunks, delivered)
        XCTAssertFalse(lifecycle.snapshot.finished, "A cancelled stream must never deliver successful EOF")
    }
}
