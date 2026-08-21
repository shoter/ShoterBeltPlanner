-- Data stage. Runs at every game load, before any world exists.
--
-- Available here: `data`, `mods`, `settings.startup`. NOT available: `game`,
-- `script`, `storage` -- those belong to control.lua.
--
-- The cursor tracker probes are deliberately NOT here: they are declared in
-- data-final-fixes.lua so that no other mod's data.raw sweep can rewrite them.

require("prototypes/belt-planner")
