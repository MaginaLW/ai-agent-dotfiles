# Auto-Merge Report

Mode: apply
Scanned skills: 6

Merged to shared: 4
- git-review
- paper-polish
- path-risk
- placeholder-ok

Merged to claude-only: 0

Merged to codex-only: 1
- codex-repo-maintainer

Archived copies: 11
- codex-repo-maintainer: previous-source -> imports/skills-archive/previous-source/codex-repo-maintainer
- codex-repo-maintainer: merged-inbox-copy -> imports/skills-archive/merged/fake-pc/codex/codex-repo-maintainer
- git-review: previous-source -> imports/skills-archive/previous-source/git-review
- git-review: merged-inbox-copy -> imports/skills-archive/merged/fake-pc/claude/git-review
- git-review: merged-inbox-copy -> imports/skills-archive/merged/fake-pc/codex/git-review
- paper-polish: previous-source -> imports/skills-archive/previous-source/paper-polish
- paper-polish: merged-inbox-copy -> imports/skills-archive/merged/fake-pc/claude/paper-polish
- path-risk: previous-source -> imports/skills-archive/previous-source/path-risk
- path-risk: merged-inbox-copy -> imports/skills-archive/merged/fake-pc/codex/path-risk
- placeholder-ok: previous-source -> imports/skills-archive/previous-source/placeholder-ok
- placeholder-ok: merged-inbox-copy -> imports/skills-archive/merged/fake-pc/codex/placeholder-ok

Quarantined skills: 0
- none

Path rewrites: 1
- path-risk: imports/skills-inbox/fake-pc/codex/path-risk/SKILL.md Windows user path normalized -> $HOME

## Final skills-source Structure
- codex-only/codex-repo-maintainer
- shared/git-review
- shared/paper-polish
- shared/path-risk
- shared/placeholder-ok

## Build Result

```text
Built Claude skills: 4
Built Codex skills: 5
Updated manifest: C:\Repos\ai-agent-dotfiles\manifests\managed-skills.txt
```

## Scan Result

```text
Running gitleaks from <gitleaks executable>

    ○
    │╲
    │ ○
    ○ ░
    ░    gitleaks

8:20AM INF scanned ~320874 bytes (320.87 KB) in 17.8ms
8:20AM INF no leaks found
WARN: Keyword hints found (non-blocking): 78

File                                   Line Pattern
----                                   ---- -------
.gitleaks.toml                            1 Keyword hint
.gitleaks.toml                           25 Keyword hint
.gitleaks.toml                           31 Keyword hint
.gitleaks.toml                           36 Keyword hint
.gitleaks.toml                           37 Keyword hint
.gitleaks.toml                           48 Keyword hint
.gitleaks.toml                           49 Keyword hint
.gitleaks.toml                           50 Keyword hint
.gitleaks.toml                           51 Keyword hint
.gitleaks.toml                           54 Keyword hint
.gitleaks.toml                           56 Keyword hint
.gitleaks.toml                           57 Keyword hint
README.md                                19 Keyword hint
docs\ai-agent-dotfiles-sync-plan-v2.md    7 Keyword hint
docs\ai-agent-dotfiles-sync-plan-v2.md   11 Keyword hint
docs\ai-agent-dotfiles-sync-plan-v2.md   72 Keyword hint
docs\ai-agent-dotfiles-sync-plan-v2.md   77 Keyword hint
docs\ai-agent-dotfiles-sync-plan-v2.md  191 Keyword hint
docs\ai-agent-dotfiles-sync-plan-v2.md  201 Keyword hint
docs\ai-agent-dotfiles-sync-plan-v2.md  268 Keyword hint


WARN: 58 additional keyword hints suppressed.
No blocking secrets found.
```
