-- The tool's window: belt tier, the quality to place at when there is more than
-- one, and the two decisions the brief asks to be visible rather than buried in
-- mod settings - whether to tunnel under things and whether to landfill water.
--
-- It exists only while the tool is in hand, so it is built on taking the tool
-- and destroyed on putting it away. Nothing about it is persisted beyond the
-- per-player choices themselves.

local flib_gui = require("__flib__.gui")
local belts = require("scripts/belts")
local qualities = require("scripts/qualities")
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

local function on_quality_clicked(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  local quality = event.element.tags.quality
  if not quality then return end

  session.set_quality(player, quality)
  planner_gui.refresh(player)
end

flib_gui.add_handlers({
  beltplanner_option_toggled = on_option_toggled,
  beltplanner_tier_clicked = on_tier_clicked,
  beltplanner_quality_clicked = on_quality_clicked,
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

--- The quality choice: a caption and one slot button per selectable quality,
--- lowest first, in the same shape as the belt tier row above it.
---
--- Only built when there is a choice to make. A base-game-only install has a
--- single selectable quality, and a row offering one option would be noise that
--- also made the window taller for nothing.
local function add_quality_row(flow, pdata)
  if not qualities.selectable() then return end

  local chosen = session.quality_of(pdata).name

  local elems = flib_gui.add(flow, {
    { type = "label", style = "caption_label", caption = { "beltplanner.gui-quality" } },
    { type = "table", name = "beltplanner_qualities", column_count = 5 },
  })

  for _, quality in ipairs(qualities.all()) do
    flib_gui.add(elems.beltplanner_qualities, {
      type = "sprite-button",
      style = "slot_button",
      sprite = "quality/" .. quality.name,
      tooltip = quality.localised_name,
      toggled = quality.name == chosen,
      tags = { quality = quality.name },
      handler = { [defines.events.on_gui_click] = on_quality_clicked },
    })
  end

  flow.visible = true
end

--- Re-mark which quality button is the chosen one. A no-op when the row was
--- never built.
local function refresh_quality_row(body, pdata)
  local flow = body["beltplanner_quality"]
  local buttons = flow and flow["beltplanner_qualities"]
  if not buttons then return end

  local chosen = session.quality_of(pdata).name
  for _, button in pairs(buttons.children) do
    button.toggled = button.tags.quality == chosen
  end
end

--- Whether a tier button is clickable for this player, and what it says when
--- hovered. A tier the force has not researched stays visible but greyed out,
--- so the player can see what is coming without being handed a ghost nobody on
--- the force can build yet.
local function tier_availability(player, tier)
  if belts.unlocked(player.force, tier.belt) then
    return true, { "entity-name." .. tier.belt }
  end
  return false, { "beltplanner.gui-tier-locked", { "entity-name." .. tier.belt } }
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
      -- Filled in and shown by add_quality_row only when there is a quality to
      -- choose. Invisible elements take no space, so without one the window is
      -- pixel for pixel what it was before quality existed.
      { type = "flow", name = "beltplanner_quality", direction = "vertical", visible = false },
      { type = "line" },
      checkbox("landfill", { "beltplanner.gui-landfill" }, { "beltplanner.gui-landfill-tip" }, pdata.landfill),
      checkbox("clear_built", { "beltplanner.gui-clear" }, { "beltplanner.gui-clear-tip" }, pdata.clear_built),
      cliffs_checkbox(player, pdata),
      { type = "line" },
      { type = "label", name = "beltplanner_status", caption = "" },
      { type = "label", name = "beltplanner_tally", caption = "" },
    },
  })

  local chosen = pdata.tier or (belts.default() and belts.default().belt)
  for _, tier in ipairs(belts.all()) do
    local enabled, tooltip = tier_availability(player, tier)
    flib_gui.add(elems.beltplanner_tiers, {
      type = "sprite-button",
      style = "slot_button",
      sprite = "item/" .. tier.item,
      tooltip = tooltip,
      enabled = enabled,
      toggled = tier.belt == chosen,
      tags = { belt = tier.belt },
      handler = { [defines.events.on_gui_click] = on_tier_clicked },
    })
  end

  add_quality_row(elems.beltplanner_quality, pdata)

  planner_gui.refresh(player)
end

function planner_gui.close(player)
  local existing = player.gui.left[ROOT]
  if existing then existing.destroy() end
end

--- Update the parts that change without rebuilding: the chosen tier, which
--- tiers the force has researched, the switches that depend on research, and
--- the status lines for the run in progress.
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
      -- Research can finish or be reversed while the window is open, so the
      -- greying is re-read here rather than fixed when the button was made.
      local tier = belts.get(button.tags.belt)
      if tier then
        local enabled, tooltip = tier_availability(player, tier)
        button.enabled = enabled
        button.tooltip = tooltip
      end
    end
  end

  refresh_cliffs_checkbox(player, body)
  refresh_quality_row(body, pdata)
  planner_gui.refresh_status(player, pdata.summary)
end

--- The two status lines: what the run is, and what the click will cost.
---
--- `summary` is what session last handed over through its hook, or nil. With a
--- planned run in hand the first line is the run's own description - lanes,
--- tiles, throughput - with the gesture hints after it, and the second line is
--- the tally; these are the very same LocalisedStrings the cursor label draws.
--- Without one the lines fall back to the state texts, so a refusal or a pointer
--- off the map reads as "running" rather than as a stale count.
function planner_gui.refresh_status(player, summary)
  local window = player.gui.left[ROOT]
  if not window then return end

  local body = window["beltplanner_body"]
  if not body then return end

  local status = body["beltplanner_status"]
  local cost = body["beltplanner_tally"]
  if not status then return end

  local pdata = session.get(player.index)
  local anchor = pdata.anchor

  if anchor and summary then
    status.caption = { "beltplanner.gui-status-planned", summary.run }
    if cost then
      -- Hidden rather than blanked: an empty label still takes a row.
      cost.caption = summary.cost or ""
      cost.visible = summary.cost ~= nil
    end
    return
  end

  if anchor then
    status.caption = anchor.reversed
        and { "beltplanner.gui-status-reversed", anchor.lanes }
      or { "beltplanner.gui-status", anchor.lanes }
  elseif pdata.anchor_origin then
    status.caption = { "beltplanner.gui-status-sizing" }
  else
    status.caption = { "beltplanner.gui-status-idle" }
  end
  if cost then
    cost.caption = ""
    cost.visible = false
  end
end

--- Refresh the window of everyone on a force who has it open. Research is a
--- property of the force, so when a belt technology finishes - or is reversed -
--- every window on that force is out of date at once. refresh itself returns
--- straight away for a player without the window.
function planner_gui.refresh_force(force)
  for _, player in pairs(force.connected_players) do
    planner_gui.refresh(player)
  end
end

--------------------------------------------------------------------------------
-- session hook

-- session cannot require this file - this file requires session - so it leaves
-- a hook for the window to fill in. Set at file scope so it is in place on every
-- load, the same as the handlers above.
session.on_summary = function(player, summary)
  planner_gui.refresh_status(player, summary)
end

return planner_gui
