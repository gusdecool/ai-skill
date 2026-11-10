---
name: authoring-skills
description: Use when creating or changing a skill: edit the source repo by PR, then install and refresh the local copy.
---

# Authoring skills

A skill is shared code: several agents load it, and one file change reaches all of them. It therefore needs review,
version history and one source of truth, so you never patch it where it happens to be installed.

## 1. Change the skill in its source repository

Make the change in the repository that owns the skill, on a branch, and open a pull request for it. Never edit the
skill in place in the global install folders that agents load it from, or in any per-agent copy of those folders.

Why: the install folders are targets, not sources. A local edit there is overwritten on the next sync, and it is never
reviewed or versioned, so the fix or the new rule can vanish without a trace.

Keep each change about one skill, and make the pull request say what changed and why, so a reviewer can judge the rule
rather than guess at the intent.

## 2. Install the skill after the merge

Once the pull request is merged, install the merged version globally with `npx skills update -g`, run from your home
directory.

Why: the global install is what agents load, and it only changes when you update it, so a merged skill does nothing
until this step runs.

## 3. Refresh the local copy in the same session

After a skill pull request merges, run `npx skills update -g` again as the last step of the same session. After a
standards pull request merges, run `git pull` in the local clone of the standards repository in the same session.

Why: agents read the local install, so a merged change has no effect until it is pulled into that copy.

## Checklist before you finish

- [ ] The edit was made in the source repository on a branch, not in an install folder.
- [ ] A pull request is open, with the reason for the change in its description.
- [ ] The repository's own checks pass.
- [ ] After the merge, the global install was updated and the local copy was refreshed in the same session.
