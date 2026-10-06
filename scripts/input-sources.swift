import Foundation
import Carbon
import Darwin

// Build with: xcrun swiftc scripts/input-sources.swift -o haiwang-input-sources
// Carbon's public TextInputSources.h documents registration in ~/Library/Input Methods,
// followed by a fresh input-source lookup and TISEnableInputSource. Selection is explicit.
private let haiwangID = "com.haiwang.inputmethod.Haiwang"
private let unifiedSourceID = haiwangID + ".pinyin"
private let legacyEnglishID = haiwangID + ".english"

private func resolvedID(_ value: String) -> String {
    switch value {
    case "haiwang", "haiwang-pinyin": return unifiedSourceID
    case "haiwang-english": return legacyEnglishID
    case "haiwang-parent": return haiwangID
    default: return value
    }
}

private struct InputSourceRecord: Codable {
    let id: String
    let name: String
    let bundleID: String?
    let enabled: Bool
    let selected: Bool
    let selectCapable: Bool
    let enableCapable: Bool
    let languages: [String]
}

private enum SourceError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(message) = self { return message }
        return nil
    }
}

private func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
}

private func record(_ source: TISInputSource) -> InputSourceRecord {
    let id = property(source, kTISPropertyInputSourceID) as? String ?? ""
    let bundleID = property(source, kTISPropertyBundleID) as? String
    return InputSourceRecord(
        id: id,
        name: property(source, kTISPropertyLocalizedName) as? String ?? "",
        bundleID: bundleID,
        enabled: (property(source, kTISPropertyInputSourceIsEnabled) as? NSNumber)?.boolValue ?? false,
        selected: (property(source, kTISPropertyInputSourceIsSelected) as? NSNumber)?.boolValue ?? false,
        selectCapable: (property(source, kTISPropertyInputSourceIsSelectCapable) as? NSNumber)?.boolValue ?? false,
        enableCapable: (property(source, kTISPropertyInputSourceIsEnableCapable) as? NSNumber)?.boolValue ?? false,
        languages: property(source, kTISPropertyInputSourceLanguages) as? [String] ?? []
    )
}

private func sources(id: String? = nil, bundleID: String? = nil, all: Bool = false) -> [TISInputSource] {
    var properties: [String: String] = [:]
    if let id { properties[kTISPropertyInputSourceID as String] = id }
    if let bundleID { properties[kTISPropertyBundleID as String] = bundleID }
    let filter: CFDictionary? = properties.isEmpty ? nil : properties as CFDictionary
    guard let value = TISCreateInputSourceList(filter, all) else { return [] }
    let array = value.takeRetainedValue() as NSArray
    return array.map { $0 as! TISInputSource }
}

private func lookup(_ argument: String) throws -> TISInputSource {
    let id = resolvedID(argument)
    if let value = sources(id: id).first ?? sources(id: id, all: true).first { return value }
    throw SourceError.message("系统中没有找到输入源：\(id)")
}

private func current() throws -> InputSourceRecord {
    guard let value = TISCopyCurrentKeyboardInputSource() else {
        throw SourceError.message("无法读取当前键盘输入源。请在已登录的 Mac 桌面会话中运行。")
    }
    return record(value.takeRetainedValue())
}

private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func emit<T: Encodable>(_ value: T) throws {
    FileHandle.standardOutput.write(try encoded(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func check(_ status: OSStatus, operation: String) throws {
    guard status == noErr else { throw SourceError.message("\(operation)失败，系统状态：\(status)") }
}

private func select(_ id: String) throws {
    let source = try lookup(id)
    let value = record(source)
    guard value.enabled, value.selectCapable else {
        throw SourceError.message("输入源尚未启用或不可选：\(value.name)（\(value.id)）")
    }
    try check(TISSelectInputSource(source), operation: "选择 \(value.name)")
    let selected = try current()
    guard selected.id == value.id else {
        throw SourceError.message("系统返回成功但当前输入源仍为 \(selected.name)（\(selected.id)）。")
    }
    try emit(selected)
}

private func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        throw SourceError.message("用法：haiwang-input-sources list [--all] [--id ID | --bundle ID] | current | register APP路径 | enable ID | select ID | retire-english | snapshot JSON路径 | restore JSON路径。当前输入法 ID 可用 haiwang；haiwang-english 仅用于读取旧版状态。")
    }
    switch command {
    case "list":
        let extra = Array(args.dropFirst())
        let all = extra.contains("--all")
        var id: String?
        var bundleID: String?
        if let index = extra.firstIndex(of: "--id"), extra.indices.contains(index + 1) {
            id = resolvedID(extra[index + 1])
        }
        if let index = extra.firstIndex(of: "--bundle"), extra.indices.contains(index + 1) {
            bundleID = extra[index + 1] == "haiwang" ? haiwangID : extra[index + 1]
        }
        let known = extra.filter { $0 != "--all" }
        guard known.isEmpty || (known.count == 2 && (known.first == "--id" || known.first == "--bundle")) else {
            throw SourceError.message("list 仅接受 --all 和 --id ID / --bundle ID。")
        }
        try emit(sources(id: id, bundleID: bundleID, all: all).map(record))
    case "current":
        guard args.count == 1 else { throw SourceError.message("current 不接受参数。") }
        try emit(current())
    case "register":
        guard args.count == 2 else { throw SourceError.message("register 需要输入法 App 的完整路径。") }
        let url = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              id == haiwangID else {
            throw SourceError.message("注册仅允许出海王输入法包，且必须有有效的 Info.plist。")
        }
        try check(TISRegisterInputSource(url as CFURL), operation: "注册出海王输入法")
        let registered = sources(bundleID: haiwangID, all: true).map(record)
        guard !registered.isEmpty else { throw SourceError.message("注册调用成功，但未能读回出海王输入源。") }
        try emit(registered)
    case "enable":
        guard args.count == 2 else { throw SourceError.message("enable 需要输入源 ID。") }
        let source = try lookup(args[1])
        let value = record(source)
        guard value.enableCapable || value.enabled else {
            throw SourceError.message("该输入源不能被启用：\(value.name)（\(value.id)）")
        }
        // A mode's default enabled flag may be true even after its parent was
        // removed during renamed-bundle registration. Request both explicitly.
        if value.bundleID == haiwangID && value.id != haiwangID,
           let parent = sources(id: haiwangID, all: true).first {
            try check(TISEnableInputSource(parent), operation: "启用出海王父输入源")
        }
        try check(TISEnableInputSource(source), operation: "启用 \(value.name)")
        let enabled = record(try lookup(value.id))
        guard enabled.enabled else { throw SourceError.message("系统未确认输入源已启用：\(value.id)") }
        try emit(enabled)
    case "select":
        guard args.count == 2 else { throw SourceError.message("select 需要输入源 ID。") }
        try select(args[1])
    case "retire-english":
        guard args.count == 1 else { throw SourceError.message("retire-english 不接受参数。") }
        if let source = sources(id: legacyEnglishID, all: true).first {
            let old = record(source)
            guard old.bundleID == haiwangID else { throw SourceError.message("旧英文输入源的包标识不匹配。") }
            if old.selected { try select(unifiedSourceID) }
            if old.enabled { try check(TISDisableInputSource(source), operation: "移除独立海王英文输入源") }
        }
        guard !sources(id: legacyEnglishID, all: true).map(record).contains(where: { $0.enabled }) else {
            throw SourceError.message("系统仍启用了旧英文输入源，请在键盘设置的“文本输入 → 编辑”中选中“海王·英文”并点“−”。")
        }
        try emit(sources(bundleID: haiwangID, all: true).map(record))
    case "snapshot":
        guard args.count == 2 else { throw SourceError.message("snapshot 需要 JSON 文件路径。") }
        let value = try current()
        let url = URL(fileURLWithPath: args[1]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { throw SourceError.message("快照文件已存在，不覆盖：\(url.path)") }
        try encoded(value).write(to: url, options: .atomic)
        try emit(value)
    case "restore":
        guard args.count == 2 else { throw SourceError.message("restore 需要 snapshot 生成的 JSON 文件。") }
        let value = try JSONDecoder().decode(InputSourceRecord.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        // During an upgrade, the former English source is replaced by the unified
        // source. During rollback it remains selectable after restoring enablement.
        if value.id == legacyEnglishID && !(sources(id: legacyEnglishID, all: true).map(record).contains { $0.enabled && $0.selectCapable }) {
            try select(unifiedSourceID)
        } else { try select(value.id) }
    case "restore-enablement":
        guard args.count == 2 else { throw SourceError.message("restore-enablement 需要海王输入源列表 JSON 文件。") }
        let previous = try JSONDecoder().decode([InputSourceRecord].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let known = [haiwangID, haiwangID + ".pinyin", haiwangID + ".english"]
        guard previous.allSatisfy({ known.contains($0.id) && $0.bundleID == haiwangID }) else {
            throw SourceError.message("恢复启用状态仅支持海王输入源。")
        }
        for id in known where previous.contains(where: { $0.id == id && $0.enabled }) {
            if let source = try? lookup(id), !record(source).enabled {
                try check(TISEnableInputSource(source), operation: "恢复启用 \(id)")
            }
        }
        for id in known.reversed() where !previous.contains(where: { $0.id == id && $0.enabled }) {
            if let source = try? lookup(id), record(source).enabled {
                try check(TISDisableInputSource(source), operation: "恢复停用 \(id)")
            }
        }
        try emit(sources(bundleID: haiwangID, all: true).map(record))
    default:
        throw SourceError.message("未知操作：\(command)")
    }
}

do { try run() } catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
