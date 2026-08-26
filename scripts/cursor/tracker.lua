-- Cursor tracker.
--
-- Factorio never tells a mod where the mouse is. What it does tell us is that
-- LuaControl.selected changed, so the pointer is located by covering the area in
-- invisible probes and watching which one the engine highlights.
--
-- The probes form a shallow tree over the size ladder in cursor/const: a
-- 32-tile root is replaced underneath by 16 eight-tile probes when the cursor
-- lands on it, and an eight-tile probe by 64 one-tile leaves. Each rung costs
-- one tick -- the engine reports the new selection next tick -- so a cold
-- descent converges in two. Ordinary movement is cheaper still: inside the
-- 8x8-tile leaf field the pointer lands straight on a sibling leaf for zero
-- ticks, and anywhere else in the current 32-cell the mid probes (which
-- outrank real entities) catch it in one.
--
-- Per tracked player that is ROOT_SPAN^2 = 49 roots plus 16 mid probes plus 64
-- leaves -- 129 entities and no more, however far the cursor roams. They are
-- destroyed the moment tracking stops.

local const = require("scripts/cursor/const")

local floor = math.floor

local tracker = {}

--------------------------------------------------------------------------------
-- storage

local function pdata_of(player_index, create)
  local root = storage.cursor
  local pdata = root.players[player_index]
  if not pdata and create then
    pdata = { tracking = false, probes = {} }
    root.players[player_index] = pdata
  end
  return pdata
end

function tracker.init()
  storage.cursor = storage.cursor or {}
  storage.cursor.players = storage.cursor.players or {}
end

--------------------------------------------------------------------------------
-- the tracker force

-- Probes live on their own force because force_visibility = "not-friend" makes
-- selectability a diplomacy question: befriending a force is how the probes are
-- switched off for it.
local function ensure_force()
  local force = game.forces[const.FORCE_NAME]
  if not force then
    force = game.create_force(const.FORCE_NAME)
  end
  return force
end
tracker.ensure_force = ensure_force

--- Show the probes to the forces that are actually using them, and to nobody
--- else.
---
--- Friendship used never to be set at all, which left every force in the game
--- able to select every probe: in multiplayer that put invisible selection boxes
--- under the cursor of people who had never touched the tool.
---
--- What this cannot do is separate two players who share a force, because
--- diplomacy has no finer grain than that - a team-mate of someone holding the
--- tool still sees the probes, and no part of the API can change it. Keeping the
--- root probes below every real entity is what bounds that to one 32-tile cell
--- around their pointer instead of the whole tracked block.
---
--- Cease-fire is set regardless, so nothing ever shoots at a probe.
local function refresh_visibility()
  local force = game.forces[const.FORCE_NAME]
  if not force then return end

  local tracked = {}
  for player_index, pdata in pairs(storage.cursor.players) do
    if pdata.tracking then
      local player = game.get_player(player_index)
      if player then tracked[player.force.index] = true end
    end
  end

  for _, other in pairs(game.forces) do
    if other.name ~= force.name then
      force.set_cease_fire(other, true)
      other.set_cease_fire(force, true)
      -- The deciding direction is probes -> viewer: a force the probes count as
      -- a friend fails the "not-friend" test and cannot see them.
      other.set_friend(force, true)
      force.set_friend(other, not tracked[other.index])
    end
  end
end
tracker.refresh_visibility = refresh_visibility

--------------------------------------------------------------------------------
-- probes

local function create_probe(surface, level, x, y, force)
  local entity = surface.create_entity {
    name = level.name,
    position = { x, y },
    force = force,
    create_build_effect_smoke = false,
  }
  if entity then
    entity.destructible = false
  end
  return entity
end

-- pdata.probes is keyed by level SIZE (32/8/1). An old save may hold stale
-- keys from a previous ladder; their entities either lost their prototype and
-- were dropped by the engine on load, or are destroyed here like any others,
-- because this iterates whatever keys exist rather than the current ladder.
local function destroy_level(pdata, size)
  local list = pdata.probes[size]
  if not list then return end
  for _, entity in pairs(list) do
    if entity.valid then entity.destroy() end
  end
  pdata.probes[size] = nil
end

local function destroy_all_probes(pdata)
  for size in pairs(pdata.probes) do
    destroy_level(pdata, size)
  end
  pdata.probes = {}
end

--- Place the whole chain of probes the pointer is expected to be standing on,
--- from just below the roots down to a leaf, without waiting to be told.
---
--- A descent normally costs a tick per level, because each level has to be
--- SELECTED before the next one is created. That is invisible while the pointer
--- is already being followed, but every re-seed starts from cold, and cold is
--- where the lag was: two ticks at best, and unbounded over a machine or an ore
--- patch, since a root deliberately loses to those and so is never selected at
--- all. Re-seeding happens on the ordinary business of moving the pointer across
--- the screen, which is why it was felt as an occasional long stall.
---
--- The pointer is almost always still near wherever it last was, so the entire
--- chain is guessed from that in one go. A right guess costs one tick; a wrong
--- one costs nothing, because every coarser level is guessed too and the
--- ordinary descent corrects from whichever level does cover the pointer.
---
--- Levels are destroyed before being replaced, so this is safe to call at any
--- time rather than only on a fresh field.
--- Takes a surface rather than a player so it can be exercised headlessly:
--- --create produces a map with no players, and the grid arithmetic below is
--- precisely the sort that is wrong by half a tile without ever looking it.
local function seed_descent(pdata, surface, centre)
  local force = ensure_force()

  for i = 2, #const.levels do
    local level = const.levels[i]
    local parent = level.parent
    local size = level.size

    destroy_level(pdata, size)

    -- Each level tiles the parent-size-aligned cell containing the pointer,
    -- and is therefore aligned to the global grid of its own size too - that
    -- is where a real subdivision lands as well - so a guessed probe is
    -- indistinguishable from a placed one and the descent can pick up from
    -- either.
    local left = floor(centre.x / parent.size) * parent.size
    local top = floor(centre.y / parent.size) * parent.size

    local list = {}
    for ix = 0, level.per_parent - 1 do
      for iy = 0, level.per_parent - 1 do
        local entity = create_probe(surface, level,
          left + (ix + 0.5) * size,
          top + (iy + 0.5) * size,
          force)
        if entity then list[#list + 1] = entity end
      end
    end
    pdata.probes[size] = list
  end
end
tracker.seed_descent = seed_descent

-- Roots tile a block around `centre`, which is the pointer once it is known and
-- the player only until then.
local function seed_roots(pdata, player, centre)
  local level = const.root
  local size = level.size
  local surface = player.surface
  local force = ensure_force()
  local origin = centre or player.position

  local base_x = floor(origin.x / size)
  local base_y = floor(origin.y / size)
  local first = -floor(const.ROOT_SPAN / 2)

  local list = {}
  for ix = first, first + const.ROOT_SPAN - 1 do
    for iy = first, first + const.ROOT_SPAN - 1 do
      local entity = create_probe(
        surface, level,
        (base_x + ix + 0.5) * size,
        (base_y + iy + 0.5) * size,
        force)
      if entity then list[#list + 1] = entity end
    end
  end

  pdata.probes[level.size] = list
  pdata.root_center = { x = origin.x, y = origin.y }
  pdata.surface_index = surface.index

  -- Guess the rest of the way down rather than leaving the field to be walked
  -- from the roots one tick at a time.
  seed_descent(pdata, surface, origin)
end

-- Replace one probe with its children. The children tile the parent exactly, so
-- whichever one covers the pointer is highlighted next tick. The previous
-- generation at this depth is dropped first, which is what keeps the entity
-- count flat instead of leaving a trail behind the cursor. A mid subdivide
-- therefore churns 64 destroys and 64 creates, which is fine for an event that
-- only fires when the pointer crosses an 8-tile cell boundary.
local function subdivide(pdata, parent_entity, level)
  local child = level.child
  if not child then return end

  local surface = parent_entity.surface
  local force = parent_entity.force
  local centre = parent_entity.position
  -- Children per axis INSIDE the selected probe: level.size / child.size,
  -- which is exactly the child's per_parent.
  local n = child.per_parent
  local step = child.size

  destroy_level(pdata, child.size)

  local list = {}
  for ix = 0, n - 1 do
    for iy = 0, n - 1 do
      local entity = create_probe(
        surface, child,
        centre.x + (ix + 0.5) * step - level.half,
        centre.y + (iy + 0.5) * step - level.half,
        force)
      if entity then list[#list + 1] = entity end
    end
  end
  pdata.probes[child.size] = list
end

--------------------------------------------------------------------------------
-- public API

function tracker.is_tracking(player_index)
  local pdata = pdata_of(player_index, false)
  return pdata ~= nil and pdata.tracking
end

function tracker.start(player)
  local pdata = pdata_of(player.index, true)
  destroy_all_probes(pdata)
  pdata.tracking = true
  pdata.position = nil
  pdata.tile = nil
  ensure_force()
  refresh_visibility()
  seed_roots(pdata, player)
end

function tracker.stop(player_index)
  local pdata = pdata_of(player_index, false)
  if not pdata then return end
  destroy_all_probes(pdata)
  pdata.tracking = false
  pdata.position = nil
  pdata.tile = nil
  pdata.root_center = nil
  refresh_visibility()
end

--- Last known pointer position, or nil while the descent has not reached a leaf
--- yet. Accurate to half a leaf width.
function tracker.get_position(player_index)
  local pdata = pdata_of(player_index, false)
  return pdata and pdata.position
end

--- Last known pointer position floored to a tile.
function tracker.get_tile(player_index)
  local pdata = pdata_of(player_index, false)
  return pdata and pdata.tile
end

--- Ticks the most recent descent took to reach a leaf. This is the tracker's
--- input lag, and the number worth watching while tuning the size ladder in
--- cursor/const.
function tracker.get_last_latency(player_index)
  local pdata = pdata_of(player_index, false)
  return (pdata and pdata.last_latency) or 0
end

--------------------------------------------------------------------------------
-- events

function tracker.on_selected_entity_changed(event)
  local pdata = pdata_of(event.player_index, false)
  if not (pdata and pdata.tracking) then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local selected = player.selected
  if not (selected and selected.valid) then
    -- Our own doing, one line below, rather than the pointer going anywhere.
    if pdata.self_cleared then
      pdata.self_cleared = nil
      return
    end

    -- Nothing under the cursor at all. Usually a GUI or the map edge, but it
    -- also means the pointer has left the tracked block - after a jump the
    -- proactive re-centring cannot have seen. Re-seed on the last place we knew
    -- about, rate-limited so hovering a window does not thrash it.
    -- Rate-limited only so that resting the pointer on a window does not thrash
    -- the field. It used to wait 30 ticks, which is half a second of a dead
    -- preview every time the pointer came back from somewhere untracked.
    --
    -- Not on the zoomed-out map, though. Remote view at chart zoom has no entity
    -- selection at all, so a probe field placed there can never be highlighted
    -- and re-seeding would only churn entities for nothing. chart_zoomed_in is
    -- the ordinary world drawn from the map and selects normally; zooming back
    -- in to it is what brings the pointer back, and that lands on a probe or a
    -- real entity and is handled like any other selection.
    if player.render_mode == defines.render_mode.chart then return end

    if pdata.position and (event.tick - (pdata.recovered_tick or 0)) > 12 then
      pdata.recovered_tick = event.tick
      destroy_all_probes(pdata)
      seed_roots(pdata, player, pdata.position)
    end
    return
  end

  -- A real selection supersedes a pending self-clear, so the flag can never be
  -- left set to swallow a later genuine loss.
  pdata.self_cleared = nil

  local level = const.by_name[selected.name]
  if not level then
    -- A real entity. Roots deliberately lose to those, so nothing would narrow
    -- the pointer down until it crossed open ground - the stall that made the
    -- preview feel like it had stopped working inside a factory.
    --
    -- But a selected entity is itself a position: the cursor is somewhere inside
    -- its selection box. Guessing the chain there puts probes that DO outrank it
    -- under the cursor, and the next tick reads an exact tile off a leaf.
    --
    -- Seeing a real entity at all proves no fine probe covers that spot, since
    -- one would have outranked it. Guessing once per entity keeps a selection
    -- box too large to cover from being re-guessed every tick; the field is then
    -- no worse off than before, and the next pointer move settles it.
    local key = selected.unit_number
      or (selected.name .. ":" .. selected.position.x .. ":" .. selected.position.y)

    if pdata.root_center and pdata.hint_key ~= key then
      pdata.hint_key = key
      seed_descent(pdata, player.surface, selected.position)
    end
    return
  end

  -- Back on a probe, so any entity hinted from earlier is stale.
  pdata.hint_key = nil

  if level.is_leaf then
    local centre = selected.position
    pdata.position = { x = centre.x, y = centre.y }
    pdata.tile = { x = floor(centre.x), y = floor(centre.y) }

    -- Move the block along before the pointer can run off the edge of it. Doing
    -- this on the way out rather than after the fact means there is never a
    -- moment with nothing under the cursor to track.
    local anchor = pdata.root_center
    if anchor then
      local limit = const.RECENTRE_DISTANCE
      if math.abs(centre.x - anchor.x) > limit or math.abs(centre.y - anchor.y) > limit then
        destroy_all_probes(pdata)
        seed_roots(pdata, player, centre)
      end
    end
    -- How many ticks this descent took, counted from the first non-leaf hit.
    -- Zero means the pointer moved within one leaf's parent and landed straight
    -- on a sibling that already existed.
    pdata.last_latency = pdata.descent_started and (event.tick - pdata.descent_started) or 0
    pdata.descent_started = nil
  else
    pdata.descent_started = pdata.descent_started or event.tick
    subdivide(pdata, selected, level)

    -- The game draws its own selection box around whatever the cursor is over,
    -- and while the tool is held that is always one of these probes. Left alone
    -- a descent therefore flashes a 32-tile box and then an 8-tile one, and only
    -- the leaf after them is the tile actually being pointed at -- so the tool
    -- appeared to be picking areas it was not. Dropping the selection the moment
    -- a probe has been subdivided means the leaf is the only box ever drawn.
    --
    -- This does not stall the descent, because selection is recomputed from the
    -- cursor every tick rather than cached until it moves. That is the same fact
    -- the whole tracker rests on: a child appearing under a stationary cursor is
    -- what advances a descent in the first place. The child is created just
    -- above, and outranks its parent, so the next tick lands on it.
    pdata.self_cleared = true
    player.clear_selected_entity()
  end
end

-- The root block is finite, so walking far enough would take the pointer off the
-- tracked area entirely. Re-seed rather than grow.
function tracker.on_player_moved(event)
  local pdata = pdata_of(event.player_index, false)
  if not (pdata and pdata.tracking and pdata.root_center) then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local origin = player.position
  local dx = origin.x - pdata.root_center.x
  local dy = origin.y - pdata.root_center.y
  local limit = const.RESEED_DISTANCE

  if dx * dx + dy * dy > limit * limit or player.surface.index ~= pdata.surface_index then
    destroy_all_probes(pdata)
    seed_roots(pdata, player)
  end
end

--------------------------------------------------------------------------------
-- housekeeping

--- Destroys every probe on every surface, whoever owns it. Used on configuration
--- change so a crash, a mod update or a stale save can never leave probes lying
--- in the world.
function tracker.purge_world()
  local names = {}
  for _, level in ipairs(const.levels) do names[#names + 1] = level.name end

  local removed = 0
  for _, surface in pairs(game.surfaces) do
    for _, entity in pairs(surface.find_entities_filtered { name = names }) do
      entity.destroy()
      removed = removed + 1
    end
  end

  for _, pdata in pairs(storage.cursor.players) do
    pdata.probes = {}
    pdata.tracking = false
    pdata.position = nil
    pdata.tile = nil
  end
  refresh_visibility()
  return removed
end

return tracker
