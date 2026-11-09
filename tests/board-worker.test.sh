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
  rm -f "$STUB_DIR"/curl-argv "$STUB_DIR"/curl-stdin "$STUB_DIR"/curl-body "$STUB_DIR"/curl-fail "$STUB_DIR"/curl-calls
  rm -rf "$STUB_DIR/curl-routes"
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
FIELDS_OK='[{"id":"description","name":"Description","custom":false},'
FIELDS_OK+='{"id":"customfield_10036","name":"Auto merge","custom":true}]'
# Queues the field list and the ticket's Auto merge value (a JSON value, default null), runs the approval check on
# BM-5; sets OUT and RC.
run_approve() {
  reset_curl "200|${2:-$FIELDS_OK}" "200|$(jq -cn --argjson v "${1:-null}" '{fields: {customfield_10036: $v}}')"
  OUT="$(bash "$APPROVE" BM-5 2>/dev/null)"; RC=$?
}
run_approve '[{"value":"Yes","id":"10036"}]'
assert_eq "a ticked field is approved" "0 true" "$RC $(jq -r .approved <<<"$OUT")"
assert_eq "the approved reason names the field" "the 'Auto merge' field is ticked" "$(jq -r .reason <<<"$OUT")"
run_approve
assert_eq "an absent value is not approved" "1 false" "$RC $(jq -r .approved <<<"$OUT")"
assert_eq "the not approved reason names the field" "the 'Auto merge' field is not ticked" "$(jq -r .reason <<<"$OUT")"
run_approve '[]'
assert_eq "an empty array is not approved" "1" "$RC"
run_approve '[{"value":"No"}]'
assert_eq "the option No is not approved" "1" "$RC"
run_approve '[{"value":"yes"}]'
assert_eq "the value must be exactly Yes" "1" "$RC"
run_approve '"Yes"'
assert_eq "a plain string value is not approved" "1" "$RC"
run_approve '[{"value":"Yes"}]' '[{"id":"description","name":"Description","custom":false}]'
assert_eq "a missing Auto merge field exits 2" "2" "$RC"
run_approve '[{"value":"Yes"}]' \
  '[{"id":"customfield_1","name":"Auto merge","custom":true},{"id":"customfield_2","name":"Auto merge","custom":true}]'
assert_eq "two fields named Auto merge exit 2" "2" "$RC"
run_approve '[{"value":"Yes"}]' '[{"id":"customfield_1","name":"Auto merge","custom":false}]'
assert_eq "a non-custom field named Auto merge is ignored" "2" "$RC"
run_approve '[{"value":"Yes"}]' '[{"id":"customfield_10036?x=1","name":"Auto merge","custom":true}]'
assert_eq "a malformed field id exits 2" "2" "$RC"
assert_eq "a malformed field id is never used in a ticket request" "0" \
  "$(grep -c '/rest/api/2/issue' "$STUB_DIR/curl-argv" || true)"
reset_curl "200|$FIELDS_OK" "200|$(jq -cn '{fields: {customfield_10036: null, description: "Auto merge: true"}}')"
OUT="$(bash "$APPROVE" BM-5 2>/dev/null)"; RC=$?
assert_eq "text saying Auto merge: true does not approve" "1" "$RC"
run_approve '[{"value":"Yes"}]'
assert_eq "the ticket request asks only for the custom field" "1" \
  "$(grep -c -x 'https://x.atlassian.net/rest/api/2/issue/BM-5?fields=customfield_10036' "$STUB_DIR/curl-argv" || true)"
reset_curl "500|{}"
bash "$APPROVE" BM-5 >/dev/null 2>&1
assert_eq "a Jira error on the field list exits 2" "2" "$?"
reset_curl "200|$FIELDS_OK" "500|{}"
bash "$APPROVE" BM-5 >/dev/null 2>&1
assert_eq "a Jira error on the ticket exits 2" "2" "$?"
bash "$APPROVE" not-a-key 2>/dev/null
assert_eq "a bad key exits 2" "2" "$?"
bash "$APPROVE" https://evil.example/browse/BM-5 2>/dev/null
assert_eq "a browse URL on another host exits 2" "2" "$?"

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

# Writes a Jira route for the curl stub. Args: route name, a glob matched against "METHOD URL", "<code>|<json>".
# Routes are persistent and the first by name wins, so a "00-" name overrides a default "50-" route.
route() {
  mkdir -p "$STUB_DIR/curl-routes"
  printf '%s\n%s\n' "$2" "$3" >"$STUB_DIR/curl-routes/$1"
}

READY_DESC=$'## Goal\nX\n\n## Done when\nY\n'
# Replaces the Todo tickets of the fake Jira board. Each argument is "KEY|Priority|component", the last two may be
# empty. Every ticket also gets a ready-check route (a ready description) with its component.
set_todos() {
  local spec key prio comp issues="[]"
  for spec in "$@"; do
    IFS='|' read -r key prio comp <<<"$spec"
    issues="$(jq -c --arg k "$key" --arg p "$prio" --arg c "$comp" \
      '. + [{key: $k, fields: {priority: (if $p == "" then null else {name: $p} end),
        components: (if $c == "" then [] else [{name: $c}] end)}}]' <<<"$issues")"
    route "50-ready-$key" "GET */rest/api/2/issue/$key\\?fields=description,components" \
      "200|$(jq -cn --arg d "$READY_DESC" --arg c "$comp" \
        '{fields: {description: $d, components: (if $c == "" then [] else [{name: $c}] end)}}')"
  done
  route "50-search-todo" 'GET *status%20%3D%20%22Todo%22*' \
    "200|$(jq -cn --argjson i "$issues" '{issues: $i, isLast: true}')"
}

# Resets the stub state and loads the fake Jira board; every ticket is ready unless a test says otherwise.
reset_board() {
  rm -f "$STUB_DIR"/gh-* "$STUB_DIR/calls.log" "$STUB_DIR"/curl-argv "$STUB_DIR"/curl-calls "$STUB_DIR"/curl-body
  rm -rf "$STUB_DIR/curl-routes"
  : >"$STUB_DIR/curl-responses"
  echo '{"visibility":"PRIVATE"}' >"$STUB_DIR/gh-repo-view"
  route 50-transitions-get 'GET */transitions' \
    '200|{"transitions":[{"id":"41","name":"Park","to":{"name":"HITL"}}]}'
  route 50-transitions-post 'POST */transitions' '204|'
  route 50-label 'PUT */rest/api/2/issue/*' '204|'
  route 50-comment 'POST */comment' '201|{}'
  set_todos "BM-10|Low|gusdecool/x" "BM-11|High|gusdecool/x" "BM-12|Highest|gusdecool/x" \
    "BM-13|Medium|acme/y" "BM-14||gusdecool/x"
}

# Makes a ticket unready by giving it an empty description (and a valid component).
make_unready() {
  route "00-ready-$1" "GET */rest/api/2/issue/$1\\?fields=description,components" \
    '200|{"fields":{"description":"","components":[{"name":"gusdecool/x"}]}}'
}

# Prints the mutating Jira steps taken on a ticket, in order, as "move label comment".
mutations() {
  awk -v k="$1" '$1 != "GET" && $2 ~ ("/issue/" k "(/|$)") {
    w = ($2 ~ /transitions$/) ? "move" : ($2 ~ /comment$/) ? "comment" : "label"
    printf "%s%s", (n++ ? " " : ""), w } END { print "" }' "$STUB_DIR/curl-calls"
}
# Counts every mutating Jira call (POST or PUT) of the last run.
mutation_count() { grep -c -E '^(POST|PUT) ' "$STUB_DIR/curl-calls" || true; }
# Counts the Jira calls of the last run that mention the given text.
jira_mentions() { grep -c -F -- "$1" "$STUB_DIR/curl-calls" || true; }
# Prints the body of the last POST to a ticket's comment endpoint.
comment_of() { grep "^POST .*/issue/$1/comment " "$STUB_DIR/curl-calls" | tail -n 1 | cut -d' ' -f3-; }

# Runs board-pick-next, storing stdout in OUT, stderr in ERR and the exit code in CODE.
run_pick() {
  rm -f "$STUB_DIR/curl-calls"
  OUT="$(bash "$PICK" "$@" 2>"$STUB_DIR/pick-err")"
  CODE=$?
  ERR="$(cat "$STUB_DIR/pick-err")"
}

echo "Pick next"
reset_board
run_pick
assert_eq "Highest priority wins" "BM-12" "$(jq -r .key <<<"$OUT")"
assert_eq "pick prints repo, key and browse url" \
  '{"repo":"gusdecool/x","key":"BM-12","url":"https://x.atlassian.net/browse/BM-12"}' "$(jq -c . <<<"$OUT")"
assert_eq "pick exits 0" "0" "$CODE"
assert_eq "pick lists the Todo tickets of the project" "1" \
  "$(grep -c 'search/jql?jql=project%20%3D%20BM%20AND%20status%20%3D%20%22Todo%22&fields=' "$STUB_DIR/curl-calls")"
assert_eq "a foreign-owner ticket is never checked" "00" \
  "$(grep -c 'acme/y' "$STUB_DIR/calls.log" || true)$(jira_mentions BM-13)"
assert_eq "a ready pick changes nothing" "0" "$(mutation_count)"

# Picks until the list is empty and prints the keys in pick order; ready tickets are removed one by one.
pick_order() {
  local specs=("$@") remaining order="" key spec
  while [ "${#specs[@]}" -gt 0 ]; do
    set_todos "${specs[@]}"
    run_pick
    [ "$CODE" -eq 0 ] || break
    key="$(jq -r .key <<<"$OUT")"
    order="$order $key"
    remaining=()
    for spec in "${specs[@]}"; do
      if [ "${spec%%|*}" != "$key" ]; then remaining+=("$spec"); fi
    done
    specs=("${remaining[@]+"${remaining[@]}"}")
  done
  printf '%s' "${order# }"
}
reset_board
assert_eq "priority order is Highest, High, Medium, Low, Lowest, none" "BM-6 BM-5 BM-4 BM-3 BM-2 BM-1" \
  "$(pick_order "BM-1||gusdecool/x" "BM-2|Lowest|gusdecool/x" "BM-3|Low|gusdecool/x" "BM-4|Medium|gusdecool/x" \
    "BM-5|High|gusdecool/x" "BM-6|Highest|gusdecool/x")"
reset_board
set_todos "BM-14||gusdecool/x"
run_pick
assert_eq "a ticket with no priority is still picked" "BM-14" "$(jq -r .key <<<"$OUT")"
set_todos "BM-14||gusdecool/x" "BM-30|Low|gusdecool/x"
run_pick
assert_eq "a ticket with a priority beats one with none" "BM-30" "$(jq -r .key <<<"$OUT")"
set_todos "BM-10|High|gusdecool/x" "BM-9|High|gusdecool/x"
run_pick
assert_eq "equal priority: BM-9 comes before BM-10 (numeric key order)" "BM-9" "$(jq -r .key <<<"$OUT")"
set_todos "BM-100|Medium|gusdecool/x" "BM-20|Medium|gusdecool/x"
run_pick
assert_eq "equal priority: the lower key number wins, not the text order" "BM-20" "$(jq -r .key <<<"$OUT")"

reset_board
make_unready BM-12
run_pick
assert_eq "an unready ticket is skipped for the next one" "BM-11" "$(jq -r .key <<<"$OUT")"
assert_eq "an unready ticket gets a comment naming the gap" "1" \
  "$(comment_of BM-12 | grep -c -F 'Missing: Goal, Acceptance criteria. Moved to HITL.')"
assert_eq "an unready ticket gets the HITL label" "1" \
  "$(grep -c '^PUT https://x.atlassian.net/rest/api/2/issue/BM-12 {"update":{"labels":\[{"add":"HITL"}\]}}$' \
    "$STUB_DIR/curl-calls")"
assert_eq "an unready ticket moves to HITL" "1" \
  "$(grep -c '^POST .*/issue/BM-12/transitions {"transition":{"id":"41"}}$' "$STUB_DIR/curl-calls")"
assert_eq "parking moves, then labels, then comments" "move label comment" "$(mutations BM-12)"

reset_board
set_todos "BM-13|Medium|acme/y"
run_pick
assert_eq "only a foreign-owner ticket: no qualifying ticket exits 1" "1" "$CODE"
assert_eq "a foreign-owner ticket is ignored untouched" "00" "$(mutation_count)$(jira_mentions BM-13)"

reset_board
set_todos "BM-20|Highest|" "BM-21|Low|gusdecool/x"
run_pick
assert_eq "an unknown-repo ticket is parked and the next one is picked" "BM-21" "$(jq -r .key <<<"$OUT")"
assert_eq "an unknown-repo ticket is parked with Component missing" "1" \
  "$(comment_of BM-20 | grep -c 'Missing: Component. Moved to HITL.')"
assert_eq "an unknown-repo ticket parks in order" "move label comment" "$(mutations BM-20)"
assert_eq "an unknown-repo ticket is not looked up for visibility (only BM-21 is)" "1" \
  "$(grep -c 'repo view' "$STUB_DIR/calls.log" || true)"
set_todos "BM-22|High|bungamata"
run_pick
assert_eq "a component without an owner counts as unknown and is parked" "move label comment" "$(mutations BM-22)"

reset_board
make_unready BM-12
route 00-comment-fail 'POST */comment' '500|{}'
run_pick
assert_eq "a failing comment while parking exits 2" "2" "$CODE"
assert_eq "a failing park prints cannot park" "1" "$(grep -c 'cannot park BM-12' <<<"$ERR")"

reset_board
make_unready BM-12
route 00-move-fail 'POST */transitions' '400|{"errorMessages":["Transition is not valid"]}'
run_pick
assert_eq "a failed move exits 2" "2" "$CODE"
assert_eq "a failed move posts no comment and no label" "move" "$(mutations BM-12)"
assert_eq "a failed move never repeats a comment" "0" "$(jira_mentions BM-12/comment)"

reset_board
make_unready BM-12
route 00-label-fail 'PUT */rest/api/2/issue/*' '403|{"errorMessages":["no"]}'
run_pick
assert_eq "a failed label exits 2" "2" "$CODE"
assert_eq "a failed label posts no comment" "move label" "$(mutations BM-12)"

reset_board
route 00-search-fail 'GET *search/jql*' '401|{}'
run_pick
assert_eq "a Jira error while listing exits 2" "2" "$CODE"
reset_board
route 00-ready-BM-12 'GET */rest/api/2/issue/BM-12\?fields=description,components' '500|{}'
run_pick
assert_eq "an unreadable ticket is skipped" "BM-11" "$(jq -r .key <<<"$OUT")"
assert_eq "an unreadable ticket is named on stderr" "1" "$(grep -c 'skipping BM-12, cannot read it' <<<"$ERR")"
assert_eq "an unreadable ticket is left alone" "" "$(mutations BM-12)"

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
make_unready BM-12
run_pick --dry-run
assert_eq "dry-run still picks the next ready ticket" "BM-11" "$(jq -r .key <<<"$OUT")"
assert_eq "dry-run exits 0" "0" "$CODE"
assert_eq "dry-run never comments, labels or moves" "0" "$(mutation_count)"

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
assert_eq "a public repo's ticket is commented" "1" \
  "$(comment_of BM-12 | grep -c -F "Ignored by the board worker: this repo's visibility is blocked")"
assert_eq "a public repo's ticket gets HITL and moves, in order" "move label comment" "$(mutations BM-12)"
assert_eq "a public repo's ticket gets the HITL label" "1" \
  "$(grep -c '^PUT .*/issue/BM-12 {"update":{"labels":\[{"add":"HITL"}\]}}$' "$STUB_DIR/curl-calls")"
reset_board
echo '{"visibility":"PUBLIC"}' >"$STUB_DIR/gh-repo-view"
run_pick --dry-run
assert_eq "dry-run on a public repo changes nothing" "0" "$(mutation_count)"
reset_board
touch "$STUB_DIR/gh-fail-repo-view"
run_pick
assert_eq "an unreadable visibility skips the ticket, exit 1" "1" "$CODE"
assert_eq "an unreadable visibility changes nothing" "0" "$(mutation_count)"
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
# Runs the merge gate on BM-5 / PR 3. Args: Auto merge value (JSON), visibility, then the PR file list. The ticket
# has the component in COMPONENTS (default gusdecool/x). Sets OUT and RC.
COMPONENTS='[{"name":"gusdecool/x"}]'
# Queues the three Jira answers of a gate run: components, field list, Auto merge value (arg 1, JSON).
queue_gate() {
  reset_curl "200|$(jq -cn --argjson c "$COMPONENTS" '{fields: {components: $c}}')" "200|$FIELDS_OK" \
    "200|$(jq -cn --argjson v "$1" '{fields: {customfield_10036: $v}}')"
}
PRVIEW='{"headRefName":"BM-5-fix-it","state":"OPEN"}'
run_gate() {
  queue_gate "$1"
  printf '%s\n' "$PRVIEW" >"$STUB_DIR/gh-pr-view"
  echo "{\"visibility\":\"$2\"}" >"$STUB_DIR/gh-repo-view"
  printf '%s\n' "${@:3}" >"$STUB_DIR/gh-pr-diff"
  : >"$STUB_DIR/calls.log"
  OUT="$(bash "$GATE" BM-5 3 2>/dev/null)"; RC=$?
}
# Prints the first blocked reason of the last gate run.
first_block() { jq -r '.blocked[0]' <<<"$OUT"; }
TICKED='[{"value":"Yes"}]'
run_gate "$TICKED" PRIVATE src/a.ts
assert_eq "everything in order is allowed" "0 true" "$RC $(jq -r .allowed <<<"$OUT")"
assert_eq "the allowed output has no reasons" "[]" "$(jq -c .blocked <<<"$OUT")"
COMPONENTS='[{"name":"other/x"}]'
run_gate "$TICKED" PRIVATE src/a.ts
assert_eq "an owner outside the allow-list blocks the merge" "1 repo owner is not in the allowed owners" \
  "$RC $(first_block)"
COMPONENTS='[{"name":"gusdecool/x"}]'
run_gate "$TICKED" PUBLIC src/a.ts
assert_eq "a public repo blocks the merge" "1 repo visibility is blocked by the board-worker config" \
  "$RC $(first_block)"
touch "$STUB_DIR/gh-fail-repo-view"
queue_gate "$TICKED"
OUT="$(bash "$GATE" BM-5 3 2>/dev/null)"; RC=$?
rm -f "$STUB_DIR/gh-fail-repo-view"
assert_eq "an unreadable visibility blocks the merge" "1 repo visibility could not be read" "$RC $(first_block)"
run_gate null PRIVATE src/a.ts
assert_eq "an unticked Auto merge blocks the merge" "1 the 'Auto merge' field is not ticked" "$RC $(first_block)"
reset_curl "200|$(jq -cn --argjson c "$COMPONENTS" '{fields: {components: $c}}')" "500|{}"
printf '%s\n' src/a.ts >"$STUB_DIR/gh-pr-diff"
echo '{"visibility":"PRIVATE"}' >"$STUB_DIR/gh-repo-view"
OUT="$(bash "$GATE" BM-5 3 2>/dev/null)"; RC=$?
assert_eq "an unreadable approval blocks the merge" "1 approval could not be read" "$RC $(first_block)"
run_gate "$TICKED" PRIVATE .github/workflows/x.yml
assert_eq "a CI/CD change blocks the merge" "1" "$RC"
assert_eq "the CI/CD reason lists the path" "true" \
  "$(jq -r '.blocked[0] | contains("CI/CD") and contains(".github/workflows/x.yml")' <<<"$OUT")"
run_gate "$TICKED" PRIVATE main.tf
assert_eq "an infra change blocks by default" "1" "$RC"
run_gate "$TICKED" PRIVATE main.tf
queue_gate "$TICKED"
OUT="$(BOARD_WORKER_CONFIG="$FIX/config-infra" bash "$GATE" BM-5 3 2>/dev/null)"; RC=$?
assert_eq "an infra change passes when the flag is true" "0" "$RC"
run_gate "$TICKED" PRIVATE .github/workflows/x.yml
queue_gate "$TICKED"
OUT="$(BOARD_WORKER_CONFIG="$FIX/config-infra" bash "$GATE" BM-5 3 2>/dev/null)"; RC=$?
assert_eq "a CI/CD change blocks even with the infra flag" "1" "$RC"
run_gate "$TICKED" PRIVATE src/a.ts
touch "$STUB_DIR/gh-fail-pr-diff"
queue_gate "$TICKED"
OUT="$(bash "$GATE" BM-5 3 2>/dev/null)"; RC=$?
rm -f "$STUB_DIR/gh-fail-pr-diff"
assert_eq "an unreadable file list blocks the merge" "1 the PR file list could not be read" "$RC $(first_block)"
BAD_COMPONENTS=('[]' '[{"name":"gusdecool/x"},{"name":"gusdecool/y"}]' '[{"name":"not a repo"}]' '[{"name":"a/b/c"}]')
for COMPONENTS in "${BAD_COMPONENTS[@]}"; do
  run_gate "$TICKED" PRIVATE src/a.ts
  assert_eq "components $COMPONENTS block with the component reason" \
    "1 the ticket must have exactly one component named owner/repo" "$RC $(first_block)"
  assert_eq "components $COMPONENTS never read the PR diff" "0" "$(grep -c 'pr diff' "$STUB_DIR/calls.log" || true)"
  assert_eq "components $COMPONENTS still run the approval" "3" \
    "$(grep -c "/rest/api/2/" "$STUB_DIR/curl-argv" || true)"
done
COMPONENTS='[]'
run_gate null PRIVATE src/a.ts
assert_eq "no component and no approval give two reasons" "2" "$(jq '.blocked | length' <<<"$OUT")"
COMPONENTS='[{"name":"gusdecool/x"}]'
reset_curl "500|{}"
bash "$GATE" BM-5 3 >/dev/null 2>&1
assert_eq "a Jira error on the components exits 2" "2" "$?"
run_gate "$TICKED" PRIVATE src/a.ts
OUT="$(bash "$GATE" BM-5 abc 2>/dev/null)"; RC=$?
assert_eq "a non-numeric PR number exits 2" "2" "$RC"
bash "$GATE" not-a-key 3 >/dev/null 2>&1
assert_eq "a bad key exits 2" "2" "$?"
run_gate null PUBLIC .github/workflows/x.yml
assert_eq "several blocks are all listed" "3" "$(jq '.blocked | length' <<<"$OUT")"
assert_eq "the blocked output is valid JSON" "true" \
  "$(jq -e '.allowed == false and (.blocked | type == "array")' <<<"$OUT")"

# Runs the gate for PR view JSON $1 on a valid, approved, private-repo ticket; sets OUT and RC.
run_gate_pr() { PRVIEW="$1"; run_gate "$TICKED" PRIVATE src/a.ts; }
run_gate_pr '{"headRefName":"BM-5-x","state":"OPEN"}'
assert_eq "an open PR on the ticket branch passes" "0" "$RC"
assert_eq "the repo is printed on success" "gusdecool/x" "$(jq -r .repo <<<"$OUT")"
assert_eq "the output keys are in order" '["allowed","repo","blocked"]' "$(jq -c 'keys_unsorted' <<<"$OUT")"
assert_eq "the PR is looked up in the ticket's repo" "1" \
  "$(grep -c -x 'pr view 3 --repo gusdecool/x --json headRefName,state' "$STUB_DIR/calls.log" || true)"
BRANCH_MSG="the PR branch does not belong to this ticket (it must start with BM-5-)"
run_gate_pr '{"headRefName":"BM-55-x","state":"OPEN"}'
assert_eq "a longer key prefix is another ticket" "1 $BRANCH_MSG" "$RC $(first_block)"
run_gate_pr '{"headRefName":"bm-5-x","state":"OPEN"}'
assert_eq "a lowercase key blocks" "1 $BRANCH_MSG" "$RC $(first_block)"
run_gate_pr '{"headRefName":"BM-5","state":"OPEN"}'
assert_eq "the bare key as branch blocks" "1 $BRANCH_MSG" "$RC $(first_block)"
run_gate_pr '{"headRefName":"feature/BM-5-x","state":"OPEN"}'
assert_eq "a key that is not at the start blocks" "1" "$RC"
run_gate_pr '{"headRefName":"BM-5-x","state":"MERGED"}'
assert_eq "a merged PR blocks" "1 the PR is not open" "$RC $(first_block)"
run_gate_pr '{"headRefName":"BM-5-x","state":"CLOSED"}'
assert_eq "a closed PR blocks" "1 the PR is not open" "$RC $(first_block)"
assert_eq "a PR that fails check 5 is not diffed" "0" "$(grep -c 'pr diff' "$STUB_DIR/calls.log" || true)"
run_gate_pr 'not json'
assert_eq "unparseable PR data blocks" "1 the PR could not be read in gusdecool/x" "$RC $(first_block)"
run_gate_pr '{"state":"OPEN"}'
assert_eq "PR data without a branch blocks" "1" "$RC"
PRVIEW='{"headRefName":"BM-5-x","state":"OPEN"}'
touch "$STUB_DIR/gh-fail-pr-view"
run_gate "$TICKED" PRIVATE src/a.ts
rm -f "$STUB_DIR/gh-fail-pr-view"
assert_eq "a failing gh pr view blocks" "1 the PR could not be read in gusdecool/x" "$RC $(first_block)"
assert_eq "a failing gh pr view never reaches the diff" "0" "$(grep -c 'pr diff' "$STUB_DIR/calls.log" || true)"
run_gate_pr '{"headRefName":"BM-5-x","state":"MERGED"}'
assert_eq "a blocked PR keeps the other results (repo still printed)" "gusdecool/x" "$(jq -r .repo <<<"$OUT")"
COMPONENTS='[]'
run_gate_pr '{"headRefName":"BM-5-x","state":"OPEN"}'
assert_eq "no valid component prints an empty repo" '""' "$(jq -c .repo <<<"$OUT")"
assert_eq "no valid component never calls gh pr view" "0" "$(grep -c 'pr view' "$STUB_DIR/calls.log" || true)"
COMPONENTS='[{"name":"gusdecool/x"}]'
PRVIEW='{"headRefName":"BM-5-fix-it","state":"OPEN"}'

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

# Replaces the In progress tickets of the fake Jira board. Each argument is "KEY|updated|component"; updated and
# component may be empty (no updated field, no component).
set_progress() {
  local spec key upd comp issues="[]"
  for spec in "$@"; do
    IFS='|' read -r key upd comp <<<"$spec"
    issues="$(jq -c --arg k "$key" --arg u "$upd" --arg c "$comp" \
      '. + [{key: $k, fields: ({components: (if $c == "" then [] else [{name: $c}] end)}
        + (if $u == "" then {} else {updated: $u} end))}]' <<<"$issues")"
  done
  route "50-search-progress" 'GET *%22In%20progress%22*' \
    "200|$(jq -cn --argjson i "$issues" '{issues: $i, isLast: true}')"
}

# Loads the board with In progress tickets BM-20 (30 minutes quiet, +0800 clock) and BM-21 (1 hour quiet) on top of
# the Todo fixtures.
precheck_board() {
  reset_board
  set_progress "BM-20|2026-11-06T19:30:00.123+0800|gusdecool/x" "BM-21|2026-11-06T11:00:00.000+0000|gusdecool/x"
  echo '[]' >"$STUB_DIR/gh-pr-list"
}
# Runs board-precheck with a fixed clock and a provider stub, storing the exit code in CODE and stderr in ERR.
run_precheck() {
  rm -f "$STUB_DIR/curl-calls"
  ERR="$(NOW_EPOCH="$NOW_EPOCH" PICK_PROVIDER="$STUB_DIR/${1:-pp-ok}" bash "$PRECHECK" 2>&1 >/dev/null)"
  CODE=$?
}

precheck_board
run_precheck
assert_eq "two active In progress tickets exit 1" "1" "$CODE"
assert_eq "the failed condition is named on one line" "1" "$(wc -l <<<"$ERR" | tr -d ' ')"
assert_eq "the line names the In progress limit" "1" "$(grep -c 'In progress' <<<"$ERR")"
assert_eq "active tickets are not reaped" "0" "$(mutation_count)"
assert_eq "the In progress search uses the project and the status" "1" \
  "$(grep -c 'jql=project%20%3D%20BM%20AND%20status%20%3D%20%22In%20progress%22&fields=summary%2Ccomponents%2Cupdated' \
    "$STUB_DIR/curl-calls")"

precheck_board
set_progress "BM-20|2026-11-06T17:00:00.123+0800|gusdecool/x" "BM-21|2026-11-06T11:00:00.000+0000|gusdecool/x"
echo '[{"updatedAt":"2026-11-06T08:00:00Z","url":"https://github.com/gusdecool/x/pull/99"}]' >"$STUB_DIR/gh-pr-list"
run_precheck
assert_eq "a 3-hour-stale ticket is reaped and frees a slot" "0" "$CODE"
assert_eq "the stale ticket gets a comment with the 2-hour rule, last activity and last PR" "1" \
  "$(comment_of BM-20 \
    | grep -c -E 'since 2026-11-06T09:00:00Z.*2 hours.*seen: https://github.com/gusdecool/x/pull/99\.')"
assert_eq "the stale ticket gets the HITL label" "1" \
  "$(grep -c '^PUT .*/issue/BM-20 {"update":{"labels":\[{"add":"HITL"}\]}}$' "$STUB_DIR/curl-calls")"
assert_eq "the stale ticket moves, labels and comments in that order" "move label comment" "$(mutations BM-20)"
assert_eq "the fresh ticket is left alone" "" "$(mutations BM-21)"
assert_eq "the precheck never parks Todo tickets" "" "$(mutations BM-1[0-4])"
assert_eq "the PR search is by ticket key, newest first, 100 results" "1" \
  "$(grep -c -E '^pr list --repo gusdecool/x --state all --limit 100 --search BM-20 sort:updated-desc ' \
    "$STUB_DIR/calls.log")"

precheck_board
set_progress "BM-20|2026-11-06T17:00:00.000+0800|gusdecool/x" "BM-21|2026-11-06T11:00:00.000+0000|gusdecool/x"
echo '[{"updatedAt":"2026-11-06T11:45:00Z","url":"https://github.com/gusdecool/x/pull/98"}]' >"$STUB_DIR/gh-pr-list"
run_precheck
assert_eq "recent PR activity keeps a ticket with a stale Jira update" "1" "$CODE"
assert_eq "a ticket with recent PR activity is not reaped" "0" "$(mutation_count)"

precheck_board
set_progress "BM-20|2026-11-06T19:30:00.123+0800|gusdecool/x" "BM-21|2026-11-06T04:00:00.000-0500|gusdecool/x"
run_precheck
assert_eq "a -0500 time is converted: 04:00-0500 is 09:00Z, stale" "0" "$CODE"
assert_eq "the -0500 ticket is reaped with its UTC time" "1" \
  "$(comment_of BM-21 | grep -c -F 'No activity since 2026-11-06T09:00:00Z')"
assert_eq "a +0800 time is converted: 19:30+0800 is 11:30Z, fresh" "" "$(mutations BM-20)"
precheck_board
set_progress "BM-20|2026-11-06T17:00:00.123+0800|gusdecool/x" "BM-21|2026-11-06T06:30:00.000-0500|gusdecool/x"
run_precheck
assert_eq "a +0800 time is converted: 17:00+0800 is 09:00Z, stale" "move label comment" "$(mutations BM-20)"
assert_eq "a -0500 time is converted: 06:30-0500 is 11:30Z, fresh" "" "$(mutations BM-21)"
assert_eq "the offset conversion lets the precheck pass" "0" "$CODE"
precheck_board
set_progress "BM-20|2026-11-06T11:59:00.5+0000|gusdecool/x" "BM-21|2026-11-06T14:00:00Z|gusdecool/x"
run_precheck
assert_eq "an offset +0000 and a Z time are both read" "1" "$CODE"

precheck_board
set_todos
run_precheck
assert_eq "no Todo ticket and two active tickets exit 1" "1" "$CODE"
set_progress "BM-20|2026-11-06T19:30:00.123+0800|gusdecool/x"
run_precheck
assert_eq "no Todo ticket exits 1" "1" "$CODE"
assert_eq "no Todo ticket is named" "1" "$(grep -c 'Todo' <<<"$ERR")"

precheck_board
set_progress "BM-20|2026-11-06T19:30:00.123+0800|gusdecool/x"
run_precheck pp-fail
assert_eq "provider failure exits 1" "1" "$CODE"
assert_eq "provider failure is named" "1" "$(grep -c 'provider' <<<"$ERR")"
run_precheck pp-ok
assert_eq "one In progress ticket, a Todo ticket and a provider exit 0" "0" "$CODE"

precheck_board
set_progress "BM-20|2026-11-06T17:00:00.000+0800|gusdecool/x" "BM-21|2026-11-06T16:00:00.000+0800|gusdecool/x"
run_precheck
assert_eq "both stale tickets are reaped, so the precheck passes" "0" "$CODE"
assert_eq "the status move happens before the comment" "move label comment" "$(mutations BM-20)"
assert_eq "the second stale ticket is reaped too" "move label comment" "$(mutations BM-21)"

precheck_board
set_progress "BM-20|2026-11-06T17:00:00.000+0800|gusdecool/x" "BM-21|2026-11-06T17:00:00.000+0800|gusdecool/x"
route 00-comment-fail 'POST */comment' '500|{}'
run_precheck
assert_eq "a failing reap exits 2" "2" "$CODE"
assert_eq "a failing reap still tries the next ticket" "move label comment" "$(mutations BM-21)"
assert_eq "a failing reap names the failed tickets" "2" "$(grep -o 'BM-2[01]' <<<"$ERR" | sort -u | wc -l | tr -d ' ')"

precheck_board
set_progress "BM-20|2026-11-06T17:00:00.000+0800|gusdecool/x" "BM-21|2026-11-06T11:00:00.000+0000|gusdecool/x"
route 00-move-fail 'POST */transitions' '400|{"errorMessages":["no"]}'
run_precheck
assert_eq "a failed move exits 2 and the ticket is named" "2 1" \
  "$CODE $(grep -c 'could not reap: BM-20' <<<"$ERR")"
assert_eq "a failed move adds no label and no comment" "move" "$(mutations BM-20)"

precheck_board
set_progress "BM-20|2026-11-06T17:00:00.000+0800|gusdecool/x" "BM-21|2026-11-06T17:00:00.000+0800|gusdecool/x"
touch "$STUB_DIR/gh-fail-pr-list"
run_precheck
assert_eq "unreadable activity counts as active" "1" "$CODE"
assert_eq "unreadable activity never reaps" "0" "$(mutation_count)"

precheck_board
set_progress "BM-20||gusdecool/x" "BM-21||gusdecool/x"
run_precheck
assert_eq "a missing updated time counts as active and is not reaped" "1" "$CODE"
assert_eq "a missing updated time never reaps" "0" "$(mutation_count)"

precheck_board
set_progress "BM-20|2026-11-06T19:30:00.123+0800|gusdecool/x" "BM-30|2026-11-06T01:00:00.000+0000|acme/y"
run_precheck
assert_eq "a foreign-owner In progress ticket is counted" "1" "$CODE"
assert_eq "a foreign-owner In progress ticket is never reaped" "00" \
  "$(grep -c 'acme/y' "$STUB_DIR/calls.log" || true)$(jira_mentions BM-30/)"
set_progress "BM-31|2026-11-06T01:00:00.000+0000|" "BM-20|2026-11-06T19:30:00.000+0800|gusdecool/x"
run_precheck
assert_eq "an unknown-repo In progress ticket is counted" "1" "$CODE"
assert_eq "an unknown-repo In progress ticket is never reaped" "00" "$(mutation_count)$(jira_mentions BM-31/)"

# Asserts the last precheck wrote exactly one stderr line. Arg: label.
assert_one_line() { assert_eq "$1 prints exactly one stderr line" "1" "$(printf '%s\n' "$ERR" | grep -c .)"; }
precheck_board
run_precheck
assert_one_line "limit reached"
precheck_board
set_todos
set_progress "BM-20|2026-11-06T19:30:00.123+0800|gusdecool/x"
run_precheck
assert_one_line "no Todo ticket"
precheck_board
set_progress "BM-20|2026-11-06T19:30:00.123+0800|gusdecool/x"
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
route 00-search-fail 'GET *%22In%20progress%22*' '500|{}'
run_precheck
assert_eq "a Jira error while listing exits 2" "2" "$CODE"
assert_one_line "a Jira error"
precheck_board
route 00-search-fail 'GET *%22Todo%22*' '500|{}'
set_progress "BM-20|2026-11-06T19:30:00.123+0800|gusdecool/x"
run_precheck
assert_eq "an unreadable Todo list exits 2" "2" "$CODE"

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
