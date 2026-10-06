import Foundation
import Translation
import HaiwangCore
import AppKit

/// Deterministic workspace checks. Translation responses below are explicit test fixtures.
/// These checks do not download language packs, write preferences, or access the clipboard.
@main @MainActor
struct WorkspaceSmoke {
    private static var checkCount = 0

    static func main() async {
        let chinese = CommandLine.arguments.contains("--expect-chinese")
        checkLocalization(chinese: chinese)
        checkManualSameLanguage()
        await checkAutomaticLanguage()
        checkStaleResponses()
        checkCancellation()
        checkPhraseLanguages()
        checkEngineRouting()
        checkConfigurationIdentityStability()
        await checkLocalDownloadCancellation()
        checkNativeCompositionEvents()
        await checkRealtimeTranslation()
        await checkAutomaticPreparationBoundary()
        checkStreamingSafety()
        print("PASS: \(chinese ? "Chinese" : "English") — \(checkCount) workspace checks")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checkCount += 1
    }

    private static func makeModel() -> WorkspaceModel {
        var settings = EnginePreferences()
        settings.mode = .apple
        return WorkspaceModel(runtime: EngineRuntime(settings: settings, catalog: .bundled, persistSettings: false))
    }

    private static func checkLocalization(chinese: Bool) {
        expect(HWLocale.isChinese == chinese, "App-specific language override must be respected")
        expect(hw("工作台", "Workspace") == (chinese ? "工作台" : "Workspace"), "Plain UI text must use the selected language")
        expect(WorkspaceSection.settings.localizedTitle == (chinese ? "设置" : "Settings"), "Navigation must be localized")
        expect(SourceLanguage.automatic.localizedName == (chinese ? "自动识别" : "Auto-detect"), "Automatic detection label must be localized")
        expect(SourceLanguage.japanese.localizedName == (chinese ? "日语" : "Japanese"), "Language names must be localized")
        expect(Market.japan.localizedName == (chinese ? "日本" : "Japan"), "Country names must be localized")
        expect(SourceLanguage.japanese.displayLabel.contains("日本語"), "Language menus must retain the language's native name")
        expect(PhraseCategory.service.localizedTitle == (chinese ? "客户沟通" : "Customer care"), "Phrase navigation must be localized")
        expect(workspaceErrorMessage(EngineError.protectedTextChanged) == hw("模型改变了订单号、链接或邮箱，请尝试其他模型。", "The model changed an order ID, link, or email. Try another model."), "Protected business identifiers need an actionable localized error")
    }

    private static func checkManualSameLanguage() {
        let model = makeModel()
        model.preferences = KeyboardPreferences(market: .unitedStates, source: .english)
        let original = "  Preserve this text exactly.\n"
        model.setSource(original)
        expect(model.canTranslate, "Matching languages must allow keeping the original")
        model.translate()
        expect(model.outputText == original, "Keeping the original must preserve leading and trailing whitespace")
        expect(model.resultIsOriginal && model.request == nil, "Matching languages must not start a translation request")
        model.setSource("Edited")
        expect(model.outputText == nil && !model.resultIsOriginal, "Editing must invalidate the previous output")
    }

    private static func checkAutomaticLanguage() async {
        let model = makeModel()
        model.preferences = KeyboardPreferences(market: .unitedStates, source: .automatic)
        await model.checkAvailability()
        expect(!model.isCheckingAvailability, "Empty auto-detection must not leave an endless checking state")
        expect(model.statusTitle == hw("输入文字后，自动识别源语言", "Enter text to detect its language."), "Empty auto-detection status must be localized")
        expect(!model.canPrepare, "Preparing languages requires an explicit source language")
        let configuration = WorkspaceTranslationRequest(operation: .translate, source: .automatic, market: .japan, text: "Hello", revision: 1, snapshot: model.runtime.snapshot(), engineConfigurationID: model.engineConfigurationID).configuration
        expect(configuration.source == nil, "Automatic translation must pass a nil source language to Apple")

        let original = "  Please keep this original English message exactly as it is.\n"
        model.setSource(original)
        expect(model.confidentlyDetectedSource == "en", "The substantive English fixture should be confidently detected")
        expect(model.sameLanguage && model.canTranslate, "A strong target-language match must allow keeping the original")
        model.translate()
        expect(model.request == nil && model.resultIsOriginal, "A strong automatic match must not request a translation")
        expect(model.outputText == original, "Automatic same-language output must preserve the exact text")

        model.setSource("Bonjour, merci pour votre message et votre commande.")
        expect(!model.sameLanguage, "French must not be treated as an English match")
        model.setSource("Hello")
        expect(model.confidentlyDetectedSource == nil, "Short text must not take the confident-detection shortcut")
        model.availability = .unsupported
        expect(model.canTranslate, "Uncertain automatic detection must still allow the system to try translating")
        expect(model.statusTitle == hw("尚无法确认此语言组合，可手动选源语言或尝试翻译", "This pair is unconfirmed. Choose a source language or try translating."), "An uncertain automatic pair must not be presented as definitively unsupported")
    }

    private static func checkStaleResponses() {
        let model = makeModel()
        model.preferences = KeyboardPreferences(market: .japan, source: .english)
        model.availability = .installed
        model.setSource("First message")
        model.translate()
        guard let oldRequest = model.request else { preconditionFailure("First translation should create a request") }
        model.setSource("A newer message")
        model.translate()
        guard let currentRequest = model.request else { preconditionFailure("Editing and retrying should create a new request") }

        // Inject explicit fixtures to verify response identity, without invoking the translation engine.
        model.complete(.translated("古い結果"), for: oldRequest)
        expect(model.outputText == nil, "An outdated result must never appear")
        expect(model.request?.id == currentRequest.id, "An outdated callback must not cancel the current request")
        model.complete(.translated("新しい結果"), for: currentRequest)
        expect(model.outputText == "新しい結果", "The current response should be accepted")
        model.setSource("Third message")
        expect(model.outputText == nil, "Editing must clear a completed translation")

        model.translate()
        guard let previousPairRequest = model.request else { preconditionFailure("Third translation should create a request") }
        model.preferences.market = .france
        model.complete(.translated("Wrong target"), for: previousPairRequest)
        expect(model.outputText == nil, "A response for a previous language pair must be rejected")
        model.clear()
        expect(model.request == nil && model.composition.source.isEmpty, "Clear must remove both text and pending work")
    }

    private static func checkCancellation() {
        let model = makeModel()
        model.preferences = KeyboardPreferences(market: .japan, source: .english)
        model.availability = .installed
        let original = "Please keep this text when I cancel."
        model.setSource(original)
        model.translate()
        guard let request = model.request else { preconditionFailure("Translation should create a cancellable request") }
        model.complete(.cancelled, for: request)
        expect(model.request == nil && model.composition.pendingRevision == nil, "Cancellation must clear the pending state")
        expect(model.composition.source == original, "Cancellation must preserve the original text")
        expect(model.displayedError == nil, "Cancellation must not be presented as a generic error")
        expect(model.preparationMessage == hw("已取消，原文已保留。", "Cancelled. Your original text is safe."), "Cancellation status must be localized")
        model.complete(.translated("Late result"), for: request)
        expect(model.outputText == nil, "A cancelled request must not later publish a result")
    }

    private static func checkPhraseLanguages() {
        let model = makeModel()
        for source in [SourceLanguage.japanese, .spanish, .french] {
            model.preferences.source = source
            expect(!model.phrases.isEmpty, "Japanese, Spanish, and French must have corresponding phrase templates")
            expect(model.phrases.allSatisfy { $0.text(for: source) != $0.english }, "Non-English templates must not silently fall back to English")
        }
        model.preferences.source = .german
        expect(model.phrases.isEmpty, "A language without templates must show the empty state")
        model.preferences.source = .traditionalChinese
        expect(model.phrases.first?.text(for: .traditionalChinese)?.contains("訂單") == true, "Traditional Chinese templates must use Traditional Chinese characters")
        expect(Set(WorkspaceModel.targetLanguages.map(\.languageIdentifier)).count == WorkspaceModel.targetLanguages.count, "Target-language choices must not contain duplicate languages")
        expect(WorkspaceModel.targetLanguages.contains { $0.languageIdentifier == "zh-Hans" }, "Simplified Chinese must remain available as a target")
    }

    private static func checkConfigurationIdentityStability() {
        let model = makeModel()
        model.preferences = KeyboardPreferences(market: .japan, source: .english)
        model.setSource("A translation must survive unrelated view updates.")
        model.availability = .installed
        model.translate()
        guard let request = model.request else { preconditionFailure("A stable configuration must create a request") }
        let originalID = model.engineConfigurationID
        var encodedSettings = Set<Data>()
        for _ in 0..<100 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encodedSettings.insert(try! encoder.encode(model.runtime.settings))
            expect(model.engineConfigurationID == originalID, "Unchanged settings must produce a stable ID on every read")
        }
        expect(encodedSettings.count == 1, "Independent encoders must produce the same canonical preferences bytes")
        model.complete(.translated("Stable response fixture"), for: request)
        expect(model.outputText == "Stable response fixture", "Repeated configuration reads must not reject a valid translation")
    }

    private static func checkLocalDownloadCancellation() async {
        let model = makeModel()
        model.prepareLocalModel()
        expect(model.isPreparingLocal, "A model preparation must retain its busy state")
        model.section = .guide
        model.section = .settings
        expect(model.isPreparingLocal, "Navigating between pages must not discard the download state")
        model.cancelLocalPreparation()
        expect(model.isCancellingLocal, "Cancellation must remain visible until the task has stopped")
        // Cancel before yielding to the task, so this check never invokes a real model download.
        for _ in 0..<100 where model.isPreparingLocal { await Task.yield() }
        expect(!model.isPreparingLocal && !model.isCancellingLocal, "The cancelled task must clear its busy state")
        expect(model.localPreparationError == nil, "Download cancellation must not be presented as an error")
        expect(model.localPreparationMessage == hw("模型下载已取消。", "Model download cancelled."), "Download cancellation must be localized")
    }

    private static func checkEngineRouting() {
        var settings = EnginePreferences()
        let catalog = ModelCatalog(revision: "smoke-catalog", defaultLocalModelID: ModelCatalog.bundled.defaultLocalModelID,
                                   defaultAPIModelID: "smoke-api", localModels: ModelCatalog.bundled.localModels,
                                   apiModels: [.init(id: "smoke-api", name: "Smoke fixture API")])
        let automaticRuntime = EngineRuntime(settings: settings, catalog: catalog, persistSettings: false)
        expect(!automaticRuntime.settings.cloudFallbackEnabled, "API fallback must stay off by default")
        expect(automaticRuntime.resolvedEngine != .cloud, "Automatic mode must not choose API without opt-in")
        automaticRuntime.settings.cloudFallbackEnabled = true
        expect(!automaticRuntime.settings.cloudFallbackEnabled, "Mac must ignore legacy API fallback")
        expect(automaticRuntime.resolvedEngine != .cloud, "Automatic Mac mode must remain on-device")
        expect(!TranslationEngine.platformChoices.contains(.cloud), "Mac engine choices must not include API")

        settings.mode = .cloud
        settings.apiModelID = "smoke-api"
        let runtime = EngineRuntime(settings: settings, catalog: catalog, persistSettings: false)
        expect(runtime.settings.mode == .automatic && runtime.settings.apiModelID.isEmpty,
               "A saved API mode must migrate to on-device automatic translation")
        expect(runtime.resolvedEngine != .cloud, "Legacy configuration must never resolve to an API request")
        runtime.settings.mode = .apple
        let model = WorkspaceModel(runtime: runtime)
        model.preferences = KeyboardPreferences(market: .japan, source: .english)
        model.setSource("Keep this request on the device.")
        model.availability = .installed
        model.translate()
        guard let stale = model.request else { preconditionFailure("Installed Apple translation should create a request snapshot") }
        expect(stale.snapshot.engine == .apple, "The Mac request must freeze an on-device engine")
        expect(!model.dataFlowMessage.contains(settings.serviceURL), "Device translation must not report a cloud destination")
        runtime.settings.localModelID = "changed-model-fixture"
        model.complete(.translated("Stale on-device fixture"), for: stale)
        expect(model.outputText == nil, "Old engine settings must invalidate a response")
        model.enginePreferencesChanged()
        expect(model.request == nil && model.composition.source == "Keep this request on the device.",
               "Engine changes must preserve the original text")
        model.availability = .installed
        model.translate()
        guard let current = model.request else { preconditionFailure("Current on-device settings should create a request") }
        model.complete(.translated("Current on-device fixture"), for: current)
        expect(model.outputText == "Current on-device fixture", "Current on-device output should be accepted")
        runtime.settings.mode = .localModel
        model.enginePreferencesChanged()
        expect(model.outputText == nil, "Changing engines must invalidate a completed output")
    }

    private static func realtimeModel() -> WorkspaceModel {
        var settings = EnginePreferences()
        settings.mode = .apple
        let model = WorkspaceModel(runtime: EngineRuntime(settings: settings, catalog: .bundled, persistSettings: false), automaticTranslationDelay: .milliseconds(40))
        model.preferences = KeyboardPreferences(market: .japan, source: .english)
        model.availability = .installed
        model.editorAppeared()
        return model
    }

    private static func settleDebounce() async { try? await Task.sleep(for: .milliseconds(100)) }

    private static func checkNativeCompositionEvents() {
        let editor = CompositionTextView()
        var events: [(String, Bool)] = []
        editor.onEdit = { events.append(($0, $1)) }
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        expect(editor.hasMarkedText(), "Native editor must preserve an active marked range")
        expect(events.last?.0 == "ni" && events.last?.1 == true, "Marked native edits must report text and composition atomically")
        expect(events.allSatisfy { $0.1 }, "setMarkedText must not briefly publish provisional text as committed")
        events.removeAll()
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        expect(!editor.hasMarkedText() && events.last?.0 == "你" && events.last?.1 == false, "Choosing a candidate must report committed text")
        editor.setMarkedText("hao", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.unmarkText()
        expect(events.last?.1 == false, "Unmark without another text-change notification must still be reported")
    }

    private static func checkRealtimeTranslation() async {
        let model = realtimeModel()
        expect(model.autoTranslationEnabled, "Automatic translation must default to enabled")
        model.sourceEditorChanged("First input", hasMarkedText: false)
        expect(model.isDebouncing && model.request == nil, "Committed input must wait for the debounce interval")
        model.sourceEditorChanged("Second input", hasMarkedText: false)
        model.sourceEditorChanged("Latest input", hasMarkedText: false)
        await settleDebounce()
        guard let latest = model.request else { preconditionFailure("Stable committed input should automatically translate") }
        expect(latest.text == "Latest input" && !model.isDebouncing, "Rapid input must coalesce to the last text")
        expect(latest.streaming, "Automatic translation requests must enable streaming")
        model.updatePreview("最新の", for: latest)
        expect(model.streamPreview == "最新の" && model.outputText == nil, "An in-flight preview must never become copyable output")
        model.autoTranslationEnabled = false
        expect(model.request == nil && model.streamPreview == nil, "Disabling automatic mode must cancel its active request")
        model.updatePreview("Late automatic preview", for: latest)
        expect(model.streamPreview == nil, "A cancelled automatic stream must not reappear")
        model.setSource("Manual input")
        await settleDebounce()
        expect(model.request == nil && !model.isDebouncing, "Disabled automatic mode must leave new input idle")
        model.translate()
        expect(model.request?.text == "Manual input", "The manual translation action must remain available")
        expect(model.request?.streaming == false, "Disabling automatic mode must retain non-streaming manual translation")

        model.autoTranslationEnabled = true
        model.sourceEditorChanged("provisional ni", hasMarkedText: true)
        await settleDebounce()
        expect(model.isSourceComposing && model.request == nil && !model.canTranslate, "Marked text must cancel previous work and block automatic and manual translation")
        model.sourceEditorChanged("Confirmed text", hasMarkedText: false)
        await settleDebounce()
        expect(model.request?.text == "Confirmed text", "Committing an IME candidate must start a fresh debounce")
        model.sourceEditorChanged("Confirmed text hao", hasMarkedText: true)
        model.editorDisappeared()
        expect(model.composition.source == "Confirmed text" && !model.isSourceComposing, "Closing during composition must preserve only previously committed text")
        expect(model.request == nil && !model.isDebouncing, "Leaving the editor must cancel pending translation")
        model.editorAppeared()
        model.setSource("Will be cleared")
        model.clear()
        await settleDebounce()
        expect(model.request == nil && model.composition.source.isEmpty && !model.isDebouncing, "Clear must cancel a pending debounce")
        model.setSource("Will disappear")
        model.editorDisappeared()
        await settleDebounce()
        expect(model.request == nil && !model.isDebouncing, "A hidden editor must not begin an automatic request")

        model.editorAppeared()
        model.setSource("Change the target while waiting")
        model.preferences.market = .france
        model.preferencesChanged(persist: false)
        model.availability = .installed
        await settleDebounce()
        guard let french = model.request else { preconditionFailure("The new target should translate after the pause") }
        expect(french.market == .france, "Language changes must replace the scheduled language pair")
        model.runtime.settings.mode = .localModel
        model.enginePreferencesChanged()
        model.updatePreview("Stale French stream", for: french)
        expect(model.streamPreview == nil && model.request == nil, "Engine changes must reject old stream fragments immediately")
        model.editorDisappeared()
    }

    private static func checkAutomaticPreparationBoundary() async {
        let model = realtimeModel()
        model.availability = .supported
        model.setSource("Do not show download prompts while typing")
        await settleDebounce()
        expect(model.request == nil && model.canTranslate, "Automatic Apple translation must wait for installed packs while manual translation remains available")
        model.prepare()
        guard let preparation = model.request else { preconditionFailure("Manual preparation must remain available") }
        expect(preparation.operation == .prepare && !model.isDebouncing, "Language preparation must cancel any pending automatic debounce")
        model.complete(.prepared(true), for: preparation)
        await settleDebounce()
        expect(model.request == nil && !model.isDebouncing, "Completing preparation must not create an automatic loop")
        model.setSource("A new committed edit after preparation")
        await settleDebounce()
        expect(model.request?.operation == .translate, "A later edit may automatically translate with ready language packs")
        model.editorDisappeared()
    }

    private static func checkStreamingSafety() {
        let model = makeModel()
        model.preferences = KeyboardPreferences(market: .japan, source: .english)
        model.availability = .installed
        let original = "Order AB-2026: https://example.com/order. Contact help@example.com."
        model.setSource(original)
        model.translate()
        guard let first = model.request else { preconditionFailure("Streaming fixture should begin") }
        model.updatePreview("注文の詳細", for: first)
        model.updatePreview("注", for: first)
        expect(model.streamPreview == "注文の詳細", "Shorter cumulative fragments must not regress the preview")
        expect(model.outputText == nil, "Unvalidated partial text must never be usable as output")
        model.complete(.translated("Identifiers were removed"), for: first)
        expect(model.outputText == nil && model.streamPreview == nil && model.displayedError != nil, "A final result that changes business identifiers must clear the preview and remain unusable")
        expect(model.composition.source == original, "A failed final validation must preserve the source")
        model.updatePreview("A late chunk after failure", for: first)
        expect(model.streamPreview == nil, "Late fragments after failure must be discarded")
        model.translate()
        guard let second = model.request else { preconditionFailure("A failed stream should allow retry") }
        model.updatePreview("旧リクエストの遅い結果", for: first)
        expect(model.streamPreview == nil, "Retry must reject stream fragments from the old request ID")
        model.updatePreview("注文 AB-2026", for: second)
        let valid = "注文 AB-2026: https://example.com/order. 連絡先 help@example.com."
        model.complete(.translated(valid), for: second)
        expect(model.outputText == valid && model.streamPreview == nil, "Only a checked final result may become output")
        model.updatePreview("Late partial result", for: second)
        expect(model.outputText == valid && model.streamPreview == nil, "Late queued progress must not replace a final result")

        model.setSource("A revision guard fixture")
        model.translate()
        guard let revisionRequest = model.request else { preconditionFailure("Revision guard fixture should begin") }
        model.composition.invalidate()
        model.updatePreview("Wrong revision", for: revisionRequest)
        model.complete(.translated("Wrong revision final"), for: revisionRequest)
        expect(model.streamPreview == nil && model.outputText == nil, "A changed composition revision must reject partial and final results even when request ID matches")
        model.clear()
    }

}
