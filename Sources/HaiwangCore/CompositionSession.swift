import Foundation

/// The source stays in the keyboard until the user explicitly commits a translation.
/// A revision token prevents an old async response being inserted after an edit or focus change.
public struct CompositionSession: Sendable {
    public private(set) var source = ""
    public private(set) var cursor = 0
    public private(set) var translation: String?
    public private(set) var revision: UInt64 = 0
    public private(set) var pendingRevision: UInt64?
    public private(set) var errorMessage: String?
    public let maximumLength = 2000
    public init() {}

    public mutating func setSource(_ value: String) {
        source = String(value.prefix(maximumLength))
        cursor = source.count
        invalidate()
    }
    public mutating func append(_ value: String) { setSource(source + value) }
    public mutating func insert(_ value: String) {
        let insertion = String(value.prefix(max(0, maximumLength - source.count)))
        let index = source.index(source.startIndex, offsetBy: cursor)
        let prefix = String(source[..<index]) + insertion
        source = prefix + source[index...]
        // Combining marks and emoji joiners can merge with the preceding grapheme.
        cursor = min(prefix.count, source.count)
        invalidate()
    }
    public mutating func moveCursor(by offset: Int) {
        cursor = max(0, min(source.count, cursor + offset))
        invalidate()
    }
    public mutating func deleteBackward() {
        guard cursor > 0 else { return }
        let index = source.index(source.startIndex, offsetBy: cursor - 1)
        source.remove(at: index)
        cursor = min(cursor - 1, source.count)
        invalidate()
    }
    public mutating func invalidate() {
        revision &+= 1
        translation = nil
        pendingRevision = nil
        errorMessage = nil
    }
    public mutating func beginTranslation() -> UInt64? {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        invalidate()
        pendingRevision = revision
        return revision
    }
    @discardableResult public mutating func finish(_ result: String, revision expected: UInt64) -> Bool {
        guard expected == revision, pendingRevision == expected else { return false }
        pendingRevision = nil
        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { errorMessage = "没有返回译文，请重试。"; return false }
        translation = cleaned
        return true
    }
    public mutating func fail(_ message: String, revision expected: UInt64) {
        guard expected == revision, pendingRevision == expected else { return }
        pendingRevision = nil
        errorMessage = message
    }
    public mutating func takeTranslation() -> String? {
        guard let output = translation else { return nil }
        reset()
        return output
    }
    public mutating func reset() { source = ""; cursor = 0; invalidate() }
}
