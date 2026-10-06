#if canImport(CHaHaRuntime) && os(macOS)
import Foundation
import CHaHaRuntime

private func L(_ text: String, _ arguments: CVarArg...) -> String {
    let translations = [
        "翻译正在进行，请先取消当前任务。": "Translation is in progress. Cancel the current task first.",
        "可用内存不足，请关闭其他应用后重试。": "Not enough available memory. Close other apps and retry.",
        "请选择有效的源语言和目标语言。": "Choose valid source and target languages.",
        "原文含有空字符，无法作为文本翻译。请清除空字符后重试。": "Remove null characters from the input and try again.",
        "模型没有返回译文，请尝试缩短原文后重试。": "No translation was returned. Try a shorter passage.",
        "当前段落超过模型长度限制，请分成更短的段落。": "This passage exceeds the model context. Split it into shorter passages.",
        "译文达到长度限制，请缩短段落后重试。": "The translation reached the output limit. Try a shorter passage.",
        "本地翻译失败：%@": "Local translation failed: %@",
        "推理引擎错误（%d）": "Inference error (%d)"
    ]
    let value = (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? text : translations[text] ?? text
    return String(format: value, arguments: arguments)
}

enum LocalTranslationError: LocalizedError, Sendable {
    case busy
    case allocationFailed
    case invalidLanguage
    case invalidText
    case emptyTranslation
    case inputTooLong
    case outputLimit
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .busy: return L("翻译正在进行，请先取消当前任务。")
        case .allocationFailed: return L("可用内存不足，请关闭其他应用后重试。")
        case .invalidLanguage: return L("请选择有效的源语言和目标语言。")
        case .invalidText: return L("原文含有空字符，无法作为文本翻译。请清除空字符后重试。")
        case .emptyTranslation: return L("模型没有返回译文，请尝试缩短原文后重试。")
        case .inputTooLong: return L("当前段落超过模型长度限制，请分成更短的段落。")
        case .outputLimit: return L("译文达到长度限制，请缩短段落后重试。")
        case .runtime(let message): return L("本地翻译失败：%@", message)
        }
    }
}

// Engine access is serialized by LocalTranslationEngine. The detached task owns
// a strong reference for its full lifetime, including token callbacks.
private final class RuntimeHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init() throws {
        guard let pointer = haha_engine_create() else { throw LocalTranslationError.allocationFailed }
        self.pointer = pointer
    }
    deinit { haha_engine_destroy(pointer) }
}

private final class RuntimeCancellation: @unchecked Sendable {
    let pointer: OpaquePointer
    init() throws {
        guard let pointer = haha_cancellation_create() else { throw LocalTranslationError.allocationFailed }
        self.pointer = pointer
    }
    func cancel() { haha_cancellation_request(pointer) }
    deinit { haha_cancellation_destroy(pointer) }
}

private final class TokenReceiver {
    let receive: @Sendable (String) -> Void
    init(_ receive: @escaping @Sendable (String) -> Void) { self.receive = receive }
}

/// Native, offline Hy-MT2 inference. onToken supplies incremental UTF-8 chunks.
/// No Python environment, HTTP server, user text logging, or network calls.
actor LocalTranslationEngine {
    private var handle: RuntimeHandle?
    private var activeTask: Task<String, Error>?
    private var activeCancellation: RuntimeCancellation?
    private var activeID: UUID?
    private var isUnloading = false

    nonisolated static var runtimeVersion: String { String(cString: haha_runtime_version()) }

    func translate(
        text: String,
        sourceLanguage: String?,
        targetLanguage: String,
        modelURL: URL,
        glossary: [String: String] = [:],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        // A newer committed edit replaces inference on the same native handle.
        // Join the cancelled worker before starting again, including when three
        // successive edits arrive while the first worker is still unwinding.
        while let previous = activeTask {
            let previousID = activeID
            activeCancellation?.cancel()
            _ = await previous.result
            try Task.checkCancellation()
            if activeID == previousID {
                activeTask = nil
                activeCancellation = nil
                activeID = nil
            }
        }
        guard !isUnloading else { throw LocalTranslationError.busy }
        let languages = [targetLanguage] + (sourceLanguage.map { [$0] } ?? [])
        guard languages.allSatisfy({ language in
            !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !language.contains("\n") && !language.contains("\r") &&
            !language.contains("\0") && language.count < 80
        }) else {
            throw LocalTranslationError.invalidLanguage
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard !text.contains("\0") else { throw LocalTranslationError.invalidText }
        if handle == nil { handle = try RuntimeHandle() }
        guard let runtime = handle else { throw LocalTranslationError.allocationFailed }
        let cancellation = try RuntimeCancellation()
        let id = UUID()
        let prompt = Self.translationPrompt(text: text, sourceLanguage: sourceLanguage,
                                            targetLanguage: targetLanguage, glossary: glossary)
        let task = Task.detached(priority: .userInitiated) { () throws -> String in
            let receiver = TokenReceiver(onToken)
            let receiverPointer = Unmanaged.passUnretained(receiver).toOpaque()
            var output: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            var metrics = haha_metrics()
            let status = withExtendedLifetime(receiver) {
                modelURL.path.withCString { path in
                    prompt.withCString { input in
                        haha_engine_translate(runtime.pointer, path, input, 2048, cancellation.pointer,
                            { bytes, length, opaque in
                                guard let bytes, let opaque, length > 0 else { return }
                                let receiver = Unmanaged<TokenReceiver>.fromOpaque(opaque).takeUnretainedValue()
                                let buffer = UnsafeRawBufferPointer(start: bytes, count: length)
                                receiver.receive(String(decoding: buffer, as: UTF8.self))
                            }, receiverPointer, &output, &error, &metrics)
                    }
                }
            }
            defer { haha_string_free(output); haha_string_free(error) }
            switch status {
            case Int32(HAHA_CANCELLED.rawValue): throw CancellationError()
            case Int32(HAHA_CONTEXT_LIMIT.rawValue): throw LocalTranslationError.inputTooLong
            case Int32(HAHA_OUTPUT_LIMIT.rawValue): throw LocalTranslationError.outputLimit
            case Int32(HAHA_OK.rawValue):
                guard let output else { throw LocalTranslationError.emptyTranslation }
                let result = String(cString: output).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !result.isEmpty else { throw LocalTranslationError.emptyTranslation }
                return result
            default:
                throw LocalTranslationError.runtime(error.map { String(cString: $0) } ?? L("推理引擎错误（%d）", status))
            }
        }
        activeID = id
        activeTask = task
        activeCancellation = cancellation
        defer {
            if activeID == id {
                activeTask = nil
                activeCancellation = nil
                activeID = nil
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }

    /// Nonblocking: sets an atomic flag observed during loading, prefill and decode.
    func cancel() async { activeCancellation?.cancel() }

    /// Cancels and joins inference before releasing the model and KV allocation.
    func unload() async {
        guard !isUnloading else { return }
        isUnloading = true
        activeCancellation?.cancel()
        if let task = activeTask { _ = await task.result }
        if let runtime = handle {
            await Task.detached(priority: .utility) { haha_engine_unload(runtime.pointer) }.value
        }
        activeTask = nil
        activeCancellation = nil
        activeID = nil
        isUnloading = false
    }

    // Official English task template; language values are full names, not ISO codes.
    // Automatic mode keeps the official template unchanged. A manual language
    // supplies disambiguating context for short text such as the German "Gift".
    private nonisolated static func translationPrompt(text: String, sourceLanguage: String?,
        targetLanguage: String, glossary: [String: String]) -> String {
        let relevant = glossary.filter {
            !$0.key.isEmpty && !$0.key.contains("\0") && !$0.value.contains("\0") && text.localizedCaseInsensitiveContains($0.key)
        }
        let terms = relevant.sorted { $0.key < $1.key }.prefix(50).map {
            "\($0.key.replacingOccurrences(of: "\n", with: " ")) translates to \($0.value.replacingOccurrences(of: "\n", with: " "))"
        }
        let prefix = terms.isEmpty ? "" : "Reference the following translations:\n" + terms.joined(separator: "\n") + "\n\n"
        // The pinned models may ignore a standalone hint; retain the language in
        // both clauses, as exercised by the German/English short-word regression.
        let sourceText = sourceLanguage.map { "\($0) text" } ?? "text"
        let sourceHint = sourceLanguage.map { " The source language is \($0)." } ?? ""
        return prefix + "Translate the following \(sourceText) into \(targetLanguage).\(sourceHint) Note that you should only output the translated result without any additional explanation:\n\n" + text
    }
}

#endif
