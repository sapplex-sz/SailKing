import Foundation

public enum Market: String, CaseIterable, Codable, Identifiable, Sendable {
    case unitedStates, unitedKingdom, japan, korea, germany, france, spain, mexico, brazil, indonesia, vietnam, thailand, saudiArabia
    case china, taiwan, italy, russia, india, turkey, netherlands, poland, ukraine

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .unitedStates: "美国"; case .unitedKingdom: "英国"; case .japan: "日本"
        case .korea: "韩国"; case .germany: "德国"; case .france: "法国"
        case .spain: "西班牙"; case .mexico: "墨西哥"; case .brazil: "巴西"
        case .indonesia: "印度尼西亚"; case .vietnam: "越南"; case .thailand: "泰国"; case .saudiArabia: "沙特阿拉伯"
        case .china: "中国大陆"; case .taiwan: "中国台湾"; case .italy: "意大利"; case .russia: "俄罗斯"
        case .india: "印度"; case .turkey: "土耳其"; case .netherlands: "荷兰"; case .poland: "波兰"; case .ukraine: "乌克兰"
        }
    }
    public var flag: String {
        switch self {
        case .unitedStates: "🇺🇸"; case .unitedKingdom: "🇬🇧"; case .japan: "🇯🇵"
        case .korea: "🇰🇷"; case .germany: "🇩🇪"; case .france: "🇫🇷"
        case .spain: "🇪🇸"; case .mexico: "🇲🇽"; case .brazil: "🇧🇷"
        case .indonesia: "🇮🇩"; case .vietnam: "🇻🇳"; case .thailand: "🇹🇭"; case .saudiArabia: "🇸🇦"
        case .china: "🇨🇳"; case .taiwan: "🇹🇼"; case .italy: "🇮🇹"; case .russia: "🇷🇺"
        case .india: "🇮🇳"; case .turkey: "🇹🇷"; case .netherlands: "🇳🇱"; case .poland: "🇵🇱"; case .ukraine: "🇺🇦"
        }
    }
    public var languageName: String {
        switch self {
        case .unitedStates, .unitedKingdom: "英语"
        case .japan: "日语"; case .korea: "韩语"; case .germany: "德语"; case .france: "法语"
        case .spain, .mexico: "西班牙语"; case .brazil: "葡萄牙语"
        case .indonesia: "印度尼西亚语"; case .vietnam: "越南语"; case .thailand: "泰语"; case .saudiArabia: "阿拉伯语"
        case .china: "简体中文"; case .taiwan: "繁体中文"; case .italy: "意大利语"; case .russia: "俄语"
        case .india: "印地语"; case .turkey: "土耳其语"; case .netherlands: "荷兰语"; case .poland: "波兰语"; case .ukraine: "乌克兰语"
        }
    }
    /// Use supported base languages. Region-specific wording is not guaranteed by on-device translation.
    public var languageIdentifier: String {
        switch self {
        case .unitedStates, .unitedKingdom: "en"
        case .japan: "ja"; case .korea: "ko"; case .germany: "de"; case .france: "fr"
        case .spain, .mexico: "es"; case .brazil: "pt"
        case .indonesia: "id"; case .vietnam: "vi"; case .thailand: "th"; case .saudiArabia: "ar"
        case .china: "zh-Hans"; case .taiwan: "zh-Hant"; case .italy: "it"; case .russia: "ru"
        case .india: "hi"; case .turkey: "tr"; case .netherlands: "nl"; case .poland: "pl"; case .ukraine: "uk"
        }
    }
}

public enum SourceLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic = "auto", chinese = "zh-Hans", traditionalChinese = "zh-Hant", english = "en"
    case japanese = "ja", korean = "ko", french = "fr", german = "de", spanish = "es", portuguese = "pt"
    case italian = "it", russian = "ru", arabic = "ar", hindi = "hi", indonesian = "id", vietnamese = "vi"
    case thai = "th", turkish = "tr", dutch = "nl", polish = "pl", ukrainian = "uk"
    public var id: String { rawValue }
    public var languageIdentifier: String? { self == .automatic ? nil : rawValue }
    public var name: String {
        switch self {
        case .automatic: "自动识别"; case .chinese: "简体中文"; case .traditionalChinese: "繁体中文"; case .english: "英语"
        case .japanese: "日语"; case .korean: "韩语"; case .french: "法语"; case .german: "德语"
        case .spanish: "西班牙语"; case .portuguese: "葡萄牙语"; case .italian: "意大利语"; case .russian: "俄语"
        case .arabic: "阿拉伯语"; case .hindi: "印地语"; case .indonesian: "印度尼西亚语"; case .vietnamese: "越南语"
        case .thai: "泰语"; case .turkish: "土耳其语"; case .dutch: "荷兰语"; case .polish: "波兰语"; case .ukrainian: "乌克兰语"
        }
    }
    public var nativeName: String {
        switch self {
        case .automatic: "Auto-detect"; case .chinese: "简体中文"; case .traditionalChinese: "繁體中文"; case .english: "English"
        case .japanese: "日本語"; case .korean: "한국어"; case .french: "Français"; case .german: "Deutsch"
        case .spanish: "Español"; case .portuguese: "Português"; case .italian: "Italiano"; case .russian: "Русский"
        case .arabic: "العربية"; case .hindi: "हिन्दी"; case .indonesian: "Bahasa Indonesia"; case .vietnamese: "Tiếng Việt"
        case .thai: "ไทย"; case .turkish: "Türkçe"; case .dutch: "Nederlands"; case .polish: "Polski"; case .ukrainian: "Українська"
        }
    }
    public var inputHint: String { "使用现有系统输入法" }
}

public struct KeyboardPreferences: Codable, Equatable, Sendable {
    public var market: Market
    public var source: SourceLanguage
    public init(market: Market = .unitedStates, source: SourceLanguage = .automatic) {
        self.market = market
        self.source = source
    }
    public static let defaultsSuite = "com.haiwang.shared"
    public static let storageKey = "keyboard-preferences-v1"
    public static func load(from defaults: UserDefaults = UserDefaults(suiteName: defaultsSuite) ?? .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey), let result = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return result
    }
    public func save(to defaults: UserDefaults = UserDefaults(suiteName: Self.defaultsSuite) ?? .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
