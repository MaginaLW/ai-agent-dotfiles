# Local Run Reports

The repository's operational commands may write paired human-readable Markdown
and machine-readable JSON reports here, including build, scan, sync, config,
profile, skills, and environment operations.

Generated reports, logs, manifests, and sidecars are machine- and run-specific
operational artifacts. They are ignored by Git, including files in nested
directories. This README is the only tracked file in this directory. A successful
secret scan does not make a report suitable for committing: metadata and filenames
can still identify a machine, account, or private path.

The build/sync JSON sidecar follows
[`schemas/run-report.schema.json`](../schemas/run-report.schema.json). Other
commands use their own artifact contracts; do not assume every JSON file is a
run-report payload. Reports should contain only the metadata required by their
contract, summary fields, safe skill names, and next actions. Environment status
and rollback evidence may include lock validity, definition drift, live parity,
Codex `.system` status, plan hashes, previous environment names, and a safe backup
reference. Never include backup or file contents, credentials, private keys,
tokens, VPS/node configuration, sessions, caches, or `config.toml` contents.

`env.lock.json` is a verifiable environment lock in generated staging, not a
run-report payload. Reports may state whether the lock is valid, but must not
embed its file contents or source material.

Import inventory, analysis, and dedupe reports under `imports/skills-reports/`
are also local evidence, including names containing a machine or batch identifier.
Current auto-merge reports belong beside their create-new external plan in
`<external-plan.json>.reports/`; that external location does not make them
publishable. Historical permission to commit import reports is superseded by
these rules and `AGENTS.md`.

For existing tracked reports, first review the exact file list and dependencies,
then remove only those files from the Git index while preserving their local
bytes. Ignore future outputs. Do not delete or move originals, re-add redacted
raw reports, or rewrite history as part of routine hygiene. Removing tracking
does not remove earlier committed data.

Durable project records belong in the existing `status/active/` or
`status/archived/` task record. Write a reviewed summary with the operation,
candidate commit, relevant counts, outcome, and unresolved limitations. Omit
machine names, user names, account values, machine-bearing filenames, and local
absolute paths. Use placeholders such as `<repo-root>`, `<home-root>`,
`<machine-id>`, `<external-plan.json>`, and `<run-id>` in documentation and examples.
Do not copy raw evidence into tracked documentation or commit messages.
