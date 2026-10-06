import SwiftUI
import HaiwangCore
#if os(macOS)
import AppKit
#endif

public struct SharedWorkspaceView: View {
    @State private var model = WorkspaceModel()
    #if os(macOS)
    @State private var inputMethodSetup = InputMethodSetupCoordinator()
    @State private var onboarding: InputMethodOnboardingPresentation?
    #endif

    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 820
            #if os(macOS)
            let showsSetupReminder = !inputMethodSetup.progress.completed || inputMethodSetup.status.needsInstallation
            #else
            let showsSetupReminder = false
            #endif
            HStack(spacing: 0) {
                if wide {
                    sidebar.frame(width: 180)
                    Rectangle().fill(OceanStyle.line).frame(width: 1)
                }
                VStack(spacing: 0) {
                    if !wide { compactNavigation }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            #if os(macOS)
                            if showsSetupReminder {
                                setupReminder
                            }
                            #endif
                            switch model.section {
                            case .workspace:
                                WorkspaceEditorView(model: model, wide: geometry.size.width >= 820,
                                                    editorHeight: min(360, max(200, geometry.size.height - (showsSetupReminder ? 294 : 230))))
                            case .phrases: PhraseLibraryView(model: model)
                            case .guide: WorkspaceGuideView()
                            case .settings: WorkspaceSettingsView(model: model, wide: geometry.size.width >= 960)
                            }
                        }
                        .padding(wide ? 18 : 16)
                        .frame(maxWidth: 1040, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .scrollIndicators(.hidden)
                }
                .background(OceanStyle.canvas)
            }
        }
        .foregroundStyle(OceanStyle.ink)
        .tint(OceanStyle.blue)
        .preferredColorScheme(.light)
        .background(alignment: .center) {
            if let request = model.request {
                TranslationRunner(request: request, runtime: model.runtime, progress: model.updatePreview, completion: model.complete)
                    .id(request.id)
            }
        }
        .onChange(of: model.preferences) { _, _ in model.preferencesChanged() }
        .onChange(of: model.engineConfigurationID) { _, _ in model.enginePreferencesChanged() }
        .task { await model.refreshCatalogOnLaunch() }
        .task(id: model.availabilityCheckID) { await model.checkAvailability() }
        .onDisappear { model.editorDisappeared() }
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 560)
        .environment(\.openInputMethodSetup, openSetup)
        .sheet(item: $onboarding, onDismiss: {
            if !inputMethodSetup.progress.completed { inputMethodSetup.deferSetup() }
        }) { _ in
            InputMethodOnboardingView(setup: inputMethodSetup, workspace: model)
        }
        .task {
            inputMethodSetup.refresh()
            if inputMethodSetup.progress.shouldPresentAutomatically { onboarding = .setup }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inputMethodSetupRequested)) { _ in openSetup() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in inputMethodSetup.refresh() }
        #endif
    }

    #if os(macOS)
    private func openSetup() {
        inputMethodSetup.refresh()
        onboarding = .setup
    }

    private var setupReminder: some View {
        HStack(spacing: 10) {
            Label(hw("完成输入法设置", "Finish keyboard setup"), systemImage: "keyboard")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button(hw("继续设置", "Continue setup"), action: openSetup)
                .buttonStyle(OceanButtonStyle()).accessibilityIdentifier("open-input-method-setup")
        }.padding(10).background(OceanStyle.paleBlue, in: RoundedRectangle(cornerRadius: 10))
    }
    #endif

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            OceanBrand(compact: true).padding(.top, 26).padding(.bottom, 20).padding(.horizontal, 12)
            VStack(spacing: 4) {
                ForEach(WorkspaceSection.allCases) { section in
                    Button {
                        model.section = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.symbol).font(.system(size: 14, weight: .medium)).frame(width: 18)
                            Text(section.localizedTitle).font(.system(size: 13, weight: model.section == section ? .semibold : .regular))
                            Spacer()
                        }
                        .foregroundStyle(section == model.section ? OceanStyle.blue : OceanStyle.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(section == model.section ? OceanStyle.paleBlue : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == model.section ? .isSelected : [])
                }
            }.padding(.horizontal, 10)
            Spacer(minLength: 12)
        }
        .background(.white)
    }

    private var compactNavigation: some View {
        HStack {
            OceanBrand(compact: true)
            Spacer()
            Menu {
                ForEach(WorkspaceSection.allCases) { section in
                    Button(section.localizedTitle, systemImage: section.symbol) { model.section = section }
                }
            } label: {
                Label(model.section.localizedTitle, systemImage: "line.3.horizontal").font(.system(size: 13, weight: .medium))
            }
        }.padding(.horizontal, 16).padding(.vertical, 10).background(.white)
    }
}

struct WorkspaceEditorView: View {
    @Bindable var model: WorkspaceModel
    let wide: Bool
    var editorHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            marketSelection
            editor
            actionBar
        }
        .onAppear { model.editorAppeared() }
        .onDisappear { model.editorDisappeared() }
    }

    private var marketSelection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { regionSelector; Spacer(minLength: 0); engineSelector }
            VStack(alignment: .leading, spacing: 8) { regionSelector; engineSelector }
        }
    }

    private var regionSelector: some View {
        HStack(spacing: 8) {
            Text(hw("地区", "Region")).font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
            marketMenu
        }
    }

    private var engineSelector: some View {
        Menu {
            Picker(hw("翻译引擎", "Translation engine"), selection: Binding(get: { model.runtime.settings.mode }, set: { model.runtime.settings.mode = $0 })) {
                ForEach(TranslationEngine.platformChoices) { engine in Text(engine.localizedTitle).tag(engine) }
            }
            Divider()
            Button(hw("引擎与模型设置…", "Engine and model settings…")) { model.section = .settings }
        } label: {
            Label(model.engineLabel, systemImage: model.effectiveEngine == .cloud ? "network" : "cpu").font(.system(size: 12))
        }.menuStyle(.borderlessButton).fixedSize()
    }

    private var sourceLanguagePicker: some View {
        Picker(hw("源语言", "Source language"), selection: $model.preferences.source) {
            ForEach(SourceLanguage.allCases) { source in Text(source.localizedName).tag(source) }
        }.labelsHidden().frame(minWidth: 140, maxWidth: 210, alignment: .trailing)
            .accessibilityIdentifier("workspace-source-language")
    }

    private var targetLanguagePicker: some View {
        Picker(hw("目标语言", "Target language"), selection: Binding(get: { model.preferences.market.languageIdentifier }, set: { identifier in
            if let market = WorkspaceModel.targetLanguages.first(where: { $0.languageIdentifier == identifier }) { model.preferences.market = market }
        })) {
            ForEach(WorkspaceModel.targetLanguages) { market in Text(market.localizedLanguageName).tag(market.languageIdentifier) }
        }.labelsHidden().frame(minWidth: 140, maxWidth: 210, alignment: .trailing)
            .accessibilityIdentifier("workspace-target-language")
    }

    private var marketMenu: some View {
        Menu {
            Picker(hw("目标市场", "Target market"), selection: $model.preferences.market) {
                ForEach(Market.allCases) { market in Text("\(market.flag) \(market.localizedName) · \(market.localizedLanguageName)").tag(market) }
            }
        } label: {
            Text(model.preferences.market.flag + " " + model.preferences.market.localizedName)
                .font(.system(size: 12)).padding(.horizontal, 5).padding(.vertical, 5)
        }.menuStyle(.borderlessButton)
        .fixedSize().accessibilityLabel(hw("选择目标市场", "Choose a target market"))
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if wide {
                HStack(spacing: 0) {
                    sourcePane
                    Rectangle().fill(OceanStyle.line).frame(width: 1)
                    translationPane
                }
            } else {
                sourcePane
                Rectangle().fill(OceanStyle.line).frame(height: 1)
                translationPane
            }
            #if !os(macOS)
            if model.effectiveEngine == .cloud {
                Divider()
                Label(model.dataFlowMessage, systemImage: "network")
                    .font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            #endif
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(OceanStyle.line, lineWidth: 1))
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hw("原文", "Original")).font(.system(size: 12, weight: .medium)).foregroundStyle(OceanStyle.secondary)
                Spacer()
                sourceLanguagePicker
            }.padding(.horizontal, 12).padding(.vertical, 10)
            ZStack(alignment: .topLeading) {
                if model.composition.source.isEmpty {
                    Text(hw("输入原文", "Enter text"))
                        .font(.system(size: 17)).foregroundStyle(OceanStyle.secondary)
                        .padding(.horizontal, 12).padding(.top, 9).allowsHitTesting(false)
                }
                NativeSourceEditor(text: model.composition.source, resetID: model.sourceEditorResetID) { text, marked in
                    model.sourceEditorChanged(text, hasMarkedText: marked)
                }
                    .padding(.horizontal, 7).padding(.top, 2)
            }.frame(height: wide ? editorHeight : 160)
            HStack {
                Text("\(model.composition.source.count) / \(model.composition.maximumLength)").monospacedDigit()
                Spacer()
                Button(hw("清空", "Clear"), systemImage: "xmark.circle") { model.clear() }
                    .buttonStyle(.plain).frame(minHeight: 28).disabled(model.composition.source.isEmpty)
            }.font(.system(size: 11)).foregroundStyle(OceanStyle.secondary).padding(.horizontal, 12).padding(.vertical, 4)
        }.frame(maxWidth: .infinity)
    }

    private var translationPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.sameLanguage ? hw("输出", "Output") : hw("译文", "Translation")).font(.system(size: 12, weight: .medium)).foregroundStyle(OceanStyle.secondary)
                Spacer()
                targetLanguagePicker
            }.padding(.horizontal, 12).padding(.vertical, 10)
            Group {
                if let text = model.outputText {
                    ScrollView {
                        Text(text).font(.system(size: 17)).lineSpacing(5).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 5)
                    }
                    .environment(\.layoutDirection, model.preferences.market == .saudiArabia ? .rightToLeft : .leftToRight)
                } else if let preview = model.streamPreview {
                    ScrollView {
                        Text(preview).font(.system(size: 17)).lineSpacing(5).textSelection(.disabled)
                            .foregroundStyle(OceanStyle.ink.opacity(0.78))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 5)
                    }
                    .environment(\.layoutDirection, model.preferences.market == .saudiArabia ? .rightToLeft : .leftToRight)
                } else {
                    ZStack(alignment: .topLeading) {
                        Text(model.sameLanguage ? hw("原文输出", "Original text") : hw("译文", "Translation"))
                            .font(.system(size: 17)).foregroundStyle(OceanStyle.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 12).padding(.top, 9)
                        if model.isBusy { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                }
            }.frame(height: wide ? editorHeight : 160)
            HStack {
                if model.streamPreview != nil {
                    Text(hw("正在生成", "Generating"))
                } else if model.outputText != nil {
                    Text(model.resultIsOriginal ? hw("已保留原文", "Original kept") : hw("已完成", "Complete"))
                }
                Spacer()
                Button(model.copied ? hw("已复制", "Copied") : model.resultIsOriginal ? hw("复制原文", "Copy original") : hw("复制译文", "Copy translation"), systemImage: model.copied ? "checkmark" : "doc.on.doc") { model.copyTranslation() }
                    .buttonStyle(.plain).foregroundStyle(OceanStyle.blue).frame(minHeight: 28).disabled(model.outputText == nil)
                    .accessibilityIdentifier("copy-translation")
            }.font(.system(size: 11)).foregroundStyle(OceanStyle.secondary).padding(.horizontal, 12).padding(.vertical, 4)
        }.frame(maxWidth: .infinity).background(Color(red: 0.98, green: 0.99, blue: 1))
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { automaticToggle; Spacer(minLength: 12); translateButton }
                VStack(alignment: .leading, spacing: 10) { automaticToggle; translateButton }
            }
            if !model.isEngineReady || model.isBusy || model.isSourceComposing { languageStatus }
            if let error = model.displayedError {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Color(red: 0.67, green: 0.29, blue: 0.16)).fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.preparationMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(OceanStyle.secondary)
            }
        }
    }

    private var automaticToggle: some View {
        Toggle(hw("自动翻译", "Auto translate"), isOn: $model.autoTranslationEnabled)
            .toggleStyle(.switch).controlSize(.small).font(.system(size: 12, weight: .medium))
            .fixedSize().accessibilityIdentifier("automatic-translation")
            .help(hw("停顿后翻译，输入法选词期间等待。", "Translate after a pause; wait until keyboard candidates are confirmed."))
    }

    private var languageStatus: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { statusLabel; preparationActions }
            VStack(alignment: .leading, spacing: 6) { statusLabel; preparationActions }
        }.font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            Circle().fill(model.isEngineReady ? OceanStyle.green : OceanStyle.secondary).frame(width: 5, height: 5)
            Text(model.statusTitle)
        }
    }

    @ViewBuilder private var preparationActions: some View {
        if model.availability == .supported && model.canPrepare {
            Button(hw("准备语言包", "Prepare languages"), systemImage: "arrow.down.circle") { model.prepare() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(OceanStyle.blue).frame(minHeight: 28)
        }
        if model.effectiveEngine != .apple && !model.isEngineReady {
            Button(hw("打开模型设置", "Open model settings"), systemImage: "slider.horizontal.3") { model.section = .settings }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(OceanStyle.blue).frame(minHeight: 28)
        }
    }

    private var translateButton: some View {
        Button { model.translate() } label: {
            HStack(spacing: 11) {
                Image(systemName: "arrow.turn.down.right")
                Text(model.sameLanguage ? hw("保留原文", "Keep original") : hw("翻译", "Translate"))
                #if os(macOS)
                Text("⌘ ↵").font(.system(size: 10, weight: .medium)).opacity(0.7)
                #endif
            }
        }
        .buttonStyle(OceanButtonStyle(primary: true))
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!model.canTranslate)
        .accessibilityIdentifier("translate-button")
    }
}
