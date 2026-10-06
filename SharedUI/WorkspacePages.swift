import SwiftUI
import HaiwangCore
#if os(macOS)
import AppKit
#endif

struct PhraseLibraryView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker(hw("短语语言", "Phrase language"), selection: $model.preferences.source) {
                    ForEach(SourceLanguage.allCases) { Text($0.localizedName).tag($0) }
                }.frame(maxWidth: 260, alignment: .leading)
                Spacer(minLength: 0)
            }
            Picker(hw("分类", "Category"), selection: $model.category) {
                ForEach(PhraseCategory.allCases) { category in
                    Text(category.localizedTitle).tag(category)
                }
            }.labelsHidden().pickerStyle(.segmented).accessibilityIdentifier("phrase-category")
            if model.phrases.isEmpty {
                Text(hw("此语言暂无预设短语", "No phrases for this language yet"))
                    .font(.system(size: 13)).foregroundStyle(OceanStyle.secondary)
                Button(hw("返回工作台", "Back to workspace")) { model.section = .workspace }
                    .buttonStyle(OceanButtonStyle())
            } else {
                VStack(spacing: 0) {
                    ForEach(model.phrases.filter { $0.category == model.category }) { phrase in
                        Button { model.usePhrase(phrase) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(phrase.localizedTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(OceanStyle.ink)
                                    Text(phrase.text(for: model.preferences.source) ?? "")
                                        .font(.system(size: 13)).foregroundStyle(OceanStyle.secondary)
                                        .lineSpacing(3).multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.left").font(.system(size: 12)).foregroundStyle(OceanStyle.blue)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(hw("填入", "Use ") + phrase.localizedTitle)
                        if phrase.id != model.phrases.last(where: { $0.category == model.category })?.id {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(OceanStyle.line, lineWidth: 1))
            }
        }
    }
}

struct WorkspaceGuideView: View {
    #if os(macOS)
    @Environment(\.openInputMethodSetup) private var openInputMethodSetup
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(macOS)
            Button(action: openInputMethodSetup) { Label(hw("输入法新手设置", "Keyboard setup guide"), systemImage: "keyboard") }
                .buttonStyle(OceanButtonStyle(primary: true)).accessibilityIdentifier("guide-open-keyboard-setup")
            #endif
            OceanDisclosure(title: hw("输入与翻译", "Typing and translation"), symbol: "text.cursor") {
                #if os(macOS)
                instructionLine("1", hw("普通输入：空格或数字确认拼音候选；Shift 切换中文拼音和英文直输。", "Space or a number confirms Pinyin candidates. Shift switches Chinese Pinyin and English."))
                instructionLine("2", hw("Control + Shift + T 开启翻译输入。先完成选词，回车翻译，再次回车确认上屏；不会替你发送消息。", "Control + Shift + T toggles translation input. Finish choosing words, press Return to translate, then Return again to insert without sending a message."))
                instructionLine("3", hw("Esc 返回修改或取消。失败时可上屏原文；切换输入框会取消旧译文，未上屏草稿可从输入法菜单恢复。", "Escape edits or cancels. Insert the original if translation fails. Changing fields cancels stale translations; recover unsent drafts from the input method menu."))
                Text(hw("翻译使用本机模型或 Apple 语言包，请先在设置中准备。目标语言与工作台共用。", "Prepare a local model or Apple language packs in Settings. The target language is shared with the workspace."))
                #else
                Text(hw("当前 iOS 版提供翻译工作台。选择语言、输入原文，翻译后复制到需要的应用；暂不包含系统键盘扩展或本地开源模型。API 需要服务访问码，Apple 翻译可能需要下载语言包。", "The iOS app provides a translation workspace. Choose languages, enter text, then copy the translation into your app. A system keyboard extension and local open-source models are not available. API mode requires a service access code; Apple translation may require language downloads."))
                #endif
                Text(hw("自动翻译会等待已确认文字停顿约 0.6 秒。完成前不可复制；编辑原文或切换语言会清除旧结果。", "Auto translation waits about 0.6 seconds after confirmed input pauses. Copy is available after completion. Editing text or changing languages clears old results."))
                Text(hw("源语言可自动识别。相同语言保留原文；支持的语言组合取决于引擎、模型和设备。重要内容请核对译文。", "Source language can be detected automatically. Matching languages keep the original. Supported pairs depend on the engine, model and device. Review important translations."))
            }
            #if os(macOS)
            OceanDisclosure(title: hw("快捷键与翻译面板", "Shortcuts and translation panel"), symbol: "command") {
                shortcut("⇧", hw("切换中文 / 英文", "Switch Chinese / English"))
                shortcut("⌃ ⇧ Space", hw("切换中文 / 英文", "Switch Chinese / English"))
                shortcut("⌃ ⇧ T", hw("切换普通 / 翻译输入", "Toggle translation input"))
                shortcut("⌘ Return", hw("工作台翻译", "Translate in workspace"))
                shortcut("⌥ Space", hw("打开全局翻译面板", "Open translation panel"))
                Text(hw("全局面板支持已有输入法。翻译并核对后复制，回到原应用粘贴；自动粘贴需自行开启辅助功能权限。", "The global panel works with your existing keyboard. Translate, review, copy, and paste into your app. Automatic pasting requires Accessibility access enabled by you."))
            }
            OceanDisclosure(title: hw("候选窗口位置", "Candidate window position"), symbol: "hand.draw") {
                Text(hw("拖动候选窗口标题或原文区域固定位置，切换应用或重启后保留。点击取消固定按钮，或在输入法菜单选择“候选窗口跟随光标”，恢复自动定位。", "Drag the candidate window title or source text to pin its position across apps and restarts. Use the unpin button or Follow caret in the input method menu to restore automatic placement."))
            }
            OceanDisclosure(title: hw("卸载输入法", "Uninstall input method"), symbol: "trash") {
                instructionLine("1", hw("先切换到 ABC。在系统设置 → 键盘 → 文本输入 → 编辑中选中出海王，点击“−”并完成。", "Switch to ABC. In System Settings → Keyboard → Text Input → Edit, select SailKing, click −, then Done."))
                instructionLine("2", hw("打开下方文件夹，再退出出海王，将“海王输入法键盘.app”移到废纸篓。", "Open the folder below, quit SailKing, then move 海王输入法键盘.app to Trash."))
                instructionLine("3", hw("将应用程序中的“出海王输入法.app”移到废纸篓。菜单如有残留，保存工作后退出登录再登录。", "Move 出海王输入法.app from Applications to Trash. If a menu entry remains, save your work, log out, and log back in."))
                Button(hw("打开输入法组件文件夹", "Open keyboard component folder"), systemImage: "folder") {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods", isDirectory: true))
                }.buttonStyle(OceanButtonStyle()).accessibilityIdentifier("guide-open-input-method-folder")
                Text(hw("仅停用时完成第 1 步即可。模型、词库和偏好保留。", "To disable temporarily, only step 1 is needed. Models, learned words and preferences are kept."))
            }
            #endif
        }
    }

    private func instructionLine(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(OceanStyle.blue).frame(width: 14)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shortcut(_ key: String, _ caption: String) -> some View {
        HStack(spacing: 12) {
            Text(key).font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(OceanStyle.ink).frame(width: 105, alignment: .leading)
            Text(caption)
        }
    }
}

struct WorkspaceSettingsView: View {
    @Bindable var model: WorkspaceModel
    var wide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(macOS)
            InputMethodSettingsView()
            if wide {
                HStack(alignment: .top, spacing: 12) {
                    EngineSettingsView(model: model).frame(maxWidth: .infinity)
                    languageSettings.frame(maxWidth: .infinity)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    EngineSettingsView(model: model)
                    languageSettings
                }
            }
            #else
            EngineSettingsView(model: model)
            languageSettings
            #endif
            privacyAndSupport
        }
    }

    private var languageSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            OceanSettingsGroup(title: hw("语言偏好", "Language preferences")) {
                settingRow(hw("源语言", "Source")) {
                    Picker(hw("源语言", "Source language"), selection: $model.preferences.source) {
                        ForEach(SourceLanguage.allCases) { Text($0.localizedName).tag($0) }
                    }.labelsHidden().frame(maxWidth: 220, alignment: .trailing)
                }
                settingRow(hw("目标语言", "Target")) {
                    Picker(hw("目标语言", "Target language"), selection: Binding(get: { model.preferences.market.languageIdentifier }, set: { identifier in
                        if let market = WorkspaceModel.targetLanguages.first(where: { $0.languageIdentifier == identifier }) { model.preferences.market = market }
                    })) {
                        ForEach(WorkspaceModel.targetLanguages) { Text($0.localizedLanguageName).tag($0.languageIdentifier) }
                    }.labelsHidden().frame(maxWidth: 220, alignment: .trailing)
                }
                settingRow(hw("地区", "Region")) {
                    Picker(hw("目标市场", "Target market"), selection: $model.preferences.market) {
                        ForEach(Market.allCases) { Text($0.flag + " " + $0.localizedName).tag($0) }
                    }.labelsHidden().frame(maxWidth: 220, alignment: .trailing)
                }
            }
            if model.effectiveEngine == .apple { appleLanguages }
        }
    }

    private var appleLanguages: some View {
        OceanSettingsGroup(title: hw("Apple 语言包", "Apple language packs")) {
            Text(model.preferences.source.localizedName + " → " + model.preferences.market.localizedLanguageName)
                .font(.system(size: 12, weight: .medium))
            Text(model.statusTitle).font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
            if model.preferences.source.languageIdentifier == nil {
                Text(hw("提前下载请先选择源语言。", "Choose a source language to download in advance."))
                    .font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { languagePackButtons }
                VStack(alignment: .leading, spacing: 8) { languagePackButtons }
            }
            if let message = model.preparationMessage { Text(message).font(.system(size: 12)).foregroundStyle(OceanStyle.green) }
            if let error = model.preparationError { Text(error).font(.system(size: 12)).foregroundStyle(OceanStyle.warning) }
        }
    }

    @ViewBuilder private var languagePackButtons: some View {
        Button(hw("准备语言包", "Prepare languages"), systemImage: "arrow.down.circle") { model.prepare() }
            .buttonStyle(OceanButtonStyle(primary: true)).disabled(!model.canPrepare)
        Button(hw("检查状态", "Check status"), systemImage: "arrow.clockwise") { Task { await model.checkAvailability() } }
            .buttonStyle(OceanButtonStyle()).disabled(model.isBusy)
    }

    private var privacyAndSupport: some View {
        OceanDisclosure(title: hw("隐私与支持", "Privacy and support"), symbol: "lock.shield") {
            Text(model.dataFlowMessage)
            #if os(macOS)
            Text(hw("工作台保存语言和引擎偏好，不保留翻译历史。翻译使用本机模型或 Apple 语言包；首次准备需要联网，原文不会发送到 API。", "The workspace saves language and engine preferences without translation history. Translation uses local models or Apple language packs. Initial preparation needs internet; source text is not sent to an API."))
            Text(hw("中文拼音在本机词库中学习确认过的词语、相关拼音和使用频次，记录可能包含输入内容，不会上传。取消输入或翻译不删除已有学习记录。未上屏草稿只在输入法运行期间暂存。", "Chinese Pinyin learns confirmed words, Pinyin and usage frequency in a local dictionary. Records may contain typed content and are not uploaded. Cancelling input or translation does not remove earlier learning. Uncommitted drafts remain in memory only while the input method runs."))
            #else
            Text(hw("工作台保存偏好，不保留原文或译文历史。API 原文会发送到后台及其供应商；服务访问码仅在当前 App 会话中保留。", "The workspace saves preferences without source or translation history. API mode sends source text to the backend and its provider. Service access codes remain in memory for this app session only."))
            #endif
            HStack {
                Text(hw("技术支持", "Support"))
                Spacer()
                Link("sapplex@icloud.com", destination: URL(string: "mailto:sapplex@icloud.com")!)
            }
            Text("SailKing \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
        }
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder control: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 12)).fixedSize()
                Spacer(minLength: 0)
                control()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12))
                control()
            }
        }
    }
}
