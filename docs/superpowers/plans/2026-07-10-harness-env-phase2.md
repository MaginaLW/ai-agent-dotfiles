# Harness Environments Phase 2（gated env activate）Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** 落地 `env activate <name>`：默认 dry-run、`-Apply` 门控的全局环境切换，部署只经由现有 `sync.ps1`（含其不可跳过的强制备份），成功后写 `state/current-env.json`；真机上绝不实际运行 `-Apply`（全部用 fake home 验证）。

**Approach:** 按设计文档 §4.2 实施，但有一处**明确的范围收窄**：Phase 2 只切换 **skills 子集 + 状态文件**，不做 config-pull 的 home 配置部署。理由：当前所有环境的 profile 组件只产出项目级文件（AGENTS.md 块、项目 settings 片段），没有任何环境差异化的 home 配置可部署——接入 config-pull 只会增加一条无差别的写 home 路径而不带来环境差异。此收窄记录进 spec 附注，待未来出现 home 级差异化组件时再单独评审接入。切换语义：staging 携带**全量** manifest 副本而 skills 目录只含环境子集，`sync.ps1` 的既有 prune 逻辑因此自动实现"切到小环境=裁剪大环境装的受管 skills"，同时保持 unknown 目录与 Codex `.system` 永不触碰。

**Materials:**
- 设计：`docs/superpowers/specs/2026-07-10-harness-env-design.md` §4.2
- 关键已核实事实：
  - `scripts/sync.ps1` 参数 `-Apply/-DryRun/-SkipBuild/-SkipSecretScan/-BackupRoot/-RepoRoot/-HomeRoot`；源为 `<RepoRoot>/claude/skills`、`codex/skills`、`openclaw/skills`，**三者都必须存在**否则报错；manifest 读 `<RepoRoot>/manifests/managed-skills.<platform>.txt`（`Read-ManagedNames` 对缺失文件返回空集不报错）；`-Apply` 内部强制调用 `backup.ps1 -BackupRoot .. -RepoRoot .. -HomeRoot ..`，**无参数可跳过备份**；其内部 build/scan 子调用不带参数（永远作用于真实仓库），可用 `-SkipBuild/-SkipSecretScan` 跳过；OpenClaw 插件 dry-run 在 `<RepoRoot>/openclaw/plugins/managed-plugins.json` 缺失时自动跳过
  - `scripts/backup.ps1` 参数 `-HomeRoot/-BackupRoot/-RepoRoot/-DryRun` → fake home 可测
  - `scripts/scan-secrets.ps1` 参数 `-RepoRoot` → 测试可指向 fake repo（快）
  - Phase 1 产物：`scripts/harness-env-common.ps1`（含 `Get-HarnessEnvStagingRoot` 裸标识符校验、`Read-HarnessEnvState`）、`scripts/build-harness-env.ps1`（内存计划先行、失败零写入）、`tests/harness-env.tests.ps1`（fake repo 模式，57 用例）
- 入口范本：`scripts/agent-dotfiles.ps1` 对 `sync` 的显式模式校验（`-DryRun`/`-Apply` 二选一）

**Validation:** `tests/harness-env.tests.ps1` 全绿（含新增 activate 用例）；`tests/harness-profile.tests.ps1` 33/33 无回归；build-skills + scan-secrets 通过；真机 `env activate work`（无 `-Apply`）输出合理 dry-run 计划且零写入；`git status` 干净（`envs/`、`state/` 被 ignore）。

---

### Task 1: staging 补全 sync 兼容布局

**Artifacts / Locations:**
- Modify: `scripts/build-harness-env.ps1`
- Review: `scripts/sync.ps1`（源与 manifest 路径约定）

- [x] **Step 1: 扩展 build 写入计划**

Modify: `scripts/build-harness-env.ps1` 的写入计划部分，新增三项：
- `manifests/managed-skills.claude.txt`：**全量**复制真实仓库的同名文件（不是环境子集——这是切换时 prune 语义的关键）
- `manifests/managed-skills.codex.txt`：同上
- `openclaw/skills/` 空目录（满足 sync.ps1 的三源存在性检查；不放 openclaw manifest → 空受管集 → sync 对 OpenClaw 零动作）
保留既有的环境子集 `manifest.claude.txt`/`manifest.codex.txt`（根级，供人读与未来 status 用）。空目录不进 `env.lock.json`（lock 只收文件，全量 manifest 副本要进）。在脚本的 comment-based help 中同步说明新布局及其原因。

- [x] **Step 2: 验证**

Check: `pwsh -NoProfile -File scripts/build-harness-env.ps1 -Name work`；检查 `envs/work/manifests/managed-skills.claude.txt` 与真实仓库同名文件内容一致、`envs/work/openclaw/skills/` 存在且空；连跑两次 lock 哈希一致（幂等保持）。
Expected: 全部成立；`tests/harness-env.tests.ps1` 现有用例仍全绿（"lock covers every staged file" 用例自动覆盖新文件）。

### Task 2: activate 脚本

**Artifacts / Locations:**
- Create: `scripts/activate-harness-env.ps1`
- Review: `scripts/sync.ps1`（参数与退出码）、`scripts/harness-env-common.ps1`

- [x] **Step 1: 实现**

Create: `scripts/activate-harness-env.ps1`，comment-based help + `#requires -Version 7.0` + StrictMode + `$ErrorActionPreference='Stop'`，dot-source `harness-env-common.ps1`。参数：
`[Parameter(Mandatory)][string]$Name`、`[switch]$Apply`、`[switch]$DryRun`（与 `-Apply` 互斥，二者都缺省时等同 `-DryRun`）、`[string]$RepoRoot`、`[string]$HomeRoot = $env:USERPROFILE`、`[string]$BackupRoot =（与 sync.ps1 相同默认）`、`[switch]$SkipBuild`、`[switch]$SkipSecretScan`。

流程（顺序即 gate 顺序，任一步失败立即以其退出码退出且**不写状态文件**）：
1. 解析并校验环境（`Read-/Resolve-HarnessEnvDefinition`）。
2. 防御断言：`$HomeRoot` 解析后不得等于 `$RepoRoot` 或位于其下。
3. 除非 `-SkipBuild`：`pwsh -NoProfile -File <scripts>/build-skills.ps1 -RepoRoot $RepoRoot`。
4. 除非 `-SkipSecretScan`：`pwsh -NoProfile -File <scripts>/scan-secrets.ps1 -RepoRoot $RepoRoot`（失败即止）。
5. `pwsh -NoProfile -File <scripts>/build-harness-env.ps1 -Name $Name -RepoRoot $RepoRoot`（staging 永远重建，杜绝 stale 激活）。
6. 调用 `pwsh -NoProfile -File <scripts>/sync.ps1` 传 `-RepoRoot <staging>` `-HomeRoot $HomeRoot` `-SkipBuild -SkipSecretScan`（步骤 3/4 已跑，sync 内部的备份 gate 无法跳过、保持强制）加 `-DryRun` 或 `-Apply -BackupRoot $BackupRoot`。
7. dry-run：输出 `DRY-RUN complete...`（透传 sync 输出）并打印"State file would be written: <path>"；不碰 `state/`。
8. `-Apply` 且 sync 退出 0：用 `Write-HarnessJsonFile` 写 `state/current-env.json`：`{ SchemaVersion = 1, Name, DefinitionHash, ActivatedAtUtc = [DateTime]::UtcNow.ToString('o'), HomeRoot }`；输出 `Activated environment: <name>`。

- [x] **Step 2: 冒烟验证（只 dry-run，真机零写入）**

Check: `pwsh -NoProfile -File scripts/activate-harness-env.ps1 -Name work`（默认 dry-run；耗时可加 `-SkipBuild -SkipSecretScan` 复跑一次对比）。
Expected: 透传的 sync 计划显示 Claude/Codex 的 add/update 只含 work 环境的 skills、prune 列出全量 manifest 内不属 work 的受管 skills（**只是计划，不执行**）、OpenClaw 全零、`.system preserved`；结尾有 "State file would be written"；`state/` 不存在；`git status` 无新增。

### Task 3: 入口分发 activate + 显式模式

**Artifacts / Locations:**
- Modify: `scripts/agent-dotfiles.ps1`

- [x] **Step 1: 实现**

Modify: `$envCommandMap` 增加 `activate = 'activate-harness-env.ps1'`。仿照 sync 的模式校验：`env activate` 必须显式带 `-DryRun` 或 `-Apply` 之一（两者都给或都不给 → 用法提示 + exit 1）；`list/status/build` 不受影响。更新 `Write-Usage` 与 help 注释（env 子动作列表加 activate，注明其模式要求）。

- [x] **Step 2: 验证**

Check: `pwsh -File scripts/agent-dotfiles.ps1 env activate work -DryRun` → 正常 dry-run 退出 0；`env activate work`（无模式）→ exit 1 + 用法；`env activate work -DryRun -Apply` → exit 1；`env list` 等仍正常。
Expected: 如上。

### Task 4: status 报告激活后定义漂移

**Artifacts / Locations:**
- Modify: `scripts/status-harness-env.ps1`

- [x] **Step 1: 实现**

Modify: 激活报告处——当状态文件存在、`Name` 有对应定义文件、且状态含 `DefinitionHash` 而其值 ≠ 当前定义哈希时，`Active environment: <n>` 行追加 ` (definition changed since activation — re-run env activate)`。状态无 `DefinitionHash` 键（旧格式）时不追加、不报错。

- [x] **Step 2: 验证**

由 Task 5 的测试用例覆盖（真机不制造状态文件）。

### Task 5: 回归测试扩展（fake home apply）

**Artifacts / Locations:**
- Modify: `tests/harness-env.tests.ps1`

- [x] **Step 1: fake home 基建**

在既有 fake repo 之外新建 `$work/home`（`.claude/skills/`、`.codex/skills/.system/system.md`（哨兵文件）、`.codex/skills/`、`.openclaw/skills/`、一个非受管目录 `.claude/skills/unknown-local/SKILL.md`）与 `$work/backups`。fake repo 补 `manifests/managed-skills.openclaw.txt` 不需要（保持缺失）。fake repo 增加第二个环境 `small.psd1`（Claude 仅 `fixture-a`，Codex 仅 `fixture-a`）。所有 activate 调用传 `-RepoRoot <fakeRepo> -HomeRoot <fakeHome> -BackupRoot <fakeBackups> -SkipBuild`；secret scan 首选不跳过（`scan-secrets.ps1 -RepoRoot <fakeRepo>` 扫小假仓库应当很快）——若 gitleaks 对非 git 目录不可用则回退为 `-SkipSecretScan` 并在测试输出注明（执行者当场验证决定）。

- [x] **Step 2: 用例（每条独立 Assert 组）**

1. **dry-run 零写入**：activate good（dry-run）→ exit 0；fake home 快照（文件清单+哈希）前后一致；`state/` 不存在；输出含 "State file would be written"。
2. **apply 安装**：activate good `-Apply` → exit 0；`home/.claude/skills/fixture-a|fixture-b/SKILL.md` 与 `home/.codex/skills/fixture-a/SKILL.md` 存在；`state/current-env.json` 存在且 `Name='good'`、含 `DefinitionHash` 与 `ActivatedAtUtc`；`backups/` 下有新备份目录；`.system/system.md` 哨兵原样；`unknown-local` 原样。
3. **status 集成**：status → `Active environment: good`；list → `* good`。
4. **重复 apply 幂等**：再次 activate good `-Apply` → exit 0，sync 计划 `+0 ~0 -0`（从输出断言）。
5. **切换裁剪**：activate small `-Apply` → `fixture-b` 从 `home/.claude/skills/` 消失（全量 manifest prune 语义）、`fixture-a` 保留、`unknown-local` 与 `.system` 哨兵仍原样；状态 `Name='small'`。
6. **定义漂移提示**：改 `small.psd1`（加注释）→ status 输出含 `definition changed since activation`；还原后提示消失。
7. **失败不写状态**：删除 `state/`（或改名后）activate 不存在的环境 `-Apply` → 非零退出、`state/` 不存在；对 good 传 `-HomeRoot <fakeRepo>`（home==repo）→ 非零退出（防御断言）且 fake repo 无变化。
8. **入口模式校验**：经 `agent-dotfiles.ps1 env activate good`（无模式，任意 RepoRoot）→ exit 1。

- [x] **Step 3: 验证**

Check: `pwsh -NoProfile -File tests/harness-env.tests.ps1`；`pwsh -NoProfile -File tests/harness-profile.tests.ps1`。
Expected: 新旧用例全绿；工作区成功后自动清理。

### Task 6: 文档与安全规则同步

**Artifacts / Locations:**
- Modify: `docs/README.md`（§16）、`STATUS.md`、`CLAUDE.md`、`docs/superpowers/specs/2026-07-10-harness-env-design.md`

- [x] **Step 1: docs/README.md §16**

改标题为 "Harness Environments"；命令清单加 `env activate <name> -DryRun|-Apply`（注明入口强制显式模式）；安全规则改写：activate 是唯一受批准的环境切换路径，gate 链 = build → 扫密 → staging 重建 → sync（含不可跳过的强制备份）→ 状态文件；home-only 文件与 `.system` 永不随切换变动；**Phase 2 范围收窄说明**（只切 skills+状态，config-pull 接入 deferred 及理由）；非目标更新（去掉"activate 不存在"，保留 lockfile/回滚/OpenClaw 插件/MCP secrets）。

- [x] **Step 2: STATUS.md**

Current phase 段落追加 Phase 2 已落地（gated activate，skills 范围）；canonical decisions 更新：将 "global switching requires the Phase 2 gated env activate, which must be separately reviewed" 改为已实施的事实描述（activate 经由 sync.ps1 单一写路径、默认 dry-run、备份强制、config 部署 deferred）；Build/scan status 更新测试计数；Next actions 更新（真机首次 `env activate <n> -Apply` 需先人工审查 dry-run 计划；config-pull 接入待未来评审）。

- [x] **Step 3: CLAUDE.md**

Scope trigger 加 `scripts/activate-harness-env.ps1`；hard rules 更新："`env activate` 是唯一受批准的全局环境切换命令，默认 dry-run、`-Apply` 门控、部署只经 `sync.ps1`（强制备份），任何其他直接写 home 的方式仍然禁止；真机 `-Apply` 前必须人工审查 dry-run 计划"。删除/改写 "env activate does not exist yet" 表述。

- [x] **Step 4: spec 附注**

在设计文档 §4.2 末尾加 "Implementation note (2026-07-10)"：Phase 2 落地为 skills+状态切换；config-pull 部署因当前无 home 级差异化组件而 deferred，接入需单独评审。

- [x] **Step 5: 验证**

Check: 通读四处改动；确认没有任何文档声称 config 会随环境切换、没有声称真机已执行过 `-Apply`。
Expected: 文档与实际行为一致。

### Task 7: 全量收尾验证与提交

**Artifacts / Locations:**
- Review: 全部改动

- [x] **Step 1: 校验链**

依次全部退出码 0：`build-skills.ps1`、`scan-secrets.ps1`、`tests/harness-profile.tests.ps1`、`tests/harness-env.tests.ps1`、`agent-dotfiles.ps1 env list`、`env status`、`env build work`、`env activate work -DryRun`。确认真机 `state/` 目录不存在、`~/.claude` 等未被触碰（activate 只跑过 dry-run）。

- [x] **Step 2: Git 卫生与提交**

`git status --short` 只含本计划的预期改动；`git diff` 人工过一遍 `agent-dotfiles.ps1`、`build-harness-env.ps1` 与四个文档；提交（消息注明 phase 2 gated activate + Co-Authored-By 尾注）。

- [x] **Step 3: 汇报**

勾掉计划 checkbox；汇报验证输出摘要与已知限制（config 部署 deferred；真机 apply 待人工 dry-run 审查后自行执行）。
