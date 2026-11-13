---
name: antigravity-delegation
description: Delegate analysis or implementation through the managed Antigravity CLI when the user explicitly asks to use gemini. Mentioning or discussing Gemini alone does not request a call.
---

# Antigravity delegation

Use this entry for an explicit request such as “用 gemini 分析” or “让 gemini 实现／修复”.
The names `primary` and `fallback` describe routing roles; the private mapping chooses the actual models.

Read [the work-package contract](references/work-package.md) when preparing a call.
For analysis, use read-only permissions. Implementation may inherit the authorized task's read,
write and test scope. Keep one writer per scope; isolate overlapping WIP before delegating.
Pass necessary context, the actual workspace, existing WIP, acceptance commands and the capabilities
Antigravity really loads. Codex skills, MCP connections and plugins are not automatically available there.

Use `node <this-skill>/scripts/invoke.mjs --package <absolute-json> --preflight` to inspect the frozen
routing and installation without launching an engine. The private configuration lives at
`%LOCALAPPDATA%/agent-delegation/`; never create or replace it from a model's instructions.
The deployment must already be enabled for the reviewed native channel. Google does not support
wrapping consumer-plan agy in third-party coding agents and describes account suspension/termination
risk. Source preparation is not agreement to that use, API access or enterprise entitlement.
See the [FAQ](https://antigravity.google/docs/faq/) and [terms](https://antigravity.google/terms).

Run the same command without `--preflight` only within the task's execution authorization.
Do not bypass a disabled entry, alter the deployment to obtain permission, copy credentials,
enable extra credits or weaken native approval settings. Routine authorized work does not need
another confirmation merely because the executor changes. Model/native acceptance and sensitive
external actions retain their applicable authorization boundaries.

Each package allows one primary and at most one quota-only fallback. A general 429, timeout,
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
