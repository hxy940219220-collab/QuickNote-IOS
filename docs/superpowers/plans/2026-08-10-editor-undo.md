# Editor Undo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a toolbar undo action that restores the latest text or rich-text formatting edit through the native AppKit undo chain.

**Architecture:** Keep `NSTextView` as the single undo owner. `RichTextEditorController` exposes undo state/action and registers full attributed-document snapshots only for existing programmatic editor commands that bypass AppKit's automatic typing undo; `RootNoteView` renders the button and clears history after a successful note switch.

**Tech Stack:** SwiftUI, AppKit `NSTextView`/`NSUndoManager`, XCTest, Xcode.

## Global Constraints

- `Command + Z` and the toolbar button must share one native undo history.
- One programmatic formatting command is one undo step.
- Undo restores attributed content and selection.
- No cross-relaunch version history or new dependency.
- Existing uncommitted audio and default-title work must be preserved.

---

### Task 1: Native editor undo

**Files:**
- Modify: `quick-note-mac/QuickNoteTests/AppShellTests.swift`
- Modify: `quick-note-mac/QuickNote/Editor/RichTextEditor.swift`
- Modify: `quick-note-mac/QuickNote/Views/RootNoteView.swift`

**Interfaces:**
- Consumes: `RichTextEditorController.connect(_:)`, existing editor formatting commands, `NSTextView.undoManager`.
- Produces: `RichTextEditorController.canUndo: Bool`, `undo()`, `clearUndoHistory()`, and internal snapshot registration for programmatic edits.

- [ ] **Step 1: Write failing tests for text and format undo**

Add two `@MainActor` tests to `AppShellTests`:

```swift
func testEditorUndoRestoresLatestTextEdit() throws {
    let controller = RichTextEditorController()
    let textView = NSTextView()
    textView.allowsUndo = true
    controller.connect(textView)

    textView.insertText("内容", replacementRange: textView.selectedRange())
    controller.refreshUndoAvailability()
    XCTAssertTrue(controller.canUndo)
    controller.undo()

    XCTAssertEqual(textView.string, "")
}

func testEditorUndoRestoresLatestFormattingEditAndSelection() throws {
    let controller = RichTextEditorController()
    let textView = NSTextView()
    textView.allowsUndo = true
    textView.textStorage?.setAttributedString(NSAttributedString(
        string: "标题",
        attributes: [.font: NSFont.systemFont(ofSize: 15)]
    ))
    textView.undoManager?.removeAllActions()
    textView.setSelectedRange(NSRange(location: 0, length: 2))
    controller.connect(textView)

    controller.toggleBold()
    XCTAssertTrue(controller.canUndo)
    controller.undo()

    let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 2))
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
xcodebuild test -project QuickNote.xcodeproj -scheme QuickNote -destination 'platform=macOS' -only-testing:QuickNoteTests/AppShellTests/testEditorUndoRestoresLatestTextEdit -only-testing:QuickNoteTests/AppShellTests/testEditorUndoRestoresLatestFormattingEditAndSelection
```

Expected: compilation fails because `canUndo` and `undo()` do not exist.

- [ ] **Step 3: Add the minimal native undo bridge**

In `RichTextEditorController`, add published availability, `undo()`, `clearUndoHistory()`, and a private snapshot registrar. The undo closure captures the current attributed document before restoring the previous one so `NSUndoManager` automatically builds redo:

```swift
@Published private(set) var canUndo = false

func undo() {
    textView?.undoManager?.undo()
    refreshUndoAvailability()
}

func clearUndoHistory() {
    textView?.undoManager?.removeAllActions()
    refreshUndoAvailability()
}

func refreshUndoAvailability() {
    canUndo = textView?.undoManager?.canUndo == true
}

private func registerUndoSnapshot(in textView: NSTextView) {
    let document = NSAttributedString(attributedString: textView.attributedString())
    let selection = textView.selectedRange()
    textView.undoManager?.registerUndo(withTarget: self) { [weak textView] controller in
        guard let textView else { return }
        controller.registerUndoSnapshot(in: textView)
        controller.stopAudioAttachments(in: textView)
        textView.textStorage?.setAttributedString(document)
        controller.commit(textView, preserving: selection)
    }
    textView.undoManager?.setActionName("编辑")
    refreshUndoAvailability()
}
```

Call `registerUndoSnapshot(in:)` immediately before mutation in `applyTextStyle`, `insertBodyParagraphAfterTitle`, `applyTextColor`, `applyBackgroundColor`, `applyAlignment`, `changeIndent`, `applyLineHeightMultiple`, `continueListAfterNewline`, `insertChecklistItem`, `toggleChecklistItem`, `applyList`, `applyBlockQuote`, `deleteCurrentTable`, `toggleFontTrait`, `toggleDecoration`, and `replaceSelection`. Tables and files are covered by their existing `replaceSelection` path. Do not register normalization work such as link detection or attachment view preparation. In the coordinator's `textDidChange`, call `refreshUndoAvailability()` after forwarding the document change.

In `RootNoteView`, add the disabled undo button before “格式”:

```swift
toolbarButton("撤回", systemImage: "arrow.uturn.backward", action: editorController.undo)
    .disabled(!editorController.canUndo)
```

After a successful `openRecovering`, `createAndOpenRecovering`, or deletion that replaces the current note, call `editorController.clearUndoHistory()` so an old note cannot be restored into the new one.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command again.

Expected: both tests pass.

- [ ] **Step 5: Run proportional project verification**

Run:

```bash
./scripts/verify-p0.sh
```

Expected: all tests pass, universal Release build and code-sign verification succeed.

- [ ] **Step 6: Commit implementation**

```bash
git add quick-note-mac/QuickNoteTests/AppShellTests.swift quick-note-mac/QuickNote/Editor/RichTextEditor.swift quick-note-mac/QuickNote/Views/RootNoteView.swift quick-note-mac/docs/superpowers/plans/2026-08-10-editor-undo.md
git commit -m "feat: add editor undo control"
```
