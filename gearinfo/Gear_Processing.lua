-- ── parse_augment_line ──────────────────────────────────────────────────
-- Parser for single augment strings as they appear in Misc_augments.lua
-- (JSE necks) and Unity_rank[id].augments (HQ Unity variants). Each
-- input is ONE augment line like "STR+15", "Magic Acc.+20", "Double
-- Attack+5", "Damage taken-5%", "Pet: Double Attack+15", etc. The
-- function PARSES the line and ADDS the resulting stats into
-- target_item — which is the edited_item table being built up by
-- find_all_values.
--
-- Why a dedicated parser instead of desypher_description?
--   • desypher_description's patterns use the bare stat name as anchor:
--     "(Attack):?%s?([+-]?%d+)". Feeding "Double Attack+5" to that
--     produces a SPURIOUS Attack=+5 match (the substring "Attack+5"
--     inside "Double Attack+5"). That's harmless for full description
--     text where surrounding context disambiguates, but ruinous when
--     parsing standalone augment lines.
--   • desypher_description's valid_strings list is incomplete for the
--     stat names that JSE necks use: 'Double Attack', 'Triple Attack',
--     'Critical Hit Rate', 'Store TP' (without quotes), 'Magic Damage',
--     'Magic Attack Bonus', 'Magic Burst Damage', etc. The matcher
--     drops these silently.
--
-- The parser here uses ANCHORED matching (^name±N$) so substrings
-- don't false-positive, and has its own explicit name → stat_key map
-- so JSE-specific stat names are recognized and routed to the right
-- key in edited_item.
--
-- Stats not in the recognized list ARE silently dropped, same as
-- desypher_description. Most unrecognized augments are panel-display
-- stats (Kick Attacks, Physical Damage Limit, Pet: X, Avatar: X,
-- Wyvern: X) that aren't tracked by get_equip_stats's stat_table
-- anyway — dropping them at this stage is no worse than the previous
-- state where they didn't reach Gear_info at all.
local _AUGMENT_NAME_TO_KEY = {
	-- Primary stats
	['STR']  = 'STR', ['DEX'] = 'DEX', ['VIT'] = 'VIT',
	['AGI']  = 'AGI', ['INT'] = 'INT', ['MND'] = 'MND',
	['CHR']  = 'CHR',
	-- Vitals
	['HP']   = 'HP',  ['MP']  = 'MP',
	-- Combat
	['Accuracy']        = 'Accuracy',
	['Attack']          = 'Attack',
	['Ranged Accuracy'] = 'Ranged Accuracy',
	['Ranged Attack']   = 'Ranged Attack',
	['Evasion']         = 'Evasion',
	['Magic Accuracy']  = 'Magic Accuracy',
	['Mag. Acc.']       = 'Magic Accuracy',
	['Magic Atk. Bonus']     = 'Magic Atk. Bonus',
	['Mag. Atk. Bns.']       = 'Magic Atk. Bonus',
	['Magic Attack Bonus']   = 'Magic Atk. Bonus',
	['Magic Evasion']        = 'Magic Evasion',
	['Magic Def. Bonus']     = 'Magic Def. Bonus',
	['DEF']    = 'DEF',
	-- Multi-hit modifiers (the false-positive prone ones — anchored
	-- match means "Double Attack" only matches the whole augment name,
	-- not "Attack" inside it)
	['Double Attack']     = 'Double Attack',
	['Triple Attack']     = 'Triple Attack',
	['Quadruple Attack']  = 'Quadruple Attack',
	['Critical Hit Rate'] = 'Critical hit rate',
	['Critical Hit Damage'] = 'Critical hit damage',
	['Subtle Blow']       = 'Subtle Blow',
	-- TP/casting modifiers
	['Store TP']  = 'Store TP',
	['Fast Cast'] = 'Fast Cast',
	['Dual Wield'] = 'Dual Wield',
	-- DT family
	['Damage taken']           = 'DT',
	['Physical damage taken']  = 'PDT',
	['Magic damage taken']     = 'MDT',
	['Breath damage taken']    = 'BDT',
}

function parse_augment_line(target_item, line)
	if not line or line == '' then return end
	-- Strip "Pet: " / "Wyvern: " / "Avatar: " / "Luopan: " prefixes —
	-- those are pet stats and shouldn't roll into the player's
	-- edited_item. (We could route them to a sub-table later, but for
	-- now they're dropped, same as the original Pet:-stripping in
	-- check_for_augments.)
	if line:contains('Pet:') or line:contains('Wyvern:')
	   or line:contains('Avatar:') or line:contains('Luopan:')
	   or line:contains('Automaton:') then
		return
	end
	-- Match: anchored start, allow whitespace, name, optional colon,
	-- optional whitespace, signed integer, optional % suffix, then
	-- end-or-whitespace. The anchored ^ prevents "Attack" matching
	-- inside "Double Attack".
	for name, stat_key in pairs(_AUGMENT_NAME_TO_KEY) do
		-- Lua pattern: ^<name>:? ?[+-]?N%?$ — escape pattern magic
		-- chars in name with a manual gsub (only "." is magic in our
		-- stat names; brackets/parens don't appear).
		local pat_name = name:gsub('([%.%-%+%*%?%[%]%(%)%%])', '%%%1')
		local match_val = line:match('^%s*' .. pat_name .. '%s*:?%s*([+%-]?%d+)%%?%s*$')
		if match_val then
			local n = tonumber(match_val)
			if n then
				if target_item[stat_key] then
					target_item[stat_key] = target_item[stat_key] + n
				else
					target_item[stat_key] = n
				end
			end
			return  -- found a match; don't try other names
		end
	end
	-- No recognized stat name. Silently drop — same as desypher_description
	-- does for unknown lines. The line might be a pet/avatar prefix we
	-- didn't catch, an unrecognized stat name, or whitespace.
end

function find_all_values(item)
	-- notice(item.id)
	local temp = check_for_augments(item)
	local augs = Extdata.decode(item).augments
	
	local item = res.items:with('id', item.id)
	
	if item.flags:contains('Equippable') then
	
		if res.item_descriptions[item.id] then
			item.discription = string.gsub(res.item_descriptions:with('id', item.id ).en, '\n', ' ') 
		else
			item.discription = 'none'
		end
		
		descript_table = T{}
		descript_table = desypher_description(item.discription, item)
		
		item.defined_job = T{}
		
		for k, v in pairs(item.jobs) do
			item.defined_job[k] = res.jobs:with('id', k ).ens	
		end
		
		item.defined_slots = T{}
		for k, v in pairs(item.slots) do
			item.defined_slots[k] = res.slots:with('id', k ).en	
		end
	
		local edited_item = T{en=item.en, id=item.id, category=item.category , discription = item.discription, jobs = item.defined_job, slots = item.defined_slots}
		
			--item_level
		if item.item_level then
			edited_item.item_level = item.item_level
		end
		
		if augs then edited_item.augments = augs end
		
		for k, v in pairs(descript_table) do
			edited_item[k] = v
		end
		
		-- Check "Enhances \"Dual Wield\" effect" Gear for value
		for k, v in pairs(DW_Gear) do
			if item.id == k then
				if  edited_item['Dual Wield'] then
					edited_item['Dual Wield'] = edited_item['Dual Wield'] + v["Dual Wield"]
				else
					edited_item['Dual Wield'] = v["Dual Wield"]
				end
			end
		end
		
		-- Check Unity gear for stat and value.
		for k, v in pairs(Unity_rank) do
			if item.id == k then
				value = math.floor(((v['rank']['max'] - v['rank']['min'])/ 11) * (11 - (settings.player.rank -1))) + v['rank']['min']
				if edited_item[v['Unity Ranking']] then
					-- edited_item[v['Unity Ranking']] = edited_item[v['Unity Ranking']] + v.rank[settings.rank]
					edited_item[v['Unity Ranking']] = edited_item[v['Unity Ranking']] + value
					edited_item['Unity Ranking Bonus Applied'] = v['Unity Ranking'] .. ' + ' ..tostring(value)
				else
					-- edited_item[v['Unity Ranking']] = v['rank'][settings.rank]
					edited_item[v['Unity Ranking']] = value
					edited_item['Unity Ranking Bonus Applied'] = v['Unity Ranking'] .. ' + ' ..tostring(value)
				end 
				
				-- OmniWatch patch (2026-05-16): Unity_rank[id].augments is the
				-- ADDITIONAL static augment list that the +1/HQ variants of
				-- Unity items carry on top of the rank-scaled main stat
				-- (e.g. Comeuppances +1 has the Accuracy roll above PLUS a
				-- fixed "DEX+20, Accuracy+40, ..." block). The original
				-- GearInfo code reads only v['Unity Ranking'] (the main
				-- stat handled above) and silently ignores v['augments'],
				-- which meant the HQ variants were under-applied. Walk the
				-- augment list through parse_augment_line so the stats
				-- land in the same edited_item table; from there they flow
				-- through get_equip_stats into Gear_info naturally.
				if v.augments then
					for _, aug_line in ipairs(v.augments) do
						parse_augment_line(edited_item, aug_line)
					end
				end
			end
		end
		
		-- OmniWatch patch (2026-05-16): JSE neck augments (Reisenjima/
		-- Sortie pieces in Misc_augments.lua / ow_unity_augments). These
		-- are items whose max-rank augments aren't carried in the in-game
		-- item description text, so desypher_description on item.discription
		-- doesn't catch them. The Misc_augments.lua table holds the literal
		-- "Stat+N" strings per item_id; we feed each one through
		-- parse_augment_line and merge into edited_item the same way
		-- extdata augments do (see check_for_augments path above).
		--
		-- ow_unity_augments is loaded by gearinfo/_loader.lua from
		-- res/Misc_augments.lua. If load failed it's an empty table, so
		-- the pairs() walk below is a no-op — safe.
		if ow_unity_augments and ow_unity_augments[item.id] then
			for _, aug_line in ipairs(ow_unity_augments[item.id]) do
				parse_augment_line(edited_item, aug_line)
			end
		end
		
		for k, v in pairs(Set_bonus_by_item_id) do
			if item.id == k then
				edited_item['Set Bonus'] = {["set id"] = v["set id"], ["bonus"] = v["bonus"] }
			end		
		end
		
		if item.category == 'Weapon' then
			for k,v in pairs(item) do
				-- if k == 'delay' then	
					-- edited_item[k] = tonumber(v)
				-- end
				if k == 'skill' then
					local skill = res.skills:with('id', v ).en
					edited_item[k] = skill
				end
			end
		end
		
		if temp then
			local temp_augments = T{}
			for k, v in pairs(temp) do
				temp_augments[k] = v
			end
			
			for k, v in pairs(temp_augments) do
				if edited_item[k] then
					edited_item[k] = edited_item[k] + v
				else
					edited_item[k] = v
				end
			end
		end

		return edited_item
	end
		
end

function check_for_augments(item)
	
	local augs = Extdata.decode(item).augments
	local item_t = res.items:with('id', item.id)
	local temp = T{}
	if augs then
		-- OmniWatch patch: REMA / Dynamis Divergence weapons return opaque
		-- strings like "Path: A", "Rank: 15", "Damage: 0", etc. via
		-- extdata.decode. desypher_description can't extract stats from
		-- these — "Path" is not a valid stat name and the line silently
		-- drops. We detect path strings (case-insensitive "path: X") and
		-- redirect through OmniWatch's ow_path_augments table, which
		-- holds the R15 max-rank stat list per item_id × path key (loaded
		-- from gearinfo/res/DREMA_augments.lua via the OmniWatch loader).
		-- Each resolved stat line is then fed through desypher_description
		-- the same way a normal augment string would be.
		--
		-- Failure mode: if ow_path_augments lacks an entry for this
		-- (item_id, path), the path string falls through untouched —
		-- desypher_description discards it, no stats added. The behavior
		-- matches the pre-patch state for unrecognized REMA, so adding
		-- entries to DREMA_augments.lua is purely additive.
		for k,v in pairs(augs) do
			
			if v:contains('Pet:') or v:contains('Wyvern:') or v:contains('Avatar:') then
			
			else
				local resolved_lines = nil
				local path_match = v:lower():match('^%s*path:%s*([a-z])%s*$')
				if path_match and ow_path_augments
				   and ow_path_augments[item.id] then
					local lookup_key = 'path: ' .. path_match
					resolved_lines = ow_path_augments[item.id][lookup_key]
				end
				
				if resolved_lines then
					-- Walk the resolved stat list through the same
					-- desypher_description pipeline so all the normal
					-- abbreviation rewrites (Ranged Acc / Mag. Acc /
					-- Magic Atk. Bonus / etc.) apply.
					for _, line in ipairs(resolved_lines) do
						for i, j in pairs(desypher_description(line, item_t)) do
							if temp[i] then
								temp[i] = temp[i] + j
							else
								temp[i] = j
							end
						end
					end
				else
					for i, j in pairs(desypher_description(v, item_t)) do
						if temp[i] then
							temp[i] = temp[i] + j
						else
							temp[i] = j
						end
					end
				end
			end
		end
		return temp
	else
		return nil
	end
	
end

function desypher_description(discription_string, item_t)
	
	-- Diagnostic: trace every call. _ow_gear_trace toggled via
	-- //ow geartrace. Prints first 100 chars of the input so we can
	-- correlate which item we're parsing. Item name resolved from
	-- item_t when available.
	if _ow_gear_trace then
		local item_name = '?'
		if item_t then
			item_name = item_t.en or item_t.enl
			           or ('id:' .. tostring(item_t.id))
		end
		local preview = tostring(discription_string or ''):sub(1, 100)
		windower.add_to_chat(207, string.format(
			'[OW gear-trace] desypher: %s | %s', item_name, preview))
	end
	
	-- Citizen of <Nation>: conditional clauses. Items like Republican
	-- Platinum Medal carry stats gated on conquest allegiance:
	--   Citizen of Bastok: "Regain"+2
	-- Apply the bonus only when player.nation matches the clause's
	-- nation. Otherwise strip the whole clause so the stat doesn't
	-- get credited.
	--
	-- windower.ffxi.get_player().nation values:
	--   0 = San d'Oria
	--   1 = Bastok
	--   2 = Windurst
	local player_nation = nil
	if windower and windower.ffxi and windower.ffxi.get_player then
		local _p = windower.ffxi.get_player()
		player_nation = _p and _p.nation
	end
	local NATION_NAME = {
		[0] = "San d'Oria",
		[1] = "Bastok",
		[2] = "Windurst",
	}
	-- Each clause typically ends at a newline. Match the literal
	-- "Citizen of <nation>:" then capture everything up to newline
	-- (or end of string if last line). Process each nation in turn.
	for nation_id, nation_name in pairs(NATION_NAME) do
		-- Build the pattern carefully — San d'Oria contains an
		-- apostrophe; Lua patterns treat ' as literal so this works.
		local prefix = "Citizen of " .. nation_name .. ":%s*"
		if player_nation == nation_id then
			-- Player is citizen of this nation — strip just the prefix
			-- so the stat (which follows it on the same line) parses
			-- through the normal pipeline.
			discription_string = string.gsub(discription_string, prefix, "")
		else
			-- Not this nation — strip the prefix AND the rest of the
			-- line so the stat is excluded. The "[^\n]*" captures
			-- everything up to but not including the next newline.
			discription_string = string.gsub(discription_string,
				prefix .. "[^\n]*", "")
		end
	end

	-- string that need modifying to stop clashing
	discription_string = string.gsub(discription_string, 'Ranged Accuracy%s?', 'Ranged_accuracy') 
	discription_string = string.gsub(discription_string, 'Rng.%s?Acc.%s?', 'Ranged_accuracy')  
	-- R. Acc. / R. Accuracy abbreviation. Used on Raetic series and
	-- some other newer ilvl pieces. Order matters: longer first so
	-- "R. Accuracy" matches before just "R. Acc."
	local _n_racc_full
	discription_string, _n_racc_full = string.gsub(discription_string, 'R%.%s?Accuracy%s?', 'Ranged_accuracy')
	if _n_racc_full > 0 and _ow_gear_trace then
		windower.add_to_chat(207, string.format(
			'[OW gear-trace] R. Accuracy → Ranged_accuracy fired %d time(s)', _n_racc_full))
	end
	discription_string = string.gsub(discription_string, 'R%.%s?Acc%.%s?', 'Ranged_accuracy')
	discription_string = string.gsub(discription_string, 'Ranged Attack%s?', 'Ranged_attack') 
	discription_string = string.gsub(discription_string, 'Rng.%s?Atk.%s?', 'Ranged_attack') 
	discription_string = string.gsub(discription_string, 'R%.%s?Attack%s?', 'Ranged_attack')
	discription_string = string.gsub(discription_string, 'R%.%s?Atk%.%s?', 'Ranged_attack')
	
	discription_string = string.gsub(discription_string, 'Magic Accuracy%s?', 'Magic_accuracy')
	discription_string = string.gsub(discription_string, 'Mag.%s?Acc.%s?', 'Magic_accuracy') 	
	discription_string = string.gsub(discription_string, 'Magic Acc.%s?', 'Magic_accuracy') 
	-- M. Acc. / M. Accuracy abbreviation. Used on Raetic series and
	-- similar newer ilvl pieces. Parallel to the R. Accuracy patterns
	-- above. Longer pattern first so "M. Accuracy" matches before just
	-- "M. Acc."
	discription_string = string.gsub(discription_string, 'M%.%s?Accuracy%s?', 'Magic_accuracy')
	discription_string = string.gsub(discription_string, 'M%.%s?Acc%.%s?', 'Magic_accuracy')
	-- M. Atk. / M. Attack — parallel for Magic Attack Bonus.
	discription_string = string.gsub(discription_string, 'M%.%s?Atk%.?%s?Bns%.%s?', 'Magic Atk. Bonus')
	discription_string = string.gsub(discription_string, 'M%.%s?Atk%.%s?', 'Magic Atk. Bonus')
	
	-- OmniWatch patch: 'Weapon Skill Accuracy', 'Weapon Skill Damage',
	-- 'Weapon Skill Attack' etc. need rewriting BEFORE the bare
	-- 'Accuracy' / 'Attack' patterns run below. Otherwise the unanchored
	-- gmatch in the main loop picks up the "Accuracy+10" substring of
	-- "Weapon Skill Accuracy+10" and adds +10 to Accuracy, which is
	-- wrong (WS Accuracy applies only during weapon skills, not to the
	-- general acc total). Without these rewrites Cooper saw a +10 WS
	-- Accuracy ring inflating his idle Accuracy by 10.
	--
	-- We rewrite to underscore variants so the bare-stat pattern
	-- doesn't match them. The rewritten name is then not in
	-- valid_strings, so it's silently dropped (same outcome as if
	-- desypher hadn't picked it up at all — which is the correct
	-- behavior for now, since panel stat_table doesn't track WS-
	-- conditional stats separately). If we ever want to display
	-- "WS Acc +N" or feed it into a weapon-skill-specific accuracy
	-- helper, add 'Weapon_skill_accuracy' to valid_strings + a
	-- temp_key mapping, and the parse will resume populating it.
	--
	-- Same family: Weapon Skill DEX is already handled below (line
	-- ~372 in the original layout) via WS_dex. These rewrites
	-- extend that pattern to the other WS-conditional augments.
	discription_string = string.gsub(discription_string, 'Weapon [Ss]kill Accuracy%s?', 'WS_accuracy_aug')
	discription_string = string.gsub(discription_string, 'Weapon [Ss]kill Damage%s?',   'WS_damage_aug')
	discription_string = string.gsub(discription_string, 'Weapon [Ss]kill Attack%s?',   'WS_attack_aug')
	
	discription_string = string.gsub(discription_string, '\"Magic Atk. Bonus\"', 'Magic Atk. Bonus' )
	discription_string = string.gsub(discription_string, '\"Mag.%s?Atk.%s?Bns.\"', 'Magic Atk. Bonus' ) 
	
	discription_string = string.gsub(discription_string, 'Magic Evasion', 'Magic_evasion' )
	-- OmniWatch patch: Nyame and other ilvl pieces print "Magic Eva.+150"
	-- with a period. Normalize before the bare "Eva." substitution so
	-- the longer form wins (otherwise "Eva.+150" would gsub first and
	-- leave a "Magic Evasion+150" that doesn't match valid_strings'
	-- Magic_evasion key — same kind of silent drop as plain Eva.).
	discription_string = string.gsub(discription_string, 'Magic Eva%.%s?', 'Magic_evasion')
	discription_string = string.gsub(discription_string, 'Mag%.%s?Eva%.%s?', 'Magic_evasion')
	discription_string = string.gsub(discription_string, '\"Magic Def. Bonus\"', 'Magic Def. Bonus' )
	
	-- OmniWatch patch: Nyame and several other ilvl pieces print
	-- "Eva.+119" with a period instead of "Evasion+119". The original
	-- valid_strings list only matches 'Evasion', so abbreviated lines
	-- silently dropped — verified missing on Nyame Sollerets (Eva.+119
	-- not picked up). Substitute "Eva.+/-N" → "Evasion+/-N". The lookahead
	-- on +/- avoids touching "Eva." mid-sentence (no real cases exist
	-- in item text but the guard is cheap). The Magic Eva. and Mag. Eva.
	-- substitutions above run first so "Magic Eva." won't accidentally
	-- become "Magic Evasion" (which doesn't match valid_strings anyway).
	discription_string = string.gsub(discription_string, 'Eva%.([%+%-])', 'Evasion%1')
	
	discription_string = string.gsub(discription_string, 'Crit. hit damage', 'Critical hit damage' )
	discription_string = string.gsub(discription_string, 'Crit. hit rate', 'Critical hit rate' )

	discription_string = string.gsub(discription_string, 'Physical damage taken II', 'PDT_2' )
	discription_string = string.gsub(discription_string, 'Physical damage taken', 'PDT' )
	discription_string = string.gsub(discription_string, 'Breath damage taken', 'BDT' )
	discription_string = string.gsub(discription_string, 'Breath dmg. taken', 'BDT' )
	discription_string = string.gsub(discription_string, 'Magic damage taken II', 'MDT_2' )
	discription_string = string.gsub(discription_string, 'Magic damage taken', 'MDT' )
	discription_string = string.gsub(discription_string, 'Phys. dmg. taken', 'PDT' )
	discription_string = string.gsub(discription_string, 'Magic dmg. taken', 'MDT' )
	discription_string = string.gsub(discription_string, 'Damage taken', 'D_T' )
	
	discription_string = string.gsub(discription_string, 'Weapon skill DEX', 'WS_dex' )
	
	discription_string = string.gsub(discription_string,  "Great Axe skill",  "Great axe skill")
	discription_string = string.gsub(discription_string,  "Great Katana skill",  "Great katana skill")
	discription_string = string.gsub(discription_string,  "Great Sword skill",  "Great sword skill")
	
	local str_table = ''
	
	if discription_string:contains('Pet:') then
		str_table = discription_string:psplit("Pet:")
		discription_string = str_table[1]
	elseif discription_string:contains('Wyvern:') then
		str_table = discription_string:psplit("Wyvern:")
		discription_string = str_table[1]
	elseif discription_string:contains('Avatar:') then
		str_table = discription_string:psplit("Avatar:")
		discription_string = str_table[1]
	elseif discription_string:contains('Luopan:') then
		str_table = discription_string:psplit("Luopan:")
		discription_string = str_table[1]
	elseif discription_string:contains('Latent effect:') then
		str_table = discription_string:psplit("Latent effect:")
		discription_string = str_table[1]
	elseif discription_string:contains('Unity Ranking:') then
		str_table = discription_string:psplit("Unity Ranking:")
		discription_string = str_table[1]
	end

	local valid_strings = L{'Delay','DEF','HP','MP','STR','DEX','VIT','AGI','INT','MND','CHR',
								'Accuracy','Acc.','Attack','Atk.',
								'Ranged_accuracy', 'Ranged_attack',
								'Magic_accuracy', 'Magic Atk. Bonus',
								'Haste','\"Slow\"','\"Store TP\"','\"Dual Wield\"','\"Fast Cast\"','\"Martial Arts\"',
								'\"Regain\"',
								'DMG','PDT','MDT','BDT','D_T','MDT_2','PDT_2',
								'Evasion',
								'Critical hit damage' ,'Critical hit rate', 
								"Hand%-to%-Hand skill", "Dagger skill", "Sword skill", "Great sword skill", "Axe skill", "Great axe skill",  "Scythe skill", "Polearm skill", 
								"Katana skill", "Great katana skill", "Club skill",  "Staff skill", "Archery skill", "Marksmanship skill" , "Throwing skill","Guarding skill","Evasion skill","Shield skill","Parrying skill",
								"Divine Magic skill","Healing Magic skill","Enhancing Magic skill","Enfeebling Magic skill","Elemental Magic skill","Dark Magic skill","Summoning Magic skill","Ninjutsu skill","Singing skill",
								"Stringed Instrument skill","Wind Instrument skill","Blue Magic skill","Geomancy skill","Handbell skill",
								"Phalanx",'All magic skills','All skills','Combat skills','Magic skills',
								}
	
	local temp_table = T{}
	local temp_key = { 
		['Delay'] = 'delay',
		["Acc."] = "Accuracy",
		["Atk."] = 'Attack',
		['\"Slow\"'] = 'Slow',
		['\"Store TP\"'] = 'Store TP', 
		['\"Dual Wield\"'] = 'Dual Wield' ,
		['\"Fast Cast\"'] = 'Fast Cast' ,
		['\"Regain\"'] = 'Regain',
		['Magic_accuracy'] = 'Magic Accuracy' , 
		['Ranged_accuracy'] =  'Ranged Accuracy' ,
		['Ranged_attack'] =  'Ranged Attack' ,
		['Magic_evasion'] = 'Magic Evasion',
		["Great axe skill"] = "Great Axe skill" ,
		["Great katana skill"] = "Great Katana skill",
		["Great sword skill"] = "Great Sword skill",
		['DMG'] = 'damage',
		['D_T'] = 'DT',
		['MDT_2'] = 'MDT2',
		['PDT_2'] = 'PDT2',
		['\"Martial Arts\"'] = 'Martial Arts',
		['WS_dex'] = 'Weapon skill DEX',
		['\"Quadruple Attack\"'] = 'Quadruple Attack',
		['\"Triple Attack\"'] = 'Triple Attack',
		['\"Double Attack\"'] = 'Double Attack',
	}
	
	for k, v in pairs(valid_strings) do
		-- v = DEF etc
		pattern = "("..v.."):?%s?([+-]?%d+)"
		for key , val in discription_string:gmatch(pattern) do
			
			if temp_key[key] then
				temp_table[temp_key[key]] = tonumber(val)
			else
				temp_table[key] = tonumber(val)	
			end
			-- if item_t then
				-- if item_t.id == 20540 then
					-- notice('('..discription_string .. ') '..key .. ' ' ..val)
				-- end
			-- end
		end
	end
	-- Diagnostic: dump the parsed temp_table for items whose preview
	-- string contained R. or Ranged. Lets us see whether the main
	-- gmatch loop above actually pulled "Ranged Accuracy" out of the
	-- substituted string, or if it fell through silently.
	if _ow_gear_trace and (discription_string:find('Ranged_')
	                       or discription_string:find('R%. ')) then
		local parts = {}
		for k_, v_ in pairs(temp_table) do
			parts[#parts + 1] = string.format('%s=%s', tostring(k_), tostring(v_))
		end
		windower.add_to_chat(207, '[OW gear-trace] temp_table: '
		                          .. table.concat(parts, ', '))
	end
	return temp_table
end

function get_equip_stats(equipment_table)

	-- OmniWatch patch (2026-05-18): the stock GearInfo init was missing
	-- several stat keys. The gate at line ~520 (`if stat_table[key]`)
	-- treats uninitialized keys as falsy and SILENTLY DROPS any
	-- equipped contribution. So an item with "Magic Accuracy+40"
	-- (e.g. Cooper's Ternion Dagger +1's Unity augment) had its
	-- Magic Accuracy contribution discarded entirely — the
	-- find_all_values pipeline parsed it correctly into the slot,
	-- but get_equip_stats then dropped it because the key was nil.
	-- Adding initial zero values for all stats the parser can
	-- produce (per _AUGMENT_NAME_TO_KEY at top of file) ensures the
	-- gate sees them as truthy.
	local stat_table = { ['Haste'] = 0, ['Slow'] = 0, ['Dual Wield'] = 0, ['Store TP'] = 0, ['Accuracy'] = 0, ['Attack'] = 0, ['Ranged Accuracy'] = 0, ['Ranged Attack'] = 0,
									['Evasion'] = 0,

									['DT'] = 0, ['PDT'] = 0, ['PDT2'] = 0, ['MDT'] = 0, ['MDT2'] = 0, ['BDT'] = 0,
									['DEF'] = 0,
							 
									["MND"]=0, ["AGI"]=0, ["DEX"]=0, ["VIT"]=0, ["STR"]=0, ["INT"]=0,  ["CHR"]=0, 
							 
									["Hand-to-Hand skill"]=0, ["Dagger skill"]=0, ["Sword skill"]=0, ["Great Sword skill"]=0, ["Axe skill"]=0, ["Great Axe skill"]=0, ["Scythe skill"]=0, ["Polearm skill"]=0, 
									["Katana skill"]=0, ["Great Katana skill"]=0,["Club skill"]=0,["Staff skill"]=0,["Archery skill"]=0,["Marksmanship skill"]=0,["Throwing skill"]=0,['Combat skills']=0,
									
									['Evasion skill'] = 0,

									-- OmniWatch additions: previously missing — see comment
									-- above. Keys must match _AUGMENT_NAME_TO_KEY's stat_key
									-- values so parsed augments land in cells the get_equip_stats
									-- loop will recognize.
									['Magic Accuracy']   = 0,
									['Magic Atk. Bonus'] = 0,
									['Magic Evasion']    = 0,
									['Magic Def. Bonus'] = 0,
									['HP']               = 0,
									['MP']               = 0,
									['Double Attack']    = 0,
									['Triple Attack']    = 0,
									['Quadruple Attack'] = 0,
									['Critical hit rate']   = 0,
									['Critical hit damage'] = 0,
									['Subtle Blow']      = 0,
									['Fast Cast']        = 0,
									['Regain']           = 0,

									['main'] = {['skill'] = '', value = 0}, ['sub'] = {['skill'] = '', value = 0}, ['range'] = {['skill'] = '', value = 0}, ['ammo'] = {['skill'] = '', value = 0},
								}
								
	local melee_skills = L{"Hand-to-Hand skill", "Dagger skill", "Sword skill", "Great Sword skill", "Axe skill", "Great Axe skill", "Scythe skill", "Polearm skill", "Katana skill", "Great Katana skill", "Club skill", "Staff skill"}
	local ranged_skills = L{"Archery skill", "Marksmanship skill", "Throwing skill"}
							
	local set_bonus = {}
	
	if type(equipment_table) ~= 'table' or equipment_table == nil then
		error('get_equip_stats() function went wrong')
		return stat_table
	else	
		for equip_slot, equipped_item in pairs(equipment_table) do
			--log(equip_slot)
			for key, value in pairs(equipped_item) do
				--if equip_slot == 'main' then log(key) end
				if stat_table[key] or (key == 'skill' and stat_table[value..' skill']) then
					if equipped_item["category"]=="Weapon" then
						if equipped_item['skill'] then
							stat_table[equip_slot]['skill'] =  equipped_item['skill']
							if 	equipped_item[equipped_item['skill'] ..' skill'] then
								stat_table[equip_slot].value =  equipped_item[equipped_item['skill'] ..' skill']
							end
						end
						if not melee_skills:contains(key) and not ranged_skills:contains(key) and not (key == 'skill' and stat_table[value..' skill']) then
							if key == 'Haste' then
								stat_table['Haste'] = stat_table['Haste'] + math.floor(value / 100 * 1024)
							elseif key == 'Slow' then
								stat_table['Haste'] = stat_table['Haste'] - math.floor(value / 100 * 1024)
							elseif key == 'Combat skills' then
								-- OmniWatch patch (2026-05-09): the original
								-- code added 'Combat skills +N' to all four
								-- weapon-skill slots (main, sub, range, ammo).
								-- That double-counted with player.combat_skills
								-- which already reflects the gear bonus, causing
								-- inflated aux/ranged Acc and Att on equipment
								-- like Combatant's Torque. Empirically the main
								-- slot is unaffected (compute_player_stats reads
								-- main from a different source) so we only
								-- remove the sub/range/ammo adds; keep main as
								-- the original GearInfo behaviour to avoid any
								-- regression on the primary path.
								stat_table['main'].value = stat_table['main'].value + value
							else
								stat_table[key] = stat_table[key] + value
							end
						end
					else
						if key == 'Haste' then
							stat_table['Haste'] = stat_table['Haste'] + math.floor(value / 100 * 1024)
						elseif key == 'Slow' then
							stat_table['Haste'] = stat_table['Haste'] - math.floor(value / 100 * 1024)
						elseif key == 'Combat skills' then
							-- OmniWatch patch (2026-05-09): see explanation
							-- on the matching block above. Same de-doubling
							-- fix: keep main, drop sub/range/ammo.
							stat_table['main'].value = stat_table['main'].value + value
						else
							stat_table[key] = stat_table[key] + value
						end
					end
				elseif equip_slot == 'main' and equipped_item.en == '' then
					stat_table['main']['skill'] = 'Hand-to-Hand'
				end
				if key == "Set Bonus" then
					if type(value["set id"]) == 'table' then
						for i, j  in pairs(value["set id"]) do
							if set_bonus[j]  then
								set_bonus[j] = set_bonus[j] + 1
							else
								set_bonus[j]  = 1
							end
						end
					else
						if set_bonus[value["set id"]] then
							set_bonus[value["set id"]] = set_bonus[value["set id"]] + 1
						else
							set_bonus[value["set id"]]  = 1
						end
					end
				end
			end
		end

		for k, v in pairs(set_bonus) do
			if v > 1 then
				if v >= Set_bonus_by_Set_ID[k]["minimum peices"] then
					if Set_bonus_by_Set_ID[k]["bonus"][v] then
						for key, value in pairs(Set_bonus_by_Set_ID[k]["bonus"][v]) do
							if stat_table[key] then
								stat_table[key] = stat_table[key] + value
							end
						end
					end
				end
			end
		end
	end
	-- table.vprint(stat_table['main'])
	stat_table['Haste'] = stat_table['Haste'] + manual_ghaste
	stat_table['Dual Wield'] = stat_table['Dual Wield'] + manual_dw
	stat_table['Store TP'] = stat_table['Store TP'] + manual_stp

	return stat_table

end

function get_player_acc(stat_table)
	
	local stat_table = stat_table
	
	-- OmniWatch patch: when no weapon is equipped, FFXI defaults to
	-- Hand-to-Hand for that hand. GearInfo's gear-walk leaves
	-- stat_table['main'].skill empty when bare-handed, so the
	-- player_base_skills loop below never matches and the H2H skill
	-- (152 at lvl 99 with E rank) is silently dropped from the
	-- accuracy/attack calc. Default to "Hand-to-Hand" here so the
	-- skill IS picked up and matches /checkparam.
	if not stat_table['main'].skill or stat_table['main'].skill == '' then
		stat_table['main'].skill = 'Hand-to-Hand'
	end
	if not stat_table['sub'].skill or stat_table['sub'].skill == '' then
		stat_table['sub'].skill = 'Hand-to-Hand'
	end
	
	for skill_name, value in pairs(player_base_skills) do
		--log(stat_table['range'].skill:lower())
		--notice(main_hand.skill)
		--log(skill_name  .. ' | ' .. string.gsub(stat_table['main'].skill:lower(), ' ', '_'))
		if skill_name == string.gsub(stat_table['main'].skill:lower(), ' ', '_') then
			--log(stat_table['main'].value..'  ' ..value.. '  '..stat_table[stat_table['main'].skill .. ' skill'])
			
			stat_table['main'].value = stat_table['main'].value + value  + stat_table[stat_table['main'].skill .. ' skill']
		end
		if skill_name == string.gsub(stat_table['sub'].skill:lower(), ' ', '_') then
			stat_table['sub'].value = stat_table['sub'].value + value + stat_table[stat_table['sub'].skill .. ' skill']
		end
		if skill_name == string.gsub(stat_table['range'].skill:lower(), ' ', '_') and player.equipment.range['damage'] then
			stat_table['range'].value = stat_table['range'].value + value + stat_table[stat_table['range'].skill .. ' skill']
		end
		if skill_name == string.gsub(stat_table['ammo'].skill:lower(), ' ', '_') and player.equipment.ammo['damage'] then
			stat_table['ammo'].value = stat_table['ammo'].value + value + stat_table[stat_table['ammo'].skill .. ' skill']
		end
	end
	
	if player.stats then
		for stat, value in pairs(player.stats) do
			if stat_table[stat] then 
				stat_table[stat] = stat_table[stat] + value 
			end	
		end
	end

	
	-- BLU spell-derived stat bonuses. The helper iterates the equipped
	-- mainjob spell list and looks each ID up in Blu_spells. On non-BLU
	-- jobs that list contains job-specific spells (ninjutsu IDs, white
	-- magic IDs, etc.) that aren't in Blu_spells — pairs(nil) then
	-- crashes the function and acc/att/eva/def fail upstream. Gate the
	-- call to BLU only. Same pattern that get_player_att / _evasion /
	-- _defence already use (they have the same line commented out).
	if player and (player.main_job == 'BLU' or player.sub_job == 'BLU') then
		stat_table = get_blue_mage_stats_from_equipped_spells(stat_table)
	end
	
	local Total_acc = {main = 0, sub = 0, range = 0, ammo = 0, dex = 0, agi = 0}
	local main_acc_skill = acc_from_skill(stat_table['main'].value)
	local sub_acc_skill = acc_from_skill(stat_table['sub'].value )
	local ranged_acc_skill = racc_from_skill(stat_table['range'].value )
	local ammo_acc_skill = racc_from_skill(stat_table['ammo'].value )
	Total_acc.dex = math.floor(stat_table['DEX'] * 0.75)
	Total_acc.agi = math.floor(stat_table['AGI'] * 0.75)
	
	Total_acc.main = main_acc_skill + math.floor((stat_table['DEX']+ Buffs_inform['DEX']) * 0.75) + stat_table['Accuracy'] + get_player_acc_from_job() + Buffs_inform['Accuracy']

	if player.equipment.sub.id ~= 0 and player.equipment.sub.category == 'Weapon' and player.equipment.sub.damage then
		Total_acc.sub = sub_acc_skill + math.floor((stat_table['DEX']+ Buffs_inform['DEX']) * 0.75) + stat_table['Accuracy'] + get_player_acc_from_job() + Buffs_inform['Accuracy']
	else
		Total_acc.sub = 0
	end
	if player.equipment.range.id ~= 0 and player.equipment.range.category == 'Weapon' and player.equipment.range['damage'] then
		Total_acc.range = ranged_acc_skill + math.floor((stat_table['AGI']+ Buffs_inform['AGI']) * 0.75) + stat_table['Ranged Accuracy'] + get_player_acc_from_job() + Buffs_inform['Ranged Accuracy']
	else
		Total_acc.range = 0
	end
	if player.equipment.ammo.id ~= 0 and player.equipment.ammo.category == 'Weapon' and player.equipment.ammo['damage'] then
		Total_acc.ammo = ammo_acc_skill + math.floor((stat_table['AGI']+ Buffs_inform['AGI']) * 0.75) + stat_table['Ranged Accuracy'] + get_player_acc_from_job() + Buffs_inform['Ranged Accuracy']
	else
		Total_acc.ammo = 0
	end
	
	--notice('Main Acc = '.. Total_acc.main .. ' | Off hand Acc = '.. Total_acc.sub .. ' | Ranged Acc = '.. Total_acc.range .. ' | ammo Acc = '.. Total_acc.ammo)
	--log('Dex = '.. stat_table['DEX'] .. ' | Main skill  = '.. stat_table['main'].value .. ' | Sub skill = '.. stat_table['sub'].value .. ' | job acc = ' ..get_player_acc_from_job() .. ' | gear acc = ' .. stat_table['Accuracy'])
	--log('Agi = '.. stat_table['AGI'] .. ' | Range skill  = '.. stat_table['range'].value .. ' | Ammo skill = '.. stat_table['ammo'].value .. ' | job acc = ' ..get_player_acc_from_job().. ' | gear r.acc = ' .. stat_table['Ranged Accuracy'])
	
	--log(main_acc_skill.. ' ' .. item_acc .. ' ' .. get_player_acc_from_job() .. ' ' .. main_hand.value .. ' ' .. skill_from_gear_main .. ' ' ..item_dex .. ' ' .. player_dex )
	--log(ammo_acc_skill.. ' ' .. item_racc .. ' ' .. get_player_acc_from_job() .. ' ' .. ammo.value .. ' ' .. skill_from_gear_ammo .. ' ' ..item_agi .. ' ' .. player_agi )	
	return Total_acc
end

function get_player_att(stat_table)
	
	local stat_table = stat_table
	
	-- OmniWatch patch: same H2H fallback as get_player_acc. When
	-- nothing is equipped main/sub skill is empty, but FFXI defaults
	-- to Hand-to-Hand. Ensures the H2H skill value flows into both
	-- the acc and att calcs consistently.
	if not stat_table['main'].skill or stat_table['main'].skill == '' then
		stat_table['main'].skill = 'Hand-to-Hand'
	end
	if not stat_table['sub'].skill or stat_table['sub'].skill == '' then
		stat_table['sub'].skill = 'Hand-to-Hand'
	end
	
	local two_handers ={ ["Great Sword"]=0, ["Great Axe"]=0, ["Scythe"]=0, ["Polearm"]=0, ["Great Katana"]=0,["Staff"]=0}
								
	--stat_table = get_blue_mage_stats_from_equipped_spells(stat_table)
	
	local Total_att = {main = 0, sub = 0, range = 0, ammo = 0, str = 0}
	
	
	-- Attack (2H) 
	if table.containskey(two_handers, stat_table['main']['skill']) then
		local base_attack = 8 + stat_table['main'].value + stat_table['STR'] + Buffs_inform['STR'] + stat_table['Attack'] + get_player_att_from_job() + Buffs_inform['Attack']
		local multi = Buffs_inform['Attack perc'] / 1024
		local BA_multi = math.floor(base_attack * (1 + get_smite() + multi))
		Total_att.main = BA_multi
		--print(base_attack, get_smite(), multi, Buffs_inform['Attack perc'])
	-- Attack (H2H)
	elseif stat_table['main']['skill'] == 'Hand-to-Hand' then
		local base_attack = 8 + stat_table['main'].value + stat_table['STR'] + Buffs_inform['STR'] + stat_table['Attack'] + get_player_att_from_job() + Buffs_inform['Attack']
		local multi = Buffs_inform['Attack perc'] / 1024
		local BA_multi = math.floor(base_attack * (1 + get_smite() + multi))
		Total_att.main = BA_multi + Buffs_inform['Attack']
	-- Attack (1H main)
	else
		local base_attack = 8 + stat_table['main'].value + stat_table['STR'] + Buffs_inform['STR'] + stat_table['Attack'] + get_player_att_from_job() + Buffs_inform['Attack']
		local multi = Buffs_inform['Attack perc'] / 1024
		local BA_multi = math.floor(base_attack * (1 + multi))
		Total_att.main = BA_multi
	end
	
	-- Attack (1H sub)
	if player.equipment.sub.id ~= 0 and player.equipment.sub.category == 'Weapon' and player.equipment.sub.damage then
		local base_attack = 8 + stat_table['sub'].value + math.floor( (stat_table['STR'] + Buffs_inform['STR']) / 2) + stat_table['Attack'] + get_player_att_from_job() + Buffs_inform['Attack']
		local multi = Buffs_inform['Attack perc'] / 1024
		local BA_multi = math.floor(base_attack * (1 + multi))
		Total_att.sub = BA_multi
	end
	-- Ranged Attack
	if player.equipment.range.id ~= 0 and player.equipment.range.category == 'Weapon' and player.equipment.range['damage'] then
		local base_attack = 8 + stat_table['range'].value + stat_table['STR'] + stat_table['Ranged Attack'] + get_player_att_from_job() + Buffs_inform['Attack']
		local multi = Buffs_inform['Attack perc'] / 1024
		local BA_multi = math.floor(base_attack * (1 + multi))
		Total_att.range = BA_multi
	end
	
	if player.equipment.range.id == 0 and player.equipment.ammo.id ~= 0 and player.equipment.ammo.category == 'Weapon' and player.equipment.ammo['damage'] then
		local base_attack = 8 + stat_table['ammo'].value + stat_table['STR'] + stat_table['Ranged Attack'] + get_player_att_from_job() + Buffs_inform['Attack']
		local multi = Buffs_inform['Attack perc'] / 1024
		local BA_multi = math.floor(base_attack * (1 + multi))
		Total_att.ammo = BA_multi
	end
	
	return Total_att
end

function get_smite()
	
	local main_job_smite = 0
	local sub_job_smite = 0
	
	if player.sub_job then
		if player.sub_job:upper() == 'DRK' then
			if player.sub_job_level < 35 and  player.sub_job_level > 14 then sub_job_smite = 0.097
			elseif player.sub_job_level > 34 then sub_job_smite = 0.15
			end
		elseif player.sub_job:upper() == 'WAR' then
			if player.sub_job_level > 34 then sub_job_smite = 0.097
			end
		elseif player.sub_job:upper() == 'MNK' then
			if player.sub_job_level > 39 then sub_job_smite = 0.097
			end
		elseif player.sub_job:upper() == 'DRG' then
			if player.sub_job_level > 39 then sub_job_smite = 0.097
			end
		end
	end
	
	if player.main_job:upper() == 'DRK' then
		if player.main_job_level < 35 and  player.main_job_level > 14 then main_job_smite = 0.097
		elseif player.main_job_level < 55 and  player.main_job_level > 34 then main_job_smite = 0.15
		elseif player.main_job_level < 75 and  player.main_job_level > 54 then main_job_smite = 0.199
		elseif player.main_job_level < 95 and  player.main_job_level > 74 then main_job_smite = 0.25
		elseif player.main_job_level > 94 then main_job_smite = 0.296
		end
	elseif player.main_job:upper() == 'WAR' then
		if player.main_job_level < 65 and  player.main_job_level > 34 then main_job_smite = 0.097
		elseif player.main_job_level < 95 and  player.main_job_level > 64 then main_job_smite = 0.15
		elseif player.main_job_level > 94 then main_job_smite = 0.199
		end
	elseif player.main_job:upper() == 'MNK' then
		if player.main_job_level < 80 and  player.main_job_level > 39 then main_job_smite = 0.097
		elseif player.main_job_level > 79 then main_job_smite = 0.15
		end
	elseif player.main_job:upper() == 'DRG' then
		if player.main_job_level < 80 and  player.main_job_level > 39 then main_job_smite = 0.097
		elseif player.main_job_level > 79 then main_job_smite = 0.15
		end
	elseif player.main_job:upper() == 'PUP' then
		if player.main_job_level > 59 then main_job_smite = 0.097
		end
	end
	
	if sub_job_smite > main_job_smite then
		return sub_job_smite
	else
		return main_job_smite
	end

end

function get_player_evasion(stat_table)
	
	local stat_table = stat_table
	
	if player_base_skills['evasion'] then 
		--notice('in')
		stat_table['Evasion skill'] = stat_table['Evasion skill'] + player_base_skills['evasion']
		--notice(stat_table['Evasion skill']..' '..player_base_skills['evasion'])
	end
	
	--stat_table = get_blue_mage_stats_from_equipped_spells(stat_table)
	
	--notice(stat_table['AGI'] .. ' | ' .. stat_table['Evasion skill'] .. ' | ' .. eva_from_skill(stat_table['Evasion skill'] ) .. ' | ' .. get_player_eva_from_job().. ' | ' .. stat_table['Evasion'])
	local evasion = math.floor( stat_table['AGI']/2 ) + ( eva_from_skill(stat_table['Evasion skill'] ) ) + ( get_player_eva_from_job() + stat_table['Evasion'])
	return evasion
end

function get_player_defence(stat_table)
	
	local stat_table = stat_table
	local defence = 0
	--notice(stat_table['AGI'] .. ' | ' .. stat_table['Evasion skill'] .. ' | ' .. eva_from_skill(stat_table['Evasion skill'] ) .. ' | ' .. get_player_eva_from_job().. ' | ' .. stat_table['Evasion'])
	if player.main_job_level < 51 then
		defence = math.floor(3*stat_table['VIT']/2) + player.main_job_level + 8
	elseif player.main_job_level > 50 and player.main_job_level < 61 then
		defence = math.floor(3*stat_table['VIT']/2) + (2 * player.main_job_level ) - 48
	elseif player.main_job_level > 60 and player.main_job_level < 90 then
		defence = math.floor(3*stat_table['VIT']/2) + ( player.main_job_level ) + 18
	else
		defence = math.floor(3*stat_table['VIT']/2) + ( player.main_job_level ) + 18 + math.floor( (player.main_job_level - 89) / 2 )
	end
	defence = defence + stat_table['DEF'] + get_player_def_from_job()

	return defence
end

function get_blue_mage_stats_from_equipped_spells(stat_table)

	local spells_set = T(windower.ffxi.get_mjob_data().spells):filter(function(id) return id ~= 512 end):map(function(id) return id end)
	
	for key, spell_id in pairs(spells_set) do
		-- Guard against spell IDs not present in Blu_spells (e.g. spells
		-- added in patches after our Blu_spells table was generated).
		-- Without this, pairs(nil) crashes the helper, which crashes
		-- get_player_acc, which makes the panel show no stats at all.
		if Blu_spells[spell_id] then
			for stat, value in pairs(Blu_spells[spell_id]) do
				if stat_table[stat] then 
					stat_table[stat] = stat_table[stat] + value 
				end
			end
		end
	end

	return stat_table
end

function get_player_skill_in_gear(equip)
	
	player_base_skills = player.skills
	
	-- string.gsub(sub_hand.skill, ' ', '_')
	local combat_skills = L{"hand_to_hand", "dagger", "sword", "great_sword", "axe", "great_axe",  "scythe", "polearm", 
										"katana", "great_katana", "club",  "staff", "archery", "marksmanship" , "throwing","guard","evasion","shield","parrying",}
	local magic_skills = L{"divine_magic","healing_magic","enhancing_magic","enfeebling_magic","elemental_magic","dark_magic","summoning_magic",
									"ninjutsu","singing","stringed Instrument","wind Instrument","blue_magic","geomancy","handbell"}
	local skills = L{"Hand-to-Hand skill", "Dagger skill", "Sword skill", "Great sword skill", "Axe skill", "Great axe skill",  "Scythe skill", "Polearm skill", 
							"Katana skill", "Great katana skill", "Club skill",  "Staff skill", "Archery skill", "Marksmanship skill" , "Throwing skill","Guard skill","Evasion skill","Shield skill","Parrying skill",
							"Divine Magic skill","Healing Magic skill","Enhancing Magic skill","Enfeebling Magic skill","Elemental Magic skill","Dark Magic skill","Summoning Magic skill","Ninjutsu skill","Singing skill",
							"Stringed Instrument skill","Wind Instrument skill","Blue Magic skill","Geomancy skill","Handbell skill",'All magic skills','Combat skills','Magic skills',
							}
	
	if equip then
		for slot ,item in pairs(equip) do
			if slot == 'main' or slot == 'sub' or slot == 'range' or slot == 'ammo' then
				if item.category == 'Weapon' then
					if item.damage == nil then
						if item.item_level == nil then
							for stat_key, value in pairs(item) do
								if skills:contains(stat_key) then
									str = string.gsub(stat_key, ' skill', '')
									if player_base_skills[string.gsub(str, ' ', '_'):lower()] then
										player_base_skills[string.gsub(str, ' ', '_'):lower()] = player_base_skills[string.gsub(str, ' ', '_'):lower()] - value
										-- notice('value 1 = ' .. value)
										-- break
									elseif player_base_skills['hand_to_hand'] and stat_key == "Hand-to-Hand skill" then
										player_base_skills['hand_to_hand'] = player_base_skills['hand_to_hand'] - value
									elseif stat_key == "Combat skills" then
										for k, player_skill in pairs(player_base_skills) do
											if combat_skills:contains(player_skill) then
												player_base_skills.player_skill = player_base_skills.player_skill - value
											end
										end
									elseif stat_key == 'All magic skills' or stat_key == 'Magic skills' then
										for k, player_skill in pairs(player_base_skills) do
											if magic_skills:contains(player_skill) then
												player_base_skills.player_skill = player_base_skills.player_skill - value
											end
										end
									end
								end
							end
						end
					end
				end
			else
				for stat_key, value in pairs(item) do
					if skills:contains(stat_key) then
						str = string.gsub(stat_key, ' skill', '')
						if player_base_skills[string.gsub(str, ' ', '_'):lower()] then
							player_base_skills[string.gsub(str, ' ', '_'):lower()] = player_base_skills[string.gsub(str, ' ', '_'):lower()] - value
							-- notice('value 2 = ' .. value .. ' for item: ' .. item.en)
							-- break
						elseif player_base_skills['hand_to_hand'] and stat_key == "Hand-to-Hand skill" then
							player_base_skills['hand_to_hand'] = player_base_skills['hand_to_hand'] - value
						elseif stat_key == "Combat skills" then
							for k, player_skill in pairs(player_base_skills) do
								if combat_skills:contains(player_skill) then
									player_base_skills.player_skill = player_base_skills.player_skill - value
								end
							end
						elseif stat_key == 'All magic skills' or stat_key == 'Magic skills' then
							for k, player_skill in pairs(player_base_skills) do
								if magic_skills:contains(player_skill) then
									player_base_skills.player_skill = player_base_skills.player_skill - value
								end
							end
						end
					end
				end
			end
		end
	end
	-- notice(player_base_skills.sword)
end
	
function acc_from_skill(skill)
	
	if skill < 200 then return skill end
	if skill < 400 and skill > 199 then return (math.floor((skill -200) * 0.9) + 200) end
	if skill < 600 and skill > 399 then return (math.floor((skill -400) * 0.8) + 380) end
	if skill > 599 then return (math.floor((skill -600) * 0.9) + 540) end

end

function racc_from_skill(skill)
	
	if skill < 200 then return skill end
	if skill < 400 and skill > 199 then return (math.floor((skill -200) * 0.9) + 200) end
	if skill < 600 and skill > 399 then return (math.floor((skill -400) * 0.8) + 380) end
	if skill > 599 then return (math.floor((skill -600) * 0.9) + 540) end

end

function eva_from_skill(skill)
	
	if skill < 200 then return skill end
	if skill < 400 and skill > 199 then return (math.floor((skill -200) * 0.9) + 200) end
	if skill < 600 and skill > 399 then return (math.floor((skill -400) * 0.8) + 380) end
	if skill > 599 then return (math.floor((skill -600) * 0.9) + 540) end

end

function get_player_acc_from_job()
	
	local sub_job_acc = 0
	local main_job_acc = 0
	local player_has_sj = false
	
	if player.sub_job then
		if player.sub_job:upper() == 'RNG' then
			if player.sub_job_level < 10  then sub_job_acc = 0
			elseif player.sub_job_level < 30 and  player.sub_job_level > 9 then sub_job_acc = 10
			elseif player.sub_job_level > 29 then sub_job_acc = 22
			end
		elseif player.sub_job:upper() == 'DRG' then
			if player.sub_job_level < 30  then sub_job_acc = 0
			elseif player.sub_job_level > 29 then sub_job_acc = 10
			end
		elseif player.sub_job:upper() == 'DNC' then
			if player.sub_job_level < 30  then sub_job_acc = 0
			elseif player.sub_job_level > 29 then sub_job_acc = 10
			end
		end
	end

	local jp = player.job_points[player.main_job:lower()]['jp_spent']
		
	local jp_acc = 0
	for k, v in pairs(Gifts[player.main_job]['Gifts']) do
		if k <= jp then
			for i, j in pairs(v) do
				if i == 'Physical Accuracy Bonus' then
					jp_acc = jp_acc + j
				end
			end
		end
	end
	
	if player.main_job == 'BLU' then
		-- here we look up job points spent on blue for the DW bonus
		local jp_boost = 0
		if jp < 100 then
			jp_boost = 0
		elseif jp >= 100 and jp < 1200 then
			jp_boost = 1
		elseif jp >= 1200 then
			jp_boost = 2
		end
		
		local spells_set = T(windower.ffxi.get_mjob_data().spells):filter(function(id) return id ~= 512 end):map(function(id) return id end)
		local spell_value = 0
		for key, spell_id in pairs(spells_set) do
			-- Guard against post-patch BLU spell IDs not yet in Blu_spells.
			if Blu_spells[spell_id] and Blu_spells[spell_id].trait == 'Accuracy' then
				spell_value = spell_value + Blu_spells[spell_id]['points']
			end
		end
		
		if math.floor(spell_value / 8) > 0 then
			spell_value  = math.floor(spell_value / 8) + jp_boost
		else
			spell_value = 0
		end

		if spell_value == 0 then main_job_acc = 0
		elseif spell_value == 1 then main_job_acc = 10
		elseif spell_value == 2 then main_job_acc = 22
		elseif spell_value == 3 then main_job_acc = 35
		elseif spell_value == 4 then main_job_acc = 48
		elseif spell_value == 5 then main_job_acc = 60
		elseif spell_value == 6 then main_job_acc = 73
		end
		
	elseif player.main_job == 'RNG' then
		if player.main_job_level < 10  then main_job_acc = 0
		elseif player.main_job_level < 30 and  player.main_job_level > 9 then main_job_acc = 10
		elseif player.main_job_level < 50 and  player.main_job_level > 29 then main_job_acc = 22
		elseif player.main_job_level < 70 and  player.main_job_level > 49 then main_job_acc = 35
		elseif player.main_job_level < 86 and  player.main_job_level > 69 then main_job_acc = 48
		elseif player.main_job_level < 96 and  player.main_job_level > 85 then main_job_acc = 60
		elseif player.main_job_level < 100 and  player.main_job_level > 95 then main_job_acc = 73
		end
	
	elseif player.main_job == 'DRG' then
		if player.main_job_level < 30  then main_job_acc = 0
		elseif player.main_job_level > 29 and player.main_job_level < 60 then main_job_acc = 10
		elseif player.main_job_level > 59 and player.main_job_level < 76 then main_job_acc = 22
		elseif player.main_job_level > 75  then main_job_acc = 35
		end
		
	elseif player.main_job == 'DNC' then
		if player.main_job_level < 30  then main_job_acc = 0
		elseif player.main_job_level > 29 and player.main_job_level < 60 then main_job_acc = 10
		elseif player.main_job_level > 59 and player.main_job_level < 76 then main_job_acc = 22
		elseif player.main_job_level > 75  then main_job_acc = 35
		end
		
	elseif player.main_job == 'RUN' then
		if player.main_job_level < 50  then main_job_acc = 0
		elseif player.main_job_level > 49 and player.main_job_level < 70 then main_job_acc = 10
		elseif player.main_job_level > 69 and player.main_job_level < 90 then main_job_acc = 22
		elseif player.main_job_level > 89  then main_job_acc = 35
		end
	end
	
	if sub_job_acc > main_job_acc then
		return sub_job_acc + jp_acc
	else
		return main_job_acc + jp_acc
	end
end

function get_player_eva_from_job()
	
	local sub_job_acc = 0
	local main_job_acc = 0
	local player_has_sj = false
	
	if player.sub_job then
		if player.sub_job:upper() == 'THF' then
			if player.sub_job_level < 10  then sub_job_acc = 0
			elseif player.sub_job_level < 30 and  player.sub_job_level > 9 then sub_job_acc = 10
			elseif player.sub_job_level > 29 then sub_job_acc = 22
			end
		elseif player.sub_job:upper() == 'DNC' then
			if player.sub_job_level < 15  then sub_job_acc = 0
			elseif player.sub_job_level < 45 and  player.sub_job_level > 14 then sub_job_acc = 10
			elseif player.sub_job_level > 44 then sub_job_acc = 22
			end
		elseif player.sub_job:upper() == 'PUP' then
			if player.sub_job_level < 20  then sub_job_acc = 0
			elseif player.sub_job_level < 40 and  player.sub_job_level > 19 then sub_job_acc = 10
			elseif player.sub_job_level >39  then sub_job_acc = 22
			end
		end
	end

	local jp = player.job_points[player.main_job:lower()]['jp_spent']
		
	local jp_eva = 0
	for k, v in pairs(Gifts[player.main_job]['Gifts']) do
		if k <= jp then
			for i, j in pairs(v) do
				if i == 'Physical Evasion Bonus' then
					jp_eva = jp_eva + j
				end
			end
		end
	end
	
	if player.main_job == 'BLU' then
		-- here we look up job points spent on blue for the DW bonus
		local jp_boost = 0
		if jp < 100 then
			jp_boost = 0
		elseif jp >= 100 and jp < 1200 then
			jp_boost = 1
		elseif jp >= 1200 then
			jp_boost = 2
		end
		
		local spells_set = T(windower.ffxi.get_mjob_data().spells):filter(function(id) return id ~= 512 end):map(function(id) return id end)
		local spell_value = 0
		for key, spell_id in pairs(spells_set) do
			-- Guard against post-patch BLU spell IDs not yet in Blu_spells.
			if Blu_spells[spell_id] and Blu_spells[spell_id].trait == 'Evasion' then
				spell_value = spell_value + Blu_spells[spell_id]['points']
			end
		end
		
		if math.floor(spell_value / 8) > 0 then
			spell_value  = math.floor(spell_value / 8) + jp_boost
		else
			spell_value = 0
		end

		if spell_value == 0 then main_job_acc = 0
		elseif spell_value == 1 then main_job_acc = 10
		elseif spell_value == 2 then main_job_acc = 22
		elseif spell_value == 3 then main_job_acc = 35
		elseif spell_value == 4 then main_job_acc = 48
		elseif spell_value == 5 then main_job_acc = 60
		end
		
	elseif player.main_job == 'THF' then
		if player.main_job_level < 10  then main_job_acc = 0
		elseif player.main_job_level < 30 and  player.main_job_level > 9 then main_job_acc = 10
		elseif player.main_job_level < 50 and  player.main_job_level > 29 then main_job_acc = 22
		elseif player.main_job_level < 70 and  player.main_job_level > 49 then main_job_acc = 35
		elseif player.main_job_level < 76 and  player.main_job_level > 69 then main_job_acc = 48
		elseif player.main_job_level < 88 and  player.main_job_level > 75 then main_job_acc = 60
		elseif player.main_job_level > 87  then main_job_acc = 72
		end
	
	elseif player.main_job == 'DNC' then
		if player.main_job_level < 15  then main_job_acc = 0
		elseif player.main_job_level < 45 and  player.main_job_level > 14 then main_job_acc = 10
		elseif player.main_job_level < 75 and  player.main_job_level > 44 then main_job_acc = 22
		elseif player.main_job_level < 86 and  player.main_job_level > 74 then main_job_acc = 35
		elseif player.main_job_level > 85  then main_job_acc = 48
		end
		
	elseif player.main_job == 'PUP' then
		if player.main_job_level < 20  then main_job_acc = 0
		elseif player.main_job_level < 40 and  player.main_job_level > 19 then main_job_acc = 10
		elseif player.main_job_level < 60 and  player.main_job_level > 39 then main_job_acc = 22
		elseif player.main_job_level > 76  then main_job_acc = 35
		end
	end
	
	if sub_job_acc > main_job_acc then
		return sub_job_acc + jp_eva
	else
		return main_job_acc + jp_eva
	end
end

-- copy pasta from get_player_acc_from_job but returns Attack
function get_player_att_from_job()
	
	local sub_job_acc = 0
	local main_job_acc = 0
	local player_has_sj = false
	
	if player.sub_job then
		if player.sub_job:upper() == 'DRK' then
			if player.sub_job_level < 30 and  player.sub_job_level > 9 then sub_job_acc = 10
			elseif player.sub_job_level > 29 then sub_job_acc = 22
			end
		elseif player.sub_job:upper() == 'DRG' then
			if player.sub_job_level > 9 then sub_job_acc = 10
			end
		elseif player.sub_job:upper() == 'WAR' then
			if player.sub_job_level > 29 then sub_job_acc = 10
			end
		end
	end

	local jp = player.job_points[player.main_job:lower()]['jp_spent']
		
	local jp_eva = 0
	for k, v in pairs(Gifts[player.main_job]['Gifts']) do
		if k <= jp then
			for i, j in pairs(v) do
				if i == 'Physical Attack Bonus' then
					jp_eva = jp_eva + j
				end
			end
		end
	end
	
	if player.main_job == 'BLU' then
		-- here we look up job points spent on blue for the DW bonus
		local jp_boost = 0
		if jp < 100 then
			jp_boost = 0
		elseif jp >= 100 and jp < 1200 then
			jp_boost = 1
		elseif jp >= 1200 then
			jp_boost = 2
		end
		
		local spells_set = T(windower.ffxi.get_mjob_data().spells):filter(function(id) return id ~= 512 end):map(function(id) return id end)
		local spell_value = 0
		for key, spell_id in pairs(spells_set) do
			-- Guard against post-patch BLU spell IDs not yet in Blu_spells.
			if Blu_spells[spell_id] and Blu_spells[spell_id].trait == 'Attack' then
				spell_value = spell_value + Blu_spells[spell_id]['points']
			end
		end
		
		if math.floor(spell_value / 8) > 0 then
			spell_value  = math.floor(spell_value / 8) + jp_boost
		else
			spell_value = 0
		end

		if spell_value == 0 then main_job_acc = 0
		elseif spell_value == 1 then main_job_acc = 10
		elseif spell_value == 2 then main_job_acc = 22
		elseif spell_value == 3 then main_job_acc = 35
		elseif spell_value == 4 then main_job_acc = 48
		elseif spell_value == 5 then main_job_acc = 60
		elseif spell_value == 6 then main_job_acc = 72
		end
		
	elseif player.main_job == 'DRK' then
		if player.main_job_level < 10  then main_job_acc = 0
		elseif player.main_job_level < 30 and  player.main_job_level > 9 then main_job_acc = 10
		elseif player.main_job_level < 50 and  player.main_job_level > 29 then main_job_acc = 22
		elseif player.main_job_level < 70 and  player.main_job_level > 49 then main_job_acc = 35
		elseif player.main_job_level < 76 and  player.main_job_level > 69 then main_job_acc = 48
		elseif player.main_job_level < 83 and  player.main_job_level > 75 then main_job_acc = 60
		elseif player.main_job_level < 91 and  player.main_job_level > 82 then main_job_acc = 72
		elseif player.main_job_level < 99 and  player.main_job_level > 90 then main_job_acc = 84
		elseif player.main_job_level > 98  then main_job_acc = 96
		end
	
	elseif player.main_job == 'DRG' then
		if player.main_job_level < 10  then main_job_acc = 0
		elseif player.main_job_level < 91 and  player.main_job_level > 9 then main_job_acc = 10
		elseif player.main_job_level > 90  then main_job_acc = 22
		end
		
	elseif player.main_job == 'WAR' then
		if player.main_job_level < 30  then main_job_acc = 0
		elseif player.main_job_level < 65 and  player.main_job_level > 29 then main_job_acc = 10
		elseif player.main_job_level < 90 and  player.main_job_level > 64 then main_job_acc = 22
		elseif player.main_job_level > 89  then main_job_acc = 35
		end
	end
	
	if sub_job_acc > main_job_acc then
		return sub_job_acc + jp_eva
	else
		return main_job_acc + jp_eva
	end
end

function get_player_def_from_job()
	
	local sub_job_acc = 0
	local main_job_acc = 0
	local player_has_sj = false
	
	if player.sub_job then
		if player.sub_job:upper() == 'PLD' then
			if player.sub_job_level < 10  then sub_job_acc = 0
			elseif player.sub_job_level < 30 and  player.sub_job_level > 9 then sub_job_acc = 10
			elseif player.sub_job_level > 29 then sub_job_acc = 22
			end
		elseif player.sub_job:upper() == 'WAR' then
			if player.sub_job_level < 10  then sub_job_acc = 0
			elseif player.sub_job_level < 45 and  player.sub_job_level > 9 then sub_job_acc = 10
			elseif player.sub_job_level > 44  then sub_job_acc = 22
			end
		end
	end

	local jp = player.job_points[player.main_job:lower()]['jp_spent']
		
	local jp_eva = 0
	for k, v in pairs(Gifts[player.main_job]['Gifts']) do
		if k <= jp then
			for i, j in pairs(v) do
				if i == 'Physical Defense Bonus' then
					jp_eva = jp_eva + j
				end
			end
		end
	end
	
	if player.main_job == 'BLU' then
		-- here we look up job points spent on blue for the DW bonus
		local jp_boost = 0
		if jp < 100 then
			jp_boost = 0
		elseif jp >= 100 and jp < 1200 then
			jp_boost = 1
		elseif jp >= 1200 then
			jp_boost = 2
		end
		
		local spells_set = T(windower.ffxi.get_mjob_data().spells):filter(function(id) return id ~= 512 end):map(function(id) return id end)
		local spell_value = 0
		for key, spell_id in pairs(spells_set) do
			-- Guard against post-patch BLU spell IDs not yet in Blu_spells.
			if Blu_spells[spell_id] and Blu_spells[spell_id].trait == 'Defense Bonus' then
				spell_value = spell_value + Blu_spells[spell_id]['points']
			end
		end
		
		if math.floor(spell_value / 8) > 0 then
			spell_value  = math.floor(spell_value / 8) + jp_boost
		else
			spell_value = 0
		end

		if spell_value == 0 then main_job_acc = 0
		elseif spell_value == 1 then main_job_acc = 10
		elseif spell_value == 2 then main_job_acc = 22
		elseif spell_value == 3 then main_job_acc = 35
		elseif spell_value == 4 then main_job_acc = 48
		elseif spell_value == 5 then main_job_acc = 60
		elseif spell_value == 6 then main_job_acc = 72
		end
		
	elseif player.main_job == 'PLD' then
		if player.main_job_level < 10  then main_job_acc = 0
		elseif player.main_job_level < 30 and  player.main_job_level > 9 then main_job_acc = 10
		elseif player.main_job_level < 50 and  player.main_job_level > 29 then main_job_acc = 22
		elseif player.main_job_level < 70 and  player.main_job_level > 49 then main_job_acc = 35
		elseif player.main_job_level < 76 and  player.main_job_level > 69 then main_job_acc = 48
		elseif player.main_job_level < 91 and  player.main_job_level > 75 then main_job_acc = 60
		elseif player.main_job_level > 90  then main_job_acc = 72
		end
		
	elseif player.main_job == 'WAR' then
		if player.main_job_level < 10  then main_job_acc = 0
		elseif player.main_job_level < 45 and  player.main_job_level > 9 then main_job_acc = 10
		elseif player.main_job_level < 86 and  player.main_job_level > 44 then main_job_acc = 22
		elseif player.main_job_level > 85  then main_job_acc = 35
		end
	end

	main_job_acc = main_job_acc
	
	if sub_job_acc > main_job_acc then
		return sub_job_acc + jp_eva
	else
		return main_job_acc + jp_eva
	end
end