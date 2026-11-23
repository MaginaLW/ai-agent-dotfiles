---
name: swarm
description: Coordinate parallel agent work in Codex Desktop, including worker dispatch, a shared live board, member @mentions, delivery receipts and a communication graph. Use for a swarm, agent team, 并行委派, 蜂群, 团队看板 or 协作收件箱.
---

# Swarm

Use this skill to run the team. For a milestone with dependency waves and multiple review levels, use the installed `teamwork` skill to determine which work can start. Both use the same run manifest and event history.

1. Identify the outcome, the permitted inputs, the writer for each deliverable, and how to check it. Apply the [dispatch rules](references/dispatch.md) before selecting workers. Check Desktop privacy once for the current scope. A host worker ID identifies a process. A manifest member identifies its persistent inbox.
2. For visible coordination, open a run and its board with [the run and mailbox commands](references/coordination.md). Give each worker the manifest, its own outbox path, the named recipients and its acceptance check. When a host isolates writes, map that worker to a writable directory in its own checkout.
3. Address peers by member name. Peer messages inherit the assignment's scope. Check the inbox on startup, when idle, and before reporting completion. When the host supports notifying that existing idle member, send one notification with the pending event ID. The recipient reads the durable message and writes its own receipt. On a polling-only host, a stopped worker picks up its inbox when it next runs.
4. Show the live board in the current chat's right panel with `mcp__codex_app__open_in_codex` and the printed loopback URL. For `queued`, keep the original request pending until the chat is visible, then verify the panel page and status polls. The board and graph follow the same worker events. Use the local queries and receipts to inspect the events behind an edge or review finding before acting. [Queued panel open](references/coordination.md#wait-for-a-queued-open) · [Panel and receipt commands](references/coordination.md#open-a-run) · [Native project interoperability](references/upstream-interop.md)
5. Retrieve accepted artifacts and archive the manifest and outboxes before worker cleanup. The Project Orchestrator owns final acceptance. An acknowledged message, a completed worker process and a released artifact are separate observable events.
