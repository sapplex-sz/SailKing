import AppKit
import SwiftUI
import ApplicationServices
import HaiwangCore

@MainActor
final class QuickComposeModel: ObservableObject {
    @Published var targetName = hw("原应用", "previous app")
    @Published var canPaste = AXIsProcessTrusted()
    @Published var message: String?
    var deliver: ((String) -> Void)?
    var dismiss: (() -> Void)?
}

struct QuickComposeView: View {
    @State private var workspace: WorkspaceModel
    @ObservedObject var delivery: QuickComposeModel
    @State private var editing = false

    init(delivery: QuickComposeModel, workspace: WorkspaceModel) {
        self.delivery = delivery
        _workspace = State(initialValue: workspace)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                OceanBrand(compact: true)
                Spacer()
                Button(hw("清空", "Clear")) { workspace.clear() }
                    .buttonStyle(.plain).font(.system(size: 11)).disabled(workspace.composition.source.isEmpty)
                Text(hw("跨语言输入", "Translate & Type")).font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
                Button { delivery.dismiss?() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
            }
            HStack {
                Picker("源语言", selection: $workspace.preferences.source) {
                    ForEach(SourceLanguage.allCases) { source in Text(source.displayLabel).tag(source) }
                }.labelsHidden().frame(maxWidth: .infinity)
                Image(systemName: "arrow.right").foregroundStyle(OceanStyle.blue)
                Picker("目标语言", selection: $workspace.preferences.market) {
                    ForEach(languageTargets) { market in Text(market.languageDisplayLabel).tag(market) }
                }.labelsHidden().frame(maxWidth: .infinity)
            }
            Toggle(hw("边打字边翻译", "Translate as you type"), isOn: $workspace.autoTranslationEnabled)
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            sourcePane

            translationPane

            if let error = workspace.composition.errorMessage ?? workspace.preparationError {
                Text(error).foregroundStyle(.orange).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            if let message = delivery.message { Text(message).foregroundStyle(OceanStyle.secondary).font(.system(size: 12)) }
            if let message = workspace.preparationMessage { Text(message).foregroundStyle(OceanStyle.secondary).font(.system(size: 12)) }
            actionFooter

            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                Text(workspace.dataFlowMessage)
                Spacer()
            }.font(.system(size: 10)).foregroundStyle(OceanStyle.secondary)
            if !delivery.canPaste {
                HStack {
                    Text(hw("当前通过复制输出，返回后按 ⌘V 粘贴。", "Return to your app and press ⌘V to paste."))
                    Spacer()
                    Button(hw("设置自动粘贴…", "Set up auto-paste…")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }.buttonStyle(.link)
                }.font(.system(size: 10)).foregroundStyle(OceanStyle.secondary)
            }
        }
        .padding(24).frame(width: 650)
        .background(OceanStyle.canvas).preferredColorScheme(.light).tint(OceanStyle.blue)
        .background {
            if let request = workspace.request {
                TranslationRunner(request: request, progress: workspace.updatePreview, completion: workspace.complete).id(request.id)
            }
        }
        .onChange(of: workspace.preferences) { _, _ in workspace.preferencesChanged() }
        .onChange(of: workspace.engineConfigurationID) { _, _ in workspace.enginePreferencesChanged() }
        .task(id: workspace.availabilityCheckID) {
            await workspace.checkAvailability()
        }
        .onAppear { workspace.editorAppeared(); editing = true }
        .onDisappear { workspace.editorDisappeared() }
    }

    private var sourcePane: some View {
    ZStack(alignment: .topLeading) {
        if workspace.composition.source.isEmpty {
            Text(hw("用你习惯的系统输入法输入母语…", "Type in your language using your usual keyboard…"))
                .font(.system(size: 17)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 8).allowsHitTesting(false)
        }
        NativeSourceEditor(text: workspace.composition.source, resetID: workspace.sourceEditorResetID,
            isFocused: $editing, accessibilityID: "quick-source", fontSize: 18) { text, marked in
                workspace.sourceEditorChanged(text, hasMarkedText: marked)
            }
    }.frame(height: 150).padding(10)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(OceanStyle.line))
    }

    @ViewBuilder private var translationPane: some View {
    if let result = workspace.outputText {
        ScrollView {
            Text(result).font(.system(size: 18)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: 112).padding(16)
            .environment(\.layoutDirection, workspace.preferences.market == .saudiArabia ? .rightToLeft : .leftToRight)
            .background(OceanStyle.paleBlue, in: RoundedRectangle(cornerRadius: 12))
    } else if let preview = workspace.streamPreview {
        VStack(alignment: .leading, spacing: 5) {
            Label(hw("译文生成中…", "Translation in progress…"), systemImage: "ellipsis")
                .font(.system(size: 10)).foregroundStyle(OceanStyle.secondary)
            ScrollView {
                Text(preview).font(.system(size: 18)).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 88)
        }.padding(16)
            .environment(\.layoutDirection, workspace.preferences.market == .saudiArabia ? .rightToLeft : .leftToRight)
            .background(OceanStyle.paleBlue, in: RoundedRectangle(cornerRadius: 12))
    } else if workspace.isBusy {
        HStack { ProgressView().controlSize(.small); Text(hw("正在翻译…", "Translating…")).font(.system(size: 12)) }
    }
    }

    private var actionFooter: some View {
    HStack {
        Text("\(workspace.composition.source.count)/2000 · \(workspace.statusTitle)")
            .font(.system(size: 10)).foregroundStyle(OceanStyle.secondary)
        Spacer()
        if workspace.outputText != nil {
            Button(delivery.canPaste ? hw("输入到 \(delivery.targetName)", "Insert into \(delivery.targetName)") : hw("复制并返回 \(delivery.targetName)", "Copy & return to \(delivery.targetName)")) {
                guard let current = workspace.outputText else { return }
                delivery.deliver?(current)
            }.buttonStyle(OceanButtonStyle(primary: true)).keyboardShortcut(.return, modifiers: .command)
        } else {
            Button(hw("翻译  ⌘↵", "Translate  ⌘↵")) { workspace.translate() }
                .buttonStyle(OceanButtonStyle(primary: true)).disabled(!workspace.canTranslate)
                .keyboardShortcut(.return, modifiers: .command)
        }
    }
    }

    private var languageTargets: [Market] {
        // Include a saved regional variant even when the language list is otherwise deduplicated.
        var seen = Set<String>()
        return ([workspace.preferences.market] + Market.allCases).filter { seen.insert($0.languageIdentifier).inserted }
    }
}

@MainActor
final class HaiwangApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var hotKey: GlobalHotKey?
    private var panel: NSPanel?
    private var target: NSRunningApplication?
    private var targetElement: AXUIElement?
    private let delivery = QuickComposeModel()
    private let quickWorkspace = WorkspaceModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        InputMethodTranslationHost.shared.start()
        hotKey = GlobalHotKey(onTrigger: { [weak self] in self?.showComposer() })
        if hotKey?.start() != true { delivery.message = hw("快捷键不可用，请从出海王应用的“跨语言输入”菜单打开输入面板。", "Shortcut unavailable. Open the input panel from SailKing’s Translate & Type menu.") }
        delivery.dismiss = { [weak self] in self?.hideComposer() }
        delivery.deliver = { [weak self] text in self?.deliver(text) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        InputMethodTranslationHost.shared.stop()
    }

    @objc func showComposer() {
        if panel?.isKeyWindow == true { hideComposer(); return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        target = frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier ? frontmost : nil
        targetElement = target.flatMap { focusedElement(pid: $0.processIdentifier) }
        delivery.targetName = target?.localizedName ?? hw("原应用", "previous app")
        delivery.canPaste = AXIsProcessTrusted() && targetElement != nil
        delivery.message = nil
        // Keep the in-memory source, but discard results and requests tied to the old target.
        quickWorkspace.preferences = KeyboardPreferences.load()
        quickWorkspace.autoTranslationEnabled = UserDefaults(suiteName: KeyboardPreferences.defaultsSuite)?.object(forKey: "automatic-translation-enabled") as? Bool ?? true
        quickWorkspace.preferencesChanged()
        let view = NSHostingView(rootView: QuickComposeView(delivery: delivery, workspace: quickWorkspace))
        if panel == nil {
            let created = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 490), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            created.title = hw("出海王 · 跨语言输入", "SailKing · Translate & Type")
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.isFloatingPanel = true
            created.level = .floating
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            created.standardWindowButton(.closeButton)?.isHidden = true
            created.standardWindowButton(.miniaturizeButton)?.isHidden = true
            created.standardWindowButton(.zoomButton)?.isHidden = true
            panel = created
        }
        panel?.contentView = view
        panel?.setContentSize(NSSize(width: 650, height: min(680, (NSScreen.main?.visibleFrame.height ?? 900) - 70)))
        panel?.center()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    private func hideComposer() {
        quickWorkspace.editorDisappeared()
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel { quickWorkspace.editorDisappeared() }
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            delivery.message = hw("无法写入剪贴板，请重试。", "Could not copy the result. Please try again.")
            return
        }
        guard let target, !target.isTerminated else {
            delivery.message = hw("结果已复制。请在需要的应用中按 ⌘V 粘贴。", "Result copied. Press ⌘V in your app to paste.")
            return
        }
        let pid = target.processIdentifier
        let mayPaste = AXIsProcessTrusted() && targetElement != nil
        let originalElement = targetElement
        let clipboardRevision = NSPasteboard.general.changeCount
        hideComposer()
        target.activate(options: [.activateAllWindows])
        guard mayPaste else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            // Never paste into an app that took focus after the confirmation click.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  !target.isTerminated, AXIsProcessTrusted(),
                  NSPasteboard.general.changeCount == clipboardRevision,
                  let originalElement, let currentElement = self.focusedElement(pid: pid),
                  CFEqual(originalElement, currentElement) else { return }
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return }
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
