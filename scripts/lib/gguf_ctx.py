#!/usr/bin/env python3
"""Print a GGUF file's trained context length (<arch>.context_length) from its header.

Usage: gguf_ctx.py <file.gguf | https://.../resolve/<rev>/file.gguf> [...]
Reads only the metadata header (stdlib only; URLs are fetched with HTTP Range).
Output: one line per input: "<n_ctx_train>\t<arch>\t<input>".
"""
import struct, sys, urllib.request

class Src:
    def __init__(self, path):
        self.path, self.buf, self.pos = path, b"", 0
        self.f = None if path.startswith(("http://", "https://")) else open(path, "rb")
    def read(self, n):
        if self.f:
            b = self.f.read(n)
        else:
            while len(self.buf) < self.pos + n:
                start = len(self.buf); end = start + max(n, 4 << 20) - 1
                req = urllib.request.Request(self.path, headers={"Range": "bytes=%d-%d" % (start, end)})
                with urllib.request.urlopen(req, timeout=60) as r:
                    chunk = r.read()
                if not chunk:
                    raise EOFError(self.path)
                self.buf += chunk
            b = self.buf[self.pos:self.pos + n]; self.pos += n
        if len(b) != n:
            raise EOFError(self.path)
        return b

FMT = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i", 6: "<f", 7: "<?", 10: "<Q", 11: "<q", 12: "<d"}

def val(s, t):
    if t in FMT:
        f = FMT[t]; return struct.unpack(f, s.read(struct.calcsize(f)))[0]
    if t == 8:
        n = struct.unpack("<Q", s.read(8))[0]; return s.read(n).decode("utf-8", "replace")
    if t == 9:
        et, n = struct.unpack("<IQ", s.read(12))
        if et in FMT:  # skip fixed-size arrays in one read
            s.read(struct.calcsize(FMT[et]) * n); return None
        for _ in range(n):
            val(s, et)
        return None
    raise ValueError("bad gguf type %d" % t)

def ctx(path):
    s = Src(path)
    if s.read(4) != b"GGUF":
        raise ValueError("not a GGUF file: " + path)
    ver, _tensors, nkv = struct.unpack("<IQQ", s.read(20))
    kv = {}
    for _ in range(nkv):
        k = val(s, 8); t = struct.unpack("<I", s.read(4))[0]; v = val(s, t)
        kv[k] = v
        arch = kv.get("general.architecture")
        if arch and arch + ".context_length" in kv:
            return kv[arch + ".context_length"], arch
    return None, kv.get("general.architecture")

if __name__ == "__main__":
    rc = 0
    for p in sys.argv[1:]:
        try:
            n, a = ctx(p); print("%s\t%s\t%s" % (n, a, p))
        except Exception as e:
            print("error\t%s\t%s" % (e, p), file=sys.stderr); rc = 1
    sys.exit(rc)
