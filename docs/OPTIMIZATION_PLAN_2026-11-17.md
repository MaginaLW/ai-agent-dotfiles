# 仓库全景优化立项方案（安全门禁、三端闭环、插件生命周期与仓库减负）

日期：2026-11-17。
**O1–O5 已完成。** 下文保留 2026-11-17 的立项依据和设计决议。历史分支已于 2026-11-20 清理，Project Harness Profiles 继续按决议 5 被动观察。[当前状态](../STATUS.md)

本文记录在 [AGENTS.md](../AGENTS.md) 约束下，对 `ai-agent-dotfiles` 仓库与本机只读状态进行全面审计后整理出的 7 大类 14 项待优化清单、所有者在交互访谈中确认的 6 项关键设计决议，以及面向跨端执行代理（Antigravity / Codex / ZCode）的五个独立实施轨道（`O1`–`O5`）。

核心原则：**外科手术式最小改动**；保持默认 DryRun、零明文凭据与零本机私有路径入库、保留非托管目录与个人设置；`AGENTS.md` Skill rules 10 的持续授权边界保持不变，不自动外推至 `config-sync`、Antigravity 插件或 `mcp-sync`。

---

## 1. 所有者设计决议记录（2026-11-17）

以下 6 项决策已在立项前与所有者逐一对齐，后续任何客户端接力实施对应轨道时直接沿用，不再重复发起同一设计选型访谈（涉及 live 写入或政策修订的执行授权仍按各轨道边界申请）：

1. **三端全局 `AGENTS.md` 与 `config-sync` 方案**：
   - 补齐 `zcode/AGENTS.md` 并纳入 `manifests/whitelist.psd1` 与 `scripts/config-common.ps1` 的受管 block 同步（显式 `-Platform ZCode`），自动更新 `~/.zcode/AGENTS.md` 受管块并完整保留块外 ZCode 专属尾部条款；默认同步范围继续保持 `Codex` 不变。
   - 维持 `codex/AGENTS.md`、`antigravity/AGENTS.md`、`zcode/AGENTS.md` 三份约 40 行的扁平源文件，**不引入公共模板生成层**，以确保 `config-push` 从本机反向捕获受管块的能力完好无损。
   - 统一 `config-status.ps1`、`config-pull.ps1`、`config-push.ps1` 的 `-Platform` 逗号分隔多选支持，消除与 `mcp-sync.ps1` 的参数体验割裂，并对齐统一 CLI `scripts/agent-dotfiles.ps1` 的参数校验。
2. **Antigravity 插件状态迁出与受控 `update` 一步到位**：
   - 构建候选包继续保留在当前工作树本地 `tmp/antigravity/`；将机器级归属回执、挂起标记与安装尝试快照（`installed.json`、`pending-*.json`、attempt 目录）迁移至与 `deploy-skills.ps1` 一致的 `%LOCALAPPDATA%/ai-agent-dotfiles.deploy/antigravity/`，并提供已核验 `0.4.0` 回执的迁移路径，从而释放并回收长期保留的临时工作树 `wt-ag-040`。
   - 将 `antigravity status` 解耦为直接比对源码期望摘要与线上已装内容，不再因当前工作树未跑 `build` 或门禁指纹变化而提前报错 `blocked` 并把已装文件误显示为全量 `Added`。
   - 同步完成原生升级合同验证与落地：基于“写前备份 + 官方 `agy plugin uninstall` + `agy plugin install` + 读回一致性校验”打通受控 `update` 流程，并同步修订 `AGENTS.md` Skill rules 3 及 `docs/README.md` §15。
3. **只读可观测性职责分离（`doctor.ps1` vs 顶层 `status`）**：
   - `scripts/doctor.ps1` 继续保持零外部 CLI 依赖的轻量基础设施检查（确保在 CI `scripts/run-repository-validation.ps1` 隔离环境中稳定运行），将已退役 Claude 平台的缺失 `~/.claude/skills` 提示从 `WARN` 降为 `INFO`，并补齐核心必检脚本清单。
   - 在统一入口 `scripts/agent-dotfiles.ps1` 新增顶层只读 `status` 子命令，一站式汇总上次记录环境、三端 `config-status`、`antigravity status` 与 `mcp status`（支持 `-Json` 输出）。
4. **秘密扫描显式规则库精准扩充**：
   - 保留 `.gitleaks.toml` 与 `scripts/scan-secrets.ps1` 的确定性显式规则契约（不回退开启泛化默认规则，防止对普通哈希/示例文本产生误报），在 `.gitleaks.toml`、`scripts/scan-secrets.ps1` 及 `scripts/mcp-sync.ps1` 同步精准补齐：Google/Gemini API Key（`AIza` 前缀 39 位密钥）、无算法前缀的 PKCS#8 标准 `PRIVATE KEY` 块头，以及 GitHub OAuth/App/Refresh 令牌（`gho_` / `ghu_` / `ghs_` / `ghr_` 前缀）。
5. **存量子系统与退役平台处置**：
   - **Reasonix 彻底清理**：确认已停用，移除 `scripts/repo-common.ps1`、`.gitignore`、`tests/scan-secrets.tests.ps1` 与 `tests/repository-policy.tests.ps1` 中的 `reasonix/skills` 及 `.reasonix/desktop-topic-*` 保护特判。
   - **Project Harness Profiles 设为冻结观察项**：实测本仓 `status-harness-profile.ps1` 因 `AGENTS.md` 无 `AGENT-HARNESS` 标记块而全部 `skip`，暂不盲目删除也不扩写 Antigravity/ZCode 目标。按被动观察四元组管理：
     - **触发源**：后续下游项目维护或仓库阶段性盘点；
     - **窗口周期**：自 2026-11-17 起至下次跨项目盘点（最长 90 天，纯人工被动核对，不新增定时任务、台账或后台采集）；
     - **终止条件**：确认任一下游项目仍在消费则转入按需维护；确认零下游项目依赖则单独立项退役清理；
     - **连续失败上限**：不适用自动重试；若单次盘点无法确认某个下游仓库归属则保持冻结并记录缺口。
6. **历史分支与临时目录清理**：
   - 经只读核验（`git branch -r --merged main` 与 `git branch --merged main`），`origin` 全部 19 条非 `main` 历史分支（8 条 `antigravity/*`、11 条 `codex/*`）及本地 `codex/subagent-dispatch-20261112` 均已 100% 合入 `main`，零未合并孤立提交。本地分支在轨道 `O5` 按 `AGENTS.md` 祖先证明规则清理；远端 19 条已合入分支须在轨道 `O5` 取得单独明确授权后清理。

---

## 2. 全量 14 项待优化项清单总览

| 编号 | 类别 | 待优化项与实测依据 | 主要涉及路径 | 归属轨道 |
|---|---|---|---|---|
| `#1` | 安全门禁 | 秘密扫描补齐 Google `AIza` 密钥、PKCS#8 标准私钥块与 GitHub `gho_/ghu_/ghs_/ghr_` 令牌，三处规则同步 | `.gitleaks.toml`、`scripts/scan-secrets.ps1`、`scripts/mcp-sync.ps1` | `O1` |
| `#2` | 纵深防御 | `.gitignore` 补齐 `antigravity/` 运行时排除项（与 `manifests/whitelist.psd1` 的 `ExcludedItems` 对齐） | `.gitignore` | `O1` |
| `#3` | 插件状态 | Antigravity 机器级归属回执与尝试记录迁至 `%LOCALAPPDATA%/ai-agent-dotfiles.deploy/antigravity/`，解耦并回收 `wt-ag-040` | `scripts/antigravity-plugins.ps1`、`tests/antigravity-plugins.tests.ps1` | `O3` |
| `#4` | 插件巡检 | `antigravity status` 改为直接对比源码期望摘要与线上已装内容，消除未跑 `build` 或门禁指纹变动引发的 `blocked`/`Added` 误报 | `scripts/antigravity-plugins.ps1`、`tests/antigravity-plugins.tests.ps1` | `O3` |
| `#5` | 插件升级 | 完成 T0 验证并打通基于写前备份 + `agy plugin uninstall` + `agy plugin install` + 读回校验的受控 `update`，修订规则与手册 | `scripts/antigravity-plugins.ps1`、`AGENTS.md`、`docs/README.md` | `O3` |
| `#6` | 配置闭环 | 新增 `zcode/AGENTS.md` 纳入受管 block 同步（显式 `-Platform ZCode`），替代 `~/.zcode/AGENTS.md` 手工同步 | `zcode/AGENTS.md`、`manifests/whitelist.psd1`、`scripts/config-*.ps1`、`docs/ZCODE.md`、`docs/ONBOARD_NEW_MACHINE.md` | `O2` |
| `#7` | 协议维护 | 保持 `codex/`、`antigravity/`、`zcode/` 三份约 40 行扁平 `AGENTS.md` 公共底线条款一致，保留 `config-push` 捕获能力 | `codex/AGENTS.md`、`antigravity/AGENTS.md`、`zcode/AGENTS.md` | `O2` |
| `#8` | CLI 一致性 | `config-status/pull/push.ps1` 支持 `-Platform` 逗号分隔多选，并统一 `agent-dotfiles.ps1` 子命令参数防缩写校验粒度 | `scripts/config-status.ps1`、`scripts/config-pull.ps1`、`scripts/config-push.ps1`、`scripts/agent-dotfiles.ps1` | `O2` |
| `#9` | 只读巡检 | `doctor.ps1` 将缺失 `~/.claude/skills` 由 `WARN` 降为 `INFO` 并补齐必检脚本；`agent-dotfiles.ps1` 新增顶层只读 `status` 汇总全机漂移 | `scripts/doctor.ps1`、`scripts/agent-dotfiles.ps1`、`README.md`、`docs/README.md` | `O4` |
| `#10` | 存量子系统 | `Project Harness Profiles` 设为冻结观察项（本仓实测全 `skip` 且仅支持旧双端），按 §1 四元组跟踪下游真实依赖后再定维护或退役 | `scripts/*-harness-profile.ps1`、`harness-source/profiles/` | `O5` 盘点 |
| `#11` | 退役与细节 | 清理 `Reasonix` 历史特判与多余 `codex/.gitkeep`；修复 `brainstorming/SKILL.md` 3 处引用瑕疵（`Visual Choices` 标题、不存在的 `elements-of-style` skill 引用、挂接 `spec-document-reviewer-prompt.md`）；`build-skills.ps1` 构建 `claude/skills/` 时排除 Codex 专属 `agents/openai.yaml` | `scripts/repo-common.ps1`、`scripts/build-skills.ps1`、`.gitignore`、`codex/.gitkeep`、`skills-source/shared/brainstorming/SKILL.md`、`tests/scan-secrets.tests.ps1`、`tests/repository-policy.tests.ps1` | `O1` |
| `#12` | 上下文减负 | 将 `STATUS.md` `Current state` 压缩回纯现在时基线事实，清理历史 PR 叙事与过期统计（如旧 `24 skills`、`0/10/8`）以降低每次会话启动加载开销 | `STATUS.md` | `O1` |
| `#13` | 实机与分支 | 对齐本机 `[Antigravity] blender` MCP `/args` 漂移并完成 T3 端到端实测，归档 `MULTIMODAL_AND_MCP_EXTENSION_PLAN_2026-11-15.md`；清理 1 条本地与 19 条远端已合入分支及 ACL 受限残留临时目录 | `STATUS.md`、`docs/HISTORY.md`、`tmp/approval-effectiveness/` | `O5` |
| `#14` | 运行效率 | `deploy.ps1 -Apply` 在 `skills preflight` 扫描通过且输入未变时向 `config-pull -Apply` 传 `-SkipSecretScan` 消除重复全树扫描；`run-tests.ps1` 支持按 `-Suite` 过滤局部套件 | `scripts/deploy.ps1`、`scripts/run-tests.ps1`、`tests/deploy.tests.ps1`、`tests/test-runner.tests.ps1` | `O2` |

---

## 3. 分轨道实施路线图与验收门禁（Tracks O1 → O5）

各轨道相互解耦，建议按 `O1 → O2 → O3 → O4 → O5` 顺序独立建分支与 PR 推进（`O1`、`O2`、`O4` 互不冲突也可视情况先后合入）。

### 轨道 O1：安全门禁补强、退役清理与仓库减负（`#1`、`#2`、`#11`、`#12`）

- **改动范围与写入边界**：仅限仓库内部配置、脚本、skill 源文、测试与文档（不写本机 live home）。
  - `#1`：在 `.gitleaks.toml`、`scripts/scan-secrets.ps1` 的 `ScanBlockingPatterns` 与 `scripts/mcp-sync.ps1` 的 `Assert-McpSafeValue` 同步新增 Google API Key（`AIza` 开头 39 位）、PKCS#8 无算法前缀私钥块以及 GitHub `gho_` / `ghu_` / `ghs_` / `ghr_` 令牌规则，并在 `tests/scan-secrets.tests.ps1` 与 `tests/mcp-sync.tests.ps1` 补对应正负向用例（测试串继续在运行期拼接，不落盘字面量）。
  - `#2`：在 `.gitignore` 补齐 `antigravity/` 运行时排除项（对齐 `manifests/whitelist.psd1` 的 `Antigravity.ExcludedItems`，如 `config.json`、`mcp_config.json`、`import_manifest.json`、`node_modules/`、`plugins/`、`projects/`、`sidecars/`）。
  - `#11`：清理 `scripts/repo-common.ps1`、`tests/scan-secrets.tests.ps1`、`tests/repository-policy.tests.ps1` 与 `.gitignore` 中的 `reasonix/skills` 及 `.reasonix/*` 特判；移除多余的 `codex/.gitkeep`；修复 `skills-source/shared/brainstorming/SKILL.md`（L28 指向 `Visual Choices`、移除不存在的 `elements-of-style:writing-clearly-and-concisely` 引用、挂接同目录 `spec-document-reviewer-prompt.md`）；在 `scripts/build-skills.ps1` 构建 Claude 产物时排除仅供 Codex 使用的 `agents/openai.yaml`（并在 `tests/build-skills.tests.ps1` 验证 Codex 保留而 Claude/ZCode 排除）。
  - `#12`：将 `STATUS.md` 的 `Current state` 精简为纯现在时事实，历史版本叙事确认已在 `docs/HISTORY.md` 或 Git 历史可查后移除冗余段落与过期数字。
- **授权边界**：仓库内代码与测试按常规开发分支推进；提交、推送与合入 `main` 须获所有者授权。若 `build-skills.ps1` 对 `agents/openai.yaml` 的排除使 `work` 环境中 ZCode 已选的 `meng-cmame-writing` 触发预期 `update`，应在提交后先跑 `deploy-skills.ps1 -Environment work` dry-run 核对，按 `AGENTS.md` Skill rules 10 完成更新或请所有者确认。
- **验收门禁**：
  - 语法与扫描：`check-powershell-syntax.ps1`、`build-skills.ps1`、`scan-secrets.ps1`、`git diff --check`。
  - 受影响测试：`tests/scan-secrets.tests.ps1`、`tests/mcp-sync.tests.ps1`、`tests/build-skills.tests.ps1`、`tests/repository-policy.tests.ps1`、`tests/powershell-syntax-gate.tests.ps1`。
  - 合入前门禁：全量 `scripts/run-tests.ps1` 与 exact-head GitHub Actions `Validate`。

### 轨道 O2：三端 `config-sync` 闭环与部署/测试效率（`#6`、`#7`、`#8`、`#14`）

- **改动范围与写入边界**：仓库脚本、manifest、文档与测试 + 获准后对本机 `~/.zcode/AGENTS.md` 执行一次显式 `-Platform ZCode` 受管同步。
  - `#6` & `#7`：基于 `codex/AGENTS.md` 共享条款抽取/核对生成 `zcode/AGENTS.md`，在 `manifests/whitelist.psd1` 增加 `ZCode` 节点（`HomeRelativeRoot = '.zcode'`、`RepoRelativeRoot = 'zcode'`、`PushItems = @('AGENTS.md')`、`PullItems = @('AGENTS.md')`、`ExcludedItems` 覆盖 `skills`、`cli`、`cache` 等运行时文件），并在 `scripts/config-common.ps1` 的 `ManagedAgentsBlocks` 注册 `ZCode` 块标记；默认 `Platform` 保持 `Codex` 不变，更新 `docs/ZCODE.md` 与 `docs/ONBOARD_NEW_MACHINE.md`。
  - `#8`：在 `scripts/config-status.ps1`、`scripts/config-pull.ps1`、`scripts/config-push.ps1` 将 `-Platform` 从单层数组改为支持逗号拆分的规范化解析（复用或对齐 `mcp-sync.ps1` 逻辑），并检查 `scripts/agent-dotfiles.ps1` 对各子命令组参数传透的一致性。
  - `#14`：在 `scripts/deploy.ps1` 中当 `skills preflight` 刚完成 `scan-secrets.ps1` 且源码与配置输入未变时，向 `config-pull.ps1 -Apply` 传入 `-SkipSecretScan`（避免同一轮联合 Apply 连续拷贝并扫描全仓两次）；在 `scripts/run-tests.ps1` 新增可选 `-Suite` 过滤参数以支持局部快速带预算执行（无参数仍运行全部套件并校验 `test-timeouts.psd1` 覆盖率）。
- **授权边界**：`AGENTS.md` Skill rules 10 不覆盖 `config-sync`。向 `~/.zcode/AGENTS.md` 写入受管 block 前（尤其是首次包装已有文件外层的 ZCode 专属条款），必须先执行 `config pull -Platform ZCode -DryRun` 审阅完整计划并取得明确授权。
- **验收门禁**：
  - 语法与扫描：`check-powershell-syntax.ps1`、`scan-secrets.ps1`、`git diff --check`。
  - 受影响测试：`tests/config-sync.tests.ps1`、`tests/deploy.tests.ps1`、`tests/agent-dotfiles.tests.ps1`、`tests/test-runner.tests.ps1`、`tests/repository-policy.tests.ps1`。
  - 实机验证（获准后）：`config pull -Platform ZCode -Apply` 后 `config status -Platform Codex,Antigravity,ZCode` 均报告 `in-sync (managed block)`，且 `~/.zcode/AGENTS.md` 尾部专属条款完整保留。
  - 合入前门禁：全量 `scripts/run-tests.ps1` 与 exact-head CI `Validate`。

### 轨道 O3：Antigravity 插件状态迁出、巡检解耦与受控 `update`（`#3`、`#4`、`#5`）

- **改动范围与写入边界**：`scripts/antigravity-plugins.ps1`、`tests/antigravity-plugins.tests.ps1`、`AGENTS.md`（Skill rules 3 修订）、`docs/README.md` §15，以及本机 `%LOCALAPPDATA%/ai-agent-dotfiles.deploy/antigravity/`、临时工作树 `wt-ag-040` 与 Antigravity 插件目录的实机状态对齐。
  - `#3`：将机器级状态（`installed.json`、`pending-install.json`、`pending-external-*.json`、attempt 备份与快照）迁出 `<RepoRoot>/tmp/antigravity/` 至 `%LOCALAPPDATA%/ai-agent-dotfiles.deploy/antigravity/`（保留测试用可控根参数）；构建候选包与 `build.json` 留在工作树 `tmp/antigravity/`。提供核验逻辑将 `wt-ag-040` 下已核实的 `0.4.0` 回执迁入机器级状态根，并在读回验证通过后删除 `wt-ag-040`。
  - `#4`：重整 `Get-AgPluginPlan`：即使当前工作树尚未运行 `antigravity build` 或后续改过门禁指纹，`status` 也能依据源码预期文件哈希直接比对线上 `InstalledPath` 与归属回执，准确报告 `unchanged` / `update` / `install` / `blocked`，仅打印真实差异文件而非全量 `Added`。
  - `#5`：在隔离环境及受控条件下完成 T0 验证（确认 `agy plugin uninstall` + `agy plugin install` 幂等性、启用状态保留与 `config.json` 完整性）；实现基于“写前备份当前已装目录 + `uninstall` + `install` + 文件与外部插件不变性读回核验”的受控 `update` 路径（异常失败保留备份与诊断记录并止步），同步更新 `AGENTS.md` Skill rules 3。
- **授权边界**：涉及 `AGENTS.md` 规则权限边界修改须先提交精确 diff 由所有者审批；所有本机机器级回执迁移、删除 `wt-ag-040` 及实机 `antigravity deploy -Apply` / T0 升降版验证均不继承 Skill rules 10，每次操作前须审阅计划并获覆盖具体插件身份、版本与恢复范围的单独授权（卸载/安装外部变动期间需确认关闭 Antigravity 桌面端）。
- **验收门禁**：
  - 语法与扫描：`check-powershell-syntax.ps1`、`scan-secrets.ps1`、`git diff --check`。
  - 受影响测试：`tests/antigravity-plugins.tests.ps1`（补齐迁移、未构建态 `status` 精度与受控 `update`/失败回滚隔离夹具测试）、`tests/agent-dotfiles.tests.ps1`、`tests/repository-policy.tests.ps1`。
  - 实机验证（获准后）：在未构建或主工作树直接运行 `antigravity status` 准确报告 `0.4.0` `unchanged`；`wt-ag-040` 成功清理。
  - 合入前门禁：全量 `scripts/run-tests.ps1` 与 exact-head CI `Validate`。

### 轨道 O4：只读可观测性与 `doctor.ps1` 现代化（`#9`）

- **改动范围与写入边界**：仅限仓库脚本、测试与文档（repo-only）。
  - 修改 `scripts/doctor.ps1`：将“Claude live root not found”从 `WARN` 调整为 `INFO`（保留对已存在目录的检测），并将必检核心脚本清单补全为覆盖 `agent-dotfiles.ps1`、`antigravity-plugins.ps1`、`mcp-sync.ps1`、`config-status.ps1`、`config-pull.ps1` 等核心入口；保持零外部 CLI 调用，不依赖 `agy` 或 `codex` 以兼容 CI 隔离门禁。
  - 在 `scripts/agent-dotfiles.ps1` 新增顶层只读 `status` 子命令：调用并聚合 `env list` 记录状态、三端 `config-status`、`antigravity status` 与 `mcp status`，以紧凑摘要展示全机漂移；支持 `-Json` 输出结构化对象。
  - 更新 `README.md` 与 `docs/README.md` §14，引导用户使用 `agent-dotfiles.ps1 status` 作为日常只读总览入口。
- **授权边界**：纯只读能力与文档变更，不写 live home；提交、推送与合入按常规 PR/CI 授权推进。
- **验收门禁**：
  - 语法与扫描：`check-powershell-syntax.ps1`、`scan-secrets.ps1`、`git diff --check`。
  - 受影响测试：`tests/doctor.tests.ps1`、`tests/agent-dotfiles.tests.ps1`、`tests/repository-policy.tests.ps1`。
  - 门禁验证：在独立临时 `-HomeRoot` 验证 `doctor.ps1` 与 `run-repository-validation.ps1` 的 `doctor` 步骤；本机运行 `agent-dotfiles.ps1 status` 与 `-Json` 输出可解析且零写入。
  - 合入前门禁：全量 `scripts/run-tests.ps1` 与 exact-head CI `Validate`。

### 轨道 O5：实机 MCP 对齐、T3 验收、观察项盘点与历史分支收尾（`#10`、`#13`）

- **改动范围与写入边界**：混合实机写入、客户端实测与 Git 仓库治理收尾。
  - 实机运行 `mcp deploy -Platform Antigravity -Server blender -DryRun` 复核后，在明确授权下 `-Apply` 对齐 `[Antigravity] blender` 的 `/args` 漂移，使三端 `mcp status` 收敛为全 `unchanged`。
  - 按 [MULTIMODAL_AND_MCP_EXTENSION_PLAN_2026-11-15.md](MULTIMODAL_AND_MCP_EXTENSION_PLAN_2026-11-15.md) 完成 Antigravity / Codex / ZCode 三端对 `multimodal-generation`、`unity` 插件与 `blender` MCP 的 T3 端到端实测验收；完成后将该计划文档归档至 `docs/HISTORY.md` 并更新 `STATUS.md`。
  - 结合当前下游项目实际使用情况，对 `#10`（`Project Harness Profiles` 冻结观察项）完成盘点结论：若确认无下游依赖则另立小型清理 PR；若仍在消费则明确维护口径并移出待定项。
  - Git 与临时目录收尾：
    - 本地分支 `codex/subagent-dispatch-20261112` 在满足 `AGENTS.md` 已合入祖先证明（`git merge-base --is-ancestor` 退出 0 且无工作树占用）后本地删除；
    - 经核实已 100% 合入 `main` 的 19 条远端历史分支（8 条 `antigravity/*`、11 条 `codex/*`），**在取得单独明确授权后**清理；
    - 评估并安全清理主工作树外侧或内部残留的 ACL 受限目录 `tmp/approval-effectiveness/validation-deps/`（若需修改目录 ACL 须单独确认）。
- **授权边界**：`mcp deploy -Apply` 须单独批准；T3 实测涉及真实客户端/Blender 运行须在所有者确认的动作边界内进行；**远端分支删除必须取得与推送/合入分离的单独明确授权**。
- **验收门禁**：
  - `agent-dotfiles.ps1 status`（含三端 config、Antigravity 与 MCP）全部收敛或无未预期漂移；
  - 归档后的 `STATUS.md` 与 `docs/HISTORY.md` 通过 `git diff --check`、`scan-secrets.ps1` 与 `tests/repository-policy.tests.ps1`。

---

## 4. 跨端接力与归档说明

1. **接手约定**：无论在 Antigravity、Codex 还是 ZCode 中接力，任务开始前必须读取 [AGENTS.md](../AGENTS.md)、[STATUS.md](../STATUS.md) 与 `status/active/`；如主工作树已有其他任务占用或存在未提交改动，须在独立 throwaway worktree 内开发。
2. **单轨道小步交付**：每次聚焦一个轨道（如 `O1` 或 `O4`）开设独立任务分支与 PR，禁止顺手跨轨道修改无关文件。
3. **状态更新与归档**：每个轨道合入 `main` 后，及时更新本文对应轨道的进展标记与 `STATUS.md`；当 `O1`–`O5` 全部收口关闭后，比照历史执行计划归档规范将本文登记至 [HISTORY.md](HISTORY.md) 并移除。
