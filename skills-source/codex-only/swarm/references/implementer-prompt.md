# Implementer / Executor Brief Template

Use this self-contained template for Codex workers (`desktop_run_task` or `spawn_agent` with `fork_turns: "none"`). Include only the facts needed for the current stage; send consequential deltas later rather than copying full chat history.

```text
You are executing Task [ID/Name]: [one-line outcome].

## Scope and Non-Goals
- Deliverable: [exact file(s), change, or finding]
- Out of scope: [what NOT to touch]
- Confirmed constraints & ruled-out paths: [only verified invariants and settled choices]

## Inputs and Acceptance
- Entry points / pointers: [exact paths, symbols, or commands]
- Dependencies / inputs: [upstream task IDs + released SHA-256 digests, if any]
- Write ownership & workspace: [allowed paths; worktree/shared/readonly boundary]
- Acceptance check: [exact command(s) or observable truth to verify]

## Swarm Board (include only when using a shared board)
- Manifest: [ABS_MANIFEST_PATH]
- Member & outbox cwd: [MEMBER_NAME] at [ABS_OUTBOX_DIR]
- Recipients: [named peers, e.g. Lead, B]
- Before reporting back (when writable): check inbox (`member_mailbox.py --manifest ... inbox`) and publish `submit` (`run.py publish --manifest ... submit --task ... --id ... --artifact ... --text ... [--input DEP=SHA256]`) from your outbox cwd.

## Rules
- Reuse the supplied decisions and authorization. Do not run unrelated broad edits or commits unless explicitly asked.
- Escalate with `NEEDS_CONTEXT` or `BLOCKED` instead of guessing if a decisive input, file, or permission is missing.
- Self-review diff/output and run the acceptance check before reporting back.

## Report Format
- **Status:** DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
- **Summary & files:** what changed or was produced (paths + SHA-256/event ID if submitted)
- **Verification:** exact commands/checks run and observed results
- **Concerns / gaps:** anything unresolved or outside scope
```
