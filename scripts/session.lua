-- Per-player planning session: what the tool is currently anchored to, and what
-- each gesture does about it.
--
-- The state machine is deliberately two states. With no anchor, a selection sets
-- one. With an anchor, a selection commits a run and re-anchors at its far end,
-- which is what lets the player keep clicking to extend.
--
-- The cursor tracker runs for as long as the tool is in hand, not just while a
-- run is open: the opening drag needs a live pointer before any anchor exists.
-- It stops the moment the tool is put away, so probes never outlive the tool.

local geometry = require("scripts/geometry")
local belts = require("scripts/belts")
local plan = require("scripts/logic/plan")
local place = require("scripts/logic/place")
local preview = require("scripts/preview")
local tracker = require("scripts/cursor/tracker")

local session = {}

--------------------------------------------------------------------------------
-- state

function session.get(player_index)
  local pdata = storage.players[player_index]
  if not pdata then
    pdata = {}
    storage.players[player_index] = pdata
  end
  return pdata
end

-- The belt tier cannot be a mod setting: the settings stage runs before the data
-- stage, so no belt prototype exists yet to build an allowed_values list from.
-- It lives in storage and is cycled at runtime instead.
local function options_for(player, pdata, clear_built)
  local per_user = settings.get_player_settings(player)

  return {
    tier = (pdata.tier and belts.get(pdata.tier)) or belts.default(),
    landfill = per_user["beltplanner-use-landfill"].value,
    tunnels = per_user["beltplanner-use-tunnels"].value,
    max_tiles = settings.global["beltplanner-max-tiles"].value,
    clear_built = clear_built or false,
  }
end

-- How long a mouse-down counts for. The selection event arrives on release, so
-- this only has to outlive a click, not a whole drag.
local CTRL_GRACE_TICKS = 120

--- Was Ctrl held for the click we are handling?
---
--- Selection events carry no modifier information at all, so this is recovered
--- from a custom input bound to CONTROL + mouse-button-1, which fires on the
--- press that precedes the release we are reacting to.
local function ctrl_held(pdata)
  return pdata.ctrl_tick ~= nil and (game.tick - pdata.ctrl_tick) <= CTRL_GRACE_TICKS
end

--- Step to the next belt tier, slowest to fastest, wrapping round.
function session.cycle_belt(player)
  local pdata = session.get(player.index)
  local order = belts.all()
  if #order == 0 then return end

  local current = pdata.tier or belts.default().belt
  local index = 1
  for i, tier in ipairs(order) do
    if tier.belt == current then
      index = i
      break
    end
  end

  local chosen = order[(index % #order) + 1]
  pdata.tier = chosen.belt
  player.create_local_flying_text {
    text = { "beltplanner.belt-chosen", { "entity-name." .. chosen.belt } },
    create_at_cursor = true,
  }
  player.play_sound { path = "utility/list_box_click" }

  pdata.preview_tile = nil
  session.update_preview(player)
end

--------------------------------------------------------------------------------
-- live preview

--- Re-plan from wherever the pointer is and redraw. Cheap to call often: it
--- returns immediately unless the pointer has crossed into a different tile,
--- because re-planning and rebuilding a few hundred render objects per tick
--- would be felt.
function session.update_preview(player)
  local pdata = session.get(player.index)
  local tile = tracker.get_tile(player.index)
  if not tile then return end

  local last = pdata.preview_tile
  local anchor = pdata.anchor

  -- No anchor yet: if the button is down, this is the opening drag, and the
  -- squares can be shown as it is being made.
  if not anchor then
    if not pdata.drag_from then return end

    -- A press with no matching release means the selection never happened
    -- (cancelled, or the click went somewhere else). Do not leave it armed.
    if game.tick - (pdata.drag_tick or 0) > 3600 then
      pdata.drag_from = nil
      preview.clear(pdata)
      return
    end

    if last and last.x == tile.x and last.y == tile.y then return end
    preview.show_drag(player, pdata, pdata.drag_from, tile)
    pdata.preview_tile = tile
    return
  end

  if last and last.x == tile.x and last.y == tile.y then return end

  local resolved = geometry.resolve(anchor, tile)
  if not resolved then
    preview.render(player, pdata, anchor)
    pdata.preview_tile = tile
    return
  end

  local options = options_for(player, pdata)
  local result, _, blockers = plan.build(player.surface, player.force, anchor, resolved, options)

  preview.render(player, pdata, anchor, resolved, result, blockers)
  pdata.preview_tile = tile
end

--------------------------------------------------------------------------------
-- gestures

--- Abandon the current run. The tracker keeps running: it belongs to the tool
--- being in hand, not to a run being in progress, because the opening drag needs
--- a live pointer before any anchor exists.
function session.cancel(player, quiet)
  local pdata = session.get(player.index)
  local had_anchor = pdata.anchor ~= nil

  preview.clear(pdata)
  pdata.anchor = nil
  pdata.preview_tile = nil
  pdata.drag_from = nil
  pdata.ctrl_tick = nil

  if had_anchor and not quiet then
    player.create_local_flying_text { text = { "beltplanner.cancelled" }, create_at_cursor = true }
  end
end

--- The tool is in hand: start following the pointer.
function session.enter(player)
  tracker.start(player)
end

--- The tool is gone. Everything this mod owns goes with it.
function session.leave(player)
  session.cancel(player, true)
  tracker.stop(player.index)
end

function session.flip(player)
  local pdata = session.get(player.index)
  if not pdata.anchor then return false end

  pdata.anchor.reversed = not pdata.anchor.reversed
  player.play_sound { path = "utility/rotated_medium" }

  pdata.preview_tile = nil
  session.update_preview(player)
  return true
end

--- The corner of the dragged box furthest from the anchor, per axis. A plain
--- click collapses the box to one tile, so both corners agree and this reduces
--- to "the tile you clicked".
local function far_corner(origin, x1, y1, x2, y2)
  return {
    x = math.abs(x2 - origin.x) >= math.abs(x1 - origin.x) and x2 or x1,
    y = math.abs(y2 - origin.y) >= math.abs(y1 - origin.y) and y2 or y1,
  }
end

--- A selection with no anchor set: open a run.
local function set_anchor(player, pdata, area)
  local anchor, reason = geometry.anchor_from_area(area)
  if not anchor then
    preview.say(player, reason)
    return
  end

  pdata.anchor = anchor
  pdata.preview_tile = nil
  preview.render(player, pdata, anchor)

  -- Every utility sound named in this file is checked against
  -- data.raw["utility-sounds"].default; an invented name is a hard crash, not a
  -- silent no-op. rail_plan_start is the engine's own "planning tool armed" cue.
  player.play_sound { path = "utility/rail_plan_start" }
end

--- A selection with an anchor set: plan, commit, and move the anchor to the far
--- end so the next click continues from there.
local function commit(player, pdata, area)
  local anchor = pdata.anchor
  local x1, y1, x2, y2 = geometry.tile_bounds(area)
  local target = far_corner(anchor.tile, x1, y1, x2, y2)

  local resolved, reason = geometry.resolve(anchor, target)
  if not resolved then
    preview.say(player, reason)
    return
  end

  -- Ctrl on the click that opened this selection means "clear whatever I built
  -- that is in the way too", not just trees and rocks.
  local options = options_for(player, pdata, ctrl_held(pdata))
  local result, failure, blockers = plan.build(player.surface, player.force, anchor, resolved, options)

  if not result then
    preview.say(player, failure)
    preview.flash_blockers(player, blockers)
    return
  end

  local created = place.execute(player.surface, player.force, player, result.specs)
  if created == 0 then
    preview.say(player, { "beltplanner.error-nothing-placed" })
    return
  end

  -- The anchor keeps the axis and width but jumps to the end of what was just
  -- placed, so a second click extends the same run rather than starting over.
  local next_anchor = geometry.next_anchor(anchor, resolved)
  next_anchor.reversed = anchor.reversed
  pdata.anchor = next_anchor
  pdata.preview_tile = nil

  preview.render(player, pdata, next_anchor)
  player.play_sound { path = "utility/build_blueprint_medium" }
end

--- Mouse-down while the tool is held.
---
--- This exists because Factorio raises nothing during a drag: without the press
--- we would know neither where the opening drag began nor whether Ctrl was
--- down, since selection events carry no modifier information.
function session.on_press(player, position, ctrl)
  local pdata = session.get(player.index)

  pdata.ctrl_tick = ctrl and game.tick or nil

  if not pdata.anchor and position then
    pdata.drag_from = { x = math.floor(position.x), y = math.floor(position.y) }
    pdata.drag_tick = game.tick
    pdata.preview_tile = nil
  end
end

--- `select` and `alt_select` both land here; alt forces a fresh anchor.
function session.on_select(player, area, force_new_anchor)
  local pdata = session.get(player.index)

  -- The drag is over, whatever it produced.
  pdata.drag_from = nil
  pdata.preview_tile = nil

  if force_new_anchor or not pdata.anchor then
    set_anchor(player, pdata, area)
  else
    commit(player, pdata, area)
  end
end

return session
