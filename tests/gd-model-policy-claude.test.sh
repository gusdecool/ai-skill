#!/usr/bin/env bash
# Exercises Claude model decisions and adapter installation in isolated directories.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO/skills/gd-model-policy"
GUARD="$SKILL/adapters/claude/hooks/guard-subagent-model"
INSTALL="$SKILL/scripts/install-claude-adapter"
TMP="$(mktemp -d)"
FAILS=0
export CLAUDE_HOME="$TMP/home"
export CLAUDE_AGENTS_DIR="$TMP/agents"
mkdir -p "$CLAUDE_AGENTS_DIR" "$TMP/project/.claude/agents"

# Removes all isolated fixtures on exit.
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Counts mismatched assertions while allowing later cases to run.
assert_eq() {
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1 (expected '$2', got '$3')"
    FAILS=$((FAILS + 1))
  else
    echo "ok: $1"
  fi
}

# Invokes the real guard and verifies its exit status and decision envelope.
hook() {
  OUT="$(bash "$GUARD" <<<"$2" 2>"$TMP/stderr")"
  CODE=$?
  assert_eq "$1 exits zero" 0 "$CODE"
  if [ "$3" = allow ]; then
    assert_eq "$1 prints nothing" '' "$OUT"
  else
    assert_eq "$1 decision" "$3" "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$OUT")"
    assert_eq "$1 event" PreToolUse "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$OUT")"
  fi
}

# Writes a minimal definition with a pinned model.
pin() { printf '%s\n' '---' "model: $2" '---' >"$1"; }

# Builds an agent hook payload without interpolating JSON manually.
payload() {
  jq -nc --arg type "$1" --arg model "$2" --arg cwd "$TMP/project" \
    '{tool_name:"Agent",cwd:$cwd,tool_input:({subagent_type:$type} +
      (if $model == "" then {} else {model:$model} end))}'
}

pin "$CLAUDE_AGENTS_DIR/pinned.md" haiku
hook 'explicit low' "$(payload unknown haiku)" allow
hook 'explicit mid' "$(payload unknown sonnet)" allow
hook 'definition low' "$(payload pinned '')" allow
pin "$CLAUDE_AGENTS_DIR/pinned.md" sonnet
hook 'definition mid' "$(payload pinned '')" allow
hook 'plugin agent without model' "$(payload superpowers:code-reviewer '')" deny
assert_eq 'plugin denial explains explicit model and skill' true \
  "$(jq '.hookSpecificOutput.permissionDecisionReason | contains("model") and
    contains("sonnet") and contains("haiku") and contains("gd-model-policy")' <<<"$OUT")"
hook 'plugin agent with explicit model' "$(payload superpowers:code-reviewer sonnet)" allow
hook 'relative traversal agent' "$(payload ../x '')" deny
hook 'absolute path agent' "$(payload /etc/passwd '')" deny

# A restricted executable path reproduces missing jq without touching the host installation.
mkdir -p "$TMP/no-jq"
for tool in bash cat awk; do ln -sf "$(command -v "$tool")" "$TMP/no-jq/$tool"; done
no_jq_payload="$(payload unknown sonnet)"
OUT="$(PATH="$TMP/no-jq" bash "$GUARD" <<<"$no_jq_payload" 2>"$TMP/stderr")"
CODE=$?
assert_eq 'missing jq exits zero' 0 "$CODE"
assert_eq 'missing jq denies dispatch' deny "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$OUT")"
assert_eq 'missing jq keeps event envelope' PreToolUse "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$OUT")"
assert_eq 'missing jq explains required dependency and guard' true \
  "$(jq '.hookSpecificOutput.permissionDecisionReason | contains("jq") and
    contains("required") and contains("gd-model-policy")' <<<"$OUT")"

hook 'missing definition' "$(payload unknown '')" deny
assert_eq 'deny explains inheritance and skill' true \
  "$(jq '.hookSpecificOutput.permissionDecisionReason | contains("inherit") and
    contains("gd-model-policy")' <<<"$OUT")"
for model in opus fable inherit unknown; do
  hook "explicit $model" "$(payload pinned "$model")" ask
  pin "$CLAUDE_AGENTS_DIR/pinned.md" "$model"
  hook "definition $model" "$(payload pinned '')" ask
done
hook 'Bash untouched' '{"tool_name":"Bash","tool_input":{"command":"true"}}' allow
hook 'Task guarded' '{"tool_name":"Task","tool_input":{"model":"opus"}}' ask
hook 'missing type' '{"tool_name":"Agent","tool_input":{}}' deny
hook 'uninstalled implementer denied' "$(payload sdd-implementer '')" deny
# Shipped definitions are tested directly without ever reading the real Claude directory.
CLAUDE_AGENTS_DIR="$SKILL/adapters/claude/agents" hook 'shipped implementer' \
  "$(payload sdd-implementer '')" allow
CLAUDE_AGENTS_DIR="$SKILL/adapters/claude/agents" hook 'shipped final reviewer' \
  "$(payload sdd-final-reviewer '')" ask
CLAUDE_AGENTS_DIR="$SKILL/adapters/claude/agents" hook 'explicit overrides low definition' \
  "$(payload sdd-implementer opus)" ask
hook 'fork always asks' "$(payload fork sonnet)" ask
pin "$TMP/project/.claude/agents/x.md" sonnet
pin "$CLAUDE_AGENTS_DIR/x.md" opus
hook 'project definition wins' "$(payload x '')" allow
hook 'explicit overrides project definition' "$(payload x haiku)" allow
pin "$CLAUDE_AGENTS_DIR/no-pin.md" sonnet
printf '%s\n' '---' 'description: no project pin' '---' 'model: sonnet' \
  >"$TMP/project/.claude/agents/no-pin.md"
hook 'project without frontmatter pin prevents global fallback' "$(payload no-pin '')" deny
hook 'unknown input fields do not pin model' '{"tool_name":"Agent","tool_input":{"unknown":"sonnet"}}' deny
for bad in 'not json' '' '{"tool_name":"Agent"} {"tool_name":"Bash"}' '[]' 'null' \
  '{"tool_name":"Agent","tool_input":[]}' \
  '{"tool_name":"Agent","tool_input":{"model":12}}' '{}'; do
  hook "malformed payload $bad" "$bad" deny
done

# Runs the installer with isolated paths and captures its result.
install_adapter() {
  OUT="$(bash "$INSTALL" "$@" 2>"$TMP/stderr")"
  CODE=$?
}

mkdir -p "$CLAUDE_HOME"
printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[]}]},"other":true}' \
  >"$CLAUDE_HOME/settings.json"
cp "$CLAUDE_HOME/settings.json" "$TMP/original.json"
install_adapter
assert_eq 'install succeeds' 0 "$CODE"
for name in sdd-implementer sdd-implementer-sonnet sdd-task-reviewer sdd-final-reviewer; do
  assert_eq "$name absolute link" "$SKILL/adapters/claude/agents/$name.md" \
    "$(readlink "$CLAUDE_HOME/agents/$name.md")"
done
assert_eq 'one matching hook with absolute command' 1 \
  "$(jq --arg guard "$GUARD" '[.hooks.PreToolUse[] | select(.matcher == "Agent|Task" and
    .hooks == [{type:"command",command:$guard}])] | length' "$CLAUDE_HOME/settings.json")"
assert_eq 'existing entry survives' 1 \
  "$(jq '[.hooks.PreToolUse[] | select(.matcher == "*")] | length' "$CLAUDE_HOME/settings.json")"
assert_eq 'unrelated settings survive' true "$(jq .other "$CLAUDE_HOME/settings.json")"
assert_eq 'settings backup is original' "$(cat "$TMP/original.json")" \
  "$(cat "$CLAUDE_HOME/settings.json.bak")"
cp "$CLAUDE_HOME/settings.json" "$TMP/installed.json"
install_adapter
assert_eq 'second install succeeds' 0 "$CODE"
assert_eq 'second install changes nothing' "$(cat "$TMP/installed.json")" \
  "$(cat "$CLAUDE_HOME/settings.json")"
assert_eq 'second install preserves backup' "$(cat "$TMP/original.json")" \
  "$(cat "$CLAUDE_HOME/settings.json.bak")"
rm "$CLAUDE_HOME/agents/sdd-implementer.md"
echo 'user agent' >"$CLAUDE_HOME/agents/sdd-implementer.md"
install_adapter
assert_eq 'regular file refuses replacement' 1 "$CODE"
assert_eq 'regular file is unchanged' 'user agent' "$(cat "$CLAUDE_HOME/agents/sdd-implementer.md")"
install_adapter --force
assert_eq 'force succeeds' 0 "$CODE"
assert_eq 'force backs up agent' 'user agent' "$(cat "$CLAUDE_HOME/agents/sdd-implementer.md.bak")"
assert_eq 'force replaces with own link' "$SKILL/adapters/claude/agents/sdd-implementer.md" \
  "$(readlink "$CLAUDE_HOME/agents/sdd-implementer.md")"
rm "$CLAUDE_HOME/agents/sdd-implementer-sonnet.md"
echo 'keep user agent' >"$CLAUDE_HOME/agents/sdd-implementer-sonnet.md"
rm "$CLAUDE_HOME/agents/sdd-task-reviewer.md"
ln -s "$TMP/unrelated.md" "$CLAUDE_HOME/agents/sdd-task-reviewer.md"
install_adapter --uninstall
assert_eq 'uninstall succeeds' 0 "$CODE"
assert_eq 'uninstall removes own link' false \
  "$(if [ -L "$CLAUDE_HOME/agents/sdd-implementer.md" ]; then echo true; else echo false; fi)"
assert_eq 'uninstall keeps regular file' 'keep user agent' \
  "$(cat "$CLAUDE_HOME/agents/sdd-implementer-sonnet.md")"
assert_eq 'uninstall keeps foreign link'  "$TMP/unrelated.md" \
  "$(readlink "$CLAUDE_HOME/agents/sdd-task-reviewer.md")"
assert_eq 'uninstall keeps only unrelated entry' '[{"matcher":"*","hooks":[]}]' \
  "$(jq -c .hooks.PreToolUse "$CLAUDE_HOME/settings.json")"
CLAUDE_HOME="$TMP/fresh" install_adapter
assert_eq 'missing settings created' 0 "$CODE"
assert_eq 'new settings contain guard' "$GUARD" \
  "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$TMP/fresh/settings.json")"

# Each operation must write through an existing settings link to its external target.
for operation in install uninstall; do
  linked_home="$TMP/linked-$operation"
  linked_target="$TMP/$operation-settings.json"
  mkdir -p "$linked_home"
  if [ "$operation" = install ]; then
    cp "$TMP/original.json" "$linked_target"
  else
    cp "$TMP/installed.json" "$linked_target"
  fi
  ln -s "$linked_target" "$linked_home/settings.json"
  if [ "$operation" = install ]; then
    CLAUDE_HOME="$linked_home" install_adapter
    expected_count=1
  else
    CLAUDE_HOME="$linked_home" install_adapter --uninstall
    expected_count=0
  fi
  assert_eq "$operation linked settings succeeds" 0 "$CODE"
  assert_eq "$operation preserves settings symlink" "$linked_target" "$(readlink "$linked_home/settings.json")"
  assert_eq "$operation updates settings target" "$expected_count" \
    "$(jq '[.hooks.PreToolUse[] | select(.matcher == "Agent|Task")] | length' "$linked_target")"
done

# Compares each shipped alias with the first word in its real Claude tier cell.
for name in sdd-implementer sdd-implementer-sonnet sdd-task-reviewer sdd-final-reviewer; do
  case "$name" in sdd-implementer) column=3 ;; sdd-final-reviewer) column=5 ;; *) column=4 ;; esac
  expected="$(awk -F'|' -v col="$column" '$2 ~ /^ Claude $/ {
    gsub(/^[[:space:]]+/, "", $col); split($col, words, /[[:space:]]+/); print tolower(words[1]); exit
  }' "$SKILL/models.md")"
  actual="$(sed -n 's/^model:[[:space:]]*//p' "$SKILL/adapters/claude/agents/$name.md" | tr '[:upper:]' '[:lower:]')"
  assert_eq "$name alias agrees with real tier table" "$expected" "$actual"
done

if [ "$FAILS" -eq 0 ]; then echo 'Claude adapter tests passed'; fi
exit "$FAILS"
