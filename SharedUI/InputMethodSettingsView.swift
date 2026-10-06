#if os(macOS)
import AppKit
import Carbon
import SwiftUI
import HaiwangCore

@MainActor
struct InputMethodSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var preferences = InputMethodPreferences.load()
    @State private var sourceStatus = InputSourceStatus()
    @State private var statusUnavailable = false
    @State private var parentEnabled = false
    @Environment(\.openInputMethodSetup) private var openInputMethodSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(hw("系统输入法", "System input method")).font(.system(size: 13, weight: .semibold))
                Spacer()
                if statusUnavailable {
                    Label(hw("状态不可用", "Status unavailable"), systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(OceanStyle.warning)
                } else {
                    Label(sourceStatus.description, systemImage: sourceStatus.enabled ? "checkmark.circle" : "circle")
                        .font(.system(size: 12)).foregroundStyle(sourceStatus.enabled ? OceanStyle.green : OceanStyle.secondary)
                }
            }
            if !statusUnavailable && (!sourceStatus.registered || !sourceStatus.enabled) {
                Text(hw("请通过新手设置安装并添加输入法。", "Use the setup guide to install and add the keyboard."))
                    .font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { typingLanguage; Spacer(minLength: 0); translationToggle }
                VStack(alignment: .leading, spacing: 10) { typingLanguage; translationToggle }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { setupButtons }
                VStack(alignment: .leading, spacing: 8) { setupButtons }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(OceanStyle.line, lineWidth: 1))
        .onAppear { refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))) { _ in refresh() }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String))) { _ in refresh() }
    }

    private var typingLanguage: some View {
        Picker(hw("输入语言", "Typing language"), selection: Binding(get: { preferences.inputMode }, set: { saveInputMode($0) })) {
            Text(hw("中文拼音", "Chinese Pinyin")).tag(InputMethodInputMode.pinyin)
            Text(hw("英文直输", "English")).tag(InputMethodInputMode.english)
        }
        .labelsHidden().pickerStyle(.segmented).frame(minWidth: 240, maxWidth: 300, alignment: .leading)
        .accessibilityIdentifier("input-method-typing-language")
        .help(hw("Shift 切换中英文。", "Shift switches Chinese and English."))
    }

    private var translationToggle: some View {
        Toggle(hw("翻译输入", "Translate input"), isOn: Binding(get: { preferences.translationEnabled }, set: { saveTranslationBehavior($0) }))
            .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small).fixedSize()
            .accessibilityIdentifier("input-method-translation-enabled")
            .help(hw("选词完成后回车翻译，再次回车确认上屏。", "After choosing words, Return translates; Return again inserts the result."))
    }

    @ViewBuilder private var setupButtons: some View {
        Button(action: openInputMethodSetup) { Label(hw("新手设置", "Setup guide"), systemImage: "keyboard") }
            .buttonStyle(OceanButtonStyle())
        Button(hw("键盘设置", "Keyboard settings"), systemImage: "gearshape") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
        }.buttonStyle(OceanButtonStyle())
        Button(hw("检查状态", "Check status"), systemImage: "arrow.clockwise") { refresh() }
            .buttonStyle(OceanButtonStyle())
    }

    private func saveTranslationBehavior(_ enabled: Bool) {
        // Keep the latest language chosen inside the input method.
        var latest = InputMethodPreferences.load()
        latest.translationEnabled = enabled
        latest.save()
        preferences = latest
    }

    private func saveInputMode(_ mode: InputMethodInputMode) {
        var latest = InputMethodPreferences.load()
        latest.inputMode = mode
        latest.save()
        preferences = latest
    }

    private func refresh() {
        preferences = InputMethodPreferences.load()
        guard let result = TISCreateInputSourceList(nil, true) else {
            statusUnavailable = true
            return
        }
        let sources = (result.takeRetainedValue() as NSArray).map { $0 as! TISInputSource }
        let parent = sources.first {
            property($0, kTISPropertyInputSourceID) as? String == "com.haiwang.inputmethod.Haiwang"
        }
        parentEnabled = parent.map {
            (property($0, kTISPropertyInputSourceIsEnabled) as? NSNumber)?.boolValue ?? false
        } ?? false
        if let source = sources.first(where: {
            property($0, kTISPropertyInputSourceID) as? String == InputMethodPreferences.systemSourceID
        }) {
            // macOS can report a mode as enabled before its parent method is added.
            let enabled = parentEnabled && ((property(source, kTISPropertyInputSourceIsEnabled) as? NSNumber)?.boolValue ?? false)
            sourceStatus = InputSourceStatus(registered: true, enabled: enabled,
                                            selected: enabled && ((property(source, kTISPropertyInputSourceIsSelected) as? NSNumber)?.boolValue ?? false))
        } else { sourceStatus = InputSourceStatus() }
        statusUnavailable = false
    }

    private func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }
}

private struct InputSourceStatus {
    var registered = false
    var enabled = false
    var selected = false
    var description: String {
        if selected { return hw("已启用 · 当前使用", "Enabled · Current") }
        if enabled { return hw("已注册 · 已启用", "Registered · Enabled") }
        if registered { return hw("已注册 · 待添加", "Registered · Not enabled") }
        return hw("未注册", "Not registered")
    }
}
#endif
