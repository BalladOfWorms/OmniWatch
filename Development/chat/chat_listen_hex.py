"""Standalone chat-stream listener with hex dump.
Stop the OmniWatch Python overlay first (it holds the ports).
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
print(f"Listening on {PORTS}. HEX shown for any non-ASCII bytes.")
print()

def hex_dump(b):
    parts = []
    for byte in b:
        if 0x20 <= byte <= 0x7E:
            parts.append(f" {chr(byte)} ")
        else:
            parts.append(f"\\x{byte:02x}")
    return ''.join(parts)

def has_weird(b):
    return any(byte < 0x20 or byte > 0x7E for byte in b)

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
                        if has_weird(text_bytes):
                            print(f"    HEX: {hex_dump(text_bytes)}")
                print()
            except socket.timeout:
                continue
    except KeyboardInterrupt:
        print(f"\nFinal: text={count[5013]} battle={count[5014]}")
        break