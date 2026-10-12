# Pet appears to walk backwards

- Reported: 2026-10-12, real GNOME session
- Status: Open; reproduction details needed

## Observation

The user reported backwards walking under the GNOME extension. No cause was
identified in the original handoff or project review. The renderer is shared
between backends, and the handoff reports that the sprite-sheet frames face right.

## Next investigation

Record whether the pet is walking on the floor, chasing the pointer, climbing
a side, or hanging upside down. Check movement direction against `Pet.facing`,
`Pet.transform()` and the displayed frame in that state. The monitor and chase
fixes do not establish a resolution for this separate report.

Source: [pet.zig](../src/pet.zig), [sprites.zig](../src/sprites.zig),
[main.zig](../src/main.zig), [HANDOFF.md](../HANDOFF.md).
