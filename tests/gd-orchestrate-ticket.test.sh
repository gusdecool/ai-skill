#!/usr/bin/env bash
# Tests for gd-orchestrate-ticket's ticket-repos script, with orca replaced by the stub in tests/stubs.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/skills/gd-orchestrate-ticket/scripts/ticket-repos"
export STUB_DIR
STUB_DIR="$(mktemp -d)"
export PATH="$REPO/tests/stubs:$PATH"
export ORCHESTRATE_TICKET_REPOS="$STUB_DIR/none"
FAILS=0

# Removes the stub output directory.
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() { rm -rf "$STUB_DIR"; }
trap cleanup EXIT

# Records a failure when two values differ.
assert_eq() {
  if [ "$2" != "$3" ]; then echo "FAIL: $1 (expected '$2', got '$3')"; FAILS=$((FAILS + 1)); else echo "ok: $1"; fi
}

# Writes the fake `orca repo list --json` output with the given display names (one repo per argument).
set_repos() {
  local names="" n i=0
  for n in "$@"; do
    i=$((i + 1))
    names+="{\"id\":\"id-$i\",\"displayName\":\"$n\",\"path\":\"/r/$n\"},"
  done
  printf '{"ok":true,"result":{"repos":[%s]}}\n' "${names%,}" >"$STUB_DIR/orca-repos"
}

# Runs ticket-repos; stdout goes to OUT, the exit code to CODE.
# shellcheck disable=SC2034 # OUT and CODE are read by the assertions
run() {
  OUT="$(bash "$SCRIPT" "$@" 2>/dev/null)"
  CODE=$?
}

set_repos api bm-app
run api
assert_eq "match exits 0" 0 "$CODE"
assert_eq "match repo id" "id-1" "$(jq -r '.[0].repoId' <<<"$OUT")"
run BM-App
assert_eq "case-insensitive match" "id-2" "$(jq -r '.[0].repoId' <<<"$OUT")"
run api ghost
assert_eq "unmatched exits 3" 3 "$CODE"
assert_eq "unmatched keeps component" "ghost" "$(jq -r '.[1].component' <<<"$OUT")"
assert_eq "unmatched repoId is null" "null" "$(jq -r '.[1].repoId' <<<"$OUT")"
assert_eq "matched one still resolved" "id-1" "$(jq -r '.[0].repoId' <<<"$OUT")"

set_repos api API
run api
assert_eq "ambiguous name exits 3" 3 "$CODE"
assert_eq "ambiguous repoId is null" "null" "$(jq -r '.[0].repoId' <<<"$OUT")"

set_repos api bm-app
printf '# comment\n\nbackend=api\n' >"$STUB_DIR/overrides"
ORCHESTRATE_TICKET_REPOS="$STUB_DIR/overrides" run backend
assert_eq "override maps component to repo" "id-1" "$(jq -r '.[0].repoId' <<<"$OUT")"

run
assert_eq "no arguments exits 2" 2 "$CODE"

# ticket-gate: board scripts are replaced by stubs that print $STUB_DIR/ready and $STUB_DIR/ticket.
GATE="$REPO/skills/gd-orchestrate-ticket/scripts/ticket-gate"
mkdir -p "$STUB_DIR/board"
printf '#!/usr/bin/env bash\ncat "%s/ready"\n[ "$(jq .ready "%s/ready")" = true ]\n' "$STUB_DIR" "$STUB_DIR" \
  >"$STUB_DIR/board/board-check-ready"
printf '#!/usr/bin/env bash\ncat "%s/ticket"\n' "$STUB_DIR" >"$STUB_DIR/board/board-ticket-cli"
chmod +x "$STUB_DIR/board/"*

# Runs ticket-gate; stdout goes to OUT, the exit code to CODE.
# shellcheck disable=SC2034 # OUT and CODE are read by the assertions
gate() {
  OUT="$(BOARD_SCRIPTS="$STUB_DIR/board" bash "$GATE" BM-1 2>/dev/null)"
  CODE=$?
}

set_repos api
echo '{"ready":true,"missing":[]}' >"$STUB_DIR/ready"
echo '{"components":["api"]}' >"$STUB_DIR/ticket"
gate
assert_eq "gate: ready and mapped exits 0" 0 "$CODE"
assert_eq "gate: ready and mapped does not ask" false "$(jq .ask <<<"$OUT")"

echo '{"ready":false,"missing":["Open questions"]}' >"$STUB_DIR/ready"
gate
assert_eq "gate: open questions exits 1" 1 "$CODE"
assert_eq "gate: open questions are listed" "Open questions" "$(jq -r '.missing[0]' <<<"$OUT")"

echo '{"ready":true,"missing":[]}' >"$STUB_DIR/ready"
echo '{"components":["ghost"]}' >"$STUB_DIR/ticket"
gate
assert_eq "gate: unmatched component exits 1" 1 "$CODE"
assert_eq "gate: unmatched component is listed" "Repo mapping" "$(jq -r '.missing[0]' <<<"$OUT")"

if [ "$FAILS" -eq 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
