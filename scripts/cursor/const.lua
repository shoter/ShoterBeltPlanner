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
-- that is always one of these probes while the tool is held. Only the leaf's box
-- is ever seen: the tracker drops the selection as soon as a coarser probe has
-- been subdivided, because otherwise every level in this range flashes past as a
-- box of its own size and the tool looks like it is picking areas it is not.
--
-- The range is still kept short, since each level costs a tick of input lag: one
-- tile is as precise as the planner ever needs, and 32 still catches the cursor
-- anywhere on screen.
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
    -- A child sits inside its parent, so both are under the cursor at once, and
    -- priority has to rise as the box shrinks or the descent stalls on the
    -- parent. 255 is the engine maximum; staying under it leaves other mods room
    -- to outrank us deliberately.
    --
    -- The ROOTS are the exception and sit below everything instead. They tile a
    -- 224x224 block, so at high priority they take the cursor off every real
    -- entity in that whole area -- and not only for the player being tracked,
    -- because visibility is a property of the force, so in multiplayer everyone
    -- on it loses their cursor to boxes they cannot see. Below the default of 50
    -- a root only wins over bare ground, which is all it has to do to start a
    -- descent, and the probes that DO outrank real entities then cover one root
    -- cell rather than the whole block.
    --
    -- A descent therefore cannot BEGIN on a root while the pointer rests on
    -- something selectable. That used to mean waiting for open ground; the
    -- tracker now guesses the finer levels instead of walking down to them, both
    -- when the field is re-seeded and when a real entity is what got selected,
    -- and those probes do outrank ordinary entities.
    --
    -- 1, not 0: the engine treats a selection_priority of 0 as though the field
    -- were absent and gives it the default of 50, which would tie with ordinary
    -- entities rather than lose to them. Nothing complains -- the prototype
    -- simply reads back as 50 - so the self-test asserts the value the engine
    -- ended up with rather than the one written here.
    selection_priority = (pow == const.MAX_POW) and 1 or (250 + (const.MAX_POW - 1 - pow)),
  }
  const.levels[#const.levels + 1] = level
  const.by_pow[pow]         = level
  const.by_name[level.name] = level
end

const.root = const.by_pow[const.MAX_POW]
const.leaf = const.by_pow[const.MIN_POW]

return const
