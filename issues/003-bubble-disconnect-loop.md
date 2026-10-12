# Bubble disconnect traps the event loop

- Reported: 2026-10-12
- Status: Fixed
- Severity: P2

## Failure

After EOF, each `pollEvent()` emitted another synthetic right-click. The
bubble drain loop discarded these events forever, so the process stopped
rendering and ignored the quit command.

## Resolution

Connection loss is terminal and emits `disconnected` once. The main loop
exits cleanly if either the pet or bubble connection closes.

## Verification

- Zig test: disconnection is reported once and the connection stays lost.
- Private-socket regression: closing only the bubble socket exits the pet
  with status 0, in Debug and ReleaseSafe.

Source: [gnome.zig](../src/backend/gnome.zig), [main.zig](../src/main.zig).
