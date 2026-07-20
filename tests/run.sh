#!/usr/bin/env bash
# setlint test harness — fixture-driven, no repo or network needed.
#
# Each tests/fixtures/<case>/ holds a synthetic settings.json plus an
# expected.txt of `key=value` assertions checked against
# `setlint --json <case>`. Pointing the tool at the directory also
# exercises discovery (it finds settings.json inside), and expected.txt is
# invisible to the tool because discovery only looks for settings.json /
# settings.local.json.
#
# NOT `set -e`: every assertion runs even after one fails.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$REPO/bin/setlint"
FIXTURES="$REPO/tests/fixtures"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

evaluate() { python3 "$REPO/tests/check.py" "$1"; }

# --- 1. fixture assertions --------------------------------------------------

for dir in "$FIXTURES"/*/; do
  name="$(basename "$dir")"
  exp="$dir/expected.txt"
  [ -f "$exp" ] || { bad "$name: missing expected.txt"; continue; }
  out="$("$TOOL" --json "$dir" 2>/dev/null)"
  msg="$(printf '%s' "$out" | evaluate "$exp")"
  if [ -z "$msg" ]; then ok; else bad "$name: $(printf '%s' "$msg" | tr '\n' ';')"; fi
done

# --- 2. exit-code / flag behavior -------------------------------------------

"$TOOL" "$FIXTURES/clean" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "clean tree should exit 0, got $rc"

"$TOOL" "$FIXTURES/matcher-ignored" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok || bad "warnings-only should exit 1, got $rc"

"$TOOL" --strict "$FIXTURES/matcher-ignored" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "--strict on a warning should exit 2, got $rc"

"$TOOL" "$FIXTURES/hook-wrong-level" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "an error should exit 2, got $rc"

"$TOOL" "$FIXTURES/does-not-exist" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "a missing path should exit 2, got $rc"

EMPTY="$(mktemp -d)"; trap 'rmdir "$EMPTY" 2>/dev/null' EXIT
"$TOOL" "$EMPTY" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "a directory with no settings files should exit 2, got $rc"

"$TOOL" --json --ci "$FIXTURES/clean" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "--json and --ci together should exit 2, got $rc"

# --quiet suppresses the clean line; findings-only stays silent on a clean tree.
out="$("$TOOL" --quiet "$FIXTURES/clean" 2>/dev/null)"
[ -z "$out" ] && ok || bad "--quiet on a clean tree should print nothing, got: $out"

# --ci emits a GitHub Actions annotation for an error.
out="$("$TOOL" --ci "$FIXTURES/hook-wrong-level" 2>/dev/null)"
printf '%s' "$out" | grep -q '^::error file=' && ok || bad "--ci should emit ::error, got: $out"

# --- 3. a settings.json that is not valid UTF-8 -----------------------------
#
# Generated here rather than committed as a fixture: the whole point is a byte
# no editor can render, and a committed 0xff is exactly the kind of thing a
# well-meaning editor or normalizing tool silently rewrites — which would turn
# this into a test that passes while testing nothing. Building it at run time
# keeps the tracked tree valid UTF-8 and makes the offending byte explicit.
#
# Regression: the read guard used to be `except OSError`, but UnicodeDecodeError
# is a ValueError — so this input crashed with a traceback instead of raising a
# finding. Must be an error (exit 2), never a crash, and never a clean report.
BADUTF="$(mktemp -d)"
trap 'rm -rf "$EMPTY" "$BADUTF" 2>/dev/null' EXIT
printf '{"env":{"A":"\xff\xfe"}}' > "$BADUTF/settings.json"

out="$("$TOOL" --json "$BADUTF" 2>/dev/null)"; rc=$?
[ "$rc" = 2 ] && ok || bad "a non-UTF-8 settings.json should exit 2, got $rc"
printf '%s' "$out" | grep -q '"check": *"not-utf8"' && ok \
  || bad "a non-UTF-8 settings.json should raise not-utf8, got: $out"
# The crash wrote a traceback to stderr; a finding must not.
err="$("$TOOL" "$BADUTF" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q 'Traceback' && bad "non-UTF-8 input still tracebacks" || ok

# --- summary ----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
