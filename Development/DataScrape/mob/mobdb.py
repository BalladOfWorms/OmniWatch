#!/usr/bin/env python3
"""
mobdb.py
==============

One-shot script to merge OmniWatch's two mob data sources:
  - The legacy per-zone .lua MobDB files (one .lua per zone, with damage
    modifiers, level ranges, immunity flags, etc.)
  - The BG-wiki scrape JSON (abilities, spells, element resists, intro
    text, BG-wiki URL, image refs).

Output: a single mob_individuals.json that contains the union of both
sources' fields. OmniWatch loads this single file at startup; the .lua
files become unnecessary at runtime.

USAGE
-----
    python mobdb.py \
        --json   addons/OmniWatch/data/mobdata/mob_individuals.json \
        --lua    addons/OmniWatch/data/mobdata/ \
        --output addons/OmniWatch/data/mobdata/mob_individuals_merged.json

If you're standing in the OmniWatch addon root, the defaults work:
    python mobdb.py

The script does NOT modify either source — it writes a fresh output file
you can inspect before swapping it in. To replace the live data, rename
the output to mob_individuals.json once verified.

DESIGN
------
The two sources have non-trivial schema differences. We unify them like
so:

  * Keys are LOWERCASE name strings (matches existing JSON's index style).
  * Each entry is a dict with fields from both sources merged.
  * .lua-only fields (damage modifiers, zone arrays, immunity flags) get
    namespaced under entry["zones"] to preserve per-zone variations.
  * JSON-only fields (abilities, spells, intro_text, etc.) become
    top-level fields on the entry.
  * Where both have the same field (family, aggro, link, detects), the
    .lua source wins for booleans (game-engine accurate), but JSON's
    string formats are preserved alongside as `_display_<field>`.
  * Mobs in only one source are kept; missing fields default to empty.

Name matching is exact-after-lowercase. Some mismatches are expected
(quote styles, punctuation differences); the script reports them but
keeps the entry under each source's own name. Manual fixup after.

OUTPUT FIELDS
-------------
  display          str    Pretty name (from JSON or .lua _name)
  family           str    Mob family (e.g. "Yagudo", "Crab")
  type             str    Broader category (e.g. "Birds", "Lizards")
  aggro            bool   True if aggro (.lua canonical)
  link             bool   Linking behavior (.lua canonical)
  detects          str    "True Sight", "True Sound", etc. (JSON)
  detect_flags     dict   Per-mode booleans: {sight, sound, blood, magic, ja, scent}
  crystal          str    Element crystal drop (JSON)
  abilities        list   TP move names (JSON)
  spells           list   Spell names (JSON)
  resists          list   Element resists (JSON)
  susceptible      list   Element weaknesses (JSON)
  absorbs          list   Element absorbs (JSON)
  immune           list   Element immunities (JSON)
  traits           list   (JSON)
  main_job         str    Mob's primary job (JSON)
  sub_job          str    Mob's sub job (JSON)
  intro_text       str    BG-wiki intro/notes (JSON)
  link_url         str    BG-wiki page URL (JSON)
  image_filename   str    Image filename if cached (cache JSON)
  image_url        str    Direct BG-wiki image URL (cache JSON)
  zones            list   Per-zone .lua entries: [{zone_id, level_range,
                          modifiers, immunities, ...}]

REQUIREMENTS
------------
Python 3.7+. Stdlib only.
"""

import argparse
import json
import os
import re
import sys
from collections import defaultdict


# ── .lua mobdb parser ─────────────────────────────────────────────────────
# This mirrors the parser in OmniWatch.py (_parse_mobdb_file +
# _parse_mob_body). Kept independent so this script has zero coupling
# to the main addon — it can run standalone.

def parse_mob_body(body):
    """Extract key fields from a MobDB entry body string."""
    out = {
        "notorious": False,
        "aggro":     False,
        "link":      False,
        "truesight": False,
        "sight":     False,
        "sound":     False,
        "blood":     False,
        "magic":     False,
        "ja":        False,
        "scent":     False,
        "min_level": 0,
        "max_level": 0,
        "immunities": 0,
        "respawn":    0,
        "job":        0,
        "family":     "",
        "modifiers":  {},
        "spells":     [],
    }

    # Bools/scalars. Word boundary on left side prevents "Sight" matching inside
    # "TrueSight".
    bool_fields = ["Notorious", "Aggro", "Link", "TrueSight",
                   "Sight", "Sound", "Blood", "Magic", "JA", "Scent"]
    for fld in bool_fields:
        m = re.search(r"(?:^|[^A-Za-z])" + fld + r"\s*=\s*(true|false)",
                      body, re.IGNORECASE)
        if m:
            out[fld.lower()] = (m.group(1).lower() == "true")

    int_fields = ["MinLevel", "MaxLevel", "Immunities", "Respawn", "Job"]
    out_keys   = ["min_level", "max_level", "immunities", "respawn", "job"]
    for fld, key in zip(int_fields, out_keys):
        m = re.search(r"\b" + fld + r"\s*=\s*(\d+)", body)
        if m:
            try: out[key] = int(m.group(1))
            except ValueError: pass

    # Family (string).
    m = re.search(r"\bFamily\s*=\s*'([^']*)'", body)
    if m:
        out["family"] = m.group(1)

    # Modifiers = { Slashing=1.0, Piercing=0.85, ... }
    m = re.search(r"\bModifiers\s*=\s*\{([^}]*)\}", body)
    if m:
        for kvp in re.finditer(r"(\w+)\s*=\s*([\d.]+)", m.group(1)):
            try: out["modifiers"][kvp.group(1).lower()] = float(kvp.group(2))
            except ValueError: pass

    # Spells = { 1, 2, 3, ... } — list of spell IDs
    m = re.search(r"\bSpells\s*=\s*\{([^}]*)\}", body)
    if m:
        for sid in re.finditer(r"\d+", m.group(1)):
            out["spells"].append(int(sid.group(0)))

    return out


def parse_mobdb_lua(path):
    """Parse one .lua MobDB file. Yields (zone_id, name, parsed_body)."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError) as e:
        print(f"  [warn] could not read {path}: {e}", file=sys.stderr)
        return

    m = re.search(r"--\s*Zone\s*ID:\s*(\d+)", text)
    zone_id = int(m.group(1)) if m else 0

    pattern = re.compile(
        r"\[\s*'((?:[^'\\]|\\.)*)'\s*\]\s*=\s*\{\s*((?:[^{}]|\{[^{}]*\})*)\s*\}",
        re.DOTALL,
    )
    for match in pattern.finditer(text):
        name = match.group(1).replace("\\'", "'")
        body = match.group(2)
        entry = parse_mob_body(body)
        yield zone_id, name, entry


def load_lua_dir(lua_dir):
    """Walk a directory of .lua mobdb files. Returns { lower_name: [entries] }."""
    if not os.path.isdir(lua_dir):
        print(f"[warn] no .lua mobdb dir at {lua_dir}; .lua-side will be empty.",
              file=sys.stderr)
        return {}
    by_lower = defaultdict(list)
    files = sorted(f for f in os.listdir(lua_dir) if f.lower().endswith(".lua"))
    if not files:
        print(f"[warn] no .lua files in {lua_dir}", file=sys.stderr)
        return {}
    print(f"Scanning {len(files)} .lua files in {lua_dir} ...")
    total = 0
    for fn in files:
        for zone_id, name, entry in parse_mobdb_lua(os.path.join(lua_dir, fn)):
            entry["_zone_id"] = zone_id
            entry["_name"]    = name
            by_lower[name.lower()].append(entry)
            total += 1
    print(f"  → {total} entries across {len(by_lower)} unique names.")
    return dict(by_lower)


# ── Image cache reader ───────────────────────────────────────────────────

def load_image_cache(path):
    """Load _mob_image_cache.json. Returns:
        ({ lower_name: (filename, url) },
         { display_name: filename })   # raw, for the migrator
    """
    if not os.path.isfile(path):
        return {}, {}
    with open(path, "r", encoding="utf-8") as f:
        d = json.load(f)
    out = {}
    fnames = d.get("image_filenames", {}) or {}
    urls   = d.get("image_urls", {})       or {}
    for display, fname in fnames.items():
        if not fname:
            continue
        out[display.lower()] = (fname, urls.get(fname, ""))
    return out, dict(fnames)


# ── Main merge ──────────────────────────────────────────────────────────

def detect_flags_from_string(s):
    """Convert JSON's "True Sight"/"True Sound" etc. strings into per-mode
    booleans matching the .lua schema. Multi-mode strings split on '/' or ','."""
    out = {"sight": False, "sound": False, "blood": False, "magic": False,
           "ja": False, "scent": False, "truesight": False, "truesound": False}
    if not s:
        return out
    text = s.lower()
    # Catch true* variants first since "true sight" contains "sight".
    if "true sight"  in text: out["truesight"] = True; out["sight"] = True
    if "true sound"  in text: out["truesound"] = True; out["sound"] = True
    if "sight"       in text and not out["sight"]:  out["sight"]  = True
    if "sound"       in text and not out["sound"]:  out["sound"]  = True
    if "blood"       in text: out["blood"]  = True
    if "magic"       in text: out["magic"]  = True
    if "scent"       in text: out["scent"]  = True
    if "ja"          in text or "job ability" in text: out["ja"] = True
    return out


def name_to_image_key(name):
    """Convert a mob's display/lowercase name into a filename-safe image
    key. Strips spaces, apostrophes, hyphens, periods, commas. Lowercased.
    Examples:
        "Goblin Leecher"   → "goblinleecher"
        "Goblin's Leech"   → "goblinsleech"
        "Aa Nawu the Thunderblade" → "aanawuthethunderblade"
    """
    if not name:
        return ""
    out = name.lower()
    for ch in (" ", "'", "-", ".", ",", '"'):
        out = out.replace(ch, "")
    return out


def copy_cached_images(image_cache_dir, image_filenames_map, dest_dir,
                       merged_records):
    """Copy any cached scrape images into the new mobicons/ folder using
    the mob-name-derived filename. Returns count of images successfully
    placed.

    image_cache_dir: where the scrape's downloaded images live (the
        folder of .jpg/.png files alongside _mob_image_cache.json).
        Pass None to skip copying — useful when the user only has the
        JSON files and no image files to migrate.
    image_filenames_map: { display_name: scrape_filename } from the cache.
        E.g. {"Goblin Leecher": "Goblin_Leecher.jpg"}.
    dest_dir: target mobicons/ folder.
    merged_records: dict of merged mob entries; we read `image` field
        from each and rename the source file to match.
    """
    if not image_cache_dir or not os.path.isdir(image_cache_dir):
        return 0
    try:
        os.makedirs(dest_dir, exist_ok=True)
    except OSError as e:
        print(f"  [warn] could not create {dest_dir}: {e}", file=sys.stderr)
        return 0

    # Index source files by lowercase basename for tolerant matching.
    by_lower = {}
    try:
        for fn in os.listdir(image_cache_dir):
            by_lower[fn.lower()] = fn
    except OSError as e:
        print(f"  [warn] could not list {image_cache_dir}: {e}", file=sys.stderr)
        return 0

    import shutil
    copied = 0
    skipped = 0
    for name_lower, rec in merged_records.items():
        img_key = rec.get("image", "")
        if not img_key:
            continue
        # The display-name version that maps to the source filename.
        display = rec.get("display") or name_lower
        src_fn = image_filenames_map.get(display, "")
        if not src_fn:
            continue
        # Find the actual file (case-insensitive).
        src_actual = by_lower.get(src_fn.lower())
        if not src_actual:
            skipped += 1
            continue
        # Preserve source extension. Most are .jpg or .png.
        ext = os.path.splitext(src_actual)[1].lower() or ".png"
        dest_fn = img_key + ext
        dest_path = os.path.join(dest_dir, dest_fn)
        if os.path.exists(dest_path):
            continue   # already migrated; don't re-copy
        try:
            shutil.copy2(os.path.join(image_cache_dir, src_actual), dest_path)
            copied += 1
        except OSError as e:
            print(f"  [warn] copy {src_actual} → {dest_fn}: {e}",
                  file=sys.stderr)
    if skipped:
        print(f"  ({skipped} entries had image filenames the script "
              "couldn't locate in the cache folder.)")
    return copied


def merge(json_data, lua_data, image_cache):
    """Produce the merged dict keyed by lowercase name.

    For each unique name across both sources, we build a single record
    containing every field from both. Per-zone .lua data accumulates
    under entry["zones"]. Image references collapse to a single
    `image` field per mob (string key, or empty if no image available).
    """
    merged = {}
    json_inds = json_data.get("individuals", {}) or {}

    # Universe of all names from both sources.
    all_names = set(json_inds.keys()) | set(lua_data.keys())

    for name_lower in sorted(all_names):
        json_rec = json_inds.get(name_lower) or {}
        lua_recs = lua_data.get(name_lower) or []
        display  = json_rec.get("display") or (
            lua_recs[0].get("_name") if lua_recs else name_lower)

        if lua_recs:
            r = lua_recs[0]
            detect_flags = {
                "sight":     bool(r.get("sight"))     or bool(r.get("truesight")),
                "sound":     bool(r.get("sound")),
                "blood":     bool(r.get("blood")),
                "magic":     bool(r.get("magic")),
                "ja":        bool(r.get("ja")),
                "scent":     bool(r.get("scent")),
                "truesight": bool(r.get("truesight")),
                "truesound": False,
            }
            aggro_bool = bool(r.get("aggro"))
            link_bool  = bool(r.get("link"))
            family     = r.get("family") or json_rec.get("family") or ""
        else:
            detect_flags = detect_flags_from_string(json_rec.get("detects", ""))
            aggro_bool = (json_rec.get("aggro", "").strip().lower() == "yes")
            link_bool  = (json_rec.get("link", "").strip().lower() == "yes")
            family     = json_rec.get("family") or ""

        zones = []
        for r in lua_recs:
            zones.append({
                "zone_id":    r.get("_zone_id", 0),
                "min_level":  r.get("min_level", 0),
                "max_level":  r.get("max_level", 0),
                "immunities": r.get("immunities", 0),
                "respawn":    r.get("respawn", 0),
                "job":        r.get("job", 0),
                "modifiers":  dict(r.get("modifiers", {})),
                "spells":     list(r.get("spells", [])),
                "notorious":  bool(r.get("notorious")),
            })

        # Image key: derive from name. We only set a non-empty value
        # when the scrape's image cache had a real entry for this mob;
        # otherwise it stays empty and the entry is a slot you fill in
        # manually by dropping a file into mobicons/.
        scrape_filename, scrape_url = image_cache.get(name_lower, ("", ""))
        # Image filename naming: scraped-image entries get the
        # name-derived key; user can rename the file on disk to match.
        # Empty string when no image is known (slot-to-fill).
        img_key = name_to_image_key(display) if scrape_filename else ""

        merged[name_lower] = {
            "display":         display,
            "family":          family,
            "type":            json_rec.get("type", ""),
            "aggro":           aggro_bool,
            "link":            link_bool,
            "detect_flags":    detect_flags,
            "_display_aggro":  json_rec.get("aggro", ""),
            "_display_link":   json_rec.get("link", ""),
            "_display_detects": json_rec.get("detects", ""),
            "crystal":         json_rec.get("crystal", ""),
            "abilities":       list(json_rec.get("abilities", [])),
            "spells_named":    list(json_rec.get("spells", [])),
            "resists":         list(json_rec.get("resists", [])),
            "susceptible":     list(json_rec.get("susceptible", [])),
            "absorbs":         list(json_rec.get("absorbs", [])),
            "immune":          list(json_rec.get("immune", [])),
            "traits":          list(json_rec.get("traits", [])),
            "main_job":        json_rec.get("main_job", ""),
            "sub_job":         json_rec.get("sub_job", ""),
            "intro_text":      json_rec.get("intro_text", ""),
            "image":           img_key,    # filename stem (no extension)
            "image_url":       scrape_url, # for on-demand re-download if file missing
            "zones":           zones,
        }

    only_json = sum(1 for n in all_names if n not in lua_data)
    only_lua  = sum(1 for n in all_names if n not in json_inds)
    both      = sum(1 for n in all_names if n in lua_data and n in json_inds)
    with_img  = sum(1 for v in merged.values() if v["image"])
    print(f"\nMerge stats:")
    print(f"  Total unique mob names: {len(all_names)}")
    print(f"  In both sources:        {both}")
    print(f"  JSON only:              {only_json}")
    print(f"  .lua only:              {only_lua}")
    print(f"  With image refs:        {with_img}")

    return merged


def main():
    here = os.path.abspath(os.path.dirname(__file__))
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--json",
        default=os.path.join(here, "mob_individuals.json"),
        help="BG-wiki scrape JSON (default: ./mob_individuals.json)")
    p.add_argument("--cache",
        default=os.path.join(here, "_mob_image_cache.json"),
        help="Image-cache JSON (default: ./_mob_image_cache.json)")
    p.add_argument("--lua",
        default=here,
        help="Directory containing .lua mobdb files "
             "(default: alongside this script)")
    p.add_argument("--images",
        default=here,
        help="Directory containing the SCRAPE's downloaded image files "
             "(.jpg/.png) to migrate into mobicons/ "
             "(default: alongside this script)")
    p.add_argument("--mobicons",
        default=os.path.join(here, "mobicons"),
        help="Output directory for migrated images "
             "(default: ./mobicons)")
    p.add_argument("--output",
        default=os.path.join(here, "mob_individuals_merged.json"),
        help="Output filename (default: ./mob_individuals_merged.json)")
    args = p.parse_args()

    # Load.
    print(f"Loading JSON scrape: {args.json}")
    with open(args.json, "r", encoding="utf-8") as f:
        json_data = json.load(f)
    print(f"  → {len(json_data.get('individuals', {}))} entries.")

    print(f"Loading image cache: {args.cache}")
    image_cache, image_filenames_map = load_image_cache(args.cache)
    print(f"  → {len(image_cache)} mob→image mappings.")

    print(f"Scanning .lua dir: {args.lua}")
    lua_data = load_lua_dir(args.lua)

    # Merge.
    merged = merge(json_data, lua_data, image_cache)

    # Copy any cached images into mobicons/ with new naming.
    if image_filenames_map:
        print(f"\nMigrating images: {args.images} → {args.mobicons}")
        copied = copy_cached_images(
            args.images, image_filenames_map, args.mobicons, merged)
        print(f"  → {copied} images copied.")

    # Wrap with metadata so consumers can know what they got.
    out = {
        "_meta": {
            "schema_version": 2,   # bumped: image format changed
            "merged_from": {
                "json":  os.path.basename(args.json),
                "cache": os.path.basename(args.cache),
                "lua":   args.lua,
            },
            "entry_count": len(merged),
        },
        "individuals": merged,
    }

    # Write. Top-level keys are alphabetized (sorted iteration of
    # all_names in merge()) so manual editing is easy. JSON stable
    # sort means re-running the script doesn't shuffle entries.
    print(f"\nWriting merged file: {args.output}")
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False, sort_keys=False)
    size_mb = os.path.getsize(args.output) / (1024 * 1024)
    print(f"  → {size_mb:.1f} MB")
    print("\nDone. Inspect the output, then rename it to mob_individuals.json")
    print("to make OmniWatch use the merged data. Drop additional images")
    print(f"into {args.mobicons}/ named after the mob (e.g. goblinleecher.png)")
    print('and edit the JSON entry\'s "image" field to match.')


if __name__ == "__main__":
    main()