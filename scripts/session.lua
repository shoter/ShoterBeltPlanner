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

--- Seed this player's choices the first time they pick the tool up.
---
--- The per-user mod settings are the DEFAULT, not the live value: once the
--- window exists the player edits these directly, and two sources of truth for
--- the same switch would be a bug waiting to happen. The belt tier cannot be a
--- setting at all - the settings stage runs before any prototype exists, so
--- there is nothing to build an allowed_values list from.
function session.ensure_defaults(player, pdata)
  if pdata.landfill ~= nil then return end

  local per_user = settings.get_player_settings(player)
  pdata.landfill = per_user["beltplanner-use-landfill"].value
  pdata.clear_built = false
end

local function options_for(player, pdata)
  session.ensure_defaults(player, pdata)

  return {
    tier = (pdata.tier and belts.get(pdata.tier)) or belts.default(),
    landfill = pdata.landfill,
    max_tiles = settings.global["beltplanner-max-tiles"].value,
    -- Whether the player's own buildings may be cleared is a switch in the tool
    -- window and nothing else. It used to also be a held modifier, but a
    -- modifier cannot be read while the pointer is merely hovering, so the
    -- preview could not show what the click was going to do -- which for
    -- something that marks your factory for deconstruction is the wrong way
    -- round.
    clear_built = pdata.clear_built or false,
  }
end

--- Choose a belt tier by prototype name.
function session.set_belt(player, belt_name)
  local tier = belts.get(belt_name)
  if not tier then return end

  local pdata = session.get(player.index)
  pdata.tier = tier.belt
  player.play_sound { path = "utility/list_box_click" }

  pdata.preview_tile = nil
  session.update_preview(player)
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
  player.create_local_flying_text {
    text = { "beltplanner.belt-chosen", { "entity-name." .. chosen.belt } },
    create_at_cursor = true,
  }
  session.set_belt(player, chosen.belt)
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

  local resolved, unresolved = geometry.resolve(anchor, tile)
  if not resolved then
    preview.render(player, pdata, anchor)
    preview.show_problem(player, pdata, tile, unresolved)
    pdata.preview_tile = tile
    return
  end

  local options = options_for(player, pdata)
  local result, failure, blockers = plan.build(player.surface, player.force, anchor, resolved, options)

  preview.render(player, pdata, anchor, resolved, result, blockers)
  if not result then
    preview.show_problem(player, pdata, tile, failure)
  end
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

  if had_anchor and not quiet then
    player.create_local_flying_text { text = { "beltplanner.cancelled" }, create_at_cursor = true }
  end
end

--- The tool is in hand: start following the pointer.
function session.enter(player)
  local pdata = session.get(player.index)
  session.ensure_defaults(player, pdata)
  -- A previous failure switched the preview off; taking the tool out again is
  -- the retry.
  pdata.preview_broken = nil
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
local function commit(player, pdata, area, splitters)
  local anchor = pdata.anchor
  local x1, y1, x2, y2 = geometry.tile_bounds(area)
  local target = far_corner(anchor.tile, x1, y1, x2, y2)

  local resolved, reason = geometry.resolve(anchor, target)
  if not resolved then
    preview.say(player, reason)
    return
  end

  local options = options_for(player, pdata)
  options.splitters = splitters
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
--- This exists because Factorio raises nothing during a drag, so without the
--- press there is no way to know where the opening drag began.
function session.on_press(player, position)
  local pdata = session.get(player.index)

  if not pdata.anchor and position then
    local from = { x = math.floor(position.x), y = math.floor(position.y) }
    pdata.drag_from = from
    pdata.drag_tick = game.tick
    pdata.preview_tile = nil

    -- Mark the starting tile straight away rather than waiting for the tracker.
    -- Whether the engine keeps updating the selection while a mouse button is
    -- held is not something a mod can find out from the API, so the live growth
    -- of this box is best-effort; the press itself is not, and marking the
    -- origin means there is always SOME indication that a drag has begun.
    preview.show_drag(player, pdata, from, from)
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

--- Finish the run with a row of splitters instead of belts.
---
--- Otherwise identical to an ordinary commit, so the belts leading up to the
--- splitters and the clearing all behave exactly as they would have; only the
--- last tile of the run changes.
function session.on_splitter(player, area)
  local pdata = session.get(player.index)
  pdata.drag_from = nil
  pdata.preview_tile = nil

  if not pdata.anchor then
    preview.say(player, { "beltplanner.error-no-run" })
    return
  end

  commit(player, pdata, area, true)
end

return session
