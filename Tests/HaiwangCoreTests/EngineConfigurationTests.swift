import XCTest
@testable import HaiwangCore

final class EngineConfigurationTests: XCTestCase {
    func testBundledCatalogHasPinnedCommercialTranslationModels() throws {
        let catalog = try ModelCatalog.bundled.validated()
        XCTAssertEqual(catalog.defaultLocalModelID, "hy-mt2-light")
        XCTAssertEqual(catalog.localModels[0].downloadBytes, 461_860_800)
        XCTAssertTrue(catalog.apiModels.isEmpty)
        XCTAssertFalse(EnginePreferences().cloudFallbackEnabled)
        XCTAssertEqual(EnginePreferences().localModelID, "", "An untouched client follows the backend default")
        XCTAssertEqual(EnginePreferences().serviceURL, "https://www.octsz.com/app-api/haiwang")
        XCTAssertEqual(try JSONDecoder().decode(ModelCatalog.self, from: JSONEncoder().encode(catalog)), catalog)
    }
    func testInvalidModelDoesNotBecomeDownloadPath() {
        let original = ModelCatalog.bundled.localModels[0]
        for filename in ["../model.gguf", "weights.safetensors", "/tmp/model.gguf", "model.gguf?token=abc"] {
            let model = LocalModelDescriptor(id: "bad", name: "bad", repository: original.repository,
                revision: original.revision, downloadBytes: original.downloadBytes, minimumMemoryGB: 4,
                filename: filename, sha256: original.sha256)
            XCTAssertFalse(model.isValid)
        }
        let movingRevision = LocalModelDescriptor(id: "bad", name: "bad", repository: original.repository,
            revision: "main", downloadBytes: original.downloadBytes, minimumMemoryGB: 4,
            filename: original.filename, sha256: original.sha256)
        XCTAssertFalse(movingRevision.isValid)
    }
    func testRejectDuplicateModelsAndUnknownSchema() throws {
        let local = ModelCatalog.bundled.localModels[0]
        XCTAssertThrowsError(try ModelCatalog(revision: "test", defaultLocalModelID: local.id,
            defaultAPIModelID: "", localModels: [local,local], apiModels: []).validated())
        XCTAssertThrowsError(try ModelCatalog(schemaVersion: 9, revision: "test", defaultLocalModelID: local.id,
            defaultAPIModelID: "", localModels: [local], apiModels: []).validated())
    }
    func testServiceEndpointRejectsCredentialsAndInsecureSchemes() throws {
        for base in ["http://octsz.com", "file:///tmp/key", "https://user:key@octsz.com", "https://octsz.com?token=x", "https://octsz.com#fragment"] {
            XCTAssertThrowsError(try CloudTranslationClient.endpoint(base: base, path: "translate"))
        }
        XCTAssertEqual(try CloudTranslationClient.endpoint(base: "https://www.octsz.com/app-api/haiwang", path: "config").absoluteString,
            "https://www.octsz.com/app-api/haiwang/config")
    }
    func testReasoningAndEmptyResponsesCannotLeakAsTranslation() throws {
        XCTAssertEqual(try TranslationPrompt.clean("<think>reasoning</think> Bonjour "), "Bonjour")
        XCTAssertEqual(try TranslationPrompt.clean("Example: </think> must remain literal."), "Example: </think> must remain literal.")
        XCTAssertThrowsError(try TranslationPrompt.clean("<think>unfinished"))
        XCTAssertThrowsError(try TranslationPrompt.clean("  \n "))
    }
}

private final class ServiceProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class CloudTranslationClientTests: XCTestCase {
    private func client() -> CloudTranslationClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ServiceProtocol.self]
        return CloudTranslationClient(session: URLSession(configuration: config))
    }
    func testCatalogCannotReturnSecretsAsRequiredClientFields() async throws {
        ServiceProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.path, "/app-api/haiwang/config")
            return (200, try JSONEncoder().encode(ModelCatalog.bundled))
        }
        let value = try await client().catalog(base: EnginePreferences().serviceURL)
        XCTAssertEqual(value.defaultLocalModelID, "hy-mt2-light")
    }
    func testCloudPreservesMultilingualTextAndResponseIdentity() async throws {
        ServiceProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-fixture-only")
            let data: Data
            if let body = request.httpBody { data = body }
            else {
                let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 10000)
                let count = stream.read(&bytes, maxLength: bytes.count)
                data = Data(bytes.prefix(count))
            }
            let input = try JSONSerialization.jsonObject(with: data) as! [String:Any]
            XCTAssertEqual(input["text"] as? String, "Merci pour DEMO-482 👋")
            XCTAssertEqual(input["target"] as? String, "ja")
            return (200, try JSONSerialization.data(withJSONObject: ["text":"DEMO-482 ありがとうございます 👋", "modelID":"test-model", "requestID":input["requestID"]!]))
        }
        let result = try await client().translate(text: "Merci pour DEMO-482 👋", source: "fr", target: "ja", market: "japan", modelID: "test-model", base: EnginePreferences().serviceURL, accessCode: "test-fixture-only")
        XCTAssertEqual(result, "DEMO-482 ありがとうございます 👋")
    }
    func testAuthenticationAndQuotaFailureAreSafeErrors() async {
        for status in [401,429,503] {
            ServiceProtocol.handler = { _ in (status, Data("secret upstream diagnostic".utf8)) }
            do {
                _ = try await client().translate(text: "Bonjour", source: "fr", target: "ja", market: "japan", modelID: "fixture", base: EnginePreferences().serviceURL, accessCode: "test-fixture-only")
                XCTFail("Expected service failure")
            } catch { XCTAssertFalse(error.localizedDescription.contains("secret")) }
        }
    }
    func testUnmatchedRequestCannotBecomeTranslation() async throws {
        ServiceProtocol.handler = { _ in (200, Data(#"{"text":"wrong result","modelID":"fixture","requestID":"old-request"}"#.utf8)) }
        do {
            _ = try await client().translate(text: "Hello", source: "en", target: "ja", market: "japan", modelID: "fixture", base: EnginePreferences().serviceURL, accessCode: "test-fixture-only")
            XCTFail("Expected identity validation")
        } catch { XCTAssertTrue(error is EngineError) }
    }
}

final class ProtectedTextTests: XCTestCase {
    func testIdentifiersURLsAndEmailAreProtectedWithoutTreatingNormalWordsAsIDs() throws {
        let source = "Merci pour DEMO-310, SKU-A17. Contact: help@example.com https://example.com/order/310."
        XCTAssertEqual(ProtectedText.entities(in: source), ["DEMO-310", "SKU-A17", "help@example.com", "https://example.com/order/310"])
        XCTAssertNoThrow(try ProtectedText.validate(source: source, output: "DEMO-310、SKU-A17。 help@example.com https://example.com/order/310"))
        XCTAssertThrowsError(try ProtectedText.validate(source: source, output: "演示-310"))
        XCTAssertThrowsError(try ProtectedText.validate(source: "订单DEMO-310已确认", output: "演示-310"))
        XCTAssertThrowsError(try ProtectedText.validate(source: "订单DEMO-310已确认", output: "DEMO-3100"))
        XCTAssertThrowsError(try ProtectedText.validate(source: "Use SEA10", output: "Use SEA100"))
        XCTAssertThrowsError(try ProtectedText.validate(source: "DEMO-310 DEMO-310", output: "DEMO-310"))
        XCTAssertNoThrow(try ProtectedText.validate(source: "订单DEMO-310已确认", output: "Order DEMO-310 is confirmed"))
        XCTAssertTrue(ProtectedText.entities(in: "bonjour everyone 👋").isEmpty)
        XCTAssertEqual(ProtectedText.entities(in: "DEMO-310 DEMO-310").count, 2)
    }
}
