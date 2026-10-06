import AppKit
import Carbon
@preconcurrency import InputMethodKit

/// An in-memory text client implementing the actual IMKTextInput protocol.
/// Its NSRanges use UTF-16, as Cocoa text clients do.
@MainActor
final class MockInputClient: NSObject, @preconcurrency IMKTextInput {
    private(set) var document = ""
    private(set) var inserted: [String] = []
    private(set) var markedUpdates: [String] = []
    private(set) var hostReturnCount = 0
    private(set) var lastAttributeIndex: Int?
    private var selection = NSRange(location: 0, length: 0)
    private var mark = NSRange(location: NSNotFound, length: 0)
    private let uniqueID = UUID().uuidString

    var committedText: String {
        guard mark.location != NSNotFound else { return document }
        return (document as NSString).replacingCharacters(in: mark, with: "")
    }

    func reset(_ text: String = "", selectedRange: NSRange? = nil) {
        document = text
        selection = selectedRange ?? NSRange(location: text.utf16.count, length: 0)
        mark = NSRange(location: NSNotFound, length: 0)
        inserted = []
        markedUpdates = []
        hostReturnCount = 0
        lastAttributeIndex = nil
    }

    private func text(_ value: Any?) -> String {
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String ?? ""
    }

    private func replacement(_ range: NSRange) -> NSRange {
        if range.location != NSNotFound { return range }
        return mark.location == NSNotFound ? selection : mark
    }

    private func replace(_ range: NSRange, with text: String) {
        precondition(range.location >= 0 && NSMaxRange(range) <= document.utf16.count, "Invalid host replacement range: \(range)")
        document = (document as NSString).replacingCharacters(in: range, with: text)
    }

    func insertText(_ value: Any?, replacementRange range: NSRange) {
        let value = text(value)
        let target = replacement(range)
        replace(target, with: value)
        selection = NSRange(location: target.location + value.utf16.count, length: 0)
        mark = NSRange(location: NSNotFound, length: 0)
        inserted.append(value)
    }

    func setMarkedText(_ value: Any?, selectionRange selected: NSRange, replacementRange range: NSRange) {
        let value = text(value)
        let target = replacement(range)
        replace(target, with: value)
        precondition(NSMaxRange(selected) <= value.utf16.count, "Marked selection exceeds its UTF-16 text")
        mark = value.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: target.location, length: value.utf16.count)
        selection = NSRange(location: target.location + selected.location, length: selected.length)
        markedUpdates.append(value)
    }

    func receiveUnhandled(_ event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            hostReturnCount += 1
            insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        } else if let characters = event.characters, !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control && !((0xf700...0xf8ff).contains($0.value)) }),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            insertText(characters, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    func selectedRange() -> NSRange { selection }
    func markedRange() -> NSRange { mark }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= document.utf16.count else { return nil }
        return NSAttributedString(string: (document as NSString).substring(with: range))
    }
    func length() -> Int { document.utf16.count }
    func characterIndex(for point: NSPoint, tracking mode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>?) -> Int {
        inMarkedRange?.pointee = ObjCBool(mark.location != NSNotFound)
        return selection.location
    }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle: UnsafeMutablePointer<NSRect>?) -> [AnyHashable: Any]? {
        lastAttributeIndex = index
        lineHeightRectangle?.pointee = NSRect(x: 200, y: 300, width: 1, height: 20)
        return [:]
    }
    func validAttributesForMarkedText() -> [Any]? { [NSAttributedString.Key.underlineStyle] }
    func overrideKeyboard(withKeyboardNamed name: String?) {}
    func selectMode(_ identifier: String?) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String? { "com.haiwang.tests.InputMethodSmoke.client" }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { true }
    func uniqueClientIdentifierString() -> String? { uniqueID }
    func string(from range: NSRange, actualRange: NSRangePointer?) -> String? {
        guard let result = attributedSubstring(from: range)?.string else { return nil }
        actualRange?.pointee = range
        return result
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        return NSRect(x: 200, y: 300, width: 1, height: 20)
    }
}
