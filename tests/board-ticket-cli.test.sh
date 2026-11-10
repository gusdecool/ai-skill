#!/usr/bin/env bash
# Tests for board-ticket-cli, with curl replaced by the stub in tests/stubs. No network is used and the real Jira config
# is never read: a fake config with a fake token is used.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICKET="$REPO/skills/board-worker/scripts/board-ticket-cli"
export BOARD_WORKER_CONFIG="$REPO/tests/fixtures/board/config"
export STUB_DIR
STUB_DIR="$(mktemp -d)"
export PATH="$REPO/tests/stubs:$PATH"
export BOARD_JIRA_CONFIG="$STUB_DIR/jira"
printf "JIRA_SITE='https://x.atlassian.net'\nJIRA_EMAIL='a@b.c'\nJIRA_TOKEN='FAKE-TOKEN-abc'\n" >"$BOARD_JIRA_CONFIG"
FAILS=0

# Removes the stub output directory.
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() { rm -rf "$STUB_DIR"; }
trap cleanup EXIT

# Records a failure when two values differ.
assert_eq() {
  if [ "$2" != "$3" ]; then echo "FAIL: $1 (expected '$2', got '$3')"; FAILS=$((FAILS + 1)); else echo "ok: $1"; fi
}

# Clears the curl stub logs and routes, then queues the given responses, one "<code>|<json>" per argument.
reset_curl() {
  rm -f "$STUB_DIR"/curl-argv "$STUB_DIR"/curl-stdin "$STUB_DIR"/curl-body "$STUB_DIR"/curl-fail "$STUB_DIR"/curl-calls
  rm -rf "$STUB_DIR/curl-routes"
  : >"$STUB_DIR/curl-responses"
  local r
  for r in "$@"; do printf '%s\n' "$r" >>"$STUB_DIR/curl-responses"; done
}

# Runs board-ticket-cli with the given arguments; stdout goes to OUT, stderr to ERR, the exit code to CODE.
# shellcheck disable=SC2034 # OUT, ERR and CODE are read by the assertions
run() {
  OUT="$(bash "$TICKET" "$@" 2>"$STUB_DIR/err")"
  CODE=$?
  ERR="$(cat "$STUB_DIR/err")"
}

# Prints the number of curl calls made so far.
ncalls() { if [ -f "$STUB_DIR/curl-calls" ]; then wc -l <"$STUB_DIR/curl-calls" | tr -d ' '; else echo 0; fi; }

FIELDS='[{"id":"summary","name":"Summary","custom":false},'
FIELDS+='{"id":"customfield_10036","name":"Auto merge","custom":true}]'
ISSUE='{"key":"BM-5","fields":{"summary":"Fix it","status":{"name":"In progress"},"priority":{"name":"High"},'
ISSUE+='"components":[{"name":"acme/app"}],"labels":["HITL","x"],"description":"h2. Goal\nX",'
ISSUE+='"customfield_10036":[{"value":"Yes"}]}}'

echo "view"
reset_curl "200|$FIELDS" "200|$(jq -c . <<<"$ISSUE")"
run view BM-5
assert_eq "view exits 0" "0" "$CODE"
EXPECT='{"key":"BM-5","summary":"Fix it","status":"In progress","priority":"High","component":"acme/app",'
EXPECT+='"components":["acme/app"],"labels":["HITL","x"],"description":"h2. Goal\nX","autoMerge":true,'
EXPECT+='"url":"https://x.atlassian.net/browse/BM-5"}'
assert_eq "view prints the ticket fields" "$EXPECT" "$OUT"
reset_curl "200|$FIELDS" "200|$(jq -c '.fields.customfield_10036 = null | .fields.components = []' <<<"$ISSUE")"
run view https://x.atlassian.net/browse/BM-5
assert_eq "view takes a browse URL; null checkbox is false; no component is empty" \
  "false||[]" "$(jq -r '"\(.autoMerge)|\(.component)|\(.components)"' <<<"$OUT" | tr -d '\n ')"
reset_curl '200|[{"id":"summary","name":"Summary","custom":false}]' "200|$(jq -c . <<<"$ISSUE")"
run view BM-5
assert_eq "view with no Auto merge field gives autoMerge null" "null" "$(jq -c .autoMerge <<<"$OUT")"
reset_curl "200|$(jq -c '. + [{"id":"customfield_2","name":"Auto merge","custom":true}]' <<<"$FIELDS")" \
  "200|$(jq -c . <<<"$ISSUE")"
run view BM-5
assert_eq "view with two Auto merge fields gives autoMerge null" "null" "$(jq -c .autoMerge <<<"$OUT")"
reset_curl "200|$FIELDS" '404|{"errorMessages":["Issue does not exist"]}'
run view BM-5
assert_eq "view of a missing ticket exits 2" "2" "$CODE"

echo "status"
reset_curl '200|{"fields":{"status":{"name":"In progress"}}}'
run status BM-5
assert_eq "status prints the name only" "0 In progress" "$CODE $OUT"
assert_eq "status reads the ticket" "GET https://x.atlassian.net/rest/api/2/issue/BM-5?fields=status " \
  "$(cat "$STUB_DIR/curl-calls")"

echo "comment"
reset_curl '201|{"id":"1"}'
# shellcheck disable=SC2016 # the comment is a literal $(...) on purpose: it must be sent as data
run comment BM-5 "Board worker" 'started $(touch '"$STUB_DIR"'/pwned) "q"'
assert_eq "comment exits 0" "0" "$CODE"
# shellcheck disable=SC2016 # the comment is a literal $(...) on purpose: it must be sent as data
assert_eq "comment joins the words and sends them as data" \
  'Board worker started $(touch '"$STUB_DIR"'/pwned) "q"' "$(jq -r .body "$STUB_DIR/curl-body")"
assert_eq "comment posts to the comment resource" "POST https://x.atlassian.net/rest/api/2/issue/BM-5/comment" \
  "$(cut -d' ' -f1-2 "$STUB_DIR/curl-calls")"
assert_eq "comment text was not executed" "no" "$([ -e "$STUB_DIR/pwned" ] && echo yes || echo no)"
reset_curl
run comment BM-5 ""
assert_eq "an empty comment exits 2 with no call" "2 0" "$CODE $(ncalls)"
run comment BM-5
assert_eq "a comment with no text exits 2 with no call" "2 0" "$CODE $(ncalls)"
run comment 'BM-5;ls' hi
assert_eq "a bad key exits 2 with no call" "2 0" "$CODE $(ncalls)"

echo "label"
reset_curl '204|' '204|'
run label BM-5 add HITL
assert_eq "label add exits 0" "0" "$CODE"
assert_eq "label add sends the update payload" '{"update":{"labels":[{"add":"HITL"}]}}' \
  "$(jq -c . "$STUB_DIR/curl-body")"
run label BM-5 remove HITL
assert_eq "label remove sends the update payload" '{"update":{"labels":[{"remove":"HITL"}]}}' \
  "$(jq -c . "$STUB_DIR/curl-body")"
assert_eq "label uses PUT on the ticket" "PUT https://x.atlassian.net/rest/api/2/issue/BM-5" \
  "$(tail -n 1 "$STUB_DIR/curl-calls" | cut -d' ' -f1-2)"
reset_curl
run label BM-5 add 'bad label'
assert_eq "an invalid label exits 2 with no call" "2 0" "$CODE $(ncalls)"
run label BM-5 add "$(printf 'a%.0s' {1..41})"
assert_eq "a 41 character label exits 2 with no call" "2 0" "$CODE $(ncalls)"
run label BM-5 toggle HITL
assert_eq "an unknown label operation exits 2 with no call" "2 0" "$CODE $(ncalls)"
run label bm-5 add HITL
assert_eq "a lower case key exits 2 with no call" "2 0" "$CODE $(ncalls)"
run label https://evil.example/browse/BM-5 add HITL
assert_eq "a URL on another host exits 2 with no call" "2 0" "$CODE $(ncalls)"

echo "create"
DESC="$STUB_DIR/desc"
# shellcheck disable=SC2016 # the description is a literal $(...) on purpose: it must be sent as data
printf 'h2. Goal\nSay "hi" and run $(touch %s/pwned2)\n`id`\n' "$STUB_DIR" >"$DESC"
reset_curl '201|{"id":"9","key":"BM-9"}'
# shellcheck disable=SC2016 # the summary is a literal $(...) on purpose: it must be sent as data
run create --summary 'Add "x" $(id)' --component acme/app --description-file "$DESC" --priority High
assert_eq "create prints key and url" '{"key":"BM-9","url":"https://x.atlassian.net/browse/BM-9"}' "$OUT"
assert_eq "create posts to the issue resource" "POST https://x.atlassian.net/rest/api/2/issue" \
  "$(cut -d' ' -f1-2 "$STUB_DIR/curl-calls")"
assert_eq "create sends project, component, priority and type, with no status" \
  'BM|acme/app|High|Task|false' \
  "$(jq -r '.fields | "\(.project.key)|\(.components[0].name)|\(.priority.name)|\(.issuetype.name)|\(has("status"))"' \
    "$STUB_DIR/curl-body")"
# shellcheck disable=SC2016 # the summary is a literal $(...) on purpose: it must be sent as data
assert_eq "create sends the summary as data" 'Add "x" $(id)' "$(jq -r .fields.summary "$STUB_DIR/curl-body")"
assert_eq "create sends the description file intact" "$(cat "$DESC")" \
  "$(jq -r .fields.description "$STUB_DIR/curl-body")"
assert_eq "create did not execute the description" "no" "$([ -e "$STUB_DIR/pwned2" ] && echo yes || echo no)"
reset_curl '201|{"id":"9","key":"BM-10"}'
run create --summary S --component a/b --description-file "$DESC"
assert_eq "create defaults to Medium and Task" "Medium|Task" \
  "$(jq -r '.fields | "\(.priority.name)|\(.issuetype.name)"' "$STUB_DIR/curl-body")"
run create --summary S --component a/b --description-file "$DESC" --type Bug --priority Lowest
assert_eq "create accepts --type and --priority" "Lowest|Bug" \
  "$(jq -r '.fields | "\(.priority.name)|\(.issuetype.name)"' "$STUB_DIR/curl-body")"
reset_curl
run create --summary S --component 'a/b/c' --description-file "$DESC"
assert_eq "a nested component exits 2 with no call" "2 0" "$CODE $(ncalls)"
run create --summary S --component 'ab' --description-file "$DESC"
assert_eq "a component without a slash exits 2 with no call" "2 0" "$CODE $(ncalls)"
run create --summary S --component 'a b/c' --description-file "$DESC"
assert_eq "a component with a space exits 2 with no call" "2 0" "$CODE $(ncalls)"
run create --summary "" --component a/b --description-file "$DESC"
assert_eq "an empty summary exits 2 with no call" "2 0" "$CODE $(ncalls)"
run create --summary $'two\nlines' --component a/b --description-file "$DESC"
assert_eq "a summary with a newline exits 2 with no call" "2 0" "$CODE $(ncalls)"
run create --summary "$(printf 'a%.0s' {1..256})" --component a/b --description-file "$DESC"
assert_eq "a 256 character summary exits 2 with no call" "2 0" "$CODE $(ncalls)"
run create --summary S --component a/b --description-file "$DESC" --priority Urgent
assert_eq "an invalid priority exits 2 with no call" "2 0" "$CODE $(ncalls)"
run create --summary S --component a/b --description-file "$DESC" --type Epic
assert_eq "an invalid type exits 2 with no call" "2 0" "$CODE $(ncalls)"
run create --summary S --component a/b --description-file "$STUB_DIR/missing"
assert_eq "a missing description file exits 2 with no call" "2 0" "$CODE $(ncalls)"
run create --summary S --component a/b
assert_eq "a missing --description-file exits 2 with no call" "2 0" "$CODE $(ncalls)"
run create --summary S --bogus x
assert_eq "an unknown create option exits 2 with no call" "2 0" "$CODE $(ncalls)"

echo "automerge"
reset_curl "200|$FIELDS" '204|'
run automerge BM-5
assert_eq "automerge exits 0" "0" "$CODE"
assert_eq "automerge ticks the checkbox" '{"fields":{"customfield_10036":[{"value":"Yes"}]}}' \
  "$(jq -c . "$STUB_DIR/curl-body")"
assert_eq "automerge uses PUT on the ticket" "PUT https://x.atlassian.net/rest/api/2/issue/BM-5" \
  "$(tail -n 1 "$STUB_DIR/curl-calls" | cut -d' ' -f1-2)"
reset_curl '200|[{"id":"summary","name":"Summary","custom":false}]'
run automerge BM-5
assert_eq "automerge with no Auto merge field exits 2 and does not write" "2 1" "$CODE $(ncalls)"
reset_curl "200|$(jq -c '. + [{"id":"customfield_2","name":"Auto merge","custom":true}]' <<<"$FIELDS")"
run automerge BM-5
assert_eq "automerge with two Auto merge fields exits 2 and does not write" "2 1" "$CODE $(ncalls)"
reset_curl '200|[{"id":"evil","name":"Auto merge","custom":true}]'
run automerge BM-5
assert_eq "automerge with an odd field id exits 2 and does not write" "2 1" "$CODE $(ncalls)"
reset_curl
run automerge 'BM-5 x'
assert_eq "automerge with a bad key exits 2 with no call" "2 0" "$CODE $(ncalls)"

echo "usage and secrets"
reset_curl
run
assert_eq "no arguments exits 2" "2" "$CODE"
run frobnicate BM-5
assert_eq "an unknown subcommand exits 2 with no call" "2 0" "$CODE $(ncalls)"
run view
assert_eq "view without a key exits 2" "2" "$CODE"
run status BM-5 extra
assert_eq "status with an extra argument exits 2" "2" "$CODE"
reset_curl '401|{}'
run status BM-5
assert_eq "a Jira error exits 2" "2" "$CODE"
assert_eq "the token is never printed" "0" "$(grep -c 'FAKE-TOKEN' <<<"$OUT$ERR")"
assert_eq "the token is not in the curl arguments" "0" "$(grep -c 'FAKE-TOKEN' "$STUB_DIR/curl-argv")"

echo "blockers and link"
LINKS='{"fields":{"issuelinks":['
LINKS+='{"type":{"name":"Blocks"},"inwardIssue":{"key":"BM-1","fields":{"status":{"name":"QA"}}}},'
LINKS+='{"type":{"name":"Blocks"},"inwardIssue":{"key":"BM-2","fields":{"status":{"name":"Todo"}}}},'
LINKS+='{"type":{"name":"Blocks"},"inwardIssue":{"key":"BM-4","fields":{"status":{"name":"Done"}}}},'
LINKS+='{"type":{"name":"Blocks"},"outwardIssue":{"key":"BM-9","fields":{"status":{"name":"Todo"}}}},'
LINKS+='{"type":{"name":"Relates"},"inwardIssue":{"key":"BM-3","fields":{"status":{"name":"Backlog"}}}}]}}'
reset_curl "200|$LINKS"
run blockers BM-5
assert_eq "blockers exits 0" "0" "$CODE"
assert_eq "blockers lists only the Blocks links where the ticket is blocked, with finished for QA and Done" \
  '[{"key":"BM-1","status":"QA","finished":true},{"key":"BM-2","status":"Todo","finished":false},'\
'{"key":"BM-4","status":"Done","finished":true}]' "$OUT"
reset_curl '200|{"fields":{"issuelinks":[]}}'
run blockers BM-5
assert_eq "blockers of a ticket with no links is an empty array" "[]" "$OUT"
run blockers
assert_eq "blockers without a key exits 2" "2" "$CODE"

reset_curl '200|{"fields":{"issuelinks":[]}}' '201|'
run link BM-5 blocked-by BM-2
assert_eq "link exits 0" "0" "$CODE"
assert_eq "link posts a Blocks link: the blocker is the outward issue" \
  '{"type":{"name":"Blocks"},"outwardIssue":{"key":"BM-2"},"inwardIssue":{"key":"BM-5"}}' \
  "$(jq -c . "$STUB_DIR/curl-body")"
assert_eq "link posts to the issueLink endpoint" "1" \
  "$(grep -c '^POST https://x.atlassian.net/rest/api/2/issueLink ' "$STUB_DIR/curl-calls")"
reset_curl "200|$LINKS"
run link BM-5 blocked-by BM-2
assert_eq "link does nothing when the link already exists" "0 1" "$CODE $(ncalls)"
reset_curl
run link BM-5 blocked-by BM-5
assert_eq "link to itself exits 2 with no call" "2 0" "$CODE $(ncalls)"
run link BM-5 blocks BM-2
assert_eq "link with another word than blocked-by exits 2 with no call" "2 0" "$CODE $(ncalls)"
run link BM-5 blocked-by nope
assert_eq "link with a bad blocker key exits 2 with no call" "2 0" "$CODE $(ncalls)"
reset_curl '200|{"fields":{"issuelinks":[]}}' '400|{"errorMessages":["no"]}'
run link BM-5 blocked-by BM-2
assert_eq "a Jira error while linking exits 2" "2" "$CODE"

if [ "$FAILS" -eq 0 ]; then echo "All board-ticket-cli tests passed"; fi
exit "$FAILS"
