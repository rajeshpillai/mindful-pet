# Independent and group roaming

- Requested: 2026-10-12
- Status: Fixed

## Request

Several pets should be able to roam independently or travel together.

## Resolution

`--roam` gives each pet its own schedule. `--roam-group NAME` joins a named
group with shared walking destinations every 8–16 seconds and monitor
visits every 30–60 seconds. Separate groups and solo pets remain independent.
Targets account for each member's body width, with gaps when space permits.
Narrow screens compress spacing so positions remain visible.

Group members follow a monitor chosen by another member's pointer/drag, and
choose monitor visits autonomously. Busy, sleeping, climbing and carried
pets defer adopting a plan until available. A member can quit without
stopping the group; missed heartbeats expire after three seconds.

A versioned private file in the shared runtime directory coordinates up to
32 members. File locks never wait, writes are bounded, timestamps are read
under the lock, and symlinks/non-private/non-regular files are rejected.
The inode is retained to avoid races as members join or leave. After three
seconds with no live members, the next pet creates a fresh plan.

## Verification

- Unit tests verify common plans, mixed-size spacing, narrow monitors,
  departure recovery, stale plans and autonomous visits.
- A four-process regression checks two friends, a different group and a
  solo pet; a sleeping friend waits, wakes and rejoins. The survivor works
  after the first member quits.
- Regression checks reject invalid group names and symlinks, and verify
  that a held file lock does not delay clean quit.
- Two grouped pets autonomously visited the same second monitor in a real
  headless GNOME Shell, with separated targets and a clean shell log.
