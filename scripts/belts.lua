-- Belt tier registry.
--
-- Built once per load from the prototypes rather than kept in storage: prototype
-- data is rebuilt on every load anyway, so caching it in a save could only ever
-- go stale against a changed mod set.
--
-- Note the asymmetry the engine actually has, which is easy to get backwards:
-- `related_underground_belt` points belt -> underground and is nil on the
-- underground itself, and `max_underground_distance` lives on the UNDERGROUND
-- prototype, not on the belt.

local preview_const = require("scripts/belt_preview_const")

local belts = {}

-- draw_animation takes a prototype name, and the four cardinal names are what
-- the data stage sliced. Anything diagonal has no belt graphic to show.
local DIRECTION_NAME = {
  [defines.direction.north] = "north",
  [defines.direction.east] = "east",
  [defines.direction.south] = "south",
  [defines.direction.west] = "west",
}

local cache

-- Belt speeds are floats, so they are keyed as fixed-precision strings rather
-- than trusted to compare equal as numbers.
local function speed_key(speed)
  return string.format("%.8f", speed or 0)
end

local function build()
  local tiers = {}
  local order = {}

  -- A splitter has no link back to its belt - there is no related_splitter - so
  -- it is matched on throughput instead: a tier's splitter is the one that moves
  -- items at the same rate. That holds for vanilla and for any mod shipping a
  -- matched belt family, and a tier simply has no splitter if nothing matches.
  local splitter_by_speed = {}
  for name, proto in pairs(prototypes.get_entity_filtered { { filter = "type", type = "splitter" } }) do
    local items = proto.items_to_place_this
    if items and #items > 0 then
      -- pairs() order over a prototype table is not something to depend on, so
      -- two splitters at one speed are settled by name rather than by whichever
      -- the iteration happened to reach first.
      local key = speed_key(proto.belt_speed)
      local chosen = splitter_by_speed[key]
      if not chosen or name < chosen then
        splitter_by_speed[key] = name
      end
    end
  end

  for name, proto in pairs(prototypes.get_entity_filtered { { filter = "type", type = "transport-belt" } }) do
    -- A belt with nothing to place it with is scenery or a mod's internal
    -- helper, not something a player can be offered.
    local items = proto.items_to_place_this
    if items and #items > 0 then
      local underground = proto.related_underground_belt

      local tier = {
        belt = name,
        item = items[1].name,
        speed = proto.belt_speed,
        underground = underground and underground.name or nil,
        -- Nothing places these yet: automatic tunnelling was removed because
        -- choosing an underground's length for the player is exactly the kind of
        -- guess this tool refuses to make. They are still resolved here, because
        -- a manual "put an underground here" gesture will want them and
        -- re-deriving the pairing later is pointless work.
        max_distance = underground and underground.max_underground_distance or nil,
        splitter = splitter_by_speed[speed_key(proto.belt_speed)],
      }

      tiers[name] = tier
      order[#order + 1] = tier
    end
  end

  table.sort(order, function(a, b)
    if a.speed ~= b.speed then return a.speed < b.speed end
    return a.belt < b.belt
  end)

  -- Which belts the data stage managed to slice a preview animation out of.
  -- Belts whose graphics use layers, stripes or a filename list are absent and
  -- fall back to their item icon.
  local previewable = {}
  local published = prototypes.mod_data[preview_const.MOD_DATA]
  if published and type(published.data) == "table" then
    for name in pairs(published.data) do previewable[name] = true end
  end

  return { tiers = tiers, order = order, previewable = previewable }
end

local function get()
  cache = cache or build()
  return cache
end

--- Every usable belt tier, slowest first. Each entry is
--- { belt, item, speed, underground, max_distance }.
function belts.all()
  return get().order
end

--- One tier by belt prototype name, or nil.
function belts.get(belt_name)
  return get().tiers[belt_name]
end

--- The slowest tier, used as the default before the player has chosen.
function belts.default()
  return get().order[1]
end

--- The animation prototype that draws this belt facing this way, or nil when the
--- belt's graphics could not be sliced and the icon has to stand in.
function belts.preview_animation(belt_name, direction)
  local cached = get()
  if not cached.previewable[belt_name] then return nil end

  local direction_name = DIRECTION_NAME[direction]
  if not direction_name then return nil end

  return preview_const.animation_name(belt_name, direction_name)
end

--------------------------------------------------------------------------------
-- research

--- Every recipe that produces this item, by name. Cached for the life of the
--- load alongside the tiers: the prototype query is the expensive half, and it
--- cannot change without a reload. Whether a force has those recipes is NOT
--- cached, since that is exactly what research changes.
---
--- The recipe is looked up by product rather than by name because a recipe being
--- called after its item is a vanilla habit, not a rule; a modded belt may well
--- come out of a recipe named something else, or out of several.
local function recipes_for(item)
  local cached = get()
  cached.recipes_by_item = cached.recipes_by_item or {}

  local names = cached.recipes_by_item[item]
  if names then return names end

  names = {}
  local found = prototypes.get_recipe_filtered {
    { filter = "has-product-item", elem_filters = { { filter = "name", name = item } } },
  }
  for name in pairs(found) do names[#names + 1] = name end
  table.sort(names)

  cached.recipes_by_item[item] = names
  return names
end

local function craftable(force, tier)
  for _, name in ipairs(recipes_for(tier.item)) do
    local recipe = force.recipes[name]
    if recipe and recipe.enabled then return true end
  end
  return false
end

--- The tiers this force can build right now, as a set keyed by belt name.
---
--- When the force can build none of them - a mod set that unlocks belts some
--- other way, or a scenario that starts with nothing - the whole list is
--- offered rather than nothing at all. A picker with every button greyed out
--- is a dead tool, and a ghost for a belt you cannot yet make is merely a
--- ghost that waits.
function belts.unlocked_set(force)
  local set = {}
  local any = false
  for _, tier in ipairs(get().order) do
    if craftable(force, tier) then
      set[tier.belt] = true
      any = true
    end
  end

  if not any then
    for _, tier in ipairs(get().order) do set[tier.belt] = true end
  end
  return set
end

--- Whether this force can currently build this tier. See unlocked_set for what
--- happens when it can build none.
function belts.unlocked(force, belt_name)
  return belts.unlocked_set(force)[belt_name] == true
end

--- The tier a cycling keypress lands on: from `current_belt`, `direction` steps
--- of +1 (faster) or -1 (slower) through the tiers this force can build,
--- wrapping round. Locked tiers are skipped over, not avoided: a locked current
--- tier - research reversed under the player, say - is stepped away from like
--- any other, but the player's choice is never changed for them until they
--- press the key.
---
--- Returns nil only when there are no tiers at all.
function belts.step(force, current_belt, direction)
  local order = get().order
  local count = #order
  if count == 0 then return nil end

  direction = direction or 1
  local index = 1
  for i, tier in ipairs(order) do
    if tier.belt == current_belt then
      index = i
      break
    end
  end

  -- The last candidate tried is the current tier itself, so with a single
  -- buildable tier the key lands where it started rather than nowhere.
  local unlocked = belts.unlocked_set(force)
  for step = 1, count do
    local candidate = order[((index - 1 + step * direction) % count) + 1]
    if unlocked[candidate.belt] then return candidate end
  end
  return nil
end

--- Invalidate the cache. Only needed if something reloads prototypes mid-session,
--- which nothing does today; kept so the cache never becomes a debugging trap.
function belts.invalidate()
  cache = nil
end

return belts
