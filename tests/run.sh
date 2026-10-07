#!/usr/bin/env bash
# Minimal test runner (bash 3.2).
# Usage: bash tests/run.sh [pattern]
#   Runs each tests/test_*.sh in its own bash process; each test_* function in its own
#   subshell. pattern filters by substring of "file:function" (e.g. "takeover", "brg_run").
# Env: TEST_TIMEOUT — per-test limit in seconds (default 60).

case ${BASH_SOURCE[0]} in */*) TESTS_DIR=${BASH_SOURCE[0]%/*} ;; *) TESTS_DIR=. ;; esac
TESTS_DIR=$(cd "$TESTS_DIR" && pwd)
ROOT=$(cd "$TESTS_DIR/.." && pwd)
export TESTS_DIR ROOT

# Child mode: run the tests of one file.
if [ "${1:-}" = "--file" ]; then
  file=$2 pattern=$3 results=$4
  . "$TESTS_DIR/lib.sh"
  _t_init
  . "$file"
  base=${file##*/}
  for fn in $(awk '
      /^[ \t]*(function[ \t]+)?test_[A-Za-z0-9_]+[ \t]*\(\)/ {
        s = $0; sub(/^[ \t]*(function[ \t]+)?/, "", s); sub(/[ \t]*\(.*/, "", s); print s
      }' "$file"); do
    case "$base:$fn" in *"$pattern"*) ;; *) continue ;; esac
    declare -F "$fn" >/dev/null || continue
    _t_run_one "$base" "$fn" "$results"
  done
  exit 0
fi

pattern=${1:-}
tmp=${TMPDIR:-/tmp}
tmp=${tmp%/}
while :; do
  RESULTS=$tmp/brg-results.$$.$RANDOM
  [ -e "$RESULTS" ] || break
done
: >"$RESULTS"
trap 'rm -f "$RESULTS"' EXIT

for f in "$TESTS_DIR"/test_*.sh; do
  [ -f "$f" ] || continue
  bash "$TESTS_DIR/run.sh" --file "$f" "$pattern" "$RESULTS"
done

pass=$(awk '$1 == "PASS"' "$RESULTS" | wc -l | tr -d ' ')
failed=$(awk '$1 == "FAIL"' "$RESULTS" | wc -l | tr -d ' ')
echo "── итого: $pass прошло, $failed упало"
[ "$((pass + failed))" -gt 0 ] || { echo "тесты не найдены${pattern:+ по шаблону '$pattern'}"; exit 1; }
[ "$failed" -eq 0 ]
