#!/usr/bin/env python3
"""Minimal coding agent for llama-server (stdlib only, runs on Termux/Windows/Linux).

It asks the router's "coder" model for tool calls and runs them through the
server's own built-in tools and MCP tools (POST /tools), so file access and
shell commands happen wherever the server's --tools-runtime puts them.

  python3 scripts/agent.py --cwd ./workspace "create hello.py that prints hi, then run it"

Only the tools offered to the model can run; a call to any other tool is refused.
A tool runs without asking only when the server lists it as a built-in (type "server")
without the "write" permission; every other tool (writes, shell, MCP tools) asks before
running unless --yes. Without a terminal to answer, the answer is no.

Languages (see README "Languages"). scripts/serve.sh records the locale and mode it
started with in .cache/language.json (LOCALE / LANGUAGE_MODE / --language-mode override).
Each prompt's language is detected from its Unicode script and common words; when that
gives no clue, the system locale is used. English prompts get no language handling.
  native     (default) the coder works in the user's language directly; the agent only
             asks for answers in that language. No extra model.
  swap       same, while the server runs a language-native model as "general".
  interpret  opt-in: the router's "language" model (HY-MT1.5-1.8B; license not valid in
             the EU, UK and South Korea) translates a non-English prompt to English for
             the coder and the final answer back. Code spans (`...`) and fenced blocks are
             replaced by placeholders and restored byte for byte.
  off        (also any English locale): no language handling.

  LOCALE=auto python3 scripts/agent.py "arregla el test que falla en `tests/test_api.py`"
  python3 scripts/agent.py --localize docs/guide.md --to ja > docs/guide.ja.md

A stuck run (the same tool call skipped twice, three tool failures in a row, or the step
limit) saves a terse brief and exits 1. /remote on sends that brief once to the attached
login. Logins are an https model or a local client: grok, agy, claude, codex, or exec.
An empty remote session id starts the client; a stored id resumes it. Image, audio, video,
and pdf paths are handed to a local client as paths, not bytes.
  python3 scripts/agent.py "/remote login work grok"
  python3 scripts/agent.py "/remote on"
"""
import argparse
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from lib import remote as remote_handoff
from lib.lockmem import try_lock_process

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEAN_TOOLS = ["read_file", "write_file", "edit_file", "exec_shell_command"]
LOOPBACK = {"127.0.0.1", "localhost", "::1"}

# --- language slot -------------------------------------------------------------
LANGS = {"en": "English", "es": "Spanish", "pt": "Portuguese", "de": "German", "fr": "French", "it": "Italian",
         "ru": "Russian", "zh": "Simplified Chinese", "ja": "Japanese", "ko": "Korean", "hi": "Hindi", "ar": "Arabic"}
INTERPRETER = ("You are a translator for a coding assistant. Translate the user's text into {tgt}. "
               "Copy every placeholder like \u27e6C0\u27e7 exactly where it belongs; they stand for code. "
               "Keep file paths, commands, identifiers, URLs and numbers unchanged. Keep the meaning; do not answer, "
               "explain or add anything. Output only the translation.")
CODE_RE = re.compile(r"```.*?```|`[^`\n]+`", re.S)
# Sentences may be translated. These stay byte for byte: code, URLs, flags, hashes, paths, model files.
KEEP_RE = re.compile(
    r"```.*?```|`[^`\n]+`"
    r"|https?://\S+"
    r"|\b[a-fA-F0-9]{32,64}\b"
    r"|--[A-Za-z0-9][\w.-]*"
    r"|(?:(?:\./|\.\./|/)[A-Za-z0-9_.+-]+(?:/[A-Za-z0-9_.+-]+)+)"
    r"|\b[\w./+-]+\.(?:gguf|sh|py|ps1|json|ini|md|txt)\b",
    re.S)


def mask_code(text, pattern=None):
    """replace protected spans with placeholders. pattern defaults to code fences and `spans`."""
    spans = []
    def sub(m):
        spans.append(m.group(0))
        return f"\u27e6C{len(spans) - 1}\u27e7"
    return (pattern or CODE_RE).sub(sub, text), spans


def unmask_code(text, spans):
    """put the code back; returns (text, ok) where ok means every placeholder appeared exactly once"""
    ok = True
    for i, code in enumerate(spans):
        ph = f"\u27e6C{i}\u27e7"
        if text.count(ph) != 1:
            ok = False
        text = text.replace(ph, code)
    return text, ok and not re.search("\u27e6C\\d+\u27e7", text)


PATH_KEYS = ("path", "file_path", "filepath", "dir", "directory", "cwd")
def outside_path(cwd, params):
    """first path argument that resolves outside cwd (host paths only), else None.
    Not a sandbox: exec_shell_command can still reach anything; use the container runtime for that."""
    if not cwd or not os.path.isdir(cwd) or not isinstance(params, dict):
        return None
    root = os.path.realpath(cwd)
    for k in PATH_KEYS:
        v = params.get(k)
        if isinstance(v, str) and v:
            full = os.path.realpath(os.path.join(root, os.path.expanduser(v)))
            if full != root and not full.startswith(root + os.sep):
                return v
    return None


def load_tools_meta():
    """cwd the tools runtime can see, written by scripts/serve.sh (.cache/tools.json)."""
    path = os.path.join(ROOT, ".cache", "tools.json")
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def resolve_cwd(requested, meta):
    """header value for x-tool-cwd. An empty --cwd uses the runtime cwd from tools.json.
    Inside a container, a relative path is joined under that cwd (/work). A host absolute
    path outside the mount is refused: the container cannot see it."""
    runtime = meta.get("runtime") or "host"
    isolate = meta.get("cwd") or ""
    if runtime == "host" or not isolate:
        isolate = ""
    if requested is None or requested == "":
        return isolate or None
    if isolate:
        base = isolate.rstrip("/")
        if requested.startswith("/"):
            if requested == base or requested.startswith(base + "/"):
                return requested
            raise SystemExit(
                f"agent: --cwd {requested} is not inside the tools container ({isolate}). "
                "Set WORKDIR to the project to edit and restart serve.sh.")
        rel = requested[2:] if requested.startswith("./") else requested
        return base + "/" + rel.lstrip("/")
    if not requested.startswith("/") and os.path.isdir(requested):
        return os.path.abspath(requested)
    return requested


def ask(prompt):
    """y/N question on stdin; a closed stdin or end of input means no."""
    if sys.stdin is None or sys.stdin.closed:
        print(prompt + "(stdin closed: denied; use --yes to allow)", file=sys.stderr)
        return False
    try:
        return input(prompt).strip().lower() == "y"
    except (EOFError, OSError, ValueError):
        print("(no answer: denied)", file=sys.stderr)
        return False


def read_key(path):
    if not path or not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    return None


def reasoning_mode():
    """REASONING=on|auto|off. Empty and off add nothing. Anything else is a mistake."""
    mode = os.environ.get("REASONING", "").strip()
    if mode not in ("", "off", "on", "auto"):
        raise SystemExit(f"agent: unknown REASONING={mode} (on|off|auto)")
    return mode


def reasoning_fields(model, mode):
    """Per-request thinking for general and coder. Off, empty, and other roles send nothing extra.
    on forces enable_thinking; auto only asks for a stream so the server's preset can decide."""
    if mode not in ("on", "auto") or model not in ("general", "coder"):
        return {}
    fields = {"stream": True}
    if mode == "on":
        fields["chat_template_kwargs"] = {"enable_thinking": True}
    return fields


class Client:
    def __init__(self, url, key, cwd=None):
        self.url, self.key, self.cwd = url.rstrip("/"), key, cwd
        u = urllib.parse.urlparse(self.url)
        if key and u.scheme == "http" and (u.hostname or "") not in LOOPBACK:
            raise SystemExit(f"refusing to send the API key over plain http to {u.hostname}; use https or a loopback URL")

    def _open(self, method, path, body, timeout):
        headers = {"Content-Type": "application/json"}
        if self.key:
            headers["Authorization"] = "Bearer " + self.key
        if self.cwd and path == "/tools":
            headers["x-tool-cwd"] = self.cwd
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(self.url + path, data=data, method=method, headers=headers)
        try:
            return urllib.request.urlopen(r, timeout=timeout)
        except urllib.error.HTTPError as e:
            raise SystemExit(f"HTTP {e.code} on {path}: {e.read().decode(errors='replace')}")
        except (urllib.error.URLError, ConnectionError, TimeoutError, http.client.HTTPException, OSError) as e:
            # server stopped, restarted or never started: one line instead of a traceback
            why = getattr(e, "reason", None) or e
            raise SystemExit(f"agent.py: lost the connection to {self.url} during {method} {path} ({why}). "
                             "Is the server still running? Start it again (start.sh / start.bat) and retry.")

    def req(self, method, path, body=None, timeout=3600):
        with self._open(method, path, body, timeout) as resp:
            return json.load(resp)

    def chat(self, body, timeout=3600):
        """POST /v1/chat/completions. A live router streams text/event-stream; the test server returns one JSON body."""
        with self._open("POST", "/v1/chat/completions", body, timeout) as resp:
            ctype = (resp.headers.get("Content-Type") or "").lower()
            if "text/event-stream" in ctype:
                return self._read_sse(resp)
            data = json.load(resp)
            self._print_reasoning_blob(data)
            return data

    def _print_think(self, text, state):
        if not text:
            return
        if not state["on"]:
            sys.stderr.write("[think] ")
            state["on"] = True
        sys.stderr.write(text)
        sys.stderr.flush()

    def _end_think(self, state):
        if state["on"]:
            sys.stderr.write("\n")
            sys.stderr.flush()
            state["on"] = False

    def _print_reasoning_blob(self, data):
        """Non-stream JSON: the whole thought arrives at once. Still show it."""
        try:
            msg = data["choices"][0]["message"]
        except (KeyError, IndexError, TypeError):
            return
        if not isinstance(msg, dict):
            return
        text = msg.get("reasoning_content")
        if isinstance(text, str) and text:
            sys.stderr.write("[think] " + text + "\n")
            sys.stderr.flush()

    def _read_sse(self, resp):
        content, reasoning, tool_calls, timings = [], [], {}, {}
        role, think, data_lines = "assistant", {"on": False}, []

        def flush_event():
            nonlocal role, timings
            if not data_lines:
                return
            payload = "\n".join(data_lines)
            data_lines.clear()
            if payload == "[DONE]":
                return
            try:
                ev = json.loads(payload)
            except json.JSONDecodeError as e:
                raise SystemExit(f"agent.py: chat stream was not JSON ({e})")
            if isinstance(ev.get("timings"), dict):
                timings = ev["timings"]
            choices = ev.get("choices") or []
            if not choices:
                return
            delta = choices[0].get("delta") or {}
            if delta.get("role"):
                role = delta["role"]
            piece = delta.get("reasoning_content")
            if isinstance(piece, str) and piece:
                self._print_think(piece, think)
                reasoning.append(piece)
            text = delta.get("content")
            if isinstance(text, str) and text:
                self._end_think(think)
                content.append(text)
            for tc in delta.get("tool_calls") or []:
                self._end_think(think)
                idx = tc.get("index", 0)
                slot = tool_calls.setdefault(idx, {"id": "", "type": "function", "function": {"name": "", "arguments": ""}})
                if tc.get("id"):
                    slot["id"] = tc["id"]
                if tc.get("type"):
                    slot["type"] = tc["type"]
                fn = tc.get("function") or {}
                if fn.get("name"):
                    slot["function"]["name"] += fn["name"]
                if isinstance(fn.get("arguments"), str):
                    slot["function"]["arguments"] += fn["arguments"]

        while True:
            line = resp.readline()
            if not line:
                break
            if isinstance(line, bytes):
                line = line.decode("utf-8", "replace")
            line = line.rstrip("\r\n")
            if line == "":
                flush_event()
                continue
            if line.startswith(":"):
                continue
            if line.startswith("data:"):
                data_lines.append(line[5:].lstrip())
        flush_event()
        self._end_think(think)
        msg = {"role": role, "content": "".join(content)}
        if reasoning:
            msg["reasoning_content"] = "".join(reasoning)
        if tool_calls:
            msg["tool_calls"] = [tool_calls[i] for i in sorted(tool_calls)]
        return {"choices": [{"message": msg}], "timings": timings}


def translate(c, text, target, style="sys", tries=2):
    """translate text with the router's "language" model, code spans protected by placeholders"""
    masked, spans = mask_code(text, KEEP_RE)
    tgt = LANGS.get(target, target)
    for _ in range(tries):
        if style == "hy":   # HY-MT official prompt (no system prompt)
            p = (f"将以下文本翻译为中文，注意只需要输出翻译后的结果，不要额外解释：\n\n{masked}" if target == "zh"
                 else f"Translate the following segment into {tgt}, without additional explanation.\n\n{masked}")
            msgs = [{"role": "user", "content": p}]
        else:
            msgs = [{"role": "system", "content": INTERPRETER.format(tgt=tgt)}, {"role": "user", "content": masked}]
        res = c.req("POST", "/v1/chat/completions", {"model": "language", "messages": msgs, "temperature": 0,
                                                     "max_tokens": 2048, "chat_template_kwargs": {"enable_thinking": False}})
        out, ok = unmask_code((res["choices"][0]["message"]["content"] or "").strip(), spans)
        if ok:
            return out, True
    return out, False


def localize_text(c, text, target, style="sys"):
    """translate prose only: fenced blocks stay verbatim, each paragraph is translated on its own
    (inline `code` masked); a paragraph whose placeholders get lost is kept in the original.
    Returns (text, number of paragraphs kept in the original)."""
    out, failed = [], 0
    for part in re.split(r"(```.*?```)", text, flags=re.S):
        if part.startswith("```"):
            out.append(part); continue
        paras = []
        for para in part.split("\n\n"):
            if para.strip():
                t, ok = translate(c, para.strip("\n"), target, style)
                if not ok:
                    failed += 1; t = para.strip("\n")
                # keep the paragraph's leading/trailing newlines
                para = para[:len(para) - len(para.lstrip("\n"))] + t + para[len(para.rstrip("\n")):]
            paras.append(para)
        out.append("\n\n".join(paras))
    return "".join(out), failed


SCRIPTS = [("ja", r"[\u3040-\u30ff]"), ("ko", r"[\uac00-\ud7af\u1100-\u11ff]"), ("zh", r"[\u4e00-\u9fff]"),
           ("hi", r"[\u0900-\u097f]"), ("ar", r"[\u0600-\u06ff]"), ("ru", r"[\u0400-\u04ff]")]
STOP = {   # generic function words + thanks/please only (no words taken from the test items)
 "en": "the a an and or is are was to of in on at it that this these can could you your with for from not do does what how why please thanks thank yes ok".split(),
 "es": "el la los las un una y o es son que en de del al por para con no se lo le su mi tu como pero gracias porfavor está".split(),
 "pt": "o os as um uma e ou é são que em de do da dos das no na por para com não se seu sua meu você como mas obrigado obrigada está".split(),
 "de": "der die das den dem ein eine und oder ist sind zu in im mit von für nicht es ich du sie wie aber bitte danke auch".split(),
 "fr": "le la les un une et ou est sont que en de du des pour avec ne pas se il elle je vous comme mais merci".split(),
 "it": "il lo la gli le un una e o è sono che in di del per con non si io tu come ma grazie".split(),
}
NON_LATIN = {l for l, _ in SCRIPTS}
ACCENT = {"es": "ñ¿¡", "pt": "ãõ", "de": "äöüß"}
def detect_heuristic(text):
    """Unicode script, then function words for Latin-script languages; (lang, confidence), confidence 0 = no clue"""
    t = CODE_RE.sub(" ", text)
    letters = len(re.findall(r"[^\W\d_]", t))
    if letters == 0: return "en", 0.0
    kana = len(re.findall(SCRIPTS[0][1], t))
    for lang, rx in SCRIPTS:
        n = len(re.findall(rx, t))
        if lang == "zh" and kana: continue
        if n / letters >= 0.3 or (lang == "ja" and kana >= 2):
            return lang, min(1.0, n / letters + 0.3)
    words = re.findall(r"[a-zà-ÿ']+", t.lower())
    score = {l: sum(w in s for w in words) for l, s in STOP.items()}
    for l, chars in ACCENT.items(): score[l] += 2 * sum(t.lower().count(c) for c in chars)
    best = max(score, key=score.get)
    tot = sum(score.values())
    if score[best] == 0: return "en", 0.0
    return best, score[best] / tot


def server_language():
    """what scripts/serve.sh started with (.cache/language.json), overridable by LOCALE / LANGUAGE_MODE"""
    info = {"locale": "en", "mode": "off", "swapped": ""}
    try:
        with open(os.path.join(ROOT, ".cache", "language.json"), encoding="utf-8") as f:
            info.update(json.load(f))
    except (OSError, ValueError):
        pass
    return info


def resolve_language(a, text):
    """returns (mode, lang): mode in off|native|swap|interpret; lang = language to answer in.
    Detection: script + common-word heuristic on the prompt, the system locale when it gives no clue."""
    info = server_language()
    mode = info["mode"] if a.language_mode == "auto" else a.language_mode
    loc = info["locale"] if a.locale == "auto" else a.locale.lower().replace("_", "-").split("-")[0]
    if mode == "off" or loc in ("en", "c", "posix", ""):
        return "off", None
    lang, p = detect_heuristic(text)
    latin = not re.search(r"[^\x00-\u024f]", CODE_RE.sub(" ", text))
    if p == 0.0:          # no clue (one Latin word, only code): the locale's language, unless the
        # locale uses another script and the user typed Latin letters (then it is English)
        lang, p = ("en", 1.0) if latin and text.strip() and loc in NON_LATIN and CODE_RE.sub("", text).strip() else (loc, 1.0)
    if lang == "zh" and loc == "ja":   # kanji only: a Japanese user writing Japanese
        lang = "ja"
    print(f"[agent] detected language: {lang} (p={p:.2f}; locale {loc})", file=sys.stderr)
    if lang == "en" or p < a.detect_min_p:   # English or unsure: plain English handling
        return "off", None
    return mode, lang


def main():
    try_lock_process("agent.py")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prompt")
    ap.add_argument("--url", default=os.environ.get("LLAMA_URL", "http://127.0.0.1:" + os.environ.get("PORT", "9931")))
    ap.add_argument("--key-file", default=os.environ.get("API_KEY_FILE", os.path.join(ROOT, ".secrets", "api-keys")))
    ap.add_argument("--model", default=os.environ.get("AGENT_MODEL", "coder"))
    ap.add_argument("--cwd", default=None, help="tool working directory (host path, or /work inside a container runtime)")
    ap.add_argument("--max-steps", type=int, default=12)
    ap.add_argument("--max-tokens", type=int, default=1024)
    ap.add_argument("--tools", default=os.environ.get("AGENT_TOOLS", ""),
                    help="comma-separated subset of the server's tools to offer the model (fewer tools = shorter "
                         "prompt; each costs 30-340 tokens), or 'lean' = read_file,write_file,edit_file,exec_shell_command")
    ap.add_argument("--allow-outside", action="store_true",
                    help="let file tools use paths outside --cwd (default: refused; exec_shell_command is never confined)")
    ap.add_argument("--yes", action="store_true", help="do not ask before tools that write")
    ap.add_argument("--json-log", default=None, help="append every step as JSON lines to this file")
    ap.add_argument("--locale", default=os.environ.get("LOCALE", "auto"),
                    help="user language: auto (what serve.sh detected), en (off), es, zh, ja, ...")
    ap.add_argument("--language-mode", default=os.environ.get("LANGUAGE_MODE", "auto"),
                    choices=["auto", "native", "swap", "interpret", "off"],
                    help="auto = the mode scripts/serve.sh started with (default native)")
    ap.add_argument("--language-prompt", default=os.environ.get("LANGUAGE_PROMPT", "sys"), choices=["sys", "hy"],
                    help="prompt style of the language model: sys (system prompt) or hy (HY-MT template)")
    ap.add_argument("--detect-min-p", type=float, default=float(os.environ.get("DETECT_MIN_P", "0.3")))
    ap.add_argument("--localize", metavar="FILE",
                    help="translate the sentences of a text/Markdown FILE and print it. "
                         "Code, paths, flags, URLs, and hashes stay as written")
    ap.add_argument("--to", default=None,
                    help="target language for --localize (default: LOCALE). "
                         "Does not translate code, paths, flags, URLs, or hashes")
    a = ap.parse_args()
    reason = reasoning_mode()
    if a.prompt.startswith("/remote") and not a.localize:
        ws = os.path.abspath(a.cwd) if a.cwd else ROOT
        return remote_handoff.dispatch(a.prompt, ws)

    cwd = resolve_cwd(a.cwd, load_tools_meta())
    local_key = read_key(a.key_file)
    c = Client(a.url, local_key, cwd)

    if a.localize:   # localize docs/comments/strings: prose translated, code blocks and `spans` kept
        target = (a.to or (server_language()["locale"] if a.locale == "auto" else a.locale)).split("-")[0].lower()
        if not target or target in ("auto", "en"):
            raise SystemExit("--localize needs --to LANG (or LOCALE) other than en")
        with open(a.localize, encoding="utf-8") as f:
            out, failed = localize_text(c, f.read(), target, a.language_prompt)
        if failed:
            print(f"[localize] {failed} paragraph(s) lost code placeholders and were kept in the original", file=sys.stderr)
        sys.stdout.write(out)
        return 0

    lang_mode, user_lang = resolve_language(a, a.prompt)
    prompt = a.prompt
    if lang_mode == "interpret":
        prompt, ok = translate(c, a.prompt, "en", a.language_prompt)
        print(f"[agent] interpreted ({user_lang} -> en): {prompt}", file=sys.stderr)
        if not ok:   # never lose code: give the coder the original too
            prompt += "\n\n(Original message, code spans authoritative:)\n" + a.prompt

    all_tools = c.req("GET", "/tools")
    tools = all_tools
    if a.tools:
        want = LEAN_TOOLS if a.tools == "lean" else [t.strip() for t in a.tools.split(",") if t.strip()]
        missing = [t for t in want if t not in {x["tool"] for x in all_tools}]
        if missing:
            print(f"[agent] not on the server, skipped: {','.join(missing)}", file=sys.stderr)
        tools = [t for t in all_tools if t["tool"] in want]
    defs = [t["definition"] for t in tools]
    offered = {t["tool"] for t in tools}
    # approval comes from the server's full list, never from the offered subset or a tool's name:
    # only a built-in (type "server") without the write permission runs unasked. If two tools
    # share a name (an MCP tool called read_file), the stricter rule wins.
    needs_ok = {t["tool"] for t in all_tools
                if t.get("type") != "server" or (t.get("permissions") or {}).get("write") is not False}
    # file changes (any tool that may write, except the shell) start a new state for the repeat guard
    resets = {t["tool"] for t in all_tools if t["tool"] in needs_ok and t["tool"] != "exec_shell_command"}
    names = [t["tool"] for t in tools]
    print(f"[agent] model={a.model} tools={','.join(names)} cwd={cwd or '(server cwd)'}", file=sys.stderr)

    system = ("You are a careful coding agent. Use the tools to inspect, create, edit and run files. "
              "Use relative paths. Keep answers short. As soon as the task is done (for example the program "
              "ran and printed what was asked), stop calling tools and reply with a one-line summary.")
    if lang_mode in ("native", "swap"):
        system += (f" The user writes in {LANGS.get(user_lang, user_lang)}: reply in that language, but keep code, "
                   "file paths, commands and identifiers unchanged.")
    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": prompt},
    ]
    log = open(a.json_log, "a", encoding="utf-8") if a.json_log else None
    # repeat guard: small coders (Qwen3.5-2B, measured) sometimes re-run the same call until the
    # step limit. An identical call runs once per "epoch"; a new epoch starts whenever a file tool
    # (write_file, edit_file) or an MCP tool runs, so run/edit/run/edit/run works. Shell commands
    # do not start one (repeating `python3 hello.py` is the loop seen in practice). A model that
    # repeats again after being told gets no tools on its next step.
    ran, epoch, skips = set(), 0, 0
    fail_streak = 0
    wrote, stuck, last_tool = [], {"name": "", "args": ""}, {"name": "", "text": ""}

    def note_write(fn, params):
        path = str(params.get("path") or params.get("file") or "")
        if fn == "write_file":
            body = str(params.get("content") or "")
        else:
            bits = []
            for edit in (params.get("edits") or [])[:3]:
                if isinstance(edit, dict):
                    bits.append("-" + str(edit.get("old_text") or "")[:80])
                    bits.append("+" + str(edit.get("new_text") or "")[:80])
            body = "\n".join(bits)
        wrote.append({"path": path, "body": body})
        del wrote[:-2]

    def mark_fail(name, detail):
        nonlocal fail_streak
        fail_streak += 1
        stuck["name"] = name
        stuck["args"] = str(detail)[:400]
        return fail_streak >= 3

    def give_up(why, answer=""):
        if answer:
            if lang_mode == "interpret":
                answer, failed = localize_text(c, answer, user_lang, a.language_prompt)
                if failed:
                    answer += f"\n\n[agent] ({failed} paragraph(s) kept in English: translation dropped code spans)"
            print(answer)

        def tr(text):
            out, failed = localize_text(c, text, user_lang, a.language_prompt)
            if failed:
                out += f"\n\n[agent] ({failed} paragraph(s) kept in English: translation dropped code spans)"
            return out

        return remote_handoff.handoff(
            why=why, task=prompt, workspace=cwd or ROOT, wrote=list(wrote), stuck=dict(stuck),
            tool=dict(last_tool), redact=local_key or "",
            translate=tr if lang_mode == "interpret" else None)

    for step in range(1, a.max_steps + 1):
        t0 = time.time()
        body = {"model": a.model, "messages": messages, "tools": defs, "max_tokens": a.max_tokens}
        body.update(reasoning_fields(a.model, reason))
        # tool_choice none keeps the tool definitions in the prompt (cached prefix) but parses the reply as text
        why = None
        if step == a.max_steps:   # last step: no more tools, the model has to answer
            why = "limit"
            body["tool_choice"] = "none"
            messages.append({"role": "user", "content": "Step limit reached: do not call tools; summarize what was done and what is left."})
        elif skips >= 2:
            why = "repeat"
            body["tool_choice"] = "none"
            messages.append({"role": "user", "content": "You are repeating the same tool call. Do not call tools now: "
                                                        "reply with a one-line summary of what was done and what is left, if anything."})
            skips = 0
        res = c.chat(body)
        msg = res["choices"][0]["message"]
        timings = res.get("timings") or {}
        print(f"[agent] step {step}: {time.time()-t0:.1f}s, gen {timings.get('predicted_per_second', 0):.1f} tok/s, "
              f"prompt {timings.get('prompt_per_second', 0):.1f} tok/s", file=sys.stderr)
        if log:
            log.write(json.dumps({"step": step, "message": msg, "timings": timings}) + "\n")
        calls = msg.get("tool_calls") or []
        messages.append({k: v for k, v in msg.items() if k in ("role", "content", "tool_calls", "reasoning_content")})
        if why or not calls:
            answer = msg.get("content") or ""
            if why:
                return give_up(why, answer)
            if lang_mode == "interpret":
                answer, failed = localize_text(c, answer, user_lang, a.language_prompt)
                if failed:   # those paragraphs stay in English rather than risk changed code
                    answer += f"\n\n[agent] ({failed} paragraph(s) kept in English: translation dropped code spans)"
            print(answer)
            return 0
        for call in calls:
            fn = call["function"]["name"]
            try:
                params = json.loads(call["function"].get("arguments") or "{}")
            except json.JSONDecodeError as e:
                out = json.dumps({"error": f"invalid JSON arguments: {e}"})
                print(f"[tool] -> {out}", file=sys.stderr)
                messages.append({"role": "tool", "tool_call_id": call.get("id", ""), "content": out})
                if mark_fail(fn, out):
                    return give_up("errors")
                continue
            else:
                print(f"[tool] {fn} {json.dumps(params)[:300]}", file=sys.stderr)
                key = (fn, json.dumps(params, sort_keys=True))
                if fn not in offered:   # never run a tool the model was not given (its approval may differ)
                    out = json.dumps({"error": f"unknown tool {fn!r}; available: {', '.join(sorted(offered))}"})
                    print(f"[tool] -> refused: {fn} was not offered", file=sys.stderr)
                    messages.append({"role": "tool", "tool_call_id": call.get("id", ""), "content": out})
                    if mark_fail(fn, out):
                        return give_up("errors")
                    continue
                if (key, epoch) in ran:
                    out = ("Not run again: this identical call already ran, and no file was written or edited "
                           "since, so look at its earlier result. If the task is done, do not call more tools: "
                           "reply with a one-line summary. Otherwise do something different.")
                    skips += 1
                    stuck["name"] = fn
                    stuck["args"] = json.dumps(params)[:400]
                    print(f"[tool] -> skipped repeat", file=sys.stderr)
                    messages.append({"role": "tool", "tool_call_id": call.get("id", ""), "content": out})
                    continue
                bad = None if a.allow_outside else outside_path(cwd, params)
                if bad:   # keeps the model in the project (it wandered over / in tests; a grep there OOM-killed the server)
                    out = json.dumps({"error": f"path {bad!r} is outside the project directory; use paths relative to it"})
                    print(f"[tool] -> {out}", file=sys.stderr)
                    messages.append({"role": "tool", "tool_call_id": call.get("id", ""), "content": out})
                    if mark_fail(fn, bad):
                        return give_up("errors")
                    continue
                if fn in needs_ok and not a.yes:
                    if not ask(f"allow {fn}? [y/N] "):
                        out = json.dumps({"error": "denied by user"})
                        messages.append({"role": "tool", "tool_call_id": call.get("id", ""), "content": out})
                        continue
                r = c.req("POST", "/tools", {"tool": fn, "params": params})
                if fn in resets:
                    epoch += 1
                ran.add((key, epoch))
                out = r["plain_text_response"] if "plain_text_response" in r else json.dumps(r)
                fail_streak = 0
                last_tool["name"] = fn
                last_tool["text"] = out[:800]
                if fn in ("write_file", "edit_file"):
                    note_write(fn, params)
            print(f"[tool] -> {out[:300]!r}", file=sys.stderr)
            if log:
                log.write(json.dumps({"step": step, "tool": fn, "result": out[:4000]}) + "\n")
            messages.append({"role": "tool", "tool_call_id": call.get("id", ""), "content": out})
    return give_up("limit")


if __name__ == "__main__":
    sys.exit(main())
