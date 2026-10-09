#!/usr/bin/env bash
# pii-guard.sh: a migration that adds a personal-looking column needs an ops/anonymize entry.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
CI_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$CI_SELF_DIR/common.sh"

usage() {
  cat <<'USAGE'
Usage: pii-guard.sh --base <sha> [--head <sha>]

Run in the project root (the ci working directory) inside the git checkout.
For files changed in <base>...<head> (env BASE_SHA, HEAD_SHA work too) that
match MIGRATIONS_GLOB from ops/project.conf, it finds the columns the added
lines create (SQL ADD COLUMN and column definitions, quoted names and symbols
used by migration DSLs, `name =` / `name:` field lines), keeps those whose
name matches config/pii-patterns.txt, and requires a `rule|<table>|<column>|…`
or `ignore|<table>|<column>|<reason>` line for each in ops/anonymize (matched
by column name, case-insensitive; the table may be any, or * for ignore).
Comment lines and destructive lines (drops, renames) are skipped.
Exit 0 (also when MIGRATIONS_GLOB isn't set: a notice), 1 when a column is
missing from ops/anonymize, 2 on usage error, 5 outside a git repo.
USAGE
}

base="${BASE_SHA:-}"
head="${HEAD_SHA:-HEAD}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base) [ "$#" -ge 2 ] || ci_usage_error "--base needs a value"; base="$2"; shift 2 ;;
    --head) [ "$#" -ge 2 ] || ci_usage_error "--head needs a value"; head="$2"; shift 2 ;;
    *) ci_usage_error "unknown argument: $1" ;;
  esac
done
[ -n "$base" ] || ci_usage_error "missing --base (or BASE_SHA)"
[ -z "$head" ] && head=HEAD
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || ci_die "$CI_EXIT_PREREQ" "not inside a git checkout: $(pwd)"
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || ci_die "$CI_EXIT_PREREQ" "base commit not found: $base (fetch-depth 0?)"
git rev-parse --verify --quiet "$head^{commit}" >/dev/null || ci_die "$CI_EXIT_PREREQ" "head commit not found: $head"

if [ ! -f ops/project.conf ]; then
  ci_notice "no ops/project.conf: PII guard not configured; skipped"
  exit 0
fi
mig_globs=$(ci_conf_get ops/project.conf MIGRATIONS_GLOB "")
if [ -z "$mig_globs" ]; then
  ci_notice "MIGRATIONS_GLOB is empty in ops/project.conf: PII guard skipped"
  exit 0
fi

tmp=$(ci_mktemp_dir)
trap 'rm -rf "${tmp:?}"' EXIT

set -f
# shellcheck disable=SC2086  # MIGRATIONS_GLOB is a space-separated list of globs
ci_globs_regex_file "$tmp/mig.re" $mig_globs
set +f
ci_patterns_file "$CI_CONFIG_DIR/pii-patterns.txt" "$tmp/pii.re"
ci_patterns_file "$CI_CONFIG_DIR/destructive-migration-patterns.txt" "$tmp/destructive.re"

# Columns that ops/anonymize covers (rule or ignore), lower case.
: > "$tmp/covered"
if [ -f ops/anonymize ]; then
  awk -F'|' '
    { sub(/\r$/, "") }
    /^[ \t]*#/ || NF < 3 { next }
    {
      d = $1; gsub(/^[ \t]+|[ \t]+$/, "", d)
      c = $3; gsub(/^[ \t]+|[ \t]+$/, "", c)
      if (d == "rule" || d == "ignore") print tolower(c)
    }' ops/anonymize | sort -u > "$tmp/covered"
fi

# extract_columns : stdin = added lines of a migration; stdout = candidate column names
extract_columns() {
  awk '
    function emit(n) { if (n ~ /^[a-z_][a-z0-9_]*$/ && !(n in skip)) print n }
    BEGIN {
      split("add alter column constraint index primary foreign unique key check partition fulltext spatial value attribute if not exists table create references default null on to as", w, " ")
      for (i in w) skip[w[i]] = 1
      types = "(varchar|character|char|nvarchar|nchar|text|ntext|citext|tinytext|mediumtext|longtext|int|int2|int4|int8|integer|bigint|smallint|tinyint|mediumint|serial|bigserial|smallserial|uuid|bool|boolean|date|datetime|datetime2|timestamp|timestamptz|time|timetz|interval|json|jsonb|xml|numeric|decimal|money|real|double|float|bytea|blob|tinyblob|mediumblob|longblob|binary|varbinary|bit|enum|set|inet|cidr|macaddr|string|bytes|year|point|geometry|geography|tsvector)"
    }
    {
      line = tolower($0)
      t = line; sub(/^[ \t]+/, "", t)
      if (t ~ /^(--|#|\/\/|\/\*|\*)/) next

      # SQL: ADD [COLUMN] [IF NOT EXISTS] name
      s = line
      while (match(s, /(^|[^a-z0-9_])add[ \t]+(column[ \t]+)?(if[ \t]+not[ \t]+exists[ \t]+)?["`[]?[a-z_][a-z0-9_]*/)) {
        m = substr(s, RSTART, RLENGTH); sub(/.*[ \t"`[]/, "", m); emit(m)
        s = substr(s, RSTART + RLENGTH)
      }
      # SQL / schema DSL column definition: name TYPE
      if (match(line, "^[ \t]*[\"`[]?[a-z_][a-z0-9_]*[]\"`]?[ \t]+" types "([^a-z0-9_]|$)")) {
        m = line; sub(/^[ \t]*["`[]?/, "", m); sub(/[^a-z0-9_].*$/, "", m); emit(m)
      }
      # quoted names: add_column(..., "email"), $table->string("email"), sa.Column("email")
      s = line
      while (match(s, /["`'"'"'][a-z_][a-z0-9_]*["`'"'"']/)) {
        emit(substr(s, RSTART + 1, RLENGTH - 2)); s = substr(s, RSTART + RLENGTH)
      }
      # symbols: t.string :email, add :email, :string
      s = line
      while (match(s, /(^|[^:a-z0-9_]):[a-z_][a-z0-9_]*/)) {
        m = substr(s, RSTART, RLENGTH); sub(/^[^:]*:/, "", m); emit(m)
        s = substr(s, RSTART + RLENGTH)
      }
      # field lines: email = models.EmailField(...), email: { type: ... }, Email = table.Column<...>
      if (match(line, /^[ \t]*[a-z_][a-z0-9_]*[ \t]*(=[^=]|:[^:]|:$)/)) {
        m = line; sub(/^[ \t]*/, "", m); sub(/[^a-z0-9_].*$/, "", m); emit(m)
      }
    }'
}

git diff -z --no-color --no-ext-diff --relative --name-only --diff-filter=AMR -M "$base...$head" > "$tmp/files"
missing=0
n_mig=0
while IFS= read -r -d '' path; do
  printf '%s\n' "$path" | grep -Eq -f "$tmp/mig.re" || continue
  n_mig=$((n_mig + 1))
  ci_diff_added_lines "$base" "$head" "$path" > "$tmp/added"
  grep -Eiv -f "$tmp/destructive.re" "$tmp/added" > "$tmp/added_nd" || true
  extract_columns < "$tmp/added_nd" | sort -u > "$tmp/cols"
  while IFS= read -r col; do
    [ -n "$col" ] || continue
    printf '%s\n' "$col" | grep -Eiq -f "$tmp/pii.re" || continue
    if grep -Fxq "$col" "$tmp/covered"; then
      ci_info "ok: $path adds '$col', covered by ops/anonymize"
    else
      missing=$((missing + 1))
      ci_error "$path adds column '$col', which looks personal: add 'rule|<table>|$col|<strategy>' or 'ignore|<table>|$col|<reason>' to ops/anonymize"
      ci_summary "- :x: \`$path\` adds personal-looking column \`$col\` with no ops/anonymize rule or ignore"
    fi
  done < "$tmp/cols"
done < "$tmp/files"

ci_info "checked $n_mig changed migration file(s)"
if [ "$missing" -gt 0 ]; then
  ci_error "PII guard: $missing personal-looking column(s) without an ops/anonymize entry (docs/rules.md §8)"
  exit 1
fi
ci_info "ok: every personal-looking column added by a migration is in ops/anonymize"
