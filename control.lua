-- Control stage aggregator.
--
-- script.on_init / on_load / on_configuration_changed take exactly one handler
-- each, and a second registration silently replaces the first, so every module
-- is wired up from here rather than registering for itself.

local flib_gui = require("__flib__.gui")
local tracker = require("scripts/cursor/tracker")
local session = require("scripts/session")
local planner_gui = require("gui/planner_gui")

-- Registers every on_gui_* event and routes it to the handler stored in the
-- element's tags. Called at file scope so the registration is identical on
-- every load.
flib_gui.handle_events()

local TOOL = "beltplanner-tool"

--------------------------------------------------------------------------------
-- bootstrap

local function init_storage()
  storage.players = storage.players or {}
  tracker.init()
end

script.on_init(init_storage)

script.on_configuration_changed(function()
  init_storage()
  -- A crash, a mod update or an interrupted session could leave probes in the
  -- world. They are invisible, so sweep unconditionally rather than trusting the
  -- bookkeeping in storage.
  tracker.purge_world()
end)

--------------------------------------------------------------------------------
-- helpers

--- Run something that draws, and let a fault cost the preview rather than the
--- session.
---
--- The preview redraws on every cursor move and is purely cosmetic, yet it is
--- the one part of this mod with no automated coverage: nothing that draws can
--- run headlessly, because --create produces a map with no player. So it runs
--- behind pcall and is switched off for that player after the first failure
--- rather than erroring again every tick. Taking the tool out afresh re-enables
--- it.
---
--- EVERY path that draws has to come through here, which is why this takes the
--- action rather than naming one: session.on_press drew directly and was the one
--- way round the guard.
---
--- Safe in multiplayer: an error here is a function of state every peer shares,
--- so every peer takes the same branch.
local function guarded(player, action, ...)
  local pdata = session.get(player.index)
  -- Once the preview is off, the state these actions keep is only ever read by
  -- the preview itself, so skipping them entirely is right rather than merely
  -- cheap.
  if pdata.preview_broken then return end

  local ok, err = pcall(action, player, ...)
  if ok then return end

  pdata.preview_broken = true
  pcall(session.cancel, player, true)
  log("Belt Planner: preview failed, switched off for player " .. player.index .. ": " .. tostring(err))
  player.print({ "beltplanner.preview-failed" })
end

local function safe_update_preview(player)
  guarded(player, session.update_preview)
end

local function holding_tool(player)
  local stack = player.cursor_stack
  return stack ~= nil and stack.valid and stack.valid_for_read and stack.name == TOOL
end

-- Mouse-down while our tool is held. Gated hard on holding the tool: these are
-- bound to plain and Ctrl left-click, so they fire on every click in the game
-- and must do nothing at all the rest of the time.
--
-- Both variants do the same thing. The Ctrl one exists only so that a
-- Ctrl-click still marks where a drag began; the modifier itself no longer
-- means anything to this tool.
local function on_press(event)
  -- A click on our own window is still a left-click, and without this it would
  -- arm a drag from wherever the window happens to sit on the map.
  if event.in_gui then return end

  local player = game.get_player(event.player_index)
  if not (player and holding_tool(player)) then return end
  guarded(player, session.on_press, event.cursor_position)
end

script.on_event("beltplanner-press", on_press)
script.on_event("beltplanner-ctrl-press", on_press)
script.on_event("beltplanner-select-press", on_press)

--------------------------------------------------------------------------------
-- the tool

-- `select` and `alt_select` both open or extend a run; alt forces a fresh anchor
-- even mid-run. Both are gated on event.item so another mod's selection tool
-- never reaches this code.
local function on_selected(event, force_new_anchor)
  if event.item ~= TOOL then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  session.on_select(player, event.area, force_new_anchor)
  planner_gui.refresh(player)
end

script.on_event(defines.events.on_player_selected_area, function(event)
  on_selected(event, false)
end)

script.on_event(defines.events.on_player_alt_selected_area, function(event)
  on_selected(event, true)
end)

-- Shift + right-drag: end the run with splitters rather than belts.
script.on_event(defines.events.on_player_alt_reverse_selected_area, function(event)
  if event.item ~= TOOL then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  session.on_splitter(player, event.area)
  planner_gui.refresh(player)
end)

script.on_event(defines.events.on_player_reverse_selected_area, function(event)
  if event.item ~= TOOL then return end
  local player = game.get_player(event.player_index)
  if player then
    session.cancel(player, false)
    planner_gui.refresh(player)
  end
end)

script.on_event("beltplanner-flip", function(event)
  local player = game.get_player(event.player_index)
  if not (player and holding_tool(player)) then return end
  session.flip(player)
  planner_gui.refresh(player)
end)

script.on_event("beltplanner-cycle-belt", function(event)
  local player = game.get_player(event.player_index)
  if not (player and holding_tool(player)) then return end
  session.cycle_belt(player)
  planner_gui.refresh(player)
end)

-- The tracker follows the tool rather than the run, because the opening drag
-- needs a live pointer before any anchor exists. Putting the tool away ends
-- everything: otherwise the anchor outlives the tool and the next selection,
-- with any tool at all, would look like a continuation.
script.on_event(defines.events.on_player_cursor_stack_changed, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  if holding_tool(player) then
    session.enter(player)
    planner_gui.open(player)
  else
    session.leave(player)
    planner_gui.close(player)
  end
end)

--------------------------------------------------------------------------------
-- teardown

local function forget_player(event)
  local player = game.get_player(event.player_index)
  if player then
    session.leave(player)
    planner_gui.close(player)
  else
    tracker.stop(event.player_index)
  end
end

script.on_event(defines.events.on_player_left_game, forget_player)
script.on_event(defines.events.on_player_removed, forget_player)

-- Changing surface is not putting the tool down, and treating it as though it
-- were left the tool inert in hand: the probes stopped, the window shut, and the
-- only way back was to stow the tool and take it out again. Space Age players
-- cross surfaces constantly.
--
-- The anchor genuinely cannot survive the move, because it names tiles on the
-- surface it was made on, so the run is cancelled. The tool itself carries over,
-- and re-entering re-seeds the probe field on the surface the player is now on.
script.on_event(defines.events.on_player_changed_surface, function(event)
  local player = game.get_player(event.player_index)
  if not player then
    tracker.stop(event.player_index)
    return
  end

  session.leave(player)

  if holding_tool(player) then
    session.enter(player)
    planner_gui.open(player)
  else
    planner_gui.close(player)
  end
end)

--------------------------------------------------------------------------------
-- cursor tracker (M0 scaffolding)
--
-- Temporary: once the tracker is wired into the preview, tracking starts and
-- stops with the tool rather than with a hotkey of its own.

local function clear_debug_overlay(pdata)
  if not pdata.tracker_renders then return end
  for _, object in pairs(pdata.tracker_renders) do
    if object.valid then object.destroy() end
  end
  pdata.tracker_renders = nil
end

local function draw_debug_overlay(player, pdata)
  clear_debug_overlay(pdata)

  local tile = tracker.get_tile(player.index)
  local position = tracker.get_position(player.index)
  if not (tile and position) then return end

  -- Input lag in ticks: how long the last descent took to narrow back down to a
  -- leaf. The running maximum is the number that decides whether the tracker is
  -- responsive enough to build the whole tool on.
  local latency = tracker.get_last_latency(player.index)
  pdata.worst_latency = math.max(pdata.worst_latency or 0, latency)

  pdata.tracker_renders = {
    rendering.draw_rectangle {
      color = { 0.2, 1, 0.3, 0.6 },
      width = 2,
      filled = false,
      left_top = { tile.x, tile.y },
      right_bottom = { tile.x + 1, tile.y + 1 },
      surface = player.surface,
      players = { player },
    },
    rendering.draw_text {
      text = string.format("%.2f, %.2f  tile %d,%d  lag %dt (max %dt)",
        position.x, position.y, tile.x, tile.y, latency, pdata.worst_latency),
      target = { position.x, position.y - 1.2 },
      color = { 0.2, 1, 0.3 },
      scale = 0.7,
      alignment = "center",
      surface = player.surface,
      players = { player },
    },
  }
end

script.on_event(defines.events.on_selected_entity_changed, function(event)
  tracker.on_selected_entity_changed(event)

  local cursor = storage.cursor.players[event.player_index]
  if not (cursor and cursor.tracking) then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  -- The tracker has just narrowed the pointer down; redraw what would be built
  -- from here. update_preview is a no-op unless the pointer changed tile.
  safe_update_preview(player)

  if storage.debug_tracker then
    draw_debug_overlay(player, session.get(event.player_index))
  end
end)

script.on_event(defines.events.on_player_changed_position, tracker.on_player_moved)

-- Which forces may see the probes is recomputed from which forces have someone
-- tracking, so it goes stale when the set of forces or their membership changes.
-- Starting and stopping the tracker covers the common case; these cover the rest.
local function refresh_probe_visibility()
  tracker.refresh_visibility()
end

script.on_event(defines.events.on_force_created, refresh_probe_visibility)
script.on_event(defines.events.on_forces_merged, refresh_probe_visibility)
script.on_event(defines.events.on_player_changed_force, refresh_probe_visibility)

-- Tracking itself now follows the tool, so this only toggles the diagnostic
-- readout drawn on top of it.
script.on_event("beltplanner-toggle-tracker", function(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  local pdata = session.get(event.player_index)
  storage.debug_tracker = not storage.debug_tracker

  if storage.debug_tracker then
    pdata.worst_latency = nil
    player.print({ "beltplanner.tracker-on" })
  else
    clear_debug_overlay(pdata)
    player.print({ "beltplanner.tracker-off" })
  end
end)

--------------------------------------------------------------------------------
-- escape hatch

commands.add_command("beltplanner-purge", { "beltplanner.purge-help" }, function(command)
  local removed = tracker.purge_world()
  local player = command.player_index and game.get_player(command.player_index)
  local message = { "beltplanner.purge-done", removed }
  if player then player.print(message) else game.print(message) end
end)
