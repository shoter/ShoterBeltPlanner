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

local belts = {}

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
      local key = speed_key(proto.belt_speed)
      splitter_by_speed[key] = splitter_by_speed[key] or name
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
        -- How far apart the two ends of a pair may sit, in tiles.
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

  return { tiers = tiers, order = order }
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

--- True when this tier can bridge a gap of `gap` blocked tiles: the pair needs
--- one tile for the entry and one for the exit, and the engine measures
--- max_distance between the two ends.
function belts.can_span(tier, gap)
  if not (tier and tier.underground and tier.max_distance) then return false end
  return (gap + 1) <= tier.max_distance
end

--- Invalidate the cache. Only needed if something reloads prototypes mid-session,
--- which nothing does today; kept so the cache never becomes a debugging trap.
function belts.invalidate()
  cache = nil
end

return belts
