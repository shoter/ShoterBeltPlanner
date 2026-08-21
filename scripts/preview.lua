-- Everything the player sees that is not an entity.
--
-- The preview is drawn from the SAME spec list that place.lua commits, so what
-- is on screen is what will be built - including what will be cleared out of the
-- way and which tiles get landfill.
--
-- Render objects are stored per player and destroyed explicitly: a
-- position-targeted render outlives whatever created it, so a session that ends
-- without clearing would leave marks on the map forever.

local geometry = require("scripts/geometry")
local belts = require("scripts/belts")

local preview = {}

local ANCHOR_COLOUR = { 0.35, 0.9, 0.45, 0.8 }
local BLOCKER_COLOUR = { 1, 0.25, 0.2, 0.9 }

-- The wash the copy tool leaves on the ground: low alpha, and drawn beneath
-- entities so it reads as marked ground rather than as something floating over
-- the base.
local ANCHOR_FILL = { 0.35, 0.9, 0.45, 0.16 }
local BLOCKER_FILL = { 1, 0.25, 0.2, 0.16 }

local BELT_TINT = { 1, 1, 1, 0.55 }
local UNDERGROUND_TINT = { 0.55, 1, 0.7, 0.9 }
local LANDFILL_TINT = { 0.9, 0.85, 0.6, 0.45 }
local ARROW_TINT = { 0.4, 1, 0.5, 0.75 }
local REMOVE_TINT = { 1, 0.55, 0.2, 0.9 }
local SPLITTER_TINT = { 0.6, 0.8, 1, 0.95 }

-- Past this many pieces the per-tile sprites are replaced by a line per lane.
-- Every sprite is destroyed and recreated whenever the cursor crosses a tile, so
-- an unbounded count would turn mouse movement into a stutter.
local SPRITE_LIMIT = 300
local ARROW_EVERY = 3

-- The same ceiling, for the same reason, on the tiles a refusal marks. A run
-- refused across a built base names every offending tile on every lane, and each
-- one was a render object rebuilt every time the pointer crossed a tile - the
-- exact cliff SPRITE_LIMIT exists to prevent, on the path most likely to reach
-- it. Past a few hundred the outlines have merged into a red wash anyway.
local BLOCKER_LIMIT = 200

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

--- An area marked the way Factorio marks a copy selection: a tinted wash on the
--- ground with a crisp border over it. An outline on its own is easy to miss
--- against a busy base, which is the whole reason the vanilla tools fill.
local function draw_marked_area(player, pdata, left_top, right_bottom, border, fill)
  local surface = player.surface

  store(pdata, rendering.draw_rectangle {
    color = fill,
    filled = true,
    draw_on_ground = true,
    left_top = left_top,
    right_bottom = right_bottom,
    surface = surface,
    players = { player },
  })

  store(pdata, rendering.draw_rectangle {
    color = border,
    width = 3,
    filled = false,
    left_top = left_top,
    right_bottom = right_bottom,
    surface = surface,
    players = { player },
  })
end

--- Mark the tiles that stopped a run.
---
--- `pdata` may be nil, which draws objects nobody has to clean up afterwards;
--- `ttl` then decides how long they last. What the cap leaves out is counted
--- rather than dropped quietly, because an unlabelled wash of red reads as "all
--- of this is blocked", which is a different and larger claim than "200 of 1400
--- tiles are marked".
local function draw_blockers(player, pdata, blockers, ttl)
  local total = blockers and #blockers or 0
  if total == 0 then return end

  local shown = math.min(total, BLOCKER_LIMIT)
  local surface = player.surface

  for index = 1, shown do
    local tile = blockers[index]
    local object = rendering.draw_rectangle {
      color = BLOCKER_COLOUR,
      width = 3,
      filled = false,
      left_top = { tile.x, tile.y },
      right_bottom = { tile.x + 1, tile.y + 1 },
      surface = surface,
      players = { player },
      time_to_live = ttl,
    }
    if pdata then store(pdata, object) end
  end

  if total > shown then
    local last = blockers[shown]
    local object = rendering.draw_text {
      text = { "beltplanner.blockers-hidden", total - shown, total },
      target = { last.x + 0.5, last.y + 1.3 },
      color = BLOCKER_COLOUR,
      scale = 0.7,
      alignment = "center",
      surface = surface,
      players = { player },
      time_to_live = ttl,
    }
    if pdata then store(pdata, object) end
  end
end

--- 2.0 directions are 16-way and a RealOrientation is 0..1.
local function orientation_of(direction)
  return (direction or 0) / 16
end

--------------------------------------------------------------------------------
-- pieces

--- One marked area over the whole anchor band rather than a square per lane: a
--- row of small boxes next to the cursor's own selection box is just noise.
local function draw_anchor(player, pdata, anchor)
  local first = geometry.lane_start(anchor, 1)
  local last = geometry.lane_start(anchor, anchor.lanes)

  draw_marked_area(player, pdata,
    { math.min(first.x, last.x), math.min(first.y, last.y) },
    { math.max(first.x, last.x) + 1, math.max(first.y, last.y) + 1 },
    ANCHOR_COLOUR, ANCHOR_FILL)
end

--- Sprite and tint for anything that is not a plain belt.
---
--- Shared by both the detailed and the summarised preview, so a spec kind can no
--- longer be handled in one and forgotten in the other. That is exactly how a
--- deconstruct spec - which carries a LuaEntity rather than a prototype name -
--- reached an "item/" .. spec.name and crashed the summarised path.
local function marker_for(spec)
  local kind = spec.kind
  if kind == "deconstruct" then
    return "utility/cross_select", REMOVE_TINT, 0.55
  elseif kind == "landfill" then
    return "item/landfill", LANDFILL_TINT, 0.5
  elseif kind == "underground" then
    return "item/" .. spec.name, UNDERGROUND_TINT, 0.62
  elseif kind == "splitter" then
    return "item/" .. spec.name, SPLITTER_TINT, 0.75
  end
  return nil
end

local function draw_specs(player, pdata, specs)
  local surface = player.surface
  local belt_index = 0

  for _, spec in ipairs(specs) do
    local sprite, tint, scale = marker_for(spec)

    if sprite then
      store(pdata, rendering.draw_sprite {
        sprite = sprite,
        target = spec.position,
        x_scale = scale, y_scale = scale,
        tint = tint,
        surface = surface,
        players = { player },
      })
    else
      -- The belt's own graphics, which sit in the tile the way a built belt
      -- does. An item icon is a small picture OF a belt and never looked like
      -- one lying on the ground. Belts whose sheet could not be sliced fall
      -- back to the icon.
      local animation = belts.preview_animation(spec.name, spec.direction)

      if animation then
        store(pdata, rendering.draw_animation {
          animation = animation,
          target = spec.position,
          tint = BELT_TINT,
          surface = surface,
          players = { player },
        })
      else
        store(pdata, rendering.draw_sprite {
          sprite = "item/" .. spec.name,
          target = spec.position,
          x_scale = 0.5, y_scale = 0.5,
          tint = BELT_TINT,
          surface = surface,
          players = { player },
        })
      end

      belt_index = belt_index + 1
    end

    -- Item icons carry no facing, so direction is shown by a separate arrow
    -- rather than by rotating the icon, which would just look broken.
    if spec.direction and (spec.kind == "underground" or belt_index % ARROW_EVERY == 1) then
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

  -- Tunnels, landfill and anything to be removed still matter at this scale, so
  -- they stay visible even when the belts are reduced to lines.
  for _, spec in ipairs(specs) do
    local sprite, tint, scale = marker_for(spec)
    if sprite then
      store(pdata, rendering.draw_sprite {
        sprite = sprite,
        target = spec.position,
        x_scale = scale, y_scale = scale,
        tint = tint,
        surface = surface,
        players = { player },
      })
    end
  end
end

--------------------------------------------------------------------------------
-- public

--- The label over the anchor: what the run is, and under it what the click
--- will cost.
---
--- Two render objects rather than one text with a newline in it, because
--- whether draw_text breaks lines is not something the API promises, and a
--- label that might come out as one long line is not worth finding out about in
--- someone's save. The cost line sits nearest the anchor; it is the one that
--- changes as the pointer moves.
local function draw_label(player, pdata, anchor, summary)
  local head = geometry.lane_start(anchor, 1)
  local surface = player.surface

  store(pdata, rendering.draw_text {
    text = summary.run,
    target = { head.x + 0.5, head.y - (summary.cost and 1.65 or 1.1) },
    color = ANCHOR_COLOUR,
    scale = 0.6,
    alignment = "center",
    surface = surface,
    players = { player },
  })

  if summary.cost then
    store(pdata, rendering.draw_text {
      text = summary.cost,
      target = { head.x + 0.5, head.y - 1.1 },
      color = ANCHOR_COLOUR,
      scale = 0.6,
      alignment = "center",
      surface = surface,
      players = { player },
    })
  end
end

--- Redraw everything for this player. `result` may be nil, which draws the
--- anchor alone - the state between setting an anchor and knowing where the
--- cursor is. `summary` is tally.summary's reading of that result; it is made
--- by the caller so that the window can be told the very same thing.
function preview.render(player, pdata, anchor, resolved, result, blockers, summary)
  preview.clear(pdata)
  if not anchor then return end

  draw_anchor(player, pdata, anchor)

  -- Blockers are drawn even when the plan failed: seeing exactly which tile is
  -- in the way, live, is more useful than a message saying something was.
  draw_blockers(player, pdata, blockers)

  if not (result and resolved) then return end

  if #result.specs <= SPRITE_LIMIT then
    draw_specs(player, pdata, result.specs)
  else
    draw_summary(player, pdata, anchor, resolved, result.specs)
  end

  if summary then
    draw_label(player, pdata, anchor, summary)
  end
end

--- The anchor being sized: the marked area the next click will accept.
---
--- This is the live version of what a drag could never show, because the engine
--- stops updating the selection the moment a mouse button is held. With two
--- clicks no button is down while the pointer moves, so this follows properly.
function preview.show_candidate(player, pdata, anchor)
  preview.clear(pdata)
  draw_anchor(player, pdata, anchor)

  local head = geometry.lane_start(anchor, 1)
  store(pdata, rendering.draw_text {
    text = { "beltplanner.drag-label", anchor.lanes },
    target = { head.x + 0.5, head.y - 1.1 },
    color = ANCHOR_COLOUR,
    scale = 0.7,
    alignment = "center",
    surface = player.surface,
    players = { player },
  })
end

--- Say, at the cursor, why nothing can be drawn.
---
--- Without this a refused plan looks exactly like a broken tool: the belts
--- simply stop appearing and nothing explains it. Appends to the current render
--- set, so it is cleared with everything else on the next refresh.
function preview.show_problem(player, pdata, tile, message)
  if not (tile and message) then return end

  store(pdata, rendering.draw_text {
    text = message,
    target = { tile.x + 0.5, tile.y - 0.8 },
    color = BLOCKER_COLOUR,
    scale = 0.7,
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
  local fill = legal and ANCHOR_FILL or BLOCKER_FILL
  local surface = player.surface

  -- One marked area for the whole selection, whatever its size, so the shape
  -- being dragged is obvious before the button is let go.
  draw_marked_area(player, pdata, { x1, y1 }, { x2 + 1, y2 + 1 }, colour, fill)

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
  draw_blockers(player, nil, blockers, 90)
end

function preview.say(player, message)
  player.create_local_flying_text { text = message, create_at_cursor = true }
  player.play_sound { path = "utility/cannot_build" }
end

return preview
