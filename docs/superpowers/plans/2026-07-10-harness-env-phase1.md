# Harness Environments Phase 1（只读环境层）Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** 落地 Harness Environments 的只读环境层：`env list` / `env status` / `env build` 三个子命令、环境定义 schema、两个示例环境（`work`、`minimal`）、自包含回归测试并入 CI。全程不写 home、不改任何安全规则。

**Approach:** 按设计文档 `docs/superpowers/specs/2026-07-10-harness-env-design.md` 方案 C Phase 1 实施。新增薄环境层脚本（common + list + status + build），复用 `scripts/harness-profile-common.ps1` 的解析/校验/哈希 helper；staging 输出到仓库根 `envs/<name>/`（Git-ignored）；状态文件 `state/current-env.json` 在 Phase 1 只读（不存在时报告 "no environment activated"，本期没有任何代码会创建它）。测试沿用 `tests/harness-profile.tests.ps1` 的无 Pester 自包含模式。

**Materials:**
- 设计文档：`docs/superpowers/specs/2026-07-10-harness-env-design.md`
- 命名与结构范本：`scripts/status-harness-profile.ps1`、`scripts/build-harness-profile.ps1`、`scripts/harness-profile-common.ps1`
- 可复用 helper（在 `scripts/harness-profile-common.ps1`）：`Import-HarnessDataFile`、`Test-HarnessKnownKeys`、`Resolve-HarnessProfileExtends`、`Get-HarnessComponents`、`Get-HarnessFileHash`、`Write-HarnessJsonFile`、`New-HarnessProfilePlan`
- 入口分发范本：`scripts/agent-dotfiles.ps1`（`$commandMap` 模式）
- 测试范本：`tests/harness-profile.tests.ps1`（Assert 计数、`tmp/` 工作区、成功删除失败保留）
- CI：`.github/workflows/validate.yml`（"Run harness profile tests" 步骤为模板）
- 管理名单：`manifests/managed-skills.claude.txt`、`manifests/managed-skills.codex.txt`

**Validation:** `pwsh -NoProfile -File tests/harness-env.tests.ps1` 全绿；`pwsh -NoProfile -File tests/harness-profile.tests.ps1` 仍全绿（无回归）；`scripts/build-skills.ps1` + `scripts/scan-secrets.ps1` 通过；`git status` 无未预期的未跟踪文件（`envs/`、`state/` 被 ignore）。

---

### Task 1: 环境定义 schema 与 common helper

**Artifacts / Locations:**
- Create: `scripts/harness-env-common.ps1`
- Review: `scripts/harness-profile-common.ps1`、`docs/superpowers/specs/2026-07-10-harness-env-design.md` §3.1

- [x] **Step 1: 读取设计与现有 helper**

Read: 设计文档 §3.1–§3.3；`scripts/harness-profile-common.ps1` 中上列可复用函数的签名。
Extract: 环境定义字段（SchemaVersion、Name、Description、Profile、Skills.Claude、Skills.Codex、McpTemplates）；profile 解析入口 `Resolve-HarnessProfileExtends` 的调用方式。

- [x] **Step 2: 实现 common helper**

Create: `scripts/harness-env-common.ps1`，`#requires -Version 7.0` + `Set-StrictMode`，dot-source `harness-profile-common.ps1`。实现并导出：
- `Get-HarnessEnvRoot([string]$RepoRoot)` → `<repo>/harness-source/envs`
- `Get-HarnessEnvDefinitionFiles($RepoRoot)` → 枚举 `harness-source/envs/*.psd1`（不存在目录时返回空数组，不报错）
- `Read-HarnessEnvDefinition($Path)` → 用 `Import-HarnessDataFile` 加载；用 `Test-HarnessKnownKeys` 拒绝未知键；校验 `SchemaVersion -eq 1`、`Name` 与文件名一致、`Skills` 仅含 `Claude`/`Codex` 键
- `Resolve-HarnessEnvDefinition($RepoRoot, $Definition)` → 硬校验：`Profile` 在 `harness-source/profiles/` 中存在且 `Resolve-HarnessProfileExtends` 成功；`Skills.Claude` 每项都出现在 `manifests/managed-skills.claude.txt`（逐行精确匹配，忽略空行）；`Skills.Codex` 同理对 `manifests/managed-skills.codex.txt`；`McpTemplates` 每项在 `harness-source/components/mcp-templates/<id>/` 存在（列表为空则跳过）。任一失败 throw，消息包含环境名与出错项
- `Get-HarnessEnvStagingRoot($RepoRoot, $Name)` → `<repo>/envs/<name>`
- `Get-HarnessEnvStatePath($RepoRoot)` → `<repo>/state/current-env.json`
- `Read-HarnessEnvState($RepoRoot)` → 文件不存在返回 `$null`；存在则解析 JSON 并要求含 `Name` 键，损坏时 throw（消息提示文件路径）
- `Get-HarnessEnvDefinitionHash($Path)` → 复用 `Get-HarnessFileHash`

- [x] **Step 3: 验证**

Check: `pwsh -NoProfile -Command ". scripts/harness-env-common.ps1"` 无输出无错误退出码 0。
Expected: dot-source 成功，StrictMode 下无告警。

### Task 2: 示例环境定义 work 与 minimal

**Artifacts / Locations:**
- Create: `harness-source/envs/work.psd1`、`harness-source/envs/minimal.psd1`
- Review: `manifests/managed-skills.claude.txt`、`manifests/managed-skills.codex.txt`、`harness-source/profiles/`

- [x] **Step 1: 选取真实 skill 名**

Read: 两个 manifest 文件。
Extract: 从 Claude 名单选 2–3 个实际存在的名字（如名单中有 `git-review`、`systematic-debugging` 则优先），从 Codex 名单选 2–3 个。`minimal` 环境各选 1 个。

- [x] **Step 2: 写定义文件**

Create: `work.psd1` → `Profile = 'coding'`、Skills 用上一步选出的名字、`McpTemplates = @()`、`Description = '日常编码环境'`。
Create: `minimal.psd1` → `Profile = 'base'`、每平台 1 个 skill、`McpTemplates = @()`、`Description = '最小验证环境'`。
格式对齐 `harness-source/profiles/base.psd1` 的缩进与注释风格。

- [x] **Step 3: 验证**

Check: `pwsh -NoProfile -Command ". scripts/harness-env-common.ps1; $d = Read-HarnessEnvDefinition 'harness-source/envs/work.psd1'; Resolve-HarnessEnvDefinition (Get-Location).Path $d"` 对两个文件各跑一次。
Expected: 均无异常。

### Task 3: env list 脚本

**Artifacts / Locations:**
- Create: `scripts/list-harness-env.ps1`
- Review: `scripts/status-harness-profile.ps1`（输出与参数风格）

- [x] **Step 1: 实现**

Create: `scripts/list-harness-env.ps1`，参数 `[string]$RepoRoot`（默认脚本上级）。行为：枚举全部环境定义；每个环境输出一行：名字、Description、Profile、各平台 skill 数、校验结果（`ok` 或首条错误摘要）；读 `Read-HarnessEnvState`，当前激活环境行首标 `*`，无状态文件时末尾输出 `No environment activated.`。只读，退出码：全部定义有效为 0，存在无效定义为 1。

- [x] **Step 2: 验证**

Check: `pwsh -NoProfile -File scripts/list-harness-env.ps1`
Expected: 列出 `minimal`、`work` 两行均 `ok`，输出 `No environment activated.`，退出码 0。

### Task 4: env build 脚本

**Artifacts / Locations:**
- Create: `scripts/build-harness-env.ps1`
- Review: `scripts/build-harness-profile.ps1`（结构范本）、设计文档 §3.2

- [x] **Step 1: 实现**

Create: `scripts/build-harness-env.ps1`，参数 `[Parameter(Mandatory)][string]$Name`、`[string]$RepoRoot`。流程：
1. 加载并 `Resolve-HarnessEnvDefinition` 校验（失败即退出，不写任何文件）。
2. 前置检查：定义中每个 Claude skill 在生成输出 `claude/skills/<skill>/` 存在、每个 Codex skill 在 `codex/skills/<skill>/` 存在；否则报错 `Run scripts/build-skills.ps1 first.` 并退出码 1，不写任何文件。
3. 写 staging 到 `envs/<name>/`（先清空重建该目录，路径必须以 `<repo>/envs/` 为前缀才允许删除——防御性断言）：
   - `claude/skills/<skill>/`、`codex/skills/<skill>/`：从生成输出复制
   - `manifest.claude.txt`、`manifest.codex.txt`：环境的 skill 名单（每行一个，排序稳定）——Phase 2 参数化 sync 的输入
   - `profile/`：用 `New-HarnessProfilePlan` 渲染环境 Profile 的组件输出（AGENTS.md 规则块文本、settings 片段），落为文件
   - `env.lock.json`：用 `Write-HarnessJsonFile` 写入 `{ Name, DefinitionHash, BuiltFiles: { <相对路径>: <hash> } }`，hash 用 `Get-HarnessFileHash`
4. 输出摘要：环境名、文件数、staging 路径。

- [x] **Step 2: 验证**

Check: 先 `pwsh -NoProfile -File scripts/build-skills.ps1`，再 `pwsh -NoProfile -File scripts/build-harness-env.ps1 -Name work`；然后 `git status --short`。
Expected: `envs/work/` 生成且含 `env.lock.json` 与两份 manifest；git status 不出现 `envs/`（Task 6 完成 .gitignore 后复验）。连续构建两次，第二次 `env.lock.json` 的 `DefinitionHash` 与文件 hash 集合不变（幂等）。

### Task 5: env status 脚本

**Artifacts / Locations:**
- Create: `scripts/status-harness-env.ps1`
- Review: `scripts/status-harness-profile.ps1`

- [x] **Step 1: 实现**

Create: `scripts/status-harness-env.ps1`，参数 `[string]$RepoRoot`、可选 `[string]$Name`（缺省报告全部环境）。对每个环境输出：
- 定义校验：`valid` / `invalid: <原因>`
- staging 状态：`missing`（无 `envs/<name>/`）、`stale`（`env.lock.json` 的 `DefinitionHash` ≠ 当前定义文件 hash，或 lock 缺失/损坏）、`built`（hash 一致）
- 末尾报告激活状态：状态文件不存在 → `No environment activated.`；存在 → `Active environment: <Name>`，若该名字无对应定义文件则加注 `(definition missing)`。
只读；任何路径都不写。退出码恒为 0（status 是报告不是 gate），但 `invalid` 定义以警告色输出。

- [x] **Step 2: 验证**

Check: `pwsh -NoProfile -File scripts/status-harness-env.ps1`；随后临时给 `work.psd1` 加一行注释再跑一次，最后还原。
Expected: 第一次 `work` 为 `built`（Task 4 已构建）、`minimal` 为 `missing`；改动后 `work` 变 `stale`；还原后回到 `built`。

### Task 6: 入口分发与 .gitignore

**Artifacts / Locations:**
- Modify: `scripts/agent-dotfiles.ps1`、`.gitignore`

- [x] **Step 1: agent-dotfiles.ps1 增加 env 子命令**

Modify: 在参数解析后增加分支：`Command -ieq 'env'` 时取 `$RemainingArguments[0]` 为子动作，映射 `list → list-harness-env.ps1`、`status → status-harness-env.ps1`、`build → build-harness-env.ps1`，其余参数透传；子动作缺失或未知时输出用法并退出码 1。更新 `Write-Usage`：命令列表加 `env`，示例加 `agent-dotfiles.ps1 env list`。不改动现有五个命令的任何行为。

- [x] **Step 2: .gitignore 增加两条**

Modify: `.gitignore` 的 "Generated, backup, and temporary files" 区块追加：
```
envs/
state/
```
（注意：已有 `openclaw/state/` 规则不受影响；新增的是仓库根级目录。）

- [x] **Step 3: 验证**

Check: `pwsh -File scripts/agent-dotfiles.ps1 env list`、`pwsh -File scripts/agent-dotfiles.ps1 env` （后者应报用法）、`pwsh -File scripts/agent-dotfiles.ps1 doctor -SkipSecretsScan`（现有命令不回归）；`git status --short` 中 `envs/work/` 不再出现。
Expected: 分发正确、用法输出、doctor 正常、staging 被 ignore。

### Task 7: 回归测试 tests/harness-env.tests.ps1

**Artifacts / Locations:**
- Create: `tests/harness-env.tests.ps1`
- Review: `tests/harness-profile.tests.ps1`（复制其 Assert/工作区/Invoke-Script 骨架）

- [x] **Step 1: 搭骨架与 fixture**

Create: 测试脚本，无 Pester，工作区 `tmp/harness-env-tests/`（成功删除、失败保留）。在工作区内搭一个最小假仓库树：`harness-source/profiles/`（复制真实 `base.psd1`、`coding.psd1` 与其引用的 `components/`）、`harness-source/envs/`（测试用定义）、`manifests/managed-skills.claude.txt` 与 `.codex.txt`（写入 2 个假名字如 `fixture-a`、`fixture-b`）、生成输出 `claude/skills/fixture-a/SKILL.md` 等假 skill 目录。所有脚本调用通过 `-RepoRoot <工作区假仓库>` 指向 fixture，绝不触碰真实 home 或真实 `envs/`。

- [x] **Step 2: 写测试用例**

必须覆盖（每条为独立 Assert 组）：
1. list：枚举出 fixture 环境且校验 `ok`，无状态文件时输出含 `No environment activated.`，退出码 0。
2. 定义校验失败面：未知键、`Name` 与文件名不符、`Profile` 不存在、skill 不在 manifest、`SchemaVersion` ≠ 1 —— 各造一个坏定义，`Read-/Resolve-` 报错且 list 退出码 1。
3. build 前置：生成输出缺 skill 目录时报错含 `build-skills.ps1`，且 `envs/<name>/` 未创建。
4. build 成功：staging 含 skills 副本、两份 manifest（内容与定义一致且排序稳定）、`profile/` 输出、`env.lock.json` 含正确 `DefinitionHash`。
5. build 幂等：连跑两次，两次 `env.lock.json` 内容一致。
6. status：build 后 `built`；改定义文件后 `stale`；删 staging 后 `missing`。
7. status 激活报告：手工在 fixture `state/current-env.json` 写 `{"Name":"fixture-env"}` → 输出 `Active environment`；写不存在的名字 → 含 `definition missing`；删除文件 → `No environment activated.`。
8. 只读保证：list 与 status 运行前后对 fixture 树做文件清单+hash 快照对比，完全一致。

- [x] **Step 3: 验证**

Check: `pwsh -NoProfile -File tests/harness-env.tests.ps1`；随后 `pwsh -NoProfile -File tests/harness-profile.tests.ps1`。
Expected: 新测试全 PASS 退出码 0；旧测试仍 33/33 无回归。

### Task 8: CI 接入

**Artifacts / Locations:**
- Modify: `.github/workflows/validate.yml`

- [x] **Step 1: 加测试步骤**

Modify: 在 "Run harness profile tests" 步骤之后新增 "Run harness env tests" 步骤，内容照抄该步骤的模式（存在性检查 + `pwsh -NoProfile -File` + 退出码 throw），路径换成 `tests\harness-env.tests.ps1`。

- [x] **Step 2: 验证**

Check: 本地 `pwsh -NoProfile -Command "ConvertFrom-Yaml"` 不可用时，改用 `git diff` 目检缩进与既有步骤一致；并确认 "Verify build leaves Git clean" 步骤不会受影响（`envs/`、`state/`、`tmp/` 均已 ignore）。
Expected: YAML 结构与相邻步骤完全同构。

### Task 9: 文档与安全规则同步

**Artifacts / Locations:**
- Modify: `docs/README.md`、`STATUS.md`、`CLAUDE.md`

- [x] **Step 1: docs/README.md 新增 §16**

Modify: 在 §15 之后新增 "## 16. Harness Environments（Phase 1）"：一段定位说明（命名环境只读层，activate 属 Phase 2 未实施）、命令清单（`env list/status/build` 三条 + 测试命令）、目录说明（`harness-source/envs/` tracked 源、`envs/` Git-ignored staging、`state/current-env.json` 机器私有）、安全规则（不写 home；`envs/` 与 `state/` 永不提交；环境层不新增写 home 代码路径）。§4 文件表格补三个脚本与两个目录的行。

- [x] **Step 2: STATUS.md 更新**

Modify: "Current phase" 段落追加 Harness Environments Phase 1 已落地（只读）；"Current canonical decisions" 增加两条：环境定义在 `harness-source/envs/`、`envs/` 与 `state/` 为非提交生成物/机器私有状态；"Build / scan status" 增加 harness-env 测试；"Next actions" 增加 "Phase 2（gated env activate）需按设计文档单独评审后实施"。日期更新为实际执行日。

- [x] **Step 3: CLAUDE.md 更新**

Modify: Scope trigger 列表追加：`harness-source/envs/`、`envs/`（仓库根 staging）、`state/current-env.json`、`scripts/harness-env-common.ps1`、`scripts/list-harness-env.ps1`、`scripts/status-harness-env.ps1`、`scripts/build-harness-env.ps1`、`tests/harness-env.tests.ps1`。Hard rules 追加两条：`envs/` 是生成 staging，永不手改或提交；Phase 1 环境脚本只读 home，`state/` 机器私有永不提交。

- [x] **Step 4: 验证**

Check: 通读三个文件改动处；确认没有把 "activate 已可用" 写进任何文档（Phase 1 无 activate）。
Expected: 文档只描述已实现行为，Phase 2 明确标注为未实施、待评审。

### Task 10: 全量收尾验证

**Artifacts / Locations:**
- Review: 全部改动

- [x] **Step 1: 跑完整校验链**

Check（依次，全部要求退出码 0）：
```powershell
pwsh -NoProfile -File scripts/build-skills.ps1
pwsh -NoProfile -File scripts/scan-secrets.ps1
pwsh -NoProfile -File tests/harness-profile.tests.ps1
pwsh -NoProfile -File tests/harness-env.tests.ps1
pwsh -File scripts/agent-dotfiles.ps1 env list
pwsh -File scripts/agent-dotfiles.ps1 env status
pwsh -File scripts/agent-dotfiles.ps1 env build work
```

- [x] **Step 2: Git 卫生检查**

Check: `git status --short` —— 未跟踪项只应有本计划新增的 tracked 文件（scripts×4、envs 定义×2、tests×1、plan/spec 文档），绝无 `envs/`、`state/`、`tmp/` 条目；`git diff` 人工过一遍 `.gitignore`、`agent-dotfiles.ps1`、`validate.yml`、三个文档的改动。
Expected: 与计划清单一一对应，无多余改动。

- [x] **Step 3: 汇报**

Update: 勾掉本计划全部 checkbox；向用户汇报结果与验证输出摘要。提交与否由用户决定（本仓库惯例：人工审查后再 commit）。
