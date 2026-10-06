#!/bin/sh
# Warm fetch-llama.sh must not re-hash an unchanged archive or unpacked tree.
# FULL_VERIFY=1, a changed file, and a missing stamp still hash.
# No network and no real llama-server.
#   sh tests/test_fetch_llama_stamp.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
fails=0
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

d=$T/sandbox
mkdir -p "$d/config" "$T/stubs" "$T/src"
cp -R "$ROOT/scripts" "$d/scripts"

printf '%s\n' '#!/bin/sh' 'echo "version: test"' > "$T/src/llama-server"
printf 'lib\n' > "$T/src/libfake.so"
chmod +x "$T/src/llama-server"
ln -s llama-server "$T/src/llama-server.link"
tar -C "$T/src" -czf "$T/llama.tar.gz" llama-server libfake.so llama-server.link
sum=$(/usr/bin/sha256sum "$T/llama.tar.gz" | cut -d' ' -f1)

cat > "$d/config/llama-release.json" <<EOF
{
  "tag": "btest",
  "base_url": "https://example.invalid/llama/",
  "assets": [
    {
      "platform": "linux-x64",
      "variant": "cpu",
      "file": "llama.tar.gz",
      "sha256": "$sum"
    }
  ]
}
EOF

cat > "$T/stubs/curl" <<EOF
#!/bin/sh
out=""
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-o" ]; then out=\$a; fi
  prev=\$a
  case "\$a" in
    http://*|https://*) printf '%s\n' "\$a" >> "$T/curl.log" ;;
  esac
done
[ -n "\$out" ] || exit 2
cp "$T/llama.tar.gz" "\$out"
exit 0
EOF
cat > "$T/stubs/sha256sum" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$T/sha.log"
exec /usr/bin/sha256sum "\$@"
EOF
chmod +x "$T/stubs/curl" "$T/stubs/sha256sum"
: > "$T/curl.log"
: > "$T/sha.log"

dest=$d/bin/llama-btest-linux-x64-cpu
run_fetch() {
  : > "$T/sha.log"
  : > "$T/curl.log"
  ( cd "$d" && PATH="$T/stubs:$PATH" FULL_VERIFY="$1" \
      sh scripts/fetch-llama.sh --platform linux-x64 --variant cpu >"$T/out" 2>"$T/err" )
}
sha_n() { wc -l < "$T/sha.log" | tr -d ' '; }
curl_n() { wc -l < "$T/curl.log" | tr -d ' '; }
rm_verified() {
  for s in "$dest"/.verified-*; do
    [ -e "$s" ] || continue
    rm -f "$s"
  done
}

if run_fetch 0; then ok "first fetch"
else bad "first fetch failed: $(cat "$T/err")"; fi
if [ "$(sha_n)" -gt 0 ] && grep -q 'llama.tar.gz' "$T/sha.log" && grep -q 'llama-server' "$T/sha.log"; then
  ok "first fetch hashes the archive and the tree"
else bad "first fetch did not hash: $(cat "$T/sha.log")"; fi
if [ "$(curl_n)" -eq 1 ]; then ok "first fetch downloads once"
else bad "first fetch curl count $(curl_n)"; fi
if [ -x "$dest/llama-server" ] && grep -q 'version: test' "$T/err"; then ok "fake llama-server runs --version"
else bad "missing unpacked server or version line: $(cat "$T/err")"; fi

if run_fetch 0; then ok "warm fetch"
else bad "warm fetch failed: $(cat "$T/err")"; fi
if [ "$(sha_n)" -eq 0 ]; then ok "warm fetch does not hash"
else bad "warm fetch hashed: $(cat "$T/sha.log")"; fi
if [ "$(curl_n)" -eq 0 ]; then ok "warm fetch does not download"
else bad "warm fetch downloaded"; fi
if grep -q 'unchanged since its last sha256 check' "$T/err"; then ok "warm fetch says unchanged"
else bad "warm fetch missing unchanged note: $(cat "$T/err")"; fi

if run_fetch 1; then ok "FULL_VERIFY fetch"
else bad "FULL_VERIFY fetch failed: $(cat "$T/err")"; fi
if [ "$(sha_n)" -gt 0 ] && grep -q 'llama.tar.gz' "$T/sha.log" && grep -q 'llama-server' "$T/sha.log"; then
  ok "FULL_VERIFY=1 still hashes archive and tree"
else bad "FULL_VERIFY did not hash: $(cat "$T/sha.log")"; fi
if [ "$(curl_n)" -eq 0 ]; then ok "FULL_VERIFY does not download a match"
else bad "FULL_VERIFY downloaded"; fi

if run_fetch 0; then ok "warm after FULL_VERIFY"
else bad "warm after FULL_VERIFY failed: $(cat "$T/err")"; fi
if [ "$(sha_n)" -eq 0 ]; then ok "stamp refreshed by FULL_VERIFY skips the next hash"
else bad "hash after FULL_VERIFY: $(cat "$T/sha.log")"; fi

rm -f "$d/.cache/dl/llama.tar.gz.fp"
if run_fetch 0; then ok "missing archive stamp fetch"
else bad "missing archive stamp failed: $(cat "$T/err")"; fi
if grep -q 'llama.tar.gz' "$T/sha.log"; then ok "missing archive stamp still hashes"
else bad "missing archive stamp did not hash: $(cat "$T/sha.log")"; fi
if [ "$(curl_n)" -eq 0 ]; then ok "missing archive stamp does not download a match"
else bad "missing archive stamp downloaded"; fi

for s in "$dest"/.verified-*.fp; do
  [ -e "$s" ] || continue
  rm -f "$s"
done
if run_fetch 0; then ok "missing tree fingerprint fetch"
else bad "missing tree fingerprint failed: $(cat "$T/err")"; fi
if grep -q 'llama-server' "$T/sha.log"; then ok "missing tree fingerprint still hashes"
else bad "missing tree fingerprint did not hash: $(cat "$T/sha.log")"; fi
if grep -q 'unpacking again' "$T/err"; then bad "missing tree fingerprint unpacked again"
else ok "missing tree fingerprint keeps an intact unpack"; fi

saved=$T/server-copy
cp -p "$dest/llama-server" "$saved"
printf 'x\n' >> "$dest/llama-server"
if run_fetch 0; then ok "changed tree fetch"
else bad "changed tree failed: $(cat "$T/err")"; fi
if grep -q 'unpacking again' "$T/err" && grep -q 'llama-server' "$T/sha.log"; then
  ok "changed tree hashes and unpacks again"
else bad "changed tree did not recheck: $(cat "$T/err")"; fi
if cmp -s "$saved" "$dest/llama-server"; then ok "changed tree is restored from the archive"
else bad "changed tree was not restored"; fi

rm_verified
if run_fetch 0; then ok "missing content stamp fetch"
else bad "missing content stamp failed: $(cat "$T/err")"; fi
if grep -q 'llama-server' "$T/sha.log"; then ok "missing content stamp still hashes"
else bad "missing content stamp did not hash: $(cat "$T/sha.log")"; fi

printf 'corrupt\n' >> "$d/.cache/dl/llama.tar.gz"
if run_fetch 0; then ok "changed archive fetch"
else bad "changed archive failed: $(cat "$T/err")"; fi
if grep -q 'llama.tar.gz' "$T/sha.log"; then ok "changed archive still hashes"
else bad "changed archive did not hash: $(cat "$T/sha.log")"; fi
if [ "$(curl_n)" -ge 1 ]; then ok "changed archive is downloaded again"
else bad "changed archive was not downloaded"; fi
if [ -x "$dest/llama-server" ]; then ok "server still unpacked after a bad archive"
else bad "server missing after bad archive"; fi

[ "$fails" = 0 ] || { echo "test_fetch_llama_stamp: $fails failed" >&2; exit 1; }
echo "test_fetch_llama_stamp: OK"
