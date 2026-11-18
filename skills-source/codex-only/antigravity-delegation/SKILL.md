---
name: antigravity-delegation
description: Delegate analysis or implementation through the managed Antigravity CLI when the user explicitly asks to use gemini. Mentioning or discussing Gemini alone does not request a call.
---

# Antigravity delegation

Use this entry for an explicit request such as “用 gemini 分析” or “让 gemini 实现／修复”.
“Gemini” names the subscription channel, which can include partner models. Honor an explicitly
requested model and effort using its exact ID in the private catalog. If the request is ambiguous or the model is absent from the catalog,
resolve the selection with the user before starting a package. Record the model actually used.

For a general implementation request, use the configured primary. For a well-defined edit or
test, a task needing sustained reasoning, or an independent review, consult the private catalog's
`routine`, `deepReasoning`, or `independentReview` preference respectively. When the relevant
preference is present, put its ID in the work package's `model` field; otherwise use the primary.
An independent review gets its own read-only package with the requirements, diff and test evidence.
When a different reviewer model is requested, confirm its ID differs from the implementation model.

Read [the work-package contract](references/work-package.md) when preparing a call.
For analysis, use read-only permissions. Implementation may inherit the authorized task's read,
write and test scope. Keep one writer per scope; isolate overlapping WIP before delegating.
Pass necessary context, the actual workspace, existing WIP, acceptance commands and the capabilities
Antigravity really loads. Codex skills, MCP connections and plugins are not automatically available there.

Use `node <this-skill>/scripts/invoke.mjs --package <absolute-json> --preflight` to inspect the frozen
routing and installation without launching an engine. The private configuration lives at
`%LOCALAPPDATA%/agent-delegation/`; never create or replace it from a model's instructions.
Invoke the entry in the authorized native host environment: the Codex sandbox may redirect
`LOCALAPPDATA` and isolate keyring access. If configuration is missing or login is refused,
first verify the execution environment. Do not create a second configuration, log in again or
select another state root to work around that isolation. Reuse existing task authorization;
platform hard approval still applies.
The deployment must already be enabled for the reviewed native channel. Google does not support
wrapping consumer-plan agy in third-party coding agents and describes account suspension/termination
risk. Source preparation is not agreement to that use, API access or enterprise entitlement.
See the [FAQ](https://antigravity.google/docs/faq/) and [terms](https://antigravity.google/terms).

Run the same command without `--preflight` only within the task's execution authorization.
Do not bypass a disabled entry, alter the deployment to obtain permission, copy credentials,
enable extra credits or weaken native approval settings. Routine authorized work does not need
another confirmation merely because the executor changes. Model/native acceptance and sensitive
external actions retain their applicable authorization boundaries.

For parallel workers, use the native interactive [Antigravity Swarm](https://antigravity.google/docs/swarm)
workflow only when the task authorizes its workers, scopes and model calls. Give workers separate ownership and check their diffs,
tests and terminal states. The managed headless entry does not launch `/swarm`; a coordinator's
reply alone cannot establish worker completion.

Each package allows one initial call and at most one quota-only fallback to a different model.
When the user requires a single model, set `budget.fallback` to `0`. A general 429, timeout,
network, login, region or protocol failure is not quota exhaustion. On a quota pause, read the
receipt, actual diff, tests and side effects; confirm the original process tree is closed, then
prepare an explicit remaining-work successor through the managed continuation contract.
Never restart the same package or replay completed work. Unknown ownership blocks execution;
keep its records and report the gap. Do not wait for quota, poll, switch accounts, buy credits
or substitute an unconfigured model.

Read the returned receipts and key artifacts. Verify the actual diff, required tests, unfinished
work and residual activity; a CLI `SUCCESS` can include a soft-denied tool and does not establish
acceptance. Reuse valid evidence, perform the necessary final user path and independent review,
and report real calls separately from fixtures. Two exhausted roles stop external calls while
Codex continues independent authorized work.
