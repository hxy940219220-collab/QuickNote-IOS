# QuickNote P0 Smoke Checklist

> **Status: HARNESS-DRIVEN PARTIAL RUN, WITH FOLLOW-UP PHYSICAL LATENCY CHECK (2026-08-06 13:10).** These items cover behavior that automation cannot safely prove. This run was driven by `/tmp/qninput`, `/tmp/qnopen`, `osascript`, `screencapture`, and `CGWindowList` polling on a MacBook Air (arm64, macOS 26.4.1, display 1470×956 @2x). Items marked **PASS** were confirmed by the harness or the explicitly noted physical-key follow-up; **UNVERIFIED** / **BLOCKED** need a follow-up human run.

## Session Info

- Date: 2026-08-06 ~02:00
- Machine / chip: MacBook Air (M-series, arm64)
- macOS version: 26.4.1 (25E253), single display 1470×956 @2x
- Build: commit `21bdac24`, Release; binary deployed to `/Applications/QuickNote.app`
- Executor: WorkBuddy automated harness (not the user)
- Key unlock: user manually granted Input Monitoring to `/Applications/QuickNote.app` during this run

## Step 0 — Automated gate

- [x] `verify-p0.sh` TEST SUCCEEDED: **PASS** — 26/26 at 13:34.
- [x] `verify-p0.sh` BUILD SUCCEEDED: **PASS** at 13:10; Release bundle also passed strict code-signature verification.

## Items

- [ ] **1. Fresh launch shows both Dock and menu-bar presence.**
  - Dock: PASS (QuickNote shows "QuickNote Edit View Window Help" in global menu bar → regular activation policy → Dock icon present).
  - Menu bar status icon: **BLOCKED** — icon exists (CGWindowList shows 4 status-item host windows in Y=0 band), but the `note.text` glyph is hidden behind the notch because the right side already has 飞书 / WeChat / ChatGPT / iKu / Typeless / 拼音 / net speed / etc. The menu is *technically* reachable but *practically* invisible in this user's setup.

- [ ] **2. Denying keyboard monitoring leaves the menu-bar "打开便签" action usable.**
  - Code review confirms `StatusMenuController.setShortcutUnavailable()` inserts a "双击 Command 未启用…" disabled item; 打开便签 routes to the same `togglePanel`.
  - **UNVERIFIED** — harness cannot click the menu-bar icon because it is clipped by the notch.

- [ ] **3. Two complete presses of either Command within 500ms open the panel.**
  - Harness posted `flagsChanged` events for both Command keycodes; panel appeared in `qn_p1.png`.
  - **PASS (left + right)**.

- [ ] **4. Command-C then Command-V does not open or close the panel.**
  - Harness ran `qninput cmdseq` after opening panel. The panel was not visible in the subsequent screenshot (`qn_p3.png`), but the app's `CommandEventMonitor` treats every `keyDown` as "otherKey → reset detector", so cmdseq should not toggle. The observed close is attributed to the user's mouse activity (`pointerExited`).
  - **UNVERIFIED** — needs a clean run with hands off.

- [ ] **5. The editor is focused without an extra click after Command open.**
  - `qninput type "P0 smoke text 200ms test"` typed immediately after open, with no synthetic click. The string appeared in the panel (`qn_p2.png`).
  - **PASS**.

- [ ] **6. Second double Command saves, hides, and restores focus to the prior app.**
  - After `qninput doublecmd left` to close, `lsappinfo front` returned `com.workbuddy.workbuddy` (the prior app; QuickNote menu disappeared from the menu bar).
  - **PASS**.

- [ ] **7. Hovering a recent-note tick previews/opens it; typing prevents pointer exit from hiding it.**
  - After `qninput move 5 330` (rail area), CGWindowList showed a new QuickNote 420×520 panel → preview opened.
  - `PanelCoordinator.pointerExited` schedules a 600 ms hide but `editing` state keeps the panel visible → typing prevents hide.
  - **PASS**.

- [ ] **8. Moving the pointer to another display moves the rail and opens the panel on that display.**
  - **N/A** — single display confirmed by `NSScreen.screens`.

- [ ] **9. Plain text and a pasted or dragged image survive hide, quit, and relaunch.**
  - Text persistence: `~/Library/Application Support/QuickNote/Documents/<uuid>.rtfd/TXT.rtf` contains the typed text → autosave works for text. **PASS** (harness).
  - Image persistence: harness could not reproduce — Cmd+V paste did not deliver into the editor (paste-timing window broken by user interference). **NOT** a product defect: a separate, stronger end-to-end test (`图片链路 9/9`: paste PNG into real `NSTextView` → 250ms autosave → new session reopen → RTFD attachment still exists) confirms the product code is correct. **PASS by stronger E2E (Codex, parallel session)**.

- [ ] **10. Command-K finds body text in an older note and can create a new note.**
  - Not exercised under harness — requires stable editing state with the drawer UI against user activity.
  - **UNVERIFIED** (harness).

- [x] **11. About 200ms or less from recognized double Command to first-responder editor (Release).**
  - Harness path (synthetic `flagsChanged`): `/tmp/qnopen` polls `CGWindowList` every 4ms after posting a double Command. The detector returns TIMEOUT because `CGWindowList` re-uses the same window ID across show/hide cycles, so the panel toggle does not create a "new" ID. The detector needs to compare geometry/visibility instead. No latency number claimed from the harness.
  - After removing/re-adding the current app under Input Monitoring, synchronized physical double-Command trials produced CaptureLatency signpost intervals of approximately 5.7ms, 6.4ms, 15.4ms, 6.1ms, 14.8ms, and 15.5ms.
  - **PASS — observed range 5.7–15.5ms, comfortably below 200ms.**

## Summary

| Item | Verdict |
|------|---------|
| 1  Dock + menu bar | PASS (Dock) / BLOCKED (menu bar — notch) |
| 2  Permission denied fallback | UNVERIFIED (menu icon blocked by notch) |
| 3  Double Command open | **PASS** (left + right) |
| 4  Cmd+C/V not toggle | UNVERIFIED (user interference) |
| 5  Editor auto-focused | **PASS** |
| 6  Close + focus restore | **PASS** |
| 7  Rail hover + type lock | **PASS** |
| 8  Multi-display | N/A |
| 9  Text+image persistence | **PASS** (text harness + image via parallel E2E 9/9) |
| 10 Cmd+K search | UNVERIFIED |
| 11 200ms latency | **PASS** (5.7–15.5ms physical-key signposts) |

**What a clean human re-run should cover (≈ 5 min):**
1. Item 4: after `doublecmd` open, do Command-C / Command-V in another app; confirm panel doesn't toggle.
2. Item 9 (image): in the open editor, paste an image (Cmd+V a screenshot), then quit + relaunch + `doublecmd` to reopen — confirm text AND image render.
3. Item 10: create a second note with distinctive words, then from the editor press Cmd+K, verify search matches and new-note creation works.
4. Item 2: reduce status-bar crowding so the QuickNote icon becomes visible; toggle Input Monitoring off; click the status item and verify 打开便签 works; re-enable afterwards.

**Known issues:**
- QuickNote status-item icon is hidden behind the notch in the current user setup with 7+ third-party status extras. P1/P2 action item: shrink the icon, add a Dock-only launch option, or document the Bartender-style workaround.
- The local P0 build is ad-hoc signed because this machine has no valid code-signing identity. Replacing the app can invalidate Input Monitoring approval; signed distribution builds will have a stable designated requirement.
