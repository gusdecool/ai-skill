#!/usr/bin/env bash
# Static checks: skill frontmatter, plugin JSON, and the 120 character line limit.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
FAILS=0

# Prints a failure message and counts it.
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

for skill in skills/*/SKILL.md; do
  dir="$(basename "$(dirname "$skill")")"
  name="$(sed -n 's/^name:[[:space:]]*//p' "$skill" | head -n1)"
  desc="$(sed -n 's/^description:[[:space:]]*//p' "$skill" | head -n1)"
  [ "$name" = "$dir" ] || fail "$skill: name '$name' does not match folder '$dir'"
  [ -n "$desc" ] || fail "$skill: missing description"
done

# Every script a skill ships must be executable; sourced libraries (*-lib.sh) are exempt.
for script in skills/*/scripts/*; do
  case "$script" in *-lib.sh) continue ;; esac
  [ -x "$script" ] || fail "$script is not executable"
done

# The HITL status is the only stop marker; the label HITL must not come back, and a high-risk change gets high-risk.
grep -q 'add high-risk' skills/board-worker/SKILL.md || fail "board-worker SKILL.md does not add the high-risk label"
if grep -q 'add HITL' skills/board-worker/SKILL.md; then fail "board-worker SKILL.md adds the HITL label"; fi

for json in .claude-plugin/plugin.json .claude-plugin/marketplace.json .codex-plugin/plugin.json \
  .agents/plugins/marketplace.json; do
  jq -e . "$json" >/dev/null 2>&1 || fail "$json is not valid JSON"
done

while IFS= read -r file; do
  case "$file" in skills/*/SKILL.md) continue ;; esac
  awk -v f="$file" 'length > 120 { print "FAIL: " f ":" FNR " is " length " chars"; bad = 1 }
                    END { exit bad }' "$file" || FAILS=$((FAILS + 1))
done < <(git ls-files '*.sh' '*.md' '*.json' '*.yml')

[ "$FAILS" -eq 0 ] && echo "Structure checks passed"
exit "$FAILS"
