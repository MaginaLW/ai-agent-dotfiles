# 项目后续任务分阶段完成计划

日期：2026-09-23。状态：**已获执行指令；S0 基线已整合，S1 进行中，S2–S6 尚未执行**。

本计划将 [9 月 23 日审查记录](../../../status/active/live-safety-hardening.md#2026-09-23-multi-agent-audit-and-ordered-backlog)
转成执行顺序、写入归属和验收条件。项目当前状态仍以 [STATUS.md](../../../STATUS.md#current-state)
为准，技术合同沿用 [live-safety 设计](../specs/2026-08-09-live-safety-hardening-design.md) 和
[Phase 4 提案的已采纳部分](../../specs/2026-09-16-phase4-schema-ci-release-proposal.md)。
S0–S6 是本计划的阶段编号，不改变原 Phase 0–4 / Task 8–9 的含义。旧计划中已完成的任务不重开。

## 1. 完成目标、基线与范围

**本轮交付目标：完成发布阻断修复，接受一个有完整证据的候选，完成 Task 9 真机只读与
DryRun 交接。** 真实部署及发布后扩展另列 S6，不能因为发布收口完成便自动执行。

规划基线是 `main@dfa9d20f3eda59a1aa599fac7224faa8d97c07e3`，工作区干净。2026-09-23
22:50 UTC+8 只读刷新：远端 main 为 `627ef3f`，其
[Validate #135](https://github.com/MaginaLW/ai-agent-dotfiles/actions/runs/35852562723) 失败；
`codex/ci-regressions-e4-preflight@3b835f1` 的
[#138](https://github.com/MaginaLW/ai-agent-dotfiles/actions/runs/35873759132) 仍运行中，未发现
open PR。本地比该 main 多 6 个提交，CI 分支则多 3 个提交，两条线尚未整合。执行时重查，
不将此快照当作最终 CI 结果。

- 原候选 `bffa7d7` 已拒绝；policy 目前是 released，不能依赖机械 interlock 防止写入。
- 缓存迁移、recovery cast、公开 Apply 退出码三项修复已提交，不重复实现；补其缺失回归。
- canonical 测试身份隔离、零变更 rollback、当前使用指南和报告卫生属于本轮修复。
- rollback 全局 unfinished gate 是静态疑点，先复现再决定修复；work/full 先按实验参数问题处理。
- 原审查的九项旧断言不是完整缺陷清单。历史测试数、179 文件、42 套件不能硬编码为新验收总数。
- 分片机制及 SID occupancy 已实现。MCP 注册、OpenClaw/OpenCode 退役内容不因旧 roadmap
  的未勾选条目重新引入；全仓 PowerShell 重写不在本计划默认范围。

计划编制后，所有者已指示“开始执行”。执行沿用当前任务授权；push/merge、runner 实际批准、
一次性身份实验及逐机操作按现有边界办理，计划和历史批准均不自行扩大权限。普通授权范围内
的可恢复修复、验证与本地提交连续完成，不为每个子步骤重复确认。

## 2. 阶段与并发总览

sub-agent 数量均不含主 agent；沿用运行时默认与用户设置，不固定模型或推理档位。

| 阶段 | 目标 | 前置 | 计划 sub-agent 数量与职责 | 串行部分 / 出口 |
|---|---|---|---|---|
| S0 | 统一现有工作与执行基线 | 当前状态重查 | 2：CI/分支差异核对；身份入口/测试清单核对 | 主 agent 串行整合分支、处理冲突、确认文件归属，产出明确基线 B |
| S1 | 修复安全缺口及操作资料 | S0；公共隔离接口先明确 | 5：A canonical 隔离；B rollback；C 指南；D 文件卫生；E 只读隔离审查 | 同一公共 helper 仅一个写者；B 动态测试依赖隔离证明；各路定向验收完成 |
| S2 | 组合树复核并固定候选 C | S1 | 2：安全/恢复独立审查；测试矩阵/文档与证据独立审查 | 主 agent 唯一整合者，统一 pins、修复评审问题、提交并冻结完整 SHA |
| S3 | 完整本地门禁 | S2；安全测试前置通过，适用一次性身份验证范围明确 | 0，主 agent 运行完整入口 | 独立 OS 身份内精确检出同一候选，完整 gate / artifact 链通过 |
| S4 | 一次性 OS 身份 lab、CI 与接受候选 | S3 与适用实验/发布授权 | 1：只读核对已完成路线证据 | 主 agent 串行控制实验身份；CI 自身四个 job 并行；全证据通过才接受 C |
| S5 | Task 9 与发布阶段归档 | S4；逐机适用范围明确 | 0，主 agent 逐机串行 | 正确路线的只读/DryRun，停在真实 Apply 前；无开放发布阻断才归档 |
| S6 | 发布后独立工作包 | 按各包依赖，不阻塞已完成的发布 | 见第 9 节，各包另定写入归属 | 每包独立设计、验证和收口；真实部署单独绑定具体机器与计划 |

主依赖：`S0 → S1 → S2 → S3 → S4 → S5`。失败返回所属修复阶段；新代码导致候选变化时重建
该候选证据。S6 的 CI 摘要与 config-sync 可并行，平台 registry 先定契约，依赖它的去重随后串行。
不得在同一用户 authority 下并行跑未证明隔离的测试，也不让多个 worker 争用同一个实验身份。

## 3. S0：基线协调与工作拆分

- [ ] 刷新 Git 根、当前改动、远端 main/修复分支、相关 PR 与 #138 最终结论。红灯只依据该 run
  原始日志归因，区分夹具 15 秒期限与 suite 900 秒 timeout；遵循 [CI 失败规则](../../CI_FAILURE_RULES.md)。
- [ ] 对比本地 6 个提交与 CI 分支 3 个提交的实际内容。主 agent 在干净 `codex/` 工作分支或
  隔离 worktree 整合；保留已在验证的改动和提交来源，不重做、不改写另一会话分支。
- [ ] 将已完成修复、仍需复现项、文档问题映射到文件和测试。特别核对远端修改过的
  `sync`、`root-claims-registry`、`repository-policy` 套件，不能直接覆盖为旧版本。
- [ ] 由 A/E 与主 agent 明确 canonical 隔离方案及公共 helper 接口。选择受控 fixture resolver
  或一次性 Windows identity 执行器；验证计划、Apply、锁、recovery、清理共用同一边界。
  不以改 HOME/LOCALAPPDATA、仅换 helper 或 mock 单个调用点作为隔离证明。

**出口：** 基线 B、差异处置、公共接口和所有权已写入活动记录；没有未经处理的同文件冲突。
不等远端长任务时可继续静态清单和方案工作；不能将运行中结果记为通过。

## 4. S1：并行修复与定向验证

### A：canonical 测试身份隔离

**写入范围：** `scripts/canonical-transaction*.ps1`、必要的 identity resolver seam、
`scripts/internal/live-transaction-host.ps1`、`tests/helpers/safety-sandbox.ps1`，以及
`canonical-command-result`、`canonical-recovery`、`canonical-transaction-apply` 相关测试。
其他工作流对这些文件只提交建议，由 A/主 agent 落地；不得扩大公开 CLI 的权限入口。

- [ ] 列全解析链：Get-CanonicalPrivateRootSelection、Get-WindowsHomeAuthorityIdentity、
  Resolve-HomeAuthorityContextFromIdentity、子进程继承与异常 cleanup。按调用链找同类裸调用。
- [ ] 确保无有效隔离能力时生产 identity 行为不变；隔离初始化失败立即拒绝。若选择内部 seam，
  不增加可伪造的公开测试覆盖参数，不把真实 private roots 排除在测试写入边界之外。
- [ ] 去除测试对真实 private base/claim 的 cleanup；只清理本次拥有、已解析并验证 containment
  且无 reparse 逃逸的精确 fixture 目标。已有真实残留另列事实，不顺手清理。
- [ ] 更新基于机器偶然状态的失败预期，覆盖下表。E 先复核写入/清理边界，再恢复相关动态套件。

| 必需场景 | 验收 |
|---|---|
| pristine identity、recovery root 原本不存在 | 公共 setup Apply 退出 0、单个 typed PASS、terminal committed；覆盖此前 cast 与 exit 修复 |
| 已完整 authority / 部分 prefix / ACL 或内容漂移 | 确定性结果，拒绝时保留原有字节，不依赖当前真实用户状态 |
| canonical/global 争锁及释放 | contender 按合同失败；释放后合法调用可执行 |
| canonical recover 与计划重放 | 同一隔离根、正确终态；已消费/不匹配计划拒绝 |
| 无效 capability，repo/plan/private/cleanup 越界或 reparse | 首次写入前拒绝，异常退出也不清理真实目录 |
| 父进程、所有子进程和清理路径 | 宿主 authority/live 根无本次写入证据；unknown 不算通过，`.system` 只做允许的 marker 检查 |

### B：rollback 零目标闭合与 unfinished 疑点

**写入范围：** `scripts/live-transaction-common.ps1`、`scripts/rollback-harness-env.ps1`、
`tests/backup-recovery.tests.ps1`。两项修复共用文件，由同一 agent 串行处理。

- [ ] 在已证明隔离的 fixture 内复现同 hash 的零变更回滚；若依赖 A 尚未完成的 canonical
  setup，先只做静态实现/fixture 设计，待接口和边界通过后再运行。
- [ ] 保留空数组或复用既有列表标准化函数。不能直接 early-return：零 live diff 仍必须完成
  authority state/generation、receipt、journal 的协议闭合。
- [ ] 验证零/单/多目标，至少一次公开 rollback DryRun→Apply；零目标 live 字节不变、state
  正确、receipt COMPLETE、唯一 terminal COMPLETE、unfinished 为空，后续正常操作可继续。
- [ ] 构造 source receipt 仍有效、兄弟事务未完成的场景，动态确认静态疑点。若成立，在持有
  canonical→overlay→global 所需锁之后、首次 staging/header/receipt 写入之前，复用完整
  unfinished scan，保留 unreadable=unfinished 的保守语义。
- [ ] 覆盖 header-only、receipt 完成但无 terminal、result 已写但无 COMPLETE、损坏或不可读
  journal：拒绝且不增加/改变 journal、receipt 或既有字节；已闭合兄弟事务不阻断，reviewed
  recovery 后可继续。如疑点不成立，以具体入口、锁和动态证据关闭，不为假定缺陷增加行为。

### C：当前操作指南

**写入范围：** `CLAUDE.md`、`README.md`、`docs/README.md`、`docs/ONBOARD_NEW_MACHINE.md`、
`docs/RESTORE.md`，必要的旧计划 current/superseded 指针。AGENTS、STATUS、活动记录由主 agent维护。

- [ ] 当前安全状态统一引用 STATUS；纠正“仍机械 interlocked”及裸 DryRun 必然 fail-closed
  的承诺。同步主 agent 持有的 AGENTS 命令说明，不改变授权与扫描规则。
- [ ] 删除退役 standalone backup 步骤及已失效参数；按实际 dispatcher/param 合同补齐
  PlanPath、receipt、route 和材料生成顺序。真实操作示例不拿来直接测试主机。
- [ ] 旧历史正文保留原意，只加准确指针；隔离完成后用受控 fixture 验证当前指南中的适用示例。

### D：历史报告与文件卫生

**写入范围：** `.gitignore`、`reports/README.md` 和当前报告生成/落盘规范；主 agent 独占索引
操作及活动记录中的脱敏事实摘要，不并发操作共享暂存区。

- [ ] 检查该目录全部已跟踪 JSON/Markdown 运行报告及文件名中的私有字段，固定精确清单，
  至少处理审查定位的两个已跟踪运行报告：
  `imports/skills-reports/skills-analysis.json`、`imports/skills-reports/auto-merge-report.json`。
  先查 tracked 清单和依赖，不泛化为删除 imports 目录。
- [ ] 按 AGENTS 的运行材料不入库规则处理：保留必要的脱敏事实摘要，再仅解除已核实报告的
  Git 跟踪、保留原本地文件并补忽略规则；不把清洗后的原始 imports 报告重新提交。
  旧 imports 占位说明与高优先级规则不一致时，在当前 docs/report 规范中明确其失效范围。
- [ ] 验证本地原件仍存在、索引不再包含选定运行材料、新摘要无机器名/用户名/绝对路径或账户值。
  不移动或删除原件，不重写 Git 历史；解除跟踪不等于消除历史公开数据。

**E：只读审查。** 独立复核 A 的完整根解析/清理边界、B fixture 的安全性及 C 示例的路由。
E 不参与这些实现文件写入。各实现 agent 只提交自己复核过的文件；共享仓库下提交/暂存统一
由主 agent 串行负责，采用隔离 worktree 时也由主 agent 负责最终整合。

**主 agent：实验 kit 准备。** 在 S1/S2 完成第 7 节的路线矩阵、schema-valid seed、预期终态
和运行脚本。当前 kit 不完整，不能把补脚本留到 C 冻结后。拟入库的可复用脚本先核对既有
scripts/tests 目录约定、清除机内路径并明确与 A/B helper 的写入归属；原始实验数据不入库。
外部 kit 同样复核并记录版本/hash，与 C 一起冻结。冻结的是脚本和 seed 生成逻辑；依赖候选
SHA/身份的实例在本次隔离身份内生成。S4 只部署冻结材料、生成新运行证据。

## 5. S2：整合、独立复核与候选固定

- [ ] 合并 A–D 的自洽改动，主 agent 在组合树统一复算必须变化的 schema/seam/toolchain pins；
  未变化的 pin 保持不动，不以重钉掩盖行为失败，不降低扫描、hard-kill 或 schema 门禁。
- [ ] 两个独立 reviewer 分别审查安全/恢复合同和测试/文档/证据覆盖。取消、工具失败或不完整
  评审记为未完成；反馈逐项核验，修复后做受影响回归，不无条件采纳模型断言。
- [ ] 定向回归、实验 kit 和评审问题收口后提交最后一组修复，固定 clean commit **C**；记录完整 SHA、
  ToolchainPolicyHash、protocol/schema/runner 版本和相关提交范围。

**候选规则：** policy 已 released，无需再 flip；不临时改 policy、不 amend 已拒绝候选，
不制造只为“候选标签”的空提交。新修复提交即可成为 C。接受记录另作后继 **D**，不能用 D
替换 lab 的 C。后续代码、policy、toolchain 或 workflow 变化产生 C2，旧证据保留但不冒充 C2。

## 6. S3：完整本地门禁

在真正独立的 Windows Sandbox / 一次性用户 / VM 身份内，精确检出 C，并使用已验证的测试
身份边界，由主 agent 唯一执行。宿主 worktree 不能替代这项一次性 OS 身份验证。证据目录必须在
worktree/Git 私有目录之外，采用 create-new 路径，保留原始日志、退出码、摘要和 hash。
先在该身份内通过仓库的 `install-schema-validator.ps1`、`install-gitleaks.ps1` 安装并
以 `-VerifyOnly` 验证 pinned 工具；不依赖宿主已有 cache。任何所需 runner 批准只适用于
该一次性身份，并满足相应授权；不能为跑门禁修改宿主批准记录。
按当前 runner 的预算合同设置外层上限；中断无 exit code 或缺摘要不算通过。

```powershell
# 仅在 S1/S2 前置通过后执行；路径使用本次新建、与仓库隔离的外部目录。
pwsh -NoProfile -File scripts/run-repository-validation.ps1 `
  -OutputRoot '<external-empty-output-dir>' `
  -ChildArtifactManifestPath '<external-new-children.json>' `
  -FinalArtifactManifestPath '<external-new-final.json>' `
  -JsonSummaryPath '<external-new-summary.json>'
```

- [ ] 本地不传 SkipGates 或 GateCatalogPath。沿用现有完整入口；其内部统一 `run-tests -All`
  只运行一次，不再手工复制一遍全量，也不以定向 suite 代替全量。
- [ ] 全部现有 gate 通过：parse、pinned tools、build、scan、doctor、manifest parity、
  env build/list/status、artifact validation、全部测试、危险 tracked 文件、clean state。
- [ ] 退出码 0，passed=discovered、failed=0、timed-out=0；child→summary→final artifact
  关系和 hash 可验证；checkout 仍干净。数量按实际发现记录。

本阶段同一 C 的合格全量结果同时作为整合门禁和 Task 8 Step 3 证据；没有新改动、失败或新疑点
不重复跑全量。发现问题返回 S1/S2，重新固定候选并验证。

## 7. S4：一次性身份实验、远端 CI 与候选接受

### S4.1 实验准备与路线矩阵

原机内 lab kit 只有部分 initial/env/chain/smoke/诊断路线；S1/S2 必须已补齐并冻结可复现脚本、
schema-valid seed、before/after 断言和证据清单，才可进入本阶段。此处仅运行 C 对应的 kit，
记录其 hash；若需改逻辑，返回 S2 复核，涉及 tracked bytes 时产生 C2。原始 OS identity、
计划、receipt、journal 和运行日志留在机内忽略目录或外部目录。
互斥路线从各自 fresh snapshot 开始，不能擦 immutable claim 或复用失败残留来切换路线。

共同前置：在真正独立的 Windows Sandbox / 一次性用户 / VM 身份中精确检出 C，安装验证 pinned
工具，审查并批准该身份自己的 runner。宿主 roots 不作为测试数据；仅重设环境变量不等于 OS
身份隔离。主 agent 串行控制身份和每条 mutation 路线，证据 reviewer 只读已完成产物。

| 路线组 | 必需覆盖及通过标准 |
|---|---|
| pristine initial + canonical setup | **先 initial DryRun → canonical setup DryRun/审查/Apply → 新 invocation → initial Apply 消费原 pristine plan**；fresh recovery root；公开退出码正确 |
| authority 建立/接管 | migrate、adopt、repair-adopt、takeover 各自 fresh seed；status 唯一路由、正确 state/claims；不拿旧 fixture 冒充实际迁移证据 |
| environment / task | activation；work 基线下 task ensure/sync/close；明确 overlay/environment 一致性，不能把 BaseEnv full 的旧报错视为已修产品缺陷 |
| rollback | 有变化及零变化都走公共 DryRun→Apply；receipt/state/journal 闭合、可继续操作；兄弟 unfinished 拒绝不写入 |
| retirement | 显式清单、canonical absence 与 selection 约束；仅精确 reviewed 目标改变，旧计划不可重放 |
| canonical / live recovery | 按原设计合法 abandon/rollback/finalize 路由构造证据；hard-kill 矩阵与 schema/no-read 门禁完整保留，不以单一 smoke 代替 |

initial 的特殊顺序来自 `scripts/sync.ps1` 的现有合同：计划时 ControlBase 必须 MISSING，
Apply 时 bootstrap 必须 COMPLETE，允许两者间产生经审查的 prefix。执行前按符号重新核对，
不能机械照搬旧提案“所有路线都先 setup 再生成 initial plan”的顺序。

- [ ] 每条正向路线同时满足子进程退出码、结构化 PASS、预期 receipt、state 与 terminal journal；
  不用 AllowFailure 后匹配 stdout 当成功。负向路线按预期非零与零副作用断言判定。
- [ ] 记录宿主 authority/live roots 前后未被实验修改的证据；保护未知 skills，`.system` 仅做
  允许的 marker 检查，不读取内容或统计内容 hash/count。任一路失败拒绝 C，保留证据并返回修复。

### S4.2 CI 与发布收口

- [ ] 在适用远端授权下发布精确候选以触发 CI。保持既有 1 个 gates + 3 个测试 shard：CI
  orchestrator 的已批准例外只跳过统一测试入口，测试由三 shard 完整且恰好一次执行。
  本地 S3 不沿用这个 SkipGates 例外。
- [ ] 取得 C 的 Validate 四 job 全绿与原始运行 URL。PR 合成 merge ref/merge commit 不冒充 C；
  如发布生成不同 SHA，记录其父链、CI 验证范围及与 C 的差异，不能用旧 head CI 宣称新 SHA 已验。
- [ ] C 的本地 gates、lab、CI 全部齐全后，才在后继 D 写接受状态、版本、实测数量与限制。
  推送、合并仅按实际授权执行并核验远端状态；计划不默认承诺某种发布方式。

## 8. S5：Task 9 真机只读/DryRun 与归档

- [ ] 逐机核对适用范围、候选/发布版本、pinned tools 和 runner 状态；读取 doctor、hooks、
  config/env/task、canonical status 及 canonical/live recovery status；setup 已完成时，在新
  invocation 中运行 env authority status，重新确定唯一合法路线，不沿用历史 parity。
- [ ] canonical setup 缺失时仅准备 setup DryRun 并停；unfinished 进入 recovery 证据路线；
  manual/owner-action 路线只报告；adopt/repair-adopt 需要明确环境选择，不能默认 work。
- [ ] 仅为所选路线创建外部新计划，记录脱敏 hashes 和三平台 add/update/no-op/prune 数量。
  真机计划必须使用当前规则明确允许的入口；普通 internal sandbox 计划不能冒充真机证据。
  如当前规则与真机 DryRun 入口冲突，先解决该具体入口边界，不以裸调用试探联锁。
- [ ] 对未解释的 prune、未知目录或漂移保留原因，停在真实 Apply 前。后续 Apply 不复用过期计划。
- [ ] 更新 STATUS 与活动记录，区分“候选接受 / 实际发布 SHA / Task 9 完成 / 真机部署未执行”。
  发布阻断或 Task 9 未完成时保持 active；完成后将本轮局部任务归档并修正链接，S6 单独跟踪。

## 9. S6：发布后独立工作包

这些工作不作为本轮候选新增前置条件。接手时逐包明确采纳、延期或不实施及理由；采纳项形成
小范围设计和验收，不以“完成项目”为由扩成无边界重写。可并行组是 F1/F2/F3；F4 依赖 F3
及安全合同稳定；F5 每台机器串行，并与其他会改变同一机器状态的工作互斥。

| 工作包 | 最小范围与验收 | 计划 sub-agent / 依赖 |
|---|---|---|
| F1 CI 证据持久化 | 新建白名单字段的可公开摘要，只含 SHA/run/job/shard、相对 suite 名称、结果、数量、退出码、安全原因码与必要 hash。不得上传整个临时目录、raw logs、原始 summary 或含 Path 的 manifest/plan/receipt/journal，不改写 hash 绑定原件。成功/失败路径都有安全摘要，导出错误不掩盖原始失败；注入私有路径、未知字段、异常文本均不能泄漏，人工核对一次下载产物 | 1 个 CI 实现 agent，主 agent 独立复核；先协调既有 CI 分支，独占 workflow/helper/相关测试 |
| F2 config pull/push 边界 | 白名单路径规范化、absolute/.. /reparse 拒绝、backup-root 碰撞及相交检查、production scan gate；覆盖正常/越界/备份失败恢复。保留个人模型设置；Codex config.toml 仍排除，不接入 environment activation | 2 个：实现；独立 fixture/审查。公共 helper 接口先由主 agent 串行定稿；通过隔离验证后才考虑真实使用 |
| F3 平台能力注册 | 先固化 Claude/Codex/Reasonix 当前能力表，只集中已存在的能力数据，保持 project-local allowlist、schema、DryRun/rollback 行为。新增 Reasonix 项目输出须有明确需求另作决定，不默认为已授权功能 | 2 个：契约/清单；实现/测试。公共 registry 单一写者，接口定稿后实现 |
| F4 局部模块去重 | 以调用者、职责和边界证明重复，逐模块小改；行为等价，受影响测试通过，无权限或路径范围扩大，不默认全仓模块重写 | 起始 1 个实施 agent，主 agent 独立复核；F3 后执行，有不相交模块再扩大并发 |
| F5 真实环境选择与部署 | 明确 work/full、具体主机、status 路线和 reviewed plan；逐机重新生成/审查计划，在适用明确授权下 Apply，验证 receipt、state、parity、恢复路径和未知目录保护 | 0 个 mutation sub-agent，主 agent 唯一执行者；依赖 S5，必要时 1 个只读计划 reviewer |

若决定把 F1 等工作提前纳入本轮发布，必须在 S2 固定 C 前完成并纳入全部验收；不能在已验收
候选之后追加 workflow/代码改动而沿用原证据。取消跟踪的历史私有字段是否需要历史处理属于
单独决定，不自行 rewrite/force-push，也不声称前向清理已擦除历史。

## 10. 每阶段收尾与接续

主 agent 每完成一个自洽阶段，复核 diff/暂存区，仅提交本阶段文件；记录基线、提交范围、
实际检查及退出码、证据位置/hash、未解决项和下一阶段入口。运行材料、凭据、个人路径、
generated output 和备份不入库；源材料与证据不覆盖旧批次。长验证没有最终退出码或摘要时
保留 partial，不写 PASS。实现、实验、CI、接受和真机部署分别记录，不互相替代。

执行入口：先完成 S0；完成清单的依据填入既有活动记录，本计划只更新任务状态和必要依赖。
本轮计划编制的文档检查不算 S0–S6 的实施验收，也不新增自动化、后台监控或跨项目写入。
