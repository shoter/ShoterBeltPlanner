-- THROWAWAY. Exercises the planner against a real surface headlessly, so the
-- geometry and tunnelling rules are checked by the engine rather than by eye.
-- Run via `factorio --create`, read the log, then delete this file.

local geometry = require("scripts/geometry")
local plan = require("scripts/logic/plan")
local place = require("scripts/logic/place")
local belts = require("scripts/belts")
local cursor_const = require("scripts/cursor/const")

local selftest = {}

local passed, failed = 0, 0

local function line(fmt, ...)
  log("[BP-SELFTEST] " .. string.format(fmt, ...))
end

local function check(label, condition, detail)
  if condition then
    passed = passed + 1
    line("  PASS  %s", label)
  else
    failed = failed + 1
    line("  FAIL  %s  %s", label, detail or "")
  end
end

local function count_kinds(specs)
  local tally = {}
  for _, spec in ipairs(specs) do
    tally[spec.kind] = (tally[spec.kind] or 0) + 1
  end
  return tally
end

local function area(x1, y1, x2, y2)
  return { left_top = { x = x1, y = y1 }, right_bottom = { x = x2, y = y2 } }
end

--- `--create` rolls a fresh map seed every run, so the test area has to be
--- flattened or the results depend on where the trees landed.
local function clear_area(surface, x1, y1, x2, y2)
  local box = { { x1, y1 }, { x2, y2 } }

  for _, entity in pairs(surface.find_entities_filtered { area = box }) do
    if entity.valid and entity.type ~= "character" then
      entity.destroy { do_cliff_correction = false }
    end
  end
  surface.destroy_decoratives { area = box }

  local ground = prototypes.tile["grass-1"] and "grass-1" or "landfill"
  local tiles = {}
  for x = math.floor(x1), math.floor(x2) do
    for y = math.floor(y1), math.floor(y2) do
      tiles[#tiles + 1] = { name = ground, position = { x, y } }
    end
  end
  surface.set_tiles(tiles)
end

function selftest.run()
  local bend -- shared between the corner and splitter sections
  local surface = game.surfaces[1]
  local force = "player"
  local BX, BY = 2000, 2000

  surface.request_to_generate_chunks({ x = BX, y = BY }, 3)
  surface.force_generate_chunk_requests()
  clear_area(surface, BX - 20, BY - 20, BX + 40, BY + 40)

  local tier = belts.default()
  line("=== planner self-test (tier %s, max_distance %s) ===", tier.belt, tostring(tier.max_distance))

  local options = { tier = tier, tunnels = true, landfill = false, max_tiles = 10000 }

  ----------------------------------------------------------------------------
  line("--- geometry ---")

  local anchor, reason = geometry.anchor_from_area(area(BX, BY, BX + 1, BY + 3))
  check("1x3 drag is a valid anchor", anchor ~= nil, serpent and "" or tostring(reason))
  if not anchor then return end
  check("axis is x", anchor.axis == "x", "got " .. tostring(anchor.axis))
  check("lanes is 3", anchor.lanes == 3, "got " .. tostring(anchor.lanes))

  local bad = geometry.anchor_from_area(area(BX, BY, BX + 3, BY + 3))
  check("3x3 drag is refused", bad == nil)

  local single = geometry.anchor_from_area(area(BX, BY, BX, BY))
  check("click gives a 1x1 anchor with no axis", single ~= nil and single.axis == nil and single.lanes == 1)

  local resolved = geometry.resolve(anchor, { x = BX + 9, y = BY })
  check("resolve sign is +1", resolved and resolved.along_sign == 1)
  check("resolve length is 10", resolved and resolved.length == 10, "got " .. tostring(resolved and resolved.length))
  check("cost is 30", geometry.cost(anchor, resolved) == 30)

  local back = geometry.resolve(anchor, { x = BX - 4, y = BY })
  check("backwards resolve sign is -1", back and back.along_sign == -1)
  check("backwards length is 5", back and back.length == 5)

  check("zero length is refused", geometry.resolve(anchor, { x = BX, y = BY }) == nil)

  ----------------------------------------------------------------------------
  line("--- cursor tracker geometry ---")

  -- The probe block follows the pointer and is re-centred before the pointer can
  -- reach its edge. If the trigger distance ever creeps out to the edge itself
  -- there is a gap with nothing tracked; if it reaches zero the block re-seeds on
  -- every movement. Both are silent, so the margin is pinned here.
  local root = cursor_const.root
  local half_span = (cursor_const.ROOT_SPAN / 2) * root.size
  local margin = half_span - cursor_const.RECENTRE_DISTANCE

  check("re-centring happens before the pointer reaches the edge",
    cursor_const.RECENTRE_DISTANCE > 0 and margin >= root.size,
    string.format("half-span %.0f, re-centre at %.0f, margin %.0f, root %.0f",
      half_span, cursor_const.RECENTRE_DISTANCE, margin, root.size))
  check("the tracked block is wider than a zoomed-out screen",
    half_span * 2 >= 200, string.format("%.0f tiles across", half_span * 2))

  ----------------------------------------------------------------------------
  line("--- clear ground ---")

  local result, failure = plan.build(surface, force, anchor, resolved, options)
  check("plan succeeds on clear ground", result ~= nil, tostring(failure and failure[1]))
  if result then
    local tally = count_kinds(result.specs)
    check("30 belts, no undergrounds", tally.belt == 30 and tally.underground == nil,
      string.format("belts=%s undergrounds=%s", tostring(tally.belt), tostring(tally.underground)))
    check("no blockers", #result.blockers == 0)
    local first = result.specs[1]
    check("belts face east", first.direction == defines.direction.east, "got " .. tostring(first.direction))
    check("first belt centred on tile", first.position.x == BX + 0.5 and first.position.y == BY + 0.5,
      string.format("got %s,%s", first.position.x, first.position.y))
  end

  ----------------------------------------------------------------------------
  line("--- reversed (build from destination back to source) ---")

  anchor.reversed = true
  local reversed_result = plan.build(surface, force, anchor, resolved, options)
  if reversed_result then
    check("reversed belts face west", reversed_result.specs[1].direction == defines.direction.west,
      "got " .. tostring(reversed_result.specs[1].direction))
  else
    check("reversed plan succeeds", false)
  end
  anchor.reversed = false

  ----------------------------------------------------------------------------
  line("--- one obstacle: tunnel spans exactly it ---")

  local obstacles = {}
  for lane = 0, 2 do
    obstacles[#obstacles + 1] = surface.create_entity {
      name = "steel-chest", position = { BX + 4.5, BY + lane + 0.5 }, force = force,
    }
  end

  result, failure = plan.build(surface, force, anchor, resolved, options)
  check("plan succeeds over a 1-tile obstacle", result ~= nil, tostring(failure and failure[1]))
  if result then
    local tally = count_kinds(result.specs)
    check("6 underground ends (2 per lane)", tally.underground == 6, "got " .. tostring(tally.underground))
    -- 30 tiles, 3 blocked, so 27 buildable; 6 of those become underground ends.
    check("21 plain belts", tally.belt == 21, "got " .. tostring(tally.belt))

    local ends = {}
    for _, spec in ipairs(result.specs) do
      if spec.kind == "underground" then ends[#ends + 1] = spec end
    end
    check("entry is input, exit is output",
      ends[1].type == "input" and ends[2].type == "output",
      string.format("got %s,%s", tostring(ends[1].type), tostring(ends[2].type)))
    check("entry sits just before the obstacle", ends[1].position.x == BX + 3.5,
      "got " .. tostring(ends[1].position.x))
    check("exit sits just after the obstacle", ends[2].position.x == BX + 5.5,
      "got " .. tostring(ends[2].position.x))
  end

  line("--- reversed over an obstacle puts the entrance on the far side ---")
  anchor.reversed = true
  local rev = plan.build(surface, force, anchor, resolved, options)
  if rev then
    local ends = {}
    for _, spec in ipairs(rev.specs) do
      if spec.kind == "underground" then ends[#ends + 1] = spec end
    end
    -- Tiles are walked in FLOW order, so the first end met is always the
    -- entrance whichever way the run was drawn. Flowing west, that is the tile
    -- east of the obstacle.
    check("reversed: first end is still the entrance", ends[1].type == "input",
      "got " .. tostring(ends[1].type))
    check("reversed: entrance is east of the obstacle", ends[1].position.x == BX + 5.5,
      "got " .. tostring(ends[1].position.x))
    check("reversed: exit is west of the obstacle", ends[2].position.x == BX + 3.5,
      "got " .. tostring(ends[2].position.x))
  else
    check("reversed obstacle plan succeeds", false)
  end
  anchor.reversed = false

  line("--- tunnelling disabled refuses instead of guessing ---")
  local no_tunnel = { tier = tier, tunnels = false, landfill = false, max_tiles = 10000 }
  local blocked_result, blocked_reason, blocked_tiles = plan.build(surface, force, anchor, resolved, no_tunnel)
  check("refused when tunnels are off", blocked_result == nil)
  check("refusal names the blocked tiles", blocked_tiles ~= nil and #blocked_tiles > 0)
  check("refusal reason is error-blocked",
    blocked_reason and blocked_reason[1] == "beltplanner.error-blocked",
    tostring(blocked_reason and blocked_reason[1]))

  for _, chest in ipairs(obstacles) do if chest.valid then chest.destroy() end end

  ----------------------------------------------------------------------------
  line("--- obstacle too long to bridge ---")

  local wall = {}
  for step = 0, 5 do
    wall[#wall + 1] = surface.create_entity {
      name = "steel-chest", position = { BX + 3.5 + step, BY + 0.5 }, force = force,
    }
  end

  local long_result, long_reason = plan.build(surface, force, anchor, resolved, options)
  check("refused when the obstacle outreaches the belt", long_result == nil)
  check("refusal reason is error-tunnel-too-long",
    long_reason and long_reason[1] == "beltplanner.error-tunnel-too-long",
    tostring(long_reason and long_reason[1]))

  for _, chest in ipairs(wall) do if chest.valid then chest.destroy() end end

  ----------------------------------------------------------------------------
  line("--- trees are cleared, not refused ---")

  local tree_name
  for name in pairs(prototypes.get_entity_filtered { { filter = "type", type = "tree" } }) do
    tree_name = tree_name or name
  end

  if tree_name then
    local tree = surface.create_entity { name = tree_name, position = { BX + 4.5, BY + 0.5 } }
    check("test tree placed", tree ~= nil, tree_name)

    local tree_result, tree_reason = plan.build(surface, force, anchor, resolved, options)
    check("plan succeeds through a tree", tree_result ~= nil, tostring(tree_reason and tree_reason[1]))

    if tree_result then
      local tally = count_kinds(tree_result.specs)
      check("tree is marked for removal", (tally.deconstruct or 0) == 1,
        "got " .. tostring(tally.deconstruct))
      check("no tunnel dug for a tree", tally.underground == nil,
        "got " .. tostring(tally.underground))
      check("all 30 tiles still get belt", tally.belt == 30, "got " .. tostring(tally.belt))

      -- The preview indexes spec.name for everything except a deconstruct,
      -- which carries a LuaEntity instead. Assuming otherwise crashed the
      -- summarised preview, so the shape is pinned here.
      local shape_ok, detail = true, ""
      for _, spec in ipairs(tree_result.specs) do
        if not spec.position then
          shape_ok, detail = false, spec.kind .. " has no position"
        elseif spec.kind == "deconstruct" then
          if spec.entity == nil then shape_ok, detail = false, "deconstruct has no entity" end
        elseif spec.name == nil then
          shape_ok, detail = false, spec.kind .. " has no name"
        end
      end
      check("every spec has the shape the preview expects", shape_ok, detail)
    end
    if tree and tree.valid then tree.destroy() end
  else
    line("  SKIP  no tree prototype available")
  end

  ----------------------------------------------------------------------------
  line("--- player entities need Ctrl ---")

  local chest = surface.create_entity { name = "steel-chest", position = { BX + 4.5, BY + 0.5 }, force = force }

  local guarded = plan.build(surface, force, anchor, resolved,
    { tier = tier, tunnels = false, landfill = false, max_tiles = 10000 })
  check("without Ctrl a chest is not cleared", guarded == nil)

  local ctrl_options = { tier = tier, tunnels = false, landfill = false, max_tiles = 10000, clear_built = true }
  local cleared, cleared_reason = plan.build(surface, force, anchor, resolved, ctrl_options)
  check("with Ctrl the chest is cleared", cleared ~= nil, tostring(cleared_reason and cleared_reason[1]))
  if cleared then
    local tally = count_kinds(cleared.specs)
    check("chest is marked for removal", (tally.deconstruct or 0) == 1,
      "got " .. tostring(tally.deconstruct))
  end

  if chest and chest.valid then chest.destroy() end

  ----------------------------------------------------------------------------
  line("--- budget ---")

  local tiny = { tier = tier, tunnels = true, landfill = false, max_tiles = 5 }
  local over, over_reason = plan.build(surface, force, anchor, resolved, tiny)
  check("run over the budget is refused", over == nil)
  check("refusal reason is error-too-big",
    over_reason and over_reason[1] == "beltplanner.error-too-big",
    tostring(over_reason and over_reason[1]))

  ----------------------------------------------------------------------------
  line("--- replanning over a run already placed ---")

  -- Regression: the tracker blankets the area in probes, and surveying them as
  -- obstructions forced can_place_entity on every tile. That call refuses a tile
  -- that already holds a ghost, so a second run over the first came back wholly
  -- blocked and the planner tried to tunnel under its own belts.
  local probe_force = game.forces[cursor_const.FORCE_NAME]
    or game.create_force(cursor_const.FORCE_NAME)
  local probe = surface.create_entity {
    name = cursor_const.root.name,
    position = { BX + 5, BY + 1 },
    force = probe_force,
  }
  check("a root probe covers the whole run", probe ~= nil, cursor_const.root.name)

  local first_pass = plan.build(surface, force, anchor, resolved, options)
  check("first run plans with probes present", first_pass ~= nil)
  if first_pass then
    place.execute(surface, force, nil, first_pass.specs)

    local second_pass, second_reason = plan.build(surface, force, anchor, resolved, options)
    check("second run over the first is not blocked", second_pass ~= nil,
      tostring(second_reason and second_reason[1]))
    if second_pass then
      local tally = count_kinds(second_pass.specs)
      check("no tunnels invented over our own ghosts", tally.underground == nil,
        "got " .. tostring(tally.underground))
      check("second run still lays 30 belts", tally.belt == 30, "got " .. tostring(tally.belt))
    end

    for _, ghost in pairs(surface.find_entities_filtered {
      area = { { BX - 2, BY - 2 }, { BX + 14, BY + 6 } }, name = "entity-ghost",
    }) do
      ghost.destroy()
    end
  end
  if probe and probe.valid then probe.destroy() end

  ----------------------------------------------------------------------------
  line("--- corners ---")

  bend = geometry.resolve(anchor, { x = BX + 10, y = BY + 6 })
  check("off-axis target resolves to a curve", bend ~= nil and bend.curved == true)

  if bend then
    -- lanes 1..3 start at y = BY, BY+1, BY+2 and turn at x = BX+12, +11, +10:
    -- the outermost lane carries furthest so the bundle stays parallel.
    check("corner cost is 51", geometry.cost(anchor, bend) == 51,
      "got " .. tostring(geometry.cost(anchor, bend)))

    local corners = {}
    for lane = 1, 3 do
      local runs = geometry.lane_runs(anchor, bend, lane)
      if lane == 1 then
        check("a corner splits the lane into two runs", #runs == 2, "got " .. #runs)
        check("leg one heads east", runs[1].direction == defines.direction.east)
        check("leg two heads south", runs[2].direction == defines.direction.south)
        check("leg one is 12 tiles", #runs[1].tiles == 12, "got " .. #runs[1].tiles)
        check("leg two is 7 tiles incl. the corner", #runs[2].tiles == 7, "got " .. #runs[2].tiles)
      end
      corners[lane] = geometry.lane_runs(anchor, bend, lane)[2].tiles[1].x
    end

    table.sort(corners)
    check("lanes turn at three consecutive columns",
      corners[1] == BX + 10 and corners[2] == BX + 11 and corners[3] == BX + 12,
      table.concat(corners, ","))

    local after = geometry.next_anchor(anchor, bend)
    check("axis flips after a corner", after.axis == "y", "got " .. tostring(after.axis))
    check("width survives the corner", after.lanes == 3)
    check("next anchor sits on the destination row",
      after.tile.x == BX + 10 and after.tile.y == BY + 6,
      string.format("got %s,%s", after.tile.x, after.tile.y))

    local bend_result, bend_reason = plan.build(surface, force, anchor, bend, options)
    check("a corner plans on clear ground", bend_result ~= nil,
      tostring(bend_reason and bend_reason[1]))
    if bend_result then
      local tally = count_kinds(bend_result.specs)
      check("corner lays 51 belts", tally.belt == 51, "got " .. tostring(tally.belt))
      check("no tunnel dug on clear ground", tally.underground == nil)
    end

    anchor.reversed = true
    local back = geometry.lane_runs(anchor, bend, 1)
    check("reversed corner leads with the far leg", back[1].direction == defines.direction.north,
      "got " .. tostring(back[1].direction))
    check("reversed corner ends heading west", back[2].direction == defines.direction.west,
      "got " .. tostring(back[2].direction))
    anchor.reversed = false
  end

  line("--- corners that cannot be made ---")
  local shallow, shallow_reason = geometry.resolve(anchor, { x = BX + 10, y = BY + 2 })
  check("a turn too shallow for the width is refused", shallow == nil)
  check("refusal names the shallow turn",
    shallow_reason and shallow_reason[1] == "beltplanner.error-corner-too-shallow",
    tostring(shallow_reason and shallow_reason[1]))

  local behind, behind_reason = geometry.resolve(anchor, { x = BX - 1, y = BY + 6 })
  check("a corner behind the anchor is refused", behind == nil,
    tostring(behind and "resolved anyway"))
  check("refusal names the cramped corner",
    behind_reason and behind_reason[1] == "beltplanner.error-corner-too-close",
    tostring(behind_reason and behind_reason[1]))

  ----------------------------------------------------------------------------
  line("--- splitters ---")

  check("the default belt has a matching splitter", tier.splitter ~= nil,
    "tier " .. tier.belt)

  local split_options = {
    tier = tier, tunnels = true, landfill = false, max_tiles = 10000, splitters = true,
  }

  -- Splitters take a lane pair, so this needs an even bundle of its own.
  local pair = geometry.anchor_from_area(area(BX, BY + 20, BX + 1, BY + 22))
  check("2-lane anchor for the splitter tests", pair ~= nil and pair.lanes == 2,
    "got " .. tostring(pair and pair.lanes))

  if pair then
    local straight = geometry.resolve(pair, { x = BX + 9, y = BY + 20 })
    local split_result, split_reason = plan.build(surface, force, pair, straight, split_options)
    check("a run can end in splitters", split_result ~= nil,
      tostring(split_reason and split_reason[1]))

    if split_result then
      local tally = count_kinds(split_result.specs)
      check("one splitter for the pair", tally.splitter == 1, "got " .. tostring(tally.splitter))
      -- 2 lanes x 10 tiles, less the two end tiles the splitter takes over.
      check("18 belts lead up to it", tally.belt == 18, "got " .. tostring(tally.belt))

      local splitter
      for _, spec in ipairs(split_result.specs) do
        if spec.kind == "splitter" then splitter = spec end
      end
      -- Two tiles wide, so it sits on the boundary between the lanes.
      check("splitter straddles both lanes",
        splitter.position.x == BX + 9.5 and splitter.position.y == BY + 21,
        string.format("got %s,%s", splitter.position.x, splitter.position.y))
      check("splitter faces the flow", splitter.direction == defines.direction.east,
        "got " .. tostring(splitter.direction))
    end

    pair.reversed = true
    local back_split = plan.build(surface, force, pair, straight, split_options)
    if back_split then
      for _, spec in ipairs(back_split.specs) do
        if spec.kind == "splitter" then
          check("reversed splitter faces west", spec.direction == defines.direction.west,
            "got " .. tostring(spec.direction))
        end
      end
    else
      check("reversed run can end in splitters", false)
    end
    pair.reversed = false
  end

  local odd, odd_reason = plan.build(surface, force, anchor, resolved, split_options)
  check("an odd bundle is refused", odd == nil)
  check("refusal names the odd bundle",
    odd_reason and odd_reason[1] == "beltplanner.error-splitter-odd",
    tostring(odd_reason and odd_reason[1]))

  if bend then
    local curved_split, curved_reason = plan.build(surface, force, anchor, bend, split_options)
    check("splitters on a corner are refused", curved_split == nil)
    check("refusal names the corner",
      curved_reason and curved_reason[1] == "beltplanner.error-splitter-corner",
      tostring(curved_reason and curved_reason[1]))
  end

  ----------------------------------------------------------------------------
  line("--- chaining ---")

  local next_anchor = geometry.next_anchor(anchor, resolved)
  check("next anchor keeps the axis", next_anchor.axis == "x")
  check("next anchor keeps the width", next_anchor.lanes == 3)
  check("next anchor sits at the far end", next_anchor.tile.x == BX + 9,
    "got " .. tostring(next_anchor.tile.x))

  line("=== %d passed, %d failed ===", passed, failed)

  selftest.benchmark(surface, force, tier)
end

--- What a live preview actually costs.
---
--- The preview re-plans every time the pointer crosses a tile, and each plan
--- surveys the whole run box. Whether that matters has been guesswork so far, so
--- it is measured instead.
function selftest.benchmark(surface, force, tier)
  local BX, BY = 4000, 4000
  local LONG = 200

  surface.request_to_generate_chunks({ x = BX + LONG / 2, y = BY }, 8)
  surface.force_generate_chunk_requests()
  clear_area(surface, BX - 5, BY - 5, BX + LONG + 10, BY + 10)

  local options = { tier = tier, tunnels = true, landfill = false, max_tiles = 100000 }
  local anchor = geometry.anchor_from_area(area(BX, BY, BX + 1, BY + 3))
  local short_run = geometry.resolve(anchor, { x = BX + 9, y = BY })
  local long_run = geometry.resolve(anchor, { x = BX + LONG - 1, y = BY })

  local function bench(label, iterations, fn)
    local profiler = game.create_profiler()
    for _ = 1, iterations do fn() end
    profiler.stop()
    profiler.divide(iterations)
    log({ "", "[BP-BENCH] " .. label .. " (avg of " .. iterations .. "): ", profiler })
  end

  bench("30 tiles, clear", 200, function()
    plan.build(surface, force, anchor, short_run, options)
  end)

  bench(LONG * 3 .. " tiles, clear", 50, function()
    plan.build(surface, force, anchor, long_run, options)
  end)

  -- Every tile occupied by something that has to be cleared: the most expensive
  -- path there is, since each tile also produces a removal spec.
  local tree_name
  for name in pairs(prototypes.get_entity_filtered { { filter = "type", type = "tree" } }) do
    tree_name = tree_name or name
  end
  if tree_name then
    local planted = 0
    for step = 0, LONG - 1 do
      for lane = 0, 2 do
        if surface.create_entity {
              name = tree_name,
              position = { BX + step + 0.5, BY + lane + 0.5 },
            } then
          planted = planted + 1
        end
      end
    end
    log("[BP-BENCH] planted " .. planted .. " trees across the run")

    bench(LONG * 3 .. " tiles, every tile a tree", 50, function()
      plan.build(surface, force, anchor, long_run, options)
    end)
  end

  local corner = geometry.resolve(anchor, { x = BX + 100, y = BY + 60 })
  if corner then
    bench("corner, 3 lanes, ~" .. geometry.cost(anchor, corner) .. " tiles", 50, function()
      plan.build(surface, force, anchor, corner, options)
    end)
  end

  ----------------------------------------------------------------------------
  -- The other half of a preview refresh: the render objects. Planning was
  -- measured first and drawing was not, which left half the cost unknown.
  --
  -- `players` is omitted here because a headless map has none; that draws for
  -- everyone rather than for one player, which costs the same to create.
  local COUNT = 300

  local function make(index)
    return rendering.draw_sprite {
      sprite = "item/transport-belt",
      target = { BX + (index % 60), BY + math.floor(index / 60) },
      x_scale = 0.5, y_scale = 0.5,
      tint = { 1, 1, 1, 0.55 },
      surface = surface,
    }
  end

  bench(COUNT .. " sprites: create and destroy (one refresh as it works now)", 50, function()
    local objects = {}
    for i = 1, COUNT do objects[i] = make(i) end
    for i = 1, COUNT do objects[i].destroy() end
  end)

  local pool = {}
  for i = 1, COUNT do pool[i] = make(i) end

  bench(COUNT .. " sprites: move and retint an existing pool", 50, function()
    for i = 1, COUNT do
      local object = pool[i]
      object.target = { BX + (i % 60) + 0.25, BY + math.floor(i / 60) }
      object.color = { 1, 1, 1, 0.4 }
    end
  end)

  for i = 1, COUNT do
    if pool[i].valid then pool[i].destroy() end
  end
end

return selftest
