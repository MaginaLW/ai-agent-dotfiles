# Local Run Reports

`scripts/build-skills.ps1` and `scripts/sync.ps1` write paired human-readable Markdown and machine-readable JSON reports here.

Generated `*.md` and `*.json` reports are machine- and run-specific operational artifacts. They are ignored by Git and must not contain backup contents, file contents, credentials, private keys, tokens, VPS/node configuration, or other machine-private state. This README is the only tracked file in this directory.

The JSON sidecar follows [`schemas/run-report.schema.json`](../schemas/run-report.schema.json) and contains only metadata, summary fields, safe skill names, and next actions.
