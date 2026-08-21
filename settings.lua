-- Settings stage. Runs before data.lua.
--
-- The belt tier is deliberately NOT here: this stage runs before any prototype
-- exists, so there is nothing to build an allowed_values list from. It is chosen
-- at runtime and kept in storage instead.

data:extend({
  {
    -- The ceiling on how much work one click may ask for. A run is planned in a
    -- single tick, so this is what stops a stray click across the map from
    -- stalling the game.
    type = "int-setting",
    name = "beltplanner-max-tiles",
    setting_type = "runtime-global",
    default_value = 2000,
    minimum_value = 50,
    maximum_value = 100000,
    order = "a",
  },
  {
    type = "bool-setting",
    name = "beltplanner-use-landfill",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "c",
  },
})
