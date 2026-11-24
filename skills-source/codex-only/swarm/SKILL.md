---
name: swarm
description: Coordinate parallel agent work in Codex Desktop, including worker dispatch, a shared live board, member @mentions, delivery receipts and a communication graph. Use for a swarm, agent team, 并行委派, 蜂群, 团队看板 or 协作收件箱.
---

# Swarm

Use this skill to run the team. For a milestone with dependency waves and multiple review levels, use the installed `teamwork` skill to determine which work can start. Both use the same run manifest and event history.

1. Identify the outcome, permitted inputs, writer for each deliverable, and acceptance check. Apply [dispatch rules](references/dispatch.md) and the host's delegation, privacy, and `fork_turns` rules before selecting workers. A host worker ID identifies a process; a manifest member identifies its persistent inbox.
2. For visible coordination, open or reuse a run and its board via [the coordination commands](references/coordination.md). Give each worker the manifest, its own outbox path, named recipients, and its acceptance check. When a host isolates writes, map that worker to a writable directory in its own checkout.
3. Address peers by member name. Peer messages inherit the assignment's scope. Check the inbox on startup, when idle, and before reporting completion. When the host can notify an idle member, send one notification with the pending event ID; the recipient reads the durable message and writes its own receipt. On a polling-only host, a stopped worker picks up its inbox when it next runs.
4. Show or reuse the live board in the current chat's right panel with `mcp__codex_app__open_in_codex` and the URL printed by `coordination.py --manifest ... --reuse`. For `queued`, keep the request pending until the chat is visible, then confirm `uiGets >= 1` and `statePolls >= 1` via `run.py status` or `GET <url>api/health`. Use `run.py status --manifest MANIFEST` before acting to inspect tasks, Sentinel alerts, pending receipts, and communication edges. [Queued panel open](references/coordination.md#wait-for-a-queued-open) · [Panel and receipt commands](references/coordination.md#open-a-run) · [Native project interoperability](references/upstream-interop.md)
5. Follow dual-path review: use actor-signed `approve`/`changes` when a writable peer reviewer has its own outbox; collect `readonly` subscription reviews through the host and record the external task ID, reviewed digest, verdict, and evidence in Lead's `release --text` and report (Lead never impersonates a reviewer). Retrieve accepted artifacts and archive the manifest and outboxes before worker cleanup. The Project Orchestrator owns final acceptance.
