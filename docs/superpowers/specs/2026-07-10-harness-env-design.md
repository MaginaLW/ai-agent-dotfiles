# Harness Environments（conda 式环境管理）设计

日期：2026-07-10
状态：已与用户对齐的设计稿，待审阅
范围：方案 C —— 分阶段混合（薄环境层 + 复用现有 gated 部署机制）

## 1. 背景与动机

仓库现有三块相关能力：

- `harness-source/`：component/profile 库（Project Harness Profiles MVP，仅项目本地）。
- config-sync（`config-status/pull/push.ps1`）：home ↔ repo 白名单同步，但 home 只有"一份"状态。
- `sync.ps1`：manifest-scoped live skills 同步。

缺少的是 conda 的核心形态：**命名环境、一条 activate 命令切换、当前环境可查、项目声明所需环境**。本设计补上这一层。

## 2. 已确认的方向决策

| 决策点 | 结论 |
|---|---|
| 作用域 | 两层：全局命名环境可切换 + 项目声明所需环境，分阶段实施 |
| 环境内容 | skills 子集 + harness 配置（settings/AGENTS.md 规则块/prompts/permissions）+ MCP 模板（仅占位符）；OpenClaw 插件集不纳入 |
| 切换机制 | 环境目录 + 受控部署：每环境构建到 `envs/<name>/`，activate 复用现有 `sync.ps1`/`config-pull.ps1` gated 机制；机器私有状态永不随环境切换 |
| 项目联动 | 只检测提醒，手动切换；不做自动 activate |
| 实现方向 | 方案 C：薄环境层（定义 + 状态文件），部署始终走现有单一写 home 路径 |

## 3. 概念模型与目录结构

### 3.1 环境定义（tracked，源真相）

`harness-source/envs/<name>.psd1`，与现有 profile/component 同风格：

```powershell
@{
    SchemaVersion = 1
    Name          = 'work'
    Description   = '日常编码环境'
    Profile       = 'coding'          # 引用 harness-source/profiles/，继承其 Extends 链
    Skills        = @{
        Claude = @('git-review', 'systematic-debugging')   # manifests 管理名单的子集
        Codex  = @('...')
    }
    McpTemplates  = @('...')          # 引用 components/mcp-templates/，只含占位符
}
```

设计约束：

- 不建单独注册表文件：`env list` 直接枚举 `harness-source/envs/*.psd1`。
- 环境之间不互相 Extends：复用 profile 已有继承链，避免两套继承语义。
- `Skills` 中的名字必须是对应平台 manifest 管理名单的子集，build 时硬校验。

### 3.2 环境构建产物（Git-ignored，disposable）

仓库根新增 `envs/<name>/`。`env build` 将环境定义解析后完整构建到此：skills 子集、harness 配置文件、MCP 模板。目录布局刻意对齐 `sync.ps1` / `config-pull.ps1` 期望的源布局，使部署阶段只是"把现有脚本的源指向 staging"，不新增写 home 代码。

### 3.3 当前环境状态（机器私有，Git-ignored）

`state/current-env.json`：当前激活环境名、激活时间、各部分内容哈希。`env status` 用哈希对比 home 实际状态报告 drift（环境定义已变未重新 activate、home 被手动改动等）。状态文件只是缓存视图，不假装永远为真——哈希对比是权威。

### 3.4 CLI

挂在统一入口 `scripts/agent-dotfiles.ps1` 下：

```
agent-dotfiles.ps1 env list       # 枚举可用环境 + 标记当前激活
agent-dotfiles.ps1 env status     # 当前环境 vs home 的 drift 报告（只读）
agent-dotfiles.ps1 env build <n>  # 构建 envs/<n>/ staging
agent-dotfiles.ps1 env activate <n> [-Apply]   # 默认 dry-run
```

实现按仓库惯例：`scripts/harness-env-common.ps1` + 各子命令脚本 + `tests/harness-env.tests.ps1`，并入 `.github/workflows/validate.yml`。

## 4. 分期计划

### Phase 1 —— 只读环境层

- 交付：`env list` / `env status` / `env build`、环境定义 schema、两个示例环境（`work`、`minimal`）。
- 全程不写 home、不改任何安全规则。无状态文件时 `env status` 报告 "no environment activated"。
- 验收：`tests/harness-env.tests.ps1` 全绿并进 CI。

### Phase 2 —— 门控切换（本设计即"显式解禁全局切换"的 reviewed design）

`env activate <n>` 编排：build → 扫密 → 备份 → 以 `envs/<n>/` 为源跑参数化的 `sync.ps1` / `config-pull.ps1` → 成功后写状态文件。

硬约束：

- 默认 dry-run；`-Apply` 才写 home；apply 前备份为强制步骤。
- 只动 manifest/whitelist 范围内路径；home-only 文件（credentials、sessions、缓存、Codex `.system`、Codex `config.toml`）永不随环境切换、永不 prune。
- 写 home 的代码路径仍仅为现有 `sync.ps1` / `config-pull.ps1`；环境层只做编排。
- 落地时同步修订 `CLAUDE.md` 与 `STATUS.md` canonical decisions：将"不做全局 home 切换"改为"仅经由 gated `env activate` 进行"。

> **Implementation note (2026-07-10)**：Phase 2 已落地，范围为 **skills 子集切换 + 状态文件**。
> config-pull 的 home 配置部署未接入：当前所有环境的 profile 组件只产出项目级文件，
> 不存在环境差异化的 home 配置可部署，接入只会增加一条无差别写 home 路径。
> 待出现 home 级差异化组件时单独评审接入。切换裁剪语义由"staging 携带全量 manifest
> 副本 + skills 目录只含环境子集"驱动 `sync.ps1` 的既有 manifest-scoped prune 实现。
> 落地过程中修复了 `sync.ps1` 两个由空受管集/未知目录触发的潜伏缺陷（见 STATUS.md）。

### Phase 3 —— 项目联动

- 项目 `.agent-harness/profile.psd1` 增加可选字段 `RequiredEnv = '<name>'`。
- `env status -ProjectRoot <p>` 增加检查：当前激活环境 ≠ 项目声明时输出提醒与建议命令。
- 不做任何自动 activate。

> **Implementation note (2026-07-10)**：Phase 3 已按上述范围落地。`RequiredEnv` 为
> project profile 的合法可选键（library profile/component 键集不变），检测覆盖
> 匹配/不匹配/未激活/声明的环境无定义/未声明/无 profile 六种情形，全部只读。

## 5. 非目标（本轮不做）

- lockfile / `env export` 跨机复现。
- 环境回滚命令（回滚 = activate 另一环境，或从强制备份恢复）。
- OpenClaw 插件集入环境。
- MCP secrets 管理（模板仅占位符）。
- 会话级环境变量隔离（CLAUDE_CONFIG_DIR 等路线已评估并否决）。
- home 目录 junction/链接改造（已评估并否决：home 混杂机器私有状态，指针切换风险过高）。

## 6. 风险与缓解

| 风险 | 缓解 |
|---|---|
| Phase 2 首次 apply 写坏 home | 先 fake-home 测试（沿用仓库既有测试模式），再真机 dry-run 人审后 apply；备份强制 |
| 状态文件与 home 脱节（用户绕过 env 直接跑 sync） | 状态文件存内容哈希，`env status` 哈希对比发现并报告 |
| 环境定义引用不存在的 skill/profile | build 硬校验失败；CI 覆盖 |
| 环境层演化成第二条写 home 路径 | 设计约束写入 CLAUDE.md：环境层永远只做编排，部署只经现有脚本 |

## 7. 验证方法

- 每期：`tests/harness-env.tests.ps1`（Phase 1 起建立，逐期扩展），进 `.github/workflows/validate.yml`。
- Phase 2 额外：fake-home 端到端 activate 测试；真机首次 apply 前人工 `git diff` / dry-run 审查。
- 文档同步：`docs/README.md` 新增章节，`STATUS.md` 决策与阶段状态更新。
