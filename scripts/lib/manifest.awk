# Minimal reader for this repo's pretty-printed JSON manifests (one "key": value per
# line, flat objects inside an array), so the launchers need no Python.
# Prints one tab-separated line per object whose keys match the filters.
#   awk -v match_kv="pick=default role=coder" -v fields="role repo revision file sha256" -f manifest.awk FILE
# Missing fields print as "-"; true/false print as yes/no. Strings must not contain
# escaped quotes (checked by scripts/check-manifests.sh).
function reset() { split("", obj) }
function emit(   i, n, f, out, ok, nm, m, kv) {
  ok = 1
  nm = split(match_kv, m, " ")
  for (i = 1; i <= nm; i++) { split(m[i], kv, "="); if (!((kv[1]) in obj) || obj[kv[1]] != kv[2]) ok = 0 }
  if (!ok || !("file" in obj)) return
  n = split(fields, f, " "); out = ""
  for (i = 1; i <= n; i++) out = out (i > 1 ? "\t" : "") ((f[i] in obj) && obj[f[i]] != "" ? obj[f[i]] : "-")
  print out
}
BEGIN { reset() }
/^[ \t]*[{][ \t]*$/ { reset(); next }   # a new object: nothing carries over from the enclosing one
/^[ \t]*"[A-Za-z0-9_]+":[ \t]*/ {
  line = $0; sub(/^[ \t]*"/, "", line)
  k = line; sub(/".*/, "", k)
  v = line; sub(/^[A-Za-z0-9_]+":[ \t]*/, "", v); sub(/[ \t]*,?[ \t]*$/, "", v)
  if (v ~ /^"/) { sub(/^"/, "", v); sub(/"$/, "", v) }
  else if (v == "true") v = "yes"
  else if (v == "false") v = "no"
  obj[k] = v
  next
}
/^[ \t]*},?[ \t]*$/ { emit(); reset() }
