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

It earns its keep: it is what showed a 483-tile corner costing 16.6 ms against
1.75 ms for a 600-tile straight run. The enclosing rectangle of an L is almost
all empty space, and the survey was reading all of it.
