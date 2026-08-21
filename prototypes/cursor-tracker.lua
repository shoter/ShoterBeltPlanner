-- The probe prototypes behind the cursor tracker.
--
-- Factorio deliberately exposes no mouse position -- the only per-tick signal a
-- mod gets about where the pointer is, is that LuaControl.selected changed. So
-- the cursor is found by covering the area in invisible selectable entities and
-- watching which one the engine highlights, narrowing the box each tick.
--
-- These are declared in data-final-fixes so that no other mod's data.raw sweep
-- rewrites them: a probe that gains a collision layer or loses its selection
-- box stops the tracker dead.

local const = require("scripts/cursor/const")

-- Probes sit on their own force and cannot be attacked, but a stray shot would
-- still log damage events, so make them immune to every damage type that exists
-- once every mod has declared its own.
local immune_to_everything = {}
for _, damage_type in pairs(data.raw["damage-type"]) do
  immune_to_everything[#immune_to_everything + 1] = { type = damage_type.name, percent = 100 }
end

local invisible = { filename = "__core__/graphics/empty.png", size = 64, priority = "very-low" }
local transparent = { 0, 0, 0, 0 }

local probes = {}

for _, level in ipairs(const.levels) do
  local half = level.half

  probes[#probes + 1] = {
    type = "simple-entity-with-owner",
    name = level.name,

    picture = invisible,

    -- The whole trick. On simple-entity-with-owner, selectability is decided by
    -- force diplomacy, and "not-friend" means "selectable by forces that are not
    -- my friend". Befriending the tracker force therefore switches every probe
    -- off at once, with no teleporting and no destroy/recreate.
    force_visibility = "not-friend",

    -- A child probe lies inside its parent, so both are under the cursor at the
    -- same moment; the finer box has to outrank the coarser one or the descent
    -- stalls one level up.
    selection_priority = level.selection_priority,
    selection_box = { { -half, -half }, { half, half } },

    -- A selection box this large does not behave without a collision box to
    -- match. The mask is empty, so the probe still collides with nothing and
    -- probes freely overlap each other and the world.
    collision_box = { { -half, -half }, { half, half } },
    collision_mask = { layers = {} },

    flags = {
      "placeable-off-grid",           -- probes are centred on a 2^pow grid, not the tile grid
      "not-on-map",
      "not-blueprintable",
      "not-deconstructable",
      "not-flammable",
      "not-repairable",
      "not-upgradable",
      "not-in-kill-statistics",
      "not-in-made-in",
      "not-rotatable",
      "no-copy-paste",
      "hide-alt-info",
      "no-automated-item-insertion",
      "no-automated-item-removal",
    },

    max_health = 1,
    resistances = immune_to_everything,
    minable = nil,

    hidden = true,
    hidden_in_factoriopedia = true,
    remove_decoratives = "false",
    map_color = transparent,
    friendly_map_color = transparent,
    enemy_map_color = transparent,
  }
end

data:extend(probes)
