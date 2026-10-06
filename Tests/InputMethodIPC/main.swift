import AppKit
import Darwin
import Foundation
import HaiwangCore

@MainActor private final class IPCCounters {
    var configurationRequests = 0
    var translationRequests = 0
    var cancellations = 0
}

@main @MainActor
struct InputMethodIPCSmoke {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    static func main() async throws {
        let directory = URL(fileURLWithPath: "/tmp/HaiwangIPC-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await checkTransport(directory: directory)
        try await checkHost(directory: directory)
        try await checkMacRouting()
        print("PASS: \(checks) input-method IPC checks — framing, permissions, cancellation, limits, host snapshot validation, same-language preservation, and Mac API rejection.")
    }

    private static func checkTransport(directory: URL) async throws {
        let counters = IPCCounters()
        let server = InputMethodSocketServer(endpointDirectory: directory)
        let configuration = try InputMethodTranslationConfiguration.make(engine: .apple,
            settings: EnginePreferences(), catalog: .bundled)
        try await server.start { request in
            if request.operation == .configuration {
                counters.configurationRequests += 1
                return .init(id: request.id, configuration: configuration)
            }
            counters.translationRequests += 1
            if request.text == "cancel-test" {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { counters.cancellations += 1 }
            }
            return .init(id: request.id, configuration: configuration, translation: request.text)
        }
        defer { server.stop() }
        let prefs = KeyboardPreferences(market: .unitedStates, source: .chinese)
        let output = try await InputMethodTranslationClient.translate(text: "smoke-test", preferences: prefs,
                                                                     endpointDirectory: directory)
        expect(output == "smoke-test", "A valid request must round-trip without modifying payload bytes")
        expect(counters.configurationRequests == 1 && counters.translationRequests == 1,
               "Translation must negotiate an immutable public configuration before sending text")
        let endpoint = try InputMethodSocketEndpoint.existing(in: directory)
        var directoryInfo = stat()
        var socketInfo = stat()
        expect(lstat(directory.path, &directoryInfo) == 0 && directoryInfo.st_uid == geteuid()
               && (directoryInfo.st_mode & 0o777) == 0o700, "IPC directory must be private to this user")
        expect(lstat(endpoint, &socketInfo) == 0 && socketInfo.st_uid == geteuid()
               && (socketInfo.st_mode & 0o777) == 0o600, "IPC socket must be private to this user")

        var tooLongRejected = false
        do {
            _ = try await InputMethodTranslationClient.translate(text: String(repeating: "文", count: 2001),
                                                               preferences: prefs, endpointDirectory: directory)
        } catch let failure as InputMethodTranslationFailure { tooLongRejected = failure.code == "textTooLong" }
        expect(tooLongRejected && counters.translationRequests == 1,
               "Oversized source must be rejected before contacting the translation host")

        let cancellation = Task {
            try await InputMethodTranslationClient.translate(text: "cancel-test", preferences: prefs,
                                                            endpointDirectory: directory)
        }
        try await Task.sleep(for: .milliseconds(200))
        cancellation.cancel()
        var cancellationReturned = false
        do { _ = try await cancellation.value }
        catch is CancellationError { cancellationReturned = true }
        expect(cancellationReturned, "Client cancellation must unblock socket I/O immediately")
        try await Task.sleep(for: .milliseconds(300))
        expect(counters.cancellations == 1, "Closing the client socket must cancel the active host task")

        let invalidConnection = InputMethodSocketConnection()
        defer { invalidConnection.close() }
        try invalidConnection.connect(to: endpoint, timeout: 1)
        let descriptor = try invalidConnection.liveDescriptor()
        let malformed: [UInt8] = [0, 1, 0, 1] // 65,537-byte length; no payload allocation permitted.
        _ = malformed.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, malformed.count, 0) }
        try await Task.sleep(for: .milliseconds(100))
        var byte: UInt8 = 0
        expect(recv(descriptor, &byte, 1, MSG_DONTWAIT) == 0, "An oversized frame must disconnect immediately")
        expect(counters.translationRequests == 2, "An invalid frame must never reach the translation handler")

        expect(chmod(endpoint, 0o666) == 0, "Fixture must be able to change its own socket mode")
        var unsafeSocketRejected = false
        do { _ = try InputMethodSocketEndpoint.existing(in: directory) }
        catch let failure as InputMethodTranslationFailure { unsafeSocketRejected = failure.code == "unauthorized" }
        expect(unsafeSocketRejected, "A publicly accessible socket must fail authorization checks")
        expect(chmod(endpoint, 0o600) == 0, "Fixture must restore its own socket mode")
    }

    private static func checkHost(directory: URL) async throws {
        var settings = EnginePreferences()
        settings.mode = .apple
        let runtime = EngineRuntime(settings: settings, catalog: .bundled, persistSettings: false)
        let host = InputMethodTranslationHost(runtime: runtime, endpointDirectory: directory)
        host.start()
        defer { host.stop() }
        var endpoint: String?
        for _ in 0..<30 {
            endpoint = try? InputMethodSocketEndpoint.existing(in: directory)
            if endpoint != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let endpoint else { throw InputMethodTranslationFailure.unavailable }
        let prefs = KeyboardPreferences(market: .unitedStates, source: .english)
        let original = "  Preserve this original message exactly.\n"
        let output = try await InputMethodTranslationClient.translate(text: original, preferences: prefs,
                                                                     endpointDirectory: directory)
        expect(output == original, "Host must preserve exact text for identical explicit source and target languages")

        runtime.settings.mode = .localModel
        let localOriginal = try await InputMethodTranslationClient.translate(text: original, preferences: prefs,
                                                                          endpointDirectory: directory)
        expect(localOriginal == original, "Identical languages must preserve text without requiring a local model")
        runtime.settings.mode = .apple
        let autoPrefs = KeyboardPreferences(market: .unitedStates, source: .automatic)
        let autoOriginal = try await InputMethodTranslationClient.translate(text: original, preferences: autoPrefs,
                                                                         endpointDirectory: directory)
        expect(autoOriginal == original, "A substantive, confident automatic source match must preserve original text")

        let oldConfiguration = try InputMethodTranslationConfiguration.make(engine: runtime.resolvedEngine,
            settings: runtime.settings, catalog: runtime.catalog)
        runtime.settings.localModelID = "changed-test-model"
        let stale = InputMethodTranslationRequest(operation: .translate, text: "snapshot-test", preferences: prefs,
                                                  configurationFingerprint: oldConfiguration.fingerprint)
        let response = try await rawExchange(stale, endpoint: endpoint)
        expect(response.failure?.code == "configurationChanged" && response.translation == nil,
               "Host must reject an obsolete configuration before inference")

        let oversized = InputMethodTranslationRequest(operation: .translate, text: String(repeating: "文", count: 2001),
            preferences: prefs, configurationFingerprint: try InputMethodTranslationConfiguration.make(
                engine: runtime.resolvedEngine, settings: runtime.settings, catalog: runtime.catalog).fingerprint)
        let oversizeResponse = try await rawExchange(oversized, endpoint: endpoint)
        expect(oversizeResponse.failure?.code == "textTooLong", "Host must independently enforce the 2000-character source limit")
    }

    private static func rawExchange(_ request: InputMethodTranslationRequest,
                                    endpoint: String) async throws -> InputMethodTranslationResponse {
        try await InputMethodSocketIO.perform {
            let connection = InputMethodSocketConnection()
            defer { connection.close() }
            try connection.connect(to: endpoint, timeout: 1)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            try connection.write(JSONEncoder().encode(request), deadline: deadline)
            let response = try JSONDecoder().decode(InputMethodTranslationResponse.self,
                                                   from: connection.read(deadline: deadline))
            precondition(response.id == request.id && response.version == 1)
            return response
        }
    }

    private static func checkMacRouting() async throws {
        var legacy = EnginePreferences()
        legacy.mode = .cloud
        legacy.cloudFallbackEnabled = true
        legacy.apiModelID = "legacy-cloud-model"
        let runtime = EngineRuntime(settings: legacy, catalog: .bundled, persistSettings: false)
        expect(runtime.settings.mode == .automatic && !runtime.settings.cloudFallbackEnabled
               && runtime.settings.apiModelID.isEmpty, "Old Mac API settings must migrate to device-only translation")
        runtime.settings = legacy
        expect(runtime.settings.mode == .automatic && !runtime.settings.cloudFallbackEnabled,
               "Setting observers must sanitize an API selection without recursion")
        expect(runtime.resolvedEngine != .cloud, "Mac automatic routing must never resolve to API translation")
        let oldSnapshot = EngineSnapshot(engine: .cloud, settings: legacy, localModel: nil,
                                         apiModelID: "legacy-cloud-model", catalogRevision: "test-only")
        var oldSnapshotRejected = false
        do {
            _ = try await runtime.translate(text: "fixture", source: "zh-Hans", target: "en", market: "unitedStates",
                                            snapshot: oldSnapshot, streaming: false)
        } catch let error as EngineError { if case .invalidConfiguration = error { oldSnapshotRejected = true } }
        expect(oldSnapshotRejected, "A stale API snapshot must be rejected before any request to a provider")
    }
}
