# Chase offsets collapse at screen edges

- Reported: 2026-10-12
- Status: Fixed
- Severity: P2

## Failure

Clamping an outward random offset put several pets at the same edge. With
the pointer at x=32, 10 of 20 seeds targeted x=0, centering the pets directly
under the pointer.

## Resolution

Each chase retains a random side and fraction. The target calculation picks
a side with room and maps that fraction into the available offset range,
instead of clamping several destinations to one edge pixel.

## Verification

Zig tests check 20 seeds at both edges and in the screen interior: targets
stay beside the pointer, within the screen, and vary across seeds. Independent
random destinations reduce pileups; pets do not coordinate collision avoidance.

Source: [pet.zig](../src/pet.zig).
