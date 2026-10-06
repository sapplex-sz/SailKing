#if os(macOS)
import AppKit
import CryptoKit
import Darwin
import Foundation
import HaiwangCore

/// Only public configuration crosses this boundary. Credentials and source text
/// are never written to preferences, a queue, or a cache by the bridge.
struct InputMethodTranslationRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable { case configuration, translate }
    let version: Int
    let id: UUID
    let operation: Operation
    let text: String
    let source: String?
    let target: String
    let market: String
    let configurationFingerprint: String?

    init(operation: Operation, text: String = "", preferences: KeyboardPreferences,
         configurationFingerprint: String? = nil) {
        version = 1
        id = UUID()
        self.operation = operation
        self.text = text
        source = preferences.source.languageIdentifier
        target = preferences.market.languageIdentifier
        market = preferences.market.rawValue
        self.configurationFingerprint = configurationFingerprint
    }
}

struct InputMethodTranslationConfiguration: Codable, Equatable, Sendable {
    let engine: TranslationEngine
    let fingerprint: String

    static func make(engine: TranslationEngine, settings: EnginePreferences,
                     catalog: ModelCatalog) throws -> Self {
        struct PublicSnapshot: Encodable {
            let engine: TranslationEngine
            let settings: EnginePreferences
            let catalog: ModelCatalog
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(PublicSnapshot(engine: engine, settings: settings, catalog: catalog))
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(engine: engine, fingerprint: fingerprint)
    }
}

struct InputMethodTranslationResponse: Codable, Sendable {
    let version: Int
    let id: UUID
    let configuration: InputMethodTranslationConfiguration?
    let translation: String?
    let failure: InputMethodTranslationFailure?

    init(id: UUID, configuration: InputMethodTranslationConfiguration? = nil,
         translation: String? = nil, failure: InputMethodTranslationFailure? = nil) {
        version = 1
        self.id = id
        self.configuration = configuration
        self.translation = translation
        self.failure = failure
    }
}

struct InputMethodTranslationFailure: Codable, Error, LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }

    static let unavailable = Self(code: "hostUnavailable", message: "出海王翻译服务尚未就绪。请打开出海王输入法 App 后重试，原文已保留。")
    static let timedOut = Self(code: "timeout", message: "本次翻译等待超时，请缩短文字后重试，原文已保留。")
    static let invalidMessage = Self(code: "invalidMessage", message: "输入法与 App 的连接数据无效，请重新打开出海王输入法 App。")
    static let configurationChanged = Self(code: "configurationChanged", message: "翻译设置已改变，请按回车重新翻译，原文已保留。")
    static let textTooLong = Self(code: "textTooLong", message: "一次最多翻译 2000 个字，请分段输入，原文已保留。")
    static let unauthorized = Self(code: "unauthorized", message: "无法验证本机翻译服务，请重新安装并打开出海王输入法 App。")
}

@MainActor
enum InputMethodTranslationClient {
    static func translate(text: String, preferences: KeyboardPreferences,
                          endpointDirectory: URL = InputMethodSocketEndpoint.directory) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InputMethodTranslationFailure(code: "empty", message: "请先输入需要翻译的文字。")
        }
        guard text.count <= 2000 else { throw InputMethodTranslationFailure.textTooLong }
        try Task.checkCancellation()
        let configurationRequest = InputMethodTranslationRequest(operation: .configuration, preferences: preferences)
        let configurationResponse: InputMethodTranslationResponse
        do {
            configurationResponse = try await exchange(configurationRequest, timeout: 3, directory: endpointDirectory)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Do not launch another copy when a running host returns a meaningful
            // protocol or authorization error.
            if let failure = error as? InputMethodTranslationFailure,
               failure.code == "unauthorized" || failure.code == "invalidMessage" { throw failure }
            try await launchHost()
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            var ready: InputMethodTranslationResponse?
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                do {
                    ready = try await exchange(configurationRequest, timeout: 1, directory: endpointDirectory)
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            guard let ready else { throw InputMethodTranslationFailure.unavailable }
            configurationResponse = ready
        }
        if let failure = configurationResponse.failure { throw failure }
        guard let configuration = configurationResponse.configuration else {
            throw InputMethodTranslationFailure.invalidMessage
        }
        let request = InputMethodTranslationRequest(operation: .translate, text: text, preferences: preferences,
                                                   configurationFingerprint: configuration.fingerprint)
        let response = try await exchange(request, timeout: 90, directory: endpointDirectory)
        if let failure = response.failure { throw failure }
        guard response.configuration == configuration, let result = response.translation,
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, result.count <= 12000 else {
            throw InputMethodTranslationFailure.invalidMessage
        }
        try Task.checkCancellation()
        return result
    }

    private static func exchange(_ request: InputMethodTranslationRequest,
                                 timeout: TimeInterval, directory: URL) async throws -> InputMethodTranslationResponse {
        let connection = InputMethodSocketConnection()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await InputMethodSocketIO.perform {
                defer { connection.close() }
                let endpoint = try InputMethodSocketEndpoint.existing(in: directory)
                try connection.connect(to: endpoint, timeout: min(timeout, 2))
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                try connection.write(JSONEncoder().encode(request), deadline: deadline)
                let response = try JSONDecoder().decode(InputMethodTranslationResponse.self,
                                                       from: connection.read(deadline: deadline))
                guard response.version == 1, response.id == request.id else {
                    throw InputMethodTranslationFailure.invalidMessage
                }
                return response
            }
        } onCancel: {
            // shutdown wakes poll/read immediately; only the owning I/O worker
            // closes the descriptor, so cancellation cannot reuse an active fd.
            connection.cancel()
        }
    }

    private static func launchHost() async throws {
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/出海王输入法.app", isDirectory: true)
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.haiwang.app")
        let application = FileManager.default.fileExists(atPath: installed.path) ? installed : registered
        guard let application,
              Bundle(url: application)?.bundleIdentifier == "com.haiwang.app" else {
            throw InputMethodTranslationFailure.unavailable
        }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = false
        let launch = InputMethodApplicationLaunch()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                launch.attach(continuation)
                let timeout = Task {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    launch.finish(.failure(InputMethodTranslationFailure.unavailable))
                }
                launch.attachTimeout(timeout)
                NSWorkspace.shared.openApplication(at: application, configuration: options) { _, error in
                    if let error { launch.finish(.failure(error)) }
                    else { launch.finish(.success(())) }
                }
            }
        } onCancel: {
            launch.finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
    }
}

private final class InputMethodApplicationLaunch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private var timeout: Task<Void, Never>?

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        let completed = result
        if completed == nil { self.continuation = continuation }
        lock.unlock()
        if let completed { continuation.resume(with: completed) }
    }

    func attachTimeout(_ timeout: Task<Void, Never>) {
        lock.lock()
        let completed = result != nil
        if !completed { self.timeout = timeout }
        lock.unlock()
        if completed { timeout.cancel() }
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        let timeout = self.timeout
        self.continuation = nil
        self.timeout = nil
        lock.unlock()
        timeout?.cancel()
        continuation?.resume(with: result)
    }
}

enum InputMethodSocketIO {
    static let workers = DispatchQueue(label: "com.haiwang.inputmethod.ipc", attributes: .concurrent)
    static func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            workers.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

enum InputMethodSocketEndpoint {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Haiwang", isDirectory: true)
    }
    static var path: String { directory.appendingPathComponent("translation-v1.sock").path }
    static func path(in directory: URL) -> String { directory.appendingPathComponent("translation-v1.sock").path }

    static func prepare(in directory: URL = directory) throws -> String {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == S_IFDIR,
              chmod(directory.path, 0o700) == 0 else { throw InputMethodTranslationFailure.unauthorized }
        return path(in: directory)
    }

    static func existing(in directory: URL = directory) throws -> String {
        let path = path(in: directory)
        var directoryInfo = stat()
        var socketInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0 else { throw InputMethodTranslationFailure.unavailable }
        guard directoryInfo.st_uid == geteuid(), (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              (directoryInfo.st_mode & 0o777) == 0o700 else { throw InputMethodTranslationFailure.unauthorized }
        guard lstat(path, &socketInfo) == 0 else { throw InputMethodTranslationFailure.unavailable }
        guard socketInfo.st_uid == geteuid(), (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
              (socketInfo.st_mode & 0o777) == 0o600 else { throw InputMethodTranslationFailure.unauthorized }
        return path
    }

    static func address(_ path: String) throws -> (sockaddr_un, socklen_t) {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw InputMethodTranslationFailure.unavailable
        }
        let length = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)! + bytes.count
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(length)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        return (address, socklen_t(length))
    }
}

final class InputMethodSocketConnection: @unchecked Sendable {
    static let maximumFrameBytes = 64 * 1024
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false

    init(descriptor: Int32 = -1) { self.descriptor = descriptor }

    func connect(to path: String, timeout: TimeInterval) throws {
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw InputMethodTranslationFailure.unavailable }
        lock.lock()
        if cancelled {
            lock.unlock()
            Darwin.close(socketFD)
            throw CancellationError()
        }
        descriptor = socketFD
        lock.unlock()
        try Self.configure(socketFD)
        var (address, length) = try InputMethodSocketEndpoint.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketFD, $0, length) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw InputMethodTranslationFailure.unavailable }
            try wait(for: Int16(POLLOUT), deadline: ProcessInfo.processInfo.systemUptime + timeout)
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0,
                  socketError == 0 else { throw InputMethodTranslationFailure.unavailable }
        }
        try verifyPeer()
    }

    static func configure(_ descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            throw InputMethodTranslationFailure.unavailable
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    func verifyPeer() throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(try liveDescriptor(), &uid, &gid) == 0, uid == geteuid() else {
            throw InputMethodTranslationFailure.unauthorized
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if descriptor >= 0 { _ = shutdown(descriptor, SHUT_RDWR) }
        lock.unlock()
    }

    func close() {
        lock.lock()
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        lock.unlock()
    }

    /// Used only by the server's read source while awaiting translation. The lock
    /// keeps an already-closed descriptor from referring to an unrelated socket.
    func peerClosedOrSentExtraBytes() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, !cancelled else { return true }
        var byte: UInt8 = 0
        let count = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return count >= 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
    }

    func liveDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        guard descriptor >= 0 else { throw InputMethodTranslationFailure.unavailable }
        return descriptor
    }

    func read(deadline: TimeInterval) throws -> Data {
        let header = try readBytes(count: 4, deadline: deadline)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= Self.maximumFrameBytes else { throw InputMethodTranslationFailure.invalidMessage }
        return try readBytes(count: Int(size), deadline: deadline)
    }

    func write(_ payload: Data, deadline: TimeInterval) throws {
        guard !payload.isEmpty, payload.count <= Self.maximumFrameBytes else {
            throw InputMethodTranslationFailure.invalidMessage
        }
        let size = UInt32(payload.count)
        var frame = Data([UInt8((size >> 24) & 0xff), UInt8((size >> 16) & 0xff),
                          UInt8((size >> 8) & 0xff), UInt8(size & 0xff)])
        frame.append(payload)
        var sent = 0
        try frame.withUnsafeBytes { buffer in
            while sent < frame.count {
                try wait(for: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.send(try liveDescriptor(), buffer.baseAddress!.advanced(by: sent), frame.count - sent, 0)
                if count > 0 { sent += count }
                else if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                else { throw InputMethodTranslationFailure.unavailable }
            }
        }
    }

    private func readBytes(count: Int, deadline: TimeInterval) throws -> Data {
        var bytes = Data(count: count)
        var received = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while received < count {
                try wait(for: Int16(POLLIN), deadline: deadline)
                let amount = recv(try liveDescriptor(), buffer.baseAddress!.advanced(by: received), count - received, 0)
                if amount > 0 { received += amount }
                else if amount < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                else { throw InputMethodTranslationFailure.unavailable }
            }
        }
        return bytes
    }

    private func wait(for event: Int16, deadline: TimeInterval) throws {
        while true {
            let fd = try liveDescriptor()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw InputMethodTranslationFailure.timedOut }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000).rounded(.up)))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw InputMethodTranslationFailure.unavailable }
            if result == 0 { continue }
            _ = try liveDescriptor()
            if descriptor.revents & event != 0 { return }
            if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                throw InputMethodTranslationFailure.unavailable
            }
        }
    }
}

/// Each accepted connection owns one bounded request and one cancellable task.
/// Cancelling the IMK task closes its connection and cancels host-side inference.
final class InputMethodSocketServer: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (InputMethodTranslationRequest) async -> InputMethodTranslationResponse
    private let lock = NSLock()
    private let acceptance = DispatchQueue(label: "com.haiwang.inputmethod.ipc.accept")
    private let endpointDirectory: URL
    private var listener: DispatchSourceRead?
    private var transactions: [UUID: InputMethodSocketTransaction] = [:]
    private var generation = UUID()

    init(endpointDirectory: URL = InputMethodSocketEndpoint.directory) {
        self.endpointDirectory = endpointDirectory
    }

    func start(handler: @escaping Handler) async throws {
        let startGeneration: UUID = locked {
            generation = UUID()
            return generation
        }
        let directory = endpointDirectory
        let descriptor = try await InputMethodSocketIO.perform { try Self.makeListener(in: directory) }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: acceptance)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler { [weak self] in self?.accept(descriptor, handler: handler) }
        let installed: Bool = locked {
            guard generation == startGeneration, listener == nil else { return false }
            listener = source
            return true
        }
        source.resume()
        if !installed {
            source.cancel()
            _ = unlink(InputMethodSocketEndpoint.path(in: endpointDirectory))
        }
    }

    func stop() {
        let state: (DispatchSourceRead?, [InputMethodSocketTransaction]) = locked {
            generation = UUID()
            let state = (listener, Array(transactions.values))
            listener = nil
            transactions.removeAll()
            return state
        }
        state.0?.cancel()
        if state.0 != nil { _ = unlink(InputMethodSocketEndpoint.path(in: endpointDirectory)) }
        state.1.forEach { $0.cancel() }
    }

    private func accept(_ descriptor: Int32, handler: @escaping Handler) {
        while true {
            let accepted = Darwin.accept(descriptor, nil, nil)
            guard accepted >= 0 else { return }
            let connection = InputMethodSocketConnection(descriptor: accepted)
            do {
                try InputMethodSocketConnection.configure(accepted)
                try connection.verifyPeer()
            } catch { connection.close(); continue }
            let id = UUID()
            let transaction = InputMethodSocketTransaction(connection: connection)
            let registered = locked {
                guard listener != nil, transactions.count < 8 else { return false }
                transactions[id] = transaction
                return true
            }
            guard registered else { connection.close(); continue }
            let task = Task { [weak self] in
                defer {
                    transaction.finish()
                    _ = self?.locked { self?.transactions.removeValue(forKey: id) }
                }
                do {
                    let request = try await InputMethodSocketIO.perform {
                        try JSONDecoder().decode(InputMethodTranslationRequest.self,
                            from: connection.read(deadline: ProcessInfo.processInfo.systemUptime + 5))
                    }
                    try Task.checkCancellation()
                    transaction.watchDisconnect(on: self?.acceptance ?? InputMethodSocketIO.workers)
                    let deadlineTask = Task {
                        do { try await Task.sleep(for: .seconds(90)) } catch { return }
                        transaction.cancel()
                    }
                    defer { deadlineTask.cancel() }
                    let response = await handler(request)
                    try Task.checkCancellation()
                    try await InputMethodSocketIO.perform {
                        try connection.write(JSONEncoder().encode(response),
                                             deadline: ProcessInfo.processInfo.systemUptime + 3)
                    }
                } catch {
                    // Deliberately no request/response logging or retained payload.
                }
            }
            transaction.attach(task)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func makeListener(in directory: URL) throws -> Int32 {
        let path = try InputMethodSocketEndpoint.prepare(in: directory)
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_uid == geteuid(), (existing.st_mode & S_IFMT) == S_IFSOCK else {
                throw InputMethodTranslationFailure.unauthorized
            }
            let probe = InputMethodSocketConnection()
            defer { probe.close() }
            do {
                try probe.connect(to: path, timeout: 0.2)
                throw InputMethodTranslationFailure(code: "alreadyRunning", message: "出海王翻译服务已经运行。")
            } catch let failure as InputMethodTranslationFailure where failure.code == "alreadyRunning" {
                throw failure
            } catch let failure as InputMethodTranslationFailure where failure.code == "unauthorized" || failure.code == "timeout" {
                throw failure
            } catch {
                guard unlink(path) == 0 else { throw InputMethodTranslationFailure.unavailable }
            }
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw InputMethodTranslationFailure.unavailable }
        var bound = false
        do {
            try InputMethodSocketConnection.configure(descriptor)
            var (address, length) = try InputMethodSocketEndpoint.address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, length) }
            }
            guard result == 0 else { throw InputMethodTranslationFailure.unavailable }
            bound = true
            guard chmod(path, 0o600) == 0, Darwin.listen(descriptor, 8) == 0 else {
                throw InputMethodTranslationFailure.unavailable
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            if bound { _ = unlink(path) }
            throw error
        }
    }
}

private final class InputMethodSocketTransaction: @unchecked Sendable {
    let connection: InputMethodSocketConnection
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var monitor: DispatchSourceRead?
    private var cancelled = false
    private var finished = false
    init(connection: InputMethodSocketConnection) { self.connection = connection }

    func attach(_ task: Task<Void, Never>) {
        lock.lock()
        if !finished { self.task = task }
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { task.cancel() }
    }

    func watchDisconnect(on queue: DispatchQueue) {
        guard let descriptor = try? connection.liveDescriptor() else { cancel(); return }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, self.connection.peerClosedOrSentExtraBytes() else { return }
            self.cancel()
        }
        lock.lock()
        monitor = source
        let cancelNow = cancelled
        lock.unlock()
        source.resume()
        if cancelNow { source.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let currentTask = task
        let currentMonitor = monitor
        lock.unlock()
        connection.cancel()
        currentTask?.cancel()
        currentMonitor?.cancel()
    }

    func finish() {
        lock.lock()
        finished = true
        let source = monitor
        monitor = nil
        task = nil
        lock.unlock()
        source?.cancel()
        connection.close()
    }
}
#endif
