"""OmniWatch chat routing config editor — per-job filter GUI.

Standalone pygame-ce app. Edits per-job routing JSONs that gate which
combat events appear in which chat panel tabs.

Storage (in SETTINGS_DIR alongside other OmniWatch config):
  omniwatch_chat_routing.json          — global config (fallback)
  omniwatch_chat_routing-<JOB>.json    — per-job override

Cell semantics:
  None (no entry)     — emit to default destination tab
  []                  — hide entirely
  ["TabName"]         — emit to specified tab(s) instead

Layered resolution at runtime (OmniWatch.py):
  per-job → global → baked-in defaults

Build via RoutingGuiUpdate.bat (mirrors PythonUpdate.bat style).
"""

import json
import os
import sys
from pathlib import Path

import pygame
import pygame.freetype


# ─────────────────────────────────────────────────────────────────────
# Constants — must match OmniWatch.py's routing model
# ─────────────────────────────────────────────────────────────────────

# The canonical entity list, reused as the target buckets for the
# Monsters section (a mob can act on any of these).
ENTITIES = [
    ("self",      "Me"),
    ("party",     "Party members"),
    ("alliance",  "Alliance members"),
    ("pet",       "My pet/trust"),
    ("party_pet", "Party member pets"),
    ("other",     "Other players (not in party)"),
    ("other_pet", "Other players' pets/trusts"),
    ("mob",       "Monsters"),
    ("npc",       "NPCs"),
]

# Flat actors — single channel row each. Every actor except the two
# monster classes (mob_engaged / mob_passive) is flat.
FLAT_ACTORS = [
    ("self",        "Self (Me as actor)"),
    ("party",       "Party members"),
    ("alliance",    "Alliance members"),
    ("pet",         "My pet/trust"),
    ("party_pet",   "Party member pets"),
    ("other",       "Other players (not in party)"),
    ("other_pet",   "Other players' pets/trusts"),
    ("npc",         "NPCs"),
]

# Nested actors (actor → target → channel), so the user can route, e.g.,
# "mob melee on me" separately from "mob melee on another player". No
# "Any target" row — to route a mob action regardless of target, set the
# same value on each target row, or use the global/per-job default.
#
# Monsters are split into two actor classes by claim:
#   mob_engaged — your group has claim (the fight you're in)
#   mob_passive — another party's claim, or unclaimed (hidden by
#                 default; this is the engaged-vs-passive filter that
#                 in-game filters and BattleMod expose)
# A pre-split config that used a single 'mob' actor is migrated to
# 'mob_engaged' on load (see _migrate_legacy_mob), and the runtime also
# accepts a legacy 'mob' cell as an alias for mob_engaged.
NESTED_ACTORS = [
    ("mob_engaged", "Monsters — engaged (your group's claim)"),
    ("mob_passive", "Monsters — passive (other party's / unclaimed)"),
]

# Target buckets for the Monsters actor. The generic "Monsters"
# target is split into two: a mob acting on ITSELF (self-buff, self-
# cure) vs a mob acting on a DIFFERENT monster. The runtime
# distinguishes these by comparing actor_id and target_id.
MOB_TARGETS = [
    ("self",      "Me"),
    ("party",     "Party members"),
    ("alliance",  "Alliance members"),
    ("pet",       "My pet/trust"),
    ("party_pet", "Party member pets"),
    ("other",     "Other players (not in party)"),
    ("other_pet", "Other players' pets/trusts"),
    ("self_mob",  "Itself"),
    ("other_mob", "Other monsters"),
    ("npc",       "NPCs"),
]
NESTED_TARGETS = list(MOB_TARGETS)

# Quick show/hide toggles shown in the footer bar — the common
# player-chat channels. Internal name (matches OmniWatch.py's
# classifier channel names) → short display label.
QUICK_CHANNELS = [
    ("chat_say",   "Say"),
    ("chat_tell",  "Tell"),
    ("chat_emote", "Emote"),
    ("chat_party", "Party"),
    ("chat_shout", "Shout"),
    ("chat_yell",  "Yell"),
]

# Combat-only channels. Real chat (say/tell/LS) is always routed to
# fixed tabs and doesn't appear here.
CHANNELS = [
    ("melee",        "Melee attacks"),
    ("ranged",       "Ranged attacks"),
    ("misses",       "Misses (any kind)"),
    ("weaponskills", "Weapon skills"),
    ("abilities",    "Job abilities"),
    ("damage",       "Damage spells"),
    ("healing",      "Healing spells"),
    ("casting",      "Spell casts (start)"),
    ("readies",      "TP move readies"),
    ("uses",         "Item / ability uses"),
    ("buff_apply",   "Buff applied"),
    ("buff_wear",    "Buff wore off"),
    ("debuff_apply", "Debuff applied"),
    ("debuff_wear",  "Debuff wore off"),
]

# Destination tabs (must match OmniWatch.py chat_tab_names — combat-relevant only).
# Destination tabs. Each entry is (routing_id, default_label).
# For built-in tabs, routing_id == display label and the user
# cannot rename. For "custom_1" and "custom_2", routing_id is
# stable and the display label can be edited in the GUI top bar,
# persisted in _meta.tab_names in the routing JSON.
TABS = [
    ("Battle",   "Battle"),
    ("Buffs",    "Buffs"),
    ("Debuffs",  "Debuffs"),
    ("Mob",      "Mob"),
    ("custom_1", "Custom 1"),
    ("custom_2", "Custom 2"),
    ("System",   "System"),
]

# Internal ids of the user-renameable tabs.
CUSTOM_TAB_IDS = ("custom_1", "custom_2")

# Main jobs
JOBS = [
    "WAR", "MNK", "WHM", "BLM", "RDM", "THF", "PLD", "DRK",
    "BST", "BRD", "RNG", "SAM", "NIN", "DRG", "SMN", "BLU",
    "COR", "PUP", "DNC", "SCH", "GEO", "RUN",
]


# ─────────────────────────────────────────────────────────────────────
# Path resolution
# ─────────────────────────────────────────────────────────────────────

def _settings_dir():
    appdata = os.environ.get("APPDATA")
    if appdata:
        base = Path(appdata) / "OmniWatch"
    else:
        base = Path.home() / ".omniwatch"
    base.mkdir(parents=True, exist_ok=True)
    return base


def _config_path(job=None):
    """Return path to JSON for a job. job=None → global."""
    base = _settings_dir()
    if job:
        return base / f"omniwatch_chat_routing-{job.upper()}.json"
    return base / "omniwatch_chat_routing.json"


def _migrate_legacy_mob(data):
    """Migrate a pre-split routing config in place.

    Before the engaged/passive split there was a single 'mob' actor.
    The classifier now emits 'mob_engaged' / 'mob_passive'. When the GUI
    opens an older config we present the old 'mob' block under
    'mob_engaged' (engaged monsters were the only ones the old model
    could route to the Mob tab — they are the ones the user was looking
    at). 'mob_passive' starts empty (hidden by default at runtime), so
    the split's whole point — suppressing another party's fight — takes
    effect immediately without the user re-doing their mob config.

    Only migrates when there's a legacy 'mob' key AND no explicit
    'mob_engaged' yet, so re-saving (which writes 'mob_engaged') is
    idempotent and never clobbers a deliberate post-split config.
    """
    if not isinstance(data, dict):
        return data
    if "mob" in data and "mob_engaged" not in data:
        data["mob_engaged"] = data.pop("mob")
    return data


def load_config(path):
    if not path.exists():
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return _migrate_legacy_mob(data)
    except Exception as e:
        print(f"[routing-gui] Could not read {path}: {e}")
    return {}


def _load_custom_labels(path):
    """Read _meta.tab_names from the routing JSON.

    Returns a dict mapping custom_1/custom_2 → user-chosen label.
    Falls back to the TABS default label for any tab not in the
    overrides. Safe to call when the file doesn't exist.
    """
    out = {tab_id: default for tab_id, default in TABS
           if tab_id in CUSTOM_TAB_IDS}
    if not path.exists():
        return out
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        meta = data.get("_meta") if isinstance(data, dict) else None
        if isinstance(meta, dict):
            names = meta.get("tab_names")
            if isinstance(names, dict):
                for tab_id, label in names.items():
                    if tab_id in CUSTOM_TAB_IDS and isinstance(label, str) \
                            and label.strip():
                        out[tab_id] = label.strip()
    except Exception as e:
        print(f"[routing-gui] Could not read custom labels: {e}")
    return out


def _load_channel_filters(path):
    """Read _meta.channel_hidden and _meta.blacklist from the routing
    JSON. Returns (hidden_set, blacklist_list). Safe when the file
    doesn't exist."""
    hidden = set()
    blacklist = []
    if not path.exists():
        return hidden, blacklist
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        meta = data.get("_meta") if isinstance(data, dict) else None
        if isinstance(meta, dict):
            ch = meta.get("channel_hidden")
            if isinstance(ch, list):
                hidden = {c for c in ch if isinstance(c, str)}
            bl = meta.get("blacklist")
            if isinstance(bl, list):
                blacklist = [s.strip() for s in bl
                             if isinstance(s, str) and s.strip()]
    except Exception as e:
        print(f"[routing-gui] Could not read channel filters: {e}")
    return hidden, blacklist


def save_config(path, data, custom_labels=None,
                channel_hidden=None, blacklist=None):
    meta = {
        "version": 2,
        "comment": "Edited by omniwatch_routing_gui.exe. Cells: "
                   "list of tab names or empty list to hide.",
    }
    # Persist non-default custom tab labels in _meta.tab_names. If
    # the user reset a tab back to its default label, it's omitted
    # so the saved file doesn't carry redundant data.
    if custom_labels:
        defaults = {tab_id: default for tab_id, default in TABS
                    if tab_id in CUSTOM_TAB_IDS}
        renamed = {}
        for tab_id, label in custom_labels.items():
            if (tab_id in CUSTOM_TAB_IDS
                    and isinstance(label, str)
                    and label.strip()
                    and label.strip() != defaults.get(tab_id)):
                renamed[tab_id] = label.strip()
        if renamed:
            meta["tab_names"] = renamed
    # Persist global channel-hide toggles + sender blacklist.
    if channel_hidden:
        ch = sorted(c for c in channel_hidden if isinstance(c, str))
        if ch:
            meta["channel_hidden"] = ch
    if blacklist:
        bl = sorted(s.strip() for s in blacklist
                    if isinstance(s, str) and s.strip())
        if bl:
            meta["blacklist"] = bl
    out = {"_meta": meta}
    # Filter out empty actor sections. set_cell prunes individually
    # but this is defense-in-depth: an empty actor dict in the saved
    # JSON serves no purpose (it routes nothing) and risks confusing
    # downstream readers. Same goes for nested actor → target dicts
    # that ended up empty after channel removals.
    for k, v in data.items():
        if k.startswith("_"):
            continue
        if not isinstance(v, dict):
            continue
        # For nested actors (monsters/enemies), prune empty target dicts.
        cleaned = {}
        nested = False
        for inner_k, inner_v in v.items():
            if isinstance(inner_v, dict):
                nested = True
                if inner_v:
                    cleaned[inner_k] = inner_v
            else:
                cleaned[inner_k] = inner_v
        if nested:
            if cleaned:
                out[k] = cleaned
        else:
            if v:
                out[k] = v
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)


# ─────────────────────────────────────────────────────────────────────
# Routing model
# ─────────────────────────────────────────────────────────────────────

class RoutingModel:
    """Wraps a routing config dict.

    Flat actor cells:    data[actor][channel] = [tabs]
    Nested actor cells:  data[actor][target][channel] = [tabs]

    Conventions:
      - missing cell = use default (None when queried)
      - empty list   = explicitly hidden
      - list         = explicit destinations
    """
    def __init__(self, data):
        self.data = {k: v for k, v in data.items() if not k.startswith("_")}
        self._migrate_legacy()

    def _migrate_legacy(self):
        """Fold legacy 'monsters' / 'enemies' nested data into 'mob' flat.

        Old GUI versions exposed engaged/passive nested sections that the
        runtime never honored. We squash to flat 'mob' on load.

        Conflict policy: prefer HIDE over show. If any nested target had
        a channel set to empty list (explicit hide), the migrated cell is
        hidden. This is safer than last-wins — if the user hid mob misses
        anywhere, they probably wanted them hidden everywhere; we don't
        want a migration to silently re-enable noise.
        """
        legacy_keys = ("monsters", "enemies")
        if not any(k in self.data for k in legacy_keys):
            return
        mob_entry = self.data.get("mob") or {}
        if not isinstance(mob_entry, dict):
            mob_entry = {}
        for key in legacy_keys:
            old = self.data.pop(key, None)
            if not isinstance(old, dict):
                continue
            for target, ch_map in old.items():
                if not isinstance(ch_map, dict):
                    continue
                for channel, tabs in ch_map.items():
                    if not isinstance(tabs, list):
                        continue
                    existing = mob_entry.get(channel)
                    # Hide wins: if either is [], keep [].
                    if tabs == [] or existing == []:
                        mob_entry[channel] = []
                    elif existing is None:
                        mob_entry[channel] = list(tabs)
                    # Otherwise keep the existing non-hide value.
        if mob_entry:
            self.data["mob"] = mob_entry

    def _is_nested(self, actor):
        # Every actor is nested now (actor → target → channel).
        return True

    def _is_nested(self, actor):
        # Only the mob actor (and anything in NESTED_ACTORS) is nested.
        return actor in {a for a, _ in NESTED_ACTORS}

    def get_cell(self, actor, target, channel):
        """Read a routing cell. Returns None if unset.

        Flat actors: actor[channel]. Nested actors (mob):
        actor[target][channel].
        """
        ad = self.data.get(actor)
        if not isinstance(ad, dict):
            return None
        if self._is_nested(actor):
            td = ad.get(target)
            if not isinstance(td, dict):
                return None
            return td.get(channel)
        v = ad.get(channel)
        return v if isinstance(v, list) else None

    def set_cell(self, actor, target, channel, tabs):
        """Write a routing cell. tabs=None deletes and prunes empties.

        Flat actors write actor[channel]; nested actors (mob) write
        actor[target][channel].
        """
        nested = self._is_nested(actor)
        if tabs is None:
            ad = self.data.get(actor)
            if not isinstance(ad, dict):
                return
            if nested:
                td = ad.get(target)
                if isinstance(td, dict):
                    td.pop(channel, None)
                    if not td:
                        ad.pop(target, None)
            else:
                ad.pop(channel, None)
            if not ad:
                self.data.pop(actor, None)
            return
        ad = self.data.setdefault(actor, {})
        if nested:
            td = ad.setdefault(target, {})
            if not isinstance(td, dict):
                td = {}
                ad[target] = td
            td[channel] = list(tabs)
        else:
            ad[channel] = list(tabs)


# ─────────────────────────────────────────────────────────────────────
# Visual constants
# ─────────────────────────────────────────────────────────────────────

WINDOW_W = 980
WINDOW_H = 720

COLOR_BG          = (24, 26, 32)
COLOR_PANEL       = (32, 36, 44)
COLOR_HEADER      = (44, 50, 62)
COLOR_BORDER      = (60, 70, 85)
COLOR_TEXT        = (220, 224, 230)
COLOR_TEXT_DIM    = (140, 145, 155)
COLOR_TEXT_BRIGHT = (250, 250, 250)
COLOR_ACCENT      = (90, 150, 220)
COLOR_HOVER       = (50, 58, 72)
COLOR_BUTTON      = (60, 100, 160)
COLOR_BUTTON_HOV  = (80, 130, 200)
COLOR_DANGER      = (180, 60, 60)
COLOR_DANGER_HOV  = (220, 80, 80)
COLOR_OK          = (60, 140, 80)
COLOR_OK_HOV      = (80, 180, 100)
COLOR_CELL_BG     = (40, 44, 52)
COLOR_CELL_OVR    = (32, 50, 36)   # green tint = explicit override
COLOR_DD_BG       = (40, 44, 52)
COLOR_ROW_ALT     = (30, 33, 40)   # barely lighter than COLOR_BG for zebra stripe

ROW_H        = 26
SECTION_H    = 30
SUBSECTION_H = 24
PAD          = 8
INDENT       = 16
HEADER_H     = 130
FOOTER_H     = 116
SCROLL_STEP  = 32

TAB_CHIP_COLORS = {
    "Battle":   (165,  60,  60),
    "Buffs":    ( 85, 145, 185),
    "Debuffs":  (160,  95, 160),
    "Mob":      (180,  80,  80),
    "System":   (140, 140, 140),
}


# ─────────────────────────────────────────────────────────────────────
# Widget helpers
# ─────────────────────────────────────────────────────────────────────

def draw_text(surface, font, text, pos, color=COLOR_TEXT):
    font.render_to(surface, pos, text, color)


def draw_button(surface, font, text, rect, hovered=False,
                bg=COLOR_BUTTON, bg_hov=COLOR_BUTTON_HOV,
                fg=COLOR_TEXT_BRIGHT):
    fill = bg_hov if hovered else bg
    pygame.draw.rect(surface, fill, rect, border_radius=4)
    pygame.draw.rect(surface, COLOR_BORDER, rect, width=1, border_radius=4)
    tw, th = font.get_rect(text).size
    font.render_to(surface,
                   (rect.x + (rect.width - tw) // 2,
                    rect.y + (rect.height - th) // 2 + 1),
                   text, fg)


def draw_checkbox(surface, rect, checked, hovered=False):
    pygame.draw.rect(surface, COLOR_CELL_BG, rect)
    pygame.draw.rect(surface,
                     COLOR_ACCENT if hovered else COLOR_BORDER,
                     rect, width=1)
    if checked:
        cx, cy = rect.center
        pygame.draw.lines(surface, COLOR_ACCENT, False,
                          [(rect.x + 3, cy),
                           (cx - 1, rect.bottom - 4),
                           (rect.right - 3, rect.y + 3)],
                          width=2)


# ─────────────────────────────────────────────────────────────────────
# Dropdown widget
# ─────────────────────────────────────────────────────────────────────

class Dropdown:
    def __init__(self):
        self.active = False
        self.trigger_rect = None
        self.options = []
        self.on_select = None
        self.row_rects = []

    def open(self, trigger_rect, options, on_select):
        self.active = True
        self.trigger_rect = trigger_rect
        self.options = options
        self.on_select = on_select
        self.row_rects = []

    def close(self):
        self.active = False
        self.trigger_rect = None
        self.options = []
        self.on_select = None
        self.row_rects = []

    def draw(self, surface, font):
        if not self.active or not self.trigger_rect:
            return
        row_h = 22
        ph = len(self.options) * row_h + 8
        pw = max(180, self.trigger_rect.width)
        px = self.trigger_rect.x
        py = self.trigger_rect.bottom + 2
        if py + ph > WINDOW_H:
            py = self.trigger_rect.y - ph - 2
        if px + pw > WINDOW_W:
            px = WINDOW_W - pw - 8

        bg = pygame.Rect(px, py, pw, ph)
        pygame.draw.rect(surface, COLOR_DD_BG, bg, border_radius=6)
        pygame.draw.rect(surface, COLOR_BORDER, bg, width=1, border_radius=6)

        mouse = pygame.mouse.get_pos()
        self.row_rects = []
        for i, (value, label) in enumerate(self.options):
            rrect = pygame.Rect(bg.x + 2, bg.y + 4 + i * row_h,
                                bg.width - 4, row_h)
            self.row_rects.append((rrect, value))
            hovered = rrect.collidepoint(mouse)
            if hovered:
                pygame.draw.rect(surface, COLOR_HOVER, rrect, border_radius=4)
            if value in TAB_CHIP_COLORS:
                chip = pygame.Rect(rrect.x + 8, rrect.y + 8, 10, 10)
                pygame.draw.rect(surface, TAB_CHIP_COLORS[value], chip)
                label_x = rrect.x + 24
            else:
                label_x = rrect.x + 10
            font.render_to(surface, (label_x, rrect.y + 5),
                           label, COLOR_TEXT_BRIGHT)

    def handle_click(self, pos):
        if not self.active:
            return False
        for rrect, value in self.row_rects:
            if rrect.collidepoint(pos):
                cb = self.on_select
                self.close()
                if cb:
                    cb(value)
                return True
        self.close()
        return True


# ─────────────────────────────────────────────────────────────────────
# Main app
# ─────────────────────────────────────────────────────────────────────

class App:
    def __init__(self):
        self.current_job = None
        self.path = _config_path(None)
        self.model = RoutingModel(load_config(self.path))
        self.custom_labels = _load_custom_labels(self.path)
        self.channel_hidden, self.blacklist = _load_channel_filters(self.path)
        # Blacklist add-input state.
        self.blacklist_focused = False
        self.blacklist_buffer = ""
        self.blacklist_rects = {}      # name → remove-button rect
        self.blacklist_input_rect = None
        # Horizontal scroll state for the blacklist chip row. The row
        # has finite width and can hold ~8-15 chips depending on name
        # length; longer lists overflow past the right edge. _hscroll
        # is the pixel offset shifting chips left so off-screen names
        # come into view. Persists across redraws; clamped to
        # [0, max_scroll] each frame after content width is known.
        # Arrow rects are written by _draw_panel and consumed by
        # handle_click; both None until the row has actually rendered.
        self._blacklist_hscroll = 0
        self._blacklist_arrow_left_rect = None
        self._blacklist_arrow_right_rect = None
        # Set during _draw_panel to the rect of the entire chip row,
        # for routing mousewheel events to horizontal scroll when the
        # cursor is over this band. None until first draw.
        self._blacklist_row_rect = None
        # Total content width (sum of chip widths + gaps) and visible
        # window width, recomputed each frame from the live blacklist.
        # Stored on the instance so handle_scroll can clamp without
        # re-walking the chip list.
        self._blacklist_content_w = 0
        self._blacklist_visible_w = 0
        self.quick_channel_rects = {}  # channel name → toggle rect
        self.dirty = False
        self.status = ""

        # All sections collapsed except self.
        self.expanded = {a: False for a, _ in FLAT_ACTORS}
        self.expanded["self"] = True
        for actor, _ in NESTED_ACTORS:
            self.expanded[actor] = False
            for tk, _ in NESTED_TARGETS:
                self.expanded[f"{actor}.{tk}"] = False

        # Tab-rename text input state. editing_tab is the routing id
        # of the tab currently being renamed (None when inactive).
        # editing_buffer holds the typed characters.
        self.editing_tab = None
        self.editing_buffer = ""
        self.rename_rects = {}    # id → pygame.Rect (input field)

        self.scroll = 0
        self.dropdown = Dropdown()

        pygame.init()
        pygame.freetype.init()
        self.screen = pygame.display.set_mode((WINDOW_W, WINDOW_H))
        pygame.display.set_caption("OmniWatch Chat Routing")
        self.font       = pygame.freetype.SysFont("Segoe UI", 13)
        self.font_small = pygame.freetype.SysFont("Segoe UI", 11)
        self.font_bold  = pygame.freetype.SysFont("Segoe UI", 13, bold=True)
        self.font_title = pygame.freetype.SysFont("Segoe UI", 16, bold=True)
        self.clock = pygame.time.Clock()

        self.button_rects = {}
        self.section_rects = {}
        self.cell_rects = {}

    # ── Job switching ────────────────────────────────────────────────

    def switch_job(self, job):
        if job == self.current_job:
            return
        if self.dirty:
            self.do_save()
        self.current_job = job
        self.path = _config_path(job)
        self.model = RoutingModel(load_config(self.path))
        self.custom_labels = _load_custom_labels(self.path)
        self.channel_hidden, self.blacklist = _load_channel_filters(self.path)
        self.blacklist_focused = False
        self.blacklist_buffer = ""
        self.editing_tab = None
        self.editing_buffer = ""
        self.dirty = False
        self.scroll = 0
        # Reset blacklist hscroll on job switch — different file, fresh view.
        self._blacklist_hscroll = 0
        self.status = f"Now editing: {self.path.name}"

    # ── Drawing ──────────────────────────────────────────────────────

    def draw_header(self):
        rect = pygame.Rect(0, 0, WINDOW_W, HEADER_H)
        pygame.draw.rect(self.screen, COLOR_HEADER, rect)
        pygame.draw.line(self.screen, COLOR_BORDER,
                         (0, HEADER_H), (WINDOW_W, HEADER_H))

        draw_text(self.screen, self.font_title,
                  "OmniWatch Chat Routing — Filter Editor",
                  (PAD * 2, 12), COLOR_TEXT_BRIGHT)

        # Right-side action buttons
        btn_w, btn_h = 70, 28
        y = 12
        x = WINDOW_W - PAD - btn_w
        save_rect = pygame.Rect(x, y, btn_w, btn_h)
        self.button_rects["save"] = save_rect
        draw_button(self.screen, self.font, "Save",
                    save_rect,
                    hovered=save_rect.collidepoint(pygame.mouse.get_pos()),
                    bg=COLOR_OK if self.dirty else COLOR_BUTTON,
                    bg_hov=COLOR_OK_HOV if self.dirty else COLOR_BUTTON_HOV)

        x -= btn_w + 6
        cancel_rect = pygame.Rect(x, y, btn_w, btn_h)
        self.button_rects["cancel"] = cancel_rect
        draw_button(self.screen, self.font, "Cancel",
                    cancel_rect,
                    hovered=cancel_rect.collidepoint(pygame.mouse.get_pos()))

        x -= btn_w + 6
        reset_rect = pygame.Rect(x, y, btn_w, btn_h)
        self.button_rects["reset"] = reset_rect
        draw_button(self.screen, self.font, "Reset",
                    reset_rect,
                    hovered=reset_rect.collidepoint(pygame.mouse.get_pos()),
                    bg=COLOR_DANGER, bg_hov=COLOR_DANGER_HOV)

        # Second row: job selector + path
        row2_y = 52
        draw_text(self.screen, self.font, "Editing:",
                  (PAD * 2, row2_y + 6))
        job_label = "GLOBAL" if self.current_job is None else self.current_job
        job_btn = pygame.Rect(PAD * 2 + 60, row2_y, 110, 26)
        self.button_rects["job"] = job_btn
        draw_button(self.screen, self.font, f"{job_label} ▼", job_btn,
                    hovered=job_btn.collidepoint(pygame.mouse.get_pos()))

        path_str = self.path.name
        draw_text(self.screen, self.font_small, path_str,
                  (job_btn.right + 10, row2_y + 8), COLOR_TEXT_DIM)

        # Third row: custom tab rename inputs. Two side-by-side editable
        # boxes show the current labels for custom_1 / custom_2. Click
        # to edit, Enter to commit, Esc to cancel. The labels persist in
        # _meta.tab_names on Save.
        row3_y = 88
        draw_text(self.screen, self.font, "Custom tabs:",
                  (PAD * 2, row3_y + 7))
        input_x = PAD * 2 + 92
        input_w = 160
        input_h = 24
        self.rename_rects.clear()
        for i, tab_id in enumerate(CUSTOM_TAB_IDS):
            r = pygame.Rect(input_x + i * (input_w + 12),
                            row3_y + 3, input_w, input_h)
            self.rename_rects[tab_id] = r
            is_editing = (self.editing_tab == tab_id)
            bg = COLOR_HOVER if is_editing else COLOR_PANEL
            pygame.draw.rect(self.screen, bg, r, border_radius=4)
            pygame.draw.rect(self.screen, COLOR_ACCENT if is_editing
                             else COLOR_BORDER, r, width=1, border_radius=4)
            shown = self.editing_buffer if is_editing else \
                self.custom_labels.get(tab_id, "")
            cursor = "_" if is_editing else ""
            draw_text(self.screen, self.font, shown + cursor,
                      (r.x + 8, r.y + 5),
                      COLOR_TEXT_BRIGHT if is_editing else COLOR_TEXT)

    def draw_footer(self):
        rect = pygame.Rect(0, WINDOW_H - FOOTER_H, WINDOW_W, FOOTER_H)
        pygame.draw.rect(self.screen, COLOR_HEADER, rect)
        pygame.draw.line(self.screen, COLOR_BORDER,
                         (0, rect.y), (WINDOW_W, rect.y))

        mouse = pygame.mouse.get_pos()

        # ── Row 1: quick channel show/hide toggles ──────────────────
        row1_y = rect.y + 6
        draw_text(self.screen, self.font_small, "Channels:",
                  (PAD * 2, row1_y + 5), COLOR_TEXT_DIM)
        px = PAD * 2 + 62
        self.quick_channel_rects.clear()
        for ch_name, ch_label in QUICK_CHANNELS:
            hidden = ch_name in self.channel_hidden
            pill_w = 56
            pill = pygame.Rect(px, row1_y, pill_w, 20)
            hov = pill.collidepoint(mouse)
            # Green when shown, dim red when hidden.
            if hidden:
                bg = (90, 45, 45) if not hov else (120, 55, 55)
                fg = (220, 150, 150)
            else:
                bg = (45, 80, 50) if not hov else (55, 105, 65)
                fg = (180, 230, 190)
            pygame.draw.rect(self.screen, bg, pill, border_radius=10)
            pygame.draw.rect(self.screen, COLOR_BORDER, pill,
                             width=1, border_radius=10)
            tw = self.font_small.get_rect(ch_label).width
            draw_text(self.screen, self.font_small, ch_label,
                      (pill.x + (pill_w - tw) // 2, pill.y + 4), fg)
            self.quick_channel_rects[ch_name] = pill
            px += pill_w + 6

        # ── Row 2: sender blacklist ─────────────────────────────────
        row2_y = rect.y + 34
        draw_text(self.screen, self.font_small, "Blacklist:",
                  (PAD * 2, row2_y + 6), COLOR_TEXT_DIM)
        # Text input box.
        inp_w = 150
        inp = pygame.Rect(PAD * 2 + 62, row2_y, inp_w, 22)
        self.blacklist_input_rect = inp
        ed = self.blacklist_focused
        pygame.draw.rect(self.screen, COLOR_HOVER if ed else COLOR_PANEL,
                         inp, border_radius=4)
        pygame.draw.rect(self.screen, COLOR_ACCENT if ed else COLOR_BORDER,
                         inp, width=1, border_radius=4)
        shown = self.blacklist_buffer if ed else ""
        placeholder = "" if (ed or self.blacklist_buffer) else "add name…"
        cursor = "_" if ed else ""
        if placeholder:
            draw_text(self.screen, self.font_small, placeholder,
                      (inp.x + 6, inp.y + 5), COLOR_TEXT_DIM)
        else:
            draw_text(self.screen, self.font_small, shown + cursor,
                      (inp.x + 6, inp.y + 5),
                      COLOR_TEXT_BRIGHT if ed else COLOR_TEXT)
        # Add button.
        add_btn = pygame.Rect(inp.right + 6, row2_y, 38, 22)
        draw_button(self.screen, self.font_small, "Add", add_btn,
                    hovered=add_btn.collidepoint(mouse),
                    bg=COLOR_OK, bg_hov=COLOR_OK_HOV)
        self.button_rects["blacklist_add"] = add_btn

        # Current blacklist as removable chips, flowing right.
        #
        # The row has a fixed visible area between the Add button and
        # the right edge of the window. Short blacklists fit without
        # any extra UI; long ones overflow off the right edge and
        # would otherwise become invisible/un-removable (the old code
        # broke on first chip that wouldn't fit — chips past that
        # point were still in the JSON but had no GUI representation,
        # making removal possible only by hand-editing the file).
        #
        # Fix: when total chip-width exceeds the visible area, reserve
        # arrow regions on each side and apply a horizontal scroll
        # offset (self._blacklist_hscroll). Mirrors the chat-tab strip
        # scroll pattern: ◀ at left, ▶ at right, disabled (dim) when
        # at the start/end. Mousewheel anywhere over the chip row also
        # scrolls. Chips outside the visible window are clipped (not
        # rendered) AND their hit-test rects are NOT recorded, so a
        # click can't accidentally remove a chip you can't see.
        self.blacklist_rects.clear()
        arrow_w = 18
        chip_area_left  = add_btn.right + 12
        chip_area_right = WINDOW_W - PAD

        # First pass: measure total content width WITHOUT rendering.
        # This tells us whether we overflow and how much hscroll is
        # meaningful (max_scroll). Walking the list twice is cheap;
        # the inner per-chip work is just a font measure.
        chip_widths = []
        total_w = 0
        for i, name in enumerate(self.blacklist):
            cw = self.font_small.get_rect(name).width + 26
            chip_widths.append(cw)
            total_w += cw
            if i < len(self.blacklist) - 1:
                total_w += 6   # gap between chips, not after last

        visible_w_no_arrows = chip_area_right - chip_area_left
        overflow = total_w > visible_w_no_arrows
        if overflow:
            # Reserve space for the two arrows on either end.
            visible_w = visible_w_no_arrows - (arrow_w * 2 + 8)
            content_x0 = chip_area_left + arrow_w + 4
            content_x1 = chip_area_right - arrow_w - 4
        else:
            visible_w = visible_w_no_arrows
            content_x0 = chip_area_left
            content_x1 = chip_area_right

        # Clamp hscroll. max_scroll is total content minus visible
        # area; if no overflow, max is 0 (forces hscroll back to 0
        # when the list shrinks below the threshold via × removal).
        max_scroll = max(0, total_w - visible_w)
        if self._blacklist_hscroll > max_scroll:
            self._blacklist_hscroll = max_scroll
        if self._blacklist_hscroll < 0:
            self._blacklist_hscroll = 0
        # Persist for the click handler (so it knows arrow step size
        # in terms of content width without having to re-measure).
        self._blacklist_content_w = total_w
        self._blacklist_visible_w = visible_w
        # Rect covering the ENTIRE chip row (arrows + chip area) so
        # the mousewheel handler can route wheel events over this
        # band to horizontal scroll instead of the global vertical
        # scroll. Set regardless of overflow — over a non-overflowing
        # row, wheel still gets routed here (and is a no-op because
        # max_scroll is 0), which is harmless and avoids surprising
        # the user with vertical scroll when their wheel happens to
        # pass over a short chip list.
        self._blacklist_row_rect = pygame.Rect(
            chip_area_left, row2_y, chip_area_right - chip_area_left, 22)

        # Render chips, clipped to the content area so partial chips
        # at the edges don't bleed into the arrows. Pygame's set_clip
        # restricts subsequent blits to the given rect.
        prev_clip = self.screen.get_clip()
        clip_rect = pygame.Rect(content_x0, row2_y - 1,
                                content_x1 - content_x0, 24)
        self.screen.set_clip(clip_rect)

        cx = content_x0 - self._blacklist_hscroll
        for i, name in enumerate(self.blacklist):
            chip_w = chip_widths[i]
            chip_right = cx + chip_w
            # Skip chips entirely outside the visible window. We still
            # advance cx so the next chip lands at the right offset.
            visible = (chip_right > content_x0) and (cx < content_x1)
            if visible:
                chip = pygame.Rect(cx, row2_y, chip_w, 22)
                pygame.draw.rect(self.screen, (70, 50, 50), chip,
                                 border_radius=4)
                pygame.draw.rect(self.screen, COLOR_BORDER, chip,
                                 width=1, border_radius=4)
                draw_text(self.screen, self.font_small, name,
                          (chip.x + 6, chip.y + 5), (230, 190, 190))
                # × remove target. Only register the hit-test rect if
                # the × is FULLY visible (not clipped) — otherwise a
                # click could land on a half-shown × and remove the
                # wrong chip from the user's point of view.
                xr = pygame.Rect(chip.right - 16, chip.y + 2, 14, 18)
                if (xr.x >= content_x0 and xr.right <= content_x1):
                    xhov = xr.collidepoint(mouse)
                    draw_text(self.screen, self.font_small, "×",
                              (xr.x + 3, xr.y + 3),
                              (255, 140, 140) if xhov else (200, 120, 120))
                    self.blacklist_rects[name] = xr
                else:
                    # Still draw the × glyph (it's inside the chip and
                    # the clip handles partial display), just don't
                    # register the hit rect.
                    draw_text(self.screen, self.font_small, "×",
                              (xr.x + 3, xr.y + 3),
                              (200, 120, 120))
            cx += chip_w + 6
        self.screen.set_clip(prev_clip)

        # ── Scroll arrows (only when overflow) ───────────────────
        # Mirrors the chat-tab-strip arrow style at OmniWatch.py
        # draw_chat_panel: triangle polygon, dim when disabled (at
        # start/end of scroll range), bright when active. The arrow
        # backgrounds match the chip area so the arrows feel like
        # part of the row rather than a separate widget.
        self._blacklist_arrow_left_rect = None
        self._blacklist_arrow_right_rect = None
        if overflow:
            arrow_mid_y = row2_y + 11
            # Left arrow — enabled only when scrolled past the start.
            l_active = self._blacklist_hscroll > 0
            l_rect = pygame.Rect(chip_area_left, row2_y, arrow_w, 22)
            pygame.draw.rect(self.screen, COLOR_PANEL, l_rect,
                             border_radius=3)
            l_col = (COLOR_TEXT_BRIGHT if l_active else (90, 95, 105))
            _ax = l_rect.centerx
            pygame.draw.polygon(self.screen, l_col, [
                (_ax + 3, arrow_mid_y - 5),
                (_ax + 3, arrow_mid_y + 5),
                (_ax - 4, arrow_mid_y)])
            # Only register the click target when the arrow is active —
            # clicking an inactive arrow should be a no-op, not consume
            # the click (matches chat-tab-strip behavior).
            if l_active:
                self._blacklist_arrow_left_rect = l_rect
            # Right arrow — enabled when more content lies past the end.
            r_active = self._blacklist_hscroll < max_scroll
            r_rect = pygame.Rect(chip_area_right - arrow_w, row2_y,
                                 arrow_w, 22)
            pygame.draw.rect(self.screen, COLOR_PANEL, r_rect,
                             border_radius=3)
            r_col = (COLOR_TEXT_BRIGHT if r_active else (90, 95, 105))
            _bx = r_rect.centerx
            pygame.draw.polygon(self.screen, r_col, [
                (_bx - 3, arrow_mid_y - 5),
                (_bx - 3, arrow_mid_y + 5),
                (_bx + 4, arrow_mid_y)])
            if r_active:
                self._blacklist_arrow_right_rect = r_rect

        # ── Row 3: status line ──────────────────────────────────────
        row3_y = rect.y + 62
        msg = self.status or (
            "Channels: click to show/hide. Blacklist: hide all messages "
            "from a sender. Reload OmniWatch to apply."
        )
        draw_text(self.screen, self.font_small, msg,
                  (PAD * 2, row3_y + 4),
                  COLOR_ACCENT if self.status else COLOR_TEXT_DIM)

    def _draw_section_header(self, label, y, key, has_overrides=False,
                              indent=0):
        rect = pygame.Rect(PAD + indent, y, WINDOW_W - PAD * 2 - indent,
                            SECTION_H if indent == 0 else SUBSECTION_H)
        hovered = rect.collidepoint(pygame.mouse.get_pos())
        pygame.draw.rect(self.screen,
                         COLOR_HOVER if hovered else COLOR_PANEL,
                         rect, border_radius=4)
        tri_x = rect.x + 8
        tri_y = rect.y + rect.height // 2
        if self.expanded.get(key):
            points = [(tri_x, tri_y - 4), (tri_x + 10, tri_y - 4),
                      (tri_x + 5, tri_y + 4)]
        else:
            points = [(tri_x, tri_y - 5), (tri_x + 8, tri_y),
                      (tri_x, tri_y + 5)]
        pygame.draw.polygon(self.screen, COLOR_TEXT_BRIGHT, points)

        draw_text(self.screen,
                  self.font_bold if indent == 0 else self.font,
                  label,
                  (tri_x + 18, rect.y + (5 if indent == 0 else 4)),
                  COLOR_TEXT_BRIGHT)

        if has_overrides:
            draw_text(self.screen, self.font_small, "(custom)",
                      (rect.right - 80, rect.y + 8),
                      COLOR_ACCENT)
        return rect

    def _draw_cell(self, actor, target, channel, ch_label, y, indent):
        if y + ROW_H < HEADER_H or y > WINDOW_H - FOOTER_H:
            self._row_index += 1
            return y + ROW_H

        # Zebra striping: alternate row background so the eye can
        # trace each channel across the gap between label and dest.
        row_bg = COLOR_ROW_ALT if (self._row_index % 2) else None
        if row_bg:
            stripe = pygame.Rect(0, y, WINDOW_W, ROW_H)
            pygame.draw.rect(self.screen, row_bg, stripe)
        self._row_index += 1

        current = self.model.get_cell(actor, target, channel)
        is_default  = (current is None)
        is_hidden   = (current is not None and len(current) == 0)
        is_override = (current is not None and len(current) > 0)

        draw_text(self.screen, self.font, ch_label,
                  (PAD + indent + 24, y + 6), COLOR_TEXT)

        cb_x = WINDOW_W - 280
        cb_rect = pygame.Rect(cb_x, y + 4, 18, 18)
        cb_hovered = cb_rect.collidepoint(pygame.mouse.get_pos())
        draw_checkbox(self.screen, cb_rect, checked=not is_hidden,
                       hovered=cb_hovered)
        draw_text(self.screen, self.font_small,
                  "Hidden" if is_hidden else "Shown",
                  (cb_x + 24, y + 7),
                  (200, 100, 100) if is_hidden else COLOR_TEXT_DIM)

        dest_x = cb_x + 90
        dest_rect = pygame.Rect(dest_x, y + 3, 130, 20)
        if is_hidden:
            pygame.draw.rect(self.screen, (40, 40, 50), dest_rect,
                             border_radius=4)
            draw_text(self.screen, self.font_small, "—",
                      (dest_rect.x + 8, dest_rect.y + 4),
                      COLOR_TEXT_DIM)
        else:
            # Map internal ids (custom_1/custom_2) to current labels
            # for display in the dest button. Built-in tab ids match
            # their display labels so the lookup is a no-op for them.
            def _label_for(tid):
                if tid in CUSTOM_TAB_IDS:
                    return self.custom_labels.get(tid, tid)
                return tid
            dest_label = "Default ▼" if is_default else (
                ",".join(_label_for(t) for t in current) + " ▼")
            hov = dest_rect.collidepoint(pygame.mouse.get_pos())
            bg = COLOR_CELL_OVR if is_override else COLOR_CELL_BG
            pygame.draw.rect(self.screen,
                             COLOR_HOVER if hov else bg,
                             dest_rect, border_radius=4)
            pygame.draw.rect(self.screen, COLOR_BORDER, dest_rect,
                             width=1, border_radius=4)
            if is_override and current[0] in TAB_CHIP_COLORS:
                chip = pygame.Rect(dest_rect.x + 4, dest_rect.y + 6, 8, 8)
                pygame.draw.rect(self.screen,
                                 TAB_CHIP_COLORS[current[0]], chip)
                lx = dest_rect.x + 16
            else:
                lx = dest_rect.x + 8
            draw_text(self.screen, self.font_small, dest_label,
                      (lx, dest_rect.y + 4),
                      COLOR_TEXT_BRIGHT)

        self.cell_rects[(actor, target, channel)] = (cb_rect, dest_rect)
        return y + ROW_H

    def draw_content(self):
        content_top = HEADER_H
        content_bot = WINDOW_H - FOOTER_H
        prev_clip = self.screen.get_clip()
        self.screen.set_clip(pygame.Rect(0, content_top, WINDOW_W,
                                          content_bot - content_top))

        y = content_top + PAD - self.scroll
        self.section_rects.clear()
        self.cell_rects.clear()
        # Zebra-stripe counter used by _draw_cell. Reset every frame.
        self._row_index = 0

        for actor, label in FLAT_ACTORS:
            has_overrides = (isinstance(self.model.data.get(actor), dict)
                             and bool(self.model.data[actor]))
            srect = self._draw_section_header(label, y, actor, has_overrides)
            self.section_rects[actor] = srect
            y += srect.height + 2
            if self.expanded.get(actor):
                for ch, ch_label in CHANNELS:
                    y = self._draw_cell(actor, None, ch, ch_label, y, INDENT)
                y += PAD // 2

        for actor, label in NESTED_ACTORS:
            has_overrides = (isinstance(self.model.data.get(actor), dict)
                             and bool(self.model.data[actor]))
            srect = self._draw_section_header(label, y, actor, has_overrides)
            self.section_rects[actor] = srect
            y += srect.height + 2
            if self.expanded.get(actor):
                for tk, tlabel in NESTED_TARGETS:
                    sub_key = f"{actor}.{tk}"
                    actor_dict = self.model.data.get(actor, {})
                    target_dict = (actor_dict.get(tk, {})
                                   if isinstance(actor_dict, dict) else {})
                    has_t_overrides = (isinstance(target_dict, dict)
                                       and bool(target_dict))
                    sub_srect = self._draw_section_header(
                        f"on {tlabel}", y, sub_key, has_t_overrides,
                        indent=INDENT)
                    self.section_rects[sub_key] = sub_srect
                    y += sub_srect.height + 2
                    if self.expanded.get(sub_key):
                        for ch, ch_label in CHANNELS:
                            y = self._draw_cell(actor, tk, ch, ch_label,
                                                 y, INDENT * 2)
                        y += PAD // 2

        self.scroll_max = max(0, y - content_bot + self.scroll + PAD)
        self.screen.set_clip(prev_clip)

    # ── Event handling ──────────────────────────────────────────────

    def _commit_rename(self):
        """Commit the currently-editing tab rename to custom_labels.

        Empty or whitespace-only input reverts to the default label
        for that tab. Marks the model dirty so the user knows there's
        a pending save. No-op when not editing.
        """
        if not self.editing_tab:
            return
        tab_id = self.editing_tab
        buf = self.editing_buffer.strip()
        defaults = {tid: default for tid, default in TABS
                    if tid in CUSTOM_TAB_IDS}
        new_label = buf if buf else defaults.get(tab_id, tab_id)
        if self.custom_labels.get(tab_id) != new_label:
            self.custom_labels[tab_id] = new_label
            self.dirty = True
        self.editing_tab = None
        self.editing_buffer = ""

    def _commit_blacklist_add(self):
        """Add the typed name to the blacklist. No-op on empty or
        duplicate (case-insensitive). Keeps focus + clears buffer so
        several names can be added in a row."""
        name = self.blacklist_buffer.strip()
        self.blacklist_buffer = ""
        if not name:
            return
        existing = {n.lower() for n in self.blacklist}
        if name.lower() not in existing:
            self.blacklist.append(name)
            self.dirty = True
        self.blacklist_focused = True

    def handle_click(self, pos, button):
        if self.dropdown.active:
            self.dropdown.handle_click(pos)
            return

        # Rename-input click: enter edit mode for the clicked input.
        # Other clicks should commit any in-progress edit first.
        for tab_id, r in self.rename_rects.items():
            if r.collidepoint(pos):
                if self.editing_tab and self.editing_tab != tab_id:
                    self._commit_rename()
                self.editing_tab = tab_id
                self.editing_buffer = self.custom_labels.get(tab_id, "")
                return
        # Any other click: end edit mode first.
        if self.editing_tab:
            self._commit_rename()

        # Footer: quick channel toggles.
        for ch_name, pill in self.quick_channel_rects.items():
            if pill.collidepoint(pos):
                if ch_name in self.channel_hidden:
                    self.channel_hidden.discard(ch_name)
                else:
                    self.channel_hidden.add(ch_name)
                self.dirty = True
                self.blacklist_focused = False
                return

        # Footer: blacklist input focus.
        if self.blacklist_input_rect and \
                self.blacklist_input_rect.collidepoint(pos):
            self.blacklist_focused = True
            return

        # Footer: blacklist scroll arrows. Step size is one "chip's
        # worth" — heuristic: ~80px is roughly a 6-char name + chrome.
        # Tested fine on typical FFXI names (5-12 chars). When the
        # blacklist is short enough not to overflow, both arrow rects
        # are None, so these branches won't fire.
        _step = 80
        if self._blacklist_arrow_left_rect is not None \
                and self._blacklist_arrow_left_rect.collidepoint(pos):
            self._blacklist_hscroll = max(0, self._blacklist_hscroll - _step)
            return
        if self._blacklist_arrow_right_rect is not None \
                and self._blacklist_arrow_right_rect.collidepoint(pos):
            # Clamp against max_scroll. We have _blacklist_content_w
            # and _blacklist_visible_w cached from the last draw, so
            # the math is one line. No re-measure needed.
            _max = max(0, self._blacklist_content_w
                       - self._blacklist_visible_w)
            self._blacklist_hscroll = min(_max,
                                          self._blacklist_hscroll + _step)
            return

        # Footer: blacklist chip removal.
        for name, xr in self.blacklist_rects.items():
            if xr.collidepoint(pos):
                if name in self.blacklist:
                    self.blacklist.remove(name)
                    self.dirty = True
                self.blacklist_focused = False
                return

        # Clicking elsewhere unfocuses the blacklist input.
        if self.blacklist_focused and not (
                self.button_rects.get("blacklist_add")
                and self.button_rects["blacklist_add"].collidepoint(pos)):
            self.blacklist_focused = False

        for name, rect in self.button_rects.items():
            if rect.collidepoint(pos):
                if name == "save":
                    self.do_save()
                elif name == "cancel":
                    self.do_cancel()
                elif name == "reset":
                    self.do_reset()
                elif name == "job":
                    self.open_job_dropdown(rect)
                elif name == "blacklist_add":
                    self._commit_blacklist_add()
                return

        if pos[1] >= HEADER_H and pos[1] < WINDOW_H - FOOTER_H:
            for key, (cb_rect, dest_rect) in self.cell_rects.items():
                actor, target, channel = key
                if cb_rect.collidepoint(pos):
                    self.toggle_show(actor, target, channel)
                    return
                if dest_rect.collidepoint(pos):
                    current = self.model.get_cell(actor, target, channel)
                    if current is None or len(current) > 0:
                        self.open_dest_dropdown(dest_rect, actor, target, channel)
                    return

            for key, rect in self.section_rects.items():
                if rect.collidepoint(pos):
                    self.expanded[key] = not self.expanded.get(key, False)
                    return

    def handle_scroll(self, delta):
        if self.dropdown.active:
            return
        # Mousewheel over the blacklist chip row scrolls THAT row
        # horizontally rather than the main config view vertically.
        # This makes navigating a long blacklist feel natural without
        # having to aim for the small arrow buttons. Step size mirrors
        # the click step (80px ≈ one chip), scaled by wheel delta so
        # quick spins move faster. Wheel-up (positive delta) reveals
        # earlier names (scroll left); wheel-down reveals later names.
        # Falls through to vertical scroll when the cursor is anywhere
        # other than the chip row.
        if self._blacklist_row_rect is not None \
                and self._blacklist_row_rect.collidepoint(
                    pygame.mouse.get_pos()):
            _step = 80
            _max = max(0, self._blacklist_content_w
                       - self._blacklist_visible_w)
            self._blacklist_hscroll = max(
                0, min(_max, self._blacklist_hscroll - delta * _step))
            return
        self.scroll -= delta * SCROLL_STEP
        self.scroll = max(0, min(self.scroll,
                                  getattr(self, "scroll_max", 0)))

    def open_job_dropdown(self, trigger):
        opts = [(None, "GLOBAL (fallback for all jobs)")]
        for j in JOBS:
            has_file = _config_path(j).exists()
            label = f"{j}" + ("  (has config)" if has_file else "")
            opts.append((j, label))
        self.dropdown.open(trigger, opts, lambda v: self.switch_job(v))

    def open_dest_dropdown(self, trigger, actor, target, channel):
        opts = [(None, "Default (auto)")]
        for tab_id, default_label in TABS:
            # For custom tabs, show the user's renamed label if any.
            label = (self.custom_labels.get(tab_id)
                     if tab_id in CUSTOM_TAB_IDS
                     else default_label)
            opts.append((tab_id, label))
        opts.append(("__hide__", "Hide (do not show)"))
        def _on_select(value):
            if value is None:
                self.model.set_cell(actor, target, channel, None)
            elif value == "__hide__":
                self.model.set_cell(actor, target, channel, [])
            else:
                self.model.set_cell(actor, target, channel, [value])
            self.dirty = True
        self.dropdown.open(trigger, opts, _on_select)

    def toggle_show(self, actor, target, channel):
        current = self.model.get_cell(actor, target, channel)
        if current is None or len(current) > 0:
            self.model.set_cell(actor, target, channel, [])
        else:
            self.model.set_cell(actor, target, channel, None)
        self.dirty = True

    def do_save(self):
        try:
            save_config(self.path, dict(self.model.data),
                        custom_labels=self.custom_labels,
                        channel_hidden=self.channel_hidden,
                        blacklist=self.blacklist)
            self.dirty = False
            self.status = f"Saved {self.path.name}. Reload OmniWatch to apply."
        except Exception as e:
            self.status = f"Save failed: {e}"

    def do_cancel(self):
        self.model = RoutingModel(load_config(self.path))
        self.custom_labels = _load_custom_labels(self.path)
        self.channel_hidden, self.blacklist = _load_channel_filters(self.path)
        self.blacklist_focused = False
        self.blacklist_buffer = ""
        self.editing_tab = None
        self.editing_buffer = ""
        self.dirty = False
        # Cancel reloads from disk — chip list may have been different
        # before edits started. Reset hscroll so the user sees the
        # start of the post-revert list rather than a mid-scroll
        # position carried over from the abandoned edit session.
        self._blacklist_hscroll = 0
        self.status = "Reverted to saved config."

    def do_reset(self):
        self.model = RoutingModel({})
        # Reset custom labels too — the user is asking for a clean
        # slate, and that includes any renamed tabs.
        self.custom_labels = {tab_id: default for tab_id, default in TABS
                              if tab_id in CUSTOM_TAB_IDS}
        # Clean slate also clears channel filters + blacklist.
        self.channel_hidden = set()
        self.blacklist = []
        self.blacklist_focused = False
        self.blacklist_buffer = ""
        self.editing_tab = None
        self.editing_buffer = ""
        # Save immediately so the user is back to clean defaults in
        # one click. Without this, the user could click Reset, close
        # the window, and end up with the old config still saved on
        # disk — a confusing recovery path. Auto-saving makes Reset
        # mean "back to defaults, right now, for real".
        try:
            save_config(self.path, dict(self.model.data),
                        custom_labels=self.custom_labels,
                        channel_hidden=self.channel_hidden,
                        blacklist=self.blacklist)
            self.dirty = False
            self.status = (f"Reset {self.path.name} to defaults. "
                           f"Reload OmniWatch to apply.")
        except Exception as e:
            self.dirty = True
            self.status = f"Reset failed to save: {e}"

    # ── Main loop ────────────────────────────────────────────────────

    def run(self):
        running = True
        while running:
            for ev in pygame.event.get():
                if ev.type == pygame.QUIT:
                    running = False
                elif ev.type == pygame.MOUSEBUTTONDOWN:
                    if ev.button == 1:
                        self.handle_click(ev.pos, ev.button)
                    elif ev.button == 4:
                        self.handle_scroll(1)
                    elif ev.button == 5:
                        self.handle_scroll(-1)
                elif ev.type == pygame.MOUSEWHEEL:
                    self.handle_scroll(ev.y)
                elif ev.type == pygame.KEYDOWN:
                    if self.editing_tab is not None:
                        # Rename input is active; keys go here, not to
                        # the global handler.
                        if ev.key == pygame.K_ESCAPE:
                            # Cancel edit, discard buffer.
                            self.editing_tab = None
                            self.editing_buffer = ""
                        elif ev.key == pygame.K_RETURN \
                                or ev.key == pygame.K_KP_ENTER:
                            self._commit_rename()
                        elif ev.key == pygame.K_BACKSPACE:
                            if self.editing_buffer:
                                self.editing_buffer = self.editing_buffer[:-1]
                        else:
                            # Accept the character if it's printable
                            # ASCII. Cap label length at 20 to keep tab
                            # strips reasonable.
                            ch = ev.unicode
                            if ch and 32 <= ord(ch[0]) < 127 \
                                    and len(self.editing_buffer) < 20:
                                self.editing_buffer += ch
                    elif self.blacklist_focused:
                        # Blacklist add-input is active.
                        if ev.key == pygame.K_ESCAPE:
                            self.blacklist_focused = False
                            self.blacklist_buffer = ""
                        elif ev.key == pygame.K_RETURN \
                                or ev.key == pygame.K_KP_ENTER:
                            self._commit_blacklist_add()
                        elif ev.key == pygame.K_BACKSPACE:
                            if self.blacklist_buffer:
                                self.blacklist_buffer = \
                                    self.blacklist_buffer[:-1]
                        else:
                            # Printable ASCII; cap at 24 (FFXI names are
                            # ≤15 but leave margin).
                            ch = ev.unicode
                            if ch and 32 <= ord(ch[0]) < 127 \
                                    and len(self.blacklist_buffer) < 24:
                                self.blacklist_buffer += ch
                    elif ev.key == pygame.K_ESCAPE:
                        if self.dropdown.active:
                            self.dropdown.close()
                        else:
                            running = False

            self.screen.fill(COLOR_BG)
            self.draw_content()
            self.draw_header()
            self.draw_footer()
            if self.dropdown.active:
                self.dropdown.draw(self.screen, self.font)
            pygame.display.flip()
            self.clock.tick(60)
        pygame.quit()


def main():
    App().run()


if __name__ == "__main__":
    main()