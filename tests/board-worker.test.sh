#!/usr/bin/env bash
# Tests for board-lib.sh and board-check-ready, with gh replaced by the stub in tests/stubs.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/board-worker/scripts/board-lib.sh"
CHECK="$REPO/skills/board-worker/scripts/board-check-ready"
PICK="$REPO/skills/board-worker/scripts/board-pick-next"
SETSTATUS="$REPO/skills/board-worker/scripts/board-set-status"
PICKPROV="$REPO/skills/board-worker/scripts/pick-provider"
FIX="$REPO/tests/fixtures/board"
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

# Resets the stub state and loads the board fixtures; every issue is ready unless a test says otherwise.
reset_board() {
  rm -f "$STUB_DIR"/gh-* "$STUB_DIR/calls.log"
  cp "$FIX/items.json" "$STUB_DIR/gh-project-item-list"
  cp "$FIX/fields.json" "$STUB_DIR/gh-project-field-list"
  cp "$FIX/project.json" "$STUB_DIR/gh-project-view"
  set_body $'## Goal\nX\n\n## Done when\nY\n'
}

# Makes the issue with the given number unready by giving it an empty body.
make_unready() { echo '{"body":""}' >"$STUB_DIR/gh-issue-view-$1"; }

# Runs board-pick-next with a fixed date, storing stdout in OUT and the exit code in CODE.
run_pick() {
  OUT="$(TODAY=2026-11-06 bash "$PICK" 2>/dev/null)"
  CODE=$?
}

echo "Pick next"
reset_board
run_pick
assert_eq "High priority in the current iteration wins" "12" "$(jq -r .number <<<"$OUT")"
assert_eq "pick prints repo, url and item id" \
  '{"repo":"gusdecool/x","number":12,"url":"https://github.com/gusdecool/x/issues/12","itemId":"I12"}' \
  "$(jq -c . <<<"$OUT")"
assert_eq "pick exits 0" "0" "$CODE"
assert_eq "disallowed owner is never checked" "0" "$(grep -c 'acme/y' "$STUB_DIR/calls.log" || true)"

reset_board
jq 'del(.items[2])' "$FIX/items.json" >"$STUB_DIR/gh-project-item-list"
run_pick
assert_eq "High in an older iteration beats a lower priority" "11" "$(jq -r .number <<<"$OUT")"

reset_board
jq '.items |= map(select(.id == "I10" or .id == "I14"))' "$FIX/items.json" >"$STUB_DIR/gh-project-item-list"
run_pick
assert_eq "a card with a Priority beats one with none" "10" "$(jq -r .number <<<"$OUT")"
jq '.items |= map(select(.id == "I14"))' "$FIX/items.json" >"$STUB_DIR/gh-project-item-list"
run_pick
assert_eq "a card with no Priority is still picked" "14" "$(jq -r .number <<<"$OUT")"

reset_board
make_unready 12
run_pick
assert_eq "an unready card is skipped for the next one" "11" "$(jq -r .number <<<"$OUT")"
assert_eq "an unready card gets a comment naming the gap" "1" \
  "$(grep -c '^issue comment https://github.com/gusdecool/x/issues/12 --body .*Missing: Goal, Acceptance criteria' \
    "$STUB_DIR/calls.log")"
assert_eq "an unready card gets the HITL label" "1" \
  "$(grep -c '^issue edit https://github.com/gusdecool/x/issues/12 --add-label HITL' "$STUB_DIR/calls.log")"
assert_eq "an unready card moves to Backlog" "1" \
  "$(grep -c '^project item-edit .*--id I12 .*--single-select-option-id o-backlog' "$STUB_DIR/calls.log")"

reset_board
jq '.items |= map(select(.id == "I13"))' "$FIX/items.json" >"$STUB_DIR/gh-project-item-list"
run_pick
assert_eq "no qualifying card exits 1" "1" "$CODE"

reset_board
jq '.items[2].iteration = "S3" | .items[1].iteration = {startDate: "2026-11-02"}' "$FIX/items.json" \
  >"$STUB_DIR/gh-project-item-list"
run_pick
assert_eq "string or duration-less iteration does not crash" "0" "$CODE"
assert_eq "malformed iterations sort as not current, by number" "11" "$(jq -r .number <<<"$OUT")"

reset_board
make_unready 12
touch "$STUB_DIR/gh-fail-issue-comment"
run_pick
assert_eq "a failing gh while parking exits 2" "2" "$CODE"

echo "Set status"
reset_board
bash "$SETSTATUS" https://github.com/gusdecool/x/issues/10 "In progress" 2>/dev/null
assert_eq "set-status exits 0" "0" "$?"
assert_eq "set-status sends the project, card, field and option IDs" \
  "project item-edit --project-id PROJ9 --id I10 --field-id FS --single-select-option-id o-prog" \
  "$(grep '^project item-edit' "$STUB_DIR/calls.log")"
reset_board
bash "$SETSTATUS" https://github.com/gusdecool/x/issues/10 Doing 2>/dev/null
assert_eq "set-status rejects an unknown status with 2" "2" "$?"
assert_eq "set-status does not edit on an unknown status" "0" "$(grep -c '^project item-edit' "$STUB_DIR/calls.log")"
bash "$SETSTATUS" https://github.com/gusdecool/x/issues/999 Done 2>/dev/null
assert_eq "set-status rejects an unknown card with 2" "2" "$?"

echo "Pick provider"
cat >"$STUB_DIR/orca" <<'STUB'
#!/usr/bin/env bash
# Test stub for orca: prints the fixture named by $ACCOUNTS_FIXTURE for "account list --json".
cat "$ACCOUNTS_FIXTURE"
STUB
chmod +x "$STUB_DIR/orca"
cat >"$STUB_DIR/codex-models.json" <<'JSON'
{"models":[{"slug":"gpt-6-sol","visibility":"list"},{"slug":"gpt-6.1-sol","visibility":"list"},
 {"slug":"gpt-7-sol","visibility":"hide"},{"slug":"gpt-5.6-sol","visibility":"list"},
 {"slug":"gpt-6.1-terra","visibility":"list"}]}
JSON

# Runs pick-provider against a fixture at the fixed clock, storing stdout in OUT and the exit code in CODE.
run_provider() {
  ACCOUNTS_FIXTURE="$1" ORCA_BIN="$STUB_DIR/orca" CODEX_MODELS_CACHE="$STUB_DIR/codex-models.json" \
    NOW_MS=1000000000000 bash "$PICKPROV" 2>/dev/null
}
# Writes a modified copy of the accounts fixture, built from a jq filter, to $STUB_DIR/accounts.json.
tweak_accounts() { jq "$1" "$FIX/accounts.json" >"$STUB_DIR/accounts.json"; }

OUT="$(run_provider "$FIX/accounts.json")"
CODE=$?
assert_eq "worked example picks codex" \
  '{"provider":"codex","model":"gpt-6.1-sol","tier":"workhorse"}' "$(jq -c . <<<"$OUT")"
assert_eq "worked example exits 0" "0" "$CODE"

tweak_accounts '.result.rateLimits.claude.weekly.usedPercent = 10 | .result.rateLimits.claude.session.usedPercent = 5
  | .result.rateLimits.codex.status = "error"'
OUT="$(run_provider "$STUB_DIR/accounts.json")"
assert_eq "provider with status not ok is skipped" "claude" "$(jq -r .provider <<<"$OUT")"
assert_eq "claude gets its model" "claude-sonnet-5-5" "$(jq -r .model <<<"$OUT")"

tweak_accounts '.result.rateLimits.claude.weekly.usedPercent = 76 | .result.rateLimits.codex.status = "error"'
OUT="$(run_provider "$STUB_DIR/accounts.json")"
assert_eq "claude over its reserved weekly cutoff is skipped" "antigravity" "$(jq -r .provider <<<"$OUT")"
assert_eq "antigravity gets its model" "gemini-3.8-flash" "$(jq -r .model <<<"$OUT")"

tweak_accounts '.result.rateLimits.claude.weekly.usedPercent = 10 | .result.rateLimits.codex.session.usedPercent = 90
  | .result.rateLimits.antigravity.weekly.usedPercent = 95'
OUT="$(run_provider "$STUB_DIR/accounts.json")"
assert_eq "others are skipped at 90 session or 95 weekly" "claude" "$(jq -r .provider <<<"$OUT")"

tweak_accounts '.result.rateLimits.claude.session.usedPercent = 80 | .result.rateLimits.codex.session.usedPercent = 90
  | .result.rateLimits.antigravity.weekly.usedPercent = 95'
OUT="$(run_provider "$STUB_DIR/accounts.json")"
CODE=$?
assert_eq "all over cutoff exits 1" "1" "$CODE"
assert_eq "all over cutoff reports the earliest reset" \
  '{"error":"all providers over cutoff","earliestResetsAt":1000012600000}' "$(jq -c . <<<"$OUT")"

tweak_accounts '.result.rateLimits.claude.weekly.usedPercent = 10 | .result.rateLimits.claude.session.usedPercent = 5
  | .result.rateLimits.codex = .result.rateLimits.claude | .result.rateLimits.antigravity.status = "error"'
OUT="$(run_provider "$STUB_DIR/accounts.json")"
assert_eq "a tie goes to claude" "claude" "$(jq -r .provider <<<"$OUT")"

if [ "$FAILS" -eq 0 ]; then echo "All board-worker tests passed"; fi
exit "$FAILS"
