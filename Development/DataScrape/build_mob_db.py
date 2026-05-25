#!/usr/bin/env python3
"""
build_mob_db.py — Scrape BG-wiki for FFXI monster ability descriptions and
family ability lists, producing a single consolidated JSON file used by
the PartyWatch overlay.

Usage:
    python3 build_mob_db.py [--out <path>] [--cache <path>] [--rate <sec>]

Output (default): ./data/mob_abilities.json

Design principles:
- Checks robots.txt before starting. Aborts if BG-wiki disallows the API
  paths, or honors Crawl-delay if specified.
- Uses the MediaWiki API (not HTML scraping) — cleaner, lighter, less
  likely to break.
- Rate-limited to 1 request per RATE seconds (default 1.2).
- Sets a clear User-Agent identifying the tool and providing contact info.
- Resumable via disk cache (no re-fetching of pages we already have).
- Progress prints to stdout; safe to Ctrl-C and resume.

Structure of the output JSON:
{
  "_meta": {
    "generated":  "ISO timestamp",
    "source":     "https://www.bg-wiki.com",
    "abilities":  <count>,
    "families":   <count>
  },
  "abilities": {
    "jet stream": {
      "id":          123,
      "display":     "Jet Stream",
      "description": "Area damage attack ...",
      "notes":       "...",
      "families":    ["bat", "flock bat"]
    },
    ...
  },
  "families": {
    "bat": {
      "display":     "Bat",
      "ecosystem":   "Bird",
      "description": "Short blurb about bats ...",
      "abilities":   ["jet stream", "sonic boom", ...]
    },
    ...
  }
}
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import urllib.robotparser
from datetime import datetime, timezone

BG_WIKI_BASE   = "https://www.bg-wiki.com"
BG_WIKI_API    = f"{BG_WIKI_BASE}/api.php"
USER_AGENT     = (
    "PartyWatch-MobDB-Builder/1.0 "
    "(FFXI overlay cache; one-time scrape; rate-limited) "
    "contact: see github issue tracker"
)

# ═══════════════════════════════════════════════════════════════════════════
# Known monster abilities and families. In production we'd pull the ability
# list from Windower's res.monster_abilities; for standalone usage we ship
# a curated seed list of the most common family names and let the script
# discover abilities via the family page listings.
# ═══════════════════════════════════════════════════════════════════════════

SEED_FAMILIES = [
    # Amorph
    "Flan", "Slime", "Leech", "Morbol", "Sandworm",
    # Aquan
    "Crab", "Pugil", "Rafflesia", "Toad", "Uragnite", "Ruszor", "Orobon",
    "Gigas", "Lamia",
    # Arcana
    "Doll", "Evil Weapon", "Golem", "Magic Jug", "Mimic", "Wendigo",
    "Fomor", "Magic Pot", "Bomb", "Sea Monk",
    # Beast
    "Behemoth", "Cerberus", "Coeurl", "Dhalmel", "Manticore", "Marid",
    "Opo-opo", "Rabbit", "Ram", "Sheep", "Tiger", "Buffalo", "Karakul",
    "Smilodon",
    # Bird
    "Amphiptere", "Apkallu", "Bat", "Bird", "Cockatrice", "Colibri",
    "Flock Bat", "Hippogryph", "Hpemde", "Puk", "Roc", "Pephredo",
    # Demon
    "Ahriman", "Antica", "Chariot", "Demon", "Imp", "Soulflayer", "Gigas",
    "Qutrub",
    # Dragon
    "Dragon", "Hydra", "Wyrm", "Wyvern",
    # Lizard
    "Adamantoise", "Bugard", "Eft", "Lizard", "Peiste", "Raptor",
    # Plantoid
    "Funguar", "Goobbue", "Mandragora", "Panopt", "Sapling", "Treant",
    "Korrigan",
    # Undead
    "Corse", "Ghost", "Ghrah", "Hecteyes", "Lich", "Skeleton", "Tombstone",
    "Fomor",
    # Vermin
    "Beetle", "Bee", "Chigoe", "Crawler", "Diremite", "Fly", "Gnat",
    "Scorpion", "Spider", "Wamoura", "Worm", "Chapuli", "Matamata",
    "Qiqirn", "Limule",
    # Beastman / humanoid
    "Goblin", "Moblin", "Orc", "Quadav", "Sahagin", "Tonberry", "Yagudo",
    "Kindred", "Shikaree", "Troll",
    # Luminous / shadow / misc
    "Shadow", "Wanderer",
    # Older expansions / specific
    "Hydra", "Hpemde", "Craklaw", "Crawler",
]

# Canonical list of well-known FFXI monster TP moves / special abilities.
# These are fetched in pass 1 even if no family page links to them. Ensures
# we capture known-important abilities (especially NM-unique) that wiki
# pages may not cross-reference.
SEED_ABILITIES = [
    # Bat / Flock Bat
    "Jet Stream", "Sonic Boom", "Turbulence", "Mysterious Light",
    # Bird / Puk / Colibri / Roc / Cockatrice
    "Feather Storm", "Pecking Flurry", "Helldive", "Back Heel",
    "Choke Breath", "Head Butt", "Back Heel", "Claw Cyclone",
    # Bee / Wasp
    "Final Sting", "Pollen", "Wild Rage", "Sharp Sting", "Cursed Sphere",
    # Behemoth / Cerberus / beasts
    "Thunderbolt", "Thunderstrike", "Meteor", "Blastbomb", "Beatdown",
    "Trounce", "Scythe Tail", "Petrifying Glare", "Intimidate",
    "Hundred Fists", "Wild Horn", "Ram Charge", "Tail Slap",
    # Bomb
    "Self-Destruct", "Blockhead", "Firespit", "Rage", "Heat Wave",
    "Warmup", "Inferno",
    # Coeurl / Manticore / Tiger
    "Blaster", "Bloody Claws", "Chaos Blade", "Feral Howl", "Roar",
    "Razor Fang", "Great Boulder", "Killer Instinct",
    # Crab / Beetle / Pugil
    "Bubble Shower", "Bubble Curtain", "Scissor Guard", "Big Scissors",
    "Cyclotail", "Rhino Attack", "Rhino Guard", "Metallic Body",
    "Chaotic Eye", "Tortoise Song", "Harden Shell", "Screwdriver",
    # Demon / Ahriman / Imp
    "Glower", "Eyes On Me", "Level ? Holy", "Absorb-TP", "Absorb-Acc",
    "Hex Eyes", "Mortal Ray", "Death Ray",
    # Dragon / Wyrm / Wyvern / Hydra
    "Fang Rush", "Horrid Roar", "Radiant Breath", "Fire Breath",
    "Flame Breath", "Flaming Crush", "Heat Breath", "Ice Break",
    "Hurricane Wing", "Wing Cutter", "Voidsong", "Crippling Rime",
    "Puissant Stance", "Cross Attack", "Tail Smash", "Dragon Breath",
    # Funguar / Mandragora / Sapling / Treant
    "Queasyshroom", "Dark Spore", "Nightmare Sheep", "Dream Flower",
    "Leafstorm", "Photosynthesis", "Sprout Smack", "Wild Carrot",
    "Snort", "Rotten Stench", "Smite of Rage", "Sickle Slash",
    # Ghost / Skeleton / Lich
    "Terror Touch", "Shadow Spread", "Hecatomb Wave", "Nihility Song",
    "Barbed Crescent", "Bludgeon", "Necrobond",
    # Goblin / Moblin
    "Goblin Rush", "Goblin Dice", "Bomb Toss", "Blockhead",
    # Lizard / Peiste / Raptor
    "Sharp Strike", "Fireball", "Fatal Bite", "Infrasonics",
    "Scythe Tail", "Foul Waters", "Brain Crush", "Brain Drain",
    # Mandragora
    "Sheep Song", "Wild Carrot", "Dream Flower",
    # Morbol
    "Bad Breath", "Dark Mist", "Anchorage",
    # Opo-opo
    "Backhand Blow", "Blindside",
    # Orc
    "Warcry", "Gust Slash", "Sweeping Gouge", "Mighty Strikes",
    # Puk
    "Helldive", "Wind Shear",
    # Quadav
    "Heavy Strike", "Rampage",
    # Sahagin
    "Waterbomb", "Regal Gash",
    # Scorpion
    "Cross Attack", "Death Scissors", "Incinerating Lahar",
    # Slime / Flan / Leech
    "Bludgeon", "Acid Spray", "Suction", "Drainkiss", "Drain Samba",
    "Drainkiss", "Acid Mist",
    # Spider
    "Sticky Thread", "Spider Web",
    # Tonberry
    "Everyone's Grudge", "Tonberry Hate", "Throat Stab",
    "Knife Sharpening", "Weeping Moon", "Dagger Throw",
    # Yagudo
    "Burning Feathers", "Retinal Glare", "Feather Storm", "Blood Rite",
    # Worm
    "Sandspin", "Sandpit", "Sand Breath",
    # Crawler
    "Sticky Thread", "Cocoon", "Pollen",
    # Chapuli / Matamata
    "Smite of Rage", "Sound Blast", "Heat Breath", "Erratic Flutter",
    # Evil Weapon / Magic Pot / Magic Jug
    "Magic Barrier", "Whirl of Rage", "Barbed Crescent", "Rampage",
    # Apkallu
    "Aqua Breath", "Shackled Fists",
    # Generic/universal
    "Blink", "Sonic Wave", "Venom Shell", "Flash Flood", "Poison Breath",
    "Light of Penance", "Gates of Hades", "Polar Bulwark",
    "Temporal Shift", "Cosmic Elucidation", "Pyric Bulwark",
    "Magnetite Cloud", "Foot Kick", "Knockback", "Power Attack",
    "Petrifying Glare", "Plague Breath", "Rabbit Kick",
]


def throttled_get(url, rate_sec, last_fetch=[0.0]):
    """GET with a global minimum interval since last fetch."""
    now = time.time()
    elapsed = now - last_fetch[0]
    if elapsed < rate_sec:
        time.sleep(rate_sec - elapsed)
    last_fetch[0] = time.time()
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.read().decode("utf-8", errors="replace")


def check_robots(base_url):
    """Return (allowed: bool, crawl_delay: float|None) for our user agent.
    Prints a summary of the relevant robots.txt rules."""
    rp = urllib.robotparser.RobotFileParser()
    robots_url = f"{base_url}/robots.txt"
    print(f"[robots] Fetching {robots_url} ...")
    try:
        req = urllib.request.Request(robots_url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read().decode("utf-8", errors="replace")
        rp.parse(body.splitlines())
    except Exception as e:
        print(f"[robots] Could not fetch ({e}). Proceeding cautiously.")
        return True, None

    # Check API path access for our user agent.
    test_urls = [
        f"{base_url}/api.php",
        f"{base_url}/wiki/Main_Page",
    ]
    for u in test_urls:
        can = rp.can_fetch(USER_AGENT, u)
        print(f"[robots] can_fetch({u}) = {can}")
        if not can:
            return False, None

    # Look for Crawl-delay on our user agent or on *.
    delay = None
    try:
        delay = rp.crawl_delay(USER_AGENT) or rp.crawl_delay("*")
    except Exception:
        pass
    if delay:
        print(f"[robots] Crawl-delay = {delay}s")
    return True, delay


def api_query(params, rate_sec):
    """Hit BG-wiki's MediaWiki API with the given parameter dict."""
    qs = urllib.parse.urlencode(params)
    url = f"{BG_WIKI_API}?{qs}"
    body = throttled_get(url, rate_sec)
    return json.loads(body)


def fetch_page_wikitext(title, rate_sec):
    """Return the raw wikitext of a BG-wiki page, or None if missing."""
    resp = api_query({
        "action":  "query",
        "prop":    "revisions",
        "rvprop":  "content",
        "rvslots": "main",
        "format":  "json",
        "titles":  title,
        "redirects": 1,
    }, rate_sec)
    pages = resp.get("query", {}).get("pages", {})
    for _, pg in pages.items():
        if pg.get("missing") is not None:
            return None
        revs = pg.get("revisions", [])
        if not revs:
            continue
        slots = revs[0].get("slots", {})
        main  = slots.get("main", {})
        return main.get("*") or revs[0].get("*")
    return None


# ═══════════════════════════════════════════════════════════════════════════
# Wikitext extraction — parses BG-wiki's actual page structures:
#   * Ability pages use {{Blue Magic|desc=...}}, {{Standard Magic|
#     description=...}}, {{Job Ability|desc=...}}, {{Standard WS|...}}, etc.
#   * Family pages use {{Bestiary Description|Type=...}} (newer) or
#     {{Adversary Description|Type=...}} (older) and list TP moves inside
#     {{Bestiary Abilities Row|Abilities.Name=...|Abilities.Effect=...}}
#     templates nested inside {{#ifeq:...}} parser functions.
# ═══════════════════════════════════════════════════════════════════════════

def _parse_template_fields(raw):
    """Parse |field=value parts of a template body. Returns dict with
    lower-cased keys, stripped values. Handles pipes inside [[links]]."""
    safe = re.sub(r"\[\[([^\]]*?)\|([^\]]*?)\]\]", r"[[\1SAFEPIPE\2]]", raw)
    parts = safe.split("|")
    fields = {}
    for p in parts[1:]:
        if "=" in p:
            k, v = p.split("=", 1)
            k = k.strip().lower()
            v = v.strip().replace("SAFEPIPE", "|")
            if k:
                fields[k] = v
    if parts:
        fields["_name"] = parts[0].strip()
    return fields


def _find_balanced_template(text, start_pos=0):
    """Find the {{...}} block starting at or after start_pos. Tracks brace
    depth so nested templates are handled. Returns (start, end, inner) or
    None."""
    i = text.find("{{", start_pos)
    if i < 0:
        return None
    depth = 0
    j = i
    while j < len(text) - 1:
        if text[j:j+2] == "{{":
            depth += 1
            j += 2
        elif text[j:j+2] == "}}":
            depth -= 1
            j += 2
            if depth == 0:
                return (i, j, text[i+2:j-2])
        else:
            j += 1
    return None


def _strip_wikitext(s):
    """Clean wikitext → plain text."""
    if not s:
        return ""
    s = re.sub(r"<!--.*?-->", "", s, flags=re.DOTALL)
    s = re.sub(r"<ref[^>]*>.*?</ref>", "", s, flags=re.DOTALL)
    s = re.sub(r"<[^>]+>", "", s)
    prev = None
    while prev != s:
        prev = s
        s = re.sub(r"\{\|.*?\|\}", "", s, flags=re.DOTALL)
    prev = None
    while prev != s:
        prev = s
        s = re.sub(r"\{\{[^{}]*?\}\}", "", s, flags=re.DOTALL)
    # Strip dangling brace fragments.
    s = re.sub(r"\{\{[^\n]*", "", s)
    s = re.sub(r"\}\}", "", s)
    s = re.sub(r"^\s*\}\s*$", "", s, flags=re.MULTILINE)
    # Links [[target|display]] → display, with fallback to target when
    # display was emptied by a stripped template.
    s = re.sub(r"\[\[([^\]|]*?)\|\s*\]\]", r"\1", s)
    s = re.sub(r"\[\[([^\]|]*?)\|([^\]]+?)\]\]", r"\2", s)
    s = re.sub(r"\[\[([^\]]*?)\]\]", r"\1", s)
    # Dangling "[[target|" that lost its close due to template stripping.
    s = re.sub(r"\[\[([^\]|\n]*?)\|", r"\1 ", s)
    s = re.sub(r"\[\[", "", s)
    s = re.sub(r"\]\]", "", s)
    s = re.sub(r"\[https?://[^ \]]+ ([^\]]+)\]", r"\1", s)
    s = re.sub(r"\[https?://\S+", "", s)
    s = re.sub(r"(?im)^category:.*$", "", s)
    s = s.replace("'''", "").replace("''", "")
    s = re.sub(r"</?onlyinclude>", "", s)
    s = re.sub(r"<br\s*/?>", " ", s)
    s = re.sub(r"</?nowiki>", "", s)
    s = re.sub(r"[ \t]+", " ", s)
    s = re.sub(r"\n{3,}", "\n\n", s)
    return s.strip()


def _is_redirect_or_disambig(wikitext):
    if not wikitext:
        return True
    head = wikitext.lstrip()[:200].lower()
    return ("#redirect" in head or
            head.startswith("{{disambiguation") or
            head.startswith("{{category page header"))


# ── Ability descriptions ────────────────────────────────────────────────────

ABILITY_TEMPLATES = [
    # (template-name regex, desc-field-key)
    (r"Blue Magic",        "desc"),
    (r"Standard Magic",    "description"),
    (r"Job Ability",       "desc"),
    (r"Standard WS",       "description"),
    (r"Weapon Skill",      "description"),
    (r"Standard Ninjutsu", "desc"),
    (r"White Magic",       "desc"),
    (r"Black Magic",       "desc"),
    (r"Songs?",            "desc"),
]


def extract_ability_description(wikitext, max_chars=500):
    """Return a clean description for an ability page. Strategy:
      1. Parse known ability templates and extract their desc= or
         description= field, plus type/class/target/element/damage/level
         context. Works even when templates are nested.
      2. Italic-prose openers (like Hundred Fists' narration).
      3. Stripped-prose fallback, filtering footer noise."""
    if not wikitext or _is_redirect_or_disambig(wikitext):
        return ""

    # Strategy 1: known ability templates (including nested ones).
    for tpl_name, desc_key in ABILITY_TEMPLATES:
        pattern = r"\{\{\s*" + tpl_name + r"\b"
        for m in re.finditer(pattern, wikitext, re.IGNORECASE):
            tpl = _find_balanced_template(wikitext, m.start())
            if not tpl:
                continue
            _s, _e, content = tpl
            fields = _parse_template_fields(content)
            desc = fields.get(desc_key, "").strip()
            if not desc:
                continue
            clean = _strip_wikitext(desc)
            if not clean or len(clean) < 5:
                continue
            extras = []
            for k in ("type", "class", "target", "element", "damage",
                      "level", "family"):
                v = _strip_wikitext(fields.get(k, "").strip())
                if v and v.lower() not in ("n/a", "-"):
                    extras.append(f"{k.title()}: {v}")
            if extras:
                result = clean + " — " + " | ".join(extras[:4])
            else:
                result = clean
            if len(result) > max_chars:
                result = result[:max_chars].rsplit(" ", 1)[0] + "…"
            return result

    # Strategy 2: italic prose opener.
    italics = re.match(r"\s*''(.{20,500}?)''", wikitext, re.DOTALL)
    if italics:
        clean = _strip_wikitext(italics.group(1))
        if clean and len(clean) >= 20:
            if len(clean) > max_chars:
                clean = clean[:max_chars].rsplit(" ", 1)[0] + "…"
            return clean

    # Strategy 3: stripped-prose paragraph fallback.
    text = _strip_wikitext(wikitext)
    for para in text.split("\n\n"):
        p = para.strip()
        if not p or p.startswith("=") or len(p) < 30:
            continue
        low = p.lower()
        if (low.startswith("note: all") or low.startswith("main article")
                or low.startswith("see also") or low.startswith("image:")
                or low.startswith("file:") or "ffxidb" in low):
            continue
        if len(p) > max_chars:
            p = p[:max_chars].rsplit(" ", 1)[0] + "…"
        return p
    return ""


# ── Family pages: description + ability list ────────────────────────────────

def extract_family_description(wikitext):
    """Extract ecosystem info from Bestiary Description (new format) or
    Adversary Description (old format). Fallback to prose."""
    if not wikitext:
        return ""
    # Note: older "disambiguation" pages still have Adversary Description
    # after the disambiguation marker, so don't reject them outright.
    if _is_redirect_or_disambig(wikitext):
        if ("Adversary Description" not in wikitext and
                "Bestiary Description" not in wikitext):
            return ""

    for tpl_pattern in (r"\{\{\s*Bestiary Description\b",
                        r"\{\{\s*Adversary Description\b"):
        for m in re.finditer(tpl_pattern, wikitext, re.IGNORECASE):
            tpl = _find_balanced_template(wikitext, m.start())
            if not tpl:
                continue
            _s, _e, content = tpl
            fields = _parse_template_fields(content)
            ftype   = fields.get("type", "").strip()
            related = fields.get("related", "").strip()
            mjob    = (fields.get("main job", "") or
                       fields.get("main.job", "")).strip()
            sjob    = (fields.get("sub job", "") or
                       fields.get("sub.job", "")).strip()
            crystal = fields.get("crystal", "").strip()
            detects = fields.get("detects", "").strip()
            parts = []
            if ftype:   parts.append(f"Ecosystem: {ftype}")
            if mjob:    parts.append(f"Main Job: {mjob}")
            if sjob:    parts.append(f"Sub Job: {sjob}")
            if crystal: parts.append(f"Crystal: {crystal}")
            if detects: parts.append(f"Detects: {detects}")
            if related: parts.append(f"Related: {related}")
            if parts:
                return " | ".join(parts)

    text = _strip_wikitext(wikitext)
    for para in text.split("\n\n"):
        p = para.strip()
        if p and not p.startswith("=") and len(p) >= 30:
            return p[:400]
    return ""


def extract_family_abilities(wikitext):
    """Extract TP moves from a family page's Bestiary Abilities Rows. The
    rows are nested inside {{#ifeq:...}} blocks, so we pattern-scan for
    every row template anywhere in the text. Returns list of dicts:
    [{name, class, type, target, area, effect, shadows}, ...]"""
    if not wikitext:
        return []
    out = []
    seen = set()
    for m in re.finditer(r"\{\{\s*Bestiary Abilities Row\b",
                         wikitext, re.IGNORECASE):
        tpl = _find_balanced_template(wikitext, m.start())
        if not tpl:
            continue
        _s, _e, content = tpl
        fields = _parse_template_fields(content)
        name = _strip_wikitext(fields.get("abilities.name", "")).strip()
        if not name or len(name) < 2 or len(name) > 60:
            continue
        if name.lower() in seen:
            continue
        seen.add(name.lower())
        entry = {
            "name":    name,
            "class":   _strip_wikitext(fields.get("abilities.class", "")),
            "type":    _strip_wikitext(fields.get("abilities.type", "")),
            "target":  _strip_wikitext(fields.get("abilities.target", "")),
            "area":    _strip_wikitext(fields.get("abilities.area", "")),
            "effect":  _strip_wikitext(fields.get("abilities.effect", "")),
            "shadows": _strip_wikitext(fields.get("abilities.shadows", "")),
        }
        out.append(entry)
    return out


# ── Compatibility shims for the rest of the script ─────────────────────────
# The main() function below still calls extract_intro() (ability & family
# description) and extract_ability_list() (family's ability name list).
# These forwards preserve the old interface while using the new logic.

def extract_intro(wikitext, max_chars=600):
    """Alias for extract_ability_description. For family pages main() now
    uses extract_family_description directly."""
    return extract_ability_description(wikitext, max_chars)


def extract_ability_list(wikitext):
    """Return a list of ability NAMES found on a family page (for backward
    compat with the caller in main(), which will be updated to use the new
    structured form)."""
    entries = extract_family_abilities(wikitext)
    return [e["name"] for e in entries]


# ── Ability-name sanity filter ──────────────────────────────────────────────
# Many links inside "Special Attacks" sections are NOT monster TP moves.
# Reject status effects, stat/trait names, expansion abbreviations, and
# common English words that don't refer to an ability.

_ABILITY_NAME_BLOCKLIST = {
    # expansion abbreviations
    "cop", "toau", "wotg", "soa", "tom", "tvr", "rov",
    # common statuses that aren't the monster ability with the same name
    "poison", "silence", "sleep", "paralysis", "paralyze",
    "stun", "blind", "blindness", "bind", "petrification",
    "curse", "doom", "disease", "plague", "virus",
    "encumbrance", "amnesia", "terror", "charm", "weight", "slow", "haste",
    "knockback", "weakness", "attack down", "defense down",
    "magic defense down", "evasion down", "accuracy down",
    "magic accuracy down", "magic atk. bonus", "magic def. bonus",
    "intelligence down", "mind down", "vitality down", "agility down",
    "dexterity down", "strength down", "charisma down",
    "str down", "dex down", "vit down", "agi down",
    "int down", "mnd down", "chr down",
    "max hp down", "max mp down", "max tp down",
    # stat / trait categories
    "evasion bonus", "magic attack bonus", "magic defense bonus",
    "attack bonus", "defense bonus", "accuracy bonus",
    "vit", "str", "dex", "agi", "int", "mnd", "chr",
    "hp", "mp", "tp",
    # common spells that are often linked from monster pages but aren't
    # monster-unique abilities (most jobs can cast them)
    "protect", "shell", "regen", "stoneskin",
    "dispel", "erase", "haste", "slow", "silence", "dia", "banish",
    "fire", "ice", "blizzard", "stone", "water", "aero", "thunder",
    # random statuses that appeared in your first run
    "flash", "flash (status)", "paralyze (status)", "poison (status)",
    "sleep (status)", "silence (status)", "stun (status)", "slow (status)",
    # non-ability flavor words
    "spontaneity", "enmity", "tonberry hate", "orcish counterstance",
}

def _is_plausible_ability_name(name):
    """Filter out obvious non-ability wikilinks."""
    if not name:
        return False
    low = name.strip().lower()

    # Length sanity.
    if len(low) < 2 or len(low) > 50:
        return False

    # Namespace links.
    if any(low.startswith(p) for p in
           ("category:", "file:", "image:", "special:", "template:",
            "user:", "talk:", "help:")):
        return False

    # Blocklist.
    if low in _ABILITY_NAME_BLOCKLIST:
        return False
    if low.endswith("(status)") or low.endswith("(status effect)"):
        return False

    # Must contain at least one letter (filter out pure numbers/symbols).
    if not re.search(r"[a-z]", low):
        return False

    # Reject if the first word is a stat/status prefix followed by " down/up".
    if re.match(r"^(str|dex|vit|agi|int|mnd|chr|hp|mp|tp|evasion|"
                r"accuracy|attack|defense|magic)\s+(down|up|bonus)$", low):
        return False

    return True


def load_cache(path):
    if not os.path.exists(path):
        return {"abilities_wiki": {}, "families_wiki": {}}
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {"abilities_wiki": {}, "families_wiki": {}}


def save_cache(path, cache):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        json.dump(cache, f, indent=2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out",       default="data/mob_abilities.json",
                    help="Path for the final consolidated JSON file")
    ap.add_argument("--cache",     default="data/_mob_cache.json",
                    help="Resumable cache of raw wikitext fetched from BG-wiki")
    ap.add_argument("--rate",      type=float, default=1.2,
                    help="Minimum seconds between HTTP requests (respect site)")
    ap.add_argument("--families",  nargs="*", default=None,
                    help="Override the seed family list for a targeted scrape")
    ap.add_argument("--max", type=int, default=0,
                    help="Stop after this many requests (0 = no limit; useful for dry-runs)")
    args = ap.parse_args()

    # 1. Robots.txt check.
    allowed, robots_delay = check_robots(BG_WIKI_BASE)
    if not allowed:
        print("[fatal] BG-wiki's robots.txt disallows our intended paths. Aborting.")
        sys.exit(2)
    rate = max(args.rate, float(robots_delay or 0))
    print(f"[ok] Using rate limit of {rate:.2f}s per request.")

    cache = load_cache(args.cache)
    req_count = 0

    families = args.families or SEED_FAMILIES
    family_data = {}   # lowercase_key -> {display, description, abilities[]}
    ability_data = {}  # lowercase_key -> {display, description, families[]}

    # ── Pass 2 first: fetch each family page, extract ability lists ────────
    print(f"[pass2] Fetching {len(families)} family pages...")
    for idx, fam_title in enumerate(families, 1):
        if args.max and req_count >= args.max:
            print("[limit] Max request count reached; stopping.")
            break
        fam_key = fam_title.lower()
        wikitext = cache["families_wiki"].get(fam_title)
        if wikitext is None:
            print(f"  [{idx:3d}/{len(families)}] fetching: {fam_title}", flush=True)
            try:
                wikitext = fetch_page_wikitext(fam_title, rate) or ""
                cache["families_wiki"][fam_title] = wikitext
                req_count += 1
            except Exception as e:
                print(f"  [warn] {fam_title}: fetch failed ({e}) — skipped", flush=True)
                cache["families_wiki"][fam_title] = ""
                wikitext = ""
                save_cache(args.cache, cache)
        ability_entries = extract_family_abilities(wikitext)
        ability_list    = [e["name"] for e in ability_entries]
        description     = extract_family_description(wikitext)

        family_data[fam_key] = {
            "display":     fam_title,
            "description": description,
            "abilities":   [a.lower() for a in ability_list],
            "tp_moves":    ability_entries,
        }
        print(f"  [{idx:3d}/{len(families)}] {fam_title}: "
              f"{len(ability_list)} abilities, {len(description)} chars",
              flush=True)
        if idx % 5 == 0:
            save_cache(args.cache, cache)

    save_cache(args.cache, cache)

    # ── Pass 1: for each unique ability, fetch its BG-wiki page.
    # Sources: (a) abilities linked from family pages, (b) our curated seed
    # list of well-known monster TP moves. Each ability's `families` set
    # records which family pages referenced it (empty if only in seed).
    unique_abils = {}
    for fam_key, fam in family_data.items():
        for a in fam["abilities"]:
            if _is_plausible_ability_name(a):
                unique_abils.setdefault(a, set()).add(fam_key)
    # Include curated seed abilities even if no family linked to them.
    for seed in SEED_ABILITIES:
        if _is_plausible_ability_name(seed):
            unique_abils.setdefault(seed.lower(), set())

    print(f"[pass1] Fetching {len(unique_abils)} unique ability pages...", flush=True)
    for idx, (a_key, fam_keys) in enumerate(sorted(unique_abils.items()), 1):
        if args.max and req_count >= args.max:
            print("[limit] Max request count reached; stopping.")
            break
        # Title casing priority: (1) match in SEED_ABILITIES list (which has
        # the canonical capitalization we trust), (2) match from a family's
        # ability link, (3) plain .title() as last resort.
        display = None
        for seed in SEED_ABILITIES:
            if seed.lower() == a_key:
                display = seed
                break
        if not display:
            for fam_key in fam_keys:
                fam = family_data.get(fam_key, {})
                for orig in fam.get("abilities", []):
                    if orig.lower() == a_key:
                        display = orig  # preserve wiki's exact capitalization
                        break
                if display:
                    break
        display = display or a_key.title()

        wikitext = cache["abilities_wiki"].get(display)
        if wikitext is None:
            # Print BEFORE the fetch so if it hangs you can see the culprit.
            print(f"  [{idx:4d}/{len(unique_abils)}] fetching: {display}", flush=True)
            try:
                wikitext = fetch_page_wikitext(display, rate) or ""
                cache["abilities_wiki"][display] = wikitext
                req_count += 1
            except Exception as e:
                print(f"  [warn] {display}: fetch failed ({e}) — marking skipped", flush=True)
                # Store empty wikitext so re-runs skip this page, and also
                # save cache immediately so progress survives a crash.
                cache["abilities_wiki"][display] = ""
                wikitext = ""
                save_cache(args.cache, cache)
        description = extract_ability_description(wikitext, max_chars=500)

        # Filter: if the ability has no description AND isn't referenced by
        # any family, skip it entirely. These are usually 404s from bad seed
        # names (lowercase duplicates, expansion abbreviations like "cop"
        # that slipped through the seed list).
        if not description and not fam_keys:
            continue

        ability_data[a_key] = {
            "display":     display,
            "description": description,
            "families":    sorted(fam_keys),
        }
        if idx % 5 == 0:
            # Save cache more aggressively and flush so Windows shows output.
            save_cache(args.cache, cache)
            sys.stdout.flush()

    save_cache(args.cache, cache)

    # ── Write consolidated output.
    out = {
        "_meta": {
            "generated": datetime.now(timezone.utc).isoformat(),
            "source":    BG_WIKI_BASE,
            "abilities": len(ability_data),
            "families":  len(family_data),
            "rate_sec":  rate,
        },
        "families":  family_data,
        "abilities": ability_data,
    }
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2, sort_keys=True)

    print(f"[done] Wrote {args.out} "
          f"({len(family_data)} families, {len(ability_data)} abilities)")
    print(f"[done] Total requests: {req_count}")


if __name__ == "__main__":
    main()