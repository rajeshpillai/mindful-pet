# Shell integration for the desktop pet. Source from ~/.bashrc or ~/.zshrc:
#
#   source /path/to/mindful-pets/scripts/pet.sh
#
# Then:
#   zb              zig build with the cat reacting to the result (args pass through)
#   zt              zig build test, same
#   pet_run CMD...  any command: cat works while it runs, then purrs or hisses
#   pet_say WORD    send a raw command (ok, fail, work, done, sleep, wake, meow, goto X)

PET_HOME="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
export PATH="$PET_HOME/scripts:$PATH"

pet_say() { petctl "$@"; }
pet_run() { petctl run "$@"; }
zb() { petctl run zig build "$@"; }
zt() { petctl run zig build test "$@"; }
