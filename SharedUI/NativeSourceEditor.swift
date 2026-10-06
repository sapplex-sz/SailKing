import SwiftUI

/// Reports text and IME composition together; ordinary SwiftUI redraws never replace marked text.
struct NativeSourceEditor {
    let text: String
    var resetID: UInt64 = 0
    var isFocused: Binding<Bool>?
    var accessibilityID = "source-editor"
    var accessibilityLabel: String?
    var fontSize: CGFloat = 17
    var onCommittedInsertion: ((String) -> Void)?
    let onChange: (String, Bool) -> Void
}

#if os(macOS)
import AppKit

extension NativeSourceEditor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let view = CompositionTextView()
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainerInset = NSSize(width: 0, height: 8)
        view.textContainer?.lineFragmentPadding = 5
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = NSColor(OceanStyle.ink)
        view.insertionPointColor = NSColor(OceanStyle.blue)
        view.setAccessibilityLabel(accessibilityLabel ?? hw("需要翻译的原文", "Text to translate"))
        view.setAccessibilityIdentifier(accessibilityID)
        view.string = text
        view.delegate = context.coordinator
        view.onEdit = { [weak coordinator = context.coordinator] text, marked in coordinator?.parent.onChange(text, marked) }
        view.onCommittedInsertion = { [weak coordinator = context.coordinator] text in coordinator?.parent.onCommittedInsertion?(text) }
        scroll.documentView = view
        context.coordinator.lastResetID = resetID
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CompositionTextView else { return }
        context.coordinator.parent = self
        let reset = context.coordinator.lastResetID != resetID
        context.coordinator.lastResetID = resetID
        if reset || (!view.hasMarkedText() && view.string != text) {
            view.applyingModel = true
            if reset { view.unmarkText() }
            let selection = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            view.applyingModel = false
        }
        context.coordinator.updateFocus(view)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeSourceEditor
        var lastResetID: UInt64 = 0
        private var requestedFocus = false
        init(_ parent: NativeSourceEditor) { self.parent = parent }
        func updateFocus(_ view: NSTextView) {
            guard let desired = parent.isFocused?.wrappedValue else { return }
            guard desired != requestedFocus else { return }
            requestedFocus = desired
            if desired {
                DispatchQueue.main.async { [weak view] in
                    guard let view, self.parent.isFocused?.wrappedValue == true else { return }
                    view.window?.makeFirstResponder(view)
                }
            } else if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        }
        func textDidBeginEditing(_ notification: Notification) {
            requestedFocus = true
            if parent.isFocused?.wrappedValue != true { parent.isFocused?.wrappedValue = true }
        }
        func textDidEndEditing(_ notification: Notification) {
            requestedFocus = false
            if parent.isFocused?.wrappedValue == true { parent.isFocused?.wrappedValue = false }
        }
    }
}

final class CompositionTextView: NSTextView {
    var onEdit: ((String, Bool) -> Void)?
    var onCommittedInsertion: ((String) -> Void)?
    var applyingModel = false
    private var isPasting = false
    private var inputDepth = 0
    private func report() {
        guard !applyingModel, inputDepth == 0 else { return }
        onEdit?(string, hasMarkedText())
    }
    override func didChangeText() { super.didChangeText(); report() }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !applyingModel, inputDepth == 0 { onEdit?(self.string, true) }
        inputDepth += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        inputDepth -= 1
        report()
    }
    override func unmarkText() {
        inputDepth += 1
        super.unmarkText()
        inputDepth -= 1
        report()
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        inputDepth += 1
        super.insertText(insertString, replacementRange: replacementRange)
        inputDepth -= 1
        report()
        if !applyingModel && !isPasting && !hasMarkedText() {
            let inserted = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
            onCommittedInsertion?(inserted)
        }
    }
    override func paste(_ sender: Any?) {
        isPasting = true
        defer { isPasting = false }
        super.paste(sender)
    }
}
#else
import UIKit

extension NativeSourceEditor: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CompositionTextView {
        let view = CompositionTextView()
        view.font = .systemFont(ofSize: fontSize)
        view.textColor = UIColor(OceanStyle.ink)
        view.tintColor = UIColor(OceanStyle.blue)
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 5
        view.isScrollEnabled = true
        view.text = text
        view.accessibilityLabel = hw("需要翻译的原文", "Text to translate")
        view.accessibilityIdentifier = accessibilityID
        view.delegate = context.coordinator
        view.onEdit = { [weak coordinator = context.coordinator] text, marked in coordinator?.parent.onChange(text, marked) }
        context.coordinator.lastResetID = resetID
        return view
    }

    func updateUIView(_ view: CompositionTextView, context: Context) {
        context.coordinator.parent = self
        let reset = context.coordinator.lastResetID != resetID
        context.coordinator.lastResetID = resetID
        if reset || (view.markedTextRange == nil && view.text != text) {
            view.applyingModel = true
            if reset { view.unmarkText() }
            let selection = view.selectedRange
            view.text = text
            view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
            view.applyingModel = false
        }
        context.coordinator.updateFocus(view)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeSourceEditor
        var lastResetID: UInt64 = 0
        private var requestedFocus = false
        init(_ parent: NativeSourceEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { (textView as? CompositionTextView)?.report() }
        func textViewDidChangeSelection(_ textView: UITextView) { (textView as? CompositionTextView)?.report() }
        func updateFocus(_ view: UITextView) {
            guard let desired = parent.isFocused?.wrappedValue, desired != requestedFocus else { return }
            requestedFocus = desired
            if desired {
                DispatchQueue.main.async { [weak view] in
                    guard self.parent.isFocused?.wrappedValue == true else { return }
                    view?.becomeFirstResponder()
                }
            } else if view.isFirstResponder { view.resignFirstResponder() }
        }
        func textViewDidBeginEditing(_ textView: UITextView) {
            requestedFocus = true
            if parent.isFocused?.wrappedValue != true { parent.isFocused?.wrappedValue = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            requestedFocus = false
            if parent.isFocused?.wrappedValue == true { parent.isFocused?.wrappedValue = false }
        }
    }
}

final class CompositionTextView: UITextView {
    var onEdit: ((String, Bool) -> Void)?
    var applyingModel = false
    private var inputDepth = 0
    func report() {
        guard !applyingModel, inputDepth == 0 else { return }
        onEdit?(text ?? "", markedTextRange != nil)
    }
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if !applyingModel, inputDepth == 0 { onEdit?(text ?? "", true) }
        inputDepth += 1
        super.setMarkedText(markedText, selectedRange: selectedRange)
        inputDepth -= 1
        report()
    }
    override func unmarkText() {
        inputDepth += 1
        super.unmarkText()
        inputDepth -= 1
        report()
    }
    override func insertText(_ text: String) {
        inputDepth += 1
        super.insertText(text)
        inputDepth -= 1
        report()
    }
    override func deleteBackward() {
        inputDepth += 1
        super.deleteBackward()
        inputDepth -= 1
        report()
    }
}
#endif
