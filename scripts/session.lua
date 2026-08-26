-- Per-player planning session: what the tool is currently anchored to, and what
-- each gesture does about it.
--
-- Three states. With nothing started, a click begins sizing the anchor. While
-- sizing, the marked area follows the pointer and the next click accepts it.
-- With an anchor, a click commits a run and re-anchors at its far end, which is
-- what lets the player keep clicking to extend.
--
-- Sizing is two clicks rather than a drag for a measured reason: Factorio stops
-- updating LuaControl.selected while a mouse button is held, so the cursor
-- tracker goes blind for the whole of a drag and an area that grows as it is
-- drawn is simply not achievable that way. Between two clicks nothing is held
-- and the pointer is tracked normally. A drag is still accepted, since the area
-- it reports is the whole answer; it just cannot show itself being made.
--
-- The cursor tracker runs for as long as the tool is in hand, not only while a
-- run is open, and stops the moment the tool is put away.

local geometry = require("scripts/geometry")
local belts = require("scripts/belts")
local qualities = require("scripts/qualities")
local plan = require("scripts/logic/plan")
local place = require("scripts/logic/place")
local preview = require("scripts/preview")
local tracker = require("scripts/cursor/tracker")
local tally = require("scripts/tally")

local session = {}

--------------------------------------------------------------------------------
-- summary hook

--- Called as function(player, summary) whenever the preview's reading of the run
--- changes: tally.summary's result while a run is planned, nil when there is
--- nothing planned or the plan was refused.
---
--- The tool window shows the same tally as the cursor label, and it is updated
--- from here rather than polled, because the window only redraws on events and
--- the preview re-plans on every tile the pointer crosses. The window requires
--- this module, so this module cannot require the window; it leaves a hook
--- instead, which gui/planner_gui.lua fills in at file scope.
session.on_summary = nil

--- Remember the current summary and tell whoever is listening, but only when
--- it actually changed: the window would otherwise be rewritten on every call
--- that merely confirms there is still nothing to say.
---
--- The summary lives in pdata so the window's event-driven refresh can show it
--- again without re-planning, and it is cleared wherever the run it describes
--- stops being the run in hand.
local function set_summary(player, pdata, summary)
  if summary == nil and pdata.summary == nil then return end
  pdata.summary = summary
  if session.on_summary then
    session.on_summary(player, summary)
  end
end

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
  -- The settled case - both fields already seeded - is hit on every re-plan,
  -- one per tile the pointer crosses, and get_player_settings is a Lua-to-C++
  -- crossing that allocates. Once there is nothing left to seed, the settings
  -- are not worth asking for.
  if pdata.landfill ~= nil and pdata.clear_cliffs ~= nil then return end

  local per_user = settings.get_player_settings(player)

  if pdata.landfill == nil then
    pdata.landfill = per_user["beltplanner-use-landfill"].value
    pdata.clear_built = false
  end

  -- Seeded on its own rather than under the landfill guard, because a player
  -- who picked the tool up before this switch existed already has `landfill`
  -- set and would otherwise never receive it.
  if pdata.clear_cliffs == nil then
    pdata.clear_cliffs = per_user["beltplanner-clear-cliffs"].value
  end
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
    -- Same shape as clear_built. Whether the force is actually allowed to blow
    -- cliffs up is the planner's decision, not this one's, so an early tick of
    -- the switch cannot order something the robots would ignore.
    clear_cliffs = pdata.clear_cliffs or false,
    -- The quality the ghosts are placed at. Nil is "normal", which is what every
    -- ghost got before this choice existed, so a save from then needs no
    -- migration; a name that no longer exists (its mod was removed) falls back
    -- the same way rather than asking create_entity for something unknown.
    quality = session.quality_of(pdata).name,
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

--- Step to the next belt tier the player's force can build, wrapping round.
--- `direction` is +1 towards faster (the default) or -1 towards slower.
---
--- Tiers the force has not researched are skipped rather than offered: a ghost
--- for a belt nobody can craft is a ghost that sits there forever, and the
--- window greys those tiers out for the same reason. If research is reversed
--- under a chosen tier the choice is left alone - the player made it, and the
--- next keypress moves off it like any other step.
function session.cycle_belt(player, direction)
  local pdata = session.get(player.index)
  if not belts.default() then return end

  local current = pdata.tier or belts.default().belt
  local chosen = belts.step(player.force, current, direction)
  if not chosen then return end

  player.create_local_flying_text {
    text = { "beltplanner.belt-chosen", { "entity-name." .. chosen.belt } },
    create_at_cursor = true,
  }
  session.set_belt(player, chosen.belt)
end

--------------------------------------------------------------------------------
-- quality

--- The quality record the player's choice resolves to. Always a real,
--- selectable quality: see the note in options_for.
function session.quality_of(pdata)
  return qualities.get(pdata.quality) or qualities.default()
end

--- Choose a quality by prototype name.
function session.set_quality(player, quality_name)
  local quality = qualities.get(quality_name)
  if not quality then return end

  local pdata = session.get(player.index)
  pdata.quality = quality.name
  player.play_sound { path = "utility/list_box_click" }

  -- The preview is planned from this, so it is now out of date.
  pdata.preview_tile = nil
  session.update_preview(player)
end

--- Step one quality up (step = 1) or down (step = -1), wrapping round.
---
--- Does nothing at all when there is only one quality to choose from: the
--- hotkeys are linked to the vanilla quality-cycling controls, which exist
--- whether or not quality is in play, and on an install without it the tool
--- must stay exactly as silent as it was.
function session.cycle_quality(player, step)
  if not qualities.selectable() then return end

  local pdata = session.get(player.index)
  local order = qualities.all()
  local current = session.quality_of(pdata).name
  local index = 1
  for i, quality in ipairs(order) do
    if quality.name == current then
      index = i
      break
    end
  end

  local chosen = order[((index - 1 + step) % #order) + 1]
  player.create_local_flying_text {
    text = { "beltplanner.quality-chosen", chosen.localised_name },
    create_at_cursor = true,
  }
  session.set_quality(player, chosen.name)
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
  if not tile then
    -- Nothing to project from. Fall back to what is actually settled - the
    -- anchor alone, or nothing at all - rather than leaving a run drawn towards
    -- wherever the pointer was last seen. Once rather than on every call, since
    -- this runs repeatedly while a descent converges.
    --
    -- Hovering the tool window is deliberately NOT this case: the tracker keeps
    -- its last tile then, which is what lets a checkbox re-plan the run under
    -- the pointer instead of blanking it.
    if pdata.preview_tile ~= nil then
      pdata.preview_tile = nil
      preview.render(player, pdata, pdata.anchor)
      set_summary(player, pdata, nil)
    end
    return
  end

  local last = pdata.preview_tile
  local anchor = pdata.anchor

  if not anchor then
    -- Sizing: the first click has landed and the second has not. No button is
    -- held, so the pointer is tracked properly and the marked area can follow it
    -- - which is exactly what a held drag can never do.
    if pdata.anchor_origin then
      if last and last.x == tile.x and last.y == tile.y then return end
      local candidate = geometry.anchor_between(pdata.anchor_origin, tile)
      if candidate then
        preview.show_candidate(player, pdata, candidate)
      end
      pdata.preview_tile = tile
      return
    end

    -- A drag is still allowed, and still completes an anchor in one gesture. It
    -- cannot grow as it is made, so all it gets is its starting tile marked.
    if not pdata.drag_from then return end

    -- A press with no matching release means the selection never happened
    -- (cancelled, or the click went somewhere else). Do not leave it armed.
    if game.tick - (pdata.drag_tick or 0) > 3600 then
      pdata.drag_from = nil
      preview.clear(pdata)
      return
    end

    if last and last.x == tile.x and last.y == tile.y then return end

    -- Counted so the diagnostics can say whether the engine keeps updating the
    -- selection while a mouse button is held. If this stays at zero for a whole
    -- drag, a live rectangle is not possible and the tool should stop pretending
    -- otherwise.
    pdata.drag_updates = (pdata.drag_updates or 0) + 1

    preview.show_drag(player, pdata, pdata.drag_from, tile)
    pdata.preview_tile = tile
    return
  end

  if last and last.x == tile.x and last.y == tile.y then return end

  local resolved, unresolved = geometry.resolve(anchor, tile)
  if not resolved then
    preview.render(player, pdata, anchor)
    preview.show_problem(player, pdata, tile, unresolved)
    set_summary(player, pdata, nil)
    pdata.preview_tile = tile
    return
  end

  local options = options_for(player, pdata)
  local result, failure, blockers = plan.build(player.surface, player.force, anchor, resolved, options)

  -- One reading of the result for both the label and the window, so the two
  -- can never quote different numbers. A refusal has no tally: the window goes
  -- back to its plain status and the reason is shown at the cursor.
  local summary = result and tally.summary(anchor, result, options.tier) or nil

  preview.render(player, pdata, anchor, resolved, result, blockers, summary)
  if not result then
    preview.show_problem(player, pdata, tile, failure)
  end
  set_summary(player, pdata, summary)
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

  local was_sizing = pdata.anchor_origin ~= nil

  preview.clear(pdata)
  pdata.anchor = nil
  pdata.anchor_origin = nil
  pdata.preview_tile = nil
  pdata.drag_from = nil
  set_summary(player, pdata, nil)

  if (had_anchor or was_sizing) and not quiet then
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
  -- Remembered so a controller change can tell whether the run is still on the
  -- surface it was planned on. Every surface change re-enters, so this is always
  -- the surface any anchor was made on.
  pdata.surface_index = player.surface.index
  tracker.start(player)
end

--- The tool is gone. Everything this mod owns goes with it.
function session.leave(player)
  session.cancel(player, true)
  tracker.stop(player.index)
end

--- The player's controller changed while the tool stayed in hand: entering or
--- leaving remote view, mostly. The pointer is now somewhere else, and may be
--- on another surface, and the engine does not always announce the surface part
--- of that separately.
---
--- A run anchored on this same surface is still exactly where it was made, and
--- stepping out to the map to see where a long run should end is a perfectly
--- good reason to change controller, so it is kept. Only the probe field has to
--- be rebuilt, around wherever the pointer has gone. A different surface is a
--- different matter: the anchor names tiles that are not here, so that is the
--- same as a surface change.
function session.relocate(player)
  local pdata = session.get(player.index)
  if not tracker.is_tracking(player.index) or pdata.surface_index ~= player.surface.index then
    -- Either the tool arrived in the cursor by way of the controller change
    -- itself, with no cursor-stack event to set things up, or the surface is
    -- not the one the run was made on. Both are a fresh start.
    session.leave(player)
    session.enter(player)
    return
  end
  -- start() clears any field it finds first, so this is a restart.
  tracker.start(player)
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

--- Adopt a finished anchor and start planning from it.
---
--- Every utility sound named in this file is checked against
--- data.raw["utility-sounds"].default; an invented name is a hard crash, not a
--- silent no-op. rail_plan_start is the engine's own "planning tool armed" cue.
local function accept_anchor(player, pdata, anchor)
  pdata.anchor = anchor
  pdata.anchor_origin = nil
  pdata.preview_tile = nil
  set_summary(player, pdata, nil)
  preview.render(player, pdata, anchor)
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

  -- The anchor keeps the axis and width but jumps to the end of what was just
  -- placed, so a second click extends the same run rather than starting over.
  local next_anchor = geometry.next_anchor(anchor, resolved)
  next_anchor.reversed = anchor.reversed

  -- Both ends of that jump go onto the undo item, so Ctrl+Z can walk the anchor
  -- back along with the ghosts and Ctrl+Y can walk it forward again. See
  -- session.on_undo.
  local undo_tag = {
    before = geometry.anchor_snapshot(anchor),
    after = geometry.anchor_snapshot(next_anchor),
  }

  local created = place.execute(player.surface, player.force, player, result.specs, undo_tag)
  if created == 0 then
    preview.say(player, { "beltplanner.error-nothing-placed" })
    return
  end

  pdata.anchor = next_anchor
  pdata.preview_tile = nil
  -- The tally described the run just placed; the next one has not been planned.
  set_summary(player, pdata, nil)

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
    pdata.drag_updates = 0
    pdata.preview_tile = nil
    pdata.saw_press = true

    -- Mark the starting tile straight away rather than waiting for the tracker.
    -- Whether the engine keeps updating the selection while a mouse button is
    -- held is not something a mod can find out from the API, so the live growth
    -- of this box is best-effort; the press itself is not, and marking the
    -- origin means there is always SOME indication that a drag has begun.
    preview.show_drag(player, pdata, from, from)
  end
end

--- `select` and `alt_select` both land here; alt forces a fresh anchor.
---
--- Three states, not two. With nothing started a click begins sizing the anchor
--- and the marked area then follows the pointer; the next click accepts it. A
--- dragged rectangle still does both at once, because the area it produces is
--- already the whole answer -- it just cannot show itself being made.
function session.on_select(player, area, force_new_anchor)
  local pdata = session.get(player.index)

  if storage.debug_tracker and pdata.saw_press then
    player.print({ "beltplanner.drag-report",
      pdata.saw_press and "yes" or "NO",
      pdata.drag_updates or 0 })
  end

  pdata.drag_from = nil
  pdata.saw_press = nil
  pdata.preview_tile = nil

  if force_new_anchor then
    pdata.anchor = nil
    pdata.anchor_origin = nil
  end

  if pdata.anchor then
    commit(player, pdata, area)
    return
  end

  local x1, y1, x2, y2 = geometry.tile_bounds(area)

  if pdata.anchor_origin then
    -- Second click: the pointer decides how wide the anchor is.
    local target = far_corner(pdata.anchor_origin, x1, y1, x2, y2)
    local anchor = geometry.anchor_between(pdata.anchor_origin, target)
    if anchor then
      accept_anchor(player, pdata, anchor)
    else
      pdata.anchor_origin = nil
      preview.clear(pdata)
    end
    return
  end

  if x2 > x1 or y2 > y1 then
    -- A dragged rectangle answers both questions at once.
    local anchor, reason = geometry.anchor_from_area(area)
    if not anchor then
      preview.say(player, reason)
      return
    end
    accept_anchor(player, pdata, anchor)
    return
  end

  -- A plain click: start sizing from here.
  pdata.anchor_origin = { x = x1, y = y1 }
  preview.show_candidate(player, pdata, geometry.anchor_between(pdata.anchor_origin, pdata.anchor_origin))
  player.play_sound { path = "utility/gui_click" }
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

--------------------------------------------------------------------------------
-- undo and redo

--- Move the anchor from `expected` to `restored`, but only if it is actually at
--- `expected`.
---
--- A commit leaves the anchor at the far end of what it placed. Undoing that
--- commit takes the ghosts away but, left alone, not the anchor, so the next
--- click would set off from the end of a run that is no longer there. The tag
--- on the undo item remembers both ends of the jump; undo plays it backwards
--- and redo plays it forwards.
---
--- The check against `expected` is what makes this safe with history in between:
--- if the player has clicked on since, or started a fresh anchor somewhere else,
--- the anchor is no longer where that commit left it and it is theirs, not ours
--- to move. Undoing an older commit then just removes ghosts, as it always did.
---
--- Which way the belts face is kept from the current anchor rather than taken
--- from the tag. Flipping is a live choice, and a flip made after the commit is
--- the newer intent; the tag only knows where the anchor stood.
local function step_anchor(player, pdata, expected, restored)
  local anchor = pdata.anchor
  if not anchor then return false end
  if not geometry.same_anchor(anchor, expected) then return false end

  local moved = geometry.anchor_snapshot(restored)
  moved.reversed = anchor.reversed
  pdata.anchor = moved
  pdata.preview_tile = nil
  -- The tally described a run planned from the anchor that has just moved away.
  set_summary(player, pdata, nil)
  preview.render(player, pdata, moved)
  return true
end

--- The player undid one of our commits while holding the tool. `tag` is the
--- table place.execute hung on the undo item.
function session.on_undo(player, tag)
  if not (tag and tag.before and tag.after) then return false end
  return step_anchor(player, session.get(player.index), tag.after, tag.before)
end

--- The player redid one of our commits while holding the tool.
function session.on_redo(player, tag)
  if not (tag and tag.before and tag.after) then return false end
  return step_anchor(player, session.get(player.index), tag.before, tag.after)
end

return session
