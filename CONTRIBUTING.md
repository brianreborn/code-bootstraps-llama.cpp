# Contributing

## Console and log output style (ASCII/ANSI house style)

Applies to new PRs. Chrome only: user and model text stays UTF-8.

### Before you open a PR

- [ ] Console/log chrome picks its glyph tier at runtime: Unicode box/blocks on UTF-8,
      cp437 bytes on an OEM console, 7-bit `+-|#` for pipes, logs and unknown encodings.
- [ ] No em dash, emoji or arrow in console/log output without a fallback (they are not in cp437).
- [ ] ANSI color only on a TTY with NO_COLOR unset and TERM != dumb; always reset with ESC[0m; no color in logs.
- [ ] Banners are <=78 columns, contain no tabs, and are skippable (--quiet or not on a TTY).
- [ ] User and model text stays UTF-8; these rules cover chrome only.
- [ ] Art is authored once as cp437 bytes; tiers are derived through one shared helper (~30 lines) per language.
- [ ] No new dependency added only for terminal chrome/colour.

### Reviewer checklist

- [ ] BLOCKING: a decorative glyph emitted on a console/log path without tier selection.
      Spot-check: `LC_ALL=C grep -n '[^ -~	]' FILE`
