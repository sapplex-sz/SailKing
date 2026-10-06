import AppKit
import Foundation
import HaiwangCore

@MainActor private var checkCount = 0

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checkCount += 1
    if !condition() { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
}

@main
private enum CandidatePanelSmoke {
    @MainActor static func main() async {
        let app = NSApplication.shared
        if !CommandLine.arguments.contains("--test") {
            app.setActivationPolicy(.accessory)
            let defaults = UserDefaults(suiteName: "com.haiwang.tests.CandidatePanelReview")!
            let panel = CandidatePanel(defaults: defaults)
            populate(panel)
            panel.model.toggleInputMode = {
                panel.model.keyboard.inputMode = panel.model.keyboard.inputMode == .pinyin ? .english : .pinyin
                panel.show(at: .zero)
            }
            panel.model.toggleTranslation = {
                panel.model.keyboard.translationEnabled.toggle()
                panel.model.translation = panel.model.keyboard.translationEnabled ? "Hello, welcome aboard." : nil
                panel.show(at: .zero)
            }
            let menu = NSMenu()
            let appMenu = NSMenuItem()
            appMenu.submenu = NSMenu()
            appMenu.submenu?.addItem(NSMenuItem(title: "退出候选窗口预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            menu.addItem(appMenu)
            app.mainMenu = menu
            panel.show(at: .zero)
            let writeBounds = {
                let frame = panel.testingWindow.frame
                let top = (NSScreen.screens.first?.frame.maxY ?? 900) - frame.maxY
                defaults.set(["left":frame.minX,"top":top,"width":frame.width,"height":frame.height],
                             forKey: "preview-window-screen-bounds")
            }
            writeBounds()
            let observers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
                NotificationCenter.default.addObserver(forName: name,
                    object: panel.testingWindow, queue: .main) { _ in
                    MainActor.assumeIsolated { writeBounds() }
                }
            }
            app.run()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            return
        }
        app.setActivationPolicy(.prohibited)
        let suite = "com.haiwang.tests.CandidatePanelSmoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = CandidatePanel(defaults: defaults)
        panel.presentsWindow = false
        populate(panel)
        for _ in 0..<8 { await Task.yield() }
        panel.show(at: .zero)
        let normal = panel.testingWindow.frame.size
        expect(abs(normal.width - 360) < 1, "Ordinary candidate window must be 360 points wide")
        expect(normal.height > 70 && normal.height < 145, "Nine short candidates must fit in a compact window, got \(normal)")
        expect(CandidatePanelPosition.load(from: defaults) == nil, "Automatic caret placement must not become a pinned user position")
        snapshot(panel, filename: "compact-candidates.png")

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pin = CandidatePanelPosition(left: visible.minX + 100, top: visible.maxY - 80)
        pin.save(to: defaults)
        let reloaded = CandidatePanel(defaults: defaults)
        reloaded.presentsWindow = false
        populate(reloaded)
        reloaded.show(at: NSRect(x: visible.maxX - 120, y: visible.minY + 160, width: 1, height: 20))
        expect(abs(reloaded.testingWindow.frame.minX - pin.left) < 1 && abs(reloaded.testingWindow.frame.maxY - pin.top) < 1,
               "A new panel must restore the saved top-left instead of following a different caret")
        expect(reloaded.model.isPinned, "Restored position must offer the reset control")
        reloaded.model.keyboard.translationEnabled = true
        reloaded.model.source = "你好，欢迎出海。"
        reloaded.model.preedit = ""
        reloaded.model.translation = String(repeating: "Welcome aboard. This is a long translation that remains scrollable. ", count: 12)
        for _ in 0..<8 { await Task.yield() }
        reloaded.show(at: .zero)
        expect(abs(reloaded.testingWindow.frame.maxY - pin.top) < 1, "Expanding a translation must retain the pinned top edge")
        expect(reloaded.testingWindow.frame.height > normal.height && reloaded.testingWindow.frame.height < 380,
               "A long translation must have bounded scrollable height")
        snapshot(reloaded, filename: "compact-translation.png")
        reloaded.resetPosition()
        reloaded.show(at: .zero)
        expect(!reloaded.model.isPinned && CandidatePanelPosition.load(from: defaults) == nil,
               "Reset must remove only the pin and restore caret following")

        panel.model.candidates = ["好", "好久不见", "好好学习", "好像", "好心情", "好消息", "好的", "好朋友", "好好说话"]
        for _ in 0..<8 { await Task.yield() }
        panel.show(at: .zero)
        expect(panel.testingWindow.frame.height < 200, "Mixed-length candidates must wrap without large grid gaps")
        expect(panel.model.candidates.count == 9, "Compact layout must retain all nine numbered candidates")
        snapshot(panel, filename: "compact-long-candidates.png")

        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let small = CandidatePanelGeometry.frame(size: NSSize(width: 360, height: 110), visible: screen,
                                                anchor: .zero, pinned: .init(left: 100, top: 700))
        let grown = CandidatePanelGeometry.frame(size: NSSize(width: 360, height: 300), visible: screen,
                                                anchor: NSRect(x: 1000, y: 100, width: 1, height: 20), pinned: .init(left: 100, top: 700))
        expect(small.minX == grown.minX && small.maxY == grown.maxY, "Pinned translation growth must preserve top-left")
        let otherScreen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        let negative = CandidatePanelGeometry.frame(size: normal, visible: otherScreen, anchor: .zero,
                                                   pinned: .init(left: -1300, top: 700))
        expect(negative.minX == -1300 && negative.maxY == 700, "Left-hand external displays need negative coordinates")
        let offscreen = CandidatePanelGeometry.frame(size: normal, visible: screen, anchor: .zero,
                                                    pinned: .init(left: 9000, top: 9000))
        expect(screen.contains(offscreen), "Removed or rearranged displays must leave the entire window reachable")
        let below = CandidatePanelGeometry.frame(size: normal, visible: screen,
                                                anchor: NSRect(x: 200, y: 500, width: 1, height: 20), pinned: nil)
        let above = CandidatePanelGeometry.frame(size: normal, visible: screen,
                                                anchor: NSRect(x: 200, y: 8, width: 1, height: 20), pinned: nil)
        expect(below.maxY < 500 && above.minY > 28, "Unpinned windows must follow the caret and avoid the screen edge")
        let compactArea = normal.width * normal.height
        let reduction = 1 - compactArea / (450 * 231)
        let report: [String: Any] = ["ordinaryWidth":normal.width,"ordinaryHeight":normal.height,
                                    "areaReductionFromUserScreenshot":reduction,"checksPassed":checkCount,
                                    "visibleWindowsShown":false,"realUserPreferencesChanged":false]
        let resource = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let output = CommandLine.arguments.dropFirst().first(where: { $0 != "--test" }).map { URL(fileURLWithPath: $0) } ?? resource
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("panel-validation.json"))
        print("PASS: compact native candidate layout, saved-position reload/reset, growing translation, negative displays, screen clamping and caret following")
        print("Ordinary panel: \(normal.width) × \(normal.height) pt; area reduction: \(Int(reduction * 100))%")
    }

    @MainActor private static func populate(_ panel: CandidatePanel) {
        panel.model.preedit = "hao"
        panel.model.candidates = ["好", "号", "浩", "豪", "耗", "郝", "昊", "皓", "毫"]
    }

    @MainActor private static func snapshot(_ panel: CandidatePanel, filename: String) {
        guard let argument = CommandLine.arguments.dropFirst().first(where: { $0 != "--test" }),
              let view = panel.testingWindow.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try! data.write(to: URL(fileURLWithPath: argument).appendingPathComponent(filename))
        }
    }
}
