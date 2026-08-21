-- The tool itself: one selection tool, reachable from a shortcut and a hotkey.
--
-- The tool is only ever in the cursor. It is not craftable, not an inventory
-- item and not in Factoriopedia, so the mod adds nothing to a savegame's item
-- economy and can be removed again without stranding anything.

local TOOL = "beltplanner-tool"

-- A filter target that is never placed in the world. See selection_mode below.
local SENTINEL = "beltplanner-never-placed"

-- A selection tool must define `select` and `alt_select`; the other three modes
-- are optional and each raises its own event.
--
-- This tool wants the dragged AREA and no entities at all. `mode = "nothing"`
-- reads like the way to say that, but it makes the drag inert -- every shipped
-- area tool instead asks for "any-entity" and then pins the filters to something
-- that cannot match. The tile pin is separately necessary: entity_filters does
-- not exclude tile-ghosts, because a tile-ghost is an entity, and "water-wube"
-- is a vanilla tile the map generator never produces.
local function selection_mode(colour, box)
  return {
    border_color = colour,
    cursor_box_type = box,
    mode = "any-entity",
    entity_filter_mode = "whitelist",
    entity_filters = { SENTINEL },
    tile_filter_mode = "whitelist",
    tile_filters = { "water-wube" },
  }
end

data:extend({
  -- Exists only to be named by the selection filters above. Nothing ever creates
  -- one, so the whitelist matches nothing and the tool collects no entities.
  {
    type = "simple-entity-with-owner",
    name = SENTINEL,
    picture = { filename = "__core__/graphics/empty.png", size = 64, priority = "very-low" },
    flags = { "not-on-map", "not-blueprintable", "not-deconstructable", "placeable-off-grid" },
    collision_mask = { layers = {} },
    selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
    hidden = true,
    hidden_in_factoriopedia = true,
  },

  {
    type = "selection-tool",
    name = TOOL,

    icon = "__ShoterBeltPlanner__/graphics/icons/belt-planner.png",
    icon_size = 64,

    stack_size = 1,
    flags = { "only-in-cursor", "not-stackable", "spawnable" },
    hidden = true,
    hidden_in_factoriopedia = true,
    auto_recycle = false,

    -- draw the anchor, then each endpoint
    select = selection_mode({ 60, 220, 90 }, "copy"),
    -- reserved: force a fresh anchor even mid-run
    alt_select = selection_mode({ 90, 160, 240 }, "copy"),
    -- cancel the run
    reverse_select = selection_mode({ 230, 80, 80 }, "not-allowed"),
    -- finish the run with a row of splitters
    alt_reverse_select = selection_mode({ 150, 200, 255 }, "pair"),
  },

  {
    type = "shortcut",
    name = "beltplanner-shortcut",
    order = "b[blueprints]-z[belt-planner]",
    action = "spawn-item",
    item_to_spawn = TOOL,
    associated_control_input = "beltplanner-get-tool",
    style = "blue",
    icon = "__ShoterBeltPlanner__/graphics/shortcut/belt-planner-x32.png",
    icon_size = 32,
    small_icon = "__ShoterBeltPlanner__/graphics/shortcut/belt-planner-x24.png",
    small_icon_size = 24,
  },

  -- action = "spawn-item" is executed by the engine, so putting the tool in hand
  -- needs no control-stage code at all.
  {
    type = "custom-input",
    name = "beltplanner-get-tool",
    key_sequence = "ALT + B",
    action = "spawn-item",
    item_to_spawn = TOOL,
    order = "a",
  },

  -- Flip which way the belts face without changing the geometry, so a run can be
  -- built from its destination back to its source. Linked to the vanilla rotate
  -- control so it uses whatever key the player already rotates with.
  {
    type = "custom-input",
    name = "beltplanner-flip",
    key_sequence = "",
    linked_game_control = "rotate",
    consuming = "none",
    order = "b",
  },

  -- Factorio raises no event while a selection is dragged, and selection events
  -- carry no modifier information, so a mouse-down hook is the only way to learn
  -- where a drag began or whether Ctrl was down for it. consuming = "none" is
  -- essential: these must observe the click, never swallow it.
  {
    type = "custom-input",
    name = "beltplanner-press",
    key_sequence = "mouse-button-1",
    consuming = "none",
    order = "d",
  },
  {
    type = "custom-input",
    name = "beltplanner-ctrl-press",
    key_sequence = "CONTROL + mouse-button-1",
    consuming = "none",
    order = "e",
  },
  -- The same thing again through the vanilla control that actually starts a
  -- selection. A raw mouse-button-1 binding may not survive the selection tool
  -- taking the click; this one cannot miss it, whatever the player has bound.
  {
    type = "custom-input",
    name = "beltplanner-select-press",
    key_sequence = "",
    linked_game_control = "select-for-blueprint",
    consuming = "none",
    order = "f",
  },

  -- Step through the belt tiers without leaving the tool.
  {
    type = "custom-input",
    name = "beltplanner-cycle-belt",
    key_sequence = "SHIFT + B",
    consuming = "none",
    order = "c",
  },
  -- And back again. Ctrl + Shift + B is unbound in vanilla (B and Alt + B are
  -- the blueprint keys) and clear of this mod's own Ctrl + B and Alt + B.
  -- Factorio matches modifiers exactly, so holding Ctrl as well does not also
  -- fire the forward step.
  {
    type = "custom-input",
    name = "beltplanner-cycle-belt-back",
    key_sequence = "CONTROL + SHIFT + B",
    consuming = "none",
    order = "c-back",
  },

  -- The tool has eight gestures and nothing in the game explains them. A tips
  -- entry is where a player already looks. starting_status = "unlocked" makes it
  -- readable from the start rather than waiting on a trigger it will never get.
  {
    type = "tips-and-tricks-item",
    name = "beltplanner-tips",
    category = "ghost-building",
    order = "z[belt-planner]",
    starting_status = "unlocked",
    icon = "__ShoterBeltPlanner__/graphics/icons/belt-planner.png",
    icon_size = 64,
  },

  -- M0 scaffolding: drive the cursor tracker on its own, without the tool.
  {
    type = "custom-input",
    name = "beltplanner-toggle-tracker",
    key_sequence = "CONTROL + B",
    consuming = "none",
    order = "z",
  },
})
