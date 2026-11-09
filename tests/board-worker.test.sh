#!/usr/bin/env bash
# Tests for board-lib.sh, board-check-ready and board-set-status, with gh and curl replaced by the stubs in tests/stubs.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/board-worker/scripts/board-lib.sh"
CHECK="$REPO/skills/board-worker/scripts/board-check-ready"
PICK="$REPO/skills/board-worker/scripts/board-pick-next"
SETSTATUS="$REPO/skills/board-worker/scripts/board-set-status"
PICKPROV="$REPO/skills/board-worker/scripts/pick-provider"
PRECHECK="$REPO/skills/board-worker/scripts/board-precheck"
WATCH="$REPO/skills/board-worker/scripts/board-watch"
FIX="$REPO/tests/fixtures/board"
export BOARD_WORKER_CONFIG="$FIX/config"
GATE="$REPO/skills/board-worker/scripts/board-merge-gate"
DIFF="$REPO/skills/board-worker/scripts/board-check-diff"
APPROVE="$REPO/skills/board-worker/scripts/board-check-merge-approved"
SETUP="$REPO/skills/board-worker/scripts/board-setup"
export STUB_DIR
STUB_DIR="$(mktemp -d)"
export PATH="$REPO/tests/stubs:$PATH"
# A fake Jira config, so the Jira-backed scripts never read the user's real token.
export BOARD_JIRA_CONFIG="$STUB_DIR/jira"
printf "JIRA_SITE='https://x.atlassian.net'\nJIRA_EMAIL='a@b.c'\nJIRA_TOKEN='FAKE-TOKEN-abc'\n" >"$BOARD_JIRA_CONFIG"
export BOARD_PRECHECK_LOG="$STUB_DIR/precheck.log"
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

# Clears the curl stub logs and queues the given responses, one "<code>|<json>" per argument.
reset_curl() {
  rm -f "$STUB_DIR"/curl-argv "$STUB_DIR"/curl-stdin "$STUB_DIR"/curl-body "$STUB_DIR"/curl-fail
  : >"$STUB_DIR/curl-responses"
  local r
  for r in "$@"; do printf '%s\n' "$r" >>"$STUB_DIR/curl-responses"; done
}

# Queues the ticket that the curl stub returns for the ticket GET: $1 is the description, $2 the components JSON array.
set_ticket() {
  reset_curl "200|$(jq -cn --arg d "$1" --argjson c "$2" '{fields: {description: $d, components: $c}}')"
}

VALID_COMPONENTS='[{"name":"gusdecool/x"}]'
# Runs board-check-ready on a ticket with the given description (and components, default one valid one), storing
# its stdout in OUT and its exit code in CODE.
run_check() {
  set_ticket "$1" "${2:-$VALID_COMPONENTS}"
  OUT="$(bash "$CHECK" BM-1)"
  CODE=$?
}

# Runs board_owner_allowed in a subshell so the sourced library stays isolated.
# shellcheck disable=SC1090 # $LIB is a runtime path, not followable statically
owner_ok() { (source "$LIB"; board_owner_allowed "$1"); }

echo "Config"
CONF_DIR="$(mktemp -d)"
BOARD_WORKER_CONFIG="$CONF_DIR/none" bash "$CHECK" BM-1 2>"$CONF_DIR/err"
assert_eq "missing config exits 2" "2" "$?"
assert_eq "missing config prints one line naming board-setup" "1" "$(grep -c 'board-setup' "$CONF_DIR/err")"
printf 'BOARD_OWNER=acme\nBOARD_PROJECT=abc\nBOARD_ALLOWED_OWNERS=acme\n' >"$CONF_DIR/bad"
BOARD_WORKER_CONFIG="$CONF_DIR/bad" bash "$CHECK" BM-1 2>"$CONF_DIR/err"
assert_eq "non-numeric project exits 2" "2" "$?"
printf 'BOARD_OWNER=acme\nBOARD_PROJECT=4\nBOARD_ALLOWED_OWNERS=acme,beta\n' >"$CONF_DIR/acme"
# shellcheck disable=SC1090
assert_eq "config values drive the allow-list" "0 1" \
  "$(BOARD_WORKER_CONFIG="$CONF_DIR/acme" bash -c \
    'source "$1"; board_owner_allowed beta/x; a=$?; board_owner_allowed bungamata/x; echo "$a $?"' _ "$LIB")"
BOARD_WORKER_CONFIG="$CONF_DIR/new/config" bash "$SETUP" --owner acme --project 4 --allowed acme,beta >/dev/null
assert_eq "board-setup writes the config" "$(cat "$CONF_DIR/acme")" "$(cat "$CONF_DIR/new/config")"
BOARD_WORKER_CONFIG="$CONF_DIR/new2" bash "$SETUP" --owner acme --project x --allowed acme 2>/dev/null
assert_eq "board-setup rejects a bad project" "2" "$?"
assert_eq "board-setup writes nothing on bad input" "no" "$([ -e "$CONF_DIR/new2" ] && echo yes || echo no)"
BOARD_WORKER_CONFIG="$CONF_DIR/new3" bash "$SETUP" </dev/null 2>/dev/null
assert_eq "board-setup without a terminal or flags exits 2" "2" "$?"
rm -rf "$CONF_DIR"

echo "Merge approval"
U=https://github.com/gusdecool/x/issues/5
# Runs the approval check for a body and an author association; sets OUT and RC.
run_approve() {
  jq -n --arg body "$1" --arg assoc "$2" '{body: $body, author_association: $assoc}' >"$STUB_DIR/gh-output"
  OUT="$(bash "$APPROVE" "$U" 2>/dev/null)"; RC=$?
}
run_approve $'## Goal\nx\n\nAuto merge: true\n' OWNER
assert_eq "flag plus owner is approved" "0 true" "$RC $(jq -r .approved <<<"$OUT")"
run_approve $'auto MERGE: **true**\r\n' COLLABORATOR
assert_eq "case, bold and CRLF still count" "0" "$RC"
run_approve $'## Goal\nx\n' OWNER
assert_eq "no flag is not approved" "1" "$RC"
run_approve $'Auto merge: false\n' OWNER
assert_eq "Auto merge: false is not approved" "1" "$RC"
run_approve $'> Auto merge: true\n' OWNER
assert_eq "a quoted flag is ignored" "1" "$RC"
run_approve $'Auto merge: true\n' NONE
assert_eq "flag from a stranger is not approved" "1" "$RC"
run_approve $'Auto merge: true\n' CONTRIBUTOR
assert_eq "a contributor is not enough" "1" "$RC"
bash "$APPROVE" not-a-url 2>/dev/null
assert_eq "bad URL exits 2" "2" "$?"

echo "Flags"
CF="$(mktemp -d)"
# Prints the loaded visibility and infra flags for the config file given as $1.
flag_of() {
  BOARD_WORKER_CONFIG="$1" bash -c 'source "$1"; echo "[$BOARD_BLOCKED_VISIBILITIES] $BOARD_ALLOW_INFRA_CHANGE"' \
    _ "$LIB"
}
assert_eq "absent flags default to blocking public, no infra" "[public] false" "$(flag_of "$FIX/config")"
printf 'BOARD_OWNER=a\nBOARD_PROJECT=1\nBOARD_ALLOWED_OWNERS=a\nBOARD_BLOCKED_VISIBILITIES=\n' \
  >"$CF/set"
printf 'BOARD_ALLOW_INFRA_CHANGE=true\n' >>"$CF/set"
assert_eq "an empty blocked list and infra true are honoured" "[] true" "$(flag_of "$CF/set")"
printf 'BOARD_OWNER=a\nBOARD_PROJECT=1\nBOARD_ALLOWED_OWNERS=a\nBOARD_ALLOW_INFRA_CHANGE=yes\n' >"$CF/bad"
BOARD_WORKER_CONFIG="$CF/bad" bash "$CHECK" BM-1 2>/dev/null
assert_eq "an invalid flag exits 2" "2" "$?"
rm -rf "$CF"

echo "Visibility"
# shellcheck disable=SC1090 # LIB is a variable path
vis() { (source "$LIB"; board_visibility_blocked gusdecool/x); echo $?; }
echo '{"visibility":"PUBLIC"}' >"$STUB_DIR/gh-repo-view"
assert_eq "a public repo is blocked by default" "0" "$(vis)"
echo '{"visibility":"PRIVATE"}' >"$STUB_DIR/gh-repo-view"
assert_eq "a private repo is allowed" "1" "$(vis)"
touch "$STUB_DIR/gh-fail-repo-view"
assert_eq "an unreadable visibility is reported as 2" "2" "$(vis)"
rm -f "$STUB_DIR/gh-fail-repo-view"

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
# shellcheck disable=SC1090
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

for placeholder in 'none' 'None.' 'N/A' 'n/a.' '-' '—' '<!-- nothing yet -->'; do
  run_check $'## Goal\nX\n\n## Done when\nY\n\n## Open questions\n'"$placeholder"$'\n'
  assert_eq "open questions placeholder '$placeholder' counts as empty" "0" "$CODE"
done
run_check $'## Goal\nX\n\n## Done when\nY\n\n## Open questions\nnone\nWhich database?\n'
assert_eq "a placeholder next to a real question still fails" '["Open questions"]' "$(jq -c .missing <<<"$OUT")"

run_check $'## Goal:\nX\n\n## Acceptance criteria:\nY\n'
assert_eq "headings with a trailing colon pass" "0" "$CODE"
run_check $'**Goal**\nX\n\n**Acceptance criteria**\nY\n'
assert_eq "bold-only headings pass" "0" "$CODE"
run_check $'**Goal:**\nX\n\n**Done when**\nY\n\n**Open questions**\nWhich database?\n'
assert_eq "a bold Open questions heading with content fails" '["Open questions"]' "$(jq -c .missing <<<"$OUT")"

run_check $'## Goal\nX\n\n## Done when\nY\n\n## Open questions\n\n'
assert_eq "empty open questions pass" '{"ready":true,"missing":[]}' "$(jq -c . <<<"$OUT")"
assert_eq "empty open questions exit 0" "0" "$CODE"

run_check $'h2. Goal\nShip the board worker.\n\nh4. done when\n- works\n'
assert_eq "Jira wiki headings pass at any level" '{"ready":true,"missing":[]}' "$(jq -c . <<<"$OUT")"
assert_eq "Jira wiki headings exit 0" "0" "$CODE"
run_check $'h2. Goal\nX\n\nh2. Done when\nY\n\nh2. Open questions\nWhich database?\n'
assert_eq "Jira wiki open questions with an answer fail" '["Open questions"]' "$(jq -c .missing <<<"$OUT")"
assert_eq "Jira wiki open questions with an answer exit 1" "1" "$CODE"
run_check $'h2. Goal\nX\n\nh2. Done when\nY\n\nh2. Open questions\nnone\n\n## Notes\nWhich database?\n'
assert_eq "a later Markdown heading ends the Jira wiki open questions" '{"ready":true,"missing":[]}' \
  "$(jq -c . <<<"$OUT")"

run_check $'## Goal\nX\n\n## Done when\nY\n' '[]'
assert_eq "zero components fail with Component missing" '["Component"]' "$(jq -c .missing <<<"$OUT")"
assert_eq "zero components exit 1" "1" "$CODE"
run_check $'## Goal\nX\n\n## Done when\nY\n' '[{"name":"gusdecool/x"},{"name":"bungamata/api"}]'
assert_eq "two components fail with Component missing" '["Component"]' "$(jq -c .missing <<<"$OUT")"
run_check $'## Goal\nX\n\n## Done when\nY\n' '[{"name":"bungamata"}]'
assert_eq "a component without an owner fails" '["Component"]' "$(jq -c .missing <<<"$OUT")"
run_check $'## Goal\nX\n\n## Done when\nY\n' '[{"name":"bungamata/bm app"}]'
assert_eq "a component with a space fails" '["Component"]' "$(jq -c .missing <<<"$OUT")"

# Resets the stub state and loads the board fixtures; every issue is ready unless a test says otherwise.
reset_board() {
  rm -f "$STUB_DIR"/gh-* "$STUB_DIR/calls.log"
  cp "$FIX/items.json" "$STUB_DIR/gh-project-item-list"
  cp "$FIX/fields.json" "$STUB_DIR/gh-project-field-list"
  cp "$FIX/project.json" "$STUB_DIR/gh-project-view"
  echo '{"visibility":"PRIVATE"}' >"$STUB_DIR/gh-repo-view"
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
assert_eq "an unready card moves to HITL" "1" \
  "$(grep -c '^project item-edit .*--id I12 .*--single-select-option-id o-hitl' "$STUB_DIR/calls.log")"
assert_eq "parking moves, then labels, then comments" "project item-edit issue edit issue comment" \
  "$(grep -E '^(issue comment|issue edit|project item-edit) .*(I12|issues/12)' "$STUB_DIR/calls.log" \
    | awk '{printf "%s%s %s", (NR > 1 ? " " : ""), $1, $2}')"

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

reset_board
make_unready 12
touch "$STUB_DIR/gh-fail-project-item-edit"
run_pick
assert_eq "a failed move exits 2" "2" "$CODE"
assert_eq "a failed move posts no comment" "0" \
  "$(grep -c '^issue comment .*issues/12' "$STUB_DIR/calls.log" || true)"

echo "Set status"
TRANSITIONS='{"transitions":[{"id":"11","name":"Start","to":{"name":"In progress"}},'
TRANSITIONS+='{"id":"31","name":"Finish","to":{"name":"Done"}}]}'
reset_curl "200|$TRANSITIONS" '204|'
OUT="$(bash "$SETSTATUS" https://x.atlassian.net/browse/BM-1 Done 2>"$STUB_DIR/err")"; CODE=$?
assert_eq "set-status exits 0 when the transition posts" "0" "$CODE"
assert_eq "set-status prints nothing on success" "" "$OUT"
assert_eq "set-status posts the matching transition id" '{"transition":{"id":"31"}}' \
  "$(jq -c . "$STUB_DIR/curl-body")"
assert_eq "set-status sends a POST after the GET" "1" "$(grep -c -x 'POST' "$STUB_DIR/curl-argv")"
assert_eq "set-status reads and posts the transitions of the browse URL's key" "2" \
  "$(grep -c -x 'https://x.atlassian.net/rest/api/2/issue/BM-1/transitions' "$STUB_DIR/curl-argv")"
reset_curl "200|$TRANSITIONS" '204|'
bash "$SETSTATUS" BM-1 "In progress" 2>/dev/null
assert_eq "set-status finds a status with a space" "0" "$?"
assert_eq "set-status posts the In progress transition id" '{"transition":{"id":"11"}}' \
  "$(jq -c . "$STUB_DIR/curl-body")"
reset_curl
bash "$SETSTATUS" BM-1 Doing 2>"$STUB_DIR/err"
assert_eq "set-status rejects an unknown status with 2" "2" "$?"
assert_eq "set-status prints one line for an unknown status" "board-set-status: unknown status 'Doing'" \
  "$(cat "$STUB_DIR/err")"
assert_eq "set-status never calls curl on an unknown status" "no" \
  "$([ -e "$STUB_DIR/curl-argv" ] && echo yes || echo no)"
bash "$SETSTATUS" BM-1 done 2>/dev/null
assert_eq "set-status status match is case-sensitive" "2" "$?"
bash "$SETSTATUS" not-a-key Done 2>/dev/null
assert_eq "set-status rejects a bad ticket key with 2" "2" "$?"
assert_eq "set-status never calls curl for a bad key" "no" "$([ -e "$STUB_DIR/curl-argv" ] && echo yes || echo no)"
reset_curl "200|{\"transitions\":[{\"id\":\"11\",\"name\":\"Start\",\"to\":{\"name\":\"In progress\"}}]}"
bash "$SETSTATUS" BM-1 QA 2>"$STUB_DIR/err"
assert_eq "set-status with no matching transition exits 2" "2" "$?"
assert_eq "set-status with no matching transition prints one line" \
  "board-set-status: no transition to 'QA' from the current status" "$(cat "$STUB_DIR/err")"
assert_eq "set-status with no matching transition posts nothing" "0" \
  "$(grep -c -x 'POST' "$STUB_DIR/curl-argv" || true)"
assert_eq "set-status with no matching transition makes only the GET" "1" \
  "$(grep -c '^https://' "$STUB_DIR/curl-argv")"
reset_curl "200|$TRANSITIONS" '400|{"errorMessages":["Transition is not valid"]}'
bash "$SETSTATUS" BM-1 Done 2>"$STUB_DIR/err"
assert_eq "a Jira error on the POST exits 2" "2" "$?"
assert_eq "a Jira error on the POST prints the Jira line only" \
  "board-worker: Jira HTTP 400: Transition is not valid" "$(cat "$STUB_DIR/err")"
reset_curl '404|{"errorMessages":["Issue does not exist or you do not have permission to see it."]}'
bash "$SETSTATUS" BM-999 Done 2>"$STUB_DIR/err"
assert_eq "an unknown ticket exits 2 on the Jira 404" "2" "$?"
assert_eq "an unknown ticket prints the Jira line only" \
  "board-worker: Jira HTTP 404: Issue does not exist or you do not have permission to see it." "$(cat "$STUB_DIR/err")"

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
    NOW_MS=1000000000000 bash "$PICKPROV" "${@:2}" 2>/dev/null
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

tweak_accounts '.result.rateLimits.claude.session = null | .result.rateLimits.claude.weekly = null'
OUT="$(run_provider "$STUB_DIR/accounts.json")"
assert_eq "a provider with no windows is not eligible" "codex" "$(jq -r .provider <<<"$OUT")"

tweak_accounts '.result.rateLimits.claude.weekly.usedPercent = 74.9 | .result.rateLimits.claude.session.usedPercent = 70
  | .result.rateLimits.codex.session.usedPercent = 1'
OUT="$(run_provider "$STUB_DIR/accounts.json")"
assert_eq "without the flag codex can win" "codex" "$(jq -r .provider <<<"$OUT")"
OUT="$(run_provider "$STUB_DIR/accounts.json" --orchestrator)"
CODE=$?
assert_eq "--orchestrator picks claude even when codex scores higher" "claude 0" "$(jq -r .provider <<<"$OUT") $CODE"

tweak_accounts '.result.rateLimits.claude.weekly.usedPercent = 10 | .result.rateLimits.claude.session.usedPercent = 80
  | .result.rateLimits.codex.session.usedPercent = 1'
OUT="$(run_provider "$STUB_DIR/accounts.json" --orchestrator)"
CODE=$?
assert_eq "--orchestrator exits 1 when claude is over its reserved cutoff" "1" "$CODE"
assert_eq "--orchestrator names the error" "1" "$(jq -r 'has("error") | if . then 1 else 0 end' <<<"$OUT")"

# With ORCA_BIN unset and no orca on PATH (the Orca scheduler's case), pick-provider uses the fallback binary.
NOORCA="$STUB_DIR/noorca-bin"
mkdir -p "$NOORCA"
for tool in bash jq date dirname cat; do ln -sf "$(command -v "$tool")" "$NOORCA/$tool"; done
OUT="$(env -u ORCA_BIN PATH="$NOORCA" ORCA_FALLBACK_BIN="$STUB_DIR/orca" ACCOUNTS_FIXTURE="$FIX/accounts.json" \
  CODEX_MODELS_CACHE="$STUB_DIR/codex-models.json" NOW_MS=1000000000000 "$(command -v bash)" "$PICKPROV" 2>/dev/null)"
CODE=$?
assert_eq "no orca on PATH uses the fallback binary" "codex 0" "$(jq -r .provider <<<"$OUT") $CODE"

echo "Board watch"
W="$STUB_DIR/w"
mkdir -p "$W"
cat >"$STUB_DIR/watch-orca" <<'STUB'
#!/usr/bin/env bash
# Test stub for orca: worker-show and worker-read answer from $WATCH_DIR, account list from $ACCOUNTS_FIXTURE.
case "$1 $2" in
  "orchestration worker-show") cat "$WATCH_DIR/show-$4.json" ;;
  "orchestration worker-read") cat "$WATCH_DIR/read-$4.json" ;;
  "account list") cat "$ACCOUNTS_FIXTURE" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/watch-orca"

# Writes the worker-show and worker-read answers for one dispatch. Args: id, stage, waitingOnHuman (json), tail text.
watch_worker() {
  jq -n --arg id "$1" --arg stage "$2" --argjson wait "$3" \
    '{ok:true,result:{dispatchId:$id,state:"running",stage:$stage,waitingOnHuman:$wait}}' >"$W/show-$1.json"
  jq -n --arg t "$4" '{ok:true,result:{terminal:{tail:($t | split("\n"))}}}' >"$W/read-$1.json"
}
# Runs board-watch with the stub orca and no waiting, storing stdout in OUT and the exit code in CODE.
# POLLS (default 1) and SILENT (default 600) tune the run.
run_watch() {
  OUT="$(ORCA_BIN="$STUB_DIR/watch-orca" WATCH_DIR="$W" ACCOUNTS_FIXTURE="$STUB_DIR/accounts.json" \
    NOW_MS=1000000000000 WATCH_INTERVAL=0 WATCH_MAX_POLLS="${POLLS:-1}" SILENT_SECONDS="${SILENT:-600}" \
    bash "$WATCH" "$@" 2>/dev/null)"
  CODE=$?
}
tweak_accounts '.result.rateLimits.codex.session.usedPercent = 10'

watch_worker d1 settled false "all done"
run_watch d1:codex
assert_eq "a settled worker exits 0 with event settled" "0 settled" "$CODE $(jq -r .event <<<"$OUT")"

watch_worker d1 running false "working on it"
run_watch d1:codex
assert_eq "a healthy worker reports no event" "3 none" "$CODE $(jq -r .event <<<"$OUT")"

watch_worker d1 running true "Switch to gpt-6-luna?"
run_watch d1:codex
assert_eq "a worker waiting on a human is stuck" "1 stuck waiting_on_human" \
  "$CODE $(jq -r '"\(.event) \(.reason)"' <<<"$OUT")"

watch_worker d1 running false "ran git diff
You've hit your usage limit. Upgrade to Pro or try again at 3:13 PM."
run_watch d1:codex
assert_eq "a usage limit on screen is stuck" "1 stuck limit_text" "$CODE $(jq -r '"\(.event) \(.reason)"' <<<"$OUT")"
assert_eq "the limit line is in the detail" "1" "$(jq -r .detail <<<"$OUT" | grep -c 'try again at 3:13 PM')"

OLD="You've hit your usage limit.
$(seq 1 20 | sed 's/^/line /')"
watch_worker d1 running false "$OLD"
run_watch d1:codex
assert_eq "a limit phrase more than 15 lines up is old output" "3 none" "$CODE $(jq -r .event <<<"$OUT")"

tweak_accounts '.result.rateLimits.codex.session.usedPercent = 90'
watch_worker d1 running false "working"
run_watch d1:codex
assert_eq "codex at its 90 session cutoff is stuck" "1 quota_cutoff" "$CODE $(jq -r .reason <<<"$OUT")"
tweak_accounts '.result.rateLimits.codex.session.usedPercent = 89'
run_watch d1:codex
assert_eq "codex just under the cutoff is fine" "3" "$CODE"
tweak_accounts '.result.rateLimits.claude.weekly.usedPercent = 10 | .result.rateLimits.claude.session.usedPercent = 80'
run_watch d1:claude
assert_eq "claude at its reserved 80 session cutoff is stuck" "1 quota_cutoff" "$CODE $(jq -r .reason <<<"$OUT")"
tweak_accounts '.result.rateLimits.claude.weekly.usedPercent = 10 | .result.rateLimits.claude.session.usedPercent = 79'
run_watch d1:claude
assert_eq "claude just under its cutoff is fine" "3" "$CODE"

tweak_accounts '.result.rateLimits.codex.session.usedPercent = 10'
watch_worker d1 running false "same output"
POLLS=2 SILENT=0 run_watch d1:codex
assert_eq "unchanged output on two polls is silent" "1 silent" "$CODE $(jq -r .reason <<<"$OUT")"

rm "$W/show-d1.json"
run_watch d1:codex
assert_eq "an unreadable worker exits 2" "2" "$CODE"

echo "Pick next --dry-run"
reset_board
make_unready 12
OUT="$(TODAY=2026-11-06 bash "$PICK" --dry-run 2>/dev/null)"
CODE=$?
assert_eq "dry-run still picks the next ready card" "11" "$(jq -r .number <<<"$OUT")"
assert_eq "dry-run exits 0" "0" "$CODE"
assert_eq "dry-run never comments, labels or moves" "0" \
  "$(grep -c -E '^(issue comment|issue edit|project item-edit)' "$STUB_DIR/calls.log" || true)"

echo "Draft check"
DRAFT="$(mktemp)"
printf '## Goal\nShip it.\n\n## Acceptance criteria\n- works\n' >"$DRAFT"
OUT="$(bash "$CHECK" --file "$DRAFT")"; CODE=$?
assert_eq "a ready draft file passes" "0 true" "$CODE $(jq -r .ready <<<"$OUT")"
reset_curl
OUT="$(bash "$CHECK" --file "$DRAFT")"; CODE=$?
assert_eq "a draft has no component check and makes no Jira call" "0 no" \
  "$CODE $([ -e "$STUB_DIR/curl-argv" ] && echo yes || echo no)"
printf '## Acceptance criteria\n- works\n' >"$DRAFT"
OUT="$(bash "$CHECK" --file "$DRAFT")"; CODE=$?
assert_eq "a draft without a Goal fails" "1 [\"Goal\"]" "$CODE $(jq -c .missing <<<"$OUT")"
bash "$CHECK" --file "$DRAFT.none" 2>/dev/null
assert_eq "a missing draft file exits 2" "2" "$?"
rm -f "$DRAFT"

echo "Pick next with a blocked visibility"
reset_board
echo '{"visibility":"PUBLIC"}' >"$STUB_DIR/gh-repo-view"
run_pick
assert_eq "all public: nothing is picked" "1" "$CODE"
assert_eq "a public repo's card is commented" "1" \
  "$(grep -c '^issue comment https://github.com/gusdecool/x/issues/12 --body .*visibility is blocked' \
    "$STUB_DIR/calls.log")"
assert_eq "a public repo's card gets HITL" "1" \
  "$(grep -c '^issue edit https://github.com/gusdecool/x/issues/12 --add-label HITL' "$STUB_DIR/calls.log")"
assert_eq "a public repo's card moves to HITL" "1" \
  "$(grep -c '^project item-edit .*--id I12 .*--single-select-option-id o-hitl' "$STUB_DIR/calls.log")"
reset_board
echo '{"visibility":"PUBLIC"}' >"$STUB_DIR/gh-repo-view"
OUT="$(TODAY=2026-11-06 bash "$PICK" --dry-run 2>/dev/null)"
assert_eq "dry-run on a public repo changes nothing" "0" \
  "$(grep -c -E '^(issue comment|issue edit|project item-edit)' "$STUB_DIR/calls.log" || true)"
reset_board
touch "$STUB_DIR/gh-fail-repo-view"
run_pick
assert_eq "an unreadable visibility skips the card, exit 1" "1" "$CODE"
assert_eq "an unreadable visibility changes nothing" "0" \
  "$(grep -c -E '^(issue comment|issue edit|project item-edit)' "$STUB_DIR/calls.log" || true)"
rm -f "$STUB_DIR/gh-fail-repo-view"

echo "Diff check"
# Runs board-check-diff on a file list; sets OUT and RC.
run_diff() { printf '%s\n' "$@" >"$STUB_DIR/gh-pr-diff"; OUT="$(bash "$DIFF" 3 gusdecool/x 2>/dev/null)"; RC=$?; }
run_diff src/app.ts README.md
assert_eq "plain files pass" "0 false false" "$RC $(jq -r '[.cicd,.infra]|join(" ")' <<<"$OUT")"
run_diff src/app.ts .github/workflows/ci.yml
assert_eq "a workflow file is CI/CD" "1 true" "$RC $(jq -r .cicd <<<"$OUT")"
run_diff infra/main.tf
assert_eq "a .tf file is infra" "1 true" "$RC $(jq -r .infra <<<"$OUT")"
run_diff services/api/Dockerfile
assert_eq "a nested Dockerfile is infra" "1 true" "$RC $(jq -r .infra <<<"$OUT")"
run_diff .GitHub/Workflows/CI.yml
assert_eq "upper case does not hide CI/CD" "1 true" "$RC $(jq -r .cicd <<<"$OUT")"
run_diff docs/terraform-notes.md
assert_eq "a doc that only mentions terraform passes" "0" "$RC"
printf '%s\n' deployment/prod.yaml >"$STUB_DIR/gh-pr-diff"
OUT="$(BOARD_WORKER_CONFIG="$FIX/config-extra" bash "$DIFF" 3 gusdecool/x 2>/dev/null)"
assert_eq "extra infra globs from the config apply" "true" "$(jq -r .infra <<<"$OUT")"
touch "$STUB_DIR/gh-fail-pr-diff"
bash "$DIFF" 3 gusdecool/x 2>/dev/null
assert_eq "an unreadable file list exits 2" "2" "$?"
rm -f "$STUB_DIR/gh-fail-pr-diff"

echo "Merge gate"
G=https://github.com/gusdecool/x/issues/5
# Runs the merge gate for an approval, author association, visibility and file list; sets OUT and RC.
run_gate() {
  jq -n --arg body "$1" --arg assoc "$2" '{body: $body, author_association: $assoc}' >"$STUB_DIR/gh-output"
  echo "{\"visibility\":\"$3\"}" >"$STUB_DIR/gh-repo-view"
  printf '%s\n' "${@:4}" >"$STUB_DIR/gh-pr-diff"
  OUT="$(bash "$GATE" "$G" 3 2>/dev/null)"; RC=$?
}
run_gate $'Auto merge: true\n' OWNER PRIVATE src/a.ts
assert_eq "everything in order is allowed" "0 true" "$RC $(jq -r .allowed <<<"$OUT")"
run_gate $'Auto merge: true\n' OWNER PUBLIC src/a.ts
assert_eq "a public repo blocks the merge" "1" "$RC"
run_gate $'Goal only\n' OWNER PRIVATE src/a.ts
assert_eq "no Auto merge line blocks the merge" "1" "$RC"
run_gate $'Auto merge: true\n' OWNER PRIVATE .github/workflows/x.yml
assert_eq "a CI/CD change blocks the merge" "1" "$RC"
run_gate $'Auto merge: true\n' OWNER PRIVATE main.tf
assert_eq "an infra change blocks by default" "1" "$RC"
OUT="$(BOARD_WORKER_CONFIG="$FIX/config-infra" bash "$GATE" "$G" 3 2>/dev/null)"; RC=$?
assert_eq "an infra change passes when the flag is true" "0" "$RC"
printf '%s\n' .github/workflows/x.yml >"$STUB_DIR/gh-pr-diff"
OUT="$(BOARD_WORKER_CONFIG="$FIX/config-infra" bash "$GATE" "$G" 3 2>/dev/null)"; RC=$?
assert_eq "a CI/CD change blocks even with the infra flag" "1" "$RC"
run_gate $'Auto merge: true\n' OWNER PRIVATE src/a.ts
touch "$STUB_DIR/gh-fail-pr-diff"
OUT="$(bash "$GATE" "$G" 3 2>/dev/null)"; RC=$?
assert_eq "an unreadable file list blocks the merge" "1" "$RC"
rm -f "$STUB_DIR/gh-fail-pr-diff"

echo "Precheck"
NOW_ISO=2026-11-06T12:00:00Z
NOW_EPOCH="$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$NOW_ISO" +%s 2>/dev/null || date -u -d "$NOW_ISO" +%s)"
cat >"$STUB_DIR/pp-ok" <<'STUB'
#!/usr/bin/env bash
echo '{"provider":"claude","model":"m","tier":"workhorse"}'
STUB
cat >"$STUB_DIR/pp-fail" <<'STUB'
#!/usr/bin/env bash
echo '{"error":"all providers over cutoff"}'
exit 1
STUB
chmod +x "$STUB_DIR/pp-ok" "$STUB_DIR/pp-fail"

# Loads the board with In progress cards 20 and 21 on top of the Todo fixtures.
precheck_board() {
  reset_board
  jq '.items += [
    {"id":"I20","status":"In progress","content":{"type":"Issue","number":20,"repository":"gusdecool/x",
      "url":"https://github.com/gusdecool/x/issues/20"}},
    {"id":"I21","status":"In progress","content":{"type":"Issue","number":21,"repository":"gusdecool/x",
      "url":"https://github.com/gusdecool/x/issues/21"}}]' "$FIX/items.json" >"$STUB_DIR/gh-project-item-list"
  echo '{"updatedAt":"2026-11-06T11:30:00Z"}' >"$STUB_DIR/gh-issue-view-20"
  echo '{"updatedAt":"2026-11-06T11:00:00Z"}' >"$STUB_DIR/gh-issue-view-21"
  echo '[]' >"$STUB_DIR/gh-pr-list"
}
# Runs board-precheck with a fixed clock and a provider stub, storing the exit code in CODE and stderr in ERR.
run_precheck() {
  ERR="$(TODAY=2026-11-06 NOW_EPOCH="$NOW_EPOCH" PICK_PROVIDER="$STUB_DIR/${1:-pp-ok}" \
    bash "$PRECHECK" 2>&1 >/dev/null)"
  CODE=$?
}

precheck_board
run_precheck
assert_eq "two active In progress cards exit 1" "1" "$CODE"
assert_eq "the failed condition is named on one line" "1" "$(wc -l <<<"$ERR" | tr -d ' ')"
assert_eq "the line names the In progress limit" "1" "$(grep -c 'In progress' <<<"$ERR")"
assert_eq "active cards are not reaped" "0" "$(grep -c -E '^(issue comment|issue edit)' "$STUB_DIR/calls.log" || true)"

precheck_board
echo '{"updatedAt":"2026-11-06T09:00:00Z"}' >"$STUB_DIR/gh-issue-view-20"
echo '[{"updatedAt":"2026-11-06T08:00:00Z","url":"https://github.com/gusdecool/x/pull/99"}]' >"$STUB_DIR/gh-pr-list"
run_precheck
assert_eq "a 3-hour-stale card is reaped and frees a slot" "0" "$CODE"
assert_eq "the stale card gets a comment with the 2-hour rule, last activity and last PR" "1" \
  "$(grep -c -E 'issues/20 --body .*2026-11-06T09:00:00Z.*2 hours.*pull/99' "$STUB_DIR/calls.log")"
assert_eq "the stale card gets the HITL label" "1" \
  "$(grep -c '^issue edit https://github.com/gusdecool/x/issues/20 --add-label HITL' "$STUB_DIR/calls.log")"
assert_eq "the stale card moves to HITL" "1" \
  "$(grep -c '^project item-edit .*--id I20 .*--single-select-option-id o-hitl' "$STUB_DIR/calls.log")"
assert_eq "the active card is left alone" "0" \
  "$(grep -c -E '^issue (comment|edit) .*issues/21' "$STUB_DIR/calls.log" || true)"
assert_eq "the precheck never parks Todo cards" "0" \
  "$(grep -c -E '^issue (comment|edit) .*issues/1[0-4]' "$STUB_DIR/calls.log" || true)"

precheck_board
echo '{"updatedAt":"2026-11-06T09:00:00Z"}' >"$STUB_DIR/gh-issue-view-20"
echo '[{"updatedAt":"2026-11-06T11:45:00Z","url":"https://github.com/gusdecool/x/pull/98"}]' >"$STUB_DIR/gh-pr-list"
run_precheck
assert_eq "recent PR activity keeps a card with a stale issue" "1" "$CODE"
assert_eq "a card with recent PR activity is not reaped" "0" "$(grep -c '^issue comment' "$STUB_DIR/calls.log" || true)"

precheck_board
jq '.items |= map(select(.status != "Todo"))' "$STUB_DIR/gh-project-item-list" >"$STUB_DIR/items.tmp"
jq '.items |= map(select(.id != "I21"))' "$STUB_DIR/items.tmp" >"$STUB_DIR/gh-project-item-list"
run_precheck
assert_eq "no Todo card exits 1" "1" "$CODE"
assert_eq "no Todo card is named" "1" "$(grep -c 'Todo' <<<"$ERR")"

precheck_board
jq '.items |= map(select(.id != "I21"))' "$STUB_DIR/gh-project-item-list" >"$STUB_DIR/items.tmp"
cp "$STUB_DIR/items.tmp" "$STUB_DIR/gh-project-item-list"
run_precheck pp-fail
assert_eq "provider failure exits 1" "1" "$CODE"
assert_eq "provider failure is named" "1" "$(grep -c 'provider' <<<"$ERR")"
run_precheck pp-ok
assert_eq "one In progress card, a Todo card and a provider exit 0" "0" "$CODE"

precheck_board
echo '{"updatedAt":"2026-11-06T09:00:00Z"}' >"$STUB_DIR/gh-issue-view-20"
echo '{"updatedAt":"2026-11-06T08:00:00Z"}' >"$STUB_DIR/gh-issue-view-21"
run_precheck
assert_eq "both stale cards are reaped, so the precheck passes" "0" "$CODE"
assert_eq "the status move happens before the comment" "1" \
  "$([ "$(grep -n '^project item-edit .*--id I20' "$STUB_DIR/calls.log" | head -1 | cut -d: -f1)" -lt \
    "$(grep -n '^issue comment .*issues/20' "$STUB_DIR/calls.log" | head -1 | cut -d: -f1)" ] && echo 1 || echo 0)"
assert_eq "the PR lookup asks for 100 results, newest first" "1" \
  "$(grep -c -E '^pr list .*--limit 100 --search #20 sort:updated-desc' "$STUB_DIR/calls.log")"

precheck_board
echo '{"updatedAt":"2026-11-06T09:00:00Z"}' >"$STUB_DIR/gh-issue-view-20"
echo '{"updatedAt":"2026-11-06T09:00:00Z"}' >"$STUB_DIR/gh-issue-view-21"
touch "$STUB_DIR/gh-fail-issue-comment"
run_precheck
assert_eq "a failing reap exits 2" "2" "$CODE"
assert_eq "a failing reap still tries the next card" "1" \
  "$(grep -c '^project item-edit .*--id I21' "$STUB_DIR/calls.log")"
assert_eq "a failing reap names the failed cards" "2" \
  "$(grep -o 'issues/2[01]' <<<"$ERR" | sort -u | wc -l | tr -d ' ')"

precheck_board
echo '{"updatedAt":"2026-11-06T09:00:00Z"}' >"$STUB_DIR/gh-issue-view-20"
touch "$STUB_DIR/gh-fail-issue-view"
run_precheck
assert_eq "unreadable activity counts as active" "1" "$CODE"
assert_eq "unreadable activity never reaps" "0" "$(grep -c -E '^(issue (comment|edit)|project item-edit)' \
  "$STUB_DIR/calls.log" || true)"

precheck_board
echo '{}' >"$STUB_DIR/gh-issue-view-20"
echo '{}' >"$STUB_DIR/gh-issue-view-21"
run_precheck
assert_eq "a null updatedAt counts as active and is not reaped" "1" "$CODE"
assert_eq "a null updatedAt never reaps" "0" "$(grep -c -E '^(issue (comment|edit)|project item-edit)' \
  "$STUB_DIR/calls.log" || true)"

precheck_board
jq '.items |= map(select(.id != "I21")) | .items += [{"id":"I30","status":"In progress",
  "content":{"type":"Issue","number":30,"repository":"acme/y","url":"https://github.com/acme/y/issues/30"}}]' \
  "$STUB_DIR/gh-project-item-list" >"$STUB_DIR/items.tmp"
cp "$STUB_DIR/items.tmp" "$STUB_DIR/gh-project-item-list"
echo '{"updatedAt":"2026-11-06T01:00:00Z"}' >"$STUB_DIR/gh-issue-view-30"
run_precheck
assert_eq "a foreign-owner In progress card is counted" "1" "$CODE"
assert_eq "a foreign-owner In progress card is never reaped" "0" "$(grep -c 'acme/y' "$STUB_DIR/calls.log" || true)"

# Asserts the last precheck wrote exactly one stderr line. Arg: label.
assert_one_line() { assert_eq "$1 prints exactly one stderr line" "1" "$(printf '%s\n' "$ERR" | grep -c .)"; }
precheck_board
run_precheck
assert_one_line "limit reached"
precheck_board
jq '.items |= map(select(.status != "Todo" and .id != "I21"))' "$STUB_DIR/gh-project-item-list" >"$STUB_DIR/items.tmp"
cp "$STUB_DIR/items.tmp" "$STUB_DIR/gh-project-item-list"
run_precheck
assert_one_line "no Todo card"
precheck_board
jq '.items |= map(select(.id != "I21"))' "$STUB_DIR/gh-project-item-list" >"$STUB_DIR/items.tmp"
cp "$STUB_DIR/items.tmp" "$STUB_DIR/gh-project-item-list"
run_precheck pp-fail
assert_one_line "no provider"
cat >"$STUB_DIR/pp-broken" <<'STUB'
#!/usr/bin/env bash
echo "boom" >&2
exit 2
STUB
chmod +x "$STUB_DIR/pp-broken"
run_precheck pp-broken
assert_eq "an unreadable provider exits 2, not 1" "2" "$CODE"
assert_one_line "unreadable provider"
# Start the log empty so only this run is checked.
: >"$BOARD_PRECHECK_LOG"
run_precheck pp-broken
LOGGED="$(cat "$BOARD_PRECHECK_LOG")"
assert_eq "the log names the failing sub-script" "1" "$(grep -c 'pick-provider exited 2: boom' <<<"$LOGGED")"
assert_eq "the log records the final exit" "1" "$(grep -c 'exit 2: cannot read the provider' <<<"$LOGGED")"
touch "$STUB_DIR/gh-fail-project-item-list"
run_precheck
assert_eq "an unreadable board exits 2" "2" "$CODE"

# board-cleanup: only a clean worktree with a merged PR is removed.
CLEANUP="$REPO/skills/board-worker/scripts/board-cleanup"
make_wt() {
  mkdir -p "$STUB_DIR/$1" && git -C "$STUB_DIR/$1" init -q
  git -C "$STUB_DIR/$1" remote add origin https://github.com/acme/app.git
}
make_wt issue-1; make_wt issue-2; echo x >"$STUB_DIR/issue-2/dirty"
jq -n --arg a "$STUB_DIR/issue-1" --arg b "$STUB_DIR/issue-2" '{result: {worktrees: [
  {path: $a, displayName: "issue-1", branch: "refs/heads/feat/a", isMainWorktree: false},
  {path: $b, displayName: "issue-2", branch: "refs/heads/feat/b", isMainWorktree: false},
  {path: "/main", displayName: "main", branch: "refs/heads/main", isMainWorktree: true}]}}' >"$STUB_DIR/orca-worktrees"
echo 1 >"$STUB_DIR/gh-pr-list"
: >"$STUB_DIR/calls.log"
OUT="$(bash "$CLEANUP")"
# Counts calls.log lines starting with the given text.
calls() { grep -c "^$1" "$STUB_DIR/calls.log"; }
assert_eq "cleanup removes a clean merged worktree" "1" "$(calls "orca worktree rm --worktree path:$STUB_DIR/issue-1")"
assert_eq "cleanup closes its terminals" "1" "$(calls "orca terminal close --worktree path:$STUB_DIR/issue-1 --all")"
assert_eq "cleanup deletes the remote branch" "1" "$(calls "api -X DELETE repos/acme/app/git/refs/heads/feat/a")"
assert_eq "cleanup skips a dirty worktree" "0" "$(calls "orca worktree rm --worktree path:$STUB_DIR/issue-2")"
echo 0 >"$STUB_DIR/gh-pr-list"
rm -f "$STUB_DIR/gh-fail-project-item-list"
echo '{"items": [{"status": "In progress", "content": {"repository": "acme/app", "number": 1}}]}' \
  >"$STUB_DIR/gh-project-item-list"
: >"$STUB_DIR/calls.log"
bash "$CLEANUP" >/dev/null
assert_eq "cleanup skips an unmerged PR whose card is not Done" "0" "$(calls "orca worktree rm")"
echo '{"items": [{"status": "Done", "content": {"repository": "acme/app", "number": 1}}]}' \
  >"$STUB_DIR/gh-project-item-list"
: >"$STUB_DIR/calls.log"
bash "$CLEANUP" >/dev/null
assert_eq "cleanup removes a Done card's worktree" "1" "$(calls "orca worktree rm --worktree path:$STUB_DIR/issue-1")"
assert_eq "cleanup keeps the remote branch when the PR is not merged" "0" "$(calls "api -X DELETE")"
assert_eq "cleanup still skips a dirty Done worktree" "0" \
  "$(calls "orca worktree rm --worktree path:$STUB_DIR/issue-2")"

if [ "$FAILS" -eq 0 ]; then echo "All board-worker tests passed"; fi
exit "$FAILS"
