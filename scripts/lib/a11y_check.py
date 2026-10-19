"""a11y_check.py: a small stdlib accessibility check for the panel's HTML.

It catches the mistakes that make a form unusable with a keyboard, a switch or a
screen reader. It is not a full WCAG audit (no colour contrast maths, no live
screen-reader test):
  - <html lang>, a non-empty <title>, exactly one <h1>, a <main> landmark
  - every visible input/select/textarea has a <label for> or aria-label(ledby)
  - every radio and checkbox group with more than one control sits in a <fieldset> with a <legend>
  - no positive tabindex (it breaks the reading/scan order), no duplicate ids
  - every aria-describedby / aria-labelledby / label-for / href="#id" target exists
  - every <img> has alt; every <button> and <a> has text or aria-label
  - no <script>, no <meta http-equiv=refresh> (no timeouts, works without JS)
problems(html) returns a list of strings; empty means it passed.
"""
from html.parser import HTMLParser

VOID = {"input", "img", "br", "meta", "link", "hr", "area", "base", "col", "embed", "source", "track", "wbr"}


class _P(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.errs, self.ids, self.refs, self.label_for = [], {}, [], set()
        self.controls, self.stack, self.h1, self.lang, self.title = [], [], 0, None, ""
        self.has_main, self.in_title = False, False
        self.text_for = []  # [tag, attrs, collected text] for buttons/links/labels
        self.fieldset = []  # stack of [has_legend, controls]
        self.labels = []  # one bool per open <label>: True when it wraps its control

    def handle_starttag(self, tag, attrs):
        a = {k: (v if v is not None else "") for k, v in attrs}
        if tag == "html":
            self.lang = a.get("lang")
        if tag == "title":
            self.in_title = True
        if tag == "h1":
            self.h1 += 1
        if tag == "main":
            self.has_main = True
        if tag == "script":
            self.errs.append("<script> found: the panel must work without JavaScript")
        if tag == "meta" and a.get("http-equiv", "").lower() == "refresh":
            self.errs.append("<meta http-equiv=refresh>: no timed reloads")
        if "id" in a:
            if a["id"] in self.ids:
                self.errs.append(f"duplicate id {a['id']!r}")
            self.ids[a["id"]] = tag
        ti = a.get("tabindex")
        if ti is not None and ti.lstrip("-").isdigit() and int(ti) > 0:
            self.errs.append(f"<{tag}> has tabindex={ti}: positive tabindex breaks the scan order")
        for k in ("aria-describedby", "aria-labelledby"):
            for ref in a.get(k, "").split():
                self.refs.append((k, ref))
        if tag == "a" and a.get("href", "").startswith("#") and len(a["href"]) > 1:
            self.refs.append(("href", a["href"][1:]))
        if tag == "label":
            if a.get("for"):
                self.label_for.add(a["for"])
                self.refs.append(("label for", a["for"]))
            self.labels.append(not a.get("for"))
        if tag == "img" and "alt" not in a:
            self.errs.append(f"<img src={a.get('src', '')!r}> has no alt")
        if tag == "fieldset":
            self.fieldset.append([False, []])
        if tag == "legend" and self.fieldset:
            self.fieldset[-1][0] = True
        if tag in ("input", "select", "textarea"):
            typ = a.get("type", "text").lower() if tag == "input" else tag
            if typ not in ("hidden", "submit", "button", "reset", "image"):
                self.controls.append((tag, typ, a, any(self.labels)))
                if typ in ("radio", "checkbox"):
                    if self.fieldset:
                        self.fieldset[-1][1].append((typ, a.get("name")))
                    else:
                        self.controls[-1] = self.controls[-1] + ("nofieldset",)
            if typ in ("submit", "button", "reset") and not (a.get("value") or a.get("aria-label")):
                self.errs.append(f"<input type={typ}> has no value text")
        if tag in ("button", "a"):
            self.text_for.append([tag, a, ""])
        if tag not in VOID:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False
        if tag == "label" and self.labels:
            self.labels.pop()
        if tag in ("button", "a") and self.text_for and self.text_for[-1][0] == tag:
            t, a, txt = self.text_for.pop()
            if not txt.strip() and not a.get("aria-label") and not a.get("aria-labelledby"):
                self.errs.append(f"<{t}> with no text or aria-label")
        if tag == "fieldset" and self.fieldset:
            has_legend, ctl = self.fieldset.pop()
            if ctl and not has_legend:
                self.errs.append("<fieldset> without a <legend>")
        if tag in self.stack:
            while self.stack and self.stack.pop() != tag:
                pass

    def handle_data(self, data):
        if self.in_title:
            self.title += data
        for t in self.text_for:
            t[2] += data


def problems(html):
    p = _P()
    p.feed(html)
    p.close()
    errs = list(p.errs)
    if not p.lang:
        errs.append("<html> has no lang attribute")
    if not p.title.strip():
        errs.append("page has no <title>")
    if p.h1 != 1:
        errs.append(f"page has {p.h1} <h1> elements; expected exactly 1")
    if not p.has_main:
        errs.append("page has no <main> landmark")
    for kind, ref in p.refs:
        if ref not in p.ids:
            errs.append(f"{kind} points at missing id {ref!r}")
    groups = {}
    for c in p.controls:
        tag, typ, a, wrapped = c[:4]
        named = a.get("id") in p.label_for or a.get("aria-label") or a.get("aria-labelledby") or wrapped
        if not named:
            errs.append(f"<{tag} name={a.get('name', '')!r}> has no label")
        if len(c) > 4 and typ == "radio":
            groups.setdefault(a.get("name"), 0)
            groups[a.get("name")] += 1
    for name, n in groups.items():
        if n > 1:
            errs.append(f"radio group {name!r} is not in a <fieldset> with a <legend>")
    return errs
