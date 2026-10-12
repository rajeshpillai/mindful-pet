# GNOME speech bubbles consume clicks

- Reported: 2026-10-12
- Status: Fixed in installed extension v0.1.3; requires re-login to activate
- Severity: P2

## Failure

The GNOME backend ignored the bubble's empty input shape. The extension
made opaque bubble pixels reactive, consumed clicks, and sent events that
the pet discarded.

## Resolution

The extension advertises input control to v2 clients. An empty input shape
sends `input 0`, keeping the bubble non-reactive; the pet uses `input 1`
for alpha-based hit-testing. Older extensions retain their old behavior
until the updated extension is installed and loaded after re-login.

## Verification

- Extension regression: opaque bubble pixels stay non-reactive, pet pixels
  remain clickable, and transparent pixels pass through.
- Private-socket regression: only the bubble receives `input 0`.
- Headless GNOME accepts the negotiated input commands without protocol errors.

Source: [extension.js](../gnome-extension/mindful-pet@rajeshpillai.github.io/extension.js),
[gnome.zig](../src/backend/gnome.zig).
