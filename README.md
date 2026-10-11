# jarvis-bot (code name)

A tiny desktop pet written in Zig: a pixel-art cat that lives along the bottom
edge of your screen, wanders, naps, chases your mouse, and reacts to events you
send it from scripts (a failed build, a finished deploy, a Claude Code hook).

It is a prototype. The window layer talks to X11 directly, so on a Wayland
desktop it runs through XWayland. See [Limitations](#limitations).

## Requirements

- Zig master (built against `0.17.0-dev.2056`, see `build.zig.zon`)
- X11 development headers and libraries: `libx11-dev`, `libxfixes-dev`, `libxext-dev`
  (Debian/Ubuntu names; the runtime needs `libX11`, `libXfixes`, `libXext`)
- An X server or XWayland with a 32-bit ARGB visual (any compositing desktop)

## Build and run

```sh
zig build            # binary lands in zig-out/bin/pet
zig build run        # build and launch
zig build run -- --scale 6
zig build test       # unit tests for the state machine and command parser
zig build sheet      # dump every animation frame to zig-out/sheet.ppm
```

## Command line

```
pet [--scale N] [--help]

  --scale N   pixel zoom of the 16x16 art, 1..12 (default 4 = 64px cat)
  -h, --help  show this help
```

Environment:

- `XDG_RUNTIME_DIR` decides where the command pipe is created (falls back to `/tmp`).
- `PET_DEBUG=1` logs mouse button events to stderr.

## Using the cat

Mouse:

| Action | Result |
| --- | --- |
| Move the pointer near it | It runs after the pointer, then sits down. |
| Left click | It startles and meows (printed to stderr). |
| Drag | Carry it anywhere. Drop it above the floor and it falls. |
| Right click | Quit. |

Clicks only land on the cat's opaque pixels. The transparent part of its
window passes clicks through to whatever is underneath.

On its own it idles, walks to random spots, sits, blinks, and after about
45 seconds with nothing happening nearby it falls asleep. Moving the pointer
close to it wakes it up.

## Sending it events

The cat listens on a named pipe at `$XDG_RUNTIME_DIR/pet.fifo`. Write one
command per line:

| Command | Effect |
| --- | --- |
| `ok`, `pass`, `happy` | Content: eyes closed, little heart. |
| `fail`, `error`, `angry` | Hisses, then sulks. |
| `sleep` | Curls up until woken. |
| `wake` | Wakes a sleeping cat. |
| `meow`, `alert`, `poke` | Startle it. |
| `goto X` | Walk so its centre ends up at screen x coordinate X. |
| `quit`, `exit` | Exit. |

Examples:

```sh
echo fail > "$XDG_RUNTIME_DIR/pet.fifo"

# React to a build result
zig build && echo ok > "$XDG_RUNTIME_DIR/pet.fifo" || echo fail > "$XDG_RUNTIME_DIR/pet.fifo"
```

Claude Code hook example (`.claude/settings.json`), so the cat wakes while an
agent is working and settles when the turn ends:

```json
{
  "hooks": {
    "PreToolUse": [{ "hooks": [{ "type": "command", "command": "echo wake > \"$XDG_RUNTIME_DIR/pet.fifo\"" }] }],
    "Stop":       [{ "hooks": [{ "type": "command", "command": "echo ok > \"$XDG_RUNTIME_DIR/pet.fifo\"" }] }]
  }
}
```

## Project layout

```
src/main.zig     event loop, argument parsing, rendering into the window buffer
src/pet.zig      the state machine (idle, walk, run, sit, sleep, alert, happy, angry, held, fall)
src/sprites.zig  16x16 frames drawn as ASCII art, expanded at comptime
src/x11.zig      transparent override-redirect window, XImage blit, XFixes input shape
src/events.zig   named-pipe command reader and parser
src/c.h          the C headers translated by build.zig (Xlib, XFixes, libc bits)
tools/sheet.zig  renders all frames to a PPM for reviewing the art
```

To change the art, edit the ASCII blocks in `src/sprites.zig` (palette at the
top of the file) and run `zig build sheet` to check the result.

## Limitations

- **Wayland.** The cat is an X11 client, so under GNOME Wayland it lives in
  XWayland. It cannot see the pointer while the pointer is over native Wayland
  windows, so cursor chasing only works over X11 applications and the cat
  itself. It also cannot sit on top of native windows reliably. The planned fix
  is a small GNOME Shell extension that draws the sprite where this Zig core
  tells it to; the core already keeps all compositor-specific code in
  `src/x11.zig`.
- Single monitor. It uses the root window size of the default screen.
- No sound yet. `meow!` goes to stderr.
