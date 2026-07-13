# Restore and Environment Rollback

Environment rollback and whole-home recovery are different operations. The
repository-managed rollback is intentionally narrow: it restores only the
current Claude/Codex managed skill set and the previous environment state.
It does not restore arbitrary home files or machine state.

Backups are created outside the repository. Keep the backup root and its
contents private; documentation and run reports should record only a safe
backup reference, never backup contents.

All commands below use placeholders. Replace them with reviewed values without
putting the resulting machine paths or backup data into Git.

## 1. Environment rollback (preferred)

Use `env rollback` for a previous `env activate -Apply` run. First generate a
plan and inspect the managed action list:

```powershell
$BackupRoot = '<external-backup-root>'
$PlanPath = '<external-plan.json>'

pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env rollback `
  -RunId '<reviewed-run-id>' -BackupRoot $BackupRoot `
  -DryRun -PlanPath $PlanPath
```

Only after reviewing the plan, apply the exact same plan:

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env rollback `
  -RunId '<reviewed-run-id>' -BackupRoot $BackupRoot `
  -Apply -PlanPath $PlanPath
```

`env rollback -Apply` requires all of the following:

- exactly one explicit mode, `-DryRun` or `-Apply`;
- a selected activation backup with valid backup and activation metadata;
- the current environment state still matches the selected activation;
- the same external plan produced by the preceding dry-run, with no plan drift.

The operation restores only skill directories named by the current
`manifests/managed-skills.claude.txt` and
`manifests/managed-skills.codex.txt`, plus the environment state record. It
does not touch:

- unknown live skill directories;
- Codex `.system`;
- credentials, sessions, or caches;
- Codex `config.toml`;
- OpenClaw machine state, identity, plugin installs, or workspace state.

If the selected backup is not an environment activation backup, or if its
metadata and plan do not validate, stop and select a different reviewed run.

## 2. Verify the result

Use the read-only status command after rollback:

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env status
```

For the active environment, review `lock validity`, `definition drift`,
`live parity`, Codex `.system` status, and `backup reference`. A backup
reference is an audit pointer only; it is not a license to copy arbitrary
backup content into live directories.

If canonical generated skills must be restored instead, use the normal
manifest-scoped sync workflow: generate a dry-run plan, review it, and apply
the same plan only with explicit authorization. Do not reverse-copy live or
backup trees into `skills-source/`, generated output, or the live roots.

## 3. Codex `.system` rule

Codex `.system` is platform-managed and is outside environment activation and
rollback. Never edit, move, overwrite, prune, delete, or mirror it from this
repository. If it is missing or damaged, stop the repository workflow and use
the Codex/platform recovery path separately.

## Rules

- Keep backups outside the repository and never stage or commit them.
- Do not place backup contents, credentials, tokens, sessions, caches, or
  machine-private paths in docs or reports.
- Do not use whole-directory mirroring against live skill roots.
- Do not use manual backup copying as a substitute for the manifest-scoped,
  plan-bound rollback workflow.
