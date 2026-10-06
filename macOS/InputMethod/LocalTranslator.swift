import Foundation
import Translation
import HaiwangCore

enum LocalTranslationFailure: LocalizedError {
    case missingModels, unsupported, empty
    var errorDescription: String? {
        switch self {
        case .missingModels: "请先打开出海王输入法 App，下载这组语言包，再返回翻译。"
        case .unsupported: "本机暂不支持这组语言，请在 App 中选择其他目标语言。"
        case .empty: "没有返回译文，请重试。"
        }
    }
}

@MainActor
enum LocalTranslator {
    static func translate(_ text: String, preferences: KeyboardPreferences) async throws -> String {
        if preferences.source.rawValue == preferences.market.languageIdentifier { return text }
        let source = Locale.Language(identifier: preferences.source.rawValue)
        let target = Locale.Language(identifier: preferences.market.languageIdentifier)
        let status = await LanguageAvailability().status(from: source, to: target)
        try Task.checkCancellation()
        switch status {
        case .unsupported: throw LocalTranslationFailure.unsupported
        case .supported: throw LocalTranslationFailure.missingModels
        case .installed: break
        @unknown default: throw LocalTranslationFailure.unsupported
        }
        let session = TranslationSession(installedSource: source, target: target)
        let result = try await session.translate(text)
        try Task.checkCancellation()
        guard !result.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalTranslationFailure.empty }
        return result.targetText
    }
}
