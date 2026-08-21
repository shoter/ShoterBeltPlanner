-- Preview graphics for the belts themselves.
--
-- The preview drew item icons, which are small perspective pictures of a belt
-- rather than a belt, and do not sit in a tile the way the real thing does. The
-- entity's own graphics do, because they are exactly what the game draws for a
-- built belt.
--
-- A belt's graphics live in belt_animation_set.animation_set: a RotatedAnimation
-- whose sheet is laid out one direction per row and one frame per column.
-- Measured against the vanilla sheets rather than assumed --
-- transport-belt.png is 2048x2560 for size 128, frame_count 16,
-- direction_count 20, so width = frame_count * size and
-- height = direction_count * size exactly, and row N begins at y = (N-1) * size.
-- Slicing a single row out of that yields a plain Animation facing one way,
-- which is what rendering.draw_animation takes.
--
-- Declared in data-final-fixes so every mod's belts are present, and so nothing
-- else rewrites the sheets underneath afterwards.

local const = require("scripts/belt_preview_const")

-- Engine defaults for TransportBeltAnimationSet. Vanilla ships them commented
-- out, so relying on the defaults is relying on the documented values.
local DIRECTIONS = {
  { name = "east", field = "east_index", default = 1 },
  { name = "west", field = "west_index", default = 2 },
  { name = "north", field = "north_index", default = 3 },
  { name = "south", field = "south_index", default = 4 },
}

--- A frame's dimensions. `size` may be a number or a {width, height} pair, and
--- explicit width/height win over it.
local function frame_size(set)
  local width, height = set.width, set.height

  if not (width and height) then
    local size = set.size
    if type(size) == "table" then
      width = width or size[1]
      height = height or size[2]
    elseif size then
      width = width or size
      height = height or size
    end
  end

  return width, height
end

--- Only a plain single-sheet animation can be sliced by row. Layers, stripes and
--- filename lists all mean the row arithmetic above does not describe the file,
--- so those belts are skipped and fall back to their item icon at runtime.
local function sliceable(set)
  if type(set) ~= "table" then return false end
  if set.layers or set.stripes or set.filenames then return false end
  if not set.filename then return false end

  local width, height = frame_size(set)
  return width ~= nil and height ~= nil and set.frame_count ~= nil
end

local previews = {}
local covered = {}

for belt_name, belt in pairs(data.raw["transport-belt"] or {}) do
  local animation_set = belt.belt_animation_set
  local sheet = animation_set and animation_set.animation_set

  if sliceable(sheet) then
    local width, height = frame_size(sheet)

    for _, direction in ipairs(DIRECTIONS) do
      local index = animation_set[direction.field] or direction.default

      previews[#previews + 1] = {
        type = "animation",
        name = const.animation_name(belt_name, direction.name),

        filename = sheet.filename,
        priority = sheet.priority,
        flags = sheet.flags,
        width = width,
        height = height,
        x = 0,
        y = (index - 1) * height,
        frame_count = sheet.frame_count,
        -- One row holds the whole cycle for this direction.
        line_length = sheet.frame_count,
        scale = sheet.scale,
        shift = sheet.shift,

        -- A preview does not have to run at the belt's real rate, and a slower
        -- cycle reads more clearly than a blur.
        animation_speed = 0.4,
      }
    end

    covered[belt_name] = true
  end
end

-- The control stage cannot see belt_animation_set, so which belts ended up with
-- a preview has to be handed across. mod-data is the channel meant for exactly
-- this, and prototypes.mod_data reads it back at runtime.
previews[#previews + 1] = {
  type = "mod-data",
  name = const.MOD_DATA,
  data = covered,
}

data:extend(previews)
