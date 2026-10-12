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

Everything is committed and pushed; the tree is clean.

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
  exit). Not yet tested in the real session: that needs a re-login so GNOME
  loads the extension; the shipped `pet` (auto backend) then picks it up by
  itself and logs "gnome backend". Pointer
  chasing over native windows, click, drag and right-click-quit through the
  extension are implemented but unverified by hand.
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
- Live X11: xdotool click meows, drag carries, drop falls, transparent
  corner clicks pass through, `petctl quit` exits and removes the pipe.
- Live GNOME backend: only against a nested shell (see AGENTS.md pitfalls):
  connect, screen size, frames, bubble, sound, clean quit for both windows,
  and the auto build choosing gnome vs x11 correctly. Clicks and drags
  through the extension are implemented but were never exercised by hand.

## Open questions only the user can answer

1. After the next login, does the shipped `pet` log "gnome backend", and do
   pointer chase over native windows, left-click meow, drag/drop and
   right-click quit all work through the extension? This is the first thing
   to check next session; the extension is installed and enabled already.
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
3. Later: multi-monitor awareness, macOS/Windows backends (TODO section 6).

## Code map

```
src/main.zig     event loop, --scale/--help parsing, render(), input shape
src/pet.zig      Pet struct, State/Event enums, update(), frame()
src/sprites.zig  Frame/palette/Transform/source(), Character struct, `all` + byName()
src/characters/  cat.zig, dog.zig, rabbit.zig; each exports `character`
src/font.zig     3x5 font + drawBubble()
src/backend.zig  backend interface: Window contract, Event/Rect/PointerPos, wait, -Dbackend
src/channel.zig  command channel interface (by OS); channel/fifo.zig = named pipe
src/audio.zig    clips + Audio interface (by OS); audio/shell.zig = pw-play/paplay/aplay/afplay/ffplay
src/backend/x11.zig  Xlib Window.init/present/move/setInputShape/queryPointer/pollEvent
src/backend/gnome.zig  socket client: hello/img/move/show/hide/raise out, screen/pointer/press/release in
src/backend/auto.zig   default build; gnome.available() decides once, union(Kind) dispatch
gnome-extension/     extension.js: SocketService, PetWindow (Clutter.Image actor, alpha hit-test, 30 Hz pointer)
src/events.zig   Command union and parse(); the pipe itself is in channel/fifo.zig
src/c.h          headers for the translate-c step
scripts/petctl   pipe writer; `petctl run CMD` wraps a command
scripts/pet.sh   zb, zt, pet_run, pet_say
tools/sheet.zig  sprite sheet dump (zig build sheet)
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
