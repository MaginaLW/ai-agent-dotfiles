# Local Run Reports

Repository commands, such as `scripts/build-skills.ps1`, may write paired human-readable
Markdown and machine-readable JSON reports here.

Generated reports, logs, manifests, and sidecars are machine- and run-specific
operational artifacts. They are ignored by Git, including files in nested
directories. This README is the only tracked file in this directory. A successful
secret scan does not make a report suitable for committing: metadata and filenames
can still identify a machine, account, or private path.

Reports should contain only summary fields, safe skill names, and next actions. Never
include backup or file contents, credentials, private keys, tokens, VPS/node
configuration, sessions, caches, or `config.toml` contents.

Import inventory, analysis, dedupe and auto-merge reports under `imports/skills-reports/`
are also local evidence, including names containing a machine or batch identifier.
Historical permission to commit import reports is superseded by these rules and
`AGENTS.md`.

For existing tracked reports, first review the exact file list and dependencies,
then remove only those files from the Git index while preserving their local
bytes. Ignore future outputs. Do not delete or move originals, re-add redacted
raw reports, or rewrite history as part of routine hygiene. Removing tracking
does not remove earlier committed data.

Durable project records belong in the existing `status/active/` or
`status/archived/` task record. Write a reviewed summary with the operation,
commit, relevant counts, outcome, and unresolved limitations. Omit machine names,
user names, account values, machine-bearing filenames, and local absolute paths.
Use placeholders such as `<repo-root>`, `<home-root>`, `<machine-id>` and `<run-id>`
in documentation and examples. Do not copy raw evidence into tracked documentation
or commit messages.
