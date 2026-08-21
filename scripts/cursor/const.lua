-- Shared by the data stage and the control stage: both need the probe names and
-- sizes, and they must agree exactly or the tracker silently never fires.

local const = {}

const.NAME_PREFIX = "beltplanner-tracker-"
const.FORCE_NAME  = "beltplanner-tracker"

-- The tracker is a quadtree of invisible probes. A probe of size 2^pow is
-- subdivided into SUBDIVISIONS^2 children of size 2^(pow-1) when the cursor
-- lands on it, so the search narrows one level per tick until it reaches
-- MIN_POW, which is the resolution the cursor position is reported at.
const.SUBDIVISIONS = 2
const.MIN_POW      = -1  -- 2^-1 = 0.5 tiles, i.e. sub-tile precision
const.MAX_POW      = 6   -- 2^6  = 64 tiles per root probe

-- Roots are seeded as a ROOT_SPAN x ROOT_SPAN block centred on the player, so
-- 3 covers 192x192 tiles - far past build range - for nine entities. Re-seeded
-- once the player has walked RESEED_DISTANCE from where the block was centred.
const.ROOT_SPAN        = 3
const.RESEED_DISTANCE  = 32

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
