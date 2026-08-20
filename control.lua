-- Control stage. Runs when a save is created or loaded, and then during play.
--
-- Available here: `game`, `script`, `storage`, `defines`, `prototypes`. Prototypes can be read
-- but never created or changed from here.
--
-- Rules this file exists to keep straight:
--   * all persistent state lives in `storage`, and only serialisable values go in it;
--   * event handlers are registered at the top level, never inside a condition;
--   * `on_built_entity` and friends are always registered with a filter.

--- Creates the storage keys this mod needs, leaving any that already exist untouched.
---
--- Called from both bootstrap hooks on purpose: `on_init` covers a fresh save and this mod being
--- added to an existing one, `on_configuration_changed` covers an update to a save that has run
--- an older version and is therefore missing whatever keys that version did not have.
local function init_storage()
  storage.players = storage.players or {}
end

script.on_init(init_storage)
script.on_configuration_changed(init_storage)

-- Event handlers go below, e.g.:
--
-- script.on_event(defines.events.on_player_selected_area, function(event)
--   if event.item ~= "belt-planner" then return end
--   ...
-- end)
