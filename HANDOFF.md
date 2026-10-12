# Handoff

Status of the desktop-pet project as of 2026-10-12, for picking up in a fresh
session. The README covers usage; this file covers decisions, state, and what
to do next.

## What this is

The repo is github.com/rajeshpillai/mindful-pets; the local folder was
once named "jarvis-bot", an old code name. The project is a desktop pet: a pixel-art
cat that lives along the bottom of the screen, wanders, naps, chases the
cursor, and reacts to events sent through a named pipe. Written in Zig
(master, 0.17.0-dev.2056) over Xlib, running under XWayland on GNOME.

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
  The updated extension still needs installation and re-login in the real
  shell; shipping the binary alone does not reload GNOME's cached extension.
  Validated with all three backend unit suites, six private-socket/FIFO
  regressions, extension protocol/hit-testing checks, and a two-monitor
  headless GNOME round trip for both the new pet and the installed legacy pet.

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
  input control, legacy-extension compatibility and full/no-reader FIFOs.
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
3. Later: multi-monitor for the X11 backend and a `--monitor` flag (the
   GNOME backend already keeps to the primary monitor), macOS/Windows
   backends (TODO section 6).

## Code map

```
src/main.zig     event loop, --scale/--help parsing, render(), input shape
src/pet.zig      Pet struct, State/Event enums, update(), frame(), resize() after monitor changes, chaseTarget()
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
                     protocol v2 negotiation, per-monitor `screen`, `input 0|1`); writer.js: non-blocking bounded line writer
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
