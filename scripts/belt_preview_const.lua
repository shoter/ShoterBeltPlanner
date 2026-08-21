-- Shared by the data stage and the control stage. Both have to agree on the
-- animation names and on where the coverage list is published, and a mismatch
-- would be silent: the preview would simply fall back to icons forever.

local const = {}

const.PREFIX = "beltplanner-preview-"
const.MOD_DATA = "beltplanner-belt-previews"

function const.animation_name(belt_name, direction_name)
  return const.PREFIX .. belt_name .. "-" .. direction_name
end

return const
