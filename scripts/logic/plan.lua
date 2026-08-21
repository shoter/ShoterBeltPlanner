-- Turns two endpoints into a list of things to place.
--
-- This is the hinge of the whole tool: the preview and the commit both consume
-- the list this produces, so what the player sees is provably what gets built.
--
-- The non-smart rule is enforced here. The run never leaves the line the player
-- drew. Where it meets an obstacle, an underground pair spans exactly that
-- obstacle and no further, so the tunnel length is dictated by the world rather
-- than guessed. If the obstacle is too long to bridge, or sits where an entry or
-- exit would have to go, the whole segment is refused rather than approximated.

local geometry = require("scripts/geometry")
local belts = require("scripts/belts")
local cursor_const = require("scripts/cursor/const")

local plan = {}

local floor, ceil = math.floor, math.ceil

local FREE, WATER, BLOCKED = 1, 2, 3

-- Types an area query returns that never obstruct a belt. Without this list
-- their mere presence would condemn a tile.
local HARMLESS = {
  ["item-entity"] = true,
  ["resource"] = true,
  ["corpse"] = true,
  ["item-request-proxy"] = true,
  ["highlight-box"] = true,
  ["deconstructible-tile-proxy"] = true,
  ["particle-source"] = true,
  ["explosion"] = true,
  ["smoke-with-trigger"] = true,
  -- Ghosts are almost certainly ours from the previous click, and building over
  -- one is fine.
  ["entity-ghost"] = true,
  ["tile-ghost"] = true,
}

--------------------------------------------------------------------------------
-- survey

local function key_of(x, y)
  return x .. ":" .. y
end

--- Everything the run needs to know about the world, in two queries rather than
--- two per tile. Entities are bucketed onto every tile their bounding box
--- touches, so a 3x3 machine blocks all nine.
local function survey(surface, box)
  local water, occupants = {}, {}

  for _, tile in pairs(surface.find_tiles_filtered { area = box, collision_mask = "water_tile" }) do
    water[key_of(tile.position.x, tile.position.y)] = true
  end

  for _, entity in pairs(surface.find_entities_filtered { area = box }) do
    -- Our own cursor probes are invisible, collide with nothing, and blanket the
    -- area by design. Surveyed as obstructions they force can_place_entity to be
    -- consulted on every tile, and that call refuses any tile already holding a
    -- ghost - so a second run over the first one came back entirely blocked.
    if entity.valid and not HARMLESS[entity.type] and not cursor_const.by_name[entity.name] then
      local bb = entity.bounding_box
      for x = floor(bb.left_top.x), ceil(bb.right_bottom.x) - 1 do
        for y = floor(bb.left_top.y), ceil(bb.right_bottom.y) - 1 do
          local key = key_of(x, y)
          local list = occupants[key]
          if list then
            list[#list + 1] = entity
          else
            occupants[key] = { entity }
          end
        end
      end
    end
  end

  return water, occupants
end

--- Can this entity simply be ordered away to make room?
---
--- Trees and rocks always: that is what stamping a vanilla blueprint does, and
--- nobody means to keep a tree standing where they just asked for a belt.
--- Anything the player built only when they explicitly asked, because clearing
--- someone's machines by accident is not worth one undo.
local function clearable(entity, context)
  local kind = entity.type

  if kind == "tree" then return true end
  if kind == "simple-entity" and entity.prototype.count_as_rock_for_filtered_deconstruction then
    return true
  end

  if context.clear_built and kind ~= "character" and entity.force.name == context.force_name then
    return true
  end

  return false
end

--- Decide what one tile is, and what would have to go to make it usable.
---
--- The engine is only consulted when something we may NOT remove is present,
--- because can_place_entity answers the wrong question on its own: a belt GHOST
--- places quite happily under a tree, so trusting it would silently leave the
--- tree standing and the ghost unbuildable. That was the bug this shape exists
--- to prevent.
local function classify(context, direction, tile, water, occupants)
  local key = key_of(tile.x, tile.y)

  if water[key] then
    return context.landfill and WATER or BLOCKED
  end

  local present = occupants[key]
  if not present then
    return FREE
  end

  local removable, obstructed = {}, false
  for _, entity in ipairs(present) do
    if entity.valid then
      if clearable(entity, context) then
        removable[#removable + 1] = entity
      else
        obstructed = true
      end
    end
  end

  if obstructed then
    local placeable = context.surface.can_place_entity {
      name = context.tier.belt,
      position = { x = tile.x + 0.5, y = tile.y + 0.5 },
      direction = direction,
      force = context.force,
      build_check_type = defines.build_check_type.blueprint_ghost,
      forced = true, -- ignore things already marked for deconstruction
    }
    if not placeable then
      return BLOCKED
    end
  end

  return FREE, removable
end

--------------------------------------------------------------------------------
-- one lane

local function centre(tile)
  return { x = tile.x + 0.5, y = tile.y + 0.5 }
end

--- Walk one straight run, emitting specs. Returns false plus a reason if it
--- cannot be built; a partial run is never emitted, because half a belt is worse
--- than none.
---
--- Tiles arrive in the order items FLOW along them, so the first end of a tunnel
--- is always the entrance and the second always the exit, whichever way the run
--- was drawn.
local function plan_run(context, run, water, occupants, specs, blockers)
  local tiles, direction = run.tiles, run.direction
  local states, removals = {}, {}
  for index, tile in ipairs(tiles) do
    states[index], removals[index] = classify(context, direction, tile, water, occupants)
  end

  -- One entity can straddle several tiles and several lanes, so removals are
  -- deduplicated across the whole run rather than per tile.
  local function emit_removals(index)
    for _, entity in ipairs(removals[index] or {}) do
      local id = entity.unit_number
        or (entity.name .. ":" .. entity.position.x .. ":" .. entity.position.y)
      if not context.seen[id] then
        context.seen[id] = true
        specs[#specs + 1] = {
          kind = "deconstruct",
          entity = entity,
          position = entity.position,
        }
      end
    end
  end

  local count = #tiles
  local index = 1

  while index <= count do
    local state = states[index]

    if state ~= BLOCKED then
      emit_removals(index)
      if state == WATER then
        specs[#specs + 1] = {
          kind = "landfill",
          name = "landfill",
          position = centre(tiles[index]),
        }
      end
      specs[#specs + 1] = {
        kind = "belt",
        name = context.tier.belt,
        position = centre(tiles[index]),
        direction = direction,
      }
      index = index + 1
    else
      -- Measure the obstacle, then decide whether it can be tunnelled.
      local first = index
      local last = index
      while last < count and states[last + 1] == BLOCKED do
        last = last + 1
      end
      for blocked = first, last do
        blockers[#blockers + 1] = tiles[blocked]
      end

      if not context.tunnels then
        return false, { "beltplanner.error-blocked" }
      end

      local entry = first - 1
      local exit = last + 1
      if entry < 1 or exit > count then
        -- Nothing to anchor the pair to: the obstacle touches an end of the run.
        return false, { "beltplanner.error-blocked-at-end" }
      end

      local gap = last - first + 1
      if not belts.can_span(context.tier, gap) then
        return false, { "beltplanner.error-tunnel-too-long", gap, context.tier.max_distance or 0 }
      end

      -- The belt already emitted on the entry tile becomes the underground
      -- entrance instead.
      specs[#specs] = {
        kind = "underground",
        name = context.tier.underground,
        position = centre(tiles[entry]),
        direction = direction,
        type = "input",
      }
      emit_removals(exit)
      specs[#specs + 1] = {
        kind = "underground",
        name = context.tier.underground,
        position = centre(tiles[exit]),
        direction = direction,
        type = "output",
      }

      index = exit + 1
    end
  end

  return true
end

--------------------------------------------------------------------------------
-- splitters

--- Replace the belts on the final tile of the run with a row of splitters.
---
--- A splitter is two tiles across, so it takes a lane PAIR - lanes 1-2, 3-4 and
--- so on - which is why an odd bundle is refused outright rather than half
--- converted. Straight runs only: the lanes of a corner end staggered, so a row
--- across them would not line up.
---
--- Returns the new spec list, or nil plus a LocalisedString.
local function apply_splitters(anchor, resolved, context, specs)
  if resolved.curved then
    return nil, { "beltplanner.error-splitter-corner" }
  end
  if anchor.lanes % 2 ~= 0 then
    return nil, { "beltplanner.error-splitter-odd", anchor.lanes }
  end
  if not context.tier.splitter then
    return nil, { "beltplanner.error-splitter-none" }
  end

  local ends, lane_of = {}, {}
  for lane = 1, anchor.lanes do
    local tile = geometry.lane_end(anchor, resolved, lane)
    ends[lane] = tile
    lane_of[key_of(tile.x, tile.y)] = lane
  end

  -- Drop the belts on those tiles. Landfill and removals there still apply, so
  -- they are kept; a tunnel mouth cannot also be a splitter, so it refuses.
  local kept, replaced = {}, {}
  for _, spec in ipairs(specs) do
    local lane = spec.position
      and lane_of[key_of(floor(spec.position.x), floor(spec.position.y))]

    if lane and spec.kind == "belt" then
      replaced[lane] = true
    elseif lane and spec.kind == "underground" then
      return nil, { "beltplanner.error-splitter-blocked" }
    else
      kept[#kept + 1] = spec
    end
  end

  for lane = 1, anchor.lanes, 2 do
    if not (replaced[lane] and replaced[lane + 1]) then
      -- One of the pair never got a belt, so the ground under it is not clear.
      return nil, { "beltplanner.error-splitter-blocked" }
    end

    local a, b = ends[lane], ends[lane + 1]
    kept[#kept + 1] = {
      kind = "splitter",
      name = context.tier.splitter,
      -- Two tiles wide, so it is centred on the boundary between the pair
      -- rather than on either tile.
      position = { x = (a.x + b.x) / 2 + 0.5, y = (a.y + b.y) / 2 + 0.5 },
      direction = context.splitter_direction,
    }
  end

  return kept
end

--------------------------------------------------------------------------------
-- public

--- Build the full spec list for a run.
---
--- `options` carries { tier, landfill, tunnels, clear_built, max_tiles }.
--- Returns { specs, blockers, cost } or nil plus a LocalisedString and the
--- blocking tiles.
function plan.build(surface, force, anchor, resolved, options)
  local tier = options.tier or belts.default()
  if not tier then
    return nil, { "beltplanner.error-no-belts" }
  end

  local cost = geometry.cost(anchor, resolved)
  if options.max_tiles and cost > options.max_tiles then
    return nil, { "beltplanner.error-too-big", cost, options.max_tiles }
  end

  local context = {
    surface = surface,
    force = force,
    -- force may arrive as a LuaForce or as a name; comparisons need the name.
    force_name = type(force) == "string" and force or force.name,
    tier = tier,
    landfill = options.landfill,
    tunnels = options.tunnels,
    clear_built = options.clear_built or false,
    seen = {},
  }

  local box = geometry.bounding_box(anchor, resolved)
  local water, occupants = survey(surface, box)

  local specs, blockers = {}, {}

  for lane = 1, anchor.lanes do
    -- A corner splits a lane into two straight runs, which is also what keeps a
    -- tunnel from being dug across the bend: each run is planned on its own.
    for _, run in ipairs(geometry.lane_runs(anchor, resolved, lane)) do
      local ok, reason = plan_run(context, run, water, occupants, specs, blockers)
      if not ok then
        return nil, reason, blockers
      end
    end
  end

  if options.splitters then
    -- A straight run has exactly one run per lane, and its direction is the way
    -- items flow, which is the way the splitters must face.
    local runs = geometry.lane_runs(anchor, resolved, 1)
    context.splitter_direction = runs[1] and runs[1].direction

    local replaced, reason = apply_splitters(anchor, resolved, context, specs)
    if not replaced then
      return nil, reason, blockers
    end
    specs = replaced
  end

  return { specs = specs, blockers = blockers, cost = cost }
end

return plan
