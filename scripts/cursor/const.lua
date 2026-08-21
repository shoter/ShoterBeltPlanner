-- Shared by the data stage and the control stage: both need the probe names and
-- sizes, and they must agree exactly or the tracker silently never fires.

local const = {}

const.NAME_PREFIX = "beltplanner-tracker-"
const.FORCE_NAME  = "beltplanner-tracker"

-- The tracker is a quadtree of invisible probes. A probe of size 2^pow is
-- subdivided into SUBDIVISIONS^2 children of size 2^(pow-1) when the cursor
-- lands on it, so the search narrows one level per tick until it reaches
-- MIN_POW, which is the resolution the cursor position is reported at (one tile).
const.SUBDIVISIONS = 2
-- The game draws its own selection box round whatever the cursor is over, and
-- that is always one of these probes while the tool is held. Every level in this
-- range is therefore a box size the player sees flicker past as the search
-- narrows, so the range is kept short: one tile is as precise as the planner
-- ever needs, and 32 still catches the cursor anywhere on screen.
const.MIN_POW      = 0   -- 2^0 = one tile
const.MAX_POW      = 5   -- 2^5 = 32 tiles per root probe

-- Roots are a ROOT_SPAN x ROOT_SPAN block, so 7 covers 224x224 tiles for 49
-- entities. The block follows the POINTER, not the player: anchoring it to the
-- character meant the preview simply stopped once the cursor was more than about
-- eighty tiles away, which is well within what a zoomed-out screen shows.
--
-- It is re-centred before the pointer can reach the edge rather than after, so
-- there is never a gap where nothing is tracked. RECENTRE_DISTANCE is measured
-- from the block's centre and leaves at least one whole root cell of margin.
const.ROOT_SPAN        = 7
const.RESEED_DISTANCE  = 32
const.RECENTRE_DISTANCE = (math.floor(const.ROOT_SPAN / 2) - 1) * (const.SUBDIVISIONS ^ const.MAX_POW)

-- A negative power would make a name like "...-tracker--1"; spell it "m1".
local function level_name(pow)
  return const.NAME_PREFIX .. (pow < 0 and ("m" .. -pow) or tostring(pow))
end
const.level_name = level_name

const.levels  = {}  -- coarse -> fine
const.by_pow  = {}
const.by_name = {}

for pow = const.MAX_POW, const.MIN_POW, -1 do
  local size = const.SUBDIVISIONS ^ pow
  local level = {
    pow     = pow,
    size    = size,
    half    = size / 2,
    name    = level_name(pow),
    is_root = (pow == const.MAX_POW),
    is_leaf = (pow == const.MIN_POW),
    -- A child sits inside its parent, so both are under the cursor at once.
    -- Priority has to rise as the box shrinks or the descent stalls on the
    -- parent. 255 is the engine maximum; staying under it leaves other mods
    -- room to outrank us deliberately.
    selection_priority = 200 + (const.MAX_POW - pow),
  }
  const.levels[#const.levels + 1] = level
  const.by_pow[pow]         = level
  const.by_name[level.name] = level
end

const.root = const.by_pow[const.MAX_POW]
const.leaf = const.by_pow[const.MIN_POW]

return const
