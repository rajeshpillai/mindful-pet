# Agent notes for mindful-pets

Read this before changing anything. README.md is for users, TODO.md is the
roadmap, HANDOFF.md carries session-to-session state.

## What this is

A desktop pet in Zig: a pixel-art cat, dog or rabbit in a transparent X11
override-redirect window (runs under XWayland on GNOME). It reacts to
commands on a named pipe and to Claude Code hooks. `jarvis-bot` was an old
code name; the repo is github.com/rajeshpillai/mindful-pets.

## Commands the user gives

- **"ship it" or "deploy"**: run `scripts/ship`. It builds with
  `-Doptimize=ReleaseSafe` and copies `pet` and `petctl` into
  `~/Desktop/tools`. Commit and push first if there are changes, then ship.
- Zig reference: https://ziglang.in (the user's own site), tracks master.

## Build, test, check

```sh
zig build                 # also required before any live test: `zig build test`
                          # and `zig build sheet` do NOT reinstall the exe
zig build test            # unit tests (state machine, parser, font, characters)
zig build sheet           # all frames -> zig-out/sheet.ppm (check art this way;
                          # GNOME blocks CLI screenshots)
zig fmt --check build.zig src tools
```

Toolchain: Zig master (0.17.0-dev). `@cImport` is gone; C headers go through
`b.addTranslateC` on `src/c.h`. `main(init: std.process.Init)`, args via
`init.minimal.args.iterate()`, `std.mem.printSentinel` for C strings.

## Layout

```
src/main.zig        event loop, flags, rendering, Audio (embedded WAVs), bubble window
src/pet.zig         state machine; knows nothing about X11 or audio
src/sprites.zig     Frame format, palette, orientation mapping, Character struct, `all`
src/characters/     cat.zig, dog.zig, rabbit.zig (16x16 ASCII art, facing right)
src/backend.zig     window backend interface: shared types, comptime selection, contract check
src/backend/x11.zig Xlib implementation: window creation, XImage blit, XFixes input shape
src/events.zig      named pipe reader + command parser
src/font.zig        3x5 font + speech bubble painter
scripts/petctl      send a command; `petctl run CMD`; `-n NAME` for named instances
scripts/pet.sh      shell shortcuts (zb, zt, pet_run, pet_say)
scripts/ship        the "ship it" action
tools/sheet.zig     sprite sheet dump; tools/gen_sounds.py regenerates src/assets/*.wav
.claude/settings.json  hooks: prompt -> work, stop -> ok, notification -> meow + say
```

## Pitfalls that cost time

- VS Code's Python extension runs a tool also named `pet`. Never
  `pkill -x pet` or trust `pgrep -x pet`; track the pet by PID (`$!`).
- Each `x11.Window` opens its own X connection. Anything you do to a window
  must be followed by that window's `flush()` or it silently never happens.
- `std.debug.print` goes to stderr; when testing in the background, read the
  log after a clean quit (`petctl quit`), not after `kill`.
- The pet walks, so a window position read with `xwininfo` is stale within a
  second. xdotool works under XWayland for click/drag tests.
- A Claude Code settings file created mid-session is not loaded until
  `/hooks` or a restart.

## Conventions

- Keep compositor-specific code in `src/backend/`. main.zig only uses
  `backend.Window`, `backend.wait` and the shared types in `src/backend.zig`.
  New backend (GNOME Shell extension, AppKit, Win32): add a file beside
  x11.zig exporting `name`, `Window` and `wait`, a value to the `Backend`
  enum in build.zig plus its system libraries, and an arm in the `impl`
  switch in backend.zig. The comptime block there tells you what is missing.
- New reaction: add frames to every file in `src/characters/` and a field in
  `sprites.Character`, a `State`/`Event` in pet.zig, a word in
  `events.parse`, the usage string in main.zig, `anims` in tools/sheet.zig,
  and the README table.
- Commit messages: imperative summary line, body with bullets, co-author
  trailer as configured. Push to `origin main` after committing.
