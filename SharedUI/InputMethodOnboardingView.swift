#if os(macOS)
import AppKit
import Carbon
import SwiftUI
import HaiwangCore

enum InputMethodOnboardingPresentation: String, Identifiable {
    case setup
    var id: String { rawValue }
}

@MainActor
struct InputMethodOnboardingView: View {
    let setup: InputMethodSetupCoordinator
    @Bindable var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var step: InputMethodSetupStep
    @State private var practiceText = ""
    @State private var practiceFocused = false
    let observesSystem: Bool

    init(setup: InputMethodSetupCoordinator, workspace: WorkspaceModel, initialStep: InputMethodSetupStep? = nil, observesSystem: Bool = true) {
        self.setup = setup
        self.workspace = workspace
        self.observesSystem = observesSystem
        let suggestion = setup.status.suggestedStep
        _step = State(initialValue: initialStep ?? (suggestion == .practice && !setup.practice.menuConfirmed ? .enable : suggestion))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            steps.padding(.horizontal, 30).padding(.bottom, 20)
            Divider().overlay(OceanStyle.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: step.title, subtitle: step.subtitle)
                    if let message = setup.installMessage {
                        Label(message, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(OceanStyle.green)
                    }
                    switch step {
                    case .install: installation
                    case .enable: enablement
                    case .practice: practice
                    case .translation: translation
                    }
                    if let error = setup.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    if setup.backupURL != nil {
                        Button(hw("查看安装记录", "View installation records"), systemImage: "folder") {
                            if let url = setup.backupURL { NSWorkspace.shared.open(url) }
                        }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(OceanStyle.secondary)
                    }
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .id(step)
            footer
        }
        .frame(width: 760, height: 660)
        .foregroundStyle(OceanStyle.ink).tint(OceanStyle.blue)
        .background(OceanStyle.canvas).preferredColorScheme(.light)
        .interactiveDismissDisabled(setup.isInstalling)
        .task {
            guard observesSystem else { return }
            setup.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                setup.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if observesSystem { setup.refresh() }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))) { _ in
            if observesSystem { setup.refresh() }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String))) { _ in
            if observesSystem { setup.refresh() }
        }
    }

    private var header: some View {
        HStack {
            OceanBrand(compact: true)
            Spacer()
            Text(hw("新手设置", "Keyboard setup")).font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
            Button { postpone() } label: { Image(systemName: "xmark").padding(8) }
                .buttonStyle(.plain).disabled(setup.isInstalling)
                .accessibilityLabel(hw("稍后设置", "Set up later"))
        }.padding(.horizontal, 30).padding(.vertical, 24)
    }

    private var steps: some View {
        HStack(spacing: 12) {
            ForEach(InputMethodSetupStep.allCases, id: \.rawValue) { item in
                Button {
                    practiceFocused = false
                    step = item
                } label: {
                    HStack(spacing: 7) {
                        Text(String(item.rawValue + 1)).font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .background(step == item ? OceanStyle.blue : OceanStyle.line, in: Circle())
                            .foregroundStyle(step == item ? Color.white : OceanStyle.secondary)
                        Text(item.shortTitle).font(.system(size: 12, weight: step == item ? .semibold : .regular))
                        if item == .translation { Text(hw("可选", "Optional")).font(.system(size: 9)).foregroundStyle(OceanStyle.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(setup.isInstalling || !canVisit(item))
                    .accessibilityIdentifier("setup-step-\(item.rawValue)")
            }
        }
    }

    private var installation: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusRow(setup.status.installed && !setup.status.updateAvailable,
                      setup.status.updateAvailable ? hw("输入法组件有更新", "A keyboard update is available") : hw("输入法组件", "Keyboard component"),
                      setup.status.installed ? hw("已安装在这台 Mac", "Installed on this Mac") : hw("等待安装", "Not installed yet"))
            Text(hw("App 已包含输入法组件。点击安装后，它会出现在 macOS 可添加的输入法中。安装在当前用户下，无需管理员密码；更新时保留原版本、词库和偏好。", "The app includes its keyboard component. Installing it makes it available to macOS. Installation is for your user account and needs no administrator password. Updates keep the previous version, dictionary and preferences."))
                .font(.system(size: 13)).foregroundStyle(OceanStyle.secondary).lineSpacing(5)
            if setup.status.needsInstallation {
                if setup.status.payloadAvailable {
                    HStack(spacing: 14) {
                        Button(setup.isInstalling ? hw("正在安装…", "Installing…") : setup.status.updateAvailable ? hw("更新输入法组件", "Update keyboard component") : hw("安装输入法组件", "Install keyboard component"), systemImage: "arrow.down.circle") {
                            Task { @MainActor in
                                await setup.install()
                                if !setup.status.needsInstallation { step = .enable }
                            }
                        }.buttonStyle(OceanButtonStyle(primary: true)).disabled(setup.isInstalling)
                            .accessibilityIdentifier("setup-install-component")
                        if setup.isInstalling { ProgressView().controlSize(.small) }
                    }
                } else {
                    Label(hw("当前 App 缺少输入法组件，请重新安装完整的 macOS 版本。", "This app is missing its keyboard component. Reinstall the complete macOS version."), systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            Text(hw("装好 App 和组件后，首次使用还需完成下一步的键盘设置。", "After installing the app and component, first use still needs the next keyboard setup step."))
                .font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
        }.setupCard()
    }

    private var enablement: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusRow(setup.status.registered, hw("系统识别", "macOS registration"), setup.status.registered ? hw("已识别出海王", "SailKing is registered") : hw("等待系统识别", "Waiting for registration"))
            statusRow(setup.status.enabled, hw("键盘启用", "Keyboard activation"), setup.status.enabled ? hw("系统报告已启用，下一步试打", "Reported enabled — try typing next") : hw("需要添加到输入源", "Add it to your input sources"))
            if !setup.status.queryAvailable {
                Text(hw("暂时读不到系统状态。请完成下面的添加步骤，再点击“检查状态”。", "System status is unavailable. Follow the steps below and click Check status."))
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            Divider()
            instruction("1", hw("打开“键盘设置”，在“文本输入”右侧点击“编辑…”", "Open Keyboard settings and click Edit next to Text Input."))
            instruction("2", hw("点击左下角“＋”，在“简体中文”中找到“出海王输入法”", "Click + and find SailKing under Chinese, Simplified."))
            instruction("3", hw("点击“添加”，然后回到这里继续", "Click Add, then return here to continue."))
            HStack(spacing: 12) {
                Button(hw("打开键盘设置", "Open Keyboard settings"), systemImage: "keyboard") { setup.openKeyboardSettings() }
                    .buttonStyle(OceanButtonStyle(primary: true)).accessibilityIdentifier("setup-open-keyboard-settings")
                Button(hw("检查状态", "Check status"), systemImage: "arrow.clockwise") { setup.refresh() }
                    .buttonStyle(OceanButtonStyle())
            }
            Toggle(hw("我已在右上角输入法菜单中看到“出海王输入法”", "I can see SailKing in the Input menu at the top right"), isOn: Binding(get: { setup.practice.menuConfirmed }, set: { setup.practice.menuConfirmed = $0 }))
                .toggleStyle(.checkbox).font(.system(size: 12)).disabled(!setup.status.canPractice)
                .accessibilityIdentifier("setup-confirm-input-menu")
            Text(hw("只需要一个出海王输入源，中英文在它里面切换。菜单里找不到时，确认“在菜单栏显示输入法菜单”已开启；关闭再打开系统设置仍未出现时，保存工作后退出登录再登录。", "One SailKing source includes Chinese and English. If it is missing, enable Show Input menu in menu bar. Reopen System Settings; if it is still missing, save your work and log out and back in."))
                .font(.system(size: 12)).foregroundStyle(OceanStyle.secondary).lineSpacing(4)
        }.setupCard()
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 15) {
            statusRow(setup.status.selected, hw("当前键盘", "Current keyboard"), setup.status.selected ? hw("出海王输入法", "SailKing") : hw("先切换到出海王", "Switch to SailKing first"))
            HStack {
                Button(hw("切换并试打拼音", "Switch and try Pinyin"), systemImage: "keyboard") {
                    if setup.beginPractice() { practiceFocused = true }
                }.buttonStyle(OceanButtonStyle(primary: true)).disabled(!setup.status.canPractice)
                    .accessibilityIdentifier("setup-begin-practice")
                Text(hw("切到中文 · 普通输入", "Chinese · Ordinary input")).font(.system(size: 11)).foregroundStyle(OceanStyle.secondary)
            }
            Text(hw("点击下面的试打框，输入 nihao，再按空格选择“你好”。", "Click the field below, type nihao, then press Space to confirm 你好."))
                .font(.system(size: 13)).foregroundStyle(OceanStyle.secondary)
            ZStack(alignment: .topLeading) {
                if practiceText.isEmpty {
                    Text(hw("在这里试打…", "Try typing here…")).font(.system(size: 18)).foregroundStyle(OceanStyle.secondary.opacity(0.6))
                        .padding(14).allowsHitTesting(false)
                }
                NativeSourceEditor(text: practiceText, isFocused: $practiceFocused, accessibilityID: "setup-practice-editor", accessibilityLabel: hw("输入法试打框", "Keyboard practice field"), fontSize: 18, onCommittedInsertion: setup.noteInsertion) { text, _ in practiceText = text }
                    .padding(8)
            }.frame(height: 86).background(OceanStyle.canvas, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(OceanStyle.line))
            Label(setup.practice.verified ? hw("中文已上屏，试打完成", "Chinese text confirmed — practice complete") : hw("等待出海王确认中文候选；粘贴不会完成试打", "Confirm Chinese with SailKing; pasted text does not complete practice"), systemImage: setup.practice.verified ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 12)).foregroundStyle(setup.practice.verified ? OceanStyle.green : OceanStyle.secondary)
            Divider()
            Text(hw("轻按 Shift 切换中文／英文。空格或数字选词，Esc 取消。拖动候选窗口标题或原文可以固定位置，点击取消固定可恢复跟随光标。", "Tap Shift to switch Chinese/English. Use Space or number keys to select words; Escape cancels. Drag the candidate title or source text to pin the window, and unpin it to follow the caret again."))
                .font(.system(size: 12)).foregroundStyle(OceanStyle.secondary).lineSpacing(4)
        }.setupCard()
    }

    private var translation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(hw("普通输入已经可以使用", "Ordinary typing is ready"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(OceanStyle.green)
            Text(hw("翻译输入可稍后设置。Mac 版使用 Apple 内置翻译或本地模型，首次准备语言包或模型需要联网。点击“配置翻译”会打开设置，帮助你选择语言并准备引擎。", "Translation can be set up later. The Mac version uses Apple translation or a local model. Preparing language packs or a model requires internet access. Configure translation opens Settings to choose languages and prepare an engine."))
                .font(.system(size: 13)).foregroundStyle(OceanStyle.secondary).lineSpacing(5)
            Button(hw("配置翻译", "Configure translation"), systemImage: "character.bubble") {
                if setup.complete() { workspace.section = .settings; dismiss() }
            }.buttonStyle(OceanButtonStyle()).disabled(!canFinish)
                .accessibilityIdentifier("setup-configure-translation")
            Divider()
            instruction("1", hw("在设置里准备 Apple 语言包或下载本地模型", "Prepare Apple language packs or download a local model in Settings."))
            instruction("2", hw("在出海王输入法中按 Control + Shift + T 开启翻译输入", "In SailKing, press Control + Shift + T to enable translation input."))
            instruction("3", hw("选好中文词语后，回车翻译；核对后再按回车上屏", "Choose Chinese words, press Return to translate, then review and press Return to insert."))
            Text(hw("确认译文只会插入文字，不会发送聊天消息。你也可以继续使用普通拼音和英文。", "Confirming a translation inserts text without sending a chat message. Ordinary Pinyin and English remain available."))
                .font(.system(size: 12)).foregroundStyle(OceanStyle.secondary).lineSpacing(4)
        }.setupCard()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(hw("稍后设置", "Set up later")) { postpone() }.buttonStyle(.plain)
                .foregroundStyle(OceanStyle.secondary).disabled(setup.isInstalling)
            Spacer()
            if step != .install {
                Button(hw("上一步", "Back")) { practiceFocused = false; step = InputMethodSetupStep(rawValue: step.rawValue - 1)! }
                    .buttonStyle(OceanButtonStyle()).disabled(setup.isInstalling)
            }
            Button(step == .translation ? hw("完成设置，开始使用", "Finish setup") : hw("下一步", "Continue")) {
                practiceFocused = false
                if step == .translation {
                    if setup.complete() { dismiss() }
                } else { step = InputMethodSetupStep(rawValue: step.rawValue + 1)! }
            }.buttonStyle(OceanButtonStyle(primary: true)).disabled(!canContinue || setup.isInstalling)
                .accessibilityIdentifier("setup-continue")
        }.font(.system(size: 12)).padding(.horizontal, 24).padding(.vertical, 18).background(.white)
    }

    private var canFinish: Bool { setup.status.canPractice && setup.practice.menuConfirmed && setup.practice.verified }
    private var canContinue: Bool {
        switch step {
        case .install: !setup.status.needsInstallation
        case .enable: setup.status.canPractice && setup.practice.menuConfirmed
        case .practice, .translation: canFinish
        }
    }
    private func canVisit(_ item: InputMethodSetupStep) -> Bool {
        switch item {
        case .install: true
        case .enable: !setup.status.needsInstallation
        case .practice: setup.status.canPractice && setup.practice.menuConfirmed
        case .translation: canFinish
        }
    }
    private func postpone() { setup.deferSetup(); dismiss() }
    private func statusRow(_ ready: Bool, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle").foregroundStyle(ready ? OceanStyle.green : OceanStyle.secondary)
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
            Text(detail).font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
        }
    }
    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 11, weight: .semibold)).foregroundStyle(OceanStyle.blue)
                .frame(width: 23, height: 23).background(OceanStyle.paleBlue, in: Circle())
            Text(text).font(.system(size: 13)).foregroundStyle(OceanStyle.ink).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension View {
    func setupCard() -> some View {
        padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(OceanStyle.line))
    }
}

private extension InputMethodSetupStep {
    var shortTitle: String {
        switch self {
        case .install: hw("安装组件", "Install")
        case .enable: hw("加入键盘", "Add keyboard")
        case .practice: hw("试打拼音", "Try Pinyin")
        case .translation: hw("翻译输入", "Translation")
        }
    }
    var title: String {
        switch self {
        case .install: hw("让出海王成为你的键盘", "Make SailKing your keyboard")
        case .enable: hw("把出海王加入键盘", "Add SailKing to your keyboards")
        case .practice: hw("输入第一句“你好”", "Type your first 你好")
        case .translation: hw("准备好，开始表达", "You’re ready to start typing")
        }
    }
    var subtitle: String {
        switch self {
        case .install: hw("App 已就位，接下来安装它的输入法组件。", "The app is ready. Install its keyboard component next.")
        case .enable: hw("首次使用需要在系统设置中添加一次。返回 App 后会自动检查状态。", "Add it once in System Settings. Status updates automatically when you return.")
        case .practice: hw("试打框使用真实系统输入法，帮助你确认设置成功。", "This field uses the real system keyboard to check your setup.")
        case .translation: hw("中文和英文直接输入；翻译功能可以按需准备。", "Type Chinese and English now. Prepare translation whenever you need it.")
        }
    }
}
#endif
