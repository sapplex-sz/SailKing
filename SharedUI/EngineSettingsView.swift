import SwiftUI
import HaiwangCore

struct EngineSettingsView: View {
    @Bindable var model: WorkspaceModel
    #if !os(macOS)
    @State private var serviceDraft = ""
    @State private var isRefreshing = false
    @State private var serviceMessage: String?
    @State private var serviceError: String?
    #endif

    private var localModel: LocalModelDescriptor? {
        model.runtime.catalog.localModels.first { $0.id == model.runtime.settings.localModelID }
            ?? model.runtime.catalog.localModels.first { $0.id == model.runtime.catalog.defaultLocalModelID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsGroup(hw("翻译引擎", "Translation engine")) {
                Picker(hw("翻译方式", "Translation mode"), selection: Binding(get: { model.runtime.settings.mode }, set: { model.runtime.settings.mode = $0 })) {
                    ForEach(TranslationEngine.platformChoices) { engine in Text(engine.localizedTitle).tag(engine) }
                }
                .labelsHidden()
                #if os(macOS)
                .pickerStyle(.segmented)
                #else
                .pickerStyle(.menu)
                #endif
                .help(model.runtime.settings.mode.localizedSummary)
                #if !os(macOS)
                if model.runtime.settings.mode == .automatic {
                    Toggle(hw("允许自动回退到 API（需要联网）", "Allow API fallback (requires internet)"), isOn: Binding(get: { model.runtime.settings.cloudFallbackEnabled }, set: { model.runtime.settings.cloudFallbackEnabled = $0 }))
                        .font(.system(size: 12)).toggleStyle(.switch)
                    Text(hw("默认关闭。关闭时，自动模式不会把输入文字发送到后台。", "Off by default. When disabled, Automatic mode does not send your text to the backend."))
                        .font(.system(size: 11)).foregroundStyle(OceanStyle.secondary)
                }
                #endif
                if model.runtime.settings.mode == .automatic {
                    Label(model.engineLabel, systemImage: model.effectiveEngine == .cloud ? "network" : "cpu")
                        .font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
                }
                #if !os(macOS)
                Text(model.dataFlowMessage).font(.system(size: 11)).foregroundStyle(OceanStyle.secondary).lineSpacing(3)
                #endif
            }

            settingsGroup(hw("本地模型", "Local model")) {
                if model.runtime.catalog.localModels.isEmpty {
                    #if os(macOS)
                    Text(hw("暂时没有可用模型。请检查网络后重新打开 App，或先使用 Apple 内置翻译。", "No models are available yet. Check your connection and reopen the app, or use Apple translation for now.")).font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
                    #else
                    Text(hw("当前目录没有本地模型，可尝试刷新后台配置。", "No local models are listed. Try refreshing the backend configuration.")).font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
                    #endif
                } else {
                    Picker(hw("选择模型", "Choose a model"), selection: Binding(get: { localModel?.id ?? "" }, set: { model.runtime.settings.localModelID = $0 })) {
                        ForEach(model.runtime.catalog.localModels) { entry in Text(entry.name).tag(entry.id) }
                    }.labelsHidden().font(.system(size: 12)).disabled(model.isPreparingLocal || model.runtime.downloadProgress != nil)
                }
                if let localModel {
                    Text(ByteCountFormatter.string(fromByteCount: localModel.downloadBytes, countStyle: .file) + " · " + hw("建议 \(localModel.minimumMemoryGB) GB 内存", "\(localModel.minimumMemoryGB) GB memory recommended"))
                        .font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
                }
                #if os(iOS)
                Text(hw("当前 iOS 版暂不运行本地开源模型。请选择 API 或 Apple 内置翻译。", "This iOS version does not run local open-source models. Choose API or Apple translation."))
                    .font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
                #else
                if !model.runtime.localModelCompatible {
                    Text(hw("当前设备不适配所选模型，请选其他模型或 Apple 内置翻译。", "This model does not fit the current device. Choose another model or Apple translation."))
                        .font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
                }
                #endif
                if let progress = model.runtime.downloadProgress {
                    ProgressView(value: min(max(progress, 0), 1)) {
                        Text(hw("正在下载模型", "Downloading model"))
                    } currentValueLabel: {
                        Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                    }.font(.system(size: 11))
                }
                HStack(spacing: 12) {
                    Button(model.runtime.localModelReady ? hw("模型已就绪", "Model ready") : hw("下载模型", "Download model"), systemImage: model.runtime.localModelReady ? "checkmark.circle" : "arrow.down.circle") {
                        model.prepareLocalModel()
                    }.buttonStyle(OceanButtonStyle()).disabled(localModel == nil || !model.runtime.localModelCompatible || model.runtime.localModelReady || model.isPreparingLocal || model.runtime.downloadProgress != nil)
                    if model.isPreparingLocal {
                        Button(model.isCancellingLocal ? hw("正在取消…", "Cancelling…") : hw("取消下载", "Cancel download")) {
                            model.cancelLocalPreparation()
                        }.buttonStyle(OceanButtonStyle()).disabled(model.isCancellingLocal)
                        ProgressView().controlSize(.small)
                    }
                }
                if let message = model.localPreparationMessage { Text(message).font(.system(size: 12)).foregroundStyle(OceanStyle.green) }
                if let error = model.localPreparationError { Text(error).font(.system(size: 12)).foregroundStyle(OceanStyle.warning) }
                #if !os(macOS)
                Text(hw("模型目录由后台维护。下载模型不会上传输入文字。", "The backend maintains the model catalog. Downloading a model does not upload your input text."))
                    .font(.system(size: 11)).foregroundStyle(OceanStyle.secondary)
                #endif
            }

            #if !os(macOS)
            settingsGroup(hw("后台与 API", "Backend and API")) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(hw("后台地址", "Backend address")).font(.system(size: 12, weight: .medium))
                    TextField("https://octsz.com", text: $serviceDraft).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .autocorrectionDisabled()
                    HStack(spacing: 10) {
                        Button(hw("应用地址", "Apply address")) { applyServiceAddress() }
                            .buttonStyle(OceanButtonStyle()).disabled(isRefreshing || serviceDraft == model.runtime.settings.serviceURL)
                        Button(hw("刷新模型目录", "Refresh model catalog"), systemImage: "arrow.clockwise") { refreshCatalog() }
                            .buttonStyle(OceanButtonStyle()).disabled(isRefreshing || serviceDraft != model.runtime.settings.serviceURL)
                        if isRefreshing { ProgressView().controlSize(.small) }
                    }
                }
                Divider()
                if model.runtime.catalog.apiModels.isEmpty {
                    Text(hw("后台尚未提供 API 模型。请刷新配置，或使用本地引擎。", "The backend has not provided any API models. Refresh the configuration or use an on-device engine."))
                        .font(.system(size: 12)).foregroundStyle(OceanStyle.secondary)
                } else {
                    Picker(hw("API 模型", "API model"), selection: Binding(get: { selectedAPIModelID }, set: { model.runtime.settings.apiModelID = $0 })) {
                        ForEach(model.runtime.catalog.apiModels) { entry in Text(entry.name).tag(entry.id) }
                    }.font(.system(size: 12))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(hw("出海王服务访问码", "SailKing service access code")).font(.system(size: 12, weight: .medium))
                    SecureField(hw("输入服务访问码", "Enter your service access code"), text: Binding(get: { model.runtime.accessCode }, set: { model.runtime.accessCode = $0 }))
                        .textFieldStyle(.roundedBorder).privacySensitive()
                    Text(hw("访问码仅在本次会话有效，关闭后需要重新输入。", "The access code is valid for this app session only. Enter it again after closing the app."))
                        .font(.system(size: 11)).foregroundStyle(OceanStyle.secondary).lineSpacing(3)
                }
                Text(hw("API 模式会把原文发送到上述后台及其配置的翻译供应商；供应商密钥仅保存在服务端。", "API mode sends the original text to this backend and its configured translation provider. Provider API keys stay on the server."))
                    .font(.system(size: 12)).foregroundStyle(OceanStyle.secondary).lineSpacing(4)
                if let serviceMessage { Text(serviceMessage).font(.system(size: 12)).foregroundStyle(OceanStyle.green) }
                if let serviceError { Text(serviceError).font(.system(size: 12)).foregroundStyle(OceanStyle.warning) }
            }
            #endif
        }
        #if !os(macOS)
        .onAppear { serviceDraft = model.runtime.settings.serviceURL }
        #endif
    }

    #if !os(macOS)
    private var selectedAPIModelID: String {
        model.runtime.catalog.apiModels.first { $0.id == model.runtime.settings.apiModelID }?.id
            ?? model.runtime.catalog.defaultAPIModelID
    }

    private func applyServiceAddress() {
        let address = serviceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            serviceError = hw("请输入不含账号、查询参数或片段的 HTTPS 后台地址。", "Enter an HTTPS backend address without credentials, query parameters, or a fragment.")
            serviceMessage = nil
            return
        }
        model.runtime.settings.serviceURL = address
        serviceDraft = address
        serviceError = nil
        serviceMessage = hw("后台地址已更新，请刷新模型目录。", "Backend address updated. Refresh the model catalog next.")
    }

    private func refreshCatalog() {
        isRefreshing = true
        serviceMessage = nil
        serviceError = nil
        Task { @MainActor in
            defer { isRefreshing = false }
            do {
                try await model.runtime.refreshCatalog()
                serviceMessage = hw("模型目录已从后台更新。", "The model catalog was updated from the backend.")
            } catch is CancellationError {
                serviceMessage = hw("刷新已取消。", "Refresh cancelled.")
            } catch { serviceError = workspaceErrorMessage(error) }
        }
    }
    #endif

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        OceanSettingsGroup(title: title, content: content)
    }
}
