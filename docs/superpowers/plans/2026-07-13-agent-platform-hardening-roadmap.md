# Agent Platform Hardening Roadmap Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** 将当前多 Agent skills、harness 和 environment 管理脚本，逐阶段收敛为可审计、可恢复、可复现的运行时管理系统。

**Approach:** 先修正导入/合并和 live sync 的安全闭环，再补齐 CI、测试和机器可读证据，最后扩展 environment rollback、Harness 多平台组件、MCP 和 OpenClaw 插件版本治理。每个阶段都产生独立可审阅的结果，并在进入下一阶段前保留明确的验证门槛。

**Materials:** AGENTS.md、docs/README.md、STATUS.md、docs/MERGE_POLICY.md、scripts/auto-merge-skills.ps1、scripts/inventory-skills.ps1、scripts/sync.ps1、scripts/agent-dotfiles.ps1、scripts/doctor.ps1、scripts/activate-harness-env.ps1、.github/workflows/validate.yml、tests/config-sync.tests.ps1、tests/harness-profile.tests.ps1、tests/harness-env.tests.ps1。

**Validation:** 每阶段执行对应的 PowerShell 回归测试、secret scan、build reproducibility、Git diff 检查和必要的 fake-home / fake-repo 验证；任何阶段不得修改 ~/.codex/skills/.system、live skills、imports 原始副本或机器私有状态。

---

## 总体范围与不变量

以下规则贯穿所有阶段：

- skills-source/ 仍是唯一手工维护的 skills source of truth。
- generated output、envs/、state/、reports 和 imports 原始内容不提交。
- 所有 live apply 继续默认 dry-run，并保留 build、secret scan、backup 和 manifest-scoped prune 门禁。
- Codex .system 永远排除在 inventory、merge、sync、prune 和 rollback 之外；backup 只负责保存它以便恢复。
- 不直接编辑 ~/.openclaw/plugins/installs.json，不通过整体覆盖方式写入 ~/.claude.json 或 Codex config.toml。
- Project Harness Profiles 在明确评审前仍保持项目本地，不自动切换全局 home harness。
- config-pull 不接入 environment activation，除非先出现真实的、经过评审的环境差异化 home 配置组件。

## 阶段依赖

Phase 0 基线与状态校准
  -> Phase 1 导入/合并安全边界
  -> Phase 2 事务性 sync 与 plan fingerprint
  -> Phase 3 CI、测试与机器可读证据
  -> Phase 4 Environment lock、attestation 与 rollback
  -> Phase 5 可选扩展：Harness 多平台、MCP、OpenClaw 插件治理

Phase 3 可以在 Phase 2 的接口稳定后并行收尾；Phase 4 不得在 Phase 2 的 sync 语义未稳定前扩展 live 写入路径。

## Phase 0: 建立可信基线并修正状态漂移

结果：文档、doctor 输出和 CI 对当前仓库结构使用同一套事实；后续改动有干净基线。

### Task 0.1: 记录基线

Artifacts / Locations:
- Review: STATUS.md
- Review: .github/workflows/validate.yml
- Review: scripts/doctor.ps1
- Review: tests/config-sync.tests.ps1
- Review: tests/harness-profile.tests.ps1
- Review: tests/harness-env.tests.ps1

- [x] Step 1: Gather the needed input

运行：git status --short --branch；tests/config-sync.tests.ps1；tests/harness-profile.tests.ps1；tests/harness-env.tests.ps1。记录当前测试总数、managed skill 数量、doctor warnings、未安装的 hooks 和状态文档中的矛盾事实。

- [x] Step 2: Produce the task output

在本计划或对应阶段记录中固定基线，不把机器私有路径、token、backup 内容或 live 文件内容写入 Git。

- [x] Step 3: Verify the output

Expected：三组现有回归测试全部通过，工作树只包含本计划文件或预期的已审阅变更。

### Task 0.2: 修正状态和结构检查

Artifacts / Locations:
- Modify: STATUS.md
- Modify: scripts/doctor.ps1
- Modify: .github/workflows/validate.yml
- Review: README.md、CLAUDE.md、docs/README.md

- [x] Step 1: Reconcile current facts

统一真实机器 activation、live parity、hooks 安装状态和下一步描述；删除已经完成事项的待办描述，保留历史证据但区分已完成和待重新验证。

- [x] Step 2: Correct repository structure checks

让 doctor 以 claude/skills、codex/skills、openclaw/skills 为当前 generated layout 的事实来源，不再因为不存在的顶层 generated/ 产生误导性 warning。

- [x] Step 3: Make required CI checks fail closed

对 doctor、scan、build 和三组核心测试文件的缺失改为失败；只有明确标记为 optional 的检查才允许 warning-and-skip。

- [x] Step 4: Verify the output

运行：scripts/doctor.ps1 -RepoRoot . -SkipSecretsScan；scripts/scan-secrets.ps1 -RepoRoot .；git diff --check。Expected：doctor 不再报告错误的 generated layout warning；CI 核心入口缺失时返回非零；secret scan 和 diff check 通过。

## Phase 1: 导入、fingerprint 与合并安全边界

结果：import/merge 对相同内容只去重，对不同内容只报告冲突，不再根据质量分数静默选择 canonical；Claude、Codex、OpenClaw 的来源路径和平台分类一致。

### Task 1.1: 统一 inventory 与平台路径探测

Artifacts / Locations:
- Modify: scripts/skills-common.ps1
- Modify: scripts/inventory-skills.ps1
- Modify: scripts/analyze-skills.ps1
- Review: scripts/sync.ps1
- Create: tests/skills-import.tests.ps1

- [x] Step 1: Define the source contract

统一 Claude、Codex、OpenClaw 的 live probe 顺序；Codex 使用 .codex/skills 优先、.agents/skills fallback；inventory 明确排除 .system，并为 OpenClaw 提供显式 source tool / collection 字段。

- [x] Step 2: Preserve evidence

让每个 record 至少包含 normalized name、source tool、machine id、collection、source path、file count、size、SKILL.md hash、tree hash、平台信号、secret/path/binary findings 和 scan status。modified time 未实现前必须记录为 not-collected，不得推断。

- [x] Step 3: Add focused tests

测试 fake home 中的 .codex/skills 优先级、.agents/skills fallback、.system 排除、OpenClaw inventory、重复运行不覆盖已有 inbox batch。

- [x] Step 4: Verify the output

运行 tests/skills-import.tests.ps1 和 scripts/scan-secrets.ps1 -RepoRoot .。Expected：inventory 结果与 sync 的 live path 选择一致，.system 不进入候选，测试覆盖所有路径分支。

### Task 1.2: 让 auto-merge fail closed

Artifacts / Locations:
- Modify: scripts/auto-merge-skills.ps1
- Modify: scripts/promote-skill.ps1
- Modify: scripts/normalize-skill.ps1
- Modify: scripts/skills-common.ps1
- Extend: tests/skills-import.tests.ps1
- Review: docs/MERGE_POLICY.md

- [x] Step 1: Implement deterministic decisions

按以下顺序决策：

1. 完全相同 tree fingerprint -> DEDUPLICATED。
2. 已有有效 canonical -> CANONICAL_RETAINED，不同候选只报告。
3. 无 canonical 且只有一个有效 fingerprint -> PROMOTE_CANDIDATE，仍需显式 Apply。
4. 同名不同 fingerprint、平台冲突、路径/二进制/secret 风险 -> CONFLICT 或 QUARANTINED。

quality score 只能作为报告排序字段，不能决定 canonical。

- [x] Step 2: Complete OpenClaw support

使 analyze、auto-merge、promote、normalize 支持 openclaw-only，并验证 shared / Claude-only / Codex-only / OpenClaw-only 之间的名称冲突。

- [x] Step 3: Correct report accounting

报告真实的 exact duplicate count、conflict groups、quarantine reason codes、canonical source、未采用候选和 source fingerprints；不写敏感值。

- [x] Step 4: Verify the output

覆盖：完全重复、同名不同树、同名仅 SKILL.md 相同、已有 canonical、Claude/Codex 平台冲突、OpenClaw-only 晋升、secret quarantine、.system 排除。Expected：所有不同 fingerprint 的自动合并 Apply 都被阻止，除非存在明确且唯一的人工选择。

## Phase 2: 内容感知、计划绑定与事务性 sync

结果：sync 能区分真正变化和同名 no-op；Apply 绑定已审阅的 dry-run 计划，并在中途失败时保持可恢复状态。

### Task 2.1: 引入内容感知的 sync plan

Artifacts / Locations:
- Modify: scripts/sync.ps1
- Modify: scripts/report-common.ps1
- Modify: scripts/build-skills.ps1
- Create: schemas/sync-plan.schema.json
- Create or extend: tests/sync.tests.ps1

- [x] Step 1: Define plan data

每个平台、每个 managed skill 记录 source tree hash、live tree hash、manifest membership、action、.system 状态、unknown/prune 状态和 backup requirement。

- [x] Step 2: Add plan binding

dry-run 输出稳定 JSON plan 和 plan hash；Apply 前重新计算 source、manifest、live target 的摘要。摘要变化时拒绝 Apply，并要求重新 dry-run。

- [x] Step 3: Separate action types

把 add、content-update、no-op、prune、unknown-preserved 分开报告，避免把所有同名目录都显示为 update。

- [x] Step 4: Verify the output

在 fake home 中验证完全相同内容是 no-op、单文件变化是 update、manifest 外 unknown 永不删除、managed stale 才能 prune、.system 永不进入计划。

### Task 2.2: 实现受控 staging、journal 和失败恢复

Artifacts / Locations:
- Modify: scripts/sync.ps1
- Modify: scripts/backup.ps1 only if journal needs a stable backup manifest reference
- Extend: tests/sync.tests.ps1
- Review: docs/RESTORE.md

- [x] Step 1: Stage each managed skill

在目标 live root 同一文件系统的临时目录完成复制和验证，再替换目标目录；OpenClaw .clawhub 保留逻辑必须在 staging 方案中保持不变。

- [x] Step 2: Record operations

在 repo 外记录 run id、plan hash、backup path、已完成操作和失败点；报告只包含 metadata 和 skill names，不包含文件内容。

- [x] Step 3: Add rollback behavior

任何 managed skill apply 失败都必须停止后续操作，并能依据 backup/journal 恢复已变更的 managed targets；unknown live 目录和 .system 不得被 rollback 代码触碰。

- [x] Step 4: Verify the output

通过 fake home 注入复制失败、目标目录缺失、空 manifest、unknown 目录、.system 存在等场景，确认失败后 live managed set 可恢复且状态报告明确为 failed/partial。

## Phase 3: CI、回归覆盖与机器可读证据

结果：核心安全约束进入自动验证，脚本结果可被 CI 和后续 Agent 稳定消费。

### Task 3.1: 补齐核心脚本测试矩阵

Artifacts / Locations:
- Create or modify: tests/sync.tests.ps1
- Create: tests/skills-import.tests.ps1
- Create: tests/openclaw-plugin.tests.ps1
- Create: tests/doctor.tests.ps1
- Modify: .github/workflows/validate.yml

- [x] Step 1: Cover sync and backup

覆盖 dry-run no-op、add/update/prune、unknown preservation、.system preservation、backup-before-apply、custom HomeRoot rejection、plan drift rejection 和 rollback。

- [x] Step 2: Cover import and merge

覆盖 fingerprint conflict、OpenClaw-only、Codex path fallback、quarantine、duplicate batch 和不覆盖 canonical。

- [x] Step 3: Cover plugin and doctor behavior

使用 fake openclaw executable 或 CLI fixture，覆盖 desired-state plan、unknown plugin preservation、enable/disable、CLI unavailable fallback、parity failure；doctor 覆盖结构缺失和 warning/fail 规则。

- [x] Step 4: Verify the output

CI 必须在 Windows runner 上执行全部核心测试；任何核心脚本缺失、测试缺失或 schema 校验失败都返回非零。

### Task 3.2: 固化报告 schema 和命令入口

Artifacts / Locations:
- Modify: scripts/report-common.ps1
- Modify: scripts/agent-dotfiles.ps1
- Create: schemas/run-report.schema.json
- Modify: reports/README.md

- [x] Step 1: Define stable JSON commands

为 doctor、build、scan、sync、env status、inventory、merge 提供 JSON 输出或 JSON report path；人类输出仍保留，但不能作为唯一机器接口。

- [x] Step 2: Extend the dispatcher carefully

加入 config、profile、inventory、merge、plugin 子命令前，保持现有脚本作为唯一实现，不在 wrapper 中复制业务逻辑。所有会写 live 的命令继续要求显式 -DryRun 或 -Apply。

- [x] Step 3: Verify the output

对每个 JSON 输出运行 schema validation，并确认报告不包含 secrets、完整私有路径、backup 内容、session/cache 内容或 .system 内容。

## Phase 4: Environment 可复现、attestation 与 rollback

结果：environment 不只是 skills 子集切换，而是带来源证明、可验证 lock 和明确回退路径的运行时版本。

### Task 4.1: 扩展 environment lock

Artifacts / Locations:
- Modify: scripts/build-harness-env.ps1
- Modify: scripts/harness-env-common.ps1
- Modify: scripts/status-harness-env.ps1
- Modify: scripts/activate-harness-env.ps1
- Create: schemas/harness-env-lock.schema.json
- Extend: tests/harness-env.tests.ps1

- [x] Step 1: Record provenance

在 env.lock.json 中记录 environment definition hash、repo commit、平台 manifest hash、每个 staged skill tree hash、profile output hash 和 managed plugin declaration hash（若纳入该环境）。

- [x] Step 2: Validate activation inputs

activate 只能使用 lock 与 staging 内容完全匹配的环境；定义变更、source 变更或 staging 文件缺失时必须先 rebuild。

- [x] Step 3: Add attestation output

env status --Json 报告 active env、lock validity、definition drift、live managed-set parity、.system 状态和 backup reference，不报告敏感内容。

- [x] Step 4: Verify the output

fake repo/fake home 测试 source 变更、lock 损坏、staging 缺失、激活后 drift 和重建后的恢复路径。

### Task 4.2: 增加显式 rollback

Artifacts / Locations:
- Create: scripts/rollback-harness-env.ps1
- Modify: scripts/agent-dotfiles.ps1
- Modify: docs/RESTORE.md
- Extend: tests/harness-env.tests.ps1

- [x] Step 1: Define rollback scope

rollback 只恢复本仓库 managed skills 和对应状态；不修改 .system、unknown live dirs、credentials、sessions、cache、Codex config.toml 或 OpenClaw machine state。

- [x] Step 2: Require explicit selection

rollback 必须指定 backup/run id，并先输出 dry-run 计划；Apply 前验证 backup manifest、target root 和 plan hash。

- [x] Step 3: Verify the output

fake home 验证激活环境 A -> B -> rollback A，managed parity 恢复、unknown 和 .system 保持不变，状态文件只在成功后更新。

## Phase 5: 可选扩展轨道（需要单独评审）

本阶段不与 Phase 1-4 混合实现。只有在前述阶段稳定、测试覆盖充分后，才从以下方向选择一个独立设计。

### Task 5.1: Project Harness 多平台组件

扩展 harness-source/components/ 和 harness-profile-common.ps1，实现 Claude commands/agents、Codex prompts/agents 或 OpenClaw 受控配置。每种输出类型都必须有独立 schema、目标 allowlist、dry-run、rollback 和回归测试；不能通过扩大 apply-harness-profile.ps1 的路径权限来实现。

- [x] 新增 component output contract/schema，覆盖 Claude commands/agents、Codex prompts/agents、OpenClaw project config。
- [x] build/apply/status 接入 DirectoryFiles 与 OpenClaw StructuredMerge；apply 保持项目级 allowlist、备份和事务性回滚。
- [x] `tests/harness-multiplatform.tests.ps1` 覆盖成功、空/重复执行、非法路径、敏感字段和失败回滚。

### Task 5.2: MCP 模板安全落地

把 claude/mcp/apply-mcp.ps1 从 placeholder 变成模板验证 + 环境变量检查 + CLI 注册流程。禁止整体覆盖 ~/.claude.json，禁止把 secret 写入模板、报告或命令日志；先设计 dry-run 和 removal/update 语义，再实现 apply。

- [x] 新增模板 schema/validator、占位符与环境变量存在性/哈希 attestation。
- [x] 实现 dry-run plan hash、单服务器 add/update/remove、repo 外备份和失败阶段证据。
- [x] `env build` staging MCP templates；`env activate` 不隐式注册；统一 CLI 增加显式模式 gate。
- [x] `tests/mcp.tests.ps1` 覆盖脱敏、缺失变量、路径边界、update/remove、plan drift、CLI 失败和重复执行。

### Task 5.3: OpenClaw 插件版本治理

在 openclaw/plugins/managed-plugins.json 增加明确的版本/来源约束、更新策略和验证字段；通过 OpenClaw CLI 管理状态，不编辑 installs.json。必须先解决 CLI 失败后的部分成功记录和可回退证据，再考虑自动更新。

## 阶段完成标准

一个阶段只有同时满足以下条件才算完成：

- 该阶段的所有 checkbox 完成，且没有未解释的失败或 warning。
- 新增测试覆盖了本阶段的成功、失败、空集合、路径边界和重复执行场景。
- pwsh -NoProfile -File scripts/scan-secrets.ps1 -RepoRoot . 通过。
- git diff --check 通过，generated output、imports、backups、live home 和机器私有文件未被提交。
- 所有 apply 仍经过 dry-run、backup 和现有安全 gate；没有直接写入 Codex .system。
- STATUS.md 只记录已验证事实，计划进度保留在本文件或对应 active status 记录中。

## 推荐执行顺序

1. Phase 0：先清理基线和状态漂移。
2. Phase 1：修复 inventory / merge / promote 的 fail-closed 逻辑。
3. Phase 2：实现内容感知 plan 和事务性 sync。
4. Phase 3：把 Phase 1-2 的约束全部纳入 CI 和 JSON 证据。
5. Phase 4：在稳定 sync 之上做 environment lock、attestation 和 rollback。
6. Phase 5：根据实际需求从 Harness、MCP、OpenClaw 插件中选择一个单独立项。

当前执行状态：Phase 0–4 已完成并通过本地回归验证；Phase 5 的 Task 5.1（多平台 Harness）和 Task 5.2（MCP 模板）已完成并通过本地回归验证；Task 5.3（OpenClaw 插件版本治理）保持未启动，需另行评审。

本次回归验证证据包括：config-sync 17/17、harness-profile 33/33、multi-platform Harness 20/20、MCP 22/22、harness-env 117/117、skills import/merge 22/22、unified CLI 12/12，以及 OpenClaw plugin、doctor、sync 测试全部通过；真实仓库 build、fallback secret scan、dry-run sync 和 env/plan/run-report JSON schema 校验通过。未执行任何本任务内的 live `-Apply`、MCP 注册或 environment rollback，未修改 Codex `.system`。
