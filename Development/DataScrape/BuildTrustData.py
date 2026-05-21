"""
build_trusts_fandom.py — Scrape FFXIclopedia (Fandom) for trust data.

Designed to run IN PARALLEL with the BG-wiki scrape — different host,
no shared rate-limit concerns. ~120 trust pages × ~3s/req ≈ 6 minutes
total runtime. Resumable via on-disk cache.

Usage:
    python build_trusts_fandom.py
    python build_trusts_fandom.py --refresh-list  (re-fetch the index)
    python build_trusts_fandom.py --skip-images   (data only)
    python build_trusts_fandom.py --limit 5       (test a few)
    python build_trusts_fandom.py --rate 5        (slower if needed)

Output:
    data/trusts.json                          (per-trust structured data)
    data/trust_portraits/<name>.png           (one per trust, original size)
    data/_trusts_fandom_cache.json            (resumable cache)

Per-trust data captured:
    name, job, role, race, weapon, obtained, casting_time, recast_time,
    job_abilities, job_traits, weapon_skills, spells, notable, dialogue,
    portrait_url, intro_text.

Notes on parsing:
    Fandom doesn't use templated infoboxes the way BG-wiki does — most
    trust data lives in prose with bullet/comma delimiters. The parser
    handles both shapes: structured templates if present, prose patterns
    as fallback. Prose patterns are based on the consistent format
    observed across multiple trust pages (Romaa Mihgo, Cornelia, Sylvie
    UC, Darrcuiln, Koru-Moru) — Job/Role/Race/Weapon as inline tokens,
    then "Job Abilities:", "Weapon Skills:", "Spells:", "Notable:",
    "Dialogue", "Summon:", "Dismiss:", "Death:" as section markers.
"""

import argparse
import io
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import urllib.robotparser

try:
    from PIL import Image
except ImportError:
    Image = None  # Optional — only needed for image processing


# ── Config ──────────────────────────────────────────────────────────────────

BASE_URL          = "https://ffxiclopedia.fandom.com"
API_URL           = BASE_URL + "/api.php"
ROBOTS_URL        = BASE_URL + "/robots.txt"
USER_AGENT        = "OmniWatch-TrustScraper/1.0 (Cooper; one-shot)"
DEFAULT_RATE_SEC  = 3.0          # Fandom doesn't publish a crawl-delay;
                                 # 3s is conservative-polite, faster than
                                 # BG-wiki's 30s but well under Fandom's
                                 # actual capacity.
REQUEST_TIMEOUT   = 20

CATEGORY_PAGE     = "Category:Trust"

DATA_DIR          = "data"
PORTRAIT_DIR      = os.path.join(DATA_DIR, "trust_portraits")
CACHE_PATH        = os.path.join(DATA_DIR, "_trusts_fandom_cache.json")
OUTPUT_PATH       = os.path.join(DATA_DIR, "trusts.json")


# ── HTTP helpers ────────────────────────────────────────────────────────────

def throttled_get(url, rate_sec, last_fetch=[0.0]):
    """Sleep so each request is at least rate_sec apart, then GET it.
    Returns (status, headers, body_bytes)."""
    wait = (last_fetch[0] + rate_sec) - time.time()
    if wait > 0:
        time.sleep(wait)
    last_fetch[0] = time.time()
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, {}, b""
    except Exception as e:
        print(f"  [http] error fetching {url}: {e}", flush=True)
        return 0, {}, b""


def check_robots(base_url):
    """Return crawl-delay (seconds) suggested by robots.txt, or default.
    Also confirms our User-Agent isn't disallowed from /api.php and /wiki/."""
    rp = urllib.robotparser.RobotFileParser()
    print(f"[robots] Fetching {base_url}/robots.txt ...")
    try:
        req = urllib.request.Request(f"{base_url}/robots.txt",
                                      headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as r:
            rp.parse(r.read().decode("utf-8", errors="replace").splitlines())
    except Exception as e:
        print(f"[robots] could not fetch ({e}); using default {DEFAULT_RATE_SEC}s.")
        return DEFAULT_RATE_SEC
    for path in ("/api.php", f"/wiki/{CATEGORY_PAGE}"):
        if not rp.can_fetch(USER_AGENT, base_url + path):
            print(f"[robots] DISALLOWED: {path} — aborting.")
            sys.exit(2)
    delay = rp.crawl_delay(USER_AGENT) or rp.crawl_delay("*")
    if delay:
        print(f"[robots] Crawl-delay = {delay}s (using max of that and default)")
        return max(float(delay), DEFAULT_RATE_SEC)
    print(f"[robots] No crawl-delay published; using default {DEFAULT_RATE_SEC}s.")
    return DEFAULT_RATE_SEC


def api_query(params, rate_sec):
    """Hit Fandom's MediaWiki API with the given params."""
    params.setdefault("format", "json")
    qs = urllib.parse.urlencode(params)
    url = f"{API_URL}?{qs}"
    status, _, body = throttled_get(url, rate_sec)
    if status != 200 or not body:
        return None
    try:
        return json.loads(body.decode("utf-8", errors="replace"))
    except json.JSONDecodeError as e:
        print(f"  [api] JSON parse error: {e}", flush=True)
        return None


def fetch_category_members(category, rate_sec):
    """Yield page titles in the given category, paginating with cmcontinue."""
    out = []
    cont = None
    while True:
        params = {
            "action":  "query",
            "list":    "categorymembers",
            "cmtitle": category,
            "cmlimit": 500,
            "cmtype":  "page",
        }
        if cont:
            params["cmcontinue"] = cont
        data = api_query(params, rate_sec)
        if not data:
            break
        members = ((data.get("query") or {}).get("categorymembers")) or []
        for m in members:
            title = m.get("title")
            if title:
                out.append(title)
        cont = (data.get("continue") or {}).get("cmcontinue")
        if not cont:
            break
    return out


def fetch_page_data(title, rate_sec):
    """Fetch wikitext + page image for a single page in one API call.
    Returns dict with 'wikitext' and 'image_url' keys (either may be empty)."""
    params = {
        "action":   "query",
        "titles":   title,
        "prop":     "revisions|pageimages",
        "rvprop":   "content",
        "rvslots":  "main",
        "piprop":   "original",
    }
    data = api_query(params, rate_sec)
    out = {"wikitext": "", "image_url": ""}
    if not data:
        return out
    pages = ((data.get("query") or {}).get("pages")) or {}
    for _pid, pdata in pages.items():
        if pdata.get("missing") is not None:
            continue
        revs = pdata.get("revisions", [])
        if revs:
            slots = revs[0].get("slots", {})
            main  = slots.get("main", {})
            out["wikitext"] = main.get("*") or revs[0].get("*") or ""
        original = pdata.get("original")
        if original:
            out["image_url"] = original.get("source", "")
    return out


# ── Trust filter ────────────────────────────────────────────────────────────

# Category:Trust contains both quest pages and actual trust pages. Quest
# pages we want to exclude — they describe how to acquire trusts, not
# the trusts themselves.
NON_TRUST_PAGES = {
    "Trust", "Trust: Bastok", "Trust: San d'Oria", "Trust: Windurst",
    "Trust Magic", "Trust Checklist", "Trust Permits", "Trust Initiative",
    "Cipher", "Trust Master Key Item",
}


def is_trust_page(title):
    """True if this is a real per-trust page (e.g. 'Trust: Romaa Mihgo'),
    not a quest/meta page."""
    if title in NON_TRUST_PAGES:
        return False
    # Real trust pages start with 'Trust: ' followed by a name. Quest
    # pages either have no colon (just 'Trust') or are listed above.
    if not title.startswith("Trust: "):
        return False
    name = title.split(":", 1)[1].strip()
    if not name:
        return False
    # Quest pages are nation names — skip those.
    if name in {"Bastok", "San d'Oria", "Windurst"}:
        return False
    return True


# ── Wikitext parsing ────────────────────────────────────────────────────────
# Fandom trust pages are inconsistent — some have infobox templates, most
# are plain prose with consistent delimiter conventions. We try templates
# first, fall back to prose patterns.

def _strip_wikitext(s):
    """Clean wikitext → plain text. Removes templates, links, HTML."""
    if not s:
        return ""
    s = re.sub(r"<!--.*?-->", "", s, flags=re.DOTALL)
    s = re.sub(r"<ref[^>]*>.*?</ref>", "", s, flags=re.DOTALL)
    s = re.sub(r"<[^>]+>", "", s)
    # Strip nested templates (innermost first, repeatedly).
    prev = None
    while prev != s:
        prev = s
        s = re.sub(r"\{\{[^{}]*?\}\}", "", s, flags=re.DOTALL)
    s = re.sub(r"\{\{[^\n]*", "", s)
    s = re.sub(r"\}\}", "", s)
    # Links.
    s = re.sub(r"\[\[([^\]|]*?)\|\s*\]\]", r"\1", s)
    s = re.sub(r"\[\[([^\]|]*?)\|([^\]]+?)\]\]", r"\2", s)
    s = re.sub(r"\[\[([^\]]*?)\]\]", r"\1", s)
    s = re.sub(r"\[\[", "", s)
    s = re.sub(r"\]\]", "", s)
    s = re.sub(r"\[https?://[^ \]]+ ([^\]]+)\]", r"\1", s)
    s = re.sub(r"\[https?://\S+\]?", "", s)
    s = re.sub(r"(?im)^category:.*$", "", s)
    s = s.replace("'''", "").replace("''", "")
    s = re.sub(r"<br\s*/?>", " ", s)
    s = re.sub(r"[ \t]+", " ", s)
    s = re.sub(r"\n{3,}", "\n\n", s)
    return s.strip()


def _extract_categories(wikitext):
    """Return list of [[Category:X]] tags from the page."""
    cats = []
    for m in re.finditer(r"\[\[\s*Category\s*:\s*([^\]\|]+?)\s*[\]\|]",
                         wikitext, re.IGNORECASE):
        cats.append(m.group(1).strip())
    return cats


def _race_from_categories(cats):
    """Infer race from category tags. Pages tag themselves like
    [[Category:Mithra NPCs]], [[Category:Hume NPCs]], etc."""
    races = ["Hume", "Elvaan", "Tarutaru", "Mithra", "Galka",
             "Beast", "Demon", "Goblin", "Tonberry", "Soulflayer",
             "Moogle", "Dragon"]
    for cat in cats:
        for r in races:
            if cat.startswith(r + " ") or cat == f"{r} NPCs":
                return r
    return ""


_FFXI_JOB_FULL_TO_ABBREV = {
    "warrior": "WAR", "monk": "MNK", "white mage": "WHM", "black mage": "BLM",
    "red mage": "RDM", "thief": "THF", "paladin": "PLD", "dark knight": "DRK",
    "beastmaster": "BST", "bard": "BRD", "ranger": "RNG", "samurai": "SAM",
    "ninja": "NIN", "dragoon": "DRG", "summoner": "SMN", "blue mage": "BLU",
    "corsair": "COR", "puppetmaster": "PUP", "dancer": "DNC", "scholar": "SCH",
    "geomancer": "GEO", "rune fencer": "RUN",
}
# Abbreviation set (for accepting either input form unchanged)
_FFXI_JOB_ABBREVS = set(_FFXI_JOB_FULL_TO_ABBREV.values())


def _normalize_job(s):
    """Convert any FFXI job name to its 3-letter abbreviation. Accepts
    either full names ('Warrior') or abbreviations ('WAR'). Returns the
    input unchanged if not recognized (e.g. 'Chemist', 'Adventurer')."""
    if not s:
        return ""
    s = s.strip()
    low = s.lower()
    if low in _FFXI_JOB_FULL_TO_ABBREV:
        return _FFXI_JOB_FULL_TO_ABBREV[low]
    upper = s.upper()
    if upper in _FFXI_JOB_ABBREVS:
        return upper
    return s   # unrecognized — return as-is


def _find_balanced_template(text, start_pos=0):
    """Return (start, end, inner) for the next {{...}} from start_pos,
    tracking brace depth so nested templates don't break us."""
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


def _parse_template_fields(raw):
    """Parse |key=value parts of a template body. Returns dict with
    lowercased keys, stripped values. Pipes inside [[links]] and
    nested {{templates}} are protected during the split."""
    # Protect pipes inside [[links]].
    safe = re.sub(r"\[\[([^\]]*?)\|([^\]]*?)\]\]",
                  r"[[\1SAFEPIPE\2]]", raw)
    # Also protect pipes inside nested {{templates}}.
    # Walk character by character, replacing pipes only at depth==0.
    out_chars = []
    depth = 0
    i = 0
    while i < len(safe):
        c = safe[i]
        if c == "{" and i + 1 < len(safe) and safe[i+1] == "{":
            depth += 1
            out_chars.append("{{")
            i += 2
            continue
        if c == "}" and i + 1 < len(safe) and safe[i+1] == "}":
            depth -= 1
            out_chars.append("}}")
            i += 2
            continue
        if c == "|" and depth > 0:
            out_chars.append("SAFEPIPE")
            i += 1
            continue
        out_chars.append(c)
        i += 1
    safe = "".join(out_chars)
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


def _find_trust_template(wikitext):
    """Locate the {{TrustNPC|...}} template and return its inner body,
    or '' if not found. Pages may have leading templates ({{Trust II|...}},
    {{Disambig3|...}}, {{spoiler}}, etc.) before the TrustNPC block.
    We walk all top-level templates and return the first one whose head
    name matches 'trustnpc'."""
    pos = 0
    while True:
        found = _find_balanced_template(wikitext, pos)
        if not found:
            return ""
        start, end, inner = found
        pos = end
        head = inner.strip().split("|", 1)[0].strip().lower()
        # Some pages use 'TrustNPC II' or similar variants.
        if head == "trustnpc" or head.startswith("trustnpc "):
            return inner
    return ""


# Section-name patterns for decomposing the Notes field. Each maps a
# section heading (case-insensitive) to its destination key in the
# output record. We match the wiki's own bullet-bold convention:
#   *'''Job Abilities:''' [[Steal]], [[Sneak Attack]]...
# The keys are searched in declaration order; first match wins.
# Section-heading regexes. Three formal variants observed across the corpus:
#
#   Variant 1 (most common): bullet + bold + colon-inside-or-outside-quotes
#       *'''Job Abilities:''' [[Steal]], [[Sneak Attack]]
#       *'''Spells''': single-target nukes
#
#   Variant 2 (Iroha-style): no leading bullet, just bold heading at line start
#       '''Job Traits:'''
#       *[[Save TP]]
#
#   Variant 3 (Klara-style): bullet + plain-text label + colon, no bold at all
#       *Job abilities: [[Berserk]], [[Warcry]]
#
# All variants strip up through the colon (and optional space after) so the
# caller's tail-content starts cleanly. We also support the rare "(level)"
# parenthetical that follows Job Abilities / Spells in some pages.
_NOTES_SECTIONS = [
    # Variant 1: bullet + bold
    ("job_abilities",  re.compile(r"^\s*\*+\s*'''\s*Job Abilities?\s*:?\s*'''(?:\s*\([^)]*\))?\s*:?\s*",
                                   re.IGNORECASE)),
    ("job_traits",     re.compile(r"^\s*\*+\s*'''\s*Job Traits?\s*:?\s*'''\s*:?\s*",
                                   re.IGNORECASE)),
    ("weapon_skills",  re.compile(r"^\s*\*+\s*'''\s*Weapon Skills?\s*:?\s*'''\s*:?\s*",
                                   re.IGNORECASE)),
    ("spells",         re.compile(r"^\s*\*+\s*'''\s*Spells?\s*:?\s*'''(?:\s*\([^)]*\))?\s*:?\s*",
                                   re.IGNORECASE)),
    ("notable",        re.compile(r"^\s*\*+\s*'''\s*Notable\s*:?\s*'''\s*:?\s*",
                                   re.IGNORECASE)),
    # Variant 2: no bullet, bold only (Iroha)
    ("job_abilities",  re.compile(r"^\s*'''\s*Job Abilities?\s*:?\s*'''\s*:?\s*$",
                                   re.IGNORECASE)),
    ("job_traits",     re.compile(r"^\s*'''\s*Job Traits?\s*:?\s*'''\s*:?\s*$",
                                   re.IGNORECASE)),
    ("weapon_skills",  re.compile(r"^\s*'''\s*Weapon Skills?\s*:?\s*'''\s*:?\s*$",
                                   re.IGNORECASE)),
    ("spells",         re.compile(r"^\s*'''\s*Spells?\s*:?\s*'''\s*:?\s*$",
                                   re.IGNORECASE)),
    ("notable",        re.compile(r"^\s*'''\s*Notable\s*:?\s*'''\s*:?\s*$",
                                   re.IGNORECASE)),
    # Variant 3: bullet + plain label + colon, no bold (Klara)
    # The label MUST be followed by content on the same line — otherwise
    # we'd mis-fire on prose like "*Casts the following spells:".
    ("job_abilities",  re.compile(r"^\s*\*+\s*Job Abilities?\s*:\s+",
                                   re.IGNORECASE)),
    ("job_traits",     re.compile(r"^\s*\*+\s*Job Traits?\s*:\s+",
                                   re.IGNORECASE)),
    ("weapon_skills",  re.compile(r"^\s*\*+\s*Weapon Skills?\s*:\s+",
                                   re.IGNORECASE)),
    ("spells",         re.compile(r"^\s*\*+\s*Spells?\s*:\s+",
                                   re.IGNORECASE)),
]

_DIALOGUE_RX = [
    ("summon",  re.compile(r"\*\s*Summon\s*:\s*['\"]?([^\n*]+?)['\"]?\s*$",
                            re.IGNORECASE | re.MULTILINE)),
    ("dismiss", re.compile(r"\*\s*Dismiss\s*:\s*['\"]?([^\n*]+?)['\"]?\s*$",
                            re.IGNORECASE | re.MULTILINE)),
    ("death",   re.compile(r"\*\s*Death\s*:\s*['\"]?([^\n*]+?)['\"]?\s*$",
                            re.IGNORECASE | re.MULTILINE)),
]


def _decompose_notes(notes_text):
    """Take the Notes field body (bullet-listed sections) and split it
    into section-name → bullet-content mapping. Returns dict keyed by
    section name (job_abilities, weapon_skills, etc.).

    Walks line by line; when we hit a bullet whose text starts with a
    bolded section name like '''Job Abilities:''', we begin capturing
    that section and continue until the next section heading, a
    '''Dialogue''' heading, or end of string. Sub-bullets (** or
    deeper) belong to the current section.
    """
    sections = {}
    lines = notes_text.splitlines()
    current_key  = None
    current_lines = []

    # Terminator: any line containing '''Dialogue''' (with optional whitespace)
    # ends section capture. Also any line that's just "}}" or starts a new
    # template like {{TrustNavBox}}.
    dialogue_terminator = re.compile(r"^\s*'''\s*Dialogue\s*'''\s*$",
                                      re.IGNORECASE)
    template_terminator = re.compile(r"^\s*\{\{[A-Za-z]")

    def flush():
        nonlocal current_key, current_lines
        if current_key:
            sections[current_key] = "\n".join(current_lines).strip()
        current_key = None
        current_lines = []

    # Generic-heading sniffer: detects any *'''Word:'''-shaped line, even
    # if it's not one of our recognized sections. Used as a flush
    # terminator so unrecognized sections (e.g. Synergy, Combos, Notes)
    # don't bleed their content into the previous recognized section.
    generic_heading = re.compile(
        r"^\s*(?:\*+\s*)?'''[^']{1,40}:?'''\s*:?\s*",
        re.IGNORECASE)
    # Bulleted non-list-content prefixes — these are conditional or
    # explanatory bullets, not enumerable items, so we skip them.
    nonlist_prefixes = re.compile(
        r"^\s*\*+\s*(?:During|When|If|Note|Per|Will|May|This|These)\b",
        re.IGNORECASE)

    for ln in lines:
        # Hard terminator → flush and stop capturing.
        if dialogue_terminator.match(ln) or template_terminator.match(ln):
            flush()
            continue

        # Detect section headings. A line could be a heading if it starts
        # with a bullet (Variants 1 & 3) or with a bold marker (Variant 2).
        # We check all _NOTES_SECTIONS regexes and the first match wins.
        new_key = None
        head_strip_len = 0
        if re.match(r"^\s*(?:\*+\s*)?'''", ln) or re.match(r"^\s*\*+\s*[A-Za-z]", ln):
            for sec_key, rx in _NOTES_SECTIONS:
                m = rx.match(ln)
                if m:
                    new_key = sec_key
                    head_strip_len = m.end()
                    break

        if new_key:
            flush()
            current_key = new_key
            tail = ln[head_strip_len:].strip()
            if tail:
                current_lines.append(tail)
        else:
            # Unrecognized heading-shaped line ('''Synergy:''', etc.) —
            # treat as flush terminator without starting a new section.
            if generic_heading.match(ln):
                flush()
                continue
            if current_key is not None:
                # Plain bulleted dialogue inside notes ("* Summon: ...")
                # is not part of a section — terminates capture.
                if re.match(r"^\s*\*\s+(?:Summon|Dismiss|Death)\s*[:(]",
                            ln, re.IGNORECASE):
                    flush()
                    continue
                # Drop conditional/explanatory bullets that aren't list
                # items themselves. ("**During X will do Y" — not a spell.)
                if nonlist_prefixes.match(ln):
                    continue
                current_lines.append(ln)

    flush()
    return sections


def _split_list(value):
    """Convert list-shaped wiki content into a clean list of names.

    Handles patterns observed across Fandom trust pages:
      1. Bulleted item per line — single OR sub-bullet, with or without
         trailing skillchain/description prose:
            *[[Third Eye]]
            **[[Aurous Charge]]: Liquefaction/Transfixion skillchain
            **[[Howling Gust]]: Fragmentation...
      2. Bullet form with school labels (Koru-Moru):
            **''Enfeebling:'' [[Dia III]], [[Slow II]], [[Dispel]]
            **''Enhancing:'' [[Protect V]], [[Shell V]], ...
         → flatten to ["Dia III", "Slow II", "Dispel", "Protect V", ...]
      3. Comma form on a single line (no bullets):
            [[Steal]], [[Sneak Attack]], [[Trick Attack]], and [[Feint]].
      4. Mixed (heading line has commas, then bullets nested below)
      5. "None (does not melee)" → empty list

    Returns deduped list of names with parentheticals/skillchain props
    stripped down to just the entity name.
    """
    if not value:
        return []

    # Classify each non-empty line. A line that starts with one or more
    # asterisks is a list item (which we'll process individually). All
    # other lines are joined into an "inline" buffer for comma/and-split.
    bullet_lines = []
    inline_lines = []
    for ln in value.splitlines():
        s = ln.strip()
        if not s:
            continue
        if s.startswith("*"):
            # Strip leading asterisks (any depth) + spaces.
            stripped = re.sub(r"^\*+\s*", "", s).strip()
            if stripped:
                bullet_lines.append(stripped)
        else:
            inline_lines.append(s)

    items = []

    # Negation prefix: "Does not cast [[X]], [[Y]]" describes what the trust
    # DOESN'T do, so the inner links aren't real abilities/spells.
    negation_rx = re.compile(
        r"^\s*(?:does\s*not|cannot|can't|won't|will\s*not|never)\b",
        re.IGNORECASE)

    for bl in bullet_lines:
        # Skip negation-flavored bullets entirely.
        if negation_rx.match(bl):
            continue
        # Strip leading italic-quoted label like "''School:''" if present.
        # (Koru-Moru-style spell schools.)
        bl_stripped = re.sub(r"^''[^']+''\s*:?\s*", "", bl).strip()

        # If the bullet contains wikilinks, just extract those — the prose
        # connective tissue ("and", "Does not cast the lower tier versions
        # of", etc.) is unreliable for splitting and produces noise.

        # Special case first: "[[Name]]: descriptive prose" — the colon
        # introduces a description of Name, not a list. Take only Name
        # (Darrcuiln "**[[Howling Gust]]: Fragmentation/Compression
        # skillchain properties and deals [[Wind]] damage." → Howling
        # Gust only, not Wind).
        sb_named_desc = re.match(
            r"^\s*\[\[([^\]\|]+?)(?:\|[^\]]+)?\]\]\s*(?:\([^)]*\))?\s*:",
            bl_stripped)
        if sb_named_desc:
            items.append(sb_named_desc.group(1))
            continue

        # Plain-text named sub-bullet: "Mix: Guard Drink - Applies..."
        # or "Hyper Potion - Restores 250 HP". The ability name is what
        # comes before the first hyphen-separator or trailing prose.
        # Pattern: optional prefix label + colon, then NAME, then either
        # " - " separator (dash-introduced description) or "(...)" annotation
        # or end of meaningful text.
        # We DON'T fire this if the bullet contains [[wikilinks]] (those
        # are handled below by the link-extraction path), only when the
        # bullet is purely plain-text.
        if not re.search(r"\[\[", bl_stripped):
            # Match "Word: Name [-(].* " or "Word: Name $"
            plain_named = re.match(
                r"^\s*([A-Z][A-Za-z]+(?:[-:'\s][A-Z][A-Za-z\-']+)*)\s+(?:[-—–]|\()",
                bl_stripped)
            if plain_named:
                name = plain_named.group(1).strip()
                if 1 <= len(name.split()) <= 5:
                    items.append(name)
                    continue
            # Bare "Word: Name" with no separator (single-line sub-bullet)
            plain_namedonly = re.match(
                r"^\s*([A-Z][A-Za-z]+(?::\s+[A-Z][A-Za-z\-']+)*)\s*\.?\s*$",
                bl_stripped)
            if plain_namedonly:
                name = plain_namedonly.group(1).strip()
                if 1 <= len(name.split()) <= 5:
                    items.append(name)
                    continue

        link_matches = re.findall(r"\[\[([^\]\|]+?)(?:\|[^\]]+)?\]\]", bl_stripped)
        if len(link_matches) >= 1:
            # Trim the bullet body at the first negation phrase to avoid
            # picking up "Does not cast [[X]]" entries — the X there isn't
            # a real ability/spell (e.g. Iroha "[[Protectra V]] and
            # [[Shellra V]] Does not cast the lower tier versions of
            # [[Protectra]] and [[Shellra]]" → keep only the first two).
            body_until_negation = re.split(
                r"\b(?:[Dd]oes not|[Cc]annot|[Cc]an't|[Ww]on't|[Ww]ill not|[Nn]ever)\b",
                bl_stripped, maxsplit=1)[0]
            link_matches = re.findall(r"\[\[([^\]\|]+?)(?:\|[^\]]+)?\]\]", body_until_negation)
            for ln_text in link_matches:
                # Drop parenthetical-only links like "(one [[Reraise]])"
                # — those are annotations, not list members. We detect
                # this by checking if the link sits inside a (...) span.
                link_pos = body_until_negation.find(f"[[{ln_text}")
                if link_pos < 0:
                    link_pos = body_until_negation.find(ln_text)
                if link_pos >= 0:
                    before = body_until_negation[:link_pos]
                    after  = body_until_negation[link_pos:]
                    # Count unmatched ( before and ) after this link.
                    open_parens  = before.count("(") - before.count(")")
                    if open_parens > 0:
                        # We're inside a paren group; check if it closes
                        # in `after`.
                        if ")" in after:
                            # Yes, we're inside a parenthetical → skip.
                            continue
                items.append(ln_text)
            continue

        # No wikilinks — fall back to comma/and-split on the prose, since
        # some bullets are pure plain-text (rare but happens).
        if "," in bl_stripped or " and " in bl_stripped:
            plain = _strip_wikitext(bl_stripped).strip()
            plain = re.sub(r"\s+and\s+", ",", plain)
            for piece in re.split(r"[,;]", plain):
                items.append(piece)
        else:
            items.append(bl_stripped)

    # Non-bulleted inline content: comma-and split.
    inline_text = " ".join(inline_lines)
    if inline_text:
        cleaned = re.sub(r"\s*\([^)]*\)\s*", "", inline_text).strip(" .,;:")
        if cleaned.lower() in ("none", "n/a", "na", "?"):
            inline_text = ""
    if inline_text:
        plain = _strip_wikitext(inline_text).strip()
        plain = re.sub(r"\s+and\s+", ",", plain)
        for piece in re.split(r"[,;]", plain):
            items.append(piece)

    out = []
    for raw in items:
        s = _strip_wikitext(raw).strip(" .,;:'\"")
        if not s:
            continue
        if s.lower() in ("none", "n/a", "na", "?", "conversely"):
            continue
        # Strip trailing skill-chain / level annotations.
        s = re.sub(r"\s*\([^)]*\)\s*$", "", s)
        # If a colon remains, decide whether to keep or strip what follows:
        #   "Amatsu: Hanadoki"            → keep (proper-noun continuation)
        #   "Mix: Guard Drink"             → keep (Monberaux-style multi-word name)
        #   "Aurous Charge: Liquefaction"  → strip (descriptive skillchain note)
        #   "Provoke: at level 5"          → strip (level annotation)
        # Heuristic: if EVERY word after the colon is capitalized and the
        # tail is short (1-3 words), it's part of the name; keep the whole
        # thing. Otherwise, drop the tail.
        if ":" in s:
            head, tail = s.split(":", 1)
            head = head.strip()
            tail = tail.strip()
            tail_words = tail.split()
            keep_tail = (
                tail_words
                and len(tail_words) <= 3
                and all(w[:1].isupper() for w in tail_words if w)
            )
            if keep_tail:
                s = head + ": " + tail
            else:
                s = head
        s = s.strip(" .,;:'\"")
        if not s:
            continue
        # Reject prose-fragment tokens. Real entries are typically 1-3
        # words; >3 words usually means we picked up a descriptive
        # phrase ("AoE damage", "Does not cast Ancient Magic").
        wc = len(s.split())
        if wc > 4:
            continue
        # First character must be a letter — real spell/ability names
        # always start with an uppercase letter in FFXI's localization.
        # This filters: '000 gil)' (digit), '+220 Defense' (punct),
        # '?' (punct), prose fragments starting with whitespace.
        if not s or not s[0].isalpha():
            continue
        if s[0].islower():
            continue
        # Reject items with unbalanced closing parens — strong signal
        # that we picked up a fragment from prose like "100,000 gil)".
        if s.count(")") > s.count("("):
            continue
        # Reject lines that are obviously prose continuations, not items.
        prose_markers = (
            r"\b(party|while|in the|does not|cast|melee|nor|and|or|the|a|an)\b"
        )
        # If MORE THAN HALF the words are prose-markers, skip it.
        words = s.split()
        marker_count = sum(1 for w in words
                            if re.fullmatch(prose_markers, w, re.IGNORECASE))
        if words and marker_count >= len(words) / 2:
            continue
        # Specific noise tokens picked up from sub-bullet prose tails.
        if s.lower() in ("aoe damage", "aoe", "damage"):
            continue
        if s not in out:
            out.append(s)
    return out


# Generic-page link names that pop up as wiki cross-references but
# aren't actual abilities/spells/traits. We strip these from any
# extracted list to keep the output clean. Note: we deliberately do
# NOT include real spell/ability names that happen to share words
# with categories ("Haste" is both a category page AND a real spell;
# context will sort them out via the dedup logic).
_GENERIC_LINK_NOISE = {
    "job trait", "job traits", "job ability", "job abilities",
    "weapon skill", "weapon skills", "spell", "spells",
    "status effect", "damage over time", "dot", "cone attack",
    "area of effect", "aoe", "knockback", "single target",
    "alter ego", "alter egos", "trust",
    # Damage-element status pages (the elements themselves are not
    # spells, even when linked in skillchain prose)
    "darkness", "physical", "magical",
    # Generic stat names that get linked
    "attack boost", "defense boost", "magic attack boost",
    "magic defense bonus",
    # Weapon type pages — appear in "Uses a [[Sword]]" prose but
    # aren't abilities. The weapon's name and type live in the
    # `weapon` field of the TrustNPC infobox, not in abilities.
    "sword", "swords", "great sword", "great swords",
    "axe", "axes", "great axe", "great axes",
    "club", "clubs", "staff", "staves",
    "dagger", "daggers", "polearm", "polearms",
    "katana", "great katana", "great katanas",
    "bow", "bows", "crossbow", "crossbows",
    "gun", "guns", "marksmanship",
    "scythe", "scythes", "hand-to-hand", "fists",
    "wand", "wands", "shield", "shields",
}


def _prose_fallback_extract(notes_text):
    """Best-effort extraction from free-form Notes when no formal
    `*'''Section:'''` headings exist. Used for ~40 trusts whose Fandom
    pages describe behavior in prose bullets.

    Strategy: walk bullets and classify each by verb prefix:
        "Casts X" / "Casts up to X" / "Cast X"   → spells
        "Has X" / "Has the X"                     → traits
        "Uses X" / "Will use X"                    → abilities
        "**[[X]]: descriptive prose"               → weapon skills

    Inside each line, only [[wikilinks]] are taken (extracts are too
    noisy without that anchor). A "ws-context" sub-bullet rule fires
    when a parent line says "Uses the following weapon skills" / "WSs:"
    / "Uses X unique weapon skills" — subsequent **[[Y]] sub-bullets
    are then treated as WS regardless of generic shape.

    Returns dict {job_abilities, weapon_skills, spells, job_traits}
    populated with deduped link-text lists. Empty lists are valid
    output for trusts whose prose is truly unstructured (e.g.
    Cornelia, Kupofried).
    """
    spells = []
    abilities = []
    traits = []
    ws = []

    lines = notes_text.splitlines()
    in_ws_context = False    # Set true after "Uses the following weapon skills"

    casts_rx = re.compile(r"^\s*\*+\s*Casts?\b", re.IGNORECASE)
    has_rx   = re.compile(r"^\s*\*+\s*Has\s+(?:the\s+)?\[\[",   re.IGNORECASE)
    uses_rx  = re.compile(r"^\s*\*+\s*(?:Uses|Will use)\s+(?:the\s+)?\[\[",
                           re.IGNORECASE)
    ws_announce_rx = re.compile(
        r"\b(?:weapon skills?|WSs?)\b\s*:?\s*$|"
        r"Uses\s+(?:the\s+following|\w+\s+(?:unique\s+)?)?weapon skills?",
        re.IGNORECASE)

    # Sub-bullet shapes that flag a weapon skill regardless of context:
    # "**[[Name]]: descriptive prose"
    sb_named_desc = re.compile(
        r"^\s*\*\*+\s*\[\[([^\]\|]+?)(?:\|[^\]]+)?\]\]\s*(?:\([^)]*\))?\s*:")
    # "**[[Name]]" (just a sub-bullet link, no description) → list item
    # of whatever the parent context implies.
    sb_just_link = re.compile(
        r"^\s*\*\*+\s*\[\[([^\]\|]+?)(?:\|[^\]]+)?\]\]\s*$")

    def extract_links(text):
        """All wikilinks in text, in order, with display-text preferred
        over the target page name. Filters generic-noise links."""
        out = []
        for m in re.finditer(r"\[\[([^\]\|]+?)(?:\|([^\]]+))?\]\]", text):
            tgt   = m.group(1).strip()
            disp  = (m.group(2) or "").strip()
            name  = disp if disp else tgt
            # Strip "(Status Effect)", "(Job Trait)", etc. parenthetical
            # disambiguators on the wiki page name.
            name = re.sub(r"\s*\([^)]*\)\s*$", "", name).strip()
            if not name:
                continue
            if name.lower() in _GENERIC_LINK_NOISE:
                continue
            out.append(name)
        return out

    for ln in lines:
        s = ln.strip()
        if not s:
            continue

        # Hard terminator: dialogue heading or template close.
        if re.match(r"^\s*'''\s*Dialogue\s*'''", s, re.IGNORECASE):
            break
        if s.startswith("{{"):
            # template block ({{UnityTrust}}, {{PassiveTrust}}, etc.) —
            # skip but don't break (it might be inline with content).
            continue

        # Sub-bullet "**[[X]]: ..." → always a WS.
        sb_m = sb_named_desc.match(s)
        if sb_m:
            ws.append(sb_m.group(1))
            continue
        # Sub-bullet just-link → assigned by current context.
        sj_m = sb_just_link.match(s)
        if sj_m:
            if in_ws_context:
                ws.append(sj_m.group(1))
            continue

        # WS-context announcement: lines like "Uses the following weapon
        # skills:" / "WSs:" / "Uses four unique weapon skills." flip the
        # ws_context flag so subsequent "**[[X]]" sub-bullets are routed
        # to weapon_skills. We check this BEFORE the strict uses_rx so
        # an announcement without a link still triggers context.
        if (re.match(r"^\s*\*+\s*Uses\s+", s, re.IGNORECASE)
                and ws_announce_rx.search(s)):
            in_ws_context = True
            # Inline links on the announcement line are also WS.
            for nm in extract_links(s):
                if nm not in ws:
                    ws.append(nm)
            continue

        # Top-level bullet — verb-prefix classification.
        if casts_rx.match(s):
            for nm in extract_links(s):
                if nm not in spells:
                    spells.append(nm)
            in_ws_context = False
            continue
        if has_rx.match(s):
            for nm in extract_links(s):
                if nm not in traits:
                    traits.append(nm)
            in_ws_context = False
            continue
        if uses_rx.match(s):
            # Strict "Uses [[X]]" or "Uses the [[X]]" → abilities.
            for nm in extract_links(s):
                if nm not in abilities:
                    abilities.append(nm)
            in_ws_context = False
            continue

        # Lines starting with "WSs:" / "Weapon Skills:" (Cid-style)
        if re.match(r"^\s*\*+\s*(?:WSs?|Weapon Skills?)\s*:", s, re.IGNORECASE):
            for nm in extract_links(s):
                if nm not in ws:
                    ws.append(nm)
            in_ws_context = True
            continue

        # Top-level bullet that doesn't fit any verb pattern: leave
        # context alone but don't extract anything. (These are usually
        # behavior-narrative lines like "Keeps his distance...".)
        in_ws_context = False

    return {
        "job_abilities":  abilities,
        "weapon_skills":  ws,
        "spells":         spells,
        "job_traits":     traits,
    }


def parse_trust_page(title, wikitext):
    """Parse a Fandom trust page's wikitext into a structured record.

    Strategy: locate the {{TrustNPC|...}} infobox template and parse
    its named fields (image, alter ego, job, role, race, weapon,
    Obtained, Notes). The Notes field is bullet-decomposed into
    section sub-fields (Job Abilities, Weapon Skills, Spells, Notable,
    Job Traits). Dialogue lines are parsed from the raw wikitext
    regardless of where they sit (inside Notes, after the template,
    or in their own '''Dialogue''' section)."""
    rec = {
        "name":              title.replace("Trust: ", "").replace("Trust:_", "").strip(),
        "alter_ego":         "",
        "job":               "",      # raw "MAIN/SUB" string for display
        "main_job":          "",      # parsed main job
        "sub_job":           "",      # parsed sub job (may be empty)
        "role":              "",
        "race":              "",
        "weapon":            "",
        "obtained":          "",
        "casting_time":      "5 seconds",   # constant for all trusts
        "recast_time":       "240 seconds", # constant for all trusts
        "job_abilities":     [],
        "job_traits":        [],
        "weapon_skills":     [],
        "spells":            [],
        "spells_raw":        "",
        "weapon_skills_raw": "",
        "notable":           "",
        "dialogue":          {},
        "intro_text":        "",
        "categories":        [],
    }
    if not wikitext:
        return rec
    if wikitext.lstrip()[:100].lower().startswith("#redirect"):
        return rec

    rec["categories"] = _extract_categories(wikitext)
    if not rec["race"]:
        rec["race"] = _race_from_categories(rec["categories"])

    # Find and parse the TrustNPC template.
    inner = _find_trust_template(wikitext)
    if inner:
        f = _parse_template_fields(inner)
        rec["alter_ego"] = _strip_wikitext(f.get("alter ego", "")).strip()

        # Job: "PLD/WHM", "Warrior", "Thief/Warrior", "Monk / Warrior",
        # "White Mage / Black Mage/Samurai" (Iroha II has 3 jobs).
        # Split on '/' (with optional whitespace) to extract main and sub.
        # Strip {{Verification}}-style template residue too, then normalize
        # to 3-letter abbreviations so the format is consistent across
        # the dataset regardless of which form the wiki author used.
        raw_job = _strip_wikitext(f.get("job", "")).strip()
        raw_job = re.sub(r"\{\{[^}]*\}\}", "", raw_job).strip()
        if raw_job:
            parts = [p.strip() for p in re.split(r"\s*/\s*", raw_job) if p.strip()]
            normalized = [_normalize_job(p) for p in parts]
            if normalized:
                rec["main_job"] = normalized[0]
            if len(normalized) >= 2:
                rec["sub_job"] = normalized[1]
            # Reconstruct the display job string from the normalized parts
            # so e.g. 'Thief/Warrior' and 'PLD/WHM' both end up canonical.
            rec["job"] = "/".join(normalized) if normalized else raw_job
        else:
            rec["job"] = raw_job

        rec["role"]      = _strip_wikitext(f.get("role", "")).strip()
        if not rec["race"]:
            rec["race"]  = _strip_wikitext(f.get("race", "")).strip()
        rec["weapon"]    = _strip_wikitext(f.get("weapon", "")).strip()
        # Obtained: keep first sentence/paragraph for compactness.
        obtained = _strip_wikitext(f.get("obtained", "")).strip()
        if obtained:
            obtained = re.split(r"\.(?:\s|$)", obtained, maxsplit=1)[0]
            if len(obtained) > 300:
                obtained = obtained[:300] + "..."
            rec["obtained"] = obtained.strip()

        # Decompose Notes into sections.
        notes = f.get("notes", "")
        if notes:
            sections = _decompose_notes(notes)
            if "job_abilities" in sections:
                rec["job_abilities"] = _split_list(sections["job_abilities"])
            if "job_traits" in sections:
                rec["job_traits"] = _split_list(sections["job_traits"])
            if "weapon_skills" in sections:
                ws_raw = sections["weapon_skills"]
                rec["weapon_skills"] = _split_list(ws_raw)
                clean = _strip_wikitext(ws_raw).strip()
                if len(clean) > 600:
                    clean = clean[:600] + "..."
                rec["weapon_skills_raw"] = clean
            if "spells" in sections:
                sp_raw = sections["spells"]
                rec["spells"] = _split_list(sp_raw)
                clean = _strip_wikitext(sp_raw).strip()
                if len(clean) > 600:
                    clean = clean[:600] + "..."
                rec["spells_raw"] = clean
            if "notable" in sections:
                notable = _strip_wikitext(sections["notable"]).strip()
                if len(notable) > 500:
                    notable = notable[:500] + "..."
                rec["notable"] = notable

        # Prose fallback: if section decomposition found NO recognized
        # sections at all (the page is genuinely free-form, e.g. Ygnas,
        # Kupofried, AAHM, Aldo (UC), etc.), walk the Notes content with
        # verb-prefix heuristics. We DON'T run this when sections were
        # detected but produced empty lists (e.g. Shantotto's spells
        # section is all "Does not cast..." negations) — running the
        # fallback there would pick up unrelated content from notable
        # or other sections as spells.
        sections_found = bool(notes) and bool(_decompose_notes(notes))
        if notes and not sections_found:
            fb = _prose_fallback_extract(notes)
            # Run each list through _split_list cleanup (capitalization
            # filter, length cap, etc.) to match the formal-section
            # output format. _split_list is happy with one-item-per-line
            # input shape — bullet lines.
            for key in ("job_abilities", "weapon_skills",
                        "spells", "job_traits"):
                if fb.get(key):
                    bullet_form = "\n".join("*" + n for n in fb[key])
                    rec[key] = _split_list(bullet_form)

    # Dialogue — parse from the raw wikitext (catches both in-Notes and
    # after-template forms). Use the FIRST match per dialogue type since
    # some pages have multiple summon variants.
    for key, rx in _DIALOGUE_RX:
        m = rx.search(wikitext)
        if m:
            line = _strip_wikitext(m.group(1)).strip(" :'\"")
            # Reject placeholders.
            if line.lower() in ("n/a", "na", "none", "?", ""):
                continue
            if line and len(line) < 300:
                rec["dialogue"][key] = line

    # Intro text — fall back to a snippet of cleaned prose for tooltips.
    plain = _strip_wikitext(wikitext)
    for ln in plain.splitlines():
        s = ln.strip()
        if not s or s.startswith(("==", "Category:", "|", "{")):
            continue
        if len(s) > 30:
            rec["intro_text"] = s[:600]
            break

    return rec




# ── Cache I/O ───────────────────────────────────────────────────────────────

def load_cache():
    default = {
        "category_members": [],
        "page_data":        {},  # title → {"wikitext": str, "image_url": str}
        "parsed":           {},  # title → parsed record
    }
    if not os.path.exists(CACHE_PATH):
        return default
    try:
        with open(CACHE_PATH, "r", encoding="utf-8") as f:
            cache = json.load(f)
        for k, v in default.items():
            cache.setdefault(k, v)
        return cache
    except Exception as e:
        print(f"[cache] could not read {CACHE_PATH}: {e}; starting fresh.")
        return default


def save_cache(cache):
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(CACHE_PATH, "w", encoding="utf-8") as f:
        json.dump(cache, f, indent=2, sort_keys=True, ensure_ascii=False)


# ── Image download ──────────────────────────────────────────────────────────

def download_portrait(url, out_path, rate_sec):
    """Fetch an image URL and save it to out_path. Returns True on success."""
    if not url:
        return False
    status, _, body = throttled_get(url, rate_sec)
    if status != 200 or not body:
        return False
    try:
        with open(out_path, "wb") as f:
            f.write(body)
        return True
    except Exception as e:
        print(f"  [img] write failed for {out_path}: {e}", flush=True)
        return False


def safe_filename(name):
    """Convert a trust name to a safe filename."""
    name = name.replace(":", "").replace(" ", "_").replace("'", "")
    name = re.sub(r"[^A-Za-z0-9_\-()]+", "", name)
    return name.lower()


# ── Main ────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="Scrape FFXIclopedia (Fandom) for trust data.")
    ap.add_argument("--refresh-list", action="store_true",
                    help="Re-fetch Category:Trust members list.")
    ap.add_argument("--rate", type=float, default=None,
                    help="Override rate limit in seconds (default: from "
                         f"robots.txt, fallback {DEFAULT_RATE_SEC}s).")
    ap.add_argument("--limit", type=int, default=0,
                    help="For testing: only process this many trusts.")
    ap.add_argument("--only", nargs="+", default=None,
                    help="Limit to specific trust names "
                         "(e.g. --only 'Romaa Mihgo' Cornelia).")
    ap.add_argument("--skip-images", action="store_true",
                    help="Don't download portrait images.")
    ap.add_argument("--force-images", action="store_true",
                    help="Re-download images even if already on disk.")
    args = ap.parse_args()

    # Rate setup.
    if args.rate is not None:
        rate_sec = args.rate
        print(f"[ok] Using rate limit of {rate_sec}s (--rate override).")
    else:
        rate_sec = check_robots(BASE_URL)
        print(f"[ok] Using rate limit of {rate_sec:.2f}s per request.")

    os.makedirs(DATA_DIR, exist_ok=True)
    if not args.skip_images:
        os.makedirs(PORTRAIT_DIR, exist_ok=True)

    cache = load_cache()

    # ── 1. Category:Trust members ───────────────────────────────────────────
    if args.refresh_list or not cache.get("category_members"):
        print(f"[1/4] Fetching {CATEGORY_PAGE} ...")
        members = fetch_category_members(CATEGORY_PAGE, rate_sec)
        cache["category_members"] = members
        save_cache(cache)
        print(f"[1/4] Found {len(members)} category members.")
    else:
        print(f"[1/4] Using cached category list "
              f"({len(cache['category_members'])} entries).")

    # ── 2. Filter to actual trust pages ─────────────────────────────────────
    all_titles = cache["category_members"]
    trusts = [t for t in all_titles if is_trust_page(t)]
    print(f"[2/4] Filtered to {len(trusts)} actual trust pages "
          f"({len(all_titles) - len(trusts)} excluded as quest/meta pages).")

    if args.only:
        wanted = {s.lower().replace("trust: ", "") for s in args.only}
        trusts = [t for t in trusts
                  if t.replace("Trust: ", "").lower() in wanted]
        print(f"[2/4] Limited to {len(trusts)} per --only.")
    if args.limit:
        trusts = trusts[:args.limit]
        print(f"[2/4] Limited to first {len(trusts)} (--limit).")

    # ── 3. Per-trust fetch + parse ──────────────────────────────────────────
    print(f"[3/4] Fetching wikitext + portrait URL per trust "
          f"(estimated runtime: "
          f"{len(trusts) * rate_sec / 60:.1f} min at {rate_sec}s/req)...")
    n_fetched = n_cached = 0
    for idx, title in enumerate(trusts, 1):
        page = cache["page_data"].get(title)
        if page is None:
            print(f"  [{idx:3d}/{len(trusts)}] fetching: {title}", flush=True)
            page = fetch_page_data(title, rate_sec)
            cache["page_data"][title] = page
            n_fetched += 1
        else:
            n_cached += 1
        cache["parsed"][title] = parse_trust_page(title, page.get("wikitext", ""))

        if idx % 10 == 0:
            save_cache(cache)
            sys.stdout.flush()
    save_cache(cache)
    print(f"[3/4] Done. fetched={n_fetched} from-cache={n_cached}")

    # ── 4. Download portraits + write JSON ──────────────────────────────────
    if args.skip_images:
        print(f"[4/4] Skipping portrait downloads (--skip-images).")
        n_with_image = 0
    else:
        print(f"[4/4] Downloading portraits...")
        n_with_image = 0
        for idx, title in enumerate(trusts, 1):
            page = cache["page_data"].get(title, {})
            url = page.get("image_url", "")
            if not url:
                continue
            name = title.replace("Trust: ", "").strip()
            ext = os.path.splitext(urllib.parse.urlparse(url).path)[1] or ".png"
            ext = ext.split("?", 1)[0]  # Fandom URLs sometimes have ?cb=...
            if ext.lower() not in (".png", ".jpg", ".jpeg", ".gif", ".webp"):
                ext = ".png"
            out_path = os.path.join(PORTRAIT_DIR, safe_filename(name) + ext)
            if not args.force_images and os.path.exists(out_path):
                n_with_image += 1
                continue
            if download_portrait(url, out_path, rate_sec):
                n_with_image += 1
                if idx % 10 == 0:
                    print(f"  [{idx:3d}/{len(trusts)}] {name}: OK", flush=True)
        print(f"[4/4] {n_with_image}/{len(trusts)} portraits saved.")

    # Build output JSON.
    print(f"[4/4] Writing {OUTPUT_PATH}...")
    individuals = {}
    n_with_data = 0
    n_with_abilities = 0
    for title in trusts:
        rec = cache["parsed"].get(title)
        if not rec:
            continue
        # Drop the categories field from output — it was an internal
        # parsing aid, not user-facing data.
        out_rec = {k: v for k, v in rec.items() if k != "categories"}
        # Include the resolved portrait URL for downstream use.
        page = cache["page_data"].get(title, {})
        out_rec["portrait_url"] = page.get("image_url", "")
        out_rec["display"] = title
        key = rec["name"].lower()
        individuals[key] = out_rec
        if rec.get("job") or rec.get("race") or rec.get("weapon"):
            n_with_data += 1
        if rec.get("job_abilities") or rec.get("spells") or rec.get("weapon_skills"):
            n_with_abilities += 1

    out = {
        "_meta": {
            "source":           BASE_URL,
            "category":         CATEGORY_PAGE,
            "total_trusts":     len(trusts),
            "with_data":        n_with_data,
            "with_abilities":   n_with_abilities,
            "with_portraits":   n_with_image,
            "rate_sec":         rate_sec,
        },
        "trusts": individuals,
    }
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, sort_keys=True, ensure_ascii=False)
    print(f"[4/4] Wrote {OUTPUT_PATH}")
    print(f"[4/4] {n_with_data} trusts with header data, "
          f"{n_with_abilities} with abilities/spells, "
          f"{n_with_image} with portraits saved")


if __name__ == "__main__":
    main()