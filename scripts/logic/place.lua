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
-- into a single Ctrl+Z, landfill included.

local place = {}

function place.execute(surface, force, player, specs)
  local created = 0
  -- Stays true until something actually lands: if the first create_entity fails,
  -- the undo item was never opened and the next spec has to open it instead.
  local needs_new_undo_item = true

  for _, spec in ipairs(specs) do
    -- Clearing the way is an order, not a placement, but it takes the same
    -- undo_index, so a tree felled for a belt is undone by the same Ctrl+Z that
    -- removes the belt.
    if spec.kind == "deconstruct" then
      local entity = spec.entity
      if entity and entity.valid and not entity.to_be_deconstructed() then
        local ordered = entity.order_deconstruction(
          force, player, player and (needs_new_undo_item and 0 or 1) or nil)
        if ordered then
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
      args = {
        name = "entity-ghost",
        inner_name = spec.name,
        position = spec.position,
        direction = spec.direction,
        -- Only underground belts read this, and they must: belt_to_ground_type
        -- is read-only, so an entry/exit set wrongly here cannot be repaired
        -- afterwards.
        type = spec.type,
      }
    end

    args.force = force
    -- Undo items live on a player, so a scripted or robot-driven call has no
    -- queue to bookkeep and must not ask for one.
    if player then
      args.player = player
      args.undo_index = needs_new_undo_item and 0 or 1
    end
    args.create_build_effect_smoke = false
    args.raise_built = true

    if surface.create_entity(args) then
      created = created + 1
      needs_new_undo_item = false
    end

    ::continue::
  end

  return created
end

return place
