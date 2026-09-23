# New Windows Machine Onboarding

Use this guide to reconcile a Windows identity with the canonical repository and select the correct
plan-bound route. Read [STATUS.md current state](../STATUS.md#current-state) first: a released policy
does not prove candidate acceptance or authorize live deployment. Maintenance validation uses an
isolated fixture; an explicitly scoped machine checkpoint may read status and create DryRun evidence,
then stops before Apply. The Apply examples below describe the contract for separately authorized work.

Use PowerShell 7+, preserve unknown local skills, and never traverse, copy, hash, count the contents of,
or modify Codex `.system`. Its allowed root/marker metadata is sufficient for the repository checks.
Keep plans, receipts, logs, machine names and private paths outside Git.

## 1. Verify tools and clone

```powershell
git --version
$PSVersionTable.PSVersion
Get-Command pwsh
$RepoUrl = Read-Host 'Repository SSH or HTTPS URL, without embedded credentials'
$RepoRoot = '<repo-root>'
git clone $RepoUrl $RepoRoot
Set-Location $RepoRoot
git status --short --branch --untracked-files=all
pwsh -NoProfile -File .\bootstrap.ps1
```

Choose a repository root outside the live and private safety roots. Bootstrap installs inert or
approved Git-private wrappers, then checks the pinned schema validator, pinned gitleaks and runner
approval in that order. Follow the exact dependency command it prints; obtain the applicable runner
approval before running its approval command, then invoke bootstrap again. Bootstrap and hooks produce
preview/events only; they never produce an actionable plan or Apply live changes. `-SkipInitialPlan`
skips only the optional preview diagnostic. Do not infer isolation from an expected rejection.

## 2. Check the repository and retain local evidence

```powershell
pwsh -NoProfile -File .\scripts\doctor.ps1 -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw 'Doctor failed; inspect the reported cause.' }
pwsh -NoProfile -File .\scripts\scan-secrets.ps1 -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw 'Baseline secret scan failed.' }
```

Review warnings and existing changes before proceeding. Do not bypass the scanner or substitute a
previous machine's results. The public standalone `backup.ps1` is retired: it writes nothing and
returns `backup-is-transaction-internal` (exit 1), including with `-DryRun`. Do not run it as a
prerequisite or copy arbitrary backup trees into live roots. Managed Apply creates its own bound
receipt and snapshot through the transaction host. Whole-home recovery, if needed, is a separate
platform/owner operation and must not include repository-driven copying of `.system`.

Create a new external evidence directory on the current machine. It must be outside the worktree,
Git internals, live roots and private safety roots; each plan filename must be create-new. Preserve
the generated plan and its bound materialization/candidate files together, unchanged, through review.

```powershell
$EvidenceRoot = Join-Path ([IO.Path]::GetTempPath()) ('ai-agent-dotfiles-onboard-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $EvidenceRoot | Out-Null
```

## 3. Import only reviewed local skill directories

Import is optional: skip it when no local skill needs reconciliation. Import reads local directories
and writes an ignored inbox only; it does not make imported content canonical. A local machine label
may select `imports/skills-inbox/<local-label>/`, but neither that label nor the real machine name
belongs in tracked notes, filenames or commit messages.

```powershell
$ComputerName = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($ComputerName)) { throw 'Local machine label is unavailable.' }
$LocalLabel = $ComputerName.ToLowerInvariant()
$InboxRoot = Join-Path $RepoRoot "imports\skills-inbox\$LocalLabel"
if (Test-Path -LiteralPath $InboxRoot) { throw 'Inbox exists; review it without overwriting.' }
New-Item -ItemType Directory -Path $InboxRoot | Out-Null
```

Select exact skill directories containing `SKILL.md` from Claude, Codex and/or Reasonix. Codex uses
the existing preferred `.codex/skills` root or, when absent, `.agents/skills`; Reasonix uses the
claimed root, normally the Windows Roaming AppData `reasonix/skills` directory. Reject reparse points,
name collisions, missing manifests and `.system` before copying a reviewed directory to its platform
inbox. Do not recursively copy home roots, plugin caches, credentials, sessions or configuration.

```powershell
pwsh -NoProfile -File .\scripts\analyze-skills.ps1 -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw 'Skill analysis failed.' }
pwsh -NoProfile -File .\scripts\dedupe-skills.ps1 -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw 'Dedupe analysis failed.' }
pwsh -NoProfile -File .\scripts\scan-secrets.ps1 -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw 'Post-import secret scan failed.' }
```

Keep all raw reports under ignored `imports/skills-reports/`. Resolve same-name differences, empty
shells, sensitive values and unexplained paths before promotion. Promotion/merge is a separate
canonical transaction: it requires canonical readiness, its own create-new external `-PlanPath`,
review, and the same plan on authorized Apply. Do not run auto-merge Apply as an onboarding shortcut.
Never reverse-copy live contents over `skills-source/` or edit generated output to resolve a conflict.

## 4. Build and scan the canonical baseline

```powershell
pwsh -NoProfile -File .\scripts\build-skills.ps1 -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw 'Skill build failed.' }
pwsh -NoProfile -File .\scripts\scan-secrets.ps1 -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw 'Post-build secret scan failed.' }
```

Review Claude, Codex and Reasonix counts against the selected source. Generated roots and `envs/`
staging are disposable, ignored output. A build validates source; it does not deploy any live skills.

## 5. Select the machine route

Run canonical status first, then interpret its typed result as well as its exit code:

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 canonical status -RepoRoot $RepoRoot
```

- `canonical-ready`: in a **new invocation**, run `env authority status` below.
- `canonical-setup-required`: use the setup sequence below. For a pristine identity, the initial
  sync DryRun must precede setup; do not create the control base first.
- `canonical-recovery-required`, `setup-finalize-required` or `manual-recovery-required`: inspect
  `canonical recover status` and follow the evidence-qualified route in [RESTORE.md](RESTORE.md).
  Do not repeat setup or delete a lock, claim or journal to force a clean state.

When canonical-ready:

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 env authority status -RepoRoot $RepoRoot
```

The status command emits one route. Its short next-operation hint may omit a required plan path;
use the complete invocation below. Do not default to `work` or `full` for an existing machine.

| Route | Required next step |
|---|---|
| `activate` | Select the intended environment and create an `env activate` plan. |
| `migrate` | Use the verified legacy environment name and exact repo-local legacy state locator with `-LegacyStatePath` on both invocations. |
| `adopt` | Select and review an environment for the observed non-pristine roots; use `env authority adopt`. |
| `repair-adopt` | Use the status-qualified environment; pass `-CorruptStatePath` only for the CORRUPT-state branch, never the MISSING-state branch. |
| `takeover` | Use the existing verified selection; this changes controller ownership, not the selected environment. |
| `recovery` | Run `live recover status`; complete the qualified recovery route before new deployment. |
| `controller-owner-action-required` / `manual-recovery-required` | Preserve evidence and resolve the indicated owner/evidence problem; do not guess a mutator. |
| `initial` | Requires a pristine sync plan created before canonical setup; follow the sequence below. If setup already exists and no such plan exists, stop for route review rather than deleting private roots. |

### Pristine initial and canonical setup sequence

Plain sync can create an initial plan only when all three live skills roots and the control base are
absent. It materializes the named `full` environment; an existing Codex root, including one containing
only `.system`, is not pristine. Do not delete existing roots to qualify.

For a pristine identity, generate and review this plan **before** canonical setup:

```powershell
$InitialPlan = Join-Path $EvidenceRoot 'initial-plan.json'
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 sync -RepoRoot $RepoRoot -DryRun -PlanPath $InitialPlan
if ($LASTEXITCODE -ne 0) { throw 'Initial plan failed; inspect the route, do not remove existing state.' }
```

For a non-pristine identity requiring setup, skip the initial command. Generate the separate setup
plan; the public wrapper derives its fixed private roots from Windows identity and the repository:

```powershell
$SetupPlan = Join-Path $EvidenceRoot 'canonical-setup-plan.json'
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 canonical setup -RepoRoot $RepoRoot -DryRun -PlanPath $SetupPlan
if ($LASTEXITCODE -ne 0) { throw 'Canonical setup plan failed.' }
```

**A read-only/DryRun onboarding checkpoint stops here.** Setup Apply creates private authority state;
the ordinary live sandbox helper does not isolate canonical Windows identity. After acceptance,
review and applicable authorization, consume that exact setup plan in its own process:

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 canonical setup -RepoRoot $RepoRoot -Apply -PlanPath $SetupPlan
if ($LASTEXITCODE -ne 0) { throw 'Setup failed; retain typed output and recovery evidence.' }
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 canonical status -RepoRoot $RepoRoot
```

Require `canonical-ready`. For the pristine path, a **new invocation** then consumes the original
initial plan; do not regenerate it after setup, which would fail `live-plan-authority-present`:

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 sync -RepoRoot $RepoRoot -Apply -PlanPath $InitialPlan
if ($LASTEXITCODE -ne 0) { throw 'Initial Apply failed; retain receipt and journal evidence.' }
```

For the non-pristine path, run `env authority status` in a new invocation after setup and use only its
qualified route. Changing `HOME`, `USERPROFILE` or `LOCALAPPDATA` is not Windows identity isolation.

## 6. Create the selected environment or authority plan

For `activate`, choose an environment and a new plan path:

```powershell
$EnvironmentName = '<reviewed-environment-name>'
$EnvironmentPlan = Join-Path $EvidenceRoot 'environment-plan.json'
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 env build $EnvironmentName -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) { throw 'Environment build failed.' }
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 env activate $EnvironmentName -RepoRoot $RepoRoot -DryRun -PlanPath $EnvironmentPlan
if ($LASTEXITCODE -ne 0) { throw 'Environment plan failed.' }
```

For an authority transition, use the exact route, name and evidence selected above. This example
describes migrate; adopt, repair-adopt and takeover have their own route-specific arguments:

```powershell
$EnvironmentName = '<verified-legacy-environment-name>' # From the validated legacy selection, not a new choice.
$LegacyStatePath = Join-Path $RepoRoot 'state/current-env.json'
$AuthorityPlan = Join-Path $EvidenceRoot 'authority-plan.json'
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 env authority migrate -Name $EnvironmentName -RepoRoot $RepoRoot -LegacyStatePath $LegacyStatePath -DryRun -PlanPath $AuthorityPlan
if ($LASTEXITCODE -ne 0) { throw 'Authority plan failed.' }
```

`-ReasonixLiveSkillsPath` is an initial-claim selector for migrate/adopt only, before schema 3 claims
exist; it cannot override an existing immutable claim. Do not pass `-HomeRoot` to public sync or use
internal root overrides as a production identity selector.

Review the operation kind, controller/identity binding, environment/base selection, all platform
add/update/prune targets, unknown preservation, `.system` marker status, receipt intent and bound
materialization. DryRun writes evidence but does not deploy live skills. Do not edit a plan to fix
drift; create and review a new plan at a new path. If this is the Task 9 checkpoint, stop after review.

For authorized deployment, invoke the same command with `-Apply` instead of `-DryRun` and the exact
same plan path, name and route-specific evidence. Environment activation never invents its plan
during Apply. For example, after review and authorization:

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 env activate $EnvironmentName -RepoRoot $RepoRoot -Apply -PlanPath $EnvironmentPlan
if ($LASTEXITCODE -ne 0) { throw 'Activation failed; retain receipt and journal evidence.' }
```

## 7. Verify and record the result

For any executed mutation, check exit code, typed result where emitted, COMPLETE receipt and terminal
journal/state evidence together. A success string alone is insufficient. Retain external evidence;
if the transaction is unfinished, follow [RESTORE.md](RESTORE.md) before any new operation.

```powershell
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 env authority status -RepoRoot $RepoRoot
pwsh -NoProfile -File .\scripts\agent-dotfiles.ps1 env status -RepoRoot $RepoRoot
pwsh -NoProfile -File .\scripts\scan-secrets.ps1 -RepoRoot $RepoRoot
git diff --check
git status --short --untracked-files=all
```

Review claims/state pairing, controller, generation, lock validity, definition drift, live parity,
unknown preservation and `.system` marker status. An environment rollback selects the COMPLETE
environment **receipt directory**, not a run ID or a JSON file; see the restore guide. Config pull
is a separately reviewed home configuration operation and is not part of activation or rollback.

Add only a concise, sanitized result to the existing task record: candidate SHA, route, checks,
PASS/FAIL/unknown, and remaining decision. Keep raw reports and the real machine identity local.
Review and stage exact source/manifest/documentation files, then make a coherent local commit such as
`docs: record onboarding verification`. Do not create an empty commit when no tracked change is needed.
Publishing still needs its applicable authorization.

## Completion checklist

- [ ] Current release/acceptance state and machine scope were checked.
- [ ] PowerShell 7+, bootstrap dependencies and applicable runner approval were verified.
- [ ] Imports, if needed, stayed in the ignored inbox; no `.system` contents were read or copied.
- [ ] Build and secret scan passed for all three platforms.
- [ ] Canonical status and the route-specific preconditions selected the operation.
- [ ] Pristine initial planning preceded setup, if that route applied.
- [ ] External create-new plans and bound materializations were reviewed; Task 9 stopped before Apply.
- [ ] Any separately authorized Apply has complete exit/result/receipt/journal/state evidence.
- [ ] Tracked changes and commit messages contain no machine names, usernames or private paths.
