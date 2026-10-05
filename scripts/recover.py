#!/usr/bin/env python3
"""Bring general and coder back after the kernel kills them.

llama-server marks a dead child unloaded. A signal death is reported as exit
code 1 (the bundled subprocess library collapses it). A clean stop is exit 0
and is left alone. Decision and language are not reloaded: they are the ones
that may be dropped. Three deaths of the same model inside two minutes stop
the retries and say so.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib.lockmem import try_lock_process

CORE = ("general", "coder")
WINDOW = 120
LIMIT = 3


def should_reload(model):
    status = model.get("status") or {}
    if status.get("value") != "unloaded":
        return False
    if not status.get("failed"):
        return False
    code = status.get("exit_code")
    return code not in (0, None)


def allow_retry(deaths, name, now):
    hist = [t for t in deaths.get(name, []) if now - t < WINDOW]
    hist.append(now)
    deaths[name] = hist
    return len(hist) <= LIMIT


def clear_ok(deaths, models):
    for model in models:
        status = (model.get("status") or {}).get("value")
        if model.get("id") in CORE and status == "loaded":
            deaths.pop(model["id"], None)


def main():
    try_lock_process("recover.py")
    url = os.environ.get("RECOVER_URL", "http://127.0.0.1:9931").rstrip("/")
    key_file = os.environ.get("API_KEY_FILE", "")
    key = ""
    if key_file and os.path.isfile(key_file):
        for line in open(key_file, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#"):
                key = line
                break
    deaths = {}
    quiet = set()
    while True:
        time.sleep(2)
        try:
            req = urllib.request.Request(url + "/models")
            if key:
                req.add_header("Authorization", "Bearer " + key)
            with urllib.request.urlopen(req, timeout=5) as resp:
                body = json.load(resp)
        except (OSError, urllib.error.URLError, ValueError, json.JSONDecodeError):
            continue
        models = body.get("data") or []
        clear_ok(deaths, models)
        for model in models:
            name = model.get("id")
            if name not in CORE or not should_reload(model):
                quiet.discard(name)
                continue
            now = time.time()
            if not allow_retry(deaths, name, now):
                if name not in quiet:
                    code = (model.get("status") or {}).get("exit_code")
                    sys.stderr.write("recover.py: %s died (exit %s) too often; not reloading it again yet\n" % (name, code))
                    quiet.add(name)
                continue
            code = (model.get("status") or {}).get("exit_code")
            sys.stderr.write("recover.py: %s died (exit %s); loading it again\n" % (name, code))
            try:
                data = json.dumps({"model": name}).encode()
                post = urllib.request.Request(url + "/models/load", data=data, method="POST")
                post.add_header("Content-Type", "application/json")
                if key:
                    post.add_header("Authorization", "Bearer " + key)
                urllib.request.urlopen(post, timeout=30).read()
            except (OSError, urllib.error.URLError):
                sys.stderr.write("recover.py: could not load %s; will try again\n" % name)


if __name__ == "__main__":
    main()
