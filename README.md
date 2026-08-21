# Shoter Belt Planner

A Factorio 2.0 mod. Plan a whole belt run in a couple of clicks — several lanes at
once, around corners, forwards or backwards, placed as ghosts you can undo in one go.

The player-facing description, as published on the mod portal, is in
[dev/mod-portal-description.md](dev/mod-portal-description.md).

## Status

**Beta.** It works and it is tested, but it has not had many hours on it in a real save.

Most of the code was written by Claude, Anthropic's AI. The design calls and the
in-game testing are mine.

## Requirements

- Factorio **2.0** (works with Space Age)
- [flib](https://mods.factorio.com/mod/flib) `>= 0.16.0`

## Building

```powershell
.\build.ps1
```

Packs the mod into `dist/ShoterBeltPlanner_<version>.zip`, reading the version from
`info.json` and refusing to build if the name there disagrees with the zip it is
about to write. `dev/`, `dist/`, `.claude/`, scripts and docs are left out.

```powershell
.\publish_local.ps1
```

Builds, clears any older copy out of `%APPDATA%\Factorio\mods`, and installs the new
zip. It refuses to run while Factorio is open, because the running game holds its mod
zips: pass `-Force` to override, `-ModsDir` to install somewhere else, or `-WhatIf` to
see what it would do.

## Tests

`dev/selftest.lua` exercises the planner against a real surface headlessly — geometry,
corners, clearing, splitters, every refusal, and replanning over a run already placed.
It is not shipped and not wired up; [dev/README.md](dev/README.md) explains how to run
it, and carries the benchmark numbers and an honest account of what is *not* covered.

The short version:

```
factorio.exe -c <tmp>\fconfig.ini --create <tmp>\t.zip --mod-directory <tmp>
```

Run it at least twice. `--create` rolls a fresh map seed each time, and a test that
depends on where the trees landed will pass once and fail the next time.

## Layout

| | |
|---|---|
| `control.lua` | control-stage aggregator; every event is wired up here |
| `data.lua`, `data-final-fixes.lua` | prototype entry points |
| `prototypes/` | the tool, the cursor probes, the sliced belt preview graphics |
| `scripts/geometry.lua` | pure tile geometry — no world access, no storage, no side effects |
| `scripts/logic/plan.lua` | turns two endpoints into a list of things to place |
| `scripts/logic/place.lua` | commits that list as ghosts, in one undo item |
| `scripts/belts.lua`, `scripts/qualities.lua` | belt tier and quality registries, built from the prototypes each load |
| `scripts/tally.lua` | what a click will cost, counted off the spec list; the label and the window both read it |
| `scripts/cursor/` | the cursor tracker |
| `scripts/preview.lua` | everything the player sees that is not an entity |
| `gui/` | the tool window |
| `dev/` | tests and notes; excluded from the build |

## Design notes

Four constraints shaped most of this, and they are not obvious from the outside:

**Factorio never tells a mod where the mouse is.** There is no API for it — only
`on_selected_entity_changed`. The cursor is located by blanketing the area in invisible
probe entities and watching which one the engine highlights, then subdividing it. Each
level of that search costs a tick, so the tracker guesses the whole chain from the last
known position rather than walking down it. Probe *roots* sit below ordinary entities in
selection priority, so the field does not steal the cursor from the rest of the game;
only the finer levels outrank real entities, and the tracker drops the selection as soon
as a probe has been subdivided so that only the leaf's box is ever drawn.

**Selection freezes while a mouse button is held.** Measured, not assumed. That is why
the opening gesture is two clicks rather than a drag: an area drawn by dragging cannot
show itself being made.

**The preview and the commit consume the same spec list.** What is drawn is what gets
built, including what will be cleared and where landfill goes. That invariant is the
mod's main promise, and it is the first thing to protect in any change.

**Everything is a ghost.** Nothing is built for real and no item is consumed, and
`undo_index` collapses a whole run into a single Ctrl+Z — felled trees and landfill
included. Water is covered with tile ghosts of whatever the terrain's own cover tile is —
landfill on Nauvis, foundation on lava, ice platform on Aquilo — so water is never modified directly.

One more worth recording, because it was a real bug: **what obstructs a belt is decided
by collision-mask intersection, not by entity type.** A list of harmless types is a
denylist by omission over every type in the game, and it classified construction robots
as buildings — so a bot drifting overhead refused the run, on the gesture most likely to
summon one.
