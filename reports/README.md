# Local Run Reports

The repository's operational commands may write paired human-readable Markdown
and machine-readable JSON reports here, including build, scan, sync, config,
profile, skills, and environment operations.

Generated `*.md` and `*.json` reports are machine- and run-specific operational artifacts. They are ignored by Git and must not contain backup contents, file contents, credentials, private keys, tokens, VPS/node configuration, or other machine-private state. This README is the only tracked file in this directory.

The JSON sidecar follows [`schemas/run-report.schema.json`](../schemas/run-report.schema.json) and contains only metadata, summary fields, safe skill names, and next actions. Environment status and rollback evidence may include lock validity, definition drift, live parity, Codex `.system` status, plan hashes, previous environment names, and a safe backup reference; they must never include backup contents.

`env.lock.json` is a verifiable environment lock in generated staging, not a
run-report payload. Reports may state whether the lock is valid, but must not
embed its file contents or source material.

Use placeholders such as `<repo-root>`, `<home-root>`, `<external-plan.json>`,
and `<run-id>` in documentation and examples. Never record real machine paths,
secrets, credentials, sessions, caches, `config.toml`, or OpenClaw machine
state in a report.
