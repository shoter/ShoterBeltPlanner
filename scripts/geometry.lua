-- Pure tile geometry. No world access, no storage, no side effects, so this is
-- the part of the planner that can be reasoned about and tested on its own.
--
-- Tile convention: tile (tx, ty) covers [tx, tx+1) x [ty, ty+1), and an entity
-- placed on it is centred at (tx + 0.5, ty + 0.5). Factorio's y axis grows
-- downwards, so +y is south.
--
-- Everything below works in ALONG/CROSS coordinates rather than x/y. `along` is
-- the anchor's own axis - the way the run leaves the anchor - and `cross` is
-- perpendicular to it. That makes a run turning east-to-south the same code as
-- one turning north-to-west, which is the only way the corner logic stays
-- readable.

local geometry = {}

local floor, ceil, abs, max, min = math.floor, math.ceil, math.abs, math.max, math.min

local DIRECTION = {
  x = { [1] = defines.direction.east, [-1] = defines.direction.west },
  y = { [1] = defines.direction.south, [-1] = defines.direction.north },
}

local PERPENDICULAR = { x = "y", y = "x" }

local function to_tile(axis, along, cross)
  if axis == "x" then return { x = along, y = cross } end
  return { x = cross, y = along }
end

local function of_tile(axis, tile)
  if axis == "x" then return tile.x, tile.y end
  return tile.y, tile.x
end

local function sign_of(value)
  return value > 0 and 1 or -1
end

local function reversed_copy(list)
  local out, count = {}, #list
  for index = 1, count do out[index] = list[count + 1 - index] end
  return out
end

--------------------------------------------------------------------------------
-- anchors

--- Tile range covered by a selection area.
---
--- `ceil(right_bottom) - 1` is right for a dragged box but collapses to zero
--- width when a coordinate lands exactly on a tile boundary, which is what a
--- click on an integer position produces, hence the max().
local function tile_bounds(area)
  local x1 = floor(area.left_top.x)
  local y1 = floor(area.left_top.y)
  return x1, y1,
    max(x1, ceil(area.right_bottom.x) - 1),
    max(y1, ceil(area.right_bottom.y) - 1)
end

geometry.tile_bounds = tile_bounds

--- Turn the opening selection into an anchor.
---
--- The brief's rule: the rectangle always has one side of length 1. That short
--- side is the run axis (the belt is one tile deep at the start), and the long
--- side is the width, one lane per tile. A 1x1 selection is legal but leaves the
--- axis open until the first endpoint decides it.
local function anchor_from_tiles(x1, y1, x2, y2)
  local width = x2 - x1 + 1
  local height = y2 - y1 + 1

  local axis, lanes
  if width == 1 and height == 1 then
    axis, lanes = nil, 1
  elseif width == 1 then
    axis, lanes = "x", height
  elseif height == 1 then
    axis, lanes = "y", width
  else
    return nil, { "beltplanner.error-not-a-line", width, height }
  end

  return {
    axis = axis,
    lanes = lanes,
    tile = { x = x1, y = y1 },
    reversed = false,
  }
end

function geometry.anchor_from_area(area)
  return anchor_from_tiles(tile_bounds(area))
end

--- The anchor implied by a first click at `origin` and the pointer now at
--- `cursor`.
---
--- Snapped to whichever axis the pointer has travelled furthest along, so the
--- shape is always a legal line one tile deep and there is no illegal state to
--- warn about. A tie goes to the vertical - arbitrary, but consistent, and a tie
--- only happens on an exact diagonal.
function geometry.anchor_between(origin, cursor)
  local dx = cursor.x - origin.x
  local dy = cursor.y - origin.y

  if abs(dy) >= abs(dx) then
    return anchor_from_tiles(origin.x, min(origin.y, cursor.y), origin.x, max(origin.y, cursor.y))
  end
  return anchor_from_tiles(min(origin.x, cursor.x), origin.y, max(origin.x, cursor.x), origin.y)
end

--- The start tile of lane `index` (1-based). Lanes sit one tile apart across the
--- run, starting at the anchor tile.
function geometry.lane_start(anchor, index)
  local offset = index - 1
  if anchor.axis == "x" then
    return { x = anchor.tile.x, y = anchor.tile.y + offset }
  end
  return { x = anchor.tile.x + offset, y = anchor.tile.y }
end

--------------------------------------------------------------------------------
-- resolving an endpoint

--- How far past the least-travelling lane this lane carries on before turning.
---
--- A bundle cannot turn as one tile: the lane on the OUTSIDE of the corner has
--- further to go, so the lanes turn at staggered points and come out of the
--- corner still parallel and still the same width.
local function stagger(lanes, index, cross_sign)
  if cross_sign > 0 then return lanes - index end
  return index - 1
end

--- Work out the run implied by pointing at `target`.
---
--- The anchor fixes the axis the run leaves along, so a target off to one side
--- means "go this far, then turn once" - never "turn first", which would make
--- one click mean two different routes.
---
--- Returns a descriptor, or nil plus a LocalisedString.
function geometry.resolve(anchor, target)
  local axis = anchor.axis
  if not axis then
    -- A 1x1 anchor has no axis yet; the longer of the two deltas picks it.
    local dx = target.x - anchor.tile.x
    local dy = target.y - anchor.tile.y
    if dx == 0 and dy == 0 then
      return nil, { "beltplanner.error-zero-length" }
    end
    axis = abs(dx) >= abs(dy) and "x" or "y"
  end

  local lanes = anchor.lanes
  local along0, cross0 = of_tile(axis, anchor.tile)
  local along_end, cross_end = of_tile(axis, target)

  local along_delta = along_end - along0
  local cross_delta = cross_end - cross0

  if along_delta == 0 then
    -- With no travel along the anchor's own axis there is no unambiguous way
    -- out of the anchor, so refuse rather than pick a side.
    return nil, { "beltplanner.error-zero-length" }
  end

  local along_sign = sign_of(along_delta)

  if cross_delta == 0 then
    return {
      axis = axis,
      curved = false,
      along_sign = along_sign,
      along_end = along_end,
      length = abs(along_delta) + 1,
    }
  end

  local cross_sign = sign_of(cross_delta)

  -- The corners occupy `lanes` consecutive along-coordinates starting at the
  -- target, so the destination bundle is the row the brief describes: the target
  -- tile plus lanes-1 beyond it.
  local corner_base = along_sign > 0 and along_end or (along_end + lanes - 1)

  -- Every lane needs somewhere to go before it turns, and somewhere to go after.
  for index = 1, lanes do
    local corner_along = corner_base + along_sign * stagger(lanes, index, cross_sign)
    if (corner_along - along0) * along_sign < 0 then
      return nil, { "beltplanner.error-corner-too-close" }
    end
    local lane_cross = cross0 + (index - 1)
    if (cross_end - lane_cross) * cross_sign < 1 then
      return nil, { "beltplanner.error-corner-too-shallow", lanes }
    end
  end

  return {
    axis = axis,
    curved = true,
    along_sign = along_sign,
    cross_sign = cross_sign,
    along_end = along_end,
    cross_end = cross_end,
    corner_base = corner_base,
  }
end

--------------------------------------------------------------------------------
-- laying a lane out

--- One lane as a list of straight runs, in the order items FLOW along them.
---
--- Ordering by flow rather than by how the run was drawn is what makes
--- backwards building fall out for free: the first tile of the first run is
--- always where items enter, so an underground pair is always entry-then-exit
--- and never has to be reasoned about twice. Each run carries its own direction,
--- and a corner starts a new run, which is also what stops a tunnel being dug
--- across a bend.
---
--- Returns an array of { tiles = {...}, direction = defines.direction }.
function geometry.lane_runs(anchor, resolved, index)
  local axis = resolved.axis
  local perpendicular = PERPENDICULAR[axis]
  local along0, cross0 = of_tile(axis, anchor.tile)
  local lane_cross = cross0 + (index - 1)
  local reversed = anchor.reversed

  if not resolved.curved then
    local tiles = {}
    for step = 0, resolved.length - 1 do
      tiles[step + 1] = to_tile(axis, along0 + resolved.along_sign * step, lane_cross)
    end

    if reversed then
      return { { tiles = reversed_copy(tiles), direction = DIRECTION[axis][-resolved.along_sign] } }
    end
    return { { tiles = tiles, direction = DIRECTION[axis][resolved.along_sign] } }
  end

  local corner_along = resolved.corner_base
    + resolved.along_sign * stagger(anchor.lanes, index, resolved.cross_sign)

  -- Leg one stops short of the corner: the corner tile already faces the new
  -- direction, so it belongs with leg two.
  local leg1 = {}
  local steps = (corner_along - along0) * resolved.along_sign
  for step = 0, steps - 1 do
    leg1[step + 1] = to_tile(axis, along0 + resolved.along_sign * step, lane_cross)
  end

  local corner = to_tile(axis, corner_along, lane_cross)

  local leg2 = {}
  local span = (resolved.cross_end - lane_cross) * resolved.cross_sign
  for step = 1, span do
    leg2[step] = to_tile(axis, corner_along, lane_cross + resolved.cross_sign * step)
  end

  if not reversed then
    local second = { corner }
    for _, tile in ipairs(leg2) do second[#second + 1] = tile end

    local runs = {}
    if #leg1 > 0 then
      runs[#runs + 1] = { tiles = leg1, direction = DIRECTION[axis][resolved.along_sign] }
    end
    runs[#runs + 1] = { tiles = second, direction = DIRECTION[perpendicular][resolved.cross_sign] }
    return runs
  end

  -- Flowing the other way the corner feeds leg one instead, so it moves.
  local second = { corner }
  for _, tile in ipairs(reversed_copy(leg1)) do second[#second + 1] = tile end

  local runs = {}
  if #leg2 > 0 then
    runs[#runs + 1] = {
      tiles = reversed_copy(leg2),
      direction = DIRECTION[perpendicular][-resolved.cross_sign],
    }
  end
  runs[#runs + 1] = { tiles = second, direction = DIRECTION[axis][-resolved.along_sign] }
  return runs
end

--- The far tile of one lane: where the run ends as DRAWN, which is where the
--- player pointed, regardless of which way items end up flowing along it.
--- Straight runs only - the lanes of a corner end staggered, so a row across
--- them would not line up.
function geometry.lane_end(anchor, resolved, index)
  if resolved.curved then return nil end

  local axis = resolved.axis
  local along0, cross0 = of_tile(axis, anchor.tile)
  return to_tile(
    axis,
    along0 + resolved.along_sign * (resolved.length - 1),
    cross0 + index - 1)
end

--------------------------------------------------------------------------------
-- derived facts

--- Box covering an along/cross rectangle, in world coordinates.
local function box_of(axis, along_lo, along_hi, cross_lo, cross_hi)
  local a = to_tile(axis, along_lo, cross_lo)
  local b = to_tile(axis, along_hi, cross_hi)
  return {
    left_top = { x = min(a.x, b.x), y = min(a.y, b.y) },
    right_bottom = { x = max(a.x, b.x) + 1, y = max(a.y, b.y) + 1 },
  }
end

--- The areas the world has to be surveyed over, so it can be read in a couple of
--- queries rather than one per tile.
---
--- A corner is returned as TWO boxes, one per leg, not as the rectangle that
--- encloses them. The enclosing rectangle of an L is almost all empty space: a
--- 100x60 corner spans some 6000 tiles to plan a few hundred, and surveying that
--- cost about ten times as much per tile as a straight run of the same length.
function geometry.survey_boxes(anchor, resolved)
  local axis = resolved.axis
  local along0, cross0 = of_tile(axis, anchor.tile)
  local lanes = anchor.lanes
  local cross_hi = cross0 + lanes - 1

  if not resolved.curved then
    local far = along0 + resolved.along_sign * (resolved.length - 1)
    return { box_of(axis, min(along0, far), max(along0, far), cross0, cross_hi) }
  end

  -- The corners occupy `lanes` consecutive along-coordinates; the legs run out
  -- of those in each direction.
  local corner_far = resolved.corner_base + resolved.along_sign * (lanes - 1)
  local corner_lo = min(resolved.corner_base, corner_far)
  local corner_hi = max(resolved.corner_base, corner_far)

  return {
    -- everything before the turn: a band `lanes` wide along the anchor axis
    box_of(axis, min(along0, corner_lo), max(along0, corner_hi), cross0, cross_hi),
    -- everything after it: a band `lanes` wide across the other axis
    box_of(axis, corner_lo, corner_hi,
      min(cross0, resolved.cross_end), max(cross_hi, resolved.cross_end)),
  }
end

--- Where the next segment starts if the player keeps clicking.
---
--- After a corner the bundle is travelling the other way, so the anchor's axis
--- flips with it and chaining carries on as if the new leg had been drawn by
--- hand.
function geometry.next_anchor(anchor, resolved)
  local axis = resolved.axis

  if not resolved.curved then
    local along0, cross0 = of_tile(axis, anchor.tile)
    local far = along0 + resolved.along_sign * (resolved.length - 1)
    return {
      axis = axis,
      lanes = anchor.lanes,
      tile = to_tile(axis, far, cross0),
      reversed = anchor.reversed,
    }
  end

  return {
    axis = PERPENDICULAR[axis],
    lanes = anchor.lanes,
    -- In the new axis the old cross becomes the along, and the corners' own
    -- along becomes the new cross - lowest first, which is where lane 1 sits.
    tile = to_tile(PERPENDICULAR[axis], resolved.cross_end, resolved.along_end),
    reversed = anchor.reversed,
  }
end

--- How many tile-slots a run costs, for the calculation budget.
function geometry.cost(anchor, resolved)
  if not resolved.curved then
    return anchor.lanes * resolved.length
  end

  local along0, cross0 = of_tile(resolved.axis, anchor.tile)
  local total = 0
  for index = 1, anchor.lanes do
    local corner_along = resolved.corner_base
      + resolved.along_sign * stagger(anchor.lanes, index, resolved.cross_sign)
    local lane_cross = cross0 + (index - 1)
    local leg1 = (corner_along - along0) * resolved.along_sign
    local leg2 = (resolved.cross_end - lane_cross) * resolved.cross_sign
    total = total + leg1 + 1 + leg2
  end
  return total
end

return geometry
