# Harness Environments Phase 3（项目联动 RequiredEnv）Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** 项目可在 `.agent-harness/profile.psd1` 声明 `RequiredEnv = '<name>'`；`env status -ProjectRoot <p>` 检测"当前激活环境 ≠ 项目声明"并给出提醒与建议命令。只检测提醒，绝不自动 activate。

**Approach:** 设计文档 §4.3 原文实施。改动极小：project profile 允许键加 `RequiredEnv`（additive，不影响既有校验），`status-harness-env.ps1` 加 `-ProjectRoot` 检查段，本仓库自身 profile 声明 `RequiredEnv = 'work'` 作为 dogfood，测试与文档同步。

**Materials:** `scripts/harness-profile-common.ps1` `Get-HarnessProjectProfile`（允许键列表在此，line ~86）；`scripts/status-harness-env.ps1`；`tests/harness-env.tests.ps1` 的 fake repo/fake home 基建；设计文档 §4.3。

**Validation:** 两个测试套件全绿；真机 `env status -ProjectRoot .` 输出正确提醒；git 卫生。

---

### Task 1: 允许键 + status 检查

- [x] **Step 1**: `harness-profile-common.ps1` 的 project profile AllowedKeys 加 `'RequiredEnv'`（library profile/component 的键列表不动）。
- [x] **Step 2**: `status-harness-env.ps1` 加 `[string]$ProjectRoot` 参数：给定时读 `<ProjectRoot>/.agent-harness/profile.psd1`（缺文件或无 `RequiredEnv` 键 → 输出 `Project declares no RequiredEnv.`；有 → 三种结果：`matches active`、`does not match active '<x>' — run: agent-dotfiles.ps1 env activate <name> -DryRun`、`required env '<n>' has no definition` 警告；无激活环境时提示 `no environment activated — run: ...`）。只读不写；退出码仍恒 0。
- [x] **Step 3**: 本仓库 `.agent-harness/profile.psd1` 加 `RequiredEnv = 'work'`。
- [x] **Step 4**: 验证：`pwsh -NoProfile -File scripts/status-harness-env.ps1 -ProjectRoot .` 输出与当前激活状态相符的提醒；`status-harness-profile.ps1 -ProjectRoot .` 与 `build-harness-profile.ps1 -ProjectRoot .` 不因新键报错。

### Task 2: 测试

- [x] **Step 1**: `tests/harness-env.tests.ps1` 加第 10 组：fake 项目目录（`.agent-harness/profile.psd1` 含 `RequiredEnv='small'`）。用例：无激活状态 → 提醒含 `env activate small`；激活 `small` 后（复用第 9 组留下的状态或重新 apply）→ `matches`；声明 `RequiredEnv='ghost'` → `has no definition` 警告；profile 无 `RequiredEnv` 键 → `declares no RequiredEnv`；无 profile 文件 → 同样不报错。
- [x] **Step 2**: 两个套件全绿：`tests/harness-env.tests.ps1`、`tests/harness-profile.tests.ps1`。

### Task 3: 文档与提交

- [x] **Step 1**: `docs/README.md` §16 命令清单加 `-ProjectRoot` 用法与"只提醒不自动切换"规则；§15 提一句 profile 可声明 `RequiredEnv`（指向 §16）。
- [x] **Step 2**: `STATUS.md`：phase 描述加 Phase 3；canonical decisions 加"RequiredEnv 只提醒，绝不自动 activate"。
- [x] **Step 3**: spec §4.3 加 Implementation note。
- [x] **Step 4**: 全量校验链 + `git status` 审查 + 提交。
