"""Standalone chat-stream listener. Binds 5013/5014 and prints every
packet that arrives. Use as a one-off diagnostic when you need to
confirm the Lua side is sending without involving the main overlay.

IMPORTANT: stop OmniWatch first, or it'll be holding the same ports
and this script will get "address in use". Or change the ports below
to anything else and run BOTH — but easier to just stop the overlay.

Run with:
    python chat_listen.py
"""
import socket
import base64
import time

PORTS = [5013, 5014]
LABELS = {5013: "TEXT", 5014: "BATTLE"}

def make_sock(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", port))
    s.settimeout(0.1)
    return s

socks = [(p, make_sock(p)) for p in PORTS]
print(f"Listening on {PORTS}. Chat in-game to see packets. Ctrl-C to stop.")
print()

count = {p: 0 for p in PORTS}
last_status = time.time()

while True:
    try:
        for port, s in socks:
            try:
                data, _ = s.recvfrom(32768)
                count[port] += 1
                raw = data.decode("utf-8", errors="replace")
                lines = raw.split("\n")
                hdr = lines[0]
                print(f"[{LABELS[port]} #{count[port]}] header: {hdr}")
                for ln in lines[1:]:
                    if not ln:
                        continue
                    fields = ln.split("\t")
                    if len(fields) >= 12 and fields[0] == "chat":
                        try:
                            text = base64.b64decode(fields[11]).decode(
                                "utf-8", errors="replace") if fields[11] else ""
                        except Exception:
                            text = "<b64 decode failed>"
                        print(f"  mode={fields[3]:>4} "
                              f"actor={fields[5]!r:30} "
                              f"text={text[:80]!r}")
                    else:
                        print(f"  raw: {ln[:120]}")
                print()
            except socket.timeout:
                continue
        # Periodic heartbeat so you know it's alive even if no traffic
        now = time.time()
        if now - last_status >= 10.0:
            last_status = now
            print(f"[status] alive, text={count[5013]} battle={count[5014]}")
    except KeyboardInterrupt:
        print(f"\nFinal: text={count[5013]} battle={count[5014]}")
        break