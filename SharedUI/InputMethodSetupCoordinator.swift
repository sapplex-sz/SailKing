#if os(macOS)
import AppKit
import Carbon
import Observation
import SwiftUI
import HaiwangCore

extension Notification.Name {
    static let inputMethodSetupRequested = Notification.Name("com.haiwang.open-input-method-setup")
}

private struct OpenInputMethodSetupKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openInputMethodSetup: () -> Void {
        get { self[OpenInputMethodSetupKey.self] }
        set { self[OpenInputMethodSetupKey.self] = newValue }
    }
}

@Observable @MainActor
final class InputMethodSetupCoordinator {
    static let bundleID = "com.haiwang.inputmethod.Haiwang"
    static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/海王输入法键盘.app", isDirectory: true)
    }
    static var payloadURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/InputMethodInstaller", isDirectory: true)
    }

    private(set) var status = InputMethodSetupStatus()
    private(set) var progress: InputMethodOnboardingProgress
    private(set) var isInstalling = false
    private(set) var error: String?
    private(set) var installMessage: String?
    private(set) var backupURL: URL?
    var practice = InputMethodPractice()
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        progress = .load(from: defaults)
    }

    // Read Info.plist fresh: Bundle(url:) can cache a replaced component's old metadata.
    static func componentBuild(at url: URL) -> InputMethodBuild? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleID,
              let version = plist["CFBundleShortVersionString"] as? String,
              let build = plist["CFBundleVersion"] as? String,
              let executable = plist["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/" + executable).path) else { return nil }
        return InputMethodBuild(version: version, build: build)
    }

    static func readStatus() -> InputMethodSetupStatus {
        var status = InputMethodSetupStatus()
        let installed = componentBuild(at: installedURL)
        let bundled = componentBuild(at: payloadURL.appendingPathComponent("出海王输入法键盘.app"))
        status.installed = installed != nil
        status.updateAvailable = installed.flatMap { current in bundled.map { current.isOlder(than: $0) } } ?? false
        status.payloadAvailable = bundled != nil
            && FileManager.default.isExecutableFile(atPath: payloadURL.appendingPathComponent("haiwang-input-sources").path)
            && FileManager.default.fileExists(atPath: payloadURL.appendingPathComponent("install-input-method.sh").path)
        guard let result = TISCreateInputSourceList(nil, true) else {
            status.queryAvailable = false
            return status
        }
        let sources = (result.takeRetainedValue() as NSArray).map { $0 as! TISInputSource }
        let parent = sources.first { property($0, kTISPropertyInputSourceID) as? String == bundleID }
        let mode = sources.first { property($0, kTISPropertyInputSourceID) as? String == InputMethodPreferences.systemSourceID }
        status.registered = mode != nil
        status.parentEnabled = parent.map { flag($0, kTISPropertyInputSourceIsEnabled) } ?? false
        status.modeEnabled = mode.map { flag($0, kTISPropertyInputSourceIsEnabled) } ?? false
        status.selected = status.enabled && currentSourceID() == InputMethodPreferences.systemSourceID
        return status
    }

    static func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource() else { return nil }
        return property(source.takeRetainedValue(), kTISPropertyInputSourceID) as? String
    }

    func refresh() { status = Self.readStatus() }

    func install() async {
        guard !isInstalling else { return }
        isInstalling = true
        error = nil
        installMessage = nil
        defer { isInstalling = false; refresh() }
        do {
            let result = try await InputMethodComponentInstaller.install(payload: Self.payloadURL)
            backupURL = result.backupURL
            practice = .init()
            if result.exitStatus == 0 || result.exitStatus == 2 {
                installMessage = hw("输入法组件已安装。接下来把它加入键盘并试打。", "The keyboard component is installed. Add it to your input sources and try typing next.")
            } else {
                error = hw("安装未完成，旧版恢复材料已保留。请重试，或打开安装记录查看详情。", "Installation did not finish. Recovery files were kept. Try again, or open the installation records for details.")
            }
        } catch {
            self.error = hw("暂时无法启动安装，请重新打开 App 后重试。", "Could not start installation. Reopen the app and try again.")
        }
    }

    func openKeyboardSettings() {
        error = nil
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!) {
            error = hw("请从苹果菜单打开“系统设置 → 键盘 → 文本输入 → 编辑”。", "Open System Settings → Keyboard → Text Input → Edit from the Apple menu.")
        }
    }

    func beginPractice() -> Bool {
        refresh()
        guard status.canPractice, let sources = TISCreateInputSourceList([kTISPropertyInputSourceID as String: InputMethodPreferences.systemSourceID] as CFDictionary, false),
              let source = (sources.takeRetainedValue() as NSArray).firstObject else {
            error = hw("请先在键盘设置中添加出海王输入法，再回来试打。", "Add SailKing in Keyboard settings, then return to try typing.")
            return false
        }
        let result = TISSelectInputSource((source as! TISInputSource))
        refresh()
        guard result == noErr, status.selected else {
            error = hw("请在屏幕右上角的输入法菜单中选中“出海王输入法”，然后点击试打框。", "Select SailKing from the Input menu at the top right of the screen, then click the practice field.")
            return false
        }
        // This explicit action prepares ordinary Pinyin; other setup steps do not change typing preferences.
        var preferences = InputMethodPreferences.load()
        preferences.inputMode = .pinyin
        preferences.translationEnabled = false
        preferences.save()
        error = nil
        return true
    }

    func noteInsertion(_ text: String) {
        practice.recordInsertion(text, selectedSourceID: Self.currentSourceID(), marked: false)
    }

    func deferSetup() { progress.deferSetup(); progress.save(to: defaults) }

    func complete() -> Bool {
        refresh()
        guard progress.complete(status: status, practice: practice) else {
            error = hw("请先确认输入法菜单中能选到出海王，并完成一次中文试打。", "Check that SailKing appears in the Input menu and confirm some Chinese text before finishing setup.")
            return false
        }
        progress.save(to: defaults)
        return true
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }

    private static func flag(_ source: TISInputSource, _ key: CFString) -> Bool {
        (property(source, key) as? NSNumber)?.boolValue ?? false
    }

    #if DEBUG
    func preview(status: InputMethodSetupStatus, verified: Bool = false) {
        self.status = status
        practice.menuConfirmed = status.canPractice
        if verified { practice.recordInsertion("你好", selectedSourceID: InputMethodPreferences.systemSourceID, marked: false) }
    }
    #endif
}

private enum InputMethodComponentInstaller {
    struct Result: Sendable {
        let exitStatus: Int32
        let backupURL: URL
    }

    static func install(payload: URL) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let backup = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Haiwang/InstallBackups/Setup-" + UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: backup, withIntermediateDirectories: true)
            let log = backup.appendingPathComponent("installation.log")
            manager.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [payload.appendingPathComponent("install-input-method.sh").path, "--input-method-only", "--no-open", "--source-dir", payload.path]
            var environment = ProcessInfo.processInfo.environment
            environment["HAIWANG_BACKUP_ROOT"] = backup.path
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            return Result(exitStatus: process.terminationStatus, backupURL: backup)
        }.value
    }
}
#endif
