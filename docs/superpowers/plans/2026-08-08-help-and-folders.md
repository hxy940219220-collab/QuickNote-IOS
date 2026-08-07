# QuickNote Help and Folders Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Add persistent, expandable single-level note folders and replace the verbose help popover with concise shortcut guidance.

**Architecture:** Add a standalone SwiftData NoteFolder model and store its UUID as an optional scalar on NoteRecord; NoteRepository owns validation and folder mutations. RootNoteView reloads notes and folders after mutations, while NoteDrawerView owns transient expansion and editor presentation state.

**Tech Stack:** Swift 5.10, SwiftUI, SwiftData, AppKit, XCTest, XcodeGen.

## Global Constraints

- Folders are single-level and may be empty; one note belongs to at most one folder.
- Deleting a folder moves its notes to “未分类” and never deletes note documents.
- Use native DisclosureGroup, Menu, sheet/form controls, and SF Symbols; add no dependency.
- Preserve existing tags, pinning, search, audio, and first-line title behavior.
- Do not modify docs/p0-smoke-checklist.md.

---

### Task 1: Persistent folder lifecycle

**Files:**
- Modify: QuickNote/Storage/NoteRecord.swift:4-31
- Modify: QuickNote/Storage/NoteRepository.swift:4-43
- Modify: QuickNoteTests/NoteRepositoryTests.swift:1-45

**Interfaces:**
- Produces: NoteFolder, FolderNameError, allFolders(), createFolder(named:), rename(_:to:), move(_:to:), and delete(_ folder:).
- Preserves: existing delete(_ note:), allNotes(), search, and save APIs.

- [ ] **Step 1: Write failing lifecycle and validation tests**

Add an in-memory container containing both models and tests that exercise every new repository API:

    private func makeRepository() throws -> (ModelContainer, NoteRepository) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: NoteRecord.self,
            NoteFolder.self,
            configurations: configuration
        )
        return (container, NoteRepository(context: container.mainContext))
    }

    func testFolderLifecyclePreservesNotesWhenFolderIsDeleted() throws {
        let (_, repository) = try makeRepository()
        let folder = try repository.createFolder(named: " 工作 ")
        let note = repository.createNote()
        repository.move(note, to: folder)
        try repository.rename(folder, to: "项目")
        try repository.save()

        XCTAssertEqual(try repository.allFolders().map(\.name), ["项目"])
        XCTAssertEqual(note.folderID, folder.id)

        try repository.delete(folder)
        try repository.save()

        XCTAssertTrue(try repository.allFolders().isEmpty)
        XCTAssertEqual(try repository.allNotes().map(\.id), [note.id])
        XCTAssertNil(note.folderID)
    }

    func testFolderNamesMustBeNonEmptyAndUnique() throws {
        let (_, repository) = try makeRepository()
        _ = try repository.createFolder(named: "Work")

        XCTAssertThrowsError(try repository.createFolder(named: "  ")) {
            XCTAssertEqual($0 as? FolderNameError, .empty)
        }
        XCTAssertThrowsError(try repository.createFolder(named: " work ")) {
            XCTAssertEqual($0 as? FolderNameError, .duplicate)
        }
    }

- [ ] **Step 2: Run the focused tests and confirm RED**

Run:

    cd /Users/xixi/Documents/idea/.worktrees/quick-note-p0/quick-note-mac
    xcodegen generate
    xcodebuild test -project QuickNote.xcodeproj -scheme QuickNote \
      -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath /tmp/QuickNoteDerived CODE_SIGNING_ALLOWED=NO \
      -only-testing:QuickNoteTests/NoteRepositoryTests

Expected: compile failure because NoteFolder, FolderNameError, and the folder repository methods do not exist.

- [ ] **Step 3: Add the minimal models and repository methods**

Add folderID to NoteRecord and define the independent model in NoteRecord.swift:

    var folderID: UUID? = nil

    @Model
    final class NoteFolder {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date

        init(id: UUID = UUID(), name: String, now: Date = .now) {
            self.id = id
            self.name = name
            createdAt = now
        }
    }

Add FolderNameError and repository methods. validatedFolderName trims names and rejects case-insensitive duplicates, excluding the folder being renamed:

    func allFolders() throws -> [NoteFolder]
    func createFolder(named rawName: String) throws -> NoteFolder
    func rename(_ folder: NoteFolder, to rawName: String) throws
    func move(_ note: NoteRecord, to folder: NoteFolder?)
    func delete(_ folder: NoteFolder) throws

delete(_ folder:) loops through allNotes() where folderID matches, sets folderID to nil, then deletes the folder from the context.

- [ ] **Step 4: Run the focused tests and confirm GREEN**

Run the Step 2 command again. Expected: NoteRepositoryTests passes with zero failures.

- [ ] **Step 5: Commit the data slice**

    git add quick-note-mac/QuickNote/Storage/NoteRecord.swift \
      quick-note-mac/QuickNote/Storage/NoteRepository.swift \
      quick-note-mac/QuickNoteTests/NoteRepositoryTests.swift
    git commit -m "feat: add persistent note folders"

---

### Task 2: Expandable folder drawer

**Files:**
- Modify: QuickNote/App/AppDelegate.swift:30-65
- Modify: QuickNote/Views/RootNoteView.swift:4-178
- Modify: QuickNote/Views/NoteDrawerView.swift:3-116

**Interfaces:**
- Consumes: all Task 1 repository APIs.
- Produces: drawer callbacks for folder create, rename, delete, and note movement; no new global type.

- [ ] **Step 1: Wire both models and repository closures into the root view**

Change the container:

    let container = try ModelContainer(for: NoteRecord.self, NoteFolder.self)

Add these RootNoteView inputs:

    let allFolders: () throws -> [NoteFolder]
    let createFolder: (String) throws -> Void
    let renameFolder: (NoteFolder, String) throws -> Void
    let deleteFolder: (NoteFolder) throws -> Void
    let moveNote: (NoteRecord, NoteFolder?) throws -> Void

AppDelegate passes closures that call the corresponding repository method and repository.save(). RootNoteView stores folders in state and uses one reload helper after mutations:

    private func reloadLibrary() {
        do {
            notes = try allNotes()
            folders = try allFolders()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

- [ ] **Step 2: Replace the flat list with native grouped content**

Update NoteDrawerView with folders and the four mutation callbacks. Add:

    @State private var expandedFolders = Set<UUID>()

When search is empty, render one DisclosureGroup per folder and a “未分类” section:

    DisclosureGroup(isExpanded: expansionBinding(for: folder)) {
        ForEach(notes.filter { $0.folderID == folder.id }) { note in
            noteRow(note).padding(.leading, 12)
        }
    } label: {
        folderRow(folder)
    }

    Section("未分类") {
        ForEach(notes.filter { $0.folderID == nil }) { note in
            noteRow(note)
        }
    }

When search is active, render matching notes as one flat list. Reuse one noteRow helper so selection, pinning, movement, and deletion are identical in each location.

The empty-state check must consider both folders and notes, so an empty folder remains visible even when there are no notes.

Add folder.badge.plus next to the compose button. The note menu contains a native “移动到文件夹” submenu listing “未分类” and all folders. The folder menu provides rename and destructive delete.

- [ ] **Step 3: Keep invalid folder input open**

Present a small sheet backed by local name and error state. Disable saving when trimmed input is empty; only dismiss after the throwing callback succeeds:

    private func submitFolderName() {
        do {
            try save(name)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

Folder deletion confirmation uses the exact copy: 文件夹中的便签会移到“未分类”，不会被删除。

- [ ] **Step 4: Build the app to validate SwiftUI composition**

Run:

    cd /Users/xixi/Documents/idea/.worktrees/quick-note-p0/quick-note-mac
    xcodegen generate
    xcodebuild build -project QuickNote.xcodeproj -scheme QuickNote \
      -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath /tmp/QuickNoteDerived CODE_SIGNING_ALLOWED=NO

Expected: BUILD SUCCEEDED with no Swift compiler errors.

- [ ] **Step 5: Commit the UI slice**

    git add quick-note-mac/QuickNote/App/AppDelegate.swift \
      quick-note-mac/QuickNote/Views/RootNoteView.swift \
      quick-note-mac/QuickNote/Views/NoteDrawerView.swift
    git commit -m "feat: add expandable folder drawer"

---

### Task 3: Concise help popover

**Files:**
- Modify: QuickNote/Views/RootNoteView.swift:584-671

**Interfaces:**
- Preserves: existing System Settings URL behavior.
- Produces: compact QuickNoteHelpView with two shortcut rows and one API security sentence.

- [ ] **Step 1: Replace verbose copy with compact native rows**

Remove the ScrollView, numbered circles, and long permission details. Keep the two settings actions:

    shortcutSection(
        shortcut: "双击 Command",
        detail: "快速打开或收起 QuickNote",
        path: "隐私与安全性 → 输入监控",
        button: "打开输入监控",
        settingsPane: "Privacy_ListenEvent"
    )

    shortcutSection(
        shortcut: "Option + 空格",
        detail: "分析当前选中的文字",
        path: "隐私与安全性 → 辅助功能",
        button: "打开辅助功能",
        settingsPane: "Privacy_Accessibility"
    )

Use the exact API copy:

    Text("API Key 仅保存在这台 Mac 的系统钥匙串中；AI 内容只发送给当前服务商。")

Set a compact fixed width near 350 points and let intrinsic content determine height.

- [ ] **Step 2: Build after the help-only change**

Run the Task 2 Step 4 build command. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit the help slice**

    git add quick-note-mac/QuickNote/Views/RootNoteView.swift
    git commit -m "refactor: simplify shortcut help"

---

### Task 4: Full verification and installation

**Files:**
- Verify only; do not edit docs/p0-smoke-checklist.md.

**Interfaces:**
- Consumes: all changes from Tasks 1-3.
- Produces: tested, signed Release app installed at /Applications/QuickNote.app.

- [ ] **Step 1: Run the project verification script**

    cd /Users/xixi/Documents/idea/.worktrees/quick-note-p0/quick-note-mac
    ./scripts/verify-p0.sh

Expected: all XCTest cases pass, Release build succeeds, and codesign verification exits 0.

- [ ] **Step 2: Inspect the exact diff and working tree**

    git diff --check
    git status --short
    git diff --stat

Expected: no whitespace errors; pre-existing audio/title changes and the user-owned smoke checklist remain present and untouched.

- [ ] **Step 3: Install the verified Release build**

    ditto /tmp/QuickNoteDerived/Build/Products/Release/QuickNote.app /Applications/QuickNote.app
    codesign --verify --deep --strict --verbose=2 /Applications/QuickNote.app

Expected: installation and signature verification exit 0.

- [ ] **Step 4: Compare built and installed executables**

    shasum -a 256 \
      /tmp/QuickNoteDerived/Build/Products/Release/QuickNote.app/Contents/MacOS/QuickNote \
      /Applications/QuickNote.app/Contents/MacOS/QuickNote

Expected: both SHA-256 hashes are identical.
