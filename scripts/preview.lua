-- Everything the player sees that is not an entity.
--
-- The preview is drawn from the SAME spec list that place.lua commits, so what
-- is on screen is what will be built - including where the tunnels go and which
-- tiles get landfill.
--
-- Render objects are stored per player and destroyed explicitly: a
-- position-targeted render outlives whatever created it, so a session that ends
-- without clearing would leave marks on the map forever.

local geometry = require("scripts/geometry")

local preview = {}

local ANCHOR_COLOUR = { 0.35, 0.9, 0.45, 0.8 }
local BLOCKER_COLOUR = { 1, 0.25, 0.2, 0.9 }

local BELT_TINT = { 1, 1, 1, 0.55 }
local UNDERGROUND_TINT = { 0.55, 1, 0.7, 0.9 }
local LANDFILL_TINT = { 0.9, 0.85, 0.6, 0.45 }
local ARROW_TINT = { 0.4, 1, 0.5, 0.75 }
local REMOVE_TINT = { 1, 0.55, 0.2, 0.9 }

-- A drag can be flung right across the map, so past this many tiles the
-- per-tile squares give way to a single outline.
local DRAG_SQUARE_LIMIT = 400

-- Past this many pieces the per-tile sprites are replaced by a line per lane.
-- Every sprite is destroyed and recreated whenever the cursor crosses a tile, so
-- an unbounded count would turn mouse movement into a stutter.
local SPRITE_LIMIT = 300
local ARROW_EVERY = 3

local function store(pdata, object)
  pdata.renders = pdata.renders or {}
  pdata.renders[#pdata.renders + 1] = object
  return object
end

function preview.clear(pdata)
  if not pdata.renders then return end
  for _, object in pairs(pdata.renders) do
    if object.valid then object.destroy() end
  end
  pdata.renders = nil
  pdata.preview_tile = nil
end

--- 2.0 directions are 16-way and a RealOrientation is 0..1.
local function orientation_of(direction)
  return (direction or 0) / 16
end

--------------------------------------------------------------------------------
-- pieces

local function draw_anchor(player, pdata, anchor)
  for lane = 1, anchor.lanes do
    local tile = geometry.lane_start(anchor, lane)
    store(pdata, rendering.draw_rectangle {
      color = ANCHOR_COLOUR,
      width = 2,
      filled = false,
      left_top = { tile.x + 0.1, tile.y + 0.1 },
      right_bottom = { tile.x + 0.9, tile.y + 0.9 },
      surface = player.surface,
      players = { player },
    })
  end
end

local function draw_specs(player, pdata, specs)
  local surface = player.surface
  local belt_index = 0

  for _, spec in ipairs(specs) do
    if spec.kind == "deconstruct" then
      store(pdata, rendering.draw_sprite {
        sprite = "utility/cross_select",
        target = spec.position,
        x_scale = 0.55, y_scale = 0.55,
        tint = REMOVE_TINT,
        surface = surface,
        players = { player },
      })
    elseif spec.kind == "landfill" then
      store(pdata, rendering.draw_sprite {
        sprite = "item/landfill",
        target = spec.position,
        x_scale = 0.5, y_scale = 0.5,
        tint = LANDFILL_TINT,
        surface = surface,
        players = { player },
      })
    else
      local underground = spec.kind == "underground"
      store(pdata, rendering.draw_sprite {
        sprite = "item/" .. spec.name,
        target = spec.position,
        x_scale = underground and 0.62 or 0.5,
        y_scale = underground and 0.62 or 0.5,
        tint = underground and UNDERGROUND_TINT or BELT_TINT,
        surface = surface,
        players = { player },
      })

      -- Item icons carry no facing, so direction is shown by a separate arrow
      -- rather than by rotating the icon, which would just look broken.
      belt_index = belt_index + 1
      if underground or belt_index % ARROW_EVERY == 1 then
        store(pdata, rendering.draw_sprite {
          sprite = "utility/indication_arrow",
          target = spec.position,
          orientation = orientation_of(spec.direction),
          x_scale = 0.5, y_scale = 0.5,
          tint = ARROW_TINT,
          surface = surface,
          players = { player },
        })
      end
    end
  end
end

--- Cheap stand-in for a run too long to draw tile by tile.
local function draw_summary(player, pdata, anchor, resolved, specs)
  local surface = player.surface

  -- One line per straight run, so a corner shows as two lines meeting rather
  -- than one line cutting the bend.
  for lane = 1, anchor.lanes do
    for _, run in ipairs(geometry.lane_runs(anchor, resolved, lane)) do
      local first, last = run.tiles[1], run.tiles[#run.tiles]
      if first and last then
        store(pdata, rendering.draw_line {
          color = ARROW_TINT,
          width = 3,
          from = { first.x + 0.5, first.y + 0.5 },
          to = { last.x + 0.5, last.y + 0.5 },
          surface = surface,
          players = { player },
        })
      end
    end
  end

  -- Tunnels and landfill still matter at this scale, so they stay visible.
  for _, spec in ipairs(specs) do
    if spec.kind ~= "belt" then
      store(pdata, rendering.draw_sprite {
        sprite = "item/" .. spec.name,
        target = spec.position,
        x_scale = 0.55, y_scale = 0.55,
        tint = spec.kind == "underground" and UNDERGROUND_TINT or LANDFILL_TINT,
        surface = surface,
        players = { player },
      })
    end
  end
end

--------------------------------------------------------------------------------
-- public

--- Redraw everything for this player. `result` may be nil, which draws the
--- anchor alone - the state between setting an anchor and knowing where the
--- cursor is.
function preview.render(player, pdata, anchor, resolved, result, blockers)
  preview.clear(pdata)
  if not anchor then return end

  draw_anchor(player, pdata, anchor)

  -- Blockers are drawn even when the plan failed: seeing exactly which tile is
  -- in the way, live, is more useful than a message saying something was.
  for _, tile in ipairs(blockers or {}) do
    store(pdata, rendering.draw_rectangle {
      color = BLOCKER_COLOUR,
      width = 3,
      filled = false,
      left_top = { tile.x, tile.y },
      right_bottom = { tile.x + 1, tile.y + 1 },
      surface = player.surface,
      players = { player },
    })
  end

  if not (result and resolved) then return end

  if #result.specs <= SPRITE_LIMIT then
    draw_specs(player, pdata, result.specs)
  else
    draw_summary(player, pdata, anchor, resolved, result.specs)
  end

  local head = geometry.lane_start(anchor, 1)
  store(pdata, rendering.draw_text {
    text = { "beltplanner.preview-label", anchor.lanes, result.cost,
      anchor.reversed and { "beltplanner.reversed-suffix" } or "" },
    target = { head.x + 0.5, head.y - 1.1 },
    color = ANCHOR_COLOUR,
    scale = 0.6,
    alignment = "center",
    surface = player.surface,
    players = { player },
  })
end

--- Live feedback for the opening drag.
---
--- Factorio raises no event at all while a selection is being dragged, so
--- neither corner is knowable from the selection itself: the start comes from
--- the mouse-down custom input and the moving corner from the cursor tracker.
--- Colour says whether the shape is a legal anchor before the button is let go.
function preview.show_drag(player, pdata, from, to)
  preview.clear(pdata)

  local x1, x2 = math.min(from.x, to.x), math.max(from.x, to.x)
  local y1, y2 = math.min(from.y, to.y), math.max(from.y, to.y)
  local width, height = x2 - x1 + 1, y2 - y1 + 1

  local legal = (width == 1 or height == 1)
  local colour = legal and ANCHOR_COLOUR or BLOCKER_COLOUR
  local surface = player.surface

  if width * height <= DRAG_SQUARE_LIMIT then
    for x = x1, x2 do
      for y = y1, y2 do
        store(pdata, rendering.draw_rectangle {
          color = colour,
          width = 2,
          filled = false,
          left_top = { x + 0.1, y + 0.1 },
          right_bottom = { x + 0.9, y + 0.9 },
          surface = surface,
          players = { player },
        })
      end
    end
  else
    store(pdata, rendering.draw_rectangle {
      color = colour,
      width = 3,
      filled = false,
      left_top = { x1, y1 },
      right_bottom = { x2 + 1, y2 + 1 },
      surface = surface,
      players = { player },
    })
  end

  store(pdata, rendering.draw_text {
    text = legal and { "beltplanner.drag-label", math.max(width, height) }
      or { "beltplanner.error-not-a-line", width, height },
    target = { (x1 + x2 + 1) / 2, y1 - 1.1 },
    color = colour,
    scale = 0.6,
    alignment = "center",
    surface = surface,
    players = { player },
  })
end

--- Paint the tiles that stopped a run. These expire on their own rather than
--- joining pdata.renders, so a refusal never has to be cleaned up.
function preview.flash_blockers(player, blockers)
  for _, tile in ipairs(blockers or {}) do
    rendering.draw_rectangle {
      color = BLOCKER_COLOUR,
      width = 3,
      filled = false,
      left_top = { tile.x, tile.y },
      right_bottom = { tile.x + 1, tile.y + 1 },
      surface = player.surface,
      players = { player },
      time_to_live = 90,
    }
  end
end

function preview.say(player, message)
  player.create_local_flying_text { text = message, create_at_cursor = true }
  player.play_sound { path = "utility/cannot_build" }
end

return preview
