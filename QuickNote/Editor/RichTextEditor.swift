import AppKit
import SwiftUI

struct RichTextEditor: NSViewRepresentable {
    let document: NSAttributedString
    let cursorLocation: Int
    let onChange: (NSAttributedString, Int) -> Void
    let onActivate: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.isAutomaticTextCompletionEnabled = false
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.delegate = context.coordinator
        textView.textStorage?.setAttributedString(document)
        textView.setSelectedRange(NSRange(location: clampedCursorLocation, length: 0))
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.owner = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if !textView.attributedString().isEqual(to: document) {
            textView.textStorage?.setAttributedString(document)
        }
        if textView.selectedRange().location != clampedCursorLocation {
            textView.setSelectedRange(NSRange(location: clampedCursorLocation, length: 0))
        }
    }

    private var clampedCursorLocation: Int {
        min(max(cursorLocation, 0), document.length)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: RichTextEditor

        init(owner: RichTextEditor) { self.owner = owner }

        func textDidBeginEditing(_ notification: Notification) {
            owner.onActivate()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            owner.onChange(textView.attributedString(), textView.selectedRange().location)
        }
    }
}
