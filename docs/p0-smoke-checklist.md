# QuickNote P0 Smoke Checklist

- [ ] Fresh launch shows both Dock and menu-bar presence. — **UNVERIFIED:** Release launch succeeded, but status-extra presence was not safely controllable by the available harness.
- [ ] Denying keyboard monitoring leaves the menu-bar “打开便签” action usable. — **UNVERIFIED:** requires changing the user's system permission and selecting the status-extra menu.
- [ ] Two complete presses of either Command within 300ms open the panel. — **UNVERIFIED:** the harness cannot synthesize modifier-only presses.
- [ ] Command-C then Command-V does not open or close the panel. — **UNVERIFIED:** requires observing the panel while generating trusted keyboard input.
- [ ] The editor is focused without an extra click after Command open. — **UNVERIFIED:** depends on the modifier-only open path.
- [ ] A second double Command saves, hides, and restores focus to the prior app. — **UNVERIFIED:** depends on the modifier-only open/close path.
- [ ] Hovering a recent-note tick previews/opens it; typing prevents pointer exit from hiding it. — **UNVERIFIED:** requires interactive pointer and typing observation.
- [ ] Moving the pointer to another display moves the rail and opens the panel on that display. — **UNVERIFIED:** requires an interactive multi-display setup.
- [ ] Plain text and a pasted or dragged image survive hide, quit, and relaunch. — **UNVERIFIED:** requires interactive paste/drag and relaunch observation.
- [ ] Command-K finds body text in an older note and can create a new note. — **UNVERIFIED:** requires interactive editor and drawer use.
- [ ] Instruments Points of Interest or an equivalent timestamp log shows about 200ms or less from recognized double Command to first-responder editor in Release. — **UNVERIFIED:** no real modifier-only trigger was available, so no duration is claimed.
