#!/usr/bin/env python3
"""normalize_mob_icons.py — convert any image to a 128x128 mob icon.

Drop-in tool for taking images you've found by any means (BG-wiki manual
download, in-game screenshot, AI-generated, hand-drawn) and normalizing
them into the format OmniWatch's overlay expects: 128x128 RGBA PNG with
the source image proportionally scaled and padded onto a transparent
canvas.

Filename convention:
    Source: anything you want — Goblin.jpg, crab_funny.png, Bee 1.gif
    Output: lowercased family name only — goblin.png, crab.png, bee.png

The output filename is derived from the input filename (with the
extension stripped and lowercased). If you saved a file as
'Goblin Leecher.png' it becomes 'goblin leecher.png' — which is
probably NOT what you want. The overlay looks up by FAMILY name, so
rename your source files to the family name BEFORE running this.

Usage:
    Drop your image files into <DataScrape>/inbox/
    Then run:
        py normalize_mob_icons.py

    Or specify directories:
        py normalize_mob_icons.py --src ./mypics --out ./data/mob_icons

    Or process a single file:
        py normalize_mob_icons.py --src goblin.jpg

The script is idempotent — running it again only processes new files
(checks the destination first). Existing icons are not overwritten
unless --force is passed.
"""

import argparse
import os
import sys

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow not installed. Run: pip install Pillow",
          file=sys.stderr)
    sys.exit(1)


OUTPUT_SIZE = (128, 128)
SUPPORTED_EXT = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.tga'}


def normalize_image(src_path, dest_path):
    """Convert one image to a 128x128 RGBA PNG with transparent padding.

    Returns (success: bool, message: str).
    """
    try:
        with Image.open(src_path) as src:
            src = src.convert("RGBA")
            # Proportional shrink to fit within OUTPUT_SIZE.
            src.thumbnail(OUTPUT_SIZE, Image.LANCZOS)
            # Centered paste onto transparent canvas.
            canvas = Image.new("RGBA", OUTPUT_SIZE, (0, 0, 0, 0))
            cx = (OUTPUT_SIZE[0] - src.size[0]) // 2
            cy = (OUTPUT_SIZE[1] - src.size[1]) // 2
            canvas.paste(src, (cx, cy), src)
            canvas.save(dest_path, format="PNG", optimize=True)
        return True, f"OK ({src.size[0]}x{src.size[1]} → 128x128)"
    except Exception as e:
        return False, f"ERROR: {e}"


def process_directory(src_dir, out_dir, force=False):
    """Walk src_dir and normalize every supported image into out_dir."""
    os.makedirs(out_dir, exist_ok=True)
    n_done = n_skip = n_fail = 0
    for entry in sorted(os.listdir(src_dir)):
        src_path = os.path.join(src_dir, entry)
        if not os.path.isfile(src_path):
            continue
        name, ext = os.path.splitext(entry)
        if ext.lower() not in SUPPORTED_EXT:
            print(f"  skip (not an image): {entry}")
            continue
        # Derived output name: lowercase, .png extension.
        out_name = name.lower() + ".png"
        out_path = os.path.join(out_dir, out_name)
        if os.path.exists(out_path) and not force:
            print(f"  skip (already exists): {out_name}")
            n_skip += 1
            continue
        ok, msg = normalize_image(src_path, out_path)
        if ok:
            print(f"  {entry:40s} → {out_name}  [{msg}]")
            n_done += 1
        else:
            print(f"  {entry:40s} → FAILED  [{msg}]")
            n_fail += 1
    return n_done, n_skip, n_fail


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_src = os.path.join(here, "inbox")
    default_out = os.path.join(here, "data", "mob_icons")

    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", default=default_src,
                    help="Source directory or single file. "
                         f"Defaults to {default_src}.")
    ap.add_argument("--out", default=default_out,
                    help="Output directory. "
                         f"Defaults to {default_out}.")
    ap.add_argument("--force", action="store_true",
                    help="Overwrite existing icons (default: skip).")
    args = ap.parse_args()

    if not os.path.exists(args.src):
        print(f"ERROR: source not found: {args.src}", file=sys.stderr)
        print(f"Hint: drop image files into {default_src} and rerun, "
              f"or pass --src <path>.", file=sys.stderr)
        return 1

    if os.path.isfile(args.src):
        # Single-file mode.
        os.makedirs(args.out, exist_ok=True)
        name, ext = os.path.splitext(os.path.basename(args.src))
        if ext.lower() not in SUPPORTED_EXT:
            print(f"ERROR: not a supported image type: {args.src}",
                  file=sys.stderr)
            return 1
        out_path = os.path.join(args.out, name.lower() + ".png")
        if os.path.exists(out_path) and not args.force:
            print(f"Already exists: {out_path}")
            print("Use --force to overwrite.")
            return 0
        ok, msg = normalize_image(args.src, out_path)
        if ok:
            print(f"{args.src} → {out_path}  [{msg}]")
            return 0
        else:
            print(f"FAILED: {msg}", file=sys.stderr)
            return 1

    # Directory mode.
    print(f"Source: {args.src}")
    print(f"Output: {args.out}")
    print()
    n_done, n_skip, n_fail = process_directory(args.src, args.out,
                                                  force=args.force)
    print()
    print(f"Done. saved={n_done} skipped(already_exists)={n_skip} "
          f"failed={n_fail}")
    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())