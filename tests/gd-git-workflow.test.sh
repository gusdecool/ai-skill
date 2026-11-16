#!/usr/bin/env bash
# Tests for gd-git-workflow's git-cleanup against throwaway git repos, with gh replaced by a fake that reads files.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/skills/gd-git-workflow/scripts/git-cleanup"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
FAILS=0

# Removes the temp directory.
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Records a failure when two values differ.
assert_eq() {
  if [ "$2" != "$3" ]; then echo "FAIL: $1 (expected '$2', got '$3')"; FAILS=$((FAILS + 1)); else echo "ok: $1"; fi
}

# Fake gh: `gh pr list --head <b>` prints $WORK/pr/<b with / as _>, or fails when that file is missing.
mkdir -p "$WORK/bin" "$WORK/pr"
cat >"$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
b=""; while [ $# -gt 0 ]; do [ "$1" = --head ] && b="$2"; shift; done
f="$PWD_PR/${b//\//_}"
[ -f "$f" ] && cat "$f" || echo '[]'
GH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" PWD_PR="$WORK/pr" ORCA_BIN=""
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Sets the fake PR list for a branch: state and head sha.
set_pr() { printf '[{"state":"%s","headRefOid":"%s"}]\n' "$2" "$3" >"$PWD_PR/${1//\//_}"; }
# Commits a file on the checked-out branch of the given checkout.
commit() { echo "$2" >"$1/${2//\//_}"; git -C "$1" add -A; git -C "$1" commit -qm "$2"; }
# Prints "yes" when the local branch exists in the main checkout.
has_local() { git -C "$WORK/main" show-ref --verify -q "refs/heads/$1" && echo yes || echo no; }
# Prints "yes" when the branch exists on the origin.
has_remote() { git -C "$WORK/origin.git" show-ref --verify -q "refs/heads/$1" && echo yes || echo no; }

git init -q --bare -b main "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/main" 2>/dev/null
commit "$WORK/main" base
git -C "$WORK/main" push -q origin main
git -C "$WORK/main" remote set-head origin main

# Makes a pushed branch with one commit, in its own worktree; prints nothing.
mk() {
  git -C "$WORK/main" worktree add -q -b "$1" "$WORK/wt-${1//\//_}" main
  commit "$WORK/wt-${1//\//_}" "$1-file"
  git -C "$WORK/wt-${1//\//_}" push -q -u origin "$1"
}
tip() { git -C "$WORK/main" rev-parse "$1"; }

mk feat/merged;   set_pr feat/merged MERGED "$(tip feat/merged)"
mk feat/closed;   set_pr feat/closed CLOSED "$(tip feat/closed)"
mk feat/open;     set_pr feat/open OPEN "$(tip feat/open)"
mk feat/nopr
mk feat/dirty;    set_pr feat/dirty MERGED "$(tip feat/dirty)"; echo x >"$WORK/wt-feat_dirty/untracked"
mk feat/extra;    set_pr feat/extra MERGED "$(tip feat/extra)"; commit "$WORK/wt-feat_extra" more
git -C "$WORK/main" worktree add -q -b feat/unpushed "$WORK/wt-feat_unpushed" main
commit "$WORK/wt-feat_unpushed" unpushed; set_pr feat/unpushed CLOSED "$(tip feat/unpushed)"

OUT="$(cd "$WORK/main" && bash "$SCRIPT" --dry-run)"
assert_eq "dry run deletes nothing" "yes" "$(has_local feat/merged)"
assert_eq "dry run says would delete" "would delete feat/merged (merged)" "$(grep 'feat/merged' <<<"$OUT")"

OUT="$(cd "$WORK/main" && bash "$SCRIPT")"
assert_eq "merged: local branch gone" "no" "$(has_local feat/merged)"
assert_eq "merged: remote branch gone" "no" "$(has_remote feat/merged)"
assert_eq "merged: worktree gone" "no" "$([ -d "$WORK/wt-feat_merged" ] && echo yes || echo no)"
assert_eq "closed: local branch gone" "no" "$(has_local feat/closed)"
assert_eq "closed: remote branch kept" "yes" "$(has_remote feat/closed)"
assert_eq "open: kept" "yes" "$(has_local feat/open)"
assert_eq "no PR: kept" "yes" "$(has_local feat/nopr)"
assert_eq "uncommitted changes: kept" "yes" "$(has_local feat/dirty)"
assert_eq "merged with extra local commit: kept" "yes" "$(has_local feat/extra)"
assert_eq "closed and unpushed: kept" "yes" "$(has_local feat/unpushed)"
assert_eq "default branch untouched" "yes" "$(has_local main)"
assert_eq "kept line gives the reason" "kept feat/dirty: uncommitted changes in $WORK/wt-feat_dirty" \
  "$(grep 'feat/dirty' <<<"$OUT")"

# A merged branch checked out in the main checkout: the main checkout moves to the default branch first.
git -C "$WORK/main" switch -q -c feat/inmain
commit "$WORK/main" inmain; git -C "$WORK/main" push -q -u origin feat/inmain
set_pr feat/inmain MERGED "$(tip feat/inmain)"
(cd "$WORK/main" && bash "$SCRIPT" >/dev/null)
assert_eq "main checkout switched to default" "main" "$(git -C "$WORK/main" branch --show-current)"
assert_eq "main checkout branch deleted" "no" "$(has_local feat/inmain)"

# Run from inside a worktree whose PR is merged: it keeps that worktree and says so.
set_pr feat/open MERGED "$(tip feat/open)"
OUT="$(cd "$WORK/wt-feat_open" && bash "$SCRIPT")"
assert_eq "current worktree kept" "kept feat/open: current worktree, run from the main checkout" \
  "$(grep 'feat/open' <<<"$OUT")"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS failure(s)"; exit 1; fi
echo "all passed"
