#!/usr/bin/env bash
# Tests for board-migrate-from-github, with gh and curl replaced by the stubs in tests/stubs. No network is used and
# the real Jira config is never read: a fake config with a fake token is used.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE="$REPO/skills/board-worker/scripts/board-migrate-from-github"
export BOARD_WORKER_CONFIG="$REPO/tests/fixtures/board/config"
export STUB_DIR
STUB_DIR="$(mktemp -d)"
export PATH="$REPO/tests/stubs:$PATH"
export BOARD_JIRA_CONFIG="$STUB_DIR/jira"
printf "JIRA_SITE='https://x.atlassian.net'\nJIRA_EMAIL='a@b.c'\nJIRA_TOKEN='FAKE-TOKEN-abc'\n" >"$BOARD_JIRA_CONFIG"
FAILS=0
SITE="https://x.atlassian.net/rest/api/2"

# Removes the stub output directory.
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() { rm -rf "$STUB_DIR"; }
trap cleanup EXIT

# Records a failure when two values differ.
assert_eq() {
  if [ "$2" != "$3" ]; then echo "FAIL: $1 (expected '$2', got '$3')"; FAILS=$((FAILS + 1)); else echo "ok: $1"; fi
}

# Records a failure when the haystack does not contain the needle.
assert_has() {
  if [[ "$3" != *"$2"* ]]; then echo "FAIL: $1 (missing '$2' in '$3')"; FAILS=$((FAILS + 1)); else echo "ok: $1"; fi
}

# Writes one curl route file: name, glob of "METHOD URL", and the "<code>|<json>" answer.
route() { printf '%s\n%s\n' "$2" "$3" >"$STUB_DIR/curl-routes/$1"; }

# Clears all stub logs and canned outputs, then installs the default Jira routes (every create answers BM-100).
reset() {
  rm -rf "$STUB_DIR"/curl-* "$STUB_DIR"/gh-* "$STUB_DIR/calls.log"
  mkdir "$STUB_DIR/curl-routes"
  route 1-create "POST $SITE/issue" '201|{"key":"BM-100"}'
  route 2-transitions "GET $SITE/issue/BM-100/transitions" \
    '200|{"transitions":[{"id":"11","to":{"name":"Todo"}},{"id":"12","to":{"name":"QA"}},'\
'{"id":"13","to":{"name":"HITL"}}]}'
  route 3-post "POST $SITE/issue/BM-100/transitions" '204|'
  route 4-put "PUT $SITE/issue/BM-100" '204|'
  echo 0 >"$STUB_DIR/gh-output"
}

# Builds one board item JSON. Args: number, repo, status, priority, type, title, body, labels JSON array.
item() {
  jq -cn --argjson n "$1" --arg r "$2" --arg s "$3" --arg p "$4" --arg t "$5" --arg ti "$6" --arg b "$7" \
    --argjson l "$8" '{id: ("I" + ($n | tostring)), status: $s, priority: $p, labels: $l,
      content: {type: $t, number: $n, repository: $r, url: ("https://github.com/" + $r + "/issues/" + ($n | tostring)),
                title: $ti, body: $b}}
      | if $s == "" then del(.status) else . end | if $p == "" then del(.priority) else . end'
}

# Stores the given item JSON arguments as the canned board.
board() { jq -cn '{items: $ARGS.positional | map(fromjson)}' --args "$@" >"$STUB_DIR/gh-project-item-list"; }

# Runs the migration with the given arguments; stdout goes to OUT, stderr to ERR, the exit code to CODE.
# shellcheck disable=SC2034 # OUT, ERR and CODE are read by the assertions
run() {
  OUT="$(bash "$MIGRATE" "$@" 2>"$STUB_DIR/err")"
  CODE=$?
  ERR="$(cat "$STUB_DIR/err")"
}

# Prints the number of lines in a stub log matching an extended regex (0 when the log is missing).
count() { if [ -f "$2" ]; then grep -cE "$1" "$2" || true; else echo 0; fi; }

# Prints the bodies of the create calls, one JSON per line.
creates() { grep -E "^POST $SITE/issue " "$STUB_DIR/curl-calls" 2>/dev/null | cut -d' ' -f3- || true; }

BOARD="gusdecool/x"
EMPTY='[]'
BODY=$'Intro **bold** and `code`\nAuto merge: true\nTail'

echo "dry run"
reset
board "$(item 10 $BOARD Todo High Issue 'First' "$BODY" "$EMPTY")" \
  "$(item 11 $BOARD QA Low Issue 'Second' '' "$EMPTY")" \
  "$(item 12 bungamata/z "In progress" Urgent Issue 'Third' '' "$EMPTY")" \
  "$(item 13 acme/y Todo High Issue 'Foreign' '' "$EMPTY")" \
  "$(item 14 $BOARD Done High Issue 'Finished' '' "$EMPTY")" \
  "$(item 15 $BOARD Todo High PullRequest 'A PR' '' "$EMPTY")" \
  "$(item 16 $BOARD Todo High Issue 'Moved already' '' "$EMPTY")" \
  "$(item 17 $BOARD Todo High Issue 'No comments' '' "$EMPTY")"
echo 1 >"$STUB_DIR/gh-issue-view-16"
touch "$STUB_DIR/gh-fail-issue-view-17"
run --owner bungamata --project 9
EXPECT="would migrate gusdecool/x#10 -> Todo [High] (auto merge not carried over)
would migrate gusdecool/x#11 -> QA [Low]
would migrate bungamata/z#12 -> HITL [Medium]
skip acme/y#13: owner not allowed
skip gusdecool/x#14: status Done
skip gusdecool/x#15: not an issue
skip gusdecool/x#16: already moved to Jira
fail gusdecool/x#17: cannot read the issue comments
summary: 3 migrated, 4 skipped, 1 failed (dry run)"
assert_eq "dry run prints the plan" "$EXPECT" "$OUT"
assert_eq "dry run exits 1 because a card failed" "1" "$CODE"
assert_eq "dry run makes no Jira call" "0" "$(count . "$STUB_DIR/curl-calls")"
assert_eq "dry run posts no GitHub comment" "0" "$(count 'issue comment' "$STUB_DIR/calls.log")"
assert_has "the board is read with the project, owner and default limit" \
  "project item-list 9 --owner bungamata --format json --limit 500" "$(cat "$STUB_DIR/gh-args")"
run --owner bungamata --project 9 --limit 7
assert_has "--limit is passed to gh" "--limit 7" "$(cat "$STUB_DIR/gh-args")"

echo "apply: status handling"
# Each row: status|labels JSON|priority|expected status|expected transition id ("" for none)|expect label (yes|no)
while IFS='|' read -r st labels prio want tid lab; do
  reset
  board "$(item 10 $BOARD "$st" "$prio" Issue 'T' 'body' "$labels")"
  run --owner bungamata --project 9 --apply
  assert_eq "[$st] output" "migrated gusdecool/x#10 -> BM-100 $want
summary: 1 migrated, 0 skipped, 0 failed" "$OUT"
  assert_eq "[$st] exit code" "0" "$CODE"
  if [ -n "$tid" ]; then
    assert_eq "[$st] transition posted" "POST $SITE/issue/BM-100/transitions {\"transition\":{\"id\":\"$tid\"}}" \
      "$(grep -E '/transitions \{' "$STUB_DIR/curl-calls" || true)"
  else
    assert_eq "[$st] no transition" "0" "$(count '/transitions' "$STUB_DIR/curl-calls")"
  fi
  want_label="PUT $SITE/issue/BM-100 {\"update\":{\"labels\":[{\"add\":\"HITL\"}]}}"
  if [ "$lab" = yes ]; then
    assert_eq "[$st] HITL label added" "$want_label" "$(grep -E '^PUT ' "$STUB_DIR/curl-calls" || true)"
  else
    assert_eq "[$st] no label" "0" "$(count '^PUT ' "$STUB_DIR/curl-calls")"
  fi
done <<'ROWS'
Todo|[]|High|Todo|11|no
QA|[]|Low|QA|12|no
HITL|["HITL"]|Medium|HITL|13|yes
Backlog|[]|Urgent|Backlog||no
In progress|[]||HITL|13|yes
Todo|["bug","HITL"]|High|Todo|11|yes
ROWS

echo "apply: creation, comment and conversion"
reset
board "$(item 10 $BOARD Todo High Issue 'A $(whoami) "title"' "$BODY" "$EMPTY")" \
  "$(item 11 bungamata/z Backlog Low Issue 'Second' 'plain' "$EMPTY")"
run --owner bungamata --project 9 --apply
assert_eq "apply output" "migrated gusdecool/x#10 -> BM-100 Todo (auto merge not carried over)
migrated bungamata/z#11 -> BM-100 Backlog
summary: 2 migrated, 0 skipped, 0 failed" "$OUT"
assert_eq "one ticket per card" "2" "$(creates | wc -l | tr -d ' ')"
FIRST="$(creates | sed -n 1p)"
SECOND="$(creates | sed -n 2p)"
assert_eq "component of the first card" "gusdecool/x" "$(jq -r '.fields.components[0].name' <<<"$FIRST")"
assert_eq "component of the second card" "bungamata/z" "$(jq -r '.fields.components[0].name' <<<"$SECOND")"
assert_eq "priorities are mapped" "High Low" \
  "$(jq -r '.fields.priority.name' <<<"$FIRST") $(jq -r '.fields.priority.name' <<<"$SECOND")"
assert_eq "title stays data" 'A $(whoami) "title"' "$(jq -r '.fields.summary' <<<"$FIRST")"
assert_eq "description starts with the GitHub link" "GitHub: https://github.com/gusdecool/x/issues/10" \
  "$(jq -r '.fields.description' <<<"$FIRST" | sed -n 1p)"
assert_eq "description has a blank second line" "" "$(jq -r '.fields.description' <<<"$FIRST" | sed -n 2p)"
assert_eq "body is converted and the Auto merge line is gone" "*bold* and {{code}}|Tail" \
  "$(jq -r '.fields.description' <<<"$FIRST" | sed -n '3,$p' | sed 's/^Intro //' | paste -sd'|' -)"
assert_eq "the GitHub issue is commented" \
  "issue comment https://github.com/gusdecool/x/issues/10 --body Moved to Jira: https://x.atlassian.net/browse/BM-100" \
  "$(grep -E '^issue comment .*/x/issues/10' "$STUB_DIR/calls.log")"
assert_eq "the GitHub issue is never closed or edited" "0" "$(count 'issue (close|edit)' "$STUB_DIR/calls.log")"
assert_eq "automerge is never called" "0" "$(count '/field|customfield' "$STUB_DIR/curl-calls")"
assert_eq "the token is never printed" "0" "$(grep -c 'FAKE-TOKEN' <<<"$OUT$ERR")"

echo "apply: markdown converter"
reset
MD=$'# Title\n## Sub **x**\n###### Six\n####### Seven\n#nospace\nuse `a` and **b**\n```js\n# not **x** `y`'
MD+=$'\n$(rm -rf /) "q"\n```'
MD+=$'\n```\nplain\n```\ntext $(echo hi) "quoted" '"'"'single'"'"' `a`'
board "$(item 10 $BOARD Backlog High Issue 'T' "$MD" "$EMPTY")"
run --owner bungamata --project 9 --apply
EXPECT='h1. Title
h2. Sub *x*
h6. Six
####### Seven
#nospace
use {{a}} and *b*
{code:js}
# not **x** `y`
$(rm -rf /) "q"
{code}
{code}
plain
{code}
text $(echo hi) "quoted" '"'"'single'"'"' {{a}}'
assert_eq "markdown is converted, fenced text untouched, shell syntax intact" "$EXPECT" \
  "$(creates | jq -r '.fields.description' | sed -n '3,$p')"

echo "apply: titles"
reset
LONG="abcd"$'\n'"ef$(printf 'g%.0s' {1..300})"
board "$(item 10 $BOARD Backlog High Issue "$LONG" '' "$EMPTY")"
run --owner bungamata --project 9 --apply
SUMMARY="$(creates | jq -r '.fields.summary')"
assert_eq "long title is cut to 255 characters" "255" "${#SUMMARY}"
assert_eq "newlines in the title become spaces" "abcd efgg" "${SUMMARY:0:9}"
assert_eq "long title card migrated" "0" "$CODE"

echo "apply: failures"
reset
route 2-transitions "GET $SITE/issue/BM-100/transitions" '200|{"transitions":[]}'
board "$(item 10 $BOARD Todo High Issue 'One' '' "$EMPTY")" \
  "$(item 11 $BOARD Backlog High Issue 'Two' '' "$EMPTY")"
run --owner bungamata --project 9 --apply
assert_has "a failed status reports the new key" "fail gusdecool/x#10: BM-100 created but status Todo failed" "$OUT"
assert_has "the run continues after a failure" "migrated gusdecool/x#11 -> BM-100 Backlog" "$OUT"
assert_has "the summary counts the failure" "summary: 1 migrated, 0 skipped, 1 failed" "$OUT"
assert_eq "the run exits 1" "1" "$CODE"
assert_eq "the issue is still commented so it is not migrated twice" "2" \
  "$(count 'issue comment' "$STUB_DIR/calls.log")"
reset
route 1-create "POST $SITE/issue" '400|{"errorMessages":["bad"]}'
board "$(item 10 $BOARD Todo High Issue 'One' '' "$EMPTY")"
run --owner bungamata --project 9 --apply
assert_has "a failed create is a fail line" "fail gusdecool/x#10: create failed" "$OUT"
assert_eq "a failed create posts no GitHub comment" "0" "$(count 'issue comment' "$STUB_DIR/calls.log")"
reset
touch "$STUB_DIR/gh-fail-issue-view-10"
board "$(item 10 $BOARD Todo High Issue 'One' '' "$EMPTY")"
run --owner bungamata --project 9 --apply
assert_eq "an unreadable comment list fails without creating" "1 0" "$CODE $(count . "$STUB_DIR/curl-calls")"
reset
touch "$STUB_DIR/gh-fail-issue-comment"
board "$(item 10 $BOARD Backlog High Issue 'One' '' "$EMPTY")"
run --owner bungamata --project 9 --apply
assert_has "a failed GitHub comment reports the key" \
  "fail gusdecool/x#10: BM-100 created but GitHub comment failed" "$OUT"

echo "board and usage errors"
reset
touch "$STUB_DIR/gh-fail-project-item-list"
run --owner bungamata --project 9
assert_eq "an unreadable board exits 2" "2" "$CODE"
reset
echo 'not json' >"$STUB_DIR/gh-project-item-list"
run --owner bungamata --project 9
assert_eq "an invalid board exits 2" "2" "$CODE"
reset
for args in "--project 9" "--owner bungamata" "--owner bungamata --project x" "--owner bad/owner --project 9" \
  "--owner bungamata --project 9 --limit -1" "--owner bungamata --project 9 --bogus" \
  "--owner bungamata --project" ""; do
  # shellcheck disable=SC2086 # the argument strings are split on purpose
  run $args
  assert_eq "usage error for '$args'" "2" "$CODE"
  assert_has "usage line for '$args'" "usage: board-migrate-from-github" "$ERR"
done
assert_eq "usage errors call nothing" "0" "$(count . "$STUB_DIR/calls.log")"

if [ "$FAILS" -eq 0 ]; then echo "All board-migrate tests passed"; fi
exit "$FAILS"
