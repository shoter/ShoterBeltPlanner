# dev/

Not shipped. `build.ps1` excludes this directory, and it must stay excluded:
`selftest.lua` flattens a region of the map to make its results deterministic,
which must never run in someone's save.

## Running the tests

`selftest.lua` is not wired up, because wiring it means running it on every new
game. To run it, temporarily add to `control.lua`:

```lua
local selftest = require("dev/selftest")   -- TEMPORARY
script.on_init(function()
  init_storage()
  selftest.run()                            -- TEMPORARY
end)
```

then build a zip that *includes* `dev/` (the normal `build.ps1` will not) and
generate a throwaway map, which is what runs `on_init`:

```
factorio.exe --create <tmp>\t.zip --mod-directory <tmp>
```

Results go to the log as `[BP-SELFTEST]` lines. Remove both TEMPORARY lines
afterwards.

Run it at least twice: `--create` rolls a fresh map seed each time, and a test
that depends on where the trees landed will pass once and fail the next time.
`clear_area` exists for exactly that reason.

## Running while Factorio is open

Factorio takes an instance lock in its write-data directory, so a second copy
normally refuses to start with *"Couldn't create lock file"*. There is no
`--write-data` flag, but `-c` accepts a config file and the path lives in there,
so pointing a throwaway config at a throwaway directory moves the lock with it:

```ini
[path]
read-data=__PATH__system-read-data__
write-data=C:/some/scratch/dir

[general]
locale=auto
```

```
factorio.exe -c <tmp>\fconfig.ini --create <tmp>\t.zip --mod-directory <tmp>
```

That also keeps the test runs from writing into the real `script-output` and
from touching the real `mods` folder.

## What is and is not covered

The planner is well covered: geometry, corners, tunnelling, clearing, splitters,
the refusals, and replanning over a run already placed.

Nothing that draws is covered at all. `--create` produces a map with no player,
so the GUI and the preview renderer cannot run headlessly — which is how two
crashes reached a player. `control.lua` therefore calls the preview behind
`pcall`, and `selftest.lua` pins the shape every spec kind must have, but the
only real test of anything visual is playing the game.

## Benchmark

`selftest.benchmark()` runs after the assertions and reports `[BP-BENCH]` timings
for a short run, a long run, a long run where every tile has to be cleared, and a
corner. The preview re-plans every time the pointer crosses a tile, so these are
the numbers that decide whether it feels smooth; a tick is 16.7 ms.

It earns its keep twice over.

It found a real problem: a 483-tile corner cost 16.6 ms against 1.75 ms for a
600-tile straight run, because the enclosing rectangle of an L is almost all
empty space and the survey was reading all of it. Surveying each leg separately
took that to 2.3 ms.

It also stopped a pointless optimisation. The preview destroys and recreates its
render objects on every refresh, which looked worth pooling — `sprite`, `target`,
`color`, `visible` and the scales are all writable, so objects could be moved
instead of churned. Measured:

| | cost |
|---|---|
| 300 sprites, create and destroy | 0.52 ms |
| 300 sprites, move and retint a pool | 0.17 ms |

A 0.35 ms saving against planning costs of 1.7–6.4 ms, in exchange for pool
lifecycle, storage safety and hiding surplus objects. Not worth it. The benchmark
stays so the decision can be revisited with numbers rather than reopened on a
hunch.

## Where the time actually goes

One preview refresh, worst case, on this machine:

| run | plan | draw | total |
|---|---|---|---|
| 30 tiles, clear | 0.10 | ~0.1 | ~0.2 ms |
| 600 tiles, clear | 1.74 | 0.52 | ~2.3 ms |
| corner, 483 tiles | 2.40 | 0.52 | ~2.9 ms |
| 600 tiles, every tile a tree | 6.45 | 0.52 | ~7.0 ms |

A tick is 16.7 ms, and a refresh only happens when the pointer crosses a tile,
not every tick. The remaining hot spot is a run where *every* tile needs clearing
— four times the clear-ground cost, because each tile then populates the occupant
table, runs the clearable check and produces a removal spec. That is not a shape
anyone builds in practice, so it is left alone.
