# mindful-pet

A tiny desktop pet written in Zig: a pixel-art cat that lives on the edges of
your screen. It wanders, naps, climbs the sides, hangs from the top, drops
down, chases your mouse, swipes at it, and reacts with sounds to events you
send it from scripts (a failed build, a finished deploy, a Claude Code hook).

It is a prototype. The window layer talks to X11 directly, so on a Wayland
desktop it runs through XWayland. See [Limitations](#limitations).

## Requirements

- Zig master (built against `0.17.0-dev.2056`, see `build.zig.zon`)
- X11 development headers and libraries: `libx11-dev`, `libxfixes-dev`, `libxext-dev`
  (Debian/Ubuntu names; the runtime needs `libX11`, `libXfixes`, `libXext`)
- An X server or XWayland with a 32-bit ARGB visual (any compositing desktop)
- For sound, one of `pw-play`, `paplay`, `aplay` or `ffplay` on PATH (optional)

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
pet [--scale N] [--top N] [--mute] [--help]

  --scale N   pixel zoom of the 16x16 art, 1..12 (default 4 = 64px cat)
  --top N     pixels reserved for the top panel; the cat hangs below it (default 32)
  --mute      no sounds
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
| Rest the pointer on it | After about a second it swipes a paw at it. |
| Left click | It startles and meows. |
| Drag | Carry it anywhere. Drop it above the floor and it falls. |
| Right click | Quit. |

Clicks only land on the cat's opaque pixels. The transparent part of its
window passes clicks through to whatever is underneath.

On its own it idles, walks to random spots, sits, blinks, and now and then
heads for a screen edge, climbs it, pauses, and either climbs back down or
hangs upside down from the top edge, walks along it, and drops. After about
45 seconds with nothing happening nearby it falls asleep. Moving the pointer
close to it wakes it up.

Sounds: a meow when clicked or poked, a purr on `ok`, a hiss on `fail`. The
clips are synthesized by `tools/gen_sounds.py` and embedded in the binary;
drop real recordings into `src/assets/` and rebuild to replace them. Pass
`--mute` to silence it.

## Sending it events

The cat listens on a named pipe at `$XDG_RUNTIME_DIR/pet.fifo`. Write one
command per line:

| Command | Effect |
| --- | --- |
| `ok`, `pass`, `happy` | Content: eyes closed, little heart. |
| `fail`, `error`, `angry` | Hisses, then sulks. |
| `work`, `busy` | Sits and types until `ok`, `fail` or `done` arrives (gives up after 15 min). Ignores the pointer meanwhile. |
| `done`, `idle` | Ends `work` without a verdict. |
| `climb` | Walk to the nearest screen edge and climb it. |
| `sleep` | Curls up until woken. |
| `wake` | Wakes a sleeping cat. |
| `meow`, `alert`, `poke` | Startle it. |
| `goto X` | Walk so its centre ends up at screen x coordinate X. |
| `quit`, `exit` | Exit. |

### petctl and shell integration

`scripts/petctl` wraps the pipe and is a silent no-op when the cat is not
running, so it is safe in hooks and makefiles:

```sh
scripts/petctl fail              # one command
scripts/petctl run zig build     # cat works while the command runs, then ok/fail
```

`scripts/pet.sh` adds shortcuts to your shell. Source it from `~/.bashrc`:

```sh
source /path/to/jarvis-bot/scripts/pet.sh
zb            # zig build, cat reacts to the result
zt            # zig build test
pet_run make  # any command
pet_say meow
```

Set `PET_FIFO` to point both at a different pipe. Commands sent while the cat
is not running are dropped: the pet removes its pipe on exit.

### Claude Code

`.claude/settings.json` in this repo wires three hooks: when you submit a
prompt the cat starts typing, when the turn ends it purrs, and when Claude
needs your attention (a permission prompt) it meows. They call
`scripts/petctl`, so nothing happens if the cat is not running. To get the
same in another project, copy that file or merge the `hooks` block into its
`.claude/settings.json`.

### Other ideas

```sh
# git: wake the cat on every commit
echo 'petctl meow' > .git/hooks/post-commit && chmod +x .git/hooks/post-commit

# tests in a watch loop
watchexec -e zig -- petctl run zig build test
```

## Project layout

```
src/main.zig     event loop, argument parsing, rendering into the window buffer
src/pet.zig      the state machine (idle, walk, run, sit, sleep, alert, happy, angry, work, bat, climb, cling, hang, held, fall)
src/sprites.zig  16x16 frames drawn as ASCII art, expanded at comptime
src/x11.zig      transparent override-redirect window, XImage blit, XFixes input shape
src/events.zig   named-pipe command reader and parser
src/c.h          the C headers translated by build.zig (Xlib, XFixes, libc bits)
src/assets/      meow/purr/hiss WAVs, embedded at build time
tools/gen_sounds.py  regenerates those clips (stdlib Python)
tools/sheet.zig  renders all frames to a PPM for reviewing the art
scripts/petctl   send a command to the pipe, or wrap a command and report its result
scripts/pet.sh   shell shortcuts (zb, zt, pet_run, pet_say)
.claude/         Claude Code hooks that drive the cat
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
- The top edge is the screen's, not your editor's. Climbing an application
  window needs window geometry, which is the same Wayland gap as above.
- Single monitor. It uses the root window size of the default screen.
- No sound yet. `meow!` goes to stderr.
