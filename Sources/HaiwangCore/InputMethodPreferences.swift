import Foundation

/// One system input source contains both typing modes; translation is independent.
public enum InputMethodInputMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case pinyin, english

    public var id: String { rawValue }
    public var systemID: String { InputMethodPreferences.systemSourceID }
    public var title: String {
        switch self {
        case .pinyin: "中文拼音"
        case .english: "英文直输"
        }
    }
}

public struct InputMethodPreferences: Codable, Equatable, Sendable {
    public var inputMode: InputMethodInputMode
    public var translationEnabled: Bool

    public init(inputMode: InputMethodInputMode = .pinyin, translationEnabled: Bool = false) {
        self.inputMode = inputMode
        self.translationEnabled = translationEnabled
    }

    public static let storageKey = "inputmethod-preferences-v1"
    // Keep the existing Pinyin source ID so an upgrade preserves the user's keyboard entry.
    public static let systemSourceID = "com.haiwang.inputmethod.Haiwang.pinyin"
    public static let legacyEnglishSourceID = "com.haiwang.inputmethod.Haiwang.english"

    public static func load(from defaults: UserDefaults = UserDefaults(suiteName: KeyboardPreferences.defaultsSuite) ?? .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let preferences = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return preferences
    }

    public func save(to defaults: UserDefaults = UserDefaults(suiteName: KeyboardPreferences.defaultsSuite) ?? .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
