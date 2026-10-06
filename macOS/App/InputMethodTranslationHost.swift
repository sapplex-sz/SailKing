import Foundation
import HaiwangCore
import NaturalLanguage
import Observation
import Translation

/// The IMK process borrows the main App's model runtime. It owns no model, key,
/// network client, text cache, or translation history of its own.
@MainActor
final class InputMethodTranslationHost {
    static let shared = InputMethodTranslationHost()
    private let server: InputMethodSocketServer
    private let runtime: EngineRuntime
    private var startTask: Task<Void, Never>?
    private var started = false
    private(set) var startupError: String?

    init(runtime: EngineRuntime? = nil, endpointDirectory: URL = InputMethodSocketEndpoint.directory) {
        self.runtime = runtime ?? .shared
        server = InputMethodSocketServer(endpointDirectory: endpointDirectory)
    }

    func start() {
        guard !started, startTask == nil else { return }
        startTask = Task { [weak self] in
            guard let self else { return }
            defer { startTask = nil }
            do {
                try await server.start { [weak self] request in
                    guard let self else { return .init(id: request.id, failure: .unavailable) }
                    return await process(request)
                }
                try Task.checkCancellation()
                started = true
                startupError = nil
            } catch {
                server.stop()
                startupError = (error as? InputMethodTranslationFailure)?.message
                    ?? "输入法翻译服务未能启动，请重新打开出海王输入法 App。"
            }
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        started = false
        server.stop()
    }

    private func process(_ request: InputMethodTranslationRequest) async -> InputMethodTranslationResponse {
        do {
            guard request.version == 1,
                  let market = Market(rawValue: request.market), market.languageIdentifier == request.target,
                  request.source == nil || SourceLanguage.allCases.contains(where: { $0.languageIdentifier == request.source }) else {
                throw InputMethodTranslationFailure.invalidMessage
            }
            let invalidation = InputMethodConfigurationInvalidation()
            let snapshot = withObservationTracking {
                runtime.snapshot()
            } onChange: {
                // Observation fires before the mutation. Remember even a change
                // that is later reverted while the translation is still running.
                invalidation.invalidate()
            }
            let configuration = try publicConfiguration(runtime)
            if request.operation == .configuration {
                guard request.text.isEmpty else { throw InputMethodTranslationFailure.invalidMessage }
                return .init(id: request.id, configuration: configuration)
            }
            guard request.configurationFingerprint == configuration.fingerprint else {
                throw InputMethodTranslationFailure.configurationChanged
            }
            guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw InputMethodTranslationFailure(code: "empty", message: "请先输入需要翻译的文字。")
            }
            guard request.text.count <= 2000 else { throw InputMethodTranslationFailure.textTooLong }
            try Task.checkCancellation()
            let output: String
            switch snapshot.engine {
            case .apple, .localModel:
                if alreadyTargetLanguage(request) {
                    output = request.text
                } else if snapshot.engine == .apple {
                    output = try await translateApple(request)
                } else {
                    output = try await runtime.translate(text: request.text, source: request.source,
                        target: request.target, market: request.market, snapshot: snapshot, streaming: false)
                }
            case .cloud, .automatic:
                throw InputMethodTranslationFailure(code: "unsupportedEngine", message: "Mac 输入法仅支持本地模型和 Apple 翻译，请在出海王输入法 App 中选择。")
            }
            try Task.checkCancellation()
            // Even a settings change followed by a model catalog refresh must
            // not cause a candidate from an earlier configuration to be accepted.
            guard !invalidation.isInvalidated, snapshot == runtime.snapshot(),
                  configuration == (try publicConfiguration(runtime)) else {
                throw InputMethodTranslationFailure.configurationChanged
            }
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, output.count <= 12000 else {
                throw EngineError.invalidResponse
            }
            try ProtectedText.validate(source: request.text, output: output)
            return .init(id: request.id, configuration: configuration, translation: output)
        } catch {
            return .init(id: request.id, failure: failure(error))
        }
    }

    private func publicConfiguration(_ runtime: EngineRuntime) throws -> InputMethodTranslationConfiguration {
        try .make(engine: runtime.resolvedEngine, settings: runtime.settings, catalog: runtime.catalog)
    }

    private func alreadyTargetLanguage(_ request: InputMethodTranslationRequest) -> Bool {
        if let source = request.source { return sameLanguage(source, request.target) }
        guard request.text.filter(\.isLetter).count >= 16 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(request.text)
        guard let strongest = recognizer.languageHypotheses(withMaximum: 1).first,
              strongest.value >= 0.97 else { return false }
        return sameLanguage(strongest.key.rawValue, request.target)
    }

    private func translateApple(_ request: InputMethodTranslationRequest) async throws -> String {
        let target = Locale.Language(identifier: request.target)
        let sourceIdentifier: String
        let availability: LanguageAvailability.Status
        if let source = request.source {
            sourceIdentifier = source
            if sameLanguage(source, request.target) { return request.text }
            availability = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: target)
        } else {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(request.text)
            guard let detected = recognizer.dominantLanguage else {
                throw InputMethodTranslationFailure(code: "sourceUnknown", message: "暂未识别源语言，请补充文字或在输入法面板选择源语言。")
            }
            sourceIdentifier = detected.rawValue
            // Match the workbench's conservative rule before treating an
            // automatically detected sample as already being the target language.
            let strongest = recognizer.languageHypotheses(withMaximum: 1).first
            if request.text.filter(\.isLetter).count >= 16,
               let strongest, strongest.value >= 0.97,
               sameLanguage(sourceIdentifier, request.target) { return request.text }
            if sameLanguage(sourceIdentifier, request.target) {
                throw InputMethodTranslationFailure(code: "sourceAmbiguous", message: "短文本的源语言还不确定，请在输入法面板选择源语言后重试。")
            }
            availability = try await LanguageAvailability().status(for: request.text, to: target)
        }
        try Task.checkCancellation()
        switch availability {
        case .installed: break
        case .supported:
            throw InputMethodTranslationFailure(code: "languagesNotInstalled", message: "这组 Apple 语言包尚未安装。请打开出海王输入法 App 准备语言包后重试，原文已保留。")
        case .unsupported:
            throw InputMethodTranslationFailure(code: "languageUnsupported", message: "Apple 翻译暂不支持这组语言，请在出海王输入法 App 选择本地模型或其他语言。")
        @unknown default:
            throw InputMethodTranslationFailure(code: "languageUnsupported", message: "本机暂不支持这组语言，请在 App 中检查语言设置。")
        }
        // Recheck the exact detected pair used to construct an installed-only
        // session. No download or language selection sheet appears in another app.
        let source = Locale.Language(identifier: sourceIdentifier)
        let exactStatus = await LanguageAvailability().status(from: source, to: target)
        try Task.checkCancellation()
        guard exactStatus == .installed else {
            throw InputMethodTranslationFailure(code: "languagesNotInstalled", message: "识别出的源语言包尚未就绪，请打开出海王输入法 App 检查语言或手动选择源语言。")
        }
        let session = TranslationSession(installedSource: source, target: target)
        let result = try await session.translate(request.text)
        try Task.checkCancellation()
        return result.targetText
    }

    private func sameLanguage(_ source: String, _ target: String) -> Bool {
        let first = Locale.Language(identifier: source)
        let second = Locale.Language(identifier: target)
        guard first.languageCode == second.languageCode else { return false }
        if first.languageCode?.identifier == "zh" { return first.script == second.script }
        return true
    }

    private func failure(_ error: Error) -> InputMethodTranslationFailure {
        if let failure = error as? InputMethodTranslationFailure { return failure }
        if error is CancellationError || TranslationError.alreadyCancelled ~= error {
            return .init(code: "cancelled", message: "翻译已取消，原文已保留。")
        }
        switch error {
        case TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage:
            return .init(code: "languageUnsupported", message: "Apple 翻译暂不支持这组语言，请在 App 中检查语言设置。")
        case TranslationError.notInstalled:
            return .init(code: "languagesNotInstalled", message: "请打开出海王输入法 App 准备 Apple 语言包后重试，原文已保留。")
        case TranslationError.nothingToTranslate:
            return .init(code: "empty", message: "请先输入需要翻译的文字。")
        case let engine as EngineError:
            return .init(code: "engineFailure", message: engine.localizedDescription)
        default:
            return .init(code: "translationFailed", message: "本次翻译未完成，请在出海王输入法 App 检查引擎或语言状态，原文已保留。")
        }
    }
}

private final class InputMethodConfigurationInvalidation: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return changed
    }
    func invalidate() {
        lock.lock()
        changed = true
        lock.unlock()
    }
}
