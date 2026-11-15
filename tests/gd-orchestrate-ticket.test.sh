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
# shellcheck disable=SC2016 # the stub body must keep its $(...) unexpanded
printf '#!/usr/bin/env bash\ncat "%s/ready"\n[ "$(jq .ready "%s/ready")" = true ]\n' "$STUB_DIR" "$STUB_DIR" \
  >"$STUB_DIR/board/board-check-ready"
# shellcheck disable=SC2016 # the stub body must keep its $1 unexpanded
printf '#!/usr/bin/env bash\nif [ "$1" = blockers ]; then cat "%s/blockers"; else cat "%s/ticket"; fi\n' \
  "$STUB_DIR" "$STUB_DIR" >"$STUB_DIR/board/board-ticket-cli"
echo '[]' >"$STUB_DIR/blockers"
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

echo '{"components":["api"]}' >"$STUB_DIR/ticket"
echo '{"ready":true,"missing":[]}' >"$STUB_DIR/ready"
echo '[{"key":"BM-9","status":"Backlog","finished":false}]' >"$STUB_DIR/blockers"
gate
assert_eq "gate: unfinished blocker exits 1" 1 "$CODE"
assert_eq "gate: unfinished blocker is listed" "Blocker BM-9" "$(jq -r '.missing[0]' <<<"$OUT")"

echo '[{"key":"BM-9","status":"Done","finished":true}]' >"$STUB_DIR/blockers"
gate
assert_eq "gate: finished blocker does not ask" 0 "$CODE"

# ticket-record-stats: board-run-stats and board-ticket-cli are stubs; the CLI keeps its runs in $STUB_DIR/runs.json.
REC="$REPO/skills/gd-orchestrate-ticket/scripts/ticket-record-stats"
mkdir -p "$STUB_DIR/rec"
cat >"$STUB_DIR/rec/board-run-stats" <<STUB
#!/usr/bin/env bash
# Prints \$STUB_DIR/stats-<since> (or codex-stats for --provider codex) for the --since value given.
case " \$* " in *" --provider codex "*) cat "$STUB_DIR/codex-stats"; exit 0 ;; esac
cat "$STUB_DIR/stats-\$3"
STUB
cat >"$STUB_DIR/rec/board-ticket-cli" <<STUB
#!/usr/bin/env bash
f="$STUB_DIR/runs.json"
case "\$1" in
  runs) cat "\$f" ;;
  *)
    if [ "\$3" = --model ]; then
      jq -c --arg m "\$4" '. + [{provider: "codex", startedAt: null, models: [{label: \$m}]}]' "\$f" >"\$f.new"
    else
      jq -c -s '.[0] + [.[1] | {provider, startedAt, minutes, costUsd, models}]' "\$f" - >"\$f.new"
    fi
    mv "\$f.new" "\$f"
    ;;
esac
STUB
chmod +x "$STUB_DIR/rec/"*

# Writes a fake stats file for a --since value: minutes, tokens, cost for one claude model.
set_stats() {
  printf '{"provider":"claude","startedAt":"%s","minutes":%s,"tokens":%s,"costUsd":%s,"models":[{"label":"claude:m",
"input":%s,"output":0,"cacheRead":0,"cacheWrite":0,"costUsd":%s}],"markdown":"x"}\n' "$1" "$2" "$3" "$4" "$3" "$4" \
    >"$STUB_DIR/stats-$1"
}

# Runs ticket-record-stats; stdout goes to OUT, the exit code to CODE.
# shellcheck disable=SC2034 # OUT and CODE are read by the assertions
rec() {
  OUT="$(BOARD_SCRIPTS="$STUB_DIR/rec" bash "$REC" BM-1 --worktree "$STUB_DIR" "$@" 2>&1)"
  CODE=$?
}

set_stats 2026-01-01T00:00:00Z 100 1000 4.00
set_stats 2026-01-01T01:00:00Z 40 400 1.50
echo '[]' >"$STUB_DIR/runs.json"
rec --since 2026-01-01T00:00:00Z --model codex:gpt
assert_eq "record: session and worker exit 0" 0 "$CODE"
assert_eq "record: two runs written" 2 "$(jq length "$STUB_DIR/runs.json")"
rec --since 2026-01-01T00:00:00Z --model codex:gpt
assert_eq "record: rerun adds nothing" 2 "$(jq length "$STUB_DIR/runs.json")"

echo '[]' >"$STUB_DIR/runs.json"
rec --since 2026-01-01T00:00:00Z --end 2026-01-01T01:00:00Z
assert_eq "record: window subtracts minutes" 60 "$(jq -r '.[0].minutes' "$STUB_DIR/runs.json")"
assert_eq "record: window subtracts cost" 2.5 "$(jq -r '.[0].costUsd' "$STUB_DIR/runs.json")"
assert_eq "record: window run is written" 1 "$(jq length "$STUB_DIR/runs.json")"

printf '%s\n' '{"provider":"codex","startedAt":"2026-01-01T00:05:00Z","minutes":12,"tokens":500,"costUsd":0,' \
  '"models":[{"label":"codex:a"},{"label":"codex:b"}],"markdown":"x"}' | tr -d '\n' >"$STUB_DIR/codex-stats"
echo '[]' >"$STUB_DIR/runs.json"
rec --since 2026-01-01T00:00:00Z --codex-worktree /wt/codex
assert_eq "record: codex worker exits 0" 0 "$CODE"
assert_eq "record: codex worker and session written" "claude codex" \
  "$(jq -r '[.[].provider] | sort | join(" ")' "$STUB_DIR/runs.json")"
rec --since 2026-01-01T00:00:00Z --codex-worktree /wt/codex
assert_eq "record: codex rerun adds nothing" 2 "$(jq length "$STUB_DIR/runs.json")"
printf '{"provider":"codex","startedAt":null,"minutes":0,"tokens":0,"models":[]}\n' >"$STUB_DIR/codex-stats"
rec --since 2026-01-01T00:00:00Z --codex-worktree /wt/nologs
assert_eq "record: codex worker without logs exits 1" 1 "$CODE"

rec
assert_eq "record: missing --since exits 2" 2 "$CODE"

if [ "$FAILS" -eq 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
