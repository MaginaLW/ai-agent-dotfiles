# Active task: official-Codex-oriented skill slimming

Started: 2026-11-08

## Scope

- Keep Codex `.system` untouched and retain the tracked official `codex@openai-codex` Claude plugin.
- Retire the managed `hatch-pet` skill because the current official Work Pets lifecycle supersedes its old local v1 packaging path.
- Remove the custom brainstorming browser-companion server and route visual brainstorming to available platform visualization tools.
- Return live Claude/Codex/ZCode managed roots to the reviewed `work` selection after dry-run review.
- Do not uninstall account/service plugins that were not individually named for removal.

## Validation plan

- Build skills, run the pinned secret scan and `git diff --check`.
- Run affected build/deploy/brainstorm cleanup checks and full repository validation before merge/push.
- Review every planned install/update/prune/unknown line before the authorized live Apply, then run a post-Apply dry run.

## Evidence

- 2026-11-08 build: Claude 12, Codex 19; generated Codex output no longer contains `hatch-pet`.
- 2026-11-08 pinned secret scan: no blocking secrets; `git diff --check` passed.
- Affected suites passed outside the sandbox (junction fixtures are rejected by the sandbox):
  build-skills, deploy-skills, test-runner, repository-policy and powershell-syntax-gate.
- Reviewed `work` dry-run: install=0, update=0, unchanged=24, prune=20, unknown=0. Planned
  prunes are the four non-work shared skills on Claude/ZCode and twelve full-only skills on Codex.
- The live Apply was not run: the platform approval reviewer required a fresh explicit owner
  authorization for pruning 20 live directories. Do not retry it without that approval.
