# Automated review follow-ups

- Reported: 2026-10-12, no-mistakes review
- Status: Fixed

The first release candidate fixed the six original findings. Automated review
identified five additional hardening items before publication:

1. **Repeated input commands.** Every animation frame resent `input 1` even
   when the input mode had not changed. Cache the last mode sent.
2. **Dropped monitor notification.** A full 32-entry input queue could discard
   `screen_changed` after the geometry was already updated. Keep the geometry
   notification sticky until the main loop consumes it.
3. **False pointer movement.** Rebasing a stationary pointer after an origin
   change made it appear to move for one frame. Reset pointer tracking when
   the main loop handles the new geometry.
4. **Malformed hello version.** A nonnumeric version yielded inconsistent
   capability and geometry messages. Normalize the protocol version once.
5. **Python environment interference.** A hook's working directory or Python
   environment could shadow standard modules and delay or break `petctl`.
   Run the helper interpreter in isolated mode without importing `site`.

All five fixes are implemented. The Zig regression fills the event queue,
changes monitor geometry twice, and confirms delivery of the latest geometry.
Extension checks cover invalid and noninteger versions. Integration checks
verify one input-mode message across animation frames and successful command
delivery with an invalid `PYTHONHOME`. All original regressions still pass.

The final review found no release blocker. It also suggested recording an input
mode only after a successful send; that cache bookkeeping fix is included.
Monitor changes cancel active drags, and a gesture received during the same
geometry transition can be discarded. This preserves the geometry update and
keeps the pet on its monitor.

Source: [gnome.zig](../src/backend/gnome.zig), [main.zig](../src/main.zig),
[extension.js](../gnome-extension/mindful-pet@rajeshpillai.github.io/extension.js),
[petctl](../scripts/petctl).
