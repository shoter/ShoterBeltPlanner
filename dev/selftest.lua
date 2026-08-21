-- THROWAWAY. Exercises the planner against a real surface headlessly, so the
-- geometry and tunnelling rules are checked by the engine rather than by eye.
-- Run via `factorio --create`, read the log, then delete this file.

local geometry = require("scripts/geometry")
local plan = require("scripts/logic/plan")
local place = require("scripts/logic/place")
local belts = require("scripts/belts")
local qualities = require("scripts/qualities")
local cursor_const = require("scripts/cursor/const")
local tracker = require("scripts/cursor/tracker")
-- Not `tally`: the sections below each keep a local of that name for their own
-- count of spec kinds, and shadowing the module would be an easy mistake.
local cost_tally = require("scripts/tally")

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

  local options = { tier = tier, landfill = false, max_tiles = 10000 }

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

  line("--- belt preview graphics ---")

  -- The data stage slices these and publishes the list through mod-data; the
  -- control stage reads it back. A mismatch in either the naming or the channel
  -- is silent - the preview just falls back to item icons forever - so the
  -- handshake is asserted rather than trusted.
  local east = belts.preview_animation(tier.belt, defines.direction.east)
  check("the default belt has a preview animation", east ~= nil, tier.belt)
  check("it is named for the belt and the direction",
    east == "beltplanner-preview-" .. tier.belt .. "-east", tostring(east))

  local all_four = true
  for _, dir in ipairs({ defines.direction.north, defines.direction.east,
                         defines.direction.south, defines.direction.west }) do
    if not belts.preview_animation(tier.belt, dir) then all_four = false end
  end
  check("all four facings are sliced", all_four)

  check("a diagonal has no belt graphic to show",
    belts.preview_animation(tier.belt, defines.direction.northeast) == nil)
  check("an unknown belt has none either",
    belts.preview_animation("beltplanner-not-a-belt", defines.direction.east) == nil)

  ----------------------------------------------------------------------------
  line("--- research-aware tiers ---")

  -- The picker and Shift+B both lean on belts.unlocked, which reads the force's
  -- recipes rather than assuming a recipe is named after its item. Vanilla
  -- starts with the yellow belt enabled and every faster one behind research;
  -- a modded test environment may not, so the expected answer is read off the
  -- force's own recipes rather than hard-coded.
  local test_force = game.forces[force]
  local order = belts.all()

  local function force_can_craft(f, item)
    local found = prototypes.get_recipe_filtered {
      { filter = "has-product-item", elem_filters = { { filter = "name", name = item } } },
    }
    for name in pairs(found) do
      local recipe = f.recipes[name]
      if recipe and recipe.enabled then return true end
    end
    return false
  end

  if belts.get("transport-belt") then
    check("the starting belt is unlocked on a fresh force",
      belts.unlocked(test_force, "transport-belt") == true)
  end

  local fastest = order[#order]
  local fastest_expected = force_can_craft(test_force, fastest.item)
  check("the fastest tier follows its recipe on a fresh force (" .. fastest.belt .. ")",
    belts.unlocked(test_force, fastest.belt) == fastest_expected,
    "unlocked says " .. tostring(belts.unlocked(test_force, fastest.belt))
    .. ", recipes say " .. tostring(fastest_expected))

  check("cycling forward from the default lands on something buildable",
    belts.unlocked(test_force, belts.step(test_force, tier.belt, 1).belt))
  check("cycling back from the default lands on something buildable",
    belts.unlocked(test_force, belts.step(test_force, tier.belt, -1).belt))

  -- A throwaway force whose belt recipes can be switched on and off at will,
  -- so the skipping and the nothing-unlocked fallback can be pinned without
  -- depending on what the mod set happens to research at the start.
  local lab = game.forces["beltplanner-selftest-lab"] or game.create_force("beltplanner-selftest-lab")

  local function set_lab_recipes(item, enabled)
    local found = prototypes.get_recipe_filtered {
      { filter = "has-product-item", elem_filters = { { filter = "name", name = item } } },
    }
    for name in pairs(found) do
      local recipe = lab.recipes[name]
      if recipe then recipe.enabled = enabled end
    end
  end

  for _, t in ipairs(order) do set_lab_recipes(t.item, false) end
  check("with nothing researched every tier is offered rather than none",
    belts.unlocked(lab, tier.belt) and belts.unlocked(lab, fastest.belt))

  if #order >= 2 then
    local nothing_step = belts.step(lab, tier.belt, 1)
    check("and cycling then behaves as it always did",
      nothing_step ~= nil and nothing_step.belt == order[2].belt,
      tostring(nothing_step and nothing_step.belt))

    set_lab_recipes(tier.item, true)
    check("one recipe enabled: that tier is unlocked", belts.unlocked(lab, tier.belt) == true)
    check("one recipe enabled: the fastest is not", belts.unlocked(lab, fastest.belt) == false)

    local only = belts.step(lab, tier.belt, 1)
    check("cycling with one tier unlocked stays on it",
      only ~= nil and only.belt == tier.belt, tostring(only and only.belt))

    set_lab_recipes(fastest.item, true)
    local forward = belts.step(lab, tier.belt, 1)
    check("cycling forward skips the locked middle tiers",
      forward ~= nil and forward.belt == fastest.belt, tostring(forward and forward.belt))
    local backward = belts.step(lab, tier.belt, -1)
    check("cycling back wraps round to the fastest unlocked tier",
      backward ~= nil and backward.belt == fastest.belt, tostring(backward and backward.belt))

    -- Research reversed under the player's choice: the choice is not taken
    -- away, but the next step moves off it.
    set_lab_recipes(fastest.item, false)
    local off_locked = belts.step(lab, fastest.belt, 1)
    check("cycling from a tier that has since locked steps off it",
      off_locked ~= nil and off_locked.belt == tier.belt, tostring(off_locked and off_locked.belt))
  end

  game.merge_forces(lab, test_force)

  ----------------------------------------------------------------------------
  line("--- two-click anchor sizing ---")

  -- Snapped to the longer delta, so the shape is always a legal line and the
  -- player cannot produce an illegal one however they move.
  local function sized(ox, oy, cx, cy)
    return geometry.anchor_between({ x = ox, y = oy }, { x = cx, y = cy })
  end

  local down = sized(0, 0, 0, 3)
  check("straight down gives 4 lanes on the x axis",
    down and down.axis == "x" and down.lanes == 4,
    string.format("axis %s lanes %s", tostring(down and down.axis), tostring(down and down.lanes)))

  local across = sized(0, 0, 3, 0)
  check("straight across gives 4 lanes on the y axis",
    across and across.axis == "y" and across.lanes == 4,
    string.format("axis %s lanes %s", tostring(across and across.axis), tostring(across and across.lanes)))

  local single = sized(0, 0, 0, 0)
  check("no movement is a single lane with the axis still open",
    single and single.axis == nil and single.lanes == 1)

  local wide = sized(0, 0, 5, 2)
  check("a mostly-horizontal diagonal snaps across",
    wide and wide.axis == "y" and wide.lanes == 6,
    string.format("axis %s lanes %s", tostring(wide and wide.axis), tostring(wide and wide.lanes)))

  local tall = sized(0, 0, 2, 5)
  check("a mostly-vertical diagonal snaps down",
    tall and tall.axis == "x" and tall.lanes == 6,
    string.format("axis %s lanes %s", tostring(tall and tall.axis), tostring(tall and tall.lanes)))

  local tie = sized(0, 0, 3, 3)
  check("an exact diagonal resolves consistently", tie and tie.axis == "x" and tie.lanes == 4,
    string.format("axis %s lanes %s", tostring(tie and tie.axis), tostring(tie and tie.lanes)))

  local back = sized(0, 0, 0, -3)
  check("sizing backwards puts the anchor at the far tile",
    back and back.tile.y == -3 and back.lanes == 4,
    string.format("tile.y %s lanes %s", tostring(back and back.tile.y), tostring(back and back.lanes)))

  local always_legal = true
  for dx = -4, 4 do
    for dy = -4, 4 do
      if not sized(0, 0, dx, dy) then always_legal = false end
    end
  end
  check("no pointer position can produce an illegal shape", always_legal)

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
  line("--- your own buildings stop the run ---")

  -- Nothing is tunnelled under any more, and nothing the player built is
  -- removed unasked, so a chest on the line refuses rather than being bridged.
  local obstacles = {}
  for lane = 0, 2 do
    obstacles[#obstacles + 1] = surface.create_entity {
      name = "steel-chest", position = { BX + 4.5, BY + lane + 0.5 }, force = force,
    }
  end

  local guarded, guarded_reason, guarded_tiles = plan.build(surface, force, anchor, resolved, options)
  check("a building of your own refuses the run", guarded == nil)
  check("refusal names your own building",
    guarded_reason and guarded_reason[1] == "beltplanner.error-own-structure",
    tostring(guarded_reason and guarded_reason[1]))
  check("every offending tile is reported, not just the first",
    guarded_tiles ~= nil and #guarded_tiles == 3, "got " .. tostring(guarded_tiles and #guarded_tiles))

  local cleared_options = { tier = tier, landfill = false, max_tiles = 10000, clear_built = true }
  local cleared, cleared_reason = plan.build(surface, force, anchor, resolved, cleared_options)
  check("switching the option on clears it instead", cleared ~= nil,
    tostring(cleared_reason and cleared_reason[1]))
  if cleared then
    local tally = count_kinds(cleared.specs)
    check("three chests marked for removal", tally.deconstruct == 3, "got " .. tostring(tally.deconstruct))
    check("no tunnel is invented", tally.underground == nil, "got " .. tostring(tally.underground))
    check("all 30 tiles get belt", tally.belt == 30, "got " .. tostring(tally.belt))
  end

  for _, chest in ipairs(obstacles) do if chest.valid then chest.destroy() end end

  line("--- something that is not yours stops it too ---")

  -- Same obstruction on another force: not clearable whatever the option says,
  -- and reported as a plain blockage rather than as one of yours.
  local foreign = surface.create_entity {
    name = "steel-chest", position = { BX + 4.5, BY + 0.5 }, force = "neutral",
  }
  local blocked, blocked_reason = plan.build(surface, force, anchor, resolved, cleared_options)
  check("a foreign building refuses the run even with clearing on", blocked == nil)
  check("refusal is a plain blockage",
    blocked_reason and blocked_reason[1] == "beltplanner.error-blocked",
    tostring(blocked_reason and blocked_reason[1]))
  if foreign and foreign.valid then foreign.destroy() end

  ----------------------------------------------------------------------------
  line("--- things that cannot collide with a belt do not stop it ---")

  -- The regression this section exists for. The survey used to ask what TYPE an
  -- entity was and treat anything it did not recognise as an obstruction; a
  -- construction robot is on your force, so a bot passing overhead refused the
  -- whole run and blamed "your own buildings". The tool calls bots in itself by
  -- placing ghosts, so extending a run was the likeliest way to meet it. The
  -- question is now whether the collision masks share a layer, which no bot,
  -- corpse, character or dropped item ever does with a belt.
  local bystanders = {
    surface.create_entity {
      name = "construction-robot", position = { BX + 3.5, BY + 0.5 }, force = force,
    },
    surface.create_entity {
      name = "logistic-robot", position = { BX + 5.5, BY + 1.5 }, force = force,
    },
    surface.create_entity {
      name = "item-on-ground", position = { BX + 6.5, BY + 2.5 }, stack = "iron-plate",
    },
  }
  check("bystanders placed on the line", #bystanders == 3 and bystanders[3] ~= nil,
    "got " .. tostring(#bystanders))

  local ignored, ignored_reason = plan.build(surface, force, anchor, resolved, options)
  check("a robot overhead does not refuse the run", ignored ~= nil,
    tostring(ignored_reason and ignored_reason[1]))
  if ignored then
    local tally = count_kinds(ignored.specs)
    check("nothing is marked for removal because of them", tally.deconstruct == nil,
      "got " .. tostring(tally.deconstruct))
    check("all 30 tiles still get belt", tally.belt == 30, "got " .. tostring(tally.belt))
    check("no tile is reported blocked", #ignored.blockers == 0,
      "got " .. tostring(#ignored.blockers))
  end

  -- And with clearing switched on it must not decide to deconstruct them
  -- either, which is what the type-list version did.
  local swept = plan.build(surface, force, anchor, resolved, cleared_options)
  check("clearing does not order a robot deconstructed",
    swept ~= nil and count_kinds(swept.specs).deconstruct == nil,
    tostring(swept and count_kinds(swept.specs).deconstruct))

  for _, bystander in ipairs(bystanders) do
    if bystander and bystander.valid then bystander.destroy() end
  end

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
  line("--- plants are felled like trees ---")

  -- Space Age's yumako trees and jellystems are "plant", not "tree", so a plant
  -- used to fall through to a plain blockage and refuse the run that a tree one
  -- surface over would have sailed through. The engine keeps every plant on the
  -- neutral force - even one created on the player's force comes back neutral,
  -- which is pinned here because the rule in verdict_for leans on it: there is
  -- no crop to tell apart from a weed. The type only exists with Space Age
  -- loaded, so the section is skipped rather than failed without.
  local plant_name
  for name in pairs(prototypes.get_entity_filtered { { filter = "type", type = "plant" } }) do
    plant_name = plant_name or name
  end

  if plant_name then
    local wild = surface.create_entity {
      name = plant_name, position = { BX + 4.5, BY + 0.5 }, force = "neutral",
    }
    check("wild plant placed", wild ~= nil, plant_name)

    local wild_result, wild_reason = plan.build(surface, force, anchor, resolved, options)
    check("a plant is cleared, not refused", wild_result ~= nil,
      tostring(wild_reason and wild_reason[1]))
    if wild_result then
      local tally = count_kinds(wild_result.specs)
      check("the plant is marked for removal", (tally.deconstruct or 0) == 1,
        "got " .. tostring(tally.deconstruct))
      check("all 30 tiles still get belt", tally.belt == 30, "got " .. tostring(tally.belt))
      check("no tile is reported blocked", #wild_result.blockers == 0,
        "got " .. tostring(#wild_result.blockers))
    end
    if wild and wild.valid then wild.destroy() end

    local crop = surface.create_entity {
      name = plant_name, position = { BX + 4.5, BY + 0.5 }, force = force,
    }
    check("a plant created on the player's force comes back neutral",
      crop ~= nil and crop.force.name == "neutral",
      tostring(crop and crop.force.name))

    local crop_result, crop_reason = plan.build(surface, force, anchor, resolved, options)
    check("so it is cleared like any other plant", crop_result ~= nil,
      tostring(crop_reason and crop_reason[1]))
    if crop and crop.valid then crop.destroy() end
  else
    line("  SKIP  no plant prototype available (Space Age not loaded)")
  end

  ----------------------------------------------------------------------------
  line("--- cliffs are a switch, and the switch needs the research ---")

  -- A cliff shares the object layer with a belt, so the survey sees it like any
  -- other obstruction. Whether it may be blown up is two questions, not one:
  -- the switch in the window, and whether the force has cliff explosives at
  -- all. Both are forced here so every combination is pinned.
  local player_force = game.forces[force]
  local had_explosives = player_force.cliff_deconstruction_enabled

  -- A straight west-to-east segment is four tiles across and three deep, so
  -- centred on the middle lane it crosses all three.
  local cliff = surface.create_entity {
    name = "cliff", position = { BX + 4, BY + 1.5 }, cliff_orientation = "west-to-east",
  }
  check("test cliff placed", cliff ~= nil and cliff.valid)

  if cliff and cliff.valid then
    -- Which of the run's tiles the cliff covers is read back from the entity
    -- rather than assumed, because cliffs snap to a grid of their own, and the
    -- bucketing mirrors the survey's so the two cannot drift apart.
    local box = cliff.bounding_box
    local cx1, cx2 = math.floor(box.left_top.x), math.ceil(box.right_bottom.x) - 1
    local cy1, cy2 = math.floor(box.left_top.y), math.ceil(box.right_bottom.y) - 1
    local expected = 0
    for x = math.max(cx1, BX), math.min(cx2, BX + 9) do
      for _ = math.max(cy1, BY), math.min(cy2, BY + 2) do
        expected = expected + 1
      end
    end
    check("the cliff lies across the run", expected > 0,
      string.format("box %s,%s to %s,%s", box.left_top.x, box.left_top.y,
        box.right_bottom.x, box.right_bottom.y))

    local function under_the_cliff(tiles)
      if not tiles or #tiles ~= expected then return false end
      for _, tile in ipairs(tiles) do
        if tile.x < cx1 or tile.x > cx2 or tile.y < cy1 or tile.y > cy2 then
          return false
        end
      end
      return true
    end

    local cliff_options = { tier = tier, landfill = false, max_tiles = 10000, clear_cliffs = true }

    player_force.cliff_deconstruction_enabled = false

    local off, off_reason, off_tiles = plan.build(surface, force, anchor, resolved, options)
    check("a cliff refuses the run with the switch off", off == nil)
    check("refusal names the cliff switch",
      off_reason and off_reason[1] == "beltplanner.error-cliff",
      tostring(off_reason and off_reason[1]))
    check("every tile under the cliff is reported, and nothing else",
      under_the_cliff(off_tiles),
      string.format("got %s, wanted %d", tostring(off_tiles and #off_tiles), expected))

    local early, early_reason = plan.build(surface, force, anchor, resolved, cliff_options)
    check("the switch alone is not enough without cliff explosives", early == nil)
    check("refusal still names the cliff",
      early_reason and early_reason[1] == "beltplanner.error-cliff",
      tostring(early_reason and early_reason[1]))

    player_force.cliff_deconstruction_enabled = true

    local still, still_reason = plan.build(surface, force, anchor, resolved, options)
    check("the research alone does not clear a cliff unasked", still == nil)
    check("refusal names the switch, not a plain blockage",
      still_reason and still_reason[1] == "beltplanner.error-cliff",
      tostring(still_reason and still_reason[1]))

    local blasted, blasted_reason = plan.build(surface, force, anchor, resolved, cliff_options)
    check("switch on and researched plans through the cliff", blasted ~= nil,
      tostring(blasted_reason and blasted_reason[1]))

    if blasted then
      local tally = count_kinds(blasted.specs)
      check("the cliff is marked for removal once, not once per tile",
        tally.deconstruct == 1, "got " .. tostring(tally.deconstruct))
      check("all 30 tiles get belt over it", tally.belt == 30, "got " .. tostring(tally.belt))
      check("no tile is reported blocked", #blasted.blockers == 0,
        "got " .. tostring(#blasted.blockers))

      local order
      for _, spec in ipairs(blasted.specs) do
        if spec.kind == "deconstruct" then order = spec end
      end
      check("the removal is the cliff itself", order and order.entity == cliff)

      -- The same order a deconstruction planner gives, so the robots treat it
      -- the same way.
      local created = place.execute(surface, force, nil, blasted.specs)
      check("the cliff is ordered deconstructed", cliff.to_be_deconstructed(),
        "created " .. tostring(created))
      check("every belt ghost lands over the marked cliff", created == 31,
        "created " .. tostring(created))

      for _, ghost in pairs(surface.find_entities_filtered {
        area = { { BX - 2, BY - 2 }, { BX + 14, BY + 6 } }, name = "entity-ghost",
      }) do
        ghost.destroy()
      end
      cliff.cancel_deconstruction(force)
    end

    player_force.cliff_deconstruction_enabled = had_explosives
    if cliff.valid then cliff.destroy { do_cliff_correction = false } end
  end

  line("--- water is bridged with the terrain's own cover tile ---")

  -- The survey finds water by collision layer, and lava, oil, ammoniacal ocean
  -- and empty space all carry it. The tile ordered over them used to be a
  -- literal "landfill", which on any of those can never be built; it now comes
  -- from the tile prototype's default_cover_tile. These pin that the name on the
  -- spec is the engine's answer and not a constant that happens to agree.
  local ground_name = prototypes.tile["grass-1"] and "grass-1" or "landfill"
  local wet_options = { tier = tier, landfill = true, max_tiles = 10000 }

  -- Two columns across all three lanes, in the middle of the 10-tile run.
  local function lay(tile_name)
    local tiles = {}
    for x = BX + 4, BX + 5 do
      for y = BY, BY + 2 do
        tiles[#tiles + 1] = { name = tile_name, position = { x, y } }
      end
    end
    -- correct_tiles is off so the tile set is the tile found: the transition
    -- fix-up may otherwise swap a deep tile bordering land for a shallower one.
    surface.set_tiles(tiles, false)
    return surface.get_tile(BX + 4, BY).name == tile_name
  end

  --- Name of every landfill spec, or the first one that disagrees.
  local function cover_names(specs)
    local name, mixed = nil, false
    for _, spec in ipairs(specs) do
      if spec.kind == "landfill" then
        if name and spec.name ~= name then mixed = true end
        name = name or spec.name
      end
    end
    return name, mixed
  end

  local water_cover = prototypes.tile["water"] and prototypes.tile["water"].default_cover_tile
  check("vanilla water is covered by landfill", water_cover and water_cover.name == "landfill",
    tostring(water_cover and water_cover.name))

  if prototypes.tile["water"] and lay("water") then
    local dry, dry_reason, dry_tiles = plan.build(surface, force, anchor, resolved, options)
    check("water refuses the run with the switch off", dry == nil)
    check("refusal is a plain blockage",
      dry_reason and dry_reason[1] == "beltplanner.error-blocked",
      tostring(dry_reason and dry_reason[1]))
    check("every wet tile is reported", dry_tiles ~= nil and #dry_tiles == 6,
      "got " .. tostring(dry_tiles and #dry_tiles))

    local wet, wet_reason = plan.build(surface, force, anchor, resolved, wet_options)
    check("the switch bridges it", wet ~= nil, tostring(wet_reason and wet_reason[1]))
    if wet then
      local tally = count_kinds(wet.specs)
      check("one landfill spec per wet tile", tally.landfill == 6, "got " .. tostring(tally.landfill))
      check("belts still cover all 30 tiles", tally.belt == 30, "got " .. tostring(tally.belt))
      local name, mixed = cover_names(wet.specs)
      check("water is covered with landfill", name == "landfill" and not mixed,
        string.format("name %s mixed %s", tostring(name), tostring(mixed)))
    end
  else
    line("  SKIP  no water tile to lay")
  end

  -- A different water tile, still in base: the name must follow the prototype.
  local deep = prototypes.tile["deepwater"]
  if deep and deep.default_cover_tile and lay("deepwater") then
    local expected = deep.default_cover_tile.name
    local over_deep = plan.build(surface, force, anchor, resolved, wet_options)
    check("deepwater plans with the switch on", over_deep ~= nil)
    if over_deep then
      local name, mixed = cover_names(over_deep.specs)
      check("deepwater is covered with its prototype's cover tile",
        name == expected and not mixed,
        string.format("wanted %s got %s", expected, tostring(name)))
    end
  else
    line("  SKIP  no deepwater tile with a cover")
  end

  -- The case the change exists for: a water-layer tile whose cover is NOT
  -- landfill. Base has none, so this only runs with Space Age (lava, the oil
  -- ocean, the ammoniacal ocean, empty space) or a mod that adds one.
  local foreign_name, foreign_cover
  for name, tile in pairs(prototypes.tile) do
    local cover = tile.default_cover_tile
    if tile.collision_mask.layers.water_tile and cover and cover.name ~= "landfill" then
      foreign_name, foreign_cover = name, cover.name
      break
    end
  end
  if foreign_name and lay(foreign_name) then
    local over_foreign, foreign_reason = plan.build(surface, force, anchor, resolved, wet_options)
    check(foreign_name .. " plans with the switch on", over_foreign ~= nil,
      tostring(foreign_reason and foreign_reason[1]))
    if over_foreign then
      local name, mixed = cover_names(over_foreign.specs)
      check(foreign_name .. " is covered with " .. foreign_cover .. ", not landfill",
        name == foreign_cover and not mixed,
        string.format("got %s mixed %s", tostring(name), tostring(mixed)))
    end
  else
    line("  SKIP  no water-layer tile with a cover other than landfill (needs Space Age)")
  end

  -- Water that nothing covers is a wall even with the switch on. Found by
  -- asking the prototypes rather than by name, because which tile that is
  -- depends on what is loaded; out-of-map is the usual answer.
  local bare_name
  for name, tile in pairs(prototypes.tile) do
    if tile.collision_mask.layers.water_tile and not tile.default_cover_tile then
      bare_name = name
      break
    end
  end
  if bare_name and lay(bare_name) then
    local bare, bare_reason, bare_tiles = plan.build(surface, force, anchor, resolved, wet_options)
    check(bare_name .. " refuses the run even with the switch on", bare == nil)
    check("refusal is a plain blockage",
      bare_reason and bare_reason[1] == "beltplanner.error-blocked",
      tostring(bare_reason and bare_reason[1]))
    check("every uncoverable tile is reported", bare_tiles ~= nil and #bare_tiles == 6,
      "got " .. tostring(bare_tiles and #bare_tiles))
  else
    line("  SKIP  no water-layer tile without a cover tile")
  end

  -- Dry land again for everything that follows.
  check("ground restored after the water tests", lay(ground_name))

  line("--- the tally: what the label and the window say a click costs ---")

  -- The label and the window quote the same tally, taken off the spec list the
  -- click commits, so the numbers are checked against a run whose cost is
  -- known: six tiles of water across all three lanes, two trees, and one chest
  -- of the player's own with the clearing switch on.
  local yellow = belts.get("transport-belt")
  check("yellow belt is 15 items/s", yellow ~= nil and cost_tally.throughput(yellow) == 15,
    "got " .. tostring(yellow and cost_tally.throughput(yellow)))

  if yellow and tree_name and prototypes.tile["water"] then
    local ground = prototypes.tile["grass-1"] and "grass-1" or "landfill"
    local function flood(name)
      local tiles = {}
      for x = BX + 2, BX + 3 do
        for y = BY, BY + 2 do
          tiles[#tiles + 1] = { name = name, position = { x, y } }
        end
      end
      surface.set_tiles(tiles)
    end
    flood("water")

    local felled = {
      surface.create_entity { name = tree_name, position = { BX + 5.5, BY + 0.5 } },
      surface.create_entity { name = tree_name, position = { BX + 6.5, BY + 1.5 } },
    }
    local chest = surface.create_entity {
      name = "steel-chest", position = { BX + 8.5, BY + 2.5 }, force = force,
    }
    check("tally fixtures placed", felled[1] ~= nil and felled[2] ~= nil and chest ~= nil)

    local costed_options = { tier = yellow, landfill = true, max_tiles = 10000, clear_built = true }
    local costed, costed_reason = plan.build(surface, force, anchor, resolved, costed_options)
    check("the costed run plans", costed ~= nil, tostring(costed_reason and costed_reason[1]))

    if costed then
      local counts = cost_tally.count(costed.specs)
      check("tally counts 30 belts", counts.belts == 30, "got " .. tostring(counts.belts))
      check("tally counts 6 landfill", counts.landfill == 6, "got " .. tostring(counts.landfill))
      check("tally counts 2 trees/rocks", counts.natural == 2, "got " .. tostring(counts.natural))
      check("tally counts 1 of your buildings", counts.owned == 1, "got " .. tostring(counts.owned))
      check("tally counts nothing that is not there",
        counts.splitters == 0 and counts.undergrounds == 0,
        string.format("splitters=%s undergrounds=%s", tostring(counts.splitters), tostring(counts.undergrounds)))

      local summary = cost_tally.summary(anchor, costed, yellow)
      local run = summary.run
      check("run line is the preview label", run[1] == "beltplanner.preview-label", tostring(run[1]))
      check("run line says 3 lanes over 30 tiles", run[2] == 3 and run[3] == 30,
        string.format("got %s, %s", tostring(run[2]), tostring(run[3])))
      check("run line says 45 items/s for three yellow lanes", run[4] == "45", tostring(run[4]))
      -- The suffix slot is a concatenation of the reversed note and the quality
      -- note, each empty when there is nothing to say.
      check("run line has no reversed suffix",
        type(run[5]) == "table" and run[5][1] == "" and run[5][2] == "",
        serpent.line(run[5]))
      check("run line has no quality suffix at normal", run[5][3] == "", serpent.line(run[5]))

      -- The cost line is fragments joined in Lua, which is what lets each be
      -- translated; the join has to stay under the 20-parameter limit with
      -- room for every kind the tally knows.
      local cost = summary.cost
      check("cost line exists", cost ~= nil)
      if cost then
        check("cost line is a concatenation", cost[1] == "", tostring(cost[1]))
        check("cost line is within the parameter limit", #cost <= 20, "got " .. #cost)
        local named = {}
        for index = 2, #cost do
          local part = cost[index]
          if part[1] ~= "beltplanner.tally-separator" then
            named[#named + 1] = part[1] .. "=" .. tostring(part[2])
          end
        end
        check("cost line names only the non-zero parts, in order",
          table.concat(named, " ") ==
            "beltplanner.tally-belts=30 beltplanner.tally-landfill=6 beltplanner.tally-natural=2 beltplanner.tally-owned=1",
          table.concat(named, " "))
        check("separators sit between the parts, never at the ends",
          cost[2][1] ~= "beltplanner.tally-separator"
            and cost[#cost][1] ~= "beltplanner.tally-separator"
            and #cost == 2 * #named)
      end

      anchor.reversed = true
      local reversed_summary = cost_tally.summary(anchor, costed, yellow)
      check("reversed run line carries the suffix",
        type(reversed_summary.run[5]) == "table"
          and type(reversed_summary.run[5][2]) == "table"
          and reversed_summary.run[5][2][1] == "beltplanner.reversed-suffix",
        serpent.line(reversed_summary.run[5]))
      anchor.reversed = false
    end

    -- Nothing to name, nothing said: the window hides the line rather than
    -- showing an empty one.
    check("an empty list has no cost line", cost_tally.cost_line(cost_tally.count({})) == nil)

    for _, tree in ipairs(felled) do if tree and tree.valid then tree.destroy() end end
    if chest and chest.valid then chest.destroy() end
    flood(ground)
  else
    line("  SKIP  tally fixtures unavailable (yellow belt, a tree and water are needed)")
  end

  ----------------------------------------------------------------------------
  line("--- probe selection priority ---")

  -- These two facts are what keep the tracker from taking the cursor off the
  -- whole map. A root sits below ordinary entities, so it only wins over bare
  -- ground; every level below it outranks them, so once a descent has started it
  -- holds even across a factory. Get either backwards and the tool still works
  -- for the player holding it, which is exactly why it needs pinning here: what
  -- breaks is everyone else's cursor, in multiplayer, silently.
  local root_priority = prototypes.entity[cursor_const.root.name].selection_priority
  check("a root probe sits below ordinary entities", root_priority < 50,
    "got " .. tostring(root_priority))

  local rising, detail, previous = true, "", nil
  for _, level in ipairs(cursor_const.levels) do
    if not level.is_root then
      local priority = prototypes.entity[level.name].selection_priority
      if priority <= 50 then
        rising, detail = false, level.name .. " is " .. priority .. ", not above ordinary entities"
      elseif previous and priority <= previous then
        rising, detail = false, level.name .. " is " .. priority .. ", not above its parent"
      end
      previous = priority
    end
  end
  check("every level below the root outranks them, and rises with depth", rising, detail)

  ----------------------------------------------------------------------------
  line("--- guessing the descent chain ---")

  -- Every re-seed used to leave only the roots, so the pointer had to be walked
  -- back down one level per tick - and inside a factory not at all, since roots
  -- lose to real entities on purpose. The chain is now guessed in one go from
  -- the last known position. If this arithmetic is off by so much as half a
  -- tile the guess lands on the wrong tile and the preview quietly follows the
  -- cursor at an offset, which is why it is pinned rather than eyeballed.
  tracker.init()
  local probe_pdata = { probes = {} }
  local target = { x = BX + 6.5, y = BY + 3.5 }
  tracker.seed_descent(probe_pdata, surface, target)

  local levels_ok, levels_detail = true, ""
  local expected_per_level = cursor_const.SUBDIVISIONS ^ 2
  for pow = cursor_const.MIN_POW, cursor_const.MAX_POW - 1 do
    local list = probe_pdata.probes[pow]
    if not list or #list ~= expected_per_level then
      levels_ok = false
      levels_detail = "level " .. pow .. " has " .. tostring(list and #list)
    end
  end
  check("every level below the root is guessed", levels_ok, levels_detail)
  check("the roots themselves are left alone", probe_pdata.probes[cursor_const.MAX_POW] == nil)

  -- The point of the whole exercise: a leaf must be sitting on the target tile,
  -- because that is what the next tick reads the pointer position off.
  local want_x, want_y = math.floor(target.x), math.floor(target.y)
  local landed = false
  for _, probe in ipairs(probe_pdata.probes[cursor_const.MIN_POW] or {}) do
    if math.floor(probe.position.x) == want_x and math.floor(probe.position.y) == want_y then
      landed = true
    end
  end
  check("a leaf probe lands on the target tile", landed,
    string.format("wanted %d,%d", want_x, want_y))

  -- Each level must tile its parent exactly, or the guess leaves gaps the
  -- pointer can sit in and the descent stalls on nothing.
  local covers, covers_detail = true, ""
  for pow = cursor_const.MIN_POW, cursor_const.MAX_POW - 1 do
    local size = cursor_const.by_pow[pow].size
    local parent_size = cursor_const.by_pow[pow + 1].size
    local left = math.floor(target.x / parent_size) * parent_size
    local top = math.floor(target.y / parent_size) * parent_size

    local area = 0
    for _, probe in ipairs(probe_pdata.probes[pow]) do
      local px, py = probe.position.x - size / 2, probe.position.y - size / 2
      if px < left or py < top or px + size > left + parent_size or py + size > top + parent_size then
        covers, covers_detail = false, "level " .. pow .. " strays outside its parent cell"
      end
      area = area + size * size
    end
    if area ~= parent_size * parent_size then
      covers, covers_detail = false, "level " .. pow .. " covers " .. area .. " of " .. (parent_size * parent_size)
    end
  end
  check("each guessed level tiles its parent exactly", covers, covers_detail)

  for pow, list in pairs(probe_pdata.probes) do
    for _, probe in ipairs(list) do
      if probe.valid then probe.destroy() end
    end
    probe_pdata.probes[pow] = nil
  end

  ----------------------------------------------------------------------------
  line("--- budget ---")

  local tiny = { tier = tier, landfill = false, max_tiles = 5 }
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

  line("--- straight from any row of the bundle ---")

  -- The 3-lane anchor covers rows BY, BY+1 and BY+2. A target on any of those
  -- rows is a straight run: no corner is possible inside the bundle's own
  -- width, so this is a definition rather than a guess. It used to be refused
  -- as a turn too shallow for the width, which meant a wide bus could only be
  -- carried on by pointing at lane 1's exact row.
  local middle_row = geometry.resolve(anchor, { x = BX + 10, y = BY + 1 })
  check("a target on the middle row resolves straight",
    middle_row ~= nil and middle_row.curved == false,
    tostring(middle_row and middle_row.curved))
  check("and is as long as pointing at lane 1's row",
    middle_row and middle_row.length == 11 and middle_row.along_sign == 1,
    string.format("length %s sign %s",
      tostring(middle_row and middle_row.length), tostring(middle_row and middle_row.along_sign)))

  local last_row = geometry.resolve(anchor, { x = BX + 10, y = BY + 2 })
  check("a target on the last row resolves straight",
    last_row ~= nil and last_row.curved == false,
    tostring(last_row and last_row.curved))
  check("and is the same length", last_row and last_row.length == 11,
    "got " .. tostring(last_row and last_row.length))

  local just_past = geometry.resolve(anchor, { x = BX + 10, y = BY + 3 })
  check("the first row outside the band is a corner again",
    just_past ~= nil and just_past.curved == true,
    tostring(just_past and just_past.curved))
  local just_before = geometry.resolve(anchor, { x = BX + 10, y = BY - 1 })
  check("so is the first row on the other side",
    just_before ~= nil and just_before.curved == true,
    tostring(just_before and just_before.curved))

  -- Nothing ahead of the anchor can be refused now: inside the band it is
  -- straight, outside it every lane has at least one tile of second leg.
  local ahead_always_resolves = true
  for cross = -6, 8 do
    if geometry.resolve(anchor, { x = BX + 10, y = BY + cross }) == nil then
      ahead_always_resolves = false
    end
  end
  check("no target ahead of the anchor is refused, on any row", ahead_always_resolves)

  -- Rows 2 and 3 plan exactly the belts row 1 does, not merely a run of the
  -- same shape.
  local function fingerprint(specs)
    local entries = {}
    for _, spec in ipairs(specs) do
      entries[#entries + 1] = string.format("%s %s %s,%s %s",
        spec.kind, tostring(spec.name), spec.position.x, spec.position.y, tostring(spec.direction))
    end
    table.sort(entries)
    return table.concat(entries, ";")
  end

  local row1 = plan.build(surface, force, anchor, geometry.resolve(anchor, { x = BX + 9, y = BY }), options)
  local row2 = plan.build(surface, force, anchor, geometry.resolve(anchor, { x = BX + 9, y = BY + 1 }), options)
  local row3 = plan.build(surface, force, anchor, geometry.resolve(anchor, { x = BX + 9, y = BY + 2 }), options)
  check("rows 1, 2 and 3 all plan", row1 ~= nil and row2 ~= nil and row3 ~= nil)
  if row1 and row2 and row3 then
    check("row 1 plans 30 belts", count_kinds(row1.specs).belt == 30,
      "got " .. tostring(count_kinds(row1.specs).belt))
    check("row 2 plans the same belts as row 1", fingerprint(row2.specs) == fingerprint(row1.specs))
    check("row 3 plans the same belts as row 1", fingerprint(row3.specs) == fingerprint(row1.specs))
  end

  line("--- corners that cannot be made ---")
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
    tier = tier, landfill = false, max_tiles = 10000, splitters = true,
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

      -- The preview never plans splitters today, but the tally must already
      -- count them for the day it does.
      local counts = cost_tally.count(split_result.specs)
      check("tally counts the splitter and the belts leading to it",
        counts.splitters == 1 and counts.belts == 18,
        string.format("splitters=%s belts=%s", tostring(counts.splitters), tostring(counts.belts)))
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

  ----------------------------------------------------------------------------
  line("--- quality ---")

  -- Every ghost used to come out normal because nothing ever passed a quality.
  -- The choice now travels options -> spec -> create_entity, and a ghost already
  -- sitting on a tile at the wrong quality has to be replaced the way a wrong
  -- tier is, or changing quality mid-chain would strand one tile of the old
  -- quality in the middle of the new run.
  local normal = qualities.default()
  check("normal is the default quality", normal ~= nil and normal.name == "normal",
    tostring(normal and normal.name))

  -- "normal" is the one hidden quality that must still be there: the base game
  -- hides it and the quality mod unhides it, and either way it is the default.
  local offers_hidden, hidden_name = false, ""
  for _, quality in ipairs(qualities.all()) do
    if quality.name ~= "normal" and prototypes.quality[quality.name].hidden then
      offers_hidden, hidden_name = true, quality.name
    end
  end
  check("hidden qualities other than normal are never offered", not offers_hidden, hidden_name)
  check("a choice is offered only when there is more than one",
    qualities.selectable() == (#qualities.all() > 1),
    tostring(#qualities.all()) .. " selectable")

  local function ghost_at(x, y)
    -- find_entities_filtered, not find_entity: a bare name in find_entity means
    -- normal quality only, and these tests exist to look at ghosts that are not.
    return surface.find_entities_filtered {
      position = { x + 0.5, y + 0.5 }, name = "entity-ghost", limit = 1,
    }[1]
  end

  --- The one quality every spec of this kind carries, and whether they all agree.
  local function spec_quality(specs, kind)
    local seen, uniform = nil, true
    for _, spec in ipairs(specs) do
      if spec.kind == kind then
        if seen == nil then
          seen = spec.quality
        elseif spec.quality ~= seen then
          uniform = false
        end
      end
    end
    return seen, uniform
  end

  local function clear_ghosts(x1, y1, x2, y2)
    for _, ghost in pairs(surface.find_entities_filtered {
      area = { { x1, y1 }, { x2, y2 } }, name = "entity-ghost",
    }) do
      ghost.destroy()
    end
  end

  local normal_options = { tier = tier, landfill = true, max_tiles = 10000, quality = "normal" }

  -- A tile has no quality, so the landfill spec must not carry one even when the
  -- belts around it do. Checked before any ghost goes down, on a single tile of
  -- water dropped into the run and taken out again afterwards.
  local ground = surface.get_tile(BX + 4, BY + 1).name
  surface.set_tiles({ { name = "water", position = { BX + 4, BY + 1 } } })
  local wet_result, wet_reason = plan.build(surface, force, anchor, resolved, normal_options)
  check("a run over water plans with a quality given", wet_result ~= nil,
    tostring(wet_reason and wet_reason[1]))
  if wet_result then
    local tally = count_kinds(wet_result.specs)
    check("one landfill spec for the water tile", tally.landfill == 1, "got " .. tostring(tally.landfill))
    local landfill_quality = spec_quality(wet_result.specs, "landfill")
    check("a landfill spec carries no quality", landfill_quality == nil, tostring(landfill_quality))
  end
  surface.set_tiles({ { name = ground, position = { BX + 4, BY + 1 } } })

  local normal_result, normal_reason = plan.build(surface, force, anchor, resolved, normal_options)
  check("plan succeeds with a quality given", normal_result ~= nil,
    tostring(normal_reason and normal_reason[1]))
  if normal_result then
    local carried, uniform = spec_quality(normal_result.specs, "belt")
    check("every belt spec carries the chosen quality", carried == "normal" and uniform,
      tostring(carried))
    check("the result echoes the quality for the preview label",
      normal_result.quality == "normal", tostring(normal_result.quality))

    place.execute(surface, force, nil, normal_result.specs)
    local ghost = ghost_at(BX, BY)
    check("a ghost is placed at the head of the run", ghost ~= nil)
    check("the ghost is normal quality", ghost ~= nil and ghost.quality.name == "normal",
      tostring(ghost and ghost.quality.name))
  end

  -- The other half needs a second quality, which only Space Age or a quality
  -- mod provides. A base-only install skips it rather than failing.
  local other
  for _, quality in ipairs(qualities.all()) do
    if quality.name ~= "normal" then
      other = other or quality
    end
  end

  if other and normal_result then
    local other_options = { tier = tier, landfill = false, max_tiles = 10000, quality = other.name }
    local other_result, other_reason = plan.build(surface, force, anchor, resolved, other_options)
    check("plan succeeds at " .. other.name, other_result ~= nil,
      tostring(other_reason and other_reason[1]))

    if other_result then
      local carried, uniform = spec_quality(other_result.specs, "belt")
      check("belt specs carry the other quality", carried == other.name and uniform,
        tostring(carried))

      -- Over the normal run just placed: every tile already holds our own belt
      -- ghost at the wrong quality, so every one must be replaced.
      local created = place.execute(surface, force, nil, other_result.specs)
      check("every tile is replaced, not kept", created == 30, "got " .. tostring(created))

      local ghost = ghost_at(BX, BY)
      check("the head ghost now has the other quality",
        ghost ~= nil and ghost.quality.name == other.name,
        tostring(ghost and ghost.quality.name))
      local on_tile = surface.find_entities_filtered {
        area = { { BX, BY }, { BX + 1, BY + 1 } }, name = "entity-ghost",
      }
      check("one ghost on the tile after the replacement", #on_tile == 1, "got " .. #on_tile)

      local again = place.execute(surface, force, nil, other_result.specs)
      check("the same run at the same quality places nothing new", again == 0,
        "got " .. tostring(again))
    end

    -- Splitters are entity ghosts too, so they take the quality as well.
    if pair then
      local straight = geometry.resolve(pair, { x = BX + 9, y = BY + 20 })
      local split_quality = {
        tier = tier, landfill = false, max_tiles = 10000, splitters = true, quality = other.name,
      }
      local split_result, split_reason = plan.build(surface, force, pair, straight, split_quality)
      check("a split run plans at " .. other.name, split_result ~= nil,
        tostring(split_reason and split_reason[1]))
      if split_result then
        local carried = spec_quality(split_result.specs, "splitter")
        check("the splitter spec carries the quality", carried == other.name, tostring(carried))

        place.execute(surface, force, nil, split_result.specs)
        local splitter_ghost = surface.find_entities_filtered {
          position = { BX + 9.5, BY + 21 }, name = "entity-ghost", limit = 1,
        }[1]
        check("the splitter ghost has the quality",
          splitter_ghost ~= nil and splitter_ghost.quality.name == other.name,
          tostring(splitter_ghost and splitter_ghost.quality.name))
      end
      clear_ghosts(BX - 2, BY + 18, BX + 14, BY + 24)
    end
  else
    line("  SKIP  only one selectable quality here; replacement by quality is not exercised")
  end

  clear_ghosts(BX - 2, BY - 2, BX + 14, BY + 6)

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

  local options = { tier = tier, landfill = false, max_tiles = 100000 }
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
