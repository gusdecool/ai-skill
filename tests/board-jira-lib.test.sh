#!/usr/bin/env bash
# Tests for the Jira helpers in board-lib.sh, with curl replaced by the stub in tests/stubs. No network is used.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/skills/board-worker/scripts/board-lib.sh"
export BOARD_WORKER_CONFIG="$REPO/tests/fixtures/board/config"
export STUB_DIR
STUB_DIR="$(mktemp -d)"
export PATH="$REPO/tests/stubs:$PATH"
TOKEN='FAKE-TOKEN-abc=123_xyz'
export BOARD_JIRA_CONFIG="$STUB_DIR/jira"
FAILS=0

# Removes the stub output directory.
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() { rm -rf "$STUB_DIR"; }
trap cleanup EXIT

# Records a failure when two values differ.
assert_eq() {
  if [ "$2" != "$3" ]; then echo "FAIL: $1 (expected '$2', got '$3')"; FAILS=$((FAILS + 1)); else echo "ok: $1"; fi
}

# Writes a valid Jira config using the given token text (quotes included by the caller).
write_config() {
  printf "JIRA_SITE='https://x.atlassian.net'\nJIRA_EMAIL=\"a@b.c\"\nJIRA_TOKEN=%s\n" "$1" >"$BOARD_JIRA_CONFIG"
}

# Clears the curl stub logs and queues the given responses, one "<code>|<json>" per argument.
reset_stub() {
  rm -f "$STUB_DIR"/curl-argv "$STUB_DIR"/curl-stdin "$STUB_DIR"/curl-body "$STUB_DIR"/curl-fail
  : >"$STUB_DIR/curl-responses"
  local r
  for r in "$@"; do printf '%s\n' "$r" >>"$STUB_DIR/curl-responses"; done
}

# Runs a command string in a fresh shell that has sourced the library; stdout goes to OUT, stderr to ERR, exit to CODE.
# shellcheck disable=SC2034 # OUT, ERR and CODE are read by the assertions
run_lib() {
  OUT="$(bash -c 'source "$1"; shift; eval "$@"' _ "$LIB" "$@" 2>"$STUB_DIR/err")"
  CODE=$?
  ERR="$(cat "$STUB_DIR/err")"
}

echo "Jira config"
write_config "'$TOKEN'"
run_lib 'jira_load_config && printf "%s|%s|%s|%s" "$JIRA_SITE" "$JIRA_EMAIL" "$JIRA_TOKEN" "$JIRA_PROJECT"'
assert_eq "single, double and no quotes parse; project defaults to BM" "https://x.atlassian.net|a@b.c|$TOKEN|BM" "$OUT"
write_config "\"$TOKEN\""
run_lib 'jira_config_value JIRA_TOKEN'
assert_eq "double-quoted token kept exact" "$TOKEN" "$OUT"
write_config "$TOKEN"
run_lib 'jira_config_value JIRA_TOKEN'
assert_eq "unquoted token with = and _ kept exact" "$TOKEN" "$OUT"
write_config "'it'\"'\"'s'"
run_lib 'jira_config_value JIRA_TOKEN'
assert_eq "only one pair of quotes is stripped" "it'\"'\"'s" "$OUT"
printf "JIRA_SITE='https://x.atlassian.net'\nJIRA_EMAIL='a@b.c'\nJIRA_TOKEN='old'\n" >"$BOARD_JIRA_CONFIG"
printf "JIRA_TOKEN='new'\nJIRA_PROJECT=ABC\n" >>"$BOARD_JIRA_CONFIG"
run_lib 'jira_load_config && printf "%s|%s" "$JIRA_TOKEN" "$JIRA_PROJECT"'
assert_eq "last assignment wins and JIRA_PROJECT is read" "new|ABC" "$OUT"

rm -f "$BOARD_JIRA_CONFIG"
run_lib 'jira_load_config'
assert_eq "missing file returns 2" "2" "$CODE"
assert_eq "missing file prints one line" "1" "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')"
printf "JIRA_SITE='http://x.atlassian.net'\nJIRA_EMAIL='a@b.c'\nJIRA_TOKEN='t'\n" >"$BOARD_JIRA_CONFIG"
run_lib 'jira_load_config'
assert_eq "http site returns 2" "2" "$CODE"
printf "JIRA_SITE='https://x.atlassian.net/'\nJIRA_EMAIL='a@b.c'\nJIRA_TOKEN='t'\n" >"$BOARD_JIRA_CONFIG"
run_lib 'jira_load_config'
assert_eq "site with a path returns 2" "2" "$CODE"
printf "JIRA_SITE='https://x.atlassian.net'\nJIRA_EMAIL='not-an-email'\nJIRA_TOKEN='t'\n" >"$BOARD_JIRA_CONFIG"
run_lib 'jira_load_config'
assert_eq "bad email returns 2" "2" "$CODE"
printf "JIRA_SITE='https://x.atlassian.net'\nJIRA_EMAIL='a@b.c'\nJIRA_TOKEN=''\n" >"$BOARD_JIRA_CONFIG"
run_lib 'jira_load_config'
assert_eq "empty token returns 2" "2" "$CODE"
printf "JIRA_SITE='https://x.atlassian.net'\nJIRA_EMAIL='a@b.c'\nJIRA_TOKEN='a b'\n" >"$BOARD_JIRA_CONFIG"
run_lib 'jira_load_config'
assert_eq "token with whitespace returns 2" "2" "$CODE"
printf "JIRA_SITE='https://x.atlassian.net'\nJIRA_EMAIL='a@b.c'\n" >"$BOARD_JIRA_CONFIG"
printf "JIRA_TOKEN='t'\nJIRA_PROJECT=bm\n" >>"$BOARD_JIRA_CONFIG"
run_lib 'jira_load_config'
assert_eq "lower-case project returns 2" "2" "$CODE"

echo "Lazy loading"
rm -f "$BOARD_JIRA_CONFIG"
run_lib 'echo sourced'
assert_eq "sourcing the lib does not need the Jira config" "sourced" "$OUT"

echo "jira_api"
write_config "'$TOKEN'"
reset_stub '200|{"ok":true}'
run_lib 'jira_api GET /rest/api/2/myself'
assert_eq "2xx prints the body" '{"ok":true}' "$OUT"
assert_eq "2xx returns 0" "0" "$CODE"
assert_eq "token never in curl argv" "0" "$(grep -c -F "$TOKEN" "$STUB_DIR/curl-argv")"
assert_eq "token is in curl stdin" "1" "$(grep -c -F "$TOKEN" "$STUB_DIR/curl-stdin")"
assert_eq "credentials are a curl user line" 'user = "a@b.c:'"$TOKEN"'"' "$(cat "$STUB_DIR/curl-stdin")"
assert_eq "url is site plus path" "1" "$(grep -c -x 'https://x.atlassian.net/rest/api/2/myself' "$STUB_DIR/curl-argv")"
assert_eq "Accept header sent" "1" "$(grep -c -x 'Accept: application/json' "$STUB_DIR/curl-argv")"
assert_eq "no Content-Type without a body" "0" "$(grep -c 'Content-Type' "$STUB_DIR/curl-argv")"

reset_stub '201|{"key":"BM-1"}'
run_lib 'jira_api POST /rest/api/2/issue "{\"fields\":{\"summary\":\"a \\\"q\\\" b\"}}"'
assert_eq "POST succeeds" "0" "$CODE"
assert_eq "body delivered through the body file" '{"fields":{"summary":"a \"q\" b"}}' "$(cat "$STUB_DIR/curl-body")"
assert_eq "Content-Type sent with a body" "1" "$(grep -c -x 'Content-Type: application/json' "$STUB_DIR/curl-argv")"
bodyarg="$(grep -E '^@' "$STUB_DIR/curl-argv" | head -n 1)"
assert_eq "body file is removed after the call" "no" "$([ -e "${bodyarg#@}" ] && echo yes || echo no)"
assert_eq "body file is not the token holder" "0" "$(grep -c -F "$TOKEN" "$STUB_DIR/curl-body")"

write_config "'a\"b\\c'"
reset_stub '200|{}'
run_lib 'jira_api GET /x'
assert_eq "backslash and quote are escaped in the curl config" 'user = "a@b.c:a\"b\\c"' "$(cat "$STUB_DIR/curl-stdin")"
write_config "'$TOKEN'"

reset_stub '401|{}'
run_lib 'jira_api GET /x'
assert_eq "401 returns 2" "2" "$CODE"
assert_eq "401 message" "board-worker: Jira token rejected (HTTP 401): create a new API token" "$ERR"
reset_stub '404|{"errorMessages":["x"]}'
run_lib 'jira_api GET /x'
assert_eq "404 message uses errorMessages" "board-worker: Jira HTTP 404: x" "$ERR"
assert_eq "404 returns 2" "2" "$CODE"
reset_stub '400|{"errorMessages":[],"errors":{"summary":"required"}}'
run_lib 'jira_api POST /x "{}"'
assert_eq "400 message uses first errors value" "board-worker: Jira HTTP 400: required" "$ERR"
reset_stub '502|not json at all'
run_lib 'jira_api GET /x'
assert_eq "non-JSON body falls back to its text" "board-worker: Jira HTTP 502: not json at all" "$ERR"
reset_stub '204|'
run_lib 'jira_api PUT /x "{}"'
assert_eq "204 returns 0" "0" "$CODE"
assert_eq "204 prints nothing" "" "$OUT"
reset_stub '200|{}'
touch "$STUB_DIR/curl-fail"
run_lib 'jira_api GET /x'
assert_eq "curl failure returns 2" "2" "$CODE"
assert_eq "curl failure prints one line" "board-worker: Jira request failed (curl error)" "$ERR"
assert_eq "token not in any error output" "0" "$(printf '%s' "$ERR" | grep -c -F "$TOKEN")"

reset_stub '200|{}'
run_lib 'jira_api PATCH /x'
assert_eq "bad method returns 2" "2" "$CODE"
run_lib 'jira_api GET x'
assert_eq "path without leading slash returns 2" "2" "$CODE"
run_lib 'jira_api GET "/x y"'
assert_eq "path with space returns 2" "2" "$CODE"
run_lib 'jira_api GET "/x"$'"'\\n'"'"y"'
assert_eq "path with newline returns 2" "2" "$CODE"
assert_eq "curl never called for rejected input" "no" "$([ -e "$STUB_DIR/curl-argv" ] && echo yes || echo no)"

echo "jira_key"
write_config "'$TOKEN'"
run_lib 'jira_key BM-123'
assert_eq "plain key" "BM-123" "$OUT"
for u in https://x.atlassian.net/browse/BM-123 https://x.atlassian.net/browse/BM-123/ \
  'https://x.atlassian.net/browse/BM-123?focusedId=1' 'https://x.atlassian.net/browse/BM-123#c1'; do
  run_lib 'jira_load_config; jira_key "'"$u"'"'
  assert_eq "browse URL $u" "BM-123" "$OUT"
done
run_lib 'jira_key bm-123'
assert_eq "lower-case key rejected" "1" "$CODE"
assert_eq "lower-case key prints nothing" "" "$OUT"
run_lib 'jira_load_config; jira_key https://evil.example.com/browse/BM-123'
assert_eq "foreign host rejected" "1" "$CODE"
assert_eq "foreign host prints nothing" "" "$OUT"
run_lib 'jira_key "BM-1; rm -rf /"'
assert_eq "garbage rejected" "1" "$CODE"
run_lib 'jira_key ""'
assert_eq "empty rejected" "1" "$CODE"

echo "jira_search"
reset_stub '200|{"issues":[{"key":"BM-1"}],"nextPageToken":"tok/1+=","isLast":false}' \
  '200|{"issues":[{"key":"BM-2"}],"isLast":true}'
run_lib 'jira_search "project = BM AND summary ~ \"a b\"" "summary,status"'
assert_eq "search returns 0" "0" "$CODE"
assert_eq "both pages in one array" '["BM-1","BM-2"]' "$(printf '%s' "$OUT" | jq -c '[.[].key]')"
assert_eq "two requests made" "2" "$(grep -c '^https://' "$STUB_DIR/curl-argv")"
assert_eq "JQL url-encoded on both pages" "2" \
  "$(grep -c -F 'jql=project%20%3D%20BM%20AND%20summary%20~%20%22a%20b%22&fields=summary%2Cstatus&maxResults=100' \
    "$STUB_DIR/curl-argv")"
assert_eq "second page sends the encoded token" "1" "$(grep -c -F '&nextPageToken=tok%2F1%2B%3D' "$STUB_DIR/curl-argv")"
reset_stub '200|{"issues":[{"key":"BM-9"}],"isLast":true}'
run_lib 'jira_search "a" "b"'
assert_eq "single page" '["BM-9"]' "$(printf '%s' "$OUT" | jq -c '[.[].key]')"
reset_stub '200|{"issues":[]}'
run_lib 'jira_search "a" "b"'
assert_eq "empty result is an empty array" "[]" "$(printf '%s' "$OUT" | jq -c .)"
reset_stub '404|{"errorMessages":["bad jql"]}'
run_lib 'jira_search "a" "b"'
assert_eq "search error returns 2" "2" "$CODE"

echo "jira_board_items"
printf "JIRA_SITE='https://x.atlassian.net'\nJIRA_EMAIL='a@b.c'\n" >"$BOARD_JIRA_CONFIG"
printf "JIRA_TOKEN='t'\nJIRA_PROJECT=ABC\n" >>"$BOARD_JIRA_CONFIG"
reset_stub '200|{"issues":[{"key":"ABC-1"}],"isLast":true}'
run_lib 'jira_board_items'
assert_eq "board items returns the issues" '["ABC-1"]' "$(printf '%s' "$OUT" | jq -c '[.[].key]')"
assert_eq "board JQL uses the configured project" "1" \
  "$(grep -c -F 'jql=project%20%3D%20ABC%20AND%20statusCategory%20%21%3D%20Done%20ORDER%20BY%20created%20ASC' \
    "$STUB_DIR/curl-argv")"
assert_eq "board fields requested" "1" \
  "$(grep -c -F 'fields=summary%2Cstatus%2Cpriority%2Ccomponents%2Clabels%2Cupdated%2Ccreated' "$STUB_DIR/curl-argv")"

if [ "$FAILS" -eq 0 ]; then echo "All Jira lib tests passed"; fi
exit "$FAILS"
