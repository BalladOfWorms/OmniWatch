#!/usr/bin/env python3
"""
build_mob_abilities.py — scrape FFXIclopedia for mob ability tooltips.

Usage:
    python build_mob_abilities.py [--output PATH] [--limit N] [--resume]

What it does:
    Queries FFXIclopedia's MediaWiki API for all pages in
    Category:Mob_Abilities, fetches each page's raw wikitext, parses the
    Mob_Ability infobox (or falls back to free-text parsing for older
    pages), and writes the consolidated result to mob_abilities.json.

    Output schema:
        {
          "_meta": {
            "source": "ffxiclopedia.fandom.com",
            "scraped_at": "2026-05-13T...",
            "ability_count": NNNN,
            "family_count": NNN
          },
          "abilities": {
            "Howl": {
              "name": "Howl",
              "description": "...",
              "family": "Yagudo",
              "type": "Enhancing",
              "dispel": "N/A",
              "utsusemi": "...",
              "range": "...",
              "notes": "..."
            },
            ...
          },
          "families": {
            "yagudo": ["Howl", "Sweep", "Feather Storm", ...],
            ...
          }
        }

    Family keys are lowercased; ability names are kept as displayed
    (title case). Missing fields are stored as empty strings — Python
    consumers should treat empty as "no data" rather than render an
    empty tooltip line.

Rate limiting:
    Polite — 1 request per second by default (configurable with --rate).
    Total wall time ~25-40 min for the full ~1500-2000 page category.

Resumability:
    With --resume, reads existing output file and skips abilities
    already collected. Lets you interrupt and re-run without losing
    progress.

Dependencies:
    Just the Python standard library. No requests/beautifulsoup.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone


# MediaWiki API endpoint for FFXIclopedia. Same endpoint every Fandom
# wiki exposes at /api.php. We hit it with action=query (category list)
# and action=parse (page wikitext).
API_BASE = "https://ffxiclopedia.fandom.com/api.php"

# The Category:Mob_Abilities page lists every mob TP move. Includes
# breath weapons, magical attacks, and physical TP moves.
CATEGORY_TITLE = "Category:Mob_Abilities"

# User-Agent. Fandom rejects requests with no UA, and abuses generic
# scraper UAs ("python-requests/...") periodically. A distinctive UA
# that identifies the project keeps us out of bad-bot lists, and lets
# Fandom admins reach out if scraping causes problems.
USER_AGENT = (
    "OmniWatch/0.1 mob-ability-scraper "
    "(github.com/BalladOfWorms/OmniWatch; for FFXI addon tooltips)"
)

# Per-request delay (seconds). 1.0 is comfortably polite for a public
# MediaWiki install. Adjust with --rate.
DEFAULT_RATE = 1.0


# ── HTTP plumbing ────────────────────────────────────────────────────

def _http_get_json(url):
    """Fetch a URL and parse its body as JSON. Raises on error.

    Adds the project User-Agent. Caller is responsible for rate-limiting
    between calls — this function does not sleep internally.
    """
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read().decode("utf-8")
    return json.loads(body)


def _api_url(params):
    """Build a MediaWiki API URL with the given params plus format=json."""
    full = dict(params)
    full.setdefault("format", "json")
    full.setdefault("formatversion", "2")
    return API_BASE + "?" + urllib.parse.urlencode(full)


# ── Category enumeration ─────────────────────────────────────────────

def fetch_category_members(category, rate, log):
    """Yield all page titles in `category`, paginating as needed.

    Uses list=categorymembers with cmlimit=500 (Fandom's API max for
    most accounts). Continues via cmcontinue until exhausted.

    `rate` is seconds between requests. `log` is a function to print
    progress.
    """
    cmcontinue = None
    total = 0
    while True:
        params = {
            "action": "query",
            "list": "categorymembers",
            "cmtitle": category,
            "cmlimit": 500,
            "cmprop": "title",
            "cmtype": "page",         # exclude subcategories / files
        }
        if cmcontinue:
            params["cmcontinue"] = cmcontinue
        url = _api_url(params)
        try:
            data = _http_get_json(url)
        except Exception as e:
            log(f"  [WARN] category fetch failed: {e!r}; retrying in 5s")
            time.sleep(5)
            continue

        members = data.get("query", {}).get("categorymembers", []) or []
        for m in members:
            title = m.get("title", "")
            if title:
                total += 1
                yield title

        # Pagination: continue token if more pages remain.
        cont = data.get("continue", {})
        cmcontinue = cont.get("cmcontinue")
        if not cmcontinue:
            break

        log(f"  ... {total} members so far, fetching next page")
        time.sleep(rate)
    log(f"  category enumeration complete: {total} pages")


# ── Page wikitext fetch ──────────────────────────────────────────────

def fetch_wikitext(title, rate):
    """Fetch the raw wikitext for a single page title.

    Returns the wikitext string, or empty string on failure. Failure is
    logged but not fatal — one bad page shouldn't kill the whole run.
    """
    params = {
        "action": "parse",
        "page": title,
        "prop": "wikitext",
        "redirects": 1,
    }
    url = _api_url(params)
    try:
        data = _http_get_json(url)
    except Exception as e:
        print(f"  [WARN] wikitext fetch failed for {title!r}: {e!r}")
        return ""

    parse = data.get("parse", {}) or {}
    raw = parse.get("wikitext")
    # formatversion=2 (which we request) returns wikitext as a plain
    # string. formatversion=1 returns it as {"*": "<content>"}. Handle
    # both shapes — Fandom's MediaWiki version sometimes ignores the
    # formatversion hint and returns the legacy shape anyway.
    if isinstance(raw, str):
        wikitext = raw
    elif isinstance(raw, dict):
        wikitext = raw.get("*", "")
    else:
        wikitext = ""
    return wikitext or ""


# ── Wikitext parsing ────────────────────────────────────────────────

# Many FFXIclopedia mob ability pages use the {{Mob_Ability}} template.
# Format:
#   {{Mob_Ability
#   | name = Incinerate
#   | description = Deals Fire damage to targets in a fan-shaped area
#   | family = Crawler
#   | type = Breath
#   | dispel = N/A
#   | utsusemi = Ignores shadows
#   | range = 10' cone
#   | notes = ...
#   }}
# Older pages have free-text fields with bold labels:
#   '''Family:''' Yagudo  
#   '''Type:''' Physical
# We try the template first; fall back to label-scanning on miss.

# Template detection: grab the first {{...}} block whose name looks
# like a mob-ability infobox. The opening brace is followed by an
# optional template name on the same line, then key=value pairs.
_TEMPLATE_RE = re.compile(
    r"\{\{\s*"
    r"(Mob[_\s]Ability|Monster[_\s]Ability|MobAbility|TP[_\s]Move)"
    r"\s*\|(.*?)\}\}",
    re.IGNORECASE | re.DOTALL,
)

# Within a template body, split on top-level pipes. Templates can
# contain nested templates and links (which may have their own pipes
# inside [[...]] or {{...}}). A naive split on '|' would corrupt
# values like "type = [[Physical|melee]]". This pattern splits only
# on pipes that aren't inside brackets/braces.
def _split_template_args(body):
    """Split a wikitext template body on top-level pipes only.

    Tracks nesting depth of [[]] and {{}} so pipes inside those
    constructs don't trigger a split. Returns a list of arg strings,
    each looking like 'key = value' or just 'positional_value'.
    """
    parts = []
    cur = []
    depth_brackets = 0   # for [[ ]]
    depth_braces = 0     # for {{ }}
    i = 0
    while i < len(body):
        ch = body[i]
        nxt = body[i + 1] if i + 1 < len(body) else ""
        if ch == "[" and nxt == "[":
            depth_brackets += 1
            cur.append(ch); cur.append(nxt); i += 2; continue
        if ch == "]" and nxt == "]":
            depth_brackets = max(0, depth_brackets - 1)
            cur.append(ch); cur.append(nxt); i += 2; continue
        if ch == "{" and nxt == "{":
            depth_braces += 1
            cur.append(ch); cur.append(nxt); i += 2; continue
        if ch == "}" and nxt == "}":
            depth_braces = max(0, depth_braces - 1)
            cur.append(ch); cur.append(nxt); i += 2; continue
        if ch == "|" and depth_brackets == 0 and depth_braces == 0:
            parts.append("".join(cur).strip())
            cur = []
            i += 1
            continue
        cur.append(ch)
        i += 1
    if cur:
        parts.append("".join(cur).strip())
    return parts


# Common alternate field names used by older or alternate infoboxes.
# Maps the variant → canonical key in our output dict.
_FIELD_ALIASES = {
    "name":               "name",
    "description":        "description",
    "desc":               "description",
    "effect":             "description",
    "family":             "family",
    "type":               "type",
    "category":           "type",
    "class":              "type",
    "dispel":             "dispel",
    "dispellable":        "dispel",
    "can be dispelled":   "dispel",
    "utsusemi":           "utsusemi",
    "blink":              "utsusemi",
    "shadows":            "utsusemi",
    "utsusemi/blink absorb": "utsusemi",
    "range":              "range",
    "area":               "range",
    "area of effect":     "range",
    "aoe":                "range",
    "notes":              "notes",
    "note":               "notes",
}


# Wikitext cleanup. Most fields contain link syntax ([[Page|label]]),
# bold/italic markers, and HTML comments that we want to strip before
# storing the plain-text value.
_LINK_RE      = re.compile(r"\[\[([^\]|]+)\|([^\]]+)\]\]")   # [[a|b]]
_LINK_SIMPLE  = re.compile(r"\[\[([^\]]+)\]\]")              # [[a]]
_BOLD_RE      = re.compile(r"'''(.*?)'''")
_ITALIC_RE    = re.compile(r"''(.*?)''")
_HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
_HTML_TAG     = re.compile(r"<[^>]+>")     # crude — drops all html tags
_WHITESPACE   = re.compile(r"\s+")


def _clean_value(s):
    """Strip wikitext markup from a value so it renders as plain text."""
    if not s:
        return ""
    s = _HTML_COMMENT.sub("", s)
    s = _LINK_RE.sub(r"\2", s)         # piped link → display label
    s = _LINK_SIMPLE.sub(r"\1", s)     # plain link → text
    s = _BOLD_RE.sub(r"\1", s)
    s = _ITALIC_RE.sub(r"\1", s)
    s = _HTML_TAG.sub("", s)
    s = _WHITESPACE.sub(" ", s)
    return s.strip()


def parse_template(wikitext):
    """Try to extract fields from a {{Mob_Ability}}-style template.

    Returns a dict of canonical fields, or None if no template found.
    """
    m = _TEMPLATE_RE.search(wikitext)
    if not m:
        return None
    body = m.group(2)
    args = _split_template_args(body)
    fields = {}
    for arg in args:
        if "=" not in arg:
            continue
        key, _, val = arg.partition("=")
        key = key.strip().lower()
        canon = _FIELD_ALIASES.get(key)
        if canon is None:
            continue
        fields[canon] = _clean_value(val)
    return fields if fields else None


# Free-text fallback for older pages: '''Family:''' Yagudo
_LABEL_LINE_RE = re.compile(
    r"'''\s*([\w\s/]+?)\s*[:：]?\s*'''\s*[:：]?\s*(.+?)(?=\n|$)",
    re.IGNORECASE,
)


def parse_freetext(wikitext, title):
    """Extract fields from bold-labeled lines in free wikitext.

    Used when no template matched. Looks for patterns like:
        '''Family:''' Yagudo
        '''Type:''' Physical
    The first non-bold paragraph at the top of the page is treated as
    the description.
    """
    fields = {"name": title}

    # Label scan
    for m in _LABEL_LINE_RE.finditer(wikitext):
        label = m.group(1).strip().lower()
        value = m.group(2).strip()
        canon = _FIELD_ALIASES.get(label)
        if canon and canon not in fields:
            fields[canon] = _clean_value(value)

    # Description: take the first non-empty paragraph that isn't a
    # label line or a template/category line. Mob ability descriptions
    # on free-text pages are usually one-liners at the top.
    if "description" not in fields:
        for ln in wikitext.split("\n"):
            ln_stripped = ln.strip()
            if not ln_stripped:
                continue
            if ln_stripped.startswith(("{{", "[[Category:",
                                       "''", "*", "#", "=", "|")):
                continue
            if _LABEL_LINE_RE.match(ln_stripped):
                continue
            cleaned = _clean_value(ln_stripped)
            if cleaned:
                fields["description"] = cleaned
                break

    # Reject if we couldn't even extract a family or description —
    # probably a redirect, disambig, or non-ability page.
    if not fields.get("family") and not fields.get("description"):
        return None
    return fields


def parse_ability_page(title, wikitext):
    """Parse one ability page into our canonical dict.

    Tries template extraction first; falls back to free-text label
    scanning. Always populates `name` from the page title. Empty
    strings are stored for missing canonical fields so consumers can
    iterate uniformly.
    """
    fields = parse_template(wikitext)
    if fields is None:
        fields = parse_freetext(wikitext, title)
    if fields is None:
        return None
    # Ensure name is the page title (template might omit or differ).
    fields["name"] = fields.get("name") or title
    # Ensure all canonical fields exist (empty if missing).
    for k in ("description", "family", "type", "dispel",
              "utsusemi", "range", "notes"):
        fields.setdefault(k, "")
    return fields


# ── Output assembly ─────────────────────────────────────────────────

def write_output(path, abilities_dict):
    """Write the JSON output, including derived family→abilities map.

    Writes atomically via tempfile + rename, so a Ctrl-C mid-write
    doesn't corrupt the file.
    """
    # Build the family rollup. Family keys lowercased; ability names
    # kept in their canonical (title-case) form.
    families = {}
    for name, ab in abilities_dict.items():
        fam = (ab.get("family") or "").strip().lower()
        if not fam:
            continue
        families.setdefault(fam, []).append(name)
    # Sort each family's ability list alphabetically for deterministic
    # output (cleaner diffs when the scraper is re-run).
    for fam in families:
        families[fam] = sorted(set(families[fam]))

    out = {
        "_meta": {
            "source":      "ffxiclopedia.fandom.com",
            "category":    CATEGORY_TITLE,
            "scraped_at":  datetime.now(timezone.utc).isoformat(),
            "ability_count": len(abilities_dict),
            "family_count":  len(families),
        },
        "abilities": dict(sorted(abilities_dict.items())),
        "families":  dict(sorted(families.items())),
    }

    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def load_existing(path):
    """Load an existing output file for --resume. Returns empty dict
    if the file is missing or unreadable."""
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data.get("abilities", {}) or {}
    except Exception as e:
        print(f"  [WARN] couldn't load existing output ({e!r}); "
              f"starting fresh")
        return {}


# ── Main ────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="Scrape FFXIclopedia mob ability tooltips.")
    ap.add_argument("--output", "-o", default="mob_abilities.json",
                    help="Output JSON path (default: mob_abilities.json)")
    ap.add_argument("--limit", "-n", type=int, default=0,
                    help="Stop after N abilities (0 = no limit). "
                         "Useful for a quick test run.")
    ap.add_argument("--rate", type=float, default=DEFAULT_RATE,
                    help=f"Seconds between requests (default {DEFAULT_RATE})")
    ap.add_argument("--resume", action="store_true",
                    help="Skip abilities already present in --output")
    args = ap.parse_args()

    def log(msg):
        print(msg, flush=True)

    log(f"Output:  {args.output}")
    log(f"Rate:    {args.rate}s between requests")
    log(f"Limit:   {args.limit or 'unlimited'}")
    log(f"Resume:  {args.resume}")
    log("")

    abilities = load_existing(args.output) if args.resume else {}
    if abilities:
        log(f"Resuming with {len(abilities)} abilities already collected")

    log(f"Fetching category members from {CATEGORY_TITLE}")
    titles = list(fetch_category_members(
        CATEGORY_TITLE, args.rate, log))
    log(f"Got {len(titles)} category page titles\n")

    # Stable order so --resume is deterministic.
    titles.sort()

    fetched = 0
    skipped = 0
    failed = 0
    started_at = time.time()

    for i, title in enumerate(titles, 1):
        if args.resume and title in abilities:
            skipped += 1
            continue

        if args.limit and fetched >= args.limit:
            log(f"\nHit --limit {args.limit}, stopping early.")
            break

        wt = fetch_wikitext(title, args.rate)
        if not wt:
            failed += 1
            time.sleep(args.rate)
            continue

        ab = parse_ability_page(title, wt)
        if ab is None:
            failed += 1
            log(f"  [{i}/{len(titles)}] {title}: could not parse")
        else:
            abilities[title] = ab
            fetched += 1
            if fetched % 25 == 0:
                # Periodic flush so a crash doesn't lose recent progress.
                write_output(args.output, abilities)
                elapsed = time.time() - started_at
                rate = fetched / max(1, elapsed)
                log(f"  [{i}/{len(titles)}] {title}  "
                    f"({fetched} fetched, {rate:.1f}/s, "
                    f"checkpoint saved)")
            else:
                log(f"  [{i}/{len(titles)}] {title}")

        time.sleep(args.rate)

    # Final write.
    write_output(args.output, abilities)
    elapsed = time.time() - started_at
    log("")
    log(f"Done. {fetched} fetched, {skipped} skipped, {failed} failed "
        f"in {elapsed:.0f}s.")
    log(f"Wrote {args.output}")


if __name__ == "__main__":
    sys.exit(main() or 0)