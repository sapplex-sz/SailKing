import Foundation
import HaiwangCore

/// The production default must never be reached in this offline test executable.
/// Controller behavior is exercised with its DEBUG-only injected provider instead.
@MainActor
enum InputMethodTranslationClient {
    static func translate(text: String, preferences: KeyboardPreferences) async throws -> String {
        throw OfflineSmokeFailure.unexpectedLiveTranslation
    }
}

enum OfflineSmokeFailure: Error {
    case unexpectedLiveTranslation
    case simulatedFailure
}
