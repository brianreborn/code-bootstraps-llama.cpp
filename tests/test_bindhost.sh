#!/bin/sh
# HOST bind rules: loopback stays reachable when the user names an external address.
#   sh tests/test_bindhost.sh
set -eu
ROOT_REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_REPO/scripts/lib/bindhost.sh"
fails=0
note() {
  if [ "$1" = ok ]; then echo "ok   $2"
  else echo "FAIL $2"; fails=$((fails + 1)); fi
}
eq() {
  got=$1 want=$2 name=$3
  if [ "$got" = "$want" ]; then note ok "$name"
  else note bad "$name (got $(printf %s "$got" | tr '\n' ',') want $want)"; fi
}
pubs() { public_hosts "$1" | tr '\n' ',' | sed 's/,$//'; }

eq "$(bind_hosts 127.0.0.1)" "127.0.0.1" "loopback bind unchanged"
eq "$(probe_host_of 127.0.0.1)" "127.0.0.1" "loopback probe"
eq "$(pubs 127.0.0.1)" "" "loopback has no public address"

eq "$(bind_hosts localhost)" "localhost" "localhost bind kept"
eq "$(probe_host_of localhost)" "127.0.0.1" "localhost probes 127.0.0.1"

eq "$(bind_hosts ::1)" "::1" "::1 bind kept"
eq "$(probe_host_of ::1)" "::1" "::1 probe"
eq "$(pubs ::1)" "" "::1 has no public address"
eq "$(url_host ::1)" "[::1]" "::1 url brackets"

eq "$(bind_hosts 0.0.0.0)" "0.0.0.0" "wildcard v4 unchanged"
eq "$(probe_host_of 0.0.0.0)" "127.0.0.1" "wildcard v4 probes loopback"
eq "$(pubs 0.0.0.0)" "" "wildcard v4 has no public address"

eq "$(bind_hosts ::)" "::" "wildcard v6 unchanged"
eq "$(probe_host_of ::)" "127.0.0.1" "wildcard v6 probes loopback"
eq "$(pubs ::)" "" "wildcard v6 has no public address"

eq "$(bind_hosts 192.168.1.20)" "127.0.0.1,192.168.1.20" "lan address also binds loopback"
eq "$(probe_host_of 192.168.1.20)" "127.0.0.1" "lan address probes loopback"
eq "$(pubs 192.168.1.20)" "192.168.1.20" "lan address is public"
eq "$(url_host 192.168.1.20)" "192.168.1.20" "v4 url has no brackets"

eq "$(bind_hosts 127.0.0.1,192.168.1.20)" "127.0.0.1,192.168.1.20" "explicit loopback list unchanged"
eq "$(probe_host_of 127.0.0.1,192.168.1.20)" "127.0.0.1" "explicit list probes loopback"
eq "$(pubs '127.0.0.1,192.168.1.20')" "192.168.1.20" "explicit list public is the lan address"

eq "$(bind_hosts 10.0.0.2,10.0.0.3)" "127.0.0.1,10.0.0.2,10.0.0.3" "two lan addresses prepend loopback"
eq "$(pubs '10.0.0.2,10.0.0.3')" "10.0.0.2,10.0.0.3" "two lan addresses are both public"

eq "$(bind_hosts fe80::1)" "127.0.0.1,fe80::1" "link-local also binds loopback"
eq "$(probe_host_of fe80::1)" "127.0.0.1" "link-local probes loopback"
eq "$(pubs fe80::1)" "fe80::1" "link-local is public"
eq "$(url_host fe80::1)" "[fe80::1]" "link-local url brackets"

eq "$(bind_hosts '')" "127.0.0.1" "empty host is loopback"
eq "$(bind_hosts '0.0.0.0,192.168.1.20')" "0.0.0.0,192.168.1.20" "wildcard list is not doubled"
eq "$(pubs '0.0.0.0,192.168.1.20')" "192.168.1.20" "wildcard list still names the lan address"
eq "$(probe_host_of '::1,fe80::1')" "::1" "list with only ::1 probes ::1"

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo "bindhost: all checks passed"
