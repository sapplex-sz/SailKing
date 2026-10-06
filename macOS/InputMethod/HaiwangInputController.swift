import AppKit
import Carbon
@preconcurrency import InputMethodKit
import HaiwangCore

@MainActor private enum DraftRecovery {
    static var text: String?
}

@objc(HaiwangInputController)
@MainActor
final class HaiwangInputController: IMKInputController {
    private var preferenceDefaults = UserDefaults(suiteName: KeyboardPreferences.defaultsSuite) ?? .standard
    private var translationProvider: @MainActor (String, KeyboardPreferences) async throws -> String = {
        try await InputMethodTranslationClient.translate(text: $0, preferences: $1)
    }
    private var composition = CompositionSession()
    private var preferences = KeyboardPreferences()
    private var keyboard = InputMethodPreferences()
    private var active = false
    private var passwordMode = false
    private var romanMode = false
    private var ownsMarkedText = false
    private var overflow = ""
    private var previewSettings: EnginePreferences?
    private var translationTask: Task<Void, Never>?
    private var currentClient: (any IMKTextInput)?
    private var currentClientID: ObjectIdentifier?
    private var heldShiftKeys: Set<UInt16> = []
    private var shiftTap: (key: UInt16, timestamp: TimeInterval)?
    private lazy var panel = makePanel()
    private lazy var pinyin: HQPinyinEngine = {
        let data = Bundle.main.resourceURL!.appendingPathComponent("RimeData").path
        let user = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Haiwang/Rime", isDirectory: true).path
        return HQPinyinEngine(sharedDataPath: data, userDataPath: user)
    }()

    #if DEBUG
    var presentsCandidateWindow = true
    var testingPanelModel: CandidatePanelModel { panel.model }
    func configureForTesting(defaults: UserDefaults, pinyin engine: HQPinyinEngine,
                             translate: @escaping @MainActor (String, KeyboardPreferences) async throws -> String) {
        precondition(!active)
        preferenceDefaults = defaults
        pinyin = engine
        translationProvider = translate
        preferences = KeyboardPreferences.load(from: defaults)
        keyboard = InputMethodPreferences.load(from: defaults)
    }
    #endif

    private var secureInput: Bool { passwordMode || IsSecureEventInputEnabled() }
    private var usesPinyin: Bool { keyboard.inputMode == .pinyin && !romanMode }
    private var translating: Bool { keyboard.translationEnabled && !romanMode }
    private var hasComposition: Bool { !composition.source.isEmpty || !overflow.isEmpty || pinyin.isComposing || composition.translation != nil }
    private var completeDraft: String {
        String(composition.source.prefix(composition.cursor)) + overflow + pinyin.preedit
        + String(composition.source.dropFirst(composition.cursor))
    }

    override func activateServer(_ sender: Any!) {
        resetShiftTap()
        bindClient(sender)
        active = true
        preferences = KeyboardPreferences.load(from: preferenceDefaults)
        keyboard = InputMethodPreferences.load(from: preferenceDefaults)
        if secureInput { discardDraft(recover: false) }
    }

    override func deactivateServer(_ sender: Any!) {
        if active && !secureInput && !translating { finishOrdinaryComposition() }
        discardDraft(recover: !secureInput)
        active = false
        currentClient = nil
        currentClientID = nil
    }

    override func commitComposition(_ sender: Any!) {
        bindClient(sender)
        if secureInput { discardDraft(recover: false); return }
        if translating {
            // A focus/selection change must never implicitly accept an unreviewed translation.
            discardDraft(recover: true)
        } else {
            finishOrdinaryComposition()
            discardDraft(recover: true)
        }
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.union(.flagsChanged).rawValue)
    }

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        guard tag == Int(kTextServiceInputModePropertyTag), let identifier = value as? String else {
            super.setValue(value, forTag: tag, client: sender)
            return
        }
        bindClient(sender)
        let isPassword = identifier == "com.apple.inputmethod.Password"
        let isRoman = identifier == "com.apple.inputmethod.Roman"
        let isHaiwang = identifier == InputMethodPreferences.systemSourceID
        let isLegacyEnglish = identifier == InputMethodPreferences.legacyEnglishSourceID
        guard isPassword || isRoman || isHaiwang || isLegacyEnglish else {
            super.setValue(value, forTag: tag, client: sender)
            return
        }
        // macOS can report the same source again when focus changes. Its stable ID
        // must not overwrite the Chinese/English choice or clear an ongoing draft.
        if isHaiwang && !passwordMode && !romanMode { return }
        if active && !isPassword && !secureInput && !translating { finishOrdinaryComposition() }
        discardDraft(recover: !isPassword && !secureInput)
        passwordMode = isPassword
        romanMode = isRoman
        if isLegacyEnglish {
            keyboard.inputMode = .english
            keyboard.save(to: preferenceDefaults)
        }
    }

    override func value(forTag tag: Int, client sender: Any!) -> Any! {
        if tag == Int(kTextServiceInputModePropertyTag) {
            if passwordMode { return "com.apple.inputmethod.Password" }
            if romanMode { return "com.apple.inputmethod.Roman" }
            return InputMethodPreferences.systemSourceID
        }
        return super.value(forTag: tag, client: sender)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown || event.type == .flagsChanged,
              let client = sender as? any IMKTextInput else { return false }
        bindClient(client)
        active = true
        if secureInput { discardDraft(recover: false); return false }
        let updatedPreferences = KeyboardPreferences.load(from: preferenceDefaults)
        let updatedKeyboard = InputMethodPreferences.load(from: preferenceDefaults)
        if updatedPreferences != preferences {
            cancelPending()
            composition.invalidate()
            preferences = updatedPreferences
        }
        if updatedKeyboard != keyboard {
            discardDraft(recover: true)
            keyboard = updatedKeyboard
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .flagsChanged {
            handleModifierChange(event, modifiers: modifiers)
            return false
        }
        // A Shift used with another key belongs to that keystroke, not a language toggle.
        shiftTap = nil
        if event.keyCode == 49 && modifiers.contains([.control, .shift]) && !modifiers.contains(.command) && !modifiers.contains(.option) {
            if !event.isARepeat { toggleInputMode(nil) }
            return true
        }
        if event.keyCode == 17 && modifiers.contains([.control, .shift]) && !modifiers.contains(.command) && !modifiers.contains(.option) {
            toggleTranslation(nil)
            return true
        }
        // Do not retain a preview tied to a selection changed by a host shortcut.
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
            if hasComposition { commitComposition(client) }
            return false
        }

        switch event.keyCode {
        case 53:
            guard hasComposition else { return false }
            cancelPending()
            if composition.translation != nil || composition.errorMessage != nil {
                composition.invalidate()
            } else if pinyin.isComposing {
                pinyin.clear()
            } else { composition.reset(); overflow = "" }
            refresh()
            return true
        case 36, 76:
            if event.isARepeat && translating { return true }
            guard hasComposition else { return false }
            if !translating { confirmPinyin(); refresh(); return true }
            if composition.pendingRevision != nil { return true }
            if composition.translation != nil { insertConfirmedTranslation(); return true }
            confirmPinyin()
            translate()
            return true
        case 51:
            guard hasComposition else { return false }
            cancelPending()
            composition.invalidate()
            if pinyin.isComposing {
                _ = pinyin.processKey(0xff08, mask: 0)
                collectPinyinCommit()
            } else if !overflow.isEmpty { overflow.removeLast() }
            else { composition.deleteBackward() }
            refresh()
            return true
        case 123, 124, 125, 126, 116, 121:
            if pinyin.isComposing {
                let keys: [UInt16: Int32] = [123: 0xff51, 124: 0xff53, 125: 0xff54, 126: 0xff52, 116: 0xff55, 121: 0xff56]
                _ = pinyin.processKey(keys[event.keyCode]!, mask: 0)
                collectPinyinCommit()
                refresh()
                return true
            }
            if translating && hasComposition && (event.keyCode == 123 || event.keyCode == 124) {
                cancelPending()
                if overflow.isEmpty { composition.moveCursor(by: event.keyCode == 123 ? -1 : 1) }
                refresh()
                return true
            }
            if hasComposition { commitComposition(client) }
            return false
        case 115, 119:
            if hasComposition { commitComposition(client) }
            return false
        case 48:
            if hasComposition { commitComposition(client) }
            return false
        default: break
        }

        guard let text = event.characters, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control && !(0xF700...0xF8FF).contains($0.value) }) else { return false }
        if !translating && !usesPinyin { return false }
        if translating && composition.source.count >= composition.maximumLength && !pinyin.isComposing {
            refresh()
            return true
        }
        if text == " " && !hasComposition { return false }
        cancelPending()
        composition.invalidate()
        if usesPinyin && pinyin.available,
           let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1, scalar.value < 128 {
            let consumed = pinyin.processKey(Int32(scalar.value), mask: modifiers.contains(.shift) ? 1 : 0)
            collectPinyinCommit()
            if !consumed {
                if translating { insertSource(text) }
                else { refresh(); return false }
            }
        } else if translating { insertSource(text) }
        else { return false }
        refresh()
        return true
    }

    private func bindClient(_ sender: Any?) {
        guard let client = sender as? any IMKTextInput else { return }
        let id = ObjectIdentifier(client as AnyObject)
        if let previous = currentClientID, previous != id {
            if active && !secureInput && !translating { finishOrdinaryComposition() }
            discardDraft(recover: !secureInput)
        }
        currentClient = client
        currentClientID = id
    }

    private func insertSource(_ value: String) {
        let available = max(0, composition.maximumLength - composition.source.count)
        composition.insert(String(value.prefix(available)))
        overflow += String(value.dropFirst(available))
    }

    private func collectPinyinCommit() {
        guard let committed = pinyin.takeCommit(), !committed.isEmpty else { return }
        if translating { insertSource(committed) }
        else {
            currentClient?.insertText(committed, replacementRange: NSRange(location: NSNotFound, length: 0))
            ownsMarkedText = false
        }
    }

    private func confirmPinyin() {
        guard pinyin.isComposing else { return }
        // Selection can commit only part of a phrase. Keep remaining preedit intact.
        _ = pinyin.processKey(0x20, mask: 0)
        collectPinyinCommit()
    }

    private func finishOrdinaryComposition() {
        guard !translating, !secureInput else { return }
        finishPinyinComposition()
    }

    private func finishPinyinComposition() {
        guard !secureInput else { return }
        for _ in 0..<32 {
            guard pinyin.isComposing else { break }
            let before = pinyin.preedit
            confirmPinyin()
            if pinyin.preedit == before { break }
        }
        // A rare partially convertible sequence remains literal rather than disappearing.
        if pinyin.isComposing {
            let remainder = pinyin.preedit
            if translating { insertSource(remainder) }
            else {
                currentClient?.insertText(remainder, replacementRange: NSRange(location: NSNotFound, length: 0))
                ownsMarkedText = false
            }
            pinyin.clear()
        }
    }

    private func replyStillMatches(_ savedPreferences: KeyboardPreferences, keyboard savedKeyboard: InputMethodPreferences) -> Bool {
        guard KeyboardPreferences.load(from: preferenceDefaults) == savedPreferences, InputMethodPreferences.load(from: preferenceDefaults) == savedKeyboard else {
            composition.invalidate()
            preferences = KeyboardPreferences.load(from: preferenceDefaults)
            let latest = InputMethodPreferences.load(from: preferenceDefaults)
            if latest != keyboard { discardDraft(recover: true); keyboard = latest }
            refresh()
            return false
        }
        return true
    }

    private func translate() {
        guard active, !secureInput, !pinyin.isComposing, overflow.isEmpty else { refresh(); return }
        guard let revision = composition.beginTranslation() else { return }
        let source = composition.source
        var requestPreferences = preferences
        // A single draft can contain Chinese and English after an internal mode switch.
        requestPreferences.source = .automatic
        let savedPreferences = preferences
        let savedKeyboard = keyboard
        let savedEngineSettings = EnginePreferences.load(from: preferenceDefaults)
        let clientID = currentClientID
        refresh()
        translationTask = Task { @MainActor [weak self] in
            do {
                let output = try await self?.translationProvider(source, requestPreferences)
                guard let output else { return }
                guard let self, !Task.isCancelled, self.active, !self.secureInput,
                      self.currentClientID == clientID else { return }
                guard self.replyStillMatches(savedPreferences, keyboard: savedKeyboard) else { return }
                guard EnginePreferences.load(from: self.preferenceDefaults) == savedEngineSettings else {
                    self.composition.invalidate()
                    self.refresh()
                    return
                }
                self.composition.finish(output, revision: revision)
                self.previewSettings = savedEngineSettings
                self.refresh()
            } catch {
                guard let self, !Task.isCancelled, self.active, !self.secureInput, self.currentClientID == clientID else { return }
                guard self.replyStillMatches(savedPreferences, keyboard: savedKeyboard) else { return }
                self.composition.fail(error.localizedDescription, revision: revision)
                self.refresh()
            }
        }
    }

    private func insertConfirmedTranslation() {
        guard previewSettings == EnginePreferences.load(from: preferenceDefaults) else {
            composition.invalidate()
            refresh()
            return
        }
        guard active, !secureInput, let client = currentClient,
              KeyboardPreferences.load(from: preferenceDefaults) == preferences, InputMethodPreferences.load(from: preferenceDefaults) == keyboard,
              let result = composition.takeTranslation() else { return }
        cancelPending()
        client.insertText(result, replacementRange: NSRange(location: NSNotFound, length: 0))
        ownsMarkedText = false
        overflow = ""
        pinyin.clear()
        panel.hide()
    }

    private func insertOriginal() {
        guard active, !secureInput, let client = currentClient else { return }
        confirmPinyin()
        guard !pinyin.isComposing else { refresh(); return }
        let text = completeDraft
        guard !text.isEmpty else { return }
        cancelPending()
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        ownsMarkedText = false
        composition.reset()
        overflow = ""
        pinyin.clear()
        panel.hide()
    }

    private func cancelPending() { translationTask?.cancel(); translationTask = nil }

    private func clearMarkedText() {
        guard ownsMarkedText, let client = currentClient else { ownsMarkedText = false; return }
        let marked = client.markedRange()
        if marked.location != NSNotFound {
            client.insertText("", replacementRange: marked)
        }
        ownsMarkedText = false
    }

    private func discardDraft(recover: Bool) {
        resetShiftTap()
        cancelPending()
        if recover && !completeDraft.isEmpty { DraftRecovery.text = completeDraft }
        if !recover { DraftRecovery.text = nil }
        clearMarkedText()
        composition.reset()
        overflow = ""
        pinyin.clear()
        panel.hide()
    }

    private func updateMarkedText() {
        guard active, !secureInput, let client = currentClient else { return }
        let text = translating ? completeDraft : pinyin.preedit
        guard !text.isEmpty else { clearMarkedText(); return }
        let prefix = translating ? String(composition.source.prefix(composition.cursor)) + overflow : ""
        let cursor = (prefix + pinyin.preedit).utf16.count
        let marked = NSAttributedString(string: text, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
        client.setMarkedText(marked, selectionRange: NSRange(location: cursor, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        ownsMarkedText = true
    }

    private func refresh() {
        if secureInput { discardDraft(recover: false); return }
        if composition.translation != nil && previewSettings != EnginePreferences.load(from: preferenceDefaults) { composition.invalidate() }
        updateMarkedText()
        guard active, hasComposition else { panel.hide(); return }
        panel.model.preferences = preferences
        panel.model.keyboard = keyboard
        panel.model.source = composition.source
        panel.model.cursor = composition.cursor
        panel.model.preedit = overflow + pinyin.preedit
        panel.model.candidates = pinyin.candidates
        panel.model.highlightedIndex = pinyin.highlightedCandidateIndex
        panel.model.translation = composition.translation
        panel.model.isTranslating = composition.pendingRevision != nil
        panel.model.error = !overflow.isEmpty ? "原文超过 2000 字。请删减后翻译，或选择直接上屏原文。"
            : usesPinyin && !pinyin.available ? "拼音词库未就绪，当前按英文直接输入。请检查安装。" : composition.errorMessage
        panel.model.engine = EnginePreferences.load(from: preferenceDefaults).mode == .localModel ? "本地模型" : "设备端翻译"
        var rect = NSRect.zero
        if let client = currentClient {
            let selection = client.selectedRange()
            _ = client.attributes(forCharacterIndex: selection.location == NSNotFound ? 0 : selection.location, lineHeightRectangle: &rect)
        }
        #if DEBUG
        if presentsCandidateWindow { panel.show(at: rect) }
        #else
        panel.show(at: rect)
        #endif
    }

    private func makePanel() -> CandidatePanel {
        let panel = CandidatePanel()
        panel.model.choose = { [weak self] index in
            guard let self, self.active, !self.secureInput else { return }
            self.cancelPending()
            self.composition.invalidate()
            _ = self.pinyin.selectCandidate(UInt(index))
            self.collectPinyinCommit()
            self.refresh()
        }
        panel.model.changeMarket = { [weak self] market in
            guard let self, !self.secureInput else { return }
            self.cancelPending()
            self.composition.invalidate()
            self.preferences.market = market
            self.preferences.save(to: preferenceDefaults)
            self.refresh()
        }
        panel.model.confirm = { [weak self] in self?.insertConfirmedTranslation() }
        panel.model.insertOriginal = { [weak self] in self?.insertOriginal() }
        panel.model.toggleTranslation = { [weak self] in self?.toggleTranslation(nil) }
        panel.model.toggleInputMode = { [weak self] in self?.toggleInputMode(nil) }
        panel.model.openApp = { NSWorkspace.shared.open(URL(string: "haiwang://workspace")!) }
        return panel
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "出海王输入法")
        let language = NSMenuItem(title: keyboard.inputMode == .pinyin ? "切换英文直输 · Shift" : "切换中文拼音 · Shift", action: #selector(toggleInputMode(_:)), keyEquivalent: "")
        language.isEnabled = !secureInput && !romanMode
        menu.addItem(language)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: keyboard.translationEnabled ? "✓ 翻译输入 · 回车预览后上屏" : "启用翻译输入 · ⌃⇧T", action: #selector(toggleTranslation(_:)), keyEquivalent: "")
        menu.addItem(toggle)
        menu.addItem(NSMenuItem(title: "直接上屏原文", action: #selector(commitOriginal(_:)), keyEquivalent: ""))
        let recover = NSMenuItem(title: "恢复未上屏草稿", action: #selector(recoverDraft(_:)), keyEquivalent: "")
        recover.isEnabled = DraftRecovery.text != nil && !secureInput
        menu.addItem(recover)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "候选窗口跟随光标", action: #selector(resetCandidatePosition(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "语言、模型与键盘设置…", action: #selector(openWorkspace(_:)), keyEquivalent: ""))
        return menu
    }

    private func bindMenuClient(_ sender: Any?) {
        if let info = sender as? [String: Any], let client = info[kIMKCommandClientName as String] { bindClient(client) }
    }

    private func resetShiftTap() {
        shiftTap = nil
        heldShiftKeys.removeAll()
    }

    private func handleModifierChange(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) {
        guard !romanMode, event.keyCode == 56 || event.keyCode == 60 else {
            shiftTap = nil
            return
        }
        if modifiers.contains(.shift) && !heldShiftKeys.contains(event.keyCode) {
            let singleShift = heldShiftKeys.isEmpty && modifiers.subtracting([.capsLock, .numericPad]) == .shift
            heldShiftKeys.insert(event.keyCode)
            shiftTap = singleShift ? (event.keyCode, event.timestamp) : nil
        } else {
            heldShiftKeys.remove(event.keyCode)
            let tap = shiftTap
            shiftTap = nil
            if !modifiers.contains(.shift) { heldShiftKeys.removeAll() }
            if let tap, tap.key == event.keyCode, heldShiftKeys.isEmpty,
               modifiers.subtracting([.capsLock, .numericPad]).isEmpty,
               (0...0.6).contains(event.timestamp - tap.timestamp) {
                toggleInputMode(nil)
            }
        }
    }

    @objc private func toggleInputMode(_ sender: Any?) {
        bindMenuClient(sender)
        guard active, !secureInput, !romanMode else { return }
        // Confirm pending Chinese words first. Translation drafts remain marked in
        // the same client while ordinary words are committed before English typing.
        finishPinyinComposition()
        cancelPending()
        composition.invalidate()
        keyboard.inputMode = keyboard.inputMode == .pinyin ? .english : .pinyin
        keyboard.save(to: preferenceDefaults)
        resetShiftTap()
        refresh()
    }

    @objc private func toggleTranslation(_ sender: Any?) {
        bindMenuClient(sender)
        guard !secureInput else { return }
        discardDraft(recover: true)
        keyboard.translationEnabled.toggle()
        keyboard.save(to: preferenceDefaults)
    }

    @objc private func commitOriginal(_ sender: Any?) { bindMenuClient(sender); insertOriginal() }

    @objc private func recoverDraft(_ sender: Any?) {
        bindMenuClient(sender)
        guard active, !secureInput, let draft = DraftRecovery.text else { return }
        discardDraft(recover: true)
        keyboard.translationEnabled = true
        keyboard.save(to: preferenceDefaults)
        composition.setSource(draft)
        overflow = String(draft.dropFirst(composition.maximumLength))
        DraftRecovery.text = nil
        refresh()
    }

    @objc private func openWorkspace(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "haiwang://workspace")!)
    }

    @objc private func resetCandidatePosition(_ sender: Any?) { panel.resetPosition() }
}
