---
name: gd-infra-conventions
description: Use when you touch infra, CI, migrations or a failed deploy; covers pinning, runtimes and logs.
license: MIT
metadata:
  author: gusdecool
  version: "1.0"
---

# Infrastructure conventions

## Infrastructure as code

- Manage infrastructure as code; Terraform is the default. Make no manual console change without noting it. Why: a
  change that exists only in the console is invisible to review, lost at the next apply, and impossible to reproduce.
- CI runs through GitHub Actions unless the repo says otherwise. Why: one CI system per repo keeps the pipeline and
  its secrets in one place, and a second one is easy to miss when a check fails.

## GitHub Actions

- Pin every `uses:` to its latest major version, checked when you create or edit the workflow, never from memory or
  an older example in the repo. Why: a stale pin and a copied stale example both keep a deprecated runtime alive, and
  the problem spreads into every new workflow.
- Check the version at its source: `gh api repos/<owner>/<repo>/releases/latest --jq .tag_name`, then read the
  `action.yml` at that ref. Confirm it declares a current runtime in `runs.using` (for example `node24`, not
  `node20`). Do this for every action the workflow edit touches. Why: a current runtime avoids deprecation warnings
  in every run and a forced migration on the provider's schedule instead of yours.

## Migrations

- Migrations go in the repo's migration folder and are generated with the repo's tool. Why: the tool writes the format
  the runner expects, so the history stays consistent and replayable.
- Never edit a migration that has already been applied; add a new one. Why: an applied migration is recorded as done
  and never runs again, so the edit reaches no database and the schema you tested is not the schema anyone else gets.

## Deploy and health check failures

- When a deploy or health check fails, read the service's logs before diagnosing. Why: the log line names the failing
  step; a diagnosis without it is a guess, and a wrong guess means changing production for no reason.
- Find the service's log group in the infra repo (the resource that defines the service's logging), then read it with
  the cloud CLI and the repo's profile. For CloudWatch Logs:

  ```
  aws logs filter-log-events --log-group-name <group> --start-time <epoch ms> --limit 40 --profile <profile>
  ```

  Why: the infra repo is the source of truth for the group name, and the repo's profile is the credentials the team
  already scoped for this read.
- Never read host or container logs through remote command execution (for example SSM `send-command`). Why: that is an
  unfiltered production read with no retention and no audit trail, and it is blocked.
- If the logs show a code bug, fix it on a task branch and open a follow-up pull request. Why: the deploy is already
  broken, so the fix needs review and its own deploy rather than an untracked edit in the middle of an incident.
- If the cause is outside the repo (database credentials or grants, secrets, or infrastructure), report the exact log
  line and the change its owner must make; do not guess and do not change production. Why: those changes affect
  systems other people own, and an unverified change during an incident can widen the outage.
