#!/usr/bin/env bash
# setlint test harness — fixture-driven.
#
# Each fixture is a directory tests/fixtures/<name>/ holding a project
# tree (a .claude/ with settings + any hook scripts) plus an
# expected.txt:
#
#   <expected exit code>
#   <check name>          (zero or more lines; repeat a name to expect
#   <check name>           it more than once)
#
# expected.txt is compared as a sorted multiset of check names against
# the checks setlint actually emits (parsed from --json), plus the exit
# code. setlint discovers settings under the fixture dir, so expected.txt
# sitting at the fixture root is never linted.
#
# The executable bit on fixture hook scripts is load-bearing (the
# not-exec fixture commits a 644 script): preserve it under git.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SETLINT="$REPO/bin/setlint"
FIXTURES="$REPO/tests/fixtures"

PASS=0
FAIL=0
declare -a FAILURES=()

# Extract emitted check names (sorted) from a fixture's --json output.
emitted_checks() {
  "$SETLINT" --json "$1" 2>/dev/null \
    | jq -r '.findings[].check' \
    | LC_ALL=C sort
}

run_fixture() {
  local dir="$1" name
  name="$(basename "$dir")"

  local exp_exit exp_checks
  exp_exit="$(head -n1 "$dir/expected.txt")"
  exp_checks="$(tail -n +2 "$dir/expected.txt" | grep -vE '^\s*$' | LC_ALL=C sort)"

  "$SETLINT" "$dir" >/dev/null 2>&1
  local got_exit=$?
  local got_checks
  got_checks="$(emitted_checks "$dir")"

  local ok=1 why=""
  if [ "$got_exit" != "$exp_exit" ]; then
    ok=0; why="exit $got_exit (want $exp_exit)"
  fi
  if [ "$got_checks" != "$exp_checks" ]; then
    ok=0
    why="${why:+$why; }checks differ"
  fi

  if [ "$ok" -eq 1 ]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s — %s\n' "$name" "$why"
    FAILURES+=("$name")
    {
      printf '       expected exit %s, checks: [%s]\n' \
        "$exp_exit" "$(printf '%s' "$exp_checks" | tr '\n' ' ')"
      printf '       got      exit %s, checks: [%s]\n' \
        "$got_exit" "$(printf '%s' "$got_checks" | tr '\n' ' ')"
    }
  fi
}

echo "setlint test suite"
echo

for dir in "$FIXTURES"/*/; do
  [ -f "$dir/expected.txt" ] || continue
  run_fixture "${dir%/}"
done

# --- behavioral cases not tied to a fixture tree -----------------------------
behavioral() {
  local label="$1"; shift
  local want_exit="$1"; shift
  "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want_exit" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s — exit %s (want %s)\n' "$label" "$got" "$want_exit"
    FAILURES+=("$label")
  fi
}

echo
echo "behavioral:"
behavioral "version exits 0"          0 "$SETLINT" --version
behavioral "help exits 0"             0 "$SETLINT" --help
behavioral "unknown flag exits 2"     2 "$SETLINT" --nope
behavioral "missing path exits 2"     2 "$SETLINT" /no/such/dir/setlint-test
behavioral "no settings -> exit 2"    2 "$SETLINT" "$REPO/bin"
behavioral "json+ci exclusive"        2 "$SETLINT" --json --ci "$FIXTURES/clean"
behavioral "strict warns -> exit 2"   2 "$SETLINT" --strict "$FIXTURES/warnings"
behavioral "strict clean -> exit 0"   0 "$SETLINT" --strict "$FIXTURES/clean"
behavioral "file arg directly"        2 "$SETLINT" "$FIXTURES/invalid-json/.claude/settings.json"
behavioral "project-dir override"     2 "$SETLINT" --project-dir /no/such "$FIXTURES/clean"

echo
echo "------------------------------------"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'failures: %s\n' "${FAILURES[*]}"
  exit 1
fi
exit 0
