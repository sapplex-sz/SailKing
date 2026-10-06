import Foundation
import Observation
import HaiwangCore

@Observable @MainActor
final class EngineRuntime {
    static let shared = EngineRuntime()
    var settings: EnginePreferences {
        didSet {
            #if os(macOS)
            let sanitized = Self.macSettings(settings)
            if settings != sanitized { settings = sanitized }
            #endif
            if persistSettings { settings.save() }
            if oldValue.serviceURL != settings.serviceURL {
                accessCode = ""
                catalog = Self.cachedCatalog(for: settings.serviceURL) ?? .bundled
            }
            #if canImport(CHaHaRuntime) && os(macOS)
            if resolvedEngine != .localModel { releaseLocalModel() }
            #endif
        }
    }
    private(set) var catalog: ModelCatalog
    /// Session-only service credential. Upstream provider keys never enter the app.
    var accessCode = ""
    private(set) var downloadProgress: Double?
    private(set) var installationRevision = 0
    private var downloadID: UUID?
    private let persistSettings: Bool
    private let cloud = CloudTranslationClient()
    #if canImport(CHaHaRuntime) && os(macOS)
    private let local = LocalTranslationEngine()
    private var idleRelease: Task<Void, Never>?
    private var unloading: Task<Void, Never>?
    private func releaseLocalModel() {
        idleRelease?.cancel()
        idleRelease = nil
        guard unloading == nil else { return }
        let engine = local
        unloading = Task { [weak self] in
            await engine.unload()
            self?.unloading = nil
        }
    }
    private func scheduleIdleRelease() {
        idleRelease?.cancel()
        idleRelease = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.releaseLocalModel()
        }
    }
    #endif

    init(settings: EnginePreferences = .load(), catalog: ModelCatalog? = nil, persistSettings: Bool = true) {
        #if os(macOS)
        let prepared = Self.macSettings(settings)
        self.settings = prepared
        if persistSettings, prepared != settings { prepared.save() }
        #else
        self.settings = settings
        #endif
        self.persistSettings = persistSettings
        self.catalog = catalog ?? (persistSettings ? Self.cachedCatalog(for: settings.serviceURL) : nil) ?? .bundled
    }
    var selectedLocalModel: LocalModelDescriptor? {
        catalog.localModels.first { $0.id == settings.localModelID }
            ?? catalog.localModels.first { $0.id == catalog.defaultLocalModelID }
    }
    var localModelReady: Bool {
        _ = installationRevision
        return selectedLocalModel.map { ModelDownloadStore.isReady($0) } ?? false
    }
    var localModelCompatible: Bool {
        #if canImport(CHaHaRuntime) && os(macOS) && arch(arm64)
        guard let model = selectedLocalModel else { return false }
        return ProcessInfo.processInfo.physicalMemory >= UInt64(model.minimumMemoryGB) * 1_073_741_824
        #else
        return false
        #endif
    }
    var resolvedEngine: TranslationEngine {
        #if os(macOS)
        if settings.mode == .cloud { return .apple }
        #endif
        if settings.mode != .automatic { return settings.mode }
        if localModelCompatible && localModelReady { return .localModel }
        #if !os(macOS)
        if settings.cloudFallbackEnabled && !catalog.apiModels.isEmpty { return .cloud }
        #endif
        return .apple
    }
    func snapshot() -> EngineSnapshot {
        let apiID = catalog.apiModels.contains(where: { $0.id == settings.apiModelID })
            ? settings.apiModelID : catalog.defaultAPIModelID
        return .init(engine: resolvedEngine, settings: settings, localModel: selectedLocalModel,
                     apiModelID: apiID, catalogRevision: catalog.revision, accessCode: accessCode)
    }
    func refreshCatalog() async throws {
        let base = settings.serviceURL
        let value = try await cloud.catalog(base: base)
        try Task.checkCancellation()
        guard settings.serviceURL == base else { return }
        catalog = value
        if persistSettings, let data = try? JSONEncoder().encode(value) {
            UserDefaults(suiteName: KeyboardPreferences.defaultsSuite)?.set(data, forKey: "model-catalog:" + base)
        }
    }
    func prepareLocal() async throws {
        guard downloadProgress == nil else { throw EngineError.busy }
        guard localModelCompatible, let model = selectedLocalModel else { throw EngineError.modelIncompatible }
        let operation = UUID()
        downloadID = operation
        downloadProgress = 0
        defer { downloadID = nil; downloadProgress = nil; installationRevision += 1 }
        try await ModelDownloadStore.download(model) { [weak self] fraction in
            Task { @MainActor in
                guard self?.downloadID == operation else { return }
                self?.downloadProgress = fraction
            }
        }
    }
    func translate(text: String, source: String?, target: String, market: String, snapshot: EngineSnapshot,
                   streaming: Bool = true,
                   onUpdate: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        switch snapshot.engine {
        case .cloud:
            #if os(macOS)
            throw EngineError.invalidConfiguration
            #else
            let result: String
            if streaming {
                result = try await cloud.translateStreaming(text: text, source: source, target: target, market: market,
                    modelID: snapshot.apiModelID, base: snapshot.settings.serviceURL, accessCode: snapshot.accessCode, onUpdate: onUpdate)
            } else {
                result = try await cloud.translate(text: text, source: source, target: target, market: market,
                    modelID: snapshot.apiModelID, base: snapshot.settings.serviceURL, accessCode: snapshot.accessCode)
            }
            try ProtectedText.validate(source: text, output: result)
            return result
            #endif
        case .localModel:
            #if canImport(CHaHaRuntime) && os(macOS)
            idleRelease?.cancel()
            idleRelease = nil
            await unloading?.value
            try Task.checkCancellation()
            defer { scheduleIdleRelease() }
            guard let model = snapshot.localModel, model.isValid,
                  ProcessInfo.processInfo.physicalMemory >= UInt64(model.minimumMemoryGB) * 1_073_741_824 else { throw EngineError.modelIncompatible }
            guard ModelDownloadStore.isReady(model) else { throw EngineError.modelNotReady }
            let locale = Locale(identifier: "en")
            let previewUpdate: @Sendable (String) -> Void
            if streaming { previewUpdate = onUpdate } else { previewUpdate = { _ in } }
            let preview = LocalPreviewReceiver(update: previewUpdate)
            let output = try await local.translate(text: text,
                sourceLanguage: source.map { locale.localizedString(forIdentifier: $0) ?? $0 },
                targetLanguage: locale.localizedString(forIdentifier: target) ?? target,
                modelURL: ModelDownloadStore.location(model),
                glossary: Dictionary(uniqueKeysWithValues: Set(ProtectedText.entities(in: text)).map { ($0, $0) }),
                onToken: { preview.receive($0) })
            let result = try TranslationPrompt.clean(output)
            try ProtectedText.validate(source: text, output: result)
            return result
            #else
            throw EngineError.modelIncompatible
            #endif
        default: throw EngineError.invalidConfiguration
        }
    }
    #if os(macOS)
    private static func macSettings(_ value: EnginePreferences) -> EnginePreferences {
        var result = value
        if result.mode == .cloud { result.mode = .automatic }
        result.cloudFallbackEnabled = false
        result.apiModelID = ""
        return result
    }
    #endif

    private static func cachedCatalog(for base: String) -> ModelCatalog? {
        guard let data = UserDefaults(suiteName: KeyboardPreferences.defaultsSuite)?.data(forKey: "model-catalog:" + base),
              let decoded = try? JSONDecoder().decode(ModelCatalog.self, from: data) else { return nil }
        return try? decoded.validated()
    }
}

/// Native callbacks run on the inference worker. Keep accumulation there, and
/// coalesce UI notifications without losing any model bytes.
private final class LocalPreviewReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var raw = ""
    private var lastEmission: TimeInterval = 0
    private let update: @Sendable (String) -> Void
    init(update: @escaping @Sendable (String) -> Void) { self.update = update }
    func receive(_ delta: String) {
        lock.lock()
        raw += delta
        let now = Date.timeIntervalSinceReferenceDate
        let text = TranslationPreview.text(raw)
        let shouldEmit = !text.isEmpty && now - lastEmission >= 0.04
        if shouldEmit { lastEmission = now }
        lock.unlock()
        if shouldEmit { update(text) }
    }
}
