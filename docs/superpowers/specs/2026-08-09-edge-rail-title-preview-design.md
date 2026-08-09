# Edge Rail Title Preview Design

## Goal

Turn the compact screen-edge rail into a quiet note navigator. Hovering a rail mark previews only that note's title; opening the full note requires an explicit click.

## Interaction

- Keep the existing narrow vertical pill and one dark mark per recent note.
- Give every mark a forgiving row-sized hover and click target while preserving its small visual size.
- Hovering a mark immediately shows a compact, single-line title bubble to the right of the rail.
- Moving between marks updates the bubble in place. Leaving the active mark hides it.
- Hover never changes the selected note, session state, application focus, or note-panel visibility.
- Clicking a mark hides the title bubble, opens that note, activates QuickNote, and places the panel in editing state.
- Pinned-note styling and the existing recent-note ordering remain unchanged.

## Visual Treatment

- The title bubble uses the macOS system font at a compact label size.
- Use an opaque native control background, subtle separator stroke, small continuous corner radius, and restrained shadow.
- Show only the note title. Do not include timestamps, body excerpts, icons, or extra metadata.
- Truncate long titles to one line at a practical maximum width.
- The bubble appears beside the rail without resizing the rail or creating a large transparent hit region over other apps.

## Architecture

- `EdgeRailView` renders each mark as a plain button and emits separate preview and selection callbacks.
- `EdgeRailController` owns a second borderless, nonactivating, mouse-ignoring `NSPanel` for the title bubble. It positions the bubble beside the rail and near the current pointer.
- `AppDelegate` maps selection to a dedicated `PanelCoordinator.select(note:)` path.
- `PanelStateMachine` receives a selection event that always enters editing state for the requested note.
- The old rail hover callback is no longer wired to `PanelCoordinator.hover(note:)`, so hovering cannot open the full note panel.

## Accessibility and Motion

- Each mark exposes the note title as its accessibility label and a button role.
- The expanded hit target must be materially larger than the visible 3-point mark.
- The title bubble does not accept keyboard focus or mouse events.
- Use only a short opacity transition when Reduce Motion is off; otherwise update without animation.

## Verification

- Add a focused state-machine test proving rail selection enters editing state for the requested note, including when another note was already active.
- Build and run the complete QuickNote test suite.
- Verify manually that hovering each mark changes only the title bubble, while clicking opens the matching note.

## Out of Scope

- Body previews, timestamps, note actions, drag and drop, scrolling the rail, and folder indicators.
- Changing the number or ordering of recent notes shown in the rail.

