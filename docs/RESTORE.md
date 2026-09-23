# Restore and Environment Rollback

> Check [current release and acceptance state](../STATUS.md#current-state) first. A released policy
> can reach mutation paths; it is not candidate acceptance or deployment authorization. These Apply
> examples describe the reviewed contract and require the applicable authorization and acceptance.
> Maintenance validation uses proven isolated fixtures, not an expected production rejection.
> Hooks and bootstrap never perform rollback, recovery or retirement.

Environment rollback and whole-home recovery are different operations. The
repository-managed rollback is intentionally narrow: it restores only the
Claude/Codex/Reasonix managed targets bound by the selected receipt and the previous environment selection.
It does not restore arbitrary home files or machine state.

Backups are created outside the repository. Keep the backup root and its
contents private; documentation and run reports should record only a safe
backup reference, never backup contents.

All commands below use placeholders. Replace them with reviewed values without
putting the resulting machine paths or backup data into Git.

## 1. Environment rollback (preferred)

Use `env rollback` with the COMPLETE receipt directory of a previous `env activate`
run. The legacy `-RunId`/`-BackupPath` selection is removed: only the receipt
selects a rollback, and the reviewed plan is derived from it. `-ReceiptPath` is the directory
containing `_meta/receipt.json` and `_meta/COMPLETE`, not the JSON file. Keep the original
transaction and snapshot evidence intact. Ordinary rollback is for a committed activation;
an unfinished transaction uses the recovery route in section 3 instead.

```powershell
$RepoRoot = '<origin-repo-root>'
$ReceiptPath = '<complete-environment-receipt-directory>'
$PlanPath = '<new-external-plan.json>'

pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env rollback `
  -RepoRoot $RepoRoot `
  -ReceiptPath $ReceiptPath `
  -DryRun -PlanPath $PlanPath
```

The plan parent must exist outside the worktree, Git internals, live roots and safety roots;
the DryRun path must be create-new. Only after reviewing the plan and satisfying the applicable
authorization and acceptance, apply the exact same plan from the same origin worktree:

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env rollback `
  -RepoRoot $RepoRoot `
  -ReceiptPath $ReceiptPath `
  -Apply -PlanPath $PlanPath
```

`env rollback -Apply` requires all of the following:

- exactly one explicit mode, `-DryRun` or `-Apply`;
- a COMPLETE receipt whose `SourceOperationKind` is `environment`;
- the receipt's source transaction retained, `committed`, and byte-identical
  to its retained header/result/terminal chain;
- the origin repository and any bound worktree overlay lock identity match;
- the current environment state still matches that activation's terminal
  poststate, with an unchanged tracked overlay baseline;
- the same external plan produced by the preceding dry-run, with no plan drift.

The operation derives its target set from the receipt's managed snapshot rows for Claude,
Codex and Reasonix, and binds those rows into the reviewed rollback plan. It does not use
today's manifest to invent replacement targets. It restores the previous environment selection
with an advanced authority generation and a new receipt/journal; it does not rewind generation.
It does not touch:

- unknown live skill directories;
- Codex `.system`;
- credentials, sessions, or caches;
- Codex `config.toml`.


If the selected backup is not an environment activation backup, or if its
metadata and plan do not validate, stop and select a different reviewed run.

## 2. Verify the result

Use the read-only status command after rollback:

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env status -RepoRoot $RepoRoot
```

For the active environment, review `lock validity`, `definition drift`,
`live parity`, Codex `.system` status, and `backup reference`. A backup
reference is an audit pointer only; it is not a license to copy arbitrary
backup content into live directories.

Also verify exit code, any typed result, COMPLETE receipt and the unique terminal journal/state
evidence. A zero-change rollback still has to complete the state/receipt/journal protocol;
unchanged live bytes alone do not prove success. Preserve failures and check recovery status.

If current canonical skills should be redeployed, first select the qualified route with
`env authority status`; an existing authority normally uses a new `env activate` plan, while
plain sync is restricted to pristine initial or explicit retirement. Review and apply
the same plan only with the applicable authorization. Do not reverse-copy live or
backup trees into `skills-source/`, generated output, or the live roots.

## 3. Recover an unfinished transaction

Read the relevant namespace first; canonical source/setup and live transactions have separate
recovery entry points:

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 canonical recover status -RepoRoot $RepoRoot
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 live recover status
```

Live recovery reports `abandon-eligible` → `abandon`, `rollback-required` → `rollback`, or
`finalize-eligible` → `finalize`; its `clean` namespace needs no recovery. Canonical recovery instead
emits a typed `MessageToken` of `canonical-recover-abandon`, `canonical-recover-rollback` or
`canonical-recover-finalize`: use that action and the `TransactionId` from the same result.
`no-canonical-transaction` needs no recovery. For `operation-lock-busy` or
`canonical-recovery-status-retry`, wait for the competing operation and read status again.

A `manual-recovery-required` result requires evidence review; never guess an action or delete
journals, locks, claims or private roots.

For a qualified live transaction, create a new external recovery plan, review it, then consume
the same plan only within the authorized recovery scope:

```powershell
$TransactionId = '<reported-transaction-id>'
$RecoveryPlan = '<new-external-recovery-plan.json>'
# Example only for a transaction reported rollback-required.
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 live recover rollback `
  -RepoRoot $RepoRoot -TransactionId $TransactionId -DryRun -PlanPath $RecoveryPlan
# After review, acceptance and applicable authorization:
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 live recover rollback `
  -RepoRoot $RepoRoot -TransactionId $TransactionId -Apply -PlanPath $RecoveryPlan
```

Canonical recovery uses `canonical recover <qualified-action>` with the same explicit
`-RepoRoot`, `-TransactionId`, mode and `-PlanPath` shape. These plans and namespaces are not
interchangeable. Re-read recovery status after execution and require the expected terminal
result before resuming deployment. Do not replace unfinished recovery with `env rollback`.

## 4. Codex `.system` rule

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
