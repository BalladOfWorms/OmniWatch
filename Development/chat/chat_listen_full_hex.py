"""Always-hex listener. Shows hex for EVERY event regardless of byte
content. Use to confirm whether `?` in chat is literal ASCII 0x3F or
something stranger.

Stop OmniWatch Python overlay first. Run:
    python chat_listen_always_hex.py
"""
import socket
import base64

PORTS = [5013, 5014]
LABELS = {5013: "TEXT", 5014: "BATTLE"}


def make_sock(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", port))
    s.settimeout(0.1)
    return s


socks = [(p, make_sock(p)) for p in PORTS]
print(f"Listening on {PORTS}. Hex shown for ALL events.")
print()


def hex_dump(b):
    """Render as XX XX XX ... bytes side-by-side, two chars per byte."""
    return ' '.join(f"{byte:02x}" for byte in b)


count = {p: 0 for p in PORTS}

while True:
    try:
        for port, s in socks:
            try:
                data, _ = s.recvfrom(32768)
                count[port] += 1
                raw = data.decode("utf-8", errors="replace")
                lines = raw.split("\n")
                print(f"[{LABELS[port]} #{count[port]}] {lines[0]}")
                for ln in lines[1:]:
                    if not ln:
                        continue
                    fields = ln.split("\t")
                    if len(fields) >= 12 and fields[0] == "chat":
                        if fields[11]:
                            try:
                                text_bytes = base64.b64decode(fields[11])
                            except Exception:
                                text_bytes = b"<b64 decode failed>"
                        else:
                            text_bytes = b""
                        text_str = text_bytes.decode("utf-8", errors="replace")
                        print(f"  mode={fields[3]:>4} text={text_str!r}")
                        print(f"    HEX: {hex_dump(text_bytes)}")
                print()
            except socket.timeout:
                continue
    except KeyboardInterrupt:
        print(f"\nFinal: text={count[5013]} battle={count[5014]}")
        break