-- Turns two endpoints into a list of things to place.
--
-- This is the hinge of the whole tool: the preview and the commit both consume
-- the list this produces, so what the player sees is provably what gets built.
--
-- The non-smart rule is enforced here. The run never leaves the line the player
-- drew, and nothing is tunnelled under: deciding how long an underground should
-- be is a guess, and the brief is explicit that guessing is the one thing this
-- tool must not do. Anything in the way therefore stops the run and says what it
-- was, leaving the decision with the player.
--
-- Trees, rocks and wild plants are the sole exception, because clearing those is
-- not a guess about intent. A structure the player built is only ever removed
-- when they have asked for it.

local geometry = require("scripts/geometry")
local belts = require("scripts/belts")

local plan = {}

local floor, ceil = math.floor, math.ceil

-- OWNED and CLIFF are separated from BLOCKED so the refusal can name the thing
-- the player can do something about from the tool window: each has a switch.
local FREE, WATER, BLOCKED, OWNED, CLIFF = 1, 2, 3, 4, 5

--------------------------------------------------------------------------------
-- survey

--- Could an entity like this one be in a belt's way at all?
---
--- Asked of the engine rather than answered from a list. This used to be a table
--- of entity TYPES assumed harmless, which is a denylist by omission across
--- every type in the game: whatever the list failed to name condemned the tile.
--- Construction robots are the case that proved it wrong. A robot is on your
--- force, so one drifting over the line refused the whole run and blamed "your
--- own buildings" - and this tool calls robots in itself by placing ghosts, so
--- extending a run was the gesture most likely to hit it. Character corpses and
--- spider legs went the same way.
---
--- Two collision masks that share no layer cannot collide, whatever the entities
--- are. One rule therefore settles robots, corpses, characters, biters, dropped
--- items, ore, ghosts and our own cursor probes at once, and still blocks on
--- trees, cliffs, rails, machines and other belts. It is also the same question
--- the construction robot asks later, so the plan agrees with what can actually
--- be built.
local function obstruction_test(belt_name)
  local belt_layers = prototypes.entity[belt_name].collision_mask.layers

  -- collision_mask builds a fresh table on every read, and a survey walks
  -- hundreds of entities that are mostly repeats of a handful of prototypes, so
  -- the verdict is cached by name for the life of one plan.
  local known = {}

  return function(entity)
    local name = entity.name
    local cached = known[name]
    if cached ~= nil then return cached end

    local layers = entity.prototype.collision_mask.layers
    local obstructs = false
    for layer in pairs(belt_layers) do
      if layers[layer] then
        obstructs = true
        break
      end
    end

    known[name] = obstructs
    return obstructs
  end
end

local function key_of(x, y)
  return x .. ":" .. y
end

--- What the engine would lay over this tile to build on it, or false if there
--- is nothing that can.
---
--- The survey finds water by its collision layer, and every ground that cannot
--- be built on carries that layer: Nauvis water, but also Vulcanus lava,
--- Fulgora's oil ocean, Aquilo's ammoniacal ocean and the void around a space
--- platform. This used to order landfill over all of them, which was only ever
--- right on Nauvis - a landfill ghost on lava can never be built, so the run
--- looked placed and then sat there forever. The tile prototype already names
--- its own cover (landfill, foundation, ice platform, platform foundation), so
--- that is asked rather than assumed, and a tile with no cover at all simply
--- cannot be built on, whatever the switch says.
---
--- Cached by tile name: a survey crosses many tiles of a handful of prototypes,
--- and each lookup walks two prototype references.
local function cover_test()
  local known = {}

  return function(tile)
    local name = tile.name
    local cached = known[name]
    if cached ~= nil then return cached end

    local cover = tile.prototype.default_cover_tile
    local result = cover and cover.name or false

    known[name] = result
    return result
  end
end

local function survey_box(surface, box, water, occupants, obstructs, cover_of)
  -- A water tile maps to the name of its cover tile, or to false when nothing
  -- covers it. Both say "this is water"; only the first says "and it can be
  -- bridged".
  for _, tile in pairs(surface.find_tiles_filtered { area = box, collision_mask = "water_tile" }) do
    water[key_of(tile.position.x, tile.position.y)] = cover_of(tile)
  end

  for _, entity in pairs(surface.find_entities_filtered { area = box }) do
    if entity.valid and obstructs(entity) then
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
end

--- Everything the run needs to know about the world, in a couple of queries
--- rather than two per tile. Entities are bucketed onto every tile their
--- bounding box touches, so a 3x3 machine blocks all nine.
---
--- Takes a LIST of boxes: a corner is surveyed as two thin bands rather than the
--- mostly-empty rectangle enclosing them.
local function survey(surface, boxes, obstructs)
  local water, occupants = {}, {}
  local cover_of = cover_test()

  for _, box in ipairs(boxes) do
    survey_box(surface, box, water, occupants, obstructs, cover_of)
  end

  return water, occupants
end

--- What this entity means for the tile it sits on.
---
--- "clear" - trees, rocks and wild plants, always removed: that is what stamping
---   a vanilla blueprint does, and nobody means to keep a tree standing where
---   they just asked for a belt.
--- "own"   - something the player built, with the clearing option switched off.
---   Reported separately so the refusal can say which switch would fix it.
--- "cliff" - a cliff, with the blasting option off or not yet available.
---   Reported separately for the same reason.
--- "block" - anything else. Nothing is tunnelled under, so it simply stops.
local function verdict_for(entity, context)
  local kind = entity.type

  if kind == "tree" then return "clear" end
  if kind == "simple-entity" and entity.prototype.count_as_rock_for_filtered_deconstruction then
    return "clear"
  end

  -- Gleba's yumako trees and jellystems are "plant", not "tree": a plant is a
  -- tree that grows. The engine keeps every plant on the neutral force, even one
  -- an agricultural tower planted - create_entity with another force hands back
  -- a neutral plant, which the selftest pins - so there is no crop to tell apart
  -- from a weed, and a plant goes the way a tree does: a vanilla deconstruction
  -- planner treats the two alike.
  if kind == "plant" then return "clear" end

  -- A cliff is never cleared by default, because blowing one up costs cliff
  -- explosives the player may be saving, and it is never left to the engine's
  -- placement check either: with cliff explosives researched, a forced build
  -- check over a cliff reports placeable and would have marked the cliff as a
  -- side effect of building. That is exactly the kind of quiet guess this tool
  -- must not make, so the cliff is either ordered removed here in plain sight
  -- or it stops the run.
  if kind == "cliff" then
    return context.clear_cliffs and "clear" or "cliff"
  end

  -- A character can no longer reach this far: a character's collision mask
  -- shares no layer with a belt's, so the survey drops it before here. The guard
  -- stays anyway, because marking a player for deconstruction is a bad enough
  -- outcome to keep one comparison against.
  if kind ~= "character" and entity.force.name == context.force_name then
    return context.clear_built and "clear" or "own"
  end

  return "block"
end

--- Decide what one tile is, and what would have to go to make it usable.
---
--- The engine is only consulted when something we may NOT remove is present,
--- because can_place_entity answers the wrong question on its own: a belt GHOST
--- places quite happily under a tree, so trusting it would silently leave the
--- tree standing and the ghost unbuildable. That was the bug this shape exists
--- to prevent.
---
--- Returns the state, the entities to remove, and for water the name of the
--- tile that will cover it.
local function classify(context, direction, tile, water, occupants)
  local key = key_of(tile.x, tile.y)

  local cover = water[key]
  if cover ~= nil then
    -- Water with nothing to cover it is as solid a wall as a cliff: no ghost
    -- could ever be built there, so the switch cannot help and does not try.
    if cover and context.landfill then
      return WATER, nil, cover
    end
    return BLOCKED
  end

  local present = occupants[key]
  if not present then
    return FREE
  end

  local removable, obstructed, owned, cliff = {}, false, false, false
  for _, entity in ipairs(present) do
    if entity.valid then
      local verdict = verdict_for(entity, context)
      if verdict == "clear" then
        removable[#removable + 1] = entity
      elseif verdict == "own" then
        owned = true
      elseif verdict == "cliff" then
        cliff = true
      else
        obstructed = true
      end
    end
  end

  -- Your own building takes precedence in the reporting: it is the one the
  -- player can clear with a switch. A cliff comes next, for the same reason.
  if owned then
    return OWNED
  end
  if cliff then
    return CLIFF
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
local function plan_run(context, run, water, occupants, specs, blockers)
  local tiles, direction = run.tiles, run.direction
  local states, removals, covers = {}, {}, {}
  for index, tile in ipairs(tiles) do
    states[index], removals[index], covers[index] =
      classify(context, direction, tile, water, occupants)
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

  -- Nothing is tunnelled under and nothing the player built is removed unasked,
  -- so anything in the way stops the run. Every offending tile is collected
  -- before refusing, rather than bailing on the first, so the preview can show
  -- the player all of them at once.
  local owned, cliff, blocked = false, false, false
  for index, state in ipairs(states) do
    if state == OWNED then
      owned = true
      blockers[#blockers + 1] = tiles[index]
    elseif state == CLIFF then
      cliff = true
      blockers[#blockers + 1] = tiles[index]
    elseif state == BLOCKED then
      blocked = true
      blockers[#blockers + 1] = tiles[index]
    end
  end

  if owned then
    return false, { "beltplanner.error-own-structure" }
  end
  if cliff then
    return false, { "beltplanner.error-cliff" }
  end
  if blocked then
    return false, { "beltplanner.error-blocked" }
  end

  for index, tile in ipairs(tiles) do
    emit_removals(index)

    -- The kind stays "landfill" whatever the surface calls its cover, because
    -- that is the word the player knows and the one the preview and the commit
    -- key on. The name is the tile that actually gets placed.
    if states[index] == WATER then
      specs[#specs + 1] = {
        kind = "landfill",
        name = covers[index],
        position = centre(tile),
      }
    end

    specs[#specs + 1] = {
      kind = "belt",
      name = context.tier.belt,
      position = centre(tile),
      direction = direction,
      quality = context.quality,
    }
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
  -- they are kept.
  local kept, replaced = {}, {}
  for _, spec in ipairs(specs) do
    local lane = spec.position
      and lane_of[key_of(floor(spec.position.x), floor(spec.position.y))]

    if lane and spec.kind == "belt" then
      replaced[lane] = true
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
      quality = context.quality,
    }
  end

  return kept
end

--------------------------------------------------------------------------------
-- public

--- May this force order a cliff removed at all?
---
--- Cliffs can only be deconstructed once cliff explosives are researched; the
--- technology flips this flag on the force, and a deconstruction order on a
--- cliff before then is ignored by the engine. The switch in the tool window is
--- therefore not enough on its own, and the gate lives here rather than in the
--- window so the plan cannot be talked into it by stale GUI state. The force may
--- arrive as a name, the way the self-test passes it.
function plan.can_clear_cliffs(force)
  if type(force) == "string" then
    force = game.forces[force]
  end
  return force ~= nil and force.cliff_deconstruction_enabled == true
end

--- Build the full spec list for a run.
---
--- `options` carries { tier, landfill, clear_built, clear_cliffs, max_tiles,
--- splitters, quality }. Returns { specs, blockers, cost, quality } or nil plus a
--- LocalisedString and the blocking tiles.
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
    clear_built = options.clear_built or false,
    clear_cliffs = options.clear_cliffs and plan.can_clear_cliffs(force) or false,
    -- Only entity ghosts carry this. Landfill is a tile ghost, and tiles have
    -- no quality, so the landfill spec never gets it.
    quality = options.quality,
    seen = {},
  }

  local water, occupants = survey(surface, geometry.survey_boxes(anchor, resolved),
    obstruction_test(tier.belt))

  local specs, blockers = {}, {}

  -- Every lane is walked even once one has failed. The specs are thrown away,
  -- but the blockers are not: the preview paints them, and showing only the
  -- first lane's obstruction while the others sit there unmarked reads as though
  -- clearing that one tile would fix it.
  local failure
  for lane = 1, anchor.lanes do
    -- A corner splits a lane into two straight runs, each with its own facing.
    for _, run in ipairs(geometry.lane_runs(anchor, resolved, lane)) do
      local ok, reason = plan_run(context, run, water, occupants, specs, blockers)
      if not ok then
        failure = failure or reason
      end
    end
  end

  if failure then
    return nil, failure, blockers
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

  -- quality is echoed back so the preview labels what the specs will actually be
  -- placed at, rather than re-reading the player's choice and risking the two
  -- drifting apart.
  return { specs = specs, blockers = blockers, cost = cost, quality = context.quality }
end

return plan
