# Attack Move

A UCP3 module for Stronghold Crusader and Stronghold Crusader Extreme. It makes the game's
hidden "attack move" (Shift-click waypoints) work at any time, not only right after selecting
troops, and lets you hold Alt to move troops onto other troops - your own (for stacking) or the
enemy's (to send melee troops into a crowd instead of attacking one unit).

What the module does, in plain English, is in `module/locale/description-en.md`.

## What is in here

| Folder | |
|---|---|
| `module/` | the module itself - this is the source of truth, edited in place |
| `bench/` | the emulator bench: the module's own Lua runs against the real exe image, its assembly is assembled with UCP's own fasm.dll and then executed, together with the game's own click handler |
| `tools/publish.py` | copies `module/` into the game's module folder under a new version |

## Working on it

1. Edit under `module/`.
2. Run the bench until it is green: `cd bench && python test_behaviour.py` (Shift waypoints:
   new route, adding to a route, a route ordered but not started, a finished route, a normal
   move becoming the first leg, patrols, the nine-point cap; Alt over your own troops and over
   enemies; everything off), on both executables.
3. `python tools/publish.py --bump` - raises the last version slot and copies the module to
   `ucp/modules/attack-move-<version>`, leaving the build before it installed and clearing
   anything older. Do this with the game closed.
4. In the UCP GUI press F5, then apply.
5. Commit and tag: `git commit -am "<version> - <what changed>" && git tag v<version>`.

The bench needs Python with `lupa`, `capstone`, `pefile` and `keystone-engine`, and a 32-bit
PowerShell for fasm.dll; it reads the executables from the game folder named in `bench/shc.py`.

## How it works

* **Shift waypoints.** A group of troops keeps its route on the group: a route flag (`-1`
  waypoints, `1` patrol, `0` none), up to nine points and the current step. The click handler
  decides between "start a route" and "add a point" by a counter that is reset only when troops
  are selected; the route flag goes back to 0 when a route ends or a normal move is given. So
  after any move, Shift-clicks stored points nobody walked. The module checks the group on each
  Shift-click and starts, extends or continues the route accordingly. Fighting on the way by
  stance is the game's own behaviour and is tied to the same flag.
* **Alt.** The click handler asks `getUnitInHitBox` for your own troops (to select them) and for
  enemies (to attack them) under the cursor; while Alt is held and troops are selected, those
  questions get "none", so the click is a move order.

Every address is found by pattern scan or read from the instruction that uses it.
