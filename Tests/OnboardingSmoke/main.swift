import AppKit
import SwiftUI
import HaiwangCore

/// Uses the production wizard with explicit fixtures, never installs or changes a system input source.
@main @MainActor
private enum OnboardingSmoke {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let suite = "com.haiwang.tests.onboarding." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var ready = InputMethodSetupStatus()
        ready.installed = true
        ready.registered = true
        ready.parentEnabled = true
        ready.modeEnabled = true
        ready.payloadAvailable = true
        var missing = InputMethodSetupStatus()
        missing.payloadAvailable = true
        var add = ready
        add.parentEnabled = false
        var update = ready
        update.updateAvailable = true
        let fixtures: [(String, InputMethodSetupStatus, InputMethodSetupStep, Bool)] = [
            ("install", missing, .install, false),
            ("update", update, .install, false),
            ("add-keyboard", add, .enable, false),
            ("practice", ready, .practice, false),
            ("translation-optional", ready, .translation, true)
        ]
        var settings = EnginePreferences()
        settings.mode = .apple
        let workspace = WorkspaceModel(runtime: EngineRuntime(settings: settings, catalog: .bundled, persistSettings: false))
        for (name, status, step, verified) in fixtures {
            let setup = InputMethodSetupCoordinator(defaults: defaults)
            setup.preview(status: status, verified: verified)
            let view = InputMethodOnboardingView(setup: setup, workspace: workspace, initialStep: step, observesSystem: false)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 660)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            for _ in 0..<8 { await Task.yield() }
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No snapshot") }
            host.cacheDisplay(in: host.bounds, to: rep)
            precondition(rep.pixelsWide >= 760 && rep.pixelsHigh >= 660)
            let language = HWLocale.isChinese ? "zh" : "en"
            try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("\(name)-\(language).png"))
            precondition(setup.status == status, "Fixture rendering must not query or mutate real macOS input sources")
            window.contentView = nil
        }
        // Insertion reports must preserve normal composition; marked drafts and model resets do not count.
        let native = CompositionTextView()
        var committed: [String] = []
        native.onCommittedInsertion = { committed.append($0) }
        native.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(committed.isEmpty)
        native.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(committed == ["你好"] && !native.hasMarkedText())
        native.applyingModel = true
        native.insertText("重置", replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(committed == ["你好"])
        precondition(defaults.data(forKey: InputMethodOnboardingProgress.storageKey) == nil)
        print("PASS: \(HWLocale.isChinese ? "Chinese" : "English") onboarding: 5 production layouts and committed-insertion checks")
    }
}
