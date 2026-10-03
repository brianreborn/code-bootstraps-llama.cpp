#!/usr/bin/env python3
"""Rewrite every .ps1 under a directory so that the PowerShell 6+ automatic variables $IsWindows,
$IsLinux, $IsMacOS and $IsCoreCLR do not exist, as in Windows PowerShell 5.1 (their names get a
prefix; Test-Path Variable:<name> is rewritten the same way). Used by tests/check-ps1.sh and the
"ps51" grid of tests/model_selection_matrix.py. Run on a COPY of scripts/."""
import os, re, sys

PAT = re.compile(r"(\$|Variable:)(IsWindows|IsLinux|IsMacOS|IsCoreCLR)\b", re.I)


def rewrite(top):
    n = 0
    for dp, _, fs in os.walk(top):
        for fn in fs:
            if fn.lower().endswith(".ps1"):
                p = os.path.join(dp, fn)
                s = open(p, encoding="utf-8", newline="").read()
                t = PAT.sub(lambda m: m.group(1) + "PS51Absent" + m.group(2), s)
                if t != s:
                    open(p, "w", encoding="utf-8", newline="").write(t); n += 1
    return n


if __name__ == "__main__":
    rewrite(sys.argv[1])
