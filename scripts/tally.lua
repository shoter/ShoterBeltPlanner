-- What the click will cost, counted off the spec list the preview already has.
--
-- The label at the cursor and the status in the tool window both show this,
-- and both get it from here, so the two can never drift apart and quote the
-- player different numbers for the same run. The counts come from the same
-- list place.lua commits, which is what makes them a statement of fact rather
-- than an estimate: if the tally says three trees, three trees are marked.
--
-- Nothing here touches the world. The specs carry everything needed, and a
-- tally is taken on every re-plan, so it must stay as cheap as one pass over
-- the list.

local qualities = require("scripts/qualities")

local tally = {}

-- A belt's speed is in tiles per tick. A tile of belt holds eight items across
-- its two sides and there are sixty ticks in a second, so items per second is
-- speed * 480: yellow is 0.03125 tiles per tick, which is the familiar 15/s.
local ITEMS_PER_TILE = 8
local TICKS_PER_SECOND = 60

--- Items per second one belt of this tier moves.
function tally.throughput(tier)
  return (tier and tier.speed or 0) * ITEMS_PER_TILE * TICKS_PER_SECOND
end

--- Trees and rocks: what the run fells without being asked.
---
--- This mirrors the rule in plan.lua's verdict_for, which is local there on
--- purpose. plan.lua only ever emits a removal for something this says yes to
--- or for a building on the player's own force with the clearing switch on, so
--- whatever is NOT natural in a removal spec is one of the player's own.
local function is_natural(entity)
  local kind = entity.type
  if kind == "tree" or kind == "plant" then return true end
  return kind == "simple-entity"
    and entity.prototype.count_as_rock_for_filtered_deconstruction == true
end

--- Count the specs by what they will cost the player.
---
--- Every kind the preview knows how to draw is counted here, including the ones
--- nothing emits yet (undergrounds, and splitters outside a click), so that when
--- one appears the tally already says so instead of quietly leaving it out.
function tally.count(specs)
  local counts = {
    belts = 0,
    undergrounds = 0,
    splitters = 0,
    landfill = 0,
    natural = 0,
    cliffs = 0,
    owned = 0,
  }

  for _, spec in ipairs(specs) do
    local kind = spec.kind
    if kind == "belt" then
      counts.belts = counts.belts + 1
    elseif kind == "underground" then
      counts.undergrounds = counts.undergrounds + 1
    elseif kind == "splitter" then
      counts.splitters = counts.splitters + 1
    elseif kind == "landfill" then
      counts.landfill = counts.landfill + 1
    elseif kind == "deconstruct" then
      local entity = spec.entity
      if entity and entity.valid and is_natural(entity) then
        counts.natural = counts.natural + 1
      elseif entity and entity.valid and entity.type == "cliff" then
        -- Named apart from the player's buildings because it costs something
        -- of its own: the robots will spend cliff explosives on it.
        counts.cliffs = counts.cliffs + 1
      else
        counts.owned = counts.owned + 1
      end
    end
  end

  return counts
end

--- "15", not "15.0"; "7.5" for a modded belt that does not land on a whole
--- number. Returned as a string so the locale shows exactly this.
local function format_rate(rate)
  local rounded = math.floor(rate * 10 + 0.5) / 10
  if rounded == math.floor(rounded) then
    return string.format("%d", rounded)
  end
  return string.format("%.1f", rounded)
end

--- What the label adds for a non-normal quality, or nothing.
---
--- Normal is left unsaid: it is what every ghost was before quality could be
--- chosen, and on an install without quality the label has to read exactly as
--- it always did. The name comes from the plan result, not from the player's
--- choice, so the label describes what the specs will be placed at.
local function quality_suffix(result)
  local quality = result and result.quality and qualities.get(result.quality)
  if not quality or quality.name == "normal" then return "" end
  return { "beltplanner.quality-suffix", quality.localised_name }
end

--- The run itself: how wide, how long, how much it moves, which way, and at
--- what quality when that is worth saying.
function tally.run_line(anchor, result, tier)
  return {
    "beltplanner.preview-label",
    anchor.lanes,
    result.cost,
    format_rate(tally.throughput(tier) * anchor.lanes),
    { "", anchor.reversed and { "beltplanner.reversed-suffix" } or "", quality_suffix(result) },
  }
end

--- What it costs, naming only the parts that are not zero, or nil when there is
--- nothing to name.
---
--- Each part is its own locale string and the list is joined here, so a
--- translator gets every fragment rather than one template with the pieces
--- baked in. A localised string takes at most 20 parameters; seven parts and six
--- separators is well inside that, and anything added here must stay inside it.
function tally.cost_line(counts)
  local parts = { "" }

  local function add(key, amount)
    if amount <= 0 then return end
    if #parts > 1 then
      parts[#parts + 1] = { "beltplanner.tally-separator" }
    end
    parts[#parts + 1] = { key, amount }
  end

  add("beltplanner.tally-belts", counts.belts)
  add("beltplanner.tally-undergrounds", counts.undergrounds)
  add("beltplanner.tally-splitters", counts.splitters)
  add("beltplanner.tally-landfill", counts.landfill)
  add("beltplanner.tally-natural", counts.natural)
  add("beltplanner.tally-cliffs", counts.cliffs)
  add("beltplanner.tally-owned", counts.owned)

  if #parts == 1 then return nil end
  return parts
end

--- Both lines for a planned run: `run` is always present, `cost` is nil when
--- the list is empty. `counts` is kept on it for anything that wants the
--- numbers rather than the text.
function tally.summary(anchor, result, tier)
  local counts = tally.count(result.specs)
  return {
    run = tally.run_line(anchor, result, tier),
    cost = tally.cost_line(counts),
    counts = counts,
  }
end

return tally
