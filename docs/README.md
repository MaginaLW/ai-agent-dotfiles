# ai-agent-dotfiles 使用说明

面向"未来的我"和"接手的 Claude Code / Codex agent"。看完这份手册即可独立维护本项目。

全局状态见 [STATUS.md](../STATUS.md)；新电脑接入见 [ONBOARD_NEW_MACHINE.md](ONBOARD_NEW_MACHINE.md)；skills 合并规则见 [MERGE_POLICY.md](MERGE_POLICY.md)；当前局部任务见 [status/active/](../status/active/)；历史状态见 [status/archived/](../status/archived/)；恢复操作见 [RESTORE.md](RESTORE.md)。

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
- `skills-source/opencode-only/*`
- `opencode/AGENTS.md`、`opencode/commands/`、`opencode/agents/`（便携配置）
- 生成到 `claude/skills/`、`codex/skills/` 和 `opencode/skills/`（Git-ignored）
- 部署到本机 live：
  - Claude：`~/.claude/skills`
  - Codex：`~/.codex/skills`；仅当它不存在时才 fallback 到 `~/.agents/skills`
  - OpenCode：`~/.config/opencode/skills`

### 不会同步
- Codex `~/.codex/skills/.system`（平台内置，永远保留）
- `imports/`（原始导入、归档、隔离）
- `backup`（备份目录，在 repo 外）
- 整个 live home 目录
- generated output 不进 Git
- 机器私有配置、API keys / tokens / secrets
- 临时日志
- quarantine 原始副本
- OpenCode `opencode.json(c)`（含 provider/MCP 等机器私有设置）
- `~/.config/opencode/opencode.json(c)`（机器私有，不纳入仓库）

---

## 3. 目录说明

| 路径 | 说明 |
|---|---|
| `bootstrap.ps1` | 新 clone 的固定入口：安装 auto-sync hooks，并默认执行首次 live sync |
| `STATUS.md` | 唯一全局状态文件，直接更新，不重复新建总体状态报告 |
| `status/active/` | 当前正在进行的局部任务状态 |
| `status/archived/` | 已完成和历史局部任务状态 |
| `.claude/settings.json` | 项目级 harness 护栏（deny 编辑生成物/`.system`、禁 robocopy；allow 安全校验命令） |
| `skills-source/` | **唯一可信源**，手工维护的 skill 树 |
| `skills-source/shared/` | 跨平台 skill（生成到 Claude 和 Codex 两边） |
| `skills-source/claude-only/` | 仅 Claude 的 skill |
| `skills-source/codex-only/` | 仅 Codex 的 skill（如 `hatch-pet`） |
| `claude/skills/` | **生成物**，Git-ignored，勿手改 |
| `codex/skills/` | **生成物**，Git-ignored，勿手改 |
| `opencode/skills/` | **生成物**，Git-ignored，勿手改 |
| `opencode/AGENTS.md` | OpenCode 便携项目指令（config-sync 管理） |
| `manifests/managed-skills.txt` | 本仓库托管的 skill 名单（sync 的 prune 只作用于名单内条目） |
| `scripts/build-skills.ps1` | 从源生成 runtime output，并刷新 manifest |
| `scripts/scan-secrets.ps1` | secret 扫描（gitleaks + 自定义回退扫描器） |
| `scripts/backup.ps1` | 备份 live Claude/Codex skills（含 `.system`）到 repo 外 |
| `scripts/sync.ps1` | manifest 限定的受控同步，默认 dry-run |
| `scripts/config-status.ps1` | 只读 config drift 报告（repo ↔ home），见 §14 |
| `scripts/config-pull.ps1` | 部署 harness 配置 repo→home，默认 dry-run，`-Apply` gated |
| `scripts/config-push.ps1` | 捕获 harness 配置 home→repo，双 gate（扫密 + 私有路径），默认 dry-run |
| `harness-source/` | Project Harness Profiles 的 component/profile 源库，见 §15 |
| `.agent-harness/generated/` | Project Harness Profiles 的项目本地生成物，默认 Git-ignored，可随时重建 |
| `scripts/status-harness-profile.ps1` | 只读查看可用 profile/component 与项目生成状态，见 §15 |
| `scripts/build-harness-profile.ps1` | 从 `harness-source/` 生成项目本地 harness output，见 §15 |
| `scripts/apply-harness-profile.ps1` | 默认 dry-run；`-Apply` 仅写项目本地 allowlist，见 §15 |
| `harness-source/envs/` | Harness Environments 的环境定义（tracked 源），见 §16 |
| `.agent-harness/task-skills.psd1` | 当前分支/worktree 的共享 task skill overlay，见 §16 |
| `harness-source/components/mcp-templates/` | MCP 模板源（只含占位符和环境变量声明），见 §18 |
| `scripts/mcp-common.ps1` / `claude/mcp/apply-mcp.ps1` | MCP 模板验证、计划绑定和 Claude CLI 单服务器操作，见 §18 |
| `envs/` | 环境构建 staging，**生成物**，Git-ignored，勿手改，见 §16 |
| `state/current-env.json` | 当前激活环境记录，机器私有，Git-ignored，见 §16 |
| `scripts/list-harness-env.ps1` | 只读枚举环境定义并标记激活环境，见 §16 |
| `scripts/status-harness-env.ps1` | 只读环境状态/staging 新旧报告，见 §16 |
| `scripts/build-harness-env.ps1` | 构建 `envs/<name>/` staging，只写该目录，见 §16 |
| `scripts/activate-harness-env.ps1` | gated 环境切换，默认 dry-run，部署只经 `sync.ps1`，见 §16 |
| `scripts/task-skills.ps1` | task overlay 的校验、dry-run、addition-only 自动同步和显式 close，见 §16 |
| `scripts/auto-sync-after-git.ps1` | Git hook runner；先生成 fingerprint-bound dry-run，再调用 `sync.ps1 -Apply` |
| `scripts/apply-hooks.ps1` | 安装 repo-local Git auto-sync hooks |
| `imports/skills-inbox/` | 待审计的原始导入 skill |
| `imports/skills-archive/` | 已处理的导入归档 |
| `imports/skills-quarantine/` | 含 secret/异常、被隔离的 skill |
| `docs/archive/` | 历史计划与支持文档；历史状态报告已迁入 `status/archived/` |

---

## 4. 日常同步流程

Git 出于安全原因不会在 `git clone` 时执行仓库里的 hook。每个新 clone 的固定入口是：

```powershell
$RepoRoot = '<repo-root>'
git clone <repo-url> $RepoRoot
Set-Location $RepoRoot
pwsh -NoProfile -File .\bootstrap.ps1
```

`bootstrap.ps1` 会安装 repo-local auto-sync hooks，并进入 fingerprint-bound 的受控 sync
流程。新机器接入时应先使用 `-SkipInitialSync`，完成本文和
[ONBOARD_NEW_MACHINE.md](ONBOARD_NEW_MACHINE.md) 的 dry-run 审查，再执行显式 apply。

手动维护流程仍然可用：

```powershell
Set-Location $RepoRoot
git pull --ff-only

pwsh -NoProfile -File scripts/agent-dotfiles.ps1 build # 从源生成 runtime output
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 scan  # 检查 secrets
$plan = Join-Path $env:TEMP 'ai-agent-dotfiles-sync-plan.json'
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 sync -DryRun -PlanPath $plan # 生成并审查计划
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 sync -Apply -PlanPath $plan # 只应用同一计划
```

`sync.ps1` 默认是 **dry-run**，只打印计划、不动 live；`-Apply` 必须带有先前 dry-run 生成的 `-PlanPath`，并重新验证 source、manifest 和 live fingerprint 后才会修改。

如果只想安装 hooks、不执行首次 live 同步：

```powershell
pwsh -NoProfile -File .\bootstrap.ps1 -SkipInitialSync
```

安装后，`post-merge`、`post-checkout`、`post-rewrite` 会在 skill 管理相关路径变化时自动调用
绑定计划的同步流程。普通源变更走 `sync.ps1 -Apply`；若检测到 task overlay 变更，则走
`env task sync -Apply -Automatic`，只允许 addition-only，绝不因 Git checkout/pull 静默 prune。
自动同步仍然走 build、secret scan、backup、manifest-scoped sync 和 `.system` 保护；日志写在
`.git/ai-agent-dotfiles/auto-sync.log`。

---

## 5. 修改已有 skill 的流程

1. 只改 `skills-source/`（**不要**直接改 `claude/skills/` 或 `codex/skills/`）。
2. `scripts/build-skills.ps1`
3. `scripts/scan-secrets.ps1`
4. `$plan = Join-Path $env:TEMP 'ai-agent-dotfiles-sync-plan.json'`，再运行
   `scripts/sync.ps1 -DryRun -PlanPath $plan` 并审查计划
5. `scripts/sync.ps1 -Apply -PlanPath $plan`
6. 提交 source / manifest / docs 变更（**不要**提交 generated output）。
7. `git push`
8. 其它电脑若已安装 auto-sync hooks，`git pull --ff-only` 后会自动生成并绑定计划；否则手动运行同一 `-DryRun -PlanPath` / `-Apply -PlanPath` 流程。

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
- 不要手改 `opencode/skills/`（它是生成物）。
- 不要提交 `opencode/skills/`。
- `~/.config/opencode/opencode.json(c)` 是机器私有配置——禁止提交。
- OpenCode 的插件通过 `opencode.json` 的 `plugin` 数组声明，不纳入本仓库管理。

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
Set-Location $RepoRoot
pwsh -NoProfile -File .\bootstrap.ps1                  # 每个 clone 运行一次；安装 hooks 并首次同步
git pull --ff-only                                     # 后续相关更新会由 hooks 自动同步
```

如果没有安装 auto-sync hooks，仍可使用手动流程：

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 build
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 scan
$plan = Join-Path $env:TEMP 'ai-agent-dotfiles-sync-plan.json'
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 sync -DryRun -PlanPath $plan
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 sync -Apply -PlanPath $plan
```

---

## 11. OpenClaw 插件管理

OpenClaw 插件通过 `openclaw/plugins/managed-plugins.json` 声明期望的插件状态。
这是一个人工审核过的声明文件，不包含 secrets、本地绝对路径或机器私有数据。

同步插件前，先运行 dry-run：
```powershell
pwsh -NoProfile -File scripts/sync-openclaw-plugins.ps1
```

确认无误后 apply：
```powershell
pwsh -NoProfile -File scripts/sync-openclaw-plugins.ps1 -Apply
```

规则：
- 插件的安装、更新、启用、禁用、卸载必须通过 OpenClaw CLI（`openclaw plugins install` 等），禁止直接编辑 `~/.openclaw/plugins/installs.json`。
- `installs.json` 是机器管理的状态文件，包含绝对路径和生成元数据，**绝不提交**。
- Bundled（内置）插件只能管理 enablement，不能卸载。
- 插件同步会在 `sync.ps1` 中自动调用（当 `managed-plugins.json` 存在时）。
- 只读的 `openclaw plugins list --json` 探测默认有 15 秒超时，可用
  `-CliProbeTimeoutSeconds` 调整；超时后先读取经过字段筛选的 `installs.json`，再尝试
  `~/.openclaw/openclaw.json` 的 `plugins.entries` enablement。
- 新版 OpenClaw 的 `plugins list` 可能把已安装插件来源显示为绝对路径；对受管插件，
  脚本会再通过只读的 `plugins info` 取得 `install.resolvedName`，再做 source 比对，
  避免把正常的 npm 安装误判成 update。
- `openclaw.json` 回退只能证明插件配置中的启用状态，不能证明安装来源/版本与期望一致；
  如果 CLI 和两个安全回退面都不可用，脚本会 fail closed，不把 live 状态当成空目录并规划安装。
- 未纳入托管清单的 live 插件只报告、不安装、不启用、不禁用、不卸载。

---

## 12. 当前状态

- 全局状态、当前阶段、managed counts、机器验证、风险和下一步统一维护在 [STATUS.md](../STATUS.md)。
- 当前局部任务只放在 [status/active/](../status/active/)；任务完成后移动到 [status/archived/](../status/archived/)。
- 不再为总体状态按日期重复新建文件。

---

## 13. 常见问题

**Q：为什么 sync dry-run 显示一堆 `would update` 但没问题？**
A：`update` 只表示该 skill 在源和 live 中都存在、会被受控重新同步到与源一致。若内容本就一致，结果是等效 no-op。关键看的是 `add` / `prune` / `unknown` 是否符合预期。

**Q：为什么 Codex 比 repo-managed 数量多一个 `.system`？**
A：`.system` 是 Codex 平台自带目录，不由本仓库管理。live 校验时排除它即可；当前 managed 数量以 manifest 和 [STATUS.md](../STATUS.md) 为准。

**Q：为什么 generated output 不提交？**
A：`claude/skills/`、`codex/skills/` 是由 `build-skills.ps1` 从 `skills-source/` 生成的，属派生物，已 Git-ignored；提交它会造成源与产物双份维护和漂移。

**Q：新电脑第一次部署怎么办？**
A：`git clone` → `bootstrap.ps1 -SkipInitialSync` → 按 onboarding 文档完成 backup、build、scan、sync dry-run、计划审查，再执行同一计划的显式 apply。后续相关 `git pull` / rebase / branch checkout 才进入受控自动同步流程。Claude live 目录不存在时会自动创建。

**Q：scan-secrets 报 false positive 怎么办？**
A：优先**改写源文档/示例措辞**让它不再像真实密钥——例如把"给 `secret` 键直接赋一个带引号的明文字符串"这类示例，改写成描述性文字（说明应从环境变量或密钥管理器读取）。**不要** whitelist，**不要**削弱 scan gate。改完重新 build + scan。

---

## 14. Harness 配置同步（config-sync）

除 skills 外，仓库还管理 agent harness 配置本身。源同样是 `manifests/whitelist.psd1`
（per-platform 的 Push/Pull items 与 ExcludedItems）。

- `.claude/settings.json`（项目级、已提交）：把硬规则变成 harness 强制 `permissions.deny`
  （禁止 `Edit`/`Write` 生成物 `claude|codex|openclaw/skills/**` 与 Codex `.system`、禁止 robocopy
  整目录 mirror），并 `allow` 安全的校验命令（build-skills / scan-secrets / check-hooks）。
  `sync.ps1` **故意不在** allow 名单，保证 `-Apply` 始终走授权 gate。
- `scripts/config-status.ps1`：只读 drift 报告（repo ↔ `~/.claude`/`~/.codex`），逐项报告
  in-sync / differs / repo-only / home-only，遵守 ExcludedItems，**绝不写**。
- `scripts/config-pull.ps1`：部署 repo→home。默认 dry-run；`-Apply` 先扫密、逐文件备份被覆盖项再复制；
  **绝不整目录 mirror、绝不 prune**（home-only 文件原样保留）。
- `scripts/config-push.ps1`：捕获 home→repo。默认 dry-run；`-Apply` 写入后**双 gate**——扫密 +
  机器私有路径扫描（盘符/UNC 绝对路径），任一命中即**回滚全部捕获**；结果保持未提交供人审。
  `-SkipPathScan` 仅在绝对路径确属有意时使用。

规则：

- pull/push 默认 dry-run，`-Apply` 才动，与 `sync.ps1` 同款保守姿态。
- **config-push 捕获的内容必须人工 `git diff` 审查后再提交**——扫密只挡 token，挡不了机器私有路径。
- Codex `config.toml` **不纳入** config-sync（混杂 `[projects]`/`[mcp_servers]` 等机器私有状态）；
  Codex 侧只同步 `AGENTS.md`/`prompts`。OpenClaw 插件状态仍由 `sync-openclaw-plugins.ps1` 管理。
- 回归测试：`pwsh -NoProfile -File tests/config-sync.tests.ps1`（覆盖三脚本 + 两个 gate、no-prune、幂等）。

---

## 15. Project Harness Profiles

Project Harness Profiles 是第一版项目级 harness 组装能力。它把可复用的 component/profile
定义放在 `harness-source/`，然后为某个项目生成 `.agent-harness/generated/` 下的本地输出。
这套能力只处理项目本地文件，不切换全局 home harness。

常用命令：

```powershell
pwsh -NoProfile -File scripts/status-harness-profile.ps1 -ProjectRoot <project>
pwsh -NoProfile -File scripts/build-harness-profile.ps1 -ProjectRoot <project>
pwsh -NoProfile -File scripts/apply-harness-profile.ps1 -ProjectRoot <project>
pwsh -NoProfile -File scripts/apply-harness-profile.ps1 -ProjectRoot <project> -Apply
pwsh -NoProfile -File tests/harness-profile.tests.ps1
```

脚本职责：

- `scripts/harness-profile-common.ps1`：共享解析、路径和校验 helper。
- `scripts/status-harness-profile.ps1`：只读状态/漂移报告，不写文件。
- `scripts/build-harness-profile.ps1`：只写目标项目的 `.agent-harness/generated/`。
- `scripts/apply-harness-profile.ps1`：默认 dry-run；`-Apply` 只写项目本地 allowlist。

当前受控输出类型包括 Claude `.claude/commands/` 与 `.claude/agents/`、Codex
`.codex/prompts/` 与 `.codex/agents/`，以及只允许项目级键的 `.openclaw/project.json`。
每种类型由 component `Kind` 和独立 output contract 校验；build 会把文件型输出复制到
`.agent-harness/generated/files/`，apply 仍只写对应项目路径。

安全规则：

- `harness-source/` 是 profile/component 的源码；不要手改 `.agent-harness/generated/`。
- `.agent-harness/generated/` 是 disposable generated output，默认 Git-ignored，可删除后重建。
- 第一版 `apply-harness-profile.ps1` 不写 `~/.claude`、`~/.codex`、`~/.openclaw`，也不安装或同步 live skills。
- 第一版不安装 project-local skills，不承诺自动切换全局 harness。
- 变更 profile/component 后，先运行 status/build dry-run 和 `tests/harness-profile.tests.ps1`。
- 多平台输出变更后还应运行 `tests/harness-multiplatform.tests.ps1`；OpenClaw project config
  不是 OpenClaw machine config，也不包含 credentials、identity、sessions、cache 或 plugins。

非目标：

- 不替代 `scripts/sync.ps1` 的 live skills 同步。
- 不替代 §14 的 home-level harness config-sync。
- 不管理 Codex `.system`、OpenClaw identity/credentials、MCP secrets、session/cache/state。
- 不把项目本地 profile apply 扩展为全局机器配置切换。

---

## 16. Harness Environments

Harness Environments 是 conda 式的命名环境层：每个环境声明一个 profile、
各平台受管 skills 的子集和可验证的 MCP 模板，构建为可随时重建的 staging 目录，
并可经门控的 `env activate` 切换到 live home。
设计见 `docs/superpowers/specs/2026-07-10-harness-env-design.md`。

### 16.1 Task skill overlay（按任务热插拔）

`work.psd1` 是稳定的基础集合；任务临时需要的已管理 skill 不会被永久写回基础环境，
而是记录在当前分支/worktree 的 `.agent-harness/task-skills.psd1`。它是 Git 可审查的请求，
不是 generated output，也不是 live home 状态；默认空文件形状为：

```powershell
@{
    SchemaVersion = 1
    BaseEnv = 'work'
    Skills = @{
        Claude = @()
        Codex = @()
    }
}
```

常用命令：

```powershell
pwsh -File scripts/agent-dotfiles.ps1 env task status
pwsh -File scripts/agent-dotfiles.ps1 env task ensure-skill verification-before-completion -Platform Codex -DryRun
pwsh -File scripts/agent-dotfiles.ps1 env task ensure-skill verification-before-completion -Platform Codex -Apply
pwsh -File scripts/agent-dotfiles.ps1 env task sync -DryRun
pwsh -File scripts/agent-dotfiles.ps1 env task sync -Apply
pwsh -File scripts/agent-dotfiles.ps1 env task close -DryRun
pwsh -File scripts/agent-dotfiles.ps1 env task close -Apply
pwsh -NoProfile -File tests/task-skills.tests.ps1
```

行为边界：

- `ensure-skill` 只接受对应平台 manifest、`skills-source/` 和 generated output 都存在的 skill；
  未管理、隔离、路径型或扫密失败的内容会在 live 写入前拒绝。
- 每次变更都先构造临时 overlay，运行 build → scan → 环境 staging → fingerprint-bound sync dry-run；
  `-Apply` 才会原子更新 tracked overlay，并通过现有 `sync.ps1` 备份和事务部署。
- `close` 会删除 overlay 并可能 prune 任务增加的 managed skill，因此始终需要显式 dry-run/apply。
- Git hook 在其它电脑 checkout/pull 到 addition-only overlay 时可以自动重建并应用；检测到 removal、
  stale lock、未知 skill 或其它 gate 失败时只记录并等待人工执行 `env task sync -DryRun` / `-Apply`。
- 共享范围是提交该 overlay 的 branch/worktree；机器只根据 source + overlay 重建，不复制另一台机器的 home。
  新 clone 仍需先运行 `bootstrap.ps1` 安装 hooks；Git 不会自动安装仓库内 hook。
- Codex 应用已经缓存的 skill catalog 可能需要新 task/thread 才刷新。仓库可以热插拔文件、环境和状态，
  但不能强制应用层未公开的 catalog reload。

`list` / `status` 只读；`build` 只写可删除、可重建的 `envs/<name>/` staging，不写 home。
`activate` 默认 dry-run，`-Apply` 才动 live，且**部署只经由现有 `sync.ps1`**（含其不可跳过的强制备份）。
**Phase 2 范围收窄**：activate 只切换 skills 子集并写状态文件；home 级配置部署
（config-pull 接入）因当前没有任何环境差异化的 home 配置组件而暂缓，接入需单独评审。

常用命令：

```powershell
pwsh -File scripts/agent-dotfiles.ps1 env list          # 枚举环境 + 标记激活
pwsh -File scripts/agent-dotfiles.ps1 env status        # 定义有效性 + staging 新旧 + 激活漂移
pwsh -File scripts/agent-dotfiles.ps1 env status -ProjectRoot <p>  # 另检查项目 RequiredEnv 是否匹配
pwsh -File scripts/agent-dotfiles.ps1 env build <name>  # 构建 envs/<name>/ staging
pwsh -File scripts/agent-dotfiles.ps1 env activate <name> -DryRun  # 预览切换计划
pwsh -File scripts/agent-dotfiles.ps1 env activate <name> -Apply   # 真实切换（gated）
pwsh -File scripts/agent-dotfiles.ps1 env rollback -RunId <run-id> -DryRun -PlanPath <external-plan.json>
pwsh -File scripts/agent-dotfiles.ps1 env rollback -RunId <run-id> -Apply -PlanPath <external-plan.json>
pwsh -NoProfile -File tests/harness-env.tests.ps1       # 回归测试（也在 CI 中运行）
```

`env activate` 的 gate 链（任一步失败即止、不写状态文件）：
build-skills → scan-secrets → staging 重建 → `sync.ps1`（`-Apply` 时强制备份）→
成功后写 `state/current-env.json`。入口层强制显式 `-DryRun` 或 `-Apply`（与 sync 同款）；
`-Apply` 会先生成并绑定内部 dry-run 计划，再执行同一计划，不能把 apply 当作默认动作。
切换语义：staging 携带全量 manifest 副本而 skills 只含环境子集，sync 的
manifest-scoped prune 因此在切换到较小环境时自动裁剪多余受管 skills；
未知 live 目录与 Codex `.system` 一如既往永不触碰。

目录与文件：

- `harness-source/envs/<name>.psd1`：环境定义（tracked 源真相）。字段：
  `SchemaVersion`、`Name`（须与文件名一致）、`Description`、`Profile`
  （引用 `harness-source/profiles/`，继承其 Extends 链）、`Skills.Claude`/`Skills.Codex`
  （必须是对应 `manifests/managed-skills.<platform>.txt` 的子集）、`McpTemplates`。
- `envs/<name>/`：`env build` 的 staging 输出，Git-ignored，可删除重建。内容：
  skills 子集副本、`manifest.claude.txt`/`manifest.codex.txt`（环境子集，供人读）、
  `manifests/managed-skills.<platform>.txt`（**全量**仓库 manifest 副本，驱动
  sync 的切换裁剪语义）、空 `openclaw/skills/`（满足 sync 源检查，OpenClaw 零动作）、
   `profile/`（渲染的 profile 组件输出）、`env.lock.json`
   （可验证的定义、源/生成树、manifest、profile 和 staging 文件哈希；`env status`
   用它判定 lock validity 和 built/stale，而不是只看文件是否存在）。
   `envs/<name>/reports/` 是 activation 期间 `sync.ps1` 写入的运行证据，不属于构建
   产物，lock attestation 会忽略它。
- `state/current-env.json`：当前激活环境记录（名字、定义哈希、激活时间），机器私有、
  Git-ignored。只有 `env activate -Apply` 成功后才写；除定义哈希外还记录 task overlay
  hash/skill attestation，`status` 用它们检测“激活后定义或任务 overlay 又变了”。

安全规则：

- `env build` 只写 `envs/<name>/`，删除重建前有前缀断言；`list`/`status` 不写任何文件。
- `env activate` 是唯一受批准的环境切换路径：默认 dry-run；`-Apply` 内部经由
  `sync.ps1`，其强制备份无法跳过；home-only 文件（credentials、sessions、缓存、
  Codex `.system`、Codex `config.toml`）永不随切换变动；拒绝 `HomeRoot` 位于仓库内。
- `env status` 对当前环境报告 `lock validity`、`definition drift`、`live parity`、
  Codex `.system` 状态和 `backup reference`；这些是状态证据，不是备份内容。
- `env rollback` 不是 whole-home restore：它只恢复当前 Claude/Codex manifest 管理的
  skills 和环境状态。它永不触碰 unknown live 目录、Codex `.system`、credentials、
  sessions、cache、Codex `config.toml` 或 OpenClaw machine state。dry-run 先生成外部
  计划；`-Apply` 必须带同一 `-PlanPath`，并通过选定 activation backup 的元数据校验。
- 每台机器首次真实 `-Apply` 前必须人工审查 dry-run 计划（prune 列表尤其要过目）；已完成首次 activation 的机器在后续变更时仍应重复审查。
- task overlay 的自动路径只允许 additions；任何 removal/prune 都必须由人执行 `env task close -DryRun` 或
  `env task sync -DryRun` 后再显式 `-Apply`。
- `envs/` 与 `state/` 永不提交；环境定义变更后先跑 `env status` 和回归测试。
- 环境层永远只做编排：写 home 的代码路径只有现有 `sync.ps1`（未来接入 config 部署
  时也只能复用 `config-pull.ps1`），不新增第二条。

项目联动（Phase 3）：

- 项目 `.agent-harness/profile.psd1` 可声明可选字段 `RequiredEnv = '<name>'`。
- `env status -ProjectRoot <p>` 报告当前激活环境是否匹配项目声明，不匹配时给出
  建议命令（`env activate <name> -DryRun`）。**只检测提醒，绝不自动 activate。**
- 本仓库自身声明 `RequiredEnv = 'work'` 作为示例。

非目标（当前）：

- 不部署 home 级配置（config-pull 接入 deferred，见上）。
- 不自动切换环境（进入项目不触发任何写操作，联动仅为提醒）。
- 不把一个任务的 overlay 永久合并回 `harness-source/envs/work.psd1`；任务结束后应显式 close，
  是否提交 overlay 由任务协作者按 branch/worktree 需求决定。
- 不做 lockfile 跨机复现、OpenClaw 插件集或 MCP secrets 管理；`env.lock.json` 当前用于
  本机 staging/activation 的可验证证据，不是跨机传输 credential 或 machine state 的载体。

---

## 17. 统一 CLI 与真实边界

统一入口是 `scripts/agent-dotfiles.ps1`。它只负责路由和参数门控，不复制底层脚本的实现。
当前支持的完整命令面如下：

```text
doctor
build
scan
backup
sync
config status | pull | push
profile status | build | apply
skills inventory | analyze | dedupe | merge | normalize | promote
env list | status | build | activate | rollback | task status | task ensure-skill | task sync | task close
mcp -TemplateId <id> -DryRun|-Apply [-Remove]
```

读操作包括 `doctor`、`scan`、`config status`、`profile status`、`skills inventory`、
`skills analyze`、`skills dedupe`、`env list` 和 `env status`。`build`、`profile build`
和 `env build` 只生成可重建的派生/staging 输出；`backup` 只把运行时快照写到仓库外。
它们都不把 live home 或 canonical source 当作任意写入目标。

所有会改变 live、canonical source 或项目目标的动作都必须先走 dry-run；统一入口不会
自动补 `-Apply`。对支持模式的写操作，必须明确选择且只能选择一个 `-DryRun` 或
`-Apply`；省略模式会被拒绝，而不是隐式执行。`sync` 的 `-Apply` 还必须使用同一份
经审查的 `-PlanPath`。`config pull/push`、`profile apply`、`skills merge/promote`
也保持默认 dry-run/显式 apply 的保守边界。

`env activate` 和 `env rollback` 的 apply 需要更严格的计划绑定：activate 在 apply
内部生成并绑定 sync 计划，rollback 则要求外部 dry-run 生成的同一 `-PlanPath`，并在
执行前重新验证环境状态、备份元数据和计划哈希。`config pull` 是独立的 home-level
配置同步入口；the underlying `config-pull` is not part of `env activate`，环境切换当前
只处理受 manifest 管理的 Claude/Codex skills 和环境状态；staged MCP 模板仍需显式执行
`mcp -TemplateId <id> -DryRun` / `-Apply`，不会因环境切换隐式注册服务器。

## 18. MCP 模板安全边界

MCP 模板位于 `harness-source/components/mcp-templates/<id>/template.psd1`，只记录
服务器命令、参数、作用域和 `${ENV_VAR}` 占位符。模板、计划、报告和命令输出都不记录
环境变量的值；Apply 只通过 Claude CLI 对单个服务器执行 add/update/remove，禁止整体覆盖
`~/.claude.json`。

使用示例（必须先审查 dry-run 计划）：

```powershell
$plan = Join-Path $env:TEMP 'mcp-github-plan.json'
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 mcp -TemplateId github -DryRun -PlanPath $plan
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 mcp -TemplateId github -Apply -PlanPath $plan
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 mcp -TemplateId github -Remove -DryRun -PlanPath $plan
```

Apply 会把 CLI 状态快照和操作证据写到 home 下的仓库外备份根；失败时保留部分成功阶段和
恢复证据，不把原始 CLI 状态写入仓库或报告。MCP 不管理 OpenClaw credentials、identity、
sessions、cache、plugins，也不随 `env activate` 自动写入 home。
