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

-- ── Engaged-vs-passive mob detection ─────────────────────────────────────
--
-- A monster is "engaged" (yours) when YOU, a party member, or an
-- alliance member has claim on it — i.e. mob.claim_id matches one of
-- your group's player ids. Otherwise it's "passive": another party's
-- claim, or unclaimed. This mirrors what in-game filters and BattleMod
-- expose as engaged-vs-passive, letting the routing config show only
-- the mobs your group is actually fighting (Mob tab) while hiding a
-- nearby party's fight.
--
-- claim_id is the entity id of whoever has claim (the same field
-- OmniWatch's target panel uses at OmniWatch.lua ~13367). For PCs that
-- id is the player.id; for our own group we collect those ids from the
-- party table.
--
-- Returns true when the mob is claimed by a member of our group.
local function _ally_id_set()
    -- Build a set of player ids for self + party + alliance. Cheap to
    -- rebuild per call (party is small, <=18) and always current — no
    -- stale-cache risk if members join/leave mid-session.
    local ids = {}
    local me = windower.ffxi.get_player()
    if me and me.id then ids[me.id] = true end
    local party = windower.ffxi.get_party()
    if party then
        for slot, m in pairs(party) do
            if type(slot) == 'string' and type(m) == 'table'
               and m.mob and m.mob.id then
                ids[m.mob.id] = true
            end
        end
    end
    return ids
end

-- True when `mob` (a mob-array entry) is claimed by our group. A mob
-- with claim_id == 0 is unclaimed → passive (not ours yet). A mob
-- claimed by an id outside our group → passive (someone else's).
local function _mob_is_engaged(mob)
    if not mob then return false end
    local claim = mob.claim_id or 0
    if claim == 0 then
        return false
    end
    local allies = _ally_id_set()
    return allies[claim] == true
end

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

    -- Another player's trust or pet. Trusts/pets are is_npc combat
    -- entities; the party_pet walk above only matched OUR party's pets,
    -- so a trust/pet belonging to a nearby OTHER player would otherwise
    -- fall through to the spawn_type tail below and be tagged 'npc' or
    -- 'mob' — which the routing shows by default (no 'npc' override),
    -- cluttering the feed with other groups' buffs/fights. Tag them
    -- 'other_pet' so routing can filter them.
    --
    -- Detection signals, in priority order:
    --   1. OWNERSHIP: owner_id / master_id set to a non-self, non-zero
    --      player id. This is the AUTHORITATIVE "this is somebody's
    --      pet/trust" marker and works regardless of spawn_type — which
    --      matters because a nearby OTHER player's trust often comes back
    --      from get_mob_by_id with a partial/odd spawn_type (not the
    --      clean 14) when it's at render-edge distance. The earlier fix
    --      that only checked spawn_type==14 missed exactly those, so
    --      their AoE buffs (Reprisal/Phalanx/Ballad on another party)
    --      still leaked into Battle via the 'npc' fallback.
    --   2. spawn_type 14 (alter ego / trust): unambiguous trust marker
    --      even when owner_id isn't populated.
    --   3. spawn_type 2 (avatar/wyvern/automaton/charmed pet) WITH an
    --      owner — covered by signal 1, listed for clarity.
    do
        local omob = windower.ffxi.get_mob_by_id(id)
        if omob and omob.is_npc then
            local owner = omob.owner_id or omob.master_id
            local has_owner = owner and owner ~= 0 and owner ~= id
            if has_owner or omob.spawn_type == 14 then
                return 'other_pet', omob.name, nil
            end
        end
    end

    -- Not self, pet, party, alliance, or another player's pet/trust.
    -- Use the mob array to classify as mob / npc / other-player.
    -- get_mob_by_id may return nil for entities outside the local mob
    -- array (distant players, etc.) — in that case we return 'other'
    -- with no name; the caller will usually have a name from elsewhere
    -- (chat text contains it).
    local mob = windower.ffxi.get_mob_by_id(id)
    if not mob then
        return 'other', nil, nil
    end

    -- PC (another player not in our group). spawn_type 1, or any
    -- entity the server doesn't flag as NPC.
    if mob.spawn_type == 1 or not mob.is_npc then
        return 'other', mob.name, nil
    end

    -- Server-controlled entity (is_npc). Distinguish friendly NPC from
    -- monster, then for monsters split engaged-vs-passive.
    --
    -- Backstop for un-owned player-combat entities: an is_npc entity
    -- with a HIGH id (>= 0x1000000) is in the player/alter-ego range.
    -- HOWEVER, modern high-tier monsters (Apex mobs, Sortie/Odyssey/
    -- Aminon NMs, etc.) ALSO use the high-id range — so this backstop
    -- must NOT blindly tag every high-id is_npc as 'other_pet', or the
    -- actual monster you're fighting gets hidden (no mob actions in chat,
    -- mob-buff routing broken). The reliable discriminator is CLAIM: a
    -- real monster your group is fighting is claimed by a group member
    -- (_mob_is_engaged true); another player's trust/pet never claims
    -- YOUR mob. So check engagement FIRST: if our group has claim, it's
    -- the mob we're fighting → 'mob_engaged'. Only un-engaged high-id
    -- is_npc entities (someone else's trust/pet whose owner_id wasn't
    -- populated) fall through to the 'other_pet' backstop below.
    if id >= 0x1000000 then
        if _mob_is_engaged(mob) then
            return 'mob_engaged', mob.name, nil
        end
        -- High-id, is_npc, NOT claimed by our group. Could be another
        -- player's trust/pet OR a passive/unclaimed high-tier monster.
        -- A monster (zone-local index <= 2047) that's simply unclaimed
        -- should be 'mob_passive' (hidden by default but still a MOB),
        -- not 'other_pet'. Reserve 'other_pet' for non-monster-index
        -- entities (actual alter-egos/pets live above the mob index).
        if (id % 4096) <= 2047 then
            return 'mob_passive', mob.name, nil
        end
        return 'other_pet', mob.name, nil
    end

    -- mob vs npc by zone-local index: the GearSwap/Windower convention
    -- is that friendly NPCs (vendors, quest-givers, moogles) live at
    -- zone-local index > 2047 while enemy monsters live at 0..2047. The
    -- mod-4096 strips the zone byte. This is more reliable than
    -- spawn_type alone (mobs use several spawn_type values; the old
    -- spawn_type==16-only check mis-tagged many real mobs as 'npc').
    -- Matches OmniWatch.lua ~13394.
    local is_monster = (id % 4096) <= 2047
    if not is_monster then
        return 'npc', mob.name, nil
    end

    -- Monster. Engaged (our group has claim) → 'mob_engaged' so the
    -- user's mob routing applies to the fight they're in. Passive
    -- (another party's claim, or unclaimed) → 'mob_passive', a distinct
    -- class the routing hides by default — this is the engaged-vs-
    -- passive filter that in-game/BattleMod expose. Both carry the mob
    -- name so the line still renders if a tab is configured to show it.
    --
    -- Back-compat: the Python routing treats the legacy 'mob' actor key
    -- as an alias for 'mob_engaged', so an existing routing config that
    -- still uses 'mob' keeps applying to engaged monsters with no
    -- migration. New GUI edits write the explicit classes.
    if _mob_is_engaged(mob) then
        return 'mob_engaged', mob.name, nil
    end
    return 'mob_passive', mob.name, nil
end

return M