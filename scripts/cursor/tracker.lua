-- Cursor tracker.
--
-- Factorio never tells a mod where the mouse is. What it does tell us is that
-- LuaControl.selected changed, so the pointer is located by covering the area in
-- invisible probes and watching which one the engine highlights.
--
-- The probes form a quadtree. A root probe is 2^MAX_POW tiles across; when the
-- cursor highlights it, it is replaced underneath by its children, each half the
-- width. The child covering the pointer is highlighted on the next tick and the
-- process repeats, so the search halves its uncertainty every tick until it
-- reaches the leaf size. That costs one tick per level from cold, but ordinary
-- mouse movement only leaves the deepest probe, so it usually re-converges in
-- one or two ticks.
--
-- Only SUBDIVISIONS^2 probes exist per level per player, plus ROOT_SPAN^2 roots,
-- so a tracked player owns a few dozen entities and no more, however far the
-- cursor roams. They are destroyed the moment tracking stops.

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
-- selectability a diplomacy question: befriending this force switches every
-- probe off at once. Cease-fire is set in both directions so nothing shoots at
-- them, but friendship is never set here, because that is the off switch.
local function ensure_force()
  local force = game.forces[const.FORCE_NAME]
  if not force then
    force = game.create_force(const.FORCE_NAME)
  end
  for _, other in pairs(game.forces) do
    if other.name ~= force.name then
      force.set_cease_fire(other, true)
      other.set_cease_fire(force, true)
    end
  end
  return force
end
tracker.ensure_force = ensure_force

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

local function destroy_level(pdata, pow)
  local list = pdata.probes[pow]
  if not list then return end
  for _, entity in pairs(list) do
    if entity.valid then entity.destroy() end
  end
  pdata.probes[pow] = nil
end

local function destroy_all_probes(pdata)
  for pow in pairs(pdata.probes) do
    destroy_level(pdata, pow)
  end
  pdata.probes = {}
end

-- Roots tile a fixed block around the player. Everything deeper is created on
-- demand by the descent, so this is the only placement that has to guess where
-- the player might point.
local function seed_roots(pdata, player)
  local level = const.root
  local size = level.size
  local surface = player.surface
  local force = ensure_force()
  local origin = player.position

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

  pdata.probes[level.pow] = list
  pdata.root_center = { x = origin.x, y = origin.y }
  pdata.surface_index = surface.index
end

-- Replace one probe with its children. The children tile the parent exactly, so
-- whichever one covers the pointer is highlighted next tick. The previous
-- generation at this depth is dropped first, which is what keeps the entity
-- count flat instead of leaving a trail behind the cursor.
local function subdivide(pdata, parent, level)
  local child = const.by_pow[level.pow - 1]
  if not child then return end

  local surface = parent.surface
  local force = parent.force
  local centre = parent.position
  local n = const.SUBDIVISIONS
  local step = child.size

  destroy_level(pdata, child.pow)

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
  pdata.probes[child.pow] = list
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
--- input lag, and the number worth watching while tuning MAX_POW/SUBDIVISIONS.
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
  if not (selected and selected.valid) then return end

  local level = const.by_name[selected.name]
  if not level then return end -- a real world entity, nothing to do

  if level.is_leaf then
    local centre = selected.position
    pdata.position = { x = centre.x, y = centre.y }
    pdata.tile = { x = floor(centre.x), y = floor(centre.y) }
    -- How many ticks this descent took, counted from the first non-leaf hit.
    -- Zero means the pointer moved within one leaf's parent and landed straight
    -- on a sibling that already existed.
    pdata.last_latency = pdata.descent_started and (event.tick - pdata.descent_started) or 0
    pdata.descent_started = nil
  else
    pdata.descent_started = pdata.descent_started or event.tick
    subdivide(pdata, selected, level)
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
  return removed
end

return tracker
