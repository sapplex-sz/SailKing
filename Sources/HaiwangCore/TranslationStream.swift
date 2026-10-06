import Foundation

/// Converts an unfinished model response into a display-only preview. Never
/// publish reasoning, including when its opening tag arrives over several chunks.
public enum TranslationPreview {
    public static func text(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if "<think>".hasPrefix(text) { return "" }
        if text.hasPrefix("<think>") {
            guard let end = text.range(of: "</think>") else { return "" }
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

/// Strict, bounded SSE decoding. A preview is provisional until a matching
/// `done` event arrives; EOF or a provider's bare [DONE] never commits a result.
public struct TranslationStreamDecoder: Sendable {
    private let requestID: String
    private let modelID: String
    private var line = Data()
    private var event = "message"
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var totalBytes = 0
    private var accumulated = ""
    private var terminated = false
    public private(set) var completedText: String?

    public init(requestID: String, modelID: String) {
        self.requestID = requestID
        self.modelID = modelID
    }

    /// Returns cumulative previews, preserving multi-byte text across network boundaries.
    public mutating func append(_ chunk: Data) throws -> [String] {
        var previews: [String] = []
        for byte in chunk {
            totalBytes += 1
            guard totalBytes <= 1_000_000 else { throw EngineError.outputTooLong }
            if byte == 10 {
                if let preview = try consumeLine() { previews.append(preview) }
            } else {
                line.append(byte)
                guard line.count <= 65_536 else { throw EngineError.outputTooLong }
            }
        }
        return previews
    }

    public mutating func finish() throws -> String {
        // SSE records must end with a blank line. Ignore only whitespace at EOF.
        guard line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }), dataLines.isEmpty,
              let completedText else { throw EngineError.invalidResponse }
        return completedText
    }

    private mutating func consumeLine() throws -> String? {
        if line.last == 13 { line.removeLast() }
        guard let value = String(data: line, encoding: .utf8) else { throw EngineError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if value.isEmpty {
            defer { event = "message"; dataLines.removeAll(keepingCapacity: true); eventBytes = 0 }
            guard !dataLines.isEmpty else { return nil }
            guard !terminated else { throw EngineError.invalidResponse }
            return try consumeEvent(Data(dataLines.joined(separator: "\n").utf8))
        }
        if value.hasPrefix(":") { return nil }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var content = parts.count == 2 ? String(parts[1]) : ""
        if content.hasPrefix(" ") { content.removeFirst() }
        switch field {
        case "event": event = content
        case "data":
            eventBytes += content.utf8.count + 1
            guard eventBytes <= 262_144 else { throw EngineError.outputTooLong }
            dataLines.append(content)
        default: break
        }
        return nil
    }

    private mutating func consumeEvent(_ data: Data) throws -> String? {
        if event == "error" {
            struct Failure: Decodable { struct Body: Decodable { let code: String }; let error: Body }
            guard let failure = try? JSONDecoder().decode(Failure.self, from: data) else { throw EngineError.invalidResponse }
            terminated = true
            switch failure.error.code {
            case "authentication_required": throw EngineError.authenticationRequired
            case "ip_rate_limited", "code_rate_limited": throw EngineError.rateLimited
            case "translation_too_long", "output_too_long": throw EngineError.outputTooLong
            case "stream_not_supported": throw EngineError.streamingUnsupported
            default: throw EngineError.serviceUnavailable
            }
        }
        guard event == "delta" || event == "done" else { throw EngineError.invalidResponse }
        struct Message: Decodable { let requestID: String; let modelID: String; let text: String }
        guard let message = try? JSONDecoder().decode(Message.self, from: data),
              message.requestID == requestID, message.modelID == modelID else { throw EngineError.invalidResponse }
        if event == "delta" {
            accumulated += message.text
            guard accumulated.utf8.count <= 262_144 else { throw EngineError.outputTooLong }
            return TranslationPreview.text(accumulated)
        }
        let result = try TranslationPrompt.clean(message.text)
        if !accumulated.isEmpty {
            guard try TranslationPrompt.clean(accumulated) == result else { throw EngineError.invalidResponse }
        }
        completedText = result
        terminated = true
        return nil
    }
}
