"""Loopback rules, identical in scripts/lib/bindhost.sh, bindhost.ps1 and here.

A host value may be a comma-separated list; spaces around entries are trimmed. One entry is
loopback when it is localhost, ::1, [::1], or a dotted-quad 127.x.y.z (127.0.0.0/8). A value is
loopback only when EVERY entry is; 0.0.0.0, ::, LAN addresses and empty entries are not.
"""
import re

_V4 = re.compile(r"127\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})")


def is_loopback_host(h):
    e = (h or "").strip().lower()
    if e in ("localhost", "::1", "[::1]"):
        return True
    m = _V4.fullmatch(e)
    return bool(m) and all(int(x) <= 255 for x in m.groups())


def is_loopback(value):
    if not value:
        return False
    return all(is_loopback_host(p) for p in value.split(","))
