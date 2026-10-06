import Foundation
import CryptoKit
import HaiwangCore

struct DownloadReceipt: Codable {
    let sha256: String
    let size: Int64
    let modified: Date
}

enum ModelDownloadStore {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Haiwang/Models", isDirectory: true)
    }
    static func location(_ model: LocalModelDescriptor) -> URL {
        root.appendingPathComponent(model.cacheKey, isDirectory: true).appendingPathComponent(model.filename)
    }
    static func isReady(_ model: LocalModelDescriptor) -> Bool {
        guard model.isValid else { return false }
        let file = location(model)
        guard let data = try? Data(contentsOf: file.appendingPathExtension("receipt")),
              let receipt = try? JSONDecoder().decode(DownloadReceipt.self, from: data),
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path) else { return false }
        return receipt.sha256 == model.sha256 && receipt.size == model.downloadBytes
            && (attrs[.size] as? NSNumber)?.int64Value == receipt.size
            && attrs[.modificationDate] as? Date == receipt.modified
            && attrs[.type] as? FileAttributeType == .typeRegular
    }
    static func validate(_ file: URL, model: LocalModelDescriptor) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.int64Value == model.downloadBytes else { throw EngineError.invalidResponse }
        let stream = try FileHandle(forReadingFrom: file)
        defer { try? stream.close() }
        var hash = SHA256()
        while let data = try stream.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == model.sha256 else { throw EngineError.invalidResponse }
    }
    static func download(_ model: LocalModelDescriptor, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard model.isValid else { throw EngineError.invalidConfiguration }
        if isReady(model) { return }
        let destination = location(model)
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resources = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = resources.volumeAvailableCapacityForImportantUsage, free < model.downloadBytes * 2 { throw EngineError.modelIncompatible }
        let url = URL(string: "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(model.filename)")!
        let delegate = ModelTransferProgress(expectedBytes: model.downloadBytes, progress: progress)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3600
        let (file, response) = try await session.download(for: request, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https" else { throw EngineError.serviceUnavailable }
        try Task.checkCancellation()
        try validate(file, model: model)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: file, to: destination)
        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        let receipt = DownloadReceipt(sha256: model.sha256, size: model.downloadBytes, modified: attrs[.modificationDate] as? Date ?? .distantPast)
        try JSONEncoder().encode(receipt).write(to: destination.appendingPathExtension("receipt"), options: .atomic)
        progress(1)
    }
}

private final class ModelTransferProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expectedBytes: Int64
    let progress: @Sendable (Double) -> Void
    init(expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes; self.progress = progress
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes { downloadTask.cancel(); return }
        progress(min(0.99, Double(totalBytesWritten) / Double(expectedBytes)))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
