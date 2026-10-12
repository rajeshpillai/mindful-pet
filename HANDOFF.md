# Handoff

Status of the desktop-pet project as of 2026-10-11, for picking up in a fresh
session. The README covers usage; this file covers decisions, state, and what
to do next.

## What this is

The repo is github.com/rajeshpillai/mindful-pets; the local folder was
once named "jarvis-bot", an old code name. The project is a desktop pet: a pixel-art
cat that lives along the bottom of the screen, wanders, naps, chases the
cursor, and reacts to events sent through a named pipe. Written in Zig
(master, 0.17.0-dev.2056) over Xlib, running under XWayland on GNOME.

Two commits so far:

- `14bb383` prototype: overlay window, sprites, state machine, pipe, README
- `56bdba9` task 1 "react to real work": `work` state, `scripts/petctl`,
  `scripts/pet.sh`, Claude Code hooks in `.claude/settings.json`

Everything is committed; the tree is clean.

## Environment facts that shaped the design

- GNOME on Wayland. A native Wayland client cannot read the global cursor,
  place itself at absolute coordinates, or stay on top; GNOME has no
  wlr-layer-shell. So the overlay is an X11 override-redirect ARGB window via
  XWayland. Cursor chasing therefore only works when the pointer is over X11
  windows or the cat itself. The long-term fix is a small GNOME Shell
  extension that draws where the Zig core says, over a Unix socket. All
  compositor code is isolated in `src/x11.zig` for that reason.
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

- `zig build test`: state machine (walk arrives, work ignores pointer, fail
  then sit) and command parser.
- Live: xdotool click meows, drag carries, drop above the floor falls,
  transparent corner clicks pass through, `petctl quit` exits and removes
  the pipe. Hook commands were piped exactly as Claude Code runs them.
- `scripts/petctl` tested against a held-open pipe, a pipe with no reader
  (must not block or leak), and no pipe at all.

## Open questions only the user can answer

The user was going to live with it for a bit before task 2. Ask about:

1. Is the `work` typing animation readable at 64px? The two frames differ by
   one paw. If not, enlarge the motion or add a third frame.
2. Is `work` on every prompt (UserPromptSubmit hook) too much during long
   agent turns? Alternatives: fire on PreToolUse only, or give the cat
   breaks.
3. Did the hooks load? `.claude/settings.json` was created mid-session, so
   the user may have needed `/hooks` or a restart.

## Agreed next step: task 2, richer behaviour

Order the user and I settled on:

1. Sound: `paplay` a short meow on `meow` and a purr on `ok`. Needs two
   small audio files (none in the repo yet) and a spawn from `pet.zig`'s
   `meow()` / `onEvent`.
2. Bat at the cursor: when the pointer rests on the cat for about a second,
   a paw-swipe animation. Works today since the cat's own window always
   sees the pointer.
3. Break the loops: stretch after waking, a second idle animation, a yawn
   before sleep.
4. `say TEXT`: a speech bubble for a few seconds, turning the cat into a
   status line for scripts.

Start with 1 and 2. After task 2, the earlier roadmap continues with the
GNOME Shell extension backend (task 3) and polish/packaging (task 4:
multi-monitor, systemd user service, config file, PNG sprite loading).

## Code map

```
src/main.zig     event loop, --scale/--help parsing, render(), input shape
src/pet.zig      Pet struct, State/Event enums, update(), frame()
src/sprites.zig  Frame/palette/Transform/source(), Character struct, `all` + byName()
src/characters/  cat.zig, dog.zig, rabbit.zig; each exports `character`
src/font.zig     3x5 font + drawBubble()
src/x11.zig      Window.init/present/move/setInputShape/queryPointer/pollEvent
src/events.zig   Fifo (open, pollCommand, close+unlink) and parse()
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
