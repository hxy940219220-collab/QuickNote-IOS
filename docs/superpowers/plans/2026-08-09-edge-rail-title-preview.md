# Edge Rail Title Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make each screen-edge rail mark preview only its note title on hover and open the corresponding note only after an explicit click.

**Architecture:** `EdgeRailView` becomes a row of forgiving plain buttons with separate preview and selection callbacks. `EdgeRailController` owns a compact nonactivating title panel, while `PanelCoordinator` and `PanelStateMachine` provide an explicit selection path that always opens the requested note in editing state.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, macOS 14+.

## Global Constraints

- Keep the rail 18 points wide and preserve current recent-note ordering, eight-note limit, and pinned styling.
- Hover must not change the selected note, session state, application focus, or main panel visibility.
- The title panel must ignore mouse events and keyboard focus.
- Show only a single-line truncated title; no timestamp, body preview, icon, folder, or actions.
- Add no dependency and do not modify `docs/p0-smoke-checklist.md`.

---

### Task 1: Explicit rail selection state

**Files:**
- Modify: `QuickNote/Panel/PanelStateMachine.swift`
- Modify: `QuickNote/Panel/PanelCoordinator.swift`
- Test: `QuickNoteTests/PanelStateMachineTests.swift`

**Interfaces:**
- Produces: `PanelStateMachine.Event.select(noteID: UUID)` and `PanelCoordinator.select(note: NoteRecord) throws`.
- Preserves: command toggling, editor activation, dismissal, and existing transient-state behavior.

- [ ] **Step 1: Write the failing selection test**

Add:

```swift
func testRailSelectionReplacesTheActiveNoteAndStaysEditing() {
    let firstID = UUID()
    let secondID = UUID()
    var machine = PanelStateMachine()
    machine.send(.toggleCommand(noteID: firstID))

    machine.send(.select(noteID: secondID))

    XCTAssertEqual(machine.state, .editing(secondID))
}
```

- [ ] **Step 2: Run the focused test and confirm RED**

Run:

```bash
xcodebuild test -project QuickNote.xcodeproj -scheme QuickNote \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/QuickNoteDerived CODE_SIGNING_ALLOWED=NO \
  -only-testing:QuickNoteTests/PanelStateMachineTests/testRailSelectionReplacesTheActiveNoteAndStaysEditing
```

Expected: compilation fails because `PanelStateMachine.Event.select` does not exist.

- [ ] **Step 3: Add the minimal selection event and coordinator path**

Add the event and make it override every prior state:

```swift
case select(noteID: UUID)

case (_, let .select(id)):
    state = .editing(id)
```

Add to `PanelCoordinator`:

```swift
func select(note: NoteRecord) throws {
    dismissTask?.cancel()
    machine.send(.select(noteID: note.id))
    try render(note: note, activate: true)
}
```

- [ ] **Step 4: Run the focused test and confirm GREEN**

Run the Step 2 command again. Expected: the focused test passes with zero failures.

- [ ] **Step 5: Commit the selection slice**

```bash
git add QuickNote/Panel/PanelStateMachine.swift \
  QuickNote/Panel/PanelCoordinator.swift \
  QuickNoteTests/PanelStateMachineTests.swift
git commit -m "feat: add explicit edge rail selection"
```

---

### Task 2: Immediate title preview and click target

**Files:**
- Modify: `QuickNote/Views/EdgeRailView.swift`
- Modify: `QuickNote/Panel/EdgeRailController.swift`
- Modify: `QuickNote/App/AppDelegate.swift`
- Test: `QuickNoteTests/NotePanelControllerTests.swift`

**Interfaces:**
- Consumes: `PanelCoordinator.select(note:)` from Task 1.
- Produces: `EdgeRailView.preview: (NoteRecord?) -> Void`, `EdgeRailView.select: (NoteRecord) -> Void`, `EdgeRailController.onSelect`, and `EdgeRailController.previewFrame(...)`.

- [ ] **Step 1: Write the failing preview-position test**

Add:

```swift
func testEdgeRailPreviewFrameStaysBesideRailAndInsideScreen() {
    let frame = EdgeRailController.previewFrame(
        beside: NSRect(x: 4, y: 420, width: 18, height: 60),
        pointerY: 899,
        contentSize: NSSize(width: 120, height: 26),
        in: NSRect(x: 0, y: 0, width: 1_440, height: 900)
    )

    XCTAssertEqual(frame, NSRect(x: 30, y: 874, width: 120, height: 26))
}
```

- [ ] **Step 2: Run the focused test and confirm RED**

Run:

```bash
xcodebuild test -project QuickNote.xcodeproj -scheme QuickNote \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/QuickNoteDerived CODE_SIGNING_ALLOWED=NO \
  -only-testing:QuickNoteTests/NotePanelControllerTests/testEdgeRailPreviewFrameStaysBesideRailAndInsideScreen
```

Expected: compilation fails because `EdgeRailController.previewFrame` does not exist.

- [ ] **Step 3: Convert marks into forgiving preview/select buttons**

Replace the capsule-only hover behavior with a plain button per note:

```swift
Button {
    select(note)
} label: {
    Capsule()
        .fill(note.isPinned ? Color.primary : Color.secondary.opacity(0.45))
        .frame(width: note.isPinned ? 10 : 8, height: 3)
        .frame(width: 18, height: 16)
        .contentShape(Rectangle())
}
.buttonStyle(.plain)
.accessibilityLabel(note.title)
.onHover { preview($0 ? note : nil) }
```

Use `VStack(spacing: 0)` so the larger hit regions replace the old visual gap without introducing extra spacing.

- [ ] **Step 4: Add the nonactivating title panel**

In `EdgeRailController`, replace hover scheduling callbacks with `onSelect`, configure a second borderless panel with `ignoresMouseEvents = true`, and show/hide it from the preview callback. Position it with:

```swift
static func previewFrame(
    beside railFrame: NSRect,
    pointerY: CGFloat,
    contentSize: NSSize,
    in visibleFrame: NSRect
) -> NSRect {
    NSRect(
        x: min(railFrame.maxX + 8, visibleFrame.maxX - contentSize.width),
        y: min(
            max(pointerY - contentSize.height / 2, visibleFrame.minY),
            visibleFrame.maxY - contentSize.height
        ),
        width: contentSize.width,
        height: contentSize.height
    )
}
```

Render one system-font title with a 180-point maximum width, native control background, separator stroke, continuous 6-point radius, and one-line truncation. Fade only panel opacity for 120ms when Reduce Motion is off; cancel stale hide completions when another mark is entered.

- [ ] **Step 5: Wire click selection and remove hover opening**

Replace the two AppDelegate rail hover callbacks with:

```swift
rail.onSelect = { note in try? coordinator.select(note: note) }
```

The rail no longer calls `PanelCoordinator.hover(note:)` or `pointerExited()`.

- [ ] **Step 6: Run the focused preview test and confirm GREEN**

Run the Step 2 command again. Expected: the focused test passes with zero failures.

- [ ] **Step 7: Run complete verification**

Run:

```bash
./scripts/verify-p0.sh
```

Expected: all tests pass; the universal Release build and ad-hoc signature verification succeed.

- [ ] **Step 8: Commit the rail UI slice**

```bash
git add QuickNote/Views/EdgeRailView.swift \
  QuickNote/Panel/EdgeRailController.swift \
  QuickNote/App/AppDelegate.swift \
  QuickNoteTests/NotePanelControllerTests.swift
git commit -m "feat: preview edge rail note titles"
```

