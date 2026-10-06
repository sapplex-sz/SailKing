import Foundation

public struct CloudTranslationClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    public static func endpoint(base: String, path: String) throws -> URL {
        guard let parts = URLComponents(string: base), parts.scheme == "https",
              parts.host != nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let url = parts.url else { throw EngineError.invalidServiceURL }
        return url.appendingPathComponent(path)
    }

    public func catalog(base: String) async throws -> ModelCatalog {
        var request = URLRequest(url: try Self.endpoint(base: base, path: "config"))
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data = try await send(request)
        return try JSONDecoder().decode(ModelCatalog.self, from: data).validated()
    }

    public func translate(text: String, source: String?, target: String, market: String,
                          modelID: String, base: String, accessCode: String) async throws -> String {
        guard !accessCode.isEmpty else { throw EngineError.authenticationRequired }
        guard !modelID.isEmpty else { throw EngineError.cloudNotConfigured }
        struct Input: Encodable {
            let text: String; let source: String?; let target: String; let market: String
            let modelID: String; let requestID: String
        }
        struct Output: Decodable { let text: String; let modelID: String; let requestID: String }
        let id = UUID().uuidString
        var request = URLRequest(url: try Self.endpoint(base: base, path: "translate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + accessCode, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Input(text: text, source: source, target: target,
            market: market, modelID: modelID, requestID: id))
        let response = try JSONDecoder().decode(Output.self, from: await send(request))
        guard response.requestID == id, response.modelID == modelID else { throw EngineError.invalidResponse }
        return try TranslationPrompt.clean(response.text)
    }

    public func translateStreaming(text: String, source: String?, target: String, market: String,
                                   modelID: String, base: String, accessCode: String,
                                   onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        guard !accessCode.isEmpty else { throw EngineError.authenticationRequired }
        guard !modelID.isEmpty else { throw EngineError.cloudNotConfigured }
        struct Input: Encodable {
            let text: String; let source: String?; let target: String; let market: String
            let modelID: String; let requestID: String
        }
        let id = UUID().uuidString
        var request = URLRequest(url: try Self.endpoint(base: base, path: "translate/stream"))
        request.httpMethod = "POST"
        request.timeoutInterval = 75
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + accessCode, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Input(text: text, source: source, target: target,
            market: market, modelID: modelID, requestID: id))
        let (bytes, response) = try await session.bytes(for: request, delegate: NoServiceRedirect())
        defer { bytes.task.cancel() }
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, http.statusCode == 502 {
            var errorData = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                errorData.append(byte)
                guard errorData.count <= 16_384 else { throw EngineError.serviceUnavailable }
            }
            struct Failure: Decodable { struct Body: Decodable { let code: String }; let error: Body }
            if (try? JSONDecoder().decode(Failure.self, from: errorData))?.error.code == "stream_not_supported" {
                throw EngineError.streamingUnsupported
            }
        }
        try Self.check(response)
        guard let response = response as? HTTPURLResponse,
              response.mimeType?.lowercased() == "text/event-stream" else { throw EngineError.invalidResponse }
        var decoder = TranslationStreamDecoder(requestID: id, modelID: modelID)
        // Decode at record boundaries without waiting for the complete HTTP body.
        var chunk = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            if byte == 10 || chunk.count >= 4096 {
                for preview in try decoder.append(chunk) { onUpdate(preview) }
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        if !chunk.isEmpty { for preview in try decoder.append(chunk) { onUpdate(preview) } }
        return try decoder.finish()
    }

    private func send(_ request: URLRequest) async throws -> Data {
        // Never follow a redirect with text or a bearer code to a second endpoint.
        let (data, response) = try await session.data(for: request, delegate: NoServiceRedirect())
        try Task.checkCancellation()
        try Self.check(response)
        guard data.count <= 1_000_000 else { throw EngineError.invalidResponse }
        return data
    }

    private static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw EngineError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 401, 403: throw EngineError.authenticationRequired
        case 429: throw EngineError.rateLimited
        default: throw EngineError.serviceUnavailable
        }
    }
}

private final class NoServiceRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
