# Folder Drawer Row Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the note drawer match the approved clean Codex-style hierarchy: the whole folder row toggles, ordinary row dividers disappear, and only one full-width divider may separate unfiled notes.

**Architecture:** Keep the existing `List` and transient `expandedFolders` state. Replace `DisclosureGroup` with one custom folder row plus conditionally rendered child notes, using native SwiftUI buttons and row-separator controls.

**Tech Stack:** SwiftUI, Swift 5.10, macOS.

## Global Constraints

- Preserve folder menus, note menus, selected-note background, search, and automatic expansion of the selected note's folder.
- The trailing folder menu must stay independent from the folder toggle action.
- Add no dependency or new abstraction.
- Do not modify `docs/p0-smoke-checklist.md`.

---

### Task 1: Polish folder list rows

**Files:**
- Modify: `QuickNote/Views/NoteDrawerView.swift`

- [x] Replace each `DisclosureGroup` with `folderRow(folder)` and conditionally render its notes when `expandedFolders` contains the folder ID.
- [x] Put the chevron, folder icon, name, and count in one plain button whose full content rectangle toggles expansion; keep the ellipsis `Menu` outside that button.
- [x] Hide native list-row separators for folder rows, note rows, search rows, and the “未分类” label.
- [x] Replace the unfiled `Section` with direct rows and add one explicit full-width `Divider` only when both folders and unfiled notes exist.
- [x] Build the app, run `./scripts/verify-p0.sh`, and confirm the existing test suite passes.
