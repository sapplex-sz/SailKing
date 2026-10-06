import Foundation
import HaiwangCore

/// Resolves plain and dynamically composed UI strings using this app's preferred language.
/// App-specific `-AppleLanguages '(en)'` arguments are respected without changing system settings.
public func hw(_ chinese: String, _ english: String) -> String {
    HWLocale.isChinese ? chinese : english
}

public enum HWLocale {
    public static var isChinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }
    static let english = Locale(identifier: "en")
}

extension SourceLanguage {
    var localizedName: String {
        guard let identifier = languageIdentifier else { return hw("自动识别", "Auto-detect") }
        let english: String
        switch self {
        case .chinese: english = "Chinese (Simplified)"
        case .traditionalChinese: english = "Chinese (Traditional)"
        default: english = HWLocale.english.localizedString(forIdentifier: identifier) ?? nativeName
        }
        return hw(name, english)
    }
}

extension Market {
    var localizedLanguageName: String {
        SourceLanguage.allCases.first { $0.languageIdentifier == languageIdentifier }?.localizedName
            ?? HWLocale.english.localizedString(forIdentifier: languageIdentifier) ?? languageName
    }
    var localizedName: String {
        let region: String
        switch self {
        case .unitedStates: region = "US"; case .unitedKingdom: region = "GB"; case .japan: region = "JP"
        case .korea: region = "KR"; case .germany: region = "DE"; case .france: region = "FR"
        case .spain: region = "ES"; case .mexico: region = "MX"; case .brazil: region = "BR"
        case .indonesia: region = "ID"; case .vietnam: region = "VN"; case .thailand: region = "TH"
        case .saudiArabia: region = "SA"; case .china: region = "CN"; case .taiwan: region = "TW"
        case .italy: region = "IT"; case .russia: region = "RU"; case .india: region = "IN"
        case .turkey: region = "TR"; case .netherlands: region = "NL"; case .poland: region = "PL"; case .ukraine: region = "UA"
        }
        return hw(name, HWLocale.english.localizedString(forRegionCode: region) ?? name)
    }
}

extension WorkspaceSection {
    var localizedTitle: String {
        switch self {
        case .workspace: hw(rawValue, "Workspace")
        case .phrases: hw(rawValue, "Phrasebook")
        case .guide: hw(rawValue, "Getting started")
        case .settings: hw(rawValue, "Settings")
        }
    }
}

extension PhraseCategory {
    var localizedTitle: String {
        switch self {
        case .service: hw(rawValue, "Customer care")
        case .product: hw(rawValue, "Products")
        case .social: hw(rawValue, "Social media")
        }
    }
}

extension WorkspacePhrase {
    var localizedTitle: String {
        let english: String
        switch id {
        case "shipping": english = "Order tracking"
        case "thanks": english = "New inquiries"
        case "support": english = "Order support"
        case "material": english = "Product details"
        case "size": english = "Choosing a size"
        case "care": english = "Product care"
        case "share": english = "Share a tip"
        case "feedback": english = "Ask for feedback"
        case "community": english = "Thank followers"
        default: english = id
        }
        return hw(title, english)
    }
}

extension TranslationEngine {
    static var platformChoices: [TranslationEngine] {
        #if os(macOS)
        [.automatic, .localModel, .apple]
        #else
        allCases
        #endif
    }
    var localizedTitle: String {
        switch self {
        case .automatic: hw("自动", "Automatic")
        case .localModel: hw("轻量本地模型", "Local model")
        case .cloud: hw("API 翻译", "API translation")
        case .apple: hw("Apple 内置", "Apple built-in")
        }
    }
    var localizedSummary: String {
        switch self {
        case .automatic:
            #if os(macOS)
            hw("优先使用已就绪且适配设备的本地模型，否则使用 Apple 内置翻译。原文仅在这台 Mac 上处理。", "Prefer a ready local model that fits your Mac; otherwise use Apple translation. Text is processed on this Mac.")
            #else
            hw("优先使用已就绪且适配设备的本地模型，其他情况使用 Apple 内置；只有主动开启 API 回退后才会联网翻译。", "Prefer a ready local model that fits your device; otherwise use Apple. API translation is used only if you enable API fallback.")
            #endif
        case .localModel: hw("使用下载到本机的开源模型翻译，文字不发送到 API。", "Translate with an open-source model downloaded to this device. Text is not sent to an API.")
        case .cloud: hw("将文字发送到后台及其配置的翻译供应商，适合低配设备和手机。", "Send text to the backend and its configured translation provider, suitable for lower-powered devices and phones.")
        case .apple: hw("使用 Apple 设备内置翻译，需要系统支持对应语言组合。", "Use Apple's on-device translation, subject to the language pairs supported by your system.")
        }
    }
}

func workspaceErrorMessage(_ error: Error) -> String {
    guard let engineError = error as? EngineError else { return error.localizedDescription }
    switch engineError {
    case .invalidConfiguration: return hw("后台返回的模型配置无效。", "The backend returned an invalid model configuration.")
    case .invalidServiceURL: return hw("请输入有效的 HTTPS 后台地址。", "Enter a valid HTTPS backend address.")
    case .modelNotReady: return hw("请先在设置中下载本地模型。", "Download the local model in Settings first.")
    case .modelIncompatible:
        #if os(macOS)
        return hw("此设备无法运行该模型，请选择其他本地模型或 Apple 内置翻译。", "Choose another local model or Apple translation.")
        #else
        return hw("此设备无法运行该模型，请选择 API 或 Apple 内置翻译。", "This device cannot run the model. Choose API or Apple translation.")
        #endif
    case .cloudNotConfigured: return hw("后台尚未启用 API 模型，请刷新配置。", "No API model is enabled on the backend. Refresh the configuration.")
    case .authenticationRequired: return hw("请输入有效的出海王服务访问码。", "Enter a valid SailKing service access code.")
    case .rateLimited: return hw("已达到服务限额，请稍后重试。", "The service limit was reached. Please try again later.")
    case .serviceUnavailable: return hw("翻译服务暂不可用，请稍后重试。", "The translation service is unavailable. Please try again later.")
    case .invalidResponse: return hw("未返回有效译文，请重试。", "No valid translation was returned. Please try again.")
    case .outputTooLong: return hw("译文超出长度限制，请分段翻译。", "The translation exceeded the output limit. Split the text and try again.")
    case .busy: return hw("模型正在处理另一项操作，请稍候。", "The model is handling another operation. Please wait.")
    case .protectedTextChanged: return hw("模型改变了订单号、链接或邮箱，请尝试其他模型。", "The model changed an order ID, link, or email. Try another model.")
    case .streamingUnsupported: return hw("此模型不支持流式翻译，请关闭‘边打字边翻译’后手动翻译，或选择其他模型。", "This model does not support streaming. Turn off ‘Translate while typing’ and translate manually, or choose another model.")
    @unknown default: return engineError.localizedDescription
    }
}
