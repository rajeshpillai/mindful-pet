# Live monitor changes leave pets off-screen

- Reported: 2026-10-12
- Status: Fixed
- Severity: P2

## Failure

The GNOME client accepted new monitor dimensions, but the auto wrapper and
state machine retained startup values. Resizing to 800x600 left the pet at
y=704 instead of the new floor y=536. A changed origin could also leave a
stationary actor at its cached stage position.

## Resolution

Geometry changes invalidate cached moves and emit `screen_changed`. The
auto wrapper refreshes its dimensions, and the state machine clamps positions
and destinations to the current monitor. Bubbles tolerate a monitor narrower
than their painted width. Active drags are released when geometry changes.

## Verification

- Zig tests cover pointer rebasing, move invalidation, floor/climb positions
  and monitors smaller than the pet.
- Private-socket tests cover origin-only changes, resize to 800x600, and a
  large speech bubble surviving monitor shrink, in Debug and ReleaseSafe.

Source: [gnome.zig](../src/backend/gnome.zig), [auto.zig](../src/backend/auto.zig),
[main.zig](../src/main.zig), [pet.zig](../src/pet.zig).
