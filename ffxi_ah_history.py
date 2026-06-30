#!/usr/bin/env python3
"""
ffxi_ah_history.py - query a FINAL FANTASY XI *search server* directly for an
item's auction-house sale history, the same way FFXIAH does (no game client).

Speaks the retail / LandSandBoat search-server protocol:
  - Blowfish (FFXI's non-standard F-function) + MD5 packet framing
  - no session handshake: connect, send one AH-history request, read reply, close
  - returns up to the 10 most recent SOLD listings (price, date, seller, buyer)
    plus the item's current on-AH count.

Author: BalladOfWorms

Usage:
    python ffxi_ah_history.py <host> <port> <itemid> [--stack] [--debug]
    python ffxi_ah_history.py --auto <itemid> [--stack]   # detect your world's server
    python ffxi_ah_history.py --selftest        # offline crypto/framing proof

Notes:
  - <itemid> is the FFXI item id (the number in an ffxiah.com/item/<id> URL).
  - --stack queries stack price/history instead of single.
  - History depth is whatever the search server returns (retail caps at the last
    ~10 sales per item, same as the in-game AH "recent sales"); long-term price
    curves require accumulating these snapshots over time yourself.
  - Validate against your own LandSandBoat search server first (identical
    protocol, zero risk) before pointing at a retail world.
"""

import base64
import socket
import struct
import os
import sys
import hashlib

# Blowfish P/S subkey table (digits of pi) lifted verbatim from the search
# server: P = first 72 bytes (18 x uint32 LE), S = next 4096 bytes (1024 LE).
_SUBKEY = base64.b64decode(
    "iGo/JNMIo4UuihkTRHNwAyI4CaTQMZ8pmPouCIlsTuzmIShFdxPQOM9mVL5sDOk0tymswN1QfMm1"
    "1YQ/FwlHtdnVFpIb+3mJpgsx0ay135jbcv0vt98a0O2v4biWfiZqRZB8upl/LPFHmaEk92yRs+Ly"
    "AQgW/I6F2CBpY2lOV3Gj/likfj2T9I90lQ1Yto5yWM2Lce5KFYIdpFR7tVlawjnVMJwTYPIqI7DR"
    "xfCFYCgYeUHK7zjbuLDceY4OGDpgiw6ebD6KHrDBdxXXJ0sxvdovr3hgXGBV8yVV5pSrVapimEhX"
    "QBToY2o5ylW2EKsqNFzMtM7oQRGvhlShk+lyfBEU7rMqvG9jXcWpK/YxGHQWPlzOHpOHmzO61q9c"
    "zyRsgVMyeneGlSiYSI87r7lLaxvov8STIShmzAnYYZGpIftgrHxIMoDsXV1dhO+xdYXpAiMm3Igb"
    "ZeuBPokjxayW0/NvbQ85QvSDgkQLLgQghKRK8MhpXpsfnkJoxiGabOn2YZwMZ/CI06vSoFFqaC9U"
    "2CinD5ajM1GrbAvvbuQ7ehNQ8Du6mCr7fh1l8aF2Aa85PlnKZogOQ4IZhu6MtJ9vRcOlhH2+Xos7"
    "2HVv4HMgwYWfRBpApmrBVmKq004Gdz82ct/+Gz0Cm0Ik19A3SBIK0NPqD9ubwPFJyXJTB3sbmYDY"
    "edQl997o9hpQ/uM7THm2veBsl7oGwAS2T6nBxGCfQMKeXF5jJGoZr2/7aLVTbD7rsjkTb+xSOx9R"
    "/G0slTCbREWBzAm9Xq8E0OO+/Uoz3gcoD2azSy4ZV6jLwA90yEU5XwvS2/vTub3AeVUKMmAaxgCh"
    "1nlyLED+JZ9nzKMf+/jppY74IjLb3xZ1PBVrYf3IHlAvq1IFrfq1PTJghyP9SHsxU4LfAD67V1ye"
    "oIxvyi5WhxrbaRff9qhC1cP/fijGMmesc1VPjLAnW2nIWMq7XaP/4aAR8LiYPfoQuIMh/Wy1/Epb"
    "09EteeRTmmVF+La8SY7SkJf7S9ry3eEzfsukQRP7YujG5M7ayiDvAUx3Nv6eftC0H/ErTdrblZiR"
    "kK5xjq3qoNWTa9DRjtDgJcevL1s8jreUdY774vaPZCsS8hK4iIgc8A2QoF6tTxzDj2iR8c/RrcGo"
    "sxgiLy93Fw6+/i116qEfAosPzKDl6HRvtdbzrBiZ4onO4E+otLfgE/2BO8R82ait0maiXxYFd5WA"
    "FHPMk3cUGiFlIK3mhvq1d/VCVMfPNZ37DK/N66CJPnvTG0HWSX4eri0OJQBes3EguwBoIq/guFeb"
    "NmQkHrkJ8B2RY1Wqpt9ZiUPBeH9TWtmiW30gxbnlAnYDJoOpz5ViaBnIEUFKc07KLUezSqkUe1IA"
    "URsVKVOaP1cP1uTGm7x2pGArAHTmgbVvuggf6RtXa+yW8hXZDSohZWO2tvm55y4FNP9kVoXFXS2w"
    "U6GPn6mZR7oIageFbulwektEKbO1Lgl12yMmGcSwpm6tfd+nSbhg7pxmsu2PcYyq7P8XmmlsUmRW"
    "4Z6xwqUCNhkpTAl1QBNZoD46GOSamFQ/ZZ1CW9bkj2vWP/eZB5zSofUw6O/mOC1NwV0l8IYg3Uwm"
    "63CExumCY17MHgI/a2gJye+6PhQYlzyhcGprhDV/aIbioFIFU5y3NwdQqhyEBz5crt5/7ER9jrjy"
    "Flc32jqwDQxQ8AQfHPD/swACGvUMrrJ0tTxYeoMlvSEJ3PkTkdH2L6l8c0cylAFH9SKB5eU63NrC"
    "NzR2tcin3fOaRmFEqQ4D0A8+x8jsQR51pJnNOOIvDuo7obuAMjGzPhg4i1ROCLltTwMNQm+/BAr2"
    "kBK4LHl8lyRysHlWr4mvvB93mt4QCJPZEq6Lsy4/z9wfchJVJHFrLubdGlCHzYSfGEdYehfaCHS8"
    "mp+8jH1L6Trseuz6HYXbZkMJY9LDZMRHGBzvCNkVMjc7Q90WusIkQ02hElHEZSoCAJRQ3eQ6E574"
    "33FVTjEQ1nesgZsZEV/xVjUEa8ej1zsYETwJpSRZ7eaP8vr78Zcsv7qebjwVHnBF44axb+nqCl4O"
    "hrMqPloc5x93+gY9TrncZSkPHeeZ1ok+gCXIZlJ4yUwuarMQnLoOFcZ46uKUUzz8pfQtCh6nTvfy"
    "PSsdNg8mORlgecIZCKcjUrYSE/du/q3rZh/D6pVFvOODyHum0Td/sSj/jAHv3TLDpVpsvoUhWGUC"
    "mKtoD6XO7juVL9utfe8qhC9uWyi2IRVwYQcpdUfd7BAVn2EwqMwTlr1h6x7+NAPPYwOqkFxztTmi"
    "cEwLnp7VFN6qy7yGzO6nLGJgq1yrnG6E87KvHotkyvC9GblpI6BQu1plMlpoQLO0KjzV6Z4x97gh"
    "wBkLVJuZoF+Hfpn3lah9PWKaiDf4dy3jl1+T7RGBEmgWKYg1DtYf5seh396WmbpYeKWE9VdjciIb"
    "/8ODm5ZGwhrrCrPNVDAuU+RI2Y8oMbxt7/LrWOr/xjRh7Sj+czx87tkUSl3jt2ToFF0QQuATPiC2"
    "4u5F6quqoxVPbNvQT8v6QvRCx7W7au8dO09lBSHNQZ55HtjHTYWGakdL5FBigT3yoWLPRiaNW6CD"
    "iPyjtsfBwyQVf5J0y2kLioRHhbKSVgC/WwmdSBmtdLFiFAAOgiMqjUJY6vVVDD70rR1hcD8jkvBy"
    "M0F+k43x7F/W2zsibFk33nxgdO7Lp/KFQG4yd86EgAemnlD4GVXY7+g1l9lhqqdpqcIGDMX8qwRa"
    "3MoLgC56RJ6ENEXDBWfV/cmeHg7T23PbzYhVEHnaX2dAQ2fjZTTExdg4PnGe+Cg9IP9t8echPhVK"
    "PbCPK5/j5vetg9toWj3p90CBlBwmTPY0KWmU9yAVQffUAnYua/S8aACi1HEkCNRq9CAzt9S3Q69h"
    "AFAu9jkeRkUkl3RPIRRAiIu/HfyVTa+RtZbT3fRwRS+gZuwJvL+Fl70D0G2sfwSFyzGzJ+uWQTn9"
    "VeZHJdqaCsqrJXhQKPQpBFPahiwK+2226WIU3GgAaUjXpMAOaO6NoSei/j9PjK2H6AbgjLW21vR6"
    "fB7OquxfN9OZo3jOQiprQDWe/iC5hfPZq9c57otOEjv3+skdVhhtSzFmoyayl+PqdPpuOjJDW933"
    "50Fo+yB4yk71CvuXs/7YrFZARSeVSLo6OlNVh42DILepa/5LlZbQvGeoVViaFaFjKanMM9vhmVZK"
    "Kqb5JTE/HH70XnwxKZAC6Pj9cC8nBFwVu4DjLCgFSBXBlSJtxuQ/E8FI3IYPx+7J+QcPHwRBpHlH"
    "QBduiF3rUV8y0cCb1Y/BvPJkNRFBNHh7JWCcKmCj6PjfG2xjH8K0Eg6eMuEC0U9mrxWB0crglSNr"
    "4ZI+M2ILJDsiub7uDqKyhZkNuuaMDHLeKPeiLUV4EtD9lLeVYgh9ZPD1zOdvo0lU+kh9hyf9ncMe"
    "jT7zQWNHCnT/Lpmrbm86N/349GDcEqj43euhTOEbmQ1rbtsQVXvGNyxnbTvUZScE6NDcxw0p8aP/"
    "AMySDzm1C+0Pafufe2acfdvOC8+RoKNeFdmILxO7JK1bUb95lHvr1jt2sy45N3lZEcyX4iaALTEu"
    "9KetQmg7K2rGzEx1EhzxLng3QhJq51GSt+a7oQZQY/tLGBBrGvrtyhHYvSU9ycPh4lkWQkSGExIK"
    "buwM2Srqq9VOZ69kX6iG2ojpv77+w+RkV4C8nYbA9/D4e3hgTWADYEaD/dGwHzj2BK5Fd8z8Ntcz"
    "a0KDcase8IdBgLBfXgA8vlegdySu6L2ZQkZVYS5Yv4/0WE6i/d3yOO909MK9iYfD+WZTdI6zyFXy"
    "dbS52fxGYSbreoTfHYt5DmqE4pVfkY5ZbkZwV7QgkVXVjEzeAsnhrAu50AWCu0hiqBGeqXR1thl/"
    "twncqeChCS1mM0YyxAIfWuiMvvAJJaCZShD+bh0dPbka36SlCw/yhqFp8Wgog9q33P4GOVebzuKh"
    "Un/NTwFeEVD6gwanxLUCoCfQ5g0njPiaQYY/dwZMYMO1BqhhKHoX8OCG9cCqWGAAYn3cMNee5hFj"
    "6jgjlN3CUzQWwsJW7su73ra8kKF9/Ot2HVnOCeQFb4gBfEs9CnI5JHySfF9y44a5nU1ytFvBGvy4"
    "ntN4VVTttaX8CNN8PdjED61NXu9QHvjmYbHZFIWiPBNRbOfH1W/ETuFWzr8qNjfIxt00MprXEoJj"
    "ko76DmfgAGBAN845Os/1+tM3d8KrGy3FWp5nsFxCN6NPQCeC076bvJmdjhHVFXMPv34cLdZ7xADH"
    "axuMt0WQoSG+sW6ytG42ai+rSFd5bpS80najxsjCSWXu+A9Tfd6NRh0Kc9XGTdBM27s5KVBGuqno"
    "JpWsBONevvDV+qGaUS1q4ozvYyLuhpq4wonA9i4kQ6oDHqWk0PKcumHAg01q6ZtQFeWP1ltkuvmi"
    "JijhOjqnhpWpS+liVe/T7y/H2vdS92lvBD9ZCvp3FankgAGGsIet5gmbk+U+O1r9kOmX1zSe2bfw"
    "LFGLKwI6rNWWfaZ9AdY+z9EoLX18zyWfH5u48q1ytNZaTPWIWnGsKeDmpRng/aywR5v6k+2NxNPo"
    "zFc7KClm1fgoLhN5kQFfeFVgde1EDpb3jF7T49RtBRW6bfSIJWGhA73wZAUVnuvDoleQPOwaJ5cq"
    "Bzqpm20/G/UhYx77Zpz1GfPcJijZM3X1/VWxgjRWA7s8uooRd1Eo+NkKwmdRzKtfkq3MURfoTY7c"
    "MDhiWJ03kfkgk8KQeurOez77ZM4hUTK+T3d+47aoRj0pw2lT3kiA5hNkEAiuoiSybd39LYVpZiEH"
    "CQpGmrPdwEVkz95sWK7IIBzd975bQI1YG38B0sy747Rrfmqi3UX/WTpECjU+1c20vKjO6nK7hGT6"
    "rhJmjUdvPL9j5JvSnl0vVBt3wq5wY072jQ0OdFcTW+dxFnL4XX1TrwjLQEDM4rROakbSNISvFQEo"
    "BLDhHTqYlbSfuAZIoG7Ogjs/b4KrIDVLHRoB+CdyJ7FgFWHcP5PnK3k6u70lRTThOYigS3nOUbfJ"
    "Mi/Juh+gfsgc4PbRx7zDEQHPx6rooUmHkBqavU/Uy97a0DjaCtUqwzkDZzaRxnwx+Y1PK7Hgt1me"
    "9zq79UP/GdXynEXZJywil78q/OYVcfyRDyUVlJthk+X665y2zllkqMLRqLoSXgfBtgxqBeNlUNIQ"
    "QqQDyw5u7OA725gWvqCYTGTpeDIylR+f35LT4Cs0oNMe8nGJQXQKG4w0o0sgcb7F2DJ2w42fNd8u"
    "L5mbR28L5h3x4w9U2kzlkdjaHs95Ys5vfj7NZrEYFgUdLP3F0o+EmSL79lfzI/UjdjKmMTWokwLN"
    "zFZigfCstet1Wpc2Fm7Mc9KIkmKW3tBJuYEbkFBMFFbGcb3HxuYKFHoyBtDhRZp78sP9U6rJAA+o"
    "YuK/Jbv20r01BWkScSICBLJ8z8u2K5x2zcA+EVPT40AWYL2rOPCtRyWcIDi6ds5G98Whr3dgYHUg"
    "Tv7LhdiN6Iqw+ap6fqr5TFzCSBmMivsC5GrDAfnh69Zp+NSQoN5cpi0lCT+f5gjCMmFOt1vid87j"
    "349X5nLDOg=="
)
assert len(_SUBKEY) == 4168

# 16-byte key seed; rest of the 24-byte key buffer is filled per-packet.
KEY_SEED = bytes((0x30, 0x73, 0x3D, 0x6D, 0x3C, 0x31, 0x49, 0x5A,
                  0x32, 0x7A, 0x42, 0x43, 0x63, 0x38, 0x7B, 0x7E))
IXFF = 0x46465849  # "IXFF" magic at offset 0x04

TCP_AH_HISTORY_SINGLE = 0x05  # request type byte at offset 0x0B
TCP_AH_HISTORY_STACK  = 0x06

SEARCH_PORT_DEFAULT = 54002  # retail/LSB search-server TCP port

_MASK = 0xFFFFFFFF


def _load_ps():
    P = list(struct.unpack("<18I", _SUBKEY[0:72]))
    S = list(struct.unpack("<1024I", _SUBKEY[72:72 + 4096]))
    return P, S


def _TT(x, S):
    # FFXI's non-standard F-function: boxes 1 and 3 collapse to (val & 1) ^ 32;
    # boxes 0 and 2 contribute fully. uint32 wraparound on the sum.
    return ((((S[256 + ((x >> 8) & 0xFF)] & 1) ^ 32)
             + ((S[768 + ((x >> 24) & 0xFF)] & 1) ^ 32)
             + S[512 + ((x >> 16) & 0xFF)]
             + S[x & 0xFF]) & _MASK)


def _encipher(xl, xr, P, S):
    for i in range(16):
        xl = (xl ^ P[i]) & _MASK
        xr = (_TT(xl, S) ^ xr) & _MASK
        xl, xr = xr, xl
    xl, xr = xr, xl
    xr = (xr ^ P[16]) & _MASK
    xl = (xl ^ P[17]) & _MASK
    return xl, xr


def _decipher(xl, xr, P, S):
    for i in range(17, 1, -1):
        xl = (xl ^ P[i]) & _MASK
        xr = (_TT(xl, S) ^ xr) & _MASK
        xl, xr = xr, xl
    xl, xr = xr, xl
    xr = (xr ^ P[1]) & _MASK
    xl = (xl ^ P[0]) & _MASK
    return xl, xr


def _blowfish_init(key_bytes):
    # The server treats the key as SIGNED int8, so digest bytes >= 0x80
    # sign-extend when folded into the P-array. Replicate exactly.
    P, S = _load_ps()
    n = len(key_bytes)
    j = 0
    for i in range(18):
        data = 0
        for _ in range(4):
            b = key_bytes[j]
            sb = b - 256 if b >= 128 else b          # int8
            data = ((data << 8) | (sb & _MASK)) & _MASK
            j += 1
            if j >= n:
                j = 0
        P[i] = (P[i] ^ data) & _MASK
    dl, dr = 0, 0
    for i in range(0, 18, 2):
        dl, dr = _encipher(dl, dr, P, S)
        P[i], P[i + 1] = dl, dr
    for i in range(4):
        for k in range(0, 256, 2):
            dl, dr = _encipher(dl, dr, P, S)
            S[i * 256 + k], S[i * 256 + k + 1] = dl, dr
    return P, S


def _cipher_blocks(buf, length, P, S, decrypt):
    # Mirrors the server loop: uint32 pairs from byte 8 (uint32 index 2);
    # tmp = ((length-12)//4) rounded down to even.
    tmp = (length - 12) // 4
    tmp -= tmp % 2
    i = 0
    while i < tmp:
        o = 8 + i * 4
        xl, xr = struct.unpack_from("<II", buf, o)
        xl, xr = (_decipher if decrypt else _encipher)(xl, xr, P, S)
        struct.pack_into("<II", buf, o, xl, xr)
        i += 2


def _md5(b):
    return hashlib.md5(b).digest()


# --- request build (client -> server); mirrors server decrypt()/validate() ---
def build_ah_history_request(item_id, stack=False, key_tail=None):
    """Build a search-server AH sale-history request, matching the real client
    packet family observed on retail: 76 bytes, size@0x00, IXFF@0x04, a
    [u16 size][0x80 flag][type] sub-header at 0x08 (the 0x80 flag byte is
    required), item id@0x12, stack@0x15, md5 hash + key tail footer."""
    if key_tail is None:
        key_tail = os.urandom(4)
    length = 76
    buf = bytearray(length)
    struct.pack_into("<H", buf, 0x00, length)
    struct.pack_into("<I", buf, 0x04, IXFF)
    struct.pack_into("<H", buf, 0x08, 16)          # sub-size (mirrors observed minimal request)
    buf[0x0A] = 0x80                                # flags byte present on every real packet
    buf[0x0B] = TCP_AH_HISTORY_STACK if stack else TCP_AH_HISTORY_SINGLE
    struct.pack_into("<H", buf, 0x12, item_id & 0xFFFF)
    buf[0x15] = 1 if stack else 0
    # key2 region (length-0x18 = 0x34) left zero -> response encrypted with key2=0
    buf[length - 0x14:length - 0x04] = _md5(bytes(buf[0x08:length - 0x14]))
    buf[length - 0x04:length] = key_tail
    P, S = _blowfish_init(_md5(KEY_SEED + key_tail))
    _cipher_blocks(buf, length, P, S, decrypt=False)
    return bytes(buf), key_tail


def _req_key20_24(item_id, stack):
    """The key2 the server derives from the request (decrypted bytes at
    length-0x18). We zero that region, so this is zero; kept explicit so the
    response decrypt mirrors the server exactly."""
    return b"\x00\x00\x00\x00"


def _decode_name(raw):
    z = raw.find(b"\x00")
    if z >= 0:
        raw = raw[:z]
    return raw.decode("latin-1", "replace").strip()


def parse_ah_history_response(buf, key_tail, req_key20_24):
    buf = bytearray(buf)
    length = struct.unpack_from("<H", buf, 0x00)[0]
    if length < 28 or length > len(buf):
        raise ValueError("bad response length %d (have %d bytes)" % (length, len(buf)))
    P, S = _blowfish_init(_md5(KEY_SEED + key_tail + req_key20_24))
    _cipher_blocks(buf, length, P, S, decrypt=True)

    item_id  = struct.unpack_from("<H", buf, 0x18)[0]
    amount    = struct.unpack_from("<I", buf, 0x1A)[0]
    category = struct.unpack_from("<H", buf, 0x1E)[0]
    marker   = struct.unpack_from("<H", buf, 0x08)[0]   # 0x20 + 40*count
    n = max(0, (marker - 0x20) // 40)

    sales = []
    for i in range(n):
        o = 0x20 + 40 * i
        if o + 40 > length:
            break
        price = struct.unpack_from("<I", buf, o + 0x00)[0]
        date  = struct.unpack_from("<I", buf, o + 0x04)[0]
        seller = _decode_name(bytes(buf[o + 0x08:o + 0x08 + 15]))
        buyer  = _decode_name(bytes(buf[o + 0x18:o + 0x18 + 15]))
        sales.append({"price": price, "date": date,
                      "seller": seller, "buyer": buyer})
    return {"item_id": item_id, "amount": amount,
            "category": category, "sales": sales}



def find_search_server(port=SEARCH_PORT_DEFAULT):
    """Auto-detect the current world's search server by reading this PC's TCP
    connection table for an established remote endpoint on the search port.
    The FFXI client opens that connection when you use the AH / search in-game,
    so it points at whatever world you're logged into. Returns an IP string or
    None. (psutil if available, else `netstat`.)"""
    try:
        import psutil
        for c in psutil.net_connections(kind="tcp"):
            if c.raddr and c.raddr.port == port and c.status == psutil.CONN_ESTABLISHED:
                return c.raddr.ip
    except Exception:
        pass
    import subprocess
    import re
    out = ""
    for cmd in (["netstat", "-ano", "-p", "TCP"], ["netstat", "-an"]):
        try:
            out = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
            break
        except Exception:
            continue
    pat = re.compile(r"(\d{1,3}(?:\.\d{1,3}){3}):%d\b" % port)
    for line in out.splitlines():
        if (":%d" % port) in line and ("ESTABLISHED" in line.upper()):
            m = pat.search(line)
            if m:
                return m.group(1)
    return None


def query(host, port, item_id, stack=False, timeout=8.0, debug=False):
    req, key_tail = build_ah_history_request(item_id, stack)
    key20_24 = _req_key20_24(item_id, stack)
    with socket.create_connection((host, port), timeout=timeout) as s:
        s.sendall(req)
        s.settimeout(timeout)
        data = b""
        try:
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
                if len(data) >= 2 and len(data) >= struct.unpack_from("<H", data, 0)[0]:
                    break
        except socket.timeout:
            pass
    if debug:
        sys.stderr.write("recv %d bytes\n" % len(data))
    if len(data) < 2:
        raise ConnectionError("no/short response (%d bytes)" % len(data))
    return parse_ah_history_response(data, key_tail, key20_24)


# --- offline self-test: simulate the full client<->server exchange, no network ---
def _server_simulate(req_bytes, sample):
    buf = bytearray(req_bytes)
    length = struct.unpack_from("<H", buf, 0x00)[0]
    assert length >= 28 and length == len(buf), "server: size check"
    key_tail = bytes(buf[length - 0x04:length])
    P, S = _blowfish_init(_md5(KEY_SEED + key_tail))
    _cipher_blocks(buf, length, P, S, decrypt=True)
    assert bytes(buf[length - 0x14:length - 0x04]) == _md5(bytes(buf[0x08:length - 0x14])), \
        "server: hash mismatch"
    ptype = buf[0x0B]
    item_id = struct.unpack_from("<H", buf, 0x12)[0]
    stack = buf[0x15]
    key20_24 = bytes(buf[length - 0x18:length - 0x18 + 4])

    n = len(sample["sales"])
    rlen = 0x20 + 40 * n + 28
    r = bytearray(rlen)
    struct.pack_into("<H", r, 0x08, 0x20 + 40 * n)
    r[0x0A] = 0x80
    r[0x0B] = 0x85
    struct.pack_into("<H", r, 0x10, item_id)
    struct.pack_into("<H", r, 0x18, item_id)
    struct.pack_into("<I", r, 0x1A, sample["amount"])
    struct.pack_into("<H", r, 0x1E, sample["category"])
    for i, sale in enumerate(sample["sales"]):
        o = 0x20 + 40 * i
        struct.pack_into("<I", r, o + 0x00, sale["price"])
        struct.pack_into("<I", r, o + 0x04, sale["date"])
        r[o + 0x08:o + 0x08 + len(sale["seller"])] = sale["seller"].encode()
        r[o + 0x18:o + 0x18 + len(sale["buyer"])] = sale["buyer"].encode()
    struct.pack_into("<H", r, 0x00, rlen)
    struct.pack_into("<I", r, 0x04, IXFF)
    Pr, Sr = _blowfish_init(_md5(KEY_SEED + key_tail + key20_24))
    r[rlen - 0x14:rlen - 0x04] = _md5(bytes(r[0x08:rlen - 0x14]))
    _cipher_blocks(r, rlen, Pr, Sr, decrypt=False)
    r[rlen - 0x04:rlen] = key_tail
    return bytes(r), ptype, item_id, stack


def selftest():
    print("[*] Blowfish round-trip (encipher then decipher == identity)...")
    P, S = _blowfish_init(_md5(KEY_SEED + b"\x01\x02\x03\x04"))
    a, b = 0x01234567, 0x89ABCDEF
    assert _decipher(*_encipher(a, b, P, S), P, S) == (a, b), "round-trip failed"
    print("    OK")

    print("[*] Full request/response simulation...")
    sample = {"item_id": 4520, "amount": 7, "category": 10, "sales": [
        {"price": 1234,  "date": 1700000000, "seller": "Wormfood", "buyer": "Expiredmilk"},
        {"price": 999,   "date": 1700100000, "seller": "Somebody", "buyer": "Otherguy"},
        {"price": 50000, "date": 1700200000, "seller": "Trader",   "buyer": "Buyer3"},
    ]}
    for stack in (False, True):
        req, key_tail = build_ah_history_request(sample["item_id"], stack)
        resp, ptype, gid, gstack = _server_simulate(req, sample)
        assert ptype == (TCP_AH_HISTORY_STACK if stack else TCP_AH_HISTORY_SINGLE)
        assert gid == sample["item_id"] and bool(gstack) == stack
        out = parse_ah_history_response(resp, key_tail, _req_key20_24(sample["item_id"], stack))
        assert out["item_id"] == sample["item_id"], out
        assert out["amount"] == sample["amount"], out
        assert len(out["sales"]) == len(sample["sales"]), out
        for got, exp in zip(out["sales"], sample["sales"]):
            assert got == exp, (got, exp)
        print("    stack=%s OK (%d sales round-tripped)" % (stack, len(out["sales"])))
    print("[+] SELFTEST PASSED")


def _fmt_date(ts):
    import datetime
    try:
        return datetime.datetime.utcfromtimestamp(ts).strftime("%Y-%m-%d")
    except Exception:
        return str(ts)


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    if len(argv) < 4:
        print(__doc__)
        return 2
    if argv[1] == "--auto":
        if len(argv) < 3:
            print("usage: ffxi_ah_history.py --auto <itemid> [--stack] [--debug]")
            return 2
        host = find_search_server()
        if not host:
            print("Could not find the search server connection on port %d.\n"
                  "Open the Auction House (or use /search) in-game once so the\n"
                  "client connects, then run this again." % SEARCH_PORT_DEFAULT)
            return 1
        port = SEARCH_PORT_DEFAULT
        item_id = int(argv[2])
        stack = "--stack" in argv[3:]
        print("Detected search server: %s:%d" % (host, port))
    else:
        host, port, item_id = argv[1], int(argv[2]), int(argv[3])
        stack = "--stack" in argv[4:]
    res = query(host, port, item_id, stack=stack, debug=("--debug" in argv))
    print("Item %d  |  on AH now: %d  |  category: %d  |  %s"
          % (res["item_id"], res["amount"], res["category"], "stack" if stack else "single"))
    if not res["sales"]:
        print("  (no recent sales returned)")
    for s in res["sales"]:
        print("  %12d gil   %s   %-15s -> %-15s"
              % (s["price"], _fmt_date(s["date"]), s["seller"], s["buyer"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))