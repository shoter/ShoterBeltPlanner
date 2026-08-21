-- The tool's window: belt tier, and the two decisions the brief asks to be
-- visible rather than buried in mod settings - whether to tunnel under things
-- and whether to landfill water.
--
-- It exists only while the tool is in hand, so it is built on taking the tool
-- and destroyed on putting it away. Nothing about it is persisted beyond the
-- per-player choices themselves.

local flib_gui = require("__flib__.gui")
local belts = require("scripts/belts")
local session = require("scripts/session")
local plan = require("scripts/logic/plan")

local planner_gui = {}

local ROOT = "beltplanner_window"

--------------------------------------------------------------------------------
-- handlers
--
-- Registered at file scope: flib requires the same registration on every load,
-- and a handler added conditionally would not survive a save/load.

local function on_option_toggled(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  local option = event.element.tags.option
  if not option then return end

  local pdata = session.get(event.player_index)
  pdata[option] = event.element.state

  -- The preview is planned from these, so it is now out of date.
  pdata.preview_tile = nil
  session.update_preview(player)
end

local function on_tier_clicked(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  local belt = event.element.tags.belt
  if not belt then return end

  session.set_belt(player, belt)
  planner_gui.refresh(player)
end

flib_gui.add_handlers({
  beltplanner_option_toggled = on_option_toggled,
  beltplanner_tier_clicked = on_tier_clicked,
})

--------------------------------------------------------------------------------
-- building

local function checkbox(option, caption, tooltip, state)
  return {
    type = "checkbox",
    name = "beltplanner_" .. option,
    caption = caption,
    tooltip = tooltip,
    state = state,
    tags = { option = option },
    handler = { [defines.events.on_gui_checked_state_changed] = on_option_toggled },
  }
end

--- The cliff switch only does anything once cliff explosives are researched, so
--- until then it is greyed out and its tooltip says why, rather than sitting
--- there looking like it should work. The planner gates on the same flag, so a
--- stale window cannot order what the robots would ignore.
local function cliffs_checkbox(player, pdata)
  local allowed = plan.can_clear_cliffs(player.force)
  local def = checkbox("clear_cliffs", { "beltplanner.gui-cliffs" },
    allowed and { "beltplanner.gui-cliffs-tip" } or { "beltplanner.gui-cliffs-locked-tip" },
    pdata.clear_cliffs)
  def.enabled = allowed
  return def
end

--- Research can finish while the window is open, so the switch is re-checked on
--- every refresh rather than only when the window is built.
local function refresh_cliffs_checkbox(player, body)
  local box = body["beltplanner_clear_cliffs"]
  if not box then return end

  local allowed = plan.can_clear_cliffs(player.force)
  if box.enabled == allowed then return end

  box.enabled = allowed
  box.tooltip = allowed and { "beltplanner.gui-cliffs-tip" } or { "beltplanner.gui-cliffs-locked-tip" }
end

--- Rebuild the window from scratch. Cheap enough at this size, and far less
--- error-prone than patching individual elements as options change.
function planner_gui.open(player)
  planner_gui.close(player)

  local pdata = session.get(player.index)
  session.ensure_defaults(player, pdata)

  local elems = flib_gui.add(player.gui.left, {
    type = "frame",
    name = ROOT,
    direction = "vertical",
    caption = { "beltplanner.gui-title" },
    {
      type = "frame",
      name = "beltplanner_body",
      style = "inside_shallow_frame_with_padding",
      direction = "vertical",
      { type = "label", style = "caption_label", caption = { "beltplanner.gui-belt" } },
      { type = "table", name = "beltplanner_tiers", column_count = 4 },
      { type = "line" },
      checkbox("landfill", { "beltplanner.gui-landfill" }, { "beltplanner.gui-landfill-tip" }, pdata.landfill),
      checkbox("clear_built", { "beltplanner.gui-clear" }, { "beltplanner.gui-clear-tip" }, pdata.clear_built),
      cliffs_checkbox(player, pdata),
      { type = "line" },
      { type = "label", name = "beltplanner_status", caption = "" },
    },
  })

  local chosen = pdata.tier or (belts.default() and belts.default().belt)
  for _, tier in ipairs(belts.all()) do
    flib_gui.add(elems.beltplanner_tiers, {
      type = "sprite-button",
      style = "slot_button",
      sprite = "item/" .. tier.item,
      tooltip = { "entity-name." .. tier.belt },
      toggled = tier.belt == chosen,
      tags = { belt = tier.belt },
      handler = { [defines.events.on_gui_click] = on_tier_clicked },
    })
  end

  planner_gui.refresh(player)
end

function planner_gui.close(player)
  local existing = player.gui.left[ROOT]
  if existing then existing.destroy() end
end

--- Update the parts that change without rebuilding: the chosen tier and the
--- one-line summary of the run in progress.
function planner_gui.refresh(player)
  local window = player.gui.left[ROOT]
  if not window then return end

  local pdata = session.get(player.index)
  local chosen = pdata.tier or (belts.default() and belts.default().belt)

  -- Indexing a LuaGuiElement by name only reaches its DIRECT children, so the
  -- body frame has to be stepped through rather than searched.
  local body = window["beltplanner_body"]
  if not body then return end

  local tiers = body["beltplanner_tiers"]
  if tiers then
    for _, button in pairs(tiers.children) do
      button.toggled = button.tags.belt == chosen
    end
  end

  refresh_cliffs_checkbox(player, body)

  local status = body["beltplanner_status"]
  if status then
    local anchor = pdata.anchor
    if anchor then
      status.caption = anchor.reversed
          and { "beltplanner.gui-status-reversed", anchor.lanes }
        or { "beltplanner.gui-status", anchor.lanes }
    elseif pdata.anchor_origin then
      status.caption = { "beltplanner.gui-status-sizing" }
    else
      status.caption = { "beltplanner.gui-status-idle" }
    end
  end
end

return planner_gui
