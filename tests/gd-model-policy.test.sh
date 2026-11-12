#!/usr/bin/env bash
# Tests tier resolution against controlled tables without calling any external service.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVE="$REPO/skills/gd-model-policy/scripts/resolve-model"
FIXTURES="$(mktemp -d)"
FAILS=0

# Removes temporary model tables at exit.
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() { rm -rf "$FIXTURES"; }
trap cleanup EXIT

# Records a failure when actual output differs from the expected value.
assert_eq() {
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1 (expected '$2', got '$3')"
    FAILS=$((FAILS + 1))
  else
    echo "ok: $1"
  fi
}

cat >"$FIXTURES/models.md" <<'TABLE'
# Fixture

| Provider | Low | Mid | High | Ultra |
|---|---|---|---|---|
| Claude | Haiku 5.5 | Sonnet 5.5 | Opus 5.5 | Fable 5.2 |
| Codex | Luna, Terra | Sol | none | Astra |
| Gemini | 3.5 Flash-Lite, 3.6 Flash | 3.8 Flash | none | none |
| DeepSeek | V4.1 Flash | V4 Pro | none | none |
| Kimi | K2.6 | K2.7 Code | none | none |

## Providers

| Quota provider | Agent CLI | Table rows |
|---|---|---|
| claude | claude | Claude |
| codex | codex | Codex |
| antigravity | agy | Gemini |
| opencodeGo | opencode | DeepSeek, Kimi |

## Launch IDs

| Provider | Model | Launch id |
|---|---|---|
| Claude | Haiku 5.5 | `claude-haiku-5-5` |
| Claude | Sonnet 5.5 | `claude-sonnet-5-5` |
| Claude | Opus 5.5 | `claude-opus-5-5` |
| Claude | Fable 5.2 | `claude-fable-5-2` |
| Codex | Luna | `gpt-6-luna` |
| Codex | Terra | `gpt-6.1-terra` |
| Codex | Sol | `gpt-6.1-sol` |
| Codex | Astra | `gpt-6-astra` |
| Gemini | 3.5 Flash-Lite | none |
| Gemini | 3.6 Flash | none |
| Gemini | 3.8 Flash | `gemini-3.8-flash-medium` |
| DeepSeek | V4.1 Flash | `opencode-go/deepseek-v4.1-flash` |
| DeepSeek | V4 Pro | `opencode-go/deepseek-v4-pro` |
| Kimi | K2.6 | none |
| Kimi | K2.7 Code | `opencode-go/kimi-k2.7-code` |
TABLE

# Captures stdout and exit status for a resolver call with the selected fixture.
run() {
  OUT="$(MODELS_FILE="$TABLE" bash "$RESOLVE" "$@" 2>"$FIXTURES/stderr")"
  CODE=$?
}

TABLE="$FIXTURES/models.md"
run --provider claude --tier Mid
assert_eq "Mid resolution exits 0" 0 "$CODE"
expected='{"provider":"claude","agent":"claude","tier":"Mid","model":"Sonnet 5.5",'
expected+='"launchId":"claude-sonnet-5-5"}'
assert_eq "Mid JSON is compact and ordered" "$expected" "$OUT"

run --provider codex --tier Low
assert_eq "Low uses the first model in a cell" '0 gpt-6-luna' "$CODE $(jq -r .launchId <<<"$OUT")"

# A later model in the same cell remains usable when the first has no launch id.
# shellcheck disable=SC2016 # the backticks are literal table text, not a command substitution
sed 's/| Codex | Luna | `gpt-6-luna` |/| Codex | Luna | none |/' \
  "$FIXTURES/models.md" >"$FIXTURES/same-cell-fallback.md"
TABLE="$FIXTURES/same-cell-fallback.md"
run --provider codex --tier Low
assert_eq "same cell skips first model without launch id" '0 Terra gpt-6.1-terra' \
  "$CODE $(jq -r '.model + " " + .launchId' <<<"$OUT")"
TABLE="$FIXTURES/models.md"

run --provider antigravity --tier Low
assert_eq "models with no launch ids exit 1" 1 "$CODE"
assert_eq "unavailable models produce no stdout" '' "$OUT"

run --provider opencodeGo --tier Mid
assert_eq "first provider row wins and maps agent" '0 opencode opencode-go/deepseek-v4-pro' \
  "$CODE $(jq -r '.agent + " " + .launchId' <<<"$OUT")"

sed 's/| DeepSeek | V4.1 Flash | V4 Pro |/| DeepSeek | V4.1 Flash | none |/' \
  "$TABLE" >"$FIXTURES/fallback.md"
TABLE="$FIXTURES/fallback.md"
run --provider opencodeGo --tier Mid
assert_eq "second row is tried when first is none" '0 opencode-go/kimi-k2.7-code' \
  "$CODE $(jq -r .launchId <<<"$OUT")"

sed 's/| Codex | Luna, Terra | Sol |/| Codex | Luna, Terra | Sol (proposed), Terra |/' \
  "$FIXTURES/models.md" >"$FIXTURES/proposed.md"
TABLE="$FIXTURES/proposed.md"
run --provider codex --tier Mid
assert_eq "proposed model is skipped even with a launch id" '0 gpt-6.1-terra' \
  "$CODE $(jq -r .launchId <<<"$OUT")"

TABLE="$FIXTURES/models.md"
run --provider codex --tier High --allow-high
assert_eq "approved empty High cell exits 1" 1 "$CODE"
run --provider codex --tier High
assert_eq "High gate precedes an empty cell" 3 "$CODE"
run --provider claude --tier High
assert_eq "High needs approval" 3 "$CODE"
assert_eq "gate produces no stdout" '' "$OUT"
run --provider claude --tier High --allow-high
assert_eq "approved High resolves" '0 claude-opus-5-5' "$CODE $(jq -r .launchId <<<"$OUT")"
run --provider claude --tier Ultra
assert_eq "Ultra needs approval" 3 "$CODE"
run --provider claude --tier Ultra --allow-high
assert_eq "approved Ultra resolves" '0 claude-fable-5-2' "$CODE $(jq -r .launchId <<<"$OUT")"

run --provider codex --tier workhorse
assert_eq "unknown tier exits 2" 2 "$CODE"
run --provider gemini --tier Mid
assert_eq "unknown provider exits 2" 2 "$CODE"
run --provider codex
assert_eq "missing tier exits 2" 2 "$CODE"
run --provider
assert_eq "missing flag value exits 2" 2 "$CODE"
run --tier Mid
assert_eq "missing provider exits 2" 2 "$CODE"
run --provider codex --tier
assert_eq "missing tier value exits 2" 2 "$CODE"
run --provider codex --tier Mid --bogus
assert_eq "unknown flag exits 2" 2 "$CODE"
run --provider gemini --tier High
assert_eq "bad arguments precede the gate" 2 "$CODE"

TABLE=/nonexistent
run --provider codex --tier Mid
assert_eq "unreadable table exits 2" 2 "$CODE"
run --provider codex --tier High
assert_eq "gate precedes reading an unreadable table" 3 "$CODE"

sed '/^## Launch IDs/,$d' "$FIXTURES/models.md" >"$FIXTURES/no-launch.md"
TABLE="$FIXTURES/no-launch.md"
run --provider claude --tier Mid
assert_eq "missing launch table exits 2" 2 "$CODE"
assert_eq "missing table error explains the failure" true \
  "$(test -s "$FIXTURES/stderr" && echo true || echo false)"

TABLE="$REPO/skills/gd-model-policy/models.md"
for provider in claude codex antigravity opencodeGo; do
  run --provider "$provider" --tier Mid
  assert_eq "real table resolves $provider Mid" 0 "$CODE"
  assert_eq "real table gives $provider a launch id" true \
    "$(jq '.launchId | type == "string" and length > 0 and . != "none"' <<<"$OUT")"
done
OUT="$(unset MODELS_FILE; bash "$RESOLVE" --provider codex --tier Mid 2>"$FIXTURES/stderr")"
CODE=$?
assert_eq "default table is relative to the script" '0 gpt-6.1-sol' "$CODE $(jq -r .launchId <<<"$OUT")"

[ "$FAILS" -eq 0 ] && echo "All model policy tests passed"
exit "$FAILS"
