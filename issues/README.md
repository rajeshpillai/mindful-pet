# Issue notes

Findings from the 2026-10-12 project review, with their fixes and verification:

- [GNOME protocol compatibility](001-gnome-protocol-compatibility.md)
- [Live monitor geometry](002-live-monitor-geometry.md)
- [Bubble disconnect loop](003-bubble-disconnect-loop.md)
- [Bubble click-through](004-bubble-click-through.md)
- [Chase edge pileup](005-chase-edge-pileup.md)
- [Blocking petctl writes](006-blocking-petctl-writes.md)
- [Automated review follow-ups](008-review-hardening.md)

Unresolved observation from the real-session handoff:

- [Walking backwards](007-walking-backwards.md)

The updated extension must be loaded after a logout/login for its fixes to
take effect in the real desktop session. Binary shipping alone does not
reload GNOME Shell's extension files.
