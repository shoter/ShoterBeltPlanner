-- Quality registry.
--
-- Built once per load from the prototypes, for the same reason belts.lua is:
-- prototype data is rebuilt on every load anyway, so caching it in a save could
-- only ever go stale against a changed mod set.
--
-- A quality is offered to the player only if it is not hidden. The base game
-- ships "normal" plus a hidden "quality-unknown" placeholder, so without Space
-- Age or a quality mod exactly one quality is selectable, and everything that
-- shows a quality choice keys off that count to stay out of the way.

local qualities = {}

local NORMAL = "normal"

local cache

local function build()
  local order, by_name = {}, {}

  for name, proto in pairs(prototypes.quality) do
    if not proto.hidden then
      -- Plain records rather than the LuaQualityPrototype itself: everything
      -- that reads these wants a name, a sort key or a caption, and a table of
      -- three fields cannot go invalid.
      local record = {
        name = name,
        level = proto.level,
        order = proto.order,
        localised_name = proto.localised_name,
      }
      order[#order + 1] = record
      by_name[name] = record
    end
  end

  -- Level is the stat-increasing rank and is what the player means by "next
  -- quality up". Two qualities at one level fall back to the prototype order,
  -- then the name, so pairs() order over the prototype table never decides.
  table.sort(order, function(a, b)
    if a.level ~= b.level then return a.level < b.level end
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)

  return { order = order, by_name = by_name }
end

local function get()
  cache = cache or build()
  return cache
end

--- Every selectable quality, lowest level first. Each entry is
--- { name, level, order, localised_name }.
function qualities.all()
  return get().order
end

--- One quality by prototype name, or nil if it does not exist or is hidden.
function qualities.get(name)
  return name and get().by_name[name] or nil
end

--- The quality used before the player has chosen, and the one every ghost got
--- before this choice existed.
function qualities.default()
  return get().by_name[NORMAL] or get().order[1]
end

--- Whether there is a choice to offer at all. On a base-game-only install there
--- is not, and the tool must look and behave exactly as it did without quality.
function qualities.selectable()
  return #get().order > 1
end

--- Invalidate the cache. Nothing reloads prototypes mid-session today; kept for
--- the same reason belts.invalidate is.
function qualities.invalidate()
  cache = nil
end

return qualities
