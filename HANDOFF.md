# Handoff

Status of the desktop-pet project as of 2026-10-12, for picking up in a fresh
session. The README covers usage; this file covers decisions, state, and what
to do next.

## What this is

The repo is github.com/rajeshpillai/mindful-pets; the local folder was
once named "jarvis-bot", an old code name. The project is a desktop pet: a pixel-art
cat that lives along the bottom of the screen, wanders, naps, chases the
cursor, and reacts to events sent through a named pipe. Written in Zig
(master, 0.17.0-dev.2056), using the GNOME Shell extension when available and
Xlib/XWayland as the fallback.

History in short (`git log --oneline` has the rest):

- prototype, then "react to real work" (work state, petctl, hooks), then
  richer behaviour (climb/hang, bat at cursor, sounds, `say`, three animals,
  named instances)
- 2026-10-12: repo renamed to mindful-pets; window layer, command channel and
  audio put behind interfaces (`src/backend.zig`, `src/channel.zig`,
  `src/audio.zig`); GNOME Shell extension backend; `auto` backend as the
  default build. Shipped to ~/Desktop/tools as commit 0eb5ce0.
- 2026-10-12, later: first run of the shipped pet against the real extension
  froze the laptop within a minute or two (hard reboot). Cause: the shell sent
  `pointer` lines to every pet window with a blocking `write_all` on its main
  thread, and the pet never read the bubble window's socket, so the kernel
  buffer filled and the compositor blocked. Fixed on both sides (see AGENTS.md
  pitfalls): `writer.js` non-blocking bounded writes in the extension,
  `MSG_DONTWAIT` sends with a 2 s give-up in gnome.zig, and main.zig draining
  the bubble window. Verified with a standalone gjs test of the writer against
  a non-reading peer and a full round trip in a headless nested shell
  (`scripts/nested-shell`).
- 2026-10-12, after a re-login: the fixed extension ran in the real session.
  The shipped `pet` picked it ("gnome backend" in its log), a click meowed
  through the extension, no freeze, shell CPU normal. Two things showed up
  within minutes, both addressed in the review release below:
  (a) the user's monitors are stacked (1920x1080 HDMI
  above a 1366x768 laptop panel at x=710) and the extension reported the
  whole 2076x1848 stage, so the pet walked along the stage floor into the
  gap beside the laptop panel and vanished. Now the extension sends
  `screen X Y W H` for the primary monitor and gnome.zig translates every
  coordinate, so pet.zig and main.zig never see stage space. Needs
  `scripts/install-extension` plus another logout/login to reach the real
  shell; verified headlessly with `scripts/nested-shell --ext ... --virtual-monitor 1366x768`.
  (b) Several pets chasing one pointer all targeted the same pixel and piled
  up; each chase now picks a random spot 0.75 to 1.75 sizes beside the
  pointer (`chase_offset` in pet.zig). The user also reported the pet
  "walking backwards" under the extension; rendering is shared with X11 and
  the frames face right on the sheet, so this is unexplained. Ask which
  state it was in (floor walk, run after the pointer, hanging from the top).
- 2026-10-12, review release: fixed six review findings. Protocol v2 is
  requested with `hello W H 2`; new clients receive `capabilities input`
  then monitor geometry, while old clients receive the legacy `screen W H`
  stage size. `input 0` keeps bubbles click-through. Monitor size/origin
  changes invalidate cached moves, update the auto wrapper, and resize/clamp
  the state machine. Either socket disconnect exits cleanly through a
  one-shot `disconnected` event. Chase destinations use the available space
  beside the pointer without collapsing onto screen edges. `petctl` uses
  Python 3 for atomic non-blocking writes, dropping full-pipe commands.
  Release code at 638b44e was pushed to origin/main and shipped with
  `scripts/ship` to ~/Desktop/tools. Extension v0.1.3 is installed; the
  installer disabled the real shell's cached ACTIVE copy. Log out/in, then
  enable mindful-pet@rajeshpillai.github.io to load the updated extension.
  Validated with all three backend unit suites, six private-socket/FIFO
  regressions, extension protocol/hit-testing checks, and a two-monitor
  headless GNOME round trip for both the new pet and the installed legacy pet.
  Review follow-ups also cache input-mode messages, retain monitor notifications
  outside the best-effort input queue, reset pointer tracking after origin
  changes, normalize malformed protocol versions and isolate petctl's Python
  interpreter. Seven integration regressions now cover these paths. Issue
  notes live in `issues/`; the backwards-walking report remains open. The
  final shipped binary passed all seven private-socket/FIFO regressions and
  both installed tools matched the release artifacts byte for byte.
- 2026-10-12, monitor roaming: both backends now stay on the primary monitor
  by default. X11 uses XRandR 1.5 monitor rectangles and the primary output,
  listens for geometry events and polls once a second (Xvfb can omit events
  for logical monitor changes). Protocol v3 (`hello W H 3`) reports the
  actual monitor list; v2 and legacy peers retain their previous replies.
  Every state recovers off-screen positions/targets each frame. `--roam`
  follows the pointer and allows continued dragging across monitor origins,
  and visits other monitors on its own every 30–60 seconds in quiet floor
  states. Visits hop to the destination floor and start a walk; sleep, work,
  reactions, climbing and carrying are uninterrupted. Gaps are never chosen,
  and bubbles follow the pet's selected monitor. Unit tests pass for auto
  (27), GNOME (27) and X11 (21); ten socket/FIFO regressions, two real Xvfb
  checks and extension legacy/v2/v3 checks pass. Headless GNOME verified both
  installed v2/new v3 clients and a real autonomous visit to the second
  monitor with a clean shell log. Extension v0.1.4 requires a new login to
  load. Notes: `issues/009-monitor-roaming.md`.
- Group roaming: `--roam` keeps independent per-pet schedules;
  `--roam-group NAME` implies roaming and shares monitor visits and walking
  destinations with same-name members. Different groups stay independent.
  Goals are spaced by member body sizes and fitted to narrow monitors.
  Any member can advance the plan under a non-blocking file lock; there is
  no permanent leader. Busy/sleeping/carried pets rejoin when available,
  and departed members expire after three seconds. A private state file is
  retained in the runtime directory to avoid inode races during joining.
  The file is versioned, validated and opened without following symlinks.
  Group tests cover mixed sizes, narrow screens, member departure, separate
  groups/solo pets, sleeping/waking, path rejection and a held lock not
  delaying quit. Unit counts are now auto/GNOME 29 each, X11 23, with twelve
  integration regressions. Notes: `issues/010-group-roaming.md`.
  In headless GNOME, a cat and dog in the same group autonomously visited
  the second monitor with destinations 80 pixels apart and a clean shell log.

## Environment facts that shaped the design

- GNOME on Wayland. A native Wayland client cannot read the global cursor,
  place itself at absolute coordinates, or stay on top; GNOME has no
  wlr-layer-shell. So the overlay is an X11 override-redirect ARGB window via
  XWayland. Cursor chasing therefore only works when the pointer is over X11
  windows or the cat itself. The long-term fix is a small GNOME Shell
  extension that draws where the Zig core says, over a Unix socket. All
  compositor code is isolated behind `src/backend.zig` for that reason. Done
  on 2026-10-12: `src/backend/gnome.zig` plus `gnome-extension/`, tested
  against a nested shell (hello/screen/img/move/say/quit round trip, clean
  exit). The real-session backend and left-click meow were verified after
  re-login. Pointer chasing over native windows, drag/drop and right-click
  quit still need hand verification. Later extension updates require another
  re-login before the real session uses the new files.
- No SDL or raylib installed; Zig bindings for them lag master anyway. Pure
  Xlib via `b.addTranslateC` (the `@cImport` builtin is gone in 0.17).
- The user's own site https://ziglang.in is the Zig reference to use. Its
  pages on 0.17 changes, build system, and C import were accurate.
- Zig 0.17 gotchas hit so far: `main(init: std.process.Init)`; args via
  `init.minimal.args.iterate()`; `std.mem.printSentinel` instead of
  `bufPrintZ`; `XDestroyImage` is a macro, call `img.*.f.destroy_image`
  directly; comptime sprite parsing needs `@setEvalBranchQuota`.
- VS Code's Python extension runs a tool also named `pet`. Never use
  `pkill -x pet` or `pgrep -x pet`; track the pet by PID (`$!`).
- GNOME refuses CLI screenshots. To check art, run `zig build sheet` and
  convert `zig-out/sheet.ppm` to PNG (a stdlib-only Python snippet was used),
  then view it.
- `zig build test` and `zig build sheet` do NOT reinstall the executable. Run
  `zig build` before testing the binary live.
- xdotool works under XWayland for driving the cat (click, drag) in tests.
  Read the window position with `xwininfo -root -tree | grep '"pet"'`, but
  the cat walks, so act quickly after reading it.

## How it is verified

- `zig build test` for all three backends (`-Dbackend=auto|x11|gnome`):
  state machine, parser, font, characters, gnome protocol line handling.
- Review regressions: `python3 tools/test_integration.py` after `zig build`
  covers live monitor size/origin changes, a disconnected bubble, negotiated
  input control/deduplication, legacy-extension compatibility, full/no-reader
  FIFOs, interpreter isolation and oversized bubbles after monitor shrink.
  `node tools/test_extension.mjs` tests actual extension protocol and alpha
  hit-testing methods with a stub actor, including legacy clients and bubbles.
- Live X11: xdotool click meows, drag carries, drop falls, transparent
  corner clicks pass through, `petctl quit` exits and removes the pipe.
- Live GNOME backend: against a headless nested shell (`scripts/nested-shell`):
  connect, screen size, frames, bubble, sound, clean quit for both windows,
  and the auto build choosing gnome vs x11 correctly. With
  `--ext gnome-extension/mindful-pet@rajeshpillai.github.io --virtual-monitor 1366x768`
  (two monitors): the new pet gets the primary monitor's rectangle and the
  installed legacy pet still gets the stage size. The extension's writer
  has a standalone gjs test (a non-reading peer must stall it in
  milliseconds; a reading peer must get every line in order); it lives in the
  session scratchpad, not the repo, so rewrite it from writer.js if needed.
  A left click through the extension meowed in the real session; drags and
  right-click quit are implemented but were never exercised by hand.

## Open questions only the user can answer

1. Done on 2026-10-12: the extension ran in the real session without a
   freeze, and a left-click meowed. Still unverified by hand through the
   extension: pointer chase over native windows, drag/drop, right-click quit.
   Also: in which state was the pet "walking backwards"?
2. Should the pet stay above the top bar and popups the way it does now
   (top chrome), or sit below shell UI? Easy to change in extension.js.
3. Is `work` on every prompt too much during long agent turns?

## Agreed next step

Ordered as discussed on 2026-10-12, after the hand test above:

1. Extension reports window geometry so the pet can sit on title bars and
   walk along window edges (TODO section 5). One new protocol message plus
   surfaces in pet.zig.
2. Quality of life: break the animation loops (stretch, yawn, tail flick),
   real sound recordings, a config file, then a systemd user service.
3. Later: a `--monitor` flag for a fixed non-primary choice, macOS/Windows
   backends (TODO section 6). Primary confinement and `--roam` are done on
   both existing backends.

## Code map

```
src/main.zig     event loop, --scale/--help parsing, render(), input shape; resizes the pet on screen_changed, quits on disconnected
src/pet.zig      Pet struct, State/Event enums, update(), frame(), resize() after monitor changes, chaseTarget()
src/monitors.zig monitor rectangles/lookup excluding desktop gaps
src/roaming.zig  autonomous monitor selection during quiet floor states
src/roam_group.zig shared walking/monitor plans and bounded group membership
src/sprites.zig  Frame/palette/Transform/source(), Character struct, `all` + byName()
src/characters/  cat.zig, dog.zig, rabbit.zig; each exports `character`
src/font.zig     3x5 font + drawBubble()
src/backend.zig  backend interface: Window contract, Event/Rect/PointerPos, wait, -Dbackend
src/channel.zig  command channel interface (by OS); channel/fifo.zig = named pipe
src/audio.zig    clips + Audio interface (by OS); audio/shell.zig = pw-play/paplay/aplay/afplay/ffplay
src/backend/x11.zig  Xlib Window.init/present/move/setInputShape/queryPointer/pollEvent
src/backend/gnome.zig  socket client: hello/img/move/show/hide/raise/input out, capabilities/screen/pointer/press/release in;
                       translates stage coordinates to the primary monitor, reports screen_changed/disconnected
src/backend/auto.zig   default build; gnome.available() decides once, union(Kind) dispatch, mirrors screen_w/h on every poll
gnome-extension/     extension.js: SocketService, PetWindow (Clutter.Image actor, alpha hit-test, 30 Hz pointer,
                     v3 monitor lists, legacy/v2 compatibility, `screen`, `input 0|1`); writer.js: non-blocking bounded line writer
src/events.zig   Command union and parse(); the pipe itself is in channel/fifo.zig
src/c.h          headers for the translate-c step
scripts/petctl   pipe writer (python3, atomic non-blocking); `petctl run CMD` wraps a command
scripts/pet.sh   zb, zt, pet_run, pet_say
scripts/nested-shell  headless GNOME Shell for tests; `--ext DIR`, extra flags to gnome-shell
tools/sheet.zig  sprite sheet dump (zig build sheet)
tools/test_integration.py  fake-shell/FIFO regressions (python3, after zig build)
tools/test_extension.mjs   extension protocol + hit-testing checks (node)
```

Adding a new reaction end to end: a `Frame` array in every file under
src/characters/ plus a field in `sprites.Character`, a `State` and optionally
an `Event` in pet.zig with handling in `onEvent`, `update` and `frame`, a word
in `events.zig`'s `parse`, the usage string in main.zig, `anims` in
tools/sheet.zig, and a row in the README tables.

Adding an animal: copy src/characters/cat.zig, change `name` and the art,
pick sound clip names (add clips in tools/gen_sounds.py and the `clips`
table in main.zig's Audio), and append it to `sprites.all`.

Multiple instances are separate processes; `--name` picks pet-NAME.fifo and
`petctl -n NAME` / `PET_NAME` address it. They do not know about each other.
