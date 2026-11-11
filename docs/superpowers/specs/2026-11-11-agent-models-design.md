Source: https://bungamata.atlassian.net/browse/BM-163 (copied unchanged, Jira wiki markup)

h2. Goal
Record which provider and model did the work on each board ticket, so tickets can be filtered by model later and the
team can compare models on cost (USD) and time. Today the ticket only gets three totals (Agent minutes, Agent tokens,
Agent cost USD), with no way to tell which model produced them.

h2. Acceptance criteria
* A new Jira field "Agent models" exists: a multi-value, JQL-searchable field (Jira Labels type) on the same screens as "Agent minutes". Each value is {{provider:model}}, for example {{claude:sonnet-5.5}} or {{opencode:deepseek-v4.1-flash}}. The JQL {{"Agent models" = "claude:sonnet-5.5"}} returns the tickets that used it.
* {{board-setup --stats-fields}} creates the field when missing and is safe to run again.
* {{board-run-stats}} adds a {{label}} to each entry of {{models}} in its JSON, in {{provider:model}} form, taken from a new label column in {{model-prices.tsv}} (for example {{claude-sonnet-5-5}} becomes {{claude:sonnet-5.5}}). A model with no label row falls back to {{provider:<raw id>}} and is still listed.
* {{board-run-stats}} counts the Claude subagent session logs of the worktree too, so models used by Claude's own subagents appear. If the logs already include them, keep the code and add a test that proves it.
* {{board-ticket-cli stats}} merges the labels into "Agent models" (no duplicates, existing values kept) and stores the per-model detail in a Jira issue property named {{agent.runs}} (not in a comment, so it never mixes with human comments). The property is a JSON array; each run appends one object: {{startedAt}}, {{provider}}, {{minutes}}, {{tokens}}, {{costUsd}} and {{models}}, a list of {{label}}, {{input}}, {{output}}, {{cacheRead}}, {{cacheWrite}}, {{costUsd}}. A retried or taken-over ticket keeps all earlier runs.
* {{board-ticket-cli stats}} accepts a repeatable {{--model <provider:model>}} flag for a worker on another provider whose usage cannot be read from logs (Codex, Gemini, OpenCode). It adds the label to "Agent models" and writes a run entry with {{minutes}}, {{tokens}} and {{costUsd}} set to {{null}} (unknown, not 0). Totals fields are not changed by such an entry.
* A new subcommand {{board-ticket-cli runs <key>}} prints the {{agent.runs}} property as JSON, so analysis scripts can read it.
* The existing summary comment keeps working and also lists the model labels.
* The dispatcher and load balancer docs ({{SKILL.md}} of gusdecool-board-worker and gusdecool-load-balancer) say that, when a task is given to a worker on another provider, the orchestrator passes the {{provider:model}} it chose to {{board-ticket-cli stats --model}}.
* Tests cover: label mapping and fallback, subagent logs, merge without duplicates, the property append, the {{--model}} flag, and a Jira error never failing the ticket (stats stays report-only, exit 0).

h2. Constraints
* Repo {{gusdecool/ai-skill}}, skill {{gusdecool-board-worker}} (scripts, {{SKILL.md}}, {{model-prices.tsv}}) and a short note in {{gusdecool-load-balancer/SKILL.md}}.
* Keep stats report-only: a failure prints one stderr line and never changes how the ticket ends.
* Jira calls go through {{jira_api}} in {{board-lib.sh}}; never print the token. Tests mock Jira, no live API calls.
* The worker has no Jira admin rights: creating the field is done by {{board-setup --stats-fields}}, which a human with an admin token runs once after merge. The code must keep working (print one stderr line about the missing field) until then.
* Issue property keys must be 255 characters or fewer and the value stays under 32 KB; if the {{agent.runs}} array would pass 30 KB, keep the newest runs and set a {{truncated: true}} entry at the front.
* 120 characters per line; follow the existing bash style of the scripts.

h2. Decisions made
* One multi-value "Agent models" field, not separate provider and model fields: one ticket can use several models when Claude hands work to another agent.
* Name format {{provider:model}} (as in {{claude:sonnet-5.5}}), mapped by a label column in {{model-prices.tsv}}: readable, and matches the names in the tier table.
* Per-model numbers go to a Jira issue property, not a comment: separate from human comments and easy to query by script. The multi-value field is what JQL filters on, because Jira cannot run JQL on issue properties without an app.
* Other-provider workers are recorded by label only; minutes, tokens and cost stay unknown. Log parsers for them are separate tickets.
* No backfill of old tickets: the model was never kept, so any value would be a guess.

h2. Non-goals
* No log parsers for Codex, Gemini or OpenCode (follow-up tickets).
* No price entries for non-Claude models.
* No backfill of old tickets.
* No dashboards or weekly report (that is BM-159).
* Do not remove or rename "Agent minutes", "Agent tokens" or "Agent cost USD".
* Do not change how the summary comment looks beyond listing the labels.

h2. How to verify
* Run the repo's test suite and lint; all pass.
* Run {{board-run-stats <worktree>}} on a worktree that has Claude logs: each {{models}} entry has a {{label}} such as {{claude:sonnet-5.5}}.
* A human with a Jira admin token runs {{board-setup --stats-fields}} twice: the "Agent models" field is created once and the second run only reports it exists.
* Pipe a run into {{board-ticket-cli stats <test ticket>}}, then in Jira search {{"Agent models" = "claude:sonnet-5.5"}}: the ticket is found. {{board-ticket-cli runs <test ticket>}} prints the run with its per-model numbers. Run it again: the labels are not duplicated and {{runs}} has two entries.
* {{board-ticket-cli stats <test ticket> --model opencode:deepseek-v4.1-flash}} adds that label and a run with {{null}} numbers.

h2. Open questions
None.
