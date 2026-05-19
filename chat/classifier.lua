-- Entity classifier for the chat panel.
--
-- Given a mob ID (player, monster, NPC, pet, trust, whatever), returns
-- a (category, display_name, party_slot) triple:
--
--   category     := one of:
--                   'self'      -- it's me
--                   'pet'       -- my pet/trust
--                   'party'     -- party member (not me)
--                   'party_pet' -- pet/trust of a party member
--                   'alliance'  -- alliance member (not in my party)
--                   'mob'       -- monster
--                   'npc'       -- NPC (non-combat)
--                   'other'     -- player not in my party/alliance
--                   nil         -- can't resolve (unknown id, id=0, etc.)
--
--   display_name := the name to show in chat (may be nil for unresolved
--                   mob references; caller falls back to ?)
--
--   party_slot   := for 'party' / 'alliance' / 'party_pet' categories,
--                   the slot key from windower.ffxi.get_party()
--                   (p0..p5 own party, a10..a15 / a20..a25 alliance).
--                   nil otherwise. Used by per-job filters that want to
--                   pin a slot — e.g. "show party slot p0 in own tab".
--
-- Distinct from _ow_dps_classify_actor (line 4956) for two reasons:
--   (1) DPS classifier is gated on PW_DPS_INCLUDE_PARTY; chat must
--       classify regardless of DPS config.
--   (2) DPS classifier conflates "role" with "name" by returning the
--       member's name as the category. Chat filters need role separate
--       from name so they can match by role across many entities.
--
-- The two classifiers will likely converge in a later refactor, but
-- keeping them parallel for now avoids any chance of DPS regressions
-- while the chat path stabilizes.

local M = {}

function M.classify_entity(id)
    if not id or id == 0 then return nil, nil, nil end

    local me = windower.ffxi.get_player()
    if not me then return nil, nil, nil end

    -- Self.
    if id == me.id then
        return 'self', me.name, nil
    end

    -- Own pet/trust. me.pet covers the addon's directly-summoned pet;
    -- trusts also appear in the party as 'party' members (with mob
    -- entries that have is_npc=true and an is_trust flag), so they're
    -- handled in the party walk below — not here.
    if me.pet and me.pet.id and id == me.pet.id then
        return 'pet', me.pet.name or 'pet', nil
    end

    -- Walk party + alliance. windower.ffxi.get_party() returns a single
    -- table keyed by p0..p5 (own party), a10..a15 + a20..a25 (alliance
    -- parties). Member entries have .name, .mob (the mob array entry),
    -- and various status fields. We check .mob.id against the target id.
    local party = windower.ffxi.get_party()
    if party then
        for slot, m in pairs(party) do
            if type(slot) == 'string'
               and type(m) == 'table' and m.mob and m.mob.id == id then
                -- 'party' for own slots (p0..p5), 'alliance' for the
                -- other two parties (a10..a15, a20..a25). Slot keys
                -- starting with 'p' are own party; 'a' are alliance.
                -- Trust mobs have .mob.is_npc=true; we still call them
                -- 'party' since FFXI treats them as full party members
                -- for buff/heal targeting purposes.
                local is_own_party = slot:sub(1, 1) == 'p'
                return is_own_party and 'party' or 'alliance',
                       m.name, slot
            end
        end

        -- Pet of a party member. Match the target's mob.index against
        -- each party member's mob.pet_index (the index — not id — of
        -- their pet in the mob array). This is the only reliable way
        -- to associate a wandering pet mob with its owner.
        local target_mob = windower.ffxi.get_mob_by_id(id)
        if target_mob and target_mob.is_npc then
            for slot, m in pairs(party) do
                if type(slot) == 'string'
                   and type(m) == 'table' and m.mob and m.mob.pet_index
                   and m.mob.pet_index ~= 0
                   and target_mob.index == m.mob.pet_index then
                    return 'party_pet',
                           (m.name or '?') .. "'s pet",
                           slot
                end
            end
        end
    end

    -- Not self, pet, party, or alliance. Use the mob array to classify
    -- as mob / npc / other-player. get_mob_by_id may return nil for
    -- entities outside the local mob array (distant players, etc.) —
    -- in that case we return 'other' with no name; the caller will
    -- usually have a name from elsewhere (chat text contains it).
    local mob = windower.ffxi.get_mob_by_id(id)
    if not mob then
        return 'other', nil, nil
    end

    -- Spawn type interpretation:
    --   1  = PC
    --   2  = NPC
    --   16 = monster
    -- mob.is_npc=true is set for both NPCs and mobs (and trusts).
    -- spawn_type is the clean discriminator when present.
    local st = mob.spawn_type
    if st == 16 then
        return 'mob', mob.name, nil
    elseif st == 2 then
        return 'npc', mob.name, nil
    elseif st == 1 or not mob.is_npc then
        return 'other', mob.name, nil
    end

    -- Unknown spawn_type. Conservative default: 'npc' since
    -- mis-classifying a mob as npc just means it shows in the wrong
    -- tab; mis-classifying an npc as mob clutters the battle log.
    return 'npc', mob.name, nil
end

return M