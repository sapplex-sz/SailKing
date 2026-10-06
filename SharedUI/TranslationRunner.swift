import SwiftUI
import Translation

/// Each runner captures one immutable request. Its owner rejects callbacks from superseded requests.
struct TranslationRunner: View {
    let request: WorkspaceTranslationRequest
    var runtime: EngineRuntime = .shared
    var progress: @MainActor (String, WorkspaceTranslationRequest) -> Void = { _, _ in }
    let completion: @MainActor (WorkspaceTranslationOutcome, WorkspaceTranslationRequest) -> Void

    @ViewBuilder
    var body: some View {
        if request.snapshot.engine == .apple {
            Color.clear.frame(width: 1, height: 1)
                .translationTask(request.configuration) { await runApple($0) }
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: 1, height: 1)
                .task(id: request.id) { await runAlternative() }
                .accessibilityHidden(true)
        }
    }

    private func runApple(_ session: TranslationSession) async {
        guard !Task.isCancelled, request.engineConfigurationID == runtime.workspaceConfigurationID else { return }
        do {
            let outcome: WorkspaceTranslationOutcome
            switch request.operation {
            case .translate:
                let response = try await session.translate(request.text)
                outcome = .translated(response.targetText)
            case .prepare:
                try await session.prepareTranslation()
                outcome = .prepared(await session.isReady)
            }
            guard !Task.isCancelled else { return }
            completion(outcome, request)
        } catch { finish(error) }
    }

    private func runAlternative() async {
        guard !Task.isCancelled, request.engineConfigurationID == runtime.workspaceConfigurationID else { return }
        guard request.operation == .translate else {
            completion(.failed(hw("请在设置中准备本地模型。", "Prepare local models in Settings.")), request)
            return
        }
        do {
            let text = try await runtime.translate(text: request.text, source: request.source.languageIdentifier, target: request.market.languageIdentifier, market: request.market.rawValue, snapshot: request.snapshot, streaming: request.streaming) { update in
                Task { @MainActor in progress(update, request) }
            }
            guard !Task.isCancelled else { return }
            completion(.translated(text), request)
        } catch { finish(error) }
    }

    private func finish(_ error: Error) {
        guard !Task.isCancelled else { return }
        if isUserCancellation(error) {
            completion(.cancelled, request)
            return
        }
        let message: String
        switch error {
        case TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage:
            message = hw("系统暂不支持此语言组合，请尝试其他目标语言。原文已保留。", "This language pair is unavailable. Try another target language. Your original text is safe.")
        case TranslationError.notInstalled:
            message = hw("语言包尚未就绪。请先准备语言包，再重试。原文已保留。", "Languages are not ready. Prepare them and try again. Your original text is safe.")
        case TranslationError.nothingToTranslate:
            message = hw("没有可翻译的文字，请补充原文。", "Enter some text to translate.")
        default:
            message = hw("本次操作未完成，原文已保留。\n", "The operation could not finish. Your original text is safe.\n") + workspaceErrorMessage(error)
        }
        completion(.failed(message), request)
    }

    private func isUserCancellation(_ error: Error, depth: Int = 0) -> Bool {
        if error is CancellationError { return true }
        if case TranslationError.alreadyCancelled = error { return true }
        let native = error as NSError
        if native.domain == NSURLErrorDomain && native.code == NSURLErrorCancelled { return true }
        if native.domain == NSCocoaErrorDomain && native.code == NSUserCancelledError { return true }
        if depth < 3, let underlying = native.userInfo[NSUnderlyingErrorKey] as? Error {
            return isUserCancellation(underlying, depth: depth + 1)
        }
        return false
    }
}
