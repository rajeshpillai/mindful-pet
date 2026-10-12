# Off-screen recovery and optional monitor roaming

- Requested: 2026-10-12
- Status: Fixed

## Request

Bring a pet back when it goes off-screen. Stay on the primary monitor unless
a flag allows roaming. The user selected autonomous visits as well as pointer
following and dragging between monitors.

## Resolution

- `Pet.update` recovers positions and destinations every frame, in every
  state. Small monitors also spawn pets safely.
- X11 selects the primary XRandR monitor/output instead of the whole root
  rectangle. It translates input and movement to monitor-local coordinates,
  handles geometry notifications, and checks once a second for servers that
  omit logical-monitor notifications.
- GNOME protocol v3 supplies actual monitor rectangles. Legacy and v2 peers
  retain their existing wire formats; old extensions remain compatible.
- Without `--roam`, dragging beyond the primary monitor stops at its edge.
  With it, pointer following and dragging select another real monitor, with
  both pet and bubble rebased together. Desktop gaps are excluded.
- Autonomous visits choose another monitor every 30–60 seconds in quiet
  floor states, hop to its floor and begin walking. Sleep, work, reactions,
  climbing and dragging wait for completion. Geometry changes recover to the
  new primary monitor. A monitor smaller than the sprite anchors it at zero;
  the sprite necessarily clips when it cannot fit.

## Verification

- Unit tests cover every state's off-screen recovery, tiny-monitor startup,
  coordinate rebasing, gaps, negative monitor origins and autonomous visits.
- Private-socket tests cover primary confinement, pointer roaming, bubble
  placement, continued cross-monitor dragging and gap rejection.
- Private Xvfb tests cover primary output selection, external off-screen
  moves, live monitor changes and roaming on the stacked layout.
- Headless GNOME checks cover v2/v3 compatibility and an autonomous visit.

GNOME roaming needs extension v0.1.4 loaded after a logout/login. X11 monitor
selection needs XRandR 1.5+; older servers fall back to root-window geometry.
