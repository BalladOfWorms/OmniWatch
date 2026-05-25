"""
build_mob_images.py — Scrape BG-wiki for Bestiary data and images.

Originally scraped images only; now also extracts per-NM ability/spell/
job/weakness/resistance/aggro data from each page's wikitext while it
fetches them. Mirrors the design of build_mob_db.py:
    * Honors robots.txt (BG-wiki uses 30s crawl-delay; we sleep accordingly).
    * Resumable: caches everything (family list, wikitext, image URLs,
      parsed records) in data/_mob_image_cache.json.
    * Idempotent: skips families whose image is already saved and whose
      data has already been parsed.

Usage:
    python build_mob_images.py
    python build_mob_images.py --refresh-list   (re-fetch the index)
    python build_mob_images.py --skip-images    (data only, no images)
    python build_mob_images.py --skip-data      (images only, original behavior)
    python build_mob_images.py --only Crab Bee  (test against a few entries)

Output:
    data/mob_icons/<family_lower>.png   (one per entry, 128x128, transparent)
    data/mob_individuals.json           (per-NM structured data)
    data/_mob_image_cache.json          (resumable cache)

Per-NM data captured (when present on the page):
    family, type, main_job, sub_job, crystal, detects, aggro, link,
    susceptible (weakness), resists, immune, absorbs, abilities, spells,
    traits, intro_text.

Notes about scope:
    - Walks Category:Bestiary which contains both family hub pages
      (Crab, Goblin) AND individual NM pages (Aa Nawu the Thunderblade,
      Goblin Leecher) — about 5,800 entries total.
    - Images are saved as RGBA PNGs at 128x128, with proportional fit
      and transparent padding so they look right in the target card.
    - Many older NM pages have empty Abilities/Spells fields on the
      wiki itself; for those entries we capture what's there but the
      result will be sparse. This is a wiki content gap, not a parser
      gap, and is documented in the output's _meta.empty_records field.
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
import urllib.error

try:
    from PIL import Image
except ImportError:
    print("Pillow is required: pip install Pillow", file=sys.stderr)
    sys.exit(1)


# ── Config ──────────────────────────────────────────────────────────────────

BASE_URL          = "https://www.bg-wiki.com"
API_URL           = BASE_URL + "/api.php"
ROBOTS_URL        = BASE_URL + "/robots.txt"
USER_AGENT        = "PartyWatch-MobImageScraper/1.0 (Cooper; one-shot)"
DEFAULT_CRAWL_SEC = 1.5          # used if robots.txt can't be fetched
SAFE_CRAWL_SEC    = 30.0         # BG-wiki's published crawl-delay
REQUEST_TIMEOUT   = 15

CATEGORY_PAGE     = "Category:Bestiary"

OUTPUT_SIZE       = (128, 128)   # final saved image size

DATA_DIR          = "data"
ICON_DIR          = os.path.join(DATA_DIR, "mob_icons")
CACHE_PATH        = os.path.join(DATA_DIR, "_mob_image_cache.json")
INDIVIDUALS_PATH  = os.path.join(DATA_DIR, "mob_individuals.json")


# ── Wikitext template parsing (per-NM data extraction) ─────────────────────
# Inlined from build_mob_db.py so this script is self-contained. BG-wiki
# pages use {{Adversary Description|...}} for header info and one or
# more {{Adversary Row|...}} blocks (typically nested inside an
# {{Adversary Table|...}}) for per-zone details.

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
    lowercased keys, stripped values. Pipes inside [[links]] are
    protected during the split."""
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


_FFXI_ELEMENT_TEMPLATES = {
    # Elements
    "fire": "Fire", "ice": "Ice", "wind": "Wind", "earth": "Earth",
    "lightning": "Lightning", "water": "Water", "light": "Light",
    "dark": "Dark", "darkness": "Darkness",
    # Status effects (commonly used in resist/immune fields)
    "sleep": "Sleep", "poison": "Poison", "paralysis": "Paralysis",
    "blindness": "Blindness", "silence": "Silence",
    "petrification": "Petrification", "virus": "Virus", "curse": "Curse",
    "stun": "Stun", "bind": "Bind", "gravity": "Gravity",
    "slow": "Slow", "amnesia": "Amnesia", "charm": "Charm",
    "addle": "Addle", "doom": "Doom", "weight": "Weight",
    "plague": "Plague", "disease": "Disease", "lullaby": "Lullaby",
    "terror": "Terror",
}


def _translate_element_templates(s):
    """Replace {{ice}} → 'Ice', {{stun}} → 'Stun', etc. before generic
    template stripping. The match is case-insensitive on the template
    name, with optional trailing args (e.g. '{{ice|some param}}')."""
    if not s:
        return s
    def repl(m):
        name = m.group(1).strip().lower()
        if name in _FFXI_ELEMENT_TEMPLATES:
            return _FFXI_ELEMENT_TEMPLATES[name]
        return m.group(0)   # leave unrecognized templates alone
    return re.sub(r"\{\{(\w+)(?:\|[^{}]*)?\}\}", repl, s)


def _strip_wikitext(s):
    """Clean wikitext → plain text. Removes templates, links, HTML, refs."""
    if not s:
        return ""
    # Translate FFXI element/status templates first so they survive the
    # generic template stripper below.
    s = _translate_element_templates(s)
    s = re.sub(r"<!--.*?-->", "", s, flags=re.DOTALL)
    s = re.sub(r"<ref[^>]*>.*?</ref>", "", s, flags=re.DOTALL)
    s = re.sub(r"<[^>]+>", "", s)
    prev = None
    while prev != s:
        prev = s
        s = re.sub(r"\{\{[^{}]*?\}\}", "", s, flags=re.DOTALL)
    s = re.sub(r"\{\{[^\n]*", "", s)
    s = re.sub(r"\}\}", "", s)
    # [[Page|Display]] → Display, [[Page]] → Page, [[Page|]] → Page.
    s = re.sub(r"\[\[([^\]|]*?)\|\s*\]\]", r"\1", s)
    s = re.sub(r"\[\[([^\]|]*?)\|([^\]]+?)\]\]", r"\2", s)
    s = re.sub(r"\[\[([^\]]*?)\]\]", r"\1", s)
    s = re.sub(r"\[\[([^\]|\n]*?)\|", r"\1 ", s)
    s = re.sub(r"\[\[", "", s)
    s = re.sub(r"\]\]", "", s)
    s = re.sub(r"\[https?://[^ \]]+ ([^\]]+)\]", r"\1", s)
    s = re.sub(r"\[https?://\S+", "", s)
    s = re.sub(r"(?im)^category:.*$", "", s)
    s = s.replace("'''", "").replace("''", "")
    s = re.sub(r"<br\s*/?>", " ", s)
    s = re.sub(r"[ \t]+", " ", s)
    s = re.sub(r"\n{3,}", "\n\n", s)
    return s.strip()


def _split_csv_or_bullets(value):
    """Convert a comma- or bullet-listed wiki field into a clean list."""
    if not value:
        return []
    if re.search(r"^\s*\*", value, re.M):
        items = []
        for ln in value.splitlines():
            ln = ln.strip()
            if ln.startswith("*"):
                items.append(ln.lstrip("*").strip())
        raw = items
    else:
        raw = [x for x in value.split(",") if x.strip()]
    out = []
    for it in raw:
        cleaned = _strip_wikitext(it).strip(" .,;")
        if not cleaned:
            continue
        if cleaned.lower() in ("none", "n/a", "na", "?", "none.",
                               "no abilities", "no spells", "no traits"):
            continue
        if cleaned not in out:
            out.append(cleaned)
    return out


def _aggro_link_value(raw):
    """Normalize an Aggro/Link field to 'Yes'/'No'/'Conditional'/''."""
    if not raw:
        return ""
    cleaned = _strip_wikitext(raw).strip().lower()
    if not cleaned or "question" in cleaned:
        return ""
    if cleaned in ("yes", "y", "true", "1"):
        return "Yes"
    if cleaned in ("no", "n", "false", "0"):
        return "No"
    if re.search(r"\b(except|unless|when|if)\b", cleaned):
        return "Conditional"
    return cleaned[:40]


def extract_individual_data(wikitext):
    """Parse an NM/mob page into a structured record. Returns a dict
    with keys: family, type, main_job, sub_job, crystal, detects,
    aggro, link, susceptible, resists, immune, absorbs, abilities,
    spells, traits, intro_text. Empty fields when wiki doesn't have
    the data — most NM pages have at least header info, abilities/
    spells coverage varies by entry."""
    rec = {
        "family":      "",
        "type":        "",
        "main_job":    "",
        "sub_job":     "",
        "crystal":     "",
        "detects":     "",
        "aggro":       "",
        "link":        "",
        "susceptible": [],
        "resists":     [],
        "immune":      [],
        "absorbs":     [],
        "abilities":   [],
        "spells":      [],
        "traits":      [],
        "intro_text":  "",
    }
    if not wikitext:
        return rec
    # Skip true redirects (no content). Don't skip disambig pages —
    # many family hubs (Behemoth, Coeurl) tag themselves as disambig
    # but also carry real Adversary Description data.
    if wikitext.lstrip()[:200].lower().startswith("#redirect"):
        return rec

    # 1. Header template (Adversary Description / Bestiary Description 2).
    pos = 0
    while True:
        found = _find_balanced_template(wikitext, pos)
        if not found:
            break
        start, end, inner = found
        pos = end
        head = inner.strip().split("|", 1)[0].strip().lower()
        if head in ("adversary description", "adversary description 2",
                    "bestiary description 2"):
            f = _parse_template_fields(inner)
            rec["family"]   = _strip_wikitext(f.get("family", "")).strip()
            rec["type"]     = _strip_wikitext(f.get("type", "")).strip()
            rec["main_job"] = _strip_wikitext(
                                  f.get("main job",
                                  f.get("main.job", ""))).strip()
            rec["sub_job"]  = _strip_wikitext(
                                  f.get("sub job",
                                  f.get("sub.job", ""))).strip()
            rec["crystal"]  = _strip_wikitext(f.get("crystal", "")).strip()
            rec["detects"]  = _strip_wikitext(f.get("detects", "")).strip()
            break

    # 2. Adversary Row blocks. These are typically nested inside
    # {{Adversary Table|Adversary Row=...}} so we descend recursively.
    abilities, spells, traits = [], [], []
    susceptible, resists, immune, absorbs = [], [], [], []
    aggro_seen, link_seen = "", ""

    def _scan_for_rows(text):
        nonlocal aggro_seen, link_seen
        scan_pos = 0
        while True:
            found = _find_balanced_template(text, scan_pos)
            if not found:
                break
            tstart, tend, tinner = found
            scan_pos = tend
            thead = tinner.strip().split("|", 1)[0].strip().lower()
            if thead == "adversary row":
                f = _parse_template_fields(tinner)
                for nm in _split_csv_or_bullets(f.get("abilities", "")):
                    if nm not in abilities:
                        abilities.append(nm)
                for nm in _split_csv_or_bullets(f.get("spells", "")):
                    if nm not in spells:
                        spells.append(nm)
                for nm in _split_csv_or_bullets(f.get("traits", "")):
                    if nm not in traits:
                        traits.append(nm)
                for nm in _split_csv_or_bullets(f.get("susceptible", "")):
                    if nm not in susceptible:
                        susceptible.append(nm)
                for nm in _split_csv_or_bullets(f.get("resists", "")):
                    if nm not in resists:
                        resists.append(nm)
                for nm in _split_csv_or_bullets(f.get("immune", "")):
                    if nm not in immune:
                        immune.append(nm)
                for nm in _split_csv_or_bullets(f.get("absorbs", "")):
                    if nm not in absorbs:
                        absorbs.append(nm)
                if not aggro_seen:
                    aggro_seen = _aggro_link_value(f.get("aggro", ""))
                if not link_seen:
                    link_seen = _aggro_link_value(f.get("link", ""))
            elif thead in ("adversary table", "bestiary table"):
                _scan_for_rows(tinner)

    _scan_for_rows(wikitext)

    rec["abilities"]   = abilities
    rec["spells"]      = spells
    rec["traits"]      = traits
    rec["susceptible"] = susceptible
    rec["resists"]     = resists
    rec["immune"]      = immune
    rec["absorbs"]     = absorbs
    rec["aggro"]       = aggro_seen
    rec["link"]        = link_seen

    # 3. Intro text — first 600 chars of clean prose for tooltips. We
    # skip section headings and orphan template-field fragments that
    # the stripper can't fully remove (BG-wiki uses #ifeq/onlyinclude
    # macros that leave leftover '|fieldname=' lines behind).
    cleaned = _strip_wikitext(wikitext)
    intro_lines = []
    for ln in cleaned.splitlines():
        s = ln.strip()
        if not s:
            continue
        if s.startswith("=="):                    # section heading
            continue
        if s.startswith("|") or s.startswith("{"): # template fragment leftover
            continue
        if s.startswith("#"):                      # parser-function fragment
            continue
        intro_lines.append(s)
        if sum(len(x) for x in intro_lines) > 600:
            break
    if intro_lines:
        rec["intro_text"] = " ".join(intro_lines)[:600]

    return rec



# ── Small request helper with throttling ────────────────────────────────────

def throttled_get(url, rate_sec, last_fetch=[0.0]):
    """Sleep so each request is at least rate_sec apart; then GET it.
    Returns (status, headers, body_bytes)."""
    wait = (last_fetch[0] + rate_sec) - time.time()
    if wait > 0:
        time.sleep(wait)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as r:
            data = r.read()
            last_fetch[0] = time.time()
            return r.status, dict(r.headers), data
    except urllib.error.HTTPError as e:
        last_fetch[0] = time.time()
        return e.code, dict(e.headers or {}), b""
    except Exception as e:
        last_fetch[0] = time.time()
        print(f"  [warn] request failed: {e}", file=sys.stderr)
        return 0, {}, b""


def check_robots(base_url):
    """Best-effort: check robots.txt for crawl-delay; return effective delay."""
    print(f"[robots] Fetching {ROBOTS_URL} ...")
    try:
        req = urllib.request.Request(ROBOTS_URL, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as r:
            text = r.read().decode(errors="replace")
        # parse minimal: look for Crawl-delay value applicable to *.
        delay = None
        in_star = False
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            kv = line.split(":", 1)
            if len(kv) != 2:
                continue
            k, v = kv[0].strip().lower(), kv[1].strip()
            if k == "user-agent":
                in_star = (v == "*" or USER_AGENT.lower().startswith(v.lower()))
            elif k == "crawl-delay" and in_star:
                try:
                    delay = float(v)
                except ValueError:
                    pass
        if delay is not None:
            print(f"[robots] crawl-delay = {delay}s (honoring).")
            return delay
        print(f"[robots] no crawl-delay specified; using {DEFAULT_CRAWL_SEC}s.")
        return DEFAULT_CRAWL_SEC
    except Exception as e:
        print(f"[robots] could not fetch ({e}); using safe {SAFE_CRAWL_SEC}s.")
        return SAFE_CRAWL_SEC


# ── MediaWiki API helpers ───────────────────────────────────────────────────

def api_query(params, rate_sec):
    params = dict(params)
    params["format"] = "json"
    qs = urllib.parse.urlencode(params)
    url = f"{API_URL}?{qs}"
    status, _, body = throttled_get(url, rate_sec)
    if status != 200 or not body:
        return None
    try:
        return json.loads(body.decode("utf-8", errors="replace"))
    except Exception as e:
        print(f"  [warn] api response not JSON: {e}", file=sys.stderr)
        return None


def fetch_category_members(category, rate_sec):
    """Yield page titles in a category, paginating with cmcontinue."""
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


def fetch_page_wikitext(title, rate_sec):
    """Return wikitext for a page, or None."""
    params = {
        "action":  "query",
        "titles":  title,
        "prop":    "revisions",
        "rvprop":  "content",
        "rvslots": "main",
    }
    data = api_query(params, rate_sec)
    if not data:
        return None
    pages = ((data.get("query") or {}).get("pages")) or {}
    for _pid, pdata in pages.items():
        revs = pdata.get("revisions", [])
        if not revs:
            continue
        slots = revs[0].get("slots", {})
        main  = slots.get("main", {})
        return main.get("*") or revs[0].get("*")
    return None


def fetch_image_url(filename, rate_sec):
    """Resolve File:X to its actual URL via imageinfo."""
    if not filename.lower().startswith("file:"):
        filename = "File:" + filename
    params = {
        "action":  "query",
        "titles":  filename,
        "prop":    "imageinfo",
        "iiprop":  "url|size|mime",
    }
    data = api_query(params, rate_sec)
    if not data:
        return None
    pages = ((data.get("query") or {}).get("pages")) or {}
    for _pid, pdata in pages.items():
        if pdata.get("missing") is not None:
            return None
        ii = pdata.get("imageinfo", [])
        if ii:
            return ii[0].get("url")
    return None


def probe_category_image(title, rate_sec):
    """Probe BG-wiki for the predictable 'Category-<Title>.jpg' convention.

    BG-wiki maintains a sibling image file for every ecosystem family
    at File:Category-<Family>.jpg (e.g. File:Category-Behemoth.jpg,
    File:Category-Opo-opo.jpg). This is the most reliable way to get
    family portraits since family pages don't carry inline image refs.

    Per-NM pages (Goblin Leecher, King Arthro) generally DON'T have a
    Category- file — those return None and the caller falls back to
    scanning the page wikitext for inline image refs.

    Returns the resolved image URL or None.
    """
    filename = f"Category-{title}.jpg"
    return fetch_image_url(filename, rate_sec)


def looks_like_family_name(title):
    """Heuristic: does this title look like a family/ecosystem name?

    Currently used to decide which titles are worth a one-time probe
    for the predictable File:Category-<Title>.jpg image. Family pages
    are short single- or two-word names (Crab, Goblin, Sea Monk).
    Per-NM pages are typically longer or have parentheses/possessives
    (Aa Nawu the Thunderblade, Goblin Leecher, Bigclaw).

    Heuristic is tuned conservatively. The cost of a false positive is
    one wasted 30s API call confirming "no, doesn't exist."
    """
    if "(" in title:
        return False
    if len(title) > 25:
        return False
    word_count = len(title.split())
    if word_count > 3:
        return False
    if title.startswith(("The ", "Lord ", "Lady ", "King ", "Queen ",
                         "Prince ", "Princess ", "Sir ", "Aa ")):
        return False
    return True


# Hand-maintained list of FFXI ecosystem families that have an image
# at File:Category-<Family>.jpg on BG-wiki. Probed once upfront before
# the main scrape loop. Cost: ~55 min at 30s/req for ~109 entries.
# Better than probing every NM (would add ~44 hours of confirming
# "this NM doesn't have a Category- file"). Caller can add to this
# list freely; missing entries just don't get a portrait but cost
# nothing extra to skip.
KNOWN_FAMILIES = [
    # Amorph
    "Flan", "Slime", "Leech", "Morbol", "Sandworm",
    # Aquan
    "Crab", "Pugil", "Rafflesia", "Toad", "Uragnite", "Ruszor",
    "Orobon", "Sea Monk", "Apkallu", "Jagil",
    # Arcana
    "Cluster", "Doll", "Evil Weapon", "Golem", "Magic Jug",
    "Magic Pot", "Mimic", "Wendigo", "Bomb", "Fomor",
    # Beast
    "Behemoth", "Buffalo", "Cerberus", "Coeurl", "Dhalmel", "Karakul",
    "Manticore", "Marid", "Opo-opo", "Rabbit", "Ram", "Sheep", "Tiger",
    "Smilodon", "Lynx", "Gnole",
    # Bird / Aerial
    "Amphiptere", "Bat", "Bird", "Cockatrice", "Colibri", "Hippogryph",
    "Hpemde", "Puk", "Roc", "Sanguiptere", "Pephredo", "Flock Bat",
    # Demon / Beastman / humanoid
    "Ahriman", "Antica", "Chariot", "Demon", "Imp", "Soulflayer",
    "Gigas", "Qutrub", "Goblin", "Moblin", "Orc", "Quadav", "Sahagin",
    "Tonberry", "Yagudo", "Kindred", "Shikaree", "Troll", "Lamia",
    "Mamool Ja", "Trolls",
    # Dragon
    "Dragon", "Hydra", "Wyrm", "Wyvern", "Zilant",
    # Lizard
    "Adamantoise", "Bugard", "Eft", "Lizard", "Peiste", "Raptor",
    # Plantoid
    "Funguar", "Goobbue", "Mandragora", "Panopt", "Sapling", "Treant",
    "Korrigan",
    # Undead
    "Corse", "Ghost", "Ghrah", "Hecteyes", "Lich", "Skeleton",
    "Tombstone",
    # Vermin
    "Beetle", "Bee", "Chigoe", "Crawler", "Diremite", "Fly", "Gnat",
    "Scorpion", "Spider", "Wamoura", "Worm", "Chapuli", "Matamata",
    "Limule", "Wasp",
    # Luminous / shadow / misc
    "Shadow", "Wanderer", "Qiqirn", "Aern", "Yovra",
    # Older expansions / specific
    "Craklaw", "Phuabo", "Euvhi", "Acuex", "Velkk",
    "Poroggo", "Murex", "Slug",
]


# ── Image-from-wikitext extraction ──────────────────────────────────────────

# Common image-reference patterns on BG-wiki family pages:
#   [[File:Crab.png|thumb|...]]
#   [[Image:Crab.png|...]]
#   {{Bestiary Description|Image=Crab.png|...}}
#   {{Adversary Description|Image=Crab.png|...}}
IMAGE_PATTERNS = [
    re.compile(r"\[\[\s*File\s*:\s*([^\]\|]+?)\s*[\]\|]",     re.IGNORECASE),
    re.compile(r"\[\[\s*Image\s*:\s*([^\]\|]+?)\s*[\]\|]",    re.IGNORECASE),
    re.compile(r"\|\s*Image\s*=\s*([^\|\}\n]+?)\s*[\|\}\n]",  re.IGNORECASE),
]


def extract_image_filename(wikitext):
    """Find the first plausible image filename in wikitext, or None.
    Skips obvious icons (small UI sprites) by extension/name heuristics."""
    if not wikitext:
        return None
    seen = set()
    candidates = []
    for pat in IMAGE_PATTERNS:
        for m in pat.finditer(wikitext):
            name = m.group(1).strip()
            if not name or name in seen:
                continue
            seen.add(name)
            # Filter UI/sprite icons that aren't useful as mob images.
            low = name.lower()
            if any(skip in low for skip in (
                "icon", "logo", "stub", "navbox", "spell", "ability",
                "wsicon", "questicon", "magic-",
            )):
                continue
            ext = os.path.splitext(low)[1]
            if ext not in (".png", ".jpg", ".jpeg", ".gif"):
                continue
            candidates.append(name)
    return candidates[0] if candidates else None


# ── Image processing ────────────────────────────────────────────────────────

def resize_to_card(image_bytes, out_size=OUTPUT_SIZE):
    """Resize the raw image bytes to fit out_size while preserving aspect
    ratio. Centers on a transparent background. Returns PNG bytes."""
    src = Image.open(io.BytesIO(image_bytes))
    src = src.convert("RGBA")
    src.thumbnail(out_size, Image.LANCZOS)
    canvas = Image.new("RGBA", out_size, (0, 0, 0, 0))
    x = (out_size[0] - src.width) // 2
    y = (out_size[1] - src.height) // 2
    canvas.paste(src, (x, y), src)
    out = io.BytesIO()
    canvas.save(out, format="PNG", optimize=True)
    return out.getvalue()


# ── Cache I/O ───────────────────────────────────────────────────────────────

def load_cache():
    default = {
        "families":        [],
        "image_filenames": {},
        "image_urls":      {},
        "wikitext":        {},   # title → raw wikitext (for re-parsing without re-fetch)
        "parsed_data":     {},   # title → extract_individual_data() output
    }
    if not os.path.exists(CACHE_PATH):
        return default
    try:
        with open(CACHE_PATH, "r", encoding="utf-8") as f:
            cache = json.load(f)
        # Backfill missing keys for backward compatibility.
        for k, v in default.items():
            cache.setdefault(k, v)
        return cache
    except Exception as e:
        print(f"[cache] could not read {CACHE_PATH}: {e}; starting fresh.")
        return default


def save_cache(cache):
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(CACHE_PATH, "w", encoding="utf-8") as f:
        json.dump(cache, f, indent=2, sort_keys=True)


# ── Main ────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="Scrape BG-wiki Bestiary "
                                              "images and per-NM data.")
    ap.add_argument("--refresh-list", action="store_true",
                    help="Re-fetch the Category:Bestiary family list "
                         "(otherwise cached).")
    ap.add_argument("--only", nargs="+", default=None,
                    help="Limit to these entry names (e.g. --only Crab Bee).")
    ap.add_argument("--force", action="store_true",
                    help="Re-download images even if already on disk.")
    ap.add_argument("--skip-images", action="store_true",
                    help="Don't download images, only collect ability/spell data.")
    ap.add_argument("--skip-data", action="store_true",
                    help="Don't extract per-NM data, only download images "
                         "(legacy behavior).")
    ap.add_argument("--limit", type=int, default=0,
                    help="For testing: only process this many entries.")
    args = ap.parse_args()

    rate_sec = check_robots(BASE_URL)
    print(f"[ok] Using rate limit of {rate_sec:.2f}s per request.")

    os.makedirs(DATA_DIR, exist_ok=True)
    if not args.skip_images:
        os.makedirs(ICON_DIR, exist_ok=True)

    cache = load_cache()

    # ── 1. Family list ──────────────────────────────────────────────────────
    if args.refresh_list or not cache.get("families"):
        print(f"[1/5] Fetching {CATEGORY_PAGE} ...")
        members = fetch_category_members(CATEGORY_PAGE, rate_sec)
        # Filter out subcategories and templates that sometimes appear.
        members = [m for m in members
                   if ":" not in m or m.startswith("Category:") is False]
        members = sorted(set(members))
        cache["families"] = members
        save_cache(cache)
        print(f"[1/5] Found {len(members)} entries.")
    else:
        print(f"[1/5] Using cached entry list ({len(cache['families'])} pages).")

    families = cache["families"]
    if args.only:
        wanted = {s.lower() for s in args.only}
        families = [f for f in families if f.lower() in wanted]
        print(f"[1/5] Limited to {len(families)} entries per --only.")
    if args.limit:
        families = families[:args.limit]
        print(f"[1/5] Limited to first {len(families)} entries (--limit).")

    # ── 2. Family-image probe (upfront, low cost) ───────────────────────────
    # BG-wiki maintains a sibling image at File:Category-<Family>.jpg for
    # every ecosystem family (e.g. File:Category-Behemoth.jpg). Family
    # pages themselves don't contain inline image refs, so the only way
    # to get family portraits is to probe this predictable path. We do
    # this ONCE upfront against a curated KNOWN_FAMILIES list (~109
    # entries × 30s ≈ 55 minutes), which is dramatically cheaper than
    # probing every entry in the bestiary (~5,800 wasted probes ≈ 49
    # extra hours). Per-NM titles fall through to the inline-image
    # extraction in step 3.
    if not args.skip_images:
        print(f"[2/5] Probing {len(KNOWN_FAMILIES)} known family images "
              f"at File:Category-<Family>.jpg ...")
        n_probe_hit = n_probe_miss = n_probe_cached = 0
        for idx, fam in enumerate(KNOWN_FAMILIES, 1):
            # If --only is set and this family isn't in scope, skip the probe.
            if args.only and fam.lower() not in {s.lower() for s in args.only}:
                continue
            probe_filename = f"Category-{fam}.jpg"
            # Cache hit: we already have a non-empty URL for this filename.
            if cache["image_urls"].get(probe_filename):
                cache["image_filenames"][fam] = probe_filename
                n_probe_cached += 1
                continue
            # Cache hit (negative): we already probed and got nothing.
            # Distinguish from "never tried" by storing "" explicitly.
            if probe_filename in cache["image_urls"]:
                n_probe_cached += 1
                continue
            print(f"  [{idx:3d}/{len(KNOWN_FAMILIES)}] probing: {fam}",
                  flush=True)
            try:
                url = probe_category_image(fam, rate_sec)
            except Exception as e:
                print(f"  [{idx:3d}/{len(KNOWN_FAMILIES)}] {fam}: probe "
                      f"failed ({e})", flush=True)
                url = None
            if url:
                cache["image_urls"][probe_filename] = url
                cache["image_filenames"][fam] = probe_filename
                n_probe_hit += 1
            else:
                # Store negative result so we don't re-probe on future runs.
                cache["image_urls"][probe_filename] = ""
                n_probe_miss += 1
            if idx % 10 == 0:
                save_cache(cache)
        save_cache(cache)
        print(f"[2/5] Family-image probe done. found={n_probe_hit} "
              f"missing={n_probe_miss} cached={n_probe_cached}")
    else:
        print(f"[2/5] Skipped family-image probe (--skip-images).")

    # ── 3. Fetch wikitext for each entry, parse data inline ─────────────────
    # This pass does the bulk of the work: one HTTP request per entry,
    # unconditionally cached. Re-runs skip entries we already have. The
    # wikitext is then parsed for both image filename (for step 4) and
    # per-NM ability/spell/job data (for step 5 output).
    print(f"[3/5] Fetching wikitext + parsing data per entry "
          f"(estimated runtime: "
          f"{len(families) * rate_sec / 3600:.1f}h at {rate_sec}s/req)...")
    n_fetched = n_cached = 0
    for idx, fam in enumerate(families, 1):
        # Already have wikitext? Skip the HTTP fetch but still re-parse
        # so any parser improvements take effect on next run.
        wt = cache["wikitext"].get(fam)
        if wt is None:
            print(f"  [{idx:5d}/{len(families)}] fetching: {fam}", flush=True)
            try:
                wt = fetch_page_wikitext(fam, rate_sec) or ""
            except Exception as e:
                print(f"  [{idx:5d}/{len(families)}] {fam}: fetch failed ({e})",
                      flush=True)
                wt = ""
            cache["wikitext"][fam] = wt
            n_fetched += 1
        else:
            n_cached += 1

        # Image filename (for pass 3). Inline-image extraction from the
        # page wikitext. For per-NM pages this catches inline portrait
        # references when authors added them. Family-level portraits
        # are handled separately by the upfront family-image probe
        # below — they don't appear in family-page wikitext.
        if not args.skip_images and not cache["image_filenames"].get(fam):
            cache["image_filenames"][fam] = extract_image_filename(wt) or ""

        # Per-NM data (for pass 4). Re-parse on every run since parsing
        # is fast and lets parser improvements take effect.
        if not args.skip_data:
            cache["parsed_data"][fam] = extract_individual_data(wt)

        # Save cache every 25 entries (~12.5 min at 30s/req). This lets
        # Ctrl-C / crash / network blip pick up cleanly.
        if idx % 25 == 0:
            save_cache(cache)
            sys.stdout.flush()
    save_cache(cache)
    print(f"[3/5] Done. fetched={n_fetched} from-cache={n_cached}")

    # ── 3. Image download (skippable) ───────────────────────────────────────
    if args.skip_images:
        print(f"[4/5] Skipped (--skip-images).")
    else:
        print(f"[4/5] Downloading & resizing images ...")
        success, skipped, missing = 0, 0, 0
        for idx, fam in enumerate(families, 1):
            out_path = os.path.join(ICON_DIR,
                                     fam.lower().replace(" ", "_") + ".png")
            if not args.force and os.path.exists(out_path):
                skipped += 1
                continue
            img_name = cache["image_filenames"].get(fam, "")
            if not img_name:
                missing += 1
                continue
            # Resolve URL via imageinfo (cached).
            url = cache["image_urls"].get(img_name)
            if not url:
                url = fetch_image_url(img_name, rate_sec)
                if url:
                    cache["image_urls"][img_name] = url
                    save_cache(cache)
            if not url:
                print(f"  [{idx:5d}/{len(families)}] {fam}: URL resolution failed")
                missing += 1
                continue
            # Download.
            status, _, body = throttled_get(url, rate_sec)
            if status != 200 or not body:
                print(f"  [{idx:5d}/{len(families)}] {fam}: download failed "
                      f"({status})")
                missing += 1
                continue
            # Resize and save.
            try:
                png = resize_to_card(body)
                with open(out_path, "wb") as f:
                    f.write(png)
                success += 1
                if idx % 50 == 0:
                    print(f"  [{idx:5d}/{len(families)}] {fam}: OK")
            except Exception as e:
                print(f"  [{idx:5d}/{len(families)}] {fam}: convert failed ({e})")
                missing += 1
        save_cache(cache)
        print(f"[4/5] saved={success} skipped(already_present)={skipped} "
              f"missing={missing}")
        print(f"[4/5] images in: {ICON_DIR}")

    # ── 4. Write per-NM data JSON ───────────────────────────────────────────
    if args.skip_data:
        print(f"[5/5] Skipped (--skip-data).")
    else:
        print(f"[5/5] Writing per-NM data...")
        # Build the output structure. Filter out entries with no useful
        # data so the JSON isn't bloated with empty placeholders.
        individuals = {}
        n_with_data = n_empty = n_with_abilities = 0
        for fam in families:
            rec = cache["parsed_data"].get(fam)
            if not rec:
                n_empty += 1
                continue
            has_data = (rec.get("family") or rec.get("type") or
                        rec.get("main_job") or rec.get("abilities") or
                        rec.get("spells") or rec.get("susceptible") or
                        rec.get("resists") or rec.get("immune") or
                        rec.get("aggro") or rec.get("intro_text"))
            if not has_data:
                n_empty += 1
                continue
            rec_with_display = dict(rec)
            rec_with_display["display"] = fam
            individuals[fam.lower()] = rec_with_display
            n_with_data += 1
            if rec.get("abilities") or rec.get("spells"):
                n_with_abilities += 1

        out = {
            "_meta": {
                "source":           BASE_URL,
                "category":         CATEGORY_PAGE,
                "total_entries":    len(families),
                "with_data":        n_with_data,
                "empty_records":    n_empty,
                "with_abilities":   n_with_abilities,
                "rate_sec":         rate_sec,
            },
            "individuals": individuals,
        }
        with open(INDIVIDUALS_PATH, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=2, sort_keys=True, ensure_ascii=False)
        print(f"[5/5] Wrote {INDIVIDUALS_PATH}")
        print(f"[5/5] {n_with_data} entries with usable data, "
              f"{n_with_abilities} with abilities/spells, "
              f"{n_empty} empty")


if __name__ == "__main__":
    main()