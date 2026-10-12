# Roadmap

Checked items are done and committed. Order within a section is the order we
agreed to tackle things; it is not a promise.

## 1. Prototype

- [x] Transparent override-redirect window over Xlib / XWayland
- [x] 16x16 pixel-art cat as comptime ASCII sprites
- [x] State machine: idle, walk, run, sit, sleep, alert, happy, angry
- [x] Cursor chase, click to meow, drag and drop with gravity
- [x] Named-pipe commands (`$XDG_RUNTIME_DIR/pet.fifo`)
- [x] `--scale`, `--help`, sprite-sheet dump tool, unit tests, README

## 2. React to real work

- [x] `work` state with a typing animation, ended by ok/fail/done
- [x] `scripts/petctl` (non-blocking, safe when the cat is not running)
- [x] `petctl run CMD` reports a command's exit status
- [x] `scripts/pet.sh` shell shortcuts: zb, zt, pet_run, pet_say
- [x] Claude Code hooks: prompt -> work, stop -> ok, notification -> meow
- [x] Pipe removed on exit so stale commands are dropped

## 3. Richer behaviour

- [x] Roam the screen edges: climb the sides, cling, hang from the top, drop
- [x] Bat at the cursor when it rests on the cat
- [x] Sounds: meow, purr, hiss (synthesized placeholders, embedded)
- [x] `say TEXT` speech bubble, and the Notification hook passes its message
- [x] Several pets: cat, dog, rabbit as separate sprite sets (`--pet`), any
      number of instances with their own pipes (`--name`, `petctl -n`)
- [ ] Break the loops: stretch after waking, yawn before sleep, second idle,
      tail flick while sitting
- [ ] Real sound recordings in `src/assets/` (no code change needed)

## 4. Resident on the desktop

- [ ] systemd user service for autostart (decide at the end of this round)
- [ ] Config file for speeds, nap time, scale, top margin
- [ ] Multi-monitor awareness

## 5. See the windows (the Wayland gap)

- [x] Backend interface: `src/backend.zig` with comptime selection via
      `-Dbackend`, X11 moved to `src/backend/x11.zig`
- [ ] GNOME Shell extension backend: draws the sprite where the Zig core
      says over a Unix socket, reports pointer position and window geometry
- [ ] Sit on window title bars, walk along window edges
- [ ] Cursor chase over native Wayland windows

## 6. Other platforms

Each needs a sibling of `src/backend/x11.zig` (see AGENTS.md for the
contract). The pipe and shell-audio code are POSIX and also need a home.

- [ ] macOS: AppKit backend via the Objective-C runtime, borderless
      non-activating NSWindow at status-bar level; `afplay` for sound
- [ ] Windows: Win32 layered window (WS_EX_LAYERED | WS_EX_TRANSPARENT,
      UpdateLayeredWindow), PlaySound; commands over a Win32 named pipe or a
      local socket, and a petctl that is not bash
- [ ] Native Wayland: not as a plain client (no absolute placement or global
      pointer); the GNOME Shell extension above is the route on GNOME,
      wlr-layer-shell could serve Sway/Hyprland
- [x] Move the command channel and audio behind small interfaces too
      (`src/channel.zig`, `src/audio.zig`, selected on `builtin.os.tag`)
- [ ] Replace the libc `getenv`/`clock_gettime` left in main.zig with the
      `std.Io` equivalents once that API settles

## 7. Art pipeline

- [ ] Load sprites from PNG so they can be drawn in Aseprite
- [ ] Bigger base resolution (24x24 or 32x32)
- [ ] Let pets notice each other (sit together, chase)
- [ ] Per-animal behaviour (rabbit hops in arcs, dog fetches the cursor)
