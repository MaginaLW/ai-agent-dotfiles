# ai-agent-dotfiles 使用说明

面向"未来的我"和"接手的 Claude Code / Codex agent"。看完这份手册即可独立维护本项目。

当前状态摘要见 [CURRENT_STATE.md](CURRENT_STATE.md)；恢复操作见 [RESTORE.md](RESTORE.md)；历史报告与计划见 [archive/](archive/)。

---

## 1. 项目目的

统一管理多台电脑上的 Claude / Codex skills：

- 用 Git 维护**唯一可信源** `skills-source/`。
- 用 `scripts/build-skills.ps1` 从源生成 Claude / Codex 的 runtime output。
- 用 `scripts/sync.ps1` 安全地把生成结果部署到本机 live skills 目录。
- 用 `scripts/backup.ps1` 在每次 Apply 前保留可恢复副本。
- 用 repo-local Git hooks 在相关 `git pull` / rebase / branch checkout 后自动运行受控同步。

设计原则：保守、可审计、默认 dry-run、绝不整目录覆盖、绝不碰平台内置目录。

---

## 2. 当前管理范围

### 会同步
- `skills-source/shared/*`（跨平台，Claude + Codex 都装）
- `skills-source/claude-only/*`
- `skills-source/codex-only/*`
- 生成到 `claude/skills/` 和 `codex/skills/`（Git-ignored）
- 部署到本机 live：
  - Claude：`~/.claude/skills`
  - Codex：`~/.codex/skills`；仅当它不存在时才 fallback 到 `~/.agents/skills`

### 不会同步
- Codex `~/.codex/skills/.system`（平台内置，永远保留）
- `imports/`（原始导入、归档、隔离）
- `backup`（备份目录，在 repo 外）
- 整个 live home 目录
- generated output 不进 Git
- 机器私有配置、API keys / tokens / secrets
- 临时日志
- quarantine 原始副本

---

## 3. 目录说明

| 路径 | 说明 |
|---|---|
| `bootstrap.ps1` | 新 clone 的固定入口：安装 auto-sync hooks，并默认执行首次 live sync |
| `skills-source/` | **唯一可信源**，手工维护的 skill 树 |
| `skills-source/shared/` | 跨平台 skill（生成到 Claude 和 Codex 两边） |
| `skills-source/claude-only/` | 仅 Claude 的 skill |
| `skills-source/codex-only/` | 仅 Codex 的 skill（如 `hatch-pet`） |
| `claude/skills/` | **生成物**，Git-ignored，勿手改 |
| `codex/skills/` | **生成物**，Git-ignored，勿手改 |
| `manifests/managed-skills.txt` | 本仓库托管的 skill 名单（sync 的 prune 只作用于名单内条目） |
| `scripts/build-skills.ps1` | 从源生成 runtime output，并刷新 manifest |
| `scripts/scan-secrets.ps1` | secret 扫描（gitleaks + 自定义回退扫描器） |
| `scripts/backup.ps1` | 备份 live Claude/Codex skills（含 `.system`）到 repo 外 |
| `scripts/sync.ps1` | manifest 限定的受控同步，默认 dry-run |
| `scripts/auto-sync-after-git.ps1` | Git hook runner；相关路径变化后调用 `sync.ps1 -Apply` |
| `scripts/apply-hooks.ps1` | 安装 repo-local Git auto-sync hooks |
| `imports/skills-inbox/` | 待审计的原始导入 skill |
| `imports/skills-archive/` | 已处理的导入归档 |
| `imports/skills-quarantine/` | 含 secret/异常、被隔离的 skill |
| `docs/archive/` | 历史状态报告、部署报告、旧计划 |

---

## 4. 日常同步流程

Git 出于安全原因不会在 `git clone` 时执行仓库里的 hook。每个新 clone 的固定入口是：

```powershell
git clone <repo-url> C:\Repos\ai-agent-dotfiles
cd C:\Repos\ai-agent-dotfiles
pwsh -NoProfile -File .\bootstrap.ps1
```

`bootstrap.ps1` 会安装 repo-local auto-sync hooks，并立即通过 `auto-sync-after-git.ps1 -Force`
执行一次 `sync.ps1 -Apply`，所以初次 clone 后不会再漏掉 live skills 同步。

手动维护流程仍然可用：

```powershell
cd C:\Repos\ai-agent-dotfiles
git pull --ff-only

pwsh -NoProfile -File scripts/build-skills.ps1     # 从源生成 runtime output
pwsh -NoProfile -File scripts/scan-secrets.ps1     # 检查 secrets
pwsh -NoProfile -File scripts/sync.ps1             # dry-run：预览会同步什么
pwsh -NoProfile -File scripts/sync.ps1 -Apply      # 真实同步（自动先 build + scan + backup）
```

`sync.ps1` 默认是 **dry-run**，只打印计划、不动 live；只有 `-Apply` 才会真正修改。

如果只想安装 hooks、不执行首次 live 同步：

```powershell
pwsh -NoProfile -File .\bootstrap.ps1 -SkipInitialSync
```

安装后，`post-merge`、`post-checkout`、`post-rewrite` 会在 skill 管理相关路径变化时自动调用
`sync.ps1 -Apply`。自动同步仍然走 build、secret scan、backup、manifest-scoped sync 和 `.system`
保护；日志写在 `.git/ai-agent-dotfiles/auto-sync.log`。

---

## 5. 修改已有 skill 的流程

1. 只改 `skills-source/`（**不要**直接改 `claude/skills/` 或 `codex/skills/`）。
2. `scripts/build-skills.ps1`
3. `scripts/scan-secrets.ps1`
4. `scripts/sync.ps1`（dry-run 预览）
5. `scripts/sync.ps1 -Apply`
6. 提交 source / manifest / docs 变更（**不要**提交 generated output）。
7. `git push`
8. 其它电脑若已安装 auto-sync hooks，`git pull --ff-only` 后会自动同步；否则手动运行 `sync.ps1 -Apply`。

---

## 6. 新增 skill 的流程

- 跨平台：`skills-source/shared/<skill-name>/`
- Claude-only：`skills-source/claude-only/<skill-name>/`
- Codex-only：`skills-source/codex-only/<skill-name>/`
- 每个 skill 至少要有 `SKILL.md`。
- 若来自其它电脑或 inbox，先审计：
  - 是否重复
  - 是否含 secrets
  - 是否含机器私有路径（如 `C:\Users\<name>`）
  - 该归 shared / claude-only / codex-only
- manifest 由 `build-skills.ps1` 自动刷新（名单来自源目录），不要手改。
- build 后确认 `Built Claude skills: N` / `Built Codex skills: M` 数量变化符合预期。

---

## 7. 不能做的事情

- 不要手动编辑 generated output（`claude/skills/`、`codex/skills/`）。
- 不要提交 `claude/skills/` / `codex/skills/`。
- 不要提交 `imports/`、backup、live home 目录。
- 不要删除 `~/.codex/skills/.system`。
- 不要对 `~/.codex/skills` 用整目录 `robocopy /MIR`。
- 不要 whitelist 或削弱 secret scan gate。
- 不要把明文 key / token 写进 skill。

---

## 8. Codex `.system` 规则

- `.system` 是 Codex CLI **平台内置目录**（标记文件 `.codex-system-skills.marker`）。
- 含平台能力：`imagegen`、`openai-docs`、`plugin-creator`、`skill-creator`、`skill-installer`。
- backup 会**完整备份**它。
- sync **永远跳过**它（不更新、不删除）。
- 它**不属于** repo-managed skill。
- 删除它可能破坏 Codex 原生能力。

---

## 9. backup / restore

- `sync.ps1 -Apply` 会**自动 backup**（在改动前）。
- 手动备份：
  ```powershell
  pwsh -NoProfile -File scripts/backup.ps1
  ```
- 预览备份（不复制）：
  ```powershell
  pwsh -NoProfile -File scripts/backup.ps1 -DryRun
  ```
- 默认备份位置（repo 外）：
  ```text
  %USERPROFILE%\.ai-agent-dotfiles-backups
  ```
- 恢复操作详见 [RESTORE.md](RESTORE.md)。

---

## 10. 多电脑同步流程

一台电脑修改并 push 后，另一台：

```powershell
cd C:\Repos\ai-agent-dotfiles
pwsh -NoProfile -File .\bootstrap.ps1                  # 每个 clone 运行一次；安装 hooks 并首次同步
git pull --ff-only                                     # 后续相关更新会由 hooks 自动同步
```

如果没有安装 auto-sync hooks，仍可使用手动流程：

```powershell
pwsh -NoProfile -File scripts/build-skills.ps1
pwsh -NoProfile -File scripts/scan-secrets.ps1
pwsh -NoProfile -File scripts/sync.ps1
pwsh -NoProfile -File scripts/sync.ps1 -Apply
```

---

## 11. 当前状态摘要

- Previous baseline commit：`f2639a5`
- Claude：15
- Codex：21 + `.system`
- 已在 `DESKTOP-3GMDAB7`、`MAGINA-LAPTOP` 验收通过；其它机器 clone 后运行 `bootstrap.ps1`
- 详见 [CURRENT_STATE.md](CURRENT_STATE.md)

---

## 12. 常见问题

**Q：为什么 sync dry-run 显示一堆 `would update` 但没问题？**
A：`update` 只表示该 skill 在源和 live 中都存在、会被受控重新同步到与源一致。若内容本就一致，结果是等效 no-op。关键看的是 `add` / `prune` / `unknown` 是否符合预期。

**Q：为什么 Codex 比 repo 多一个 `.system`？**
A：`.system` 是 Codex 平台自带目录，不由本仓库管理。live 校验时排除它即可（`Codex 21 managed + .system`）。

**Q：为什么 generated output 不提交？**
A：`claude/skills/`、`codex/skills/` 是由 `build-skills.ps1` 从 `skills-source/` 生成的，属派生物，已 Git-ignored；提交它会造成源与产物双份维护和漂移。

**Q：新电脑第一次部署怎么办？**
A：`git clone` → `bootstrap.ps1`。bootstrap 会安装 auto-sync hooks，并立即走 `sync.ps1 -Apply` 的 build、secret scan、backup、manifest-scoped sync、`.system` 保护流程。之后相关 `git pull` / rebase / branch checkout 会自动同步。Claude live 目录不存在时会自动创建。

**Q：scan-secrets 报 false positive 怎么办？**
A：优先**改写源文档/示例措辞**让它不再像真实密钥——例如把"给 `secret` 键直接赋一个带引号的明文字符串"这类示例，改写成描述性文字（说明应从环境变量或密钥管理器读取）。**不要** whitelist，**不要**削弱 scan gate。改完重新 build + scan。
