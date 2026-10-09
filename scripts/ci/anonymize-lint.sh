#!/usr/bin/env bash
# anonymize-lint.sh [file]: check the ops/anonymize format (docs/rules.md §8).
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: anonymize-lint.sh [file]      (default: ops/anonymize)

Checks every directive (docs/rules.md §8):
  rule|<table>|<column>|<strategy>[|<arg>]
  ignore|<table or *>|<column>|<reason>
  devlogin|<table>|<key column>|<key value>|<col>=<value>[;<col>=<value>]
Strategies: email name first_name last_name phone address text null redact hash
(only redact takes an <arg>). Tables and columns are identifiers (a table may be
schema-qualified); `*` is allowed only as an ignore table; a column has at most
one rule or ignore per table; every email-looking value uses a fake domain
(example.invalid, example.com, example.org, example.net or *.test).
Exit 0 when valid, 1 with file:line errors, 2 on usage error, 3 when the file
doesn't exist ("not configured").
USAGE
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "$#" -le 1 ] || ci_usage_error "expected at most one file"
file="${1:-ops/anonymize}"
if [ ! -f "$file" ]; then
  printf 'not configured: no %s (fill in for your stack)\n' "$file" >&2
  exit "$CI_EXIT_NOT_CONFIGURED"
fi

set +e
awk -F'|' -v file="$file" '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  function err(msg) { printf "%s:%d: %s\n", file, NR, msg; bad++ }
  function ident(s) { return s ~ /^[A-Za-z_][A-Za-z0-9_]*$/ }
  function table(s) { return s ~ /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?$/ }
  function emails(s,   rest, m, dom) {
    rest = s
    while (match(rest, /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/)) {
      m = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
      dom = tolower(m); sub(/^[^@]*@/, "", dom); sub(/\.$/, "", dom)
      if (dom != "example.invalid" && dom != "example.com" && dom != "example.org" && dom != "example.net" && dom !~ /^([a-z0-9-]+\.)*[a-z0-9-]+\.test$/)
        err("email \"" m "\" must use a fake domain (example.invalid, example.com, example.org, example.net or *.test)")
    }
  }
  BEGIN {
    split("email name first_name last_name phone address text null redact hash", w, " ")
    for (i in w) strategy[w[i]] = 1
  }
  { sub(/\r$/, "") }
  /^[ \t]*$/ || /^[ \t]*#/ { next }
  {
    d = trim($1)
    for (i = 1; i <= NF; i++) f[i] = trim($i)
    emails($0)
    if (d == "rule") {
      if (NF < 4 || NF > 5) { err("rule needs rule|<table>|<column>|<strategy>[|<arg>]"); next }
      if (f[2] == "*") { err("`*` is allowed as a table only in ignore lines"); next }
      if (!table(f[2])) err("bad table name: " f[2])
      if (!ident(f[3])) err("bad column name: " f[3])
      if (!(f[4] in strategy)) err("unknown strategy: " f[4] " (email name first_name last_name phone address text null redact hash)")
      if (NF == 5 && f[4] != "redact") err("only the redact strategy takes an argument")
      key = tolower(f[2]) "|" tolower(f[3])
      if (key in seen) err("column " f[2] "." f[3] " already has a " seen[key] " line (line " seenline[key] ")")
      else { seen[key] = "rule"; seenline[key] = NR }
    } else if (d == "ignore") {
      if (NF != 4) { err("ignore needs ignore|<table or *>|<column>|<reason>"); next }
      if (f[2] != "*" && !table(f[2])) err("bad table name: " f[2])
      if (!ident(f[3])) err("bad column name: " f[3])
      if (f[4] == "") err("ignore needs a reason")
      key = tolower(f[2]) "|" tolower(f[3])
      if (key in seen) err("column " f[2] "." f[3] " already has a " seen[key] " line (line " seenline[key] ")")
      else { seen[key] = "ignore"; seenline[key] = NR }
    } else if (d == "devlogin") {
      if (NF != 5) { err("devlogin needs devlogin|<table>|<key column>|<key value>|<col>=<value>[;<col>=<value>]"); next }
      if (!table(f[2])) err("bad table name: " f[2])
      if (!ident(f[3])) err("bad key column name: " f[3])
      if (f[4] == "") err("devlogin needs a key value")
      n = split(f[5], pairs, ";")
      if (n == 0) err("devlogin needs at least one <col>=<value>")
      for (j = 1; j <= n; j++) {
        p = trim(pairs[j])
        if (p !~ /=/) { err("devlogin assignment needs <col>=<value>: " p); continue }
        c = p; sub(/=.*/, "", c); c = trim(c)
        if (!ident(c)) err("bad devlogin column name: " c)
      }
    } else {
      err("unknown directive: " d " (rule, ignore or devlogin)")
    }
  }
  END {
    exit (bad > 0) ? 1 : 0
  }
' "$file"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  ci_error "$file has format errors (see above; docs/rules.md §8)"
  exit 1
fi
ci_info "ok: $file"
