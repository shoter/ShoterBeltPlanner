-- Commits a spec list to the world as ghosts.
--
-- Nothing here builds a real entity or consumes an item: a committed segment is
-- an order for the construction robots, so the tool never changes anything the
-- player has not already agreed to, and taking the mod away leaves ordinary
-- vanilla ghosts behind.
--
-- The undo bookkeeping is the whole reason this is its own module.
-- `undo_index = 0` opens a fresh undo item and `1` appends to the newest one, so
-- opening once and appending for everything else collapses a segment of any size
-- into a single Ctrl+Z, landfill and felled trees included.
--
-- The undo item is also tagged. The session hands in where the anchor was before
-- the commit and where it ended up, and that rides along on the first action of
-- the item, so when the player presses Ctrl+Z the session can hear about it and
-- put the anchor back where the removed run started instead of leaving it at
-- the far end of belts that no longer exist.

local place = {}

local BELT_GHOSTS = {
  ["transport-belt"] = true,
  ["underground-belt"] = true,
  ["splitter"] = true,
}

--- Does this ghost already say exactly what the spec wants?
local function matches(existing, spec)
  if existing.ghost_name ~= spec.name then return false end
  if existing.direction ~= spec.direction then return false end
  if spec.type and existing.belt_to_ground_type ~= spec.type then return false end
  -- A ghost's quality is the quality the entity will be built at, and a spec
  -- with none asks for "normal", which is also what create_entity defaults to.
  -- Without this a quality change mid-chain would leave the shared tile at the
  -- old quality, exactly the way a tier change used to strand a belt.
  if existing.quality.name ~= (spec.quality or "normal") then return false end
  return true
end

--- Runs chain by re-anchoring on the last tile placed, so one tile of every new
--- run already holds the previous run's ghost. Leaving it alone is right when
--- nothing changed, but after a belt-tier change or a direction flip it would
--- strand a single tile of the old run in the middle of the new one - and
--- create_entity will not overwrite it. Only our own belt ghosts are replaced;
--- anything else in the way is left for the player to deal with.
---
--- Returns `satisfied` (the spec is already in place, skip it) and `destroyed`
--- (an undo action was taken, so the undo item is now open).
local function reconcile_existing(surface, spec, force_name, player, undo_index)
  -- Not find_entity: a bare prototype name there means "at normal quality", so
  -- it walks straight past a ghost placed at any other quality and the tile
  -- would then be planned over as though it were empty. The filtered search
  -- takes a plain EntityID and sees the ghost whatever its quality.
  local existing = surface.find_entities_filtered {
    position = spec.position,
    name = "entity-ghost",
    limit = 1,
  }[1]
  if not (existing and existing.valid) then return false, false end

  if matches(existing, spec) then return true, false end

  if BELT_GHOSTS[existing.ghost_type] and existing.force.name == force_name then
    existing.destroy { player = player, undo_index = undo_index }
    return false, player ~= nil
  end

  return false, false
end

--- Hang `tag` on the newest undo item, which is the one execute() just filled.
---
--- Index 1 is the most recent item on the stack, and the tag goes on its first
--- action: every action of the item is handed back in on_undo_applied, so one is
--- enough and the first is the one guaranteed to exist. Guarded on the stack
--- being non-empty rather than trusting the caller's count, because a tag on a
--- nonexistent item is an error, not a no-op.
local function tag_undo_item(player, tag)
  local stack = player.undo_redo_stack
  if not (stack and stack.valid) then return end
  if stack.get_undo_item_count() == 0 then return end
  if #stack.get_undo_item(1) == 0 then return end
  stack.set_undo_tag(1, 1, "beltplanner", tag)
end

--- `undo_tag` is optional and only meaningful with a player: without one there
--- is no undo stack for it to go on, and without anything created there is no
--- undo item of ours to put it on, so it is silently dropped in both cases.
function place.execute(surface, force, player, specs, undo_tag)
  local created = 0
  -- Stays true until something actually lands: if the first action fails, the
  -- undo item was never opened and the next spec has to open it instead.
  local needs_new_undo_item = true
  local force_name = type(force) == "string" and force or force.name

  -- Undo items live on a player, so a scripted or robot-driven call has no queue
  -- to bookkeep and must not ask for one.
  local function undo_index()
    if not player then return nil end
    return needs_new_undo_item and 0 or 1
  end

  for _, spec in ipairs(specs) do
    -- Clearing the way is an order, not a placement, but it takes the same
    -- undo_index, so a tree felled for a belt is undone by the same Ctrl+Z that
    -- removes the belt.
    if spec.kind == "deconstruct" then
      local entity = spec.entity
      if entity and entity.valid and not entity.to_be_deconstructed() then
        if entity.order_deconstruction(force, player, undo_index()) then
          created = created + 1
          needs_new_undo_item = false
        end
      end
      goto continue
    end

    local args
    if spec.kind == "landfill" then
      args = {
        name = "tile-ghost",
        inner_name = spec.name,
        position = spec.position,
      }
    else
      local satisfied, destroyed = reconcile_existing(
        surface, spec, force_name, player, undo_index())
      -- A destroy already opened the undo item, so the create that follows must
      -- append rather than opening a second one and costing two Ctrl+Z.
      if destroyed then needs_new_undo_item = false end
      if satisfied then goto continue end
      args = {
        name = "entity-ghost",
        inner_name = spec.name,
        position = spec.position,
        direction = spec.direction,
        -- Only underground belts read this, and they must: belt_to_ground_type
        -- is read-only, so an entry/exit set wrongly here cannot be repaired
        -- afterwards.
        type = spec.type,
        -- Nil means "normal". Tile ghosts never come through here, which is
        -- right: a tile has no quality.
        quality = spec.quality,
      }
    end

    args.force = force
    if player then
      args.player = player
      args.undo_index = undo_index()
    end
    args.create_build_effect_smoke = false
    args.raise_built = true

    if surface.create_entity(args) then
      created = created + 1
      needs_new_undo_item = false
    end

    ::continue::
  end

  if undo_tag and player and created > 0 then
    tag_undo_item(player, undo_tag)
  end

  return created
end

return place
