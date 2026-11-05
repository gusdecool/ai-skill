#!/usr/bin/env bash
# Tests for board-lib.sh and board-check-ready, with gh replaced by the stub in tests/stubs.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/board-worker/scripts/board-lib.sh"
CHECK="$REPO/skills/board-worker/scripts/board-check-ready"
export STUB_DIR
STUB_DIR="$(mktemp -d)"
export PATH="$REPO/tests/stubs:$PATH"
FAILS=0

# Removes the stub output directory.
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() { rm -rf "$STUB_DIR"; }
trap cleanup EXIT

# Records a failure when two values differ.
assert_eq() {
  if [ "$2" != "$3" ]; then echo "FAIL: $1 (expected '$2', got '$3')"; FAILS=$((FAILS + 1)); else echo "ok: $1"; fi
}

# Sets the issue body that the gh stub returns for gh issue view.
set_body() { jq -n --arg body "$1" '{body: $body}' >"$STUB_DIR/gh-output"; }

# Runs board-check-ready on a body, storing its stdout in OUT and its exit code in CODE.
run_check() {
  set_body "$1"
  OUT="$(bash "$CHECK" https://github.com/gusdecool/x/issues/1)"
  CODE=$?
}

# Runs board_owner_allowed in a subshell so the sourced library stays isolated.
owner_ok() { (source "$LIB"; board_owner_allowed "$1"); }

echo "Owner allow-list"
for repo in gusdecool/x bungamata/x; do
  owner_ok "$repo"
  assert_eq "$repo is allowed" "0" "$?"
done
owner_ok acme/x
assert_eq "acme/x is rejected" "1" "$?"

echo "Board items"
echo '{"items":[]}' >"$STUB_DIR/gh-output"
rm -f "$STUB_DIR/gh-args"
assert_eq "board_items prints the gh output" '{"items":[]}' "$(source "$LIB"; board_items)"
assert_eq "board_items lists project 9 as JSON" \
  "project item-list 9 --owner bungamata --format json --limit 500" "$(cat "$STUB_DIR/gh-args")"

echo "Ready check"
run_check $'## Goal\nShip the board worker.\n\n## Acceptance criteria\n- [ ] Works\n'
assert_eq "ready body prints ready" '{"ready":true,"missing":[]}' "$(jq -c . <<<"$OUT")"
assert_eq "ready body exits 0" "0" "$CODE"

run_check $'## Expected behavior\nIt works.\n'
assert_eq "missing Goal prints missing Goal" '["Goal"]' "$(jq -c .missing <<<"$OUT")"
assert_eq "missing Goal exits 1" "1" "$CODE"

run_check $'## Goal\nX\n'
assert_eq "missing acceptance section is reported" '["Acceptance criteria"]' "$(jq -c .missing <<<"$OUT")"
assert_eq "missing acceptance section exits 1" "1" "$CODE"

run_check $'## goal\r\nDo it.\r\n\r\n### done when\r\n- works\r\n'
assert_eq "CRLF and lowercase headings pass" '{"ready":true,"missing":[]}' "$(jq -c . <<<"$OUT")"
assert_eq "CRLF and lowercase headings exit 0" "0" "$CODE"

run_check $'## Goal\nX\n\n## Done when\nY\n\n## Open questions\nWhich database?\n'
assert_eq "open questions with content fail" '["Open questions"]' "$(jq -c .missing <<<"$OUT")"
assert_eq "open questions with content exit 1" "1" "$CODE"

run_check $'## Goal\nX\n\n## Done when\nY\n\n## Open questions\n\n'
assert_eq "empty open questions pass" '{"ready":true,"missing":[]}' "$(jq -c . <<<"$OUT")"
assert_eq "empty open questions exit 0" "0" "$CODE"

if [ "$FAILS" -eq 0 ]; then echo "All board-worker tests passed"; fi
exit "$FAILS"
