#!/usr/bin/env bash
# Tests for skills/gusdecool-load-balancer/scripts/pick-provider, against a stub orca and a fixed clock.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PICK="$REPO/skills/gusdecool-load-balancer/scripts/pick-provider"
STUB_DIR="$(mktemp -d)"
FAILS=0
NOW=1000000000000
MIN=60000

# Removes the stub output directory.
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() { rm -rf "$STUB_DIR"; }
trap cleanup EXIT

# Records a failure when two values differ.
assert_eq() {
  if [ "$2" != "$3" ]; then echo "FAIL: $1 (expected '$2', got '$3')"; FAILS=$((FAILS + 1)); else echo "ok: $1"; fi
}

cat >"$STUB_DIR/orca" <<'STUB'
#!/usr/bin/env bash
# Test stub for orca: "account list" prints $ACCOUNTS_FIXTURE.
[ "$1 $2" = "account list" ] && cat "$ACCOUNTS_FIXTURE"
STUB
chmod +x "$STUB_DIR/orca"

# Prints one quota window as JSON. Args: usedPercent, windowMinutes, minutes left.
win() { echo "{\"usedPercent\":$1,\"windowMinutes\":$2,\"resetsAt\":$((NOW + $3 * MIN))}"; }

# The BM-55 case: claude weekly 79 (reserved), codex 62 / 58, opencodeGo 0 / 0 / 0, antigravity weekly 6.
# Codex scores about 126 / 210 and OpenCode Go about 294, so choosing by hand "the first one under its cutoff" picks
# codex, which is wrong.
cat >"$STUB_DIR/bm55.json" <<JSON
{"result":{"rateLimits":{
  "claude":{"status":"ok","session":$(win 20 300 120),"weekly":$(win 79 10080 6000)},
  "codex":{"status":"ok","session":$(win 62 300 90),"weekly":$(win 58 10080 2040)},
  "antigravity":{"status":"ok","session":null,"weekly":$(win 6 10080 6000)},
  "opencodeGo":{"status":"ok","session":$(win 0 300 240),"weekly":$(win 0 10080 9600),"monthly":$(win 0 43200 14700)}}}}
JSON

# Runs pick-provider against a fixture, storing stdout in OUT and the exit code in CODE.
run() {
  OUT="$(HOME="$STUB_DIR/home" ACCOUNTS_FIXTURE="$1" ORCA_BIN="$STUB_DIR/orca" NOW_MS=$NOW \
    bash "$PICK" "${@:2}" 2>/dev/null)"
  CODE=$?
}

run "$STUB_DIR/bm55.json" --reserved claude
assert_eq "BM-55 chooses opencodeGo" "opencodeGo" "$(jq -r .chosen <<<"$OUT")"
assert_eq "BM-55 exits 0" "0" "$CODE"
assert_eq "claude weekly 79 is skipped as reserved" "weekly 79 >= 75 (reserved)" \
  "$(jq -r '.providers[] | select(.provider == "claude") | .reason' <<<"$OUT")"
assert_eq "codex is eligible but scores below opencodeGo" "true" \
  "$(jq '([.providers[] | select(.provider == "codex")][0].score)
    < ([.providers[] | select(.provider == "opencodeGo")][0].score)' <<<"$OUT")"
assert_eq "the table has a row per provider" "6" "$(jq -r .table <<<"$OUT" | wc -l | tr -d ' ')"
assert_eq "the table marks the chosen row" "1" "$(jq -r .table <<<"$OUT" | grep -c '| chosen |')"

run "$STUB_DIR/bm55.json" --reserved none
assert_eq "without a reserved provider claude weekly 79 is under 95" "false" \
  "$(jq '[.providers[] | select(.provider == "claude")][0].skipped' <<<"$OUT")"

# Parallel tasks: each --bump adds 5 session points to that provider.
run "$STUB_DIR/bm55.json" --reserved claude --bump opencodeGo --bump opencodeGo
assert_eq "two bumps move opencodeGo session to 10" "10" \
  "$(jq '[.providers[] | select(.provider == "opencodeGo")][0].windows[0].usedPercent' <<<"$OUT")"

run "$STUB_DIR/bm55.json" --reserved claude --exclude opencodeGo
assert_eq "an excluded provider is skipped, the next best wins" "codex excluded" \
  "$(jq -r '.chosen' <<<"$OUT") $(jq -r '[.providers[] | select(.provider == "opencodeGo")][0].reason' <<<"$OUT")"

# timeLeftFraction never goes below 0.05: a window about to reset does not give an unbounded score.
jq '.result.rateLimits.codex.session.resetsAt = 1000000001000' "$STUB_DIR/bm55.json" >"$STUB_DIR/floor.json"
run "$STUB_DIR/floor.json" --reserved claude
assert_eq "the time fraction has a floor of 0.05" "0.05" \
  "$(jq '[.providers[] | select(.provider == "codex")][0].windows[0].timeLeftFraction' <<<"$OUT")"

# Scores within 5 percent tie and go to the reserved provider.
cat >"$STUB_DIR/tie.json" <<JSON
{"result":{"rateLimits":{
  "claude":{"status":"ok","session":$(win 50 300 150),"weekly":$(win 10 10080 5040)},
  "codex":{"status":"ok","session":$(win 50 300 150),"weekly":$(win 11 10080 5040)}}}}
JSON
run "$STUB_DIR/tie.json" --reserved claude
assert_eq "a tie goes to the reserved provider" "claude" "$(jq -r .chosen <<<"$OUT")"

# Nothing eligible exits 1 and reports the earliest reset.
jq '.result.rateLimits |= with_entries(.value.status = "error")' "$STUB_DIR/bm55.json" >"$STUB_DIR/none.json"
run "$STUB_DIR/none.json" --reserved claude
assert_eq "no eligible provider exits 1" "1 null" "$CODE $(jq -r .chosen <<<"$OUT")"

# The orchestrator check looks only at the reserved provider with 90 in every window.
run "$STUB_DIR/bm55.json" --reserved claude --orchestrator
assert_eq "orchestrator mode picks claude at weekly 79" "claude" "$(jq -r .chosen <<<"$OUT")"

# A missing --reserved is a usage error, so the caller cannot skip naming its provider.
run "$STUB_DIR/bm55.json"
assert_eq "missing --reserved exits 2" "2" "$CODE"

# Config: user cutoffs (fractions of used quota, applied to every window).
cfg() { echo "$1" >"$STUB_DIR/cfg.json"; }
reason() { jq -r --arg p "$1" '.providers[] | select(.provider == $p) | .reason' <<<"$OUT"; }

cfg '{"main_orchestrator":"claude","main_cutoff":0.15}'
run "$STUB_DIR/bm55.json" --reserved claude --config "$STUB_DIR/cfg.json"
assert_eq "main_cutoff 0.15 skips claude at session 20" "session 20 >= 15, weekly 79 >= 15 (config)" "$(reason claude)"

cfg '{"main_orchestrator":"claude","main_cutoff":0.9}'
run "$STUB_DIR/bm55.json" --reserved claude --config "$STUB_DIR/cfg.json"
assert_eq "main_cutoff 0.9 lifts the reserved 75 cutoff" "null" "$(reason claude)"

cfg '{"main_orchestrator":"claude","main_cutoff":0.5}'
run "$STUB_DIR/bm55.json" --reserved claude --orchestrator --config "$STUB_DIR/cfg.json"
assert_eq "main_cutoff replaces the 90 pause check" "null" "$(jq -r .chosen <<<"$OUT")"

run "$STUB_DIR/bm55.json" --reserved codex --config "$STUB_DIR/cfg.json"
assert_eq "mismatched main_orchestrator warns" "1" "$(jq '.warnings | length' <<<"$OUT")"
assert_eq "mismatched main_orchestrator leaves claude on the defaults" "false" \
  "$(jq '[.providers[] | select(.provider == "claude")][0].skipped' <<<"$OUT")"

cfg '{"workers":[{"provider":"opencodeGo","cutoff":0},{"provider":"codex","cutoff":0.6,"reason":"x"}]}'
run "$STUB_DIR/bm55.json" --reserved claude --config "$STUB_DIR/cfg.json"
assert_eq "worker cutoff 0 skips even an unused provider" "session 0 >= 0, weekly 0 >= 0, monthly 0 >= 0 (config)" \
  "$(reason opencodeGo)"
assert_eq "worker cutoff 0.6 skips codex session 62" "session 62 >= 60 (config)" "$(reason codex)"
assert_eq "an unlisted worker keeps the defaults" "null" "$(reason antigravity)"

cfg '{"workers":[{"provider":"claude","cutoff":0.07}]}'
run "$STUB_DIR/bm55.json" --reserved none --config "$STUB_DIR/cfg.json"
assert_eq "a fraction like 0.07 becomes 7 exactly" "session 20 >= 7, weekly 79 >= 7 (config)" "$(reason claude)"

run "$STUB_DIR/bm55.json" --reserved claude
assert_eq "no default config file means defaults" "0" "$CODE"

mkdir -p "$STUB_DIR/home/.config/load-balancer"
echo '{"workers":[{"provider":"codex","cutoff":0.5}]}' >"$STUB_DIR/home/.config/load-balancer/config.json"
run "$STUB_DIR/bm55.json" --reserved claude
assert_eq "the default path config is read" "session 62 >= 50, weekly 58 >= 50 (config)" "$(reason codex)"
rm -r "${STUB_DIR:?}/home"

for bad in '{not json' '{"workers":[{"provider":"opencode","cutoff":0.5}]}' \
  '{"workers":[{"provider":"codex","cutoff":50}]}' '{"main_orchestrator":"claude"}' '{"workers":{}}'; do
  cfg "$bad"
  run "$STUB_DIR/bm55.json" --reserved claude --config "$STUB_DIR/cfg.json"
  assert_eq "bad config exits 2: $bad" "2" "$CODE"
done
run "$STUB_DIR/bm55.json" --reserved claude --config "$STUB_DIR/missing.json"
assert_eq "an explicit missing config path exits 2" "2" "$CODE"

[ "$FAILS" -eq 0 ] && echo "Load balancer tests passed"
exit "$FAILS"
