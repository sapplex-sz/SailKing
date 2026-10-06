import Foundation
import Observation
import Translation
import NaturalLanguage
import HaiwangCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case workspace = "工作台", phrases = "常用表达", guide = "使用指南", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .workspace: "square.grid.2x2"
        case .phrases: "text.bubble"
        case .guide: "book.closed"
        case .settings: "slider.horizontal.3"
        }
    }
}

enum PhraseCategory: String, CaseIterable, Identifiable {
    case service = "客户沟通", product = "商品介绍", social = "社媒互动"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .service: "bubble.left.and.bubble.right"; case .product: "shippingbox"; case .social: "sparkles" }
    }
}

struct WorkspacePhrase: Identifiable {
    let id: String
    let category: PhraseCategory
    let title: String
    let chinese: String
    let english: String
    func text(for source: SourceLanguage) -> String? {
        let identifier = source.languageIdentifier ?? Locale.preferredLanguages.first ?? ""
        let language = Locale.Language(identifier: identifier).languageCode?.identifier
        switch language {
        case "zh":
            return Locale.Language(identifier: identifier).script?.identifier == "Hant"
                ? chinese.applyingTransform(StringTransform("Hans-Hant"), reverse: false)
                : chinese
        case "en": return english
        case "ja": return Self.japanese[id]
        case "es": return Self.spanish[id]
        case "fr": return Self.french[id]
        default: return nil
        }
    }
    private static let japanese = [
        "shipping": "ご注文の商品を発送いたしました。最新の配送状況は注文ページでご確認いただけます。",
        "thanks": "お問い合わせありがとうございます。ご希望のデザインと数量をお知らせいただければ、詳しい情報をご案内いたします。",
        "support": "ご不便をおかけして申し訳ございません。注文番号と商品の写真をお送りください。できるだけ早く対応いたします。",
        "size": "ご購入前にサイズ表をご確認ください。サイズ選びに迷われた場合は、お気軽にお問い合わせください。",
        "share": "今日は便利なコツをご紹介します。皆さんは普段どうしていますか？ぜひコメントで教えてください。",
        "feedback": "次回の投稿を準備しています。どのようなテーマについて知りたいですか？コメントでお知らせください。"
    ]
    private static let spanish = [
        "shipping": "Hola, tu pedido ya ha sido enviado. Puedes consultar la información de seguimiento más reciente en la página de tu pedido.",
        "thanks": "¡Gracias por tu consulta! Dinos qué modelo y cantidad te interesan y te enviaremos más información.",
        "support": "Lamentamos las molestias. Envíanos el número de tu pedido y una foto del producto para que podamos ayudarte lo antes posible.",
        "size": "Consulta la tabla de tallas antes de comprar. Si no sabes qué talla elegir, no dudes en contactarnos.",
        "share": "Hoy quiero compartir un consejo práctico. ¿Cómo lo haces tú normalmente? Cuéntamelo en los comentarios.",
        "feedback": "Estamos preparando nuestra próxima publicación. ¿Sobre qué tema te gustaría saber más? Cuéntanos en los comentarios."
    ]
    private static let french = [
        "shipping": "Bonjour, votre commande a été expédiée. Vous pouvez consulter les dernières informations de suivi sur la page de votre commande.",
        "thanks": "Merci pour votre demande ! Indiquez-nous le modèle et la quantité qui vous intéressent, et nous vous donnerons plus de détails.",
        "support": "Nous sommes désolés pour ce désagrément. Merci de nous envoyer votre numéro de commande et une photo du produit afin que nous puissions vous aider rapidement.",
        "size": "Veuillez consulter le guide des tailles avant de commander. Si vous hésitez sur la taille à choisir, n’hésitez pas à nous contacter.",
        "share": "Aujourd’hui, j’aimerais partager une astuce pratique. Comment faites-vous habituellement ? Dites-le-moi dans les commentaires.",
        "feedback": "Nous préparons notre prochaine publication. Quel sujet aimeriez-vous découvrir ? Dites-le-nous dans les commentaires."
    ]
    static let all: [Self] = [
        .init(id: "shipping", category: .service, title: "物流进度", chinese: "您好，您的订单已经发出。您可以通过订单页面查看最新的物流信息。", english: "Hello, your order has been shipped. You can check the latest tracking information on your order page."),
        .init(id: "thanks", category: .service, title: "感谢咨询", chinese: "感谢您的咨询！请告诉我您感兴趣的款式和数量，我会为您提供更多信息。", english: "Thank you for your inquiry! Please tell me which style and quantity you are interested in, and I will share more details."),
        .init(id: "support", category: .service, title: "售后沟通", chinese: "很抱歉给您带来不便。请提供您的订单编号和商品照片，我们会尽快协助处理。", english: "We are sorry for the inconvenience. Please share your order number and a photo of the item so we can help resolve the issue."),
        .init(id: "material", category: .product, title: "材质与细节", chinese: "这款产品采用轻便的设计，方便携带。请查看商品详情中的尺寸和材质信息。", english: "This product has a lightweight design that is easy to carry. Please check the product details for dimensions and materials."),
        .init(id: "size", category: .product, title: "选择尺码", chinese: "购买前请参考尺码表。如果不确定适合的尺寸，欢迎联系我们。", english: "Please check the size chart before purchasing. If you are unsure which size to choose, feel free to contact us."),
        .init(id: "care", category: .product, title: "使用建议", chinese: "首次使用前，请仔细阅读随附的使用说明。妥善保养有助于延长产品的使用寿命。", english: "Please read the included instructions carefully before first use. Proper care can help extend the life of the product."),
        .init(id: "share", category: .social, title: "分享日常", chinese: "今天想和大家分享一个实用的小技巧。你们平时是怎么做的？欢迎在评论区交流。", english: "Today I would like to share a practical tip. How do you usually do this? Let me know in the comments."),
        .init(id: "feedback", category: .social, title: "邀请反馈", chinese: "我们正在准备下一期内容。你最想了解哪个话题？欢迎留言告诉我们。", english: "We are preparing our next post. Which topic would you like to learn about? Let us know in the comments."),
        .init(id: "community", category: .social, title: "回应关注", chinese: "谢谢你的支持和关注！很高兴在这里认识你，希望接下来的分享对你有帮助。", english: "Thank you for your support and for following! It is great to connect with you here. I hope you find our upcoming posts helpful.")
    ]
}

struct WorkspaceTranslationRequest: Identifiable {
    enum Operation { case translate, prepare }
    let id = UUID()
    let operation: Operation
    let source: SourceLanguage
    let market: Market
    let text: String
    let revision: UInt64
    let snapshot: EngineSnapshot
    let engineConfigurationID: String
    let streaming: Bool
    init(operation: Operation, source: SourceLanguage, market: Market, text: String, revision: UInt64,
         snapshot: EngineSnapshot, engineConfigurationID: String, streaming: Bool = true) {
        self.operation = operation
        self.source = source
        self.market = market
        self.text = text
        self.revision = revision
        self.snapshot = snapshot
        self.engineConfigurationID = engineConfigurationID
        self.streaming = streaming
    }
    var configuration: TranslationSession.Configuration {
        .init(source: source.languageIdentifier.map { Locale.Language(identifier: $0) }, target: Locale.Language(identifier: market.languageIdentifier))
    }
}

enum WorkspaceTranslationOutcome {
    case translated(String), prepared(Bool), failed(String), cancelled
}

extension SourceLanguage {
    var displayLabel: String { localizedName == nativeName ? localizedName : localizedName + " · " + nativeName }
}

extension Market {
    var languageDisplayLabel: String {
        SourceLanguage.allCases.first { $0.languageIdentifier == languageIdentifier }?.displayLabel ?? languageName
    }
}

extension EngineRuntime {
    /// Ephemeral access-code changes invalidate requests without exposing the code in UI or logs.
    var workspaceConfigurationID: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let preferencesData = (try? encoder.encode(settings))?.base64EncodedString() ?? ""
        return preferencesData + ":" + String(describing: catalog.revision) + ":" + String(describing: resolvedEngine) + ":" + String(accessCode.hashValue)
    }
}

@Observable @MainActor
final class WorkspaceModel {
    let runtime: EngineRuntime
    var section: WorkspaceSection = .workspace
    var preferences = KeyboardPreferences.load()
    var composition = CompositionSession()
    var request: WorkspaceTranslationRequest?
    var availability: LanguageAvailability.Status?
    var isCheckingAvailability = false
    var availabilityMessage: String?
    var preparationMessage: String?
    var preparationError: String?
    var copied = false
    var resultIsOriginal = false
    var autoTranslationEnabled: Bool {
        didSet {
            guard oldValue != autoTranslationEnabled else { return }
            if persistAutomaticPreference { UserDefaults(suiteName: KeyboardPreferences.defaultsSuite)?.set(autoTranslationEnabled, forKey: "automatic-translation-enabled") }
            cancelAutomaticTranslation()
            if !autoTranslationEnabled, let automaticRequestID, request?.id == automaticRequestID {
                composition.invalidate()
                request = nil
                streamPreview = nil
                self.automaticRequestID = nil
            }
            if autoTranslationEnabled { scheduleAutomaticTranslation() }
        }
    }
    private(set) var isSourceComposing = false
    private(set) var isDebouncing = false
    private(set) var streamPreview: String?
    private(set) var sourceEditorResetID: UInt64 = 0
    @ObservationIgnored private var isEditorActive = false
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var debounceID = UUID()
    @ObservationIgnored private var automaticRequestID: UUID?
    @ObservationIgnored private var committedBeforeMarkedText: String?
    @ObservationIgnored private let automaticTranslationDelay: Duration
    @ObservationIgnored private let persistAutomaticPreference: Bool
    private(set) var confidentlyDetectedSource: String?
    var category: PhraseCategory = .service
    private(set) var isPreparingLocal = false
    private(set) var isCancellingLocal = false
    private(set) var localPreparationMessage: String?
    private(set) var localPreparationError: String?
    @ObservationIgnored private var localPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var hasRequestedInitialCatalog = false

    init(runtime: EngineRuntime, autoTranslationEnabled: Bool = true, automaticTranslationDelay: Duration = .milliseconds(600), persistAutomaticPreference: Bool = false) {
        self.runtime = runtime
        self.autoTranslationEnabled = autoTranslationEnabled
        self.automaticTranslationDelay = automaticTranslationDelay
        self.persistAutomaticPreference = persistAutomaticPreference
    }
    convenience init() {
        let enabled = UserDefaults(suiteName: KeyboardPreferences.defaultsSuite)?.object(forKey: "automatic-translation-enabled") as? Bool ?? true
        self.init(runtime: .shared, autoTranslationEnabled: enabled, persistAutomaticPreference: true)
    }

    func editorAppeared() {
        isEditorActive = true
        reloadAutomaticTranslationPreference()
        if outputText == nil { scheduleAutomaticTranslation() }
    }

    func reloadAutomaticTranslationPreference() {
        guard persistAutomaticPreference else { return }
        autoTranslationEnabled = UserDefaults(suiteName: KeyboardPreferences.defaultsSuite)?.object(forKey: "automatic-translation-enabled") as? Bool ?? true
    }

    func editorDisappeared() {
        isEditorActive = false
        cancelAutomaticTranslation()
        if isSourceComposing {
            composition.setSource(committedBeforeMarkedText ?? "")
            committedBeforeMarkedText = nil
            isSourceComposing = false
            sourceEditorResetID &+= 1
            updateDetectedLanguage()
        }
        if request?.operation == .translate {
            composition.invalidate()
            request = nil
            streamPreview = nil
        }
    }

    private func cancelAutomaticTranslation() {
        debounceTask?.cancel()
        debounceTask = nil
        debounceID = UUID()
        isDebouncing = false
    }

    private func scheduleAutomaticTranslation() {
        cancelAutomaticTranslation()
        guard autoTranslationEnabled, isEditorActive, !isSourceComposing, !isBusy,
              !composition.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let pendingID = debounceID
        let sourceRevision = composition.revision
        let pair = languagePairID
        let configuration = engineConfigurationID
        let delay = automaticTranslationDelay
        isDebouncing = true
        debounceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, pendingID == debounceID else { return }
            debounceTask = nil
            isDebouncing = false
            guard autoTranslationEnabled, isEditorActive, !isSourceComposing,
                  composition.revision == sourceRevision, languagePairID == pair,
                  engineConfigurationID == configuration, canTranslate,
                  sameLanguage || effectiveEngine != .apple || availability == .installed else { return }
            translate()
            automaticRequestID = request?.id
        }
    }

    func refreshCatalogOnLaunch() async {
        guard !hasRequestedInitialCatalog else { return }
        hasRequestedInitialCatalog = true
        // The cached or bundled catalog remains usable if the backend is unavailable.
        try? await runtime.refreshCatalog()
    }

    func prepareLocalModel() {
        guard !isPreparingLocal else { return }
        isPreparingLocal = true
        isCancellingLocal = false
        localPreparationMessage = nil
        localPreparationError = nil
        localPreparationTask = Task { @MainActor in
            defer {
                isPreparingLocal = false
                isCancellingLocal = false
                localPreparationTask = nil
            }
            do {
                try Task.checkCancellation()
                try await runtime.prepareLocal()
                try Task.checkCancellation()
                localPreparationMessage = runtime.localModelReady
                    ? hw("本地模型已就绪，可以开始翻译。", "The local model is ready to translate.")
                    : hw("模型尚未就绪，请检查状态后重试。", "The model is not ready yet. Check its status and try again.")
            } catch {
                let native = error as NSError
                if Task.isCancelled || error is CancellationError || (native.domain == NSURLErrorDomain && native.code == NSURLErrorCancelled) {
                    localPreparationMessage = hw("模型下载已取消。", "Model download cancelled.")
                } else {
                    localPreparationError = workspaceErrorMessage(error)
                }
            }
        }
    }

    func cancelLocalPreparation() {
        guard isPreparingLocal else { return }
        isCancellingLocal = true
        localPreparationTask?.cancel()
    }

    var sameLanguage: Bool { (preferences.source.languageIdentifier ?? confidentlyDetectedSource) == preferences.market.languageIdentifier }
    var languagePairID: String { preferences.source.rawValue + ":" + preferences.market.rawValue }
    var engineConfigurationID: String { runtime.workspaceConfigurationID }
    var availabilityCheckID: String { engineConfigurationID + ":" + languagePairID + (isSourceComposing ? ":marked" : ":committed") + (preferences.source.languageIdentifier == nil ? ":" + composition.source : "") }
    var effectiveEngine: TranslationEngine { request?.snapshot.engine ?? runtime.resolvedEngine }
    var engineLabel: String {
        runtime.settings.mode == .automatic
            ? hw("自动 · ", "Auto · ") + effectiveEngine.localizedTitle
            : effectiveEngine.localizedTitle
    }
    var serviceAddress: String { String(describing: request?.snapshot.settings.serviceURL ?? runtime.settings.serviceURL) }
    var dataFlowMessage: String {
        effectiveEngine == .cloud
            ? hw("本次文字将发送到 ", "This text will be sent to ") + serviceAddress + hw(" 及后台配置的翻译供应商。", " and the translation provider configured by that backend.")
            : hw("本次文字在设备上翻译，不发送到 API。", "This translation stays on your device; text is not sent to an API.")
    }
    var isEngineReady: Bool {
        switch effectiveEngine {
        case .localModel: runtime.localModelReady && runtime.localModelCompatible
        case .cloud: !runtime.catalog.apiModels.isEmpty && !runtime.accessCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .apple: availability == .installed
        case .automatic: false
        }
    }
    var outputText: String? { !isSourceComposing && request == nil ? (resultIsOriginal ? composition.source : composition.translation) : nil }
    var displayedError: String? {
        guard let error = composition.errorMessage ?? preparationError else { return nil }
        return error == "没有返回译文，请重试。" ? hw("没有返回译文，请重试。", "No translation was returned. Please try again.") : error
    }
    var phrases: [WorkspacePhrase] { WorkspacePhrase.all.filter { $0.text(for: preferences.source) != nil } }
    var templateLanguageDescription: String { preferences.source.languageIdentifier == nil ? hw("预设短语跟随设备语言", "Phrases follow your device language") : hw("预设短语使用", "Phrase language: ") + preferences.source.localizedName }
    static var targetLanguages: [Market] {
        var seen = Set<String>()
        return Market.allCases.filter { seen.insert($0.languageIdentifier).inserted }
    }
    var canPrepare: Bool { effectiveEngine == .apple && !isBusy && !sameLanguage && preferences.source.languageIdentifier != nil && availability != .unsupported }
    var isBusy: Bool { request != nil }
    var canTranslate: Bool {
        guard !isBusy, !isSourceComposing, !composition.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if sameLanguage { return true }
        switch effectiveEngine {
        case .apple: return preferences.source.languageIdentifier == nil || availability != .unsupported
        case .localModel: return runtime.localModelReady && runtime.localModelCompatible
        case .cloud: return !runtime.catalog.apiModels.isEmpty && !runtime.accessCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .automatic: return false
        }
    }
    var statusTitle: String {
        if isSourceComposing { return hw("候选文字确认后开始翻译", "Translation waits for confirmed text") }
        if isDebouncing { return hw("等待输入停顿…", "Waiting for a pause in typing…") }
        if sameLanguage { return hw("源语言与目标语言相同，无需翻译", "Languages match. No translation needed.") }
        if let request {
            if request.operation == .prepare { return hw("正在准备语言包…", "Preparing languages…") }
            return request.snapshot.engine == .cloud ? hw("正在通过 API 翻译…", "Translating through the API…") : hw("正在本地翻译…", "Translating on device…")
        }
        if effectiveEngine == .localModel {
            if !runtime.localModelCompatible { return hw("当前设备不适配所选模型，请选择其他引擎。", "The selected model does not fit this device. Choose another engine.") }
            if runtime.downloadProgress != nil { return hw("正在下载本地模型…", "Downloading the local model…") }
            return runtime.localModelReady ? hw("本地模型已就绪", "Local model is ready") : hw("请在设置中下载本地模型", "Download the local model in Settings")
        }
        if effectiveEngine == .cloud {
            if runtime.accessCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return hw("请在设置中输入出海王服务访问码。", "Enter your SailKing service access code in Settings.") }
            return runtime.catalog.apiModels.isEmpty ? hw("后台尚未提供 API 模型，请刷新配置。", "No API models are available. Refresh the backend configuration.") : hw("使用后台 API 翻译，需要网络连接。", "Translation uses the backend API and requires an internet connection.")
        }
        if preferences.source.languageIdentifier == nil && composition.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return hw("输入文字后，自动识别源语言", "Enter text to detect its language.") }
        if isCheckingAvailability { return hw("正在检查语言支持…", "Checking language availability…") }
        if let availabilityMessage { return availabilityMessage }
        switch availability {
        case .installed: return hw("语言包已就绪", "Languages are ready")
        case .supported: return hw("首次使用需要下载语言包", "Language downloads are needed before first use.")
        case .unsupported:
            return preferences.source.languageIdentifier == nil
                ? hw("尚无法确认此语言组合，可手动选源语言或尝试翻译", "This pair is unconfirmed. Choose a source language or try translating.")
                : hw("系统暂不支持此语言组合", "This language pair is unavailable on your device.")
        case nil: return hw("语言支持取决于当前设备的 Apple Translation", "Language availability depends on Apple Translation on this device.")
        @unknown default: return hw("请检查语言包状态", "Check language availability")
        }
    }

    func setSource(_ text: String) {
        sourceEditorResetID &+= 1
        sourceEditorChanged(text, hasMarkedText: false)
    }

    func sourceEditorChanged(_ text: String, hasMarkedText: Bool) {
        let normalized = String(text.prefix(composition.maximumLength))
        if !hasMarkedText, text != normalized { sourceEditorResetID &+= 1 }
        guard normalized != composition.source || hasMarkedText != isSourceComposing else { return }
        cancelAutomaticTranslation()
        if hasMarkedText && !isSourceComposing { committedBeforeMarkedText = composition.source }
        if !hasMarkedText { committedBeforeMarkedText = nil }
        isSourceComposing = hasMarkedText
        composition.setSource(text)
        if hasMarkedText { confidentlyDetectedSource = nil } else { updateDetectedLanguage() }
        request = nil
        streamPreview = nil
        copied = false
        resultIsOriginal = false
        preparationError = nil
        preparationMessage = nil
        if preferences.source.languageIdentifier == nil { availability = nil; availabilityMessage = nil }
        scheduleAutomaticTranslation()
    }

    func preferencesChanged(persist: Bool = true) {
        cancelAutomaticTranslation()
        if persist { preferences.save() }
        composition.invalidate()
        request = nil
        streamPreview = nil
        availability = nil
        availabilityMessage = nil
        preparationMessage = nil
        preparationError = nil
        copied = false
        resultIsOriginal = false
        if !isSourceComposing { updateDetectedLanguage() }
        scheduleAutomaticTranslation()
    }

    func enginePreferencesChanged() {
        cancelAutomaticTranslation()
        composition.invalidate()
        request = nil
        streamPreview = nil
        availability = nil
        availabilityMessage = nil
        isCheckingAvailability = false
        preparationMessage = nil
        preparationError = nil
        copied = false
        resultIsOriginal = false
        scheduleAutomaticTranslation()
    }

    func clear() {
        cancelAutomaticTranslation()
        sourceEditorResetID &+= 1
        isSourceComposing = false
        committedBeforeMarkedText = nil
        composition.reset()
        confidentlyDetectedSource = nil
        request = nil
        streamPreview = nil
        copied = false
        resultIsOriginal = false
        preparationError = nil
        preparationMessage = nil
        if preferences.source.languageIdentifier == nil { availability = nil; availabilityMessage = nil }
    }

    func usePhrase(_ phrase: WorkspacePhrase) {
        guard let text = phrase.text(for: preferences.source) else { return }
        setSource(text)
        section = .workspace
    }

    func translate() {
        guard canTranslate, let revision = composition.beginTranslation() else { return }
        cancelAutomaticTranslation()
        streamPreview = nil
        copied = false
        resultIsOriginal = false
        preparationError = nil
        preparationMessage = nil
        if sameLanguage {
            _ = composition.finish(composition.source, revision: revision)
            resultIsOriginal = true
            preparationMessage = hw("源语言与目标语言相同，已保留原文，可以直接复制。", "The source and target languages match. The original text is ready to copy.")
            return
        }
        request = .init(operation: .translate, source: preferences.source, market: preferences.market, text: composition.source, revision: revision, snapshot: runtime.snapshot(), engineConfigurationID: engineConfigurationID, streaming: autoTranslationEnabled)
    }

    func prepare() {
        guard canPrepare else { return }
        cancelAutomaticTranslation()
        streamPreview = nil
        preparationMessage = nil
        preparationError = nil
        request = .init(operation: .prepare, source: preferences.source, market: preferences.market, text: "", revision: composition.revision, snapshot: runtime.snapshot(), engineConfigurationID: engineConfigurationID)
    }

    private func isCurrent(_ candidate: WorkspaceTranslationRequest) -> Bool {
        request?.id == candidate.id && composition.revision == candidate.revision && !isSourceComposing
            && languagePairID == candidate.source.rawValue + ":" + candidate.market.rawValue
            && engineConfigurationID == candidate.engineConfigurationID
    }

    func updatePreview(_ text: String, for updating: WorkspaceTranslationRequest) {
        guard updating.operation == .translate, isCurrent(updating), composition.pendingRevision == updating.revision,
              text.utf8.count >= (streamPreview?.utf8.count ?? 0) else { return }
        streamPreview = text.isEmpty ? nil : text
    }

    func complete(_ outcome: WorkspaceTranslationOutcome, for completed: WorkspaceTranslationRequest) {
        guard isCurrent(completed) else { return }
        request = nil
        streamPreview = nil
        switch outcome {
        case .translated(let text):
            do {
                try ProtectedText.validate(source: completed.text, output: text)
                if composition.finish(text, revision: completed.revision), completed.snapshot.engine == .apple { availability = .installed }
            } catch { composition.fail(workspaceErrorMessage(error), revision: completed.revision) }
        case .prepared(let ready):
            availability = ready ? .installed : .supported
            preparationMessage = ready ? hw("语言包已就绪，现在可以在本机翻译。", "Languages are ready for on-device translation.") : hw("已请求准备语言包。下载完成后，请再次检查或开始翻译。", "Language preparation was requested. Check again or translate after the download finishes.")
        case .failed(let message):
            if completed.operation == .translate { composition.fail(message, revision: completed.revision) }
            else { preparationError = message }
        case .cancelled:
            if completed.operation == .translate { composition.invalidate() }
            preparationMessage = hw("已取消，原文已保留。", "Cancelled. Your original text is safe.")
        }
    }

    /// Only skip translation for a strong local match in a substantive text sample.
    /// Short or uncertain text remains available to Apple's translation session for detection.
    private func updateDetectedLanguage() {
        confidentlyDetectedSource = nil
        guard preferences.source.languageIdentifier == nil, composition.source.filter(\.isLetter).count >= 16 else { return }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(composition.source)
        guard let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first, hypothesis.value >= 0.97 else { return }
        confidentlyDetectedSource = hypothesis.key.rawValue
    }

    func checkAvailability() async {
        let checkID = availabilityCheckID
        availabilityMessage = nil
        isCheckingAvailability = false
        guard effectiveEngine == .apple, !isSourceComposing else { availability = nil; return }
        guard !sameLanguage else { availability = nil; return }
        let target = Locale.Language(identifier: preferences.market.languageIdentifier)
        let sourceIdentifier = preferences.source.languageIdentifier
        let sourceText = composition.source
        if sourceIdentifier == nil && sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { availability = nil; return }
        isCheckingAvailability = true
        do {
            let status: LanguageAvailability.Status
            if let sourceIdentifier {
                status = await LanguageAvailability().status(from: Locale.Language(identifier: sourceIdentifier), to: target)
            } else {
                try await Task.sleep(for: .milliseconds(350))
                status = try await LanguageAvailability().status(for: sourceText, to: target)
            }
            guard !Task.isCancelled, checkID == availabilityCheckID else { return }
            availability = status
            isCheckingAvailability = false
            if status == .installed, outputText == nil, !isBusy, !isDebouncing { scheduleAutomaticTranslation() }
        } catch {
            guard !Task.isCancelled, checkID == availabilityCheckID else { return }
            availability = nil
            isCheckingAvailability = false
            availabilityMessage = hw("暂未识别语言，可补充文字或手动选择源语言", "Language not identified yet. Add more text or choose a source language.")
        }
    }

    func copyTranslation() {
        guard let text = outputText else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        copied = true
        #endif
    }
}
