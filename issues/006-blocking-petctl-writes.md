# petctl hangs when the command FIFO is full

- Reported: 2026-10-12
- Status: Fixed
- Severity: P2

## Failure

Opening the FIFO read/write avoided waiting for a reader, but the shell's
`printf` still blocked on a full pipe. A stopped pet could therefore stall
a Claude hook or `petctl run` indefinitely.

## Resolution

`petctl` uses Python 3 to open and write with `O_NONBLOCK`. Commands at or
below `PIPE_BUF` are atomic. A missing reader, full pipe or oversized command
is a silent no-op. FIFO type and symlink checks prevent accidental writes to
a replaced non-pipe path.

## Verification

The integration regression fills a FIFO, then verifies that both a direct
command and `petctl run true` finish promptly. It also verifies that a FIFO
without a reader does not block.

Source: [petctl](../scripts/petctl), [test_integration.py](../tools/test_integration.py).
