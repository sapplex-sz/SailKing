import AppKit
import Carbon
import Foundation
@preconcurrency import InputMethodKit
import HaiwangCore

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@MainActor
private final class DeferredTranslator {
    struct Call { let text: String; let preferences: KeyboardPreferences }
    private(set) var calls: [Call] = []
    private var continuations: [CheckedContinuation<String, any Error>] = []

    func translate(_ text: String, _ preferences: KeyboardPreferences) async throws -> String {
        calls.append(Call(text: text, preferences: preferences))
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func complete(_ text: String) {
        expect(!continuations.isEmpty, "A fake translation must be pending before completion")
        continuations.removeFirst().resume(returning: text)
    }

    func fail() {
        expect(!continuations.isEmpty, "A fake translation must be pending before failure")
        continuations.removeFirst().resume(throwing: OfflineSmokeFailure.simulatedFailure)
    }

    func releasePending() {
        for continuation in continuations { continuation.resume(returning: "CANCELLED_TEST_RESPONSE") }
        continuations = []
    }
}

@MainActor
private final class Harness {
    let client = MockInputClient()
    let engine: HQPinyinEngine
    let translator = DeferredTranslator()
    let controller: HaiwangInputController
    let defaults: UserDefaults
    private let suite: String

    init(server: IMKServer, userPath: String, mode: InputMethodInputMode = .pinyin, translation: Bool = false) {
        suite = "com.haiwang.tests.InputMethodSmoke.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        KeyboardPreferences(market: .unitedStates, source: .automatic).save(to: defaults)
        InputMethodPreferences(inputMode: mode, translationEnabled: translation).save(to: defaults)
        engine = HQPinyinEngine(sharedDataPath: Bundle.main.resourceURL!.appendingPathComponent("RimeData").path,
                                userDataPath: userPath)
        expect(engine.available, engine.errorDescription ?? "The isolated real Rime engine must initialize")
        controller = HaiwangInputController(server: server, delegate: nil, client: nil)!
        controller.configureForTesting(defaults: defaults, pinyin: engine, translate: translator.translate)
        controller.presentsCandidateWindow = false
        controller.activateServer(client)
        // Clear previous test's process-local recovery without changing its stored typing language.
        controller.setValue("com.apple.inputmethod.Password", forTag: Int(kTextServiceInputModePropertyTag), client: client)
        controller.setValue(mode.systemID, forTag: Int(kTextServiceInputModePropertyTag), client: client)
    }

    func finish() {
        controller.deactivateServer(client)
        translator.releasePending()
        defaults.removePersistentDomain(forName: suite)
    }

    @discardableResult
    func send(_ text: String, key: UInt16 = 0, modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false, to other: MockInputClient? = nil) -> Bool {
        let target = other ?? client
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                    context: nil, characters: text, charactersIgnoringModifiers: text,
                                    isARepeat: repeatKey, keyCode: key)!
        let consumed = controller.handle(event, client: target)
        if !consumed { target.receiveUnhandled(event) }
        return consumed
    }

    func type(_ text: String, to other: MockInputClient? = nil) {
        for character in text { send(String(character), to: other) }
    }

    func modifiers(_ flags: NSEvent.ModifierFlags, key: UInt16 = 56, timestamp: TimeInterval = 100, to other: MockInputClient? = nil) {
        let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                                    timestamp: timestamp, windowNumber: 0, context: nil,
                                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key)!
        expect(!controller.handle(event, client: other ?? client), "Modifier state must remain available to the host")
    }

    func tapShift(key: UInt16 = 56) {
        modifiers(.shift, key: key)
        modifiers([], key: key, timestamp: 100.1)
    }

    func action(containing title: String, client: MockInputClient? = nil) {
        let menu = controller.menu()!
        guard let item = menu.items.first(where: { $0.title.contains(title) }), let selector = item.action else {
            expect(false, "Input method menu must contain \(title)")
            return
        }
        let dictionary: [String: Any] = [kIMKCommandClientName as String: client ?? self.client,
                                       kIMKCommandMenuItemName as String: item]
        _ = controller.perform(selector, with: dictionary)
    }

    func waitFor(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        expect(false, "Timed out: \(message)")
    }
}

@main
private enum InputMethodSmoke {
    @MainActor
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: InputMethodSmoke <isolated-user-data>\n".utf8))
            exit(1)
        }
        guard !IsSecureEventInputEnabled() else {
            FileHandle.standardError.write(Data("SKIP: Another desktop process has enabled secure input. No ordinary/translation tests were run.\n".utf8))
            exit(77)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard let server = IMKServer(name: "HaiwangInputSmoke-\(ProcessInfo.processInfo.processIdentifier)",
                                     bundleIdentifier: Bundle.main.bundleIdentifier!) else {
            expect(false, "The isolated IMK test server must initialize")
            return
        }
        let userPath = CommandLine.arguments[1]
        ordinaryTyping(server, userPath)
        ordinaryCandidateSelection(server, userPath)
        ordinaryFocusAndModeChanges(server, userPath)
        singleSourceTypingModes(server, userPath)
        unicodeSelectionAndAnchor(server, userPath)
        await translationPreviewAndReturn(server, userPath)
        await mixedLanguageDraftSwitching(server, userPath)
        await cancellationAndStaleResults(server, userPath)
        await preferenceChangesAndErrors(server, userPath)
        await overflowRecovery(server, userPath)
        draftCursorRecoveryAndShortcuts(server, userPath)
        passwordAndRoman(server, userPath)
        print("PASS: all real-controller offline smoke groups; no system input-source changes, visible candidate windows, network requests, or real-user dictionary/preferences writes")
    }

    @MainActor
    private static func ordinaryTyping(_ server: IMKServer, _ userPath: String) {
        let h = Harness(server: server, userPath: userPath)
        defer { h.finish() }
        h.type("nihao")
        expect(h.client.markedRange().location != NSNotFound, "Unconfirmed Pinyin must be marked in the host")
        expect(h.client.committedText.isEmpty, "Unconfirmed Pinyin is not ordinary committed text")
        expect(h.engine.candidates.first == "你好", "Fresh real Rime dictionary must offer 你好 first")
        expect(h.send(" ", key: 49), "Space must confirm a Pinyin candidate")
        expect(h.client.document == "你好", "nihao + Space must insert real Chinese text")
        expect(h.client.markedRange().location == NSNotFound, "Confirmed Pinyin must clear host marked text")
        expect(h.translator.calls.isEmpty && h.client.hostReturnCount == 0, "Ordinary Pinyin neither translates nor sends Return")
        print("PASS: ordinary nihao + Space → 你好; real Rime commit and host marked-text clearing")
    }

    @MainActor
    private static func ordinaryCandidateSelection(_ server: IMKServer, _ userPath: String) {
        for number in [2, 6, 9] {
            let h = Harness(server: server, userPath: userPath)
            h.type("hao")
            expect(h.engine.candidates.count >= number, "The current real candidate page must contain digit \(number)")
            let expected = h.engine.candidates[number - 1]
            expect(h.controller.testingPanelModel.candidates[number - 1] == expected, "Displayed and engine numeric candidates must match")
            h.send(String(number))
            expect(h.client.document == expected, "Digit \(number) must commit exactly its visible candidate")
            expect(h.client.markedRange().location == NSNotFound, "Digit selection must clear marked text")
            h.finish()
        }
        let h = Harness(server: server, userPath: userPath)
        defer { h.finish() }
        h.type("hao")
        h.send("", key: 125)
        expect(h.engine.highlightedCandidateIndex == 1, "Down arrow must highlight the second real candidate")
        expect(h.controller.testingPanelModel.highlightedIndex == 1, "The panel highlight must match Rime")
        h.send("", key: 126)
        expect(h.engine.highlightedCandidateIndex == 0, "Up arrow must restore the first candidate")
        h.send("", key: 125)
        let expected = h.engine.candidates[1]
        h.send(" ", key: 49)
        expect(h.client.document == expected, "Space must commit the highlighted candidate")
        print("PASS: digits 2/6/9 and Up/Down + Space agree with the real visible candidate page")
    }

    @MainActor
    private static func ordinaryFocusAndModeChanges(_ server: IMKServer, _ userPath: String) {
        for route in 0..<4 {
            let h = Harness(server: server, userPath: userPath)
            h.type("nihaoshijie")
            switch route {
            case 0: h.controller.commitComposition(h.client)
            case 1: h.controller.deactivateServer(h.client)
            case 2: h.action(containing: "切换英文直输")
            default:
                let other = MockInputClient()
                h.type("hao", to: other)
                expect(other.committedText.isEmpty, "Old ordinary composition must not be committed into a new client")
            }
            expect(!h.client.document.isEmpty, "Ordinary focus/mode route \(route) must retain typed content")
            expect(h.client.markedRange().location == NSNotFound, "Ordinary focus/mode route \(route) must end host marking")
            expect(!h.engine.isComposing || route == 3, "Ordinary focus/mode route \(route) must consume the old preedit")
            expect(h.translator.calls.isEmpty, "Ordinary focus changes must not translate")
            h.finish()
        }
        print("PASS: ordinary client commit, deactivate, internal language change, and client replacement preserve source in the old host")
    }

    @MainActor
    private static func singleSourceTypingModes(_ server: IMKServer, _ userPath: String) {
        let h = Harness(server: server, userPath: userPath)
        defer { h.finish() }
        expect(h.controller.recognizedEvents(h.client) & Int(NSEvent.EventTypeMask.flagsChanged.rawValue) != 0,
               "The actual IMK controller must request modifier changes for Shift taps")
        h.type("nihao")
        // Reporting the same source is a no-op, including while Chinese is marked.
        h.controller.setValue(InputMethodPreferences.systemSourceID, forTag: Int(kTextServiceInputModePropertyTag), client: h.client)
        expect(h.engine.isComposing && h.client.committedText.isEmpty, "A repeated system source notification must preserve composition")
        h.tapShift()
        expect(h.client.document == "你好" && !h.engine.isComposing && h.client.markedRange().location == NSNotFound,
               "Shift switches to English after safely committing the pending real Chinese candidate")
        expect(InputMethodPreferences.load(from: h.defaults) == .init(inputMode: .english, translationEnabled: false),
               "Shift must persist English without changing the translation behavior")
        expect(h.controller.value(forTag: Int(kTextServiceInputModePropertyTag), client: h.client) as? String == InputMethodPreferences.systemSourceID,
               "English typing must retain the one canonical system source ID")
        h.type(" hello")
        h.modifiers(.shift)
        h.send("A", modifiers: .shift)
        h.modifiers([], timestamp: 100.1)
        expect(h.client.document == "你好 helloA" && InputMethodPreferences.load(from: h.defaults).inputMode == .english,
               "Shift with a letter must type uppercase without changing language")
        h.modifiers(.shift)
        h.modifiers([], timestamp: 101)
        expect(InputMethodPreferences.load(from: h.defaults).inputMode == .english, "A held Shift must not toggle language")
        h.modifiers(.shift)
        h.modifiers(.shift, key: 60, timestamp: 100.01)
        h.modifiers(.shift, timestamp: 100.05)
        h.modifiers([], key: 60, timestamp: 100.1)
        expect(InputMethodPreferences.load(from: h.defaults).inputMode == .english, "Holding both Shift keys must not create a single-key tap")
        h.controller.deactivateServer(h.client)
        h.controller.activateServer(h.client)
        h.controller.setValue(InputMethodPreferences.systemSourceID, forTag: Int(kTextServiceInputModePropertyTag), client: h.client)
        h.type(" persisted")
        expect(h.client.document == "你好 helloA persisted" && InputMethodPreferences.load(from: h.defaults).inputMode == .english,
               "Reactivation must preserve English even though the system source keeps its former Pinyin ID")
        h.send(" ", key: 49, modifiers: [.control, .shift])
        expect(InputMethodPreferences.load(from: h.defaults).inputMode == .pinyin, "Control+Shift+Space must switch inside the source")
        h.send(" ", key: 49, modifiers: [.control, .shift], repeatKey: true)
        expect(InputMethodPreferences.load(from: h.defaults).inputMode == .pinyin, "Shortcut autorepeat must not switch twice")
        h.tapShift(key: 60)
        expect(InputMethodPreferences.load(from: h.defaults).inputMode == .english, "Right Shift must also support a standalone tap")
        h.action(containing: "切换中文拼音")
        expect(InputMethodPreferences.load(from: h.defaults).inputMode == .pinyin, "The actual input method menu must switch languages")
        h.modifiers(.shift)
        h.modifiers([], timestamp: 100.1, to: MockInputClient())
        expect(InputMethodPreferences.load(from: h.defaults).inputMode == .pinyin, "A release in another client must not finish the previous client's tap")
        h.controller.setValue("com.apple.inputmethod.Password", forTag: Int(kTextServiceInputModePropertyTag), client: h.client)
        h.tapShift()
        expect(InputMethodPreferences.load(from: h.defaults).inputMode == .pinyin && h.translator.calls.isEmpty,
               "Shift must not change language or translate inside password mode")
        print("PASS: single system source, both Shift taps, uppercase/held/both-Shift guards, menu/shortcut switching, focus persistence, and password bypass")
    }

    @MainActor
    private static func unicodeSelectionAndAnchor(_ server: IMKServer, _ userPath: String) {
        let h = Harness(server: server, userPath: userPath)
        defer { h.finish() }
        let prefix = "订单👩🏽‍💻"
        h.client.reset(prefix + "替换内容尾", selectedRange: NSRange(location: prefix.utf16.count, length: "替换内容".utf16.count))
        h.type("nihao")
        expect(h.client.markedRange().location == prefix.utf16.count, "Marked text must replace the selected UTF-16 range")
        expect(h.client.lastAttributeIndex == h.client.selectedRange().location, "Candidate anchor must use the actual caret rather than character zero")
        h.send(" ", key: 49)
        expect(h.client.document == prefix + "你好尾", "Chinese replacement must preserve Unicode prefix and suffix")
        print("PASS: Unicode host selection replacement and current-caret candidate anchoring")
    }

    @MainActor
    private static func translationPreviewAndReturn(_ server: IMKServer, _ userPath: String) async {
        let h = Harness(server: server, userPath: userPath, translation: true)
        defer { h.finish() }
        h.type("nihao")
        h.send(" ", key: 49)
        expect(h.client.document == "你好" && h.client.committedText.isEmpty, "Chinese source stays marked, not committed, in translation mode")
        h.send("\r", key: 36, repeatKey: true)
        expect(h.translator.calls.isEmpty, "Autorepeated Return must not start translation")
        h.send("\r", key: 36)
        await h.waitFor("translation starts") { h.translator.calls.count == 1 }
        expect(h.translator.calls[0].text == "你好" && h.translator.calls[0].preferences.source == .automatic, "Only confirmed Chinese source must reach the translator with automatic language detection")
        expect(h.client.inserted.filter { !$0.isEmpty }.isEmpty, "Starting translation must never insert source or a newline")
        h.translator.complete("Hello")
        await h.waitFor("translation preview") { h.controller.testingPanelModel.translation == "Hello" }
        expect(h.client.committedText.isEmpty, "Preparing a translation preview must not commit it")
        h.send("\r", key: 36, repeatKey: true)
        expect(h.client.committedText.isEmpty, "Autorepeated Return must not accept a prepared preview")
        h.send("\r", key: 36)
        expect(h.client.document == "Hello" && h.client.markedRange().location == NSNotFound, "A separate Return confirms translation once and clears marking")
        h.send("\r", key: 36, repeatKey: true)
        expect(h.client.document == "Hello" && h.client.hostReturnCount == 0, "Post-confirmation autorepeat must not reach the host Return action")
        h.send("\r", key: 36)
        expect(h.client.hostReturnCount == 1, "A later independent Return outside a draft must retain normal host behavior")
        print("PASS: source marking, fake translation preview, explicit single commit, and Return autorepeat suppression")
    }

    @MainActor
    private static func mixedLanguageDraftSwitching(_ server: IMKServer, _ userPath: String) async {
        let h = Harness(server: server, userPath: userPath, translation: true)
        defer { h.finish() }
        h.type("nihao")
        h.tapShift()
        expect(h.client.document == "你好" && h.client.committedText.isEmpty && !h.engine.isComposing,
               "Switching a translation draft confirms Chinese into the draft rather than the host")
        h.type(" SKU-DEMO")
        expect(h.controller.testingPanelModel.keyboard.inputMode == .english && h.controller.testingPanelModel.source == "你好 SKU-DEMO",
               "The single candidate panel must reflect English while preserving the Chinese prefix")
        h.send("\r", key: 36)
        await h.waitFor("mixed source translation starts") { h.translator.calls.count == 1 }
        expect(h.translator.calls[0].text == "你好 SKU-DEMO" && h.translator.calls[0].preferences.source == .automatic,
               "Mixed source language must be detected instead of guessed from the last typing mode")
        h.controller.testingPanelModel.toggleInputMode?()
        expect(InputMethodPreferences.load(from: h.defaults) == .init(inputMode: .pinyin, translationEnabled: true),
               "The candidate panel language button must leave translation enabled")
        h.translator.complete("STALE_TRANSLATION")
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(2)) }
        expect(h.controller.testingPanelModel.translation == nil && !h.controller.testingPanelModel.isTranslating,
               "A mode change must cancel the old request and reject its late response")
        expect(h.client.document == "你好 SKU-DEMO" && h.client.committedText.isEmpty,
               "Mode switching and cancellation must retain the entire marked mixed draft")
        h.action(containing: "直接上屏原文")
        expect(h.client.document == "你好 SKU-DEMO" && h.client.markedRange().location == NSNotFound,
               "Original output after switching must commit the intact mixed draft once")
        print("PASS: mixed Chinese/English drafts, candidate-panel language toggle, automatic source detection, and stale translation rejection")
    }

    @MainActor
    private static func cancellationAndStaleResults(_ server: IMKServer, _ userPath: String) async {
        for route in 0..<4 {
            let h = Harness(server: server, userPath: userPath, mode: .english, translation: true)
            h.type("source")
            h.send("\r", key: 36)
            await h.waitFor("pending cancellation request") { h.translator.calls.count == 1 }
            var other: MockInputClient?
            switch route {
            case 0: h.send("", key: 53)
            case 1: h.controller.commitComposition(h.client)
            case 2: h.controller.deactivateServer(h.client)
            default:
                other = MockInputClient()
                h.type("new", to: other)
            }
            h.translator.complete("STALE_RESULT")
            for _ in 0..<8 { await Task.yield() }
            expect(!h.client.document.contains("STALE_RESULT") && h.controller.testingPanelModel.translation != "STALE_RESULT", "Cancellation route \(route) must reject a late result")
            expect(!h.client.inserted.contains("source"), "Translation cancellation must not silently commit source")
            if let other { expect(other.document == "new", "A late request must not change the new client's draft") }
            else { expect(h.client.markedRange().location == NSNotFound, "Cancelling the draft must clear host marked text") }
            h.finish()
        }
        let h = Harness(server: server, userPath: userPath, mode: .english, translation: true)
        defer { h.finish() }
        h.type("draft")
        h.send("\r", key: 36)
        await h.waitFor("preview cancellation request") { h.translator.calls.count == 1 }
        h.translator.complete("Preview")
        await h.waitFor("ready preview") { h.controller.testingPanelModel.translation != nil }
        h.send("", key: 53)
        expect(h.client.document == "draft" && h.client.committedText.isEmpty && h.controller.testingPanelModel.translation == nil, "First Escape from preview returns to editable source")
        h.send("", key: 53)
        expect(h.client.document.isEmpty && h.client.markedRange().location == NSNotFound, "Second Escape cancels the source")
        print("PASS: pending/ready Escape, client/focus changes, deactivation, and late-response rejection")
    }

    @MainActor
    private static func preferenceChangesAndErrors(_ server: IMKServer, _ userPath: String) async {
        for engineChange in [false, true] {
            let h = Harness(server: server, userPath: userPath, mode: .english, translation: true)
            h.type("Keep source")
            h.send("\r", key: 36)
            await h.waitFor("preference change request") { h.translator.calls.count == 1 }
            if engineChange {
                var settings = EnginePreferences()
                settings.mode = .apple
                settings.save(to: h.defaults)
            } else { KeyboardPreferences(market: .japan, source: .automatic).save(to: h.defaults) }
            h.translator.complete("OLD_CONFIGURATION")
            await h.waitFor("configuration invalidates spinner") { !h.controller.testingPanelModel.isTranslating }
            expect(h.controller.testingPanelModel.translation == nil && h.client.committedText.isEmpty, "Changing configuration must invalidate the old preview")
            expect(h.client.document == "Keep source", "Configuration change must preserve editable source")
            h.finish()
        }
        let h = Harness(server: server, userPath: userPath, mode: .english, translation: true)
        defer { h.finish() }
        h.type("Retry me")
        h.send("\r", key: 36)
        await h.waitFor("failed request") { h.translator.calls.count == 1 }
        h.translator.fail()
        await h.waitFor("visible translation failure") { h.controller.testingPanelModel.error != nil }
        expect(h.client.document == "Retry me" && h.client.committedText.isEmpty, "Failure must retain source without automatic insertion")
        h.action(containing: "直接上屏原文")
        expect(h.client.document == "Retry me" && h.client.markedRange().location == NSNotFound, "The input-method menu must commit original text through its actual client dictionary")
        print("PASS: target/model changes stop stale previews and spinning; failure preserves source and direct-original menu works")
    }

    @MainActor
    private static func overflowRecovery(_ server: IMKServer, _ userPath: String) async {
        let h = Harness(server: server, userPath: userPath, mode: .english, translation: true)
        defer { h.finish() }
        let full = String(repeating: "字", count: 2000)
        h.send(full + "👩🏽‍💻尾")
        expect(h.client.document == full + "👩🏽‍💻尾", "A single large input event must retain overflow graphemes")
        h.send("\r", key: 36)
        for _ in 0..<8 { await Task.yield() }
        expect(h.translator.calls.isEmpty, "Overflow must block translation rather than silently truncate source")
        expect(h.controller.testingPanelModel.error?.contains("2000") == true, "Overflow must be visible to the user")
        h.controller.commitComposition(h.client)
        expect(h.client.document.isEmpty, "Leaving a translation draft must clear host marking")
        h.action(containing: "恢复未上屏草稿")
        expect(h.client.document == full + "👩🏽‍💻尾", "Restoring an oversized draft must preserve every grapheme")
        h.action(containing: "直接上屏原文")
        expect(h.client.document == full + "👩🏽‍💻尾" && h.client.markedRange().location == NSNotFound, "Direct original output must preserve overflow and clear marking")
        print("PASS: 2000-character overflow, Unicode retention, draft recovery, and complete original output")
    }

    @MainActor
    private static func passwordAndRoman(_ server: IMKServer, _ userPath: String) {
        let h = Harness(server: server, userPath: userPath, translation: true)
        defer { h.finish() }
        h.type("nihao")
        h.controller.setValue("com.apple.inputmethod.Password", forTag: Int(kTextServiceInputModePropertyTag), client: h.client)
        expect(h.client.document.isEmpty && h.client.markedRange().location == NSNotFound, "Password mode must discard existing source and marking")
        expect(h.controller.menu().items.first(where: { $0.title.contains("恢复未上屏草稿") })?.isEnabled == false, "Password mode must clear and disable draft recovery")
        expect(h.controller.value(forTag: Int(kTextServiceInputModePropertyTag), client: h.client) as? String == "com.apple.inputmethod.Password", "Password mode must round-trip the system mode ID")
        expect(!h.send("x"), "Password typing must pass directly to the host")
        expect(h.client.document == "x" && h.client.markedUpdates.last != "x", "Password text must never enter marked composition")
        expect(h.translator.calls.isEmpty, "Password mode must never call the translation provider")
        h.client.reset()
        h.controller.setValue("com.apple.inputmethod.Roman", forTag: Int(kTextServiceInputModePropertyTag), client: h.client)
        expect(!h.send("e"), "Roman typing must pass through even when translation was enabled")
        expect(h.client.document == "e" && h.client.markedRange().location == NSNotFound, "Roman mode must type ordinary English")
        expect(h.controller.value(forTag: Int(kTextServiceInputModePropertyTag), client: h.client) as? String == "com.apple.inputmethod.Roman", "Roman mode must round-trip the system mode ID")
        h.controller.setValue(InputMethodInputMode.english.systemID, forTag: Int(kTextServiceInputModePropertyTag), client: h.client)
        expect(InputMethodPreferences.load(from: h.defaults).inputMode == .pinyin, "Exiting Roman mode must preserve the stored internal typing language")
        h.action(containing: "切换英文直输")
        expect(InputMethodPreferences.load(from: h.defaults).inputMode == .english, "Internal mode change must persist separately from workspace languages")
        expect(KeyboardPreferences.load(from: h.defaults).source == .automatic, "System mode switching must not rewrite workspace language preferences")
        print("PASS: TIS Password/Roman pass-through, no password translation, and independent internal-mode persistence")
    }

    @MainActor
    private static func draftCursorRecoveryAndShortcuts(_ server: IMKServer, _ userPath: String) {
        let h = Harness(server: server, userPath: userPath, mode: .english, translation: true)
        defer { h.finish() }
        h.send("a👩🏽‍💻b")
        h.send("", key: 123)
        h.send("z")
        expect(h.client.document == "a👩🏽‍💻zb", "Source insertion at the middle must preserve whole graphemes and suffix")
        h.controller.commitComposition(h.client)
        h.action(containing: "恢复未上屏草稿")
        expect(h.client.document == "a👩🏽‍💻zb", "Recovered draft must retain the edited source order")
        expect(!h.send("a", modifiers: .command), "Command shortcut must pass to the host")
        expect(h.client.document.isEmpty && h.client.committedText.isEmpty, "Host selection shortcuts must discard the old marked translation draft without committing it")
        for modifier in [NSEvent.ModifierFlags.control, .option] {
            h.type("draft")
            expect(!h.send("x", modifiers: modifier), "Control/Option shortcut must pass to the host")
            expect(h.client.document.isEmpty, "Host navigation shortcuts must cancel the old marked draft")
        }
        expect(h.send("t", key: 17, modifiers: [.control, .shift]), "Dedicated Control+Shift+T must be handled")
        let settings = InputMethodPreferences.load(from: h.defaults)
        expect(!settings.translationEnabled && settings.inputMode == .english, "Translation shortcut must toggle behavior without changing the internal typing language")
        expect(!h.send("t", key: 17, modifiers: [.control, .shift, .command]), "Adding Command to the translation shortcut must keep host shortcuts available")
        expect(InputMethodPreferences.load(from: h.defaults) == settings, "Unrecognized shortcut variants must not change preferences")
        print("PASS: Unicode source cursor editing/recovery and Command/Control/Option shortcut pass-through")
    }
}
