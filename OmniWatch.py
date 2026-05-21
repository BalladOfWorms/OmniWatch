import socket
import pygame
import time
import math
import json
import os
import re
import sys
import webbrowser
import urllib.parse
import datetime
import traceback

# ---------------------------------------------------------------------------
# Crash logger
# ---------------------------------------------------------------------------
# OmniWatch reliability foundation. All socket-receive loops below already
# wrap their bodies in try/except; we just need the except branches to
# write to a structured log file instead of swallowing silently with
# `pass`. _log_crash() does that.
#
# Format per entry:
#   YYYY-MM-DD HH:MM:SS [where] message
#       traceback (indented, multiple lines)
#
# The lua side writes to the SAME log directory (logs/) under the addon
# folder, so a single tail will show errors from both halves of the app.
# ---------------------------------------------------------------------------

_LOG_DIR_CACHE = None   # resolved once on first crash, then reused

def _log_dir():
    """Return a writable directory for crash logs.

    Preferred location is %APPDATA%\\OmniWatch\\logs (or ~/.omniwatch/logs
    on non-Windows) — alongside the config files. PyInstaller-extracted
    script-dir is a temp dir that gets wiped, and program-folder paths
    often have antivirus or write-permission issues, so user-data is the
    sane default. Fallback chain in case that fails:
      1. <USER_DIR>/logs                     (preferred — %APPDATA%)
      2. logs/ next to the script itself     (handy for dev runs)
      3. logs/ under the current working dir (last-ditch)
      4. system tempdir                      (always writable)
    The first writable path is cached and used for the rest of the
    session. Errors are swallowed; the worst case is "no log file gets
    created" which matches the prior behavior.
    """
    global _LOG_DIR_CACHE
    if _LOG_DIR_CACHE is not None:
        return _LOG_DIR_CACHE

    candidates = []
    # Compute the appdata-based path inline rather than depending on
    # USER_DIR (which is defined later in the file). _log_dir() is
    # called by the session-log opener at module-import time, well
    # before USER_DIR exists — so guarding `if "USER_DIR" in globals()`
    # always missed and we fell through to less-good paths (the
    # PyInstaller temp _MEIxxxx dir, which gets wiped at exit).
    try:
        appdata = os.environ.get("APPDATA")
        if appdata:
            candidates.append(os.path.join(appdata, "OmniWatch", "logs"))
        else:
            candidates.append(os.path.join(
                os.path.expanduser("~"), ".omniwatch", "logs"))
    except Exception:
        pass
    # Also keep the legacy USER_DIR path as a fallback (no-op when the
    # appdata candidate already worked, but covers the rare case where
    # APPDATA is unset and USER_DIR resolved to something different).
    try:
        if "USER_DIR" in globals():
            candidates.append(os.path.join(USER_DIR, "logs"))
    except Exception:
        pass
    try:
        candidates.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs"))
    except Exception:
        pass
    candidates.append(os.path.join(os.getcwd(), "logs"))
    try:
        import tempfile
        candidates.append(os.path.join(tempfile.gettempdir(), "OmniWatch_logs"))
    except Exception:
        pass

    for d in candidates:
        try:
            os.makedirs(d, exist_ok=True)
            # Probe-write to confirm it's actually usable.
            probe = os.path.join(d, ".write_test")
            with open(probe, "w") as f:
                f.write("ok")
            try:
                os.remove(probe)
            except Exception:
                pass
            _LOG_DIR_CACHE = d
            return d
        except Exception:
            continue

    # Total failure — return something that won't crash callers but
    # will likely fail to open later (where we silently skip).
    _LOG_DIR_CACHE = candidates[0] if candidates else "."
    return _LOG_DIR_CACHE


def _log_crash(where, exc=None, extra=""):
    """Append a crash entry to today's crash log.

    `where`  — short tag for the failing component (e.g. 'sock_target',
               'render_loop'). Shown in [brackets] for grep-ability.
    `exc`    — optional exception object. If provided, its message and
               traceback are formatted into the entry.
    `extra`  — optional extra context string appended before the trace.

    Never raises. Best-effort I/O — if logging itself fails we silently
    skip rather than escalate. Also prints a short notice to stderr so
    interactive users see something happen.
    """
    try:
        now = datetime.datetime.now()
        fname = os.path.join(_log_dir(),
                             now.strftime("crash_%Y-%m-%d.log"))
        with open(fname, "a", encoding="utf-8") as f:
            ts  = now.strftime("%Y-%m-%d %H:%M:%S")
            msg = ""
            if exc is not None:
                msg = f"{type(exc).__name__}: {exc}"
            if extra:
                msg = f"{msg} {extra}".strip()
            f.write(f"{ts} [{where}] {msg}\n")
            if exc is not None:
                tb = "".join(traceback.format_exception(type(exc), exc,
                                                         exc.__traceback__))
                for line in tb.splitlines():
                    f.write(f"    {line}\n")
        try:
            sys.stderr.write(f"[OW][CRASH] {where}: {msg} (logged)\n")
        except Exception:
            pass
    except Exception:
        # Logging failure is non-fatal — keep running.
        pass


def _excepthook(exc_type, exc_value, exc_tb):
    """Top-level uncaught exception handler.

    Catches anything that escapes the main loop's try/except. Logs and
    re-raises so the process still exits visibly (not silently).
    """
    exc = exc_value
    if exc is None:
        try:
            exc = exc_type(*exc_value.args) if exc_value else exc_type()
        except Exception:
            pass
    try:
        _log_crash("main_uncaught", exc)
    except Exception:
        pass
    # Fall through to default handler so the user still sees the message.
    sys.__excepthook__(exc_type, exc_value, exc_tb)


sys.excepthook = _excepthook


# ── Session logging ─────────────────────────────────────────────────────────
# Redirect stdout and stderr to a per-session log file under the same
# logs/ directory the crash logger uses. Built with --noconsole so the
# user sees no terminal window — without this redirect, every print()
# silently goes to the bit bucket and `[OmniWatch] ...` diagnostic
# output is impossible to recover.
#
# Rotation: we keep the 10 most recent session_*.log files. Older ones
# are deleted at startup so the logs/ folder doesn't grow unbounded.
# Crash logs (crash_*.log) are NOT touched by rotation — they're often
# the most valuable artifact and tend to be infrequent anyway.
_SESSION_LOG_KEEP = 10

class _Tee:
    """File-like wrapper that writes to two streams. Lets us send
    output to BOTH a session log AND the original stdout (the latter
    being a no-op /dev/null in --noconsole builds, but useful in dev
    when running from python directly). flush() goes to both as well
    so a crash mid-session still has the line in the file.

    Errors writing to either stream are swallowed — a broken stream
    must NEVER crash the app, since these are diagnostic only.
    """
    __slots__ = ("a", "b")
    def __init__(self, a, b):
        self.a, self.b = a, b
    def write(self, s):
        try:
            if self.a is not None:
                self.a.write(s)
        except Exception:
            pass
        try:
            if self.b is not None:
                self.b.write(s)
        except Exception:
            pass
    def flush(self):
        for s in (self.a, self.b):
            try:
                if s is not None and hasattr(s, "flush"):
                    s.flush()
            except Exception:
                pass
    def isatty(self):
        try:
            return bool(self.a and self.a.isatty())
        except Exception:
            return False

def _open_session_log():
    """Create logs/session_YYYY-MM-DD_HH-MM-SS.log and tee stdout/stderr
    into it. Returns the open file handle (kept alive at module scope
    so it isn't garbage-collected) or None on failure. Called once at
    startup before any meaningful print() output."""
    try:
        d = _log_dir()
        os.makedirs(d, exist_ok=True)
        ts = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        path = os.path.join(d, f"session_{ts}.log")
        # `buffering=1` = line-buffered, so each line hits disk as it's
        # written. Without this, a hard crash (e.g. exit code from
        # PyInstaller bootloader) could lose the most recent prints.
        fh = open(path, "w", encoding="utf-8", errors="replace",
                  buffering=1)
        # Header line so the file is self-describing if the user mails
        # it to me without context.
        fh.write(f"OmniWatch session log — started {ts}\n")
        fh.write(f"  python: {sys.version.split()[0]}\n")
        fh.write(f"  frozen: {bool(getattr(sys, 'frozen', False))}\n")
        if getattr(sys, "frozen", False):
            fh.write(f"  exe:    {sys.executable}\n")
        fh.write("=" * 60 + "\n")
        # Tee. sys.stdout / sys.stderr might be None under --noconsole
        # on some Python versions, so the Tee handles None gracefully.
        sys.stdout = _Tee(sys.stdout, fh)
        sys.stderr = _Tee(sys.stderr, fh)
        return fh, path
    except Exception:
        # Logging is best-effort. If we can't open the file, swallow
        # silently — there's no terminal under --noconsole so we have
        # nowhere useful to report this to anyway.
        return None, None

def _rotate_session_logs(keep=_SESSION_LOG_KEEP):
    """Delete session_*.log files beyond the most recent `keep`.
    Called at startup, AFTER the new log is opened so the new file
    isn't itself a rotation candidate. Crash logs are left alone."""
    try:
        d = _log_dir()
        if not os.path.isdir(d):
            return
        sessions = []
        for name in os.listdir(d):
            if name.startswith("session_") and name.endswith(".log"):
                full = os.path.join(d, name)
                try:
                    sessions.append((os.path.getmtime(full), full))
                except OSError:
                    continue
        # Newest first; drop the head we want to keep, delete the rest.
        sessions.sort(reverse=True)
        for _, full in sessions[keep:]:
            try:
                os.remove(full)
            except OSError:
                pass
    except Exception:
        pass

# Open log + rotate. _SESSION_LOG_FILE kept at module scope so the
# file handle isn't GC'd (which would close it mid-session).
_SESSION_LOG_FILE, _SESSION_LOG_PATH = _open_session_log()
_rotate_session_logs()

if _SESSION_LOG_PATH:
    print(f"[OmniWatch] session log: {_SESSION_LOG_PATH}")

WIDTH, HEIGHT = 980, 540

# ---------------------------------------------------------------------------
# Vana'diel time calculation
# Real epoch: Jan 1 2002 00:00 JST = Unix 1009810800
# Vana'diel runs 25x faster than real time
# 8-day elemental week, 84-day moon cycle
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Vana'diel time calculation
# Ported from Ashita's canonical vanatime.lua by atom0s.
# Formula:
#   vana_seconds = (unix_time + 92514960) * 25
#   day_of_year  = floor(vana_seconds / 86400)
#   moon_phase   = (day_of_year + 26) % 84
#   moon_percent = |(42 - moon_phase)| * 100 / 42
#   weekday      = day_of_year % 8      (0 = Firesday)
# ---------------------------------------------------------------------------

VANA_OFFSET  = 92514960         # seconds, from Ashita's vanatime.lua
# Fine-tuning offset in Earth seconds. The Ashita constant above is battle-tested
# across the FFXI community, so any needed correction here is usually tiny
# (sub-minute) and compensates for things like system-clock drift, private-server
# time tweaks, or a rendering offset between when data is sampled and when
# minutes are truncated for display. Raise to make the clock run later; lower
# to make it earlier. 1 Earth second = 25 Vana seconds.
VANA_FINE_TUNE = -43
VANA_SPEED   = 25
SECS_PER_DAY = 86400

VANA_DAYS = [
    "Firesday", "Earthsday", "Watersday", "Windsday",
    "Iceday", "Lightningday", "Lightsday", "Darksday"
]

DAY_COLORS = {
    "Firesday":     (255,  90,  60),
    "Earthsday":    (210, 195,  55),
    "Watersday":    ( 70, 140, 255),
    "Windsday":     ( 70, 210,  70),
    "Iceday":       (150, 210, 255),
    "Lightningday": (200, 100, 255),
    "Lightsday":    (255, 255, 210),
    "Darksday":     (150, 130, 175),
}

# Weather id → (display name, element-key, is_double_intensity).
# IDs match windower's res.weathers. 0..3 are non-elemental ambient
# weathers; 4..19 are pairs of (single, double) for the eight elements
# in the order Fire, Earth, Water, Wind, Ice, Lightning, Light, Dark.
# See https://www.bg-wiki.com/ffxi/Weather for elemental impact details.
WEATHER_TABLE = {
    0:  ("None",          None,         False),
    1:  ("Sunshine",      None,         False),
    2:  ("Clouds",        None,         False),
    3:  ("Fog",           None,         False),
    4:  ("Hot Spell",     "Fire",       False),
    5:  ("Heat Wave",     "Fire",       True),
    6:  ("Rain",          "Water",      False),
    7:  ("Squall",        "Water",      True),
    8:  ("Dust Storm",    "Earth",      False),
    9:  ("Sand Storm",    "Earth",      True),
    10: ("Wind",          "Wind",       False),
    11: ("Gales",         "Wind",       True),
    12: ("Snow",          "Ice",        False),
    13: ("Blizzards",     "Ice",        True),
    14: ("Thunder",       "Lightning",  False),
    15: ("Thunderstorms", "Lightning",  True),
    16: ("Auroras",       "Light",      False),
    17: ("Stellar Glare", "Light",      True),
    18: ("Gloom",         "Dark",       False),
    19: ("Darkness",      "Dark",       True),
}

# Element → base (R,G,B). Single intensity uses the base; double intensity
# brightens. Reuses the existing DAY_COLORS palette so weather and day
# look like the same family of accents.
WEATHER_ELEMENT_COLORS = {
    "Fire":      (255,  90,  60),
    "Earth":     (210, 195,  55),
    "Water":     ( 70, 140, 255),
    "Wind":      ( 70, 210,  70),
    "Ice":       (150, 210, 255),
    "Lightning": (200, 100, 255),
    "Light":     (255, 255, 210),
    "Dark":      (150, 130, 175),
}

def weather_display(weather_id):
    """Return (name, color) to render for a weather id, or (None, None)
    when nothing should be drawn (id=0/None or unknown).

    For elemental weathers, single-intensity uses the element's base
    color and double-intensity uses a brightened variant so the user
    can distinguish e.g. Hot Spell from Heat Wave at a glance."""
    entry = WEATHER_TABLE.get(weather_id)
    if not entry:
        return None, None
    name, element, is_double = entry
    if name == "None":
        return None, None
    if element is None:
        # Ambient, non-elemental: render in dim label color.
        return name, (180, 180, 195)
    base = WEATHER_ELEMENT_COLORS.get(element, (220, 220, 220))
    if is_double:
        # Brighten by lerping 40% toward white for the "intense" version.
        r, g, b = base
        base = (min(255, r + (255 - r) * 4 // 10),
                min(255, g + (255 - g) * 4 // 10),
                min(255, b + (255 - b) * 4 // 10))
    return name, base

def _moon_phase_name(moon_phase_day, moon_percent):
    """Map the raw cycle day (0-83) + percent to the English phase name.

    Waxing/waning direction is calibrated to the in-game /clock display:
    at 52% during "Last Quarter", moon_phase_day happens to be in 0..41,
    so we call that band the waning half and invert from the literal
    Ashita formula convention.
    """
    waning = moon_phase_day < 42
    p = moon_percent
    if p >= 93:
        return "Full Moon"
    if p <= 5:
        return "New Moon"
    if 43 <= p <= 57:
        return "Last Quarter"  if waning else "First Quarter"
    if p > 57:
        return "Waning Gibbous"  if waning else "Waxing Gibbous"
    # p < 43
    return "Waning Crescent" if waning else "Waxing Crescent"

def get_vana_time():
    """Return (hours, minutes, day_name, moon_pct, moon_phase_name).

    User offset (vana_time_offset_min, in Vana minutes) is added at the
    end so it can correct any per-machine drift without affecting the
    base epoch math. Reading the setting here keeps the function in
    sync with whatever the user has dialed in — no extra plumbing
    needed elsewhere.
    """
    now_sec          = time.time()
    vana_sec         = (now_sec + VANA_OFFSET + VANA_FINE_TUNE) * VANA_SPEED
    # User adjustment in Vana minutes → Vana seconds. Read via the
    # `setting()` helper which falls back to schema default if the
    # value isn't loaded yet (early-frame startup) or if the key is
    # missing entirely (older settings.json).
    try:
        user_offset_min = int(setting("vana_time_offset_min") or 0)
    except Exception:
        user_offset_min = 0
    vana_sec += user_offset_min * 60
    day_of_year      = int(vana_sec // SECS_PER_DAY)
    secs_in_day      = vana_sec - day_of_year * SECS_PER_DAY
    hours            = int(secs_in_day // 3600)
    minutes          = int((secs_in_day % 3600) // 60)
    day_name         = VANA_DAYS[day_of_year % 8]
    moon_phase_day   = (day_of_year + 26) % 84
    moon_percent_raw = abs(42 - moon_phase_day) * 100.0 / 42.0
    moon_pct         = int(round(moon_percent_raw))
    moon_phase       = _moon_phase_name(moon_phase_day, moon_pct)
    return hours, minutes, day_name, moon_pct, moon_phase


pygame.init()

# Set the window icon BEFORE set_mode(). Pygame on Windows will only
# pick up the title-bar icon if it's installed before the window is
# created — calling set_icon afterward updates the taskbar icon but
# NOT the corner icon on the window itself.
#
# Pygame is also picky about icon size: it wants a small surface
# (16, 24, or 32 pixels). A large source like our 1024×1024 logo
# silently fails on some pygame builds. We explicitly downscale to
# 32×32 with smoothscale so we know the input is valid.
#
# Path resolution: the icon PNG lives next to the .exe in icons/ui/.
# Relative paths can fail if the .exe was launched from a different
# CWD (shortcut, bat file). Resolve against the actual exe location
# (sys.executable when frozen, __file__ otherwise) so this works
# regardless of how the .exe got launched.
try:
    if getattr(sys, "frozen", False):
        _self_dir_for_icon = os.path.dirname(os.path.abspath(sys.executable))
    else:
        _self_dir_for_icon = os.path.dirname(os.path.abspath(__file__))
    # Search the .exe's folder AND its parent. PyInstaller dumps the
    # .exe into <addon>\dist\, while icons/ lives at <addon>\icons\.
    # Walking up one level handles that "dist subfolder" case without
    # requiring users to move the .exe by hand. Two levels up covers
    # the unlikely <addon>\build\dist\ scenario as well.
    _icon_search_dirs = [_self_dir_for_icon,
                         os.path.dirname(_self_dir_for_icon),
                         os.path.dirname(os.path.dirname(_self_dir_for_icon))]
    _icon_loaded = False
    for _base in _icon_search_dirs:
        if not _base or not os.path.isdir(_base):
            continue
        for _rel in ("icons/ui/OmniWatch.png",
                     "icons/ui/Omniwatch.png",
                     "icon.png"):
            _icon_path = os.path.join(_base, _rel)
            if os.path.exists(_icon_path):
                try:
                    icon = pygame.image.load(_icon_path).convert_alpha()
                except pygame.error:
                    icon = pygame.image.load(_icon_path)
                try:
                    icon = pygame.transform.smoothscale(icon, (32, 32))
                except Exception:
                    pass
                pygame.display.set_icon(icon)
                print(f"[OmniWatch] Set window icon from: {_icon_path}")
                _icon_loaded = True
                break
        if _icon_loaded:
            break
    if not _icon_loaded:
        print(f"[OmniWatch] No window-icon PNG found near "
              f"{_self_dir_for_icon} or its parents")
except Exception as e:
    print(f"[OmniWatch] window icon load failed: {e!r}")

screen = pygame.display.set_mode((WIDTH, HEIGHT), pygame.RESIZABLE)
pygame.display.set_caption("OmniWatch")

# Note: the previous build minimized the console window after launch
# via GetConsoleWindow + ShowWindow. With --noconsole builds there
# is no console window to minimize — print() output goes to the
# session log file instead (see _open_session_log above). For dev
# runs with `python OmniWatch.py`, the terminal stays as-is.

font_small  = pygame.font.SysFont("Consolas", 13)
font_name   = pygame.font.SysFont("Consolas", 16, bold=True)
font_label  = pygame.font.SysFont("Consolas", 12)
font_clock  = pygame.font.SysFont("Consolas", 15, bold=True)
font_day    = pygame.font.SysFont("Consolas", 13, bold=True)
font_moon   = pygame.font.SysFont("Consolas", 12)

def _bind_udp(port, label):
    """Bind a non-blocking UDP socket on 127.0.0.1:port. On collision
    (another process holds the port — common when two OmniWatch
    overlays accidentally run side-by-side, or some unrelated tool
    grabbed it) we print a clear error and re-raise so the user sees
    the cause in the console instead of a bare OSError stack."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("127.0.0.1", port))
    except OSError as e:
        print(f"[OmniWatch] FATAL: could not bind UDP port {port} "
              f"({label}): {e}")
        print(f"[OmniWatch] Another process is already using this "
              f"port. The most common cause is a second OmniWatch "
              f"overlay still running. Close it via Task Manager and "
              f"relaunch.")
        raise
    s.setblocking(False)
    return s

sock            = _bind_udp(5000, "party")
sock_equip      = _bind_udp(5001, "equipment")
sock_equip_rich = _bind_udp(5007, "equipment metadata")
sock_stats      = _bind_udp(5008, "stats")

# player_stats[stat_key_lowercase] = int/float value
player_stats = {}
# Self-identification: populated by the lua stats sender's PLAYER header.
player_self_name  = ""
player_self_mjob  = ""
player_self_sjob  = ""

# equip_rich[slot_idx] = {"item_id", "name", "ilvl", "jobs", "category",
#                         "level", "augments": [str]}
equip_rich = {}

# Ammo / other slot stack counts. slot_idx -> count. Only the ammo slot
# (pos 2) is populated currently, but the structure allows extension.
equip_counts = {}

sock_target = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock_target.bind(("127.0.0.1", 5002))
sock_target.setblocking(False)

sock_zone = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock_zone.bind(("127.0.0.1", 5003))
sock_zone.setblocking(False)

# Mob status (buffs/debuffs) events from lua addon. See the lua side for the
# line-based ASCII protocol.
sock_status = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock_status.bind(("127.0.0.1", 5004))
sock_status.setblocking(False)

# mob_statuses[mob_id] = { effect_id: {spell_id, spell_name, applied_at,
#                                       duration, actor_id, is_buff} }
# applied_at is time.time() at receipt.
mob_statuses = {}

# GearSwap state updates from the lua side. Simple text per packet:
#   SET|<literal set path>
#   STATE|<state string fallback>
# Most recent wins.
sock_gs = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock_gs.bind(("127.0.0.1", 5005))
sock_gs.setblocking(False)

# Currently displayed gearswap label (string). Empty = show "Equipment".
# Two channels feed in:
#   SET   -- the literal set/file path gearswap selected (e.g. "Engaged.DW.MaxHaste")
#   STATE -- a fallback "<state>.<mode>.<weapon>" string for older configs
# We track them separately. The renderer prefers SET when both are present
# (SET is the authoritative "gear actually equipped" name, STATE is metadata
# that re-evaluates on events that don't swap any gear -- e.g. aftermath
# gain/loss -- and would otherwise cause the header to flicker between the
# real set and a stale fallback). gearswap_label remains for backward compat
# with any code that reads it; it's set to whichever channel populated last,
# but the renderer ignores it in favour of gearswap_set/gearswap_state.
gearswap_label = ""    # legacy combined view (kept; not read by renderer)
gearswap_set   = ""    # from SET packets (authoritative when present)
gearswap_state = ""    # from STATE packets (fallback only)

# ── Simulation mode state ───────────────────────────────────────────────────
# When sim mode is on, the lua compute reads from sim values instead of
# the real game. The python side owns the UI: a floating window with
# dropdowns/inputs that pushes each change to lua over UDP. State here
# is purely UI — the authoritative state lives in lua.
#
# Window layout:
#   - sim_window_pos: (x, y) where the window sits on screen. Drag to move.
#   - sim_window_open: True while the window is rendered. Tied to the
#     sim_mode setting — flipping the setting on opens, off closes.
#   - sim_state: mirrors what we've sent to lua. Used to render current
#     values in the UI, NOT consulted by stats (lua is the source of truth).
#
# All stats default to 0/empty when sim mode toggles on (per user spec —
# "starts blank, you fill it in"). User picks job/sub from dropdowns,
# enters merit counts and JP, toggles gifts.
sim_window_pos       = [120, 120]    # mutable list so drag updates in place
sim_window_size      = [280, 0]      # [w, h]; h=0 means "auto fit content"
sim_window_open      = False
sim_window_drag      = None          # (mouse_offset_x, mouse_offset_y) while dragging
sim_window_resize    = None          # (start_w, start_h, start_mx, start_my) while resizing
sim_window_scroll    = 0             # vertical content scroll when h < natural
sim_state = {
    # Legacy fields (main_job/sub_job/merits/jp_spent/gifts) are kept in
    # Sim job/sub/JP/merits/master_level: drive the synthetic compute
    # path. When sim is on, base stats and trait bonuses are derived
    # from these values rather than the live player. (Compute integration
    # ships in a later phase; for now these store user input but lua's
    # compute path doesn't yet consume them — gear/food/buffs do work.)
    "main_job": "",
    "sub_job":  "",
    "merits":   {},
    "jp_spent": 0,
    "master_level": 0,
    "gifts":    {},
    "buffs":    {},
    "active_buffs": [],
    # Gear-slot overrides. Maps slot key (from SIM_GEAR_SLOTS) to
    # item_id. 0 means "explicitly empty" (the slot is unequipped during
    # sim). Absent slot means "use real-game gear for this slot".
    "equipment": {},
    # Simulated food. None = no food active. Otherwise an integer
    # food id from SIM_FOOD_LIST.
    "food":      None,
}
# Buff picker UI state. None = closed (showing Add button).
# {"stage": "job"} = pick a job. {"stage": "buff", "job": "BRD"} = pick a buff.
sim_buff_picker = None
# Tracks which dropdowns/inputs are "open" for editing in the floating window.
# Only one can be open at a time. Format: {"kind": "main_job"} or
# {"kind": "merit", "name": "dual_wield"}.
sim_active_field = None
# Augment-nickname editor modal state. None when not editing; otherwise
# a dict {id, fp, text, cursor_blink}. Set by right-clicking an item in
# an equipment dropdown. The text input replaces a portion of the sim
# window with a small inline editor; Enter saves, Esc cancels.
sim_nickname_editor = None
# Job rosters. Used to populate the main/sub dropdowns. Pure data.
SIM_JOB_LIST = [
    "WAR", "MNK", "WHM", "BLM", "RDM", "THF", "PLD", "DRK",
    "BST", "BRD", "RNG", "SAM", "NIN", "DRG", "SMN", "BLU",
    "COR", "PUP", "DNC", "SCH", "GEO", "RUN",
]
# Per-job merit list, prototype scope. Only haste/DW-relevant merits
# matter for the test scenarios we're starting with. Keys must match
# what windower.ffxi.get_player().merits uses (lowercase, underscore).
# Each entry: (display_label, internal_key, max_count).
# Max count is the merit cap — most are 5 but some are 8 or 10.
SIM_MERITS_BY_JOB = {
    "NIN": [
        ("Subtle Blow Effect", "subtle_blow_effect", 5),
        ("Dual Wield",         "dual_wield",         5),
        ("Tonbo-Giri",         "tonbo-giri",         5),
        ("Innin Effect",       "innin_effect",       5),
        ("Yonin Effect",       "yonin_effect",       5),
    ],
    "DNC": [
        ("Saber Dance",        "saber_dance",        5),
        ("Fan Dance",          "fan_dance",          5),
        ("No Foot Rise",       "no_foot_rise",       5),
        ("Closed Position",    "closed_position",    5),
        ("Steps & Flourishes", "steps_flourishes",   5),
    ],
    "WAR": [
        ("Berserk Recast",     "berserk_recast",     5),
        ("Defender Recast",    "defender_recast",    5),
        ("Aggressor Recast",   "aggressor_recast",   5),
        ("Warcry Recast",      "warcry_recast",      5),
        ("Tomahawk Recast",    "tomahawk_recast",    5),
    ],
    "BRD": [
        ("Lullaby Duration",   "lullaby_duration",   5),
        ("Minne Effect",       "minne_effect",       5),
        ("Minuet Effect",      "minuet_effect",      5),
        ("Madrigal Effect",    "madrigal_effect",    5),
        ("Nightingale Recast", "nightingale_recast", 5),
    ],
    # Add other jobs as needed during testing. Empty list for unlisted
    # jobs is fine — the merits panel just shows nothing for them.
}
# Job-points category list per job. Same scope reasoning. Each is just
# a single "JP spent" number for now (1 → 2100). Per-category JP would
# be a future enhancement; for prototype we store one total.
SIM_JP_MAX = 2100
# Master Level cap (per-job). +1 to all 7 base stats per ML, +1 to native
# combat/magic skill caps per ML, and sub-job effective level cap rises
# by 1 every 5 ML. Source: BG-wiki Master_Levels.
SIM_ML_MAX = 50

# Buff catalog. Mirrors OmniWatch_Sim.lua's BUFF_DATA — must stay in sync
# when buffs are added on either side. Python uses this only to populate
# the picker dropdown; the actual compute lives in lua. The 'id' string
# is what flows over UDP via SIM|buff_add|<id>, so the lua side resolves
# definitions by id and python just needs the label.
SIM_BUFF_CATALOG = [
    # (id, category, display name, kind, plus_max)
    # The "category" is what the picker dropdown shows as the top-level
    # group name. It used to be the source job (BRD/COR/GEO) but we now
    # name it for the buff TYPE (Songs/Rolls/Geomancy/Spells) since
    # that's how players think about them and it lets us add a mixed
    # "Spells" bucket without needing a job to bind it to.
    # plus_max is the upper bound for the "Plus" +/- picker. Defaults
    # to 8 (BRD song-tier cap) if omitted; GEO Indi-* spells use 10
    # to leave room for Idris-class Geomancy+ values.
    # Songs are listed in the order BRDs typically prioritize: marches
    # first (haste matters most for DD), then minuets, then madrigals.
    # Marches in named-strength order (Honor > Victory > Advancing).
    # Minuets in tier order (I → V). Keep this list in sync with
    # BUFF_DATA in OmniWatch_Sim.lua — the lua side is authoritative
    # for potency math, but the python side controls which buffs
    # appear in the picker UI.
    ("honor_march",     "Songs",    "Honor March",     "song",  8),
    ("victory_march",   "Songs",    "Victory March",   "song",  8),
    ("advancing_march", "Songs",    "Advancing March", "song",  8),
    ("minuet_i",        "Songs",    "Minuet I",        "song",  8),
    ("minuet_ii",       "Songs",    "Minuet II",       "song",  8),
    ("minuet_iii",      "Songs",    "Minuet III",      "song",  8),
    ("minuet_iv",       "Songs",    "Minuet IV",       "song",  8),
    ("minuet_v",        "Songs",    "Minuet V",        "song",  8),
    ("valor_madrigal",  "Songs",    "Valor Madrigal",  "song",  8),
    ("blade_madrigal",  "Songs",    "Blade Madrigal",  "song",  8),
    ("chaos_roll",      "Rolls",    "Chaos Roll",      "roll", 11),
    ("sam_roll",        "Rolls",    "Samurai Roll",    "roll", 11),
    ("tactician_roll",  "Rolls",    "Tactician's Roll","roll", 11),
    ("indi_fury",       "Geomancy", "Indi-Fury",       "song", 10),
    ("indi_haste",      "Geomancy", "Indi-Haste",      "song", 10),
    # Spells: flat values, no plus/level/optimal toggles. The 'spell'
    # kind renders as a single name+remove row in the sim UI; potency
    # is fixed (no math needed beyond the catalog base value).
    ("spell_haste",     "Spells",   "Haste",           "spell", 0),
    ("spell_haste2",    "Spells",   "Haste II",        "spell", 0),
    ("spell_flurry",    "Spells",   "Flurry",          "spell", 0),
    ("spell_flurry2",   "Spells",   "Flurry II",       "spell", 0),
]
# Index by category for the two-stage picker. Tuples come back as
# (id, name, kind, plus_max) — same shape as the catalog minus the
# category. The variable is still named SIM_BUFF_BY_JOB for backwards
# compat with existing references in the codebase; the key is now a
# category name (Songs/Rolls/Geomancy/Spells), not a job code.
SIM_BUFF_BY_JOB = {}
for _entry in SIM_BUFF_CATALOG:
    _bid, _bcat, _bname, _bkind = _entry[:4]
    _bplus_max = _entry[4] if len(_entry) > 4 else 8
    SIM_BUFF_BY_JOB.setdefault(_bcat, []).append((_bid, _bname, _bkind, _bplus_max))
# Category list in the order they appear in SIM_BUFF_CATALOG (preserve
# the natural Songs → Rolls → Geomancy → Spells flow rather than
# alphabetizing, which would put Geomancy first).
SIM_BUFF_JOB_LIST = []
for _entry in SIM_BUFF_CATALOG:
    _cat = _entry[1]
    if _cat not in SIM_BUFF_JOB_LIST:
        SIM_BUFF_JOB_LIST.append(_cat)

# ── Sim equipment & food ────────────────────────────────────────────────────
# 16 gear slots in canonical equipment-panel order (matching the order
# windower returns from get_items().equipment and what GearSwap exports
# expect in `sets.X = { ... }` blocks). Display labels are short to fit
# in the sim window.
SIM_GEAR_SLOTS = [
    ("main",       "Main"),
    ("sub",        "Sub"),
    ("range",      "Range"),
    ("ammo",       "Ammo"),
    ("head",       "Head"),
    ("neck",       "Neck"),
    ("left_ear",   "L.Ear"),
    ("right_ear",  "R.Ear"),
    ("body",       "Body"),
    ("hands",      "Hands"),
    ("left_ring",  "L.Ring"),
    ("right_ring", "R.Ring"),
    ("back",       "Back"),
    ("waist",      "Waist"),
    ("legs",       "Legs"),
    ("feet",       "Feet"),
]

# Curated common-food list. Each entry: (id, display_name, stats_dict).
# Stats are flat additions to the OmniWatch stats table (canonical keys
# matching what the panel reads). For percentage-of-base attributes
# (e.g. attack +N% capped at +M flat), we use the cap flat values since
# we'd need the live attack value to apply the percent — close enough
# for sim purposes; extend later if needed for edge cases.
#
# Sources: BG-wiki food pages, cross-referenced with FFXIAH descriptions.
# Added the most common high-end melee/caster foods. Add more here as
# needed; format makes it data-only.
SIM_FOOD_LIST = [
    # id     display                              stats (canonical keys)
    (5736,   "Grape Daifuku",                     {"accuracy": 50, "attack": 50,
                                                    "magic accuracy": 35, "magic attack bonus": 35}),
    (5734,   "Pear Crepe",                        {"accuracy": 60, "attack": 60,
                                                    "magic accuracy": 40, "magic attack bonus": 40}),
    (5733,   "Marine Stewpot",                    {"accuracy": 60, "attack": 60}),
    (4359,   "Sublime Sushi",                     {"accuracy": 75, "ranged accuracy": 75,
                                                    "attack": 50, "ranged attack": 50}),
    (4360,   "Sublime Sushi +1",                  {"accuracy": 80, "ranged accuracy": 80,
                                                    "attack": 55, "ranged attack": 55}),
    (5735,   "Sole Sushi",                        {"accuracy": 90, "ranged accuracy": 90,
                                                    "attack": 30, "ranged attack": 30}),
    (5739,   "Sole Sushi +1",                     {"accuracy": 95, "ranged accuracy": 95,
                                                    "attack": 35, "ranged attack": 35}),
    (5746,   "Akamochi",                          {"accuracy": 90, "attack": 50,
                                                    "magic accuracy": 60}),
    (5660,   "Soy Ramen",                         {"accuracy": 70, "attack": 70,
                                                    "magic accuracy": 50, "magic attack bonus": 50}),
    (5754,   "Tropical Crepe",                    {"magic attack bonus": 80, "magic accuracy": 60,
                                                    "magic damage": 40}),
    (5305,   "Red Curry Bun",                     {"attack": 75, "accuracy": 50}),
    (5306,   "Yellow Curry Bun",                  {"magic attack bonus": 75, "magic accuracy": 50}),
]

# Sim equipment dropdown options accessor. Returns list of
# (item_id, display_name) tuples for items currently in the player's
# inventory bags that the current main job can equip in `slot`. The
# data source is _inv_for_sim (mirrors latest snapshot from lua) plus
# the running player's job. Empty list when sim hasn't received an
# inventory snapshot yet.
def _sim_get_slot_options(slot):
    """Return a list of entry dicts valid for `slot` given the current
    player's main job and inventory contents. Each dict has:
      id, bag, idx, tag, name
    Multiple instances of the same item id are kept (so e.g. two
    Camulus's Mantles with different augments both appear). The list
    is sorted by display name. Empty list when no inventory snapshot
    has arrived yet.
    """
    out = []
    items_by_slot = _inv_for_sim.get("by_slot", {})
    candidates = items_by_slot.get(slot, [])
    cur_job = _inv_for_sim.get("main_job", "")
    for entry in candidates:
        if not isinstance(entry, dict):
            continue
        iid = entry.get("id")
        if not iid:
            continue
        # Optional job filter (lua already filters server-side, but
        # double-check here for older-format entries).
        ent_jobs = entry.get("jobs")
        if cur_job and ent_jobs and isinstance(ent_jobs, list):
            if cur_job not in ent_jobs:
                continue
        out.append(entry)
    # Sort by display name (which includes the augment tag, so two
    # capes with same base name sort by their tag suffix).
    out.sort(key=lambda e: _display_name_for_item(e).lower())
    return out

# In-memory mirror of inventory data the lua side pushes for sim use.
# Populated by SIM_INV|... messages on the inventory socket (port 5012).
# Structure:
#   _inv_for_sim = {
#       "main_job": "NIN",
#       "by_slot":  { "main": [{id, name, jobs:[...]}, ...], ... },
#   }
_inv_for_sim = {"main_job": "", "by_slot": {}, "equipped": {}, "fingerprints": {}}
# Staging buffer used while a SIM_INV snapshot is being assembled.
# Atomically swapped into _inv_for_sim when SIM_INV|END arrives so the
# dropdown UI never reads a half-built snapshot.
_sim_inv_buffer = {"main_job": "", "by_slot": {}, "equipped": {}, "fingerprints": {}}

gearswap_gil   = -1      # -1 = never received; >= 0 = real value

# Setup mode: when True, all panels render with mock data + drag handles
# regardless of in-game state. Toggled via //ow setup. See draw_setup_*
# helpers and the main render loop's setup-mode injection block.
setup_mode = False

# Mob ids whose mob_statuses entries we mock-populated during the current
# setup_mode session. Used by the setup-off cleanup to clear those mock
# statuses so they don't persist on the target card after exiting setup
# (real mobs don't send REMOVE| events for buffs/debuffs they never had).
# Cleared on setup_mode -> False transition.
_setup_mocked_statuses = set()

# Panel lock: when True, panels can't be dragged or resized — useful so
# accidental clicks don't shift things you've already positioned. Setup
# mode implicitly unlocks (you're explicitly positioning). Toggled via
# //ow lock. Default: locked, since "I keep nudging panels by accident"
# was the original complaint.
panels_locked = True

# ── Config wizard (CFGWIZ) state ────────────────────────────────────────────
# Modal overlay opened by //ow setup. Lua sends CFGWIZ|open|<flat-fields>
# with the current ow_user_config state; we render a panel with +/- buttons,
# user clicks Save and we send CFGWIZ|save|<flat-fields> back; Lua writes
# user_config.lua. Cancel / Skip also close the modal.
#
# Phase 1 scope: self-bard 12 family fields + self-cor phantom_roll. Ally
# entries are configured via the chat command (//ow config <name> <fam> <n>)
# since they require name typing which doesn't fit the +/- only design.
#
# State shape:
#   cfgwiz_visible = bool
#   cfgwiz_state = {
#       'bards.self.all_songs': int, ..., 'bards.self.scherzo': int,
#       'corsairs.self.phantom_roll': int,
#       'player.unity_rank': int,    # 1..11; 1 = highest Unity rank
#       # ally entries kept verbatim from open payload, passed through to
#       # save without modification (so chat-edited ally entries survive
#       # the wizard round-trip).
#   }
cfgwiz_visible = False
cfgwiz_state = {}

# Inline "Add Ally" dropdown. Rendered below the existing fields when
# the user clicks "+ Add Ally". Collects name + kind, then commits
# into cfgwiz_state and collapses. Modal layout reserves room for it
# when open.
cfgwiz_dropdown_open = False    # is the dropdown expanded?
cfgwiz_input_buffer  = ""       # current text in the name field
cfgwiz_input_kind    = "bard"   # 'bard' or 'cor' — selected radio

# Family keys for the bard self-row, in display order. Two rows of 6 each.
CFGWIZ_BARD_FAMILIES_ROW1 = [
    "all_songs", "minuet", "march", "madrigal", "paeon", "ballad",
]
CFGWIZ_BARD_FAMILIES_ROW2 = [
    "minne", "mambo", "prelude", "carol", "etude", "scherzo",
]

# Field keys for the geomancer self-row. Five fields, single row.
#   indi      — Indi-spell potency boost gear (Idris, Bagua Pants +3, etc.)
#   geo       — Geo-spell (Luopan) potency boost gear
#   bolster   — Bolster strength bonus gear
#   handbell  — Handbell skill bonus above 900 (scales the "900 skill" base)
#   all       — generic "+all geomancy" bucket (rare; covers gear that
#               boosts indi and geo together)
CFGWIZ_GEO_FAMILIES = [
    "indi", "geo", "bolster", "handbell", "all",
]

# Modal dimensions and layout. Tunable; centered on the pygame window.
CFGWIZ_MODAL_W = 740
CFGWIZ_MODAL_H = 700   # +60 for Unity Rank, +80 for Geomancers section
# Tracked rects for hit-testing. Populated in draw_cfgwiz, consumed in
# the click handler. Each entry is (rect, action, *extra) where action
# is one of: "inc"/"dec" with extra=field_key, or "save"/"skip"/"cancel".
cfgwiz_hit_rects = []

# Mob cast/ability events.
# mob_cast_state[mob_id] = {
#     "casting":   {"name": str, "kind": "spell"|"ability", "started": float} | None,
#     "last_cast": {"name": str, "kind": "spell"|"ability", "done_at": float} | None,
# }
sock_cast = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock_cast.bind(("127.0.0.1", 5006))
sock_cast.setblocking(False)

# ── Timer stream (port 5009) ─────────────────────────────────────────────
# Recast countdowns + self-buff durations from the lua side. Recasts are
# polled at 4Hz and arrive as RECAST_BATCH packets listing all currently-
# cooling-down spells and abilities. We store them in recast_state and
# render in a horizontal panel.
sock_timers = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock_timers.bind(("127.0.0.1", 5009))
sock_timers.setblocking(False)

# recast_state: { (kind, id): {"name": str, "secs": float, "updated_at": float} }
# Cleared per-batch on each RECAST_BATCH packet, replaced wholesale.
recast_state = {}

# Sort order for the recast panel display. Driven by OW_RECAST_CONFIG
# in the lua addon; lua sends the current value in each RECAST_BATCH
# header so python applies the same ordering the user configured.
# Values: 'asc' (closest-to-ready leftmost, default), 'desc' (longest-
# wait leftmost), 'cast' (most-recently-cast leftmost).
recast_sort_order = "asc"

# buff_state: { key: {"buff_id": int, "name": str, "secs": float,
#                     "source": str, "updated_at": float, "slot": int?} }
# Mirrors recast_state for the buff timer panel. Source is one of
# 'self', 'other', 'food', 'song', 'roll', 'song_other', 'roll_other'.
# Replaced wholesale on each BUFF_BATCH packet from lua. Names with a
# leading '~' indicate buffs cast by other players (we don't know their
# gear so the duration is approximate).
#
# Key is the slot index (0..31) when lua sends v2 wire format (slot-aware,
# enables March x2 / Minuet x2 stacking). Falls back to buff_id keying when
# lua sends v1 (legacy single-bid). The renderer doesn't care which keying
# is in use; it iterates values and uses 'buff_id' / 'name' / 'secs' fields.
buff_state = {}
buff_sort_order = "asc"

# ── DPS panel (port 5010) ─────────────────────────────────────────────────
# Rolling 5-min combat metrics from the lua addon. Each batch is a
# multi-line packet:
#   DPS|<src>|<scope>|<window>|<white>|<magic>|<ws>|<hits>|<misses>|<crits>|
#       <spells_landed>|<spells_resisted>|<melee_acc>|<mag_acc>|<crit_pct>|
#       <evasion>|<longest>|<total_dmg>|<dps>
#   WS|<src>|<name>|<count>|<total>|<best>
#   MOB|<src>|<mob_name>|<total>|<seconds_since_last_hit>
# Or DPS_EMPTY for nothing-currently-tracked. TOGGLE_PANEL is a control
# message from //ow dps that flips dps_panel_visible.
sock_dps = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock_dps.bind(("127.0.0.1", 5010))
sock_dps.setblocking(False)

# Outbound command socket: python → lua (port 5011). The button panel
# sends slash commands here when the user clicks a "windower"-kind
# button. Lua drains this on every prerender and runs each via
# windower.send_command(). Connectionless UDP, no reply expected.
sock_cmd_out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock_cmd_out.setblocking(False)
CMD_OUT_ADDR = ("127.0.0.1", 5011)

# ── Sim mode UDP senders ──────────────────────────────────────────────────
# All sim messages reuse CMD_OUT_ADDR (port 5011). Lua's drain handler
# multiplexes SIM/SIM_MODE/SETTING prefixes off the same socket.
def _sim_send_mode(on):
    """Tell lua to enter or leave sim mode."""
    try:
        msg = ("SIM_MODE|on" if on else "SIM_MODE|off").encode("utf-8")
        sock_cmd_out.sendto(msg, CMD_OUT_ADDR)
    except Exception as e:
        print(f"[OmniWatch] sim_send_mode failed: {e!r}")

def _sim_send(key, value, sub=None):
    """Push one sim value to lua. `sub` is an optional secondary key
    (e.g. merit name when key is 'merit')."""
    try:
        if sub is not None:
            payload = f"SIM|{key}|{value}|{sub}"
        else:
            payload = f"SIM|{key}|{value}"
        sock_cmd_out.sendto(payload.encode("utf-8"), CMD_OUT_ADDR)
    except Exception as e:
        print(f"[OmniWatch] sim_send failed: {e!r}")

def _sim_send_reset():
    """Wipe sim state on the lua side. Used by the window's RESET button."""
    try:
        sock_cmd_out.sendto(b"SIM|reset", CMD_OUT_ADDR)
    except Exception as e:
        print(f"[OmniWatch] sim_send_reset failed: {e!r}")


def _sim_format_equip_ref(ref):
    """Serialize a sim equipment ref for the SIM|equip wire format.
    Accepts:
      - int: legacy id-only or 0 for empty
      - dict {"id": N, "bag": N, "idx": N}: instance ref
    Returns string suitable for the wire format. Lua's set_value('equip', ...)
    parses '<id>@<bag>:<idx>' as instance ref, anything else as int.
    """
    if isinstance(ref, dict):
        iid = int(ref.get("id", 0))
        if iid <= 0:
            return "0"
        bag = int(ref.get("bag", 0))
        idx = int(ref.get("idx", 0))
        return f"{iid}@{bag}:{idx}"
    try:
        return str(int(ref))
    except (TypeError, ValueError):
        return "0"


# ── Augment nickname store ─────────────────────────────────────────────────
# Persistent dict of {fingerprint_key → user-assigned nickname}. The
# fingerprint key is "<item_id>:<sorted-augments-joined>". Used to give
# augmented items (multiple capes) friendly names in dropdowns. Loaded
# from omniwatch_settings.json at startup, written back on every update.
#
# Lookup priority for an item's display name:
#   1. nickname for (item_id, fingerprint) if set
#   2. auto augment-summary tag ("[DEX/Acc/WSD]")
#   3. plain item name
_aug_nicknames = {}    # str(fingerprint_key) → str(nickname)


def _aug_fingerprint_key(item_id, fingerprint):
    """Build the persistence key. Pass empty fingerprint for plain items
    (which won't be looked up but we keep the function uniform)."""
    return f"{int(item_id)}:{fingerprint or ''}"


def _aug_nickname_for(item_id, fingerprint):
    """Return the user-assigned nickname for this augment fingerprint,
    or None if none has been set."""
    if not fingerprint:
        return None
    return _aug_nicknames.get(_aug_fingerprint_key(item_id, fingerprint))


def _aug_set_nickname(item_id, fingerprint, nickname):
    """Set or clear the nickname. Empty string clears. Triggers a save."""
    key = _aug_fingerprint_key(item_id, fingerprint)
    if nickname:
        _aug_nicknames[key] = nickname
    else:
        _aug_nicknames.pop(key, None)
    _save_aug_nicknames()


def _save_aug_nicknames():
    """Persist nicknames to disk. Best-effort; swallows errors.
    Saved at the global USER_DIR (not per-character) since augment
    fingerprints are character-independent."""
    try:
        path = os.path.join(USER_DIR, "augment_nicknames.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(_aug_nicknames, f, indent=2, sort_keys=True)
    except Exception as e:
        print(f"[OmniWatch] save_aug_nicknames failed: {e!r}")


def _load_aug_nicknames():
    """Load nicknames from disk on startup. Best-effort."""
    global _aug_nicknames
    try:
        path = os.path.join(USER_DIR, "augment_nicknames.json")
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                _aug_nicknames = {str(k): str(v) for k, v in data.items() if v}
    except Exception as e:
        print(f"[OmniWatch] load_aug_nicknames failed: {e!r}")


def _display_name_for_item(entry):
    """Return the dropdown display string for an item entry from
    _inv_for_sim['by_slot'][slot]. Entries are dicts with id/bag/idx/
    tag/name. Looks up nickname first, falls back to name+tag."""
    if not entry:
        return ""
    name = entry.get("name", "")
    tag  = entry.get("tag", "")
    # If we have a fingerprint cached for this (bag, idx), use it for
    # nickname lookup. Otherwise we have no fingerprint to key against,
    # and only the auto-tag form is available.
    fp_entry = _inv_for_sim.get("fingerprints", {}).get(
        (entry.get("bag", 0), entry.get("idx", 0))
    )
    fp = fp_entry.get("fp", "") if fp_entry else ""
    nick = _aug_nickname_for(entry.get("id", 0), fp)
    if nick:
        return f"{name} ({nick})"
    if tag:
        return f"{name} [{tag}]"
    return name

# ── Inventory snapshot socket (port 5012) ─────────────────────────────────
# Lua sends one INV_BAG packet per bag, then a final INV_END sentinel.
# We accumulate into _inv_buffer until we see INV_END, then atomically
# swap into inventory_state. This way the dropdown never shows a
# half-built snapshot during the (very brief) inter-packet window.
#
# inventory_state: { bag_name: [ {id, count, name}, ... ] }
# Bag names are lowercase: 'inventory', 'wardrobe', 'wardrobe2', etc.
sock_inv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock_inv.bind(("127.0.0.1", 5012))
sock_inv.setblocking(False)

inventory_state    = {}      # complete snapshot, swapped in on INV_END
_inv_buffer        = {}      # accumulator while a snapshot is in progress
inventory_last_update_ts = 0.0
inventory_dropdown_open  = False
# UI scroll state per bag, and which bag is currently expanded.
inventory_active_bag     = None       # None = bag-list view; str = bag-detail view
inventory_bag_scroll     = {}         # bag_name -> int (item-row offset)
inventory_dropdown_rects = []         # click-target list for the dropdown
# Toggle button rect in the header (set in draw_header, read by click handler).
inventory_button_rect    = None

# dps_state: per-source bucket dicts, keyed by src tag ('me', 'pet',
# '<party_member>'). Replaced wholesale on each batch.
dps_state    = {}     # {src: {"window": int, "white": int, ...}}
dps_ws_state = {}     # {src: {ws_name: {"count": int, "total": int, "best": int}}}
dps_mob_state= {}     # {src: {mob_name: {"total": int, "since": float}}}
dps_scope    = "me"   # mirror of lua-side scope
dps_panel_visible = True
dps_last_update_ts = 0.0

# DPS sparkline history: rolling buffer of (timestamp, dps) tuples for the
# 'me' source. Used to render a tiny line graph behind the headline DPS
# number — shows the trend, which is more useful than the current point
# value during long fights. Trimmed to the last DPS_SPARK_WINDOW seconds
# on every render call.
import collections as _collections
dps_history       = _collections.deque(maxlen=240)   # ~2min @ 2Hz emit rate
DPS_SPARK_WINDOW  = 60.0     # seconds of history shown in the sparkline

mob_cast_state = {}

# How long a completed cast line stays visible (seconds), and fade duration.
CAST_DONE_TTL  = 3.0
CAST_DONE_FADE = 1.5   # last 1.5s of the TTL fades to transparent
CAST_START_MAX = 15.0  # safety: drop stale "casting" entries after this

# Zone / position info. Populated from UDP packets on port 5003.
zone_info = {
    "zone_id":   0,
    "zone_name": "",
    "map_index": 0,
    "x": 0.0, "y": 0.0, "z": 0.0,
    "weather":   0,    # FFXI weather id (0 = None / Sunshine / Clear)
    # FFXI map-grid string ("(J-6)" style) from windower.ffxi.get_position.
    # Empty when unavailable (e.g. before first zone packet).
    "pos_str":   "",
}

# Zone-entry timestamp. Reset to time.time() whenever we see a new
# zone_id from the zone packet. The header renders an "elapsed since
# entered" counter from this. None until the first zone packet
# arrives, so the timer label hides itself in that window.
zone_entered_at = None
_last_seen_zone_id = None    # tracks transitions for the reset above

party_data = []
ally1_data = []                  # alliance party 1 (a10..a15)
ally2_data = []                  # alliance party 2 (a20..a25)
equip_data = [0] * 16    # 16 item ids in core.lua display order, 0 = unequipped
equip_slot_rects = {}    # slot_idx -> pygame.Rect, updated each frame by draw_equip_viewer

# Mob ability hover: list of (screen_rect, ability_entry_dict) tuples,
# updated each frame by draw_target_card. Consumed by the main-loop
# hover check to show the ability tooltip.
_mob_ability_rects = []

# Party-row buff/debuff icon hover: list of (screen_rect, name) tuples,
# updated each frame by the icon-grid renderer. Consumed at end-of-frame
# to show the buff name as a small tooltip when the cursor is over an
# icon. Only populated when the "Compact icon grid" setting is on.
_party_buff_icon_rects = []

# Target card state. target_info is None when no target. last_target_time is
# the wall-clock time of the most recent non-empty target packet, used for
# the fade-out effect.
target_info = None     # {"name": str, "id": int, "hpp": int, "family": str}
last_target_time = 0.0
# The last non-None target we had (sticks around during fade).
target_sticky = None

# Sub-target mirrors the same state shape.
target_info_st      = None
last_target_time_st = 0.0
target_sticky_st    = None

flash      = True
last_flash = time.time()

# ── Draggable / resizable panel state ────────────────────────────────────────
# Per-member positions keyed by name, plus one entry for the equip viewer.
panel_positions = {}            # name -> [x, y]  (absolute pixel, derived each frame from anchor)
panel_scales    = {}            # name -> float (1.0 = default size)
equip_pos       = None          # [x, y] or None until first laid out
equip_scale     = 1.0           # float, scales EV_SLOT_SIZE

# Stats panel state — mirrors the equip panel pattern.
stats_pos       = None          # [x, y] derived each frame from anchor
stats_scale     = 1.0

# Anchor state: each panel is pinned to one of the four window corners so its
# visual position stays consistent when the window size changes. Stored as
# [anchor, ox, oy] where anchor ∈ {"tl","tr","bl","br"} and ox/oy are the
# distance from that corner to the nearest panel edge. On render we derive
# absolute x,y from anchor + current WIDTH/HEIGHT.
panel_anchors   = {}            # name -> ["tl"/"tr"/"bl"/"br", ox, oy]
equip_anchor    = None          # same shape, or None before first placement
stats_anchor    = None          # stats panel anchor
target_anchor   = None          # same shape for the target card
target_pos      = None          # [x, y] derived from target_anchor each frame
target_scale    = 1.0           # scales the target card size

# Sub-target card state. Same structure, defaults to sitting directly below
# the main target card.
target_anchor_st = None
target_pos_st    = None
target_scale_st  = 1.0

# Recast timer panel — horizontal strip of currently-cooling-down spells/abilities.
recast_anchor   = None
recast_pos      = None
recast_scale    = 1.0

buff_anchor     = None
buff_pos        = None
buff_scale      = 1.0

# DPS panel — mirrors the buff panel state shape.
dps_anchor      = None
dps_pos         = None
dps_scale       = 1.0

# Button panel — 6 wide × 2 tall grid of user-configurable buttons.
# Each button runs a command (windower slash command, shell command,
# URL, or file path) defined in omniwatch_buttons.json. Visibility
# toggled via //ow buttons.
buttons_panel_visible = True
buttons_anchor        = None
buttons_pos           = None
buttons_scale         = 1.0
buttons_config        = []      # list of 12 entries; populated by load_buttons_config
buttons_rects         = []      # per-frame: list of (pygame.Rect, button_idx)

# Multi-hotbar state. When the "Hotbars shown" setting is > 1, additional
# hotbar panels render alongside the original. Each panel is independent:
# its own draggable position, its own current content page (cyclable via
# the </> arrows in its header).
#
# Naming: "panel_idx" is which panel slot (0..visible_n-1, where 0 is the
# original buttons_pos panel), distinct from "page_idx" which is which
# content page (hotbar_pages entry) that panel is currently showing.
buttons_panel_anchors  = {}     # {panel_idx (>=1): ["tl", ox, oy]}
buttons_panel_positions= {}     # {panel_idx (>=1): [x, y]}
buttons_panel_rects    = {}     # {panel_idx: list of (rect, idx_or_action)} per-frame
# Per-panel current content page. Panel 0 defaults to hotbar_current_page
# (legacy global). Panels 1..N-1 default to their panel_idx (so on first
# show, panel 1 shows page 1, panel 2 shows page 2, etc.). User can cycle
# any panel independently with its own </> arrows.
hotbar_panel_pages = {}         # {panel_idx: page_idx}

# Hotbar editor state. Triggered by the "Edit hotbar" button in
# Settings → HotBar. While editing, the hotbar panel grows downward
# with an inline form for the currently-selected slot. Click any
# slot to switch which one is being edited; click Save/Cancel to
# leave edit mode.
hotbar_edit_mode      = False
hotbar_edit_slot      = -1       # -1 = no slot picked yet; show "select a slot"
hotbar_edit_draft     = None     # working copy of buttons_config[hotbar_edit_slot]
hotbar_focused_field  = None     # "label" | "command" | None
hotbar_text_cursor    = 0        # caret index within the focused field's text
hotbar_text_blink_t0  = 0.0      # time.time() at last cursor reset (controls blink phase)
hotbar_icon_picker_open   = False
hotbar_icon_picker_scroll = 0    # vertical scroll offset within the picker grid
# Module-level clipboard for the COPY/PASTE buttons in the slot editor.
# Holds a normalized button-entry dict, or None when nothing has been
# copied yet. Cleared on overlay restart (intentional — copy/paste is
# for batch-editing in one sitting).
_hotbar_clipboard = None
# Per-frame click-target collections, populated by draw_hotbar_editor:
hotbar_editor_rects   = []       # list of (pygame.Rect, action_dict)

# Settings dropdown menu state. Opened by clicking the gear button in
# the header (leftmost). Per-frame draw populates settings_menu_rects
# so the click handler can resolve which control was hit.
settings_menu_open    = False
settings_button_rect  = None    # pygame.Rect of the gear button itself
settings_menu_rects   = []      # list of (pygame.Rect, action_dict)
settings_menu_scroll  = 0       # vertical scroll offset (px). Reset on close.
settings_menu_panel_rect = None # actual rendered panel rect, for wheel hit-test

dragging_key    = None          # name string, "__equip__", or None
drag_mode       = None          # "move" or "resize"
drag_offset     = (0, 0)        # mouse offset from panel top-left at drag start
drag_start_scale = 1.0          # scale at the moment resize started
drag_start_size  = (0, 0)       # panel pixel size at the moment resize started
panel_order     = []            # names in draw order; most recently dragged goes last (on top)

# Clickable hyperlink regions rebuilt each frame. List of (pygame.Rect, url).
# On mouse click, if the click is inside any rect, we open the URL.
click_targets   = []
# Currently-hovered URL rect for visual feedback (underline).
hovered_url_idx = -1

# Buff/debuff scroll offsets per (member_name, column). column ∈ {"buff","debuff"}.
# Scroll is in lines; clamped at render time to the range the current list allows.
buff_scroll     = {}            # (name, "buff" | "debuff") -> int (starting line index)

# Cache of fonts by (name, size, bold) so we don't rebuild SysFont every frame.
_font_cache = {}
def get_font(name, size, bold=False):
    size = max(6, int(size))
    key  = (name, size, bold)
    f    = _font_cache.get(key)
    if f is None:
        f = pygame.font.SysFont(name, size, bold=bold)
        _font_cache[key] = f
    return f

# ── Anchor helpers ──────────────────────────────────────────────────────────
# Each panel is pinned to the nearest window corner. Positions are stored as
# (anchor, ox, oy) — offset from that corner — so they remain visually stable
# across window resolutions.
def anchor_for_pos(x, y, pw, ph, win_w, win_h):
    """Given an absolute panel position + size and the window size, pick the
    closest corner and return [anchor, ox, oy] where ox/oy are offsets from
    that corner to the panel edge touching it."""
    # Midpoints of the panel, to decide which half of the window it's in.
    cx = x + pw / 2
    cy = y + ph / 2
    horiz = "l" if cx < win_w / 2 else "r"
    vert  = "t" if cy < win_h / 2 else "b"
    anchor = vert + horiz
    if   anchor == "tl": ox, oy = x,                y
    elif anchor == "tr": ox, oy = win_w - (x + pw), y
    elif anchor == "bl": ox, oy = x,                win_h - (y + ph)
    else: # br
        ox, oy = win_w - (x + pw),                  win_h - (y + ph)
    return [anchor, int(ox), int(oy)]

def resolve_anchor(anchor_tuple, pw, ph, win_w, win_h):
    """Inverse of anchor_for_pos — returns absolute (x, y)."""
    a, ox, oy = anchor_tuple
    if   a == "tl": return ox,                oy
    elif a == "tr": return win_w - pw - ox,   oy
    elif a == "bl": return ox,                win_h - ph - oy
    else: # br
        return win_w - pw - ox,               win_h - ph - oy

# Cache of loaded item icons, keyed by (item_id, size_px).
# _icon_raw_cache stores the original surface; _icon_scaled_cache stores resized variants.
_icon_raw_cache    = {}   # item_id -> pygame.Surface (or None if missing / failed to load)
_icon_scaled_cache = {}   # (item_id, size) -> pygame.Surface

def load_icon_surface(item_id):
    """Load the raw icon surface for an item id from ICON_DIR, or None if missing."""
    if not item_id or item_id == 0:
        return None
    if item_id in _icon_raw_cache:
        return _icon_raw_cache[item_id]
    path = os.path.join(ICON_DIR, f"{item_id}.bmp")
    surf = None
    if os.path.isfile(path):
        try:
            surf = pygame.image.load(path).convert_alpha()
        except Exception as e:
            print(f"Failed to load icon {item_id}: {e}")
            surf = None
    _icon_raw_cache[item_id] = surf
    return surf

def get_icon_scaled(item_id, size):
    """Return icon resized to `size` x `size`, cached."""
    key = (item_id, size)
    s   = _icon_scaled_cache.get(key)
    if s is not None:
        return s
    raw = load_icon_surface(item_id)
    if raw is None:
        return None
    s = pygame.transform.smoothscale(raw, (size, size))
    _icon_scaled_cache[key] = s
    return s

# ── UI icon cache (button panel etc.) ────────────────────────────────────
# Keyed by filename inside UI_ICONS_DIR. Supports png/bmp/jpg/jpeg.
_ui_icon_raw_cache    = {}    # filename → Surface or None
_ui_icon_scaled_cache = {}    # (filename, size) → Surface

def load_ui_icon(filename):
    """Load a UI icon by filename (e.g. 'discord.png') from UI_ICONS_DIR.
    Returns the raw Surface or None if missing/unreadable."""
    if not filename:
        return None
    if filename in _ui_icon_raw_cache:
        return _ui_icon_raw_cache[filename]
    surf = None
    if UI_ICONS_DIR and os.path.isdir(UI_ICONS_DIR):
        path = os.path.join(UI_ICONS_DIR, filename)
        if os.path.isfile(path):
            try:
                surf = pygame.image.load(path).convert_alpha()
            except Exception as e:
                print(f"[OmniWatch] UI icon load failed for {filename}: {e}")
    _ui_icon_raw_cache[filename] = surf
    return surf

def get_ui_icon_scaled(filename, size):
    """Return UI icon resized to `size`x`size`, cached. None if missing."""
    if not filename:
        return None
    key = (filename, size)
    s = _ui_icon_scaled_cache.get(key)
    if s is not None:
        return s
    raw = load_ui_icon(filename)
    if raw is None:
        return None
    try:
        s = pygame.transform.smoothscale(raw, (size, size))
    except Exception:
        s = pygame.transform.scale(raw, (size, size))
    _ui_icon_scaled_cache[key] = s
    return s

# ── Trust portrait cache ─────────────────────────────────────────────────
# Trust portraits live under data/trustdata/trust_images/<key>.png. The
# scrape script (build_trusts_fandom.py) writes a portrait_path into
# trusts.json plus a list of portrait_filename_candidates so the loader
# can try multiple filename variants (e.g. 'aldo_(uc).png' falling back
# to 'aldo_uc.png' if user renamed by hand). Cache key is the FIRST
# candidate that resolves on disk — once found, every render uses that
# resolved path.
_trust_portrait_raw_cache = {}     # rel_path -> Surface (or None)
_trust_portrait_scaled    = {}     # (rel_path, w, h) -> Surface
_trust_portrait_resolved  = {}     # trust_key -> resolved rel_path (or None)


def _resolve_trust_portrait_path(trust_rec):
    """Walk candidate filenames for a trust record and return the first
    rel_path that exists on disk. Returns None if nothing matches.

    Per-trust resolution is cached after the first hit so we don't stat
    the disk every frame."""
    if not trust_rec:
        return None
    key = trust_rec.get("name", "") or trust_rec.get("alter_ego", "")
    if key in _trust_portrait_resolved:
        return _trust_portrait_resolved[key]
    root = globals().get("DATA_ROOT", "")
    if not root:
        _trust_portrait_resolved[key] = None
        return None

    # Build the candidate list. Try portrait_path first, then each
    # filename in portrait_filename_candidates (paths relative to
    # trustdata/trust_images/).
    candidates = []
    if trust_rec.get("portrait_path"):
        candidates.append(trust_rec["portrait_path"])
    for fn in trust_rec.get("portrait_filename_candidates") or []:
        rel = os.path.join("trustdata", "trust_images", fn)
        if rel not in candidates:
            candidates.append(rel)
    # Also try a couple of common case variants for stubborn filesystems.
    extra = []
    for c in candidates:
        for ext in (".png", ".PNG", ".jpg", ".JPG", ".jpeg"):
            stem, _, _ = c.rpartition(".")
            v = stem + ext if stem else c
            if v not in candidates and v not in extra:
                extra.append(v)
    candidates.extend(extra)

    resolved = None
    for rel in candidates:
        full = os.path.join(root, rel)
        if os.path.isfile(full):
            resolved = rel
            break
    _trust_portrait_resolved[key] = resolved
    return resolved


def load_trust_portrait(rel_path):
    """Load a trust portrait by its data-relative path. Returns a Surface
    or None on failure. DATA_ROOT is set later in the file; we use a late
    binding via globals() so import order doesn't matter."""
    if not rel_path:
        return None
    if rel_path in _trust_portrait_raw_cache:
        return _trust_portrait_raw_cache[rel_path]
    root = globals().get("DATA_ROOT", "")
    if not root:
        return None
    full = os.path.join(root, rel_path)
    surf = None
    if os.path.isfile(full):
        try:
            surf = pygame.image.load(full).convert_alpha()
        except Exception as e:
            print(f"Failed to load trust portrait {rel_path}: {e}")
    _trust_portrait_raw_cache[rel_path] = surf
    return surf


def get_trust_portrait_scaled(rel_path, w, h):
    """Return a portrait resized to (w, h), preserving aspect ratio by
    fitting inside the box and centering. Cached per (path, w, h)."""
    if not rel_path or w <= 0 or h <= 0:
        return None
    key = (rel_path, int(w), int(h))
    s = _trust_portrait_scaled.get(key)
    if s is not None:
        return s
    raw = load_trust_portrait(rel_path)
    if raw is None:
        return None
    rw, rh = raw.get_size()
    if rw == 0 or rh == 0:
        return None
    # Fit-inside scaling
    scale = min(w / rw, h / rh)
    nw, nh = max(1, int(rw * scale)), max(1, int(rh * scale))
    s = pygame.transform.smoothscale(raw, (nw, nh))
    _trust_portrait_scaled[key] = s
    return s

# Size of the corner resize grip in pixels (visual + hit target).
RESIZE_GRIP = 14
MIN_SCALE   = 0.5
MAX_SCALE   = 2.5

# ── Persistence ──────────────────────────────────────────────────────────────
def _user_data_dir():
    """Return a stable, writable directory for saving layout + icons cache.

    When packaged with PyInstaller --onefile, __file__ points into a temp
    extraction directory that is wiped on exit, which is why saves appeared
    to "not stick". Always write to a real user-profile location instead.
    """
    # Windows first (Windower is Windows-only).
    appdata = os.environ.get("APPDATA")
    if appdata:
        base = os.path.join(appdata, "OmniWatch")
    else:
        # macOS / Linux fallback for development runs.
        base = os.path.join(os.path.expanduser("~"), ".omniwatch")
    try:
        os.makedirs(base, exist_ok=True)
    except Exception:
        # Last resort: temp dir; at least the app won't crash.
        import tempfile
        base = tempfile.gettempdir()
    return base

USER_DIR    = _user_data_dir()

# ── Per-character storage ───────────────────────────────────────────────────
# Most config files live under USER_DIR/<charname>/ so two characters
# on the same machine don't clobber each other's layouts, settings,
# buff configs, gearswap paths, etc. The active "viewed" character
# defaults to the logged-in character (announced via PLAYER packets
# from lua) and can be switched via the dropdown in the header.
#
# When `active_view_char` changes we call _rebuild_path_constants()
# to point all the file path globals at the new character's subfolder.
# Code that does `open(LAYOUT_FILE)` doesn't need to know about this —
# the constant just gets re-bound under it.
#
# A small set of files stay GLOBAL (not per-char) because they're shared
# state or per-machine settings:
#   - omniwatch_dps_log.{jsonl,csv}: dps history is character-agnostic
#     for now (would need a char column to split). Stays global.
#   - logs/ crash-log dir: global.
current_char_name = ""           # who's logged in right now (from PLAYER pkt)
active_view_char  = ""           # whose configs we're viewing/editing
char_view_button_rect = None     # set by draw_header, read by click handler
char_view_dropdown_open = False
char_view_dropdown_rects = []

def list_known_characters():
    """Return a sorted list of character names that have a config
    subfolder under USER_DIR. Used by the header to decide whether to
    show a dropdown (multiple chars) or just the name (single char),
    and by the dropdown itself for the picker rows."""
    chars = []
    try:
        for entry in sorted(os.listdir(USER_DIR)):
            full = os.path.join(USER_DIR, entry)
            if not os.path.isdir(full):
                continue
            if entry.startswith(".") or entry.startswith("_"):
                continue
            if entry.lower() == "logs":
                continue
            chars.append(entry)
    except Exception as e:
        print(f"[OmniWatch] char list error: {e!r}")
    return chars

def _chardir(name):
    """Return the per-character subfolder under USER_DIR. Creates it on
    demand so callers can write straight into it. An empty `name`
    returns USER_DIR itself — used during the brief startup window
    before the PLAYER packet arrives."""
    if not name:
        return USER_DIR
    # Sanitize: FFXI char names are alphanumeric only, but be safe.
    safe = "".join(c for c in name if c.isalnum() or c in "_-")
    if not safe:
        return USER_DIR
    p = os.path.join(USER_DIR, safe)
    try:
        os.makedirs(p, exist_ok=True)
    except Exception:
        return USER_DIR
    return p

def _rebuild_path_constants():
    """Re-bind all per-character file path globals to point at the
    active_view_char's subfolder. Called once at startup and again
    whenever the user picks a different character in the dropdown.
    The constants are module globals so callers reading them after
    this point pick up the new paths automatically."""
    global LAYOUT_FILE, BUFF_CFG, MOBS_FILE, ZONES_FILE, BUTTONS_FILE
    global SETTINGS_FILE, GEARSWAP_PATH_FILE, BUFF_TIMER_CFG, RECAST_TIMER_CFG
    cd = _chardir(active_view_char)
    LAYOUT_FILE        = os.path.join(cd, "omniwatch_layout.json")
    BUFF_CFG           = os.path.join(cd, "omniwatch_buffs.json")
    MOBS_FILE          = os.path.join(cd, "omniwatch_mobs.json")
    ZONES_FILE         = os.path.join(cd, "omniwatch_zones.json")
    BUTTONS_FILE       = os.path.join(cd, "omniwatch_buttons.json")
    SETTINGS_FILE      = os.path.join(cd, "omniwatch_settings.json")
    GEARSWAP_PATH_FILE = os.path.join(cd, "omniwatch_gearswap_path.json")
    BUFF_TIMER_CFG     = os.path.join(cd, "omniwatch_buff_timer.json")
    RECAST_TIMER_CFG   = os.path.join(cd, "omniwatch_recast.json")

# Initial bind. These point to USER_DIR (no char) until the first
# PLAYER packet fires — _rebuild_path_constants() runs again then.
LAYOUT_FILE = os.path.join(USER_DIR, "omniwatch_layout.json")
BUFF_CFG    = os.path.join(USER_DIR, "omniwatch_buffs.json")
MOBS_FILE   = os.path.join(USER_DIR, "omniwatch_mobs.json")
ZONES_FILE  = os.path.join(USER_DIR, "omniwatch_zones.json")
BUTTONS_FILE = os.path.join(USER_DIR, "omniwatch_buttons.json")
SETTINGS_FILE = os.path.join(USER_DIR, "omniwatch_settings.json")
# GearSwap folder path: a single string (the user-chosen folder).
# Stored in its own JSON because the settings.json schema only
# tolerates declared scalar values, and the path is a button-driven
# write rather than a typed setting.
GEARSWAP_PATH_FILE = os.path.join(USER_DIR, "omniwatch_gearswap_path.json")
# Buff timer + recast timer configs. Used to be hardcoded tables in
# OmniWatch.lua (OW_BUFF_CONFIG / OW_RECAST_CONFIG). Now python owns
# the truth and pushes the relevant lists to lua over UDP at startup,
# so users can edit the JSON without touching the .lua file.
BUFF_TIMER_CFG   = os.path.join(USER_DIR, "omniwatch_buff_timer.json")
RECAST_TIMER_CFG = os.path.join(USER_DIR, "omniwatch_recast.json")
# DPS encounter logs stay GLOBAL (not per-char). JSON: one record per
# line, each a full encounter dict. CSV: one summary row per encounter.
# Both append-only and character-agnostic for now.
DPS_LOG_JSON = os.path.join(USER_DIR, "omniwatch_dps_log.jsonl")
DPS_LOG_CSV  = os.path.join(USER_DIR, "omniwatch_dps_log.csv")

# Per-character config files we move into the char subfolder during
# migration. DPS logs are intentionally absent — they stay global.
_PER_CHAR_FILES = (
    "omniwatch_layout.json",
    "omniwatch_buffs.json",
    "omniwatch_mobs.json",
    "omniwatch_zones.json",
    "omniwatch_buttons.json",
    "omniwatch_settings.json",
    "omniwatch_gearswap_path.json",
    "omniwatch_buff_timer.json",
    "omniwatch_recast.json",
)

def _migrate_flat_files_into_chardir(name):
    """One-time migration: if old global config files exist directly in
    USER_DIR (from before per-char storage), move them into this
    character's subfolder. Idempotent — if the target file already
    exists in the chardir, the source is left alone (don't clobber a
    real per-char config with a stale flat file).

    Called on first sight of any character. After migration the user
    can still see/move files manually if they want to copy a layout
    between characters."""
    cd = _chardir(name)
    if cd == USER_DIR:
        return  # name was empty/sanitized to empty — skip
    moved = []
    for fn in _PER_CHAR_FILES:
        src = os.path.join(USER_DIR, fn)
        dst = os.path.join(cd, fn)
        if os.path.exists(src) and not os.path.exists(dst):
            try:
                import shutil
                shutil.move(src, dst)
                moved.append(fn)
            except Exception as e:
                print(f"[OmniWatch] migrate {fn} -> {name}/: {e!r}")
    if moved:
        print(f"[OmniWatch] migrated {len(moved)} configs into "
              f"{name}/: {', '.join(moved)}")

def _on_char_change(new_name):
    """Logged-in character changed (or first became known). If the
    user is "auto-following" the live character (active_view_char ==
    previous current_char_name, i.e. they hadn't manually picked a
    different view), switch active_view_char to the new one and
    reload all configs. Otherwise leave active_view_char alone — the
    user is intentionally looking at someone else's setup."""
    global current_char_name, active_view_char
    was_following = (active_view_char == current_char_name)
    prev = current_char_name
    current_char_name = new_name
    # First-ever migration for this character. Cheap to call repeatedly
    # because it short-circuits when the destination already exists.
    _migrate_flat_files_into_chardir(new_name)
    # Special case: first-ever PLAYER packet. We may have pre-selected
    # this character's folder at startup based on most-recently-modified
    # heuristic, in which case configs are already loaded and we just
    # need to mark the live char. Skip the reload — it would re-do work
    # AND cause panel positions to flicker through their default state
    # for a frame as load_layout resets and re-reads.
    if not prev and active_view_char == new_name:
        return
    if was_following or not prev:
        _switch_active_view(new_name)

def _switch_active_view(name):
    """Change which character's configs we read/write. Reloads layout,
    settings, buffs, recasts, buttons, gearswap path. Live data
    streams (party, equip, stats, debuffs) are not affected — those
    are always for the logged-in character."""
    global active_view_char
    active_view_char = name or ""
    _rebuild_path_constants()
    # Reload everything from the new chardir. Each loader is wrapped in
    # try/except so one bad file can't kill the switch. We special-case
    # `load_settings` because it returns the new settings dict (rather
    # than mutating in place) — we need to assign it back to the
    # `settings` global or set_setting/setting calls will keep reading
    # the previous character's values.
    global settings
    try:
        new_settings = load_settings()
        if isinstance(new_settings, dict):
            settings = new_settings
    except Exception as e:
        print(f"[OmniWatch] load_settings during switch to "
              f"{name!r}: {e!r}")
    # Most loaders mutate their corresponding globals in place. A few
    # (load_buttons_config, load_zones_config, load_mobs_db) RETURN
    # the new value rather than assigning it — so we have to capture
    # and reassign here, otherwise switching characters silently keeps
    # the previous character's data in memory while saves go to the
    # new character's file. The "return-only" loaders are listed in
    # _RETURN_VALUE_LOADERS below; everything else is fire-and-forget.
    _RETURN_VALUE_LOADERS = {
        "load_buttons_config": "buttons_config",
        "load_zones_config":   "_zone_regions",
        "load_mobs_db":        None,    # mutates _mob_db; nothing to assign
    }
    global buttons_config, _zone_regions
    for fn_name in ("load_layout", "load_buff_config",
                    "load_recast_timer_config", "load_buff_timer_config",
                    "load_buttons_config", "load_mobs_db", "load_zones_config"):
        fn = globals().get(fn_name)
        if callable(fn):
            try:
                result = fn()
                target_global = _RETURN_VALUE_LOADERS.get(fn_name)
                if target_global and result is not None:
                    globals()[target_global] = result
            except Exception as e:
                print(f"[OmniWatch] {fn_name} during switch to "
                      f"{name!r}: {e!r}")
    # GearSwap path uses _load_gearswap_path which reads from the
    # rebuilt GEARSWAP_PATH_FILE. Refresh the index too.
    try:
        global gearswap_folder_path
        gearswap_folder_path = _load_gearswap_path()
        if gearswap_folder_path:
            _refresh_gearswap_index()
    except Exception as e:
        print(f"[OmniWatch] gearswap reload during switch: {e!r}")
    print(f"[OmniWatch] view switched to character: {name!r}")

# Now that USER_DIR is defined, force-resolve the crash log path so it
# locks in to %APPDATA%\OmniWatch\logs (alongside the config files) and
# print it on startup so the user knows where to look.
try:
    _resolved_log_dir = _log_dir()
    print(f"[OmniWatch] crash log path: {_resolved_log_dir}")
except Exception as _e:
    print(f"[OmniWatch] could not resolve crash log dir: {_e}")

# One-time migration from PartyWatch (the prior name of this addon) to
# OmniWatch. Looks for old-named config files in either the new
# directory or the prior %APPDATA%\PartyWatch directory and copies them
# to the new locations if the new ones don't exist yet. Idempotent — re-
# runs are no-ops once the new files exist. Logging-only on failure.
def _migrate_legacy_config():
    legacy_locations = []
    appdata = os.environ.get("APPDATA")
    if appdata:
        legacy_locations.append(os.path.join(appdata, "PartyWatch"))
    legacy_locations.append(os.path.join(os.path.expanduser("~"), ".omniwatch"))
    legacy_locations.append(USER_DIR)   # old names, new dir
    pairs = [
        ("partywatch_layout.json", LAYOUT_FILE),
        ("omniwatch_buffs.json",  BUFF_CFG),
        ("partywatch_mobs.json",   MOBS_FILE),
        ("omniwatch_zones.json",  ZONES_FILE),
    ]
    for old_name, new_path in pairs:
        if os.path.exists(new_path):
            continue
        for legacy_dir in legacy_locations:
            old_path = os.path.join(legacy_dir, old_name)
            if os.path.exists(old_path) and old_path != new_path:
                try:
                    import shutil
                    shutil.copy2(old_path, new_path)
                    print(f"[OmniWatch] migrated {old_path} → {new_path}")
                    break
                except Exception as e:
                    print(f"[OmniWatch] migration of {old_path} failed: {e}")

try:
    _migrate_legacy_config()
except Exception as _e:
    # Migration is best-effort; never block startup on it.
    print(f"[OmniWatch] migration skipped: {_e}")

# Default mob database seed — a handful of well-known NMs so the target card
# has something to show immediately. User extends this file with more entries.
# Matching is by exact name (case-insensitive). Elements are canonical names.
_MOBS_SEED = {
    "_README": [
        "OmniWatch mob reference database.",
        "",
        "Each entry is keyed by mob NAME (matches in-game name, case-insensitive).",
        "Fields:",
        "  family     — short tag: 'dragon', 'beastman', 'undead', 'arcana',",
        "               'demon', 'amorph', 'bird', 'bug', 'plantoid', 'vermin',",
        "               'aquan', 'lizard', 'beast', 'luminian', 'luminion', etc.",
        "               Used to pick a generic family icon.",
        "  strengths  — list of strengths. Elements: Fire, Ice, Wind, Earth,",
        "               Lightning, Water, Light, Dark. Weapon types: Slashing,",
        "               Piercing, Blunt, H2H.",
        "  weaknesses — same value set as strengths.",
        "  abilities  — list of TP moves / abilities the mob is known to use.",
        "",
        "After editing, save and restart OmniWatch."
    ],
    "Kirin": {
        "family": "luminian",
        "strengths":  ["Lightning"],
        "weaknesses": ["Dark"],
        "abilities":  ["Ecliptic Howl", "Eyes On Me", "Stonega IV",
                       "Firaga IV", "Blizzaga IV", "Thundaga IV", "Aeroga IV"]
    },
    "Fafnir": {
        "family": "dragon",
        "strengths":  ["Fire"],
        "weaknesses": ["Ice", "Piercing"],
        "abilities":  ["Spike Flail", "Horrid Roar", "Hurricane Wing",
                       "Heavy Stomp", "Dread Dive", "Flame Breath"]
    },
    "Nidhogg": {
        "family": "dragon",
        "strengths":  ["Ice"],
        "weaknesses": ["Fire", "Piercing"],
        "abilities":  ["Spike Flail", "Hurricane Wing", "Heavy Stomp",
                       "Dread Dive", "Frost Breath"]
    },
    "Aspidochelone": {
        "family": "aquan",
        "strengths":  ["Water"],
        "weaknesses": ["Lightning"],
        "abilities":  ["Harden Shell", "Tortoise Stomp", "Tidal Guillotine"]
    },
    "Khimaira": {
        "family": "beast",
        "strengths":  ["Slashing"],
        "weaknesses": ["Blunt"],
        "abilities":  ["Fossilizing Breath", "Fulmination", "Pyric Bulwark",
                       "Snow Cloud", "Ram Charge"]
    },
    "Ouryu": {
        "family": "dragon",
        "strengths":  ["Wind"],
        "weaknesses": ["Ice", "Piercing"],
        "abilities":  ["Hammer Beak", "Wind Shear", "Radiant Breath",
                       "Megastorm", "Touchdown"]
    },
}

def load_mobs_db():
    try:
        if not os.path.exists(MOBS_FILE):
            with open(MOBS_FILE, "w") as f:
                json.dump(_MOBS_SEED, f, indent=2)
            print(f"[OmniWatch] Created default mob DB at {MOBS_FILE}")
            return dict(_MOBS_SEED)
        with open(MOBS_FILE) as f:
            data = json.load(f)
        print(f"[OmniWatch] Loaded mob DB from {MOBS_FILE} ({len(data)-1} mobs)")
        return data
    except Exception as e:
        print(f"[OmniWatch] Could not load mob DB: {e}. Using seed.")
        return dict(_MOBS_SEED)

# Index built case-insensitively for lookups.
_mobs_db = load_mobs_db()
_mobs_by_lower = {k.lower(): v for k, v in _mobs_db.items()
                  if k != "_README" and isinstance(v, dict)}

# MobDB zonal database — keyed by lowercase name, value is a list of entries
# (a name can appear in multiple zones). Each entry carries the zone id it
# came from for disambiguation. Loaded after DATA_DIR is resolved, later.
_mobdb_by_lower = {}

# Human-readable element / damage type order, used for strengths/weaknesses
# rendering so the order is stable across mobs.
_DMG_TYPE_ORDER = [
    "Slashing", "Piercing", "H2H", "Impact",
    "Fire", "Ice", "Wind", "Earth", "Lightning", "Water", "Light", "Dark",
]

def _parse_mobdb_file(path):
    """Parse a single MobDB data file. Returns list of (zone_id, mob_dict)."""
    results = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except Exception as e:
        print(f"[OmniWatch] Could not read {path}: {e}")
        return results

    # Zone id is in the header comment: "--Zone ID: N"
    m = re.search(r"--\s*Zone\s*ID:\s*(\d+)", text)
    zone_id = int(m.group(1)) if m else 0

    # Each mob entry looks like:
    # ['Name'] = { Name='Name', Aggro=true, ..., Modifiers={Slashing=1,...} },
    # We capture NAME and BODY. BODY may contain nested braces (Modifiers,
    # Drops, Spells) but only one level deep, so we match with a non-greedy
    # body that accepts one inner brace group.
    pattern = re.compile(
        r"\[\s*'((?:[^'\\]|\\.)*)'\s*\]\s*=\s*\{\s*((?:[^{}]|\{[^{}]*\})*)\s*\}",
        re.DOTALL,
    )
    for match in pattern.finditer(text):
        name_raw = match.group(1).replace("\\'", "'")
        body     = match.group(2)
        entry = _parse_mob_body(body)
        entry["_zone_id"] = zone_id
        entry["_name"]    = name_raw
        results.append((zone_id, name_raw, entry))
    return results

def _parse_mob_body(body):
    """Extract key fields from the MobDB entry body string."""
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
        "modifiers": {},
        "spells":    [],
    }

    # Simple scalar fields. Each pattern requires (^|non-letter) before the
    # field name so e.g. "Sight" doesn't match inside "TrueSight". Python's
    # \b would consider the transition inside TrueSight a word boundary, so
    # we can't use \b; we use a negative lookbehind for a letter instead.
    scalar_patterns = {
        "notorious":  (r"(?<![A-Za-z])Notorious\s*=\s*(true|false)",  "bool"),
        "aggro":      (r"(?<![A-Za-z])Aggro\s*=\s*(true|false)",      "bool"),
        "link":       (r"(?<![A-Za-z])Link\s*=\s*(true|false)",       "bool"),
        "truesight":  (r"(?<![A-Za-z])TrueSight\s*=\s*(true|false)",  "bool"),
        "sight":      (r"(?<![A-Za-z])Sight\s*=\s*(true|false)",      "bool"),
        "sound":      (r"(?<![A-Za-z])Sound\s*=\s*(true|false)",      "bool"),
        "blood":      (r"(?<![A-Za-z])Blood\s*=\s*(true|false)",      "bool"),
        "magic":      (r"(?<![A-Za-z])Magic\s*=\s*(true|false)",      "bool"),
        "ja":         (r"(?<![A-Za-z])JA\s*=\s*(true|false)",         "bool"),
        "scent":      (r"(?<![A-Za-z])Scent\s*=\s*(true|false)",      "bool"),
        "min_level":  (r"(?<![A-Za-z])MinLevel\s*=\s*(-?\d+)",        "int"),
        "max_level":  (r"(?<![A-Za-z])MaxLevel\s*=\s*(-?\d+)",        "int"),
        "immunities": (r"(?<![A-Za-z])Immunities\s*=\s*(-?\d+)",      "int"),
        "respawn":    (r"(?<![A-Za-z])Respawn\s*=\s*(-?\d+)",         "int"),
        "job":        (r"(?<![A-Za-z])Job\s*=\s*(-?\d+)",             "int"),
    }
    for key, (pat, kind) in scalar_patterns.items():
        m = re.search(pat, body)
        if not m:
            continue
        if kind == "bool":
            out[key] = (m.group(1) == "true")
        else:
            try:    out[key] = int(m.group(1))
            except: pass

    # Family — string. Present in many MobDB entries for NMs; authoritative
    # when available.
    fm = re.search(r"(?<![A-Za-z])Family\s*=\s*'([^']*)'", body)
    if not fm:
        fm = re.search(r'(?<![A-Za-z])Family\s*=\s*"([^"]*)"', body)
    if fm:
        out["family"] = fm.group(1).strip().lower()

    # Modifiers — inner block of Key=number pairs.
    mm = re.search(r"Modifiers\s*=\s*\{([^}]*)\}", body)
    if mm:
        for km in re.finditer(r"(\w+)\s*=\s*(-?\d+(?:\.\d+)?)", mm.group(1)):
            try:
                out["modifiers"][km.group(1)] = float(km.group(2))
            except: pass

    # Spells — list of integers.
    sm = re.search(r"Spells\s*=\s*\{([^}]*)\}", body)
    if sm:
        spell_ids = [int(x) for x in re.findall(r"-?\d+", sm.group(1))]
        out["spells"] = spell_ids

    return out

# ── Job name → 3-letter abbreviation ────────────────────────────────────
# The BG-wiki scrape sometimes records main/sub jobs as full words
# ("White Mage", "Warrior") and sometimes as the 3-letter code ("WHM").
# OmniWatch's target card has a fixed-width 3-char slot, so we always
# need the abbreviation. Returns "" for unrecognized inputs (multi-job
# strings, partial words, commentary) so the family-level fallback can
# run instead.

JOB_NAME_TO_ABBR = {
    "warrior": "WAR",  "monk": "MNK",
    "white mage": "WHM", "whitemage": "WHM",
    "black mage": "BLM", "blackmage": "BLM",
    "red mage":   "RDM", "redmage":   "RDM",
    "thief": "THF",
    "paladin": "PLD",
    "dark knight": "DRK", "darkknight": "DRK",
    "beastmaster": "BST",
    "bard": "BRD",
    "ranger": "RNG",
    "samurai": "SAM",
    "ninja": "NIN",
    "dragoon": "DRG",
    "summoner": "SMN",
    "blue mage": "BLU", "bluemage": "BLU",
    "corsair": "COR",
    "puppetmaster": "PUP",
    "dancer": "DNC",
    "scholar": "SCH",
    "geomancer": "GEO",
    "rune fencer": "RUN", "runefencer": "RUN",
}

def _to_job_abbr(s):
    """Convert a job name string to its 3-letter code, or "" if no match.
    Accepts both abbreviations ("WHM" → "WHM") and full names
    ("White Mage" → "WHM"). Returns "" for blanks, commentary, and
    multi-job strings the regex can't cleanly resolve."""
    if not s:
        return ""
    s_clean = s.strip()
    if len(s_clean) == 3 and s_clean.isalpha():
        return s_clean.upper()
    key = s_clean.lower()
    if key in JOB_NAME_TO_ABBR:
        return JOB_NAME_TO_ABBR[key]
    return ""


def load_mobdb_data():
    """Load the merged mobdb. Prefers the JSON produced by mobdb.py
    (mob_individuals.json). Falls back to scanning .lua files when the
    merged JSON isn't present, for users who haven't migrated yet.

    Returns: { lower_name: [entry, ...] }
    Each entry preserves the SAME SHAPE as the legacy .lua loader so
    existing consumers (target card render, WS damage modifier readout,
    etc.) keep working unchanged. New JSON-only fields (abilities,
    spells_named, resists, image_filename, etc.) are added on top of
    each entry — consumers can opt into them where useful.

    The merged JSON's per-zone data is unpacked into one entry per zone
    so zone-aware lookup_mobdb() still works. Mobs without zone data
    (JSON-only) get a single entry with zone_id=0.
    """
    if not MOBDATA_DIR or not os.path.isdir(MOBDATA_DIR):
        return {}

    by_lower = {}
    json_path = os.path.join(MOBDATA_DIR, "mob_individuals.json")
    if os.path.isfile(json_path):
        try:
            with open(json_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError) as e:
            print(f"[OmniWatch] mob_individuals.json load failed: {e}")
            data = {}
        inds = data.get("individuals", {}) if isinstance(data, dict) else {}
        for name_lower, rec in inds.items():
            # Detect schema: flat (v4+, fields hoisted to top level, no zones
            # array) vs zoned (v2/v3, fields inside zones[]).
            zones = rec.get("zones") or []
            is_flat = "min_level" in rec and not zones

            shared = {
                "_name":          rec.get("display") or name_lower,
                "family":         rec.get("family", "") or "",
                "type":           rec.get("type", ""),
                "aggro":          bool(rec.get("aggro")),
                "link":           bool(rec.get("link")),
                # Detect flag breakdown.
                "truesight":      bool(rec.get("detect_flags", {}).get("truesight")),
                "sight":          bool(rec.get("detect_flags", {}).get("sight")),
                "sound":          bool(rec.get("detect_flags", {}).get("sound")),
                "blood":          bool(rec.get("detect_flags", {}).get("blood")),
                "magic":          bool(rec.get("detect_flags", {}).get("magic")),
                "ja":             bool(rec.get("detect_flags", {}).get("ja")),
                "scent":          bool(rec.get("detect_flags", {}).get("scent")),
                # JSON-only rich fields (visible to target card etc.).
                "abilities":      list(rec.get("abilities") or []),
                "resists":        list(rec.get("resists") or []),
                "susceptible":    list(rec.get("susceptible") or []),
                "absorbs":        list(rec.get("absorbs") or []),
                "immune":         list(rec.get("immune") or []),
                "traits":         list(rec.get("traits") or []),
                "main_job":       rec.get("main_job", ""),
                "sub_job":        rec.get("sub_job", ""),
                "intro_text":     rec.get("intro_text", ""),
                "crystal":        rec.get("crystal", ""),
                "link_url":       rec.get("link_url", ""),
                "image":          rec.get("image", ""),
                "image_url":      rec.get("image_url", ""),
            }
            # Spells: unify three possible sources into a single name list.
            #   1. Top-level `spells` from polished JSON (already names)
            #   2. Top-level `spells_named` from older merged JSON (also names)
            #   3. Numeric IDs from zones[].spells (legacy/v2-v3 mobdb) —
            #      resolved here using _spells_by_id.
            spell_names = []
            seen_spells = set()
            for n in (rec.get("spells") or rec.get("spells_named") or []):
                if isinstance(n, int):
                    if "_spells_by_id" in globals() and _spells_by_id:
                        sp = _spells_by_id.get(n)
                        if sp and sp.get("name"):
                            nm = sp["name"]
                            if nm.lower() not in seen_spells:
                                seen_spells.add(nm.lower())
                                spell_names.append(nm)
                    continue
                ns = str(n).strip()
                if ns and ns.lower() not in seen_spells:
                    seen_spells.add(ns.lower())
                    spell_names.append(ns)
            if "_spells_by_id" in globals() and _spells_by_id:
                for z in zones:
                    for sid in z.get("spells", []) or []:
                        if not isinstance(sid, int):
                            continue
                        sp = _spells_by_id.get(sid)
                        if not sp:
                            continue
                        nm = sp.get("name")
                        if nm and nm.lower() not in seen_spells:
                            seen_spells.add(nm.lower())
                            spell_names.append(nm)
            shared["spells"] = spell_names

            if is_flat:
                # New flat schema: zone-specific fields are at top level.
                # Build one entry; lookup_mobdb returns it regardless of
                # current zone (we no longer track zone-specific variants).
                entry = dict(shared)
                entry["_zone_id"]   = 0
                entry["min_level"]  = int(rec.get("min_level", 0) or 0)
                entry["max_level"]  = int(rec.get("max_level", 0) or 0)
                entry["immunities"] = int(rec.get("immunities", 0) or 0)
                entry["respawn"]    = int(rec.get("respawn", 0) or 0)
                entry["job"]        = int(rec.get("job", 0) or 0)
                entry["modifiers"]  = dict(rec.get("modifiers") or {})
                entry["notorious"]  = bool(rec.get("notorious"))
                by_lower.setdefault(name_lower, []).append(entry)
            elif zones:
                # Old zoned schema: one entry per zone for zone-aware lookup.
                for z in zones:
                    entry = dict(shared)
                    entry["_zone_id"]   = int(z.get("zone_id", 0) or 0)
                    entry["min_level"]  = int(z.get("min_level", 0) or 0)
                    entry["max_level"]  = int(z.get("max_level", 0) or 0)
                    entry["immunities"] = int(z.get("immunities", 0) or 0)
                    entry["respawn"]    = int(z.get("respawn", 0) or 0)
                    entry["job"]        = int(z.get("job", 0) or 0)
                    entry["modifiers"]  = dict(z.get("modifiers") or {})
                    # entry["spells"] is already the unified name list
                    # from `shared` — don't overwrite with raw zone IDs.
                    entry["notorious"]  = bool(z.get("notorious"))
                    by_lower.setdefault(name_lower, []).append(entry)
            else:
                # JSON-only mob with no zone data and no flat fields.
                # Stub entry with empty zone-specific fields so consumers
                # still find a valid record.
                entry = dict(shared)
                entry["_zone_id"]   = 0
                entry["min_level"]  = 0
                entry["max_level"]  = 0
                entry["immunities"] = 0
                entry["respawn"]    = 0
                entry["job"]        = 0
                entry["modifiers"]  = {}
                entry["notorious"]  = False
                by_lower.setdefault(name_lower, []).append(entry)
        print(f"[OmniWatch] Loaded merged mob db: {len(by_lower)} unique names "
              f"({sum(len(v) for v in by_lower.values())} entries).")
        return by_lower

    # Fallback: legacy .lua scan for users who haven't run mobdb.py yet.
    try:
        files = [f for f in os.listdir(MOBDATA_DIR) if f.lower().endswith(".lua")]
    except Exception as e:
        print(f"[OmniWatch] Could not list {MOBDATA_DIR}: {e}")
        return {}
    if not files:
        print(f"[OmniWatch] No mob_individuals.json found and no .lua files. "
              f"Drop mob_individuals.json (from mobdb.py) into {MOBDATA_DIR}.")
        return {}
    count = 0
    for fn in files:
        path = os.path.join(MOBDATA_DIR, fn)
        for zone_id, name, entry in _parse_mobdb_file(path):
            key = name.lower()
            by_lower.setdefault(key, []).append(entry)
            count += 1
    print(f"[OmniWatch] Legacy mob db loaded: {count} entries from "
          f"{len(files)} .lua files ({len(by_lower)} unique). Run mobdb.py "
          "to merge with BG-wiki scrape.")
    return by_lower

_mobdb_by_lower = {}   # populated once DATA_DIR is known (after icon/data dir discovery)

def lookup_mobdb(name, zone_id=0):
    """Zone-aware lookup. If multiple entries exist with the same name and
    one matches the current zone, return that. Otherwise return the first
    entry (best effort)."""
    if not name:
        return None
    entries = _mobdb_by_lower.get(name.lower())
    if not entries:
        return None
    if len(entries) == 1:
        return entries[0]
    if zone_id:
        for e in entries:
            if e.get("_zone_id") == zone_id:
                return e
    return entries[0]

def mob_strengths_weaknesses(entry):
    """Convert an entry's modifiers to (strengths_list, weaknesses_list).
    Each item is a tuple of (type_name, display_percent) where display_percent
    is the signed percent change (e.g. -50 for 0.5 multiplier, +25 for 1.25).
    Neutral (1.0) types are skipped.

    Modifier keys may be lowercase (new merged JSON) or cap-cased
    (legacy .lua format). We lookup case-insensitively and report back
    with the canonical cap-cased name from _DMG_TYPE_ORDER for display.
    """
    if not entry:
        return [], []
    mods = entry.get("modifiers") or {}
    # Build a lowercase-key view once so the iteration below is O(1) per type.
    mods_lower = {k.lower(): v for k, v in mods.items()}
    strengths  = []
    weaknesses = []
    for k in _DMG_TYPE_ORDER:
        v = mods_lower.get(k.lower())
        if v is None:
            continue
        if v == 1.0 or abs(v - 1.0) < 0.001:
            continue
        pct = int(round((v - 1.0) * 100))
        if v < 1.0:
            strengths.append((k, pct))   # pct will be negative
        else:
            weaknesses.append((k, pct))  # pct will be positive
    return strengths, weaknesses

# Immunity bitmask → human-readable labels. Bit flags as used by MobDB data.
_IMMUNITY_FLAGS = [
    (1,     "Sleep"),
    (2,     "Gravity"),
    (4,     "Bind"),
    (8,     "Stun"),
    (16,    "Silence"),
    (32,    "Paralyze"),
    (64,    "Blind"),
    (128,   "Slow"),
    (256,   "Poison"),
    (512,   "Elegy"),
    (1024,  "Requiem"),
    (2048,  "Charm"),
    (4096,  "Terror"),
    (8192,  "Petrify"),
    (16384, "Doom"),
]

def decode_immunities(mask):
    """Return a list of immunity names active in this bitmask."""
    if not mask or mask <= 0:
        return []
    return [name for bit, name in _IMMUNITY_FLAGS if (mask & bit) == bit]

def format_respawn(seconds):
    """Return 'X Minutes Y Seconds' with proper pluralization; empty for 0."""
    if not seconds or seconds <= 0:
        return ""
    m = seconds // 60
    s = seconds % 60
    parts = []
    if m > 0:
        parts.append(f"{m} Minute"  + ("s" if m != 1 else ""))
    if s > 0:
        parts.append(f"{s} Second"  + ("s" if s != 1 else ""))
    return " ".join(parts)

def lookup_mob(name):
    """Legacy hand-seeded DB lookup (Kirin/Fafnir/etc.). Returns dict or None."""
    if not name:
        return None
    return _mobs_by_lower.get(name.lower())

# ── Zone → Region lookup ─────────────────────────────────────────────────────
# FFXI has ~250 zones grouped into roughly 25 regions. We ship a seed with
# the most common regions covered, user extends via omniwatch_zones.json.
_ZONES_SEED_VERSION = 3
_ZONES_SEED = {
    "_README": [
        "OmniWatch zone → region mapping.",
        "",
        "Keys are FFXI zone IDs (integers as strings). Values are the",
        "region name to display. Regions not mapped here will show as",
        "blank in the header. Add entries as you encounter unmapped zones.",
        "",
        "_VERSION is used by OmniWatch to know when to auto-merge new",
        "default entries on startup (existing entries you've changed are",
        "preserved; only missing entries are added). Don't edit it.",
        "",
        "After editing, save and restart OmniWatch."
    ],
    "_VERSION": _ZONES_SEED_VERSION,

    # ─── Ronfaure (San d'Oria area) ────────────────────────────────
    "100": "Ronfaure", "101": "Ronfaure", "102": "Ronfaure",
    "230": "Ronfaure", "231": "Ronfaure", "232": "Ronfaure",
    "233": "Ronfaure", "190": "Ronfaure", "193": "Ronfaure",
    "139": "Ronfaure", "140": "Ronfaure", "141": "Ronfaure",
    "146": "Ronfaure", "149": "Ronfaure", "163": "Ronfaure",
    "167": "Ronfaure",
    # ─── Zulkheim ──────────────────────────────────────────────────
    "103": "Zulkheim", "108": "Zulkheim", "196": "Zulkheim",
    "248": "Zulkheim",
    # ─── Gustaberg (Bastok area) ───────────────────────────────────
    "106": "Gustaberg", "107": "Gustaberg", "234": "Gustaberg",
    "235": "Gustaberg", "236": "Gustaberg", "237": "Gustaberg",
    "172": "Gustaberg", "191": "Gustaberg", "143": "Gustaberg",
    "150": "Gustaberg",
    # ─── Norvallen ─────────────────────────────────────────────────
    "104": "Norvallen", "105": "Norvallen", "195": "Norvallen",
    # ─── Sarutabaruta (Windurst area) ──────────────────────────────
    "115": "Sarutabaruta", "116": "Sarutabaruta", "238": "Sarutabaruta",
    "239": "Sarutabaruta", "240": "Sarutabaruta", "241": "Sarutabaruta",
    "242": "Sarutabaruta", "192": "Sarutabaruta", "194": "Sarutabaruta",
    "142": "Sarutabaruta", "144": "Sarutabaruta", "145": "Sarutabaruta",
    "152": "Sarutabaruta", "169": "Sarutabaruta", "170": "Sarutabaruta",
    # ─── Kolshushu ─────────────────────────────────────────────────
    "117": "Kolshushu", "118": "Kolshushu", "198": "Kolshushu",
    "249": "Kolshushu", "250": "Kolshushu", "213": "Kolshushu",
    "173": "Kolshushu",
    # ─── Derfland ──────────────────────────────────────────────────
    "109": "Derfland", "110": "Derfland", "197": "Derfland",
    "200": "Derfland",
    # ─── Aragoneu ──────────────────────────────────────────────────
    "119": "Aragoneu", "120": "Aragoneu", "151": "Aragoneu",
    "147": "Aragoneu", "148": "Aragoneu",
    # ─── Fauregandi ────────────────────────────────────────────────
    "111": "Fauregandi", "204": "Fauregandi",
    # ─── Valdeaunia ────────────────────────────────────────────────
    "112": "Valdeaunia", "161": "Valdeaunia", "162": "Valdeaunia",
    "165": "Valdeaunia",
    # ─── Qufim ─────────────────────────────────────────────────────
    "126": "Qufim", "157": "Qufim", "158": "Qufim", "184": "Qufim",
    # ─── Li'Telor ──────────────────────────────────────────────────
    "121": "Li'Telor", "122": "Li'Telor", "153": "Li'Telor",
    "154": "Li'Telor", "166": "Li'Telor",
    # ─── Kuzotz ────────────────────────────────────────────────────
    "114": "Kuzotz", "125": "Kuzotz", "208": "Kuzotz", "247": "Kuzotz",
    # ─── Vollbow ───────────────────────────────────────────────────
    "113": "Vollbow", "174": "Vollbow", "212": "Vollbow",
    # ─── Elshimo Lowlands & Uplands ───────────────────────────────
    "123": "Elshimo", "124": "Elshimo", "159": "Elshimo",
    "160": "Elshimo", "205": "Elshimo", "252": "Elshimo",
    "176": "Elshimo",
    # ─── Tu'Lia (Sky) ──────────────────────────────────────────────
    "127": "Tu'Lia", "128": "Tu'Lia", "129": "Tu'Lia", "130": "Tu'Lia",
    "177": "Tu'Lia", "178": "Tu'Lia", "179": "Tu'Lia", "180": "Tu'Lia",
    "181": "Tu'Lia", "168": "Tu'Lia",
    # ─── Movalpolos ────────────────────────────────────────────────
    "11": "Movalpolos", "12": "Movalpolos", "13": "Movalpolos",
    # ─── Tavnazia (CoP, includes Promyvions) ───────────────────────
    "16": "Tavnazia", "17": "Tavnazia", "18": "Tavnazia", "19": "Tavnazia",
    "20": "Tavnazia", "21": "Tavnazia", "22": "Tavnazia", "23": "Tavnazia",
    "24": "Tavnazia", "25": "Tavnazia", "26": "Tavnazia", "27": "Tavnazia",
    "28": "Tavnazia", "29": "Tavnazia", "30": "Tavnazia", "31": "Tavnazia",
    "32": "Tavnazia",
    # ─── Lumoria (CoP Sea) ─────────────────────────────────────────
    "14": "Lumoria", "33": "Lumoria", "34": "Lumoria", "35": "Lumoria",
    "36": "Lumoria",
    # ─── Aht Urhgan / Near East (ToAU) ─────────────────────────────
    "48": "Aht Urhgan", "50": "Aht Urhgan", "51": "Aht Urhgan",
    "52": "Aht Urhgan", "53": "Aht Urhgan", "54": "Aht Urhgan",
    "55": "Aht Urhgan", "61": "Aht Urhgan", "62": "Aht Urhgan",
    "65": "Aht Urhgan", "79": "Aht Urhgan",
    # ─── Sacred City of Adoulin ────────────────────────────────────
    # Per BG-wiki "Category:The Sacred City of Adoulin": the city
    # zones + Rala Waterways belong here.
    "256": "Adoulin", "257": "Adoulin",          # West, East Adoulin
    "258": "Adoulin", "259": "Adoulin",          # Rala Waterways + [U]
    "281": "Adoulin",                            # Leafallia
    # ─── Ulbuka (Adoulin field zones) ──────────────────────────────
    # Per BG-wiki "Category:Ulbuka": the continent's field zones, the
    # Gates, the Caverns, Ra'Kaznar, etc.
    "260": "Ulbuka", "261": "Ulbuka", "262": "Ulbuka",   # Yahse, Ceizak, Hennetiel
    "263": "Ulbuka", "264": "Ulbuka",                    # Yorcia + [U]
    "265": "Ulbuka", "266": "Ulbuka", "267": "Ulbuka",   # Morimar, Marjami, Kamihr
    "268": "Ulbuka", "269": "Ulbuka",                    # Sih Gates, Moh Gates
    "270": "Ulbuka", "271": "Ulbuka",                    # Cirdas + [U]
    "272": "Ulbuka", "273": "Ulbuka",                    # Dho Gates, Woh Gates
    "274": "Ulbuka", "275": "Ulbuka",                    # Outer Ra'Kaznar + [U1]
    "276": "Ulbuka", "277": "Ulbuka",                    # Ra'Kaznar Inner / Turris
    "282": "Ulbuka",                                     # Mount Kamihr
    "133": "Ulbuka", "189": "Ulbuka",                    # Outer Ra'Kaznar [U2/U3]
    # ─── Reisenjima ────────────────────────────────────────────────
    "291": "Reisenjima", "292": "Reisenjima", "293": "Reisenjima",
    # ─── Escha ─────────────────────────────────────────────────────
    "288": "Escha", "289": "Escha", "290": "Escha",
    # ─── Jeuno ─────────────────────────────────────────────────────
    "243": "Jeuno", "244": "Jeuno", "245": "Jeuno", "246": "Jeuno",
    "251": "Jeuno",
    # ─── Abyssea ───────────────────────────────────────────────────
    "15": "Abyssea", "45": "Abyssea", "132": "Abyssea",
    "215": "Abyssea", "216": "Abyssea", "217": "Abyssea",
    "218": "Abyssea", "253": "Abyssea", "254": "Abyssea",
    "255": "Abyssea",
    # ─── Past Vana'diel [S] (WotG) ─────────────────────────────────
    "80": "Past", "81": "Past", "82": "Past", "83": "Past",
    "84": "Past", "85": "Past", "87": "Past", "88": "Past",
    "89": "Past", "90": "Past", "91": "Past", "92": "Past",
    "94": "Past", "95": "Past", "96": "Past", "97": "Past",
    "98": "Past", "99": "Past", "136": "Past", "137": "Past",
    "138": "Past", "155": "Past", "156": "Past", "164": "Past",
    "171": "Past", "175": "Past",
    # ─── Dynamis ───────────────────────────────────────────────────
    "39": "Dynamis", "40": "Dynamis", "41": "Dynamis", "42": "Dynamis",
    "134": "Dynamis", "135": "Dynamis", "185": "Dynamis", "186": "Dynamis",
    "187": "Dynamis", "188": "Dynamis",
    # ─── Dynamis Divergence ────────────────────────────────────────
    "294": "Dynamis [D]", "295": "Dynamis [D]",
    "296": "Dynamis [D]", "297": "Dynamis [D]",
    # ─── Limbus ────────────────────────────────────────────────────
    "37": "Limbus", "38": "Limbus",
    # ─── Walk of Echoes ────────────────────────────────────────────
    "182": "Walk of Echoes", "279": "Walk of Echoes", "298": "Walk of Echoes",
    # ─── Mog Garden / misc. ────────────────────────────────────────
    "280": "Mog Garden", "284": "Mog Garden", "285": "Mog Garden",
}

def load_zones_config():
    """Load (or write the default) zone→region map. Returns a dict keyed
    by integer zone_id → region name.

    Versioning: when an existing file's _VERSION is older than the seed,
    new default entries are merged in (existing entries are preserved
    as-is so user customizations aren't overwritten). The file is then
    rewritten with the new _VERSION so the merge runs only once per
    upgrade.
    """
    needs_write = False
    try:
        if not os.path.exists(ZONES_FILE):
            with open(ZONES_FILE, "w") as f:
                json.dump(_ZONES_SEED, f, indent=2)
            print(f"[OmniWatch] Created default zones map at {ZONES_FILE}")
            raw = dict(_ZONES_SEED)
        else:
            with open(ZONES_FILE) as f:
                raw = json.load(f)
            # Auto-upgrade: if the file is from an older seed version,
            # merge in any new default entries that don't already exist
            # in the file. User-customized values are preserved exactly.
            file_ver = raw.get("_VERSION", 0)
            if not isinstance(file_ver, int):
                file_ver = 0
            if file_ver < _ZONES_SEED_VERSION:
                added = 0
                # v2→v3: the legacy "Aradjiah" region was a coarse
                # placeholder; BG-wiki classifies these zones into
                # "Adoulin" (city + Rala) and "Ulbuka" (field zones).
                # Remap any unmodified Aradjiah entries to the canonical
                # region they should belong to. Users who edited their
                # zones map to a different value are not touched.
                _aradjiah_remap = {
                    "256": "Adoulin", "257": "Adoulin",
                    "258": "Adoulin", "259": "Adoulin",
                    "281": "Adoulin",
                    "260": "Ulbuka",  "261": "Ulbuka",  "262": "Ulbuka",
                    "263": "Ulbuka",  "264": "Ulbuka",  "265": "Ulbuka",
                    "266": "Ulbuka",  "267": "Ulbuka",  "282": "Ulbuka",
                }
                remapped = 0
                for k, target in _aradjiah_remap.items():
                    if raw.get(k) == "Aradjiah":
                        raw[k] = target
                        remapped += 1
                for k, v in _ZONES_SEED.items():
                    if k in ("_README", "_VERSION"):
                        continue
                    if k not in raw:
                        raw[k] = v
                        added += 1
                # Update README + version, then mark for rewrite below.
                raw["_README"] = _ZONES_SEED["_README"]
                raw["_VERSION"] = _ZONES_SEED_VERSION
                needs_write = True
                _msg = (f"[OmniWatch] zones map upgraded "
                        f"v{file_ver}→v{_ZONES_SEED_VERSION} "
                        f"({added} new entries")
                if remapped:
                    _msg += f", {remapped} Aradjiah→Adoulin/Ulbuka remapped"
                _msg += ")"
                print(_msg)
            else:
                print(f"[OmniWatch] Loaded zones map from {ZONES_FILE}")
    except Exception as e:
        print(f"[OmniWatch] Could not load zones map: {e}. Using seed.")
        raw = dict(_ZONES_SEED)

    if needs_write:
        try:
            with open(ZONES_FILE, "w") as f:
                json.dump(raw, f, indent=2)
        except Exception as e:
            print(f"[OmniWatch] Could not write upgraded zones map: {e}")

    # Convert string keys → int keys. Ignore _README and _VERSION.
    out = {}
    for k, v in raw.items():
        if k in ("_README", "_VERSION") or not isinstance(v, str):
            continue
        try:
            out[int(k)] = v
        except ValueError:
            continue
    return out

_zone_regions = load_zones_config()

def region_for_zone(zone_id):
    """Return the region name for a zone id, or empty string if unmapped."""
    return _zone_regions.get(int(zone_id), "")


# ── Button panel config ──────────────────────────────────────────────────
# 12 user-configurable buttons (6 wide × 2 tall). Each entry:
#   {
#     "label":   string shown on the button. "" hides label, icon-only.
#     "icon":    optional filename inside icons/ui/, e.g. "discord.png".
#                "" or null means no icon (label only).
#     "kind":    "windower" | "shell" | "url" | "file" | "none"
#     "command": the thing to run, semantics depend on kind:
#                  windower → slash-style command without leading "//",
#                             e.g. "send all /follow Wormfood" or
#                             "ow dps reset"
#                  shell    → arbitrary shell command, run with shell=True
#                  url      → http(s) URL opened in default browser
#                  file     → path to a file/program to launch via os.startfile
#                  none     → button is inert (used for placeholders)
#   }
# Ordering is row-major: indices 0–5 = top row, 6–11 = bottom row.
_BUTTONS_DEFAULT = {
    "_README": [
        "OmniWatch button panel: 20 entries (10 wide x 2 tall, row-major).",
        "Indices 0-9 = top row, 10-19 = bottom row.",
        "Each entry has fields: label, icon, kind, command.",
        "kind can be:",
        "  windower - slash command without the leading // (e.g. 'ow dps')",
        "  shell    - arbitrary shell command (any program)",
        "  url      - http(s) URL opened in browser",
        "  file     - path to a file/program launched via OS default",
        "  none     - inert placeholder",
        "icon is a filename inside OmniWatch/icons/ui/ (png or bmp).",
        "Set label to empty string for icon-only buttons.",
        "Edit this file then run //ow buttons reload to apply changes.",
    ],
    "buttons": [
        {"label": "DPS",     "icon": "", "kind": "windower", "command": "ow dps"},
        {"label": "Setup",   "icon": "", "kind": "windower", "command": "ow setup"},
        {"label": "Reset",   "icon": "", "kind": "windower", "command": "ow dps reset"},
        {"label": "Reload",  "icon": "", "kind": "windower", "command": "lua reload omniwatch"},
        {"label": "BG-Wiki", "icon": "", "kind": "url",      "command": "https://www.bg-wiki.com/"},
        {"label": "FFXIAH",  "icon": "", "kind": "url",      "command": "https://www.ffxiah.com/"},
        {"label": "",        "icon": "", "kind": "none",     "command": ""},
        {"label": "",        "icon": "", "kind": "none",     "command": ""},
        {"label": "",        "icon": "", "kind": "none",     "command": ""},
        {"label": "",        "icon": "", "kind": "none",     "command": ""},
        {"label": "",        "icon": "", "kind": "none",     "command": ""},
        {"label": "",        "icon": "", "kind": "none",     "command": ""},
        {"label": "",        "icon": "", "kind": "none",     "command": ""},
        {"label": "",        "icon": "", "kind": "none",     "command": ""},
        {"label": "",        "icon": "", "kind": "none",     "command": ""},
        {"label": "",        "icon": "", "kind": "none",     "command": ""},
        {"label": "",        "icon": "", "kind": "none",     "command": ""},
        {"label": "",        "icon": "", "kind": "none",     "command": ""},
        {"label": "",        "icon": "", "kind": "none",     "command": ""},
        {"label": "",        "icon": "", "kind": "none",     "command": ""},
    ],
}

def _normalize_button_entry(raw):
    """Coerce a single entry dict into the canonical shape, filling
    defaults for missing fields and clamping `kind` to valid values."""
    if not isinstance(raw, dict):
        return {"label": "", "icon": "", "kind": "none", "command": ""}
    kind = str(raw.get("kind", "none")).strip().lower()
    if kind not in ("windower", "shell", "url", "file", "none"):
        kind = "none"
    return {
        "label":   str(raw.get("label",   "") or ""),
        "icon":    str(raw.get("icon",    "") or ""),
        "kind":    kind,
        "command": str(raw.get("command", "") or ""),
    }

def _empty_button():
    return {"label": "", "icon": "", "kind": "none", "command": ""}

def _empty_page(name="Page"):
    return {"name": name, "buttons": [_empty_button() for _ in range(20)]}

# Total number of hotbar pages. Pages beyond what a user has configured
# show as empty slots until they're populated. Set conservatively; can
# be increased later without breaking existing configs.
HOTBAR_PAGE_COUNT = 10

# Active page state. Initialized in load_buttons_config() once pages have
# been resolved. The render/click code reads buttons_config which always
# points at the CURRENT page's buttons list (a live reference, so edits
# propagate back to hotbar_pages[hotbar_current_page]["buttons"]).
hotbar_pages        = []   # list of {name, buttons[20]}
hotbar_current_page = 0    # 0..HOTBAR_PAGE_COUNT-1

def load_buttons_config():
    """Load (or write the default) buttons config. Returns the active
    page's button list (20 entries). Also sets hotbar_pages and
    hotbar_current_page module globals.

    Supports both the legacy single-page format (`{"buttons": [...]}`)
    and the new paged format (`{"pages": [{"name", "buttons":[...]}, ...]}`).
    Old configs are migrated in-memory; the file is rewritten in the new
    format on first save.
    """
    global hotbar_pages, hotbar_current_page
    raw = None
    try:
        if not os.path.exists(BUTTONS_FILE):
            with open(BUTTONS_FILE, "w") as f:
                json.dump(_BUTTONS_DEFAULT, f, indent=2)
            print(f"[OmniWatch] Created default buttons config at "
                  f"{BUTTONS_FILE}")
            raw = _BUTTONS_DEFAULT
        else:
            with open(BUTTONS_FILE) as f:
                raw = json.load(f)
            print(f"[OmniWatch] Loaded buttons config from {BUTTONS_FILE}")
    except Exception as e:
        print(f"[OmniWatch] Could not load buttons config: {e}. "
              f"Using defaults.")
        raw = _BUTTONS_DEFAULT

    pages = []
    if isinstance(raw, dict) and isinstance(raw.get("pages"), list):
        # New paged format. Each entry is {name, buttons:[20]}.
        for p in raw["pages"]:
            if not isinstance(p, dict):
                continue
            entries = p.get("buttons", [])
            if not isinstance(entries, list):
                entries = []
            normalized = [_normalize_button_entry(e) for e in entries[:20]]
            while len(normalized) < 20:
                normalized.append(_empty_button())
            pages.append({
                "name": str(p.get("name", "") or "Page"),
                "buttons": normalized,
            })
    elif isinstance(raw, dict) and isinstance(raw.get("buttons"), list):
        # Legacy single-page format. Migrate: page 1 carries the existing
        # buttons; pages 2..N are empty.
        entries = raw.get("buttons", [])
        normalized = [_normalize_button_entry(e) for e in entries[:20]]
        while len(normalized) < 20:
            normalized.append(_empty_button())
        pages.append({"name": "Page 1", "buttons": normalized})
        print("[OmniWatch] Migrated legacy single-page buttons config "
              "to paged format")

    # Pad up to HOTBAR_PAGE_COUNT.
    while len(pages) < HOTBAR_PAGE_COUNT:
        pages.append(_empty_page(f"Page {len(pages) + 1}"))
    # Truncate if user somehow has more (shouldn't happen normally).
    pages = pages[:HOTBAR_PAGE_COUNT]

    hotbar_pages = pages
    if hotbar_current_page < 0 or hotbar_current_page >= len(hotbar_pages):
        hotbar_current_page = 0
    return hotbar_pages[hotbar_current_page]["buttons"]

buttons_config = load_buttons_config()

def save_buttons_config():
    """Persist hotbar_pages back to omniwatch_buttons.json in the new
    paged format. Errors are logged but don't raise.
    """
    try:
        envelope = {
            "_README": [
                "OmniWatch hotbar config (paged, 10x2 = 20 buttons per page).",
                "",
                "Top-level shape:",
                "  pages: list of {name, buttons[20]} dicts",
                "",
                "Each button entry:",
                "  label   : text shown on the button (short, 1-3 words)",
                "  icon    : optional filename inside icons/ui/ (.png/.bmp)",
                "  kind    : 'windower' | 'shell' | 'url' | 'file' | 'none'",
                "  command : the actual command to run for the chosen kind",
                "",
                "Edit via the in-app editor (right-click any slot, or",
                "Settings -> HotBar -> Edit hotbar). You can also hand-edit",
                "this file; reload via //ow buttons reload.",
            ],
            "pages": hotbar_pages,
        }
        with open(BUTTONS_FILE, "w") as f:
            json.dump(envelope, f, indent=2)
        total = sum(1 for p in hotbar_pages
                    for b in p["buttons"] if b["kind"] != "none")
        print(f"[OmniWatch] saved {len(hotbar_pages)} pages "
              f"({total} active buttons) to {BUTTONS_FILE}")
    except Exception as e:
        print(f"[OmniWatch] could not save buttons config: {e!r}")

def reload_buttons_config():
    """Re-read the buttons config from disk. Called by //ow buttons reload
    so users can iterate on the JSON without restarting the overlay."""
    global buttons_config
    buttons_config = load_buttons_config()
    total = sum(1 for p in hotbar_pages
                for b in p["buttons"] if b["kind"] != "none")
    print(f"[OmniWatch] Reloaded buttons config: "
          f"{total} active across {len(hotbar_pages)} pages")

def _hotbar_set_page(idx):
    """Switch to the given hotbar page index (clamped/wrapped). Updates
    buttons_config to point at the new page's buttons list so existing
    render/click code uses it without modification."""
    global hotbar_current_page, buttons_config
    if not hotbar_pages:
        return
    n = len(hotbar_pages)
    # Wrap so left from page 0 goes to last page, right from last → 0.
    hotbar_current_page = idx % n
    buttons_config = hotbar_pages[hotbar_current_page]["buttons"]

def _hotbar_panel_set_page(panel_idx, page_idx):
    """Set the content page for a specific multi-mode panel. Wraps just
    like _hotbar_set_page. Panel 0 still routes to the global so the
    primary panel and the (hidden) global state stay in sync."""
    if not hotbar_pages:
        return
    n = len(hotbar_pages)
    new_page = page_idx % n
    if panel_idx == 0:
        _hotbar_set_page(new_page)
        hotbar_panel_pages[0] = new_page
    else:
        hotbar_panel_pages[panel_idx] = new_page

def _dispatch_button_on_panel(slot_idx, panel_idx):
    """Run the command for slot_idx on the given panel's current page.
    Looks up the right buttons list rather than relying on the global
    buttons_config (which may be the wrong page in multi-mode)."""
    if not hotbar_pages:
        return
    if panel_idx == 0:
        page_idx = hotbar_panel_pages.get(0, hotbar_current_page)
    else:
        page_idx = hotbar_panel_pages.get(panel_idx, panel_idx)
    if page_idx < 0 or page_idx >= len(hotbar_pages):
        return
    page_buttons = hotbar_pages[page_idx].get("buttons", [])
    if slot_idx < 0 or slot_idx >= len(page_buttons):
        return
    entry = page_buttons[slot_idx]
    if not entry or entry.get("kind") == "none" or not entry.get("command"):
        return
    # Reuse dispatch_button by temporarily swapping buttons_config. The
    # function only reads buttons_config[idx] for the entry, so we save
    # and restore around the call.
    global buttons_config
    saved = buttons_config
    buttons_config = page_buttons
    try:
        dispatch_button(slot_idx)
    finally:
        buttons_config = saved

def dispatch_button(idx):
    """Run the command associated with button index `idx`. Robust to a
    range of failure modes (missing config, bad URLs, shell errors): logs
    and continues, never raises."""
    if idx < 0 or idx >= len(buttons_config):
        return
    entry = buttons_config[idx]
    kind = entry["kind"]
    cmd  = entry["command"]
    label = entry["label"] or f"button {idx}"
    if kind == "none" or not cmd:
        print(f"[OmniWatch] button '{label}' has no command bound; "
              f"ignoring click")
        return
    try:
        if kind == "windower":
            payload = cmd.lstrip("/").strip()
            sock_cmd_out.sendto(payload.encode("utf-8"), CMD_OUT_ADDR)
            print(f"[OmniWatch] button '{label}' -> windower //{payload}")
        elif kind == "url":
            url = cmd if "://" in cmd else "https://" + cmd
            webbrowser.open(url, new=2)
            print(f"[OmniWatch] button '{label}' -> url {url}")
        elif kind == "file":
            if hasattr(os, "startfile"):
                os.startfile(cmd)   # type: ignore[attr-defined]
            else:
                import subprocess
                opener = "open" if sys.platform == "darwin" else "xdg-open"
                subprocess.Popen([opener, cmd])
            print(f"[OmniWatch] button '{label}' -> file {cmd}")
        elif kind == "shell":
            import subprocess
            subprocess.Popen(cmd, shell=True)
            print(f"[OmniWatch] button '{label}' -> shell `{cmd}`")
    except Exception as e:
        print(f"[OmniWatch] button '{label}' ({kind}) failed: {e!r}")

# ── Settings framework ───────────────────────────────────────────────────
# Centralized, schema-driven settings persisted to omniwatch_settings.json.
# Settings are described by SETTINGS_SCHEMA, which drives both the file
# format and the dropdown UI in the header. Each setting is one entry:
#
#   {
#     "key":     unique identifier (string)
#     "label":   human-readable name shown in the dropdown
#     "kind":    "bool" | "int" | "float" | "string" | "enum"
#     "default": default value
#     "min":     (int/float) minimum allowed value
#     "max":     (int/float) maximum allowed value
#     "step":    (int/float) increment for ± buttons
#     "options": (enum) list of valid values
#     "section": grouping label for the dropdown (e.g. "DPS", "Display")
#     "applies": "python" | "lua" | "both" — where the change takes effect
#                "lua" / "both" will send a SETTING|<key>|<value> message
#                to the lua side via the existing port-5005 control socket
#     "help":    optional one-line tooltip / description
#   }
#
# Settings are intentionally additive — adding a new entry to the schema
# does NOT require migrating the JSON file; missing keys fall back to the
# default at load time. Removing or renaming a key leaves the old entry
# in the JSON file ignored (harmless cruft until next manual edit).
# Canonical section order. The dropdown renders sections in this order
# regardless of how many settings each has — so the user sees the full
# organizational structure of Settings even when sections are empty.
# Keep this aligned with the order user specified.
SETTINGS_SECTIONS = [
    "General",
    "Party",
    "Equipment",
    "Statistics",
    "Recast Timer",
    "Buff Timer",
    "Target Card",
    "DPS Tracker",
    "HotBar",
    "Inventory",
    "Developer",
]

SETTINGS_SCHEMA = [
    # ── General ─────────────────────────────────────────────────────
    {
        "key":     "dps_sparkline",
        "label":   "DPS sparkline",
        "kind":    "bool",
        "default": True,
        "section": "DPS Tracker",
        "applies": "python",
        "help":    "Show the DPS trend line behind the headline "
                   "number.",
    },
    {
        "key":     "always_on_top",
        "label":   "Always on top",
        "kind":    "bool",
        "default": False,
        "section": "General",
        "applies": "python",
        "help":    "Pin the OmniWatch window above all other windows. "
                   "Windows only.",
    },
    {
        "key":     "window_opacity",
        "label":   "Window opacity %",
        "kind":    "int",
        "default": 100,
        "min":     20,    # below this, text is unreadable
        "max":     100,
        "step":    5,
        "section": "General",
        "applies": "python",
        "help":    "Make the entire OmniWatch window translucent so "
                   "the game shows through behind it. 100 = solid "
                   "(default); 70 = mostly opaque, slight see-"
                   "through; 50 = noticeably transparent. Below 20% "
                   "is too faint to read so we clamp there. Windows "
                   "only — no effect on macOS/Linux.",
    },
    {
        "key":     "transparent_background",
        "label":   "Transparent background",
        "kind":    "bool",
        "default": False,
        "section": "General",
        "applies": "python",
        "help":    "Punches out the dark background fill so panels "
                   "and text appear floating over the game. Combines "
                   "with Window opacity %: panels dim per the slider "
                   "while empty space goes fully transparent. Windows "
                   "only — no effect on macOS/Linux.",
    },
    {
        "key":     "open_crash_log",
        "label":   "Open log folder",
        "kind":    "button",
        "section": "General",
        "applies": "python",
        "action":  "open_crash_log_folder",
        "help":    "Open the folder containing crash logs and per-"
                   "session log files. Useful when reporting bugs — "
                   "send me the most recent session_*.log.",
    },
    {
        "key":     "reset_zone_timer",
        "label":   "Reset zone timer",
        "kind":    "button",
        "button_text": "RESET",
        "section": "General",
        "applies": "python",
        "action":  "reset_zone_timer",
        "help":    "Reset the header's \"Zone Time\" counter to 0 "
                   "without changing zones. Useful when you want to "
                   "time something that started after you entered "
                   "(e.g. an instance run, a timed gathering session).",
    },
    {
        "key":      "setup_mode",
        "label":    "Setup mode",
        "kind":     "bool",
        # Live-bound: reads/writes the live `setup_mode` global rather
        # than the persistent settings dict. Setup mode shouldn't auto-
        # restore across sessions — flipping it via UDP keeps lock-state
        # changes consistent with //ow setup.
        "live_key": "setup_mode",
        "section":  "General",
        "applies":  "python",
        "help":     "Setup mode lets you drag and resize panels. "
                    "All panels render with mock data so you can "
                    "position them without being in combat. Lock "
                    "follows automatically — exit setup to re-lock.",
    },
    {
        "key":     "vana_time_offset_min",
        "label":   "Adjust Vana'diel time",
        "kind":    "int",
        "default": 0,
        "min":     -1440,    # one full Vana day
        "max":     1440,
        "step":    1,
        "section": "General",
        "applies": "python",
        "help":    "Adjust the in-header Vana'diel clock by N minutes "
                   "if it drifts from the in-game clock. Positive = "
                   "show a later time; negative = earlier. Affects "
                   "the displayed clock only; gear time-windows (e.g. "
                   "NIN feet dusk-to-dawn bonus) always read the live "
                   "game clock and ignore this setting.",
    },

    # ── Party ───────────────────────────────────────────────────────
    {
        "key":     "show_alliance",
        "label":   "Show alliance",
        "kind":    "bool",
        "default": True,
        "section": "Party",
        "applies": "python",
        "help":    "Show alliance party 1 + 2 panels. Off = main "
                   "party only.",
    },
    {
        "key":     "party_show_pets",
        "label":   "Show pets",
        "kind":    "bool",
        "default": True,
        "section": "Party",
        "applies": "python",
        "help":    "Show pet name + HP% in the corner of each party "
                   "member's row when they have a pet (BST jugs, SMN "
                   "avatars, PUP automatons, DRG wyverns, etc.).",
    },
    {
        "key":     "party_show_buffs",
        "label":   "Show buffs",
        "kind":    "bool",
        "default": True,
        "section": "Party",
        "applies": "python",
        "help":    "Show the buffs column on each party member panel.",
    },
    {
        "key":     "party_show_debuffs",
        "label":   "Show debuffs",
        "kind":    "bool",
        "default": True,
        "section": "Party",
        "applies": "python",
        "help":    "Show the debuffs column on each party member panel.",
    },
    {
        "key":     "party_buff_icon_grid",
        "label":   "Compact icon grid",
        "kind":    "bool",
        "default": False,
        "section": "Party",
        "applies": "python",
        "help":    "Render buff/debuff columns as a packed grid of small "
                   "icons (~16px) instead of text labels. Higher density "
                   "for controllers / small panels at the cost of timer "
                   "text. Affects both columns. Buffs without an icon on "
                   "disk yet fall back to the text label.",
    },
    {
        "key":     "edit_buff_blacklist",
        "label":   "Edit buffs / debuffs",
        "kind":    "button",
        "section": "Party",
        "applies": "python",
        "action":  "open_buff_blacklist",
        "help":    "Open omniwatch_buffs.json in your default editor. "
                   "Edit hide_party_buffs / hide_party_debuffs to skip "
                   "specific entries, and the aliases section to "
                   "shorten long names (e.g. \"Tactician's Roll\" → "
                   "\"TAC\").",
    },
    {
        "key":     "specific_buff_names",
        "label":   "Specific buff names (self)",
        "kind":    "bool",
        "default": False,
        "section": "Party",
        "applies": "python",
        "help":    "When on, your own buffs in the party table show the "
                   "specific tier when known (Honor March, Valor Minuet V) "
                   "instead of the generic shared name (March x2, Minuet "
                   "x2). Only applies to your own row — we don't have the "
                   "spell info to disambiguate buffs cast on other party "
                   "members. Off = legacy 'March x2' grouping.",
    },

    # ── Equipment ───────────────────────────────────────────────────
    {
        "key":     "show_equipment",
        "label":   "Show equipment panel",
        "kind":    "bool",
        "default": True,
        "section": "Equipment",
        "applies": "python",
        "help":    "Show the equipment viewer panel.",
    },

    # ── Statistics ──────────────────────────────────────────────────
    {
        "key":     "show_statistics",
        "label":   "Show statistics panel",
        "kind":    "bool",
        "default": True,
        "section": "Statistics",
        "applies": "python",
        "help":    "Show the character statistics panel.",
    },
    {
        "key":     "open_gear_settings",
        "label":   "Gear settings",
        "kind":    "button",
        "button_text": "OPEN",
        "section": "Statistics",
        "applies": "python",
        "action":  "open_gear_settings",
        "help":    "Open the config wizard to set your Song+, Phantom "
                   "Roll+, and Unity Rank values. Same as //ow setup.",
    },

    # ── Recast Timer ────────────────────────────────────────────────
    {
        "key":     "show_recast",
        "label":   "Show recast timer",
        "kind":    "bool",
        "default": True,
        "section": "Recast Timer",
        "applies": "python",
        "help":    "Show the recast timer panel.",
    },
    {
        "key":     "autohide_recast",
        "label":   "Auto-hide when empty",
        "kind":    "bool",
        "default": False,
        "section": "Recast Timer",
        "applies": "python",
        "help":    "Hide the recast panel completely when no abilities "
                   "are on cooldown. The panel reappears as soon as a "
                   "recast starts ticking. Useful to declutter the "
                   "screen between fights.",
    },
    {
        "key":     "edit_recast_blacklist",
        "label":   "Edit list",
        "kind":    "button",
        "section": "Recast Timer",
        "applies": "python",
        "action":  "open_recast_config",
        "help":    "Open omniwatch_recast.json in your default editor. "
                   "Edit the `hide` list to skip specific spells/"
                   "abilities, or the `aliases` section to shorten "
                   "long names. Restart the overlay to apply.",
    },

    # ── Buff Timer ──────────────────────────────────────────────────
    {
        "key":     "show_buff_timer",
        "label":   "Show buff timer",
        "kind":    "bool",
        "default": True,
        "section": "Buff Timer",
        "applies": "python",
        "help":    "Show the buff timer (countdown bars) panel.",
    },
    {
        "key":     "autohide_buff_timer",
        "label":   "Auto-hide when empty",
        "kind":    "bool",
        "default": False,
        "section": "Buff Timer",
        "applies": "python",
        "help":    "Hide the buff timer panel completely when no "
                   "tracked buffs are active. The panel reappears as "
                   "soon as a tracked buff is gained. Useful to "
                   "declutter the screen out of combat.",
    },
    {
        "key":     "edit_buff_timer_blacklist",
        "label":   "Edit list",
        "kind":    "button",
        "section": "Buff Timer",
        "applies": "python",
        "action":  "open_buff_timer_config",
        "help":    "Open omniwatch_buff_timer.json in your default editor. "
                   "Edit the `hide` list to skip specific buffs, or the "
                   "`aliases` section to shorten long names. Restart the "
                   "overlay to apply.",
    },

    # ── Target Card ─────────────────────────────────────────────────
    {
        "key":     "show_target",
        "label":   "Show main target",
        "kind":    "bool",
        "default": True,
        "section": "Target Card",
        "applies": "python",
        "help":    "Show the target card for your current main target.",
    },
    {
        "key":     "show_subtarget",
        "label":   "Show sub-target",
        "kind":    "bool",
        "default": True,
        "section": "Target Card",
        "applies": "python",
        "help":    "Show a second target card for your sub-target "
                   "(<st>) when one is active.",
    },
    {
        "key":     "target_show_buffs",
        "label":   "Main: show buffs / debuffs",
        "kind":    "bool",
        "default": True,
        "section": "Target Card",
        "applies": "python",
        "help":    "Show the main target's active buffs and debuffs "
                   "sections. Off = hide both.",
    },
    {
        "key":     "subtarget_show_buffs",
        "label":   "Sub: show buffs / debuffs",
        "kind":    "bool",
        "default": True,
        "section": "Target Card",
        "applies": "python",
        "help":    "Show the sub-target's active buffs and debuffs "
                   "sections. Off = hide both.",
    },

    # ── DPS Tracker ─────────────────────────────────────────────────
    {
        "key":     "show_dps",
        "label":   "Show DPS panel",
        "kind":    "bool",
        "default": True,
        "section": "DPS Tracker",
        "applies": "python",
        "help":    "Show the DPS tracker panel.",
    },
    {
        "key":     "dps_window_seconds",
        "label":   "Capture time",
        "kind":    "enum",
        # Stored as seconds (what lua expects on the wire); displayed
        # via option_labels so the dropdown reads naturally. The
        # special value 0 means "Encounter mode" — track each fight
        # as its own session, reset between mobs, log on death.
        "options":       [0,           300,      600,       1800,      3600],
        "option_labels": ["Encounter", "5 min",  "10 min",  "30 min",  "60 min"],
        "default": 300,
        "section": "DPS Tracker",
        "applies": "lua",
        "help":    "Time-window or per-encounter tracking. 'Encounter' "
                   "logs each fight separately (mob name, dps, durations) "
                   "until you change the setting. Time-window options "
                   "show a rolling average over the chosen interval.",
    },
    {
        "key":     "dps_track_party",
        "label":   "Track party damage",
        "kind":    "bool",
        "default": True,
        "section": "DPS Tracker",
        "applies": "lua",
        "help":    "Include party members and their pets in the DPS "
                   "tracker. Off = your damage only.",
    },
    {
        "key":     "open_dps_log_csv",
        "label":   "Open CSV log",
        "kind":    "button",
        "section": "DPS Tracker",
        "applies": "python",
        "action":  "open_dps_log_csv",
        "help":    "Open omniwatch_dps_log.csv (one summary row per "
                   "encounter, spreadsheet-friendly).",
    },
    {
        "key":     "open_dps_log_json",
        "label":   "Open JSON log",
        "kind":    "button",
        "section": "DPS Tracker",
        "applies": "python",
        "action":  "open_dps_log_json",
        "help":    "Open omniwatch_dps_log.jsonl (full detail per "
                   "encounter, JSON Lines format).",
    },

    # ── HotBar ──────────────────────────────────────────────────────
    {
        "key":     "show_hotbar",
        "label":   "Show hotbar",
        "kind":    "bool",
        "default": True,
        "section": "HotBar",
        "applies": "python",
        "help":    "Show the user-button hotbar panel.",
    },
    {
        "key":     "hotbar_visible_count",
        "label":   "Hotbars shown",
        "kind":    "int",
        "default": 1,
        "min":     1,
        "max":     10,
        "step":    1,
        "section": "HotBar",
        "applies": "python",
        "help":    "How many hotbar pages to display at once. 1 = the "
                   "classic single panel with </> arrows for switching "
                   "between pages. 2-10 = that many pages render as "
                   "individual draggable panels (page 0, page 1, ... in "
                   "order). The </> arrows hide when more than one is "
                   "visible since each panel is locked to its own page.",
    },
    {
        "key":     "edit_hotbar",
        "label":   "Edit hotbar",
        "kind":    "button",
        "button_text": "GO",
        "section": "HotBar",
        "applies": "python",
        "action":  "open_hotbar_editor",
        "help":    "Enter hotbar edit mode. Click any slot to edit "
                   "its label, kind, command, and icon.",
    },

    # ── Inventory ────────────────────────────────────────────────────
    {
        "key":     "show_inventory_button",
        "label":   "Show 'Bags' button",
        "kind":    "bool",
        "default": True,
        "section": "Inventory",
        "applies": "python",
        "help":    "Show the 'Bags' dropdown button in the header next "
                   "to your gil. Lists every bag's contents with one-"
                   "click links to BG-Wiki for each item.",
    },
    {
        "key":     "gearswap_folder",
        "label":   "Gearswap folder",
        "kind":    "button",
        "button_text": "PICK",
        "section": "Inventory",
        "applies": "python",
        "action":  "pick_gearswap_folder",
        "help":    "Folder containing your GearSwap .lua files. Items "
                   "referenced in any of those files get a check mark "
                   "in the inventory dropdown. Path is saved to "
                   "omniwatch_gearswap_path.json next to other configs.",
    },
    # ── Developer ───────────────────────────────────────────────────
    {
        "key":     "sim_mode",
        "label":   "Simulation mode",
        "kind":    "bool",
        "default": False,
        "section": "Developer",
        "applies": "python",
        "help":    "Override OmniWatch's stat compute with synthetic "
                   "inputs (job, sub, merits, JP, gifts). Used to test "
                   "math against known-good scenarios. Toggling on "
                   "opens a floating window where you fill in inputs; "
                   "toggling off closes the window and restores real "
                   "game data. Requires simulation/OmniWatch_Sim.lua "
                   "to be present in the addon folder.",
    },

    # NOTE: panel visibility (show_dps_panel, show_buttons_panel) and
    # panels_locked are intentionally NOT in this schema — they're
    # owned by the layout file (omniwatch_layout.json) which already
    # persists them via save_layout()/load_layout(). Eventually that
    # file may merge into this one, but for now we leave them out so
    # the two systems don't fight over the same globals.
]

# Index by key for O(1) lookups.
SETTINGS_BY_KEY = {s["key"]: s for s in SETTINGS_SCHEMA}

def _coerce_setting(schema, raw):
    """Coerce `raw` into the right type for `schema`, clamping to the
    declared range / valid options. Returns the schema's default on
    type errors so a malformed JSON can't crash the loader."""
    kind = schema["kind"]
    # Buttons aren't values — they're action triggers. Nothing to coerce.
    if kind == "button":
        return None
    try:
        if kind == "bool":
            if isinstance(raw, bool):
                return raw
            if isinstance(raw, (int, float)):
                return bool(raw)
            if isinstance(raw, str):
                return raw.strip().lower() in ("true", "1", "yes", "on")
            return bool(schema["default"])
        if kind == "int":
            v = int(raw)
            if "min" in schema:
                v = max(schema["min"], v)
            if "max" in schema:
                v = min(schema["max"], v)
            return v
        if kind == "float":
            v = float(raw)
            if "min" in schema:
                v = max(schema["min"], v)
            if "max" in schema:
                v = min(schema["max"], v)
            return v
        if kind == "string":
            return str(raw)
        if kind == "enum":
            options = schema.get("options", [])
            # Normalise int-from-json: enum option might be the int 300
            # but raw might be the string "300". Coerce raw to match.
            if options and isinstance(options[0], int):
                try:
                    raw = int(raw)
                except (ValueError, TypeError):
                    pass
            if raw in options:
                return raw
            return schema["default"]
    except (ValueError, TypeError):
        pass
    return schema["default"]

def load_settings():
    """Load (or write the default) settings JSON. Returns dict
    keyed by setting key. Missing keys fall back to the schema
    default — this means adding a new setting is an additive
    schema change, no migration needed.

    Excluded from the persistent dict:
      - Button-kind entries (they're action triggers, no value)
      - live_key bools (they read/write a module global directly,
        not the persistent settings — e.g. setup_mode)
    """
    def _persistable(s):
        if s["kind"] == "button":
            return False
        if s.get("live_key"):
            return False
        return True

    out = {s["key"]: s["default"] for s in SETTINGS_SCHEMA
           if _persistable(s)}
    try:
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE) as f:
                raw = json.load(f)
            if not isinstance(raw, dict):
                raw = {}
            for key, schema in SETTINGS_BY_KEY.items():
                if not _persistable(schema):
                    continue
                if key in raw:
                    out[key] = _coerce_setting(schema, raw[key])
            print(f"[OmniWatch] Loaded settings from {SETTINGS_FILE}")
        else:
            with open(SETTINGS_FILE, "w") as f:
                json.dump(out, f, indent=2)
            print(f"[OmniWatch] Created default settings at "
                  f"{SETTINGS_FILE}")
    except Exception as e:
        print(f"[OmniWatch] Could not load settings: {e}. "
              f"Using defaults.")
    return out

# Live settings dict. Read via setting(key); write via set_setting(key,
# value) — the latter handles persistence and side effects.
settings = load_settings()

# Load augment nicknames (cross-character, USER_DIR-scoped).
_load_aug_nicknames()

def setting(key):
    """Return the current value of the named setting, or its schema
    default if the key isn't recognised (defensive — protects against
    typos elsewhere in the code).

    Returns None for button-kind entries (they're action triggers, not
    values) and for any schema that lacks a default."""
    if key in settings:
        return settings[key]
    s = SETTINGS_BY_KEY.get(key)
    if not s:
        return None
    if s.get("kind") == "button":
        return None
    return s.get("default")

def save_settings():
    """Write the current settings dict back to disk."""
    try:
        with open(SETTINGS_FILE, "w") as f:
            json.dump(settings, f, indent=2)
    except Exception as e:
        print(f"[OmniWatch] Could not save settings: {e}")

def set_setting(key, value):
    """Update a setting's value, persist to disk, and dispatch any
    side effects declared by the schema. Returns the coerced value
    that was actually stored."""
    schema = SETTINGS_BY_KEY.get(key)
    if not schema:
        print(f"[OmniWatch] set_setting: unknown key {key!r}")
        return None
    coerced = _coerce_setting(schema, value)
    settings[key] = coerced
    save_settings()
    apply_setting_side_effects(key, coerced)
    return coerced

def dispatch_setting_action(key):
    """Run a button-kind setting's action. Looks up the action name in
    the schema and routes to the matching handler. Each action is just
    a python function; add new ones below as new buttons are needed."""
    schema = SETTINGS_BY_KEY.get(key)
    if not schema or schema.get("kind") != "button":
        print(f"[OmniWatch] dispatch_setting_action: not a button: {key!r}")
        return
    action = schema.get("action")
    handler = _SETTINGS_ACTIONS.get(action)
    if handler is None:
        print(f"[OmniWatch] no handler for setting action {action!r}")
        return
    try:
        handler()
    except Exception as e:
        print(f"[OmniWatch] action {action!r} failed: {e!r}")

def _open_path(path, label="file"):
    """Open `path` in the OS default handler (Notepad for .json on
    Windows, etc.). Catches and logs any failure so the action button
    never raises. Used by all the 'Edit X' / 'Open X log' buttons."""
    try:
        if hasattr(os, "startfile"):
            os.startfile(path)         # type: ignore[attr-defined]
        else:
            import subprocess
            opener = "open" if sys.platform == "darwin" else "xdg-open"
            subprocess.Popen([opener, path])
        print(f"[OmniWatch] opened {label}: {path}")
    except Exception as e:
        print(f"[OmniWatch] could not open {path}: {e!r}")

def _open_buff_config_in_editor():
    """Open omniwatch_buffs.json (party-panel buff/debuff blacklists +
    aliases). Re-creates from template if missing so opening always
    succeeds."""
    if not os.path.exists(BUFF_CFG):
        try:
            with open(BUFF_CFG, "w") as f:
                json.dump(_BUFF_CFG_TEMPLATE, f, indent=2)
        except Exception as e:
            print(f"[OmniWatch] could not create buff config: {e!r}")
            return
    _open_path(BUFF_CFG, "buff config")

def _open_buff_timer_config_in_editor():
    """Open omniwatch_buff_timer.json."""
    if not os.path.exists(BUFF_TIMER_CFG):
        try:
            with open(BUFF_TIMER_CFG, "w") as f:
                json.dump(_BUFF_TIMER_CFG_TEMPLATE, f, indent=2)
        except Exception as e:
            print(f"[OmniWatch] could not create buff timer config: {e!r}")
            return
    _open_path(BUFF_TIMER_CFG, "buff timer config")

def _open_recast_config_in_editor():
    """Open omniwatch_recast.json."""
    if not os.path.exists(RECAST_TIMER_CFG):
        try:
            with open(RECAST_TIMER_CFG, "w") as f:
                json.dump(_RECAST_TIMER_CFG_TEMPLATE, f, indent=2)
        except Exception as e:
            print(f"[OmniWatch] could not create recast config: {e!r}")
            return
    _open_path(RECAST_TIMER_CFG, "recast config")

def _open_dps_log_csv():
    """Open the DPS encounter CSV log. Creates an empty file with
    header on first open so Notepad has something to show."""
    if not os.path.exists(DPS_LOG_CSV):
        try:
            with open(DPS_LOG_CSV, "w", encoding="utf-8") as f:
                f.write("(no encounters logged yet — "
                        "enable encounter logging in DPS settings)\n")
        except Exception as e:
            print(f"[OmniWatch] could not create CSV log: {e!r}")
            return
    _open_path(DPS_LOG_CSV, "DPS CSV log")

def _open_dps_log_json():
    """Open the DPS encounter JSON Lines log."""
    if not os.path.exists(DPS_LOG_JSON):
        try:
            with open(DPS_LOG_JSON, "w", encoding="utf-8") as f:
                f.write("")
        except Exception as e:
            print(f"[OmniWatch] could not create JSON log: {e!r}")
            return
    _open_path(DPS_LOG_JSON, "DPS JSON log")

def _open_crash_log_folder():
    """Open the folder containing OmniWatch's crash logs."""
    # _resolved_log_dir is set during startup (see USER_DIR/logs).
    # Fall back to USER_DIR if for some reason it wasn't resolved.
    folder = globals().get("_resolved_log_dir") or os.path.join(
        USER_DIR, "logs")
    if not os.path.isdir(folder):
        try:
            os.makedirs(folder, exist_ok=True)
        except Exception as e:
            print(f"[OmniWatch] could not create crash log dir: {e!r}")
            return
    _open_path(folder, "crash log folder")

def _apply_always_on_top(enabled):
    """Pin (or unpin) the OmniWatch window above all other windows.

    Windows-only via ctypes SetWindowPos. The HWND is obtained from
    pygame's display info — we look up "window" first (modern SDL2)
    and fall back to "wmInfo.window" if needed. Failures are logged
    and ignored so the toggle never crashes.

    enabled=True  → HWND_TOPMOST  (-1) : window stays above all others
    enabled=False → HWND_NOTOPMOST (-2) : window returns to normal z-order

    Caveat: if FFXI is running in fullscreen-exclusive mode (not
    windowed or borderless windowed), no Windows topmost flag will
    show our overlay above it — that's a Direct3D z-layer that
    bypasses normal window ordering. Switch FFXI to "Windowed" or
    "Borderless windowed" mode for this to work.
    """
    if sys.platform != "win32":
        # No-op on non-Windows. We don't fight cross-platform support.
        return
    try:
        import ctypes
        from ctypes import wintypes
        # Get pygame's window HWND. The wm_info dict layout varies across
        # pygame versions — try the modern key first.
        info = pygame.display.get_wm_info()
        hwnd = info.get("window") or info.get("hwnd") or 0
        if not hwnd:
            print("[OmniWatch] always-on-top: could not get HWND")
            return

        # SetWindowPos(hwnd, hWndInsertAfter, X, Y, cx, cy, uFlags).
        # We declare argtypes/restype explicitly because the default
        # ctypes signature uses c_int for HWND, which silently
        # truncates 64-bit handles and the call lands on the wrong
        # window. wintypes.HWND is c_void_p which handles either.
        SetWindowPos = ctypes.windll.user32.SetWindowPos
        SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND,
                                 ctypes.c_int, ctypes.c_int,
                                 ctypes.c_int, ctypes.c_int,
                                 wintypes.UINT]
        SetWindowPos.restype = wintypes.BOOL
        # SWP_NOMOVE | SWP_NOSIZE so X/Y/cx/cy are ignored — we ONLY
        # want to change the z-order. SWP_NOACTIVATE prevents focus
        # theft when toggling.
        HWND_TOPMOST   = -1
        HWND_NOTOPMOST = -2
        SWP_NOMOVE = 0x0002
        SWP_NOSIZE = 0x0001
        SWP_NOACTIVATE = 0x0010
        target = HWND_TOPMOST if enabled else HWND_NOTOPMOST
        flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
        ok = SetWindowPos(wintypes.HWND(hwnd),
                          wintypes.HWND(target),
                          0, 0, 0, 0, flags)
        if not ok:
            err = ctypes.get_last_error()
            print(f"[OmniWatch] always-on-top: SetWindowPos returned 0 "
                  f"(GetLastError={err}) — HWND={hwnd!r}")
            return
        print(f"[OmniWatch] always-on-top → "
              f"{'ON' if enabled else 'OFF'} (hwnd={hwnd})")
    except Exception as e:
        print(f"[OmniWatch] always-on-top toggle failed: {e!r}")


def _apply_window_opacity(percent):
    """Set the OmniWatch window's whole-window alpha.

    Windows API: a window with the WS_EX_LAYERED bit can have its
    overall opacity controlled by SetLayeredWindowAttributes. We set
    the LWA_ALPHA flag and pass an alpha byte (0-255) computed from
    the user-facing percentage. 100% → 255 (solid), 50% → 127, etc.

    Below ~20% the window is essentially unreadable, so the schema
    clamps `min=20`. We also clamp here defensively in case a manual
    settings.json edit slips a smaller number through.

    Windows-only. macOS/Linux pygame doesn't expose this and we just
    no-op there. Errors are logged and swallowed so a transient
    Windows API hiccup never crashes the app — opacity is cosmetic."""
    if sys.platform != "win32":
        return
    try:
        import ctypes
        from ctypes import wintypes
        info = pygame.display.get_wm_info()
        hwnd = info.get("window") or info.get("hwnd") or 0
        if not hwnd:
            print("[OmniWatch] window-opacity: could not get HWND")
            return

        # Clamp + map percent → byte. 100 → 255, 0 → 0.
        try:
            p = int(percent)
        except (TypeError, ValueError):
            p = 100
        p = max(20, min(100, p))
        alpha = int(round(p * 255 / 100))

        # WS_EX_LAYERED must be set on the window before alpha calls
        # are honored. OR-ing it in is idempotent so calling
        # repeatedly is harmless.
        GWL_EXSTYLE       = -20
        WS_EX_LAYERED     = 0x00080000
        LWA_ALPHA         = 0x00000002

        user32 = ctypes.windll.user32
        # SetWindowLongPtr is the 64-bit-safe variant; SetWindowLongW
        # is the 32-bit one. Prefer Ptr, fall back if missing.
        get_long = getattr(user32, "GetWindowLongPtrW",
                           user32.GetWindowLongW)
        set_long = getattr(user32, "SetWindowLongPtrW",
                           user32.SetWindowLongW)
        cur_style = get_long(hwnd, GWL_EXSTYLE)
        if not (cur_style & WS_EX_LAYERED):
            set_long(hwnd, GWL_EXSTYLE, cur_style | WS_EX_LAYERED)

        # SetLayeredWindowAttributes(hwnd, color_key, alpha, flags)
        # color_key is unused when LWA_ALPHA is the only flag.
        result = user32.SetLayeredWindowAttributes(
            wintypes.HWND(hwnd), 0, alpha, LWA_ALPHA)
        if not result:
            err = ctypes.get_last_error()
            print(f"[OmniWatch] window-opacity: SetLayeredWindowAttributes "
                  f"returned 0 (GetLastError={err})")
            return

        print(f"[OmniWatch] window opacity → {p}%")
    except Exception as e:
        print(f"[OmniWatch] window-opacity apply failed: {e!r}")


def _apply_transparent_background(on):
    """Punch out the OmniWatch background color so the desktop/game
    shows through underneath the panels and text.

    Uses Windows' LWA_COLORKEY layered-window attribute: any pixel
    matching the key color renders as fully transparent at the
    compositor level. Since our background is `COL_BG` (a near-black
    fill) and panels/text use distinct colors, only the empty space
    between panels gets punched out — text and panel chrome stay
    fully visible.

    This composes cleanly with the existing window_opacity slider:
    LWA_ALPHA dims the whole window uniformly; LWA_COLORKEY removes
    one specific color entirely. Setting both flags together (which
    we do when both are active) gives "background invisible, panels
    at user-chosen opacity".

    Windows-only. macOS/Linux: no-op (and there's nothing to
    promise — pygame doesn't expose the equivalent there).

    Note on caveats: any panel that happens to use a color exactly
    equal to COL_BG would also become transparent. COL_BG = (15,15,20)
    — close enough to pure black that no real text/panel uses it,
    so this is safe in practice."""
    if sys.platform != "win32":
        return
    try:
        import ctypes
        from ctypes import wintypes
        info = pygame.display.get_wm_info()
        hwnd = info.get("window") or info.get("hwnd") or 0
        if not hwnd:
            print("[OmniWatch] transparent-bg: could not get HWND")
            return

        GWL_EXSTYLE       = -20
        WS_EX_LAYERED     = 0x00080000
        LWA_ALPHA         = 0x00000002
        LWA_COLORKEY      = 0x00000001

        # Build the COLORREF for COL_BG. Windows expects 0x00BBGGRR
        # (note the byte order is reversed from RGB).
        r, g, b = COL_BG[0], COL_BG[1], COL_BG[2]
        colorkey = (b << 16) | (g << 8) | r

        user32 = ctypes.windll.user32
        get_long = getattr(user32, "GetWindowLongPtrW",
                           user32.GetWindowLongW)
        set_long = getattr(user32, "SetWindowLongPtrW",
                           user32.SetWindowLongW)
        cur_style = get_long(hwnd, GWL_EXSTYLE)
        if not (cur_style & WS_EX_LAYERED):
            set_long(hwnd, GWL_EXSTYLE, cur_style | WS_EX_LAYERED)

        # When ON: combine COLORKEY (background invisible) with the
        # current window-opacity ALPHA (panels at user's chosen %).
        # When OFF: re-apply just ALPHA at the current opacity to
        # clear the colorkey bit.
        cur_pct = setting("window_opacity") if "setting" in globals() else 100
        try:    p = int(cur_pct)
        except: p = 100
        p = max(20, min(100, p))
        alpha = int(round(p * 255 / 100))

        if on:
            flags = LWA_ALPHA | LWA_COLORKEY
        else:
            flags = LWA_ALPHA
            colorkey = 0    # cleared

        result = user32.SetLayeredWindowAttributes(
            wintypes.HWND(hwnd), colorkey, alpha, flags)
        if not result:
            err = ctypes.get_last_error()
            print(f"[OmniWatch] transparent-bg: "
                  f"SetLayeredWindowAttributes returned 0 "
                  f"(GetLastError={err})")
            return

        print(f"[OmniWatch] transparent background → {bool(on)}")
    except Exception as e:
        print(f"[OmniWatch] transparent-bg apply failed: {e!r}")


def _toggle_setup_mode():
    """Flip setup mode on/off. Setup mode shows resize grips, mock
    data in panels, and unlocks dragging — used to position panels.

    Implementation: rather than duplicate the inline SETUP handler in
    the gearswap drain (which closes over multiple globals like
    panels_locked, recast_anchor, buff_anchor and re-asserts panel
    positions on toggle), we send a UDP packet to our own port-5005
    socket with `SETUP|toggle`. The drain loop picks it up next frame
    and runs through the canonical handler. Single source of truth,
    one less place to keep in sync."""
    try:
        _s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            _s.sendto(b"SETUP|toggle", ("127.0.0.1", 5005))
        finally:
            _s.close()
        print("[OmniWatch] setup mode toggle requested via settings")
    except Exception as e:
        print(f"[OmniWatch] setup mode toggle failed: {e!r}")

def _restart_overlay():
    """Spawn a fresh copy of OmniWatch and exit the current process.

    Detection: when frozen by PyInstaller (the typical user runs
    OmniWatch.exe), sys.executable IS the exe — relaunching it gives
    us the same overlay. When running from source (python omniwatch.py),
    sys.executable is the python interpreter and sys.argv[0] is the
    script path — relaunching needs both.

    The spawned process must be detached so our own exit doesn't drag
    it down. On Windows that means DETACHED_PROCESS + a new process
    group; close_fds keeps it from inheriting our open sockets.
    """
    import subprocess
    try:
        if getattr(sys, "frozen", False):
            # PyInstaller: sys.executable is the .exe, no script needed.
            cmd = [sys.executable]
        else:
            # Source mode: python interpreter + script path + any args.
            cmd = [sys.executable, *sys.argv]

        # Windows-specific flags so the new process is fully detached.
        # On other platforms we rely on close_fds + stdin/out/err
        # devnulled so the child won't be killed when the parent exits.
        kwargs = {"close_fds": True}
        if sys.platform == "win32":
            DETACHED_PROCESS = 0x00000008
            CREATE_NEW_PROCESS_GROUP = 0x00000200
            kwargs["creationflags"] = (DETACHED_PROCESS
                                        | CREATE_NEW_PROCESS_GROUP)
        else:
            kwargs["start_new_session"] = True

        # Devnull stdin/out/err so the child doesn't share our console.
        # Without this, killing the parent's console kills the child too.
        with open(os.devnull, "rb") as devnull_in, \
             open(os.devnull, "wb") as devnull_out:
            subprocess.Popen(
                cmd,
                stdin=devnull_in,
                stdout=devnull_out,
                stderr=devnull_out,
                **kwargs,
            )

        print(f"[OmniWatch] restarting: {cmd}")
        # Give the OS a beat to actually launch the new process before
        # we tear down. Without this the new exe occasionally fails to
        # acquire the UDP ports because we still hold them.
        time.sleep(0.3)

        # Clean shutdown — pygame.quit + sys.exit. The main loop will
        # see SystemExit and unwind naturally.
        try:
            pygame.quit()
        except Exception:
            pass
        sys.exit(0)
    except SystemExit:
        raise
    except Exception as e:
        print(f"[OmniWatch] restart failed: {e!r}")

def _load_gearswap_path():
    """Read the saved GearSwap folder path from disk. Returns the
    string path, or "" if no file exists or the file is malformed.
    Tolerant of missing-file and JSON-decode errors so a corrupted
    config can't crash startup."""
    try:
        if os.path.exists(GEARSWAP_PATH_FILE):
            with open(GEARSWAP_PATH_FILE) as f:
                data = json.load(f)
            if isinstance(data, dict):
                p = data.get("path", "")
                return p if isinstance(p, str) else ""
    except Exception as e:
        print(f"[OmniWatch] gearswap path load error: {e!r}")
    return ""


def _save_gearswap_path(path):
    """Write the GearSwap folder path to disk. Empty string means
    'no folder configured'."""
    global gearswap_folder_path
    gearswap_folder_path = path or ""
    try:
        with open(GEARSWAP_PATH_FILE, "w") as f:
            json.dump({"path": gearswap_folder_path}, f, indent=2)
    except Exception as e:
        print(f"[OmniWatch] gearswap path save error: {e!r}")


# In-memory snapshot: { lowercase_item_name: True } for any item name
# referenced anywhere across the user's GearSwap files. Rebuilt by
# _refresh_gearswap_index. Lookup is by lowercase name so we can
# match case-insensitively against the inventory dropdown's item names.
gearswap_referenced_items = {}
gearswap_folder_path      = ""


def _refresh_gearswap_index():
    """Scan every .lua file in gearswap_folder_path (non-recursive),
    extract any quoted strings that look like item references, and
    populate gearswap_referenced_items. Called when:
      - python starts (initial load)
      - user picks a new folder via the settings dropdown
      - user clears the folder

    The scanner is intentionally permissive: it strips line-comments
    and block-comments, then captures every double-or-single-quoted
    string. A string is treated as an "item reference" if it doesn't
    contain typical non-item chars (slashes, equals, semicolons). This
    catches both bare-name references like
        head="Telos Earring"
    and quoted-table references like
        head={ name="Carmine Mask +1", augments={...} }
    while ignoring file paths and comments. False positives are
    harmless — a checkmark on something that wasn't actually used
    only confuses if it matches a real item name.

    Also picks up `gear.X = "Item Name"` indirection so items
    referenced via gear-table aliases get marked too.

    On any I/O error, the previous index stays in place. We don't
    block on this — if the folder is huge or unreachable, we'll just
    have stale data, not a crash.
    """
    global gearswap_referenced_items
    if not gearswap_folder_path:
        gearswap_referenced_items = {}
        print("[OmniWatch] gearswap index cleared (no folder set)")
        return
    if not os.path.isdir(gearswap_folder_path):
        gearswap_referenced_items = {}
        print(f"[OmniWatch] gearswap folder not found: "
              f"{gearswap_folder_path}")
        return

    new_index = {}
    file_count = 0
    try:
        for fn in os.listdir(gearswap_folder_path):
            if not fn.lower().endswith(".lua"):
                continue
            full = os.path.join(gearswap_folder_path, fn)
            try:
                with open(full, "r", encoding="utf-8",
                          errors="replace") as f:
                    src = f.read()
            except Exception as e:
                print(f"[OmniWatch] gearswap read failed for "
                      f"{fn}: {e!r}")
                continue
            file_count += 1
            # Strip block comments first (--[[ ... ]]), then line
            # comments (-- to EOL). Both can hide gear refs that we
            # would otherwise count.
            src = re.sub(r"--\[\[.*?\]\]", "", src, flags=re.DOTALL)
            src = re.sub(r"--[^\n]*", "", src)
            # Capture every quoted string. Match both " and ' forms.
            # Pattern allows escaped quotes inside a string but
            # gearswap rarely uses them.
            for m in re.finditer(r'"([^"\n]{1,80})"|\'([^\'\n]{1,80})\'',
                                 src):
                s = m.group(1) or m.group(2) or ""
                if not s:
                    continue
                # Reject strings that look like file paths, URLs, or
                # config keywords rather than item names.
                if "/" in s or "\\" in s or "=" in s or ";" in s:
                    continue
                if s.startswith("//") or s.startswith("http"):
                    continue
                # Item names are typically 2-50 chars, alphanumeric
                # plus space/apostrophe/plus/dash/period/parens.
                if len(s) < 2 or len(s) > 50:
                    continue
                new_index[s.lower()] = True
    except Exception as e:
        print(f"[OmniWatch] gearswap scan error: {e!r}")
        return

    gearswap_referenced_items = new_index
    print(f"[OmniWatch] gearswap index built: "
          f"{len(new_index)} item names across {file_count} .lua files "
          f"in {gearswap_folder_path}")


def _pick_gearswap_folder():
    """Open a native OS folder picker so the user can point at their
    GearSwap data folder (one level deep — we scan all .lua files in
    it). Path is saved to omniwatch_gearswap_path.json so it persists
    across sessions, separate from the regular settings dict (which
    only tolerates schema-listed scalar values)."""
    try:
        import tkinter as tk
        from tkinter import filedialog
        root = tk.Tk()
        root.withdraw()
        try:
            root.attributes("-topmost", True)
        except Exception:
            pass
        path = filedialog.askdirectory(
            parent=root,
            title="Pick the folder containing your GearSwap .lua files",
        )
        try:
            root.destroy()
        except Exception:
            pass
        if path:
            _save_gearswap_path(path)
            print(f"[OmniWatch] gearswap folder set to: {path}")
            _refresh_gearswap_index()
        else:
            print("[OmniWatch] gearswap folder pick cancelled")
    except Exception as e:
        print(f"[OmniWatch] folder picker failed: {e!r}")


def _clear_gearswap_folder():
    """Forget the saved gearswap folder path."""
    _save_gearswap_path("")
    print("[OmniWatch] gearswap folder cleared")
    _refresh_gearswap_index()


def _open_hotbar_editor():
    """Enter hotbar edit mode. Closes the Settings dropdown so the user
    can see the hotbar (which is what they're editing). Doesn't pre-
    select a slot — user picks one by clicking on the hotbar."""
    global hotbar_edit_mode, hotbar_edit_slot, hotbar_edit_draft
    global settings_menu_open, hotbar_focused_field
    global hotbar_icon_picker_open
    hotbar_edit_mode = True
    hotbar_edit_slot = -1
    hotbar_edit_draft = None
    hotbar_focused_field = None
    hotbar_icon_picker_open = False
    settings_menu_open = False        # close the dropdown so the hotbar's visible
    _refresh_ui_icon_listing()        # rescan icons/ui/ on every entry
    print("[OmniWatch] hotbar editor opened — click a slot to edit it")

# Action registry. Each button-kind entry's "action" string keys into
# this dict to find its handler. Notepad can't jump to a specific line,
# so the buttons that target sub-sections of the same JSON file all
def _reset_zone_timer():
    """Reset the header's "Zone Time" counter to 0 without changing
    zones. Useful for timing something starting from now (e.g. an
    instance run that started after you entered the zone). Display
    only — doesn't affect any other state."""
    global zone_entered_at
    zone_entered_at = time.time()
    print("[OmniWatch] zone timer reset")


def _open_gear_settings():
    """Open the config wizard modal (Song+ / Phantom Roll+ values).
    Same flow as the //ow setup chat command: ask Lua to send back
    the current config state via CFGWIZ|open|<flat-fields>, which
    flips cfgwiz_visible on. Closes the settings menu in the process
    so the modal isn't fighting it for attention."""
    global settings_menu_open
    settings_menu_open = False
    _cfgwiz_send("CFGWIZ|request_open")
    print("[OmniWatch] gear settings wizard requested")


# point at the same opener — the file's _README explains the layout.
_SETTINGS_ACTIONS = {
    "open_buff_blacklist":     _open_buff_config_in_editor,
    "open_buff_timer_config":  _open_buff_timer_config_in_editor,
    "open_recast_config":      _open_recast_config_in_editor,
    "open_dps_log_csv":        _open_dps_log_csv,
    "open_dps_log_json":       _open_dps_log_json,
    "open_crash_log_folder":   _open_crash_log_folder,
    "restart_overlay":         _restart_overlay,
    "toggle_setup_mode":       _toggle_setup_mode,
    "open_hotbar_editor":      _open_hotbar_editor,
    "pick_gearswap_folder":    _pick_gearswap_folder,
    "clear_gearswap_folder":   _clear_gearswap_folder,
    "reset_zone_timer":        _reset_zone_timer,
    "open_gear_settings":      _open_gear_settings,
}

def apply_setting_side_effects(key, value):
    """Run side effects for a setting change. Some settings just need
    their global mirrored; others need a UDP message to the lua side.
    The schema's "applies" field decides:
      - "python"  side effect handled here in python only
      - "lua"     send SETTING|<key>|<value> to lua via port 5005
      - "both"    do both
    """
    global dps_panel_visible, buttons_panel_visible
    # Lua-side notifications: send SETTING|<key>|<value> on port 5005
    # (the same socket lua already uses for SETUP/LOCK/BUTTONS control
    # messages). The lua side handles SETTING tags in its gearswap
    # drain loop and translates them into per-feature state changes.
    schema = SETTINGS_BY_KEY.get(key, {})
    if schema.get("applies") in ("lua", "both"):
        try:
            payload = f"SETTING|{key}|{value}"
            # Lua listens on port 5011 for python→lua control messages
            # (see udp_cmd_in in OmniWatch.lua's prerender drain). The
            # button panel uses the same channel for slash commands;
            # settings use the SETTING| prefix to disambiguate.
            _s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            _s.sendto(payload.encode("utf-8"), ("127.0.0.1", 5011))
            _s.close()
        except Exception as e:
            print(f"[OmniWatch] failed to notify lua of "
                  f"setting change ({key}): {e}")
    # Python-side specific handling — extend here as more python-only
    # settings are added. For now, dps_sparkline is read directly
    # via setting() in the render path so no global mirror is needed.
    #
    # Two settings DO need to mirror to the existing slash-command
    # globals so //ow dps and //ow buttons stay in sync with what the
    # Settings menu shows:
    if key == "show_dps":
        dps_panel_visible = bool(value)
    elif key == "show_hotbar":
        buttons_panel_visible = bool(value)
    elif key == "always_on_top":
        _apply_always_on_top(bool(value))
    elif key == "window_opacity":
        _apply_window_opacity(value)
        # Re-apply transparent_bg state so colorkey survives the new alpha
        if setting("transparent_background"):
            _apply_transparent_background(True)
    elif key == "transparent_background":
        _apply_transparent_background(bool(value))
    elif key == "sim_mode":
        # Sim mode flip: open/close the floating window AND tell lua.
        # Order matters — open the UI before notifying lua so the user
        # sees the window appear simultaneously with the data switch.
        global sim_window_open, sim_active_field, sim_state, sim_buff_picker
        on = bool(value)
        sim_window_open = on
        if on:
            # Reset UI state to blank — per spec, sim starts with all
            # zeros and the user fills in. Wipe local cache too so
            # the rendered window matches lua's fresh state.
            sim_state = {
                "main_job": "", "sub_job": "",
                "merits": {}, "jp_spent": 0, "gifts": {},
                "buffs":  {}, "active_buffs": [], "master_level": 0, "equipment": {}, "food": None,
            }
            sim_buff_picker = None
            sim_active_field = None
            _sim_send_reset()
            _sim_send_mode(True)
        else:
            sim_active_field = None
            _sim_send_mode(False)

# NOTE: there's no "sync to globals" step here anymore. The settings
# schema deliberately doesn't include panel visibility or lock state —
# those are owned by the layout file and synced via load_layout().
# When we add settings that DO need a global mirror, do it in
# apply_setting_side_effects() and call it once at startup with the
# loaded value.

# ── DPS encounter logging ────────────────────────────────────────────────
# Called by the UDP parse loop when an ENCOUNTER_END packet finishes
# arriving. Appends one JSON-Lines record (full detail) and one CSV row
# (summary) per encounter. Both files are created on first write.
_dps_csv_header_written = False

def log_encounter(enc):
    """Append `enc` (a dict from the encounter parser) to the JSON
    and CSV logs. Robust to missing fields and fs errors — logs and
    continues, never raises."""
    global _dps_csv_header_written
    import datetime
    ts_iso = datetime.datetime.now().isoformat(timespec="seconds")
    record = {
        "timestamp_iso": ts_iso,
        "mob_id":        enc.get("mob_id", 0),
        "mob_name":      enc.get("mob_name", "?"),
        "duration_s":    round(float(enc.get("duration", 0)), 2),
        "by_src":        enc.get("by_src", {}),
        "ws_per_src":    enc.get("ws_per_src", {}),
    }

    # JSON Lines: full detail, one record per line. Easy to grep, easy
    # to load incrementally without parsing the whole file.
    try:
        with open(DPS_LOG_JSON, "a", encoding="utf-8") as f:
            json.dump(record, f, separators=(",", ":"))
            f.write("\n")
    except Exception as e:
        print(f"[OmniWatch] DPS JSON log write failed: {e!r}")

    # CSV: one summary row per source per encounter (so a kill where
    # both you and a party member damaged the mob produces 2 rows tied
    # by timestamp+mob_id). Lets you pivot in a spreadsheet.
    csv_cols = [
        "timestamp_iso", "mob_id", "mob_name", "duration_s", "src",
        "white", "magic", "ws", "sc", "skillchains",
        "hits", "misses", "crits",
        "spells_landed", "spells_resisted",
        "melee_acc", "magic_acc", "crit_pct",
        "longest", "total", "dps",
        "top_ws_name", "top_ws_count", "top_ws_total", "top_ws_best",
    ]
    try:
        # Write the header on first ever write (file didn't exist or
        # was empty before this run). Atomic-ish: we inspect the file
        # size, not just our flag, so deleting the file mid-run causes
        # a fresh header to be written.
        need_header = (not _dps_csv_header_written
                       and (not os.path.exists(DPS_LOG_CSV)
                            or os.path.getsize(DPS_LOG_CSV) == 0))
        with open(DPS_LOG_CSV, "a", encoding="utf-8", newline="") as f:
            import csv as _csv
            w = _csv.writer(f)
            if need_header:
                w.writerow(csv_cols)
            _dps_csv_header_written = True
            for src, b in record["by_src"].items():
                # Top WS for this src: highest count, ties broken by total.
                ws_map = record["ws_per_src"].get(src, {})
                top_ws_name, top_ws = "", {"count":0, "total":0, "best":0}
                for nm, w_entry in ws_map.items():
                    if (w_entry.get("count", 0) > top_ws["count"] or
                        (w_entry.get("count", 0) == top_ws["count"]
                         and w_entry.get("total", 0) > top_ws["total"])):
                        top_ws_name = nm
                        top_ws = w_entry
                w.writerow([
                    record["timestamp_iso"], record["mob_id"],
                    record["mob_name"], record["duration_s"], src,
                    b.get("white", 0), b.get("magic", 0), b.get("ws", 0),
                    b.get("sc", 0), b.get("skillchains", 0),
                    b.get("hits", 0), b.get("misses", 0), b.get("crits", 0),
                    b.get("spells_landed", 0), b.get("spells_resisted", 0),
                    f"{b.get('melee_acc', 0):.1f}",
                    f"{b.get('magic_acc', 0):.1f}",
                    f"{b.get('crit_pct',  0):.1f}",
                    b.get("longest", 0), b.get("total", 0),
                    f"{b.get('dps', 0):.1f}",
                    top_ws_name,
                    top_ws.get("count", 0),
                    top_ws.get("total", 0),
                    top_ws.get("best",  0),
                ])
    except Exception as e:
        print(f"[OmniWatch] DPS CSV log write failed: {e!r}")

    # Console feedback so user knows it worked.
    me_b = record["by_src"].get("me", {})
    print(f"[OmniWatch] encounter logged: {record['mob_name']} "
          f"in {record['duration_s']:.1f}s, "
          f"you dealt {me_b.get('total', 0):,} "
          f"({me_b.get('dps', 0):.1f} dps)")

# ── BG-Wiki link helpers ─────────────────────────────────────────────────────
BGWIKI_BASE = "https://www.bg-wiki.com/ffxi/"

def bgwiki_url(name):
    """Return a BG-Wiki URL for the given mob or zone name. Spaces become
    underscores. Other special chars are percent-encoded so apostrophes etc.
    pass through cleanly. Returns empty string for blank input."""
    if not name:
        return ""
    # MediaWiki convention: underscores for spaces, then URL-encode the rest.
    # safe="/" keeps any legitimate slashes (rare in page names but e.g.
    # some pages might have them).
    encoded = urllib.parse.quote(name.replace(" ", "_"), safe="/_")
    return BGWIKI_BASE + encoded

def open_url(url):
    """Open URL in default browser. Logged so the user can see what happened."""
    if not url:
        return
    try:
        webbrowser.open(url, new=2)   # new=2 means "new tab if possible"
        print(f"[OmniWatch] Opened: {url}")
    except Exception as e:
        print(f"[OmniWatch] Could not open URL {url}: {e}")

def register_click_target(rect, url):
    """Register a clickable region for the current frame."""
    if url and rect:
        click_targets.append((rect, url))

# Default buff config template — written to disk the first time the app runs
# if no config file exists yet. Users can edit this directly; changes apply
# on next launch. The file location is printed to the console at startup.
_BUFF_CFG_TEMPLATE = {
    "_README": [
        "OmniWatch buff/debuff display config.",
        "",
        "hide:                 legacy combined blacklist. Names in this",
        "                      list are hidden from BOTH party-panel buffs",
        "                      and party-panel debuffs. Use the split lists",
        "                      below for context-specific hiding.",
        "",
        "hide_party_buffs:     list of buff names to hide in the party",
        "                      panel's BUFFS column (per member).",
        "",
        "hide_party_debuffs:   list of debuff names to hide in the party",
        "                      panel's DEBUFFS column (per member).",
        "",
        "priority:             list of buff names that should ALWAYS show",
        "                      first when present. Put critical things",
        "                      here (Doom, Sleep, etc.) so they're never",
        "                      cut off by other entries.",
        "",
        "aliases:              map of full buff name -> short display name.",
        "                      Use to compress long names like",
        "                      \"Tactician's Roll\" -> \"TAC\" so more fit per line.",
        "",
        "All name matching is case-insensitive.",
        "Edits apply on next OmniWatch startup."
    ],
    "hide": [
        "Food",
        "Signet",
        "Sanction",
        "Sigil",
        "Ionis"
    ],
    "hide_party_buffs": [],
    "hide_party_debuffs": [],
    "priority": [
        "Doom",
        "Charm",
        "Petrification",
        "Terror",
        "Sleep",
        "Stun",
        "Silence",
        "Paralyze",
        "Amnesia",
        "Encumbrance"
    ],
    "aliases": {
        "Tactician's Roll":   "TAC Roll",
        "Chaos Roll":         "Chaos",
        "Hunter's Roll":      "Hunter",
        "Samurai Roll":       "Sam",
        "Warlock's Roll":     "Warlock",
        "Evoker's Roll":      "Evoker",
        "Rogue's Roll":       "Rogue",
        "Drachen Roll":       "Drachen",
        "Miser's Roll":       "Miser",
        "Wizard's Roll":      "Wiz",
        "Scholar's Roll":     "Scholar",
        "Companion's Roll":   "Comp",
        "Beast Roll":         "Beast",
        "Dancer's Roll":      "Dancer",
        "Corsair's Roll":     "Corsair",
        "Choral Roll":        "Choral",
        "Monk's Roll":        "Monk",
        "Healer's Roll":      "Healer",
        "Ninja Roll":         "Ninja",
        "Puppet Roll":        "Puppet",
        "Gallant's Roll":     "Gallant",
        "Allies' Roll":       "Allies",
        "Fighter's Roll":     "Fighter",
        "Magus's Roll":       "Magus",
        "Courser's Roll":     "Courser",
        "Blitzer's Roll":     "Blitzer",
        "Tamer's Roll":       "Tamer",
        "Caster's Roll":      "Caster",
        "Runeist's Roll":     "Runeist",
        "Trick Attack":       "TA",
        "Sneak Attack":       "SA",
        "Regen":              "Rgn",
        "Refresh":            "Rfr",
        "Protect":            "Prot",
        "Shell":              "Shell",
        "Haste":              "Haste",
        "Flurry":             "Flurry",
        "Reraise":            "RR",
        "Utsusemi: Ichi":     "Uts:I",
        "Utsusemi: Ni":       "Uts:II",
        "Utsusemi: San":      "Uts:III",
    }
}

# Loaded at runtime — kept as dicts for case-insensitive lookup.
_buff_hide_set         = set()   # legacy combined hide list
_buff_hide_party_buffs = set()   # extra: hide only in party-panel buff column
_buff_hide_party_debuffs = set() # extra: hide only in party-panel debuff column
_buff_priority         = []      # display names in priority order (lowercase keys → display)
_buff_priority_set     = set()   # lowercase names for fast lookup
_buff_aliases          = {}      # lowercase name → short display name


def load_buff_config():
    """Load omniwatch_buffs.json, writing a template if it doesn't exist.
    Backward-compatible: if a config has the legacy `hide` list and no
    split lists, the legacy list is used for both buff and debuff
    contexts. New split lists merge with (don't replace) the legacy
    list — so a name in `hide` is always hidden everywhere; names in
    `hide_party_buffs` add hiding only for that context.

    Auto-migrates on load: if the config exists but is missing the new
    split-list keys, we write them back with empty lists and refresh
    the _README so users discover the new sections naturally. Existing
    customizations (hide, aliases, priority) are preserved verbatim."""
    global _buff_hide_set, _buff_hide_party_buffs, _buff_hide_party_debuffs
    global _buff_priority, _buff_priority_set, _buff_aliases
    try:
        if not os.path.exists(BUFF_CFG):
            with open(BUFF_CFG, "w") as f:
                json.dump(_BUFF_CFG_TEMPLATE, f, indent=2)
            print(f"[OmniWatch] Created default buff config at {BUFF_CFG}")
            cfg = _BUFF_CFG_TEMPLATE
        else:
            with open(BUFF_CFG) as f:
                cfg = json.load(f)
            print(f"[OmniWatch] Loaded buff config from {BUFF_CFG}")

            # Migration: add the new split-list keys + refresh README if
            # missing. We only rewrite when there's something to add, so
            # we don't churn the file on every startup.
            needs_save = False
            if "hide_party_buffs" not in cfg:
                cfg["hide_party_buffs"] = []
                needs_save = True
            if "hide_party_debuffs" not in cfg:
                cfg["hide_party_debuffs"] = []
                needs_save = True
            # Only refresh README if it predates the split-list docs.
            old_readme = cfg.get("_README", [])
            if (isinstance(old_readme, list)
                    and not any("hide_party_buffs" in line
                                for line in old_readme
                                if isinstance(line, str))):
                cfg["_README"] = list(_BUFF_CFG_TEMPLATE["_README"])
                needs_save = True
            if needs_save:
                # Preserve existing key order: write README first, then
                # blacklists, then everything else.
                ordered = {}
                if "_README" in cfg:
                    ordered["_README"] = cfg["_README"]
                ordered["hide"]               = cfg.get("hide", [])
                ordered["hide_party_buffs"]   = cfg["hide_party_buffs"]
                ordered["hide_party_debuffs"] = cfg["hide_party_debuffs"]
                for k in ("priority", "aliases"):
                    if k in cfg:
                        ordered[k] = cfg[k]
                # Tack on any other keys the user added so we don't
                # eat custom data.
                for k, v in cfg.items():
                    if k not in ordered:
                        ordered[k] = v
                try:
                    with open(BUFF_CFG, "w") as f:
                        json.dump(ordered, f, indent=2)
                    print(f"[OmniWatch] Migrated buff config: added "
                          f"hide_party_buffs / hide_party_debuffs")
                    cfg = ordered
                except Exception as e:
                    print(f"[OmniWatch] buff config migration write "
                          f"failed: {e!r}")

        _buff_hide_set     = {n.lower() for n in cfg.get("hide", []) if isinstance(n, str)}
        _buff_hide_party_buffs   = {n.lower() for n in cfg.get("hide_party_buffs", []) if isinstance(n, str)}
        _buff_hide_party_debuffs = {n.lower() for n in cfg.get("hide_party_debuffs", []) if isinstance(n, str)}
        _buff_priority     = [n for n in cfg.get("priority", []) if isinstance(n, str)]
        _buff_priority_set = {n.lower() for n in _buff_priority}
        raw_aliases        = cfg.get("aliases", {}) or {}
        _buff_aliases      = {k.lower(): v for k, v in raw_aliases.items()
                              if isinstance(k, str) and isinstance(v, str)}
    except Exception as e:
        print(f"[OmniWatch] Could not load buff config: {e}. Using defaults.")
        _buff_hide_set            = {n.lower() for n in _BUFF_CFG_TEMPLATE["hide"]}
        _buff_hide_party_buffs    = set()
        _buff_hide_party_debuffs  = set()
        _buff_priority            = list(_BUFF_CFG_TEMPLATE["priority"])
        _buff_priority_set        = {n.lower() for n in _buff_priority}
        _buff_aliases             = {k.lower(): v for k, v in _BUFF_CFG_TEMPLATE["aliases"].items()}

def display_name(buff_name):
    """Return the display string for a buff (alias if defined, else the name)."""
    return _buff_aliases.get(buff_name.lower(), buff_name)

def is_hidden(buff_name):
    """Legacy hide-everywhere check. Backwards-compat for any caller that
    didn't migrate to is_hidden_in()."""
    return buff_name.lower() in _buff_hide_set

def is_hidden_in(buff_name, context):
    """Context-aware blacklist check. context is one of:
        'party_buff'    — party panel, buffs column
        'party_debuff'  — party panel, debuffs column
    Names in the legacy 'hide' list apply to all contexts; names in
    the per-context lists apply ONLY to that context. Future contexts
    (self_buff, self_debuff) will plug in here when wired up.
    """
    lo = buff_name.lower()
    if lo in _buff_hide_set:
        return True
    if context == "party_buff" and lo in _buff_hide_party_buffs:
        return True
    if context == "party_debuff" and lo in _buff_hide_party_debuffs:
        return True
    return False

def is_priority(buff_name):
    return buff_name.lower() in _buff_priority_set

load_buff_config()

# ── Buff timer config (omniwatch_buff_timer.json) ────────────────────────
# Owns the blacklist + alias map for the BUFF TIMER panel (separate from
# the party panel's blacklist). Python loads this file and pushes the
# resulting lists to lua at startup so lua's filtering matches.
_BUFF_TIMER_CFG_TEMPLATE = {
    "_README": [
        "OmniWatch buff TIMER config (separate from party panel buffs).",
        "",
        "hide:     list of buff names to hide from the buff timer panel.",
        "          These are YOUR buffs, songs, food, rolls, etc. that",
        "          you don't want a countdown bar for. Case-insensitive.",
        "",
        "aliases:  map of full buff name -> short display name. Used to",
        "          compress long names so more fit on the panel.",
        "          (Display rendering of these aliases is a planned",
        "          enhancement; the structure exists for future use.)",
        "",
        "Edits apply on next OmniWatch startup."
    ],
    "hide": [],
    "aliases": {},
}

_RECAST_TIMER_CFG_TEMPLATE = {
    "_README": [
        "OmniWatch recast timer config.",
        "",
        "hide:     list of spell/ability names to hide from the recast",
        "          panel. Use the EXACT name as it appears in",
        "          res.spells / res.job_abilities. Case-sensitive in",
        "          lua's resource lookup.",
        "",
        "aliases:  map of full name -> short display name for compression.",
        "          (Display rendering of these aliases is a planned",
        "          enhancement; the structure exists for future use.)",
        "",
        "Edits apply on next OmniWatch startup."
    ],
    "hide": [],
    "aliases": {},
}

# Loaded at runtime. Pushed to lua over UDP via _push_lua_lists().
_buff_timer_hide    = []     # list of strings (preserves source casing for editing)
_buff_timer_aliases = {}     # full → alias
_recast_hide        = []
_recast_aliases     = {}


def _load_simple_blacklist_config(path, template, label):
    """Generic loader for the buff_timer / recast configs. Both files
    have the same shape (`hide` list + `aliases` map). Returns
    (hide_list, aliases_map). Writes the template if file is missing."""
    try:
        if not os.path.exists(path):
            with open(path, "w") as f:
                json.dump(template, f, indent=2)
            print(f"[OmniWatch] Created default {label} config at {path}")
            cfg = template
        else:
            with open(path) as f:
                cfg = json.load(f)
            print(f"[OmniWatch] Loaded {label} config from {path}")
    except Exception as e:
        print(f"[OmniWatch] Could not load {label} config: {e}. "
              f"Using defaults.")
        cfg = template

    hide_list = [n for n in cfg.get("hide", []) if isinstance(n, str)]
    raw_aliases = cfg.get("aliases", {}) or {}
    aliases = {k: v for k, v in raw_aliases.items()
               if isinstance(k, str) and isinstance(v, str)}
    return hide_list, aliases


def load_buff_timer_config():
    """Load the buff timer JSON. Triggers a UDP push to lua so the
    addon's filtering picks up changes (assuming lua is running)."""
    global _buff_timer_hide, _buff_timer_aliases
    _buff_timer_hide, _buff_timer_aliases = _load_simple_blacklist_config(
        BUFF_TIMER_CFG, _BUFF_TIMER_CFG_TEMPLATE, "buff timer")


def load_recast_timer_config():
    """Load the recast timer JSON. Triggers a UDP push to lua."""
    global _recast_hide, _recast_aliases
    _recast_hide, _recast_aliases = _load_simple_blacklist_config(
        RECAST_TIMER_CFG, _RECAST_TIMER_CFG_TEMPLATE, "recast timer")


load_buff_timer_config()
load_recast_timer_config()


def _push_lua_lists():
    """Push the buff timer + recast timer hide lists to lua over UDP.
    Lua receives via its existing udp_cmd_in port (5011) using SETTING|
    messages. Wire format for lists: comma-separated values in a single
    UDP packet — buff/spell names don't contain commas so this is safe.

    Called once at python startup. Currently no live-reload — user has
    to restart the overlay after editing the JSON files."""
    try:
        # Wire one packet per list. Empty lists send an empty value
        # which lua treats as "clear the list".
        payloads = [
            ("hide_buff_timer", ",".join(_buff_timer_hide)),
            ("hide_recast",     ",".join(_recast_hide)),
        ]
        for key, value in payloads:
            packet = f"SETTING|{key}|{value}"
            _s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                _s.sendto(packet.encode("utf-8"), ("127.0.0.1", 5011))
            finally:
                _s.close()
        print(f"[OmniWatch] pushed timer blacklists to lua "
              f"({len(_buff_timer_hide)} buff timer, "
              f"{len(_recast_hide)} recast)")
    except Exception as e:
        print(f"[OmniWatch] could not push timer lists to lua: {e}")


# Push to lua immediately. If lua isn't ready yet (rare — usually loads
# first via Windower), the packet is silently dropped; user can re-push
# by clicking "Reload timer configs" in Settings or restarting.
_push_lua_lists()

# Where to look for icon assets. Layout (since the icon-folder
# consolidation): all icon assets live under OmniWatch/icons/, organized
# into subfolders:
#   icons/equipment/  → item-id-named .bmp files for the equip viewer
#   icons/mob/        → family-named .png/.bmp files for mob target cards
#   icons/ui/         → button-panel icons and other UI assets
# PARTYWATCH_ICON_DIR overrides to a different OmniWatch root (which must
# contain the same subfolder layout). Hard cutover: the old flat
# OmniWatch/icons/ and data/mob_icons/ paths are no longer searched.
def _self_addon_dir():
    """Best guess at where THIS overlay was launched from — typically
    the OmniWatch addon root that contains the .exe (or .py),
    icons/, and data/. Used as the highest-priority icon-dir base
    so users don't have to configure anything when the addon folder
    is laid out the standard way.

    PyInstaller subtlety: when frozen as a --onefile .exe, __file__
    points into the temp _MEIxxxx extraction dir, NOT the .exe
    location. sys.executable is the right answer in that case.
    For non-frozen runs (python OmniWatch.py), __file__ is correct.
    """
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))

def _find_icon_dir():
    """Find OmniWatch/icons/equipment/. Returns absolute path or a fallback
    (which won't have any files but won't crash on lookup)."""
    # 0. Self-location. If we're sitting next to icons/equipment/, just
    # use that — no env var, no setting, no guessing required. This
    # covers the standard install layout where OmniWatch.exe lives in
    # the addon folder alongside icons/ and data/.
    #
    # Also walks one or two levels up in case PyInstaller put the .exe
    # in a `dist\` subfolder. Walking up handles the common build
    # layout: <addon>\dist\OmniWatch.exe with icons at <addon>\icons\.
    self_dir = _self_addon_dir()
    for _base in (self_dir,
                  os.path.dirname(self_dir),
                  os.path.dirname(os.path.dirname(self_dir))):
        if not _base or not os.path.isdir(_base):
            continue
        cand = os.path.join(_base, "icons", "equipment")
        if os.path.isdir(cand):
            print(f"[OmniWatch] Using equipment icon dir from "
                  f"self-location: {cand}")
            return cand

    override = os.environ.get("PARTYWATCH_ICON_DIR")
    if override:
        # Override may point at the OmniWatch addon root or at the icons/
        # subdir directly. Try both.
        for sub in (os.path.join("icons", "equipment"), "equipment", ""):
            cand = os.path.join(override, sub) if sub else override
            if os.path.isdir(cand):
                print(f"[OmniWatch] Using equipment icon dir from "
                      f"PARTYWATCH_ICON_DIR: {cand}")
                return cand
        print(f"[OmniWatch] PARTYWATCH_ICON_DIR is set but no equipment "
              f"icons subfolder under: {override}")

    # Common Windower4 install locations. First hit wins.
    appdata_local = os.environ.get("LOCALAPPDATA", "")
    userprofile   = os.environ.get("USERPROFILE", os.path.expanduser("~"))
    addon_roots = [
        # Square Enix launcher install (newer SE-bundled Windower installer)
        r"C:\Program Files (x86)\SquareEnix\SquareEnix\Windower\addons\OmniWatch",
        r"C:\Program Files (x86)\SquareEnix\Windower\addons\OmniWatch",
        r"C:\Program Files\SquareEnix\SquareEnix\Windower\addons\OmniWatch",
        # Modern installer default
        os.path.join(appdata_local, "Windower4", "addons", "OmniWatch") if appdata_local else "",
        # Older / legacy installs
        r"C:\Program Files (x86)\Windower4\addons\OmniWatch",
        r"C:\Program Files\Windower4\addons\OmniWatch",
        r"C:\Windower4\addons\OmniWatch",
        r"C:\Windower\addons\OmniWatch",
        os.path.join(userprofile, "Windower4", "addons", "OmniWatch"),
        os.path.join(userprofile, "Documents", "Windower4", "addons", "OmniWatch"),
        # Common POL / FFXI-adjacent locations
        r"D:\Windower4\addons\OmniWatch",
        r"E:\Windower4\addons\OmniWatch",
    ]
    addon_roots = [c for c in addon_roots if c]
    candidates = [os.path.join(r, "icons", "equipment") for r in addon_roots]

    print("[OmniWatch] Searching for equipment icon folder (icons/equipment/)...")
    for c in candidates:
        exists = os.path.isdir(c)
        print(f"  [{'FOUND' if exists else ' no  '}] {c}")
        if exists:
            print(f"[OmniWatch] Using equipment icon dir: {c}")
            return c

    # Fallback: user data dir. Won't actually have bmps, but we won't crash.
    fallback = os.path.join(USER_DIR, "icons", "equipment")
    os.makedirs(fallback, exist_ok=True)
    print(f"[OmniWatch] No equipment icon dir found. Falling back to "
          f"(empty): {fallback}")
    print( "[OmniWatch] Tip: place .bmp files in OmniWatch/icons/equipment/ "
           "or set PARTYWATCH_ICON_DIR to an OmniWatch root.")
    return fallback

ICON_DIR = _find_icon_dir()

# Sibling icon subfolders. Resolved as siblings of ICON_DIR (so they
# inherit whatever root won the search above). UI_ICONS_DIR holds button
# panel icons keyed by name. MOB_ICONS_DIR is set later — see
# _find_mob_icons_dir() — but anchored to the same root.
_icon_root = os.path.dirname(ICON_DIR)   # the "icons/" folder
UI_ICONS_DIR = os.path.join(_icon_root, "ui")
if not os.path.isdir(UI_ICONS_DIR):
    try:
        os.makedirs(UI_ICONS_DIR, exist_ok=True)
        print(f"[OmniWatch] Created UI icons dir: {UI_ICONS_DIR}")
    except OSError as _e:
        print(f"[OmniWatch] Could not create UI icons dir "
              f"{UI_ICONS_DIR}: {_e}")
else:
    print(f"[OmniWatch] Using UI icons dir: {UI_ICONS_DIR}")

def _find_data_root():
    """Find the top-level `data/` folder where all subordinate data sources
    (mobdata, future subfolders) live. Override via PARTYWATCH_DATA_DIR."""
    override = os.environ.get("PARTYWATCH_DATA_DIR")
    if override and os.path.isdir(override):
        print(f"[OmniWatch] Using data dir from PARTYWATCH_DATA_DIR: {override}")
        return override

    # Sibling of icons/ folder — most common. ICON_DIR is now
    # OmniWatch/icons/equipment/, so the addon root is two levels up.
    # Use the cached _icon_root (= OmniWatch/icons/) and take its parent.
    if ICON_DIR:
        addon_root = os.path.dirname(_icon_root)   # OmniWatch/
        sibling = os.path.join(addon_root, "data")
        if os.path.isdir(sibling):
            print(f"[OmniWatch] Using data dir (addon root sibling of icons): {sibling}")
            return sibling

    # Fallback: %APPDATA%/OmniWatch/data
    fallback = os.path.join(USER_DIR, "data")
    if os.path.isdir(fallback):
        print(f"[OmniWatch] Using data dir: {fallback}")
        return fallback

    # Last resort: still return a valid path (the appdata fallback)
    # so downstream os.path.join calls don't blow up. Files won't exist
    # there yet but lookups will gracefully miss instead of crashing.
    print("[OmniWatch] No data folder found. Target cards will still work")
    print("            but features dependent on bundled data will be blank.")
    addon_hint = os.path.dirname(_icon_root) if ICON_DIR else "<addon root>"
    print(f"           Create a `data/` folder at: "
          f"{os.path.join(addon_hint, 'data')}")
    print(f"           Falling back to (will be auto-created): {fallback}")
    try:
        os.makedirs(fallback, exist_ok=True)
    except OSError as _e:
        print(f"           Could not create fallback dir: {_e}")
    return fallback

def _find_mobdata_dir(data_root):
    """Locate the MobDB data files. Preferred location: `<data_root>/mobdata/`.
    Falls back to `<data_root>/` itself for backward compatibility with the
    original flat layout where lua files lived directly in the data folder."""
    if not data_root:
        return None
    preferred = os.path.join(data_root, "mobdata")
    if os.path.isdir(preferred):
        print(f"[OmniWatch] Using mob data dir: {preferred}")
        return preferred
    # Legacy: look for *.lua files directly under data_root.
    try:
        if any(f.lower().endswith(".lua") for f in os.listdir(data_root)):
            print(f"[OmniWatch] Using legacy mob data dir (flat): {data_root}")
            print(f"            Tip: move .lua files into {preferred} for cleanliness.")
            return data_root
    except Exception:
        pass
    print(f"[OmniWatch] No mob data found. Drop MobDB's lua files into: {preferred}")
    return None

DATA_ROOT    = _find_data_root()
MOBDATA_DIR  = _find_mobdata_dir(DATA_ROOT)

def _find_mob_icons_dir(data_root):
    """Locate per-family mob icons. Hard cutover: only OmniWatch/icons/mob/
    is supported now; the old data/mob_icons/ location is no longer
    consulted. `data_root` is unused but kept for signature stability;
    the resolution is anchored to ICON_DIR's parent so it inherits the
    same install-root that won the equipment search."""
    candidate = os.path.join(_icon_root, "mob")
    if os.path.isdir(candidate):
        return candidate
    return None

MOB_ICONS_DIR = _find_mob_icons_dir(DATA_ROOT)
if MOB_ICONS_DIR:
    print(f"[OmniWatch] Using mob icons dir: {MOB_ICONS_DIR}")

# Backward-compat alias for anything still referencing DATA_DIR.
DATA_DIR = MOBDATA_DIR

# Resources directory — for Windower res/*.lua files that we need to parse
# Python-side (spells, monster_abilities, etc.). User drops copies of the
# relevant lua files into <DATA_ROOT>/resources/.
def _find_resources_dir(data_root):
    if not data_root:
        return None
    preferred = os.path.join(data_root, "resources")
    if os.path.isdir(preferred):
        return preferred
    return None

RESOURCES_DIR = _find_resources_dir(DATA_ROOT)
if RESOURCES_DIR:
    print(f"[OmniWatch] Using resources dir: {RESOURCES_DIR}")
else:
    print(f"[OmniWatch] No resources dir. Drop copies of Windower's")
    print(f"            res/spells.lua (etc.) into {os.path.join(DATA_ROOT, 'resources')}"
          if DATA_ROOT else "            [data root not set]")

# Parsed spell table: id (int) → {"name": str, "type": str, "element": int}
_spells_by_id = {}

def load_spells_resource():
    """Parse res/spells.lua (Windower format). Returns dict id→info."""
    if not RESOURCES_DIR:
        return {}
    path = os.path.join(RESOURCES_DIR, "spells.lua")
    if not os.path.isfile(path):
        print(f"[OmniWatch] No spells.lua at {path}")
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except Exception as e:
        print(f"[OmniWatch] Could not read spells.lua: {e}")
        return {}

    # Each entry: [123] = {id=123,en="Firaga III",..., targets={...}, levels={...}}
    # The body can contain nested braces (targets, levels, jobs) so we can't
    # use a simple [^{}]* regex. Walk the text manually, finding "[N] = {"
    # and tracking brace depth until we match the closing brace.
    out = {}
    header_re = re.compile(r"\[(\d+)\]\s*=\s*\{")
    pos = 0
    while True:
        hm = header_re.search(text, pos)
        if not hm:
            break
        try:
            sid = int(hm.group(1))
        except ValueError:
            pos = hm.end()
            continue

        # Scan from just after the opening brace, tracking depth.
        depth  = 1
        body_start = hm.end()
        i = body_start
        n = len(text)
        while i < n and depth > 0:
            c = text[i]
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    break
            elif c == '"':
                # Skip to matching close-quote, respecting backslash escapes.
                i += 1
                while i < n and text[i] != '"':
                    if text[i] == '\\':
                        i += 1
                    i += 1
            i += 1

        if depth != 0:
            break   # malformed file; stop rather than loop forever
        body = text[body_start:i]
        pos  = i + 1
        name_m    = re.search(r'\ben\s*=\s*"([^"]*)"', body)
        type_m    = re.search(r'\btype\s*=\s*"([^"]*)"', body)
        element_m = re.search(r'\belement\s*=\s*(-?\d+)', body)
        out[sid] = {
            "name":    name_m.group(1)    if name_m    else "",
            "type":    type_m.group(1)    if type_m    else "",
            "element": int(element_m.group(1)) if element_m else -1,
        }
    print(f"[OmniWatch] Loaded {len(out)} spells from resources/spells.lua")
    return out

_spells_by_id = load_spells_resource()


# ═══════════════════════════════════════════════════════════════════════════
# Mob abilities database — scraped from BG-wiki and stored under
# OmniWatch/data/mob_abilities.json. Keyed by family (lowercase).
# Structure: {families: {fam_key: {tp_moves: [{name, class, type, target,
# area, effect, shadows}, ...], description, abilities: [name,...]}}}
# ═══════════════════════════════════════════════════════════════════════════
_mob_abilities_db = {"families": {}, "abilities": {}}
def load_mob_abilities():
    """Load the mob_abilities.json file from the addon's data folder.
    Silent no-op if the file is missing."""
    path = os.path.join(DATA_ROOT, "mob_abilities.json")
    if not os.path.exists(path):
        print(f"[OmniWatch] No mob_abilities.json at {path} — ability "
              f"tooltips will be empty. Run build_mob_db.py to generate.")
        return {"families": {}, "abilities": {}}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"[OmniWatch] Could not read mob_abilities.json: {e}")
        return {"families": {}, "abilities": {}}
    fams = data.get("families", {}) or {}
    abils = data.get("abilities", {}) or {}
    print(f"[OmniWatch] Loaded mob_abilities.json: "
          f"{len(fams)} families, {len(abils)} abilities")
    return {"families": fams, "abilities": abils}

_mob_abilities_db = load_mob_abilities()

# ── Trusts database ────────────────────────────────────────────────────
# Lives at data/trustdata/trusts.json. Shape:
#   {
#     "_meta":  {...},
#     "trusts": {
#       "trust_name_lower": {
#         "name":            "Apururu (UC)",
#         "alter_ego":       "Apururu",
#         "display":         "Trust: Apururu (UC)",
#         "job":             "WHM",
#         "role":            "Healer",
#         "race":            "Tarutaru",
#         "weapon":          "Hammer",
#         "obtained":        "Trade Cipher: Apururu...",
#         "job_abilities":   ["Benediction", ...],
#         "weapon_skills":   [...],
#         "spells":          ["Cure V", "Holy", ...],
#         "job_traits":      [...],
#         "notable":         "...",
#         "dialogue":        {"summon": "...", "dismiss": "...", "death": "..."},
#         "portrait_path":   "trustdata/trust_images/apururu_(uc).png",
#         "portrait_filename_candidates": ["apururu_(uc).png", "apururu_uc.png"],
#         "portrait_url":    "https://...",   # original Fandom URL (fallback)
#       },
#       ...
#     }
#   }
# Trust names are matched against the in-game mob name. The (UC) suffix
# and other distinguishing markers stay in the keys.
_trusts_db = {"trusts": {}}
def load_trusts_db():
    """Load the trusts.json file from the addon's data folder.

    Looks first at data/trustdata/trusts.json (canonical location).
    Falls back to data/trusts.json for backwards compatibility, with
    a console hint to migrate. Silent no-op if neither exists."""
    if not DATA_ROOT:
        return {"trusts": {}}
    candidates = [
        os.path.join(DATA_ROOT, "trustdata", "trusts.json"),
        os.path.join(DATA_ROOT, "trusts.json"),
    ]
    path = None
    for p in candidates:
        if os.path.exists(p):
            path = p
            break
    if not path:
        print(f"[OmniWatch] No trusts.json found. Expected at "
              f"{candidates[0]}. Trust cards will render without "
              f"abilities/portrait until the file is in place.")
        return {"trusts": {}}
    if path == candidates[1]:
        print(f"[OmniWatch] Loaded trusts.json from legacy location: {path}")
        print(f"            Tip: move it to {candidates[0]} for the "
              f"canonical layout.")
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"[OmniWatch] Could not read trusts.json: {e}")
        return {"trusts": {}}
    trusts = data.get("trusts", {}) or {}
    print(f"[OmniWatch] Loaded trusts.json: {len(trusts)} trusts from {path}")
    return {"trusts": trusts}
_trusts_db = load_trusts_db()

def lookup_trust(name):
    """Return a trust record by in-game name (case-insensitive), or None.

    Trust display names in Windower can take several forms:
      'Apururu (UC)'     ← our JSON key is 'apururu (uc)'
      'Apururu'          ← no suffix; the alter_ego field
      'ApururuUC'        ← collapsed punctuation
      'Apururu UC'       ← parens dropped
      'Ark EV'           ← Ark Angel abbreviation, key is 'aaev'
      'Babban'           ← short form of 'Babban Ny Mheillea'
    We try the JSON key directly first, then a few normalized variants,
    then fall back to matching the alter_ego field. The DB is ~120
    entries so the linear fallback is cheap.
    """
    if not name or not _trusts_db:
        return None
    trusts = _trusts_db.get("trusts", {}) or {}
    raw = str(name).strip()

    # 1) Direct lookup.
    key = raw.lower()
    rec = trusts.get(key)
    if rec:
        return rec

    # 2) Normalized variants of the input.
    def _norm(s):
        s = s.lower()
        s = re.sub(r"[\(\)]", " ", s)        # parens become spaces
        s = re.sub(r"\s+", " ", s).strip()   # collapse whitespace
        return s

    target = _norm(raw)
    target_compact = target.replace(" ", "")  # also no-spaces variant

    # 3) Match against keys (with same normalization).
    for k, v in trusts.items():
        nk = _norm(k)
        if nk == target or nk.replace(" ", "") == target_compact:
            return v

    # 4) Match against alter_ego.
    for v in trusts.values():
        ae = (v.get("alter_ego") or "").strip().lower()
        if ae and (ae == raw.lower() or _norm(ae) == target):
            return v

    # 5) Ark Angel abbreviation: FFXI sends "ArkEV" / "ArkGK" / "ArkHM" /
    # "ArkMR" / "ArkTT" (single token, no space, no "Angel"). Our alter_ego
    # field is "Ark Angel EV", so we strip "Angel" and compare both
    # space-preserved ("ark ev") and space-collapsed ("arkev") forms.
    for v in trusts.values():
        ae = (v.get("alter_ego") or "").strip()
        if ae:
            short = re.sub(r"\bAngel\s+", "", ae, flags=re.IGNORECASE).strip()
            if short:
                short_norm = _norm(short)
                if short_norm == target or short_norm.replace(" ", "") == target_compact:
                    return v

    # 6) Leading-word match for long alter_egos like "Babban Ny Mheillea"
    # → "Babban", "Valaineral R Davilles" → "Valaineral", "Akihiko Matsui"
    # → "Matsui" or "Akihiko" (try both first and last word).
    for v in trusts.values():
        ae = (v.get("alter_ego") or "").strip()
        if not ae:
            continue
        words = ae.split()
        if len(words) >= 2:
            first = words[0].lower()
            last  = words[-1].lower()
            if target == first or target == last:
                return v

    # 7) Match against the `name` field after normalization (some trusts
    # have name='Apururu (UC)' but Windower reports 'Apururu UC' which
    # we already covered via key normalization, but fall through here
    # for any oddballs).
    for v in trusts.values():
        nm = (v.get("name") or "").strip().lower()
        if nm and (nm == raw.lower() or _norm(nm) == target):
            return v

    return None

def resolve_target_card_data(target_sticky):
    """Resolve a target_sticky dict into the values draw_target_card needs.
    Returns (mob_ref, mobdb_entry, family_key, ability_count, ability_chars,
    aggro_row_flag). Used for both main and sub-target so trusts and PCs
    render correctly in either slot.

    Branches by `kind` field from lua:
      'mob'    — full mob lookup (abilities + mobdb modifiers)
      'trust'  — trust DB lookup (abilities + portrait)
      'pc'     — minimal card (no abilities, no aggro row)
    Falls back to is_pc when kind is missing (older lua versions)."""
    if not target_sticky:
        return None, None, "", 0, 0, False

    kind = target_sticky.get("kind", "")
    if not kind:
        kind = "pc" if target_sticky.get("is_pc", 0) else "mob"

    if kind in ("pc", "npc"):
        return None, None, "", 0, 0, False

    if kind == "trust":
        raw_name = target_sticky.get("name", "")
        trust = lookup_trust(raw_name)
        # Log resolution result once per unique input — helps debug
        # cases where Windower's mob.name doesn't match our DB's keys
        # (Ark Angels, '(UC)' variants, etc.). Only fires on first miss
        # or first hit per name; quiet on repeat targets.
        global _trust_lookup_logged
        if "_trust_lookup_logged" not in globals():
            _trust_lookup_logged = set()
        if raw_name and raw_name not in _trust_lookup_logged:
            _trust_lookup_logged.add(raw_name)
            if trust:
                tk = (trust.get('name') or '').lower()
                print(f"[OmniWatch] Trust lookup: '{raw_name}' -> "
                      f"'{trust.get('name')}' "
                      f"(abil={len(trust.get('job_abilities') or [])}, "
                      f"ws={len(trust.get('weapon_skills') or [])}, "
                      f"sp={len(trust.get('spells') or [])})")
            else:
                print(f"[OmniWatch] Trust lookup MISS: '{raw_name}' "
                      f"— no record in trusts.json")
        if trust:
            # Merge all action-type lists for the existing renderer. The
            # target card's ability rendering is currently agnostic about
            # whether something is a job ability vs spell vs weapon skill;
            # we just want them all visible. Future enhancement: render
            # them in distinct sections with subheadings.
            merged = []
            for src_list in (trust.get("job_abilities") or [],
                             trust.get("weapon_skills") or [],
                             trust.get("spells") or []):
                for x in src_list:
                    if x not in merged:
                        merged.append(x)

            # Resolve the portrait via candidate-fallback. _resolve uses
            # portrait_path first, then walks portrait_filename_candidates
            # until it finds a real file. Returns None if nothing matches
            # (renderer will fall back to no portrait).
            portrait_rel = _resolve_trust_portrait_path(trust)

            ref = {
                "name":      trust.get("name", ""),
                "alter_ego": trust.get("alter_ego", ""),
                "family":    "trust",
                "abilities": merged,
                # Keep these split too in case downstream code wants them.
                "job_abilities": trust.get("job_abilities", []) or [],
                "weapon_skills": trust.get("weapon_skills", []) or [],
                "spells":        trust.get("spells", []) or [],
                "job_traits":    trust.get("job_traits", []) or [],
                "portrait":  portrait_rel or "",
                "job":       trust.get("job", ""),
                "role":      trust.get("role", ""),
                "race":      trust.get("race", ""),
                "weapon":    trust.get("weapon", ""),
                "notable":   trust.get("notable", ""),
                "obtained":  trust.get("obtained", ""),
                "dialogue":  trust.get("dialogue", {}) or {},
                "comments":  trust.get("comments", "") or "",   # Misc row, user-editable
            }
            abils, achars = _tc_ability_info(ref, "trust")
            return ref, None, "trust", abils, achars, False
        # Trust not in DB yet — render with no abilities.
        return None, None, "trust", 0, 0, False

    # Default: mob
    ref = lookup_mob(target_sticky.get("name", ""))
    mobdb = lookup_mobdb(target_sticky.get("name", ""),
                         target_sticky.get("zone_id", 0))
    fam = ""
    if mobdb and mobdb.get("family"):
        fam = mobdb["family"].lower()
    if not fam:
        fam = infer_family(target_sticky.get("name", "") or "")
    if not fam:
        fam = (ref or {}).get("family", "").lower()
    abils, achars = _tc_ability_info(ref, fam)
    return ref, mobdb, fam, abils, achars, mobdb is not None

# Roman-numeral ↔ integer helpers for spell-name condensation.
_ROMAN_TO_INT = {
    "I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6, "VII": 7, "VIII": 8,
}
_INT_TO_ROMAN = {v: k for k, v in _ROMAN_TO_INT.items()}

def condense_spell_list(spells):
    """Convert a list of spell IDs OR names to a condensed human-readable
    string. Accepts either:
      - List of integer IDs (legacy .lua mobdb format) — resolved via
        _spells_by_id.
      - List of name strings (new merged JSON format) — used directly.
      - Mixed list (defensive) — each item resolved by type.

    Groups same-family tiered spells into ranges like "Firaga I-III, Water IV".
    Ignores unresolved IDs. Returns the formatted string."""
    if not spells:
        return ""

    # First pass: collect resolved names. ID inputs need _spells_by_id;
    # name inputs are used directly.
    names_seen = []
    seen_set = set()
    for item in spells:
        name = None
        if isinstance(item, int):
            if not _spells_by_id:
                continue
            sp = _spells_by_id.get(item)
            if sp:
                name = sp.get("name")
        elif isinstance(item, str):
            name = item.strip()
        if name and name not in seen_set:
            seen_set.add(name)
            names_seen.append(name)

    if not names_seen:
        return ""

    # Second pass: split into (base, tier) where tier is int.
    # "Firaga III"  → base="Firaga",  tier=3
    # "Firaga"      → base="Firaga",  tier=1
    # "Dia II"      → base="Dia",     tier=2
    # "Stun"        → base="Stun",    tier=None   (no tier, standalone)
    tier_groups = {}       # base → set of tiers
    standalone  = []       # names without tier suffix

    for name in names_seen:
        # Match trailing roman numeral separated by a space.
        m = re.match(r"^(.*?)\s+(I{1,3}|IV|V|VI|VII|VIII)$", name)
        if m:
            base = m.group(1).strip()
            tier = _ROMAN_TO_INT[m.group(2)]
            tier_groups.setdefault(base, set()).add(tier)
        else:
            standalone.append(name)

    # Build output pieces.
    def _ranges(tier_set):
        """[1,2,3,5] → 'I-III, V'"""
        ts = sorted(tier_set)
        parts = []
        i = 0
        while i < len(ts):
            j = i
            while j + 1 < len(ts) and ts[j + 1] == ts[j] + 1:
                j += 1
            if j == i:
                parts.append(_INT_TO_ROMAN.get(ts[i], str(ts[i])))
            else:
                parts.append(f"{_INT_TO_ROMAN.get(ts[i], ts[i])}-{_INT_TO_ROMAN.get(ts[j], ts[j])}")
            i = j + 1
        return ", ".join(parts)

    pieces = []
    for base in sorted(tier_groups.keys()):
        tiers = tier_groups[base]
        if len(tiers) == 1 and 1 in tiers:
            # Single tier-1 spell ("Firaga") — drop the roman numeral.
            pieces.append(base)
        else:
            pieces.append(f"{base} {_ranges(tiers)}")
    pieces.extend(sorted(standalone))
    return ", ".join(pieces)

_mobdb_by_lower = load_mobdb_data()

# ── Setup-mode mock injection ──────────────────────────────────────────────
# Register a synthetic mob entry + family so setup mode's mock target card
# renders with realistic strengths/weaknesses/immunities/spells/abilities.
# Without this, setup-mode target cards show only the header — leaving the
# user unable to gauge the real card height when positioning.
def _register_setup_mocks():
    # 1. MobDB entry: keyed by lowercased name. Renderer pulls modifiers
    #    + immunities + spells from this dict shape.
    _mobdb_by_lower["mocktarget"] = [{
        "_zone_id": 0,
        "name":     "MockTarget",
        "family":   "mockfamily",
        "modifiers": {
            "Slashing":  0.5,    # strong vs slashing (-50%)
            "Piercing":  1.25,   # weak to piercing (+25%)
            "Fire":      0.25,   # very strong vs fire (-75%)
            "Ice":       1.5,    # weak to ice (+50%)
            "Lightning": 0.75,
        },
        "immunities": (1 | 8 | 32 | 2048),   # Sleep, Stun, Paralyze, Charm
        "spells":     [],   # populated below if _spells_by_id is ready
    }]
    # Spell IDs need to be resolvable. Pick a few that exist in any FFXI
    # install: Fire III (146), Blizzard III (149), Stun (252), Paralyze (74).
    # Skip any that aren't in _spells_by_id so condense doesn't choke.
    if "_spells_by_id" in globals() and _spells_by_id:
        candidate_spells = [146, 147, 148, 149, 252, 74]
        _mobdb_by_lower["mocktarget"][0]["spells"] = [
            sid for sid in candidate_spells if sid in _spells_by_id
        ]

    # 2. Family abilities: keyed under _mob_abilities_db.families[family].
    #    Renderer pulls tp_moves list from this shape.
    if _mob_abilities_db is not None:
        fams = _mob_abilities_db.setdefault("families", {})
        fams["mockfamily"] = {
            "description": "Ecosystem: Mock | Main Job: BLM | Sub Job: WHM "
                           "| Crystal: Fire",
            "tp_moves": [
                {"name": "Mock Slam"},
                {"name": "Mock Stomp"},
                {"name": "Mock Roar"},
                {"name": "Mock Blast"},
                {"name": "Mock Cleave"},
                {"name": "Mock Howl"},
            ],
        }

# Register immediately so setup mode just works.
try:
    _register_setup_mocks()
except Exception as _e:
    print(f"[OmniWatch] could not register setup mocks: {_e}")

def save_layout():
    try:
        data = {
            "panel_anchors":   panel_anchors,
            "panel_scales":    panel_scales,
            "equip_anchor":    equip_anchor,
            "equip_scale":     equip_scale,
            "stats_anchor":    stats_anchor,
            "stats_scale":     stats_scale,
            "target_anchor":   target_anchor,
            "target_scale":    target_scale,
            "target_anchor_st": target_anchor_st,
            "target_scale_st":  target_scale_st,
            "recast_anchor":   recast_anchor,
            "recast_scale":    recast_scale,
            "buff_anchor":     buff_anchor,
            "buff_scale":      buff_scale,
            "dps_anchor":      dps_anchor,
            "dps_scale":       dps_scale,
            "dps_panel_visible": dps_panel_visible,
            "buttons_anchor":   buttons_anchor,
            "buttons_scale":    buttons_scale,
            "buttons_panel_visible": buttons_panel_visible,
            # Multi-hotbar (visible_count > 1) panel positions and the
            # current content page each panel is showing. Saved so the
            # user's layout survives a restart. JSON keys are stringified
            # by json.dump; we restore int keys on load.
            "buttons_panel_anchors": {str(k): v for k, v
                                      in buttons_panel_anchors.items()},
            "hotbar_panel_pages":    {str(k): v for k, v
                                      in hotbar_panel_pages.items()},
            "panels_locked":   panels_locked,
            # Sim window position and user-resized size. Persisted so the
            # window stays where the user put it across restarts. Width
            # always saved; height is 0 when auto-fitting (no user resize
            # happened) and a positive int when manually sized.
            "sim_window_pos":   list(sim_window_pos),
            "sim_window_size":  list(sim_window_size),
        }
        with open(LAYOUT_FILE, "w") as f:
            json.dump(data, f, indent=2)
        print(f"[OmniWatch] Saved layout ({len(panel_anchors)} panel anchors, "
              f"equip_anchor={equip_anchor}, target_anchor={target_anchor}) "
              f"to {LAYOUT_FILE}")
    except Exception as e:
        print(f"[OmniWatch] Could not save layout: {e}")

def load_layout():
    """Load saved anchors and scales."""
    global equip_anchor, equip_scale, target_anchor, target_scale
    global target_anchor_st, target_scale_st
    global stats_anchor, stats_scale
    global recast_anchor, recast_scale
    global buff_anchor, buff_scale
    global dps_anchor, dps_scale, dps_panel_visible
    global buttons_anchor, buttons_scale, buttons_panel_visible
    global panels_locked
    try:
        if not os.path.exists(LAYOUT_FILE):
            print(f"[OmniWatch] No layout file at {LAYOUT_FILE} (first run).")
            return
        with open(LAYOUT_FILE) as f:
            data = json.load(f)

        # Current format: anchors.
        for k, v in data.get("panel_anchors", {}).items():
            if isinstance(v, list) and len(v) == 3:
                panel_anchors[k] = [str(v[0]), int(v[1]), int(v[2])]
        panel_scales.update({k: float(v) for k, v in data.get("panel_scales", {}).items()})
        # Lock state — default True (locked) on first run.
        if "panels_locked" in data:
            panels_locked = bool(data["panels_locked"])
        ea = data.get("equip_anchor")
        if ea and len(ea) == 3:
            equip_anchor = [str(ea[0]), int(ea[1]), int(ea[2])]
        equip_scale = float(data.get("equip_scale", 1.0))

        sa = data.get("stats_anchor")
        if sa and len(sa) == 3:
            stats_anchor = [str(sa[0]), int(sa[1]), int(sa[2])]
        stats_scale = float(data.get("stats_scale", 1.0))

        ta = data.get("target_anchor")
        if ta and len(ta) == 3 and not os.environ.get("PARTYWATCH_RESET_TARGET"):
            target_anchor = [str(ta[0]), int(ta[1]), int(ta[2])]
        if os.environ.get("PARTYWATCH_RESET_TARGET"):
            print("[OmniWatch] PARTYWATCH_RESET_TARGET is set — "
                  "resetting target card position to top-right default.")
        target_scale = float(data.get("target_scale", 1.0))

        tas = data.get("target_anchor_st")
        if tas and len(tas) == 3 and not os.environ.get("PARTYWATCH_RESET_TARGET"):
            target_anchor_st = [str(tas[0]), int(tas[1]), int(tas[2])]
        target_scale_st = float(data.get("target_scale_st", 1.0))

        ra = data.get("recast_anchor")
        if ra and len(ra) == 3:
            recast_anchor = [str(ra[0]), int(ra[1]), int(ra[2])]
        recast_scale = float(data.get("recast_scale", 1.0))

        ba = data.get("buff_anchor")
        if ba and len(ba) == 3:
            buff_anchor = [str(ba[0]), int(ba[1]), int(ba[2])]
        buff_scale = float(data.get("buff_scale", 1.0))

        da = data.get("dps_anchor")
        if da and len(da) == 3:
            dps_anchor = [str(da[0]), int(da[1]), int(da[2])]
        dps_scale = float(data.get("dps_scale", 1.0))
        if "dps_panel_visible" in data:
            dps_panel_visible = bool(data["dps_panel_visible"])

        bta = data.get("buttons_anchor")
        if bta and len(bta) == 3:
            buttons_anchor = [str(bta[0]), int(bta[1]), int(bta[2])]
        buttons_scale = float(data.get("buttons_scale", 1.0))
        if "buttons_panel_visible" in data:
            buttons_panel_visible = bool(data["buttons_panel_visible"])

        # Multi-hotbar panel anchors / current pages. Keys come back as
        # strings from json so we coerce to int. Skip malformed entries
        # quietly.
        for k, v in (data.get("buttons_panel_anchors") or {}).items():
            try:
                pi = int(k)
                if v and len(v) == 3:
                    buttons_panel_anchors[pi] = [str(v[0]), int(v[1]), int(v[2])]
            except (TypeError, ValueError):
                pass
        for k, v in (data.get("hotbar_panel_pages") or {}).items():
            try:
                hotbar_panel_pages[int(k)] = int(v)
            except (TypeError, ValueError):
                pass

        # Legacy format: absolute positions. Convert to anchors using the
        # window size that was saved alongside them (falling back to the
        # current window size if missing).
        if not panel_anchors and "panel_positions" in data:
            legacy_win = data.get("window") or [WIDTH, HEIGHT]
            sw, sh = int(legacy_win[0]), int(legacy_win[1])
            print(f"[OmniWatch] Migrating legacy absolute positions "
                  f"(window was {sw}x{sh}) to anchored form.")
            for k, pos in data.get("panel_positions", {}).items():
                # We don't know the panel's exact size, but ROW_MIN_H is a
                # safe approximation for corner-classification purposes.
                panel_anchors[k] = anchor_for_pos(int(pos[0]), int(pos[1]),
                                                  PANEL_W, ROW_MIN_H, sw, sh)
            lep = data.get("equip_pos")
            if lep and equip_anchor is None:
                equip_anchor = anchor_for_pos(int(lep[0]), int(lep[1]),
                                              EV_PANEL_W, EV_PANEL_H, sw, sh)

        print(f"[OmniWatch] Loaded layout from {LAYOUT_FILE}")
        print(f"  panel_anchors = {dict(panel_anchors)}")
        print(f"  panel_scales  = {dict(panel_scales)}")
        print(f"  equip_anchor  = {equip_anchor}")
        print(f"  equip_scale   = {equip_scale}")

        # Sim window position/size. Stored as 2-element lists.
        # Mutate the existing list rather than rebinding so the various
        # references in the codebase (drag handler, etc.) still see the
        # restored values.
        swp = data.get("sim_window_pos")
        if swp and len(swp) == 2:
            sim_window_pos[0] = int(swp[0])
            sim_window_pos[1] = int(swp[1])
        sws = data.get("sim_window_size")
        if sws and len(sws) == 2:
            sim_window_size[0] = int(sws[0])
            sim_window_size[1] = int(sws[1])
    except Exception as e:
        print(f"[OmniWatch] Could not load layout: {e}")

def _pre_select_active_view_char():
    """Pick the most-recently-modified per-character folder under
    USER_DIR and rebind LAYOUT_FILE et al. to its paths BEFORE the
    eager load_layout() runs at module import time.

    Reason: with per-character storage, the canonical layout file
    is at OmniWatch/<charname>/omniwatch_layout.json. The PLAYER
    packet that tells us which character is logged in arrives some
    milliseconds AFTER the main loop starts — so without this
    pre-selection, the first frames render with default positions,
    and panels visibly snap into place once the packet arrives.

    Picking the most-recent folder is a safe heuristic: it's
    almost always the character the user last played as. Once the
    real PLAYER packet arrives, _on_char_change still fires; if
    the live character matches what we pre-selected (the common
    case), no second layout reload happens and there's no jump."""
    global active_view_char
    try:
        candidates = []
        for entry in os.listdir(USER_DIR):
            full = os.path.join(USER_DIR, entry)
            if (os.path.isdir(full)
                    and not entry.startswith(".")
                    and not entry.startswith("_")
                    and entry.lower() != "logs"):
                lp = os.path.join(full, "omniwatch_layout.json")
                if os.path.exists(lp):
                    candidates.append((os.path.getmtime(lp), entry))
        if not candidates:
            return
        candidates.sort(reverse=True)
        guess = candidates[0][1]
        active_view_char = guess
        _rebuild_path_constants()
        print(f"[OmniWatch] pre-selected most-recent char folder: {guess}")
    except Exception as e:
        print(f"[OmniWatch] pre-select char folder failed: {e!r}")

_pre_select_active_view_char()
# Reload settings now that path constants point at the active char's
# folder. The earlier `settings = load_settings()` at module-import
# time read from USER_DIR root (or whatever the path was before per-
# char paths were rebuilt). Without this reload, set_setting() writes
# to the per-char file but reads from a stale dict — saves don't
# persist visibly across launches.
settings = load_settings()
load_layout()

# Reload buttons config from the now-per-char path. Same reasoning as
# settings/layout above: the initial `buttons_config = load_buttons_config()`
# at import time read from USER_DIR root before the per-char rebind,
# so without this reload the in-memory list is stale and the user's
# saved icons/labels don't appear after a restart.
buttons_config = load_buttons_config()

# After layout loads, force the panel-visibility globals to match the
# Settings menu values. Settings is the user-facing control; layout
# persists position/scale. Without this sync, a Settings toggle from
# a previous session would be silently overridden by the older layout
# value — confusing.
dps_panel_visible     = bool(setting("show_dps"))
buttons_panel_visible = bool(setting("show_hotbar"))

# Apply always-on-top if it was persisted ON. We do this here (after
# pygame's window is up — it was created earlier in the file at
# set_mode time) rather than in apply_setting_side_effects on load
# because the latter isn't called for the initial dict population.
if setting("always_on_top"):
    _apply_always_on_top(True)

# Apply persisted window opacity. Same reasoning as always_on_top:
# the side-effect dispatcher isn't fired on initial load, so we apply
# it explicitly. Skipped at exactly 100% (default, fully opaque)
# because there's no functional difference and we don't need to set
# the layered-window bit on a window that doesn't need it.
_persisted_opacity = setting("window_opacity")
if _persisted_opacity and int(_persisted_opacity) < 100:
    _apply_window_opacity(_persisted_opacity)

# Apply persisted transparent-background flag. This happens AFTER the
# opacity apply above so the colorkey bit composes with the chosen
# alpha (LWA_ALPHA | LWA_COLORKEY together gives "panels at chosen
# opacity, BG punched out completely").
if setting("transparent_background"):
    _apply_transparent_background(True)

# Force sim_mode OFF at startup regardless of persisted value. The sim
# is a transient debug/test mode — it shouldn't survive a restart.
#
# This used to be a half-measure: we'd reset settings["sim_mode"] but
# only if it was already True, and we never told lua. Result: if lua
# happened to be in sim mode when python died, lua would still be in
# sim mode on relaunch, and the next user-clicked toggle would just
# flip the wrong direction (lua: on→off, python display: off→on).
#
# Now we ALWAYS write False AND ALWAYS push SIM_MODE|off to lua at
# startup (with a brief retry since lua's UDP listener may not have
# bound yet — at most 5 attempts at 100ms intervals). Lua is the
# source of truth; we make it match what python believes.
settings["sim_mode"] = False
save_settings()
sim_window_open = False

# Push SIM_MODE|off to lua. Retry a few times in case lua's listener
# hasn't bound yet (port 5011 inbound). Each attempt is cheap and
# silent — duplicates are harmless since lua's set_active(false) is
# idempotent.
def _ow_force_lua_sim_off():
    import threading, time as _t
    def _retry():
        for _ in range(5):
            try:
                _sok = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                try:
                    _sok.sendto(b"SIM_MODE|off", ("127.0.0.1", 5011))
                finally:
                    _sok.close()
            except Exception:
                pass
            _t.sleep(0.1)
    threading.Thread(target=_retry, daemon=True).start()
_ow_force_lua_sim_off()

DEBUFF_KEYWORDS = [
    "Poison", "Paralyze", "Blind", "Silence", "Slow", "Petrification",
    "Curse", "Doom", "Sleep", "Bind", "Weight", "Stun", "Bio", "Dia"
]

# ── Colours ─────────────────────────────────────────────────────────────────
COL_BG        = (15,  15,  20)
COL_PANEL     = (25,  25,  32)
COL_HEADER    = (20,  20,  28)
COL_BORDER    = (50,  50,  65)
COL_NAME      = (220, 220, 220)
# HP band colors: 76-100 green, 51-75 yellow, 31-50 orange, 0-30 red
COL_HP_HI     = ( 60, 180,  80)
COL_HP_MID    = (200, 180,  40)
COL_HP_ORANGE = (230, 130,  40)
COL_HP_LOW    = (200,  50,  50)
COL_HP_FLASH  = (255,  80,  80)
COL_MP        = ( 60, 100, 210)
# TP band colors: 0-999 yellow, 1000-1999 light green, 2000-2999 medium green, 3000 bright green
COL_TP_LOW    = (200, 180,  40)
COL_TP_MID    = (140, 210, 110)
COL_TP_HI     = ( 70, 180,  70)
COL_TP_MAX    = ( 40, 230,  80)
COL_TP        = COL_TP_LOW   # legacy alias (unused after tp_color())
COL_BAR_BG    = ( 35,  35,  45)
COL_BUFF      = ( 60, 200,  90)
COL_DEBUFF    = (220,  70,  70)
COL_DIVIDER   = ( 45,  45,  60)
COL_CLOCK     = (200, 220, 255)
COL_MOON      = (190, 190, 210)
COL_LABEL_DIM = (110, 110, 130)
COL_SLOT_BG   = ( 30,  30,  40)
COL_SLOT_BDR  = ( 55,  55,  72)
COL_SLOT_FULL = ( 45,  45,  58)
COL_SLOT_TEXT = (170, 170, 190)
COL_SLOT_EMPTY= ( 50,  50,  65)
COL_EV_HEADER = ( 22,  22,  30)
COL_EV_TITLE  = (160, 160, 200)

# Slot label for each display_pos (matches core.lua slotMapping order)
SLOT_LABELS = [
    "Main",  "Sub",    "Range", "Ammo",
    "Head",  "Neck",   "L.Ear", "R.Ear",
    "Body",  "Hands",  "L.Rng", "R.Rng",
    "Back",  "Waist",  "Legs",  "Feet",
]

# ── Layout ───────────────────────────────────────────────────────────────────
HEADER_H     = 36
PANEL_X      = 20
ROW_PAD      = 8
START_Y      = HEADER_H + 12   # rows start below header
BAR_W        = 240
BAR_H        = 12
BAR_GAP      = 16
NAME_W       = 120
BARS_X_OFF   = NAME_W + 12
BUFF_X_OFF   = BARS_X_OFF + BAR_W + 16
BUFF_COL_W   = 110
DEBUFF_COL_W = 110
DEBUFF_X_OFF = BUFF_X_OFF + BUFF_COL_W + 12
BUFF_LINE_H  = 15
ROW_MIN_H    = 96
ROW_PAD_V    = 12
PANEL_W      = BARS_X_OFF + BAR_W + 16 + BUFF_COL_W + 12 + DEBUFF_COL_W + 20

# ── Equip Viewer layout ───────────────────────────────────────────────────────
EV_COLS      = 4
EV_ROWS      = 4
EV_SLOT_SIZE = 52          # px per cell (icon area)
EV_PAD       = 6           # inner padding around icon
EV_TITLE_H   = 22          # header label height
EV_BORDER    = 1
EV_GRID_W    = EV_COLS * EV_SLOT_SIZE
EV_GRID_H    = EV_ROWS * EV_SLOT_SIZE
EV_PANEL_W   = EV_GRID_W + 2
EV_PANEL_H   = EV_TITLE_H + EV_GRID_H + 2
EV_X         = PANEL_X     # anchored to left edge, same as party panels
# EV_Y is computed each frame from the bottom of the last party row


# ── Helpers ──────────────────────────────────────────────────────────────────
def hp_color(hpp, flashing):
    """HP bar color by percentage.
    76-100 = green, 51-75 = yellow, 31-50 = orange, 0-30 = red (flashes)."""
    if hpp <= 30:
        return COL_HP_FLASH if flashing else COL_HP_LOW
    if hpp <= 50:
        return COL_HP_ORANGE
    if hpp <= 75:
        return COL_HP_MID
    return COL_HP_HI

def tp_color(tp):
    """TP bar color by absolute TP value.
    0-999 = yellow, 1000-1999 = light green, 2000-2999 = medium green,
    3000+ pulses between COL_TP_MAX and a brighter shade for visibility."""
    if tp >= 3000:
        # Pulse at ~1.5 Hz between COL_TP_MAX and a brighter highlight.
        # Mirrors the hate-pulse cadence so it feels consistent.
        t = time.time()
        phase = (math.sin(t * 6.0) + 1.0) * 0.5  # 0..1
        base = COL_TP_MAX
        bright = (255, 255, 200)
        r = int(base[0] + (bright[0] - base[0]) * phase)
        g = int(base[1] + (bright[1] - base[1]) * phase)
        b = int(base[2] + (bright[2] - base[2]) * phase)
        return (r, g, b)
    if tp >= 2000:
        return COL_TP_HI
    if tp >= 1000:
        return COL_TP_MID
    return COL_TP_LOW

def draw_bar(surface, x, y, w, h, percent, color, label=None, label_font=None):
    pygame.draw.rect(surface, COL_BAR_BG, (x, y, w, h))
    fill_w = max(0, int(w * min(percent, 1.0)))
    if fill_w > 0:
        pygame.draw.rect(surface, color, (x, y, fill_w, h))
    pygame.draw.rect(surface, COL_BORDER, (x, y, w, h), 1)
    if label:
        lf = label_font or font_label
        # Draw a 1-pixel dark outline behind the label for readability
        # against any fill color (especially bright greens).
        shadow = lf.render(label, True, (0, 0, 0))
        main   = lf.render(label, True, (255, 255, 255))
        lx = x + 3
        ly = y + (h - main.get_height()) // 2
        for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            surface.blit(shadow, (lx + dx, ly + dy))
        surface.blit(main, (lx, ly))

def classify(buff_names, buff_ids=None):
    """Split buff list into (buffs, debuffs), applying hide/priority/alias
    rules. Each entry is first classified as buff vs debuff (by keyword
    match), THEN run through the context-aware blacklist so a name in
    hide_party_debuffs only hides debuffs (not its buff sibling, if a
    name happens to match both contexts). Priority entries come first
    within each bucket, in the order listed in the config file. Aliases
    are applied at display time.

    If `buff_ids` is provided, returns 4 lists:
      (buff_names, buff_ids_aligned, debuff_names, debuff_ids_aligned)
    Otherwise returns 2 lists (buff_names, debuff_names) — back-compat
    for callers that don't track IDs (e.g. older code paths and the
    standalone buff timer panel).
    """
    has_ids = buff_ids is not None
    # Walk both lists in lockstep so the bucket assignments preserve
    # the matching id for each name.
    if has_ids:
        # Tolerate length mismatch (defensive against legacy feeds that
        # filled `buffs` but not `buff_ids`): pad with None.
        if len(buff_ids) < len(buff_names):
            buff_ids = list(buff_ids) + [None] * (len(buff_names) - len(buff_ids))
        buff_pairs   = []      # list of (name, id) for the buffs bucket
        debuff_pairs = []      # list of (name, id) for the debuffs bucket
        for i, b in enumerate(buff_names):
            bid = buff_ids[i] if i < len(buff_ids) else None
            if any(k.lower() in b.lower() for k in DEBUFF_KEYWORDS):
                if not is_hidden_in(b, "party_debuff"):
                    debuff_pairs.append((b, bid))
            else:
                if not is_hidden_in(b, "party_buff"):
                    buff_pairs.append((b, bid))
    else:
        buffs, debuffs = [], []
        for b in buff_names:
            if any(k.lower() in b.lower() for k in DEBUFF_KEYWORDS):
                if not is_hidden_in(b, "party_debuff"):
                    debuffs.append(b)
            else:
                if not is_hidden_in(b, "party_buff"):
                    buffs.append(b)

    # Sort so priority items appear first, preserving the user's priority order.
    def _sort_key_name(name):
        lower = name.lower()
        if lower in _buff_priority_set:
            for i, p in enumerate(_buff_priority):
                if p.lower() == lower:
                    return (0, i)
        return (1, 0)
    def _sort_key_pair(pair):
        return _sort_key_name(pair[0])

    if has_ids:
        buff_pairs.sort(key=_sort_key_pair)
        debuff_pairs.sort(key=_sort_key_pair)
        # Apply aliases at display time. IDs travel through unchanged.
        buff_names_out   = [display_name(p[0]) for p in buff_pairs]
        buff_ids_out     = [p[1] for p in buff_pairs]
        debuff_names_out = [display_name(p[0]) for p in debuff_pairs]
        debuff_ids_out   = [p[1] for p in debuff_pairs]
        return (buff_names_out, buff_ids_out,
                debuff_names_out, debuff_ids_out)
    else:
        buffs.sort(key=_sort_key_name)
        debuffs.sort(key=_sort_key_name)
        buffs   = [display_name(b) for b in buffs]
        debuffs = [display_name(d) for d in debuffs]
        return buffs, debuffs

def scaled_panel_dims(scale):
    """Return a dict of scaled geometry + fonts for a party panel at the given scale."""
    s = scale
    bar_w        = int(BAR_W        * s)
    bar_h        = max(4, int(BAR_H * s))
    bar_gap      = max(6, int(BAR_GAP * s))
    name_w       = int(NAME_W       * s)
    bars_x_off   = name_w + int(12 * s)
    buff_col_w   = int(BUFF_COL_W   * s)
    debuff_col_w = int(DEBUFF_COL_W * s)
    buff_x_off   = bars_x_off + bar_w + int(16 * s)
    debuff_x_off = buff_x_off + buff_col_w + int(12 * s)
    # Buff/debuff column lines: smaller than the main panel text so more
    # entries fit per row when the user enables 'specific_buff_names'
    # (Honor March vs March is longer, so we win some space back). The
    # line height is paired with the font so they scale together.
    buff_font_px = max(7, int(8 * s))
    buff_line_h  = max(7, int((BUFF_LINE_H - 5) * s))
    row_min_h    = int(ROW_MIN_H * s)
    row_pad_v    = int(ROW_PAD_V * s)
    panel_w      = bars_x_off + bar_w + int(16 * s) + buff_col_w + int(12 * s) + debuff_col_w + int(20 * s)
    return {
        "s": s,
        "bar_w": bar_w, "bar_h": bar_h, "bar_gap": bar_gap,
        "name_w": name_w, "bars_x_off": bars_x_off,
        "buff_col_w": buff_col_w, "debuff_col_w": debuff_col_w,
        "buff_x_off": buff_x_off, "debuff_x_off": debuff_x_off,
        "buff_line_h": buff_line_h,
        "row_min_h": row_min_h, "row_pad_v": row_pad_v,
        "panel_w": panel_w,
        "f_name":      get_font("Consolas", 16 * s, bold=True),
        "f_small":     get_font("Consolas", 13 * s),
        "f_buff":      get_font("Consolas", buff_font_px),
        "f_label":     get_font("Consolas", 12 * s),
        "f_bar_label": get_font("Consolas", 12 * s, bold=True),
    }

def row_height(member, scale=1.0):
    """Panel height for a given member.

    Previously this grew to fit all buffs/debuffs, which caused panels below
    to get covered when a neighbor's buff list got long. Now height is fixed
    at row_min_h and overflow is handled at render time via '+N more' + scroll.
    The `member` argument is kept for API compatibility but ignored.
    """
    return scaled_panel_dims(scale)["row_min_h"]


def scaled_ally_dims(scale):
    """Geometry for an alliance row.

    Alliance rows are a simplified party row: name + jobs on the left,
    HP/MP/TP bars on the right. No buff/debuff columns. Shorter overall
    height since there's less to display. Used for alliance party 1 and
    alliance party 2 (a10..a15, a20..a25).
    """
    s = scale
    bar_w        = int(160 * s)        # narrower bars than main party
    bar_h        = max(3, int(8 * s))  # thinner too
    bar_gap      = max(4, int(11 * s))
    name_w       = int(110 * s)
    bars_x_off   = name_w + int(10 * s)
    row_min_h    = int(56 * s)
    row_pad_v    = int(8 * s)
    panel_w      = bars_x_off + bar_w + int(14 * s)
    return {
        "s": s,
        "bar_w": bar_w, "bar_h": bar_h, "bar_gap": bar_gap,
        "name_w": name_w, "bars_x_off": bars_x_off,
        "row_min_h": row_min_h, "row_pad_v": row_pad_v,
        "panel_w": panel_w,
        "f_name":  get_font("Consolas", 13 * s, bold=True),
        "f_label": get_font("Consolas", 10 * s),
        "f_bar_label": get_font("Consolas", 9 * s),
    }


def ally_row_height(scale=1.0):
    return scaled_ally_dims(scale)["row_min_h"]


def draw_ally_panel(surface, x, y, member, scale=1.0):
    """Render a single alliance member panel.

    Smaller than the main party panel. Layout: name + job/sub line on the
    left, three thin bars (HP/MP/TP) on the right. No buff/debuff columns,
    no targeting indicator (alliance targeting context is rare and the
    indicator clutters small panels).
    """
    d  = scaled_ally_dims(scale)
    rh = d["row_min_h"]
    pw = d["panel_w"]

    pygame.draw.rect(surface, COL_PANEL,  (x, y, pw, rh), border_radius=4)
    pygame.draw.rect(surface, COL_BORDER, (x, y, pw, rh), 1, border_radius=4)
    draw_accent_stripe(surface, x, y, rh, ACCENT_ALLY)

    # Name + job/sub stacked on the left.
    name_surf = d["f_name"].render(member.get("name", "?"), True, COL_NAME)
    mj  = member.get("main_job", "")
    mjl = member.get("main_lvl", 0)
    sj  = member.get("sub_job",  "")
    sjl = member.get("sub_lvl",  0)
    job_str = ""
    if mj:
        job_str = f"{mj}{mjl}" if mjl else mj
        if sj:
            job_str += f" / {sj}{sjl}" if sjl else f" / {sj}"
    job_surf = d["f_label"].render(job_str, True, COL_LABEL_DIM) if job_str else None

    block_h = name_surf.get_height() + (job_surf.get_height() + 2 if job_surf else 0)
    block_y = y + (rh - block_h) // 2
    surface.blit(name_surf, (x + int(8 * scale), block_y))
    if job_surf:
        surface.blit(job_surf, (x + int(8 * scale),
                                block_y + name_surf.get_height() + 2))

    # Three bars on the right, vertically centered.
    bx = x + d["bars_x_off"]
    bars_block_h = d["bar_h"] * 3 + d["bar_gap"] * 2
    by = y + (rh - bars_block_h) // 2

    hpp = member.get("hpp", 0)
    hp  = member.get("hp",  0)
    mp  = member.get("mp",  0)
    tp  = member.get("tp",  0)
    hc = hp_color(hpp, flash) if 'flash' in globals() else (200, 80, 80)
    draw_bar(surface, bx, by,
             d["bar_w"], d["bar_h"], hpp / 100.0, hc,
             f"HP {hp} ({hpp}%)", d["f_bar_label"])
    draw_bar(surface, bx, by + d["bar_gap"],
             d["bar_w"], d["bar_h"], min(mp / 1500, 1.0), COL_MP,
             f"MP {mp}", d["f_bar_label"])
    draw_bar(surface, bx, by + d["bar_gap"] * 2,
             d["bar_w"], d["bar_h"], min(tp / 3000, 1.0), tp_color(tp),
             f"TP {tp}", d["f_bar_label"])


# ── Recast panel ──────────────────────────────────────────────────────────
# Vertical stack of horizontal progress bars showing currently-cooling-down
# spells and abilities. Each entry: name on left, countdown on right,
# fill from left-to-right showing progress (empty = just cast, full = ready).
# Driven by recast_state (populated by RECAST_BATCH packets from lua).
RECAST_PANEL_PAD       = 6      # internal padding
RECAST_PANEL_BAR_H     = 18     # height per bar
RECAST_PANEL_BAR_GAP   = 3      # vertical gap between bars
RECAST_PANEL_BAR_W     = 220    # base bar width (scaled)

# Tracks the peak recast value we've seen for each entry within its current
# cooldown cycle. Used to compute the fill ratio so each bar starts empty
# and fills as the countdown progresses toward zero. Dict shape:
#   {(kind, id): {"max_secs": float, "first_seen_at": float}}
# Cleared when an entry leaves recast_state (i.e. its cooldown ended) so
# the next cast starts fresh.
_recast_peaks = {}

# Tracks recently-ready entries so they flash briefly before disappearing.
# When an entry that was in recast_state on the previous tick is no longer
# present, the receive loop pops it into here. The render loop draws these
# alongside live recasts, blinking, until RECAST_FLASH_SEC has elapsed.
# Dict shape: {(kind, id): {"name": str, "ready_at": float}}
_recast_flashes = {}
RECAST_FLASH_SEC = 2.0  # how long the green ready-flash plays

# Tracks recently-expired buffs so they flash briefly (red) before
# disappearing. Same mechanism as _recast_flashes but rendered as a red
# wear-off warning instead of a green ready signal. Dict keyed by buff_id.
_buff_flashes = {}
BUFF_FLASH_SEC = 2.0
# When this many seconds remain on a buff, it begins flashing in-panel
# (warning: about to expire). Distinct from the wear-off flash which
# fires AFTER it's gone. user prefers a tight 2-second window so the
# warning isn't visible long enough to feel naggy.
BUFF_EXPIRY_WARNING_SEC = 2.0


def _recast_color(secs):
    """Red for long waits, transitioning through yellow to green near zero."""
    if secs >= 60:    return (220, 80, 80)        # solid red
    if secs >= 30:    return (220, 140, 80)       # red-orange
    if secs >= 10:    return (220, 200, 80)       # yellow
    if secs >  0:     return (160, 220, 100)      # yellow-green
    return (120, 220, 120)                         # green (READY)


def _format_recast_time(secs):
    if secs <= 0:
        return "READY"
    if secs >= 60:
        m = int(secs // 60)
        s = int(secs % 60)
        return f"{m}:{s:02d}"
    return f"{secs:.1f}"


def scaled_recast_dims(scale):
    s = scale
    return {
        "s":         s,
        "bar_w":     max(120, int(RECAST_PANEL_BAR_W * s)),
        "bar_h":     max(12, int(RECAST_PANEL_BAR_H * s)),
        "bar_gap":   max(2,  int(RECAST_PANEL_BAR_GAP * s)),
        "pad":       max(4,  int(RECAST_PANEL_PAD * s)),
        "f_entry":   get_font("Consolas", max(9, int(12 * s)), bold=True),
        "f_label":   get_font("Consolas", max(8, int(11 * s))),
    }


def recast_panel_size(scale, entries):
    """Compute (width, height) for the vertical bar stack.

    Width is fixed by scale (constant column). Height grows with entry
    count: pad + N * (bar_h + gap) - gap + pad. Empty list shows a
    minimal placeholder so the panel is still findable in setup mode.
    """
    d = scaled_recast_dims(scale)
    pad   = d["pad"]
    bar_w = d["bar_w"]
    bar_h = d["bar_h"]
    gap   = d["bar_gap"]
    if not entries:
        return (bar_w + pad * 2, bar_h + pad * 2)
    total_h = pad + len(entries) * (bar_h + gap) - gap + pad
    return (bar_w + pad * 2, total_h)


def draw_recast_panel(surface, x, y, entries, scale=1.0, locked=False):
    """Render vertical stack of horizontal recast bars at (x, y).

    Each bar: name text on left, time text on right, fill from left as
    the cooldown elapses (empty = just cast, full = ready). Color is
    driven by remaining seconds, not fill amount, so a long-cycle ability
    near ready looks the same color as a short-cycle one near ready.
    """
    d = scaled_recast_dims(scale)
    pw, ph = recast_panel_size(scale, entries)
    pad   = d["pad"]
    bar_w = d["bar_w"]
    bar_h = d["bar_h"]
    gap   = d["bar_gap"]

    # Panel background.
    pygame.draw.rect(surface, COL_PANEL,  (x, y, pw, ph), border_radius=4)
    pygame.draw.rect(surface, COL_BORDER, (x, y, pw, ph), 1, border_radius=4)
    draw_accent_stripe(surface, x, y, ph, ACCENT_RECAST)

    if not entries:
        title_surf = d["f_label"].render("Recast", True, COL_LABEL_DIM)
        surface.blit(title_surf, (x + pad,
                                   y + (ph - title_surf.get_height()) // 2))
        return pw, ph

    # Track peaks for fill calculation. Real entries have a (kind,id)
    # identity; setup-mode mocks don't, so we use the name as a fallback.
    # Flash entries are skipped — their secs is 0 and they shouldn't
    # influence the peak (which represents the cast-moment maximum).
    _now = time.time()
    seen_keys = set()
    for e in entries:
        key = (e.get("kind", "?"), e.get("id", e.get("name")))
        seen_keys.add(key)
        if e.get("is_flash"):
            continue
        secs = e.get("secs", 0.0)
        peak = _recast_peaks.get(key)
        if peak is None or secs > peak["max_secs"]:
            _recast_peaks[key] = {"max_secs": max(secs, 0.1),
                                   "first_seen_at": _now}

    # Prune peaks for entries no longer in the panel (cooldown completed).
    stale = [k for k in _recast_peaks if k not in seen_keys]
    for k in stale:
        del _recast_peaks[k]

    # Draw each bar.
    by = y + pad
    for e in entries:
        secs    = e.get("secs", 0.0)
        name    = e.get("name", "?")
        is_flash = e.get("is_flash", False)
        bx = x + pad

        if is_flash:
            # Just-ready flash: bar fully filled, alternating between
            # bright green and dim green so it blinks. ~3 Hz blink rate.
            age = e.get("flash_age", 0.0)
            phase = int(age * 6) % 2   # toggles every ~0.17s
            bright = phase == 0
            col      = (140, 255, 140) if bright else (60, 160, 60)
            fill_col = (40, 130, 60)   if bright else (25, 75, 35)
            # Trough.
            pygame.draw.rect(surface, (30, 30, 40),
                              (bx, by, bar_w, bar_h), border_radius=3)
            # Fully filled.
            pygame.draw.rect(surface, fill_col,
                              (bx, by, bar_w, bar_h), border_radius=3)
            # Border.
            pygame.draw.rect(surface, COL_BORDER,
                              (bx, by, bar_w, bar_h), 1, border_radius=3)
            # Text overlays.
            name_surf = d["f_entry"].render(name, True, col)
            time_surf = d["f_entry"].render("READY", True, col)
            text_y    = by + (bar_h - name_surf.get_height()) // 2
            surface.blit(name_surf, (bx + 4, text_y))
            surface.blit(time_surf, (bx + bar_w - time_surf.get_width() - 4,
                                      text_y))
        else:
            col   = _recast_color(secs)
            key   = (e.get("kind", "?"), e.get("id", name))
            peak  = _recast_peaks.get(key, {}).get("max_secs", max(secs, 0.1))
            # Fill ratio: 0 when freshly cast (secs == peak), 1 when ready.
            # Clamp so floating-point drift doesn't leak past edges.
            ratio = 1.0 - (secs / peak) if peak > 0 else 1.0
            ratio = max(0.0, min(1.0, ratio))

            # Background trough for the bar.
            pygame.draw.rect(surface, (30, 30, 40),
                              (bx, by, bar_w, bar_h), border_radius=3)
            # Filled portion.
            fill_w = int(bar_w * ratio)
            if fill_w > 0:
                # Slightly darker fill so text on top still reads well.
                fill_col = tuple(int(c * 0.55) for c in col)
                pygame.draw.rect(surface, fill_col,
                                  (bx, by, fill_w, bar_h), border_radius=3)
            # Border.
            pygame.draw.rect(surface, COL_BORDER,
                              (bx, by, bar_w, bar_h), 1, border_radius=3)

            # Text overlays: name on left, countdown on right.
            time_str  = _format_recast_time(secs)
            name_surf = d["f_entry"].render(name, True, col)
            time_surf = d["f_entry"].render(time_str, True, col)
            text_y    = by + (bar_h - name_surf.get_height()) // 2
            surface.blit(name_surf, (bx + 4, text_y))
            surface.blit(time_surf, (bx + bar_w - time_surf.get_width() - 4,
                                      text_y))

        by += bar_h + gap

    return pw, ph


# ── Buff timer panel ──────────────────────────────────────────────────────
# Mirrors the recast panel: vertical stack of horizontal bars. Each bar
# shows buff name + time remaining. Bar STARTS full and empties as the
# buff burns down (opposite of recast which fills up). Color shifts from
# green (fresh) → yellow (warning) → red (about to wear off). Driven by
# buff_state. When a buff disappears from buff_state (wore off), it gets
# a brief red flash via _buff_flashes before being removed entirely.
BUFF_PANEL_PAD       = 6
BUFF_PANEL_BAR_H     = 18
BUFF_PANEL_BAR_GAP   = 3
BUFF_PANEL_BAR_W     = 220


# Tracks initial duration for each buff so we can draw a meaningful fill
# ratio. The lua side sends only seconds-remaining; the first time we see
# a given buff_id, we treat that value as the "max" for fill calculation.
# Wiped when buff_state loses the entry (it wore off).
_buff_durations = {}


def _buff_color(secs):
    """Green when fresh, yellow as warning approaches, red right before expire."""
    if secs >= 60:                          return (140, 220, 140)   # green
    if secs >= 30:                          return (200, 220, 140)   # yellow-green
    if secs >= BUFF_EXPIRY_WARNING_SEC:     return (220, 200, 80)    # yellow
    if secs >  3:                           return (220, 140, 80)    # orange
    return (220, 80, 80)                                              # red


def _format_buff_time(secs):
    """Format seconds as M:SS for >60s, else '12.3' decimal seconds.

    For exactly 0 we show '?:??' rather than '0.0' to communicate that
    the displayed timer is an estimated value that has elapsed but the
    buff is still active in player.buffs (we use base duration as a
    best guess for buffs already running when OmniWatch loaded). When
    the buff truly wears off, buff_loss fires and the entry is removed
    + flashed separately by the wear-off mechanism.
    """
    if secs <= 0:
        return "?:??"
    if secs >= 60:
        m = int(secs // 60)
        s = int(secs % 60)
        return f"{m}:{s:02d}"
    return f"{secs:.1f}"


def scaled_buff_dims(scale):
    s = scale
    return {
        "s":         s,
        "bar_w":     max(120, int(BUFF_PANEL_BAR_W * s)),
        "bar_h":     max(12, int(BUFF_PANEL_BAR_H * s)),
        "bar_gap":   max(2,  int(BUFF_PANEL_BAR_GAP * s)),
        "pad":       max(4,  int(BUFF_PANEL_PAD * s)),
        "f_entry":   get_font("Consolas", max(9, int(12 * s)), bold=True),
        "f_label":   get_font("Consolas", max(8, int(11 * s))),
    }


def buff_panel_size(scale, entries):
    d = scaled_buff_dims(scale)
    pad = d["pad"]; bar_w = d["bar_w"]; bar_h = d["bar_h"]; gap = d["bar_gap"]
    if not entries:
        return (bar_w + pad * 2, bar_h + pad * 2)
    total_h = pad + len(entries) * (bar_h + gap) - gap + pad
    return (bar_w + pad * 2, total_h)


def draw_buff_panel(surface, x, y, entries, scale=1.0, locked=False):
    """Render vertical stack of buff timer bars at (x, y). Returns (w, h).

    entries: list of dicts. Real entries: {buff_id, name, secs, source}.
             Flash entries: {flash:True, name, source, flash_age, secs:0}.
    """
    d = scaled_buff_dims(scale)
    pw, ph = buff_panel_size(scale, entries)
    pad = d["pad"]; bar_w = d["bar_w"]; bar_h = d["bar_h"]; gap = d["bar_gap"]

    pygame.draw.rect(surface, COL_PANEL,  (x, y, pw, ph), border_radius=4)
    pygame.draw.rect(surface, COL_BORDER, (x, y, pw, ph), 1, border_radius=4)
    draw_accent_stripe(surface, x, y, ph, ACCENT_BUFF)

    if not entries:
        title_surf = d["f_label"].render("Buffs", True, COL_LABEL_DIM)
        surface.blit(title_surf, (x + pad,
                                   y + (ph - title_surf.get_height()) // 2))
        return pw, ph

    # Update peak duration tracking. When we first see a buff_id, the
    # current secs IS the max (it can only count down from here). If we
    # see a higher value later it's because the buff was re-cast.
    seen_ids = set()
    for e in entries:
        if e.get("flash"):
            continue
        bid = e.get("buff_id")
        if bid is None:
            continue
        seen_ids.add(bid)
        secs = e.get("secs", 0.0)
        peak = _buff_durations.get(bid)
        if peak is None or secs > peak:
            _buff_durations[bid] = max(secs, 0.1)
    # Prune durations for buffs that left the panel.
    stale = [k for k in _buff_durations if k not in seen_ids
                                            and not any(
                                                ent.get("flash") and
                                                ent.get("buff_id") == k
                                                for ent in entries)]
    for k in stale:
        del _buff_durations[k]

    by = y + pad
    for e in entries:
        bx = x + pad
        is_flash = e.get("flash", False)
        secs = e.get("secs", 0.0)
        name = e.get("name", "?")
        is_other = name.startswith("~")

        if is_flash:
            # Wore-off flash: solid red bar blinking ~3 Hz.
            age = e.get("flash_age", 0.0)
            phase = int(age * 6) % 2
            bright = phase == 0
            col      = (255, 120, 120) if bright else (160, 60, 60)
            fill_col = (130, 40, 40)   if bright else (80, 25, 25)
            pygame.draw.rect(surface, (30, 30, 40),
                              (bx, by, bar_w, bar_h), border_radius=3)
            pygame.draw.rect(surface, fill_col,
                              (bx, by, bar_w, bar_h), border_radius=3)
            pygame.draw.rect(surface, COL_BORDER,
                              (bx, by, bar_w, bar_h), 1, border_radius=3)
            name_surf = d["f_entry"].render(name, True, col)
            time_surf = d["f_entry"].render("WORE OFF", True, col)
            text_y = by + (bar_h - name_surf.get_height()) // 2
            surface.blit(name_surf, (bx + 4, text_y))
            surface.blit(time_surf,
                         (bx + bar_w - time_surf.get_width() - 4, text_y))
        else:
            col = _buff_color(secs)
            bid = e.get("buff_id")
            peak = _buff_durations.get(bid, max(secs, 0.1))
            # Fill ratio: 1.0 fresh, 0.0 expired (decreasing).
            ratio = secs / peak if peak > 0 else 0.0
            ratio = max(0.0, min(1.0, ratio))

            pygame.draw.rect(surface, (30, 30, 40),
                              (bx, by, bar_w, bar_h), border_radius=3)
            fill_w = int(bar_w * ratio)
            if fill_w > 0:
                fill_col = tuple(int(c * 0.55) for c in col)
                pygame.draw.rect(surface, fill_col,
                                  (bx, by, fill_w, bar_h), border_radius=3)
            pygame.draw.rect(surface, COL_BORDER,
                              (bx, by, bar_w, bar_h), 1, border_radius=3)

            # Other-player buffs render dimmer to visually distinguish.
            text_col = col
            if is_other:
                text_col = tuple(int(c * 0.7) for c in col)

            time_str = _format_buff_time(secs)
            name_surf = d["f_entry"].render(name, True, text_col)
            time_surf = d["f_entry"].render(time_str, True, text_col)
            text_y = by + (bar_h - name_surf.get_height()) // 2
            surface.blit(name_surf, (bx + 4, text_y))
            surface.blit(time_surf,
                         (bx + bar_w - time_surf.get_width() - 4, text_y))

        by += bar_h + gap

    return pw, ph


# ── Per-panel accent palette ─────────────────────────────────────────────
# A 2px colored stripe along the left edge of each panel telegraphs what
# kind of panel it is at a glance — your eye finds "the red one" before
# reading the title. Colors are deliberately desaturated so they don't
# fight the data; they sit inside the existing border so the rounded-rect
# silhouette stays intact.
ACCENT_PARTY    = (140, 200, 220)   # cool blue — party
ACCENT_ALLY     = ( 90, 130, 160)   # dimmer blue — alliance
ACCENT_RECAST   = (200, 170,  70)   # amber — recasts (time-pressure feel)
ACCENT_BUFF     = (180, 140, 220)   # violet — buffs (status effects)
ACCENT_DPS      = (220, 100,  90)   # crimson — DPS (combat output)
ACCENT_BUTTONS  = (140, 200, 140)   # soft green — buttons (action)
ACCENT_STATS    = (210, 200, 130)   # parchment — stats (reference)
ACCENT_EQUIP    = (180, 160, 110)   # bronze — equipment
ACCENT_TARGET   = (220, 180, 110)   # warm amber — target

def draw_accent_stripe(surface, x, y, h, color, w=2):
    """Draw a vertical accent stripe `w` pixels wide at the left edge of
    a panel of height `h`. Stops 3px short of the top and bottom so the
    rounded corners aren't clipped through. Idempotent — call after the
    main border draw."""
    if h < 8:
        return
    pygame.draw.rect(surface, color,
                     (x + 1, y + 3, w, h - 6))


def draw_resize_grip(surface, x, y):
    """Draw a small diagonal-stripe resize handle at (x, y) bottom-right corner.

    Suppressed outside of setup mode: the grip is a UI affordance for
    resizing panels, but resizing is gated to setup_mode. Showing the
    grip in normal play just obscures content in the corners of small
    panels (target list, hotbar slots, etc.).
    """
    if not setup_mode:
        return
    g = RESIZE_GRIP
    pygame.draw.rect(surface, COL_SLOT_BG,  (x - g, y - g, g, g))
    pygame.draw.rect(surface, COL_SLOT_BDR, (x - g, y - g, g, g), 1)
    # Two diagonal hash lines for visual affordance.
    for off in (3, 7):
        pygame.draw.line(surface, COL_SLOT_TEXT,
                         (x - off,     y - 1),
                         (x - 1,       y - off))

def draw_header(surface, w):
    """Draw the game-clock header bar across the top."""
    global settings_button_rect
    hours, minutes, day_name, moon_pct, moon_phase = get_vana_time()

    # Background
    pygame.draw.rect(surface, COL_HEADER, (0, 0, w, HEADER_H))
    pygame.draw.line(surface, COL_BORDER, (0, HEADER_H - 1), (w, HEADER_H - 1))

    # ── Settings gear button (leftmost) ─────────────────────────────────────
    # Click to open/close the settings dropdown. Sized to roughly match
    # the clock height; uses a unicode gear glyph rendered in the day
    # font (bold, readable at small sizes).
    gear_size = 22
    gx = 6
    gy = (HEADER_H - gear_size) // 2
    settings_button_rect = pygame.Rect(gx, gy, gear_size, gear_size)
    # Hover / open feedback.
    mx, my = pygame.mouse.get_pos()
    is_hover = settings_button_rect.collidepoint(mx, my)
    btn_bg = (62, 62, 78) if (is_hover or settings_menu_open) else (44, 44, 54)
    btn_bdr = (180, 180, 200) if settings_menu_open else (100, 100, 115)
    pygame.draw.rect(surface, btn_bg, settings_button_rect, border_radius=3)
    pygame.draw.rect(surface, btn_bdr, settings_button_rect, 1, border_radius=3)
    # Hamburger menu: three horizontal bars drawn as rectangles. We
    # don't use a font glyph here because ⚙ / ☰ aren't reliably
    # available in all system fonts (Consolas in particular renders
    # both as tofu boxes on many Windows setups). Drawing the bars
    # ourselves means it always renders the same size and is
    # obviously a menu affordance.
    bar_color = (220, 220, 230)
    bar_w     = gear_size - 10
    bar_h     = 2
    bar_gap   = 4
    bar_x     = gx + (gear_size - bar_w) // 2
    # Center the 3-bar stack vertically.
    stack_h   = bar_h * 3 + bar_gap * 2
    bar_y     = gy + (gear_size - stack_h) // 2
    for i in range(3):
        pygame.draw.rect(
            surface, bar_color,
            (bar_x, bar_y + i * (bar_h + bar_gap), bar_w, bar_h),
        )

    # Reserve room for the gear button before the rest of the header
    # starts. Use max(PANEL_X, gear-right) so the existing layout still
    # gets its left margin even if the gear is small.
    cx = max(PANEL_X, gx + gear_size + 8)
    cy = HEADER_H // 2

    # ── Character display (plain text or dropdown depending on count) ─────
    # Single-character setup → just show the name as plain text (no pill,
    # no caret, not clickable). Multi-character setup → show as a pill
    # button that opens the picker dropdown. The "is this the live char"
    # red-border highlight is preserved for the multi case so users know
    # when they're viewing a non-live character's configs.
    global char_view_button_rect
    char_view_button_rect = None
    display_name = active_view_char or current_char_name
    if display_name:
        # Truncate to keep the header tidy.
        if len(display_name) > 14:
            display_name = display_name[:13] + "…"

        # How many characters have configs on this machine? Multi-char
        # rigs see a clickable picker; solo users see just the name.
        # We re-enumerate every frame because the count changes rarely
        # and the directory listing is essentially free.
        known_chars = list_known_characters()
        is_multi = len(known_chars) > 1

        is_off_live = (active_view_char and current_char_name
                       and active_view_char != current_char_name)
        cv_label = font_moon.render(display_name, True, (220, 220, 230))

        if not is_multi:
            # Single character: plain text, no interaction.
            cv_y = cy - cv_label.get_height() // 2
            surface.blit(cv_label, (cx, cv_y))
            cx += cv_label.get_width() + 8
        else:
            # Multi-character: pill button with caret. Click opens dropdown.
            cv_caret = font_moon.render(" ▼", True, (180, 180, 200))
            if cv_caret.get_width() < 4:
                cv_caret = font_moon.render(" v", True, (180, 180, 200))
            cv_w = cv_label.get_width() + cv_caret.get_width() + 12
            cv_h = 18
            cv_x = cx
            cv_y = cy - cv_h // 2
            char_view_button_rect = pygame.Rect(cv_x, cv_y, cv_w, cv_h)
            is_hover_cv = char_view_button_rect.collidepoint(mx, my)
            if is_off_live:
                cv_bg = (88, 60, 60) if is_hover_cv else (66, 44, 44)
                cv_bdr = (220, 140, 140)
            else:
                cv_bg = (62, 62, 78) if (is_hover_cv or char_view_dropdown_open) else (44, 44, 54)
                cv_bdr = (180, 180, 200) if char_view_dropdown_open else (100, 100, 115)
            pygame.draw.rect(surface, cv_bg, char_view_button_rect,
                             border_radius=3)
            pygame.draw.rect(surface, cv_bdr, char_view_button_rect, 1,
                             border_radius=3)
            surface.blit(cv_label,
                (cv_x + 6, cv_y + (cv_h - cv_label.get_height()) // 2))
            surface.blit(cv_caret,
                (cv_x + 6 + cv_label.get_width(),
                 cv_y + (cv_h - cv_caret.get_height()) // 2))
            cx += cv_w + 8

    # ── Time ────────────────────────────────────────────────────────────────
    time_str = f"{hours:02d}:{minutes:02d}"
    t_surf   = font_clock.render(time_str, True, COL_CLOCK)
    surface.blit(t_surf, (cx, cy - t_surf.get_height() // 2))
    cx += t_surf.get_width() + 6

    # small "VT" label
    vt_surf = font_moon.render("VT", True, COL_LABEL_DIM)
    surface.blit(vt_surf, (cx, cy - vt_surf.get_height() // 2))
    cx += vt_surf.get_width() + 18

    # ── Divider ─────────────────────────────────────────────────────────────
    pygame.draw.line(surface, COL_DIVIDER, (cx, 6), (cx, HEADER_H - 6))
    cx += 14

    # ── Day ─────────────────────────────────────────────────────────────────
    day_color = DAY_COLORS.get(day_name, COL_CLOCK)
    d_surf    = font_day.render(day_name, True, day_color)
    surface.blit(d_surf, (cx, cy - d_surf.get_height() // 2))
    cx += d_surf.get_width() + 18

    # ── Divider ─────────────────────────────────────────────────────────────
    pygame.draw.line(surface, COL_DIVIDER, (cx, 6), (cx, HEADER_H - 6))
    cx += 14

    # ── Moon ────────────────────────────────────────────────────────────────
    moon_label = font_moon.render("Moon:", True, COL_LABEL_DIM)
    surface.blit(moon_label, (cx, cy - moon_label.get_height() // 2))
    cx += moon_label.get_width() + 6

    moon_str  = f"{moon_phase}  {moon_pct}%"
    m_surf    = font_moon.render(moon_str, True, COL_MOON)
    surface.blit(m_surf, (cx, cy - m_surf.get_height() // 2))
    cx += m_surf.get_width()

    # ── Weather (right after moon, part of the left block) ────────────────
    # Renders the current FFXI weather as a colored label. Color uses the
    # weather's element family (Fire = red, Water = blue, etc.); double-
    # intensity weathers (Heat Wave, Squall, Blizzards, ...) brighten the
    # color so they stand out from their single-intensity counterparts.
    # When weather id is 0 (None) or unmapped, nothing draws.
    w_name, w_color = weather_display(zone_info.get("weather", 0))
    if w_name:
        # Divider before weather, matching the moon/day separator style.
        cx += 14
        pygame.draw.line(surface, COL_DIVIDER, (cx, 6), (cx, HEADER_H - 6))
        cx += 14
        w_lab_surf = font_moon.render("Weather:", True, COL_LABEL_DIM)
        surface.blit(w_lab_surf, (cx, cy - w_lab_surf.get_height() // 2))
        cx += w_lab_surf.get_width() + 6
        w_val_surf = font_moon.render(w_name, True, w_color)
        surface.blit(w_val_surf, (cx, cy - w_val_surf.get_height() // 2))
        cx += w_val_surf.get_width()

    # End-x of the left block. Used below to make sure the centered gil
    # doesn't overlap left content.
    left_block_end_x = cx

    # ── Gil (centered between left and right blocks) ───────────────────────
    # Drawn before the right-side zone info so we can clamp to "safe middle"
    # between the left block end and an estimated right-block start. If gil
    # would overlap, we shift it inward (still readable, just not perfectly centered).
    global inventory_button_rect
    inventory_button_rect = None
    if gearswap_gil >= 0:
        # Color: muted gold. "Gil" suffix in dim grey to keep the number prominent.
        gil_num_str = f"{gearswap_gil:,}"
        gil_col = (220, 195, 90)
        gil_dim = COL_LABEL_DIM
        gil_num_surf = font_clock.render(gil_num_str, True, gil_col)
        gil_g_surf   = font_moon.render(" Gil", True, gil_dim)
        gil_total_w  = gil_num_surf.get_width() + gil_g_surf.get_width()
        # Center on panel midpoint.
        ideal_x = (w - gil_total_w) // 2
        # Clamp so we don't bleed into the left block.
        min_x = left_block_end_x + 12
        gil_x = max(ideal_x, min_x)
        gy = cy - gil_num_surf.get_height() // 2
        surface.blit(gil_num_surf, (gil_x, gy))
        # Suffix " Gil" baseline-aligned with the number.
        gy2 = cy - gil_g_surf.get_height() // 2
        surface.blit(gil_g_surf, (gil_x + gil_num_surf.get_width(), gy2))

        # Inventory button: small "▼ Bags" pill right after Gil. Click
        # opens the dropdown that shows each bag's contents with BG-wiki
        # links. Gated on the show_inventory_button setting so users
        # who don't want it can hide it cleanly. Button rect is stashed
        # in inventory_button_rect for the main click handler.
        if setting("show_inventory_button"):
            inv_btn_x = gil_x + gil_total_w + 10
            inv_btn_y = cy - 9
            inv_btn_w, inv_btn_h = 60, 18
            inv_btn_rect = pygame.Rect(inv_btn_x, inv_btn_y,
                                       inv_btn_w, inv_btn_h)
            # Hover/open feedback.
            is_hover_inv = inv_btn_rect.collidepoint(mx, my)
            bg  = (62, 62, 78) if (is_hover_inv or inventory_dropdown_open) else (44, 44, 54)
            bdr = (180, 180, 200) if inventory_dropdown_open else (100, 100, 115)
            pygame.draw.rect(surface, bg,  inv_btn_rect, border_radius=3)
            pygame.draw.rect(surface, bdr, inv_btn_rect, 1, border_radius=3)
            # Tiny down-caret + "Bags" label.
            caret_color = (220, 220, 230)
            cax = inv_btn_x + 6
            cay = inv_btn_y + 6
            pygame.draw.polygon(surface, caret_color, [
                (cax, cay), (cax + 6, cay), (cax + 3, cay + 4)])
            bag_label = font_moon.render("Bags", True, caret_color)
            surface.blit(bag_label,
                (cax + 10, inv_btn_y + (inv_btn_h - bag_label.get_height()) // 2))
            inventory_button_rect = inv_btn_rect

    # ── Zone info on the right side ────────────────────────────────────────
    # Build parts left to right: ZoneTimer, Region, Zone (clickable),
    # Map, Coords. The timer prefix is "Zone Time - HH:MM:SS" (or
    # MM:SS if under an hour) and counts up from the last zone change.
    region = region_for_zone(zone_info["zone_id"])
    zname  = zone_info["zone_name"]
    mapi   = zone_info["map_index"]
    x, y, z = zone_info["x"], zone_info["y"], zone_info["z"]
    pos_grid = (zone_info.get("pos_str") or "").strip()

    # Format elapsed seconds as HH:MM:SS or MM:SS depending on length.
    # Skip the timer string entirely if we haven't seen a zone packet
    # yet (zone_entered_at is None) so the header doesn't show a
    # frozen "00:00".
    timer_text = ""
    if zone_entered_at is not None:
        elapsed = max(0, int(time.time() - zone_entered_at))
        h, rem = divmod(elapsed, 3600)
        m, s   = divmod(rem, 60)
        if h > 0:
            timer_text = f"Zone Time - {h:d}:{m:02d}:{s:02d}"
        else:
            timer_text = f"Zone Time - {m:02d}:{s:02d}"

    # Left part = timer + region. Right part = map + coords. Zone name
    # rendered separately so we can give it a hyperlink rect. The
    # pos_grid string ("(K-9)" style) is rendered as a dim suffix
    # right after the zone name so the BG-wiki hyperlink stays scoped
    # to just the name.
    left_pieces = []
    if timer_text:
        left_pieces.append(timer_text)
    if region:
        left_pieces.append(region)
    left_text = "  ".join(left_pieces)
    right_parts = []
    if mapi == -1:
        right_parts.append("Mog")
    elif mapi > 0:
        right_parts.append(f"Map {mapi}")
    if zname:
        right_parts.append(f"x:{x:.1f} y:{y:.1f} z:{z:.1f}")
    right_text = "  ".join(right_parts)

    if region or zname or right_text:
        # Measure all four pieces to right-align together: left, zone,
        # pos-grid suffix, right.
        gap = font_moon.size("  ")[0]
        sep_l   = (font_moon.size("  ")[0] if left_text and zname     else 0)
        sep_pos = (font_moon.size(" ")[0]  if zname and pos_grid      else 0)
        sep_r   = (font_moon.size("  ")[0] if (zname or pos_grid) and right_text else 0)

        l_surf = font_moon.render(left_text,  True, COL_LABEL_DIM) if left_text  else None
        z_surf = font_moon.render(zname,      True, COL_CLOCK)     if zname      else None
        p_surf = font_moon.render(pos_grid,   True, COL_LABEL_DIM) if pos_grid   else None
        r_surf = font_moon.render(right_text, True, COL_CLOCK)     if right_text else None

        total_w = ((l_surf.get_width() if l_surf else 0) + sep_l +
                   (z_surf.get_width() if z_surf else 0) + sep_pos +
                   (p_surf.get_width() if p_surf else 0) + sep_r +
                   (r_surf.get_width() if r_surf else 0))
        right_edge = w - PANEL_X
        draw_x = right_edge - total_w
        y_mid  = cy - (z_surf or l_surf or r_surf).get_height() // 2

        if l_surf:
            surface.blit(l_surf, (draw_x, y_mid))
            draw_x += l_surf.get_width() + sep_l
        if z_surf:
            zrect = pygame.Rect(draw_x, y_mid, z_surf.get_width(), z_surf.get_height())
            # Hover: brighten + underline.
            is_hover = zrect.collidepoint(pygame.mouse.get_pos())
            color = (255, 255, 180) if is_hover else COL_CLOCK
            z_surf = font_moon.render(zname, True, color)
            surface.blit(z_surf, (draw_x, y_mid))
            if is_hover:
                pygame.draw.line(surface, color,
                                 (draw_x, y_mid + z_surf.get_height() - 1),
                                 (draw_x + z_surf.get_width(), y_mid + z_surf.get_height() - 1))
            register_click_target(zrect, bgwiki_url(zname))
            draw_x += z_surf.get_width() + sep_pos
        if p_surf:
            surface.blit(p_surf, (draw_x, y_mid))
            draw_x += p_surf.get_width() + sep_r
        if r_surf:
            surface.blit(r_surf, (draw_x, y_mid))


# ── Settings dropdown menu ───────────────────────────────────────────────
# Renders a panel below the header gear button when settings_menu_open
# is True. Each row is one schema entry with an inline control:
#   - bool   → click anywhere on the row to toggle (or tap [ON]/[OFF])
#   - int    → [-]  value  [+]  buttons
#   - float  → same as int
#   - enum   → [<]  current  [>]  buttons cycle through options
#   - string → not yet implemented (will need a focus/text-edit pass)
#
# Hits are recorded in settings_menu_rects each frame so the click
# handler can resolve them.
def settings_menu_size():
    """Compute (w, h) of the menu based on the canonical section list
    and the schema's row count. Width is fixed; height grows with
    content. Empty sections still get a header + a small placeholder
    row so the user sees the full organizational structure."""
    width = 320
    row_h = 24
    sec_h = 22       # section header row
    placeholder_h = 18    # "(no settings yet)" row for empty sections
    pad   = 8
    # Group entries by section so we know which sections are empty.
    grouped = {sec: [] for sec in SETTINGS_SECTIONS}
    for s in SETTINGS_SCHEMA:
        sec = s.get("section")
        if sec in grouped:
            grouped[sec].append(s)
    height = pad
    for sec in SETTINGS_SECTIONS:
        height += sec_h
        if grouped[sec]:
            height += row_h * len(grouped[sec])
        else:
            height += placeholder_h
    height += pad
    return width, height


# ── Inventory dropdown ───────────────────────────────────────────────────────
# Bag-list view → click bag → bag-detail view (scrollable list of items).
# Each item row in detail view is a click target that opens its BG-Wiki
# page. A small ✓ appears next to items that match anything in the
# gearswap_referenced_items index.
#
# Bag display order matches FFXI menus (most-used first).
INVENTORY_BAG_ORDER = [
    ("inventory", "Inventory"),
    ("wardrobe",  "Wardrobe 1"),
    ("wardrobe2", "Wardrobe 2"),
    ("wardrobe3", "Wardrobe 3"),
    ("wardrobe4", "Wardrobe 4"),
    ("wardrobe5", "Wardrobe 5"),
    ("wardrobe6", "Wardrobe 6"),
    ("wardrobe7", "Wardrobe 7"),
    ("wardrobe8", "Wardrobe 8"),
    ("safe",      "Safe"),
    ("safe2",     "Safe 2"),
    ("storage",   "Storage"),
    ("locker",    "Locker"),
    ("satchel",   "Satchel"),
    ("sack",      "Sack"),
    ("case",      "Case"),
]


def _bgwiki_item_url(item_name):
    """Build a BG-Wiki URL for an item. Spaces → underscores; the rest
    of the name passes through. BG-Wiki is case-sensitive but tolerant
    of mismatches via redirects."""
    if not item_name:
        return ""
    return "https://www.bg-wiki.com/ffxi/" + item_name.replace(" ", "_")


def _inventory_panel_geometry():
    """Single source of truth for the inventory dropdown panel's
    position and size. The renderer, the dispatch function, and the
    outside-click envelope all call this so they stay in sync — when
    only one of them gets the clamping right, click hit-testing
    silently falls out of agreement with what was drawn.

    Returns (x, y, w, h) or None when the panel can't be positioned
    (no anchor button rect exists yet)."""
    if not inventory_button_rect:
        return None
    panel_w = 320
    panel_h = 380
    panel_x = inventory_button_rect.x
    panel_y = inventory_button_rect.bottom + 2
    # Horizontal clamp: don't bleed off the right edge.
    if panel_x + panel_w > WIDTH:
        panel_x = max(0, WIDTH - panel_w)
    # Vertical clamp: shrink height if we'd run off the bottom.
    if panel_y + panel_h > HEIGHT:
        panel_h = max(120, HEIGHT - panel_y)
    return (panel_x, panel_y, panel_w, panel_h)


def _item_in_gearswap(item_name):
    """True if `item_name` is referenced anywhere in the user's
    gearswap files (case-insensitive lookup)."""
    if not item_name or not gearswap_referenced_items:
        return False
    return item_name.lower() in gearswap_referenced_items


def draw_char_view_dropdown(surface):
    """Render the character-view dropdown if char_view_dropdown_open.
    Lists every character that has a subfolder under USER_DIR plus an
    explicit 'follow live character' option that tracks whoever is
    logged in. Populates char_view_dropdown_rects for click dispatch."""
    global char_view_dropdown_rects
    char_view_dropdown_rects = []
    if not char_view_dropdown_open:
        return
    if not char_view_button_rect:
        return

    # Discover characters via the shared helper. Same enumeration
    # logic the header uses to decide whether to show a dropdown.
    chars = list_known_characters()

    pad   = 6
    row_h = 20
    item_count = max(1, len(chars)) + 1   # +1 for the "Follow live" row
    panel_w = 180
    panel_h = item_count * row_h + pad * 2
    panel_x = char_view_button_rect.x
    panel_y = char_view_button_rect.bottom + 2
    if panel_x + panel_w > WIDTH:
        panel_x = max(0, WIDTH - panel_w)

    pygame.draw.rect(surface, (28, 28, 36),
                     (panel_x, panel_y, panel_w, panel_h),
                     border_radius=4)
    pygame.draw.rect(surface, (140, 140, 160),
                     (panel_x, panel_y, panel_w, panel_h), 1,
                     border_radius=4)

    f_row = pygame.font.SysFont("Consolas", 12)
    f_dim = pygame.font.SysFont("Consolas", 10, italic=True)
    cy = panel_y + pad

    # Top row: "Follow live character"
    follow_rect = pygame.Rect(panel_x + 2, cy, panel_w - 4, row_h)
    is_hover = follow_rect.collidepoint(pygame.mouse.get_pos())
    if is_hover:
        pygame.draw.rect(surface, (40, 40, 52), follow_rect)
    is_following = (active_view_char == current_char_name) and bool(current_char_name)
    follow_label = "● Follow live char" if is_following else "○ Follow live char"
    follow_color = (140, 220, 140) if is_following else (200, 200, 210)
    fs = f_row.render(follow_label, True, follow_color)
    surface.blit(fs, (panel_x + 8, cy + (row_h - fs.get_height()) // 2))
    char_view_dropdown_rects.append((follow_rect, {"kind": "follow_live"}))
    cy += row_h

    if not chars:
        msg = f_dim.render("(no saved characters yet)",
                           True, COL_LABEL_DIM)
        surface.blit(msg, (panel_x + 8, cy + 2))
        return

    # Per-character rows.
    for name in chars:
        row_rect = pygame.Rect(panel_x + 2, cy, panel_w - 4, row_h)
        is_hover = row_rect.collidepoint(pygame.mouse.get_pos())
        if is_hover:
            pygame.draw.rect(surface, (40, 40, 52), row_rect)
        is_active = (name == active_view_char)
        is_live   = (name == current_char_name)
        # Active/live indicators in the label.
        prefix = "●" if is_active else "○"
        suffix = "  (live)" if is_live else ""
        color = (220, 220, 230) if is_active else (180, 180, 195)
        label = f"{prefix} {name}{suffix}"
        ls = f_row.render(label, True, color)
        surface.blit(ls, (panel_x + 8, cy + (row_h - ls.get_height()) // 2))
        char_view_dropdown_rects.append((row_rect, {
            "kind": "select_char", "name": name,
        }))
        cy += row_h


def dispatch_char_view_dropdown_click(mx, my):
    """Handle clicks against the character-view dropdown. Returns True
    if the click was consumed."""
    global char_view_dropdown_open

    if char_view_button_rect and char_view_button_rect.collidepoint(mx, my):
        char_view_dropdown_open = not char_view_dropdown_open
        return True

    if not char_view_dropdown_open:
        return False

    for rect, action in char_view_dropdown_rects:
        if rect.collidepoint(mx, my):
            kind = action.get("kind")
            if kind == "follow_live":
                # Switch view back to the live character.
                if current_char_name:
                    _switch_active_view(current_char_name)
            elif kind == "select_char":
                target = action.get("name")
                if target:
                    _switch_active_view(target)
            char_view_dropdown_open = False
            return True

    # Click anywhere else closes the dropdown without changing selection.
    char_view_dropdown_open = False
    return True


def draw_inventory_dropdown(surface):
    """Render the inventory dropdown panel below the 'Bags' button if
    inventory_dropdown_open is True. Populates inventory_dropdown_rects
    with click targets for the main click handler.

    Two views:
      - Bag-list view (inventory_active_bag is None): shows a button per
        bag with item-count. Clicking a bag enters detail view.
      - Bag-detail view (inventory_active_bag is set): shows scrollable
        list of items in that bag with a back arrow up top. Each row is
        a hyperlink to BG-Wiki and shows a ✓ if the item appears in
        gearswap_referenced_items.
    """
    global inventory_dropdown_rects
    inventory_dropdown_rects = []
    if not inventory_dropdown_open:
        return
    if not inventory_button_rect:
        return

    # Layout: anchor below the Bags button. Width fixed, height
    # bounded; we'll scroll if we overflow.
    geom = _inventory_panel_geometry()
    if not geom:
        return
    panel_x, panel_y, panel_w, panel_h = geom

    pygame.draw.rect(surface, (28, 28, 36),
                     (panel_x, panel_y, panel_w, panel_h),
                     border_radius=4)
    pygame.draw.rect(surface, (140, 140, 160),
                     (panel_x, panel_y, panel_w, panel_h), 1,
                     border_radius=4)

    pad        = 8
    row_h      = 18
    title_font = pygame.font.SysFont("Consolas", 12, bold=True)
    label_font = pygame.font.SysFont("Consolas", 11)
    small_font = pygame.font.SysFont("Consolas", 10, italic=True)

    cy = panel_y + pad

    # ── View A: bag list ────────────────────────────────────────────────
    if inventory_active_bag is None:
        # Header line: total items + freshness.
        total_items = sum(len(inventory_state.get(b, []))
                          for b, _ in INVENTORY_BAG_ORDER)
        if inventory_last_update_ts > 0:
            age_s = int(time.time() - inventory_last_update_ts)
            hdr_text = f"Bags  ({total_items} items, {age_s}s ago)"
        else:
            hdr_text = "Bags  (waiting for lua…)"
        hdr_surf = title_font.render(hdr_text, True, (220, 200, 150))
        surface.blit(hdr_surf, (panel_x + pad, cy))
        cy += hdr_surf.get_height() + 4

        # Render one row per known bag with item count.
        for bag_key, bag_label in INVENTORY_BAG_ORDER:
            row_rect = pygame.Rect(panel_x + 2, cy,
                                   panel_w - 4, row_h)
            if row_rect.collidepoint(pygame.mouse.get_pos()):
                pygame.draw.rect(surface, (40, 40, 52), row_rect)
            items_here = inventory_state.get(bag_key, [])
            count_str  = f"{len(items_here):>3}"
            label_surf = label_font.render(bag_label, True, (220, 220, 230))
            count_surf = label_font.render(count_str, True, COL_LABEL_DIM)
            surface.blit(label_surf,
                (panel_x + pad,
                 cy + (row_h - label_surf.get_height()) // 2))
            surface.blit(count_surf,
                (panel_x + panel_w - count_surf.get_width() - pad,
                 cy + (row_h - count_surf.get_height()) // 2))
            # Empty bags get a dim row but still hover/click — the
            # detail view will show a "no items" placeholder.
            inventory_dropdown_rects.append((row_rect, {
                "kind": "open_bag", "bag": bag_key,
            }))
            cy += row_h

        # Footer hint about gearswap scan status.
        cy += 4
        if gearswap_folder_path:
            hint = (f"GearSwap scan: {len(gearswap_referenced_items)} "
                    f"items referenced")
        else:
            hint = "GearSwap scan off — set folder in Settings → Inventory"
        hint_surf = small_font.render(hint, True, COL_LABEL_DIM)
        surface.blit(hint_surf, (panel_x + pad, cy))
        return

    # ── View B: bag detail ──────────────────────────────────────────────
    bag_key   = inventory_active_bag
    bag_label = next((lbl for k, lbl in INVENTORY_BAG_ORDER if k == bag_key),
                     bag_key)
    items     = list(inventory_state.get(bag_key, []))
    # Sort alphabetically by name for predictable scanning.
    items.sort(key=lambda it: (it.get("name") or "").lower())

    # Header: back button + bag name + count.
    back_w = 28
    back_rect = pygame.Rect(panel_x + 2, cy, back_w, row_h)
    if back_rect.collidepoint(pygame.mouse.get_pos()):
        pygame.draw.rect(surface, (40, 40, 52), back_rect)
    back_surf = title_font.render("‹", True, (220, 220, 230))
    if back_surf.get_width() < 4:
        back_surf = title_font.render("<", True, (220, 220, 230))
    surface.blit(back_surf,
        (back_rect.x + (back_w - back_surf.get_width()) // 2,
         back_rect.y + (row_h - back_surf.get_height()) // 2))
    inventory_dropdown_rects.append((back_rect, {"kind": "back"}))

    title_surf = title_font.render(
        f"{bag_label}  ({len(items)} items)",
        True, (220, 200, 150))
    surface.blit(title_surf,
        (panel_x + back_w + 6, cy + (row_h - title_surf.get_height()) // 2))
    cy += row_h + 4

    # Scrollable item list.
    list_top    = cy
    list_bottom = panel_y + panel_h - pad
    available_rows = max(1, (list_bottom - list_top) // row_h)
    scroll = inventory_bag_scroll.get(bag_key, 0)
    max_scroll = max(0, len(items) - available_rows)
    scroll = max(0, min(scroll, max_scroll))
    inventory_bag_scroll[bag_key] = scroll

    if not items:
        ph = small_font.render("(empty)", True, COL_LABEL_DIM)
        surface.blit(ph, (panel_x + pad, cy + 2))
        return

    visible = items[scroll:scroll + available_rows]
    for it in visible:
        nm  = it.get("name", "") or f"#{it.get('id', 0)}"
        cnt = it.get("count", 1)
        row_rect = pygame.Rect(panel_x + 2, cy,
                               panel_w - 4, row_h)
        # Hover highlight + reserve as click target.
        is_hover = row_rect.collidepoint(pygame.mouse.get_pos())
        if is_hover:
            pygame.draw.rect(surface, (40, 40, 52), row_rect)

        # Check mark column (left): ✓ if referenced in gearswap.
        check_w = 14
        if _item_in_gearswap(nm):
            ck = label_font.render("✓", True, (140, 200, 140))
            if ck.get_width() < 3:
                # Some fonts don't ship the check glyph — fall back to '*'.
                ck = label_font.render("*", True, (140, 200, 140))
            surface.blit(ck,
                (panel_x + pad,
                 cy + (row_h - ck.get_height()) // 2))

        # Name (link styling: light blue).
        name_color = (130, 180, 230)
        name_surf  = label_font.render(nm, True, name_color)
        # Underline-on-hover using a 1px line at the bottom of the
        # text — same convention as the rest of OmniWatch's hyperlinks.
        name_x = panel_x + pad + check_w
        name_y = cy + (row_h - name_surf.get_height()) // 2
        surface.blit(name_surf, (name_x, name_y))
        if is_hover:
            pygame.draw.line(surface, name_color,
                (name_x, name_y + name_surf.get_height() - 1),
                (name_x + name_surf.get_width(),
                 name_y + name_surf.get_height() - 1))

        # Count column (right). Only show when >1.
        if cnt > 1:
            cnt_surf = label_font.render(f"x{cnt}", True, COL_LABEL_DIM)
            surface.blit(cnt_surf,
                (panel_x + panel_w - cnt_surf.get_width() - pad,
                 cy + (row_h - cnt_surf.get_height()) // 2))

        inventory_dropdown_rects.append((row_rect, {
            "kind": "open_item_url",
            "url":  _bgwiki_item_url(nm),
        }))
        cy += row_h

    # Scroll buttons (top-right of panel) when we have overflow.
    if max_scroll > 0:
        up_rect = pygame.Rect(panel_x + panel_w - 44,
                              panel_y + 4, 18, 18)
        dn_rect = pygame.Rect(panel_x + panel_w - 22,
                              panel_y + 4, 18, 18)
        for r, label in ((up_rect, "▲"), (dn_rect, "▼")):
            pygame.draw.rect(surface, (60, 60, 75), r, border_radius=2)
            ts = label_font.render(label, True, (220, 220, 230))
            if ts.get_width() < 4:
                ts = label_font.render(
                    "^" if label == "▲" else "v", True, (220, 220, 230))
            surface.blit(ts,
                (r.x + (r.w - ts.get_width()) // 2,
                 r.y + (r.h - ts.get_height()) // 2))
        inventory_dropdown_rects.append((up_rect, {
            "kind": "scroll", "bag": bag_key, "delta": -1,
        }))
        inventory_dropdown_rects.append((dn_rect, {
            "kind": "scroll", "bag": bag_key, "delta": 1,
        }))


def dispatch_inventory_dropdown_click(mx, my):
    """Resolve a click against the inventory dropdown. Returns True if
    the click was consumed (hit a control rect, was inside the panel
    chrome, OR was on the Bags button itself). When True, the main
    handler should `continue` so the click doesn't fall through to
    panel drag/url handlers underneath."""
    global inventory_dropdown_open, inventory_active_bag
    global inventory_bag_scroll

    # Always-eat the toggle button click — clicking 'Bags' should
    # never fall through to drag.
    if inventory_button_rect and inventory_button_rect.collidepoint(mx, my):
        inventory_dropdown_open = not inventory_dropdown_open
        if not inventory_dropdown_open:
            inventory_active_bag = None    # reset to bag-list view next open
        return True

    if not inventory_dropdown_open:
        return False

    # Hit-test individual rects first.
    for rect, action in inventory_dropdown_rects:
        if rect.collidepoint(mx, my):
            kind = action.get("kind")
            if kind == "open_bag":
                inventory_active_bag = action["bag"]
                inventory_bag_scroll[action["bag"]] = 0
            elif kind == "back":
                inventory_active_bag = None
            elif kind == "scroll":
                bag = action["bag"]
                cur = inventory_bag_scroll.get(bag, 0)
                inventory_bag_scroll[bag] = max(0, cur + action["delta"])
            elif kind == "open_item_url":
                url = action.get("url", "")
                if url:
                    open_url(url)
            return True

    # Click anywhere inside the panel envelope — eat it so the click
    # doesn't reach drag or url handlers underneath. Use the same
    # geometry the renderer used.
    if inventory_button_rect:
        geom = _inventory_panel_geometry()
        if geom:
            env = pygame.Rect(*geom)
            if env.collidepoint(mx, my):
                return True

    # Click outside panel + outside button = close the dropdown.
    inventory_dropdown_open = False
    inventory_active_bag = None
    return False


# ── Simulation window ───────────────────────────────────────────────────────
# Floating, draggable. Shown only when sim_window_open is true (set by
# the sim_mode setting). Drives sim_state and pushes each change to lua
# over UDP. Per-frame: render + populate sim_window_rects with click
# targets the dispatch handler consumes.

# Module-level rect lists. Cleared and refilled each frame in draw_sim_window.
sim_window_rects     = []   # list of (pygame.Rect, action_dict)
sim_window_titlebar_rect = None   # for drag-handle hit-test
sim_window_resize_rect   = None   # for resize-grip hit-test

SIM_WIN_W       = 280
SIM_WIN_PAD     = 10
SIM_WIN_ROW_H   = 22
SIM_WIN_HDR_H   = 26
SIM_WIN_BG      = (24, 24, 32)
SIM_WIN_BORDER  = (140, 140, 160)
SIM_WIN_TITLE   = (200, 200, 220)
SIM_WIN_LABEL   = (180, 180, 195)
SIM_WIN_VALUE   = (220, 220, 240)
SIM_WIN_BTN_BG  = (50, 50, 62)
SIM_WIN_BTN_HOV = (70, 70, 84)
SIM_WIN_DIM     = (110, 110, 125)


def _sim_compute_height():
    """Return the natural height of the sim window for the current state.
    Recomputed each frame because dropdown lengths depend on state.
    """
    h = SIM_WIN_HDR_H + SIM_WIN_PAD
    # HP / MP block: header + 1 row.
    h += SIM_WIN_ROW_H            # "HP / MP" header
    h += SIM_WIN_ROW_H            # the HP/MP pair row
    h += 4
    # Equipment section: header + 8 rows (2-column layout, 16 slots).
    # Plus expanded dropdown if a slot is active (full-width below row).
    # No item-count cap — the sim window itself is scrollable, so an
    # arbitrarily long inventory list is reachable by scrolling.
    h += SIM_WIN_ROW_H            # equipment header
    h += 8 * SIM_WIN_ROW_H        # 8 rows of 2 slots each
    if (sim_active_field
            and sim_active_field.get("kind") == "equip_slot"):
        slot = sim_active_field.get("slot", "")
        n_items = len(_sim_get_slot_options(slot))
        h += (n_items + 1) * 18   # +1 for "(empty)"
    h += 4
    # Food section: header + 1 dropdown row. If open, expanded list.
    h += SIM_WIN_ROW_H            # food header
    h += SIM_WIN_ROW_H            # food row
    if sim_active_field and sim_active_field.get("kind") == "food":
        h += min(12, len(SIM_FOOD_LIST) + 1) * 18  # +1 for "(none)"
    h += 4
    # Buffs section: header + active buffs + picker UI.
    h += SIM_WIN_ROW_H            # buffs header
    for entry in sim_state.get("active_buffs", []):
        bid = entry.get("id", "")
        # Pull catalog row to read kind + category. Category determines
        # whether the song-kind buff has a 3rd row (SV/Marcato — Songs
        # only) or is just 2 rows (name+X, plus controls).
        crow = next((c for c in SIM_BUFF_CATALOG if c[0] == bid), None)
        if crow is None:
            continue
        ckind = crow[3]
        ccat  = crow[1]
        # Row count per kind/category:
        #   Songs song (kind='song', cat='Songs'): 3 rows
        #     (name+X, plus +/-, SV/Marcato boost toggles)
        #   Geomancy indi-* (kind='song', cat='Geomancy'): 2 rows
        #     (name+X, plus +/- — no boost row applies)
        #   Rolls roll (kind='roll'): 3 rows
        #     (name+X, level/plus, C.Cards/Job-present checkboxes)
        #   Spells spell (kind='spell'): 1 row
        #     (just name+X — flat values, no controls)
        if ckind == "spell":
            h += 1 * SIM_WIN_ROW_H
        elif ckind == "song":
            h += (3 * SIM_WIN_ROW_H) if ccat == "Songs" else (2 * SIM_WIN_ROW_H)
        else:  # roll
            h += 3 * SIM_WIN_ROW_H
    # Picker UI height varies by stage.
    picker_stage = sim_buff_picker.get("stage") if sim_buff_picker else None
    if picker_stage is None:
        h += SIM_WIN_ROW_H        # add button
    elif picker_stage == "job":
        h += SIM_WIN_ROW_H        # prompt
        h += len(SIM_BUFF_JOB_LIST) * SIM_WIN_ROW_H
        h += SIM_WIN_ROW_H        # cancel
    elif picker_stage == "buff":
        h += SIM_WIN_ROW_H        # prompt
        chosen_job = sim_buff_picker.get("job", "")
        h += len(SIM_BUFF_BY_JOB.get(chosen_job, [])) * SIM_WIN_ROW_H
        h += SIM_WIN_ROW_H        # cancel
    h += 4
    # Export Set button + Reset button + bottom pad.
    h += SIM_WIN_ROW_H            # export
    h += SIM_WIN_ROW_H            # reset
    h += SIM_WIN_PAD
    return h


def draw_sim_window(surface):
    """Render the floating sim window (title bar, sections, buttons).
    Populates sim_window_rects with click targets the dispatcher reads.
    Skipped entirely when sim_window_open is False.

    Resizable: bottom-right corner has a grip. User can shrink below
    natural-content-height (content scrolls) or expand to leave blank
    space. Width applies linearly to the row layout.
    """
    global sim_window_rects, sim_window_titlebar_rect, sim_window_resize_rect
    global sim_window_scroll
    sim_window_rects = []
    sim_window_titlebar_rect = None
    sim_window_resize_rect = None
    if not sim_window_open:
        return

    # Window dimensions. Width comes from sim_window_size[0]; height
    # is the user-resized value if set, else natural-fit.
    nat_h = _sim_compute_height()
    ww = max(220, min(WIDTH, int(sim_window_size[0])))
    user_h = int(sim_window_size[1])
    wh = user_h if user_h > 0 else nat_h
    wh = max(SIM_WIN_HDR_H + 60, min(HEIGHT, wh))
    # If natural content is taller than rendered height, scrolling is
    # available. Clamp scroll to valid range so resizing the window
    # bigger doesn't leave us scrolled past the new bottom.
    body_h = max(0, wh - SIM_WIN_HDR_H - SIM_WIN_PAD * 2)
    overflow = max(0, nat_h - SIM_WIN_HDR_H - SIM_WIN_PAD * 2 - body_h)
    if sim_window_scroll < 0:
        sim_window_scroll = 0
    if sim_window_scroll > overflow:
        sim_window_scroll = overflow

    # Position. Clamp to screen so a previously-saved offscreen
    # position can't trap the window where it can't be reached.
    wx, wy = sim_window_pos
    wx = max(0, min(WIDTH - ww, int(wx)))
    wy = max(0, min(HEIGHT - wh, int(wy)))
    sim_window_pos[0], sim_window_pos[1] = wx, wy

    # Background + border.
    pygame.draw.rect(surface, SIM_WIN_BG, (wx, wy, ww, wh),
                     border_radius=4)
    pygame.draw.rect(surface, SIM_WIN_BORDER, (wx, wy, ww, wh), 1,
                     border_radius=4)

    # Title bar.
    title_font = pygame.font.SysFont("Consolas", 13, bold=True)
    label_font = pygame.font.SysFont("Consolas", 12)
    value_font = pygame.font.SysFont("Consolas", 12, bold=True)

    title_rect = pygame.Rect(wx, wy, ww, SIM_WIN_HDR_H)
    pygame.draw.rect(surface, (40, 40, 52), title_rect,
                     border_top_left_radius=4, border_top_right_radius=4)
    pygame.draw.line(surface, SIM_WIN_BORDER,
                     (wx, wy + SIM_WIN_HDR_H),
                     (wx + ww, wy + SIM_WIN_HDR_H))
    t_surf = title_font.render("Simulation", True, SIM_WIN_TITLE)
    surface.blit(t_surf, (wx + SIM_WIN_PAD,
                          wy + (SIM_WIN_HDR_H - t_surf.get_height()) // 2))
    # Close X — clicking it just turns sim_mode off (which closes window).
    close_size = 16
    close_rect = pygame.Rect(wx + ww - close_size - 6,
                             wy + (SIM_WIN_HDR_H - close_size) // 2,
                             close_size, close_size)
    pygame.draw.rect(surface, (90, 50, 60), close_rect, border_radius=2)
    x_surf = title_font.render("×", True, (240, 220, 220))
    surface.blit(x_surf, (close_rect.x + (close_size - x_surf.get_width()) // 2,
                          close_rect.y + (close_size - x_surf.get_height()) // 2 - 2))
    sim_window_rects.append((close_rect, {"action": "close"}))
    # Title bar (minus close button) is the drag handle.
    sim_window_titlebar_rect = pygame.Rect(
        wx, wy, ww - close_size - 12, SIM_WIN_HDR_H)

    # Clip the body region so scrolled content doesn't bleed past the
    # rounded border or the title bar. Save/restore the previous clip
    # so other panels later in the frame aren't affected.
    body_top = wy + SIM_WIN_HDR_H + 1
    body_bottom = wy + wh - 1
    prev_clip = surface.get_clip()
    surface.set_clip(pygame.Rect(wx + 1, body_top, ww - 2, body_bottom - body_top))

    # Subtract scroll from row baseline so content scrolls under the
    # body region. Click rects added during render are in screen
    # coords (already offset by -scroll), so hit-tests stay correct.
    cy = wy + SIM_WIN_HDR_H + SIM_WIN_PAD - sim_window_scroll

    # Helper: render one row with a label on the left and an editable
    # value/selector on the right. Returns the pygame.Rect of the
    # right-side editor for hit-testing.
    def _row(label_text, value_text, action_payload, hl=False):
        nonlocal cy
        l_surf = label_font.render(label_text, True, SIM_WIN_LABEL)
        surface.blit(l_surf, (wx + SIM_WIN_PAD,
                              cy + (SIM_WIN_ROW_H - l_surf.get_height()) // 2))
        # Editor area: right half of the row.
        ed_x = wx + ww // 2
        ed_w = ww // 2 - SIM_WIN_PAD
        ed_rect = pygame.Rect(ed_x, cy + 2, ed_w, SIM_WIN_ROW_H - 4)
        bg = SIM_WIN_BTN_HOV if hl else SIM_WIN_BTN_BG
        pygame.draw.rect(surface, bg, ed_rect, border_radius=3)
        v_col = SIM_WIN_VALUE if value_text else SIM_WIN_DIM
        v_text = value_text if value_text else "—"
        v_surf = value_font.render(v_text, True, v_col)
        surface.blit(v_surf, (ed_rect.x + 6,
                              ed_rect.y + (ed_rect.height - v_surf.get_height()) // 2))
        sim_window_rects.append((ed_rect, action_payload))
        cy += SIM_WIN_ROW_H
        return ed_rect

    # ── HP / MP overview ─────────────────────────────────────────────────
    # Two-cell summary at the top of the sim. Reads from the live
    # player_stats dict that lua pushes via the stats stream — the same
    # source as the main stats panel. When sim is active and you've
    # picked gear/food/buffs, these values reflect the simulated total
    # (lua's compute path stores hp/mp under the same keys regardless
    # of sim state). Useful for checking that an HP set keeps you
    # above some min HP threshold without having to leave sim mode.
    h_surf = title_font.render("HP / MP", True, SIM_WIN_TITLE)
    surface.blit(h_surf, (wx + SIM_WIN_PAD,
                          cy + (SIM_WIN_ROW_H - h_surf.get_height()) // 2))
    cy += SIM_WIN_ROW_H

    def _hp_mp_pair(label_a, key_a, label_b, key_b):
        nonlocal cy
        # Render two side-by-side cells: [label] [value] [label] [value]
        # Each takes half the width.
        cell_w = (ww - SIM_WIN_PAD * 2) // 2
        for idx, (lbl, key) in enumerate([(label_a, key_a), (label_b, key_b)]):
            cell_x = wx + SIM_WIN_PAD + idx * cell_w
            l_surf = label_font.render(lbl, True, SIM_WIN_LABEL)
            surface.blit(l_surf, (cell_x,
                                  cy + (SIM_WIN_ROW_H - l_surf.get_height()) // 2))
            val = player_stats.get(key, None)
            if val is None:
                val_text = "—"
                v_col = SIM_WIN_DIM
            else:
                try:
                    f = float(val)
                    val_text = f"{int(f)}" if abs(f - int(f)) < 0.001 else f"{f:.1f}"
                except (TypeError, ValueError):
                    val_text = str(val)
                v_col = SIM_WIN_VALUE
            v_surf = value_font.render(val_text, True, v_col)
            # Right-align the value within its half-cell.
            v_x = cell_x + cell_w - v_surf.get_width() - 6
            surface.blit(v_surf, (v_x,
                                  cy + (SIM_WIN_ROW_H - v_surf.get_height()) // 2))
        cy += SIM_WIN_ROW_H

    _hp_mp_pair("HP", "hp", "MP", "mp")
    cy += 4

    # ── Equipment section ─────────────────────────────────────────────────
    # 16 gear-slot rows. Each row has the slot label on the left and a
    # dropdown showing either the sim-overridden item OR the live equipped
    # item (greyed) for context. Click → opens the slot's dropdown showing
    # all items in inventory the current job can equip in that slot, plus
    # an "(empty)" option to sim the slot unequipped.
    h_surf = title_font.render("Equipment", True, SIM_WIN_TITLE)
    surface.blit(h_surf, (wx + SIM_WIN_PAD,
                          cy + (SIM_WIN_ROW_H - h_surf.get_height()) // 2))
    cy += SIM_WIN_ROW_H

    sim_eq = sim_state.get("equipment", {}) or {}
    cur_job = _inv_for_sim.get("main_job", "")

    # Two-column layout: each row holds 2 slot cells side-by-side.
    # 16 slots / 2 columns = 8 rows total, halving the equipment
    # section's height vs. the previous one-slot-per-row layout.
    # When a dropdown opens for a slot in column A, it expands BELOW
    # the entire 2-cell row taking the full width (so option labels
    # have room to breathe). The other slot in that row stays visible
    # but its dropdown is collapsed.
    col_count = 2
    col_w = (ww - SIM_WIN_PAD * 2) // col_count
    label_w = 38   # short slot labels: "Main", "L.Ear", etc.
    val_w   = col_w - label_w - 4

    def _equip_cell(slot_key, slot_label, col_x, row_y):
        """Draw one slot cell at (col_x, row_y); return its dropdown rect."""
        sim_val = sim_eq.get(slot_key, None)
        # sim_val can be:
        #   None        → no override, slot is "(real)" (pre-seed state)
        #   0           → explicit empty
        #   int > 0     → legacy id-only ref
        #   dict {...}  → instance ref {id, bag, idx}
        is_empty = (sim_val == 0)
        is_dict  = isinstance(sim_val, dict) and (sim_val.get("id", 0) or 0) > 0
        is_int   = isinstance(sim_val, int) and sim_val > 0
        if is_empty:
            display, dim = "(empty)", False
        elif is_dict or is_int:
            # Resolve display name from inventory snapshot.
            target_id = sim_val["id"] if is_dict else sim_val
            target_loc = (sim_val.get("bag", 0), sim_val.get("idx", 0)) if is_dict else None
            display = f"id:{target_id}"
            for entry in _sim_get_slot_options(slot_key):
                # Match exact instance when possible (dict ref), else by id.
                if target_loc and (entry.get("bag", 0), entry.get("idx", 0)) == target_loc:
                    display = _display_name_for_item(entry)
                    break
                if not target_loc and entry.get("id") == target_id:
                    display = _display_name_for_item(entry)
                    break
            dim = False
        else:
            display, dim = "(real)", True
        # Slot label on left
        l_surf = label_font.render(slot_label, True, SIM_WIN_LABEL)
        surface.blit(l_surf, (col_x,
                              row_y + (SIM_WIN_ROW_H - l_surf.get_height()) // 2))
        # Dropdown box on right
        ed_rect = pygame.Rect(col_x + label_w, row_y + 2,
                              val_w, SIM_WIN_ROW_H - 4)
        active = (sim_active_field
                  and sim_active_field.get("kind") == "equip_slot"
                  and sim_active_field.get("slot") == slot_key)
        bg = SIM_WIN_BTN_HOV if active else SIM_WIN_BTN_BG
        pygame.draw.rect(surface, bg, ed_rect, border_radius=3)
        v_col = SIM_WIN_DIM if dim else SIM_WIN_VALUE
        max_chars = max(6, (val_w - 8) // 6)
        truncated = display if len(display) <= max_chars else display[:max_chars-1] + "…"
        v_surf = value_font.render(truncated, True, v_col)
        surface.blit(v_surf, (ed_rect.x + 4,
                              ed_rect.y + (ed_rect.height - v_surf.get_height()) // 2))
        sim_window_rects.append((ed_rect,
            {"action": "open_dropdown", "kind": "equip_slot", "slot": slot_key}))
        return ed_rect, active, sim_val

    # Walk slots in groups of `col_count`. After each row, if any cell
    # in that row was active, expand its dropdown below the row using
    # full window width.
    for row_start in range(0, len(SIM_GEAR_SLOTS), col_count):
        row_slots = SIM_GEAR_SLOTS[row_start:row_start + col_count]
        active_slot = None
        active_sim_val = None
        for col_idx, (slot_key, slot_label) in enumerate(row_slots):
            col_x = wx + SIM_WIN_PAD + col_idx * col_w
            _rect, active, sim_val = _equip_cell(slot_key, slot_label,
                                                  col_x, cy)
            if active:
                active_slot = slot_key
                active_sim_val = sim_val
        cy += SIM_WIN_ROW_H

        # If a dropdown is open in this row, render the option list now,
        # taking the full window width (centered below the row of two
        # cells). 18px-tall option rows.
        if active_slot is not None:
            options = _sim_get_slot_options(active_slot)
            full_w = ww - SIM_WIN_PAD * 2
            opt_x = wx + SIM_WIN_PAD
            opt_max_chars = max(8, (full_w - 12) // 6)

            # "(empty)" sentinel
            opt_rect = pygame.Rect(opt_x, cy, full_w, 18)
            hov = (active_sim_val == 0)
            pygame.draw.rect(surface,
                SIM_WIN_BTN_HOV if hov else SIM_WIN_BTN_BG,
                opt_rect, border_radius=2)
            o_surf = label_font.render("(empty)", True, SIM_WIN_DIM)
            surface.blit(o_surf, (opt_rect.x + 6,
                                  opt_rect.y + (opt_rect.height - o_surf.get_height()) // 2))
            sim_window_rects.append((opt_rect,
                {"action": "select", "kind": "equip_slot",
                 "slot": active_slot, "value": 0}))
            cy += 18

            if not options:
                msg = ("(no inventory yet)" if not _inv_for_sim.get("by_slot")
                       else "(no items equippable)")
                e_surf = label_font.render(msg, True, SIM_WIN_DIM)
                surface.blit(e_surf, (opt_x + 6, cy + 2))
                cy += 18
            else:
                # Show ALL options. Each option is an entry dict; click
                # action sends an instance ref so augmented items resolve
                # to the exact (bag, idx). The current sim_val is matched
                # by exact location if dict-form, by id otherwise.
                cur_loc = None
                cur_id  = None
                if isinstance(active_sim_val, dict):
                    cur_loc = (active_sim_val.get("bag", 0),
                               active_sim_val.get("idx", 0))
                    cur_id  = active_sim_val.get("id")
                elif isinstance(active_sim_val, int) and active_sim_val > 0:
                    cur_id = active_sim_val
                for entry in options:
                    iid    = entry.get("id")
                    bag_id = entry.get("bag", 0)
                    idx_id = entry.get("idx", 0)
                    name = _display_name_for_item(entry)
                    opt_rect = pygame.Rect(opt_x, cy, full_w, 18)
                    # Highlight if this is the currently-selected instance.
                    is_hov = False
                    if cur_loc is not None:
                        is_hov = (cur_loc == (bag_id, idx_id))
                    elif cur_id is not None:
                        is_hov = (iid == cur_id)
                    pygame.draw.rect(surface,
                        SIM_WIN_BTN_HOV if is_hov else SIM_WIN_BTN_BG,
                        opt_rect, border_radius=2)
                    short = name if len(name) <= opt_max_chars else name[:opt_max_chars-1] + "…"
                    o_surf = label_font.render(short, True, SIM_WIN_VALUE)
                    surface.blit(o_surf, (opt_rect.x + 6,
                                          opt_rect.y + (opt_rect.height - o_surf.get_height()) // 2))
                    # Click action carries the full instance ref so lua
                    # gets <id>@<bag>:<idx> and resolves to this exact
                    # augmented copy.
                    sim_window_rects.append((opt_rect,
                        {"action": "select", "kind": "equip_slot",
                         "slot": active_slot,
                         "value": {"id": iid, "bag": bag_id, "idx": idx_id}}))
                    cy += 18

    cy += 4

    # ── Food section ───────────────────────────────────────────────────────
    # Single dropdown row, picks one food from SIM_FOOD_LIST (curated).
    h_surf = title_font.render("Food", True, SIM_WIN_TITLE)
    surface.blit(h_surf, (wx + SIM_WIN_PAD,
                          cy + (SIM_WIN_ROW_H - h_surf.get_height()) // 2))
    cy += SIM_WIN_ROW_H

    food_id = sim_state.get("food", None)
    food_disp = "(none)"
    if food_id is not None:
        for fid, fname, _stats in SIM_FOOD_LIST:
            if fid == food_id:
                food_disp = fname
                break
        else:
            food_disp = f"food:{food_id}"

    l_surf = label_font.render("Food", True, SIM_WIN_LABEL)
    surface.blit(l_surf, (wx + SIM_WIN_PAD,
                          cy + (SIM_WIN_ROW_H - l_surf.get_height()) // 2))
    fd_x = wx + ww // 2 - 30
    fd_w = ww - (fd_x - wx) - SIM_WIN_PAD
    fd_rect = pygame.Rect(fd_x, cy + 2, fd_w, SIM_WIN_ROW_H - 4)
    fd_active = (sim_active_field and sim_active_field.get("kind") == "food")
    pygame.draw.rect(surface,
        SIM_WIN_BTN_HOV if fd_active else SIM_WIN_BTN_BG,
        fd_rect, border_radius=3)
    fd_col = SIM_WIN_DIM if food_id is None else SIM_WIN_VALUE
    fd_max_chars = max(8, (fd_w - 12) // 6)
    fd_short = food_disp if len(food_disp) <= fd_max_chars else food_disp[:fd_max_chars-1] + "…"
    fd_surf = value_font.render(fd_short, True, fd_col)
    surface.blit(fd_surf, (fd_rect.x + 6,
                           fd_rect.y + (fd_rect.height - fd_surf.get_height()) // 2))
    sim_window_rects.append((fd_rect, {"action": "open_dropdown", "kind": "food"}))
    cy += SIM_WIN_ROW_H

    if fd_active:
        # "(none)" sentinel.
        opt_rect = pygame.Rect(fd_x, cy, fd_w, 18)
        hov = (food_id is None)
        pygame.draw.rect(surface,
            SIM_WIN_BTN_HOV if hov else SIM_WIN_BTN_BG,
            opt_rect, border_radius=2)
        o_surf = label_font.render("(none)", True, SIM_WIN_DIM)
        surface.blit(o_surf, (opt_rect.x + 6,
                              opt_rect.y + (opt_rect.height - o_surf.get_height()) // 2))
        sim_window_rects.append((opt_rect,
            {"action": "select", "kind": "food", "value": None}))
        cy += 18
        for fid, fname, _ in SIM_FOOD_LIST[:11]:
            opt_rect = pygame.Rect(fd_x, cy, fd_w, 18)
            hov = (food_id == fid)
            pygame.draw.rect(surface,
                SIM_WIN_BTN_HOV if hov else SIM_WIN_BTN_BG,
                opt_rect, border_radius=2)
            short = fname if len(fname) <= fd_max_chars else fname[:fd_max_chars-1] + "…"
            o_surf = label_font.render(short, True, SIM_WIN_VALUE)
            surface.blit(o_surf, (opt_rect.x + 6,
                                  opt_rect.y + (opt_rect.height - o_surf.get_height()) // 2))
            sim_window_rects.append((opt_rect,
                {"action": "select", "kind": "food", "value": fid}))
            cy += 18

    cy += 4

    # ── Buffs section: job→buff picker + active buff list ──────────────────
    # Two-stage picker. Closed by default (just an "Add Buff +" button).
    # Click → stage="job" shows BRD/COR. Pick a job → stage="buff" shows
    # the buffs for that job. Pick a buff → entry appended to
    # sim_state["active_buffs"] and lua is notified via SIM|buff_add.
    #
    # Each active buff renders as one row with controls appropriate to
    # its kind (songs: plus +/- only; rolls: plus +/- AND level +/- AND
    # optimal-job toggle).
    h_surf = title_font.render("Buffs", True, SIM_WIN_TITLE)
    surface.blit(h_surf, (wx + SIM_WIN_PAD,
                          cy + (SIM_WIN_ROW_H - h_surf.get_height()) // 2))
    cy += SIM_WIN_ROW_H

    # Render active buffs first (above the picker) so the list grows
    # downward and the "Add" button stays at the bottom of the section.
    for bidx, entry in enumerate(sim_state.get("active_buffs", [])):
        bid = entry.get("id", "")
        # Look up display info from catalog.
        catalog_entry = next(
            (c for c in SIM_BUFF_CATALOG if c[0] == bid), None)
        if catalog_entry is None:
            continue
        _, bcat, bname, bkind = catalog_entry[:4]
        # plus_max is optional in the catalog tuple; default 8 for back-
        # compat with songs/rolls that don't carry it explicitly.
        bplus_max = catalog_entry[4] if len(catalog_entry) > 4 else 8

        # Row 1: category + name + remove X. Compact label like
        # "Songs: Honor March" or "Spells: Haste".
        lbl = f"{bcat}: {bname}"
        l_surf = label_font.render(lbl, True, SIM_WIN_LABEL)
        surface.blit(l_surf, (wx + SIM_WIN_PAD,
                              cy + (SIM_WIN_ROW_H - l_surf.get_height()) // 2))
        x_size = 14
        x_rect = pygame.Rect(wx + ww - SIM_WIN_PAD - x_size,
                             cy + (SIM_WIN_ROW_H - x_size) // 2,
                             x_size, x_size)
        pygame.draw.rect(surface, (90, 50, 60), x_rect, border_radius=2)
        x_surf = label_font.render("×", True, (240, 220, 220))
        surface.blit(x_surf,
            (x_rect.x + (x_size - x_surf.get_width()) // 2,
             x_rect.y + (x_size - x_surf.get_height()) // 2 - 1))
        sim_window_rects.append((x_rect,
            {"action": "buff_remove", "idx": bidx}))
        cy += SIM_WIN_ROW_H

        # Spell-kind buffs (Haste, Flurry, etc.) have no plus/level/
        # optimal — flat values straight out of the catalog. Just the
        # name+remove row, then move on to the next buff.
        if bkind == "spell":
            continue

        # Row 2: controls. Plus +/- always; level +/- + optimal toggle for rolls.
        cur_plus = int(entry.get("plus", 0))
        if bkind == "song":
            # Just plus +/- right-aligned.
            l2 = label_font.render("  Plus", True, SIM_WIN_DIM)
            surface.blit(l2, (wx + SIM_WIN_PAD,
                              cy + (SIM_WIN_ROW_H - l2.get_height()) // 2))
            m_rect = pygame.Rect(wx + ww // 2, cy + 2, 22, SIM_WIN_ROW_H - 4)
            p_rect = pygame.Rect(wx + ww - SIM_WIN_PAD - 22, cy + 2,
                                 22, SIM_WIN_ROW_H - 4)
            v_x = m_rect.right + 4
            v_w = p_rect.left - v_x - 4
            v_rect = pygame.Rect(v_x, cy + 2, v_w, SIM_WIN_ROW_H - 4)
            pygame.draw.rect(surface, SIM_WIN_BTN_BG, m_rect, border_radius=3)
            pygame.draw.rect(surface, SIM_WIN_BTN_BG, p_rect, border_radius=3)
            pygame.draw.rect(surface, (32, 32, 40), v_rect, border_radius=3)
            m2 = value_font.render("−", True, SIM_WIN_VALUE)
            p2 = value_font.render("+", True, SIM_WIN_VALUE)
            v2 = value_font.render(f"+{cur_plus}", True, SIM_WIN_VALUE)
            surface.blit(m2, (m_rect.x + (m_rect.width - m2.get_width()) // 2,
                              m_rect.y + (m_rect.height - m2.get_height()) // 2 - 2))
            surface.blit(p2, (p_rect.x + (p_rect.width - p2.get_width()) // 2,
                              p_rect.y + (p_rect.height - p2.get_height()) // 2 - 2))
            surface.blit(v2, (v_rect.x + (v_rect.width - v2.get_width()) // 2,
                              v_rect.y + (v_rect.height - v2.get_height()) // 2))
            sim_window_rects.append((m_rect,
                {"action": "active_buff_field", "idx": bidx,
                 "field": "plus", "delta": -1, "min": 0, "max": bplus_max}))
            sim_window_rects.append((p_rect,
                {"action": "active_buff_field", "idx": bidx,
                 "field": "plus", "delta": +1, "min": 0, "max": bplus_max}))
            cy += SIM_WIN_ROW_H

            # Row 3 (BRD songs only): per-buff Soul Voice + Marcato
            # toggles. Both are BRD boosts that multiply the song's
            # output. SV is a 1-hour (x2); Marcato is a JA (x1.5) that
            # in real play only boosts the NEXT song cast — but since
            # each active buff has its own toggle here, the user picks
            # which song Marcato applies to. Stacks multiplicatively.
            # Skip for non-Songs categories (e.g. Geomancy Indi-*
            # spells, which share the song UI shape but have no BRD-
            # style boost mechanics).
            if bcat == "Songs":
                sv_on   = bool(entry.get("boost_sv", False))
                marc_on = bool(entry.get("boost_marcato", False))
                half_w  = (ww - SIM_WIN_PAD * 2) // 2
                for ti, (tkey, tlabel, ton) in enumerate([
                    ("boost_sv",      "Soul Voice", sv_on),
                    ("boost_marcato", "Marcato",    marc_on),
                ]):
                    tx = wx + SIM_WIN_PAD + ti * half_w
                    # Whole half is clickable; checkbox square at left.
                    box_size = 11
                    cb_rect = pygame.Rect(tx + 4,
                                          cy + (SIM_WIN_ROW_H - box_size) // 2,
                                          box_size, box_size)
                    pygame.draw.rect(surface, (40, 50, 65) if ton else (24, 26, 34),
                                     cb_rect, border_radius=2)
                    pygame.draw.rect(surface, (110, 130, 170), cb_rect, 1, border_radius=2)
                    if ton:
                        inner = cb_rect.inflate(-4, -4)
                        pygame.draw.rect(surface, (160, 200, 240), inner, border_radius=1)
                    lab_surf = label_font.render(tlabel, True,
                        SIM_WIN_VALUE if ton else SIM_WIN_DIM)
                    surface.blit(lab_surf,
                        (cb_rect.right + 4,
                         cy + (SIM_WIN_ROW_H - lab_surf.get_height()) // 2))
                    cell_rect = pygame.Rect(tx, cy, half_w, SIM_WIN_ROW_H)
                    sim_window_rects.append((cell_rect,
                        {"action": "active_buff_boost", "idx": bidx,
                         "field": tkey, "value": not ton}))
                cy += SIM_WIN_ROW_H
        else:
            # roll: plus + level on this row, optimal toggle on next.
            cur_lv = int(entry.get("level", 11))
            l2 = label_font.render("  Lv", True, SIM_WIN_DIM)
            surface.blit(l2, (wx + SIM_WIN_PAD,
                              cy + (SIM_WIN_ROW_H - l2.get_height()) // 2))
            # Level +/- on left half, plus +/- on right half.
            half_x = wx + (ww // 3)
            lv_minus = pygame.Rect(half_x, cy + 2, 18, SIM_WIN_ROW_H - 4)
            lv_plus  = pygame.Rect(half_x + 50, cy + 2, 18, SIM_WIN_ROW_H - 4)
            lv_val   = pygame.Rect(lv_minus.right + 2, cy + 2,
                                   lv_plus.left - lv_minus.right - 4,
                                   SIM_WIN_ROW_H - 4)
            pygame.draw.rect(surface, SIM_WIN_BTN_BG, lv_minus, border_radius=2)
            pygame.draw.rect(surface, SIM_WIN_BTN_BG, lv_plus,  border_radius=2)
            pygame.draw.rect(surface, (32, 32, 40), lv_val, border_radius=2)
            lm = value_font.render("−", True, SIM_WIN_VALUE)
            lp = value_font.render("+", True, SIM_WIN_VALUE)
            lv = value_font.render(str(cur_lv), True, SIM_WIN_VALUE)
            surface.blit(lm, (lv_minus.x + (lv_minus.width - lm.get_width()) // 2,
                              lv_minus.y + (lv_minus.height - lm.get_height()) // 2 - 2))
            surface.blit(lp, (lv_plus.x + (lv_plus.width - lp.get_width()) // 2,
                              lv_plus.y + (lv_plus.height - lp.get_height()) // 2 - 2))
            surface.blit(lv, (lv_val.x + (lv_val.width - lv.get_width()) // 2,
                              lv_val.y + (lv_val.height - lv.get_height()) // 2))
            sim_window_rects.append((lv_minus,
                {"action": "active_buff_field", "idx": bidx,
                 "field": "level", "delta": -1, "min": 1, "max": 11}))
            sim_window_rects.append((lv_plus,
                {"action": "active_buff_field", "idx": bidx,
                 "field": "level", "delta": +1, "min": 1, "max": 11}))
            # Plus on the right.
            pl_label = label_font.render("Plus", True, SIM_WIN_DIM)
            surface.blit(pl_label, (lv_plus.right + 6,
                cy + (SIM_WIN_ROW_H - pl_label.get_height()) // 2))
            pp_minus = pygame.Rect(lv_plus.right + 38, cy + 2,
                                   18, SIM_WIN_ROW_H - 4)
            pp_plus  = pygame.Rect(wx + ww - SIM_WIN_PAD - 18, cy + 2,
                                   18, SIM_WIN_ROW_H - 4)
            pp_val   = pygame.Rect(pp_minus.right + 2, cy + 2,
                                   pp_plus.left - pp_minus.right - 4,
                                   SIM_WIN_ROW_H - 4)
            pygame.draw.rect(surface, SIM_WIN_BTN_BG, pp_minus, border_radius=2)
            pygame.draw.rect(surface, SIM_WIN_BTN_BG, pp_plus,  border_radius=2)
            pygame.draw.rect(surface, (32, 32, 40), pp_val, border_radius=2)
            pm = value_font.render("−", True, SIM_WIN_VALUE)
            pp = value_font.render("+", True, SIM_WIN_VALUE)
            pv = value_font.render(f"+{cur_plus}", True, SIM_WIN_VALUE)
            surface.blit(pm, (pp_minus.x + (pp_minus.width - pm.get_width()) // 2,
                              pp_minus.y + (pp_minus.height - pm.get_height()) // 2 - 2))
            surface.blit(pp, (pp_plus.x + (pp_plus.width - pp.get_width()) // 2,
                              pp_plus.y + (pp_plus.height - pp.get_height()) // 2 - 2))
            surface.blit(pv, (pp_val.x + (pp_val.width - pv.get_width()) // 2,
                              pp_val.y + (pp_val.height - pv.get_height()) // 2))
            sim_window_rects.append((pp_minus,
                {"action": "active_buff_field", "idx": bidx,
                 "field": "plus", "delta": -1, "min": 0, "max": 11}))
            sim_window_rects.append((pp_plus,
                {"action": "active_buff_field", "idx": bidx,
                 "field": "plus", "delta": +1, "min": 0, "max": 11}))
            cy += SIM_WIN_ROW_H
            # Row 3 (rolls): "C. Cards" and "Job present" as two
            # side-by-side checkboxes, mirroring the BRD song row's
            # Soul Voice / Marcato layout. Whole half-width is
            # clickable; the small box at the left of each cell is the
            # visual indicator. Compact labels keep them legible at
            # the sim window's narrow default width.
            cc_on  = bool(entry.get("boost_cc",      False))
            opt_on = bool(entry.get("optimal",       False))
            half_w = (ww - SIM_WIN_PAD * 2) // 2
            for ti, (tkey, tlabel, ton) in enumerate([
                ("boost_cc", "C. Cards",    cc_on),
                ("optimal",  "Job present", opt_on),
            ]):
                tx = wx + SIM_WIN_PAD + ti * half_w
                box_size = 11
                cb_rect = pygame.Rect(tx + 4,
                                      cy + (SIM_WIN_ROW_H - box_size) // 2,
                                      box_size, box_size)
                pygame.draw.rect(surface, (40, 50, 65) if ton else (24, 26, 34),
                                 cb_rect, border_radius=2)
                pygame.draw.rect(surface, (110, 130, 170), cb_rect, 1, border_radius=2)
                if ton:
                    inner = cb_rect.inflate(-4, -4)
                    pygame.draw.rect(surface, (160, 200, 240), inner, border_radius=1)
                lab_surf = label_font.render(tlabel, True,
                    SIM_WIN_VALUE if ton else SIM_WIN_DIM)
                surface.blit(lab_surf,
                    (cb_rect.right + 4,
                     cy + (SIM_WIN_ROW_H - lab_surf.get_height()) // 2))
                cell_rect = pygame.Rect(tx, cy, half_w, SIM_WIN_ROW_H)
                # "optimal" goes through its own action key (preserved
                # for backwards-compat with the lua handler); CC goes
                # through the generic boost handler.
                if tkey == "optimal":
                    sim_window_rects.append((cell_rect,
                        {"action": "active_buff_optimal", "idx": bidx,
                         "value": not ton}))
                else:
                    sim_window_rects.append((cell_rect,
                        {"action": "active_buff_boost", "idx": bidx,
                         "field": tkey, "value": not ton}))
            cy += SIM_WIN_ROW_H

    # Picker UI: Add button (closed) → job dropdown → buff dropdown.
    picker_stage = sim_buff_picker.get("stage") if sim_buff_picker else None
    if picker_stage is None:
        # Closed: render "Add Buff +" button.
        add_rect = pygame.Rect(wx + SIM_WIN_PAD, cy + 2,
                               ww - SIM_WIN_PAD * 2, SIM_WIN_ROW_H - 4)
        pygame.draw.rect(surface, (50, 70, 90), add_rect, border_radius=3)
        a_surf = value_font.render("Add Buff +", True, (220, 230, 240))
        surface.blit(a_surf,
            (add_rect.x + (add_rect.width - a_surf.get_width()) // 2,
             add_rect.y + (add_rect.height - a_surf.get_height()) // 2))
        sim_window_rects.append((add_rect, {"action": "buff_picker_open"}))
        cy += SIM_WIN_ROW_H
    elif picker_stage == "job":
        # Stage 1: pick a job. Render one row per job that has buffs.
        prompt = label_font.render("Pick job:", True, SIM_WIN_LABEL)
        surface.blit(prompt, (wx + SIM_WIN_PAD,
            cy + (SIM_WIN_ROW_H - prompt.get_height()) // 2))
        cy += SIM_WIN_ROW_H
        for job in SIM_BUFF_JOB_LIST:
            j_rect = pygame.Rect(wx + SIM_WIN_PAD, cy + 1,
                                 ww - SIM_WIN_PAD * 2, SIM_WIN_ROW_H - 2)
            pygame.draw.rect(surface, SIM_WIN_BTN_BG, j_rect, border_radius=3)
            j_surf = value_font.render(job, True, SIM_WIN_VALUE)
            surface.blit(j_surf,
                (j_rect.x + (j_rect.width - j_surf.get_width()) // 2,
                 j_rect.y + (j_rect.height - j_surf.get_height()) // 2))
            sim_window_rects.append((j_rect,
                {"action": "buff_picker_job", "job": job}))
            cy += SIM_WIN_ROW_H
        # Cancel button.
        c_rect = pygame.Rect(wx + SIM_WIN_PAD, cy + 1,
                             ww - SIM_WIN_PAD * 2, SIM_WIN_ROW_H - 2)
        pygame.draw.rect(surface, (60, 50, 50), c_rect, border_radius=3)
        c_surf = value_font.render("Cancel", True, (220, 200, 200))
        surface.blit(c_surf,
            (c_rect.x + (c_rect.width - c_surf.get_width()) // 2,
             c_rect.y + (c_rect.height - c_surf.get_height()) // 2))
        sim_window_rects.append((c_rect, {"action": "buff_picker_cancel"}))
        cy += SIM_WIN_ROW_H
    elif picker_stage == "buff":
        # Stage 2: pick a buff for the chosen job.
        chosen_job = sim_buff_picker.get("job", "")
        prompt = label_font.render(f"Pick {chosen_job} buff:",
                                   True, SIM_WIN_LABEL)
        surface.blit(prompt, (wx + SIM_WIN_PAD,
            cy + (SIM_WIN_ROW_H - prompt.get_height()) // 2))
        cy += SIM_WIN_ROW_H
        for bid, bname, bkind, _bpmax in SIM_BUFF_BY_JOB.get(chosen_job, []):
            b_rect = pygame.Rect(wx + SIM_WIN_PAD, cy + 1,
                                 ww - SIM_WIN_PAD * 2, SIM_WIN_ROW_H - 2)
            pygame.draw.rect(surface, SIM_WIN_BTN_BG, b_rect, border_radius=3)
            b_surf = value_font.render(bname, True, SIM_WIN_VALUE)
            surface.blit(b_surf,
                (b_rect.x + 8,
                 b_rect.y + (b_rect.height - b_surf.get_height()) // 2))
            sim_window_rects.append((b_rect,
                {"action": "buff_picker_choose", "id": bid}))
            cy += SIM_WIN_ROW_H
        # Cancel button.
        c_rect = pygame.Rect(wx + SIM_WIN_PAD, cy + 1,
                             ww - SIM_WIN_PAD * 2, SIM_WIN_ROW_H - 2)
        pygame.draw.rect(surface, (60, 50, 50), c_rect, border_radius=3)
        c_surf = value_font.render("Cancel", True, (220, 200, 200))
        surface.blit(c_surf,
            (c_rect.x + (c_rect.width - c_surf.get_width()) // 2,
             c_rect.y + (c_rect.height - c_surf.get_height()) // 2))
        sim_window_rects.append((c_rect, {"action": "buff_picker_cancel"}))
        cy += SIM_WIN_ROW_H

    cy += 4

    # Export Set button. Writes the current sim equipment+food to a
    # GearSwap-style .lua file under simulation/export/. Lua handles
    # the file write (it has access to addon_path and to live item names
    # in resources). Disabled-looking when sim has no equipment set.
    export_rect = pygame.Rect(wx + SIM_WIN_PAD, cy + 2,
                              ww - SIM_WIN_PAD * 2, SIM_WIN_ROW_H - 4)
    has_eq = bool(sim_state.get("equipment"))
    btn_col = (50, 70, 90) if has_eq else (40, 40, 50)
    txt_col = (220, 230, 245) if has_eq else (110, 110, 130)
    pygame.draw.rect(surface, btn_col, export_rect, border_radius=3)
    e_surf = value_font.render("EXPORT SET", True, txt_col)
    surface.blit(e_surf, (export_rect.x + (export_rect.width - e_surf.get_width()) // 2,
                          export_rect.y + (export_rect.height - e_surf.get_height()) // 2))
    sim_window_rects.append((export_rect, {"action": "export_set"}))
    cy += SIM_WIN_ROW_H

    # Reset button at bottom.
    reset_rect = pygame.Rect(wx + SIM_WIN_PAD, cy + 2,
                             ww - SIM_WIN_PAD * 2, SIM_WIN_ROW_H - 4)
    pygame.draw.rect(surface, (80, 50, 50), reset_rect, border_radius=3)
    r_surf = value_font.render("RESET", True, (240, 220, 220))
    surface.blit(r_surf, (reset_rect.x + (reset_rect.width - r_surf.get_width()) // 2,
                          reset_rect.y + (reset_rect.height - r_surf.get_height()) // 2))
    sim_window_rects.append((reset_rect, {"action": "reset"}))
    cy += SIM_WIN_ROW_H

    # ── Restore clip + chrome (scrollbar, resize grip) ──────────────────────
    # Drawn AFTER restoring the previous clip so the chrome can sit on
    # top of the rounded border instead of being clipped at the body
    # edge.
    surface.set_clip(prev_clip)

    # Vertical scrollbar (only when there's overflow). Track on the
    # right inside edge; thumb sized proportional to visible/natural.
    if overflow > 0:
        sb_w = 4
        sb_x = wx + ww - sb_w - 2
        track_y = wy + SIM_WIN_HDR_H + 2
        track_h = wh - SIM_WIN_HDR_H - 4
        pygame.draw.rect(surface, (40, 40, 50),
                         (sb_x, track_y, sb_w, track_h), border_radius=2)
        thumb_h = max(20, int(track_h * body_h
                              / max(1, body_h + overflow)))
        thumb_y = track_y + int((track_h - thumb_h)
                                * sim_window_scroll / overflow)
        pygame.draw.rect(surface, (130, 130, 150),
                         (sb_x, thumb_y, sb_w, thumb_h), border_radius=2)

    # Resize grip in the bottom-right corner. Three diagonal lines —
    # standard "drag-to-resize" affordance. Hit area is a small square
    # that covers all three lines plus a generous border for easier
    # grabbing on small windows.
    grip_size = 14
    grip_rect = pygame.Rect(wx + ww - grip_size - 2,
                            wy + wh - grip_size - 2,
                            grip_size, grip_size)
    sim_window_resize_rect = grip_rect
    grip_col = (130, 130, 150)
    for i in range(3):
        off = 4 + i * 4
        pygame.draw.line(surface, grip_col,
                         (grip_rect.right - 2, grip_rect.bottom - off),
                         (grip_rect.right - off, grip_rect.bottom - 2), 1)

    # ── Augment-nickname editor overlay ──────────────────────────────
    # When right-clicking an item in an equipment dropdown, an editor
    # appears overlaying the sim window's center. Lets the user assign
    # a friendly nickname for that augment fingerprint. Enter saves,
    # Esc cancels (handled in the main key loop).
    if sim_nickname_editor is not None:
        ed = sim_nickname_editor
        # Modal panel: 80% of window width, centered, ~80px tall.
        ep_w = max(220, ww - 40)
        ep_h = 96
        ep_x = wx + (ww - ep_w) // 2
        ep_y = wy + (wh - ep_h) // 2
        # Backdrop dim
        backdrop = pygame.Surface((ww, wh), pygame.SRCALPHA)
        backdrop.fill((0, 0, 0, 140))
        surface.blit(backdrop, (wx, wy))
        # Panel
        pygame.draw.rect(surface, (32, 32, 42),
                         (ep_x, ep_y, ep_w, ep_h), border_radius=6)
        pygame.draw.rect(surface, (90, 100, 130),
                         (ep_x, ep_y, ep_w, ep_h), 1, border_radius=6)
        # Title
        t_surf = title_font.render("Nickname for this item", True, SIM_WIN_TITLE)
        surface.blit(t_surf, (ep_x + 10, ep_y + 8))
        # Hint line below title
        hint = "Enter to save · Esc to cancel · empty clears"
        h_surf = label_font.render(hint, True, SIM_WIN_DIM)
        surface.blit(h_surf, (ep_x + 10, ep_y + 26))
        # Input box
        box = pygame.Rect(ep_x + 10, ep_y + 50, ep_w - 20, 28)
        pygame.draw.rect(surface, (20, 20, 28), box, border_radius=3)
        pygame.draw.rect(surface, (110, 130, 170), box, 1, border_radius=3)
        # Text + blinking cursor
        txt = ed.get("text", "")
        # Cursor visibility toggles every ~530ms.
        show_cursor = (int((time.time() - ed.get("cursor_blink", 0)) * 1.9) % 2 == 0)
        rendered = txt + ("|" if show_cursor else "")
        i_surf = value_font.render(rendered, True, SIM_WIN_VALUE)
        # Vertically center the text
        surface.blit(i_surf, (box.x + 6,
                              box.y + (box.height - i_surf.get_height()) // 2))


def dispatch_sim_window_click(mx, my):
    """Resolve a click against sim_window_rects. Returns True if the
    click was handled (caller should not propagate to other handlers).
    Also updates sim_state and pushes the change to lua over UDP."""
    global sim_active_field, sim_state, sim_buff_picker
    if not sim_window_open:
        return False
    # Walk in reverse so dropdown options (added LAST) take priority over
    # the dropdown's parent row (added before them, smaller rect inside
    # the same vertical region).
    for rect, payload in reversed(sim_window_rects):
        if not rect.collidepoint(mx, my):
            continue
        action = payload.get("action")
        if action == "close":
            # Same as flipping sim_mode off — call set_setting so the
            # checkbox in Settings updates and side effects fire.
            try:
                set_setting("sim_mode", False)
            except Exception:
                pass
            return True
        if action == "open_dropdown":
            kind = payload.get("kind")
            slot = payload.get("slot")  # only for equip_slot
            # Toggle: clicking the same dropdown that's already open closes it.
            if (sim_active_field
                    and sim_active_field.get("kind") == kind
                    and sim_active_field.get("slot") == slot):
                sim_active_field = None
            else:
                sim_active_field = {"kind": kind}
                if slot is not None:
                    sim_active_field["slot"] = slot
            return True
        if action == "select":
            kind = payload.get("kind")
            value = payload.get("value")
            if kind == "equip_slot":
                # Sim equipment override. value can be:
                #   0 / None       → "explicitly empty"
                #   dict {id,bag,idx} → instance ref (preferred, for augments)
                #   int            → legacy id-only (fallback)
                slot = payload.get("slot")
                if slot:
                    eq = sim_state.setdefault("equipment", {})
                    if value == 0 or value is None:
                        eq[slot] = 0
                        _sim_send("equip", "0", sub=slot)
                    elif isinstance(value, dict):
                        # Store the dict as-is in sim_state so the rendering
                        # cell can match instance by exact (bag, idx).
                        eq[slot] = dict(value)
                        _sim_send("equip", _sim_format_equip_ref(value), sub=slot)
                    else:
                        eq[slot] = int(value)
                        _sim_send("equip", str(int(value)), sub=slot)
                sim_active_field = None
                return True
            if kind == "food":
                # value is None for "(none)" or an int food id.
                sim_state["food"] = value
                # Push to lua: SIM|food|<id|0>
                _sim_send("food", value if value is not None else 0)
                sim_active_field = None
                return True
            # main_job / sub_job dropdowns. Pure state writes — push to
            # lua via SIM|main_job|<v> / SIM|sub_job|<v>. The compute
            # path consumes these in the synthetic-stats pipeline (TBD
            # in the next phase).
            sim_state[kind] = value
            sim_active_field = None
            _sim_send(kind, value)
            return True
        if action == "export_set":
            # Tell lua to write the current sim equipment to disk.
            # Lua handles formatting + filename so the .lua file uses
            # correct item names from the resources lib.
            try:
                sock_cmd_out.sendto(b"SIM|export", CMD_OUT_ADDR)
            except Exception as e:
                print(f"[OmniWatch] sim export send failed: {e!r}")
            return True
        if action == "jp_step":
            cur = int(sim_state.get("jp_spent", 0))
            new = max(0, min(SIM_JP_MAX, cur + int(payload.get("delta", 0))))
            sim_state["jp_spent"] = new
            _sim_send("jp", new)
            return True
        if action == "ml_step":
            cur = int(sim_state.get("master_level", 0))
            new = max(0, min(SIM_ML_MAX, cur + int(payload.get("delta", 0))))
            sim_state["master_level"] = new
            _sim_send("master_level", new)
            return True
        if action == "merit_step":
            key = payload.get("key")
            mx_ = int(payload.get("max", 5))
            cur = int(sim_state.get("merits", {}).get(key, 0))
            new = max(0, min(mx_, cur + int(payload.get("delta", 0))))
            sim_state.setdefault("merits", {})[key] = new
            # Sub field carries the merit name; value carries the count.
            _sim_send("merit", new, sub=key)
            return True
        if action == "active_buff_boost":
            # Per-buff boost toggle (Soul Voice / Marcato on songs;
            # Crooked Cards on rolls). field is the entry key
            # ('boost_sv' / 'boost_marcato' / 'boost_cc'); value is the
            # new bool. Pushed to lua via SIM|buff_update so the
            # buff-stat compute applies the multiplier on next tick.
            idx = int(payload.get("idx", -1))
            field = payload.get("field", "")
            new_val = bool(payload.get("value", False))
            buffs = sim_state.setdefault("active_buffs", [])
            if 0 <= idx < len(buffs) and field:
                buffs[idx][field] = new_val
                # Wire format reuses buff_update: "<idx>:<field>:<value>"
                # Lua-side parser already routes any 'true'/'false' tail
                # to a bool via existing optimal handling logic.
                wire = f"{idx + 1}:{field}:{'true' if new_val else 'false'}"
                _sim_send("buff_update", wire)
            return True
        if action == "buff_picker_open":
            # Open stage 1: pick a job.
            sim_buff_picker = {"stage": "job"}
            return True
        if action == "buff_picker_cancel":
            sim_buff_picker = None
            return True
        if action == "buff_picker_job":
            # Stage 1 → stage 2.
            sim_buff_picker = {"stage": "buff", "job": payload.get("job", "")}
            return True
        if action == "buff_picker_choose":
            # Stage 2 → add to active list, close picker, notify lua.
            bid = payload.get("id", "")
            catalog_entry = next(
                (c for c in SIM_BUFF_CATALOG if c[0] == bid), None)
            if catalog_entry is not None:
                # Catalog tuple is (id, job, name, kind, plus_max).
                # Slice in case a future entry omits the trailing
                # plus_max (4-tuple back-compat).
                _, _, _, kind = catalog_entry[:4]
                # Build the local mirror entry. Defaults match lua's
                # buff_add behavior (rolls start at level 11, songs at +0).
                new_entry = {"id": bid, "plus": 0}
                if kind == "roll":
                    new_entry["level"] = 11
                    new_entry["optimal"] = False
                sim_state.setdefault("active_buffs", []).append(new_entry)
                _sim_send("buff_add", bid)
            sim_buff_picker = None
            return True
        if action == "buff_remove":
            idx = int(payload.get("idx", -1))
            buffs = sim_state.get("active_buffs", [])
            if 0 <= idx < len(buffs):
                del buffs[idx]
                # Lua list is 1-indexed; convert.
                _sim_send("buff_remove", idx + 1)
            return True
        if action == "active_buff_field":
            # ±1 to a numeric field (plus or level) on an active buff.
            idx = int(payload.get("idx", -1))
            field = payload.get("field", "")
            buffs = sim_state.get("active_buffs", [])
            if 0 <= idx < len(buffs):
                cur = int(buffs[idx].get(field, 0))
                lo = int(payload.get("min", 0))
                hi = int(payload.get("max", 0))
                new = max(lo, min(hi, cur + int(payload.get("delta", 0))))
                buffs[idx][field] = new
                # Lua wire format: SIM|buff_update|<idx>:<field>:<value>
                _sim_send("buff_update",
                          f"{idx + 1}:{field}:{new}")
            return True
        if action == "active_buff_optimal":
            # Toggle the optimal-job-present flag on a roll.
            idx = int(payload.get("idx", -1))
            new_val = bool(payload.get("value", False))
            buffs = sim_state.get("active_buffs", [])
            if 0 <= idx < len(buffs):
                buffs[idx]["optimal"] = new_val
                _sim_send("buff_update",
                          f"{idx + 1}:optimal:{'true' if new_val else 'false'}")
            return True
        if action == "reset":
            sim_state = {
                "main_job": "", "sub_job": "",
                "merits": {}, "jp_spent": 0, "gifts": {},
                "buffs":  {}, "active_buffs": [], "master_level": 0, "equipment": {}, "food": None,
            }
            sim_buff_picker = None
            sim_active_field = None
            _sim_send_reset()
            return True
    # Click was inside the window envelope but not on any control →
    # close the dropdown (if open) but otherwise no-op. Read actual
    # rendered size from sim_window_size (with auto-fit fallback to
    # natural height) so a resized window's hit-test stays accurate.
    nat_h = _sim_compute_height()
    eww = max(220, int(sim_window_size[0]))
    user_h = int(sim_window_size[1])
    ewh = user_h if user_h > 0 else nat_h
    env = pygame.Rect(sim_window_pos[0], sim_window_pos[1], eww, ewh)
    if env.collidepoint(mx, my):
        sim_active_field = None
        return True
    return False


def draw_settings_menu(surface):
    """If settings_menu_open is true, render the dropdown panel below the
    gear button in the header. Populates settings_menu_rects so click
    dispatch can find which control was hit."""
    global settings_menu_rects, settings_menu_scroll, settings_menu_panel_rect
    settings_menu_rects = []
    settings_menu_panel_rect = None
    if not settings_menu_open:
        return

    w, h_natural = settings_menu_size()
    # Anchor: top-left below the gear button (gear is at x=6, y centered).
    mx = 6
    my = HEADER_H + 2
    # Clamp to screen.
    if mx + w > WIDTH:
        mx = max(0, WIDTH - w)
    # Vertical: cap the visible panel height to whatever fits between
    # the anchor and the bottom of the window. If natural height is
    # taller, we render with scrolling.
    available_h = max(80, HEIGHT - my - 4)
    h = min(h_natural, available_h)
    overflow = max(0, h_natural - h)
    # Clamp scroll to valid range. Clamping here (rather than in the
    # scroll handler) keeps things consistent if `overflow` shrinks
    # because the user collapsed something or resized the window.
    if settings_menu_scroll < 0:
        settings_menu_scroll = 0
    if settings_menu_scroll > overflow:
        settings_menu_scroll = overflow

    # Background panel.
    pygame.draw.rect(surface, (28, 28, 36), (mx, my, w, h),
                     border_radius=4)
    pygame.draw.rect(surface, (140, 140, 160), (mx, my, w, h), 1,
                     border_radius=4)
    settings_menu_panel_rect = pygame.Rect(mx, my, w, h)

    pad   = 8
    row_h = 24
    sec_h = 22
    placeholder_h = 18
    label_font = font_label
    title_font = pygame.font.SysFont("Consolas", 13, bold=True)
    value_font = pygame.font.SysFont("Consolas", 12, bold=True)
    placeholder_font = pygame.font.SysFont("Consolas", 11, italic=True)

    # Clip drawing to the panel interior so scrolled-off rows don't
    # bleed past the rounded border. Save/restore the previous clip so
    # we don't wreck whatever the rest of the frame had set.
    prev_clip = surface.get_clip()
    surface.set_clip(pygame.Rect(mx + 1, my + 1, w - 2, h - 2))

    # Group by section so we can render each section in canonical order
    # (regardless of where its entries appear in the schema list) and
    # know which sections are empty.
    grouped = {sec: [] for sec in SETTINGS_SECTIONS}
    for s in SETTINGS_SCHEMA:
        sec = s.get("section")
        if sec in grouped:
            grouped[sec].append(s)

    # Subtract scroll from the starting y. Rows whose y+h is < my get
    # clipped at the top automatically; same for bottom. Click rects
    # added below use these (already-scrolled) coords so hit-testing
    # stays correct.
    cy = my + pad - settings_menu_scroll
    mouse_pos = pygame.mouse.get_pos()

    for section in SETTINGS_SECTIONS:
        # Section header strip.
        sec_surf = title_font.render(section.upper(), True, (200, 180, 130))
        surface.blit(sec_surf, (mx + pad, cy + 2))
        # Underline running across the row.
        pygame.draw.line(surface, (90, 90, 110),
                         (mx + pad, cy + sec_h - 2),
                         (mx + w - pad, cy + sec_h - 2))
        cy += sec_h

        section_entries = grouped[section]
        if not section_entries:
            # Empty section: show a subtle placeholder so the user
            # sees the section exists but has nothing to configure
            # yet. Italic + dim so it doesn't fight with real entries.
            ph_surf = placeholder_font.render(
                "(no settings yet)", True, (110, 110, 130))
            surface.blit(ph_surf,
                         (mx + pad + 8,
                          cy + (placeholder_h - ph_surf.get_height()) // 2))
            cy += placeholder_h
            continue

        for schema in section_entries:
            row_rect = pygame.Rect(mx + pad, cy, w - pad * 2, row_h)
            # Hover background.
            is_hover = row_rect.collidepoint(*mouse_pos)
            if is_hover:
                pygame.draw.rect(surface, (44, 44, 56), row_rect,
                                 border_radius=2)

            # Label on the left.
            lab_surf = label_font.render(schema["label"], True,
                                          (210, 210, 220))
            surface.blit(lab_surf,
                         (row_rect.x + 4,
                          row_rect.y + (row_h - lab_surf.get_height()) // 2))

            # Control on the right. Each control's hit rects are added
            # to settings_menu_rects with action dicts the click handler
            # uses to dispatch. We don't read cur_val up-front because
            # button-kind entries don't have values — those go straight
            # to the action-render branch below.
            kind = schema["kind"]
            ctrl_x_right = row_rect.x + row_rect.width - 4

            if kind == "bool":
                # If schema has a live_key, read from the live module
                # global of that name (not from the persistent settings
                # dict). Used for things like setup_mode that shouldn't
                # auto-restore on next launch.
                live_key = schema.get("live_key")
                if live_key:
                    cur_val = bool(globals().get(live_key, False))
                else:
                    cur_val = setting(schema["key"])
                # [ ON / OFF ] toggle as a single pill.
                pill_text = "ON" if cur_val else "OFF"
                pill_surf = value_font.render(pill_text, True,
                                              (40, 40, 50))
                pill_w = max(38, pill_surf.get_width() + 12)
                pill_h = 16
                pill_rect = pygame.Rect(
                    ctrl_x_right - pill_w,
                    row_rect.y + (row_h - pill_h) // 2,
                    pill_w, pill_h)
                pill_color = (140, 200, 140) if cur_val else (160, 100, 100)
                pygame.draw.rect(surface, pill_color, pill_rect,
                                 border_radius=8)
                surface.blit(pill_surf,
                             (pill_rect.x + (pill_w - pill_surf.get_width()) // 2,
                              pill_rect.y + (pill_h - pill_surf.get_height()) // 2))
                settings_menu_rects.append((pill_rect, {
                    "kind": "toggle", "key": schema["key"],
                    "live_key": live_key,    # propagate so click handler knows
                }))
            elif kind in ("int", "float"):
                cur_val = setting(schema["key"])
                # [-] value [+]
                step = schema.get("step", 1)
                val_text = (f"{cur_val:.1f}" if kind == "float"
                            else str(cur_val))
                val_surf = value_font.render(val_text, True,
                                             (220, 220, 230))
                btn_w = 18
                plus_rect = pygame.Rect(
                    ctrl_x_right - btn_w,
                    row_rect.y + (row_h - 16) // 2, btn_w, 16)
                val_rect_x = plus_rect.x - 6 - val_surf.get_width()
                minus_rect = pygame.Rect(
                    val_rect_x - 6 - btn_w,
                    row_rect.y + (row_h - 16) // 2, btn_w, 16)
                pygame.draw.rect(surface, (60, 60, 75), minus_rect,
                                 border_radius=2)
                pygame.draw.rect(surface, (60, 60, 75), plus_rect,
                                 border_radius=2)
                ms = value_font.render("-", True, (220, 220, 230))
                ps = value_font.render("+", True, (220, 220, 230))
                surface.blit(ms, (minus_rect.x +
                                  (minus_rect.w - ms.get_width()) // 2,
                                  minus_rect.y +
                                  (minus_rect.h - ms.get_height()) // 2))
                surface.blit(ps, (plus_rect.x +
                                  (plus_rect.w - ps.get_width()) // 2,
                                  plus_rect.y +
                                  (plus_rect.h - ps.get_height()) // 2))
                surface.blit(val_surf,
                             (val_rect_x,
                              row_rect.y + (row_h - val_surf.get_height()) // 2))
                settings_menu_rects.append((minus_rect, {
                    "kind": "step", "key": schema["key"],
                    "delta": -step,
                }))
                settings_menu_rects.append((plus_rect, {
                    "kind": "step", "key": schema["key"],
                    "delta": step,
                }))
            elif kind == "enum":
                cur_val = setting(schema["key"])
                # [<] value [>]
                options = schema.get("options", [])
                # If the schema provides display labels, show those
                # while the underlying stored value stays in `options`.
                # Lets us store ints (e.g. 300 seconds) but display
                # human-friendly labels ("5 min").
                option_labels = schema.get("option_labels")
                if option_labels and len(option_labels) == len(options):
                    try:
                        val_text = str(option_labels[options.index(cur_val)])
                    except ValueError:
                        val_text = str(cur_val)
                else:
                    val_text = str(cur_val)
                val_surf = value_font.render(val_text, True,
                                             (220, 220, 230))
                btn_w = 18
                next_rect = pygame.Rect(
                    ctrl_x_right - btn_w,
                    row_rect.y + (row_h - 16) // 2, btn_w, 16)
                val_rect_x = next_rect.x - 6 - val_surf.get_width()
                prev_rect = pygame.Rect(
                    val_rect_x - 6 - btn_w,
                    row_rect.y + (row_h - 16) // 2, btn_w, 16)
                pygame.draw.rect(surface, (60, 60, 75), prev_rect,
                                 border_radius=2)
                pygame.draw.rect(surface, (60, 60, 75), next_rect,
                                 border_radius=2)
                ls = value_font.render("<", True, (220, 220, 230))
                rs = value_font.render(">", True, (220, 220, 230))
                surface.blit(ls, (prev_rect.x +
                                  (prev_rect.w - ls.get_width()) // 2,
                                  prev_rect.y +
                                  (prev_rect.h - ls.get_height()) // 2))
                surface.blit(rs, (next_rect.x +
                                  (next_rect.w - rs.get_width()) // 2,
                                  next_rect.y +
                                  (next_rect.h - rs.get_height()) // 2))
                surface.blit(val_surf,
                             (val_rect_x,
                              row_rect.y + (row_h - val_surf.get_height()) // 2))
                settings_menu_rects.append((prev_rect, {
                    "kind": "enum_step", "key": schema["key"],
                    "delta": -1, "options": options,
                }))
                settings_menu_rects.append((next_rect, {
                    "kind": "enum_step", "key": schema["key"],
                    "delta": 1, "options": options,
                }))
            elif kind == "string":
                # Read-only string display. Settings of this kind are
                # set indirectly (via a button that runs a folder-picker
                # or similar) — there's no inline text editor in the
                # menu. Show a truncated value, right-aligned in a dim
                # color so it visually reads as "informational" rather
                # than "click here to edit".
                cur_val = setting(schema["key"])
                disp = str(cur_val) if cur_val else "(not set)"
                # Truncate to keep the row tidy. We don't need to be
                # precise about character count vs pixel width — the
                # menu width is fixed and the help text shows the full
                # value if needed.
                if len(disp) > 32:
                    disp = "…" + disp[-31:]
                col = (170, 170, 185) if cur_val else (110, 110, 130)
                disp_surf = value_font.render(disp, True, col)
                surface.blit(disp_surf,
                    (ctrl_x_right - disp_surf.get_width(),
                     row_rect.y + (row_h - disp_surf.get_height()) // 2))
            elif kind == "button":
                # An action trigger, not a value. Render as a small
                # rectangular button on the right side of the row;
                # click invokes the registered handler. Schema can
                # override the default "OPEN" label via "button_text"
                # — used by entries where "open" doesn't fit (e.g.
                # "Restart overlay" feels more like GO than OPEN).
                btn_text = schema.get("button_text", "OPEN")
                btn_surf = value_font.render(btn_text, True, (40, 40, 50))
                btn_w = max(46, btn_surf.get_width() + 14)
                btn_h = 16
                btn_rect = pygame.Rect(
                    ctrl_x_right - btn_w,
                    row_rect.y + (row_h - btn_h) // 2,
                    btn_w, btn_h)
                # Hover-lift like the toggle pills.
                is_btn_hover = btn_rect.collidepoint(*mouse_pos)
                btn_color = (200, 180, 130) if is_btn_hover else (180, 160, 110)
                pygame.draw.rect(surface, btn_color, btn_rect,
                                 border_radius=8)
                surface.blit(btn_surf,
                             (btn_rect.x + (btn_w - btn_surf.get_width()) // 2,
                              btn_rect.y + (btn_h - btn_surf.get_height()) // 2))
                settings_menu_rects.append((btn_rect, {
                    "kind": "action", "key": schema["key"],
                }))
            cy += row_h

    # Restore the clip rect we changed at the top of the function. If
    # we don't, subsequent draws (settings menu is one of many things
    # rendered each frame) get clipped to the menu interior — bug.
    surface.set_clip(prev_clip)

    # Scrollbar: only when content overflows. Drawn AFTER clip restore
    # so it sits on top of the rounded border instead of getting
    # clipped at the panel edge.
    if overflow > 0:
        sb_w = 4
        sb_x = mx + w - sb_w - 2
        # Track (full available height, dim).
        track_y = my + 2
        track_h = h - 4
        pygame.draw.rect(surface, (40, 40, 50),
                         (sb_x, track_y, sb_w, track_h),
                         border_radius=2)
        # Thumb size proportional to visible/natural ratio.
        thumb_h = max(20, int(track_h * h / max(1, h_natural)))
        thumb_y = track_y + int((track_h - thumb_h)
                                * settings_menu_scroll / overflow)
        pygame.draw.rect(surface, (130, 130, 150),
                         (sb_x, thumb_y, sb_w, thumb_h),
                         border_radius=2)


def dispatch_settings_menu_click(mx, my):
    """Resolve a click at (mx, my) against settings_menu_rects. Returns
    True if the click hit a control (and was dispatched), False if the
    menu didn't claim the click. The click handler closes the menu when
    a click lands OUTSIDE both the menu and the gear button."""
    for rect, action in settings_menu_rects:
        if rect.collidepoint(mx, my):
            akind = action["kind"]
            if akind == "toggle":
                # Live-bound toggles (currently just setup_mode) read
                # from a module global, not the settings dict. We
                # toggle by firing the same SETUP|toggle packet that
                # the //ow setup slash command uses, so the canonical
                # state-flipping logic (lock, anchor re-assertion,
                # setup banner) all runs through one path. The live
                # global will be flipped on the next prerender frame.
                live_key = action.get("live_key")
                if live_key == "setup_mode":
                    try:
                        _s = socket.socket(socket.AF_INET,
                                           socket.SOCK_DGRAM)
                        try:
                            _s.sendto(b"SETUP|toggle",
                                      ("127.0.0.1", 5005))
                        finally:
                            _s.close()
                    except Exception as e:
                        print(f"[OmniWatch] setup toggle (settings) "
                              f"failed: {e!r}")
                else:
                    cur = setting(action["key"])
                    set_setting(action["key"], not cur)
            elif akind == "step":
                cur = setting(action["key"])
                schema = SETTINGS_BY_KEY[action["key"]]
                new = cur + action["delta"]
                set_setting(action["key"], new)   # _coerce clamps
                _ = schema   # silence linter
            elif akind == "enum_step":
                cur = setting(action["key"])
                opts = action["options"]
                if opts:
                    try:
                        idx = opts.index(cur)
                    except ValueError:
                        idx = 0
                    new_idx = (idx + action["delta"]) % len(opts)
                    set_setting(action["key"], opts[new_idx])
            elif akind == "action":
                dispatch_setting_action(action["key"])
            return True
    return False


# ── DPS panel ─────────────────────────────────────────────────────────────
# Combat metrics panel populated from UDP port 5010. Shows rolling 5-min
# totals: per-source damage, accuracy/crit/evasion percentages, top WS
# breakdown, recent mobs hit. Toggleable visibility via //ow dps.
DPS_PANEL_PAD       = 8
DPS_PANEL_W         = 290
DPS_PANEL_LINE_H    = 14    # tight rows
DPS_PANEL_HEAD_H    = 18    # section heading row


def _format_dmg(n):
    """Compact damage formatter: 1234 → '1.2k', 1234567 → '1.23M'."""
    if not n:
        return "0"
    if n < 1000:
        return f"{int(n)}"
    if n < 1_000_000:
        return f"{n/1000:.1f}k"
    return f"{n/1_000_000:.2f}M"


def _format_dps_num(dps):
    """DPS number with one decimal up to 999.9, then compact."""
    if dps < 1000:
        return f"{dps:.1f}"
    if dps < 1_000_000:
        return f"{dps/1000:.2f}k"
    return f"{dps/1_000_000:.3f}M"


def scaled_dps_dims(scale):
    """Per-scale font + size dictionary for the DPS panel."""
    pad     = max(4, int(DPS_PANEL_PAD * scale))
    line_h  = max(11, int(DPS_PANEL_LINE_H * scale))
    head_h  = max(14, int(DPS_PANEL_HEAD_H * scale))
    panel_w = max(180, int(DPS_PANEL_W * scale))
    f_label = pygame.font.SysFont("Consolas", max(9, int(11 * scale)), bold=False)
    f_value = pygame.font.SysFont("Consolas", max(9, int(11 * scale)), bold=True)
    f_total = pygame.font.SysFont("Consolas", max(14, int(22 * scale)), bold=True)
    f_head  = pygame.font.SysFont("Consolas", max(10, int(12 * scale)), bold=True)
    return {
        "pad": pad, "line_h": line_h, "head_h": head_h,
        "panel_w": panel_w,
        "f_label": f_label, "f_value": f_value,
        "f_total": f_total, "f_head": f_head,
    }


def dps_panel_size(scale):
    """Estimate (w, h) for the DPS panel given the current dps_state.

    Sections:
      title strip                      (head_h)
      big DPS number                   (f_total height + small pad)
      stats grid                       (4-5 lines; +1 when SC is active)
      WS subhead + WS rows             (variable)
      Mob subhead + mob rows           (variable)
      Party rows                       (variable)
    """
    d = scaled_dps_dims(scale)
    pad   = d["pad"]
    line_h= d["line_h"]
    head_h= d["head_h"]
    w     = d["panel_w"]
    # Use 'me' bucket for sizing when available; else minimum.
    me = dps_state.get("me") or {}
    h = pad + head_h                       # title
    h += d["f_total"].get_height() + 2     # big DPS number
    # Stats grid is 4 rows by default, plus a 5th SC row when there's
    # been any skillchain activity. Must match the conditional row push
    # in draw_dps_panel().
    grid_rows = 4
    if me.get("sc", 0) > 0 or me.get("skillchains", 0) > 0:
        grid_rows = 5
    h += line_h * grid_rows
    if me or any(dps_ws_state.get(s) for s in dps_state):
        ws_for_me = dps_ws_state.get("me", {})
        if ws_for_me:
            h += head_h + line_h * min(4, len(ws_for_me))
    if me:
        mob_for_me = dps_mob_state.get("me", {})
        if mob_for_me:
            h += head_h + line_h * min(4, len(mob_for_me))
    # Party rows (just a single line per non-me source, brief).
    extra_sources = [s for s in dps_state if s != "me"]
    if extra_sources:
        h += head_h + line_h * len(extra_sources)
    h += pad
    if h < 80:
        h = 80
    return w, h


def draw_cfgwiz(surface):
    """Render the config wizard modal overlay if cfgwiz_visible.

    Layout:
      ┌──────────────────────────────────────────────┐
      │  Configure Song+ / Phantom Roll+ Gear        │  title bar
      ├──────────────────────────────────────────────┤
      │  Enter the +N counts from your typical cast  │  description
      │  set. all_songs sums Gjall (4), Whistle (2), │
      │  etc. Per-family fields sum the matching     │
      │  pieces (Mousai Gages NQ=carol+1, +1=carol+2).│
      ├──────────────────────────────────────────────┤
      │  Unity Rank (1=highest, 11=lowest):          │  section header
      │      [-] 1 [+]                               │  numeric field, 1..11
      ├──────────────────────────────────────────────┤
      │  Bards (you):                                │  section header
      │  [-] all_songs 4 [+]   [-] minuet 1 [+]   ...│  6 fields x 2 rows
      │  [-] minne 0 [+]       [-] mambo 0 [+]    ...│
      │                                              │
      │  Corsairs (you):                             │  section header
      │  [-] phantom_roll 0 [+]                      │
      ├──────────────────────────────────────────────┤
      │  Tip: ally bards/cors via //ow config <name> │  hint
      ├──────────────────────────────────────────────┤
      │            [ Save ] [ Skip ] [ Cancel ]      │  buttons
      └──────────────────────────────────────────────┘

    Populates cfgwiz_hit_rects so dispatch_cfgwiz_click can find which
    +/- or button was hit. Each entry is (rect, action, *extra) where
    action is "inc"/"dec" with extra=field_key, or "save"/"skip"/"cancel"
    with no extra.
    """
    global cfgwiz_hit_rects
    cfgwiz_hit_rects = []
    if not cfgwiz_visible:
        return

    win_w, win_h = surface.get_size()
    mw = CFGWIZ_MODAL_W

    # Compute height dynamically. Base layout (title + desc + bards
    # 2-row + cors 1-row + add-ally button + save/skip/cancel) is
    # ~CFGWIZ_MODAL_H. Each ally row adds ~46px, and the dropdown
    # form adds ~94px when open. Cap at 92% of window height so the
    # modal can't overflow the screen on small windows.
    bard_ally_count = len({
        k.split(".")[1] for k in cfgwiz_state
        if k.startswith("bards.") and not k.startswith("bards.self.")
    })
    cor_ally_count = len({
        k.split(".")[1] for k in cfgwiz_state
        if k.startswith("corsairs.")
        and not k.startswith("corsairs.self.")
    })
    extra_h = (bard_ally_count + cor_ally_count) * 46
    if bard_ally_count or cor_ally_count:
        extra_h += 25   # "Allies:" header
    if cfgwiz_dropdown_open:
        extra_h += 94
    desired_h = CFGWIZ_MODAL_H + extra_h
    mh = min(desired_h, int(win_h * 0.92))
    mx = (win_w - mw) // 2
    my = (win_h - mh) // 2

    # Dim the entire window behind the modal so the user knows it's
    # modal and clicks outside the modal go to "cancel".
    dim = pygame.Surface((win_w, win_h), pygame.SRCALPHA)
    dim.fill((0, 0, 0, 160))
    surface.blit(dim, (0, 0))

    # Modal background.
    pygame.draw.rect(surface, (28, 28, 36), (mx, my, mw, mh),
                     border_radius=6)
    pygame.draw.rect(surface, (140, 140, 170), (mx, my, mw, mh), 1,
                     border_radius=6)

    pad = 16
    f_title = get_font("default", 20, bold=True)
    f_text  = get_font("default", 14)
    f_label = get_font("default", 13, bold=True)
    f_value = get_font("default", 17, bold=True)
    f_btn   = get_font("default", 15, bold=True)

    # Title bar.
    tsurf = f_title.render("Configure Song+ / Phantom Roll+ Gear",
                           True, (230, 230, 240))
    surface.blit(tsurf, (mx + pad, my + pad))
    title_h = tsurf.get_height()
    cy = my + pad + title_h + 6

    # Separator under title.
    pygame.draw.line(surface, (90, 90, 110),
                     (mx + pad, cy), (mx + mw - pad, cy), 1)
    cy += 8

    # Description (3 lines wrap).
    desc_lines = [
        "Enter the +N counts from your typical cast set. Sum all gear",
        "pieces in that set. Examples: Gjallarhorn=All Songs+4,",
        "Mousai Gages=Carol+1 (NQ) or Carol+2 (+1).",
    ]
    for line in desc_lines:
        ds = f_text.render(line, True, (190, 190, 200))
        surface.blit(ds, (mx + pad, cy))
        cy += ds.get_height() + 1
    cy += 8

    # Helper to render one numeric field. Layout per cell:
    #
    #          LABEL                (centered above)
    #     VALUE  [+][-]             (value left, buttons grouped right)
    def _field(fx, fy, fw, label, key):
        btn_w = 24
        btn_h = 24
        btn_gap = 2

        # Label row (centered above).
        cell_cx = fx + fw // 2
        ls = f_label.render(label, True, (170, 170, 180))
        surface.blit(ls, (cell_cx - ls.get_width() // 2, fy))

        # Value + buttons row.
        row_y = fy + ls.get_height() + 4

        # Both buttons grouped against the right edge of the cell.
        # Order on screen: [+] then [-] (matches "+ -" in user request).
        minus_rect = pygame.Rect(fx + fw - btn_w, row_y, btn_w, btn_h)
        plus_rect  = pygame.Rect(minus_rect.x - btn_gap - btn_w,
                                 row_y, btn_w, btn_h)

        pygame.draw.rect(surface, (60, 60, 72), plus_rect,
                         border_radius=4)
        pygame.draw.rect(surface, (130, 130, 150), plus_rect, 1,
                         border_radius=4)
        ps = f_btn.render("+", True, (220, 220, 230))
        surface.blit(ps, (plus_rect.centerx - ps.get_width() // 2,
                          plus_rect.centery - ps.get_height() // 2))
        cfgwiz_hit_rects.append((plus_rect, "inc", key))

        pygame.draw.rect(surface, (60, 60, 72), minus_rect,
                         border_radius=4)
        pygame.draw.rect(surface, (130, 130, 150), minus_rect, 1,
                         border_radius=4)
        ms = f_btn.render("-", True, (220, 220, 230))
        surface.blit(ms, (minus_rect.centerx - ms.get_width() // 2,
                          minus_rect.centery - ms.get_height() // 2))
        cfgwiz_hit_rects.append((minus_rect, "dec", key))

        # Value: centered in the space LEFT of the button group.
        v = cfgwiz_state.get(key, 0)
        vs = f_value.render(str(v), True, (230, 230, 240))
        value_area_left  = fx
        value_area_right = plus_rect.x - btn_gap
        value_area_cx    = (value_area_left + value_area_right) // 2
        surface.blit(vs, (value_area_cx - vs.get_width() // 2,
                          row_y + (btn_h - vs.get_height()) // 2))

    # ── Unity Rank row ─────────────────────────────────────────────
    # Single numeric field, 1..11. Stored under "player.unity_rank".
    # GearInfo's Calculator scales Unity-augmented gear by this rank
    # (1 = highest tier of the player's Unity Concord, 11 = lowest).
    # We render it ABOVE the bard/cor rows so it reads as the most
    # prominent setting in the dialog.
    ur_hdr = f_label.render(
        "Unity Rank (1=highest, 11=lowest):", True, (200, 200, 220))
    surface.blit(ur_hdr, (mx + pad, cy))
    cy += ur_hdr.get_height() + 6
    # Use the same _field helper as Bards/Cors but pass a fixed slot
    # width so the field doesn't stretch across the modal. The dispatch
    # handler is special-cased for this key (clamp 1..11 instead of >=0).
    ur_field_w = (mw - 2 * pad) // 6   # one cell wide, like a bard family
    _field(mx + pad, cy, ur_field_w,
           "unity_rank", "player.unity_rank")
    cy += 56
    cy += 8

    # Bards section header.
    bs = f_label.render("Bards (you):", True, (200, 200, 220))
    surface.blit(bs, (mx + pad, cy))
    cy += bs.get_height() + 6

    # Two rows of 6 fields each.
    inner_w = mw - 2 * pad
    field_w = inner_w // 6
    for i, fk in enumerate(CFGWIZ_BARD_FAMILIES_ROW1):
        fx = mx + pad + i * field_w
        _field(fx, cy, field_w, fk, f"bards.self.{fk}")
    cy += 56
    for i, fk in enumerate(CFGWIZ_BARD_FAMILIES_ROW2):
        fx = mx + pad + i * field_w
        _field(fx, cy, field_w, fk, f"bards.self.{fk}")
    cy += 56

    cy += 8

    # Corsairs section header.
    cs = f_label.render("Corsairs (you):", True, (200, 200, 220))
    surface.blit(cs, (mx + pad, cy))
    cy += cs.get_height() + 6

    # Single field for phantom_roll. Use the same field layout but
    # wider so the longer label fits.
    cor_field_w = field_w * 2
    _field(mx + pad, cy, cor_field_w,
           "phantom_roll", "corsairs.self.phantom_roll")
    cy += 56

    cy += 8

    # Geomancers section header. Five fields in a single row, mirroring
    # the bard layout but narrower (5 instead of 6 per row).
    #   indi+    — gear boosting Indi-spell potency
    #   geo+     — gear boosting Geo-spell (Luopan) potency
    #   bolster+ — gear boosting Bolster strength
    #   handbell+— Handbell skill bonus above 900 (scales base potency)
    #   all+     — generic +all geomancy gear bucket (rare)
    gs = f_label.render("Geomancers (you):", True, (200, 200, 220))
    surface.blit(gs, (mx + pad, cy))
    cy += gs.get_height() + 6

    geo_field_w = inner_w // 5
    for i, fk in enumerate(CFGWIZ_GEO_FAMILIES):
        fx = mx + pad + i * geo_field_w
        _field(fx, cy, geo_field_w, fk, f"geomancers.self.{fk}")
    cy += 56

    cy += 8

    # ── Allies section ─────────────────────────────────────────────
    # Discover ally entries from cfgwiz_state. Bards have keys
    # "bards.<name>.<fam>"; cors have "corsairs.<name>.phantom_roll";
    # geomancers have "geomancers.<name>.<field>". Self entries excluded.
    bard_allies = sorted({
        k.split(".")[1] for k in cfgwiz_state
        if k.startswith("bards.") and not k.startswith("bards.self.")
    })
    cor_allies = sorted({
        k.split(".")[1] for k in cfgwiz_state
        if k.startswith("corsairs.")
        and not k.startswith("corsairs.self.")
    })
    geo_allies = sorted({
        k.split(".")[1] for k in cfgwiz_state
        if k.startswith("geomancers.")
        and not k.startswith("geomancers.self.")
    })

    if bard_allies or cor_allies or geo_allies:
        as_h = f_label.render("Allies:", True, (200, 200, 220))
        surface.blit(as_h, (mx + pad, cy))
        cy += as_h.get_height() + 6

    abbreviations = {
        "all_songs": "all", "minuet": "min", "march": "mar",
        "madrigal": "mad", "paeon": "pae", "ballad": "bal",
        "minne": "mne", "mambo": "mam", "prelude": "pre",
        "carol": "car", "etude": "etu", "scherzo": "sch",
        # Geomancer field abbreviations (5-letter cap matching bard style)
        "indi": "ind", "geo": "geo", "bolster": "bol",
        "handbell": "hb",  "all": "all",
    }
    fams_ordered = (CFGWIZ_BARD_FAMILIES_ROW1
                    + CFGWIZ_BARD_FAMILIES_ROW2)

    # Compact field: small [-] N [+] with a tiny label below.
    f_small = get_font("default", 11, bold=True)
    f_smval = get_font("default", 13, bold=True)

    def _compact_field(fx, fy, fw, abbrev, key):
        # Layout: VALUE  [+][-] on top row, abbrev label below.
        btn_w = 16
        btn_h = 16
        btn_gap = 1

        # Both buttons grouped on the right.
        minus_rect = pygame.Rect(fx + fw - btn_w, fy, btn_w, btn_h)
        plus_rect  = pygame.Rect(minus_rect.x - btn_gap - btn_w,
                                 fy, btn_w, btn_h)

        pygame.draw.rect(surface, (60, 60, 72), plus_rect,
                         border_radius=3)
        ps = f_smval.render("+", True, (220, 220, 230))
        surface.blit(ps, (plus_rect.centerx - ps.get_width() // 2,
                          plus_rect.centery - ps.get_height() // 2))
        cfgwiz_hit_rects.append((plus_rect, "inc", key))

        pygame.draw.rect(surface, (60, 60, 72), minus_rect,
                         border_radius=3)
        ms = f_smval.render("-", True, (220, 220, 230))
        surface.blit(ms, (minus_rect.centerx - ms.get_width() // 2,
                          minus_rect.centery - ms.get_height() // 2))
        cfgwiz_hit_rects.append((minus_rect, "dec", key))

        # Value centered in the area left of the buttons.
        v = cfgwiz_state.get(key, 0)
        vs = f_smval.render(str(v), True, (230, 230, 240))
        value_cx = (fx + plus_rect.x - btn_gap) // 2
        surface.blit(vs, (value_cx - vs.get_width() // 2,
                          fy + (btn_h - vs.get_height()) // 2))

        # Abbrev label below.
        ls = f_small.render(abbrev, True, (140, 140, 155))
        surface.blit(ls, (fx + (fw - ls.get_width()) // 2,
                          fy + btn_h + 1))

    inner_w = mw - 2 * pad
    name_w = 110
    rm_w = 26

    for ally in bard_allies:
        row_h = 42
        nl = f_label.render(f"{ally} (bard)", True, (210, 210, 220))
        surface.blit(nl, (mx + pad,
                          cy + (row_h - nl.get_height()) // 2))
        fields_x_start = mx + pad + name_w
        fields_avail_w = inner_w - name_w - rm_w - 8
        cf_w = max(28, fields_avail_w // 12)
        for fi, fk in enumerate(fams_ordered):
            _compact_field(
                fields_x_start + fi * cf_w, cy + 4, cf_w,
                abbreviations.get(fk, fk),
                f"bards.{ally}.{fk}")
        rx = mx + mw - pad - rm_w
        rm_rect = pygame.Rect(rx, cy + 8, rm_w, 22)
        pygame.draw.rect(surface, (110, 70, 80), rm_rect,
                         border_radius=3)
        rm_t = f_btn.render("X", True, (240, 240, 245))
        surface.blit(rm_t, (rm_rect.centerx - rm_t.get_width() // 2,
                            rm_rect.centery - rm_t.get_height() // 2))
        cfgwiz_hit_rects.append((rm_rect, "remove_ally", "bards", ally))
        cy += row_h

    for ally in cor_allies:
        row_h = 42
        nl = f_label.render(f"{ally} (cor)", True, (210, 210, 220))
        surface.blit(nl, (mx + pad,
                          cy + (row_h - nl.get_height()) // 2))
        fields_x_start = mx + pad + name_w
        _compact_field(fields_x_start, cy + 4, 80, "pr",
                       f"corsairs.{ally}.phantom_roll")
        rx = mx + mw - pad - rm_w
        rm_rect = pygame.Rect(rx, cy + 8, rm_w, 22)
        pygame.draw.rect(surface, (110, 70, 80), rm_rect,
                         border_radius=3)
        rm_t = f_btn.render("X", True, (240, 240, 245))
        surface.blit(rm_t, (rm_rect.centerx - rm_t.get_width() // 2,
                            rm_rect.centery - rm_t.get_height() // 2))
        cfgwiz_hit_rects.append((rm_rect, "remove_ally", "corsairs", ally))
        cy += row_h

    for ally in geo_allies:
        row_h = 42
        nl = f_label.render(f"{ally} (geo)", True, (210, 210, 220))
        surface.blit(nl, (mx + pad,
                          cy + (row_h - nl.get_height()) // 2))
        fields_x_start = mx + pad + name_w
        fields_avail_w = inner_w - name_w - rm_w - 8
        # 5 fields share the available width; min field width 36.
        cf_w = max(36, fields_avail_w // 5)
        for fi, fk in enumerate(CFGWIZ_GEO_FAMILIES):
            _compact_field(
                fields_x_start + fi * cf_w, cy + 4, cf_w,
                abbreviations.get(fk, fk),
                f"geomancers.{ally}.{fk}")
        rx = mx + mw - pad - rm_w
        rm_rect = pygame.Rect(rx, cy + 8, rm_w, 22)
        pygame.draw.rect(surface, (110, 70, 80), rm_rect,
                         border_radius=3)
        rm_t = f_btn.render("X", True, (240, 240, 245))
        surface.blit(rm_t, (rm_rect.centerx - rm_t.get_width() // 2,
                            rm_rect.centery - rm_t.get_height() // 2))
        cfgwiz_hit_rects.append((rm_rect, "remove_ally", "geomancers", ally))
        cy += row_h

    cy += 4

    # "+ Add Ally" button (centered). When clicked, the inline drop-
    # down expands directly below it with a name field + bard/cor
    # toggle + Confirm button.
    add_btn_w = 200
    add_btn_h = 30
    add_btn_x = mx + (mw - add_btn_w) // 2
    add_rect = pygame.Rect(add_btn_x, cy, add_btn_w, add_btn_h)
    pygame.draw.rect(surface, (45, 70, 90), add_rect,
                     border_radius=4)
    pygame.draw.rect(surface, (140, 160, 190), add_rect, 1,
                     border_radius=4)
    add_lbl = ("− Cancel Add Ally" if cfgwiz_dropdown_open
               else "+ Add Ally")
    abs2 = f_btn.render(add_lbl, True, (220, 230, 240))
    surface.blit(abs2, (add_rect.centerx - abs2.get_width() // 2,
                        add_rect.centery - abs2.get_height() // 2))
    cfgwiz_hit_rects.append(
        (add_rect,
         "add_ally_cancel" if cfgwiz_dropdown_open else "add_ally_open"))
    cy += add_btn_h + 6

    # Inline dropdown for the new-ally form.
    if cfgwiz_dropdown_open:
        # Background frame so it visually groups together.
        dd_pad_inner = 10
        dd_h = 88
        dd_rect = pygame.Rect(mx + pad, cy,
                              mw - 2 * pad, dd_h)
        pygame.draw.rect(surface, (38, 42, 52), dd_rect,
                         border_radius=4)
        pygame.draw.rect(surface, (120, 130, 150), dd_rect, 1,
                         border_radius=4)

        dx = dd_rect.x + dd_pad_inner
        dy = dd_rect.y + dd_pad_inner

        # Label.
        lbl = f_label.render("Name:", True, (200, 200, 215))
        surface.blit(lbl, (dx, dy + 6))

        # Text input field.
        ib_x = dx + 60
        ib_w = 200
        ib_h = 28
        ib_rect = pygame.Rect(ib_x, dy, ib_w, ib_h)
        pygame.draw.rect(surface, (50, 52, 62), ib_rect,
                         border_radius=4)
        pygame.draw.rect(surface, (180, 180, 200), ib_rect, 2,
                         border_radius=4)
        # Caret blinks at ~2 Hz so the field looks active.
        caret_on = (int(time.time() * 2) % 2 == 0)
        caret_str = "|" if caret_on else " "
        txt = f_value.render(cfgwiz_input_buffer + caret_str,
                             True, (230, 230, 240))
        surface.blit(txt, (ib_rect.x + 6,
                           ib_rect.centery - txt.get_height() // 2))
        # No hit_rect for the field — keystrokes go to it via keyboard
        # handler whenever the dropdown is open.

        # Bard / Cor / Geo radio toggle.
        radio_x = ib_rect.right + 16
        bard_rect = pygame.Rect(radio_x,         dy, 56, ib_h)
        cor_rect  = pygame.Rect(radio_x + 60,    dy, 56, ib_h)
        geo_rect  = pygame.Rect(radio_x + 120,   dy, 56, ib_h)
        bard_active = (cfgwiz_input_kind == "bard")
        cor_active  = (cfgwiz_input_kind == "cor")
        geo_active  = (cfgwiz_input_kind == "geo")
        for rect, label, active, action in [
            (bard_rect, "Bard", bard_active, "kind_bard"),
            (cor_rect,  "COR",  cor_active,  "kind_cor"),
            (geo_rect,  "Geo",  geo_active,  "kind_geo"),
        ]:
            fill = (60, 110, 80) if active else (60, 60, 72)
            pygame.draw.rect(surface, fill, rect, border_radius=4)
            pygame.draw.rect(surface, (180, 180, 200), rect, 1,
                             border_radius=4)
            ts = f_btn.render(label, True, (230, 230, 240))
            surface.blit(ts, (rect.centerx - ts.get_width() // 2,
                              rect.centery - ts.get_height() // 2))
            cfgwiz_hit_rects.append((rect, action))

        # Confirm button on second row.
        conf_rect = pygame.Rect(dx, dy + ib_h + 8,
                                100, 28)
        pygame.draw.rect(surface, (60, 110, 80), conf_rect,
                         border_radius=4)
        pygame.draw.rect(surface, (180, 180, 200), conf_rect, 1,
                         border_radius=4)
        cs2 = f_btn.render("Confirm", True, (240, 240, 245))
        surface.blit(cs2, (conf_rect.centerx - cs2.get_width() // 2,
                           conf_rect.centery - cs2.get_height() // 2))
        cfgwiz_hit_rects.append((conf_rect, "add_ally_confirm"))

        # Hint text inline.
        hint = f_text.render(
            "Enter to confirm, Esc to cancel. Name is lowercased.",
            True, (160, 160, 175))
        surface.blit(hint,
                     (conf_rect.right + 14,
                      conf_rect.centery - hint.get_height() // 2))

        cy += dd_h + 6

    # Buttons at the bottom.
    btn_y = my + mh - 36
    btn_w = 90
    btn_h = 26
    btn_gap = 10
    # Compute button bar centered.
    total_w = btn_w * 3 + btn_gap * 2
    bar_x = mx + (mw - total_w) // 2

    for i, (label, action, fill) in enumerate([
        ("Save",   "save",   (60, 110, 80)),
        ("Skip",   "skip",   (90, 90, 100)),
        ("Cancel", "cancel", (110, 70, 80)),
    ]):
        bx = bar_x + i * (btn_w + btn_gap)
        rect = pygame.Rect(bx, btn_y, btn_w, btn_h)
        pygame.draw.rect(surface, fill, rect, border_radius=4)
        pygame.draw.rect(surface, (180, 180, 200), rect, 1,
                         border_radius=4)
        ts = f_btn.render(label, True, (240, 240, 245))
        surface.blit(ts, (rect.centerx - ts.get_width() // 2,
                          rect.centery - ts.get_height() // 2))
        cfgwiz_hit_rects.append((rect, action))

    # Modal panel rect for click-out detection. Stored as a sentinel
    # last entry with action "modal_bounds" — dispatch checks for
    # collisions against this LAST so click-out (no inside hit) becomes
    # cancel.
    modal_rect = pygame.Rect(mx, my, mw, mh)
    cfgwiz_hit_rects.append((modal_rect, "modal_bounds"))


def dispatch_cfgwiz_click(mx, my):
    """Handle a left-click during cfgwiz modal. Returns True if the click
    was consumed (modal is up and click was inside the modal or on a
    control). Click-out (modal up, click outside) sends CFGWIZ|cancel
    and returns True too — modal eats the click either way."""
    global cfgwiz_visible, cfgwiz_input_kind
    if not cfgwiz_visible:
        return False
    # Walk hit rects. Buttons and +/- come BEFORE modal_bounds in the
    # list, so we'll find them first if the click is on one.
    inside_modal = False
    for entry in cfgwiz_hit_rects:
        rect = entry[0]
        action = entry[1]
        if action == "modal_bounds":
            if rect.collidepoint(mx, my):
                inside_modal = True
            continue
        if not rect.collidepoint(mx, my):
            continue
        if action == "inc":
            key = entry[2]
            if key == "player.unity_rank":
                # Unity Rank is 1..11, default 1.
                cur = int(cfgwiz_state.get(key, 1)) or 1
                cfgwiz_state[key] = min(11, cur + 1)
            else:
                cfgwiz_state[key] = max(0, int(cfgwiz_state.get(key, 0)) + 1)
            return True
        if action == "dec":
            key = entry[2]
            if key == "player.unity_rank":
                cur = int(cfgwiz_state.get(key, 1)) or 1
                cfgwiz_state[key] = max(1, cur - 1)
            else:
                cfgwiz_state[key] = max(0, int(cfgwiz_state.get(key, 0)) - 1)
            return True
        if action == "save":
            _cfgwiz_send_save()
            _cfgwiz_close()
            return True
        if action == "skip":
            _cfgwiz_send("CFGWIZ|skip")
            _cfgwiz_close()
            return True
        if action == "cancel":
            _cfgwiz_send("CFGWIZ|cancel")
            _cfgwiz_close()
            return True
        if action == "add_ally_open":
            _cfgwiz_dropdown_set(True)
            return True
        if action == "add_ally_cancel":
            _cfgwiz_dropdown_set(False)
            return True
        if action == "add_ally_confirm":
            _cfgwiz_commit_ally()
            return True
        if action == "kind_bard":
            cfgwiz_input_kind = "bard"
            return True
        if action == "kind_cor":
            cfgwiz_input_kind = "cor"
            return True
        if action == "kind_geo":
            cfgwiz_input_kind = "geo"
            return True
        if action == "remove_ally":
            _cfgwiz_remove_ally(entry[2], entry[3])  # kind, name
            return True
    # Click was outside any control. If it was outside the modal too,
    # treat as cancel.
    if not inside_modal:
        _cfgwiz_send("CFGWIZ|cancel")
        _cfgwiz_close()
        return True
    # Click inside modal but on dead space — eat it, do nothing.
    return True


def _cfgwiz_close():
    """Close the wizard and reset all related state so the next open
    starts clean."""
    global cfgwiz_visible
    global cfgwiz_dropdown_open, cfgwiz_input_buffer, cfgwiz_input_kind
    cfgwiz_visible = False
    cfgwiz_dropdown_open = False
    cfgwiz_input_buffer = ""
    cfgwiz_input_kind = "bard"


def _cfgwiz_dropdown_set(open_state):
    """Toggle the inline Add-Ally dropdown. Resets the input buffer
    on every open so stale text from a previous attempt doesn't carry
    over."""
    global cfgwiz_dropdown_open, cfgwiz_input_buffer, cfgwiz_input_kind
    cfgwiz_dropdown_open = bool(open_state)
    if open_state:
        cfgwiz_input_buffer = ""
        cfgwiz_input_kind = "bard"


def _cfgwiz_commit_ally():
    """Commit the dropdown's name + kind into cfgwiz_state. No-op if
    the name is empty or 'self' (reserved). Lowercases the name to
    match Buff_Processing's settings.Bards key convention."""
    global cfgwiz_dropdown_open
    name = cfgwiz_input_buffer.strip().lower()
    if not name or name == "self":
        return
    if cfgwiz_input_kind == "bard":
        # Initialize all 12 family fields at 0 so the row renders.
        for fk in (CFGWIZ_BARD_FAMILIES_ROW1
                   + CFGWIZ_BARD_FAMILIES_ROW2):
            cfgwiz_state.setdefault(f"bards.{name}.{fk}", 0)
    elif cfgwiz_input_kind == "geo":
        # Initialize all 5 geomancer fields at 0 so the row renders.
        for fk in CFGWIZ_GEO_FAMILIES:
            cfgwiz_state.setdefault(f"geomancers.{name}.{fk}", 0)
    else:  # "cor"
        cfgwiz_state.setdefault(f"corsairs.{name}.phantom_roll", 0)
    _cfgwiz_dropdown_set(False)


def _cfgwiz_remove_ally(kind, name):
    """Remove all cfgwiz_state keys belonging to the given ally."""
    prefix = f"{kind}.{name}."
    for k in list(cfgwiz_state.keys()):
        if k.startswith(prefix):
            del cfgwiz_state[k]


def _cfgwiz_send(packet_str):
    """Send a CFGWIZ packet to Lua via the inbound command socket."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as _s:
            _s.sendto(packet_str.encode("utf-8"),
                      ("127.0.0.1", 5011))
    except Exception as e:
        print(f"[OmniWatch] cfgwiz send failed: {e}")


def _cfgwiz_send_save():
    """Serialize cfgwiz_state into a CFGWIZ|save|<flat-fields> packet
    and send to Lua. Only sends fields whose key starts with bards.,
    corsairs., geomancers., or player. — anything else in cfgwiz_state
    is junk."""
    pairs = []
    for k in sorted(cfgwiz_state.keys()):
        if not (k.startswith("bards.")
                or k.startswith("corsairs.")
                or k.startswith("geomancers.")
                or k.startswith("player.")):
            continue
        pairs.append(f"{k}={int(cfgwiz_state[k])}")
    payload = "CFGWIZ|save|" + ",".join(pairs)
    _cfgwiz_send(payload)


def draw_dps_panel(surface, x, y, scale=1.0, locked=False):
    """Render the DPS panel at (x, y). Returns (w, h)."""
    d = scaled_dps_dims(scale)
    pad    = d["pad"]
    line_h = d["line_h"]
    head_h = d["head_h"]
    pw, ph = dps_panel_size(scale)

    pygame.draw.rect(surface, COL_PANEL,  (x, y, pw, ph), border_radius=4)
    pygame.draw.rect(surface, COL_BORDER, (x, y, pw, ph), 1, border_radius=4)
    draw_accent_stripe(surface, x, y, ph, ACCENT_DPS)

    cy = y + pad
    me = dps_state.get("me")

    # Title strip. Prefer the live `me["window"]` (what the lua just
    # used to bucket the displayed DPS) so the title matches the
    # number. When there's no combat data yet (common when fiddling
    # with settings), fall back to the configured setting so the
    # title reflects the user's current pick — not a hardcoded 5 min
    # placeholder that ignored the setting entirely.
    # Use `is not None` everywhere instead of truthiness — encounter
    # mode is window=0, which is falsy but still a valid window value
    # we want the title to honor.
    if me and me.get("window") is not None:
        win_secs = me["window"]
        scope_lbl = "all" if me.get("scope") == "all" else "me"
    else:
        cfg = setting("dps_window_seconds")
        win_secs = cfg if cfg is not None else 300
        scope_lbl = "me"
    if win_secs == 0:
        # Sentinel: encounter mode (per-fight tracking).
        title = f"DPS · Encounter · {scope_lbl}"
    else:
        win_min = win_secs / 60.0
        # Show one decimal for sub-minute windows, integer otherwise.
        if win_min < 1:
            title = f"DPS · {win_secs}s · {scope_lbl}"
        else:
            title = f"DPS · {win_min:.0f}min · {scope_lbl}"
    t_surf = d["f_head"].render(title, True, COL_LABEL_DIM)
    surface.blit(t_surf, (x + pad, cy))
    cy += head_h

    if not me:
        # Empty state: show a hint and stop.
        hint = d["f_label"].render("(no recent combat)", True, COL_LABEL_DIM)
        surface.blit(hint, (x + pad, cy))
        return pw, ph

    # ── DPS sparkline (renders BEHIND the headline number) ──────────────
    # Trend line of the last DPS_SPARK_WINDOW seconds of 'me' DPS values,
    # scaled vertically to fit the headline strip. Drawn first so the
    # number renders on top of it. Uses the panel's accent color, dimmed,
    # so it ties visually to the panel's identity strip.
    # Toggleable via the "Show sparkline" setting (Settings → Display).
    if setting("dps_sparkline") and len(dps_history) >= 2:
        now = time.time()
        cutoff = now - DPS_SPARK_WINDOW
        # Collect points in window
        pts = [(t, v) for (t, v) in dps_history if t >= cutoff]
        if len(pts) >= 2:
            # NOTE: deliberately do NOT name this local 'line_h' — that
            # would shadow the outer d["line_h"] used by the stats grid
            # and section rows, causing the rest of the panel to
            # mis-space and bleed off the bottom. Use spark_h directly.
            spark_x = x + pad
            spark_y = cy
            spark_w = pw - pad * 2
            spark_h = d["f_total"].get_height()
            # Map (timestamp, dps) → (x, y). Time spans the full window
            # so the line sweeps right as new samples arrive.
            t_min = pts[0][0]
            t_max = pts[-1][0]
            t_range = max(0.5, t_max - t_min)
            v_max = max(v for _, v in pts) or 1.0
            # Slight ceiling so the peak doesn't kiss the top edge.
            v_max *= 1.10
            poly = []
            for (t, v) in pts:
                px_x = spark_x + int((t - t_min) / t_range * spark_w)
                # Invert Y so higher DPS is higher on screen.
                px_y = spark_y + spark_h - int((v / v_max) * spark_h)
                poly.append((px_x, px_y))
            # Dimmed crimson, blends with the DPS accent without fighting
            # the foreground number.
            spark_col = (90, 40, 35)
            try:
                pygame.draw.lines(surface, spark_col, False, poly, 1)
            except ValueError:
                # Fewer than 2 distinct points — draw nothing this frame.
                pass

    # Big total-DPS number.
    dps_str = _format_dps_num(me.get("dps", 0.0))
    dps_surf = d["f_total"].render(dps_str, True, (240, 230, 180))
    surface.blit(dps_surf, (x + pad, cy))
    # "DPS" label to the right of the number.
    lab = d["f_head"].render("DPS", True, COL_LABEL_DIM)
    surface.blit(lab, (x + pad + dps_surf.get_width() + 6,
                        cy + dps_surf.get_height() - lab.get_height() - 2))
    # Total damage and longest hit on the right side.
    tot_str = f"{_format_dmg(me.get('total', 0))} dmg"
    tot_surf = d["f_value"].render(tot_str, True, (200, 200, 230))
    surface.blit(tot_surf, (x + pw - tot_surf.get_width() - pad, cy))
    long_str = f"longest: {_format_dmg(me.get('longest', 0))}"
    long_surf = d["f_label"].render(long_str, True, COL_LABEL_DIM)
    surface.blit(long_surf,
                 (x + pw - long_surf.get_width() - pad,
                  cy + tot_surf.get_height() + 1))
    cy += dps_surf.get_height() + 2

    # Stats grid: 2 columns × 4-5 rows. The skillchain row is added only
    # when there's been a skillchain in the window — otherwise it'd just
    # be a row of zeros taking space.
    col_w = (pw - pad * 3) // 2
    rows = [
        ("White",  _format_dmg(me.get("white", 0)),
         "Magic",  _format_dmg(me.get("magic", 0))),
        ("WS",     _format_dmg(me.get("ws", 0)),
         "Hits",   f"{me.get('hits', 0)}/{me.get('hits',0)+me.get('misses',0)}"),
        ("Crit%",  f"{me.get('crit_pct', 0):.1f}",
         "Acc%",   f"{me.get('melee_acc', 0):.1f}"),
        ("Mag%",   f"{me.get('magic_acc', 0):.1f}",
         "Evd%",   f"{me.get('evasion', 0):.1f}"),
    ]
    if me.get("sc", 0) > 0 or me.get("skillchains", 0) > 0:
        rows.append((
            "SC",  _format_dmg(me.get("sc", 0)),
            "SC#", f"{me.get('skillchains', 0)}",
        ))
    for left_lab, left_val, right_lab, right_val in rows:
        # Left column.
        l_lab = d["f_label"].render(left_lab, True, COL_LABEL_DIM)
        l_val = d["f_value"].render(left_val, True, (220, 220, 230))
        surface.blit(l_lab, (x + pad, cy))
        surface.blit(l_val,
                     (x + pad + col_w - l_val.get_width(), cy))
        # Right column.
        r_lab = d["f_label"].render(right_lab, True, COL_LABEL_DIM)
        r_val = d["f_value"].render(right_val, True, (220, 220, 230))
        surface.blit(r_lab, (x + pad * 2 + col_w, cy))
        surface.blit(r_val,
                     (x + pw - pad - r_val.get_width(), cy))
        cy += line_h

    # WS breakdown.
    ws_for_me = dps_ws_state.get("me", {})
    if ws_for_me:
        h_surf = d["f_head"].render("Weapon Skills", True, COL_LABEL_DIM)
        surface.blit(h_surf, (x + pad, cy))
        cy += head_h
        # Sort by total damage descending; show top 4.
        sorted_ws = sorted(ws_for_me.items(),
                           key=lambda kv: kv[1].get("total", 0),
                           reverse=True)[:4]
        for ws_name, w in sorted_ws:
            count = w.get("count", 0)
            total = w.get("total", 0)
            best  = w.get("best", 0)
            avg   = total // count if count else 0
            left = f"{ws_name}  ×{count}"
            right = f"{_format_dmg(total)}  (avg {_format_dmg(avg)}, best {_format_dmg(best)})"
            l_surf = d["f_label"].render(left, True, (210, 200, 230))
            r_surf = d["f_label"].render(right, True, (180, 180, 200))
            surface.blit(l_surf, (x + pad, cy))
            surface.blit(r_surf,
                         (x + pw - pad - r_surf.get_width(), cy))
            cy += line_h

    # Mob breakdown.
    mob_for_me = dps_mob_state.get("me", {})
    if mob_for_me:
        h_surf = d["f_head"].render("Mobs Hit", True, COL_LABEL_DIM)
        surface.blit(h_surf, (x + pad, cy))
        cy += head_h
        sorted_mobs = sorted(mob_for_me.items(),
                             key=lambda kv: kv[1].get("total", 0),
                             reverse=True)[:4]
        for mob_name, m in sorted_mobs:
            total = m.get("total", 0)
            since = m.get("since", 0.0)
            since_lbl = f"{int(since)}s ago" if since >= 1 else "now"
            left = f"{mob_name}"
            right = f"{_format_dmg(total)}  ({since_lbl})"
            l_surf = d["f_label"].render(left, True, (220, 210, 200))
            r_surf = d["f_label"].render(right, True, COL_LABEL_DIM)
            # Truncate name if it would collide with the right side.
            avail_w = pw - pad * 2 - r_surf.get_width() - 6
            if l_surf.get_width() > avail_w:
                # Crude character truncation.
                approx_chars = max(4, int(avail_w / 6))
                left = mob_name[:approx_chars - 1] + "…"
                l_surf = d["f_label"].render(left, True, (220, 210, 200))
            surface.blit(l_surf, (x + pad, cy))
            surface.blit(r_surf,
                         (x + pw - pad - r_surf.get_width(), cy))
            cy += line_h

    # Party / pet rows (anything in dps_state that isn't 'me').
    others = [(s, b) for s, b in dps_state.items() if s != "me"]
    if others:
        h_surf = d["f_head"].render("Others", True, COL_LABEL_DIM)
        surface.blit(h_surf, (x + pad, cy))
        cy += head_h
        for src, b in others:
            left = src
            right = f"{_format_dps_num(b.get('dps', 0))} dps · {_format_dmg(b.get('total', 0))}"
            l_surf = d["f_label"].render(left, True, (200, 220, 200))
            r_surf = d["f_label"].render(right, True, COL_LABEL_DIM)
            surface.blit(l_surf, (x + pad, cy))
            surface.blit(r_surf,
                         (x + pw - pad - r_surf.get_width(), cy))
            cy += line_h

    return pw, ph


# ── Button panel ─────────────────────────────────────────────────────────
# 6 wide × 2 tall grid of user-configurable buttons. Each button runs the
# command in buttons_config[idx] when clicked. Layout: BTN_W per button,
# BTN_H per row, BTN_GAP between, BTN_PAD on the outer edge.
BTN_COLS    = 10
BTN_ROWS    = 2
BTN_W       = 56
BTN_H       = 36
BTN_GAP     = 4
BTN_PAD     = 6
BTN_ICON_SZ = 22
BTN_HDR_H   = 18      # header row above the button grid (page name + arrows)

def buttons_panel_size(scale=1.0):
    """Total panel size at `scale`. Returns (w, h)."""
    s = max(0.5, min(2.5, float(scale)))
    cell_w = max(28, int(BTN_W * s))
    cell_h = max(20, int(BTN_H * s))
    gap    = max(2, int(BTN_GAP * s))
    pad    = max(3, int(BTN_PAD * s))
    hdr_h  = max(14, int(BTN_HDR_H * s))
    pw = pad * 2 + cell_w * BTN_COLS + gap * (BTN_COLS - 1)
    ph = pad * 2 + hdr_h + cell_h * BTN_ROWS + gap * BTN_ROWS
    return pw, ph

def draw_buttons_panel(surface, x, y, scale=1.0, locked=False,
                       panel_idx=0):
    """Render the 6×2 button panel at (x, y). Populates buttons_rects /
    buttons_panel_rects[panel_idx] so the click handler can resolve hits.
    Returns (w, h).

    panel_idx: which panel slot this is (0 = original primary panel,
        1..N-1 = additional multi-mode panels). Used to:
        - look up the panel's current content page in hotbar_panel_pages
        - route hit-test results to buttons_panel_rects[panel_idx] (for
          panel_idx > 0) or buttons_rects (for panel_idx == 0).
    """
    global buttons_rects, buttons_panel_rects
    s = max(0.5, min(2.5, float(scale)))
    cell_w = max(28, int(BTN_W * s))
    cell_h = max(20, int(BTN_H * s))
    gap    = max(2, int(BTN_GAP * s))
    pad    = max(3, int(BTN_PAD * s))
    icon_sz= max(14, int(BTN_ICON_SZ * s))
    hdr_h  = max(14, int(BTN_HDR_H * s))
    pw, ph = buttons_panel_size(scale)

    # Resolve which content page this panel is currently showing. Panel 0
    # defaults to hotbar_current_page (legacy single-mode behaviour); all
    # other panels track their own current page in hotbar_panel_pages.
    if panel_idx == 0:
        eff_page_idx = hotbar_panel_pages.get(0, hotbar_current_page)
    else:
        eff_page_idx = hotbar_panel_pages.get(panel_idx, panel_idx)
    # Clamp into valid range (config edits or page-count changes can
    # leave a stale higher index).
    n_pages_local = max(1, len(hotbar_pages))
    if eff_page_idx < 0 or eff_page_idx >= n_pages_local:
        eff_page_idx = 0
        hotbar_panel_pages[panel_idx] = 0

    # Per-panel rects collection. Panel 0 uses the legacy buttons_rects
    # (consumed by all the existing click-handler loops without changes);
    # panels 1..N-1 stash into buttons_panel_rects[panel_idx], iterated
    # by the multi-mode hit-testing in the event handlers.
    if panel_idx == 0:
        buttons_rects = []
        local_rects = buttons_rects
    else:
        local_rects = []
        buttons_panel_rects[panel_idx] = local_rects

    # Resolve buttons list for the page being rendered.
    if hotbar_pages and 0 <= eff_page_idx < len(hotbar_pages):
        page_buttons = hotbar_pages[eff_page_idx].get("buttons", [])
        page_dict    = hotbar_pages[eff_page_idx]
    else:
        page_buttons = []
        page_dict    = None

    # Outer frame, matching DPS / buff panels.
    pygame.draw.rect(surface, COL_PANEL,  (x, y, pw, ph), border_radius=4)
    pygame.draw.rect(surface, COL_BORDER, (x, y, pw, ph), 1, border_radius=4)
    draw_accent_stripe(surface, x, y, ph, ACCENT_BUTTONS)

    mx, my = pygame.mouse.get_pos()

    # font_moon is ~12px which fits BTN_H=36 nicely with single-line labels.
    label_font = font_moon

    # ── Header row: page name (left) + page arrows + page indicator (right) ──
    # The page name is editable via the hotbar editor (treated as a 21st
    # field after the 20 button slots — see hotbar_edit_slot conventions).
    # Arrows wrap (left from page 0 → last page).
    #
    # Per-panel scoping: in multi-hotbar mode each panel has its own current
    # page. The action tuples we emit into local_rects encode which panel
    # owns the click, e.g. ("__page_prev__", panel_idx). Panel 0 still emits
    # the legacy bare-string action so existing handlers keep working
    # (single-mode is the most common case; we don't churn its hot path).
    hdr_y = y + pad
    page_name = (page_dict and page_dict.get("name")) or f"Page {eff_page_idx + 1}"
    # Page name on the LEFT. Truncate so it doesn't overflow the arrows.
    name_max_w = pw - pad * 2 - 80   # reserve right edge for nav (≈80px)
    name_surf  = label_font.render(page_name, True, (220, 220, 230))
    if name_surf.get_width() > name_max_w:
        cut = page_name
        while cut and label_font.render(cut + "…", True, (220, 220, 230)).get_width() > name_max_w:
            cut = cut[:-1]
        name_surf = label_font.render((cut + "…") if cut else page_name[:1],
                                       True, (220, 220, 230))
    name_x = x + pad
    surface.blit(name_surf, (name_x,
                             hdr_y + (hdr_h - name_surf.get_height()) // 2))
    # Whole left half of header is a click-target for editing the name.
    name_rect = pygame.Rect(x + pad, hdr_y, name_max_w, hdr_h)
    if panel_idx == 0:
        local_rects.append((name_rect, "__page_name__"))
    else:
        local_rects.append((name_rect, ("__page_name__", panel_idx)))

    # Right side: < N/T >. Always shown so each panel cycles independently.
    arrow_w = max(14, int(14 * s))
    nav_y   = hdr_y
    right_arrow = pygame.Rect(x + pw - pad - arrow_w, nav_y,
                              arrow_w, hdr_h)
    # Indicator string between arrows.
    n_pages = max(1, len(hotbar_pages))
    indicator = f"{eff_page_idx + 1}/{n_pages}"
    ind_surf  = label_font.render(indicator, True, (200, 200, 215))
    ind_w     = ind_surf.get_width() + 6
    left_arrow = pygame.Rect(right_arrow.x - ind_w - arrow_w, nav_y,
                             arrow_w, hdr_h)
    ind_x = left_arrow.right
    # Hover styling for arrows.
    for arr_rect, label_text, action_name in (
        (left_arrow,  "<", "__page_prev__"),
        (right_arrow, ">", "__page_next__"),
    ):
        is_hov = arr_rect.collidepoint(mx, my) and not locked
        pygame.draw.rect(surface,
            (62, 62, 78) if is_hov else (40, 40, 50),
            arr_rect, border_radius=2)
        pygame.draw.rect(surface,
            (180, 180, 200) if is_hov else (90, 90, 105),
            arr_rect, 1, border_radius=2)
        a_surf = label_font.render(label_text, True, (220, 220, 230))
        surface.blit(a_surf,
            (arr_rect.x + (arr_rect.width  - a_surf.get_width())  // 2,
             arr_rect.y + (arr_rect.height - a_surf.get_height()) // 2))
        if panel_idx == 0:
            local_rects.append((arr_rect, action_name))
        else:
            local_rects.append((arr_rect, (action_name, panel_idx)))
    # Indicator text between arrows.
    surface.blit(ind_surf, (ind_x + 3,
                            nav_y + (hdr_h - ind_surf.get_height()) // 2))

    for row in range(BTN_ROWS):
        for col in range(BTN_COLS):
            idx = row * BTN_COLS + col
            entry = page_buttons[idx] if idx < len(page_buttons) else None
            bx = x + pad + col * (cell_w + gap)
            by = y + pad + hdr_h + gap + row * (cell_h + gap)
            rect = pygame.Rect(bx, by, cell_w, cell_h)
            # Panel 0: legacy (rect, idx) shape so existing handlers work.
            # Other panels: (rect, (idx, panel_idx)) so we can route the
            # click to the right panel's content page.
            if panel_idx == 0:
                local_rects.append((rect, idx))
            else:
                local_rects.append((rect, (idx, panel_idx)))

            is_inert = (entry is None
                        or entry["kind"] == "none"
                        or not entry["command"])
            is_hover = (rect.collidepoint(mx, my) and not is_inert
                        and not locked)

            # Cell background. Inert buttons are dimmer so users can see
            # which slots are unconfigured at a glance.
            if is_inert:
                cell_bg    = (28, 28, 36)
                border_col = (60, 60, 70)
            elif is_hover:
                cell_bg    = (62, 62, 78)
                border_col = (180, 180, 200)
            else:
                cell_bg    = (44, 44, 54)
                border_col = (100, 100, 115)
            pygame.draw.rect(surface, cell_bg, rect, border_radius=3)
            pygame.draw.rect(surface, border_col, rect, 1, border_radius=3)

            if entry is None:
                continue

            label = entry["label"]
            icon  = entry["icon"]
            icon_surf = get_ui_icon_scaled(icon, icon_sz) if icon else None
            text_color = (160, 160, 170) if is_inert else (220, 220, 230)

            # Layout: icon-only | label-only | icon+label (icon left).
            if icon_surf and label:
                ix = bx + 4
                iy = by + (cell_h - icon_sz) // 2
                surface.blit(icon_surf, (ix, iy))
                lab_surf = label_font.render(label, True, text_color)
                avail_w = cell_w - icon_sz - 10
                if lab_surf.get_width() > avail_w:
                    short = label
                    while short and label_font.size(short + "…")[0] > avail_w:
                        short = short[:-1]
                    lab_surf = label_font.render(short + "…", True, text_color)
                lx = ix + icon_sz + 4
                ly = by + (cell_h - lab_surf.get_height()) // 2
                surface.blit(lab_surf, (lx, ly))
            elif icon_surf:
                ix = bx + (cell_w - icon_sz) // 2
                iy = by + (cell_h - icon_sz) // 2
                surface.blit(icon_surf, (ix, iy))
            elif label:
                lab_surf = label_font.render(label, True, text_color)
                avail_w = cell_w - 6
                if lab_surf.get_width() > avail_w:
                    short = label
                    while short and label_font.size(short + "…")[0] > avail_w:
                        short = short[:-1]
                    lab_surf = label_font.render(short + "…", True, text_color)
                lx = bx + (cell_w - lab_surf.get_width()) // 2
                ly = by + (cell_h - lab_surf.get_height()) // 2
                surface.blit(lab_surf, (lx, ly))
            # else: empty slot, just the dim cell.

    return pw, ph


# ── Hotbar editor ────────────────────────────────────────────────────────
# In-app editor for the 20 hotbar slots. Triggered by Settings → HotBar
# → "Edit hotbar" which sets hotbar_edit_mode = True. While editing, the
# normal hotbar still renders (slot clicks SELECT for editing instead of
# running commands), and an inline form panel appears below the hotbar
# with fields for the currently-selected slot.
#
# Click flow:
#   1. User clicks slot N in the hotbar      → hotbar_edit_slot = N,
#                                               draft = copy of buttons_config[N]
#   2. User clicks Label / Command field     → hotbar_focused_field set, cursor at end
#   3. User types                            → KEYDOWN events dispatch to focused field
#   4. User clicks [<] / [>] on Kind         → cycles kinds
#   5. User clicks "Pick icon"               → opens icon picker grid
#   6. User clicks an icon thumbnail         → draft["icon"] = filename, picker closes
#   7. User clicks Save                      → buttons_config[slot] = draft, save_buttons_config()
#   8. User clicks Cancel / "Done editing"   → exits edit mode without saving in-progress draft

HOTBAR_EDIT_FORM_H   = 200   # height of the inline form panel
HOTBAR_EDIT_FIELD_H  = 22
HOTBAR_KINDS         = ["windower", "shell", "url", "file", "none"]


def _hotbar_editor_get_focused_text():
    """Return the text currently in the focused field (or empty string)."""
    if hotbar_edit_draft is None or hotbar_focused_field is None:
        return ""
    return hotbar_edit_draft.get(hotbar_focused_field, "") or ""


def _hotbar_editor_set_focused_text(new_text):
    """Write back into the focused field of the draft."""
    if hotbar_edit_draft is None or hotbar_focused_field is None:
        return
    hotbar_edit_draft[hotbar_focused_field] = new_text


def hotbar_editor_handle_keydown(event):
    """Apply a pygame KEYDOWN to the focused text field. Called from the
    main event loop when hotbar_edit_mode is on AND a field is focused.
    Supports backspace, delete, left/right arrows, home/end, and printable
    characters via event.unicode.

    Returns True if the event was consumed (so other handlers skip it)."""
    global hotbar_text_cursor, hotbar_text_blink_t0, hotbar_focused_field
    if hotbar_edit_draft is None or hotbar_focused_field is None:
        return False
    text = _hotbar_editor_get_focused_text()
    cursor = max(0, min(hotbar_text_cursor, len(text)))

    if event.key == pygame.K_BACKSPACE:
        if cursor > 0:
            text = text[:cursor - 1] + text[cursor:]
            cursor -= 1
    elif event.key == pygame.K_DELETE:
        if cursor < len(text):
            text = text[:cursor] + text[cursor + 1:]
    elif event.key == pygame.K_LEFT:
        cursor = max(0, cursor - 1)
    elif event.key == pygame.K_RIGHT:
        cursor = min(len(text), cursor + 1)
    elif event.key == pygame.K_HOME:
        cursor = 0
    elif event.key == pygame.K_END:
        cursor = len(text)
    elif event.key in (pygame.K_RETURN, pygame.K_KP_ENTER, pygame.K_TAB):
        # Move focus: label → command → label.
        hotbar_focused_field = (
            "command" if hotbar_focused_field == "label" else "label")
        new_text = _hotbar_editor_get_focused_text()
        cursor = len(new_text)
        text = new_text
    elif event.key == pygame.K_ESCAPE:
        # Defocus.
        hotbar_focused_field = None
    else:
        # Printable character. event.unicode is already the right
        # character including shift / dead keys / etc.
        ch = event.unicode
        if ch and ch.isprintable():
            text = text[:cursor] + ch + text[cursor:]
            cursor += len(ch)
        else:
            return False  # not consumed

    _hotbar_editor_set_focused_text(text)
    hotbar_text_cursor = cursor
    hotbar_text_blink_t0 = time.time()  # reset blink so cursor stays solid
    return True


def _list_ui_icons():
    """Scan the icons/ui/ folder and return a sorted list of filenames
    that pygame can load. Cached for the duration of edit mode (rebuild
    on each entry into edit mode by clearing the module-level cache)."""
    global _ui_icons_listing_cache
    try:
        _ui_icons_listing_cache
    except NameError:
        _ui_icons_listing_cache = None
    if _ui_icons_listing_cache is not None:
        return _ui_icons_listing_cache
    out = []
    if UI_ICONS_DIR and os.path.isdir(UI_ICONS_DIR):
        try:
            for fn in os.listdir(UI_ICONS_DIR):
                low = fn.lower()
                if low.endswith((".png", ".bmp", ".jpg", ".jpeg")):
                    out.append(fn)
        except Exception as e:
            print(f"[OmniWatch] could not list icons/ui/: {e!r}")
    out.sort(key=str.lower)
    _ui_icons_listing_cache = out
    return out


def _refresh_ui_icon_listing():
    """Force a rescan of icons/ui/. Called when entering edit mode so
    icons added since startup show up."""
    global _ui_icons_listing_cache
    _ui_icons_listing_cache = None


def _browse_for_icon_file():
    """Open a native OS file picker and return the absolute path the
    user chose, or "" if they cancelled. Uses tkinter's filedialog —
    stdlib, works in PyInstaller frozen exes. The dialog's hidden Tk
    root is destroyed before returning so it doesn't leak windows.

    Returns "" on any failure (no Tk available, dialog crash, etc.)
    rather than raising, so the editor stays alive."""
    try:
        import tkinter as tk
        from tkinter import filedialog
        root = tk.Tk()
        root.withdraw()      # don't show the empty Tk root window
        try:
            # On Windows, lift to TOPMOST briefly so the dialog appears
            # above the always-on-top OmniWatch overlay. Without this
            # the file picker can pop up BEHIND OmniWatch and look like
            # the click did nothing.
            root.attributes("-topmost", True)
        except Exception:
            pass
        path = filedialog.askopenfilename(
            parent=root,
            title="Pick an icon for this hotbar slot",
            filetypes=[
                ("Image files", "*.png *.bmp *.jpg *.jpeg *.gif"),
                ("PNG", "*.png"),
                ("BMP", "*.bmp"),
                ("All files", "*.*"),
            ],
        )
        try:
            root.destroy()
        except Exception:
            pass
        return path or ""
    except Exception as e:
        print(f"[OmniWatch] file picker failed: {e!r}")
        return ""


def _import_icon_into_ui_dir(src_path):
    """Copy `src_path` into UI_ICONS_DIR (icons/ui/) and return just
    the basename — that's what gets stored in the button entry's
    "icon" field. Keeps the JSON portable (no absolute paths) and
    means the file is bundled with the addon for future reference.

    If a file with the same name already exists in icons/ui/, we
    append a numeric suffix (foo.png → foo_1.png) so we don't
    overwrite an existing icon."""
    if not src_path or not os.path.isfile(src_path):
        print(f"[OmniWatch] icon import: source missing: {src_path!r}")
        return ""
    if not UI_ICONS_DIR:
        print("[OmniWatch] icon import: UI_ICONS_DIR not set")
        return ""
    try:
        os.makedirs(UI_ICONS_DIR, exist_ok=True)
    except Exception as e:
        print(f"[OmniWatch] icon import: cannot create {UI_ICONS_DIR}: {e!r}")
        return ""

    base = os.path.basename(src_path)
    stem, ext = os.path.splitext(base)
    target = os.path.join(UI_ICONS_DIR, base)
    n = 1
    # Don't overwrite an existing icon — append _1, _2, ... until we
    # find a free slot. Ten attempts is plenty; bail with a warning
    # rather than infinite-loop if something pathological happens.
    while os.path.exists(target) and n < 100:
        target = os.path.join(UI_ICONS_DIR, f"{stem}_{n}{ext}")
        n += 1
    if os.path.exists(target):
        print(f"[OmniWatch] icon import: too many name collisions for "
              f"{base}; aborting")
        return ""
    try:
        import shutil
        shutil.copy2(src_path, target)
        print(f"[OmniWatch] imported icon: {src_path} → {target}")
        return os.path.basename(target)
    except Exception as e:
        print(f"[OmniWatch] icon import failed: {e!r}")
        return ""


def draw_hotbar_editor(surface, hotbar_x, hotbar_y, hotbar_w, hotbar_h):
    """Render the inline editor form below the hotbar. Populates
    hotbar_editor_rects with click targets. Returns the total
    height consumed by the editor (form panel + optional icon picker)."""
    global hotbar_editor_rects
    hotbar_editor_rects = []
    if not hotbar_edit_mode:
        return 0

    pad   = 8
    fy    = hotbar_y + hotbar_h + 4
    form_w = hotbar_w
    form_h = HOTBAR_EDIT_FORM_H
    form_rect = pygame.Rect(hotbar_x, fy, form_w, form_h)

    # Background panel matching the dropdown style.
    pygame.draw.rect(surface, (28, 28, 36), form_rect, border_radius=4)
    pygame.draw.rect(surface, (140, 140, 160), form_rect, 1, border_radius=4)

    title_font = pygame.font.SysFont("Consolas", 13, bold=True)
    label_font = font_label
    field_font = pygame.font.SysFont("Consolas", 12)
    btn_font   = pygame.font.SysFont("Consolas", 11, bold=True)

    # Determine title + whether a draft is active. hotbar_edit_slot is
    # -1 (nothing selected), an int 0..19 (a button slot), or the
    # special string "__page_name__" (editing the current page name).
    is_page_name_mode = (hotbar_edit_slot == "__page_name__")
    is_slot_mode = (isinstance(hotbar_edit_slot, int)
                    and hotbar_edit_slot >= 0)
    has_draft = (is_page_name_mode or is_slot_mode) and (hotbar_edit_draft is not None)

    # Title strip + Done button on the right.
    if is_page_name_mode:
        title_text = f"Editing page {hotbar_current_page + 1} name"
    elif is_slot_mode:
        title_text = f"Editing slot {hotbar_edit_slot + 1}"
    else:
        title_text = "Hotbar editor — click a slot above to edit"
    t_surf = title_font.render(title_text, True, (220, 200, 150))
    surface.blit(t_surf, (form_rect.x + pad, form_rect.y + pad))

    done_w, done_h = 90, 18
    done_rect = pygame.Rect(form_rect.right - done_w - pad,
                            form_rect.y + pad,
                            done_w, done_h)
    pygame.draw.rect(surface, (180, 160, 110), done_rect, border_radius=8)
    done_surf = btn_font.render("DONE EDITING", True, (40, 40, 50))
    surface.blit(done_surf,
                 (done_rect.x + (done_w - done_surf.get_width()) // 2,
                  done_rect.y + (done_h - done_surf.get_height()) // 2))
    hotbar_editor_rects.append((done_rect, {"kind": "done"}))

    if not has_draft:
        # No slot picked yet — just show the title bar and Done button.
        return form_h + 4

    # ── Form fields ─────────────────────────────────────────────────────
    # Layout: 4 rows of (label : control) pairs. Label column on left,
    # control on right. Label/command get text-input widgets; kind gets
    # an enum-style cycler; icon gets a button + small preview.
    cy = form_rect.y + pad + 24
    label_col_w = 70
    control_x   = form_rect.x + pad + label_col_w
    control_w   = form_rect.right - pad - control_x

    def _draw_field_label(text, y):
        s = label_font.render(text, True, (180, 180, 200))
        surface.blit(s, (form_rect.x + pad, y + (HOTBAR_EDIT_FIELD_H - s.get_height()) // 2))

    def _draw_text_input(field_name, y):
        """Render a text input box for hotbar_edit_draft[field_name]."""
        rect = pygame.Rect(control_x, y, control_w, HOTBAR_EDIT_FIELD_H)
        is_focused = hotbar_focused_field == field_name
        bg = (44, 44, 56) if is_focused else (36, 36, 46)
        bdr = (200, 180, 130) if is_focused else (90, 90, 110)
        pygame.draw.rect(surface, bg, rect, border_radius=2)
        pygame.draw.rect(surface, bdr, rect, 1, border_radius=2)
        text = hotbar_edit_draft.get(field_name, "") or ""
        ts = field_font.render(text, True, (230, 230, 240))
        # Clip text to box.
        text_y = rect.y + (rect.h - ts.get_height()) // 2
        surface.blit(ts, (rect.x + 4, text_y),
                     pygame.Rect(0, 0, rect.w - 8, rect.h))

        # Cursor: blink at 2 Hz, drawn after the n-th character where
        # n = hotbar_text_cursor. Only when this field is focused.
        if is_focused:
            blink_phase = ((time.time() - hotbar_text_blink_t0) % 1.0) < 0.5
            if blink_phase:
                cursor_idx = max(0, min(hotbar_text_cursor, len(text)))
                prefix = text[:cursor_idx]
                px = rect.x + 4 + field_font.size(prefix)[0]
                pygame.draw.line(surface, (220, 220, 240),
                                 (px, rect.y + 3),
                                 (px, rect.y + rect.h - 3), 1)
        hotbar_editor_rects.append(
            (rect, {"kind": "focus", "field": field_name}))

    # Row 1: Label (or Page Name when in name-edit mode).
    _draw_field_label("Page Name" if is_page_name_mode else "Label", cy)
    _draw_text_input("label", cy)
    cy += HOTBAR_EDIT_FIELD_H + 6

    # Rows 2-4 only apply to button-slot edits. Skip them entirely when
    # editing a page name — the only field there is the name itself.
    if not is_page_name_mode:
        # Row 2: Kind (enum cycler [<] kind [>])
        _draw_field_label("Kind", cy)
        kind_val = hotbar_edit_draft.get("kind", "none")
        kind_text = kind_val
        kind_surf = field_font.render(kind_text, True, (220, 220, 230))
        btn_w = 18
        next_rect = pygame.Rect(control_x + control_w - btn_w,
                                cy + (HOTBAR_EDIT_FIELD_H - 16) // 2,
                                btn_w, 16)
        val_x = next_rect.x - 6 - kind_surf.get_width()
        prev_rect = pygame.Rect(val_x - 6 - btn_w,
                                cy + (HOTBAR_EDIT_FIELD_H - 16) // 2,
                                btn_w, 16)
        pygame.draw.rect(surface, (60, 60, 75), prev_rect, border_radius=2)
        pygame.draw.rect(surface, (60, 60, 75), next_rect, border_radius=2)
        ls = field_font.render("<", True, (220, 220, 230))
        rs = field_font.render(">", True, (220, 220, 230))
        surface.blit(ls, (prev_rect.x + (prev_rect.w - ls.get_width()) // 2,
                          prev_rect.y + (prev_rect.h - ls.get_height()) // 2))
        surface.blit(rs, (next_rect.x + (next_rect.w - rs.get_width()) // 2,
                          next_rect.y + (next_rect.h - rs.get_height()) // 2))
        surface.blit(kind_surf, (val_x,
                                 cy + (HOTBAR_EDIT_FIELD_H - kind_surf.get_height()) // 2))
        hotbar_editor_rects.append((prev_rect, {"kind": "kind_step", "delta": -1}))
        hotbar_editor_rects.append((next_rect, {"kind": "kind_step", "delta": 1}))
        cy += HOTBAR_EDIT_FIELD_H + 6

        # Row 3: Command
        _draw_field_label("Command", cy)
        _draw_text_input("command", cy)
        cy += HOTBAR_EDIT_FIELD_H + 6

        # Row 4: Icon — small thumb preview + "Pick…" button + clear.
        _draw_field_label("Icon", cy)
        icon_filename = hotbar_edit_draft.get("icon", "") or ""
        thumb_size = HOTBAR_EDIT_FIELD_H - 4
        thumb_rect = pygame.Rect(control_x, cy + 2, thumb_size, thumb_size)
        pygame.draw.rect(surface, (36, 36, 46), thumb_rect, border_radius=2)
        pygame.draw.rect(surface, (90, 90, 110), thumb_rect, 1, border_radius=2)
        if icon_filename:
            thumb = get_ui_icon_scaled(icon_filename, thumb_size - 4)
            if thumb is not None:
                surface.blit(thumb, (thumb_rect.x + 2, thumb_rect.y + 2))

        # Filename text after the thumb.
        fn_text = icon_filename if icon_filename else "(none)"
        fn_surf = field_font.render(fn_text, True, (180, 180, 200))
        surface.blit(fn_surf, (thumb_rect.right + 6,
                               cy + (HOTBAR_EDIT_FIELD_H - fn_surf.get_height()) // 2))

        # Pick / Clear buttons on the right.
        pick_w = 48
        pick_rect = pygame.Rect(control_x + control_w - pick_w * 2 - 4,
                                cy + (HOTBAR_EDIT_FIELD_H - 16) // 2,
                                pick_w, 16)
        clear_rect = pygame.Rect(control_x + control_w - pick_w,
                                 cy + (HOTBAR_EDIT_FIELD_H - 16) // 2,
                                 pick_w, 16)
        pygame.draw.rect(surface, (180, 160, 110), pick_rect, border_radius=8)
        pygame.draw.rect(surface, (160, 100, 100), clear_rect, border_radius=8)
        ps = btn_font.render("PICK", True, (40, 40, 50))
        cs = btn_font.render("CLEAR", True, (40, 40, 50))
        surface.blit(ps, (pick_rect.x + (pick_w - ps.get_width()) // 2,
                          pick_rect.y + (pick_rect.h - ps.get_height()) // 2))
        surface.blit(cs, (clear_rect.x + (pick_w - cs.get_width()) // 2,
                          clear_rect.y + (clear_rect.h - cs.get_height()) // 2))
        hotbar_editor_rects.append((pick_rect, {"kind": "pick_icon"}))
        hotbar_editor_rects.append((clear_rect, {"kind": "clear_icon"}))
        cy += HOTBAR_EDIT_FIELD_H + 8

    # Save button (commits draft → buttons_config[slot] + writes file).
    save_w, save_h = 80, 22
    save_rect = pygame.Rect(form_rect.x + pad,
                            form_rect.bottom - save_h - pad,
                            save_w, save_h)
    pygame.draw.rect(surface, (140, 200, 140), save_rect, border_radius=8)
    ss = btn_font.render("SAVE", True, (30, 50, 30))
    surface.blit(ss, (save_rect.x + (save_w - ss.get_width()) // 2,
                      save_rect.y + (save_h - ss.get_height()) // 2))
    hotbar_editor_rects.append((save_rect, {"kind": "save"}))

    # Cancel button (discards draft, leaves slot selection alone).
    cancel_rect = pygame.Rect(save_rect.right + 6,
                              save_rect.y, save_w, save_h)
    pygame.draw.rect(surface, (160, 100, 100), cancel_rect, border_radius=8)
    cs = btn_font.render("CANCEL", True, (40, 30, 30))
    surface.blit(cs, (cancel_rect.x + (save_w - cs.get_width()) // 2,
                      cancel_rect.y + (save_h - cs.get_height()) // 2))
    hotbar_editor_rects.append((cancel_rect, {"kind": "cancel"}))

    # Copy / Paste buttons. Copy snapshots the current draft into the
    # module-level _hotbar_clipboard. Paste replaces the draft with the
    # clipboard contents (you still have to SAVE to commit). Paste is
    # dimmed when the clipboard is empty. Skipped in page-name mode
    # since there's nothing meaningful to copy from a name-only draft.
    if not is_page_name_mode:
        cp_w = 64
        copy_rect = pygame.Rect(cancel_rect.right + 12,
                                save_rect.y, cp_w, save_h)
        paste_rect = pygame.Rect(copy_rect.right + 6,
                                 save_rect.y, cp_w, save_h)
        # Copy: always enabled (any draft can be copied).
        pygame.draw.rect(surface, (110, 130, 170), copy_rect, border_radius=8)
        cps = btn_font.render("COPY", True, (30, 30, 50))
        surface.blit(cps, (copy_rect.x + (cp_w - cps.get_width()) // 2,
                           copy_rect.y + (save_h - cps.get_height()) // 2))
        hotbar_editor_rects.append((copy_rect, {"kind": "copy_slot"}))
        # Paste: enabled only when clipboard has content.
        has_clip = (_hotbar_clipboard is not None)
        paste_bg = (110, 170, 130) if has_clip else (60, 70, 65)
        paste_fg = (30, 50, 35)    if has_clip else (110, 120, 115)
        pygame.draw.rect(surface, paste_bg, paste_rect, border_radius=8)
        pst = btn_font.render("PASTE", True, paste_fg)
        surface.blit(pst, (paste_rect.x + (cp_w - pst.get_width()) // 2,
                           paste_rect.y + (save_h - pst.get_height()) // 2))
        # Always register the rect — the click handler just no-ops when
        # clipboard is empty. Cleaner than a conditional rect that
        # disappears, which would cause hover layout to jitter.
        hotbar_editor_rects.append((paste_rect, {"kind": "paste_slot"}))

    total_h = form_h + 4

    # ── Icon picker ────────────────────────────────────────────────────
    # Renders below the form when open. Grid of icon thumbnails; click
    # one to set the draft's icon and close the picker.
    if hotbar_icon_picker_open:
        py = form_rect.bottom + 4
        picker_w = form_w
        picker_h = 220
        picker_rect = pygame.Rect(form_rect.x, py, picker_w, picker_h)
        pygame.draw.rect(surface, (28, 28, 36), picker_rect, border_radius=4)
        pygame.draw.rect(surface, (140, 140, 160), picker_rect, 1, border_radius=4)

        # Header strip with Browse button on the right.
        hdr_surf = title_font.render(
            "Choose an icon (click thumb, or Browse… for any file)",
            True, (220, 200, 150))
        surface.blit(hdr_surf, (picker_rect.x + pad, picker_rect.y + pad))

        # Browse button: opens a native OS file picker so the user can
        # grab an icon from anywhere on disk. Selected file gets copied
        # into icons/ui/ and auto-applied to the current draft.
        browse_w, browse_h = 80, 18
        browse_rect = pygame.Rect(
            picker_rect.right - browse_w - pad - 52,  # leave room for ▲▼
            picker_rect.y + 4, browse_w, browse_h)
        pygame.draw.rect(surface, (180, 160, 110), browse_rect, border_radius=8)
        bs = btn_font.render("BROWSE…", True, (40, 40, 50))
        surface.blit(bs, (browse_rect.x + (browse_w - bs.get_width()) // 2,
                          browse_rect.y + (browse_h - bs.get_height()) // 2))
        hotbar_editor_rects.append((browse_rect, {"kind": "browse_icon"}))

        # Grid layout: thumbnails of fixed size, wrap to fit.
        thumb = 32
        cell  = thumb + 8
        margin_top = 28
        cells_per_row = max(1, (picker_w - pad * 2) // cell)
        icons_listing = _list_ui_icons()
        # Scroll: integer row offset.
        max_rows = max(1, (picker_h - margin_top - pad) // cell)
        total_rows = (len(icons_listing) + cells_per_row - 1) // cells_per_row
        scroll_max = max(0, total_rows - max_rows)
        scroll = max(0, min(hotbar_icon_picker_scroll, scroll_max))
        first_idx = scroll * cells_per_row
        last_idx  = min(len(icons_listing), first_idx + cells_per_row * max_rows)

        # Empty-state: show a hint that points at icons/ui/ and the
        # Browse button. This is the case user hit — fresh install,
        # no icons in icons/ui/ yet.
        if not icons_listing:
            empty_lines = [
                "No icons found in icons/ui/.",
                "Click BROWSE… to pick any image file (it'll be",
                "copied into icons/ui/ for you), or drop .png/.bmp",
                "files into that folder directly.",
            ]
            ey = picker_rect.y + margin_top + 6
            for line in empty_lines:
                ls = field_font.render(line, True, (170, 170, 190))
                surface.blit(ls, (picker_rect.x + pad + 4, ey))
                ey += ls.get_height() + 2
        else:
            # Track visible icon thumbnail rects for click handling.
            for i in range(first_idx, last_idx):
                local = i - first_idx
                r = local // cells_per_row
                c = local % cells_per_row
                tx = picker_rect.x + pad + c * cell
                ty = picker_rect.y + margin_top + r * cell
                tr = pygame.Rect(tx, ty, thumb, thumb)
                pygame.draw.rect(surface, (40, 40, 52), tr, border_radius=2)
                pygame.draw.rect(surface, (80, 80, 100), tr, 1, border_radius=2)
                fn = icons_listing[i]
                ts = get_ui_icon_scaled(fn, thumb - 4)
                if ts is not None:
                    surface.blit(ts, (tr.x + 2, tr.y + 2))
                hotbar_editor_rects.append(
                    (tr, {"kind": "select_icon", "filename": fn}))

        # Scroll buttons in the top-right of the picker.
        if total_rows > max_rows:
            up_rect = pygame.Rect(picker_rect.right - 24 - 24,
                                  picker_rect.y + 4, 22, 18)
            dn_rect = pygame.Rect(picker_rect.right - 24,
                                  picker_rect.y + 4, 22, 18)
            for r, t in ((up_rect, "▲"), (dn_rect, "▼")):
                pygame.draw.rect(surface, (60, 60, 75), r, border_radius=2)
                ts = btn_font.render(t, True, (220, 220, 230))
                if ts.get_width() < 4:
                    ts = btn_font.render("^" if t == "▲" else "v",
                                         True, (220, 220, 230))
                surface.blit(ts, (r.x + (r.w - ts.get_width()) // 2,
                                  r.y + (r.h - ts.get_height()) // 2))
            hotbar_editor_rects.append(
                (up_rect, {"kind": "picker_scroll", "delta": -1}))
            hotbar_editor_rects.append(
                (dn_rect, {"kind": "picker_scroll", "delta": 1}))

        total_h += picker_h + 4

    return total_h


def dispatch_hotbar_editor_click(mx, my):
    """Resolve a click against hotbar_editor_rects. Returns True if the
    click hit something (and was consumed), False otherwise. The
    overall click handler still falls through to slot-select behavior
    if this returns False AND we're in edit mode.
    """
    global hotbar_edit_mode, hotbar_edit_slot, hotbar_edit_draft
    global hotbar_focused_field, hotbar_text_cursor, hotbar_text_blink_t0
    global hotbar_icon_picker_open, hotbar_icon_picker_scroll
    global _hotbar_clipboard
    for rect, action in hotbar_editor_rects:
        if not rect.collidepoint(mx, my):
            continue
        kind = action["kind"]
        if kind == "done":
            # Exit edit mode entirely. Doesn't auto-save the draft —
            # user has to hit Save first if they want to persist.
            hotbar_edit_mode = False
            hotbar_edit_slot = -1
            hotbar_edit_draft = None
            hotbar_focused_field = None
            hotbar_icon_picker_open = False
            print("[OmniWatch] hotbar editor closed")
        elif kind == "focus":
            hotbar_focused_field = action["field"]
            text = (hotbar_edit_draft.get(action["field"], "")
                    if hotbar_edit_draft else "")
            hotbar_text_cursor = len(text)
            hotbar_text_blink_t0 = time.time()
        elif kind == "kind_step":
            if hotbar_edit_draft is not None:
                cur = hotbar_edit_draft.get("kind", "none")
                try:
                    idx = HOTBAR_KINDS.index(cur)
                except ValueError:
                    idx = 0
                idx = (idx + action["delta"]) % len(HOTBAR_KINDS)
                hotbar_edit_draft["kind"] = HOTBAR_KINDS[idx]
        elif kind == "pick_icon":
            _refresh_ui_icon_listing()
            hotbar_icon_picker_open = True
            hotbar_icon_picker_scroll = 0
        elif kind == "clear_icon":
            if hotbar_edit_draft is not None:
                hotbar_edit_draft["icon"] = ""
        elif kind == "select_icon":
            if hotbar_edit_draft is not None:
                hotbar_edit_draft["icon"] = action["filename"]
            hotbar_icon_picker_open = False
        elif kind == "browse_icon":
            # Open a native OS file picker. The chosen file gets copied
            # into icons/ui/ (so the JSON stays portable, just stores
            # the filename) and is auto-selected for the current draft.
            picked = _browse_for_icon_file()
            if picked:
                copied_filename = _import_icon_into_ui_dir(picked)
                if copied_filename and hotbar_edit_draft is not None:
                    hotbar_edit_draft["icon"] = copied_filename
                    hotbar_icon_picker_open = False
                    _refresh_ui_icon_listing()
        elif kind == "picker_scroll":
            hotbar_icon_picker_scroll = max(
                0, hotbar_icon_picker_scroll + action["delta"])
        elif kind == "save":
            # Commit draft → buttons_config[slot] (or page name) and
            # write to disk. After saving, deselect the slot so the
            # user gets clear visual feedback. They can click another
            # slot to keep editing.
            if hotbar_edit_draft is not None:
                if hotbar_edit_slot == "__page_name__":
                    # Page name save: trim, fall back to "Page N" on empty.
                    new_name = (hotbar_edit_draft.get("label", "") or "").strip()
                    if not new_name:
                        new_name = f"Page {hotbar_current_page + 1}"
                    if hotbar_pages:
                        hotbar_pages[hotbar_current_page]["name"] = new_name
                    save_buttons_config()
                    print(f"[OmniWatch] saved page name: {new_name!r}")
                elif (isinstance(hotbar_edit_slot, int)
                        and 0 <= hotbar_edit_slot < len(buttons_config)):
                    buttons_config[hotbar_edit_slot] = _normalize_button_entry(
                        hotbar_edit_draft)
                    save_buttons_config()
                    print(f"[OmniWatch] saved slot "
                          f"{hotbar_edit_slot + 1}: "
                          f"{buttons_config[hotbar_edit_slot]}")
            hotbar_edit_slot = -1
            hotbar_edit_draft = None
            hotbar_focused_field = None
            hotbar_icon_picker_open = False
        elif kind == "cancel":
            # Discard the in-progress draft AND deselect this slot, so
            # the form returns to "click a slot to edit" state. Keeps
            # the user in edit mode (use Done Editing to leave entirely).
            hotbar_edit_slot = -1
            hotbar_edit_draft = None
            hotbar_focused_field = None
            hotbar_icon_picker_open = False
            print("[OmniWatch] hotbar slot edit cancelled")
        elif kind == "copy_slot":
            # Snapshot the current draft into the module clipboard.
            # Normalized so weird in-progress values (unknown kind, etc.)
            # don't get pasted back as-is. Page-name drafts can't be
            # copied (the COPY button isn't rendered in that mode), but
            # we guard here too in case the rect leaks through.
            if (hotbar_edit_draft is not None
                    and hotbar_edit_slot != "__page_name__"):
                _hotbar_clipboard = _normalize_button_entry(hotbar_edit_draft)
                print(f"[OmniWatch] hotbar copy: "
                      f"{_hotbar_clipboard.get('label') or '(no label)'!r}")
        elif kind == "paste_slot":
            # Replace the draft with the clipboard contents. SAVE still
            # has to be clicked to commit. No-op when the clipboard is
            # empty or when in page-name mode.
            if (_hotbar_clipboard is not None
                    and hotbar_edit_draft is not None
                    and hotbar_edit_slot != "__page_name__"):
                hotbar_edit_draft = dict(_hotbar_clipboard)
                hotbar_focused_field = None
                hotbar_icon_picker_open = False
                print(f"[OmniWatch] hotbar paste -> draft: "
                      f"{_hotbar_clipboard.get('label') or '(no label)'!r}")
        return True
    return False


def hotbar_select_slot(slot_idx):
    """Switch the editor's focus to a different slot, copying the
    current saved state into the draft. Called from the hotbar
    panel's click handler when in edit mode.

    `slot_idx` is normally an integer 0..19 (button slot). The special
    value "__page_name__" puts the editor into page-name editing mode:
    a single editable field that mirrors hotbar_pages[current]["name"].
    """
    global hotbar_edit_slot, hotbar_edit_draft, hotbar_focused_field
    global hotbar_icon_picker_open
    if slot_idx == "__page_name__":
        hotbar_edit_slot = "__page_name__"
        cur_page = hotbar_pages[hotbar_current_page] if hotbar_pages else None
        cur_name = (cur_page and cur_page.get("name")) or ""
        # Reuse the same draft shape; only "label" gets used for the name.
        hotbar_edit_draft = {
            "label": cur_name, "icon": "", "kind": "none", "command": "",
        }
        hotbar_focused_field = "label"   # auto-focus so user can type
        hotbar_icon_picker_open = False
        print(f"[OmniWatch] hotbar editor: editing page name "
              f"(page {hotbar_current_page + 1})")
        return
    if 0 <= slot_idx < len(buttons_config):
        hotbar_edit_slot = slot_idx
        hotbar_edit_draft = dict(buttons_config[slot_idx])
        hotbar_focused_field = None
        hotbar_icon_picker_open = False
        print(f"[OmniWatch] hotbar editor: now editing slot "
              f"{slot_idx + 1}")


# ── Target card ─────────────────────────────────────────────────────────────
# Base dimensions at scale 1.0. Height grows with ability list, capped so the
# card never dominates the screen. Widths calibrated for readable text.
TC_WIDTH      = 220   # mob-info column width (tall-not-wide shape)
TC_TITLE_H    = 16    # "TARGET  12.4y" title strip above the name header
TC_HEADER_H   = 34    # name + hex id strip at the top
TC_ICON_H     = 48    # family-icon strip
TC_HP_H       = 16    # HP bar
TC_SECTION_H  = 15    # one-line text sections (strengths, weaknesses)
TC_ABILITY_H  = 13    # per-ability-line
TC_PAD        = 5
TC_MAX_ABIL   = 8     # cap on visible ability lines (before "+N more")
TC_FADE_SEC   = 3.0   # seconds to fully fade after target lost

COL_TC_BG       = (22, 22, 30)
COL_TC_BORDER   = (65, 65, 85)
COL_TC_HEADER   = (32, 32, 45)
COL_TC_NAME     = (230, 230, 245)
COL_TC_HEX      = (130, 130, 160)
COL_TC_STRONG   = (120, 220, 120)
COL_TC_WEAK     = (230, 110, 110)
COL_TC_LABEL    = (140, 140, 170)
COL_TC_ABILITY  = (200, 200, 215)

# Family → icon draw function. Each takes (surface, cx, cy, radius, color).
def _icon_dragon(surf, cx, cy, r, color):
    # Diamond head with an "eye" dot.
    pts = [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
    pygame.draw.polygon(surf, color, pts, 2)
    pygame.draw.circle(surf, color, (int(cx + r * 0.3), int(cy)), max(1, r // 6))

def _icon_beastman(surf, cx, cy, r, color):
    # Stylized helmet: circle with two horn triangles.
    pygame.draw.circle(surf, color, (cx, cy), r, 2)
    pygame.draw.polygon(surf, color, [(cx - r, cy - r // 2),
                                      (cx - r - r // 3, cy - r - r // 3),
                                      (cx - r // 2, cy - r)], 2)
    pygame.draw.polygon(surf, color, [(cx + r, cy - r // 2),
                                      (cx + r + r // 3, cy - r - r // 3),
                                      (cx + r // 2, cy - r)], 2)

def _icon_undead(surf, cx, cy, r, color):
    # Skull: circle with two eye dots and a mouth line.
    pygame.draw.circle(surf, color, (cx, cy - r // 4), r, 2)
    eye = max(2, r // 4)
    pygame.draw.circle(surf, color, (cx - r // 2, cy - r // 4), eye)
    pygame.draw.circle(surf, color, (cx + r // 2, cy - r // 4), eye)
    pygame.draw.line(surf, color, (cx - r // 2, cy + r // 2),
                                  (cx + r // 2, cy + r // 2), 2)

def _icon_arcana(surf, cx, cy, r, color):
    # Six-pointed star.
    import math as _m
    pts = []
    for i in range(12):
        ang = _m.pi / 6 * i - _m.pi / 2
        rr  = r if i % 2 == 0 else r // 2
        pts.append((cx + int(rr * _m.cos(ang)), cy + int(rr * _m.sin(ang))))
    pygame.draw.polygon(surf, color, pts, 2)

def _icon_demon(surf, cx, cy, r, color):
    # Triangle pointing down with inner V (horns).
    pygame.draw.polygon(surf, color, [(cx - r, cy - r),
                                      (cx + r, cy - r),
                                      (cx, cy + r)], 2)
    pygame.draw.line(surf, color, (cx - r // 2, cy - r),
                                  (cx,          cy - r // 4), 2)
    pygame.draw.line(surf, color, (cx + r // 2, cy - r),
                                  (cx,          cy - r // 4), 2)

def _icon_aquan(surf, cx, cy, r, color):
    # Wavy horizontal lines.
    for i, dy in enumerate((-r // 2, 0, r // 2)):
        import math as _m
        pts = []
        for j in range(9):
            px = cx - r + j * (r // 4)
            py = cy + dy + int(_m.sin(j * 1.2 + i) * (r // 6))
            pts.append((px, py))
        if len(pts) >= 2:
            pygame.draw.lines(surf, color, False, pts, 2)

def _icon_bird(surf, cx, cy, r, color):
    # Chevron (wings).
    pygame.draw.lines(surf, color, False,
                      [(cx - r, cy + r // 2),
                       (cx - r // 2, cy - r // 2),
                       (cx, cy),
                       (cx + r // 2, cy - r // 2),
                       (cx + r, cy + r // 2)], 2)

def _icon_plantoid(surf, cx, cy, r, color):
    # Leaf shape (two arcs).
    rect = pygame.Rect(cx - r, cy - r, 2 * r, 2 * r)
    import math as _m
    pygame.draw.arc(surf, color, rect, _m.pi * 0.25, _m.pi * 1.25, 2)
    pygame.draw.line(surf, color, (cx - r // 2, cy + r // 2),
                                  (cx + r // 2, cy - r // 2), 2)

def _icon_vermin(surf, cx, cy, r, color):
    # Oval body with legs.
    pygame.draw.ellipse(surf, color, (cx - r, cy - r // 2, 2 * r, r), 2)
    for dx in (-r, -r // 2, 0, r // 2, r):
        pygame.draw.line(surf, color, (cx + dx // 2, cy), (cx + dx, cy + r // 2), 1)

def _icon_lizard(surf, cx, cy, r, color):
    # Zig-zag (reptilian silhouette).
    pygame.draw.lines(surf, color, False,
                      [(cx - r, cy), (cx - r // 2, cy + r // 3),
                       (cx, cy - r // 3), (cx + r // 2, cy + r // 3),
                       (cx + r, cy)], 2)

def _icon_beast(surf, cx, cy, r, color):
    # Paw: large circle with four smaller pads.
    pygame.draw.circle(surf, color, (cx, cy + r // 4), r * 2 // 3, 2)
    for dx, dy in ((-r // 2, -r // 2), (r // 2, -r // 2),
                   (-r, 0), (r, 0)):
        pygame.draw.circle(surf, color, (cx + dx, cy + dy), max(2, r // 4), 2)

def _icon_luminian(surf, cx, cy, r, color):
    # Radiant: circle with outward rays.
    pygame.draw.circle(surf, color, (cx, cy), r // 2, 2)
    import math as _m
    for i in range(8):
        ang = _m.pi / 4 * i
        pygame.draw.line(surf, color,
                         (cx + int(r * 0.55 * _m.cos(ang)),
                          cy + int(r * 0.55 * _m.sin(ang))),
                         (cx + int(r * _m.cos(ang)),
                          cy + int(r * _m.sin(ang))), 2)

def _icon_default(surf, cx, cy, r, color):
    # Generic diamond outline.
    pygame.draw.polygon(surf, color,
                        [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)], 2)

FAMILY_ICONS = {
    "dragon":   _icon_dragon,
    "beastman": _icon_beastman,
    "undead":   _icon_undead,
    "arcana":   _icon_arcana,
    "demon":    _icon_demon,
    "aquan":    _icon_aquan,
    "bird":     _icon_bird,
    "plantoid": _icon_plantoid,
    "vermin":   _icon_vermin,
    "bug":      _icon_vermin,
    "lizard":   _icon_lizard,
    "beast":    _icon_beast,
    "luminian": _icon_luminian,
    "luminion": _icon_luminian,
    "amorph":   _icon_default,
}

# ── Bitmap mob-family icons (loaded from data/mob_icons/) ────────────────────
# Keys are lowercase family names (derived from filenames). Values are the
# raw pygame.Surface at native size; scaled versions are cached per-size.
#
# Two source directories are scanned and merged into the same dict:
#   1) MOB_ICONS_DIR  (OmniWatch/icons/mob/) — canonical mob family icons
#                                              (Goblin.png, Worm.png, etc.)
#   2) MOBDATA_DIR/mobicons/                 — also holds per-mob BG-wiki
#                                              images (cached on demand) AND
#                                              PC race icons. We pick up the
#                                              race icons here since users
#                                              prefer keeping all PC-/per-mob
#                                              imagery in one folder rather
#                                              than the icons/mob/ tree.
# Shared dict means a single get_mob_icon_scaled lookup works for both kinds
# of key (family for mobs, race-key for PCs).
_mob_icons_raw    = {}    # key (lower) → Surface
_mob_icons_scaled = {}    # (key, size) → Surface

# Set of race-key filename stems we expect for PC icons. Used to filter
# the mobdata/mobicons/ scan: that directory ALSO contains thousands of
# per-mob BG-wiki images (cached lazily by name), and we don't want to
# preload all of them at startup. Only race-key matches get pulled in.
_PC_RACE_KEYS = {
    "humemale", "humefemale",
    "elvaanmale", "elvaanfemale",
    "tarutarumale", "tarutarufemale",
    "mithra", "galka",
}

def load_mob_icons():
    """Scan MOB_ICONS_DIR + MOBDATA_DIR/mobicons/ for icon images.
    Filename (without ext) → key. The mobdata/mobicons/ scan is filtered
    to only PC race-key stems so we don't preload thousands of per-mob
    images that get fetched on demand elsewhere."""
    global _mob_icons_raw
    _mob_icons_raw = {}

    def _load_one(dir_path, *, restrict_to_race_keys=False):
        if not dir_path or not os.path.isdir(dir_path):
            return 0
        try:
            files = os.listdir(dir_path)
        except Exception as e:
            print(f"[OmniWatch] Could not list {dir_path}: {e}")
            return 0
        loaded = 0
        for fn in files:
            lower = fn.lower()
            if not (lower.endswith(".png") or lower.endswith(".bmp") or
                    lower.endswith(".jpg") or lower.endswith(".jpeg")):
                continue
            stem = os.path.splitext(fn)[0].lower()
            if restrict_to_race_keys and stem not in _PC_RACE_KEYS:
                continue
            try:
                surf = pygame.image.load(
                    os.path.join(dir_path, fn)).convert_alpha()
            except Exception as e:
                print(f"[OmniWatch] Could not load mob icon {fn}: {e}")
                continue
            _mob_icons_raw[stem] = surf
            loaded += 1
        return loaded

    fam_count  = _load_one(MOB_ICONS_DIR, restrict_to_race_keys=False)
    pc_dir     = os.path.join(MOBDATA_DIR, "mobicons") if MOBDATA_DIR else None
    pc_count   = _load_one(pc_dir, restrict_to_race_keys=True)
    print(f"[OmniWatch] Loaded {fam_count} mob family icons "
          f"+ {pc_count} PC race icons.")

load_mob_icons()

def get_mob_icon_scaled(key, size):
    """Return a scaled surface for the given family key, or None if no such icon."""
    if not key:
        return None
    key = key.lower()
    if key not in _mob_icons_raw:
        return None
    cache_key = (key, size)
    if cache_key in _mob_icons_scaled:
        return _mob_icons_scaled[cache_key]
    try:
        scaled = pygame.transform.smoothscale(_mob_icons_raw[key], (size, size))
    except Exception:
        scaled = pygame.transform.scale(_mob_icons_raw[key], (size, size))
    _mob_icons_scaled[cache_key] = scaled
    return scaled

# ── On-demand per-mob images from BG-wiki ────────────────────────────────
# Distinct from the family icons above. Family icons are bundled at
# install time and used as a fallback when a specific mob image isn't
# available. Per-mob images come from the merged mobdb:
#   image / image_url fields in mob_individuals.json.
#
# `image` is a filename STEM (e.g. "goblinleecher") — no extension. We
# resolve it to whichever extension exists on disk in mobicons/. This
# lets the user drop in either .png, .jpg, .jpeg, or .bmp without
# editing the JSON.
#
# Cache directory: <MOBDATA_DIR>/mobicons/. Created on first use.
# When the file isn't on disk and `image_url` is non-empty, we fire a
# background HTTP fetch to populate it. Family icon shows during the
# fetch — never blocks the render thread.

import threading
import urllib.request

_mob_image_dir = None
if MOBDATA_DIR:
    _mob_image_dir = os.path.join(MOBDATA_DIR, "mobicons")
    try:
        os.makedirs(_mob_image_dir, exist_ok=True)
    except OSError as e:
        print(f"[OmniWatch] Could not create mobicons dir: {e}")
        _mob_image_dir = None

_mob_image_raw     = {}     # stem (str) → pygame.Surface | None (None = failed)
_mob_image_scaled  = {}     # (stem, size) → Surface
_mob_image_pending = set()  # stems currently downloading; prevents dup fetches
_mob_image_lock    = threading.Lock()

# Diagnostic: tracks which mob names we've already printed a
# lookup-debug line for, so the session log gets exactly one entry per
# mob name. Cleared on process restart.
_mob_image_logged  = set()
_mob_spells_logged = set()

# Extensions checked in order. First match wins.
_MOB_IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".bmp", ".webp")


def _mob_image_resolve_path(stem):
    """Find <stem>.{png|jpg|...} on disk. Returns full path or None."""
    if not stem or not _mob_image_dir:
        return None
    for ext in _MOB_IMAGE_EXTS:
        path = os.path.join(_mob_image_dir, stem + ext)
        if os.path.isfile(path):
            return path
    return None


def _mob_image_load_local(stem):
    """Try to load the image from disk. Returns Surface or None."""
    path = _mob_image_resolve_path(stem)
    if not path:
        return None
    try:
        return pygame.image.load(path).convert_alpha()
    except Exception as e:
        # File may be corrupt (partial download from previous crash etc).
        # Remove it so the next fetch tries again.
        print(f"[OmniWatch] Bad mob image {os.path.basename(path)}: {e} — removing.")
        try: os.remove(path)
        except OSError: pass
        return None


def _mob_image_download(stem, url):
    """Background-thread function. Downloads `url` and saves as
    <stem>.<ext> under mobicons/, where <ext> is inferred from the
    URL's path. Then loads the surface for the main render thread to
    pick up on its next frame.

    Errors are logged but not raised — failed downloads just leave the
    family icon showing. We mark the stem as 'attempted' (None entry)
    so we don't retry every frame this session; the user can clear the
    cache to retry.
    """
    global _mob_image_raw
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "OmniWatch/1.0 (BG-wiki image fetch)",
        })
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = resp.read()
        if not data:
            raise RuntimeError("empty response")
        # Pick extension from the URL path. Default to .jpg if URL has
        # no recognizable extension — most scraped mob images are jpg.
        url_path = urllib.parse.urlparse(url).path.lower()
        ext = ".jpg"
        for candidate in _MOB_IMAGE_EXTS:
            if url_path.endswith(candidate):
                ext = candidate
                break
        path = os.path.join(_mob_image_dir, stem + ext)
        # Atomic-ish: write to .tmp then rename.
        tmp_path = path + ".tmp"
        with open(tmp_path, "wb") as f:
            f.write(data)
        os.replace(tmp_path, path)
        try:
            surf = pygame.image.load(path)
        except Exception as e:
            print(f"[OmniWatch] mob image fetched but unloadable {stem}: {e}")
            with _mob_image_lock:
                _mob_image_raw[stem] = None
            return
        with _mob_image_lock:
            _mob_image_raw[stem] = surf
    except Exception as e:
        print(f"[OmniWatch] mob image fetch failed {stem}: {e}")
        with _mob_image_lock:
            _mob_image_raw[stem] = None
    finally:
        with _mob_image_lock:
            _mob_image_pending.discard(stem)


def get_mob_image_scaled(stem, url, size):
    """Return a scaled per-mob image, or None if not available yet.

    `stem` is the filename without extension (e.g. "goblinleecher"). We
    look on disk for any of <stem>.{png|jpg|...} and use the first
    that exists.

    First call for a given stem: tries disk; if missing AND `url` is
    non-empty, kicks off a background download (returns None this
    frame). Subsequent calls return the scaled surface from cache.
    """
    if not stem or not _mob_image_dir:
        return None
    raw = _mob_image_raw.get(stem, "_NOT_TRIED_")
    if raw == "_NOT_TRIED_":
        raw = _mob_image_load_local(stem)
        if raw is not None:
            with _mob_image_lock:
                _mob_image_raw[stem] = raw
        elif url:
            with _mob_image_lock:
                if stem in _mob_image_pending:
                    return None
                _mob_image_pending.add(stem)
                _mob_image_raw[stem] = "_NOT_TRIED_"
            t = threading.Thread(
                target=_mob_image_download,
                args=(stem, url),
                daemon=True,
                name=f"mob-image-{stem}",
            )
            t.start()
            return None
        else:
            with _mob_image_lock:
                _mob_image_raw[stem] = None
            return None
    if raw is None:
        return None
    cache_key = (stem, size)
    if cache_key in _mob_image_scaled:
        return _mob_image_scaled[cache_key]
    try:
        if not raw.get_flags() & pygame.SRCALPHA:
            raw = raw.convert_alpha()
            _mob_image_raw[stem] = raw
        scaled = pygame.transform.smoothscale(raw, (size, size))
    except Exception as e:
        print(f"[OmniWatch] mob image scale failed {stem}: {e}")
        return None
    _mob_image_scaled[cache_key] = scaled
    return scaled

# ── Status icon cache (buff / debuff icons in icons/status/) ─────────────
# Mirrors _mob_icons_* but keyed by buff_id (int). The lua side extracts
# 32x32 BMPs from the buff DAT (icon_extractor.buff_by_id) into
# OmniWatch/icons/status/<id>.bmp at the moment a buff is first seen on
# any party member. We load lazily — first request for a given id reads
# the BMP off disk, caches the surface, and returns scaled copies on
# subsequent calls.
#
# Returns None if the file isn't on disk yet (lua hasn't extracted it
# this session, or the id is outside the buff DAT range). Render code
# should fall back to text label in that case.
_status_icon_dir = None
_status_icon_raw    = {}     # buff_id (int)         → Surface | None
_status_icon_scaled = {}     # (buff_id, size)       → Surface

# Resolved as a sibling of ICON_DIR (which is icons/equipment/). Don't
# search separately — same install root won the equipment lookup, and
# the lua side writes here unconditionally.
if ICON_DIR:
    _status_icon_dir = os.path.join(_icon_root, "status")
    try:
        os.makedirs(_status_icon_dir, exist_ok=True)
    except OSError as e:
        print(f"[OmniWatch] Could not create status icon dir: {e}")
        _status_icon_dir = None

def _status_icon_load_raw(buff_id):
    """Load <buff_id>.bmp from disk. Returns Surface or None."""
    if not _status_icon_dir:
        return None
    path = os.path.join(_status_icon_dir, f"{int(buff_id)}.bmp")
    if not os.path.isfile(path):
        return None
    try:
        return pygame.image.load(path).convert_alpha()
    except Exception as e:
        # Likely a partial-write from a recent extraction. Remove so the
        # next ensure_status_icon retry can write fresh bytes.
        print(f"[OmniWatch] Bad status icon {buff_id}.bmp: {e} — removing.")
        try: os.remove(path)
        except OSError: pass
        return None

def get_status_icon_scaled(buff_id, size):
    """Return a scaled status icon surface, or None if unavailable.

    Caches the raw load AND the per-size scaled result. Negative ids
    (synthetic sim-mode buffs) and ids outside the FFXI buff range
    short-circuit to None.
    """
    if buff_id is None or not _status_icon_dir:
        return None
    try:
        bid = int(buff_id)
    except (TypeError, ValueError):
        return None
    if bid <= 0 or bid > 1024:
        return None

    raw = _status_icon_raw.get(bid, "_NOT_TRIED_")
    if raw == "_NOT_TRIED_":
        raw = _status_icon_load_raw(bid)
        _status_icon_raw[bid] = raw
    if raw is None:
        return None

    cache_key = (bid, size)
    cached = _status_icon_scaled.get(cache_key)
    if cached is not None:
        return cached
    try:
        scaled = pygame.transform.smoothscale(raw, (size, size))
    except Exception:
        try:
            scaled = pygame.transform.scale(raw, (size, size))
        except Exception as e:
            print(f"[OmniWatch] status icon scale failed {bid}: {e}")
            return None
    _status_icon_scaled[cache_key] = scaled
    return scaled

# ── Mob name → family inference ──────────────────────────────────────────────
# Config file: omniwatch_mob_families.json. Patterns are substrings matched
# case-insensitively against the mob name; the FIRST match wins, so order
# matters. Pre-seeded with common FFXI name→family mappings.
FAMILIES_FILE = os.path.join(USER_DIR, "omniwatch_mob_families.json")

_FAMILIES_SEED = {
    "_README": [
        "OmniWatch mob name → family inference.",
        "",
        "Patterns are matched case-insensitively as substrings against the",
        "mob name. The FIRST match wins, so put more-specific patterns",
        "before more general ones.",
        "",
        "Family values should match (case-insensitive) the filename of an",
        "icon in data/mob_icons/ (e.g. 'pugil.png' → family 'pugil'). If no",
        "matching icon exists, the card falls back to the primitive diamond.",
        "",
        "After editing, save and restart OmniWatch."
    ],
    "patterns": [
        # Ordered most-specific-first. The FIRST match wins, so compound
        # names (e.g. "Sea Monk" must match before "Monk") come first.
        # Lowercase, with leading/trailing spaces for word-boundary effect.

        # — Ecosystem 1 —
        # Beast
        [" behemoth",      "behemoth"],
        [" buffalo",       "buffalo"],
        [" cehuetzi",      "cehuetzi"],
        [" cerberus",      "cerberus"],
        [" coeurl",        "coeurl"],
        [" dhalmel",       "dhalmel"],
        [" gnole",         "gnole"],
        [" manticore",     "manticore"],
        [" marid",         "marid"],
        [" opo-opo",       "opo-opo"],
        [" raaz",          "raaz"],
        [" rabbit",        "rabbit"],
        [" hare",          "rabbit"],
        [" rarab",         "rabbit"],
        [" ram",           "ram"],
        [" sheep",         "sheep"],
        [" tiger",         "tiger"],
        [" yztarg",        "yztarg"],
        # Lizard
        [" adamantoise",   "adamantoise"],
        [" bugard",        "bugard"],
        [" eft",           "eft"],
        [" gabbrath",      "gabbrath"],
        [" hill lizard",   "hill lizard"],
        [" matamata",      "matamata"],
        [" peiste",        "peiste"],
        [" raptor",        "raptor"],
        [" wivre",         "wivre"],
        [" lizard",        "lizard"],
        # Vermin
        [" antlion",       "antlion"],
        [" bee",           "bee"],
        [" wasp",          "bee"],
        [" hornet",        "bee"],
        [" beetle",        "beetle"],
        [" bztavian",      "bztavian"],
        [" chapuli",       "chapuli"],
        [" chigoe",        "chigoe"],
        [" crawler",       "crawler"],
        [" diremite",      "diremite"],
        [" giant gnat",    "giant gnat"],
        [" gnat",          "gnat"],
        [" ladybug",       "ladybug"],
        [" mantid",        "mantid"],
        [" mosquito",      "mosquito"],
        [" scorpion",      "scorpion"],
        [" spider",        "spider"],
        [" twitherym",     "twitherym"],
        [" wamouracampa",  "wamouracampa"],
        [" wamoura",       "wamoura"],
        [" fly",           "fly"],
        # Plantoid
        [" belladonna",    "belladonna"],
        [" flytrap",       "flytrap"],
        [" funguar",       "funguar"],
        [" goobbue",       "goobbue"],
        [" leafkin",       "leafkin"],
        [" mandragora",    "mandragora"],
        [" morbol",        "morbol"],
        [" panopt",        "panopt"],
        [" rafflesia",     "rafflesia"],
        [" sabotender",    "sabotender"],
        [" sapling",       "sapling"],
        [" snapweed",      "snapweed"],
        [" treant",        "treant"],
        [" yggdreant",     "yggdreant"],

        # — Ecosystem 2 —
        # Amorph
        [" acuex",         "acuex"],
        [" botulus",       "botulus"],
        [" flan",          "flan"],
        [" hecteyes",      "hecteyes"],
        [" evil eye",      "hecteyes"],
        [" leech",         "leech"],
        [" plovid",        "plovid"],
        [" sandworm",      "sandworm"],
        [" slime",         "slime"],
        [" slug",          "slug"],
        [" worm",          "worm"],
        # Bird
        [" amphiptere",    "amphiptere"],
        [" apkallu",       "apkallu"],
        [" bat",           "bat"],
        [" cockatrice",    "cockatrice"],
        [" colibri",       "colibri"],
        [" harpeia",       "harpeia"],
        [" hippogryph",    "hippogryph"],
        [" tulfaire",      "tulfaires"],
        [" waktza",        "waktza"],
        [" bird",          "bird"],
        # Aquan
        [" sea monk",      "sea monk"],
        [" crab",          "crab"],
        [" snipper",       "crab"],
        [" craklaw",       "craklaw"],
        [" frog",          "frog"],
        [" orobon",        "orobon"],
        [" pteraketos",    "pteraketos"],
        [" pugil",         "pugil"],
        [" rockfin",       "rockfin"],
        [" ruszor",        "ruszor"],
        [" uragnite",      "uragnite"],

        # — Ecosystem 3 —
        # Undead
        [" corpselight",   "corpselight"],
        [" corse",         "corse"],
        [" dullahan",      "dullahan"],
        [" fomor",         "fomor"],
        [" ghost",         "ghost"],
        [" hound",         "hound"],
        [" naraka",        "naraka"],
        [" qutrub",        "qutrub"],
        [" skeleton",      "skeleton"],
        [" bones",         "skeleton"],
        [" vampyr",        "vampyr"],
        [" ghoul",         "qutrub"],
        # Arcana
        [" acrolith",      "acrolith"],
        [" bomb",          "bomb"],
        [" cardian",       "cardian"],
        [" cluster",       "cluster"],
        [" djinn",         "djinn"],
        [" doll",          "doll"],
        [" evil weapon",   "evil weapon"],
        [" animated",      "evil weapon"],   # "Animated Claymore" etc.
        [" golem",         "golem"],
        [" iron giant",    "iron giant"],
        [" khimaira",      "khimaira"],
        [" magic pot",     "magic pot"],
        [" mammet",        "mammets"],
        [" marolith",      "marolith"],
        [" mimic",         "mimic"],
        [" snoll",         "snoll"],

        # — Ecosystem 4 —
        # Demon
        [" ahriman",       "ahriman"],
        [" dvergr",        "dvergr"],
        [" gallu",         "gallu"],
        [" gargouille",    "gargouille"],
        [" imp",           "imp"],
        [" soulflayer",    "soulflayer"],
        [" taurus",        "taurus"],
        [" demon",         "demon"],
        # Dragon
        [" hydra",         "hydra"],
        [" puk",           "puk"],
        [" wyvern",        "wyvern"],
        [" wyrm",          "wyrm"],
        [" zilant",        "zilant"],
        [" dragon",        "dragon"],

        # — Humanoid (Beastmen) —
        [" antica",        "antica"],
        [" bugbear",       "bugbear"],
        [" gigas",         "gigas"],
        [" mamool ja",     "mamool ja"],
        [" mamool",        "mamool ja"],
        [" goblin",        "goblin"],
        [" moblin",        "goblin"],
        [" lamia",         "lamiae"],
        [" meeble",        "meeble"],
        [" moogle",        "moogle"],
        [" orcish warmachine", "orcish warmachine"],
        [" orc",           "orc"],
        [" poroggo",       "poroggo"],
        [" qiqirn",        "qiqirn"],
        [" quadav",        "quadav"],
        [" sahagin",       "sahagin"],
        [" siege turret",  "siege turret"],
        [" tonberry",      "tonberry"],
        [" troll",         "troll"],
        [" velkk",         "velkk"],
        [" yagudo",        "yagudo"],

        # — Promyvion / Empty —
        [" craver",        "craver"],
        [" gorger",        "gorger"],
        [" receptacle",    "receptacle"],
        [" seether",       "seether"],
        [" thinker",       "thinker"],
        [" wanderer",      "wanderer"],
        [" weeper",        "weeper"],

        # — Al'Taieu —
        [" aern",          "aern"],
        [" euvhi",         "euvhi"],
        [" hpemde",        "hpemde"],
        [" phuabo",        "phuabo"],
        [" xzomit",        "xzomit"],
        [" wynav",         "wynav"],
        [" yovra",         "yovra"],
        [" ghrah",         "ghrah"],
        [" zdei",          "zdei"],

        # — Abyssean —
        [" amoeban",       "amoeban"],
        [" clionid",       "clionid"],
        [" limule",        "limule"],
        [" murex",         "murex"],

        # — Miscellaneous —
        [" chariot",       "chariot"],
        [" gear",          "gear"],
        [" rampart",       "rampart"],
        [" heartwing",     "heartwing"],
        [" monoceros",     "monoceros"],
        [" pixie",         "pixie"],
        [" porxie",        "porxie"],
        [" umbril",        "umbril"],
        [" elemental",     "elemental"],
    ]
}

# Subfamily → ecosystem family. Based on BG-Wiki's bestiary taxonomy.
# Used for showing two-level labels and for icon fallback when a subfamily
# icon isn't available (e.g. no bee.png → fall back to vermin.png).
_SUBFAMILY_TO_ECOSYSTEM = {
    # Ecosystem 1
    "behemoth": "beast", "buffalo": "beast", "cehuetzi": "beast",
    "cerberus": "beast", "coeurl": "beast", "dhalmel": "beast",
    "gnole": "beast", "manticore": "beast", "marid": "beast",
    "opo-opo": "beast", "raaz": "beast", "rabbit": "beast",
    "ram": "beast", "sheep": "beast", "tiger": "beast", "yztarg": "beast",
    "adamantoise": "lizard", "bugard": "lizard", "eft": "lizard",
    "gabbrath": "lizard", "hill lizard": "lizard", "matamata": "lizard",
    "peiste": "lizard", "raptor": "lizard", "wivre": "lizard", "lizard": "lizard",
    "antlion": "vermin", "bee": "vermin", "beetle": "vermin",
    "bztavian": "vermin", "chapuli": "vermin", "chigoe": "vermin",
    "crawler": "vermin", "diremite": "vermin", "fly": "vermin",
    "giant gnat": "vermin", "gnat": "vermin", "ladybug": "vermin",
    "mantid": "vermin", "mosquito": "vermin", "scorpion": "vermin",
    "spider": "vermin", "twitherym": "vermin",
    "wamoura": "vermin", "wamouracampa": "vermin",
    "belladonna": "plantoid", "flytrap": "plantoid", "funguar": "plantoid",
    "goobbue": "plantoid", "leafkin": "plantoid", "mandragora": "plantoid",
    "morbol": "plantoid", "panopt": "plantoid", "rafflesia": "plantoid",
    "sabotender": "plantoid", "sapling": "plantoid", "snapweed": "plantoid",
    "treant": "plantoid", "yggdreant": "plantoid",

    # Ecosystem 2
    "acuex": "amorph", "botulus": "amorph", "flan": "amorph",
    "hecteyes": "amorph", "leech": "amorph", "plovid": "amorph",
    "sandworm": "amorph", "slime": "amorph", "slug": "amorph",
    "worm": "amorph",
    "amphiptere": "bird", "apkallu": "bird", "bat": "bird",
    "cockatrice": "bird", "colibri": "bird", "harpeia": "bird",
    "hippogryph": "bird", "tulfaires": "bird", "waktza": "bird",
    "bird": "bird",
    "crab": "aquan", "craklaw": "aquan", "frog": "aquan",
    "orobon": "aquan", "pteraketos": "aquan", "pugil": "aquan",
    "rockfin": "aquan", "ruszor": "aquan", "sea monk": "aquan",
    "uragnite": "aquan",

    # Ecosystem 3
    "corpselight": "undead", "corse": "undead", "dullahan": "undead",
    "fomor": "undead", "ghost": "undead", "hound": "undead",
    "naraka": "undead", "qutrub": "undead", "skeleton": "undead",
    "vampyr": "undead",
    "acrolith": "arcana", "bomb": "arcana", "cardian": "arcana",
    "cluster": "arcana", "djinn": "arcana", "doll": "arcana",
    "evil weapon": "arcana", "golem": "arcana", "iron giant": "arcana",
    "khimaira": "arcana", "magic pot": "arcana", "mammets": "arcana",
    "marolith": "arcana", "mimic": "arcana", "snoll": "arcana",

    # Ecosystem 4
    "ahriman": "demon", "dvergr": "demon", "gallu": "demon",
    "gargouille": "demon", "imp": "demon", "soulflayer": "demon",
    "taurus": "demon", "demon": "demon",
    "hydra": "dragon", "puk": "dragon", "wyvern": "dragon",
    "wyrm": "dragon", "zilant": "dragon", "dragon": "dragon",

    # Humanoid
    "antica": "beastmen", "bugbear": "beastmen", "gigas": "beastmen",
    "goblin": "beastmen", "lamiae": "beastmen", "mamool ja": "beastmen",
    "meeble": "beastmen", "moogle": "beastmen", "orc": "beastmen",
    "orcish warmachine": "beastmen", "poroggo": "beastmen",
    "qiqirn": "beastmen", "quadav": "beastmen", "sahagin": "beastmen",
    "siege turret": "beastmen", "tonberry": "beastmen", "troll": "beastmen",
    "velkk": "beastmen", "yagudo": "beastmen",

    # Promyvion
    "craver": "empty", "gorger": "empty", "receptacle": "empty",
    "seether": "empty", "thinker": "empty", "wanderer": "empty",
    "weeper": "empty",

    # Al'Taieu
    "aern": "luminian", "euvhi": "luminian", "hpemde": "luminian",
    "phuabo": "luminian", "xzomit": "luminian", "wynav": "luminian",
    "yovra": "luminian",
    "ghrah": "luminion", "zdei": "luminion",

    # Abyssean
    "amoeban": "vorageans", "clionid": "vorageans",
    "limule": "vorageans", "murex": "vorageans",

    # Miscellaneous
    "chariot": "archaic machine", "gear": "archaic machine",
    "rampart": "archaic machine",
    "elemental": "elementals", "heartwing": "elementals",
    "monoceros": "elementals", "pixie": "elementals",
    "porxie": "elementals", "umbril": "elementals",
}

def load_families_config():
    try:
        if not os.path.exists(FAMILIES_FILE):
            with open(FAMILIES_FILE, "w") as f:
                json.dump(_FAMILIES_SEED, f, indent=2)
            print(f"[OmniWatch] Created default families config at {FAMILIES_FILE}")
            raw = _FAMILIES_SEED
        else:
            with open(FAMILIES_FILE) as f:
                raw = json.load(f)
            print(f"[OmniWatch] Loaded families config from {FAMILIES_FILE}")
    except Exception as e:
        print(f"[OmniWatch] Could not load families config: {e}. Using seed.")
        raw = _FAMILIES_SEED
    # Normalize to lowercase pairs, skipping malformed entries.
    out = []
    for item in raw.get("patterns", []):
        if isinstance(item, (list, tuple)) and len(item) == 2 \
           and isinstance(item[0], str) and isinstance(item[1], str):
            out.append((item[0].lower(), item[1].lower()))
    return out

_family_patterns = load_families_config()

# Exact-match overrides for named mobs (usually NMs) whose name doesn't
# contain the family keyword. Case-insensitive. Walked first; pattern rules
# are the fallback.
_NM_FAMILY_OVERRIDES = {
    # Bats / flock bats
    "midnight wings":  "bat",
    "eldritch edge":   "bat",
    "ni'zoo":          "bat",
    # Birds
    "stroper":         "treant",
    # Dragons / wyrms
    "fafnir":          "dragon",
    "nidhogg":         "dragon",
    "vrtra":           "dragon",
    "tiamat":          "dragon",
    "jormungand":      "dragon",
    # Beasts
    "behemoth":        "behemoth",
    "king behemoth":   "behemoth",
    "cerberus":        "cerberus",
    # Arcana
    "kirin":           "arcana",
    "byakko":          "arcana",
    "suzaku":          "arcana",
    "seiryu":          "arcana",
    "genbu":           "arcana",
    # Amorph
    "bahamut":         "dragon",
    # Common NMs worth flagging
    "charybdis":       "aquan",
    "lord of onzozo":  "manticore",
}

def infer_family(name):
    """Return the family key for a mob name, or empty string if no match.
    Priority: MobDB family field (if set) > NM name overrides > name patterns.

    For compound names like "Goblin Leecher" or "Goblin's Leech", we
    have to disambiguate which family matches. Beastman families
    (Goblin, Yagudo, Orc, Tonberry, etc.) are IDENTITY-defining: a
    "Goblin Leecher" is fundamentally a goblin with a pet leech, not a
    leech-type mob. So beastman patterns take priority over creature
    patterns when both happen to match the name. Possessive forms
    ("Goblin's Leech") still match the second word as primary because
    the apostrophe-s makes Goblin's a modifier, not the noun — we
    handle that by checking a possessive-strip rule first.
    """
    if not name:
        return ""
    low_exact = name.lower().strip()
    # 1. Exact NM override (handles named mobs like Midnight Wings that
    #    don't contain their family word).
    if low_exact in _NM_FAMILY_OVERRIDES:
        return _NM_FAMILY_OVERRIDES[low_exact]
    # 2. Pattern scan with two-pass priority. First pass: beastman
    #    family patterns. Second pass: everything else. This fixes
    #    "Goblin Leecher" → "leech" mismatch (beastman wins) while
    #    leaving "Goblin's Leech" → "leech" intact (the possessive
    #    isn't matched by the beastman patterns since they require
    #    a trailing space, not apostrophe-s).
    low = " " + low_exact + " "
    for pat, fam in _family_patterns:
        if fam in _BEASTMAN_FAMILIES and pat in low:
            return fam
    for pat, fam in _family_patterns:
        if pat in low:
            return fam
    return ""

# Family keys that represent BEASTMAN races. These take priority in
# infer_family() so compound names like "Goblin Leecher" are identified
# as goblins, not as their (often pet) creature companion.
_BEASTMAN_FAMILIES = frozenset({
    "antica", "bugbear", "gigas", "mamool ja", "goblin", "lamiae",
    "meeble", "moogle", "orc", "orcish warmachine", "poroggo",
    "qiqirn", "quadav", "sahagin", "siege turret", "tonberry",
    "troll", "velkk", "yagudo",
})

def ecosystem_for_subfamily(subfamily):
    """Return the ecosystem family name for a subfamily, or '' if unknown."""
    if not subfamily:
        return ""
    return _SUBFAMILY_TO_ECOSYSTEM.get(subfamily.lower(), "")

TC_STATUS_COL_W = 90     # width of each extra column (debuffs, buffs)

def _tc_ability_info(mob_ref, family_key, mobdb_entry=None):
    """Return (count, total_chars) for the ability row of the given mob.
    Source priority (mirrors the renderer):
       1. Per-mob `abilities` from mobdb_entry (editable JSON field)
       2. mob_abilities.json family entry's tp_moves
       3. Legacy mob_ref abilities list (NM seed DB)
    Used by both size calc and rendering paths to stay consistent."""
    names = []
    # 1. Per-mob abilities take priority (editable in mob_individuals.json).
    if mobdb_entry:
        mob_abils = mobdb_entry.get("abilities") or []
        if mob_abils:
            names = list(mob_abils)
    # 2. Family JSON (structured tp_moves).
    if not names and _mob_abilities_db and family_key:
        fam = _mob_abilities_db.get("families", {}).get(family_key)
        if fam:
            tp = fam.get("tp_moves") or []
            names = [e.get("name", "") for e in tp if e.get("name")]
    # 3. Legacy mob_ref abilities list.
    if not names and mob_ref:
        names = list(mob_ref.get("abilities") or [])
    if not names:
        return 0, 0
    total = sum(len(n) for n in names) + max(0, (len(names) - 1) * 2)
    return len(names), total

def target_card_size(scale, ability_count, has_aggro_row=True, has_detect_row=True,
                     sw_extra_lines=10, has_debuffs=False, has_buffs=False,
                     has_cast=False, ability_chars=0, kind="mob",
                     comments_chars=0):
    """Return (width, height) for the card at this scale.
    Height accounts for: header + icon + HP bar + level/family line +
    aggro row + detection row + strengths + weaknesses + abilities + misc.
    `sw_extra_lines` is a reserved amount for STR/WK text wrap (default 2:
    one extra line each). Pass a larger value if you expect longer lists.
    `has_debuffs`/`has_buffs` add side columns to the right of the card.
    `has_cast` reserves a strip at the bottom for casting/just-cast text.
    `ability_chars` is the total character length of the ability-name
    list (names + ", " separators). Used to estimate wrap lines.
    `kind` is 'mob', 'pc', or 'trust'. PCs/Trusts skip the STR/WK/Imm/
    Spells/Abilities sections, so we don't allocate vertical space for
    them in that case (keeps PC cards compact).
    `comments_chars` is the length of mob_ref['comments']. Reserved for
    the Misc row (mob + trust only)."""
    w = int(TC_WIDTH * scale)
    # Each visible status column adds to the width.
    if has_debuffs:
        w += int(TC_STATUS_COL_W * scale)
    if has_buffs:
        w += int(TC_STATUS_COL_W * scale)
    is_mob   = (kind == "mob")
    is_trust = (kind == "trust")
    # Both mobs AND trusts get an abilities row; only mobs get the
    # STR/WK/Imm/Spells stat block above it.
    has_action_list = is_mob or is_trust
    h = int((TC_TITLE_H +                    # TARGET/SUB-TARGET title strip
             TC_HEADER_H + TC_ICON_H + TC_HP_H +
             TC_SECTION_H +                 # level/family line
             (TC_SECTION_H if has_aggro_row  else 0) +
             (TC_SECTION_H if has_detect_row else 0) +
             (TC_SECTION_H * 2 if is_mob else 0) +    # strengths + weaknesses
             (TC_SECTION_H * max(0, sw_extra_lines) if is_mob else 0) +  # wrap reserve
             TC_PAD * 3) * scale)
    # Abilities row: wrapped flow layout. Estimate line count from total
    # character length of the name list (names + ", " separators). The card
    # body is ~TC_WIDTH px wide; at the font we use, that fits ~28 chars per
    # line comfortably. Over-estimate by one line (ceil + 1) to be safe.
    # PC cards never render abilities, so skip this allocation.
    if has_action_list and (ability_count > 0 or ability_chars > 0):
        chars_per_line = max(18, int(TC_WIDTH / 7))  # rough estimate
        # Subtract the "Abil: " label prefix worth of width on line 1.
        effective_chars = max(ability_chars - 6, 0)
        wrap_lines = 1
        if effective_chars > 0:
            # ceil division
            wrap_lines = max(1, (effective_chars + chars_per_line - 1) // chars_per_line)
        # Label line + wrapped content. Also a small bottom padding.
        h += int((TC_SECTION_H * wrap_lines + TC_PAD) * scale)
    # Misc row reserves space when comments_chars > 0. Same chars-per-line
    # estimate as abilities, less the "Misc: " label width.
    if has_action_list and comments_chars > 0:
        chars_per_line = max(18, int(TC_WIDTH / 7))
        effective_chars = max(comments_chars - 6, 0)
        wrap_lines = 1
        if effective_chars > 0:
            wrap_lines = max(1, (effective_chars + chars_per_line - 1) // chars_per_line)
        h += int((TC_SECTION_H * wrap_lines + TC_PAD // 2) * scale)
    # Cast strip: one line for casting, one for just-cast. ~2 section rows.
    if has_cast:
        h += int(TC_SECTION_H * 2 * scale + TC_PAD * scale)
    return w, h


def _fmt_sw(items):
    """Format strengths/weaknesses list: [(name, pct), ...] → 'Water (-50%), Lightning (+25%)'."""
    if not items:
        return "—"
    parts = []
    for name, pct in items:
        sign = "+" if pct > 0 else ""
        parts.append(f"{name} ({sign}{pct}%)")
    return ", ".join(parts)


def draw_target_card(surface, x, y, info, mob_ref, mobdb_entry,
                     scale=1.0, alpha=255, title_label="TARGET",
                     statuses=None, cast_state=None):
    """Draw the target card.
    - info:        UDP target dict (name, id, hpp, zone_id, distance, etc.)
    - mob_ref:     legacy seed-DB entry (Kirin/Fafnir/...) for abilities list
    - mobdb_entry: MobDB parsed dict (modifiers, aggression flags, levels)
    - title_label: text for the top strip (e.g. "TARGET", "SUB-TARGET")
    - statuses:    dict of effect_id → status info for the current mob, or None
    - cast_state:  {"casting": {...} or None, "last_cast": {...} or None}
    """
    s = scale
    abilities = (mob_ref or {}).get("abilities", []) or []
    aggro_row = mobdb_entry is not None

    # Determine family for JSON ability lookup (same priority as later).
    # For PCs (kind='pc' or legacy is_pc=1), force the family to "adventurer"
    # so we get a clean PC card with no mob ability lookup, no aggro row,
    # and no false-positive name match against the MobDB (e.g. a player
    # named "Wormfood" would otherwise match the worm species entry).
    _info_kind = (info or {}).get("kind", "")
    if not _info_kind:
        _info_kind = "pc" if (info or {}).get("is_pc", 0) else "mob"
    if _info_kind == "pc":
        _early_fam = "adventurer"
    elif _info_kind == "trust":
        _early_fam = "trust"
    elif _info_kind == "npc":
        # Friendly NPCs (vendors, quest-givers, moogles): we don't have
        # any meaningful family/race/job info to display, so skip the
        # entire family line / icon-job/crystal zones. The card collapses
        # to just title + name + hex + HP bar.
        _early_fam = ""
    else:
        _early_fam = ""
        if mobdb_entry and mobdb_entry.get("family"):
            _early_fam = mobdb_entry["family"].lower()
        if not _early_fam:
            _early_fam = infer_family((info or {}).get("name", "") or "")
        if not _early_fam:
            _early_fam = (mob_ref or {}).get("family", "").lower()
        # If still no family data after all three lookups, this entity
        # isn't in any of our mob databases. The lua-side `id % 4096 >
        # 2047` heuristic to detect friendly NPCs was wrong — Windower's
        # own docs confirm mobs and friendly NPCs share zone index range
        # 0..1023 indistinguishably. The reliable signal is that a real
        # mob will have a bestiary entry; a friendly NPC won't. Promote
        # this entity to npc kind so the card collapses correctly.
        if not _early_fam and not mob_ref and not mobdb_entry:
            _info_kind = "npc"
    _abil_count, _abil_chars = _tc_ability_info(mob_ref, _early_fam, mobdb_entry)

    # Split statuses into debuffs (from others) and buffs (self-cast). For
    # now, we classify everything incoming via port 5004 as a debuff unless
    # is_buff was flagged — TODO: detect self-casts from the lua side.
    debuffs = []
    buffs   = []
    if statuses:
        for eff_id, st in statuses.items():
            entry = {"effect_id": eff_id, **st}
            if st.get("is_buff"):
                buffs.append(entry)
            else:
                debuffs.append(entry)

    # Settings-driven section toggles. Clearing the lists also collapses
    # the card width since has_debuffs / has_buffs feed into target_card_size.
    # Main and sub-target each get their own setting — title_label tells
    # us which we're rendering ("TARGET" vs "SUB-TARGET"). The combined
    # toggle controls both buffs and debuffs together; if the user wants
    # them shown independently they can edit the schema (the combined
    # behavior was a deliberate UI simplification).
    _is_sub = title_label == "SUB-TARGET"
    _show_setting = "subtarget_show_buffs" if _is_sub else "target_show_buffs"
    if not setting(_show_setting):
        buffs   = []
        debuffs = []

    has_debuffs = len(debuffs) > 0
    has_buffs   = len(buffs) > 0

    # Cast strip: visible if mob is currently casting OR has a recent finish.
    cs_casting   = (cast_state or {}).get("casting")
    cs_last_cast = (cast_state or {}).get("last_cast")
    has_cast = (cs_casting is not None) or (cs_last_cast is not None)

    _comments_chars = len(((mob_ref or {}).get("comments") or "").strip())
    w, h = target_card_size(s, _abil_count, aggro_row, aggro_row,
                            has_debuffs=has_debuffs, has_buffs=has_buffs,
                            has_cast=has_cast, ability_chars=_abil_chars,
                            kind=_info_kind, comments_chars=_comments_chars)
    core_w = int(TC_WIDTH * s)    # width of the mob-info area

    # Render to an offscreen surface so we can apply alpha (for fade).
    card = pygame.Surface((w, h), pygame.SRCALPHA)

    # Background
    pygame.draw.rect(card, COL_TC_BG,     (0, 0, w, h), border_radius=6)
    pygame.draw.rect(card, COL_TC_BORDER, (0, 0, w, h), 1, border_radius=6)

    # ── Title strip: "TARGET  12.4y" ──────────────────────────────────────
    title_h = int(TC_TITLE_H * s)
    # Slightly darker than the name header for visual separation.
    title_bg = (18, 18, 26)
    pygame.draw.rect(card, title_bg, (1, 1, w - 2, title_h - 1), border_radius=5)
    pygame.draw.line(card, COL_TC_BORDER, (1, title_h), (w - 1, title_h))
    # Accent stripe runs over the title strip's left edge so the stripe
    # is continuous from top to bottom of the card.
    draw_accent_stripe(card, 0, 0, h, ACCENT_TARGET)

    f_title = get_font("Consolas", 9 * s, bold=True)
    t_surf  = f_title.render(title_label, True, COL_TC_LABEL)
    card.blit(t_surf, (int(TC_PAD * s),
                       title_h // 2 - t_surf.get_height() // 2))

    dist = info.get("distance", 0.0) or 0.0
    if dist > 0:
        # Color bands: green = melee (≤5y), blue = spell range (≤21y),
        # yellow = ranged (≤25y), red = out of range.
        if dist <= 5.0:
            dcol = (100, 220, 100)   # green
        elif dist <= 21.0:
            dcol = (110, 170, 255)   # blue
        elif dist <= 25.0:
            dcol = (230, 220,  90)   # yellow
        else:
            dcol = (230, 110, 110)   # red
        # Bolder distance font than the label strip, for emphasis.
        f_dist  = get_font("Consolas", 10 * s, bold=True)
        dist_text = f"{dist:.1f} yalms"
        d_surf = f_dist.render(dist_text, True, dcol)
        card.blit(d_surf, (core_w - d_surf.get_width() - int(TC_PAD * s),
                           title_h // 2 - d_surf.get_height() // 2))

    # Header strip: name (bold) + hex id (dim right-aligned)
    header_h = int(TC_HEADER_H * s)
    pygame.draw.rect(card, COL_TC_HEADER,
                     (1, title_h + 1, core_w - 2, header_h - 1), border_radius=5)
    pygame.draw.line(card, COL_TC_BORDER,
                     (1, title_h + header_h), (core_w - 1, title_h + header_h))

    name_full = info.get("name", "-")   # original name for URL lookup
    name = name_full
    tid  = info.get("id", 0)
    f_name = get_font("Consolas", 13 * s, bold=True)
    f_hex  = get_font("Consolas",  9 * s)

    # Truncate name if wider than ~70% of the card.
    max_name_w = int(core_w * 0.70)
    nm_surf = f_name.render(name, True, COL_TC_NAME)
    if nm_surf.get_width() > max_name_w and len(name) > 3:
        while len(name) > 3 and f_name.render(name + "…", True, COL_TC_NAME).get_width() > max_name_w:
            name = name[:-1]
        nm_surf = f_name.render(name + "…", True, COL_TC_NAME)
    # Determine family up-front so we can show it under the mob name.
    # Priority: (1) MobDB's own Family field if set — authoritative,
    #          (2) name-based inference (patterns + NM overrides),
    #          (3) legacy seed DB family.
    _family_raw = _early_fam

    name_x = int(TC_PAD * s)
    f_fam_sub = get_font("Consolas", 8 * s)

    # If we have a family, reserve a line of space below the name for it.
    family_line_h = int((f_fam_sub.get_height() + 2) if _family_raw else 0)
    header_content_h = header_h - 2   # inner area

    # Name vertically centered in the header strip minus the reserved family line.
    name_y = title_h + (header_content_h - family_line_h) // 2 - nm_surf.get_height() // 2 + 2

    # Compute screen-space rect for the clickable link, and check hover so we
    # can brighten + underline. The card is blitted at (x, y), so our local
    # coords translate by (x, y).
    screen_rect = pygame.Rect(x + name_x, y + name_y,
                              nm_surf.get_width(), nm_surf.get_height())
    is_hover = (alpha > 128) and screen_rect.collidepoint(pygame.mouse.get_pos())
    if is_hover:
        nm_surf = f_name.render(name if name == name_full else (name + "…"),
                                True, (255, 255, 180))
    card.blit(nm_surf, (name_x, name_y))
    if is_hover:
        pygame.draw.line(card, (255, 255, 180),
                         (name_x, name_y + nm_surf.get_height() - 1),
                         (name_x + nm_surf.get_width(), name_y + nm_surf.get_height() - 1))

    # Only register the click if the card is mostly visible (not fading out).
    if alpha > 128 and name_full and name_full != "-":
        register_click_target(screen_rect, bgwiki_url(name_full))

    # Family line under the name, small dim font.
    # Format depends on kind:
    #   mob:    "Subfamily · Ecosystem" (e.g. "Bee · Vermin")
    #   trust:  "<Race> · Trust" (race omitted when unknown)
    #   pc:     "<Race> · Adventurer · <Title>" (title only set for self
    #           since Windower exposes title only via get_player())
    if _family_raw:
        if _info_kind == "pc":
            _race  = ((info or {}).get("race", "") or "").strip()
            _title = ((info or {}).get("pc_title", "") or "").strip()
            base   = f"{_race.title()}  ·  Adventurer" if _race else "Adventurer"
            if _title:
                fam_text = f"{base}  ·  {_title}"
            else:
                fam_text = base
        elif _info_kind == "trust":
            _trust_race = ((mob_ref or {}).get("race", "") or "").strip()
            if _trust_race:
                fam_text = f"{_trust_race.title()}  ·  Trust"
            else:
                fam_text = "Trust"
        else:
            ecosystem = ecosystem_for_subfamily(_family_raw)
            if ecosystem and ecosystem != _family_raw:
                fam_text = f"{_family_raw.title()}  ·  {ecosystem.title()}"
            else:
                fam_text = _family_raw.title()
        fam_surf = f_fam_sub.render(fam_text, True, COL_TC_LABEL)
        card.blit(fam_surf, (name_x, name_y + nm_surf.get_height()))

    hex_str = f"0x{tid:08X}"
    hx_surf = f_hex.render(hex_str, True, COL_TC_HEX)
    card.blit(hx_surf, (core_w - hx_surf.get_width() - int(TC_PAD * s),
                        title_h + header_h // 2 - hx_surf.get_height() // 2))

    cy = title_h + header_h

    # Family icon strip: trust portrait takes priority when present;
    # otherwise the original mob family/ecosystem icon logic runs.
    family = _family_raw
    icon_h = int(TC_ICON_H * s)
    icon_size = min(icon_h - 6, core_w - 6)   # leave a small margin
    icon_pad_x = int(TC_PAD * s) + 4   # small left margin

    trust_portrait_path = (mob_ref or {}).get("portrait", "") if family == "trust" else ""
    drew_trust_portrait = False
    if trust_portrait_path:
        # Left-aligned in the icon strip, mirroring the mob layout.
        # Portrait fits inside the same square footprint a mob icon would
        # occupy, so the visual size is consistent across card types.
        portrait_h = max(1, icon_h - 6)
        portrait_w = max(1, icon_size)   # square footprint
        bitmap = get_trust_portrait_scaled(trust_portrait_path,
                                           portrait_w, portrait_h)
        if bitmap is not None:
            bw, bh = bitmap.get_size()
            ix = icon_pad_x
            iy = cy + (icon_h - bh) // 2
            card.blit(bitmap, (ix, iy))
            drew_trust_portrait = True

        # Render the trust's job to the right of the portrait, in the
        # same band where mobs show Main/Sub job. Pull from mob_ref
        # (populated by resolve_target_card_data from trusts.json's
        # `job` field — e.g. 'PLD/WHM', 'Red Mage', 'GEO/???').
        trust_job = ((mob_ref or {}).get("job") or "").strip()
        if trust_job:
            f_job = get_font("Consolas", 11 * s, bold=True)
            # Render at right side of icon strip, vertically centered.
            job_surf = f_job.render(trust_job, True, (220, 220, 240))
            jx = max(icon_pad_x + portrait_w + int(TC_PAD * s),
                     core_w - int(TC_PAD * s) - job_surf.get_width())
            jy = cy + (icon_h - job_surf.get_height()) // 2
            card.blit(job_surf, (jx, jy))

    if not drew_trust_portrait:
        # Per-mob image takes priority over generic family icon. The
        # `image` field is a filename stem (e.g. "goblinleecher") that
        # resolves to mobicons/<stem>.{png|jpg|...}. If the file isn't
        # on disk and `image_url` is non-empty, the fetcher kicks off
        # a background download and returns None this frame; family
        # icon shows during the wait. Empty `image` means "no per-mob
        # image known" — skip straight to family icon.
        bitmap = None
        # ── Debug: log the lookup once per mob name per session ──
        # Helps diagnose "image file is in mobicons/ but card still
        # shows family icon" — we see whether mobdb_entry was found,
        # what stem it carried, and whether the file resolved on disk.
        # Output goes to the session log (logs/session_*.log).
        _mob_name = (info or {}).get("name", "") or ""
        if _mob_name and _mob_name not in _mob_image_logged:
            _mob_image_logged.add(_mob_name)
            if mobdb_entry:
                _stem = mobdb_entry.get("image") or ""
                _resolved = _mob_image_resolve_path(_stem) if _stem else None
                print(f"[OW image-debug] mob={_mob_name!r}  "
                      f"db_found=True  stem={_stem!r}  "
                      f"resolved_path={_resolved!r}")
            else:
                print(f"[OW image-debug] mob={_mob_name!r}  "
                      f"db_found=False (lookup miss)")
        if mobdb_entry:
            _mob_img_stem = mobdb_entry.get("image") or ""
            _mob_img_url  = mobdb_entry.get("image_url") or ""
            if _mob_img_stem:
                bitmap = get_mob_image_scaled(_mob_img_stem, _mob_img_url, icon_size)
            # Family fallback in mobicons/: when `image` is left blank in
            # mob_individuals.json, treat the lowercased family name as
            # the stem and look for mobicons/<family>.png. Lets the user
            # share one image across all members of a family without
            # having to fill in `image` for every entry. A specific
            # `image` value, when set, still overrides this.
            if bitmap is None and family:
                fam_stem = family.strip().lower()
                if _mob_image_resolve_path(fam_stem):
                    bitmap = get_mob_image_scaled(fam_stem, "", icon_size)
        if bitmap is None:
            bitmap = get_mob_icon_scaled(family, icon_size) if family else None
        if bitmap is None and family:
            ecosystem = ecosystem_for_subfamily(family)
            if ecosystem:
                bitmap = get_mob_icon_scaled(ecosystem, icon_size)
        # PC race+sex icon lookup. _family_raw is hardcoded to "adventurer"
        # for PCs (so the family text reads "Hume · Adventurer"), which
        # means the family-keyed lookup above never finds a match. Use the
        # race key sent by the Lua side ("HumeMale", "Mithra", etc.) as a
        # PC-specific override. Files live in data/mobdata/mobicons/. If
        # not present, fall through to the primitive shape below.
        if bitmap is None and _info_kind == "pc":
            pc_race_key = ((info or {}).get("pc_race_key", "") or "").strip()
            if pc_race_key:
                bitmap = get_mob_icon_scaled(pc_race_key, icon_size)
        if bitmap is not None:
            # Left-aligned in the icon strip with a small left margin.
            ix = icon_pad_x
            iy = cy + (icon_h - icon_size) // 2
            card.blit(bitmap, (ix, iy))
        else:
            # Primitive shape fallback — try subfamily key, then ecosystem key.
            # Position aligned with the bitmap path: left-justified.
            ecosystem = ecosystem_for_subfamily(family) if family else ""
            icon_fn = FAMILY_ICONS.get(family, FAMILY_ICONS.get(ecosystem, _icon_default))
            icon_r  = min(icon_h, core_w) // 3
            icon_cx = icon_pad_x + icon_r
            icon_cy = cy + icon_h // 2
            icon_color = COL_TC_BORDER if family == "" else (200, 200, 220)
            icon_fn(card, icon_cx, icon_cy, icon_r, icon_color)

        # ── Right two zones of the icon strip: jobs (middle-right), crystal (far right) ──
        # Mobs: jobs + crystal both scraped from BG-wiki Bestiary Description.
        # PCs: jobs from pc_main_job/pc_sub_job (already include level e.g. BRD99).
        #      No crystal for PCs.
        # Trusts: skipped — portrait fills the strip.

        # Build job text. Two lines for mobs/PCs with subjob, one otherwise.
        job_main = ""
        job_sub  = ""
        crystal_name = ""    # for mob crystal coloring
        if _info_kind == "pc":
            job_main = ((info or {}).get("pc_main_job", "") or "").strip()
            job_sub  = ((info or {}).get("pc_sub_job",  "") or "").strip()
        elif _info_kind == "mob":
            # Per-mob job from the mobdb entry takes priority — that's
            # what gets edited when a user fixes a specific mob's data
            # in mob_individuals.json. Only fall through to the family
            # description when the per-mob fields are empty.
            if mobdb_entry:
                _mj = (mobdb_entry.get("main_job") or "").strip()
                _sj = (mobdb_entry.get("sub_job")  or "").strip()
                # Accept either 3-letter abbreviation ("WHM") or full
                # word ("White Mage" / "Warrior"). The scrape uses both
                # depending on the mob — translate full words via
                # JOB_NAME_TO_ABBR. Anything else (empty string,
                # commentary, multi-job lists) gets skipped so the
                # family fallback below can run.
                _mj_abbr = _to_job_abbr(_mj)
                _sj_abbr = _to_job_abbr(_sj)
                if _mj_abbr:
                    job_main = _mj_abbr
                if _sj_abbr:
                    job_sub = _sj_abbr
            # Family-level fallback (only used when per-mob fields are
            # empty above — previously this was the ONLY source, which
            # caused all goblins to show the family-default jobs even
            # when a specific NM had different jobs hand-edited into
            # the JSON).
            if not job_main:
                desc = ""
                if _mob_abilities_db and family:
                    fam_rec = (_mob_abilities_db.get("families", {}) or {}).get(family)
                    if fam_rec:
                        desc = fam_rec.get("description", "") or ""
                mm = re.search(r"Main Job:\s*([A-Z]{3})", desc)
                if mm:
                    job_main = mm.group(1)
                sm = re.search(r"Sub Job:\s*([A-Za-z, ]+?)(?:\s*\||$)", desc)
                if sm:
                    first = sm.group(1).split(",")[0].strip()
                    if re.fullmatch(r"[A-Za-z]{3}", first):
                        job_sub = first.upper()
                cm = re.search(r"Crystal:\s*([A-Za-z]+)", desc)
                if cm:
                    crystal_name = cm.group(1).strip().lower()
            # Crystal: prefer per-mob value (the JSON has it as a
            # field directly), fall back to family description above.
            if mobdb_entry and not crystal_name:
                _cr = (mobdb_entry.get("crystal") or "").strip().lower()
                if _cr:
                    crystal_name = _cr

        # Crystal swatch sized off icon strip height; far-right anchor
        crystal_size = max(8, int(icon_h * 0.55))
        crystal_pad  = int(TC_PAD * s) + 2
        cx_right     = core_w - crystal_pad
        # Reserve crystal column even if no crystal so jobs land in the same
        # x for both mob and PC cards.
        crystal_col_w = crystal_size + 6 if (_info_kind == "mob") else 0

        # Job text rendering. Use two stacked lines if we have both main+sub.
        f_job_main = get_font("Consolas", 11 * s, bold=True)
        f_job_sub  = get_font("Consolas",  9 * s)
        # Right edge available for jobs = right edge minus crystal column.
        jobs_right_x = core_w - crystal_col_w - int(TC_PAD * s)
        if job_main and job_sub:
            mj_surf = f_job_main.render(job_main, True, (220, 220, 240))
            sj_surf = f_job_sub.render(job_sub,   True, (180, 180, 200))
            stack_h = mj_surf.get_height() + sj_surf.get_height()
            block_top = cy + (icon_h - stack_h) // 2
            card.blit(mj_surf, (jobs_right_x - mj_surf.get_width(), block_top))
            card.blit(sj_surf, (jobs_right_x - sj_surf.get_width(),
                                block_top + mj_surf.get_height()))
        elif job_main:
            mj_surf = f_job_main.render(job_main, True, (220, 220, 240))
            block_top = cy + (icon_h - mj_surf.get_height()) // 2
            card.blit(mj_surf, (jobs_right_x - mj_surf.get_width(), block_top))

        # Element crystal (mobs only). First try a real icon from
        # icons/mob/<element>.png — same loader as family icons. If the
        # icon isn't on disk, fall back to the colored diamond gem so
        # the card still reads correctly. Lightning uses windower's
        # canonical "thunder" key in our element map; the icon file is
        # named lightning.png on disk, so we try both.
        if _info_kind == "mob" and crystal_name:
            ELEM_COLORS = {
                "fire":      (235, 95,  60),
                "ice":       (140, 210, 240),
                "wind":      (140, 220, 150),
                "earth":     (200, 170, 110),
                "lightning": (210, 160, 230),
                "thunder":   (210, 160, 230),  # alias
                "water":     (110, 160, 230),
                "light":     (240, 230, 180),
                "dark":      (130, 110, 150),
            }
            gx = cx_right - crystal_size
            gy = cy + (icon_h - crystal_size) // 2

            # Try icon by name. Fire / ice / wind etc. all match
            # filenames in icons/mob/. "thunder" is the windower res
            # key but the on-disk filename convention is "lightning",
            # so probe both.
            elem_surf = get_mob_icon_scaled(crystal_name, crystal_size)
            if elem_surf is None and crystal_name == "thunder":
                elem_surf = get_mob_icon_scaled("lightning", crystal_size)
            elif elem_surf is None and crystal_name == "lightning":
                elem_surf = get_mob_icon_scaled("thunder", crystal_size)

            if elem_surf is not None:
                card.blit(elem_surf, (gx, gy))
            else:
                # Fallback: original diamond gem rendering. Color-coded
                # so the element still reads even without an icon file.
                ccol = ELEM_COLORS.get(crystal_name)
                if ccol:
                    cx_mid = gx + crystal_size // 2
                    cy_mid = gy + crystal_size // 2
                    pts = [
                        (cx_mid, gy),                          # top
                        (gx + crystal_size, cy_mid),           # right
                        (cx_mid, gy + crystal_size),           # bottom
                        (gx, cy_mid),                          # left
                    ]
                    pygame.draw.polygon(card, ccol, pts)
                    pygame.draw.polygon(card, COL_TC_BORDER, pts, 1)
                    # Subtle highlight on upper-left facet for "shine"
                    hl_pts = [pts[0],
                              (cx_mid, cy_mid),
                              pts[3]]
                    hl_col = tuple(min(255, c + 60) for c in ccol)
                    pygame.draw.polygon(card, hl_col, hl_pts)
                    pygame.draw.polygon(card, COL_TC_BORDER, hl_pts, 1)
    cy += icon_h

    # HP bar
    hp_h = int(TC_HP_H * s)
    pad = int(TC_PAD * s)
    hp_x = pad
    hp_y = cy + 2
    hp_w = core_w - 2 * pad
    hpp  = max(0, min(100, info.get("hpp", 0)))
    col = hp_color(hpp, flash)  # reuse party HP color bands
    pygame.draw.rect(card, COL_BAR_BG, (hp_x, hp_y, hp_w, hp_h))
    fill_w = int(hp_w * hpp / 100)
    if fill_w > 0:
        pygame.draw.rect(card, col, (hp_x, hp_y, fill_w, hp_h))
    pygame.draw.rect(card, COL_TC_BORDER, (hp_x, hp_y, hp_w, hp_h), 1)
    f_hp = get_font("Consolas", 10 * s, bold=True)
    hp_text = f"{hpp}%"
    hp_shadow = f_hp.render(hp_text, True, (0, 0, 0))
    hp_main   = f_hp.render(hp_text, True, (255, 255, 255))
    tx = hp_x + hp_w // 2 - hp_main.get_width() // 2
    ty = hp_y + hp_h // 2 - hp_main.get_height() // 2
    for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        card.blit(hp_shadow, (tx + dx, ty + dy))
    card.blit(hp_main, (tx, ty))
    cy = hp_y + hp_h + int(TC_PAD * s)

    # ── MobDB-derived info ──────────────────────────────────────────────
    f_sec   = get_font("Consolas", 10 * s, bold=True)
    f_sec_v = get_font("Consolas", 10 * s)
    f_dim   = get_font("Consolas",  9 * s)

    # Level / NM / family line.
    bits = []
    respawn_text = ""
    if mobdb_entry:
        if mobdb_entry.get("notorious"):
            bits.append("NM")
        mn, mx = mobdb_entry.get("min_level", 0), mobdb_entry.get("max_level", 0)
        if mn or mx:
            if mn == mx:
                bits.append(f"Lv.{mn}")
            else:
                bits.append(f"Lv.{mn}-{mx}")
        respawn_text = format_respawn(mobdb_entry.get("respawn", 0))
    # Family moved to under the mob name; no longer duplicated in status line.
    if bits:
        card.blit(f_dim.render("  ".join(bits), True, COL_TC_LABEL), (pad, cy))
    if respawn_text:
        # Right-aligned on the same row with a "Respawn:" prefix.
        resp_full = f"Respawn: {respawn_text}"
        rs_surf = f_dim.render(resp_full, True, COL_TC_LABEL)
        card.blit(rs_surf, (core_w - rs_surf.get_width() - pad, cy))
    cy += int(TC_SECTION_H * s)

    # Aggression row: Aggro, Links, TrueSight — each shown only when true.
    if mobdb_entry:
        x_cursor = pad
        y_row    = cy
        def _tag(label, active, color):
            nonlocal x_cursor
            if not active:
                return
            surf = f_sec.render(label, True, color)
            card.blit(surf, (x_cursor, y_row))
            x_cursor += surf.get_width() + int(8 * s)
        _tag("Aggro",     mobdb_entry.get("aggro"),     (230, 110, 110))
        _tag("Links",     mobdb_entry.get("link"),      (230, 170,  80))
        _tag("TrueSight", mobdb_entry.get("truesight"), (230, 220,  90))
        # Show "(Passive)" when the mob doesn't aggro at all, for clarity.
        if not mobdb_entry.get("aggro"):
            surf = f_dim.render("(Passive)", True, COL_TC_LABEL)
            card.blit(surf, (x_cursor, y_row))
        cy += int(TC_SECTION_H * s)

        # Detection row: Sight, Sound, Blood, Magic, JA, Scent.
        # These indicate HOW the mob aggros / links — so we show them
        # brighter and label the row. Color-coded by detection type.
        x_cursor = pad
        y_row    = cy

        # Detection-type colors — chosen to match the "theme" of each sense.
        det_palette = {
            "sight": (230, 220,  90),   # yellow (visual)
            "sound": (150, 210, 255),   # light blue (audio)
            "blood": (230, 110, 110),   # red (blood)
            "magic": (200, 140, 230),   # purple (magic)
            "ja":    (240, 180, 100),   # orange (job ability)
            "scent": (180, 220, 140),   # green-yellow (scent)
        }

        tags_to_draw = [
            ("Sight", "sight"), ("Sound", "sound"), ("Blood", "blood"),
            ("Magic", "magic"), ("JA",    "ja"),    ("Scent", "scent"),
        ]
        any_det = any(mobdb_entry.get(k) for _, k in tags_to_draw)

        if any_det:
            # Small leading label so it's obvious what the row means.
            lbl_surf = f_sec.render("Sense:", True, COL_TC_LABEL)
            card.blit(lbl_surf, (x_cursor, y_row))
            x_cursor += lbl_surf.get_width() + int(6 * s)
            for lbl_text, key in tags_to_draw:
                if mobdb_entry.get(key):
                    surf = f_sec.render(lbl_text, True, det_palette[key])
                    card.blit(surf, (x_cursor, y_row))
                    x_cursor += surf.get_width() + int(8 * s)
        cy += int(TC_SECTION_H * s)

    # Strengths / weaknesses from MobDB modifiers.
    strengths_out, weaknesses_out = mob_strengths_weaknesses(mobdb_entry)

    # STR/WK rendering with word-wrap: long lists get broken onto multiple
    # lines so the narrow card doesn't clip. First line includes the label.
    def _draw_wrapped_items(label_text, items_formatted_parts, color, start_y):
        """Render a label followed by comma-separated parts, wrapping onto
        additional indented lines if needed. Returns new cursor y."""
        lbl = f_sec.render(label_text, True, COL_TC_LABEL)
        card.blit(lbl, (pad, start_y))
        line_x_start = pad + lbl.get_width() + 4
        indent_x     = pad + lbl.get_width() + 4
        avail_w      = core_w - indent_x - pad
        max_line_w   = core_w - pad - indent_x

        if not items_formatted_parts:
            card.blit(f_sec_v.render("—", True, color), (line_x_start, start_y))
            return start_y + int(TC_SECTION_H * s)

        current_line = ""
        cy_local = start_y
        for i, piece in enumerate(items_formatted_parts):
            # First piece on a line has no leading comma; later pieces do.
            candidate = (current_line + ", " + piece) if current_line else piece
            test_surf = f_sec_v.render(candidate, True, color)
            if test_surf.get_width() <= max_line_w or not current_line:
                current_line = candidate
            else:
                # Flush current, start new line.
                card.blit(f_sec_v.render(current_line, True, color),
                          (indent_x, cy_local))
                cy_local += int(TC_SECTION_H * s)
                current_line = piece
        if current_line:
            card.blit(f_sec_v.render(current_line, True, color),
                      (indent_x, cy_local))
            cy_local += int(TC_SECTION_H * s)
        return cy_local

    def _draw_wrapped_items_trackable(label_text, parts, color, start_y):
        """Same as _draw_wrapped_items but returns (new_y, rects). Each
        rect is in CARD-LOCAL coordinates and corresponds to the on-screen
        position of the Nth item. Used for hover hit-testing on abilities.
        Only the item name (no comma/space) is covered by the rect."""
        lbl = f_sec.render(label_text, True, COL_TC_LABEL)
        card.blit(lbl, (pad, start_y))
        indent_x = pad + lbl.get_width() + 4
        max_line_w = core_w - pad - indent_x
        rects = []
        if not parts:
            card.blit(f_sec_v.render("—", True, color), (indent_x, start_y))
            return start_y + int(TC_SECTION_H * s), rects

        # Pre-measure each item's width (without comma) and a ", " separator.
        sep_w = f_sec_v.render(", ", True, color).get_width()
        item_widths = [f_sec_v.render(p, True, color).get_width() for p in parts]
        line_h = int(TC_SECTION_H * s)

        cy_local = start_y
        cur_x = indent_x
        first_on_line = True
        for i, piece in enumerate(parts):
            w = item_widths[i]
            # Prefix a ", " if this isn't the first item on the line.
            prefix_w = 0 if first_on_line else sep_w
            # If it doesn't fit, wrap.
            if not first_on_line and (cur_x + prefix_w + w) > (indent_x + max_line_w):
                cy_local += line_h
                cur_x = indent_x
                first_on_line = True
                prefix_w = 0

            if not first_on_line:
                card.blit(f_sec_v.render(", ", True, color), (cur_x, cy_local))
                cur_x += sep_w
            # Draw the name and record its rect.
            surf = f_sec_v.render(piece, True, color)
            card.blit(surf, (cur_x, cy_local))
            rects.append(pygame.Rect(cur_x, cy_local, w, surf.get_height()))
            cur_x += w
            first_on_line = False

        cy_local += line_h
        return cy_local, rects

    # Build formatted parts (so wrap can count widths accurately).
    def _parts(items):
        return [f"{name} ({'+' if pct > 0 else ''}{pct}%)" for name, pct in items]

    # The Imm / STR / WK / Spells / Abilities sections are mob-only.
    # PCs and Trusts don't have these. Skip the whole block for them so
    # the card stays compact instead of showing a stack of empty rows.
    if _info_kind == "mob":
        # Immunities — from the Immunities bitmask in MobDB. Always shown so
        # the vertical layout is stable across mobs. Empty list shows "—".
        imm_list = []
        if mobdb_entry:
            imm_list = decode_immunities(mobdb_entry.get("immunities", 0))
        cy = _draw_wrapped_items("Imm:", imm_list, (200, 200, 140), cy)

        cy = _draw_wrapped_items("STR:", _parts(strengths_out),  COL_TC_STRONG, cy)
        cy = _draw_wrapped_items("WK:",  _parts(weaknesses_out), COL_TC_WEAK,   cy)

        # Spells (condensed) — from the per-mob spells list. Accepts
        # both name strings (new merged JSON format) and numeric IDs
        # (legacy .lua mobdb). condense_spell_list() handles either.
        spells_list = []
        mob_spells = (mobdb_entry.get("spells") if mobdb_entry else None) or []
        # ── Debug: log spells lookup once per mob name per session ──
        # Helps diagnose "spells row not showing" issues. Output goes
        # to the session log.
        _sp_name = (info or {}).get("name", "") or ""
        if _sp_name and _sp_name not in _mob_spells_logged:
            _mob_spells_logged.add(_sp_name)
            print(f"[OW spells-debug] mob={_sp_name!r}  "
                  f"db_found={mobdb_entry is not None}  "
                  f"mob_spells_count={len(mob_spells)}  "
                  f"first_3={mob_spells[:3]}")
        if mob_spells:
            condensed = condense_spell_list(mob_spells)
            if condensed:
                spells_list = [p.strip() for p in condensed.split(",") if p.strip()]
        if spells_list:
            cy = _draw_wrapped_items("Spells:", spells_list,
                                      (180, 180, 230), cy)

        # Abilities: spells-style wrapped row. Source priority:
        #   1. Per-mob `abilities` from mobdb_entry (the editable
        #      mob_individuals.json field). If present, looked up
        #      against the family's tp_moves to recover rich detail
        #      (effect, class, shadows) for hover tooltips.
        #   2. mob_abilities.json family entry's tp_moves — used as
        #      a fallback when per-mob abilities are empty.
        #   3. legacy mob_ref abilities list (NM seed DB).
        # Also records per-item screen-space rects for hover tooltips.
        ability_entries = []
        # Build family rich-data lookup once for both paths.
        fam_tp_moves = []
        if _mob_abilities_db and _family_raw:
            fam_rec = _mob_abilities_db.get("families", {}).get(_family_raw)
            if fam_rec:
                fam_tp_moves = fam_rec.get("tp_moves") or []
        # Per-mob list (the user's editable source of truth).
        mob_abils = []
        if mobdb_entry:
            mob_abils = mobdb_entry.get("abilities") or []

        if mob_abils:
            # Index family tp_moves by name for fast rich-record lookup.
            by_name = {(m.get("name") or "").lower(): m for m in fam_tp_moves}
            for nm in mob_abils:
                rich = by_name.get(nm.lower())
                if rich:
                    ability_entries.append(rich)
                else:
                    # No family record for this ability (rare — likely a
                    # custom ability the user typed in or a mob with no
                    # family-level data). Fall back to a name-only entry
                    # so it still renders and tooltip shows just the name.
                    ability_entries.append({"name": nm})
        elif fam_tp_moves:
            ability_entries = fam_tp_moves
        elif abilities:
            # Legacy string list; wrap into the same record shape so the renderer
            # and tooltip can treat both paths uniformly.
            ability_entries = [{"name": nm} for nm in abilities]

        if ability_entries:
            cy += int(TC_PAD * s // 2)
            parts = [e.get("name", "") for e in ability_entries if e.get("name")]
            # Draw with per-item rect tracking. The helper returns (new_y, rects)
            # where rects is a list of pygame.Rect in CARD-LOCAL coordinates; we
            # translate to screen coords and append to the module-level hover
            # list below.
            cy, item_rects = _draw_wrapped_items_trackable(
                "Abil:", parts, COL_TC_ABILITY, cy)
            for i, r in enumerate(item_rects):
                if i < len(ability_entries):
                    _mob_ability_rects.append((
                        pygame.Rect(r.x + x, r.y + y, r.width, r.height),
                        ability_entries[i],
                    ))

    elif _info_kind == "trust":
        # Trust cards render three labeled rows (when present): Abil for
        # job abilities, WS for weapon skills, Spells for known spells.
        # Each row is rendered only when its list has entries, so a trust
        # with only abilities (most melee trusts) gets a compact card.
        # Sourced from mob_ref's per-list fields populated by
        # resolve_target_card_data() from trusts.json.
        ja_list = (mob_ref or {}).get("job_abilities") or []
        ws_list = (mob_ref or {}).get("weapon_skills") or []
        sp_list = (mob_ref or {}).get("spells") or []
        if ja_list or ws_list or sp_list:
            cy += int(TC_PAD * s // 2)
        if ja_list:
            cy = _draw_wrapped_items("Abil:", ja_list, COL_TC_ABILITY, cy)
        if ws_list:
            cy = _draw_wrapped_items("WS:",   ws_list, COL_TC_ABILITY, cy)
        if sp_list:
            cy = _draw_wrapped_items("Spells:", sp_list, (180, 180, 230), cy)

    # ── Misc row (user-editable comments) ──────────────────────────────────
    # Renders for both mob and trust cards when mob_ref has a non-empty
    # 'comments' string. The text is hand-edited in the JSON; the field
    # stays empty by default and is preserved by the scrapers across
    # re-runs. Uses a dedicated word-wrap rather than _draw_wrapped_items
    # (which inserts ", " between pieces — wrong for prose).
    _comments = ((mob_ref or {}).get("comments") or "").strip()
    if _comments and _info_kind in ("mob", "trust"):
        words = [w for w in _comments.split() if w]
        if words:
            cy += int(TC_PAD * s // 2)
            misc_color = (170, 200, 170)
            lbl = f_sec.render("Misc:", True, COL_TC_LABEL)
            card.blit(lbl, (pad, cy))
            indent_x   = pad + lbl.get_width() + 4
            max_line_w = core_w - pad - indent_x
            current = ""
            for w in words:
                cand = (current + " " + w) if current else w
                if f_sec_v.render(cand, True, misc_color).get_width() <= max_line_w \
                   or not current:
                    current = cand
                else:
                    card.blit(f_sec_v.render(current, True, misc_color),
                              (indent_x, cy))
                    cy += int(TC_SECTION_H * s)
                    current = w
            if current:
                card.blit(f_sec_v.render(current, True, misc_color),
                          (indent_x, cy))
                cy += int(TC_SECTION_H * s)

    # ── Status columns (right side): debuffs, then buffs ────────────────────
    # Only rendered when the mob has statuses — card width already reserved.
    if has_debuffs or has_buffs:
        col_w   = int(TC_STATUS_COL_W * s)
        col_pad = int(TC_PAD * s)
        col_top = int((TC_TITLE_H + 2) * s)    # start just under title strip
        col_bot = h - int(TC_PAD * s)
        row_h   = int(TC_SECTION_H * s)
        f_col_hdr = get_font("Consolas", 9 * s, bold=True)
        f_col_row = get_font("Consolas", 9 * s)
        f_col_tim = get_font("Consolas", 8 * s)

        def _draw_col(col_x, header_text, items, header_color):
            # Border separator
            pygame.draw.line(card, COL_TC_BORDER,
                             (col_x, int(TC_TITLE_H * s)),
                             (col_x, h - 1))
            hdr = f_col_hdr.render(header_text, True, header_color)
            card.blit(hdr, (col_x + col_pad, col_top))
            y_ = col_top + hdr.get_height() + 4
            # Most recently applied first.
            ordered = sorted(items, key=lambda e: -e.get("applied_at", 0))
            for st in ordered:
                if y_ + row_h > col_bot:
                    # Out of room — show a "+N more" and bail.
                    more = len(ordered) - (ordered.index(st))
                    if more > 0:
                        card.blit(f_col_tim.render(f"+{more} more", True, COL_TC_LABEL),
                                  (col_x + col_pad, y_))
                    break
                nm = st.get("spell_name", "")
                # Truncate long spell names to the column width.
                avail_name_w = col_w - 2 * col_pad
                while nm and f_col_row.render(nm, True, header_color).get_width() > avail_name_w:
                    nm = nm[:-1]
                nm_s = f_col_row.render(nm or "?", True, header_color)
                card.blit(nm_s, (col_x + col_pad, y_))
                y_ += row_h + 2

        col_x = core_w
        if has_debuffs:
            _draw_col(col_x, "DEBUFFS", debuffs, (230, 150, 150))
            col_x += col_w
        if has_buffs:
            _draw_col(col_x, "BUFFS", buffs, (150, 220, 150))

    # ── Cast strip (bottom of card) ──────────────────────────────────────────
    if has_cast:
        f_cast = get_font("Consolas", 11 * s, bold=True)
        pad_l  = int(TC_PAD * s)
        strip_h = int(TC_SECTION_H * 2 * s)
        strip_y = h - strip_h - int(TC_PAD * s)
        # Divider
        pygame.draw.line(card, COL_TC_BORDER,
                         (pad_l, strip_y),
                         (core_w - pad_l, strip_y), 1)

        line1_y = strip_y + 4
        line2_y = line1_y + f_cast.get_height() + 2

        _now = time.time()

        # Pulsing yellow "Casting X" (sine wave on alpha over ~1.2s cycle).
        if cs_casting:
            verb = "Casting" if cs_casting.get("kind") == "spell" else "Using"
            txt  = f"{verb} {cs_casting.get('name', '?')}"
            t_since = max(0.0, _now - cs_casting.get("started", _now))
            # Pulse between 140 and 255 alpha.
            phase = (t_since / 1.2) * 2 * math.pi
            pulse = int(140 + 115 * (0.5 + 0.5 * math.sin(phase)))
            pulse = max(0, min(255, pulse))
            cs_surf = f_cast.render(txt, True, (240, 220, 90))
            cs_surf.set_alpha(pulse)
            card.blit(cs_surf, (pad_l, line1_y))

        # Fading red "Casts X" / "Used X". Fades over last CAST_DONE_FADE.
        if cs_last_cast:
            verb = "Casts" if cs_last_cast.get("kind") == "spell" else "Used"
            txt  = f"{verb} {cs_last_cast.get('name', '?')}"
            t_since = max(0.0, _now - cs_last_cast.get("done_at", _now))
            if t_since >= CAST_DONE_TTL:
                done_alpha = 0
            elif t_since >= (CAST_DONE_TTL - CAST_DONE_FADE):
                frac = (CAST_DONE_TTL - t_since) / CAST_DONE_FADE
                done_alpha = max(0, min(255, int(255 * frac)))
            else:
                done_alpha = 255
            if done_alpha > 0:
                r_surf = f_cast.render(txt, True, (230, 90, 90))
                r_surf.set_alpha(done_alpha)
                card.blit(r_surf, (pad_l, line2_y))

    # Apply alpha for fade-out
    if alpha < 255:
        card.set_alpha(alpha)
    surface.blit(card, (x, y))


def equip_panel_size(scale):
    """Return (panel_w, panel_h, slot_size, title_h) at the given scale."""
    slot_size = max(20, int(EV_SLOT_SIZE * scale))
    title_h   = max(16, int(EV_TITLE_H   * scale))
    panel_w   = EV_COLS * slot_size + 2
    panel_h   = title_h + EV_ROWS * slot_size + 2
    return panel_w, panel_h, slot_size, title_h

# ═══════════════════════════════════════════════════════════════════════════
# Stats panel — fixed 7×5 grid of summed-gear stats + 4×2 elemental grid.
# Layout is job-agnostic (same cells for every job). Values are summed from
# gear, buffs, and base-stat tables on the lua side. Cells we don't yet
# compute show "--".
# ═══════════════════════════════════════════════════════════════════════════

# The main grid. Each entry is (display_label, stat_key). stat_key may be
# None for computed/combined cells — those are resolved in resolve_stat_value().
STATS_GRID_ROWS = [
    # Row 1 — primary attributes (base + gear). Unchanged.
    [("STR","str"),("DEX","dex"),("VIT","vit"),("AGI","agi"),
     ("INT","int"),("MND","mnd"),("CHR","chr")],
    # Row 2 — haste breakdown + WS spacing/damage
    [("Gear Haste","haste"),("Magic Haste","magic haste"),("JA Haste","ja haste"),
     ("Total Haste","total haste"),
     ("TP/Hit","tp per hit"),("Hit→WS","hits to ws"),("WSD","weapon skill damage")],
    # Row 3 — DW breakdown (gear/traits/cap-delta) + multi-attack + STP
    [("DW Gear","dual wield"),("DW Traits","dw trait"),("DW To Cap","dw needed"),
     ("DA","double attack"),("TA","triple attack"),("QA","quadruple attack"),
     ("STP","store tp")],
    # Row 4 — accuracy / attack pairs + snapshot + ranged
    [("Acc1","accuracy"),("Acc2","accuracy2"),
     ("Att1","attack"),("Att2","attack2"),
     ("Snapshot","snapshot"),
     ("RAcc","ranged accuracy"),("RAtt","ranged attack")],
    # Row 5 — damage taken / defenses. Unchanged.
    [("DT","damage taken"),("PDT","physical damage taken"),
     ("MDT","magic damage taken"),("BDT","breath damage taken"),
     ("MEva","magic evasion"),("Eva","evasion"),("Def","defense")],
    # Row 6 — caster mods + sustain (NEW). Sits between defenses and elements.
    [("Fast Cast","fast cast"),("Quick Magic","quick magic"),
     ("MAcc","magic accuracy"),("MAB","magic attack bonus"),
     ("Regen","regen"),("Refresh","refresh"),("Regain","regain")],
]

STATS_ELEM_ROWS = [
    # Row 1: elemental affinity from gear ("Fire +10", "Wind +5", etc.).
    # Internal key is the lowercase element name. "Lightning" displays
    # but maps to the internal "thunder" key (matches FFXI's res).
    [("Fire","fire"),("Lightning","thunder"),
     ("Earth","earth"),("Wind","wind")],
    # Row 2
    [("Ice","ice"),("Water","water"),
     ("Light","light"),("Dark","dark")],
]

# Cells that render with a "%" suffix.
PERCENT_CELLS = {
    "haste", "magic haste", "ja haste", "total haste",
    "double attack", "triple attack", "quadruple attack",
    "dual wield", "dw trait", "dw needed",
    "weapon skill damage",
    "fast cast", "quick magic",
    "damage taken", "physical damage taken", "magic damage taken",
    "breath damage taken",
    "movement speed",
}

# Cells that treat negative as good (damage taken, etc.).
INVERT_SIGN_CELLS = {
    "damage taken", "physical damage taken", "magic damage taken",
    "breath damage taken",
}

# Cells that show absolute totals (skill + base + gear + buffs + food)
# rather than gear-only deltas. Rendered as plain integers, no sign,
# matching what /checkparam shows so users can compare directly.
TOTAL_CELLS = {
    "accuracy", "attack", "accuracy2", "attack2",
    "ranged accuracy", "ranged attack",
    "defense", "evasion",
    # MAcc / MAB cells: rendered as +N (sign-prefixed delta) rather than
    # raw totals, since the value is a sum of trait/JP/gear bonuses, not
    # a base+gear total in the way physical accuracy/attack are.
    "tp per hit", "hits to ws",
}

# Cells where the value is conceptually a percentage / target rather
# than a gear-summed delta. They're percents (handled via
# PERCENT_CELLS for the suffix) but should NOT show a leading "+".
NO_SIGN_CELLS = {
    "dw trait",      # absolute trait+gift DW% (e.g. "30%" not "+30%")
    "dw needed",     # delta-to-cap, conceptually a target distance
    "total haste",   # absolute combined haste, not a gear delta
}

# Known gear/category caps. Value shown exceeds cap → render in red to flag
# wasted potential. For damage-taken stats (INVERT_SIGN_CELLS) the "cap"
# is actually a floor (e.g. PDT caps at -50%), shown in red if below.
STAT_CAPS = {
    "haste":                  25,    # gear haste cap
    "magic haste":            43.75, # ma haste cap
    "ja haste":               25,    # ja haste cap
    "total haste":            80,    # combined cap
    "dual wield":             80,    # DW gear cap (context-dep, 80 is practical max)
    "fast cast":              80,    # FC cap (gear+JA combined)
    "quick magic":            50,    # commonly-cited soft cap; gear-only
    "store tp":               100,
    "subtle blow":            50,
    "movement speed":         60,    # +60% over base is the true game cap
                                      #   (160% total). Gear-only cap is ~25,
                                      #   but with Bolter's Roll the displayed
                                      #   value can legitimately reach 60.
    "physical damage taken":  -50,   # PDT floor
    "magic damage taken":     -50,   # MDT floor
    "breath damage taken":    -50,   # BDT floor
    "damage taken":           -50,   # DT combined floor
}

# Layout metrics.
STATS_CELL_W     = 56     # logical per-cell width at scale 1
STATS_CELL_H     = 30     # logical per-cell height at scale 1 (two lines)
STATS_ELEM_CELL_W = 74    # wider since element labels are longer
STATS_GRID_COLS  = 7
STATS_ELEM_COLS  = 4
STATS_PAD        = 4
STATS_TITLE_H    = 22
STATS_SECTION_GAP = 4

def stats_panel_size(scale, _unused=None):
    """Return (panel_w, panel_h) for the fixed 7x5 + 4x2 grid at scale."""
    cell_w  = max(32, int(STATS_CELL_W * scale))
    cell_h  = max(20, int(STATS_CELL_H * scale))
    elem_w  = max(44, int(STATS_ELEM_CELL_W * scale))
    pad     = max(3,  int(STATS_PAD    * scale))
    title_h = max(16, int(STATS_TITLE_H * scale))
    gap     = max(2,  int(STATS_SECTION_GAP * scale))

    main_w = STATS_GRID_COLS * cell_w
    elem_w_total = STATS_ELEM_COLS * elem_w
    panel_w = max(main_w, elem_w_total) + pad * 2
    panel_h = (title_h + len(STATS_GRID_ROWS) * cell_h + gap
               + len(STATS_ELEM_ROWS) * cell_h + pad * 2)
    return panel_w, panel_h


def _fmt_stat_value(key, val):
    """Format a number for display. Returns (text, color).
    Over-cap values render in red (bright) regardless of sign."""
    if val is None:
        return "--", (110, 110, 120)
    # Total cells (full battle stats matching /checkparam): plain integer,
    # no sign — these aren't deltas, they're absolute totals.
    if key in TOTAL_CELLS:
        # Hits to WS: keep one decimal so users see "19.6" rather than
        # rounding "20". TP/hit and others are integer.
        if key == "hits to ws":
            return f"{float(val):.1f}", (220, 220, 230)
        v_int = int(round(float(val)))
        return f"{v_int}", (220, 220, 230)
    if isinstance(val, float) and not val.is_integer():
        txt = f"{val:+.1f}" if key not in NO_SIGN_CELLS else f"{val:.1f}"
    else:
        v_int = int(val)
        if key in NO_SIGN_CELLS:
            txt = f"{v_int}"
        else:
            txt = f"{v_int:+d}" if v_int != 0 else "0"
    if key in PERCENT_CELLS:
        txt += "%"
    num = float(val)

    # Cap check: show as bright red if we exceed the cap. For damage-taken
    # stats (negative = good), "exceeds cap" means going lower than the floor.
    cap = STAT_CAPS.get(key)
    if cap is not None:
        if key in INVERT_SIGN_CELLS:
            if num < cap:  # e.g. PDT=-52% when cap=-50
                return txt, (255, 110, 110)
        else:
            if num > cap:
                return txt, (255, 110, 110)

    # Color: green = beneficial, red = detrimental.
    # Special-case: "dw needed" is a delta-to-target. 0 means capped
    # (good), positive means more DW gear required (informational, not
    # bad). Display as green when 0, neutral when >0.
    if key == "dw needed":
        if num <= 0: col = (140, 220, 140)
        else:        col = (220, 200, 140)   # warm yellow = "more needed"
        return txt, col
    if key in INVERT_SIGN_CELLS:
        if   num < 0: col = (140, 220, 140)
        elif num > 0: col = (230, 140, 140)
        else:         col = (190, 190, 200)
    else:
        if   num > 0: col = (140, 220, 140)
        elif num < 0: col = (230, 140, 140)
        else:         col = (190, 190, 200)
    return txt, col


def _resolve_stat_value(key, stats):
    """Fetch the value for a stat key from the player_stats dict.
    Some keys are aliases or computed from multiple underlying keys."""
    if not key:
        return None
    # Direct lookup first.
    v = stats.get(key)
    if v is not None:
        return v
    # Aliases we accept (stat key as checkparam sees it, plus shortcuts).
    aliases = {
        "str": ["strength"], "dex": ["dexterity"], "vit": ["vitality"],
        "agi": ["agility"], "int": ["intelligence"], "mnd": ["mind"],
        "chr": ["charisma"],
        "defense": ["def"],
        "evasion": ["evasion skill"],
        "damage taken":           ["dt"],
        "physical damage taken":  ["pdt", "pdt2"],
        "magic damage taken":     ["mdt", "mdt2"],
        "breath damage taken":    ["bdt"],
    }
    if key in aliases:
        # For PDT/MDT we want the sum of both caps, not just one.
        if key in ("physical damage taken", "magic damage taken"):
            total = v or 0
            for a in aliases[key]:
                total += stats.get(a, 0) or 0
            return total if total != 0 else None
        for a in aliases[key]:
            v2 = stats.get(a)
            if v2 is not None:
                return v2
    return None


def draw_stats_panel(surface, x, y, job, stats, scale=1.0):
    """Render the fixed 7×5 + 4×2 stats grid at (x, y)."""
    cell_w  = max(32, int(STATS_CELL_W * scale))
    cell_h  = max(20, int(STATS_CELL_H * scale))
    elem_w  = max(44, int(STATS_ELEM_CELL_W * scale))
    pad     = max(3,  int(STATS_PAD    * scale))
    title_h = max(16, int(STATS_TITLE_H * scale))
    gap     = max(2,  int(STATS_SECTION_GAP * scale))
    panel_w, panel_h = stats_panel_size(scale)

    pygame.draw.rect(surface, COL_PANEL,    (x, y, panel_w, panel_h), border_radius=4)
    pygame.draw.rect(surface, COL_SLOT_BDR, (x, y, panel_w, panel_h), 1, border_radius=4)

    # Title bar.
    pygame.draw.rect(surface, COL_EV_HEADER,
                     (x + 1, y + 1, panel_w - 2, title_h - 1), border_radius=3)
    # Accent stripe AFTER the title bar so it remains visible across the
    # title bar's left edge (otherwise the title bar paints over it).
    draw_accent_stripe(surface, x, y, panel_h, ACCENT_STATS)
    title_font = get_font("Consolas", 12 * scale, bold=True)
    tlabel = "STATISTICS"
    t_surf = title_font.render(tlabel, True, COL_EV_TITLE)
    surface.blit(t_surf, (x + 6, y + (title_h - t_surf.get_height()) // 2))
    pygame.draw.line(surface, COL_SLOT_BDR,
                     (x + 1, y + title_h),
                     (x + panel_w - 2, y + title_h))

    f_label = get_font("Consolas", 9  * scale)
    f_value = get_font("Consolas", 11 * scale, bold=True)

    # ── Main 7×5 grid ────────────────────────────────────────────────────────
    grid_y0 = y + title_h + pad
    for ri, row in enumerate(STATS_GRID_ROWS):
        ry = grid_y0 + ri * cell_h
        for ci, (label, key) in enumerate(row):
            cx = x + pad + ci * cell_w
            # Subtle cell separators every other column/row.
            pygame.draw.rect(surface, (45, 50, 60),
                             (cx, ry, cell_w, cell_h), 1)

            # Top line: label.
            lbl = f_label.render(label, True, (160, 170, 185))
            surface.blit(lbl, (cx + (cell_w - lbl.get_width()) // 2, ry + 1))

            # Bottom line: value.
            val = _resolve_stat_value(key, stats)
            txt, col = _fmt_stat_value(key, val)
            v_surf = f_value.render(txt, True, col)
            surface.blit(v_surf,
                         (cx + (cell_w - v_surf.get_width()) // 2,
                          ry + cell_h - v_surf.get_height() - 1))

    # ── Elemental 4×2 grid below ────────────────────────────────────────────
    # Each element label gets tinted with that element's traditional FFXI
    # menu color so the row reads at a glance. Colors are softened from
    # pure RGB so they don't clash with the dark panel background.
    ELEM_COLOR = {
        "fire":    (240, 130, 90),    # red-orange
        "ice":     (140, 200, 240),   # pale cyan
        "wind":    (160, 220, 160),   # green
        "earth":   (200, 170, 110),   # tan
        "thunder": (210, 180, 240),   # violet
        "water":   (130, 170, 230),   # blue
        "light":   (240, 230, 180),   # warm white
        "dark":    (175, 155, 200),   # muted purple
    }
    elem_y0 = grid_y0 + len(STATS_GRID_ROWS) * cell_h + gap
    for ri, row in enumerate(STATS_ELEM_ROWS):
        ry = elem_y0 + ri * cell_h
        for ci, (label, key) in enumerate(row):
            cx = x + pad + ci * elem_w
            pygame.draw.rect(surface, (45, 50, 60),
                             (cx, ry, elem_w, cell_h), 1)

            label_color = ELEM_COLOR.get(key, (160, 170, 185))
            lbl = f_label.render(label, True, label_color)
            surface.blit(lbl, (cx + (elem_w - lbl.get_width()) // 2, ry + 1))

            val = _resolve_stat_value(key, stats)
            txt, col = _fmt_stat_value(key, val)
            v_surf = f_value.render(txt, True, col)
            surface.blit(v_surf,
                         (cx + (elem_w - v_surf.get_width()) // 2,
                          ry + cell_h - v_surf.get_height() - 1))

    # ── Resist + Speed boxes: right of elements, stacked vertically ────────
    # Original layout was a single SPEED box spanning both element rows.
    # We split it: top half = "Resist" (elemental resistance from Carols
    # and Bar spells), bottom half = "Speed" (movement speed, original).
    # Both use the same label/value font sizes as the regular stat cells
    # so the right-hand column visually matches the rest of the table.
    elem_total_w = STATS_ELEM_COLS * elem_w
    main_total_w = STATS_GRID_COLS * cell_w
    box_x = x + pad + elem_total_w
    box_w = max(0, main_total_w - elem_total_w)
    full_h = len(STATS_ELEM_ROWS) * cell_h
    if box_w > 30:  # only draw if there's room
        # Slightly larger than f_value but still proportional, for the
        # case where there's a SINGLE element resist (icon + value beside
        # it). When multiple elements are squeezed in, we use f_value
        # directly to leave room for the icons.
        f_value_lg = get_font("Consolas", 13 * scale, bold=True)

        # ── Resist (top half) ──────────────────────────────────────────
        resist_h = full_h // 2
        resist_y = elem_y0
        pygame.draw.rect(surface, (45, 50, 60),
                         (box_x, resist_y, box_w, resist_h), 1)
        # Label at top of cell (matches regular stat cells).
        r_lbl = f_label.render("Resist", True, (160, 170, 185))
        surface.blit(r_lbl,
                     (box_x + (box_w - r_lbl.get_width()) // 2,
                      resist_y + 1))

        # Pull active resists from stats['resist'] dict. Keys are
        # element names (fire/ice/wind/earth/thunder/water/light/dark).
        # Filter to non-zero entries — empty dict = label only.
        resist_dict = stats.get("resist") if isinstance(stats, dict) else None
        active = []
        if isinstance(resist_dict, dict):
            for k, v in resist_dict.items():
                try:
                    iv = int(v)
                except (TypeError, ValueError):
                    continue
                if iv != 0:
                    active.append((k, iv))

        # Vertical region BELOW the label, where icon(s) + value go.
        body_y = resist_y + r_lbl.get_height() + 2
        body_h = resist_h - (r_lbl.get_height() + 2) - 1

        if not active:
            # Empty: label-only state, nothing more to draw.
            pass
        elif len(active) == 1:
            # Single element: icon + value side-by-side, centered in body.
            elem_name, elem_val = active[0]
            icon_size = max(12, int(body_h * 0.85))
            icon_surf = get_mob_icon_scaled(elem_name, icon_size)
            if icon_surf is None and elem_name == "thunder":
                icon_surf = get_mob_icon_scaled("lightning", icon_size)
            elif icon_surf is None and elem_name == "lightning":
                icon_surf = get_mob_icon_scaled("thunder", icon_size)

            v_txt = ("+" if elem_val > 0 else "") + str(elem_val)
            v_surf = f_value_lg.render(v_txt, True,
                                       (140, 230, 140) if elem_val > 0
                                       else (230, 140, 140))
            gap_px = max(3, int(3 * scale))
            content_w = (icon_surf.get_width() if icon_surf else 0) \
                        + gap_px + v_surf.get_width()
            cx_start = box_x + (box_w - content_w) // 2
            cy_mid   = body_y + body_h // 2
            if icon_surf is not None:
                surface.blit(icon_surf,
                             (cx_start,
                              cy_mid - icon_surf.get_height() // 2))
                v_x = cx_start + icon_surf.get_width() + gap_px
            else:
                v_x = cx_start
            surface.blit(v_surf,
                         (v_x, cy_mid - v_surf.get_height() // 2))
        else:
            # Multiple elements: row of small icons across the body,
            # summed value below them.
            shown = active[:4]
            n = len(shown)
            icon_size = max(10, min(int(body_h * 0.50),
                                    (box_w - 12) // n))
            total_icon_w = icon_size * n + 2 * (n - 1)
            ix = box_x + (box_w - total_icon_w) // 2
            iy = body_y
            for elem_name, _ in shown:
                isurf = get_mob_icon_scaled(elem_name, icon_size)
                if isurf is None and elem_name == "thunder":
                    isurf = get_mob_icon_scaled("lightning", icon_size)
                elif isurf is None and elem_name == "lightning":
                    isurf = get_mob_icon_scaled("thunder", icon_size)
                if isurf is not None:
                    surface.blit(isurf, (ix, iy))
                ix += icon_size + 2
            total_val = sum(v for _, v in active)
            v_txt = ("+" if total_val > 0 else "") + str(total_val)
            v_surf = f_value.render(v_txt, True,
                                    (140, 230, 140) if total_val > 0
                                    else (230, 140, 140))
            surface.blit(v_surf,
                         (box_x + (box_w - v_surf.get_width()) // 2,
                          iy + icon_size + 1))

        # ── Speed (bottom half) ────────────────────────────────────────
        speed_y = elem_y0 + resist_h
        speed_h = full_h - resist_h
        pygame.draw.rect(surface, (45, 50, 60),
                         (box_x, speed_y, box_w, speed_h), 1)
        # Label at top of cell.
        sp_lbl = f_label.render("SPEED", True, (160, 170, 185))
        surface.blit(sp_lbl,
                     (box_x + (box_w - sp_lbl.get_width()) // 2,
                      speed_y + 1))
        # Value at bottom.
        sp_val = _resolve_stat_value("movement speed", stats)
        sp_txt, sp_col = _fmt_stat_value("movement speed", sp_val)
        sv_surf = f_value.render(sp_txt, True, sp_col)
        surface.blit(sv_surf,
                     (box_x + (box_w - sv_surf.get_width()) // 2,
                      speed_y + speed_h - sv_surf.get_height() - 1))


def draw_equip_viewer(surface, x, y, slots, scale=1.0):
    """Draw a 4x4 equipment grid starting at (x, y), scaled by `scale`.

    `slots` is a list of 16 ints (item ids, 0 = empty).
    Side effect: updates the module-level equip_slot_rects dict mapping
    slot index → pygame.Rect for mouse hit-testing.
    """
    global equip_slot_rects
    equip_slot_rects = {}
    panel_w, panel_h, slot_size, title_h = equip_panel_size(scale)

    # Outer panel
    pygame.draw.rect(surface, COL_PANEL,    (x, y, panel_w, panel_h), border_radius=4)
    pygame.draw.rect(surface, COL_SLOT_BDR, (x, y, panel_w, panel_h), 1, border_radius=4)

    # Title bar
    title_font = get_font("Consolas", 12 * scale)
    pygame.draw.rect(surface, COL_EV_HEADER, (x + 1, y + 1, panel_w - 2, title_h - 1), border_radius=3)
    # Accent stripe AFTER the title bar so it paints over the title-bar's
    # left edge — otherwise the title bar (which spans the full inner
    # width starting at x+1) covers the stripe near the top of the panel.
    draw_accent_stripe(surface, x, y, panel_h, ACCENT_EQUIP)
    # Show the gearswap set name when known. Two channels can populate it:
    #
    #   SET   - the literal set/file path gearswap selected. Authoritative.
    #           Pushed by gearswap via `//ow set <path>` immediately after
    #           it commits a gear swap, so it always reflects what's on
    #           the character right now.
    #   STATE - a "<state>.<mode>.<weapon>" fallback for older configs
    #           that don't call //ow set. Pushed via `//ow state <s>`.
    #
    # We prefer SET over STATE: STATE re-evaluates on events that don't
    # swap any gear (aftermath gain/loss, sub-state transitions, etc.),
    # which would otherwise make the header cycle between the real set
    # and a stale fallback after every weapon-skill or buff change.
    #
    # If only STATE is available we still display it (some users haven't
    # added `//ow set` to their gearswap), but trim the trailing weapon
    # segment of the dotted label since that's the noisy bit.
    if gearswap_set:
        title_text = gearswap_set
    elif gearswap_state:
        if "." in gearswap_state:
            title_text = gearswap_state.rsplit(".", 1)[0]
        else:
            title_text = gearswap_state
    else:
        title_text = "EQUIPMENT"
    # Truncate to fit available width (panel minus padding).
    avail_w = panel_w - 12
    t_render = title_font.render(title_text, True, COL_EV_TITLE)
    if t_render.get_width() > avail_w:
        _cut = title_text
        while _cut and title_font.render(_cut + "…", True, COL_EV_TITLE).get_width() > avail_w:
            _cut = _cut[:-1]
        title_text = (_cut + "…") if _cut else title_text[:1]
        t_render = title_font.render(title_text, True, COL_EV_TITLE)
    surface.blit(t_render, (x + 6, y + (title_h - t_render.get_height()) // 2))
    pygame.draw.line(surface, COL_SLOT_BDR,
                     (x + 1, y + title_h),
                     (x + panel_w - 2, y + title_h))

    gy = y + title_h + 1                           # grid top
    icon_px   = max(16, slot_size - 4)             # leave 2px padding per side
    label_font = get_font("Consolas", max(8, int(9 * scale)))

    for i in range(16):
        col = i % EV_COLS
        row = i // EV_COLS
        sx  = x + 1 + col * slot_size
        sy  = gy   + row * slot_size
        item_id = slots[i] if i < len(slots) else 0

        equip_slot_rects[i] = pygame.Rect(sx, sy, slot_size, slot_size)

        # Cell background + border
        cell_col = COL_SLOT_FULL if item_id else COL_SLOT_BG
        pygame.draw.rect(surface, cell_col, (sx, sy, slot_size, slot_size))
        pygame.draw.rect(surface, COL_SLOT_BDR, (sx, sy, slot_size, slot_size), 1)

        if item_id:
            icon = get_icon_scaled(item_id, icon_px)
            if icon is not None:
                # Centre icon in the cell.
                ix = sx + (slot_size - icon_px) // 2
                iy = sy + (slot_size - icon_px) // 2
                surface.blit(icon, (ix, iy))
            else:
                # Icon file missing — fall back to showing the item id in the cell
                # so you can see something's equipped even before extraction catches up.
                txt = label_font.render(str(item_id), True, COL_SLOT_TEXT)
                surface.blit(txt, (sx + 3, sy + 3))

            # Stack count overlay (currently only the ammo slot sends this).
            # Matches EquipViewer addon's convention: small white number in
            # the corner of the cell, shadowed for readability over icons.
            _cnt = equip_counts.get(i)
            if _cnt and _cnt > 0:
                _cnt_font = get_font("Consolas",
                                     max(9, int(slot_size * 0.30)),
                                     bold=True)
                _cnt_text = str(_cnt)
                _cnt_surf = _cnt_font.render(_cnt_text, True, (255, 255, 255))
                # 1px drop-shadow for contrast against any icon.
                _shad = _cnt_font.render(_cnt_text, True, (0, 0, 0))
                _tx = sx + slot_size - _cnt_surf.get_width() - 2
                _ty = sy + slot_size - _cnt_surf.get_height() - 1
                surface.blit(_shad,     (_tx + 1, _ty + 1))
                surface.blit(_cnt_surf, (_tx, _ty))
        else:
            # Empty slot: dim slot label as placeholder.
            lbl = label_font.render(SLOT_LABELS[i], True, COL_SLOT_EMPTY)
            surface.blit(lbl, (sx + (slot_size - lbl.get_width()) // 2,
                               sy + (slot_size - lbl.get_height()) // 2))


def draw_item_tooltip(surface, mx, my, info, screen_w, screen_h):
    """Draw a minimal tooltip at (mx, my) for the given item info dict.
    Shows just the item name — keeps things clean since deeper stats aren't
    reliably available locally.
    """
    if not info:
        return
    name = info.get("name", "") or f"Item #{info.get('item_id', 0)}"
    if not name:
        return

    pad_x, pad_y = 8, 5
    f_name = get_font("Consolas", 13, bold=True)
    name_surf = f_name.render(name, True, (255, 240, 180))

    total_w = name_surf.get_width()  + pad_x * 2
    total_h = name_surf.get_height() + pad_y * 2

    # Position: bottom-right of cursor by default, flip if off-screen.
    tx = mx + 14
    ty = my + 14
    if tx + total_w > screen_w:
        tx = max(0, mx - total_w - 14)
    if ty + total_h > screen_h:
        ty = max(0, screen_h - total_h - 2)

    # Drop-shadow panel + border.
    shadow = pygame.Surface((total_w, total_h), pygame.SRCALPHA)
    shadow.fill((0, 0, 0, 200))
    surface.blit(shadow, (tx, ty))
    pygame.draw.rect(surface, (80, 80, 100),
                     (tx, ty, total_w, total_h), 1, border_radius=4)

    surface.blit(name_surf, (tx + pad_x, ty + pad_y))


def draw_ability_tooltip(surface, mx, my, entry, screen_w, screen_h):
    """Draw a tooltip for a mob ability hovered in the target card.
    `entry` is a dict from mob_abilities.json tp_moves, with keys:
    name, class, type, target, area, effect, shadows.
    Wraps effect text to a reasonable width."""
    if not entry:
        return
    name = entry.get("name", "")
    if not name:
        return
    effect = (entry.get("effect") or "").strip()
    meta_bits = []
    for k in ("class", "type", "target", "area", "shadows"):
        v = (entry.get(k) or "").strip()
        if v:
            meta_bits.append(f"{k.title()}: {v}")
    meta_line = " | ".join(meta_bits) if meta_bits else ""

    pad_x, pad_y = 8, 6
    max_width_px = 420  # tooltip cap
    f_name = get_font("Consolas", 13, bold=True)
    f_meta = get_font("Consolas", 10)
    f_body = get_font("Consolas", 11)

    name_surf = f_name.render(name, True, (255, 240, 180))

    # Wrap effect text into lines that fit inside max_width_px - 2*pad_x.
    def _wrap(text, font, max_w):
        lines = []
        for para in (text or "").split("\n"):
            words = para.split()
            if not words:
                lines.append("")
                continue
            line = words[0]
            for w in words[1:]:
                test = line + " " + w
                if font.render(test, True, (0, 0, 0)).get_width() <= max_w:
                    line = test
                else:
                    lines.append(line)
                    line = w
            lines.append(line)
        return lines

    wrap_w = max_width_px - pad_x * 2
    # Meta line may be wider than the tooltip: wrap it at " | " boundaries.
    meta_surfs = []
    if meta_line:
        meta_parts = meta_line.split(" | ")
        cur = ""
        for piece in meta_parts:
            candidate = (cur + " | " + piece) if cur else piece
            if f_meta.render(candidate, True, (0, 0, 0)).get_width() <= wrap_w:
                cur = candidate
            else:
                if cur:
                    meta_surfs.append(f_meta.render(cur, True, (180, 200, 230)))
                cur = piece
        if cur:
            meta_surfs.append(f_meta.render(cur, True, (180, 200, 230)))
    body_lines = _wrap(effect, f_body, wrap_w) if effect else []
    body_surfs = [f_body.render(ln, True, (230, 230, 230)) for ln in body_lines]

    # Content width — whichever line is widest, clamped to max_width_px.
    content_w = name_surf.get_width()
    for ms in meta_surfs:
        content_w = max(content_w, ms.get_width())
    for bs in body_surfs:
        content_w = max(content_w, bs.get_width())
    content_w = min(content_w, wrap_w)

    total_w = content_w + pad_x * 2
    total_h = name_surf.get_height() + pad_y * 2
    for ms in meta_surfs:
        total_h += ms.get_height() + 2
    if body_surfs:
        total_h += 4 + sum(s.get_height() for s in body_surfs) + 2 * (len(body_surfs) - 1)

    # Position: bottom-right of cursor by default, flip if off-screen.
    tx = mx + 14
    ty = my + 14
    if tx + total_w > screen_w:
        tx = max(0, mx - total_w - 14)
    if ty + total_h > screen_h:
        ty = max(0, screen_h - total_h - 2)

    shadow = pygame.Surface((total_w, total_h), pygame.SRCALPHA)
    shadow.fill((0, 0, 0, 215))
    surface.blit(shadow, (tx, ty))
    pygame.draw.rect(surface, (80, 80, 100),
                     (tx, ty, total_w, total_h), 1, border_radius=4)

    yy = ty + pad_y
    surface.blit(name_surf, (tx + pad_x, yy))
    yy += name_surf.get_height() + 2
    for ms in meta_surfs:
        surface.blit(ms, (tx + pad_x, yy))
        yy += ms.get_height() + 2
    if body_surfs:
        yy += 2
        for bs in body_surfs:
            surface.blit(bs, (tx + pad_x, yy))
            yy += bs.get_height() + 2



# ── GearSwap index init ─────────────────────────────────────────────────────
# Load the saved gearswap folder path from disk and build the initial
# referenced-items index. Done here, after all helpers are defined,
# so a missing or malformed gearswap folder won't block earlier setup.
gearswap_folder_path = _load_gearswap_path()
if gearswap_folder_path:
    _refresh_gearswap_index()
else:
    print("[OmniWatch] no gearswap folder configured "
          "(Settings → Inventory → Gearswap folder)")


# ── Main loop ────────────────────────────────────────────────────────────────
running = True
clock   = pygame.time.Clock()

while running:
    screen.fill(COL_BG)

    # Reset clickable hyperlink regions — they'll be rebuilt as we draw.
    click_targets.clear()
    # Reset mob-ability hover regions.
    _mob_ability_rects.clear()
    _party_buff_icon_rects.clear()
    # Reset hotbar editor anchor — set during the buttons panel render
    # if it happens this frame; if not, the editor is skipped at draw
    # time so we don't reuse stale geometry from last frame.
    _hotbar_editor_anchor = None

    now = time.time()
    if now - last_flash > 0.5:
        flash      = not flash
        last_flash = now

    # ── Receive UDP data ─────────────────────────────────────────────────────
    try:
        data, _ = sock.recvfrom(8192)
        raw      = data.decode()

        party_data = []
        ally1_data = []
        ally2_data = []
        for m in raw.strip(";").split(";"):
            if not m:
                continue
            parts = m.split(",")
            if len(parts) < 5:
                continue
            name, hp, hpp, mp, tp = parts[:5]
            buffs_raw  = parts[5] if len(parts) > 5 else ""
            # Each buff entry is either "id:label" (new wire format,
            # addon v1.7+) or "label" (legacy, no icon possible).
            # Build two parallel lists: names for classify()/text rendering,
            # and ids (or None) for the icon-grid renderer. The 'x2'
            # multiplier suffix stays attached to the label.
            buff_names = []
            buff_ids   = []
            for raw in buffs_raw.split("|"):
                if not raw:
                    continue
                # id:label split — only the FIRST colon counts in case the
                # label itself ever contains one (defensive; FFXI buff
                # names don't currently).
                colon = raw.find(":")
                if colon > 0 and raw[:colon].lstrip("-").isdigit():
                    bid = int(raw[:colon])
                    nm  = raw[colon + 1:]
                else:
                    bid = None
                    nm  = raw
                buff_names.append(nm)
                buff_ids.append(bid)

            # New optional fields (addon v1.6+): main_job, main_level, sub_job, sub_level.
            # Older addon versions won't have these — fall back to empty / 0.
            mj  = parts[6] if len(parts) > 6 else ""
            mjl = parts[7] if len(parts) > 7 else "0"
            sj  = parts[8] if len(parts) > 8 else ""
            sjl = parts[9] if len(parts) > 9 else "0"
            # 11th field (optional): zone-local mob index for this party
            # member. Used to detect when a mob is targeting them.
            midx = parts[10] if len(parts) > 10 else "0"
            # 12th field (optional): entity ID of this party member.
            # Used to match against a mob's claim_id.
            pid = parts[11] if len(parts) > 11 else "0"
            # 13th field (optional): group ID. 0=main party, 1=alliance 1,
            # 2=alliance 2. Defaults to 0 for older addon versions.
            grp = parts[12] if len(parts) > 12 else "0"
            # 14th + 15th fields (optional): pet name + pet HP percent.
            # Empty name and 0 hpp = no pet. Older addon versions won't
            # send these — fall back to defaults so they look like
            # "no pet" to the renderer. Pet HP only comes as percent
            # (windower exposes hpp on mobs, not absolute hp).
            pet_name = parts[13] if len(parts) > 13 else ""
            pet_hpp  = parts[14] if len(parts) > 14 else "0"
            # 16th field (optional, addon v1.7+): pet TP. Older addon
            # versions don't send it; default to 0 so the panel just
            # shows HP% without a TP suffix.
            pet_tp   = parts[15] if len(parts) > 15 else "0"

            def _as_int(s, default=0):
                try:    return int(s)
                except: return default

            entry = {
                "name": name,
                "hp": _as_int(hp), "hpp": _as_int(hpp),
                "mp": _as_int(mp), "tp":  _as_int(tp),
                "buffs": buff_names,
                # Parallel list of buff IDs (or None for legacy entries
                # without an id prefix). Indexes line up with `buffs`.
                # Used by the icon-grid renderer to look up status icons;
                # text-mode rendering ignores it entirely.
                "buff_ids": buff_ids,
                "main_job":  mj,
                "main_lvl":  _as_int(mjl),
                "sub_job":   sj,
                "sub_lvl":   _as_int(sjl),
                "mob_index": _as_int(midx),
                "player_id": _as_int(pid),
                "group_id":  _as_int(grp),
                "pet_name":  pet_name,
                "pet_hpp":   _as_int(pet_hpp),
                "pet_tp":    _as_int(pet_tp),
            }
            g = entry["group_id"]
            if g == 1:
                ally1_data.append(entry)
            elif g == 2:
                ally2_data.append(entry)
            else:
                party_data.append(entry)
    except Exception as e:
        # Silent except was masking parse errors; surface them now.
        if "Resource temporarily unavailable" not in str(e) and "10035" not in str(e):
            print(f"[OmniWatch] party parse error: {type(e).__name__}: {e}")

    # Drain ALL queued equipment-id packets each frame, not just the
    # first. With GearSwap doing precast/midcast/aftercast in rapid
    # succession, multiple packets can queue up between our frames; if
    # we only consume one per loop iteration, displayed gear lags
    # behind reality (visible to the user as stale gear sticking on
    # the panel for a beat after the swap actually happened in-game).
    # The latest packet wins — `equip_data` is overwritten each pass,
    # so consuming all queued packets and keeping the last is the
    # correct fix.
    try:
        while True:
            edata, _ = sock_equip.recvfrom(4096)
            parts    = edata.decode().split("|")
            new_equip = []
            for i in range(16):
                if i < len(parts):
                    try:    new_equip.append(int(parts[i]))
                    except: new_equip.append(0)
                else:
                    new_equip.append(0)
            equip_data = new_equip
    except Exception:
        # Empty socket buffer (BlockingIOError / "Resource temporarily
        # unavailable") is the normal exit. Other exceptions also
        # caught here so a malformed packet doesn't kill the receive
        # loop for the rest of the session.
        pass

    # Drain rich equip metadata. One packet per slot, sent on change.
    try:
        while True:
            rdata, _ = sock_equip_rich.recvfrom(4096)
            raw = rdata.decode(errors="replace")
            rparts = raw.split("|")
            if len(rparts) < 2:
                continue
            # Lightweight extension: COUNT|slot|item_id|count
            if rparts[0] == "COUNT":
                try:
                    _sidx = int(rparts[1])
                    _cnt  = int(rparts[3]) if len(rparts) > 3 else 0
                except (ValueError, IndexError):
                    continue
                if _cnt > 0:
                    equip_counts[_sidx] = _cnt
                else:
                    equip_counts.pop(_sidx, None)
                continue
            try:
                slot_idx = int(rparts[0])
                item_id  = int(rparts[1])
            except ValueError:
                continue
            if item_id == 0:
                equip_rich.pop(slot_idx, None)
                equip_counts.pop(slot_idx, None)
                continue
            name  = rparts[2] if len(rparts) > 2 else ""
            try:    ilvl = int(rparts[3]) if len(rparts) > 3 else 0
            except: ilvl = 0
            jobs  = rparts[4] if len(rparts) > 4 else ""
            cat   = rparts[5] if len(rparts) > 5 else ""
            try:    lvl = int(rparts[6]) if len(rparts) > 6 else 0
            except: lvl = 0
            augs  = [rparts[i] for i in range(7, min(11, len(rparts)))
                     if rparts[i]]
            equip_rich[slot_idx] = {
                "item_id":  item_id,
                "name":     name,
                "ilvl":     ilvl,
                "jobs":     jobs,
                "category": cat,
                "level":    lvl,
                "augments": augs,
            }
    except Exception:
        pass

    # Drain stats socket. Each packet begins with "BEGIN\n" followed by
    # lines: "PLAYER|<n>|<main>|<sub>" and "STAT|<key>|<value>".
    # Full table replacement semantics (always reset before applying).
    try:
        while True:
            sdata, _ = sock_stats.recvfrom(65536)
            raw = sdata.decode(errors="replace")
            if not raw.startswith("BEGIN"):
                continue
            new_stats = {}
            new_name, new_mj, new_sj = player_self_name, player_self_mjob, player_self_sjob
            for line in raw.split("\n"):
                if line.startswith("PLAYER|"):
                    pparts = line.split("|", 3)
                    if len(pparts) >= 4:
                        new_name = pparts[1]
                        new_mj   = pparts[2]
                        new_sj   = pparts[3]
                    continue
                if not line.startswith("STAT|"):
                    continue
                parts = line.split("|", 2)
                if len(parts) != 3:
                    continue
                key = parts[1].strip().lower()
                if not key or len(key) >= 64:
                    continue
                try:
                    val = float(parts[2])
                    if val == int(val):
                        val = int(val)
                except ValueError:
                    continue
                new_stats[key] = val
            player_stats.clear()
            player_stats.update(new_stats)
            player_self_name = new_name
            player_self_mjob = new_mj
            player_self_sjob = new_sj
            # Diagnostic: confirm we got new stats and what defense is.
            # This fires once per accepted STATS packet.
            print(f"[OmniWatch] stats received: {len(new_stats)} keys, "
                  f"defense={new_stats.get('defense')}")

            # Per-character storage: when the logged-in character changes
            # (or first becomes known), update current_char_name. If the
            # user hasn't manually picked a different "view" character,
            # follow the live one — reloading layout/settings/etc. for
            # them. This also fires on first PLAYER packet after launch.
            if new_name and new_name != current_char_name:
                _on_char_change(new_name)
    except Exception:
        pass

    # Drain target socket — may have multiple packets buffered, keep the last.
    # Packet format: "<main_part>||<sub_part>" where each part is either
    # empty (= no target) or "name|id|hpp|family|zone_id|distance".
    try:
        while True:
            tdata, _ = sock_target.recvfrom(1024)
            raw = tdata.decode()
            # Split main vs sub. '||' is used because neither field will
            # contain two consecutive pipes on its own.
            if "||" in raw:
                main_raw, sub_raw = raw.split("||", 1)
            else:
                main_raw, sub_raw = raw, ""

            def _parse_segment(seg):
                """Return a target dict or None if segment is empty or
                represents a null target (entity id 0)."""
                if not seg:
                    return None
                p = seg.split("|")
                # Lua side replaces '||' (consecutive empty fields) with
                # '|~|' to avoid colliding with the main/sub '||'
                # delimiter. Decode the placeholder back to empty here.
                p = ["" if x == "~" else x for x in p]
                if len(p) < 3:
                    return None
                try:    tid = int(p[1])
                except: tid = 0
                # Entity id 0 is the world/null — NEVER a valid target.
                # The lua side can occasionally emit a partial mob struct
                # with id=0 when get_mob_by_target('st') returns a stub
                # rather than nil, which slips past the empty-string
                # check above. Treat it as 'no target' here.
                if tid == 0:
                    return None
                try:    hpp = int(p[2])
                except: hpp = 0
                try:    family_id = int(p[3]) if len(p) > 3 else 0
                except: family_id = 0
                try:    zone_id = int(p[4]) if len(p) > 4 else 0
                except: zone_id = 0
                try:    dist = float(p[5]) if len(p) > 5 else 0.0
                except: dist = 0.0
                # 7th field (optional): target_index — the zone-local
                # mob index of who this mob is targeting. 0 = not aggro'd.
                try:    target_index = int(p[6]) if len(p) > 6 else 0
                except: target_index = 0
                # 8th field (optional): claim_id — entity ID of the
                # player/pet that has claim on this mob. 0 = unclaimed.
                try:    claim_id = int(p[7]) if len(p) > 7 else 0
                except: claim_id = 0
                # 9th field (optional): is_pc — 1 if this is a player
                # character, 0 if a mob. Used to suppress mob ability
                # lookups when the player has themselves or a party
                # member targeted (e.g. "Wormfood" matching worm family).
                try:    is_pc = int(p[8]) if len(p) > 8 else 0
                except: is_pc = 0
                # 10th field (optional): kind — 'mob' / 'trust' / 'pc'.
                # Trusts (spawn_type 14) get their own card sourced from
                # data/trusts.json (similar shape to mob_abilities.json).
                # If absent (older lua), derive from is_pc for back-compat.
                kind = p[9] if len(p) > 9 and p[9] else (
                    "pc" if is_pc else "mob"
                )
                # 11th field (optional): race — Hume, Elvaan, Tarutaru,
                # Mithra, Galka. Only set for PC kind. Used as the family
                # line on PC target cards (e.g. "Hume · Adventurer").
                race = p[10].strip() if len(p) > 10 else ""
                # 12th-14th fields (PC kind only): main_job, sub_job, title.
                # main_job/sub_job are formatted "JOBxx" where xx is level
                # (e.g. "BRD99"). title is the full English title string
                # (e.g. "Champion of the Goddess"). Title is only sent for
                # the player character self (we cannot read other PCs'
                # titles via Windower).
                pc_main_job = p[11].strip() if len(p) > 11 else ""
                pc_sub_job  = p[12].strip() if len(p) > 12 else ""
                pc_title    = p[13].strip() if len(p) > 13 else ""
                # 15th field (PC kind only): race+sex key for icon lookup.
                # Lua sends 'HumeMale', 'HumeFemale', 'ElvaanMale',
                # 'ElvaanFemale', 'TarutaruMale', 'TarutaruFemale',
                # 'Mithra' (always F), 'Galka' (always M).
                # Used by resolve_target_card_data to set the family key
                # for the target-card icon lookup, so PCs show race/sex
                # icons just like mobs show family icons.
                pc_race_key = p[14].strip() if len(p) > 14 else ""
                return {
                    "name":         p[0],
                    "id":           tid,
                    "hpp":          hpp,
                    "family_id":    family_id,
                    "zone_id":      zone_id,
                    "distance":     dist,
                    "target_index": target_index,
                    "claim_id":     claim_id,
                    "is_pc":        is_pc,
                    "kind":         kind,
                    "race":         race,
                    "pc_main_job":  pc_main_job,
                    "pc_sub_job":   pc_sub_job,
                    "pc_title":     pc_title,
                    "pc_race_key":  pc_race_key,
                }

            new_main = _parse_segment(main_raw)
            new_sub  = _parse_segment(sub_raw)

            target_info = new_main
            if new_main is not None:
                target_sticky    = new_main
                last_target_time = time.time()

            target_info_st = new_sub
            if new_sub is not None:
                target_sticky_st    = new_sub
                last_target_time_st = time.time()
    except Exception:
        pass

    # Drain zone socket — keep the last valid packet.
    try:
        while True:
            zdata, _ = sock_zone.recvfrom(1024)
            raw = zdata.decode()
            if raw == "":
                continue
            parts = raw.split("|")
            if len(parts) >= 6:
                try:    zid = int(parts[0])
                except: zid = 0
                zname = parts[1]
                try:    mapi = int(parts[2])
                except: mapi = 0
                try:    px_ = float(parts[3])
                except: px_ = 0.0
                try:    py_ = float(parts[4])
                except: py_ = 0.0
                try:    pz_ = float(parts[5])
                except: pz_ = 0.0
                # Weather id added in v2 of the zone packet. Older lua
                # versions (or the empty heartbeat right after load) won't
                # have it, so default to 0 = None when missing.
                if len(parts) >= 7:
                    try:    wid = int(parts[6])
                    except: wid = 0
                else:
                    wid = 0
                # Map-grid position string ("(J-6)" style) from
                # windower.ffxi.get_position(). Defaults to empty.
                if len(parts) >= 8:
                    pos_grid = parts[7]
                else:
                    pos_grid = ""
                zone_info["zone_id"]   = zid
                zone_info["zone_name"] = zname
                zone_info["map_index"] = mapi
                zone_info["x"] = px_
                zone_info["y"] = py_
                zone_info["z"] = pz_
                zone_info["weather"] = wid
                zone_info["pos_str"] = pos_grid
                # Reset the "Zone Time" header counter on transition.
                # First sight of any zone (last_seen is None) also
                # counts so the timer starts ticking immediately on
                # initial load instead of staying frozen.
                if zid and zid != _last_seen_zone_id:
                    zone_entered_at = time.time()
                    _last_seen_zone_id = zid
    except Exception:
        pass

    # Drain mob-status socket. APPLY/REMOVE/CLEAR events from lua.
    try:
        while True:
            sdata, _ = sock_status.recvfrom(1024)
            raw = sdata.decode(errors="replace").strip()
            if not raw:
                continue
            parts = raw.split("|")
            cmd = parts[0]
            try:
                if cmd == "APPLY" and len(parts) >= 7:
                    tgt      = int(parts[1])
                    spell_id = int(parts[2])
                    eff_id   = int(parts[3])
                    duration = int(parts[4])
                    actor_id = int(parts[5])
                    is_buff  = (parts[6] == "1")
                    sp       = _spells_by_id.get(spell_id) or {}
                    sp_name  = sp.get("name") or f"Spell #{spell_id}"
                    mob_statuses.setdefault(tgt, {})[eff_id] = {
                        "spell_id":   spell_id,
                        "spell_name": sp_name,
                        "applied_at": time.time(),
                        "duration":   duration,
                        "actor_id":   actor_id,
                        "is_buff":    is_buff,
                    }
                elif cmd == "REMOVE" and len(parts) >= 3:
                    tgt    = int(parts[1])
                    eff_id = int(parts[2])
                    if tgt in mob_statuses and eff_id in mob_statuses[tgt]:
                        del mob_statuses[tgt][eff_id]
                        if not mob_statuses[tgt]:
                            del mob_statuses[tgt]
                elif cmd == "CLEAR" and len(parts) >= 2:
                    tgt = int(parts[1])
                    if tgt == 0:
                        mob_statuses.clear()
                    elif tgt in mob_statuses:
                        del mob_statuses[tgt]
            except Exception:
                continue
    except Exception:
        pass

    # Drain gearswap state socket. Most recent wins.
    try:
        while True:
            gdata, _ = sock_gs.recvfrom(1024)
            raw = gdata.decode(errors="replace").strip()
            if not raw:
                continue
            parts = raw.split("|", 1)
            if len(parts) < 2:
                continue
            tag, value = parts[0], parts[1].strip()
            # Clamp label length so it doesn't overflow the header —
            # but ONLY for tags that carry header-displayed labels.
            # CFGWIZ payloads contain comma-separated key=value pairs
            # that can run several hundred chars; truncating them
            # silently drops fields, which manifested as "the wizard
            # only remembers all_songs."
            if tag not in ("CFGWIZ",) and len(value) > 64:
                value = value[:64]
            if tag == "SET":
                # Authoritative source: gearswap explicitly told us what
                # set was equipped. Wins over STATE in the renderer.
                gearswap_set = value
                gearswap_label = value
            elif tag == "STATE":
                # Fallback: gearswap re-evaluated state but didn't change
                # gear (or didn't call //ow set). Don't overwrite SET.
                gearswap_state = value
                # Update legacy gearswap_label only if SET hasn't been
                # received (so old code that reads gearswap_label still
                # gets a value when SET is unavailable).
                if not gearswap_set:
                    gearswap_label = value
            elif tag == "GIL":
                try:
                    gearswap_gil = int(value)
                except ValueError:
                    pass
            elif tag == "CFGWIZ":
                # Config wizard. Lua sends "open|<flat-fields>" with the
                # current user_config state; we open the modal. Format of
                # value is a single string starting with the action verb;
                # for "open" the rest is the comma-separated flat fields.
                vsep = value.find("|")
                action = value if vsep < 0 else value[:vsep]
                payload = "" if vsep < 0 else value[vsep + 1:]
                if action == "open":
                    # Parse "bards.self.all_songs=4,bards.self.carol=2,..."
                    # into cfgwiz_state. Unknown keys (ally entries we
                    # don't render) are still kept verbatim and round-
                    # tripped on Save unchanged, so chat-edited allies
                    # aren't lost.
                    cfgwiz_state.clear()
                    for pair in payload.split(","):
                        if "=" not in pair:
                            continue
                        k, v = pair.split("=", 1)
                        try:
                            cfgwiz_state[k.strip()] = int(v.strip())
                        except ValueError:
                            pass
                    # Pre-fill anything missing for self entries so the
                    # widgets always render even if Lua sent a sparse
                    # payload.
                    for fk in (CFGWIZ_BARD_FAMILIES_ROW1
                               + CFGWIZ_BARD_FAMILIES_ROW2):
                        cfgwiz_state.setdefault(f"bards.self.{fk}", 0)
                    cfgwiz_state.setdefault(
                        "corsairs.self.phantom_roll", 0)
                    for fk in CFGWIZ_GEO_FAMILIES:
                        cfgwiz_state.setdefault(f"geomancers.self.{fk}", 0)
                    # Unity Rank defaults to 1 (highest) when Lua didn't
                    # send a value — matches the loader's default and
                    # gives players the "best" stat scaling out of the
                    # box. Clamp to 1..11 in case a stale config has an
                    # out-of-range value.
                    ur = cfgwiz_state.get("player.unity_rank", 1)
                    try:
                        ur = int(ur)
                    except (TypeError, ValueError):
                        ur = 1
                    cfgwiz_state["player.unity_rank"] = max(1, min(11, ur))
                    cfgwiz_visible = True
                    print("[OmniWatch] cfgwiz opened with",
                          len(cfgwiz_state), "fields")
                elif action == "close":
                    _cfgwiz_close()
            elif tag == "SETUP":
                # Setup mode: forces all panels to render with mock data
                # so the user can drag them into position without needing
                # to be in combat / have a target / have party members.
                # Setup also implicitly unlocks panels; exiting setup re-
                # locks them so accidental clicks during gameplay don't
                # nudge anything.
                vlow = value.lower()
                prev_setup = setup_mode
                if vlow == "on":
                    setup_mode = True
                elif vlow == "off":
                    setup_mode = False
                else:  # "toggle" or anything else
                    setup_mode = not setup_mode
                # Lock follows setup mode automatically.
                panels_locked = not setup_mode
                print(f"[OmniWatch] setup_mode = {setup_mode}, "
                      f"panels_locked = {panels_locked}")
                # When setup mode toggles, force recast and buff panels to
                # re-derive their position from their saved anchor. This
                # protects against any drift that could accumulate during
                # the dragging→exit-setup transition (e.g. clamp logic
                # using a stale panel size). Top-left anchor means the
                # panel's TOP edge stays exactly where you set it,
                # regardless of how many entries are visible.
                if prev_setup != setup_mode:
                    if recast_anchor is not None:
                        recast_pos = list(resolve_anchor(
                            recast_anchor, 0, 0, WIDTH, HEIGHT))
                        # 0,0 size args are fine for 'tl' anchor — it
                        # ignores them. For other anchors the next render
                        # frame would correct.
                    if buff_anchor is not None:
                        buff_pos = list(resolve_anchor(
                            buff_anchor, 0, 0, WIDTH, HEIGHT))
                    print(f"[OmniWatch] re-asserted: "
                          f"recast_anchor={recast_anchor} "
                          f"recast_pos={recast_pos} "
                          f"buff_anchor={buff_anchor} "
                          f"buff_pos={buff_pos}")

                    # Setup-OFF cleanup: drop the mock target stickies
                    # and their mock status entries so the fake cards
                    # disappear when leaving setup. Mock target ids
                    # are fixed (see the setup-mode mock injection
                    # block); we delete only those keys, leaving any
                    # real entries alone. Without this the "MockTarget"
                    # / "PartyMate" cards would keep showing until the
                    # user actually targets something else in-game.
                    if not setup_mode:
                        _MOCK_TGT_ID_MAIN = 0x010F0000
                        _MOCK_TGT_ID_SUB  = 0x01000001
                        for _mid in (_MOCK_TGT_ID_MAIN, _MOCK_TGT_ID_SUB):
                            mob_statuses.pop(_mid, None)
                        # Also drop mocks that we injected onto REAL target
                        # ids (when the user had a target before entering
                        # setup, the mock-injection path used the real id
                        # as the key). _setup_mocked_statuses tracked them
                        # so we know exactly which ones to clear.
                        for _mid in _setup_mocked_statuses:
                            if _mid not in (_MOCK_TGT_ID_MAIN, _MOCK_TGT_ID_SUB):
                                mob_statuses.pop(_mid, None)
                        _setup_mocked_statuses.clear()
                        # Drop the stickies if they're still pointing at
                        # our mocks (identified by the mock id). If real
                        # targeting happened during setup, the stickies
                        # will already point elsewhere — leave those.
                        if (target_sticky is not None
                                and target_sticky.get("id") == _MOCK_TGT_ID_MAIN):
                            target_sticky = None
                            target_info = None
                        if (target_sticky_st is not None
                                and target_sticky_st.get("id") == _MOCK_TGT_ID_SUB):
                            target_sticky_st = None
                            target_info_st = None
                        # Mock weather: only injected if zone_info had
                        # weather=0; revert if it's still our mock value
                        # (5 = Heat Wave). Real weather updates arrive
                        # via zone packets so a real value would have
                        # overwritten ours already.
                        if zone_info.get("weather") == 5:
                            zone_info["weather"] = 0
                        # Mock equipment / DPS state / sparkline: leave
                        # alone. Real packets will overwrite them on
                        # the next tick (equip arrives every gear
                        # change; DPS arrives every 0.5s during combat;
                        # sparkline naturally rolls over its 60s window).
                        # Mock party / alliance: leave alone for the
                        # same reason — windower party update will
                        # replace them.
                        print("[OmniWatch] cleared mock target / "
                              "weather data on setup exit")
            elif tag == "LOCK":
                # Explicit panel lock toggle. Independent of setup mode —
                # but setup mode auto-unlocks regardless of what this is
                # set to.
                vlow = value.lower()
                if vlow == "on":
                    panels_locked = True
                elif vlow == "off":
                    panels_locked = False
                else:  # toggle
                    panels_locked = not panels_locked
                print(f"[OmniWatch] panels_locked = {panels_locked}")
            elif tag == "BUTTONS":
                # Button panel control. Subcommands:
                #   on / off / toggle  → flip visibility
                #   reload             → re-read omniwatch_buttons.json
                vlow = value.lower()
                if vlow == "on":
                    buttons_panel_visible = True
                elif vlow == "off":
                    buttons_panel_visible = False
                elif vlow == "reload":
                    reload_buttons_config()
                else:   # toggle
                    buttons_panel_visible = not buttons_panel_visible
                if vlow != "reload":
                    print(f"[OmniWatch] buttons_panel_visible = "
                          f"{buttons_panel_visible}")
    except Exception:
        pass

    # Drain cast-event socket. Shows "Casting X..." (pulsing yellow) then
    # "Casts X" (solid red, fading).
    try:
        while True:
            cdata, _ = sock_cast.recvfrom(1024)
            raw = cdata.decode(errors="replace").strip()
            if not raw:
                continue
            parts = raw.split("|", 3)
            cmd = parts[0]
            try:
                if cmd == "CAST_START" and len(parts) >= 4:
                    mid  = int(parts[1])
                    kind = parts[2]
                    nm   = parts[3][:48]
                    st   = mob_cast_state.setdefault(mid, {"casting": None, "last_cast": None})
                    # Out-of-order packet guard: cat=8 (spell begin) and
                    # cat=4 (spell finish) sometimes arrive in reversed
                    # order. If we just got a CAST_DONE for the same name
                    # in the last 2 seconds, this CAST_START is stale —
                    # ignore it so we don't get stuck in "Casting..." for
                    # a spell that's already complete.
                    lc = st.get("last_cast")
                    if lc and lc.get("name") == nm and (time.time() - lc.get("done_at", 0)) < 2.0:
                        continue
                    st["casting"] = {"name": nm, "kind": kind, "started": time.time()}
                elif cmd == "CAST_DONE" and len(parts) >= 4:
                    mid  = int(parts[1])
                    kind = parts[2]
                    nm   = parts[3][:48]
                    st   = mob_cast_state.setdefault(mid, {"casting": None, "last_cast": None})
                    st["casting"]   = None
                    st["last_cast"] = {"name": nm, "kind": kind, "done_at": time.time()}
                elif cmd == "CAST_CANCEL" and len(parts) >= 2:
                    mid = int(parts[1])
                    if mid in mob_cast_state:
                        mob_cast_state[mid]["casting"] = None
            except Exception:
                continue
    except Exception:
        pass

    # Drain timer socket — recast countdowns and self-buff durations.
    # RECAST_BATCH replaces recast_state wholesale per packet.
    try:
        while True:
            tdata, _ = sock_timers.recvfrom(8192)
            raw = tdata.decode(errors="replace")
            if not raw:
                continue
            lines = raw.split("\n")
            if not lines:
                continue
            tag_line = lines[0]
            tag_parts = tag_line.split("\t")
            tag = tag_parts[0]
            if tag == "RECAST_BATCH":
                # Header format: 'RECAST_BATCH\t<sort_order>'
                # sort_order is one of 'asc' (default), 'desc', 'cast'.
                sort_order = tag_parts[1] if len(tag_parts) > 1 else "asc"
                if sort_order not in ("asc", "desc", "cast"):
                    sort_order = "asc"
                recast_sort_order = sort_order
                # Replace recast_state with the entries in this batch.
                new_state = {}
                _now = time.time()
                for ln in lines[1:]:
                    if not ln:
                        continue
                    fields = ln.split("\t")
                    if len(fields) < 4:
                        continue
                    kind = fields[0]
                    try:
                        rid = int(fields[1])
                    except ValueError:
                        continue
                    nm = fields[2]
                    try:
                        secs = float(fields[3])
                    except ValueError:
                        continue
                    # 5th field: lua-side os.clock() at last cast. Used
                    # only for sort_order='cast'. Same lua process → same
                    # monotonic baseline, so direct comparison is fine.
                    cast_ts = 0.0
                    if len(fields) >= 5:
                        try:
                            cast_ts = float(fields[4])
                        except ValueError:
                            pass
                    new_state[(kind, rid)] = {
                        "name": nm, "secs": secs, "updated_at": _now,
                        "cast_ts": cast_ts,
                    }
                # Detect entries that were cooling down last batch but
                # aren't this batch — those just hit ready. Pop them into
                # the flash dict so the panel briefly blinks them green
                # before they disappear entirely.
                for old_key, old_val in recast_state.items():
                    if old_key not in new_state:
                        # Only flash entries we'd actually been tracking
                        # (peak > 0). Setup mocks have peak seeded so they
                        # qualify; real casts always do.
                        _recast_flashes[old_key] = {
                            "name": old_val.get("name", "?"),
                            "ready_at": _now,
                        }
                recast_state = new_state
            elif tag == "BUFF_BATCH":
                # Buff timer wire format. Two layouts supported:
                #   v1 (legacy):  buff\t<bid>\t<name>\t<secs>\t<src>     (5 fields)
                #   v2 (slot):    buff\t<slot>\t<bid>\t<name>\t<secs>\t<src>  (6 fields)
                # v2 lets us distinguish March #1 from March #2 (same bid,
                # different slots, distinct timers). buff_state is keyed by
                # whatever uniqueness is available -- slot for v2, bid for v1
                # (with v1 collapsing duplicates the same way the lua side
                # used to).
                sort_order = tag_parts[1] if len(tag_parts) > 1 else "asc"
                if sort_order not in ("asc", "desc"):
                    sort_order = "asc"
                buff_sort_order = sort_order
                new_buffs = {}
                _now = time.time()
                for ln in lines[1:]:
                    if not ln:
                        continue
                    fields = ln.split("\t")
                    if len(fields) >= 6:
                        # v2: slot-aware
                        try:
                            slot = int(fields[1])
                            bid  = int(fields[2])
                        except ValueError:
                            continue
                        nm = fields[3]
                        try:
                            secs = float(fields[4])
                        except ValueError:
                            continue
                        src = fields[5]
                        # Key by slot to support buff stacking (March x2)
                        new_buffs[slot] = {
                            "slot": slot, "buff_id": bid,
                            "name": nm, "secs": secs, "source": src,
                            "updated_at": _now,
                        }
                    elif len(fields) >= 5:
                        # v1: legacy (lua addon not yet updated)
                        try:
                            bid = int(fields[1])
                        except ValueError:
                            continue
                        nm = fields[2]
                        try:
                            secs = float(fields[3])
                        except ValueError:
                            continue
                        src = fields[4]
                        # Key by bid for backward compat. Note: stacking won't
                        # work in this branch -- lua side needs the slot fix.
                        new_buffs[bid] = {
                            "buff_id": bid,
                            "name": nm, "secs": secs, "source": src,
                            "updated_at": _now,
                        }
                # Detect entries that left state since last batch (wore off
                # before being sent). Pop them into _buff_flashes for the
                # red expiry-flash. Note: old-version mocks have negative ids,
                # which still flow through as keys here.
                for old_key, old_val in buff_state.items():
                    if old_key not in new_buffs:
                        _buff_flashes[old_key] = {
                            "name": old_val.get("name", "?"),
                            "ready_at": _now,
                            "source": old_val.get("source", "self"),
                        }
                buff_state = new_buffs
    except Exception:
        pass

    # Drain inventory socket. Lua emits one INV_BAG packet per bag,
    # then INV_END as a sentinel. We accumulate into _inv_buffer and
    # only swap into inventory_state on INV_END so the dropdown UI
    # never reads a half-built snapshot.
    try:
        while True:
            idata, _ = sock_inv.recvfrom(16384)
            raw = idata.decode(errors="replace").strip()
            if not raw:
                continue
            if raw.startswith("INV_BAG|"):
                # Format: INV_BAG|<bag_name>|<count>|<id>,<count>,<name>;...
                parts = raw.split("|", 3)
                if len(parts) < 4:
                    continue
                bag_name = parts[1]
                # body is parts[3]; count in parts[2] is informational.
                body = parts[3]
                items_in_bag = []
                if body:
                    for ent in body.split(";"):
                        if not ent:
                            continue
                        fields = ent.split(",", 2)
                        if len(fields) < 2:
                            continue
                        try:
                            iid = int(fields[0])
                            cnt = int(fields[1])
                        except ValueError:
                            continue
                        nm = fields[2] if len(fields) >= 3 else ""
                        items_in_bag.append({
                            "id": iid, "count": cnt, "name": nm,
                        })
                _inv_buffer[bag_name] = items_in_bag
            elif raw.startswith("INV_END|"):
                # Atomic swap. Replace inventory_state with the new
                # snapshot and clear the staging buffer for the next
                # round. Update the timestamp so we know freshness.
                inventory_state = dict(_inv_buffer)
                _inv_buffer = {}
                inventory_last_update_ts = time.time()
            elif raw.startswith("SIM_INV|"):
                # Sim inventory snapshot: per-slot list of items the
                # current job can equip. Format details:
                #   SIM_INV|MAIN_JOB|NIN
                #   SIM_INV|SLOT|main|<id>:<name>;<id>:<name>;...
                #   SIM_INV|SLOT|head|...
                #   ...
                #   SIM_INV|END
                # We accumulate into _sim_inv_buffer and atomically swap
                # into _inv_for_sim on END so the dropdowns never see
                # half-built data.
                parts = raw.split("|")
                if len(parts) < 2:
                    continue
                sub = parts[1]
                if sub == "MAIN_JOB" and len(parts) >= 3:
                    _sim_inv_buffer["main_job"] = parts[2]
                elif sub == "SLOT" and len(parts) >= 4:
                    # New entry format: <id>@<bag>:<idx>:<tag>:<name>
                    # - id, bag, idx ints
                    # - tag is short augment summary ("DEX/Acc/WSD") or empty
                    # - name is item English name (already sanitized lua-side)
                    # Multiple instances of the same item id may appear when
                    # the user has multiple augmented copies (e.g. capes).
                    slot = parts[2]
                    body = "|".join(parts[3:])
                    items = []
                    if body:
                        for ent in body.split(";"):
                            if not ent:
                                continue
                            # Split id from rest at '@'.
                            try:
                                id_str, rest = ent.split("@", 1)
                                iid = int(id_str)
                            except ValueError:
                                continue
                            # rest = "<bag>:<idx>:<tag>:<name>"
                            fields = rest.split(":", 3)
                            if len(fields) != 4:
                                continue
                            try:
                                bag_id = int(fields[0])
                                idx_id = int(fields[1])
                            except ValueError:
                                continue
                            tag  = fields[2]
                            name = fields[3]
                            items.append({
                                "id": iid, "bag": bag_id, "idx": idx_id,
                                "tag": tag, "name": name,
                            })
                    _sim_inv_buffer.setdefault("by_slot", {})[slot] = items
                elif sub == "EQUIPPED" and len(parts) >= 3:
                    # New format: SIM_INV|EQUIPPED|<slot>:<id>@<bag>:<idx>;...
                    # Parse into staging dict; seeded into sim_state on END
                    # if sim_state.equipment is currently empty.
                    body = "|".join(parts[2:])
                    eq_map = {}
                    if body:
                        for ent in body.split(";"):
                            if not ent:
                                continue
                            try:
                                slot_name, rest = ent.split(":", 1)
                                id_str, loc = rest.split("@", 1)
                                bag_str, idx_str = loc.split(":", 1)
                                iid = int(id_str)
                                bag_id = int(bag_str)
                                idx_id = int(idx_str)
                            except (ValueError, IndexError):
                                continue
                            if iid > 0:
                                eq_map[slot_name] = {
                                    "id": iid, "bag": bag_id, "idx": idx_id,
                                }
                    _sim_inv_buffer["equipped"] = eq_map
                elif sub == "FP" and len(parts) >= 3:
                    # Fingerprint index: <bag>:<idx>:<id>:<fingerprint>;...
                    # Used for nickname lookup (key = item_id + fingerprint).
                    # The lua side encoded inner '|' as '~' so we split
                    # cleanly here; treat fingerprint as opaque.
                    body = "|".join(parts[2:])
                    fp_map = {}  # (bag, idx) → {"id": iid, "fp": "..."}
                    if body:
                        for ent in body.split(";"):
                            if not ent:
                                continue
                            ef = ent.split(":", 3)
                            if len(ef) != 4:
                                continue
                            try:
                                bag_id = int(ef[0])
                                idx_id = int(ef[1])
                                iid    = int(ef[2])
                            except ValueError:
                                continue
                            fp_map[(bag_id, idx_id)] = {
                                "id": iid, "fp": ef[3].replace("~", "|"),
                            }
                    _sim_inv_buffer["fingerprints"] = fp_map
                elif sub == "END":
                    # Swap staging buffers into the live dicts.
                    _inv_for_sim["main_job"]  = _sim_inv_buffer.get("main_job", "")
                    _inv_for_sim["by_slot"]   = _sim_inv_buffer.get("by_slot", {})
                    _inv_for_sim["equipped"]  = _sim_inv_buffer.get("equipped", {})
                    _inv_for_sim["fingerprints"] = _sim_inv_buffer.get("fingerprints", {})
                    # Seed sim_state.equipment from currently-equipped gear
                    # ONLY if the sim equipment dict is empty (first snapshot
                    # after activation). Subsequent snapshots don't clobber
                    # the user's in-progress sim picks.
                    if (sim_window_open
                            and not sim_state.get("equipment")
                            and _inv_for_sim.get("equipped")):
                        sim_state["equipment"] = {
                            k: dict(v) for k, v in _inv_for_sim["equipped"].items()
                        }
                        # Push the seeded equipment to lua so it knows
                        # about the overrides from the first compute tick.
                        for slot_key, ref in sim_state["equipment"].items():
                            wire_val = _sim_format_equip_ref(ref)
                            _sim_send("equip", wire_val, slot_key)
                    _sim_inv_buffer = {
                        "main_job": "", "by_slot": {},
                        "equipped": {}, "fingerprints": {},
                    }
    except BlockingIOError:
        pass
    except Exception as e:
        # Swallow + log: don't let a malformed packet kill the frame.
        print(f"[OmniWatch] inventory drain error: {e!r}")

    # Drain DPS socket. Replaces dps_state/ws/mob wholesale per packet.
    # The 'TOGGLE_PANEL' control message flips dps_panel_visible. The
    # 'DPS_EMPTY' message clears state without hiding the panel.
    try:
        while True:
            ddata, _ = sock_dps.recvfrom(16384)
            raw = ddata.decode(errors="replace")
            if not raw:
                continue
            raw = raw.strip()
            if raw == "TOGGLE_PANEL":
                dps_panel_visible = not dps_panel_visible
                continue
            if raw == "DPS_EMPTY":
                dps_state = {}
                dps_ws_state = {}
                dps_mob_state = {}
                dps_last_update_ts = time.time()
                dps_history.clear()
                continue
            new_state = {}
            new_ws    = {}
            new_mob   = {}
            parse_failures = []   # (line_num, reason, raw_line) for diagnostic
            _enc_in_progress = None   # encounter packet block being assembled
            for ln_idx, ln in enumerate(raw.split("\n")):
                if not ln:
                    continue
                fields = ln.split("|")
                if not fields:
                    continue
                tag = fields[0]
                if tag == "DPS":
                    if len(fields) < 19:
                        parse_failures.append(
                            (ln_idx, f"DPS field count {len(fields)} < 19", ln))
                        continue
                    try:
                        src    = fields[1]
                        scope  = fields[2]
                        window = int(fields[3])
                        white  = int(fields[4])
                        magic  = int(fields[5])
                        ws     = int(fields[6])
                        hits   = int(fields[7])
                        misses = int(fields[8])
                        crits  = int(fields[9])
                        sp_ld  = int(fields[10])
                        sp_rs  = int(fields[11])
                        m_acc  = float(fields[12])
                        ma_acc = float(fields[13])
                        cr_pct = float(fields[14])
                        evd    = float(fields[15])
                        longest= int(fields[16])
                        total  = int(fields[17])
                        dps    = float(fields[18])
                        # v2 wire format: sc_total + skillchains as fields
                        # 19 and 20. Older lua emits 19 fields; default
                        # to 0 so the parser still accepts those.
                        sc_total    = int(fields[19]) if len(fields) > 19 else 0
                        skillchains = int(fields[20]) if len(fields) > 20 else 0
                    except (ValueError, IndexError) as e:
                        parse_failures.append(
                            (ln_idx, f"DPS parse error: {e}", ln))
                        continue
                    new_state[src] = {
                        "scope": scope, "window": window,
                        "white": white, "magic": magic, "ws": ws,
                        "sc": sc_total, "skillchains": skillchains,
                        "hits": hits, "misses": misses, "crits": crits,
                        "spells_landed": sp_ld, "spells_resisted": sp_rs,
                        "melee_acc": m_acc, "magic_acc": ma_acc,
                        "crit_pct": cr_pct, "evasion": evd,
                        "longest": longest, "total": total, "dps": dps,
                    }
                    dps_scope = scope
                elif tag == "WS":
                    if len(fields) < 6:
                        parse_failures.append(
                            (ln_idx, f"WS field count {len(fields)} < 6", ln))
                        continue
                    try:
                        src   = fields[1]
                        name  = fields[2]
                        count = int(fields[3])
                        wtot  = int(fields[4])
                        best  = int(fields[5])
                    except (ValueError, IndexError) as e:
                        parse_failures.append(
                            (ln_idx, f"WS parse error: {e}", ln))
                        continue
                    new_ws.setdefault(src, {})[name] = {
                        "count": count, "total": wtot, "best": best,
                    }
                elif tag == "MOB":
                    if len(fields) < 5:
                        parse_failures.append(
                            (ln_idx, f"MOB field count {len(fields)} < 5", ln))
                        continue
                    try:
                        src   = fields[1]
                        mname = fields[2]
                        mtot  = int(fields[3])
                        since = float(fields[4])
                    except (ValueError, IndexError) as e:
                        parse_failures.append(
                            (ln_idx, f"MOB parse error: {e}", ln))
                        continue
                    new_mob.setdefault(src, {})[mname] = {
                        "total": mtot, "since": since,
                    }
                elif tag == "ENCOUNTER_BEGIN":
                    # Per-mob encounter close: lua sends a multi-line
                    # block beginning with this tag, followed by ENC_DPS
                    # and ENC_WS lines, terminated by ENCOUNTER_END.
                    # We accumulate the in-progress block in the closure
                    # variable below. Format of the BEGIN line:
                    #   ENCOUNTER_BEGIN|<mob_id>|<mob_name>|<duration_s>
                    if len(fields) >= 4:
                        _enc_in_progress = {
                            "mob_id":   int(fields[1]) if fields[1].isdigit() else 0,
                            "mob_name": fields[2],
                            "duration": float(fields[3]),
                            "by_src":   {},
                            "ws_per_src": {},
                        }
                    else:
                        _enc_in_progress = None
                elif tag == "ENC_DPS":
                    # ENC_DPS|src|white|magic|ws|hits|misses|crits|sp_ld|sp_rs|
                    #        m_acc|mag_acc|cr_pct|longest|total|dps|sc_total|skillchains
                    # 17 fields after the tag = 18 total parts.
                    if _enc_in_progress is None or len(fields) < 18:
                        continue
                    try:
                        src = fields[1]
                        _enc_in_progress["by_src"][src] = {
                            "white":         int(fields[2]),
                            "magic":         int(fields[3]),
                            "ws":            int(fields[4]),
                            "hits":          int(fields[5]),
                            "misses":        int(fields[6]),
                            "crits":         int(fields[7]),
                            "spells_landed": int(fields[8]),
                            "spells_resisted": int(fields[9]),
                            "melee_acc":     float(fields[10]),
                            "magic_acc":     float(fields[11]),
                            "crit_pct":      float(fields[12]),
                            "longest":       int(fields[13]),
                            "total":         int(fields[14]),
                            "dps":           float(fields[15]),
                            "sc":            int(fields[16]),
                            "skillchains":   int(fields[17]),
                        }
                    except (ValueError, IndexError) as e:
                        print(f"[OmniWatch DPS] ENC_DPS parse error: {e!r} | {ln!r}")
                elif tag == "ENC_WS":
                    if _enc_in_progress is None or len(fields) < 6:
                        continue
                    try:
                        src   = fields[1]
                        name  = fields[2]
                        count = int(fields[3])
                        wtot  = int(fields[4])
                        best  = int(fields[5])
                        _enc_in_progress["ws_per_src"].setdefault(src, {})[name] = {
                            "count": count, "total": wtot, "best": best,
                        }
                    except (ValueError, IndexError) as e:
                        print(f"[OmniWatch DPS] ENC_WS parse error: {e!r} | {ln!r}")
                elif tag == "ENCOUNTER_END":
                    if _enc_in_progress is not None:
                        try:
                            log_encounter(_enc_in_progress)
                        except Exception as e:
                            print(f"[OmniWatch DPS] log_encounter failed: {e!r}")
                        _enc_in_progress = None
                else:
                    parse_failures.append(
                        (ln_idx, f"unknown tag {tag!r}", ln))
            # Parse failures are kept since they indicate a real wire-
            # format mismatch (silent killers if not surfaced). Successful
            # packet receipt is no longer logged — too chatty for normal
            # combat where the panel re-renders 2x/sec.
            if parse_failures:
                print(f"[OmniWatch DPS] {len(parse_failures)} parse "
                      f"failure(s) in this packet:")
                for line_num, reason, raw_ln in parse_failures[:5]:
                    print(f"  line {line_num}: {reason} | raw={raw_ln!r}")
            dps_state    = new_state
            dps_ws_state = new_ws
            dps_mob_state= new_mob
            dps_last_update_ts = time.time()
            # Sparkline history: append the 'me' DPS value, or 0 if
            # there's no me bucket. The deque caps at maxlen so old
            # samples drop off automatically.
            _me_dps = (new_state.get("me") or {}).get("dps", 0.0)
            dps_history.append((dps_last_update_ts, float(_me_dps)))
    except BlockingIOError:
        # Normal: no more packets queued.
        pass
    except Exception as _e:
        # Real exception worth seeing.
        print(f"[OmniWatch DPS] receive loop exception: {_e!r}")

    # Prune stale casting entries (safety: 15s without a finish).
    _now = time.time()
    _cast_prune = []
    for _mid, _s in mob_cast_state.items():
        if _s.get("casting") and _now - _s["casting"]["started"] > CAST_START_MAX:
            _s["casting"] = None
        if _s.get("last_cast") and _now - _s["last_cast"]["done_at"] > CAST_DONE_TTL:
            _s["last_cast"] = None
        if not _s.get("casting") and not _s.get("last_cast"):
            _cast_prune.append(_mid)
    for _m in _cast_prune:
        del mob_cast_state[_m]

    # Safety prune: drop any status older than 30 minutes. Wear-off chat
    # messages (handled lua-side → REMOVE events) are the primary way
    # entries go away; this only catches cases where we missed the message
    # (e.g. client disconnect during the wear-off, mob despawned without
    # death packet).
    _now = time.time()
    _prune_targets = []
    for _mob_id, _effs in mob_statuses.items():
        _expired = [_eid for _eid, _st in _effs.items()
                    if (_now - _st.get("applied_at", _now)) > 30 * 60]
        for _eid in _expired:
            del _effs[_eid]
        if not _effs:
            _prune_targets.append(_mob_id)
    for _m in _prune_targets:
        del mob_statuses[_m]

    # ── Setup mode: inject mock data so all panels render ───────────────────
    # When //ow setup is enabled, populate any empty data sources with mock
    # values so the user can position panels without needing combat / target
    # / party. We modify the in-frame globals; next frame either keeps mock
    # (setup still on) or reverts to real data (setup off).
    if setup_mode:
        # Mock party: ensure 6 members so every slot's panel renders. Don't
        # overwrite the real local player (slot 0) if we have it — they may
        # still want their own name showing. Pad missing slots with stand-ins.
        if not party_data:
            party_data = []
        while len(party_data) < 6:
            slot_idx = len(party_data)
            # Some slots get mock pets so the pet-line renderer is
            # exercised in setup mode. Real combat will override this.
            mock_pets = {
                0: ("Sharpshot Frame", 88),     # PUP
                3: ("Crude Raphie", 65),        # BST jug
            }
            pet_n, pet_h = mock_pets.get(slot_idx, ("", 0))
            party_data.append({
                "name":  ("YourName" if slot_idx == 0 else f"PartyMember{slot_idx}"),
                "hp":      2500,
                "hpp":     100,
                "mp":      400,
                "tp":      1000 if slot_idx == 0 else 250 * slot_idx,
                "buffs":   [],
                "main_job": ["PUP", "BRD", "PLD", "BST", "BLM", "BLU"][slot_idx],
                "main_lvl": 99,
                "sub_job":  ["DNC", "WHM", "WAR", "NIN", "RDM", "NIN"][slot_idx],
                "sub_lvl":  49,
                "mob_index": slot_idx,
                "player_id": 0,
                "group_id":  0,
                "pet_name":  pet_n,
                "pet_hpp":   pet_h,
            })

        # Mock alliance party 1: 6 members with rotating jobs, no buffs.
        if not ally1_data:
            ally1_data = []
        while len(ally1_data) < 6:
            slot_idx = len(ally1_data)
            ally1_data.append({
                "name":     f"Ally1Member{slot_idx}",
                "hp":       2500, "hpp": 100, "mp": 350, "tp": 100 * slot_idx,
                "buffs":    [],
                "main_job": ["DRK", "SAM", "MNK", "PUP", "DRG", "RUN"][slot_idx],
                "main_lvl": 99,
                "sub_job":  ["WAR", "NIN", "WAR", "DNC", "SAM", "PLD"][slot_idx],
                "sub_lvl":  49,
                "mob_index": 0, "player_id": 0,
                "group_id":  1,
            })

        # Mock alliance party 2: 6 more members for the second alliance.
        if not ally2_data:
            ally2_data = []
        while len(ally2_data) < 6:
            slot_idx = len(ally2_data)
            ally2_data.append({
                "name":     f"Ally2Member{slot_idx}",
                "hp":       2500, "hpp": 100, "mp": 350, "tp": 100 * slot_idx,
                "buffs":    [],
                "main_job": ["THF", "COR", "BST", "DNC", "GEO", "SCH"][slot_idx],
                "main_lvl": 99,
                "sub_job":  ["DNC", "WAR", "WHM", "WAR", "RDM", "RDM"][slot_idx],
                "sub_lvl":  49,
                "mob_index": 0, "player_id": 0,
                "group_id":  2,
            })

        # Mock equipment: fake set of common item ids spread across slots so
        # the equip viewer shows non-empty slots. Keep zeros where the user
        # may not have items so the slot-empty visuals still get a peek.
        if all(v == 0 for v in equip_data):
            # Sample ids that resolve in res.items: Naegling, Heishi etc.
            # Picking values that should be present in any FFXI install.
            equip_data = [20977, 21925, 0, 22279,
                          23732, 27518, 14813, 14739,
                          25792, 23734, 26199, 26182,
                          26258, 28428, 23735, 23655]

        # Mock target main: a plausible mob entry so STR/WK/Imm all render
        # something. Use a known family that's likely in mob_abilities.json.
        if target_sticky is None:
            target_sticky = {
                "name":   "MockTarget",
                "id":     0x010F0000,
                "hpp":    75,
                "family_id":    0,
                "zone_id":      0,
                "distance":     5.0,
                "target_index": 0,
                "claim_id":     0,
                "is_pc":  0,
                "kind":   "mob",
                "race":   "",
                "pc_main_job":  "",
                "pc_sub_job":   "",
                "pc_title":     "",
            }

        # Mock sub-target: a separate plausible PC so the SUB-TARGET card
        # also renders. Skip the suppression block by setting both stickies.
        if target_sticky_st is None:
            target_sticky_st = {
                "name":   "PartyMate",
                "id":     0x01000001,
                "hpp":    100,
                "family_id":    0,
                "zone_id":      0,
                "distance":     8.0,
                "target_index": 0,
                "claim_id":     0,
                "is_pc":  1,
                "kind":   "pc",
                "race":   "Hume",
                "pc_main_job":  "WHM99",
                "pc_sub_job":   "RDM49",
                "pc_title":     "",
            }

        # Force live-info pointers to point at stickies EVERY FRAME in setup
        # mode. Without this, the target UDP receiver sets target_info to
        # None when the player isn't actually targeting anything in-game,
        # which makes tc_alpha drop and the cards start fading — visible
        # as flashing while in setup. Stickies persist across frames; we
        # just keep the alpha at full by keeping the live pointer alive.
        target_info         = target_sticky
        target_info_st      = target_sticky_st
        last_target_time    = now
        last_target_time_st = now

        # Mock statuses (buffs + debuffs) on both target cards so the
        # buff/debuff side columns render in setup. Keyed by the mock
        # target id we set above. is_buff flags split them into the
        # two columns of draw_target_card. Each entry needs the full
        # status-dict shape (spell_id, spell_name, applied_at,
        # duration, actor_id, is_buff). Only inject when the target's
        # statuses dict is empty so real combat data isn't overridden.
        # We TRACK which ids got mocks (in the global _setup_mocked_statuses)
        # so the setup-off cleanup can clear them; otherwise mock buffs/
        # debuffs would persist on the target card forever after exiting
        # setup with a real target (the real mob never sends REMOVE| for
        # things it never had).
        _mock_now = time.time()
        _tgt_id_main = target_sticky["id"]
        if _tgt_id_main not in mob_statuses or not mob_statuses[_tgt_id_main]:
            mob_statuses[_tgt_id_main] = {
                # Debuffs (is_buff = False)
                2:   {"spell_id": 220, "spell_name": "Slow",
                      "applied_at": _mock_now - 12, "duration": 180,
                      "actor_id": 0, "is_buff": False},
                3:   {"spell_id": 230, "spell_name": "Paralyze",
                      "applied_at": _mock_now - 30, "duration": 120,
                      "actor_id": 0, "is_buff": False},
                14:  {"spell_id": 252, "spell_name": "Bio II",
                      "applied_at": _mock_now - 8,  "duration": 150,
                      "actor_id": 0, "is_buff": False},
                # Buffs (is_buff = True)
                40:  {"spell_id": 478, "spell_name": "Phalanx",
                      "applied_at": _mock_now - 60, "duration": 180,
                      "actor_id": 0, "is_buff": True},
                33:  {"spell_id": 511, "spell_name": "Magic Shield",
                      "applied_at": _mock_now - 5,  "duration": 60,
                      "actor_id": 0, "is_buff": True},
            }
            _setup_mocked_statuses.add(_tgt_id_main)
        _tgt_id_sub = target_sticky_st["id"]
        if _tgt_id_sub not in mob_statuses or not mob_statuses[_tgt_id_sub]:
            mob_statuses[_tgt_id_sub] = {
                # Sub-target is a PC in our mock; populate with the kind
                # of statuses you'd see on a party member (haste, regen,
                # plus a couple of debuffs they're suffering from).
                33:  {"spell_id": 57,  "spell_name": "Haste",
                      "applied_at": _mock_now - 90, "duration": 180,
                      "actor_id": 0, "is_buff": True},
                42:  {"spell_id": 110, "spell_name": "Regen II",
                      "applied_at": _mock_now - 30, "duration": 90,
                      "actor_id": 0, "is_buff": True},
                39:  {"spell_id": 105, "spell_name": "Refresh",
                      "applied_at": _mock_now - 20, "duration": 120,
                      "actor_id": 0, "is_buff": True},
                # Couple of debuffs to make the sub card exercise both columns.
                4:   {"spell_id": 254, "spell_name": "Silence",
                      "applied_at": _mock_now - 3,  "duration": 60,
                      "actor_id": 0, "is_buff": False},
                10:  {"spell_id": 270, "spell_name": "Poison",
                      "applied_at": _mock_now - 10, "duration": 90,
                      "actor_id": 0, "is_buff": False},
            }
            _setup_mocked_statuses.add(_tgt_id_sub)

        # Mock DPS: populate dps_state / dps_ws_state / dps_mob_state with
        # believable numbers so the panel exercises every formatter (k-suffix,
        # decimals, longest-hit, WS list, mob list) for layout tuning. Don't
        # overwrite real data if combat has been happening — only fill if
        # the relevant dict is empty.
        if not dps_state:
            dps_state = {
                "me": {
                    "scope":  "all",
                    "window": 300,
                    "white":  184320, "magic":  0,     "ws":  96400,
                    "sc":     32400,  "skillchains": 5,
                    "hits":   312,    "misses": 24,    "crits": 71,
                    "spells_landed": 0, "spells_resisted": 0,
                    "melee_acc": 92.9, "magic_acc": 0.0,
                    "crit_pct":  22.8, "evasion":   41.5,
                    "longest":   24180,
                    "total":     184320 + 96400 + 32400,
                    "dps":       (184320 + 96400 + 32400) / 300.0,
                },
                "Koru-Moru": {
                    "scope":  "all",
                    "window": 300,
                    "white":  0, "magic": 168400, "ws": 0,
                    "sc":     0, "skillchains": 0,
                    "hits":   0, "misses": 0,    "crits": 0,
                    "spells_landed": 14, "spells_resisted": 2,
                    "melee_acc": 0.0,  "magic_acc": 87.5,
                    "crit_pct":  0.0,  "evasion":   0.0,
                    "longest":   18420,
                    "total":     168400,
                    "dps":       168400 / 300.0,
                },
            }
            dps_scope = "all"
        if not dps_ws_state:
            dps_ws_state = {
                "me": {
                    "Savage Blade": {"count": 3, "total": 72180, "best": 31240},
                    "Blade: Hi":    {"count": 2, "total": 24220, "best": 13180},
                },
            }
        if not dps_mob_state:
            dps_mob_state = {
                "me": {
                    "Belaboring Wasp": {"total": 142800, "since": 3.4},
                    "Hellish Cesti":   {"total": 137920, "since": 18.7},
                },
                "Koru-Moru": {
                    "Belaboring Wasp": {"total": 92400, "since": 2.1},
                    "Hellish Cesti":   {"total": 76000, "since": 22.0},
                },
            }
        # Keep the panel's "live update" check happy so it doesn't dim itself.
        dps_last_update_ts = now

        # Seed sparkline with a synthetic curve so the trend line is
        # visible in setup. We push a wave-shaped series (sin + small
        # noise) that varies between roughly 600 and 1400 dps so the
        # sparkline reads as "active combat with peaks".
        if len(dps_history) < 30:
            import math as _math, random as _random
            _random.seed(42)   # repeatable for screenshots
            now_ts = time.time()
            for i in range(60):
                t = now_ts - (60 - i)
                base = 1000 + 400 * _math.sin(i * 0.25)
                jitter = _random.uniform(-80, 80)
                dps_history.append((t, max(50, base + jitter)))

        # Mock weather: pick a vivid double-intensity weather (Heat Wave)
        # so the header chip exercises the brightened-color path. Only
        # set when the live weather is None/0 so real weather isn't
        # overridden during setup.
        if zone_info.get("weather", 0) == 0:
            zone_info["weather"] = 5    # 5 = Heat Wave (Fire, double)

    # For any new party member, assign a default top-left anchor stacked
    # vertically. For existing members, resolve their saved anchor to an
    # absolute position based on the current window size.
    #
    # Anchors are keyed by name for the local player (so YOUR panel stays
    # put across sessions) but by slot for everyone else (so when party
    # composition changes — different trust, real player joining, etc. —
    # the slot positions persist instead of being orphaned to a name that
    # may never come back). The slot key is "p1".."p5" (party member 0
    # is always you, so we use your name; 1-5 are slot-based).
    def _anchor_key(slot_idx, nm):
        if slot_idx == 0:
            return nm  # local player keeps name-based key
        return "p%d" % slot_idx
    default_y = START_Y
    for slot_idx, m in enumerate(party_data):
        nm = m["name"]
        akey = _anchor_key(slot_idx, nm)
        if nm not in panel_scales:
            panel_scales[nm] = panel_scales.get(akey, 1.0)
        sc = max(MIN_SCALE, min(MAX_SCALE, panel_scales[nm]))
        panel_scales[nm] = sc
        rh = row_height(m, sc)
        pw = scaled_panel_dims(sc)["panel_w"]

        # Migrate: if there's no anchor under the slot key but there IS
        # one under the member's name, move it. Lets old layouts keep
        # working when you re-load with someone in the same slot.
        if akey not in panel_anchors and nm in panel_anchors and slot_idx != 0:
            panel_anchors[akey] = panel_anchors[nm]
        if akey not in panel_anchors:
            # New slot — default: stacked from top-left.
            panel_anchors[akey] = ["tl", PANEL_X, default_y]
        # Always keep panel_anchors[nm] in sync with the slot anchor so
        # the rest of the code (which still keys by name) reads the right
        # position. Skip for slot 0 since name == akey.
        if slot_idx != 0:
            panel_anchors[nm] = panel_anchors[akey]
        if nm not in panel_order:
            panel_order.append(nm)

        # Resolve anchor → absolute position. Skip when this panel is
        # currently being dragged: the drag handler writes positions
        # directly, and overwriting them here would cancel the drag
        # mid-motion (you'd see the cursor move but the panel snap back).
        if dragging_key != nm:
            x, y = resolve_anchor(panel_anchors[nm], pw, rh, WIDTH, HEIGHT)
            panel_positions[nm] = [x, y]

        default_y += rh + ROW_PAD

    # Equip viewer: default to bottom-left anchor if we've never placed it.
    equip_scale = max(MIN_SCALE, min(MAX_SCALE, equip_scale))
    ew, eh, _, _ = equip_panel_size(equip_scale)
    if equip_anchor is None:
        equip_anchor = ["bl", PANEL_X, PANEL_X]
    if dragging_key != "__equip__":
        ex, ey = resolve_anchor(equip_anchor, ew, eh, WIDTH, HEIGHT)
        if equip_pos is None:
            equip_pos = [ex, ey]
        else:
            equip_pos[0], equip_pos[1] = ex, ey
    elif equip_pos is None:
        # First frame ever and we're somehow already dragging — fall back
        # to anchor-derived position to avoid None deref later.
        equip_pos = list(resolve_anchor(equip_anchor, ew, eh, WIDTH, HEIGHT))

    # Stats panel: default to bottom-left, offset to the right of the
    # equipment panel so they don't overlap on first run.
    stats_scale = max(MIN_SCALE, min(MAX_SCALE, stats_scale))
    _stats_joblist = None  # layout is fixed; arg unused
    sw, sh = stats_panel_size(stats_scale, _stats_joblist)
    if stats_anchor is None:
        stats_anchor = ["bl", PANEL_X + ew + 8, PANEL_X]
    if dragging_key != "__stats__":
        sx, sy = resolve_anchor(stats_anchor, sw, sh, WIDTH, HEIGHT)
        if stats_pos is None:
            stats_pos = [sx, sy]
        else:
            stats_pos[0], stats_pos[1] = sx, sy
    elif stats_pos is None:
        stats_pos = list(resolve_anchor(stats_anchor, sw, sh, WIDTH, HEIGHT))

    # Target card: default to top-right anchor if never placed. Its size
    # depends on the current mob's ability count, but for anchoring purposes
    # we use the size at ability_count = 0 (smallest) — the visual grows
    # downward from the top-right corner, which keeps the top of the card
    # stable across mobs with different ability lists.
    target_scale = max(MIN_SCALE, min(MAX_SCALE, target_scale))
    # Resolve target type → ref/mobdb/family/abilities/aggro-flag.
    # Same helper is used for the sub-target below, so trusts and PCs
    # render identically in either slot.
    (_tc_ref, _tc_mobdb, _tc_fam,
     _tc_abils, _tc_achars, _tc_aggrow) = resolve_target_card_data(target_sticky)
    # Statuses on the current target (split into debuffs/buffs).
    _tc_tid = (target_sticky or {}).get("id", 0)
    _tc_stat = mob_statuses.get(_tc_tid, {}) if _tc_tid else {}
    _tc_has_db = any(not s.get("is_buff") for s in _tc_stat.values())
    _tc_has_bf = any(s.get("is_buff")     for s in _tc_stat.values())
    _tc_cstate = mob_cast_state.get(_tc_tid) if _tc_tid else None
    _tc_has_cast = bool(_tc_cstate and (_tc_cstate.get("casting") or _tc_cstate.get("last_cast")))
    _tc_kind = (target_sticky or {}).get("kind") or (
        "pc" if (target_sticky or {}).get("is_pc", 0) else "mob")
    _tc_cchars = len(((_tc_ref or {}).get("comments") or "").strip())
    tcw, tch = target_card_size(target_scale, _tc_abils, _tc_aggrow, _tc_aggrow,
                                has_debuffs=_tc_has_db, has_buffs=_tc_has_bf,
                                has_cast=_tc_has_cast, ability_chars=_tc_achars,
                                kind=_tc_kind, comments_chars=_tc_cchars)
    if target_anchor is None:
        target_anchor = ["tr", PANEL_X, HEADER_H + PANEL_X]
    if dragging_key != "__target__":
        tx, ty = resolve_anchor(target_anchor, tcw, tch, WIDTH, HEIGHT)
        if target_pos is None:
            target_pos = [tx, ty]
        else:
            target_pos[0], target_pos[1] = tx, ty
    elif target_pos is None:
        target_pos = list(resolve_anchor(target_anchor, tcw, tch, WIDTH, HEIGHT))

    # Sub-target card: default to sit directly below the main card, same
    # right-edge. Once the user drags it, their saved anchor is used.
    target_scale_st = max(MIN_SCALE, min(MAX_SCALE, target_scale_st))
    (_tc_ref_st, _tc_mobdb_st, _tc_fam_st,
     _tc_abils_st, _tc_achars_st,
     _tc_aggrow_st) = resolve_target_card_data(target_sticky_st)
    _tc_tid_st = (target_sticky_st or {}).get("id", 0)
    _tc_stat_st = mob_statuses.get(_tc_tid_st, {}) if _tc_tid_st else {}
    _tc_has_db_st = any(not s.get("is_buff") for s in _tc_stat_st.values())
    _tc_has_bf_st = any(s.get("is_buff")     for s in _tc_stat_st.values())
    _tc_cstate_st = mob_cast_state.get(_tc_tid_st) if _tc_tid_st else None
    _tc_has_cast_st = bool(_tc_cstate_st and (_tc_cstate_st.get("casting") or _tc_cstate_st.get("last_cast")))
    _tc_kind_st = (target_sticky_st or {}).get("kind") or (
        "pc" if (target_sticky_st or {}).get("is_pc", 0) else "mob")
    _tc_cchars_st = len(((_tc_ref_st or {}).get("comments") or "").strip())
    tcw_st, tch_st = target_card_size(target_scale_st, _tc_abils_st,
                                       _tc_aggrow_st, _tc_aggrow_st,
                                       has_debuffs=_tc_has_db_st,
                                       has_buffs=_tc_has_bf_st,
                                       has_cast=_tc_has_cast_st,
                                       ability_chars=_tc_achars_st,
                                       kind=_tc_kind_st,
                                       comments_chars=_tc_cchars_st)
    if target_anchor_st is None:
        # Directly below the main card's default position: add tch + a gap.
        target_anchor_st = ["tr", PANEL_X, HEADER_H + PANEL_X + tch + 8]
    if dragging_key != "__target_st__":
        tx_st, ty_st = resolve_anchor(target_anchor_st, tcw_st, tch_st, WIDTH, HEIGHT)
        if target_pos_st is None:
            target_pos_st = [tx_st, ty_st]
        else:
            target_pos_st[0], target_pos_st[1] = tx_st, ty_st
    elif target_pos_st is None:
        target_pos_st = list(resolve_anchor(target_anchor_st, tcw_st, tch_st,
                                             WIDTH, HEIGHT))

    # Optional safety clamp: even after anchor resolution, keep a graspable
    # strip on screen. Rare — only matters for absurdly tiny windows — but
    # harmless to apply.
    GRIP_VISIBLE = 40
    for nm, pos in panel_positions.items():
        sc = panel_scales.get(nm, 1.0)
        pw = scaled_panel_dims(sc)["panel_w"]
        pos[0] = max(GRIP_VISIBLE - pw, min(pos[0], WIDTH  - GRIP_VISIBLE))
        pos[1] = max(HEADER_H,          min(pos[1], HEIGHT - GRIP_VISIBLE))
    equip_pos[0] = max(GRIP_VISIBLE - ew, min(equip_pos[0], WIDTH  - GRIP_VISIBLE))
    equip_pos[1] = max(HEADER_H,          min(equip_pos[1], HEIGHT - GRIP_VISIBLE))

    # Build a lookup so we can access member data by name in the draw loop.
    members_by_name = {m["name"]: m for m in party_data}

    # ── Party rows ───────────────────────────────────────────────────────────
    # Draw in panel_order so the most-recently-dragged panel renders on top.
    # Drop any names that aren't in the current party data.
    panel_order = [n for n in panel_order if n in members_by_name]
    # Belt-and-braces: ensure every current member is in panel_order. If a
    # member has a saved position but somehow isn't in panel_order yet
    # (e.g. loaded from JSON but the initial add step missed them), append.
    for nm in members_by_name:
        if nm not in panel_order:
            panel_order.append(nm)

    for name in panel_order:
        m      = members_by_name[name]
        px, py = panel_positions[name]
        scale  = panel_scales.get(name, 1.0)
        d      = scaled_panel_dims(scale)
        rh     = row_height(m, scale)
        pw     = d["panel_w"]

        pygame.draw.rect(screen, COL_PANEL,  (px, py, pw, rh), border_radius=4)
        pygame.draw.rect(screen, COL_BORDER, (px, py, pw, rh), 1, border_radius=4)
        draw_accent_stripe(screen, px, py, rh, ACCENT_PARTY)

        bx = px + d["bars_x_off"]
        by = py + int(10 * scale)

        # Name + job/level stacked vertically, centred in the name column.
        # Pulse red if any current target (main or sub) is locked onto OR
        # claimed by this party member. We check two fields because
        # target_index is unreliable (sometimes 0 even on aggro'd mobs):
        #   - target_index matches member.mob_index
        #   - claim_id matches member.player_id
        member_idx = m.get("mob_index", 0)
        member_id  = m.get("player_id", 0)
        is_targeted = False
        for tgt in (target_info, target_info_st):
            if not tgt:
                continue
            if member_idx > 0 and tgt.get("target_index", 0) == member_idx:
                is_targeted = True
                break
            if member_id > 0 and tgt.get("claim_id", 0) == member_id:
                is_targeted = True
                break
        if is_targeted:
            # Pulse between (200,40,40) and (255,120,120) at ~1.5 Hz.
            t = time.time()
            phase = (math.sin(t * 6.0) + 1.0) * 0.5  # 0..1
            r = int(200 + (255 - 200) * phase)
            g = int( 40 + (120 -  40) * phase)
            b = int( 40 + (120 -  40) * phase)
            name_color = (r, g, b)
        else:
            name_color = COL_NAME
        name_surf = d["f_name"].render(m["name"], True, name_color)

        # Build "WAR75 / DNC37" (or just "WAR75" if no sub).
        mj, mjl = m.get("main_job", ""), m.get("main_lvl", 0)
        sj, sjl = m.get("sub_job",  ""), m.get("sub_lvl",  0)
        job_str = ""
        if mj:
            job_str = f"{mj}{mjl}" if mjl else mj
            if sj:
                job_str += f" / {sj}{sjl}" if sjl else f" / {sj}"
        job_surf = d["f_label"].render(job_str, True, COL_LABEL_DIM) if job_str else None

        # Pet line: "PetName 87% / 1500" — HP% colored by HP, TP value
        # in TP-bar colors (white→yellow→cyan as TP fills) so a critical
        # pet's HP and TP both read at a glance. TP only shown when > 0
        # (skips the noisy "0" suffix on idle / freshly-summoned pets).
        # Pet field comes from the lua side; older lua versions won't
        # send it (name="") so this is a no-op without a coordinated
        # update. pet_tp added in addon v1.7.
        pet_surfs = []   # list of (surf, color) drawn left-to-right
        pet_name = m.get("pet_name", "") or ""
        pet_hpp  = m.get("pet_hpp", 0)
        pet_tp_v = m.get("pet_tp",  0)
        if pet_name and setting("party_show_pets"):
            # Name + HP% in one chunk so they share color (HP-tinted on
            # crit, dim otherwise — keeps the row from looking busy).
            hp_text  = f"{pet_name} {pet_hpp}%"
            hp_color_ = hp_color(pet_hpp, flash) if pet_hpp < 75 else COL_LABEL_DIM
            pet_surfs.append(d["f_label"].render(hp_text, True, hp_color_))
            if pet_tp_v and pet_tp_v > 0:
                # Separator + TP in TP-bar color. Capped to 3000 like
                # the main TP bar; pet TP can technically exceed that
                # (overflows from JA), but it's rare.
                tp_text  = f" / TP {pet_tp_v}"
                tp_color_ = tp_color(min(pet_tp_v, 3000))
                pet_surfs.append(d["f_label"].render(tp_text, True, tp_color_))

        pet_h = max((s.get_height() for s in pet_surfs), default=0)
        total_h = (name_surf.get_height()
                   + (job_surf.get_height() + 2 if job_surf else 0)
                   + (pet_h + 2 if pet_surfs else 0))
        block_y = py + (rh - total_h) // 2
        screen.blit(name_surf, (px + int(8 * scale), block_y))
        cur_y = block_y + name_surf.get_height() + 2
        if job_surf:
            screen.blit(job_surf, (px + int(8 * scale), cur_y))
            cur_y += job_surf.get_height() + 2
        if pet_surfs:
            ix = px + int(8 * scale)
            for ps in pet_surfs:
                screen.blit(ps, (ix, cur_y))
                ix += ps.get_width()

        hc = hp_color(m["hpp"], flash)
        draw_bar(screen, bx, by,                          d["bar_w"], d["bar_h"], m["hpp"] / 100.0,         hc,     f"HP {m['hp']} ({m['hpp']}%)", d["f_bar_label"])
        draw_bar(screen, bx, by + d["bar_gap"],           d["bar_w"], d["bar_h"], min(m["mp"] / 1500, 1.0), COL_MP, f"MP {m['mp']}",                d["f_bar_label"])
        draw_bar(screen, bx, by + d["bar_gap"] * 2,       d["bar_w"], d["bar_h"], min(m["tp"] / 3000, 1.0), tp_color(m["tp"]), f"TP {m['tp']}",                d["f_bar_label"])

        # When 'specific_buff_names' is on AND this is the player's own
        # row, rebuild the buff name list so each instance shows its
        # specific tier (Honor March, Valor Minuet V) instead of the
        # generic shared name (March x2, Minuet x2). buff_state has the
        # specific names because buff_gain populated _ow_buff_pending_meta
        # with the spell-derived display name. We can only do this for
        # ourselves — for other party members we don't see the action
        # packets for spells cast on them.
        m_buffs    = m.get("buffs", [])
        m_buff_ids = m.get("buff_ids", [])
        if (setting("specific_buff_names")
                and m.get("name") == player_self_name
                and m_buff_ids):
            # Build {buff_id: [specific names from buff_state]} for self.
            spec_by_bid = {}
            for v in buff_state.values():
                bid = v.get("buff_id")
                nm  = v.get("name")
                if not bid or not nm:
                    continue
                # Strip leading "~" prefix used to mark buffs cast by
                # other players; the party panel uses it for dimming
                # only if applicable (currently ignored here).
                if isinstance(nm, str) and nm.startswith("~"):
                    nm = nm[1:]
                spec_by_bid.setdefault(bid, []).append(nm)
            # Walk the parallel buffs / buff_ids list. For each generic
            # entry whose buff_id has specific names available, replace
            # the single "March x2" entry with separate "Honor March",
            # "Victory March" entries. If we have FEWER specific names
            # than the count, fall back to the original for the extras.
            new_buffs    = []
            new_buff_ids = []
            for label, bid in zip(m_buffs, m_buff_ids):
                if bid in spec_by_bid and spec_by_bid[bid]:
                    # The label may be "March x2" — extract count from suffix.
                    count = 1
                    if " x" in label:
                        try:
                            count = int(label.rsplit(" x", 1)[1])
                        except (ValueError, IndexError):
                            count = 1
                    avail = spec_by_bid[bid][:count]
                    for spec_nm in avail:
                        new_buffs.append(spec_nm)
                        new_buff_ids.append(bid)
                    # If we needed more than we had, pad with the
                    # generic name so the visual count is preserved.
                    for _ in range(count - len(avail)):
                        new_buffs.append(label.rsplit(" x", 1)[0]
                                          if " x" in label else label)
                        new_buff_ids.append(bid)
                else:
                    new_buffs.append(label)
                    new_buff_ids.append(bid)
            m_buffs    = new_buffs
            m_buff_ids = new_buff_ids

        # When icon-grid mode is on, classify needs the parallel id list
        # so each name keeps its buff_id alongside. Text mode is back-
        # compat so call the 2-tuple form there.
        icon_grid = setting("party_buff_icon_grid")
        if icon_grid:
            buffs, buff_ids_b, debuffs, buff_ids_d = classify(
                m_buffs, m_buff_ids)
        else:
            buffs, debuffs = classify(m_buffs)
            buff_ids_b = buff_ids_d = None

        div_x = px + d["buff_x_off"] - int(8 * scale)
        pygame.draw.line(screen, COL_DIVIDER, (div_x, py + 8), (div_x, py + rh - 8))

        # How many lines fit in this panel at the current size? Leave a sliver
        # of padding top + bottom (row_pad_v // 2 on each side).
        usable_h    = rh - d["row_pad_v"]
        max_lines   = max(1, usable_h // d["buff_line_h"])

        # Icon-grid geometry (only used when icon_grid is on).
        # ICON_PX is the rendered icon size. GAP_PX is between cells in
        # both axes. Both scale with the panel scale so grid mode keeps
        # working at zoomed-up panels too.
        ICON_PX = max(12, int(16 * scale))
        GAP_PX  = max(1,  int(2  * scale))

        def _render_column_text(items, col_key, col_x, text_color):
            """Original text rendering with scroll + '+N more' overflow."""
            n = len(items)
            if n == 0:
                return
            scroll = buff_scroll.get((name, col_key), 0)
            if n <= max_lines:
                scroll = 0
            else:
                scroll = max(0, min(scroll, n - max_lines))
            buff_scroll[(name, col_key)] = scroll

            if n <= max_lines:
                for j, item in enumerate(items):
                    screen.blit(d["f_buff"].render(item, True, text_color),
                                (col_x, py + d["row_pad_v"] // 2 + j * d["buff_line_h"]))
            else:
                visible = items[scroll : scroll + (max_lines - 1)]
                for j, item in enumerate(visible):
                    screen.blit(d["f_buff"].render(item, True, text_color),
                                (col_x, py + d["row_pad_v"] // 2 + j * d["buff_line_h"]))
                remaining = n - (scroll + (max_lines - 1))
                more_text = f"+{remaining} more" if remaining > 0 else "(end)"
                screen.blit(d["f_buff"].render(more_text, True, COL_LABEL_DIM),
                            (col_x, py + d["row_pad_v"] // 2 + (max_lines - 1) * d["buff_line_h"]))

        def _render_column_grid(items, ids, col_key, col_x, col_w, text_color):
            """Pack ICON_PX squares row-by-row into the column width.

            Buffs whose icon hasn't been extracted yet (or whose id is
            None / out of range) fall back to a tiny 2-3 letter text
            badge in the same square footprint, so the grid stays
            visually uniform while the lua extractor catches up.
            """
            n = len(items)
            if n == 0:
                return
            cell      = ICON_PX + GAP_PX
            per_row   = max(1, col_w // cell)
            usable_h_ = rh - d["row_pad_v"]
            max_rows  = max(1, usable_h_ // cell)
            capacity  = per_row * max_rows
            # Scroll: paged in row-units (one click of scroll = per_row entries).
            scroll = buff_scroll.get((name, col_key), 0)
            if n <= capacity:
                scroll = 0
            else:
                scroll = max(0, min(scroll, n - capacity))
            buff_scroll[(name, col_key)] = scroll

            visible_n = min(n - scroll, capacity)
            base_y    = py + d["row_pad_v"] // 2
            for k in range(visible_n):
                idx = scroll + k
                row = k // per_row
                col = k %  per_row
                cx  = col_x + col * cell
                cy  = base_y + row * cell
                # Background slot: dim filled square so the cell is
                # visible even when the icon hasn't loaded yet.
                pygame.draw.rect(screen, (32, 32, 38),
                                 (cx, cy, ICON_PX, ICON_PX))
                bid = ids[idx] if (ids and idx < len(ids)) else None
                surf = get_status_icon_scaled(bid, ICON_PX) if bid else None
                if surf is not None:
                    screen.blit(surf, (cx, cy))
                else:
                    # Text badge fallback — first 2 chars of the alias name.
                    nm = items[idx] or ""
                    badge = nm[:2].upper() if nm else "?"
                    bsurf = d["f_buff"].render(badge, True, text_color)
                    screen.blit(bsurf,
                        (cx + (ICON_PX - bsurf.get_width()) // 2,
                         cy + (ICON_PX - bsurf.get_height()) // 2))
                # Subtle border for separation against panel bg.
                pygame.draw.rect(screen, (16, 16, 20),
                                 (cx, cy, ICON_PX, ICON_PX), 1)
                # Record this cell's rect for end-of-frame hover tooltip.
                # The buff name (already alias-resolved by classify) is
                # stored alongside so we can show it without further lookup.
                _party_buff_icon_rects.append(
                    (pygame.Rect(cx, cy, ICON_PX, ICON_PX), items[idx]))
            # Overflow indicator: tint the bottom-right cell slightly
            # if there are more items than fit. Cheap, no extra row.
            if scroll + visible_n < n:
                last_row = (visible_n - 1) // per_row
                last_col = (visible_n - 1) %  per_row
                cx = col_x + last_col * cell
                cy = base_y + last_row * cell
                # Small "+" pip in the bottom-right corner of the last cell.
                pip_size = max(4, ICON_PX // 4)
                pygame.draw.rect(screen, COL_LABEL_DIM,
                                 (cx + ICON_PX - pip_size,
                                  cy + ICON_PX - pip_size,
                                  pip_size, pip_size))

        def _render_column(items, ids, col_key, col_x, col_w, text_color):
            """Dispatch to grid or text mode based on the current setting."""
            if icon_grid:
                _render_column_grid(items, ids, col_key, col_x, col_w, text_color)
            else:
                _render_column_text(items, col_key, col_x, text_color)

        bfx = px + d["buff_x_off"]
        if setting("party_show_buffs"):
            _render_column(buffs, buff_ids_b, "buff", bfx,
                           d["buff_col_w"], COL_BUFF)

        dbx    = px + d["debuff_x_off"]
        div2_x = dbx - int(6 * scale)
        if setting("party_show_debuffs"):
            pygame.draw.line(screen, COL_DIVIDER, (div2_x, py + 8), (div2_x, py + rh - 8))
            _render_column(debuffs, buff_ids_d, "debuff", dbx,
                           d["debuff_col_w"], COL_DEBUFF)

        # Resize grip in the bottom-right corner.
        draw_resize_grip(screen, px + pw, py + rh)

    # ── Alliance party 1 + 2 panels ─────────────────────────────────────────
    # Each alliance member gets a slot-keyed anchor (a1_0..a1_5, a2_0..a2_5).
    # Defaults stack down the right side of the screen so they don't crowd
    # the main party at top-left. They use the simplified ally renderer
    # (name + jobs + bars only, no buff/debuff columns).
    # Toggleable via the "Show alliance" setting.
    if setting("show_alliance"):
        for ally_list, group_id in ((ally1_data, 1), (ally2_data, 2)):
            for slot_idx, m in enumerate(ally_list):
                akey = f"a{group_id}_{slot_idx}"
                scale = panel_scales.get(akey, 1.0)
                scale = max(MIN_SCALE, min(MAX_SCALE, scale))
                panel_scales[akey] = scale
                d_ally = scaled_ally_dims(scale)
                rh_ally = d_ally["row_min_h"]
                pw_ally = d_ally["panel_w"]

                # Default anchor: alliance 1 stacks down right side, alliance 2
                # stacks below alliance 1 (or just continues stacking).
                if akey not in panel_anchors:
                    default_y_ally = (HEADER_H + 12 +
                                      (rh_ally + 4) * slot_idx +
                                      (group_id - 1) * (rh_ally + 4) * 6)
                    panel_anchors[akey] = ["tr", PANEL_X, default_y_ally]

                # Resolve anchor → position. Skip when this panel is being dragged.
                if dragging_key != akey:
                    ax, ay = resolve_anchor(panel_anchors[akey], pw_ally, rh_ally,
                                            WIDTH, HEIGHT)
                    panel_positions[akey] = [ax, ay]
                elif akey not in panel_positions:
                    panel_positions[akey] = list(resolve_anchor(panel_anchors[akey],
                                                                 pw_ally, rh_ally,
                                                                 WIDTH, HEIGHT))

                ax, ay = panel_positions[akey]
                draw_ally_panel(screen, ax, ay, m, scale)
                draw_resize_grip(screen, ax + pw_ally, ay + rh_ally)

    # ── Equip viewer (draggable + resizable) ─────────────────────────────────
    if setting("show_equipment"):
        draw_equip_viewer(screen, equip_pos[0], equip_pos[1], equip_data, equip_scale)
        ev_pw, ev_ph, _, _ = equip_panel_size(equip_scale)
        draw_resize_grip(screen, equip_pos[0] + ev_pw, equip_pos[1] + ev_ph)

        # Register clickable URLs for any filled equip slots — click opens
        # the item's BG-Wiki page.
        for _slot_idx, _rect in equip_slot_rects.items():
            _info = equip_rich.get(_slot_idx)
            if _info and _info.get("name"):
                _url = "https://www.bg-wiki.com/ffxi/" + _info["name"].replace(" ", "_")
                click_targets.append((_rect, _url))

    # ── Recast panel (draggable + resizable) ────────────────────────────────
    # Build sorted entries from recast_state. Sort order driven by the
    # OW_RECAST_CONFIG.sort_order in the lua addon — lua sends the current
    # value in each RECAST_BATCH header. 'asc' = closest-to-ready left,
    # 'desc' = longest-wait left, 'cast' = most-recently-cast left.
    _recast_all = [
        {"kind": k[0], "id": k[1],
         "name": v["name"], "secs": v["secs"],
         "cast_ts": v.get("cast_ts", 0.0)}
        for k, v in recast_state.items()
    ]
    if recast_sort_order == "desc":
        _recast_entries = sorted(_recast_all, key=lambda e: -e["secs"])
    elif recast_sort_order == "cast":
        # Most-recently-cast first. Entries with cast_ts == 0 (never
        # tracked) sort to the end so they don't pollute the front.
        _recast_entries = sorted(
            _recast_all,
            key=lambda e: -e["cast_ts"] if e["cast_ts"] > 0 else float("inf"))
    else:  # 'asc' default
        _recast_entries = sorted(_recast_all, key=lambda e: e["secs"])

    # Append flash entries (recently-ready) at the end, regardless of sort.
    # Prune any whose flash window has elapsed.
    _now_flash = time.time()
    _expired_flashes = [
        k for k, v in _recast_flashes.items()
        if _now_flash - v["ready_at"] >= RECAST_FLASH_SEC
    ]
    for k in _expired_flashes:
        del _recast_flashes[k]
    for fkey, fval in _recast_flashes.items():
        _recast_entries.append({
            "kind": fkey[0], "id": fkey[1],
            "name": fval["name"], "secs": 0.0,
            "cast_ts": 0.0,
            "is_flash": True,
            "flash_age": _now_flash - fval["ready_at"],
        })
    # Setup mode: inject mock entries so the panel has visible content.
    # 4 mocks at varying remaining times so the user can see the bar fill,
    # color gradient, and stack layout before any real cooldowns exist.
    if setup_mode and not any(not e.get("is_flash") for e in _recast_entries):
        _recast_entries = [
            {"name": "Utsusemi: Ni", "secs":  4.5, "cast_ts": 0.0,
             "kind": "spell",   "id": -901},
            {"name": "Migawari",     "secs": 32.1, "cast_ts": 0.0,
             "kind": "ability", "id": -902},
            {"name": "Innin",        "secs": 88.0, "cast_ts": 0.0,
             "kind": "ability", "id": -903},
            {"name": "Yonin",        "secs": 175.5, "cast_ts": 0.0,
             "kind": "ability", "id": -904},
        ]
        # Seed peaks so mock bars render with a meaningful fill ratio.
        # Without this, the first frame would compute peak == secs which
        # gives a fully-empty bar.
        for _e in _recast_entries:
            _key = (_e["kind"], _e["id"])
            if _key not in _recast_peaks:
                # Common base recasts roughly: Utsusemi:Ni=30s,
                # Migawari=60s, Innin/Yonin=300s.
                base = {"Utsusemi: Ni": 30, "Migawari": 60,
                        "Innin": 300, "Yonin": 300}.get(_e["name"], 60)
                _recast_peaks[_key] = {"max_secs": float(base),
                                        "first_seen_at": time.time()}
        # Append a perpetual flash mock so users see the ready-blink effect
        # while positioning. flash_age cycles through the flash window so
        # it visibly blinks instead of staying solid.
        _recast_entries.append({
            "name": "Hi (Just Ready)", "secs": 0.0, "cast_ts": 0.0,
            "kind": "ws", "id": -905,
            "is_flash": True,
            "flash_age": (time.time() % RECAST_FLASH_SEC),
        })
    rec_w, rec_h = recast_panel_size(recast_scale, _recast_entries)
    if recast_anchor is None:
        # Default: top-left, just below the header. Top-left anchor means
        # the panel's TOP-left corner stays put as entries are added or
        # removed — panel grows downward from a fixed visible point.
        # (Bottom-left was the previous default, but it caused the visible
        # top to "jump down" between setup mode and gameplay because the
        # entry count differs.)
        recast_anchor = ["tl", PANEL_X, HEADER_H + 4]
    if dragging_key != "__recast__":
        rcx, rcy = resolve_anchor(recast_anchor, rec_w, rec_h, WIDTH, HEIGHT)
        if recast_pos is None:
            recast_pos = [rcx, rcy]
        else:
            recast_pos[0], recast_pos[1] = rcx, rcy
    elif recast_pos is None:
        recast_pos = list(resolve_anchor(recast_anchor, rec_w, rec_h, WIDTH, HEIGHT))

    if setting("show_recast"):
        # Auto-hide: when no abilities are cooling down, skip the panel
        # entirely instead of showing an empty "Recast" placeholder.
        # Setup mode bypasses this so the panel is always positionable.
        is_empty_recast = not _recast_entries
        if is_empty_recast and setting("autohide_recast") and not setup_mode:
            pass   # autohidden — no draw, no resize grip
        else:
            draw_recast_panel(screen, recast_pos[0], recast_pos[1],
                              _recast_entries, recast_scale, panels_locked)
            draw_resize_grip(screen, recast_pos[0] + rec_w, recast_pos[1] + rec_h)

    # ── Buff timer panel (draggable + resizable) ─────────────────────────
    # Mirrors the recast panel pipeline. buff_state is replaced wholesale
    # by BUFF_BATCH packets from lua. We sort, append wear-off flashes,
    # inject setup-mode mocks if the panel would otherwise be empty.
    _buff_all = [
        {"buff_id": bid, "name": v["name"], "secs": v["secs"],
         "source": v.get("source", "self")}
        for bid, v in buff_state.items()
    ]
    if buff_sort_order == "desc":
        _buff_entries = sorted(_buff_all, key=lambda e: -e["secs"])
    else:  # 'asc' default — soonest-expiring leftmost
        _buff_entries = sorted(_buff_all, key=lambda e: e["secs"])

    # Append wear-off flashes (entries that left buff_state on the most
    # recent BUFF_BATCH). They render red and blink for BUFF_FLASH_SEC.
    _now_buff = time.time()
    _buff_expired_flashes = [
        bid for bid, v in _buff_flashes.items()
        if _now_buff - v["ready_at"] >= BUFF_FLASH_SEC
    ]
    for bid in _buff_expired_flashes:
        del _buff_flashes[bid]
    for bid, fval in _buff_flashes.items():
        _buff_entries.append({
            "buff_id": bid, "name": fval["name"], "secs": 0.0,
            "source": fval.get("source", "self"),
            "flash": True,
            "flash_age": _now_buff - fval["ready_at"],
        })

    # Setup-mode mocks: 4 buffs at varying remaining times + 1 perpetual flash.
    if setup_mode and not any(not e.get("flash") for e in _buff_entries):
        _buff_entries = [
            {"buff_id": -801, "name": "Hasso",        "secs": 122.5,
             "source": "self"},
            {"buff_id": -802, "name": "Phalanx",      "secs": 47.0,
             "source": "self"},
            {"buff_id": -803, "name": "Sublime Sushi","secs": 1543.0,
             "source": "food"},
            {"buff_id": -804, "name": "~March",       "secs": 8.5,
             "source": "song_other"},
        ]
        # Seed peak durations so the bars render with meaningful fill.
        _buff_durations.setdefault(-801, 180.0)
        _buff_durations.setdefault(-802, 180.0)
        _buff_durations.setdefault(-803, 1800.0)
        _buff_durations.setdefault(-804, 240.0)
        # Perpetual flash mock so users see the wore-off effect.
        _buff_entries.append({
            "buff_id": -805, "name": "Stoneskin", "secs": 0.0,
            "source": "self",
            "flash": True,
            "flash_age": (time.time() % BUFF_FLASH_SEC),
        })

    bf_w, bf_h = buff_panel_size(buff_scale, _buff_entries)
    if buff_anchor is None:
        # Default: top-left, just below the recast panel. Top-left anchor
        # so the panel grows downward from a fixed visible point as buffs
        # are added/removed (rather than drifting). recast_pos[1]+rec_h+8
        # gives a reasonable y-offset assuming default recast position; if
        # the user moves the recast panel, the buff default will be wrong
        # but they can drag it in setup mode.
        recast_default_bottom = HEADER_H + 4 + rec_h
        buff_anchor = ["tl", PANEL_X, recast_default_bottom + 8]
    if dragging_key != "__buff__":
        bfx, bfy = resolve_anchor(buff_anchor, bf_w, bf_h, WIDTH, HEIGHT)
        if buff_pos is None:
            buff_pos = [bfx, bfy]
        else:
            buff_pos[0], buff_pos[1] = bfx, bfy
    elif buff_pos is None:
        buff_pos = list(resolve_anchor(buff_anchor, bf_w, bf_h, WIDTH, HEIGHT))

    if setting("show_buff_timer"):
        # Auto-hide: when no tracked buffs are active, skip the panel
        # entirely. Setup mode bypasses so the panel can be positioned.
        is_empty_buff = not _buff_entries
        if is_empty_buff and setting("autohide_buff_timer") and not setup_mode:
            pass   # autohidden
        else:
            draw_buff_panel(screen, buff_pos[0], buff_pos[1],
                            _buff_entries, buff_scale, panels_locked)
            draw_resize_grip(screen, buff_pos[0] + bf_w, buff_pos[1] + bf_h)

    # ── DPS panel ────────────────────────────────────────────────────────────
    # Toggleable via //ow dps. Default anchor sits below the buff panel,
    # left-anchored so it grows downward predictably.
    if dps_panel_visible:
        dp_w, dp_h = dps_panel_size(dps_scale)
        if dps_anchor is None:
            # Default: top-left, distance below the buff panel.
            dps_anchor = ["tl", PANEL_X, buff_pos[1] + bf_h + 8]
        if dragging_key != "__dps__":
            dpx, dpy = resolve_anchor(dps_anchor, dp_w, dp_h, WIDTH, HEIGHT)
            if dps_pos is None:
                dps_pos = [dpx, dpy]
            else:
                dps_pos[0], dps_pos[1] = dpx, dpy
        elif dps_pos is None:
            dps_pos = list(resolve_anchor(dps_anchor, dp_w, dp_h, WIDTH, HEIGHT))

        draw_dps_panel(screen, dps_pos[0], dps_pos[1],
                        dps_scale, panels_locked)
        draw_resize_grip(screen, dps_pos[0] + dp_w, dps_pos[1] + dp_h)

    # ── Button panel ─────────────────────────────────────────────────────────
    # 6×2 grid of user-configurable buttons. Default anchor sits below
    # the DPS panel; user can drag freely. Toggleable via //ow buttons.
    #
    # Multi-hotbar mode: when "Hotbars shown" is > 1, additional panels
    # render alongside the original. Each panel is independent: its own
    # draggable position (buttons_panel_anchors[i]/buttons_panel_positions[i]
    # for i>=1; buttons_anchor/buttons_pos for panel 0), its own current
    # content page (hotbar_panel_pages[panel_idx]), its own </> arrows.
    if buttons_panel_visible:
        bt_w, bt_h = buttons_panel_size(buttons_scale)
        # Resolve N: clamped to [1, HOTBAR_PAGE_COUNT].
        try:
            visible_n = int(setting("hotbar_visible_count") or 1)
        except (TypeError, ValueError):
            visible_n = 1
        visible_n = max(1, min(HOTBAR_PAGE_COUNT, visible_n))

        # Panel 0 (the classic primary panel). Position via the existing
        # buttons_anchor / buttons_pos pair for backward compatibility.
        if buttons_anchor is None:
            # Default: just under the DPS panel, left-aligned.
            if dps_panel_visible and dps_pos is not None:
                default_y = dps_pos[1] + dp_h + 8
            else:
                default_y = buff_pos[1] + bf_h + 8
            buttons_anchor = ["tl", PANEL_X, default_y]
        if dragging_key != "__buttons__":
            btx, bty = resolve_anchor(buttons_anchor, bt_w, bt_h, WIDTH, HEIGHT)
            if buttons_pos is None:
                buttons_pos = [btx, bty]
            else:
                buttons_pos[0], buttons_pos[1] = btx, bty
        elif buttons_pos is None:
            buttons_pos = list(resolve_anchor(
                buttons_anchor, bt_w, bt_h, WIDTH, HEIGHT))

        draw_buttons_panel(screen, buttons_pos[0], buttons_pos[1],
                           buttons_scale, panels_locked, panel_idx=0)
        draw_resize_grip(screen,
                         buttons_pos[0] + bt_w, buttons_pos[1] + bt_h)

        # Stash the buttons-panel geometry so the hotbar editor (drawn
        # later in the frame, after all other panels) can attach itself
        # to the right spot. Drawing the editor here would put it below
        # subsequent panels in z-order — we want it on TOP of everything
        # except the header and settings dropdown.
        _hotbar_editor_anchor = (buttons_pos[0], buttons_pos[1], bt_w, bt_h)

        # Additional panels (1..visible_n-1). Each gets its own anchor
        # in buttons_panel_anchors and remembers its current content
        # page in hotbar_panel_pages. On first appearance a panel
        # defaults to showing its own panel_idx as page_idx (so panel 1
        # opens on page 1, panel 2 on page 2, etc.), and stacks below
        # the previous panel.
        if visible_n > 1:
            for panel_i in range(1, visible_n):
                # Default page for this panel: its own index, clamped
                # into the available pages list.
                if panel_i not in hotbar_panel_pages:
                    hotbar_panel_pages[panel_i] = min(panel_i,
                                                     len(hotbar_pages) - 1)
                # Default anchor: stack below the previous panel.
                if panel_i not in buttons_panel_anchors:
                    if panel_i == 1:
                        prev_pos = buttons_pos
                    else:
                        prev_pos = buttons_panel_positions.get(panel_i - 1)
                    base_y = (prev_pos[1] if prev_pos else 0)
                    base_x = (prev_pos[0] if prev_pos else PANEL_X)
                    buttons_panel_anchors[panel_i] = [
                        "tl", int(base_x), int(base_y + bt_h + 8)]
                drag_key_p = f"__buttons_{panel_i}__"
                if dragging_key != drag_key_p:
                    pxp, pyp = resolve_anchor(buttons_panel_anchors[panel_i],
                                              bt_w, bt_h, WIDTH, HEIGHT)
                    buttons_panel_positions[panel_i] = [pxp, pyp]
                elif panel_i not in buttons_panel_positions:
                    buttons_panel_positions[panel_i] = list(resolve_anchor(
                        buttons_panel_anchors[panel_i], bt_w, bt_h,
                        WIDTH, HEIGHT))
                pp = buttons_panel_positions[panel_i]
                draw_buttons_panel(screen, pp[0], pp[1],
                                   buttons_scale, panels_locked,
                                   panel_idx=panel_i)
                draw_resize_grip(screen, pp[0] + bt_w, pp[1] + bt_h)

    # ── Stats panel (draggable + resizable) ──────────────────────────────────
    if setting("show_statistics"):
        draw_stats_panel(screen, stats_pos[0], stats_pos[1],
                         player_self_mjob, player_stats, stats_scale)
        draw_resize_grip(screen, stats_pos[0] + sw, stats_pos[1] + sh)

    # ── Target card (fades out after TC_FADE_SEC of no target) ──────────────
    tc_alpha = 0
    if target_sticky is not None:
        if target_info is not None:
            tc_alpha = 255
        else:
            elapsed = time.time() - last_target_time
            if elapsed < TC_FADE_SEC:
                tc_alpha = int(255 * (1.0 - elapsed / TC_FADE_SEC))
            else:
                tc_alpha = 0
    if tc_alpha > 0 and target_pos is not None and setting("show_target"):
        # Use the same dispatch helper here as in the sizing path so trusts,
        # PCs, and mobs all get correct refs/family. The helper also returns
        # the family which we override to "adventurer" later for PC kind.
        (mob_ref, mobdb_entry, _, _, _, _) = resolve_target_card_data(target_sticky)
        draw_target_card(screen, target_pos[0], target_pos[1],
                         target_sticky, mob_ref, mobdb_entry,
                         target_scale, tc_alpha, "TARGET",
                         statuses=_tc_stat, cast_state=_tc_cstate)
        draw_resize_grip(screen, target_pos[0] + tcw, target_pos[1] + tch)
    elif target_sticky is not None and target_info is None:
        # Fade complete. Drop the sticky so a future re-target starts fresh.
        target_sticky = None

    # ── Sub-target card ─────────────────────────────────────────────────────
    # Suppression: kill sub-target rendering when it's not a meaningful
    # sub-target relationship. Three cases hit:
    #   1. Sub has the same id as main (windower returns identical entity
    #      for 't' and 'st' selectors when in NPC menus / dialogues).
    #   2. Main is a friendly NPC. You can't sub-target through an NPC
    #      menu interaction; anything 'st' is holding is stale.
    #   3. Sub itself is a friendly NPC (no useful info to render anyway).
    # This is checked here rather than in lua because friendly NPCs can't
    # be reliably distinguished from mobs by zone-local index alone (per
    # Windower's own docs).
    # Sub-target safety filters. The lua side now uses target_arrow to
    # gate sending entirely (only sends when the cursor is actively in
    # <st>/<stpc>/<stnpc> mode), so most ghost-sub cases are stopped at
    # the source. These remaining filters catch edge cases where 'st'
    # briefly returns garbage right as the cursor opens:
    #   1. Sub has the same id as main.
    #   2. Sub itself is a friendly NPC.
    _suppress_sub = False
    if target_sticky_st is not None and target_sticky is not None:
        main_id = target_sticky.get("id", 0)
        sub_id  = target_sticky_st.get("id", 0)
        sub_kd  = target_sticky_st.get("kind", "")
        if main_id and sub_id and main_id == sub_id:
            _suppress_sub = True
        elif sub_kd == "npc":
            _suppress_sub = True

    tc_alpha_st = 0
    if target_sticky_st is not None and not _suppress_sub:
        if target_info_st is not None:
            tc_alpha_st = 255
        else:
            elapsed = time.time() - last_target_time_st
            if elapsed < TC_FADE_SEC:
                tc_alpha_st = int(255 * (1.0 - elapsed / TC_FADE_SEC))
            else:
                tc_alpha_st = 0
    if tc_alpha_st > 0 and target_pos_st is not None and setting("show_subtarget"):
        (mob_ref_st, mobdb_entry_st, _, _, _, _) = resolve_target_card_data(target_sticky_st)
        draw_target_card(screen, target_pos_st[0], target_pos_st[1],
                         target_sticky_st, mob_ref_st, mobdb_entry_st,
                         target_scale_st, tc_alpha_st, "SUB-TARGET",
                         statuses=_tc_stat_st, cast_state=_tc_cstate_st)
        draw_resize_grip(screen, target_pos_st[0] + tcw_st, target_pos_st[1] + tch_st)
    elif target_sticky_st is not None and (target_info_st is None or _suppress_sub):
        # Fade complete OR suppressed. Drop the sticky.
        target_sticky_st = None

    # ── Hotbar editor (drawn after all panels so it sits ON TOP of them) ────
    # The editor anchor was stashed when the buttons panel rendered. If
    # the buttons panel is hidden, we don't have an anchor and the
    # editor is silently skipped. The form renders BELOW the header
    # and settings dropdown so those overlays still take precedence.
    try:
        _anchor = _hotbar_editor_anchor
    except NameError:
        _anchor = None
    if _anchor is not None:
        draw_hotbar_editor(screen, _anchor[0], _anchor[1],
                           _anchor[2], _anchor[3])

    # ── Header (drawn last so it sits on top) ────────────────────────────────
    draw_header(screen, WIDTH)

    # ── Settings dropdown (above everything when open) ──────────────────────
    draw_settings_menu(screen)

    # ── Inventory dropdown (above everything when open) ─────────────────────
    draw_inventory_dropdown(screen)

    # ── Character-view dropdown (small; right of gear button) ───────────────
    draw_char_view_dropdown(screen)

    # ── Simulation window (developer tool, above almost everything) ─────────
    draw_sim_window(screen)

    # ── Cursor: show a hand when hovering over a hyperlink ──────────────────
    mpos = pygame.mouse.get_pos()
    on_link = any(rect.collidepoint(mpos) for rect, _ in click_targets)
    try:
        pygame.mouse.set_cursor(
            pygame.SYSTEM_CURSOR_HAND if on_link else pygame.SYSTEM_CURSOR_ARROW
        )
    except Exception:
        # Some pygame builds / platforms don't support system cursors;
        # silently ignore and keep the default cursor.
        pass

    # ── Tooltip: if the cursor is over a filled equip slot, show item info. ──
    # Suppress when the cursor is over the hotbar editor — without this
    # the equipment slot tooltip leaks through the editor form, e.g.
    # "Cessance Earring" appearing inside the editor while the user is
    # picking an icon. Z-order applies to hover state same as clicks.
    _suppress_tooltip = False
    if hotbar_edit_mode:
        _ed_anchor = globals().get("_hotbar_editor_anchor")
        if _ed_anchor is not None:
            _ax, _ay, _aw, _ah = _ed_anchor
            _form_rect = pygame.Rect(_ax, _ay + _ah + 4,
                                     _aw, HOTBAR_EDIT_FORM_H)
            if _form_rect.collidepoint(mpos):
                _suppress_tooltip = True
            elif hotbar_icon_picker_open:
                _picker_rect = pygame.Rect(_ax,
                                           _form_rect.bottom + 4,
                                           _aw, 220)
                if _picker_rect.collidepoint(mpos):
                    _suppress_tooltip = True
    if not _suppress_tooltip:
        for _sidx, _srect in equip_slot_rects.items():
            if _srect.collidepoint(mpos):
                _tt_info = equip_rich.get(_sidx)
                if _tt_info:
                    draw_item_tooltip(screen, mpos[0], mpos[1], _tt_info, WIDTH, HEIGHT)
                break

    # ── Tooltip: if the cursor is over a mob ability name, show its data. ───
    if not _suppress_tooltip:
        for _abrect, _abentry in _mob_ability_rects:
            if _abrect.collidepoint(mpos):
                draw_ability_tooltip(screen, mpos[0], mpos[1],
                                     _abentry, WIDTH, HEIGHT)
                break

    # ── Tooltip: party-row buff/debuff icon hover ─────────────────────────
    # Only populated when "Compact icon grid" is on. Shows the buff
    # display name in a tiny chip near the cursor. Walks rects in order
    # and shows the FIRST hit so overlapping cells (shouldn't happen but
    # defensive) don't double-draw.
    if not _suppress_tooltip and _party_buff_icon_rects:
        for _brect, _bname in _party_buff_icon_rects:
            if _brect.collidepoint(mpos):
                _bf = get_font("Consolas", 12)
                _bs = _bf.render(_bname, True, (235, 235, 245))
                _pad = 4
                _tw = _bs.get_width() + _pad * 2
                _th = _bs.get_height() + _pad * 2
                # Anchor below-right of cursor; flip if it would clip.
                _tx = mpos[0] + 14
                _ty = mpos[1] + 14
                if _tx + _tw > WIDTH:  _tx = mpos[0] - _tw - 6
                if _ty + _th > HEIGHT: _ty = mpos[1] - _th - 6
                pygame.draw.rect(screen, (24, 24, 30),
                                 (_tx, _ty, _tw, _th), border_radius=3)
                pygame.draw.rect(screen, (90, 90, 110),
                                 (_tx, _ty, _tw, _th), 1, border_radius=3)
                screen.blit(_bs, (_tx + _pad, _ty + _pad))
                break

    # ── Setup mode banner ────────────────────────────────────────────────────
    # When setup_mode is True, draw a top-of-screen strip telling the user
    # they're in setup mode and how to exit. Subtle but unmissable.
    if setup_mode:
        banner_h = 26
        banner = pygame.Surface((WIDTH, banner_h), pygame.SRCALPHA)
        banner.fill((180, 60, 130, 200))   # magenta-ish, semi-translucent
        screen.blit(banner, (0, 0))
        bf = get_font("Consolas", 13, bold=True)
        msg = ("OmniWatch — SETUP MODE — drag panels to position. "
               "//ow setup again to exit.")
        bs = bf.render(msg, True, (255, 255, 255))
        screen.blit(bs, ((WIDTH - bs.get_width()) // 2,
                          (banner_h - bs.get_height()) // 2))

    # Config wizard modal (renders LAST so it sits on top of everything,
    # including settings menu, sim window, banners, etc.).
    draw_cfgwiz(screen)

    pygame.display.flip()
    clock.tick(60)

    # ── Events ───────────────────────────────────────────────────────────────
    for event in pygame.event.get():
        if event.type == pygame.QUIT:
            running = False

        elif event.type == pygame.VIDEORESIZE:
            WIDTH, HEIGHT = event.w, event.h
            screen = pygame.display.set_mode((WIDTH, HEIGHT), pygame.RESIZABLE)
            # Anchors handle repositioning automatically on the next frame.
            # No save needed — nothing on disk changes.

        elif event.type == pygame.MOUSEWHEEL:
            mx, my = pygame.mouse.get_pos()

            # Sim window first — when open, its scrollbar takes priority
            # over the panels behind it. Same wheel-step convention as
            # the settings menu (one row per click). Clamp happens in
            # draw_sim_window.
            if sim_window_open:
                nat_h = _sim_compute_height()
                eww = max(220, int(sim_window_size[0]))
                user_h = int(sim_window_size[1])
                ewh = user_h if user_h > 0 else nat_h
                env = pygame.Rect(sim_window_pos[0], sim_window_pos[1],
                                  eww, ewh)
                if env.collidepoint(mx, my):
                    sim_window_scroll = max(0,
                        sim_window_scroll - event.y * 22)
                    continue

            # Settings menu takes priority — if open and cursor is over
            # the panel, scroll its content instead of party buff columns
            # or the inventory dropdown. Wheel-step is 24px (one row).
            if (settings_menu_open
                    and settings_menu_panel_rect is not None
                    and settings_menu_panel_rect.collidepoint(mx, my)):
                # event.y > 0 = wheel up = scroll content UP (show earlier rows).
                settings_menu_scroll = max(0,
                    settings_menu_scroll - event.y * 24)
                # Upper bound clamp happens during render against the
                # current overflow value, so we don't need to clamp here.
                continue

            # Inventory dropdown takes priority — if it's open and the
            # cursor is over its panel envelope, scroll the active bag's
            # item list instead of party buff columns.
            if (inventory_dropdown_open
                    and inventory_active_bag is not None):
                _inv_geom = _inventory_panel_geometry()
                if _inv_geom is not None:
                    _inv_env = pygame.Rect(*_inv_geom)
                    if _inv_env.collidepoint(mx, my):
                        bag = inventory_active_bag
                        cur = inventory_bag_scroll.get(bag, 0)
                        # Wheel-up (event.y > 0) shows earlier rows.
                        inventory_bag_scroll[bag] = max(0, cur - event.y)
                        continue

            # Scroll the buff or debuff column the mouse is hovering over.
            if my < HEADER_H:
                continue
            for name in reversed(panel_order):
                m = members_by_name.get(name)
                if not m:
                    continue
                px, py = panel_positions[name]
                scale  = panel_scales.get(name, 1.0)
                d      = scaled_panel_dims(scale)
                rh     = row_height(m, scale)
                pw     = d["panel_w"]
                if not (px <= mx < px + pw and py <= my < py + rh):
                    continue
                # Which column is the mouse in?
                bfx_start = px + d["buff_x_off"]
                dbx_start = px + d["debuff_x_off"]
                col_key = None
                if bfx_start <= mx < dbx_start - int(6 * scale):
                    col_key = "buff"
                elif mx >= dbx_start - int(6 * scale) and mx < px + pw:
                    col_key = "debuff"
                if col_key:
                    cur = buff_scroll.get((name, col_key), 0)
                    # Wheel up scrolls toward the start (shows earlier entries).
                    buff_scroll[(name, col_key)] = max(0, cur - event.y)
                break

        elif event.type == pygame.KEYDOWN:
            # Config wizard inline-dropdown name input. When the
            # "+ Add Ally" form is open, route ALL keystrokes to it
            # before any other handler (sim editor, hotbar, hotkeys).
            # Letters append to the buffer; Backspace deletes; Enter
            # confirms; Esc closes. Anything else is swallowed so
            # global hotkeys can't fire while the user is typing a
            # name.
            if cfgwiz_visible and cfgwiz_dropdown_open:
                if event.key in (pygame.K_RETURN, pygame.K_KP_ENTER):
                    _cfgwiz_commit_ally()
                    continue
                if event.key == pygame.K_ESCAPE:
                    _cfgwiz_dropdown_set(False)
                    continue
                if event.key == pygame.K_BACKSPACE:
                    cfgwiz_input_buffer = cfgwiz_input_buffer[:-1]
                    continue
                ch = event.unicode
                # FFXI character names are letters only — reject
                # digits/punctuation. Cap at 16 chars (longest FFXI
                # name is 15).
                if (ch and ch.isalpha()
                        and len(cfgwiz_input_buffer) < 16):
                    cfgwiz_input_buffer += ch
                continue

            # Sim-window nickname editor: highest priority when open.
            # Enter saves and closes. Esc cancels. Backspace deletes.
            # Printable chars append (cap at 32 chars).
            if sim_nickname_editor is not None:
                if event.key == pygame.K_RETURN or event.key == pygame.K_KP_ENTER:
                    txt = sim_nickname_editor.get("text", "").strip()
                    _aug_set_nickname(
                        sim_nickname_editor["id"],
                        sim_nickname_editor["fp"],
                        txt,
                    )
                    sim_nickname_editor = None
                    continue
                if event.key == pygame.K_ESCAPE:
                    sim_nickname_editor = None
                    continue
                if event.key == pygame.K_BACKSPACE:
                    sim_nickname_editor["text"] = sim_nickname_editor.get("text", "")[:-1]
                    continue
                # Printable text. event.unicode is the actual character
                # (respects shift, layout, etc.) — preferred over
                # event.key which is layout-independent.
                ch = event.unicode
                if ch and ch.isprintable() and len(sim_nickname_editor.get("text", "")) < 32:
                    sim_nickname_editor["text"] = sim_nickname_editor.get("text", "") + ch
                    continue

            # Hotbar editor text input. When a label / command field
            # has focus, swallow keys here before any other handler.
            # The handler returns False for keys it doesn't consume
            # (e.g. unrecognised non-printable keys), which fall
            # through to other handlers below.
            if (hotbar_edit_mode and hotbar_focused_field is not None):
                if hotbar_editor_handle_keydown(event):
                    continue
            # Esc anywhere closes whichever overlay is open: icon
            # picker first, then editor itself, then settings menu.
            if event.key == pygame.K_ESCAPE:
                if hotbar_icon_picker_open:
                    hotbar_icon_picker_open = False
                    continue
                if hotbar_edit_mode:
                    hotbar_edit_mode = False
                    hotbar_edit_slot = -1
                    hotbar_edit_draft = None
                    hotbar_focused_field = None
                    print("[OmniWatch] hotbar editor closed (Esc)")
                    continue
                if settings_menu_open:
                    settings_menu_open = False
                    continue
                if inventory_dropdown_open:
                    inventory_dropdown_open = False
                    continue

        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            mx, my = event.pos

            # Highest priority: config wizard modal. When visible, it
            # eats every left-click — either as a control hit (+/- or
            # button) or as a click-out cancel. Nothing else processes
            # the click while the modal is up.
            if cfgwiz_visible:
                dispatch_cfgwiz_click(mx, my)
                continue

            # Highest priority: character-view dropdown. Has to come
            # before the settings handler because the char button sits
            # next to the settings gear and we don't want a missed
            # click on it to fall through to drag.
            if dispatch_char_view_dropdown_click(mx, my):
                continue

            # Highest priority: settings gear button + open menu hits.
            # We handle these before anything else because the menu
            # overlays panels — a click on the menu should never fall
            # through to drag/resize/hyperlink/button handling.
            if (settings_button_rect is not None
                    and settings_button_rect.collidepoint(mx, my)):
                settings_menu_open = not settings_menu_open
                if not settings_menu_open:
                    settings_menu_scroll = 0
                continue

            # ── Sim window (highest priority when open) ──────────────────────
            # Resize grip > title bar > body controls. Resize first
            # because the grip overlaps the body region visually.
            if sim_window_open:
                if (sim_window_resize_rect is not None
                        and sim_window_resize_rect.collidepoint(mx, my)):
                    # Begin resize. Capture initial size + mouse position;
                    # MOUSEMOTION computes new size as start + delta.
                    nat_h = _sim_compute_height()
                    cur_w = int(sim_window_size[0])
                    cur_h = int(sim_window_size[1]) or nat_h
                    sim_window_resize = (cur_w, cur_h, mx, my)
                    continue
                if (sim_window_titlebar_rect is not None
                        and sim_window_titlebar_rect.collidepoint(mx, my)):
                    # Begin dragging. Store the offset from window
                    # origin to mouse so movement preserves grip point.
                    sim_window_drag = (mx - sim_window_pos[0],
                                       my - sim_window_pos[1])
                    continue
                if dispatch_sim_window_click(mx, my):
                    continue
                # Click outside the sim window — fall through. Don't
                # close on click-outside; user closes via X or toggle.

            if settings_menu_open:
                # Click inside an open menu's controls?
                if dispatch_settings_menu_click(mx, my):
                    continue
                # Click outside the rendered menu rect → close. Use
                # settings_menu_panel_rect (the actually-rendered rect,
                # respecting the height clamp for overflow) rather than
                # recomputing from natural size — that mismatched the
                # rendered rect when scroll was active and let some
                # clicks fall through.
                env = settings_menu_panel_rect
                if env is None or not env.collidepoint(mx, my):
                    settings_menu_open = False
                    settings_menu_scroll = 0
                    continue
                # Click was inside the menu envelope but not on a
                # control (e.g. between rows): swallow it so it doesn't
                # reach the panels behind.
                continue

            # Inventory dropdown: same pattern as settings menu —
            # toggle on the header button, dispatch on hits inside,
            # close on outside clicks. Drawn above all panels so it
            # takes priority over their click targets.
            if (inventory_button_rect is not None
                    and inventory_button_rect.collidepoint(mx, my)):
                inventory_dropdown_open = not inventory_dropdown_open
                # Reset to bag-list view each time we open, so the
                # user always lands on the same entry point.
                if inventory_dropdown_open:
                    inventory_active_bag = None
                continue
            if inventory_dropdown_open:
                if dispatch_inventory_dropdown_click(mx, my):
                    continue
                # Outside-click closes the dropdown. Use the shared
                # geometry helper so this stays in sync with both the
                # renderer and the dispatch function.
                _inv_geom = _inventory_panel_geometry()
                if _inv_geom is not None:
                    inv_envelope = pygame.Rect(*_inv_geom)
                    if not inv_envelope.collidepoint(mx, my):
                        inventory_dropdown_open = False
                        continue
                # Click inside envelope but not a control — swallow.
                continue

            # Hotbar editor: when active, the editor form's click
            # targets (Save/Cancel/Done, kind cyclers, focus rects, icon
            # picker, etc.) take priority over everything else.
            #
            # Click-through fix: we ALSO swallow any click that lands
            # within the form's bounding box (between control rects),
            # so the click doesn't fall through to URL hyperlinks or
            # drag/resize logic for panels rendered behind the editor
            # (e.g. the equipment panel underneath). Without this the
            # editor form is "transparent" to clicks anywhere except
            # the buttons.
            if hotbar_edit_mode:
                if dispatch_hotbar_editor_click(mx, my):
                    continue
                # Compute the editor envelope from the stashed anchor
                # set during the buttons panel render this frame. If
                # the anchor isn't set (panel hidden), the envelope
                # is empty and we fall through normally.
                _ed_anchor = globals().get("_hotbar_editor_anchor")
                if _ed_anchor is not None:
                    _ax, _ay, _aw, _ah = _ed_anchor
                    _form_rect = pygame.Rect(_ax, _ay + _ah + 4,
                                             _aw, HOTBAR_EDIT_FORM_H)
                    if _form_rect.collidepoint(mx, my):
                        continue   # click landed in form chrome → eat it
                    if hotbar_icon_picker_open:
                        _picker_rect = pygame.Rect(_ax,
                                                   _form_rect.bottom + 4,
                                                   _aw, 220)
                        if _picker_rect.collidepoint(mx, my):
                            continue   # click in picker chrome → eat it
                # Click on a hotbar slot while in edit mode → select
                # that slot for editing instead of running its command.
                # The button-rect list now also contains nav targets
                # (page name, < / > arrows) keyed by string identifiers;
                # those are handled the same as outside edit mode (we
                # let the user navigate pages even while editing).
                if buttons_panel_visible:
                    slot_hit = False
                    # Iterate primary panel's rects + every multi-mode
                    # panel's rects. Tuples (action, panel_idx) target a
                    # specific panel; bare strings target the primary.
                    _all_rects = list(buttons_rects)
                    for _pi, _r in buttons_panel_rects.items():
                        _all_rects.extend(_r)
                    for rect, payload in _all_rects:
                        if not rect.collidepoint(mx, my):
                            continue
                        # Decode payload into (action, panel_idx). Tuples
                        # carry an explicit panel; bare values default to 0.
                        if isinstance(payload, tuple):
                            payload_kind, _panel = payload
                            target_panel = _panel
                        else:
                            payload_kind = payload
                            target_panel = 0
                        if isinstance(payload_kind, str):
                            if payload_kind == "__page_prev__":
                                cur = (hotbar_panel_pages.get(target_panel,
                                       hotbar_current_page if target_panel == 0
                                       else target_panel))
                                _hotbar_panel_set_page(target_panel, cur - 1)
                            elif payload_kind == "__page_next__":
                                cur = (hotbar_panel_pages.get(target_panel,
                                       hotbar_current_page if target_panel == 0
                                       else target_panel))
                                _hotbar_panel_set_page(target_panel, cur + 1)
                            elif payload_kind == "__page_name__":
                                # Treat as editing the name field. Editor
                                # acts on the primary panel only.
                                if target_panel == 0:
                                    hotbar_select_slot(payload_kind)
                            slot_hit = True
                            break
                        # Numeric index = a real button slot. The editor
                        # only operates on the primary panel.
                        if target_panel == 0:
                            hotbar_select_slot(payload_kind)
                        slot_hit = True
                        break
                    if slot_hit:
                        continue

            # Highest priority: button panel hits run user-defined
            # commands. Skipped in setup mode (so the user can drag the
            # panel without launching commands). Lock does NOT block
            # button presses — lock prevents accidental panel movement,
            # not deliberate button clicks.
            if (buttons_panel_visible and not setup_mode
                    and not hotbar_edit_mode):
                button_hit = False
                # Iterate primary + multi-mode panels' rects in one pass.
                _all_rects = list(buttons_rects)
                for _pi, _r in buttons_panel_rects.items():
                    _all_rects.extend(_r)
                for rect, payload in _all_rects:
                    if not rect.collidepoint(mx, my):
                        continue
                    # Decode (action, panel_idx) tuple vs bare payload.
                    if isinstance(payload, tuple):
                        payload_kind, _panel = payload
                        target_panel = _panel
                    else:
                        payload_kind = payload
                        target_panel = 0
                    if isinstance(payload_kind, str):
                        # Page navigation / name click.
                        if payload_kind == "__page_prev__":
                            cur = (hotbar_panel_pages.get(target_panel,
                                   hotbar_current_page if target_panel == 0
                                   else target_panel))
                            _hotbar_panel_set_page(target_panel, cur - 1)
                            button_hit = True
                        elif payload_kind == "__page_next__":
                            cur = (hotbar_panel_pages.get(target_panel,
                                   hotbar_current_page if target_panel == 0
                                   else target_panel))
                            _hotbar_panel_set_page(target_panel, cur + 1)
                            button_hit = True
                        elif payload_kind == "__page_name__":
                            # Click on page name → enter edit mode (only
                            # the primary panel hosts the editor).
                            if target_panel == 0:
                                _open_hotbar_editor()
                                hotbar_select_slot("__page_name__")
                                button_hit = True
                        break
                    # Numeric index = a real button slot. Dispatch on the
                    # right panel's current page.
                    _dispatch_button_on_panel(payload_kind, target_panel)
                    button_hit = True
                    break
                if button_hit:
                    continue

            # Next: check if the click landed on a hyperlink target (zone
            # name in header, mob name on target card, item icon → bg-wiki,
            # etc.). These take priority over any drag/resize action.
            #
            # EXCEPTION: in setup mode, skip hyperlink handling entirely.
            # Setup is for positioning panels, and many panels have
            # clickable hyperlinks layered over their bodies. Letting
            # those eat the click would make panels nearly impossible to
            # grab while positioning.
            if not setup_mode:
                link_hit = False
                for rect, url in click_targets:
                    if rect.collidepoint(mx, my):
                        open_url(url)
                        link_hit = True
                        break
                if link_hit:
                    continue

            # Lock check: if panels are locked and we're not in setup mode,
            # skip drag/resize hit testing entirely. Hyperlinks already
            # ran above, so the click was already handled if it was on
            # one. Lock prevents accidental nudge during gameplay.
            if panels_locked and not setup_mode:
                continue

            # Ignore other clicks in the header so the clock doesn't get
            # dragged. Allowed in setup mode for positioning near top.
            if my < HEADER_H and not setup_mode:
                continue

            hit = None

            # Hit-testing iterates panels in REVERSE render order so the
            # visually-topmost panel under the cursor wins. Render order
            # in this file is:
            #   party → ally → equip → recast → buff → dps → buttons →
            #   stats → target → sub-target
            # so we check from the bottom of that list upward. Without
            # this, a click that landed on a panel covering an older
            # panel would drag the OLDER one (the "click through"
            # behavior in setup mode the user has been hitting).

            # 1. Sub-target card (topmost).
            if hit is None and target_pos_st is not None and tc_alpha_st > 0:
                txp, typ = target_pos_st
                if (txp + tcw_st - RESIZE_GRIP) <= mx < (txp + tcw_st) and \
                   (typ + tch_st - RESIZE_GRIP) <= my < (typ + tch_st):
                    hit = ("target_st", "__target_st__", txp, typ, "resize",
                           tcw_st, tch_st, target_scale_st)
                elif txp <= mx < txp + tcw_st and typ <= my < typ + tch_st:
                    hit = ("target_st", "__target_st__", txp, typ, "move",
                           tcw_st, tch_st, target_scale_st)

            # 2. Main target card.
            if hit is None and target_pos is not None and tc_alpha > 0:
                txp, typ = target_pos
                if (txp + tcw - RESIZE_GRIP) <= mx < (txp + tcw) and \
                   (typ + tch - RESIZE_GRIP) <= my < (typ + tch):
                    hit = ("target", "__target__", txp, typ, "resize", tcw, tch, target_scale)
                elif txp <= mx < txp + tcw and typ <= my < typ + tch:
                    hit = ("target", "__target__", txp, typ, "move", tcw, tch, target_scale)

            # 3. Stats panel.
            if hit is None and stats_pos is not None:
                sx2, sy2 = stats_pos
                _jlist = None  # fixed layout
                spw, sph = stats_panel_size(stats_scale, _jlist)
                if (sx2 + spw - RESIZE_GRIP) <= mx < (sx2 + spw) and \
                   (sy2 + sph - RESIZE_GRIP) <= my < (sy2 + sph):
                    hit = ("stats", "__stats__", sx2, sy2, "resize", spw, sph, stats_scale)
                elif sx2 <= mx < sx2 + spw and sy2 <= my < sy2 + sph:
                    hit = ("stats", "__stats__", sx2, sy2, "move", spw, sph, stats_scale)

            # 4. Buttons panel (hotbar). Click hits on individual buttons
            # were consumed at the top of the mouse handler before any
            # drag check, so reaching here means the click was on the
            # panel border / between buttons.
            if (hit is None and buttons_panel_visible
                    and buttons_pos is not None):
                bxp, byp = buttons_pos
                _btw, _bth = buttons_panel_size(buttons_scale)
                if (bxp + _btw - RESIZE_GRIP) <= mx < (bxp + _btw) and \
                   (byp + _bth - RESIZE_GRIP) <= my < (byp + _bth):
                    hit = ("buttons", "__buttons__", bxp, byp, "resize",
                           _btw, _bth, buttons_scale)
                elif bxp <= mx < bxp + _btw and byp <= my < byp + _bth:
                    hit = ("buttons", "__buttons__", bxp, byp, "move",
                           _btw, _bth, buttons_scale)

            # Multi-mode hotbar panels (panel_idx 1..N-1). Same hit-test
            # shape as the primary one, keyed by __buttons_<n>__ so the
            # drag handler can route the position update to the right
            # panel-anchor dict entry.
            if hit is None and buttons_panel_visible:
                _btw, _bth = buttons_panel_size(buttons_scale)
                for _pi, _ppos in list(buttons_panel_positions.items()):
                    if not _ppos:
                        continue
                    pxp, pyp = _ppos
                    if (pxp + _btw - RESIZE_GRIP) <= mx < (pxp + _btw) and \
                       (pyp + _bth - RESIZE_GRIP) <= my < (pyp + _bth):
                        hit = ("buttons", f"__buttons_{_pi}__",
                               pxp, pyp, "resize",
                               _btw, _bth, buttons_scale)
                        break
                    elif pxp <= mx < pxp + _btw and pyp <= my < pyp + _bth:
                        hit = ("buttons", f"__buttons_{_pi}__",
                               pxp, pyp, "move",
                               _btw, _bth, buttons_scale)
                        break

            # 5. DPS panel.
            if hit is None and dps_panel_visible and dps_pos is not None:
                dxp, dyp = dps_pos
                _dpw, _dph = dps_panel_size(dps_scale)
                if (dxp + _dpw - RESIZE_GRIP) <= mx < (dxp + _dpw) and \
                   (dyp + _dph - RESIZE_GRIP) <= my < (dyp + _dph):
                    hit = ("dps", "__dps__", dxp, dyp, "resize",
                           _dpw, _dph, dps_scale)
                elif dxp <= mx < dxp + _dpw and dyp <= my < dyp + _dph:
                    hit = ("dps", "__dps__", dxp, dyp, "move",
                           _dpw, _dph, dps_scale)

            # 6. Buff panel. Skip when autohidden (no entries +
            # autohide_buff_timer setting + not in setup mode) so users
            # don't accidentally drag an invisible panel.
            _buff_autohidden = (not _buff_entries
                                and setting("autohide_buff_timer")
                                and not setup_mode)
            if hit is None and buff_pos is not None and not _buff_autohidden:
                bxp, byp = buff_pos
                _bfw, _bfh = buff_panel_size(buff_scale, _buff_entries)
                if (bxp + _bfw - RESIZE_GRIP) <= mx < (bxp + _bfw) and \
                   (byp + _bfh - RESIZE_GRIP) <= my < (byp + _bfh):
                    hit = ("buff", "__buff__", bxp, byp, "resize",
                           _bfw, _bfh, buff_scale)
                elif bxp <= mx < bxp + _bfw and byp <= my < byp + _bfh:
                    hit = ("buff", "__buff__", bxp, byp, "move",
                           _bfw, _bfh, buff_scale)

            # 7. Recast panel. Same autohide skip.
            _recast_autohidden = (not _recast_entries
                                  and setting("autohide_recast")
                                  and not setup_mode)
            if hit is None and recast_pos is not None and not _recast_autohidden:
                rxp, ryp = recast_pos
                _rcw, _rch = recast_panel_size(recast_scale, _recast_entries)
                if (rxp + _rcw - RESIZE_GRIP) <= mx < (rxp + _rcw) and \
                   (ryp + _rch - RESIZE_GRIP) <= my < (ryp + _rch):
                    hit = ("recast", "__recast__", rxp, ryp, "resize",
                           _rcw, _rch, recast_scale)
                elif rxp <= mx < rxp + _rcw and ryp <= my < ryp + _rch:
                    hit = ("recast", "__recast__", rxp, ryp, "move",
                           _rcw, _rch, recast_scale)

            # 8. Equip viewer.
            if hit is None:
                ex, ey = equip_pos
                pw, ph, _, _ = equip_panel_size(equip_scale)
                if (ex + pw - RESIZE_GRIP) <= mx < (ex + pw) and \
                   (ey + ph - RESIZE_GRIP) <= my < (ey + ph):
                    hit = ("equip", "__equip__", ex, ey, "resize", pw, ph, equip_scale)
                elif ex <= mx < ex + pw and ey <= my < ey + ph:
                    hit = ("equip", "__equip__", ex, ey, "move", pw, ph, equip_scale)

            # 9. Alliance panels (ally1 + ally2).
            if hit is None:
                for _ally_list, _gid in ((ally1_data, 1), (ally2_data, 2)):
                    if hit is not None:
                        break
                    for _slot_idx in range(len(_ally_list)):
                        _akey = f"a{_gid}_{_slot_idx}"
                        if _akey not in panel_positions:
                            continue
                        _ax, _ay = panel_positions[_akey]
                        _scale = panel_scales.get(_akey, 1.0)
                        _d_a = scaled_ally_dims(_scale)
                        _rh_a = _d_a["row_min_h"]
                        _pw_a = _d_a["panel_w"]
                        if (_ax + _pw_a - RESIZE_GRIP) <= mx < (_ax + _pw_a) and \
                           (_ay + _rh_a - RESIZE_GRIP) <= my < (_ay + _rh_a):
                            hit = ("ally", _akey, _ax, _ay, "resize",
                                   _pw_a, _rh_a, _scale)
                            break
                        if _ax <= mx < _ax + _pw_a and _ay <= my < _ay + _rh_a:
                            hit = ("ally", _akey, _ax, _ay, "move",
                                   _pw_a, _rh_a, _scale)
                            break

            # 10. Party panels (last-drawn-among-party wins via reversed iter).
            if hit is None:
                for name in reversed(panel_order):
                    m = members_by_name.get(name)
                    if not m:
                        continue
                    px, py = panel_positions[name]
                    scale  = panel_scales.get(name, 1.0)
                    d      = scaled_panel_dims(scale)
                    rh     = row_height(m, scale)
                    pw     = d["panel_w"]
                    if (px + pw - RESIZE_GRIP) <= mx < (px + pw) and \
                       (py + rh - RESIZE_GRIP) <= my < (py + rh):
                        hit = ("party", name, px, py, "resize", pw, rh, scale)
                        break
                    if px <= mx < px + pw and py <= my < py + rh:
                        hit = ("party", name, px, py, "move", pw, rh, scale)
                        break

            if hit:
                kind, key, px, py, mode, pw, ph, scale = hit
                dragging_key     = key
                drag_mode        = mode
                drag_offset      = (mx - px, my - py)
                drag_start_scale = scale
                drag_start_size  = (pw, ph)
                # Raise party panels to the top of the draw order.
                if kind == "party":
                    panel_order.remove(key)
                    panel_order.append(key)

        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 3:
            # Right-click: nickname-edit on sim window equipment dropdown
            # options. Lets the user assign a friendly name to a specific
            # augmented item (e.g. "Cam DD" for one Camulus's Mantle and
            # "Cam Acc" for another). Stored persistently keyed by
            # (item_id, augment_fingerprint).
            mx, my = event.pos
            if sim_window_open:
                handled = False
                # Walk in reverse so dropdown options take priority over
                # the dropdown's parent row, matching the left-click
                # dispatcher's behavior.
                for rect, payload in reversed(sim_window_rects):
                    if not rect.collidepoint(mx, my):
                        continue
                    action = payload.get("action")
                    if action != "select":
                        continue
                    if payload.get("kind") != "equip_slot":
                        continue
                    value = payload.get("value")
                    if not isinstance(value, dict):
                        continue
                    iid = value.get("id")
                    bag = value.get("bag", 0)
                    idx = value.get("idx", 0)
                    fp_entry = _inv_for_sim.get("fingerprints", {}).get((bag, idx))
                    fp = fp_entry.get("fp", "") if fp_entry else ""
                    if not fp:
                        # No augments → no nickname target. Right-click
                        # is a no-op on plain items.
                        handled = True
                        break
                    # Open the nickname editor modal targeting this item.
                    cur_nick = _aug_nickname_for(iid, fp) or ""
                    sim_nickname_editor = {
                        "id": iid, "fp": fp, "text": cur_nick,
                        "cursor_blink": time.time(),
                    }
                    handled = True
                    break
                if handled:
                    continue

            # Right-click on a hotbar slot opens its editor directly,
            # entering edit mode first if needed. Skipped during setup
            # mode (which owns drag interactions on the panel). Right-
            # clicking a multi-mode panel's slot consumes the click but
            # doesn't open the editor (the editor only acts on panel 0).
            if buttons_panel_visible and not setup_mode:
                hot_hit = False
                _all_rects = list(buttons_rects)
                for _pi, _r in buttons_panel_rects.items():
                    _all_rects.extend(_r)
                for rect, payload in _all_rects:
                    if not rect.collidepoint(mx, my):
                        continue
                    # Decode (action_or_idx, panel_idx) tuple if present.
                    if isinstance(payload, tuple):
                        payload_kind, _panel = payload
                        target_panel = _panel
                    else:
                        payload_kind = payload
                        target_panel = 0
                    # Only numeric slot indices on the PRIMARY panel open
                    # the editor. Page-name/arrows on either panel and
                    # numeric slots on multi-mode panels just consume.
                    if isinstance(payload_kind, int) and target_panel == 0:
                        if not hotbar_edit_mode:
                            _open_hotbar_editor()
                        hotbar_select_slot(payload_kind)
                    hot_hit = True
                    break
                if hot_hit:
                    continue

        elif event.type == pygame.MOUSEBUTTONUP and event.button == 1:
            # Sim window drag-release. Done first since dragging_key checks
            # below assume a panel drag, not a free-floating window.
            if sim_window_drag is not None:
                sim_window_drag = None
                # Persist the new position so it survives restart.
                save_layout()
                continue
            if sim_window_resize is not None:
                sim_window_resize = None
                # Persist new dimensions.
                save_layout()
                continue
            if dragging_key is not None:
                # Re-anchor the dragged panel to whichever corner is nearest
                # its new position, so it stays pinned there across resizes.
                if dragging_key == "__equip__":
                    pw, ph, _, _ = equip_panel_size(equip_scale)
                    equip_anchor = anchor_for_pos(equip_pos[0], equip_pos[1],
                                                   pw, ph, WIDTH, HEIGHT)
                elif dragging_key == "__stats__":
                    if stats_pos is not None:
                        _jlist = None  # fixed layout
                        pw, ph = stats_panel_size(stats_scale, _jlist)
                        stats_anchor = anchor_for_pos(stats_pos[0], stats_pos[1],
                                                       pw, ph, WIDTH, HEIGHT)
                elif dragging_key == "__target__":
                    if target_pos is not None:
                        _ref = lookup_mob(target_sticky["name"]) if target_sticky else None
                        _mdb = (lookup_mobdb(target_sticky["name"],
                                             target_sticky.get("zone_id", 0))
                                if target_sticky else None)
                        _fam = ""
                        if _mdb and _mdb.get("family"):
                            _fam = _mdb["family"].lower()
                        if not _fam and target_sticky:
                            _fam = infer_family(target_sticky.get("name", "") or "")
                        if not _fam:
                            _fam = (_ref or {}).get("family", "").lower()
                        _abils, _achars = _tc_ability_info(_ref, _fam)
                        _stat  = mob_statuses.get((target_sticky or {}).get("id", 0), {})
                        _cstate = mob_cast_state.get((target_sticky or {}).get("id", 0))
                        _hcast  = bool(_cstate and (_cstate.get("casting") or _cstate.get("last_cast")))
                        _hdb   = any(not s.get("is_buff") for s in _stat.values())
                        _hbf   = any(s.get("is_buff")     for s in _stat.values())
                        _cchars = len(((_ref or {}).get("comments") or "").strip())
                        pw, ph = target_card_size(target_scale, _abils,
                                                   _mdb is not None,
                                                   _mdb is not None,
                                                   has_debuffs=_hdb, has_buffs=_hbf,
                                                   has_cast=_hcast,
                                                   ability_chars=_achars,
                                                   kind=(target_sticky or {}).get("kind", "mob"),
                                                   comments_chars=_cchars)
                        target_anchor = anchor_for_pos(target_pos[0], target_pos[1],
                                                        pw, ph, WIDTH, HEIGHT)
                elif dragging_key == "__target_st__":
                    if target_pos_st is not None:
                        _ref = lookup_mob(target_sticky_st["name"]) if target_sticky_st else None
                        _mdb = (lookup_mobdb(target_sticky_st["name"],
                                             target_sticky_st.get("zone_id", 0))
                                if target_sticky_st else None)
                        _fam = ""
                        if _mdb and _mdb.get("family"):
                            _fam = _mdb["family"].lower()
                        if not _fam and target_sticky_st:
                            _fam = infer_family(target_sticky_st.get("name", "") or "")
                        if not _fam:
                            _fam = (_ref or {}).get("family", "").lower()
                        _abils, _achars = _tc_ability_info(_ref, _fam)
                        _stat  = mob_statuses.get((target_sticky_st or {}).get("id", 0), {})
                        _cstate = mob_cast_state.get((target_sticky_st or {}).get("id", 0))
                        _hcast  = bool(_cstate and (_cstate.get("casting") or _cstate.get("last_cast")))
                        _hdb   = any(not s.get("is_buff") for s in _stat.values())
                        _hbf   = any(s.get("is_buff")     for s in _stat.values())
                        _cchars = len(((_ref or {}).get("comments") or "").strip())
                        pw, ph = target_card_size(target_scale_st, _abils,
                                                   _mdb is not None,
                                                   _mdb is not None,
                                                   has_debuffs=_hdb, has_buffs=_hbf,
                                                   has_cast=_hcast,
                                                   ability_chars=_achars,
                                                   kind=(target_sticky_st or {}).get("kind", "mob"),
                                                   comments_chars=_cchars)
                        target_anchor_st = anchor_for_pos(
                            target_pos_st[0], target_pos_st[1], pw, ph, WIDTH, HEIGHT)
                elif dragging_key == "__recast__":
                    if recast_pos is not None:
                        # Always force top-left anchor for variable-height
                        # panels. Other anchor corners cause the visible top
                        # to drift as entry count changes (panel grows from
                        # the anchored corner). Top-left = grows downward
                        # from the user's chosen position, predictable.
                        recast_anchor = ["tl",
                                         max(0, int(recast_pos[0])),
                                         max(0, int(recast_pos[1]))]
                elif dragging_key == "__buff__":
                    if buff_pos is not None:
                        # Same reasoning as recast: top-left only.
                        buff_anchor = ["tl",
                                       max(0, int(buff_pos[0])),
                                       max(0, int(buff_pos[1]))]
                elif dragging_key == "__dps__":
                    if dps_pos is not None:
                        dps_anchor = ["tl",
                                      max(0, int(dps_pos[0])),
                                      max(0, int(dps_pos[1]))]
                elif dragging_key == "__buttons__":
                    if buttons_pos is not None:
                        buttons_anchor = ["tl",
                                          max(0, int(buttons_pos[0])),
                                          max(0, int(buttons_pos[1]))]
                elif dragging_key.startswith("__buttons_") and dragging_key.endswith("__"):
                    # Multi-mode hotbar panel drag-end. Extract panel_idx
                    # from "__buttons_<n>__" and write the new anchor.
                    try:
                        _pi = int(dragging_key[len("__buttons_"):-2])
                    except ValueError:
                        _pi = None
                    if _pi is not None:
                        _ppos = buttons_panel_positions.get(_pi)
                        if _ppos is not None:
                            buttons_panel_anchors[_pi] = ["tl",
                                                          max(0, int(_ppos[0])),
                                                          max(0, int(_ppos[1]))]
                else:
                    # Party / alliance row drag-end. Each row drags
                    # independently; we just compute its new anchor and
                    # save it. (The "Lock tables" feature -- moving all
                    # rows in a table together -- was scrapped because
                    # it was unreliable across the multiple keying
                    # conventions panel_anchors uses.)
                    if dragging_key.startswith("a1_") or dragging_key.startswith("a2_"):
                        scale = panel_scales.get(dragging_key, 1.0)
                        d_a   = scaled_ally_dims(scale)
                        if dragging_key in panel_positions:
                            pos = panel_positions[dragging_key]
                            new_anchor = anchor_for_pos(
                                pos[0], pos[1], d_a["panel_w"], d_a["row_min_h"],
                                WIDTH, HEIGHT)
                            panel_anchors[dragging_key] = new_anchor
                    else:
                        m = members_by_name.get(dragging_key)
                        if m is not None:
                            scale = panel_scales.get(dragging_key, 1.0)
                            pw    = scaled_panel_dims(scale)["panel_w"]
                            rh    = row_height(m, scale)
                            pos   = panel_positions[dragging_key]
                            new_anchor = anchor_for_pos(
                                pos[0], pos[1], pw, rh, WIDTH, HEIGHT)
                            panel_anchors[dragging_key] = new_anchor
                            # Also write the slot-keyed anchor so it persists
                            # across parties (slot 0 = self, 1-5 = others).
                            try:
                                slot_idx = next(
                                    (i for i, mm in enumerate(party_data)
                                     if mm.get("name") == dragging_key),
                                    None)
                                if slot_idx is not None and slot_idx > 0:
                                    panel_anchors["p%d" % slot_idx] = new_anchor
                            except Exception:
                                pass
                save_layout()
            dragging_key = None
            drag_mode    = None

        elif event.type == pygame.MOUSEMOTION and sim_window_resize is not None:
            # Resize the sim window. Compute new size from start + mouse
            # delta. Min sizes prevent shrinking below usable; max is
            # bounded by the screen via clamping in draw_sim_window.
            mx, my = event.pos
            sw, sh, smx, smy = sim_window_resize
            nw = max(220, sw + (mx - smx))
            nh = max(SIM_WIN_HDR_H + 60, sh + (my - smy))
            sim_window_size[0] = nw
            sim_window_size[1] = nh

        elif event.type == pygame.MOUSEMOTION and sim_window_drag is not None:
            # Move the sim window with the mouse, preserving the grip
            # offset captured at MOUSEBUTTONDOWN so the corner-grab feel
            # is natural. Clamping happens in draw_sim_window each frame
            # so we don't need to do it here.
            mx, my = event.pos
            sim_window_pos[0] = mx - sim_window_drag[0]
            sim_window_pos[1] = my - sim_window_drag[1]

        elif event.type == pygame.MOUSEMOTION and dragging_key is not None:
            mx, my = event.pos

            if drag_mode == "move":
                new_x = mx - drag_offset[0]
                new_y = my - drag_offset[1]
                GRIP_VISIBLE = 40
                # Reuse the panel size captured at MOUSEBUTTONDOWN. The panel
                # doesn't resize during a drag (drag is pure translation), so
                # we don't need to recompute size here. Recomputing was
                # causing visible lag — target_card_size in particular pulls
                # mob_ref / mobdb / family inference / ability counts on
                # every mouse motion event, which is heavy work running at
                # cursor-poll rate.
                pw, ph = drag_start_size
                if dragging_key == "__equip__":
                    new_x = max(GRIP_VISIBLE - pw, min(new_x, WIDTH  - GRIP_VISIBLE))
                    new_y = max(HEADER_H,         min(new_y, HEIGHT - GRIP_VISIBLE))
                    equip_pos[0], equip_pos[1] = new_x, new_y
                elif dragging_key == "__stats__":
                    if stats_pos is not None:
                        new_x = max(GRIP_VISIBLE - pw, min(new_x, WIDTH  - GRIP_VISIBLE))
                        new_y = max(HEADER_H,         min(new_y, HEIGHT - GRIP_VISIBLE))
                        stats_pos[0], stats_pos[1] = new_x, new_y
                elif dragging_key == "__target__":
                    if target_pos is not None:
                        new_x = max(GRIP_VISIBLE - pw, min(new_x, WIDTH  - GRIP_VISIBLE))
                        new_y = max(HEADER_H,         min(new_y, HEIGHT - GRIP_VISIBLE))
                        target_pos[0], target_pos[1] = new_x, new_y
                elif dragging_key == "__target_st__":
                    if target_pos_st is not None:
                        new_x = max(GRIP_VISIBLE - pw, min(new_x, WIDTH  - GRIP_VISIBLE))
                        new_y = max(HEADER_H,         min(new_y, HEIGHT - GRIP_VISIBLE))
                        target_pos_st[0], target_pos_st[1] = new_x, new_y
                elif dragging_key == "__recast__":
                    if recast_pos is not None:
                        new_x = max(GRIP_VISIBLE - pw, min(new_x, WIDTH  - GRIP_VISIBLE))
                        new_y = max(HEADER_H,         min(new_y, HEIGHT - GRIP_VISIBLE))
                        recast_pos[0], recast_pos[1] = new_x, new_y
                elif dragging_key == "__buff__":
                    if buff_pos is not None:
                        new_x = max(GRIP_VISIBLE - pw, min(new_x, WIDTH  - GRIP_VISIBLE))
                        new_y = max(HEADER_H,         min(new_y, HEIGHT - GRIP_VISIBLE))
                        buff_pos[0], buff_pos[1] = new_x, new_y
                elif dragging_key == "__dps__":
                    if dps_pos is not None:
                        new_x = max(GRIP_VISIBLE - pw, min(new_x, WIDTH  - GRIP_VISIBLE))
                        new_y = max(HEADER_H,         min(new_y, HEIGHT - GRIP_VISIBLE))
                        dps_pos[0], dps_pos[1] = new_x, new_y
                elif dragging_key == "__buttons__":
                    if buttons_pos is not None:
                        new_x = max(GRIP_VISIBLE - pw, min(new_x, WIDTH  - GRIP_VISIBLE))
                        new_y = max(HEADER_H,         min(new_y, HEIGHT - GRIP_VISIBLE))
                        buttons_pos[0], buttons_pos[1] = new_x, new_y
                elif dragging_key.startswith("__buttons_") and dragging_key.endswith("__"):
                    # Multi-mode hotbar drag-motion.
                    try:
                        _pi = int(dragging_key[len("__buttons_"):-2])
                    except ValueError:
                        _pi = None
                    if _pi is not None and _pi in buttons_panel_positions:
                        new_x = max(GRIP_VISIBLE - pw, min(new_x, WIDTH  - GRIP_VISIBLE))
                        new_y = max(HEADER_H,          min(new_y, HEIGHT - GRIP_VISIBLE))
                        buttons_panel_positions[_pi][0] = new_x
                        buttons_panel_positions[_pi][1] = new_y
                else:
                    # Could be a main-party member (keyed by name) or an
                    # alliance slot (keyed a1_0..a2_5).
                    if dragging_key.startswith("a1_") or dragging_key.startswith("a2_"):
                        scale = panel_scales.get(dragging_key, 1.0)
                        pw    = scaled_ally_dims(scale)["panel_w"]
                        new_x = max(GRIP_VISIBLE - pw, min(new_x, WIDTH  - GRIP_VISIBLE))
                        new_y = max(HEADER_H,          min(new_y, HEIGHT - GRIP_VISIBLE))
                        if dragging_key in panel_positions:
                            panel_positions[dragging_key][0] = new_x
                            panel_positions[dragging_key][1] = new_y
                    else:
                        m = members_by_name.get(dragging_key)
                        if m is not None:
                            scale = panel_scales.get(dragging_key, 1.0)
                            d     = scaled_panel_dims(scale)
                            pw    = d["panel_w"]
                            new_x = max(GRIP_VISIBLE - pw, min(new_x, WIDTH  - GRIP_VISIBLE))
                            new_y = max(HEADER_H,          min(new_y, HEIGHT - GRIP_VISIBLE))
                            panel_positions[dragging_key][0] = new_x
                            panel_positions[dragging_key][1] = new_y

            elif drag_mode == "resize":
                # Scale based on how far the mouse is from the panel's top-left.
                # Using width as the reference axis keeps behaviour predictable.
                if dragging_key == "__equip__":
                    ex, ey       = equip_pos
                    start_w, _   = drag_start_size
                    target_w     = max(40, mx - ex)
                    new_scale    = drag_start_scale * (target_w / max(1, start_w))
                    equip_scale  = max(MIN_SCALE, min(MAX_SCALE, new_scale))
                elif dragging_key == "__stats__":
                    if stats_pos is not None:
                        sx2, sy2   = stats_pos
                        start_w, _ = drag_start_size
                        target_w   = max(60, mx - sx2)
                        new_scale  = drag_start_scale * (target_w / max(1, start_w))
                        stats_scale = max(MIN_SCALE, min(MAX_SCALE, new_scale))
                elif dragging_key == "__target__":
                    if target_pos is not None:
                        txp, typ    = target_pos
                        start_w, _  = drag_start_size
                        target_w    = max(60, mx - txp)
                        new_scale   = drag_start_scale * (target_w / max(1, start_w))
                        target_scale = max(MIN_SCALE, min(MAX_SCALE, new_scale))
                elif dragging_key == "__target_st__":
                    if target_pos_st is not None:
                        txp, typ    = target_pos_st
                        start_w, _  = drag_start_size
                        target_w    = max(60, mx - txp)
                        new_scale   = drag_start_scale * (target_w / max(1, start_w))
                        target_scale_st = max(MIN_SCALE, min(MAX_SCALE, new_scale))
                elif dragging_key == "__recast__":
                    if recast_pos is not None:
                        rxp, ryp    = recast_pos
                        start_w, _  = drag_start_size
                        target_w    = max(60, mx - rxp)
                        new_scale   = drag_start_scale * (target_w / max(1, start_w))
                        recast_scale = max(MIN_SCALE, min(MAX_SCALE, new_scale))
                elif dragging_key == "__buff__":
                    if buff_pos is not None:
                        bxp, byp    = buff_pos
                        start_w, _  = drag_start_size
                        target_w    = max(60, mx - bxp)
                        new_scale   = drag_start_scale * (target_w / max(1, start_w))
                        buff_scale  = max(MIN_SCALE, min(MAX_SCALE, new_scale))
                elif dragging_key == "__dps__":
                    if dps_pos is not None:
                        dxp, dyp    = dps_pos
                        start_w, _  = drag_start_size
                        target_w    = max(60, mx - dxp)
                        new_scale   = drag_start_scale * (target_w / max(1, start_w))
                        dps_scale   = max(MIN_SCALE, min(MAX_SCALE, new_scale))
                elif dragging_key == "__buttons__":
                    if buttons_pos is not None:
                        bxp, byp       = buttons_pos
                        start_w, _     = drag_start_size
                        target_w       = max(60, mx - bxp)
                        new_scale      = drag_start_scale * (target_w / max(1, start_w))
                        buttons_scale  = max(MIN_SCALE, min(MAX_SCALE, new_scale))
                elif dragging_key.startswith("__buttons_") and dragging_key.endswith("__"):
                    # Multi-mode hotbar resize. All panels share buttons_scale
                    # (so sizes stay aligned between the primary and extras).
                    try:
                        _pi = int(dragging_key[len("__buttons_"):-2])
                    except ValueError:
                        _pi = None
                    if _pi is not None and _pi in buttons_panel_positions:
                        bxp, byp       = buttons_panel_positions[_pi]
                        start_w, _     = drag_start_size
                        target_w       = max(60, mx - bxp)
                        new_scale      = drag_start_scale * (target_w / max(1, start_w))
                        buttons_scale  = max(MIN_SCALE, min(MAX_SCALE, new_scale))
                else:
                    px, py     = panel_positions[dragging_key]
                    start_w, _ = drag_start_size
                    target_w   = max(40, mx - px)
                    new_scale  = drag_start_scale * (target_w / max(1, start_w))
                    panel_scales[dragging_key] = max(MIN_SCALE, min(MAX_SCALE, new_scale))

# Save on quit too, in case the window was closed mid-drag.
save_layout()
pygame.quit()