# GNOME protocol breaks installed pets

- Reported: 2026-10-12
- Status: Fixed
- Severity: P1

## Failure

Changing `screen W H` to `screen X Y W H` made the installed binary interpret
the monitor origin as its dimensions. The stacked-monitor probe reported
710x1080 instead of 1366x768. An origin of 0,0 prevented initialization.

## Resolution

New clients request protocol v2 with `hello W H 2`. The extension sends
monitor geometry only to v2 peers; legacy clients receive the original stage
dimensions. Input control is advertised as a capability, so new binaries
also work with old extensions without sending unsupported commands.

## Verification

- `node tools/test_extension.mjs`: legacy and v2 screen messages.
- `python3 tools/test_integration.py`: new client with legacy extension.
- Headless GNOME with two virtual monitors: both the new binary and the
  installed legacy binary connected, displayed speech and quit cleanly.

Source: [extension.js](../gnome-extension/mindful-pet@rajeshpillai.github.io/extension.js),
[gnome.zig](../src/backend/gnome.zig).
