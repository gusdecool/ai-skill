# Model tiers

Last checked: 2026-11-10

One scale for every AI provider: Low, Mid, High, Ultra. Rules elsewhere (the `gusdecool-model-policy` skill, skills)
speak only in
tiers; this file is the only place that names models. A cell holds model names separated by `, ` or the word `none`.
A model added by the weekly job is written `name (proposed)`.

| Provider | Low | Mid | High | Ultra |
|---|---|---|---|---|
| Claude | Haiku 5.5 | Sonnet 5.5 | Opus 5.5 | Fable 5.2, Mythos 5.2 |
| Codex | Luna, Terra | Sol | none | Astra |
| Gemini | 3.5 Flash-Lite, 3.6 Flash | 3.8 Flash | Argon | none |
| DeepSeek | V4.1 Flash | V4 Pro | none | none |
| Kimi | K2.6 | K2.7 Code, K3.1-pro, K3 | none | none |

## Tier definitions

Mid is anchored on Claude Sonnet 5.5. A tier is the owner's judgment of capability and cost; price is the guide.
Why: price alone misranks cheap models that do Sonnet-class work.

| Tier | Price guide (output price, relative to Sonnet 5.5) | Meaning |
|---|---|---|
| Low | up to 0.5x | easy or mechanical coding |
| Mid | 0.5x to 1.5x | default: planning, review, hard implementation |
| High | 1.5x to 3x | needs the user's OK in the conversation |
| Ultra | above 3x | extra caution: the user names the model and the cost is stated first |

Judgment overrides price. DeepSeek V4 Pro and Kimi K2.7 Code cost less than 0.5x but are Mid because the owner
rates them as Sonnet-class for the work. DeepSeek V4.1 Flash and Kimi K2.6 are Low.

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
| Claude | Mythos 5.2 | none |
| Codex | Luna | `gpt-6-luna` |
| Codex | Terra | `gpt-6.1-terra` |
| Codex | Sol | `gpt-6.1-sol` |
| Codex | Astra | `gpt-6-astra` |
| Gemini | 3.5 Flash-Lite | none |
| Gemini | 3.6 Flash | none |
| Gemini | 3.8 Flash | `gemini-3.8-flash-medium` |
| Gemini | Argon | none |
| DeepSeek | V4.1 Flash | `opencode-go/deepseek-v4.1-flash` |
| DeepSeek | V4 Pro | `opencode-go/deepseek-v4-pro` |
| Kimi | K2.6 | none |
| Kimi | K2.7 Code | `opencode-go/kimi-k2.7-code` |
| Kimi | K3.1-pro | `opencode-go/kimi-k3.1-pro` |
| Kimi | K3 | `opencode-go/kimi-k3` |

The id to pass as `--model` to an agent CLI. Never pass the display name from the tier table. Why: in BM-56 a worker
was started with `--model Sol`, Codex answered "The 'Sol' model is not supported when using Codex with a ChatGPT
account", and the dispatch was wrongly moved to another provider. The real id is `gpt-6.1-sol`.

Checked against each CLI on 2026-11-11. A cell says `none` when the CLI does not list the model.
Mythos 5.2 is unverified: it is not in the Claude Code docs or `claude --help`.
Gemini 3.8 Flash also has `-low` and `-high` variants for the reasoning level.

- Read the id from the CLI's own model list, not from memory: `agy models`, `opencode models`, and for Codex the
  `slug` field of `~/.codex/models_cache.json` (take entries with `visibility: list`). When the table is stale (a
  newer version is listed, or a launch is refused), use the CLI's list and update this table by pull request. Why: the
  CLIs change ids faster than this file, and BM-56 showed what a wrong id costs.
- A Claude id in this table is an id Claude Code accepts; check with `claude --help` if a launch is refused. Why: the
  Claude CLI has no model list command.

## API model IDs

Checked on the provider's official page, 2026-11-10.

| Name | API model ID | Source |
|---|---|---|
| DeepSeek V4.1 Flash | `deepseek-flash` | https://api-docs.deepseek.com/quick_start/pricing |
| DeepSeek V4 Pro | `deepseek-v4-pro` | https://api-docs.deepseek.com/quick_start/pricing |
| DeepSeek V4.1 Flash (OpenCode Go) | `opencode-go/deepseek-v4.1-flash` | `opencode models` |
| DeepSeek V4 Pro (OpenCode Go) | `opencode-go/deepseek-v4-pro` | `opencode models` |
| Kimi K2.6 | (unverified) | https://platform.kimi.com/docs/pricing/chat |
| Kimi K2.7 Code | `kimi-k2.7-code` (unverified) | https://platform.kimi.com/docs/pricing/chat |

The two OpenCode Go rows are the slugs for `orca agent launch --agent opencode --model <slug>`, checked with a
launch on 2026-11-10. They need the OpenCode account region set to Global, because the models are hosted outside the
EU and US.

The Kimi page names K2.6 and K2.7 Code but gives no IDs; `kimi-k2.7-code` comes from third-party sources only. The
page also says the K2 series closes to new registrations on 2026-10-31 and goes offline at the end of December 2026,
and lists K3 models (`kimi-k3`, `kimi-k3.1-pro`). Review the Kimi row before December.
