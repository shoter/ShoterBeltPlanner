-- Shared by the data stage and the control stage: both need the probe names and
-- sizes, and they must agree exactly or the tracker silently never fires.

local const = {}

const.NAME_PREFIX = "beltplanner-tracker-"
const.FORCE_NAME  = "beltplanner-tracker"

-- The ladder of probe sizes, coarse -> fine. When the cursor lands on a probe
-- it is replaced underneath by children one rung finer, which tile it exactly,
-- and the child covering the pointer is highlighted next tick. Each rung costs
-- ONE TICK of input lag -- the engine only reports the new selection on the
-- following tick -- so the ladder is kept shallow rather than binary:
-- 32 -> 8 -> 1 converges in two ticks from cold instead of five.
--
-- The wide rungs also buy latency where it is felt most. The 64 leaves blanket
-- an 8x8-tile area, so ordinary mouse movement inside it lands straight on a
-- sibling leaf and costs no ticks at all; and the 16 mid probes tile the whole
-- 32-cell, so any move within the current root cell costs at most one tick --
-- even over machines, since every non-root probe outranks real entities.
--
-- The game draws its own selection box round whatever the cursor is over, and
-- that is always one of these probes while the tool is held. Only the leaf's
-- box is ever seen: the tracker drops the selection as soon as a coarser probe
-- has been subdivided, because otherwise every rung flashes past as a box of
-- its own size and the tool looks like it is picking areas it is not.
--
-- One tile is as precise as the planner ever needs, and 32 still catches the
-- cursor anywhere on screen. Sizes must be powers of two (the names carry
-- log2) and each must divide its parent evenly (the children tile it).
local SIZES = { 32, 8, 1 }

-- Roots are a ROOT_SPAN x ROOT_SPAN block, so 7 covers 224x224 tiles for 49
-- entities. The block follows the POINTER, not the player: anchoring it to the
-- character meant the preview simply stopped once the cursor was more than about
-- eighty tiles away, which is well within what a zoomed-out screen shows.
const.ROOT_SPAN        = 7
const.RESEED_DISTANCE  = 32

-- A negative power would make a name like "...-tracker--1"; spell it "m1".
local function level_name(pow)
  return const.NAME_PREFIX .. (pow < 0 and ("m" .. -pow) or tostring(pow))
end
const.level_name = level_name

const.levels  = {}  -- coarse -> fine
const.by_name = {}

for index, size in ipairs(SIZES) do
  -- Names carry log2(size), exactly as they did when the ladder was binary.
  -- That is deliberate: a probe whose size survives a version change keeps a
  -- valid prototype in old saves, and one whose size was dropped loses its
  -- prototype and is deleted by the engine on load -- no migration needed.
  local pow = 0
  while 2 ^ pow < size do pow = pow + 1 end
  assert(2 ^ pow == size, "probe sizes must be powers of two")

  local parent = const.levels[index - 1]
  assert(not parent or parent.size % size == 0, "each probe size must divide its parent")

  local level = {
    index   = index,          -- 1-based, coarse -> fine
    pow     = pow,            -- log2(size); only the name is derived from it
    size    = size,
    half    = size / 2,
    name    = level_name(pow),
    is_root = (index == 1),
    is_leaf = (index == #SIZES),
    parent  = parent,         -- the level one rung coarser, nil for the root
    child   = nil,            -- the level one rung finer, filled in below
    -- Children per axis when tiling the parent cell; nil for the root.
    per_parent = parent and (parent.size / size) or nil,
    -- A child sits inside its parent, so both are under the cursor at once, and
    -- priority has to rise as the box shrinks or the descent stalls on the
    -- parent: 252 for the mid probes, 253 for the leaves. 255 is the engine
    -- maximum; staying under it leaves other mods room to outrank us
    -- deliberately.
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
    selection_priority = (index == 1) and 1 or (250 + index),
  }
  if parent then parent.child = level end

  const.levels[index]       = level
  const.by_name[level.name] = level
end

const.root = const.levels[1]
const.leaf = const.levels[#const.levels]

-- The root block is re-centred before the pointer can reach the edge rather
-- than after, so there is never a gap where nothing is tracked.
-- RECENTRE_DISTANCE is measured from the block's centre and leaves at least one
-- whole root cell of margin.
const.RECENTRE_DISTANCE = (math.floor(const.ROOT_SPAN / 2) - 1) * const.root.size

return const
