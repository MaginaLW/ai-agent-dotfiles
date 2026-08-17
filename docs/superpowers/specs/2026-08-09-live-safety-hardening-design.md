# Live Skills Safety Hardening 设计

日期：2026-08-09

状态：设计已获用户书面确认，实施尚未开始；执行以 2026-08-09 当前 HEAD `7d9dd08` 及其上未跟踪的同日设计/计划为基线，实施计划见同日 roadmap。设计批准不等于 Git 暂存/提交/发布授权，也不等于真实 live Apply/rollback 授权

范围：先阻断未经审阅的 live 写入，再分阶段重构 canonical source、sync、backup、rollback、environment 与 CI 的安全闭环

## 1. 背景与问题

本设计最初审计基线是 2026-08-09 的 HEAD `89019f4`；审计开始时 working tree 只有 3 个既有 `.reasonix/desktop-topic-*` 修改。在该历史基线上，`skills-source/`、三平台 generated output 与 per-platform manifests 一致，规模为 Claude 15、Codex 23、Reasonix 12；PowerShell 解析、secret scan 和当时的核心回归测试能通过。

设计终审期间，同一 shared workspace 的 cleanup/retirement 变更被外部流程提交为当前 HEAD `7d9dd087d3861f7c9ddde9eaf2a26f72552a9cb0`；该提交不是本规划流创建的。当前非私有工作树除这 7 份未跟踪设计/计划外干净，3 个既有 `.reasonix/desktop-topic-*` 修改仍由用户拥有且未读取。当前 canonical/generated/manifests 为 7/15/7，live 是 stock `work` 2/4/2 且 live parity pass；cleanup commit 改变 RepositoryCommit 后，schema 3 staging locks 与 repo-local schema 2 activation attestation 已按设计变 stale，需要未来 route-correct dry-run，而不是在本轮偷偷 Apply。

用户明确选择当前工作区作为执行基线。当前 HEAD 已完成 skill/MCP 精简，并新增一次性、计划绑定的 retirement 路径；也已局部修复 Reasonix override 备份、saved Plans 自校验和 env-lock 三平台 baseline。执行映射以 [2026-08-09 live-safety roadmap](../plans/2026-08-09-live-safety-hardening-roadmap.md) 为准：这些窄修复必须保留，但不能被当作 shared authority、content-bound receipt、durable journal 或 crash recovery 已完成。当前 `-RetireManifestPath` 正式映射为 `OperationKind=retirement`，必须与其它 live mutation 一起先 interlock，再迁入统一协议；Git hooks 永不创建或消费 retirement authority。当前提交的 `STATUS.md` 还包含完整 machine-local backup paths、设备 label 与 Codex `.system` 内容指纹/数量；四个被本设计定义为 machine-private 的 `.reasonix/desktop-topic-*` blobs 也仍在该提交的 Git index/history 中，后者只确认路径/跟踪状态，内容从未读取。2026-08-09 的只读 `git ls-remote origin refs/heads/main` 已确认远端 main 指向同一 `7d9dd08`，`gh repo view` 又确认仓库为 PUBLIC。当前树应优先追加 STATUS 脱敏并在另获授权后 index-only untrack 四路径；既有公开历史中的 STATUS 值与四个 opaque blobs 是否接受或经授权重写，需要同一个独立用户决策。

当前风险集中在 Reasonix 迁移后的写入边界和状态机，而不是 skill 内容本身：

- 普通 Git auto-sync 直接部署 full generated output，却不更新 active environment state；2026-08-09 的中间审计快照曾观察到名义 active `work` 与实际 full managed 集合之间的 live parity drift。随后经单独审阅的 `env activate work` 已把当前机器恢复为 2/4/2 parity，但 auto-sync 的机制缺口仍可让 drift 复发。
- `Normalize-SkillDirectory` 的迁移回归会错误处理 Reasonix 不兼容输入，并在已有 canonical target 上留下旧文件或嵌套目录。
- 新 env-lock writer 已记录 Reasonix task overlay baseline，但 legacy schema 2 state 缺 Reasonix 时仍被按空集合容忍，仍可能把 removal 误判为 addition-only。
- custom Reasonix root forwarding 与窄版 plan binding 已修，但 backup 仍是秒级命名的 full-tree copy并读取/复制 Codex `.system`；它没有 managed-only content receipt、authority preimage 或 crash-safe finalize，rollback/recovery 也未绑定同一 immutable snapshot/state identity。
- Git hook、bootstrap、schema validation、CI suite discovery 和操作文档没有执行同一套安全契约。

因此本轮优先目标是：**杜绝未经审阅的 live 写入、误删、错误恢复和状态漂移**。平台抽象重构、普通文档整理和体验优化延后。

## 2. 已确认的方向决策

| 决策点 | 结论 |
|---|---|
| 首要成功标准 | live skill 写入安全与状态一致性 |
| 实施策略 | 先入口止血，再分阶段重构写入安全基础契约；控制在 managed skills 范围内，不与平台注册表、config-sync 或体验重构混做 |
| Git 自动化 | Git pull、checkout、rewrite 和默认 bootstrap 只生成不可消费的 preview/event 并打印显式 external DryRun 命令，不执行 live Apply |
| active environment | HomeAuthority 级 machine-private state 是 live managed skill 集合的唯一权威；存在 active selection 时直接 full sync Apply 必须拒绝 |
| canonical source | 所有写入使用显式模式、CandidateWorkspace preflight、同卷 CanonicalRecoveryRoot、per-rename 原子 primitive、durable journal 和可调和的批量失败恢复 |
| plan / backup | 计划绑定目标上下文和内容；backup 产生精确 receipt；activation 不再扫描“最新备份”猜测引用 |
| 平台语义 | Claude、Codex、Reasonix 使用同一 fail-closed 契约，缺字段或旧 schema 不按空集合容忍 |
| live rollout | 实现和测试不执行真实 Apply；最终真实 dry-run 与真实 Apply 分开授权 |

## 3. 安全不变量

以下不变量同时约束直接脚本、统一 CLI、Git hooks 和 bootstrap：

1. Git 操作不会修改 live home；hook 最多生成并保留不可消费的待审 preview/event、打印显式 external DryRun 命令，或返回 fail-closed diagnostic。
2. 默认 bootstrap 不执行 initial live sync；首次 Apply 必须使用已审阅且位于 tracked working tree 外的计划。
3. 同一 canonical HomeRoot/current-user identity 的 active selection 存放在跨 clone/worktree 共享的 machine-private HomeAuthority state；stable location claims 首次建立后不可变，resolved identities 是可变 precondition，二者都不参与 authority namespace。存在 active selection 时，普通 live Apply 必须来自匹配该 environment lock 的 env/task 编排路径；显式 retirement 只能删除不属于该 lock/task postset 的 stale managed target，并必须绑定及原子更新同一 authority state，否则返回 `retirement-selection-conflict`。
4. Apply 必须绑定同一个 repository state、selection、HomeRoot、实际 live roots、source、manifest、live tree 和 plan document。
5. backup receipt 必须绑定本次 plan、实际 target roots 和 pre-change 内容；rollback 必须绑定 receipt 与 backup tree 内容。
6. 任一平台 baseline、schema 字段、内容哈希、共享 authority 或 target identity 缺失/无效时停止，不把“当前 clone 没有 state”解释为“机器没有 active environment”。
7. recovery 失败时保留 rollback/quarantine tree 与 journal；只有完整成功后才能清理。
8. canonical source 写入在隔离环境通过兼容性、build 和 secret scan 后才进入 journaled commit 阶段。
9. `.system`、unknown live directories、credentials、sessions、cache 和机器私有配置继续保持既有保护边界。
10. 设计批准、代码批准和真实 live Apply 是三个独立授权点，不能相互替代。
11. `.reasonix/desktop-topic-*` 是机器私有运行态；在解除跟踪前后，repository scan、diff、status 与测试都不得读取其内容，只能对四个显式路径做 Git index/path-existence 元数据检查。

## 4. 组件设计

### 4.1 入口与自动化隔离

`bootstrap.ps1` 和 `scripts/bootstrap-clone.ps1` 的默认行为调整为一个显式分阶段流程；任何一步返回 diagnostic/setup/recovery route 都必须停止，不能在同一 invocation 继续：

1. 首次 bare bootstrap 只安装/检查 inert hook wrapper，并按固定顺序检查 pinned schema validator、pinned gitleaks scanner与 approved runner。validator缺失时 stderr恰好输出一行 `validator-install-required`，scanner缺失时输出 `scanner-install-required`，各自 stdout恰好输出一行带绝对脚本路径的显式 installer命令并以固定非零 code退出；不创建声称已验证的 JSON artifact。两者都已验证但 runner未批准时才可创建 schema-valid `runner-review-required` event并在 stdout打印 approve命令。所有分支都不下载依赖、不批准 checkout code、也不生成可 Apply plan。
2. 用户分别运行 pinned validator/scanner installers（校验版本/asset SHA-256）和 runner approve 命令后，再次运行 bare bootstrap；它先用 approved pinned runner执行 doctor/recovery status与零写入`canonical status`。
3. 若有 unfinished transaction，只输出 recovery route；若 canonical setup缺失，只输出`canonical-setup-required`与外部`canonical setup -DryRun`命令。两者都不build/scan、不生成initial/live plan。用户必须另行DryRun、审查并授权canonical setup Apply；成功后再启动一个新的bare bootstrap invocation。
4. 仅当canonical status为ready且无recovery时，该新 invocation才从 policy allowlisted、Git tree mode/OID与 no-follow identity均已验证为 regular-file tree的 create-new snapshot，在隔离输出目录完成route-correct build/scan preflight和不可消费的planning preview；symlink/gitlink/reparse/hardlink/ADS/escape在任何 build content open前拒绝。这些步骤不得改动 canonical source、tracked working tree、live home、shared authority 或 legacy state。
5. 自动化只把不可由 public Apply 直接消费的 pending preview/event 保存在 `git rev-parse --git-path ai-agent-dotfiles/pending` 返回的 Git-private 目录，并打印显式 public DryRun 命令。用户运行该命令时必须把 actionable plan 写入 `ExternalUserArtifact` 路径；人工审查后，Apply只消费同一 external PlanPath。bootstrap/hook不得把Git-private preview路径打印成Apply参数。

新增语义清晰的 `-SkipInitialPlan`；旧 `-SkipInitialSync` 仅作为 deprecated alias 保留并打印迁移警告。不新增“一步生成并立即 Apply”的 bootstrap 开关。

fresh clone 的首次信任边界拆成 checkout bootstrap、validator install、scanner install 与 runner code approval 四个可审计动作；bare bootstrap 本身不隐式批准 toolchain。approve 命令记录 create-new approval event（commit、ToolchainPolicyHash、repo fingerprint、approval kind）并安装该 hash 的 pinned runner，但仍不构成 live Apply 授权。hook 不能自行调用 bootstrap/install/approve；approved runner、validator 或 scanner 缺失/漂移时 inert wrapper/second bootstrap 只输出对应 diagnostic。因此 fresh clone 不承诺一次调用产出 plan，而承诺依赖/代码未批准时 deterministic fail-closed。

已安装 hook 不能继续直接执行刚 checkout 的 `scripts/auto-sync-after-git.ps1`。`setup.ps1` 必须把经人工批准的最小 runner 及其 toolchain hash 固定到 Git-private 目录，hook wrapper 只调用这份固定 runner：

- 当前 checkout 修改 runner、setup、sync 或其它执行链脚本时，固定 runner 只写入 `runner-review-required` 事件，不执行新 checkout 中的 PowerShell。
- runner 更新只能由显式 setup/approve 操作完成，post-checkout/post-merge 不能自行更新。
- runner 缺失、hash 不匹配或无法读取 approved metadata 时 fail-closed，只保留诊断事件。
- 对纯 source/manifest 变更，固定 runner 使用隔离输出生成不可直接Apply的 pending preview/event，绑定当前 checkout 的数据 hash 和固定 toolchain hash，并给出另行写 external actionable plan 的精确DryRun命令。`.gitleaks.toml`、scan-input policy、validator/gitleaks locks/installers/approved binary hashes、runner/setup/sync及其依赖全部属于 `ToolchainPolicyHash`，绝不能按 data-only自动消费或从 PATH替换。

pending previews/events 使用 worktree namespace 和 create-new `<utc-ms>-<guid>` 文件名，目录 ACL 只允许当前用户，且不会被自动清除。显式 `plans prune -DryRun -PlanPath <new-external>` 先把 schema-valid prune plan写到ExternalUserArtifact，绑定 exact internal artifact/sidecar paths、content hashes、stale refs、registry snapshot与 selection timestamp；`-Apply -PlanPath <same-external>` 逐项重验后只把该 exact set原子移动到 Git-private retired namespace并保留 redacted audit event，绝不按当前 age/hash重枚举或扩展选择。

`scripts/auto-sync-after-git.ps1` 是显式安装 approved runner 的源码，不再由已安装 hook 从当前 checkout 直接执行。固定 runner 先执行zero-write canonical recovery/status gate：unfinished canonical transaction只产生recovery diagnostic；canonical setup缺失只产生`canonical-setup-required`与external setup DryRun命令，零build/materialization/initial preview。只有`canonical-ready`后才按 shared authority 做 selection-aware 路由：

- 无 shared authority 且三平台 live roots 均为空/不存在（Codex `.system` 除外）时，物化内置 named `full` environment 并生成 `OperationKind=initial` 的不可消费 preview/event及精确 external DryRun 命令；用户显式运行该命令得到 external plan、另行审阅并授权 Apply 后，成功 state 仍是普通 named environment selection。
- 存在有效 active environment 时，重建该 environment 加当前 task overlay 的 EnvironmentMaterializationRoot，并生成 environment 的不可消费 preview/event及精确 external DryRun 命令；只有用户显式 DryRun 才能产生 actionable plan，绝不退回 repository-wide direct sync。
- 无 shared authority 但 live root 非空时，只生成 `authority-adoption-required` 诊断；不能把 existing/unknown 内容视为可安全 initial sync。
- authority/lock/state 为旧版、缺字段、不可解析或与本 checkout 不匹配时，只生成 migration/controller-review diagnostic，不生成可 Apply plan。
- runner/toolchain/policy 脚本变化只生成 `runner-review-required`，不执行新脚本；source、manifest、environment definition 和 task overlay 等数据变化才进入上述 planner。

所有 Git-triggered planner 都是 preview-only；它们不得创建 public Apply 可消费的计划：

- 生成绑定 context/fingerprint 的不可消费 preview/event并写日志，同时打印把 actionable plan 写入 `ExternalUserArtifact` 的精确 public DryRun 命令。
- 不调用 `sync.ps1 -Apply` 或 `env task sync -Apply -Automatic`。
- 如果 preview 包含 prune/removal 或 controller transition，明确标记为 `manual-review-required`；旧 state、invalid lock 或 schema migration 只产生不可 Apply 的诊断事件。
- 多次 hook 触发以 context/preview hash 去重；旧 pending preview 在 source/live/context drift 后通过 immutable sidecar event 标记 stale，不修改原 artifact，也不删除 redacted audit 记录。

`sync.ps1` 自身必须从 machine-private shared authority root 读取 active selection 并实施 guard，不能只依赖统一 CLI 或当前 clone 的 `state/current-env.json`：

- shared authority 不存在且 live roots 确认为 pristine 时，允许显式 reviewed initial-plan Apply。
- authority 一旦存在，public direct sync Apply 永久拒绝；刷新或切换到 full 必须走 `env activate full`。
- env/task 编排传入可验证的 environment selection context，`sync.ps1` 验证 name、lock hash、task overlay hash 与 materialized source 后才接受。
- shared authority 缺失但 live 非空、legacy state 存在、authority 无效或 controller repo 变化时，只允许显式 adoption/migration/controller-transition 计划，普通 Apply 拒绝。

### 4.2 Canonical source 写入事务

`setup`、`normalize`、`promote` 与 `auto-merge` 统一使用 canonical transaction plan/hash/journal contract，入口必须显式选择 `-DryRun -PlanPath <new-file>` 或 `-Apply -PlanPath <reviewed-file>`；Apply 不得在进程内临时生成计划。canonical vocabulary固定为 `CanonicalOperationKind=setup|normalize|promote|merge`：setup只建立ControlBase/canonical root claim/setup-state且不含skill targets，其余分别映射 `normalize-skill.ps1`、`promote-skill.ps1`、`auto-merge-skills.ps1`/`agent-dotfiles.ps1 skills merge`，CLI/script别名不得产生额外kind。reviewed recovery vocabulary固定为 `CanonicalRecoveryPlanKind=canonical-recover-abandon|canonical-recover-rollback|canonical-recover-finalize`，也是 `ClosingKind=recovery` 时唯一合法的 ClosingPlanKind；正常 closure禁止它。

事务输入是一个或多个 proposed replacement：skill name、target type、input path/hash、derived canonical target，以及 normalization rewrites。canonical target 只能由 `<TargetType>/<SkillName>` 推导，拒绝任意 `OutputSkillPath`。transaction plan 同时绑定将受影响的 canonical、managed generated 与 manifest target list、每项 pre/post hash/MISSING 状态，以及必须原样保留的 generated unknown inventory。tracked manifest target 在 DryRun/Apply 时若相对 Git index 已有用户 dirty change，事务 fail-closed 且无 force bypass；先由用户单独解决该变更，不能把事务 recovery 当成覆盖许可。

执行流程：

1. 读取输入并完成 secret、binary、local-path 和 platform compatibility 分类。
2. 不兼容输入返回 `quarantine`，不创建、删除或覆盖 canonical target。
3. 在 repo-local ignored、可丢弃的 `CandidateWorkspace = tmp/canonical-candidates/<transaction-id>/` 创建完整 candidate source view，复制当前 `skills-source/` 并叠加 proposed replacements；该目录不承载 Apply recovery 的唯一副本。
4. 通过显式 candidate source/output/manifest 参数调用受信 toolchain，在 CandidateWorkspace 只产生隔离 source/generated output/manifests；机器可读 build/scan result、report、artifact manifest 和 validation summary 写入通过 `Resolve-PrivateArtifactPath` 的 `CanonicalPreflightOutputRoot`（外部或 contracted Git-private namespace）。不能通过伪造 RepoRoot、修改当前 generated output、把 reviewed artifact 留在 repo-local candidate 目录，或执行候选目录中的脚本来完成 preflight。
5. dry-run 输出 target、old/new hashes、rewrites、preflight 结果和 transaction hash，不修改 canonical source。
6. Apply 先从 resolved `git rev-parse --git-common-dir` 下的 `ai-agent-dotfiles/canonical.lock` 获取 repo-scoped OS exclusive lock；Phase 2后再按统一锁序取得global live lock并枚举全部claims，然后重新验证保存的 plan、input、canonical source 与 transaction hash。durable journal/audit 位于同一 GitCommonDir 的 `ai-agent-dotfiles/canonical-transactions/<worktree-id>/<transaction-id>/`；待提交内容和旧 target recovery copy 位于 working tree 外、与 repo 同卷且 current-user-only 的 `CanonicalRecoveryRoot/<repo-id>/<worktree-id>/<transaction-id>/`。
7. transaction target list 不只包含 canonical skill directories，还包含 candidate build 将改变的 Claude/Codex/Reasonix **managed generated skill directories**和 per-platform/union manifest files。Apply 在任何 rename 前把所有现有 target 的精确 bytes/tree hashes 或 MISSING 状态复制到 CanonicalRecoveryRoot；CandidateWorkspace 中已验证的新 canonical/generated/manifest bytes 则复制到同卷 staged area。generated roots 中不属于 managed target list 的 documented runtime-exclusion/unknown files保持原位、从不覆盖。任何 target 与 DryRun prehash 不同即 plan stale。
8. `CanonicalRecoveryRoot` 内把 immutable `preimage/` 与 mutation-time `swap-old/` 分开：前者在首个 rename 前保存每个旧 target/MISSING 的独立内容副本并绑定 hash/identity，后者初始必须为 MISSING，只接收 old→swap-old rename。每个 directory target 使用两个同卷 rename（old→swap-old、staged→target）；每个 manifest file 使用同目录 temp + flush + OS atomic file-replace并保留独立 preimage。两套副本与路径都进入 journal，完整成功或 reviewed recovery 前均不得清理。只把单个 OS primitive 视为原子，整个 multi-target replacement 由统一 journal/disk reconciliation 保护。
9. commit 后在新的 CandidateWorkspace 做 deterministic rebuild，并对真实 canonical/generated/manifest bytes 运行 scan/parity comparison；postcondition 不直接写真实 outputs。失败时按 journal byte-for-byte 恢复 canonical、managed generated 和 manifest targets，不靠“重新 build 应该相同”的假设，并保留 recovery tree 与 journal。

批量 auto-merge 使用一个 transaction 和一个 preflight，避免部分 skill 已提交、后续 build/scan 才失败。所有子进程 `$LASTEXITCODE` 和机器可读 `Result` 都必须显式检查。repo lock 从 plan revalidation 持有到 postconditions/journal complete；每次 canonical mutation获取锁后必须枚举同一GitCommonDir下**全部 worktree namespaces**的headers/records/results及其CanonicalRecoveryRoot引用，任何worktree有unfinished reservation即阻断新mutation，只开放全局只读recovery status与reviewed recovery plan；terminal consumption scan同样覆盖全部worktrees。repo cleanup不得把这两个durable roots当成`tmp/`清理。

CanonicalRecoveryRoot由独立canonical control setup在repo所在volume上选择并记录到schema-valid、create-new且v1不可替换的canonical setup state；其唯一locator固定为absolute resolved `git rev-parse --git-common-dir`加literal`ai-agent-dotfiles/canonical-setup-state.json`，linked worktree equality必须成立，且该common-dir contract只允许零或一个regular state file，extra/reparse/duplicate为manual。默认recovery root是working tree的writable sibling control directory，而不是repo内ignored`tmp/`。`RepoId=SHA256(domain-tag + access-token SID + GitCommonDir volume identity + directory file identity)`，`ClaimId=RepoId`；不含路径、时钟或随机数，因此linked worktrees共享、fresh clone不同、重启可重算，identity输入变化则作为新repo并发现旧claim冲突而非静默接管。DryRun使用token SID规范化固定的current-user-only owner/protected-DACL template，并以no-follow directory handle绑定三个private root的existing ancestor identity/owner/DACL、MISSING remainder与expected final template；existing root必须已精确符合该template，MISSING ancestor不得向Everyone/Authenticated Users/Builtin Users授予write/delete-child。plan和immutable global claim只绑定stable `SetupIntentHash`与排除Apply-derived `Final*` fields的`ExpectedSetupStateProjectionHash`。Phase 2在journal内创建roots后捕获实际directory identity/owner/DACL，发布含`RootClaimHash`、`SetupStateProjectionHash`与三个final contexts的canonical setup state；完整state hash只进入journal/result/COMPLETE而不反向进入claim，避免不可预知identity造成的hash环。每次status/Apply都以同一handle-bound采集重验intent→claim→state→actual链并拒绝owner/DACL/identity drift。它必须解析为working tree外、非volume root、非source/live/backup/control descendant，且与repo同卷。Phase 1 production canonical-control Apply保持interlocked；Phase 2接入global registry后，它通过claim→state两步finalize，且每次Apply都在canonical→global锁内对全部canonical/home claims重验不相交。已有unfinished all-worktree journal时setup/finalize/任何location change均阻断。没有合格位置时canonical Apply fail-closed，不退化为跨卷copy/delete。

### 4.3 Execution context、plan 与 Apply

machine-private control base 固定为 OS account identity 下的 user-local state root：Windows v1 必须以 access-token SID 加 Known Folder API 的 `FOLDERID_LocalAppData` 解析 `%LOCALAPPDATA%/ai-agent-dotfiles/control/`，HomeRoot/Roaming AppData同样只来自 `FOLDERID_Profile`/`FOLDERID_RoamingAppData`，不能直接信任同名环境变量。ControlBase 的 resolved path/volume/directory identity、owner SID/ACL 与 resolver version进入 execution context并在 Apply 重验；改变 `LOCALAPPDATA`、`USERPROFILE` 或 `APPDATA` 不能改变 registry/global-lock 位置。protocol v1不提供public `-HomeRoot` selector：现有该类参数只允许sealed isolated/fake-home host注入，所有production CLI/hook必须拒绝，避免status/activation/task/authority无法唯一定位custom authority；未来若要支持，需另设计持久selector与全入口签名。非Windows adapter未定义前production保持interlocked。稳定的 `HomeAuthorityKey` 只由 token SID 与 canonical Known-Folder HomeRoot location key 计算，不包含 live directory file id、存在性或 Reasonix override，因此 absent→created 仍定位同一 authority。每个 authority 位于 `homes/<HomeAuthorityKey>/`；repo-local legacy `state/current-env.json` 只可作为显式迁移证据。

ControlBase MISSING时不能先创建目录再假定global lock存在。Windows v1先从token SID、Known-Folder LocalAppData location key和固定domain tag推导working-directory无关的 `ControlBootstrapLockKey`，在**既存Known Folder root**下以no-follow regular `ai-agent-dotfiles.control-bootstrap.lock` exclusive handle串行化全部repo的first-run bootstrap；该lock file位置/owner/ACL/reparse identity固定且不依赖ControlBase identity。reviewed canonical setup plan用 `PrivateRootBootstrapIntent` 绑定Known-Folder parent identity、固定`ai-agent-dotfiles/control`与sibling`ai-agent-dotfiles/backups` remainders、各自MISSING|COMPLETE状态、current-user-only DACL template hash与expected children。Apply先取bootstrap lock并从头重验intent；若MISSING，使用带最终security descriptor的single create primitive依次创建fixed private parent、BackupRoot、ControlBase及 `homes/`、`canonical-roots/`、`live-transactions/`，每项只接受MISSING或已存在且identity/ACL/empty-or-valid-contract完全一致。hard-kill留下的exact deterministic prefix可由同一setup plan重入补齐；foreign bytes、extra/reparse、wrong ACL或identity drift只允许manual，绝不静默repair/delete。ControlBase/BackupRoot完成后才取得global live lock、创建RESERVED/receipt或触碰live。read-only status只报告MISSING/intent，不创建bootstrap lock/file/dir；Apply-derived final identities进入header/receipt/state，plan则保留MISSING sentinel+intent hash。所有receipt-backed live operations都要求该setup已完成，不能在RESERVED后隐式mkdir BackupRoot。

control base 还保存一个 current-user 级全局 live-mutation OS lock。每个authority在首次initial/migrate/adopt时create-new一个独立、immutable、schema-validated的`homes/<HomeAuthorityKey>/root-claims.json`，shared state位于同authority目录并只引用其完整文件hash。live transaction的唯一durable locator固定为`ControlBase/live-transactions/<TransactionId>/`：TransactionId在持bootstrap/global所需锁后生成，必须为规范化UUID且目录create-new；该root只允许immediate transaction directories，每个transaction namespace只允许documented header/numbered records/zero-or-one result/`_pending`，extra/duplicate/reparse为manual。全局locator/manifest/wrong-clone recovery都只从这个fixed root枚举，绝不把首次authority journal放进尚不存在的`homes/<key>`或扫描BackupRoot猜测。`RootClaimsRegistry` 是持锁时先枚举/验证全部 claims 文件，再叠加 complete state 与该fixed transaction root中的unfinished reservations得到的语义视图。plan 的 `TargetContextIntentHash` 绑定三平台 stable claims、existing identity或ABSENT parent/remainder及expected post-existence；`AuthorityBeforeTargetContextHash` 绑定已有 state 的 FinalTargetContextHash或MISSING；`RootClaimsRegistryHash` 绑定全局视图。这些只作为 plan/state precondition，不作为 namespace。fresh clone 先由 HomeAuthorityKey 找到 claims/state，再读取已登记的 custom roots，不需要预先猜 Reasonix override。所有 live Apply 在锁内拒绝不同 HomeAuthority 的任一 root ancestor/descendant overlap；由此部分重叠 target sets 也不能获得独立锁并发写入。claims 文件无法验证时全局 live mutation 进入 `manual-recovery-required`；state 无法验证但 claims 完整时只开放绑定坏 state bytes 的 `repair-adopt`。

本轮只允许 migrate/adopt/initial operation 在**首次建立 schema 3 authority**时声明 actual root locations；一旦 authority 存在，三平台 stable location claims 文件不可变。absent root 创建后只把 Apply-derived directory identities写入新的 shared-state `FinalResolvedIdentities/FinalTargetContextHash`，immutable claim仍保留同一 stable location/ABSENT-intent语义，不做原地更新，也不算 location transition。任何 default↔custom Reasonix 或其它 root-location change 都以 `root-transition-not-supported` fail-closed，旧 claim 不释放、新 root 不写入；未来若需要迁移，必须另做绑定 old+new claims、双边 backup/journal 和成功后释放 old claim 的设计。

所有 live plan 使用同一个不可变 execution context：

```text
RepositoryCommit
RelevantWorkingTreeHash / ToolchainPolicyHash
ControllerRepoFingerprint / SharedAuthorityStateHash
OperationKind = initial | adopt | repair-adopt | migrate | controller-transition | environment | task-overlay | retirement | environment-rollback
SelectionKind = environment
EnvironmentName / EnvironmentLockHash / TaskOverlayHash
Canonical HomeRoot identity
Claude/Codex/Reasonix actual source and live roots
HomeAuthorityKey / TargetContextIntentHash / AuthorityBeforeTargetContextHash / RootClaimsRegistryHash
PrivateRootBootstrapStatus=MISSING|PARTIAL|COMPLETE / PrivateRootBootstrapIntentHash
ControlBaseIdentityHash / FilesystemCapabilityHash (required only when COMPLETE; Apply-derived final values otherwise)
Per-platform manifest hashes
Pre-change managed tree content hashes
Unknown directory inventory fingerprints
Codex .system inventory marker status
```

unknown inventory fingerprint 只绑定规范化 entry name、entry type、entry自身的 no-follow file identity与 reparse tag，不解析或打开 link target，也不读取 unknown directory 的文件内容。unknown 或 `.system` root entry若是任何 reparse type，mutation planning以 `unsupported-unknown-reparse` fail-closed；不得为了“识别”它而跟随 target。普通 `.system` entry同样只记录存在性/类型/entry identity marker，任何流程都不得读取、复制、移动或修改其内容。

完整机器路径只允许出现在 tracked working tree 之外的 plan/receipt 中，包括上述 Git-private pending 目录或用户指定的外部目录；tracked reports 只记录 redacted labels 和 hashes。

所有 plan、receipt、journal、validation output、machine-context report 与既有 evidence 路径必须先经过共享的 `Resolve-PrivateArtifactPath -Role <role>`，且 public 参数不能自行选择 internal role。role 固定为三类：

- `ExternalUserArtifact` 用于 public `PlanPath`/`JsonPath`/validation output；它必须位于 current-user 可写且受控的外部目录，不得**等于** volume root 或 HomeRoot，并须与 worktree content、任意 Git internals、ControlBase、BackupRoot、CanonicalRecoveryRoot、live/source/materialization/staging roots做双向 ancestor/descendant/file-identity disjoint检查。HomeRoot下其它current-user-only目录并非因位于HomeRoot内就一律拒绝，但仍须通过ACL/no-follow/alias规则。
- `InternalContractPath` 只接受由代码按 registry 推导的 exact locator：common-dir contracts 以 absolute resolved `git rev-parse --git-common-dir` 加 literal allowlisted path 构造（canonical lock/setup-state/transactions 与 shared pending.lock）；per-worktree contracts才接受 `git rev-parse --git-path ai-agent-dotfiles/<worktree-namespace>/...`（pending events/plans等）；ControlBase 的 lock/claims/state/live-transactions 与 BackupRoot 下的 transaction-owned receipt 也各有固定 base、relative shape、0/1/cardinality 和 allowed-entry contract。两类 Git namespace在 linked worktree 做 locator equality/inequality 断言，所有 internal paths 做 no-follow identity/cardinality验证，不能互相代替、由 public path switch覆盖或接受任意安全 namespace descendant。
- `EvidenceInputPath` 仅用于 operation 明列的既有只读输入，且每种参数有独立 locator：`ReceiptPath` 只能 equality-resolve 到 exact registered `BackupReceipt` internal slot；`RetireManifestPath` 必须是 `ExternalUserArtifact` regular file；`LegacyStatePath` 必须 equality-resolve 到当前 repo 唯一 legacy state locator；`CorruptStatePath` 仅在 state entry 存在但无效时用于 equality-confirm 当前 HomeAuthority 的 exact ControlBase `current-env.json` internal locator，不能选择 external/legacy bytes。claims有效而该 state entry MISSING时，repair plan使用 `StateEvidence=MISSING`并禁止 `CorruptStatePath`。任何 evidence 在首次 content open前必须是 regular file、只含 unnamed stream、link count=1、无 reparse/ADS，且通过 handle-based final identity、allowed-root与open前后identity重验；hardlink/ADS/reparse/identity race 到 protected或outside sentinel均 fail-closed且不得打开目标内容。

每个入口在创建或打开 plan/temp/summary/evidence 前执行对应 role 检查；不能用粗粒度“RepoRoot descendant全拒绝”误伤已登记 namespace，也不能借例外写其它 Git/internal 安全路径。

为避免把不同用途的 `staging` 混为一谈，路径术语固定为：

- `CandidateWorkspace`：repo-local ignored、可丢弃的 canonical build/scan preflight workspace。
- `EnvironmentMaterializationRoot`：env build 产生的隔离 source tree；其 platform source roots 可以是该目录子项，但整个 root 只读，不是 mutation staging。
- `LiveMutationStagingRoot`：每个平台 live target 的同卷 write/swap/recovery workspace，必须位于 tracked working tree 外并保留到 transaction complete。
- `CanonicalRecoveryRoot`：canonical targets 的 working-tree 外、repo 同卷 recovery workspace；定义见 4.2。
- `BackupRoot`/`ControlBase`：durable、working-tree 外的 backup/authority roots。

所有路径先经过同一个 target resolver，但调用模式必须显式区分：`MetadataOnly` 只做 no-follow path normalization、现存 parent/entry identity、volume metadata、inventory 与 forbidden-root/overlap 检查，绝不创建 probe/temp、打开目标内容或产生残留；它只返回 `FilesystemCapabilityStatus=UNPROBED` 和独立的 `RequestedInitialRootContextHash`。严格只读 status 只能使用该模式。`MutationPreflight` 才在 approved sibling area 执行下述 write-capability probe，计算 `FilesystemCapabilityHash`，供 DryRun 写入 reviewed plan，并由 Apply 持锁重做。DryRun 必须同时绑定并重验 status 的 metadata-only context hash，不能用 probe 结果替换或弱化它。

- 对现存目录记录 resolved final path、volume identity、directory file identity 和 case-insensitive comparison key；对尚不存在的目标记录最深 existing parent identity 加规范化 remainder。
- protocol v1 只接受 Windows `DriveType=Fixed` 的 local NTFS volume；`MutationPreflight` 在 approved sibling staging/control area 运行不触碰目标内容的 create/flush/same-volume rename/ReplaceFile capability probe并清理其专用 probe slot。UNC、mapped/network、removable、FAT/ReFS/unknown filesystem、残留 probe artifact 或 probe失败均 fail-closed，非 Windows production暂不 release。volume serial、filesystem type、drive type、probe version/result与 primitive set规范化为 `FilesystemCapabilityHash`，纳入 plan/receipt/journal/target context并在 Apply 持锁重验。custom Reasonix、canonical recovery 与每个 live target分别通过该 gate；“同卷”本身不是充分条件。
- 解析并记录每个 reparse ancestor/target，在 Apply 前重新验证；无法解析、身份变化、驱动器根目录、HomeRoot 根目录或 Codex `.system` 均拒绝。
- 三平台 resolved source roots 彼此不重叠，三平台 live roots 彼此不重叠；EnvironmentMaterializationRoot 可以包含其 source roots，但与 live/backup/control/live-mutation roots 不重叠。
- 每个 actual live claim/target 必须与 tracked working tree、GitCommonDir、CandidateWorkspace、EnvironmentMaterializationRoot/source roots、ControlBase、BackupRoot、CanonicalRecoveryRoot、所有 LiveMutationStagingRoot 及其它 authority reservation 做 pairwise ancestor/descendant/file-identity disjoint 检查；不能等于 HomeRoot/volume root，也不能包含上述安全元数据或 recovery root。
- 每个 LiveMutationStagingRoot 与对应 live target 同卷、互为 sibling且不与任何 source/live/backup/control/canonical root 重叠；BackupRoot、ControlBase、LiveMutationStagingRoot 与 CanonicalRecoveryRoot 均不得位于 tracked working tree。CandidateWorkspace 只允许 repo-local preflight，不承载 durable recovery。
- linked worktree 的 Git-private 路径明确分两类：common-dir contracted namespace由absolute resolved `git rev-parse --git-common-dir`加literal `ai-agent-dotfiles/<contract>`组成并在所有linked worktree相同；per-worktree pending namespace才使用`git rev-parse --git-path`并保持隔离。current-user global registry同时枚举HomeAuthority root claims与每个repo的immutable canonical-root claim。protocol v1 canonical setup在canonical→bootstrap→global锁内预计算stable setup intent/state projection及其hash，create-new发布绑定`SetupIntentHash`与`ExpectedSetupStateProjectionHash`的immutable global claim；root创建完成后才从实际identity/owner/DACL派生create-new final setup-state，state反向绑定`RootClaimHash`，其完整hash只由journal/result/COMPLETE绑定。setup固定reviewed recovery矩阵：零claim/state primitive只能`canonical-recover-abandon`；exact claim已发布而setup-state MISSING时只能新建外部`canonical-recover-finalize` plan，重验claim、projection与已创建roots的actual final contexts后发布唯一匹配的final state并以`ClosingKind=recovery`关闭；claim+state均valid而terminal缺失也只能reviewed finalize record。原`agent-dotfiles.ps1 canonical setup -Apply`对unfinished transaction只返回`recovery-required`，绝不重入/forward-resume。state-without-claim、intent/projection/hash不符、corrupt或任何root location/owner/DACL/identity change均manual/block并返回`canonical-root-transition-not-supported`，v1没有replace/relocate。live与canonical planner均在同一registry view中做跨HomeAuthority/跨repo ancestor/descendant/file-identity overlap，不能只由canonical单向检查live。
- 显式 Reasonix override 可以位于默认 AppDataRoot 之外；mutation 入口中只有 `sync.ps1` initial 或 `env authority migrate|adopt` 可接受 `-ReasonixLiveSkillsPath <absolute>`，且 DryRun/Apply 两次 invocation 必须传入同一值并由 plan 绑定。唯一只读例外是尚无 schema 3 claims 时的 `env authority status`，它只用 `MetadataOnly` resolver做路由并产生零 filesystem write。repair-adopt/takeover/ordinary activation/rollback/recovery 从 immutable claim 解析 root 并拒绝该 switch。首次 claim 也必须通过上述完整 forbidden-root 矩阵；之后 location 必须完全一致，任何 override/change 都以 `root-transition-not-supported` 零写入拒绝。

所有递归 hash/copy/scan/restore 共用一个 `SafeTreeWalker`，不能各脚本自行 `Get-ChildItem -Recurse`：

- walker 对每个 entry 做 no-follow/lstat 与 handle-based final-identity check；managed/input/candidate/materialized/backup/recovery tree 内出现 symlink、junction、其它 reparse point、multi-link hardlink、重复 file identity，或 regular file 上除 unnamed default stream 外的任意 NTFS alternate data stream时 fail-closed，不跟随、不复制也不忽略额外内容。destination comparison同样枚举 ADS；ACL/timestamps仍不属于 content hash。
- 每个 regular file 打开后再次确认它仍位于 approved root identity 下，防止检查后替换；路径逃逸、权限不足或 identity race 都使当前 plan/backup/recovery 失败。
- unknown live directories 和 Codex `.system` 永不递归进入，只对 root entry 本身做 no-follow/lstat inventory marker；reparse entry直接阻断 mutation且不 resolve target，其 link target/content从不读取。
- backup/receipt finalize 与 recovery Apply 都重新用同一 walker 验证 snapshot/recovery tree，避免离线篡改加入 link 后越界恢复。

semantic JSON 使用 RFC 8785 JSON Canonicalization Scheme 后以 UTF-8（无 BOM）计算 SHA-256。安全契约只允许 I-JSON safe integer `[-9007199254740991, 9007199254740991]`，不允许超出范围的整数、浮点或非有限数；所有包含数值的 artifact schema 同步声明该 minimum/maximum，边界值与越界一位均有 fixture。optional value 缺失与显式 `null` 不等价。platform array 固定为 Claude、Codex、Reasonix，action/set array 按 platform、skill name 的 ordinal key 排序并拒绝重复。JSON Schema 只验证可表达的 shape/type/required/oneOf 约束；`artifact-contracts.psd1` 为复合 key 唯一性、固定顺序、hash/references 与 artifact DAG 指定命名 semantic validator，negative fixture 标明预期由 schema 还是 semantic 层拒绝。所有 identity/path string 在进入 JSON 前已经由 target resolver 规范化，并以 tracked test vectors 验证不同 PowerShell 进程产生相同 bytes/hash。

plan document schema 把内容明确拆为 `Metadata` 与 `PlanPayload`；`Metadata` 只允许 `GeneratedAtUtc` 和 schema 定义的 redacted display labels，generator/toolchain version 必须进入 payload。`PlanHash` 是完整 `PlanPayload` 的 RFC 8785 bytes SHA-256，不使用“排除所有 hash 字段”一类过滤；payload 内的 lock/state/toolchain/root-claims/manifest/source/live/backup 等所有语义 precondition hashes都受保护。`DocumentHash` 是整个保存文档除 `DocumentHash` 自身外的 SHA-256，包含 Metadata、PlanPayload 与 PlanHash，用于检测任何保存文档改写。authority 不存在等安全状态使用显式 `MISSING` sentinel，不用 `null` 或字段缺失猜测。Apply 必须依次验证：

1. 从保存的完整 plan document 重新计算 `DocumentHash`，等于 document 中的值。
2. 从保存文档的 semantic payload 重算 `PlanHash`，等于 document 中的值。
3. 从当前 source、live 和 execution context 重新计算 current semantic plan。
4. current `PlanHash` 等于 reviewed `PlanHash`。
5. selection context 与 active state/lock 匹配。
6. 在该操作按统一顺序取得的全部所需锁内扫描 retained terminal journals，确认该保存文档的 `DocumentHash` 尚未作为 original operation或 closing recovery document被消费。

`DocumentHash` 同时是 plan consumption key。journal header绑定 original operation `DocumentHash`；每次 reviewed recovery Apply 在任何 recovery primitive、result创建或 terminal发布前，先 append/flush 一个 `RECOVERY_ACTION_INTENT` record，绑定 recovery PlanKind、该 recovery plan `DocumentHash`、prior head与 expected terminal semantic projection hash。recovery plan只预绑定 Outcome、实际对象状态和 refs 等不含 ResultHash、result head或自身 DocumentHash的 projection，不能预绑定会经由该 intent 反向依赖自身的完整 result bytes/hash。terminal-intent result只绑定 original DocumentHash、其发布前的 journal head、Outcome与已完成 refs，不反向引用 recovery plan；其 `ResultBaseHeadHash`必须是最终 chain 的有效 ancestor，后续只允许schema定义的 recovery-intent/closing records。最后的 COMPLETE record绑定 header的 original `DocumentHash`、ResultHash，并以严格 oneOf 表示关闭者：`ClosingKind=original` 时 `ClosingDocumentHash` 必须等于 header original DocumentHash且禁止 ClosingPlanKind；`ClosingKind=recovery` 时必须同时绑定 reviewed recovery的 `ClosingPlanKind`与其 DocumentHash。consumption scan读取 header、每个 `RECOVERY_ACTION_INTENT.DocumentHash` 与 terminal closing hash；因此一次 action-result 后 hard-kill可由新 finalize plan原样复用result并关闭，同时原 action plan与新 closing plan都不可重放。任何 terminal Outcome都使 original与全部 attempt/closing保存文档永久 consumed，即使 `abandoned|failed-restored` 后 bytes/context 恰好恢复原状；新尝试必须重新 DryRun生成新的保存文档。任何 plan 文档篡改、另一 HomeRoot 复用、source/live drift、manifest drift、environment drift、backup context drift或 consumed document replay都会拒绝 Apply，且不创建新 reservation/backup。success/no-op/abandon/rollback/failed-restored、result-MISSING recovery construction、action-intent后各hard-kill、existing-result+new-recovery-finalize与 byte-identical reconstruction都必须有 replay/DAG fixtures。

所有 mutation 入口遵守同一个双命令契约：

| 操作 | 计划命令 | 执行命令 |
|---|---|---|
| canonical read-only status | `agent-dotfiles.ps1 canonical status`；只用MetadataOnly/no-create locator返回`canonical-recovery-required|canonical-setup-required|canonical-ready|manual-recovery-required` | 无 Apply 形式；bootstrap与rollout必须消费同一status helper |
| canonical/control setup | `agent-dotfiles.ps1 canonical setup -DryRun -PlanPath <new>`；绑定PrivateRootBootstrapIntent、RepoId/ClaimId、CanonicalRecoveryRoot capability和expected claim/setup-state bytes | 同一命令使用`-Apply -PlanPath <existing>`；fresh identity必须先完成它，才可initial；不触碰live roots；`setup.ps1`仅负责runner approval/inert hooks并拒绝这些参数 |
| pristine initial install | `sync.ps1 [-ReasonixLiveSkillsPath <absolute>] -DryRun -PlanPath <new>`；仅无 authority、roots pristine，且物化 named `full` environment | 同一 optional root 使用 `-Apply -PlanPath <existing>`；authority 已存在时永远拒绝 |
| env activation | `agent-dotfiles.ps1 env activate <name> -DryRun -PlanPath <new>` | 同一命令使用 `-Apply -PlanPath <existing>` |
| task ensure/sync/close | `agent-dotfiles.ps1 env task ensure-skill <name> -Platform <Claude|Codex|Reasonix> [-BaseEnv <name>]`、`env task sync [-BaseEnv <name>]` 或 `env task close [-BaseEnv <name>]`，分别追加 `-DryRun -PlanPath <new>`；status只读 | 同一 action/name/platform/base-env 使用 `-Apply -PlanPath <existing>`；`-Automatic` 与所有 skip/test switch拒绝 |
| explicit skill retirement | `sync.ps1 -RetireManifestPath <external> -DryRun -PlanPath <new>` | 同一 retirement manifest 使用 `-Apply -PlanPath <existing>`；hooks 永不调用；active selection 下只允许 out-of-selection stale target，且 state postimage/receipt/final hashes 一起提交 |
| legacy migration/adoption/corrupt-or-missing-state repair/controller change | `env authority migrate <name> -LegacyStatePath <exact-current-repo-path> [-ReasonixLiveSkillsPath <absolute>]`、`adopt <name> [-ReasonixLiveSkillsPath <absolute>]`、`repair-adopt <name> [-CorruptStatePath <exact-authority-state-path>]` 或 `takeover <name>`，均使用 `-DryRun -PlanPath <new>`；repair-adopt在`StateEvidence=CORRUPT`时要求exact path，在`MISSING`时禁止path；repair-adopt/takeover 拒绝 root override，adopt/takeover 拒绝 evidence-path switch | 同一固定签名与 operation kind 使用 `-Apply -PlanPath <existing>`；migrate/adopt 的 optional root 与 operation所需evidence参数在两次 invocation 必须相同 |
| environment rollback | `agent-dotfiles.ps1 env rollback -ReceiptPath <complete-environment-receipt> -DryRun -PlanPath <new>` | 同一 receipt path 使用 `-Apply -PlanPath <existing>`；只接受 `SourceOperationKind=environment` |
| canonical crash recovery | `agent-dotfiles.ps1 canonical recover status`，或 `canonical recover <abandon|rollback|finalize> -TransactionId <id> -DryRun -PlanPath <new>` | 同一 action/id 使用 `-Apply -PlanPath <existing>`；status 始终只读 |
| live crash recovery | `agent-dotfiles.ps1 live recover status`，或 `live recover <abandon|rollback|finalize> -TransactionId <id> -DryRun -PlanPath <new>` | 同一 action/id 使用 `-Apply -PlanPath <existing>`；status 始终只读 |
| pending-preview retirement | `agent-dotfiles.ps1 plans prune -DryRun -PlanPath <new-external>`，按 age/hash只选择并绑定 exact internal paths/hashes | 同一命令使用 `-Apply -PlanPath <same-external>`；只移动 reviewed set到 Git-private retired namespace，不重枚举或硬删除 |

`plans prune` 是唯一 Git-private administrative storage mutation，不属于 canonical/live lock graph：Phase 0先冻结同一semantic-json PlanHash/DocumentHash helper，再以resolved GitCommonDir下独立`ai-agent-dotfiles/pending.lock`串行化hook create-new、stale sidecar和reviewed exact-set move。它不得在持pending lock时获取canonical/global lock，也不得触碰canonical/live/authority/backup；除此之外的repository/canonical/live mutation仍遵守4.3统一锁序。

DryRun 以 create-new 写 plan，拒绝覆盖；Apply 要求已存在且 complete 的 plan，禁止内部生成、刷新或改写它。`-DryRun`/`-Apply` 互斥，Apply 缺 `PlanPath`、operation kind 不同或 plan 与当前 invocation 不匹配时失败。命令分离提供可审阅边界，但不把“曾生成计划”误当成人工授权证明。

public Apply 入口不再暴露 `-SkipBuild`、`-SkipSecretScan` 一类可用于 real target 的绕过。sync、env activation 和 task apply 都必须检查 build exit、secret-scan exit 及机器可读 PASS 结果；测试通过 internal dependency injection/fake toolchain 制造失败，不给生产 CLI 留 test-mode capability。

Apply 在 current-plan 重算前从 ControlBase 获取 current-user 级跨进程排他 live-mutation lock，并持有到 root claims、postconditions、receipt/journal 和 authority state commit 完成。锁由 OS 独占 handle 保证跨 HomeAuthority/clone/worktree 互斥；残留 metadata 只用于诊断，不能以删除 lock 文件的方式强行绕过仍存活的 owner。

所有 repository/canonical/live mutation固定使用一个全局锁序：Git-common-dir canonical lock → 仅 task/rollback-overlay相关时的 worktree overlay lock → 必要时上述pre-ControlBase bootstrap lock → current-user ControlBase global live lock。canonical Apply/recovery在 Phase 2后也持有 global live lock，以便枚举全部 root claims并防止 CanonicalRecoveryRoot与custom live root竞态；所有 live/authority/retirement/rollback/recovery先持 canonical lock冻结 repository/toolchain/materialization context，再按需取 overlay/bootstrap/global lock。任何路径不得反向获取、跳过或在持global后再取repo/overlay。protocol v1 public CLI固定zero-wait且拒绝`-LockWaitSeconds`或等价switch；锁忙时在任何 backup/mutation workspace/mutation 前以`operation-lock-busy`非零退出。只有sealed isolated test host可注入1–300秒bounded wait来证明waiter取得全部锁后仍从头重算plan/registry，且该test-only值不进入plan或public result。两个进程消费同一reviewed plan时，最多一个成功；内部bounded-wait fixture取得锁后因live/authority/canonical drift以`reviewed-plan-stale`退出，且不创建backup、不mutation。owner hard-kill后OS handles自动释放，但durable in-progress journal使下一命令进入`recovery-required`，不能直接重试Apply。Phase 1只在sealed isolated host验证canonical engine；production canonical setup/Apply保持interlocked，直到Phase 2实现global registry/lock并在每次Apply重验全部claims。

### 4.4 Backup receipt 与 recovery

protocol v1 `BackupRoot` 固定由 Known Folder `FOLDERID_LocalAppData` 推导为 current-user-only `%LOCALAPPDATA%/ai-agent-dotfiles/backups/`（不读取同名环境变量），与ControlBase sibling且不重叠；public `-BackupRoot` 一律拒绝，仅sealed fake-home host可注入。其resolved identity/ACL/filesystem capability进入execution context/plan并在Apply重验。backup directory 使用预先绑定的TransactionId/ReceiptId与 create-new 语义创建；高精度时间只作受保护display metadata，碰撞时失败，绝不复用已有目录。BackupRoot 必须位于 tracked working tree、EnvironmentMaterializationRoot、三平台 live roots、LiveMutationStagingRoot 与 CanonicalRecoveryRoot 之外，并通过同一个 target resolver 验证不相交。

正式 receipt producer 是 transaction host内部的 managed-backup函数；它接收 RESERVED header中已经解析并绑定的三平台实际 live roots与ReceiptIntent，而不是由public `backup.ps1`重新从HomeRoot猜测或独立创建receipt。public standalone `backup.ps1` 在Phase 0 interlock后于Phase 2正式退役为零写入、非零 `backup-is-transaction-internal` diagnostic；preview只存在于对应sync/env/task/rollback reviewed plan，不另发独立backup JSON。internal snapshot只包含plan中的pre-change managed skill directories；unknown directories和Codex `.system`从不复制或读取。managed skill不存在时在receipt中记录`MISSING`，不创建伪目录。internal producer返回结构化receipt：

```text
SchemaVersion=1 / ReceiptId / ReceiptHash / SourceTransactionId
SourceOperationKind / PlanHash / DocumentHash / ExecutionContextHash
Actual live roots and target identity
Per-platform directory existence
Per-skill pre-change tree hashes
Unknown/.system inventory marker evidence
Per-platform managed snapshot hashes
AuthorityStatePreimage = MISSING | relative path + bytes hash
RootClaimsPreimage = MISSING | relative path + bytes hash
CreatedAtUtc
```

`sync.ps1` 将 receipt path/hash/SourceTransactionId 直接返回给调用者。`activate-harness-env.ps1` 只接受这一个 receipt，不扫描 BackupRoot 选择“最新”目录。receipt与 RESERVED header双向绑定 TransactionId/ReceiptId/path；terminal committed result再绑定 ReceiptId/ReceiptHash，形成可验证 provenance。

backup directory 的 `snapshot/claude|codex|reasonix` 是唯一进入 managed snapshot hash 的范围；`authority-preimage/` 另外保存 pre-Apply shared state/root-claims 的精确 bytes 或 MISSING，拥有独立 hashes并受 ReceiptHash 保护，但不混入 managed snapshot hash。`_meta/receipt.json`、journal、logs 和 complete marker 明确排除，避免自引用。finalize 顺序为：复制 managed snapshot 与 authority preimage → 关闭 file handles并重算 source/snapshot/preimage hashes → 生成 semantic receipt → 计算仅排除 `ReceiptHash` 自身的 receipt hash（`CreatedAtUtc` 也受保护）→ 以 create-new temp file 写入并 flush → rename 为 final receipt → create-new/flush `COMPLETE` marker。consumer 必须同时验证 marker、receipt、managed snapshots、authority preimage 和 plan/context refs。成功 activation 的 mutation-time state swap/preimage可以按 cleanup-on-success 清理；未来 environment rollback 只依赖这份 durable receipt，不依赖临时 recovery workspace。

在 operation lock 内先固定执行：扫描 **全部** HomeAuthority 的 unfinished live transaction/reservation → 重算 reviewed plan → 生成 TransactionId。每个 header都绑定immutable `OriginRepoId`、resolved GitCommonDir identity/canonical-lock key及可选overlay-lock identity，使任意clone的recovery可先只读定位、释放scan handles，再按origin canonical→optional overlay→global顺序取锁并重找重验；缺失/歧义origin只允许manual。receipt-backed branch在任何 backup目录创建前还要生成/验证唯一 ReceiptId与 exact create-new path，并把 `ReceiptIntent`（id/path/BackupRoot identity/expected target set）写入 create-new/flush、全局可发现的 `RESERVED` header；state-only显式写 `ReceiptRef=NO_LIVE_MUTATION`。header同时绑定PlanHash、HomeAuthorityKey、完整 root-claim reservation、target identities与 `TransactionMode=receipt-backed|state-only`。receipt-backed operation之后只能创建/校验该 exact receipt slot、flush `RECEIPT_COMPLETE`、复核 live hashes、flush PREPARED、执行 live/file mutation、验证 postconditions、原子替换 state并 complete；hard-kill后 recovery按header intent检查MISSING/PARTIAL/COMPLETE，绝不扫描/猜测BackupRoot里的“最新”目录。仅 controller-transition 使用 state-only branch：跳过 backup/receipt，先持久化并验证 immutable authority-state preimage及 `STATE_PREIMAGE_COMPLETE`，再走 FILE_PREPARED/FILE_REPLACE_INTENT/FILE_REPLACED 替换 state，验证 controller-only postcondition并 complete。两种 header 都可被全局 recovery发现；header 一旦存在，只有 reviewed abandon/rollback/finalize 才能结束 reservation。

state-only recovery 的结果优先于 receipt-backed 的通用 target 规则并保持唯一：`STATE_PREIMAGE_COMPLETE` 且 state file primitive 尚未发生时只能 abandon；state 已呈现 reviewed postimage、swap-old/preimage 完整且 state/claims/controller/plan 全部重验通过时只能 finalize，即使 `FILE_REPLACED` record 尚未来得及 publish；state primitive 已发生但 postimage 语义不成立、且 captured swap-old/preimage 能唯一证明 reviewed old bytes 时只能 rollback；tuple、record chain 或 old/new 关系不能唯一调和时只能 manual-recovery-required。state-only 没有其它 live target，不能同时成为 rollback-required 与 finalize-eligible。

environment rollback dry-run 只接受已完成且 `SourceOperationKind=environment` 的 activation receipt，并必须通过 `SourceTransactionId` 找到 retained journal header、fixed result与最终 COMPLETE record，验证原始/closing plan refs、ReceiptIntent/ReceiptId/ReceiptHash一致且终态 `Outcome=committed`。对应 transaction为 `abandoned|failed-restored|rolled-back`、unfinished、缺失或 tampered时，即使 receipt自身 COMPLETE也拒绝。initial/migrate/adopt/repair-adopt/task-overlay/retirement receipts 只能用于同一事务的 crash recovery，不能发起日后普通 rollback。环境 rollback plan 绑定：

- 当前 execution context 与 active state identity，以及 activation receipt 中必定存在的旧 authority state/root-claims bytes/hashes；MISSING preimage 使普通 rollback fail-closed。
- receipt hash 和原 activation plan hash。
- 每个待恢复 backup skill tree hash。
- 当前 live tree hashes 与预计 restore/add/remove/no-op actions。
- strict eligibility：current authority state bytes/hash/generation必须恰好等于source activation committed terminal postimage；activation authority preimage、terminal postimage与当前tracked `.agent-harness/task-skills.psd1` 的 TaskOverlayHash/三平台baselines必须三者相同。任何后续task/authority/retirement generation或activation本身修正过stale overlay，都拒绝旧receipt rollback并要求先生成当前overlay的fresh environment plan。
- 对 crash recovery，还绑定 reservation/journal id、由最高连续有效 published record 推导的 `DerivedJournalHeadHash`、完整 record-chain hash、当前 target/staged/swap-old/immutable-preimage tree hashes、root claims、authority state hash、state recovery-copy hash 和所有实际 path identities。

rollback plan 从 environment activation receipt 的 authority preimage 推导 `RollbackStateIntent`：恢复旧 selection/controller/final managed 语义，但用本次 rollback 的新 plan/receipt/journal refs生成新 state；它永不创建、删除或迁移 root claims，也不改tracked overlay。rollback DryRun/Apply按canonical→overlay→global锁序绑定并重验tracked overlay hash；Apply在变更前为当前 managed live、current authority state和root claims创建durable pre-rollback receipt，并记录overlay hash marker。backup tree、authority preimage、source terminal poststate、SourceOperationKind、saved rollback plan、current live/state/claims/overlay或target identity任一变化均拒绝执行。

live 与 canonical **journal chain**只由 schema-valid create-new header和 numbered published record files构成；header绑定 original operation `DocumentHash` consumption key。两者分别是独立 ArtifactKind，不存在可递归自记账的 mutable head/index file。transaction directory另只允许零或一个固定 `result.json` ArtifactKind与专用 `_pending/` temp namespace，除此之外均为 unknown entry。每条 record包含 monotonically increasing sequence、previous-record hash、phase、target identity、expected old/new hashes和相关 paths；reviewed recovery还必须先发布 `Phase=RECOVERY_ACTION_INTENT` record，记录PlanKind/DocumentHash/prior head/expected semantic projection，之后才允许对应 primitive/result/terminal。record先在 `_pending/record-<sequence>-<guid>.tmp` self-validate/flush，再 atomic rename为固定 published filename。`DerivedJournalHeadHash`由最高连续有效 record只读推导。artifact manifest逐项枚举 header、每个 published record及存在时的 result；named semantic validator拒绝 record gap/duplicate/extra/hash断链、result-base不是有效ancestor、recovery action无preceding intent、result cardinality>1或 TransactionMode不一致。known pending temp不属于 chain，crash后保留/结合磁盘 tuple分类；unknown namespace entry才 manual-recovery-required。不能把 directory当单一 JSON，也不能依赖可能半写的 append-only text。

事务没有独立 COMPLETE marker。唯一终态是最后一个 published `Phase=COMPLETE` record，并带严格 oneOf `Outcome=committed|abandoned|rolled-back|failed-restored` 以及上述 `ClosingKind=original|recovery`：原命令正常成功或 reviewed recovery finalize写 `committed`；零 primitive 的 reviewed abandon写 `abandoned`；reviewed rollback写 `rolled-back`；commit boundary前原命令caught failure且旧状态已完整重验时写 `failed-restored` 并让命令非零退出。只有该 record关闭 reservation、使原 operation以及存在时的recovery plan stale；journal仍保留作审计但不再阻挡新事务。若终态 record未 publish，仍按 unfinished transaction处理。backup receipt的独立 `COMPLETE` marker是唯一例外，不属于 transaction journal。

machine-readable operation result 先以 `ResultScope=command|transaction` 严格分层。live schema的`command` scope只用于CLI指定的外部 JsonPath/structured stdout，绝不存入transaction namespace或关闭reservation；其 exact `CommandKind` 为 `initial|environment|task-overlay|retirement|migrate|adopt|repair-adopt|controller-transition|environment-rollback|live-recover-status|live-recover-abandon|live-recover-rollback|live-recover-finalize`。canonical-result schema使用独立exact enum `canonical-status|canonical-setup|canonical-normalize|canonical-promote|canonical-merge|canonical-recover-status|canonical-recover-abandon|canonical-recover-rollback|canonical-recover-finalize`，分别映射read-only selector、上述CanonicalOperationKind/CanonicalRecoveryPlanKind，绝不混入live schema。原始命令kind与对应OperationKind一一映射；recovery action必须另带matching recovery PlanKind，定位成功时还必须带header的OriginalOperationKind。command lifecycle只允许`no-transaction`（DryRun/interlocked/lock-busy/preflight-or-plan-stale，禁止transaction/receipt/state refs）、`unfinished`（只引用已存在TransactionId/head与MISSING|PARTIAL|COMPLETE状态，complete对象才有hash）或`terminal-reference`（只引用已验证fixed ResultHash/Outcome/terminal record，不复制authoritative payload）。unknown/missing transaction的recovery response禁止伪造OriginalOperationKind。`transaction` scope只允许transaction directory内的fixed `terminal-intent`，要求原始OperationKind并禁止CommandKind/PlanKind。

transaction-scoped header/context/fixed result 的 `OperationKind` 始终是原始事务 kind；`live-recover-*` 只出现在 closing recovery plan/command，绝不替换 fixed result 的 discriminator。`committed` fixed result必须绑定完整 plan/document/journal/state，receipt-backed还必须有 COMPLETE receipt；`abandoned` 允许 receipt/state 为 MISSING|PARTIAL|COMPLETE但只在 COMPLETE时允许对应 hash；`rolled-back|failed-restored` 必须绑定 restoration proof、最终 old-state/live hashes以及所有实际存在的 refs，仍只为 COMPLETE对象携带 hash。state-only所有分支都禁止 receipt字段。terminal-intent以 deterministic semantic payload写 `_pending/result-<guid>.tmp`并 atomic create-new为固定 `result.json`，绑定 TransactionId、original `OperationKind`/DocumentHash、`ResultBaseHeadHash`、Outcome与全部已完成 refs/hash；payload不引用 recovery plan且不使用 recovery时钟字段。随后最后一个 `Phase=COMPLETE` record引用其 ResultHash并使用 `ClosingKind` oneOf：original branch只重复original DocumentHash并禁止ClosingPlanKind，recovery branch才绑定actual `ClosingDocumentHash`/`ClosingPlanKind`。recovery若 result存在必须 byte/hash/Outcome/原始 OperationKind匹配并原样复用；若 MISSING，reviewed recovery plan只绑定不含head/ResultHash/plan-self-reference的 expected semantic projection，Apply先发布其`RECOVERY_ACTION_INTENT`，完成动作后按actual chain head构造一次fixed result并验证projection相等；pending temp需精确调和，extra/mismatch为 manual。consumer只有在 terminal record存在且 hash一致时才把 terminal-intent当成终态。matching result已存在而terminal record缺失时，recovery路由的最高优先级永远是“只补 COMPLETE”的 finalize-eligible：新 finalize plan仍先发布自己的 intent，按result现有Outcome重验对应最终tuple/refs，然后只发布terminal，绝不再次执行 abandon/rollback/live/state primitive。只有result MISSING才进入基于磁盘tuple的abandon/rollback/committed-finalize分类。kill-after-result时 reviewed finalize必须保留 existing Outcome（包括 `failed-restored|abandoned|rolled-back`），不得改成 `committed`；无 existing result才由 recovery action唯一决定 expected Outcome。result或 terminal-record publish失败仍是 unfinished transaction，terminal record成功后不得再有必需 publish。intent/result/terminal publish与primitive前后都有 hard-kill failpoint。canonical/live result schemas都遵守该scope/lifecycle规则，并用command/transaction字段交叉污染、original environment/task transaction在 result publish前后 crash、四种Outcome的result→hard-kill→finalize、attempt-hash replay、original/recovery ClosingKind mismatch、early-abandon、result-MISSING无环构造、existing-result+new-closing-plan与 fabricated-hash反例固定该 oneOf。

每个 directory target replacement 使用固定磁盘状态机：

1. `PREPARED`：验证并记录 `target=OLD|MISSING`、`swap-old=MISSING`、`staged=NEW`，并绑定独立 immutable preimage 的 hash/identity。
2. flush `MOVE_OLD_INTENT`，执行单个同卷 `target→swap-old` rename（OLD 为 MISSING 时记录 no-op），验证磁盘 tuple 后 flush `OLD_MOVED`。
3. flush `MOVE_NEW_INTENT`，执行单个同卷 `staged→target` rename，验证 `target=NEW`、`swap-old=OLD|MISSING`、`staged=MISSING` 后 flush `NEW_INSTALLED`。
4. 所有 targets 到达 `NEW_INSTALLED` 后才进入 postconditions/state commit；state file replace 的 recovery copy 也作为独立 target/record 绑定 hash。

每个 manifest、authority state、root claims 或 tracked overlay 等 **file target** 使用独立但同样 write-ahead 的状态机：`FILE_PREPARED` 绑定 `target=OLD|MISSING`、`swap-old=MISSING`、同目录 `staged=NEW` 与 immutable preimage；flush `FILE_REPLACE_INTENT` 后，existing target 使用同卷 OS atomic replace并把被替换的 destination 原子捕获到 `swap-old`，MISSING target 使用不覆盖的 atomic move。primitive 后必须调和 `target=NEW`、`staged=MISSING`、`swap-old=OLD|MISSING` 再 flush `FILE_REPLACED`。replace 前最后一次检查与 primitive 之间若有外部编辑，captured swap-old hash 必然不等于 reviewed OLD，事务进入 manual-recovery-required并保留用户 bytes；MISSING target 被竞态创建时 primitive 必须失败而不能覆盖。

若任何 canonical/generated/live target的父目录链部分或全部 MISSING，plan必须把从最深 existing parent之后的每个 component列为独立 parent-directory target，不可在 helper里隐式 `New-Item -Force`。事务按 parent-first顺序 flush `DIR_CREATE_INTENT`、执行 single-component no-overwrite create、记录 created directory identity并 flush `DIR_CREATED`，然后才允许 child staging/rename/replace。intent-only recovery用 parent identity+existence+empty/content marker调和；rollback按 child-first逆序，仅在目录仍是本事务创建的同一 identity且为空时删除。任何外部竞态创建、加入内容、identity漂移或非空目录都保留现场并进入 manual recovery，绝不递归删除。fresh HOME与fresh generated roots的完整 MISSING chain、每个 mkdir前后 hard-kill、外部竞态写入均为 canonical/live共同 fixture；最终 state使用这些 Apply-derived identities。

hard-kill 可能发生在 OS directory rename/file replace 已成功、result record 尚未持久化的窗口，因此 recovery 不能只看 journal phase。它在锁内对 target/swap-old/staged 的 path identity、existence 和 tree/file hash做 reconciliation，并独立验证 immutable preimage：符合 schema 定义的 pre-primitive tuple 才视为未执行；符合 post-primitive tuple 即使只有 intent 也视为已执行；任何两边同时出现、hash 不符、额外 entry、preimage drift 或 identity 变化都进入 `manual-recovery-required`，绝不猜测或删除。intent-only 永远不能仅因缺 result record 而走 abandon。

所有 mutation 入口开始前在 global lock 内扫描 ControlBase 下全部未完成 reservation/journal，而不是只扫描当前 authority 或 target scope：

- `RESERVED`、partial receipt、`RECEIPT_COMPLETE`、PREPARED 或 state-only `STATE_PREIMAGE_COMPLETE` 只要证明零 target/state/claims primitive，才允许生成 reviewed `recover abandon` 计划；不完整 receipt/state preimage 作为绑定 evidence 保留/隔离后才能释放 reservation。
- 任一 live target 已调和为 OLD_MOVED/NEW_INSTALLED、或首次 **HomeAuthority** claims 已创建但 shared state postimage尚不存在时，只允许生成 `live-recover-rollback` 计划，按磁盘实态逆序恢复所有 touched targets/claims；不允许 forward resume 创建 state。本行不适用于 4.2 已冻结的 canonical setup global-claim→setup-state 特例，后者只能用其外部 `canonical-recover-finalize` 计划发布 plan 已预绑定的 exact MISSING setup-state。
- receipt-backed state postimage 已存在但 transaction `Phase=COMPLETE` record 缺失时，只有 state、state recovery copy、claims、live postconditions、plan、receipt、journal chain与固定 `result.json` 全部一致才允许 `recover finalize`。若 matching terminal-intent result已存在，finalize必须原样保留其 `Outcome`；若 result为 MISSING，reviewed recovery plan只绑定唯一 expected semantic projection与其 action决定的 Outcome，并在其 recovery intent 发布后按actual head构造/验证 result。否则进入 rollback/manual-recovery-required。state-only controller transition 则按 4.4 的独立优先级验证 `NO_LIVE_MUTATION`、state preimage/file tuple、claims、controller、plan 与 journal，既不要求也不允许 receipt。
- recovery Apply 前重算 recovery plan 绑定的全部 hashes/identities；任一 drift 拒绝。status/recovery plan 是只读的，不根据 journal 自动 resume mutation。

所有 swap/recovery helper 使用 cleanup-on-success。在 shared state primitive 之前捕获 mutation failure 时，持有 lock立即逆序恢复本次所有 completed targets且不继续下一平台；旧 state/live/claims全部重验后发布 `Phase=COMPLETE, Outcome=failed-restored`，命令以 `apply-failed-but-restored` 非零退出。shared state reviewed postimage已提交后就是 live commit boundary：后续 record/result publish failure不得自动改写/恢复 state或 live，只保留证据并进入 reviewed finalize（语义/tuple无效时再按唯一矩阵 rollback/manual）。恢复失败时不得在 `finally` 中删除旧 live、rollback、quarantine 或 pre-rollback snapshot。结果区分 `apply-failed-but-restored` 与 `recovery-required`，并报告可恢复目录和 journal。

### 4.5 Environment、lock 与 task overlay

环境锁升级为 schema 3；现有 repo-local state 已经是 schema 2，因此新的 shared authority state 也升级为 schema 3，不能复用版本号。artifact 的生成时点与引用方向固定如下，后生成者只能引用更早 artifact，不允许循环或 self hash：

| Artifact | 生成时点 | 核心字段与引用 |
|---|---|---|
| `env.lock.json` schema 3 | environment materialization 后、DryRun 前 | environment/definition hash；Claude、Codex、Reasonix manifest/source/materialized hashes；三平台完整 `TaskOverlaySkills` 与 overlay hash；文件本身不存 `LockHash` |
| reviewed operation plan | DryRun | execution context、actions/preconditions、整个 lock file hash、authority-before hash、PlanHash/DocumentHash；不含 receipt/journal/state ref |
| backup receipt | Apply pre-mutation | reviewed PlanHash/DocumentHash、execution-context hash、actual targets、pre-change/snapshot hashes |
| live transaction reservation/journal | receipt 前以 `RESERVED` 开始 | plan ref、HomeAuthorityKey、root-claim reservations、targets；receipt 后加入 receipt ref、write-ahead actions与每个 phase/result；不被 receipt snapshot hash 包含；state commit 前形成 `PreStatePhaseHash` |
| immutable `root-claims.json` v1 | 首次 initial/migrate/adopt 的 live postconditions 后、state create 前 | `RESERVED` 中已绑定的三平台 stable locations；create-new 后永不 replace；文件自身不存 hash，state 引用完整文件 hash |
| shared authority state schema 3 | postconditions 全部成功后 | HomeAuthorityKey、FinalResolvedIdentities/FinalTargetContextHash、独立 root-claims hash、active selection、controller repo fingerprint、approved toolchain hash、plan/journal/final managed hashes；operation discriminator 决定 receipt/state-only 字段形状 |

state schema 只允许 `SelectionKind=environment`，因此 EnvironmentName/EnvironmentLockHash/TaskOverlayHash 与三平台 baseline 始终存在；pristine initial 选择 named `full`，不存在无 lock/task postset 的 orphan selection。receipt-bearing live operations（initial/environment/task-overlay/migrate/adopt/repair-adopt/retirement/environment-rollback）要求 ReceiptId/ReceiptHash；`LastOperationKind=controller-transition` 保留原 selection 字段但要求 `ReceiptRef=NO_LIVE_MUTATION`。recovery finalize保留原事务的 reviewed poststate，recovery rollback恢复其 prestate，因此 state没有 `live-recover` branch。state commit 后，journal complete record 再引用 `AuthorityStateHash`。`AuthorityStateHash`/execution context 中的 `SharedAuthorityStateHash` 都是完整 canonical state file bytes 的外部 SHA-256，不存入 state 自身。state 只引用 commit 前已经固定的 journal phase hash，因此引用图没有 state↔final-journal hash 循环。

DryRun plan 只能绑定 `AuthorityStateIntent`（selection/controller/root-claims/final managed 等当时已知的语义字段）与 plan-only `TargetContextIntent`：每个 stable location、existing identity 或 `ABSENT`、最深 parent identity/remainder、expected post-existence。shared state 不复制 `TargetContextIntent`；它只引用 immutable RootClaimsHash并保存 Apply 派生的 `FinalResolvedIdentities/FinalTargetContextHash`。plan 不能预造尚不存在的 ReceiptId/ReceiptHash、JournalId/PreStatePhaseHash、`FinalResolvedIdentities`/`FinalTargetContextHash` 或 final state hash。Apply 在 receipt、pre-state journal phase及缺失 root 创建完成后，用同一 resolver验证 stable locations/parent chain未漂移，计算 final identities/context hash，再由 trusted serializer合并这些 runtime fields。state semantic validator证明去除明确列出的 runtime fields 后与 reviewed AuthorityStateIntent 完全相同，并证明 final identities恰由 reviewed plan-only TargetContextIntent 的路径/postconditions派生，才允许 state replace。

`ControllerRepoFingerprint` 只由去除 credentials/userinfo 的 normalized remote identity 与 4.2 已定义的 deterministic machine-private RepoId 组成；Phase 3不得另造RepoId producer。linked worktrees共享repo id，fresh clone不共享。approved toolchain hash作为独立plan/state precondition更新，不改变controller identity。真正的controller repo变化不会被当成无state，而是要求显式takeover plan。

shared authority state 只能在三平台 Apply 与 postconditions 全部成功后通过同目录 create-new temp + flush，再对 existing state 使用 OS atomic file-replace（同时保留 recovery copy），或对首次 state 使用 atomic rename；替换失败时旧 state 保持。首次 authority 先把 proposed claims 作为独立 journal target create-new，再创建引用其 hash 的 state；两者之间 hard-kill 只允许 reviewed rollback，不能 forward resume、把孤立 claims 当成 complete authority或自动删除。只有 state postimage 已经落盘且全部 postconditions 可重验时才可能 reviewed finalize。backup 成功但 mutation 或 recovery 失败时不得写入新 state。新实现停止写 repo-local `state/current-env.json`，也不静默删除 legacy file。

旧 lock/state 仍可只读解析并显示 `migration-required`，但迁移不是普通 Apply 的隐式例外：

- `env list/status/build` 可工作并给出 legacy schema、缺失字段和候选 HomeAuthority/root claims。
- `env authority status [-ReasonixLiveSkillsPath <absolute>]` 是唯一允许为**尚无schema 3 claims**提供 intended custom Reasonix root的只读路由入口；它只用 `MetadataOnly` resolver/forbidden-root规则检查default或intended root的空/非空inventory并在结果中绑定 `RequestedInitialRootContextHash`，禁止 capability probe、temp/probe slot或任何 filesystem write。已有claims时一律拒绝该switch并直接从claim解析root；repair/takeover/ordinary路径也不接受它。随后initial/migrate/adopt DryRun必须传入同一optional root，重算同一 metadata-only hash，再另跑 `MutationPreflight` 并绑定 `FilesystemCapabilityHash`，避免status看不到custom非空root而误报pristine initial。
- Git hook 与 automatic task sync 只生成 migration diagnostic；普通 full/env/task live Apply 全部 fail-closed。
- `migrate` 的 legacy core 必需字段固定为：`SchemaVersion=2`、非空 `Name`、可规范化且匹配 HomeAuthorityKey 的 absolute `HomeRoot`、有效 `DefinitionHash/LockHash/RepositoryCommit/TaskOverlayHash`，以及 Claude/Codex/Reasonix 三项 `ManifestHashes`。RepositoryCommit/LockHash 必须与当次旧 activation lock/evidence 内部一致，但不要求等于当前 HEAD；HEAD 已前进记录为 `LegacyDrift=RepositoryCommitAdvanced`，只有旧 live parity可验证且已另行生成当前 HEAD 的 fresh named-environment lock时才可 migrate。core valid但旧live parity失败时唯一为`manual-recovery-required`，不能降级adopt覆盖相互矛盾的可信evidence。`TaskOverlaySkills.Claude/Codex` 必需；已确认迁移缺陷导致的 `TaskOverlaySkills.Reasonix` 缺失记录为 `LegacyGap=ReasonixBaselineMissing`，只允许进入显式 migration，不允许 addition-only/automatic removal 判断。legacy `BackupReference` 仅作不可信 evidence，不作为恢复来源。
- 只有 `env authority migrate <name> -LegacyStatePath <path> -DryRun -PlanPath <new>` 可以在上述 core 全部可验证时生成迁移计划；计划绑定 legacy file hash、LegacyGap、当前 live inventories、目标 schema 3 lock 与所有预计 actions。
- `... -Apply -PlanPath <reviewed>` 在 shared operation lock 内完成 backup、三平台 mutation、postconditions 后直接写 schema 3 shared state；任一步失败保持 legacy state 原样且不产生新 authority。
- 任一 legacy artifact存在但core字段缺失/不匹配时，无论live为空或非空都路由到更显眼的 `env authority adopt` reviewed plan并把旧bytes标为UNTRUSTED；无legacy artifact但live非空也adopt；只有无legacy/claims且全部live pristine时才initial。adopt不信任 legacy baseline，以实际 live inventories 对完整目标 lock 生成 actions。
- schema 3 state bytes 无法验证或state entry MISSING、但独立 root-claims 文件完整且实际 identities 匹配时，只允许 `env authority repair-adopt`。CORRUPT分支要求`<name> -CorruptStatePath <exact-ControlBase-state>`并绑定raw bytes hash/preimage；MISSING分支要求显式`StateEvidence=MISSING`、禁止path/hash。两者都绑定claims hash/current live/fresh selected lock，且原坏文件存在时保留到reviewed recovery完成。root-claims 自身无效或有 overlap 时进入 `manual-recovery-required`，普通 adopt/takeover/Apply 均不能绕过。
- shared authority 已由另一 repo 控制且 authority/lock/live parity全部有效时使用 `takeover` plan，原子更新 controller metadata且不组合 live mutation，receipt ref使用显式 `NO_LIVE_MUTATION`。若有 unfinished transaction先 recovery；若无 journal但 controller mismatch且 parity失败，status唯一返回只读 `controller-owner-action-required`，不错误推荐 recovery/adopt/takeover，只有已登记 controller可先用正常 environment dry-run/Apply恢复 parity，或未来另做 takeover-with-repair设计。state replace/finalize失败时旧 controller state保持或进入 reviewed finalize；成功 takeover后另行生成 environment plan。

Reasonix baseline 缺失不再按空集合处理。即使未来恢复某种自动化，removal 判定也必须以三平台完整 baseline 为前提；本设计中 Git hook 始终 preview-only，actionable plan只能由显式external DryRun产生。

task overlay 同时涉及 tracked worktree file 与 live/state。它遵守统一顺序 **Git-common-dir canonical lock → worktree/repo overlay lock → global live lock**；普通live无overlay目标时跳过中间锁，但不能跳过首尾。锁内重算repository/materialization、tracked overlay prehash与live plan。Git/editor不遵守advisory lock时，replace前后的外部修改由identity/hash/postcondition检测为stale或recovery-required，绝不静默覆盖，并通过canonical-vs-live、并发编辑/checkout/死锁测试验证。

### 4.6 Schema、CI 与安全文档

新增固定入口 `scripts/validate-json-artifacts.ps1`，local、artifact emitter 与 CI 共享同一个 adapter：

- `-All -JsonSummaryPath <path>` 验证 contract registry 中的 tracked schemas/fixtures 和本轮标准 generated fixtures。
- `-ArtifactManifestPath <path> -JsonSummaryPath <path>` 验证本次运行产生的 Git-private/temporary/external artifacts；manifest 中每项包含 `ArtifactKind`、完整 path、expected schema id 和 content hash，manifest 自身位于 tracked working tree 外并先按 `artifact-validation-manifest.schema.json` 验证。repository validation 使用无环的两层结构：先发布 `ManifestRole=children` 的 child manifest（只列 child outputs，不列自身或 repository summary），repository summary绑定该 child manifest hash；最后发布 `ManifestRole=final` 的 final manifest，列出 child manifest、全部 child outputs与 repository summary，但不列自身。summary绝不引用 final manifest。
- emitter 可为单个输出生成临时 artifact manifest 后调用同一入口；不存在“根据文件名猜 schema”的 fallback。

validator 必须完整支持仓库声明的 JSON Schema Draft 2020-12；具体 library 在执行计划的首个兼容性 spike 中选定后，把 name/version/package hash 固定到 `tools/schema-validator/validator.lock.json`。validation 运行时不联网、不动态安装，依赖缺失或 lock/hash 不匹配即 fail-closed。仅 `ConvertFrom-Json` 不算 schema validation。

本轮“所有 artifact”严格限定为以下 producer→schema contract，不隐含扩大到 inventory/analyze/MCP/project-profile 等未修改输出：

| Producer / artifact | Schema |
|---|---|
| canonical transaction/recovery plan/result/journal chain | 新增 `canonical-transaction-plan.schema.json` / `canonical-recovery-plan.schema.json` / `canonical-transaction-result.schema.json`，以及 `canonical-journal-header.schema.json` / `canonical-journal-record.schema.json`；head hash由连续 published records推导，无 head artifact |
| sync/env/task/authority-transition reviewed plan | 升级 `sync-plan.schema.json`，以 `OperationKind` oneOf 严格区分 initial/environment/task-overlay/migrate/adopt/repair-adopt/controller-transition/retirement；不含 full-repo/environment-rollback，也不含任何 `live-recover-*` PlanKind |
| backup receipt | 新增 `backup-receipt.schema.json` |
| environment rollback/live recovery plan | 新增 `rollback-plan.schema.json`；`PlanKind` 严格为 environment-rollback/live-recover-abandon/live-recover-rollback/live-recover-finalize |
| live activation/recovery journal chain | 新增 `live-journal-header.schema.json` / `live-journal-record.schema.json`；header/record 以 TransactionMode oneOf 区分 receipt-backed 与 controller state-only chain，head hash只读推导 |
| live/authority/rollback/recovery operation result | 新增 `live-operation-result.schema.json` v1；`ResultScope=command|transaction` oneOf严格分离exact CommandKind响应与authoritative fixed result；transaction scope只用header原始OperationKind，recovery command用exact recovery PlanKind且不能污染fixed result，供sync、environment、task、authority、retirement、rollback、recovery复用 |
| immutable HomeAuthority root claims | 新增 `root-claims.schema.json` |
| shared authority state | 新增 `current-env-state.schema.json` |
| hook pending/diagnostic event | 新增 `pending-sync-event.schema.json` |
| runner approval event / approved pointer state | 新增 `runner-approval-event.schema.json` / `approved-runner-state.schema.json`；create-new approval与atomic pointer均绑定commit、ToolchainPolicyHash、runner tree hash和Git-private identity |
| committed data snapshot manifest | 新增 `committed-data-snapshot-manifest.schema.json`；绑定allowlisted pathspec、Git mode/OID、no-follow materialized content hashes与source commit，拒绝symlink/gitlink/alias |
| canonical setup state | 新增 `canonical-setup-state.schema.json` v1；create-new/immutable绑定ClaimId、CanonicalRecoveryRoot resolved identity、filesystem capability与repo/common-dir identity，不改变approved-runner-state版本 |
| global canonical-root claim | 新增 `canonical-root-claim.schema.json` v1；位于ControlBase，create-new/immutable绑定RepoId/GitCommonDir、三个private-root intent、`SetupIntentHash`与`ExpectedSetupStateProjectionHash`，供所有live/canonical planner在global lock内枚举；Apply-derived final setup-state反向绑定其`RootClaimHash` |
| pending-plan prune plan | 新增 `pending-prune-plan.schema.json` v1；绑定 exact Git-private source/destination/hash set与 registry snapshot，不允许 Apply重枚举 |
| filtered secret-scan input manifest | 新增 `scan-input-manifest.schema.json` v1；绑定 SourcePolicyHash、ordered normalized path/length/content hash与 no-follow/ADS/hardlink identity evidence，明确四个 protected paths 不可出现 |
| env build/lock/list/status | 现有 `harness-env-build`、`harness-env-lock`、`harness-env-list`、`harness-env-status` schemas 升级并与 emitter 对齐 |
| doctor/secret-scan/run result | 现有 `doctor-report`、`secret-scan`、`run-report` schemas |
| unified test summary | 新增 `test-run-summary.schema.json` |
| artifact-validation manifest/summary | 新增 `artifact-validation-manifest.schema.json` / `artifact-validation-summary.schema.json` |
| repository validation summary | 新增 `repository-validation-summary.schema.json`；`ReportKind=repository-validation`，逐项绑定全部 named gates、`ManifestRole=children` 的外部 child artifact manifest、clean-state/parity 证据与总结果；随后由 `ManifestRole=final` manifest绑定该 summary，形成无环 DAG |

`schemas/artifact-contracts.psd1` 记录 producer、schema、positive fixture、negative sentinels 与可选的命名 semantic validators。所有新增/升级 contract 都有必需的正整数 `SchemaVersion`：lock/shared state 使用 3，其余新 artifact 从 1 开始，registry 记录唯一 accepted version。每个 emitter 在报告成功前先做 fixed-schema bootstrap validation，再执行 registry schema + semantic validators；CI 通过 artifact manifest 独立复验。negative cases 标注 `FailureLayer=Schema|Semantic`，至少包含缺 Reasonix、固定三平台/action key 重复或乱序、未知字段、错误 version、tampered hash/reference graph、manifest role/DAG cycle 和 prohibited reference。wrapper 在启动外部 validator 前扫描完整 schema：`$schema` 只允许 exact Draft 2020-12 dialect URI且不得联网解析；`$id` 只允许与当前 basename匹配的 `https://ai-agent-dotfiles.invalid/schemas/<name>` non-fetching identifier；protocol v1 的 `$ref` 只允许同文档 `#...` fragment，禁止 cross-file/URI/absolute/drive/UNC/`..`；`$dynamicRef`/`$dynamicAnchor` 及其它动态解析关键字一律禁止。schema file本身必须是 approved SchemaRoot内 canonical regular file且无 reparse/hardlink/identity race，因此 validator永不打开 schema root外或四个 protected Reasonix路径。validator manifest/summary 自验直接调用固定 schema primitive，不递归生成另一份 manifest/summary。child/final manifests均不列自身；final manifest只向后引用已发布的 child manifest、children与summary，semantic validator拒绝任何反向引用、自引用或遗漏。

secret scan 不再把 RepoRoot直接交给 fallback scanner或 gitleaks。Phase 0先以 no-follow/identity-aware walker按 tracked+non-ignored policy构建 external filtered `ScanInputRoot`：在打开普通文件前排除四个 literal `.reasonix/desktop-topic-*`，拒绝任何 reparse entry、multi-link hardlink、重复/受保护 file identity或越界路径，再让两种 scanner只消费该 materialization及其 manifest。这是 no-read privacy boundary，不是 repository secret allowlist；access-time/access-denied与 alias-to-protected sentinels证明四文件/外部目标从未打开，相邻普通文件仍被扫描。排除/输入规则只能在用户依 AGENTS明确批准后实施。gitleaks binary也必须由独立 lock记录 approved version/asset/hash并安装到 approved cache；runner只调用该绝对路径，禁止 PATH discovery/shadow。`.gitleaks.toml`、scan input policy、gitleaks lock/installer/binary hash与 fallback scanner全部进入 ToolchainPolicyHash。

新增固定入口 `pwsh -NoProfile -File scripts/run-tests.ps1 -All -JsonSummaryPath <path>`：

- 按稳定顺序枚举所有 `tests/*.tests.ps1` 并逐个在新 PowerShell 进程运行。
- 任何测试文件未执行、重复、超时或非零退出都导致 CI 失败。
- summary 包含规范化 discovery snapshot/hash、唯一 `SuiteId` 列表、每项 started/completed/timed-out/tree-killed 状态、exit code、duration/result，以及 discovered/started/completed/passed/failed/timed-out/duplicate/missing/tree-kill-failed aggregate counts；`Result=PASS` 要求 exactly-once 且所有 counts 满足 schema invariants。
- default timeout 与少数 suite override 只在 committed `tests/test-timeouts.psd1` 中配置，不作为 suite include list；超时终止整个进程树并以非零结果记录。
- timeout sentinel 必须启动 child 与 grandchild heartbeat；runner 超时后验证整个进程树均退出，不能只记录已调用 `Stop-Process`。
- GitHub Actions 调用 runner，不再手工维护容易遗漏的测试文件列表；runner 只替代 test-suite 枚举，现有 PowerShell parse、build/scan、doctor、generated parity、dangerous-file policy 和 schema gates 继续独立执行。
- 本轮 CI 只使用一个 unified-runner job，不引入 shard/discovery/aggregate artifact 分支。runner 计算并在 summary 中记录 `RequiredJobTimeoutSeconds = SetupAndNonSuiteBudgetSeconds + sum(Suite.TimeoutSeconds) + MarginSeconds`；workflow 的 `timeout-minutes` 换算后必须严格大于该值，否则 policy test 失败。

live-protocol interlock 不靠 public `-TestMode` 绕过。production CLI adapter 与测试都调用不导出的 internal transaction host；tests-only controller 只能通过 internal factory 获得指向新建 isolated temp root、明确不在真实 HomeRoot/ControlBase 下的 sandbox capability。failpoint provider 在 `after-backup`、`before/after-swap:<platform>:<skill>`、`before/after-state-commit` 等命名 checkpoint 通过 pipe/event 通知外部 controller 并阻塞；controller 等到确切 checkpoint 后 `Stop-Process -Force`，再以新进程验证 journal/recovery。测试不依赖 sleep 碰撞窗口，也不允许任意 `-HomeRoot` 自动获得测试权限。

安全文档只同步实际行为：

- `AGENTS.md`、`CLAUDE.md`、README/onboarding/restore 明确三平台、bootstrap/hooks 只能产生不可消费的 preview/event，并且 actionable plan 只能由显式 `ExternalUserArtifact` DryRun 产生。
- `.claude/settings.json` deny 覆盖 `reasonix/skills/**` generated output。
- `STATUS.md` 只记录当前可验证事实，将退役平台的历史操作移回 archived/history 语境。
- `.reasonix/desktop-topic-*` 从 Git index 解除跟踪但保留本地文件，并加入 ignore；不读取或删除用户的 desktop state。

## 5. 实施阶段与依赖顺序

### Phase 0：入口止血

- 先添加 hook/bootstrap/active-env guard 的失败测试。
- 在运行任何 repository scan/diff 前先落地四个 Reasonix desktop-state路径的 exact no-read input policy；所有 Phase 0–3 staged/unstaged/status checks只使用这四个 literal negative pathspec，禁止 broad `:(exclude).reasonix/**`。第五个/相邻普通 `.reasonix` 文件必须仍被扫描并出现在 clean-candidate gate；仅四个 protected leaf做显式 metadata 检查。
- 将 bootstrap 和 Git hooks 改为 non-consumable-preview-only，并打印显式 external DryRun命令。
- 安装 Git-private pinned runner，并让脚本/toolchain 变更进入 runner-review-required。
- 在开发分支引入无 public override 的 live-protocol interlock：Phase 2–4 的 target resolver、shared authority、lock、receipt 与 schema contract 未全部就绪前，所有 production live Apply/rollback 以及 standalone `backup.ps1` 的任何 snapshot-creating invocation都以 `safety-protocol-upgrade-required` 失败；后者必须在遍历 live tree、打开 `.system` child或创建 BackupRoot前退出。status、DryRun、isolated/fake-home test 仍可运行。
- 对 custom Reasonix root、shared authority 缺失但 live 非空、legacy state 和 direct full sync 先提供明确诊断，不允许旧 Apply 路径继续执行。
- 完成 schema-validator compatibility spike，固定 validator adapter 的 runtime/version/hash，后续每个 phase 同步提交自己的 schema 与 negative fixtures。
- 先落地按 `tests/*.tests.ps1` 自动发现的统一 runner、timeout/process-tree 基础与 CI exactly-once gate，确保 Phase 1–3 新增 suite 不会在实现期间被静默漏跑；Phase 4 再完成全量契约收口。
- 同步更新 `AGENTS.md` 与 bootstrap/onboarding 的入口命令，避免安全行为与操作说明在 Phase 0 后继续冲突；Phase 0 doctor同时移除对 `.system` child marker的探测，只保留 root entry自身的no-follow marker。
- 验收后再进入任何其它写路径修改。

### Phase 1：Canonical source 事务

- 先引入 RFC 8785 semantic JSON、target identity resolver 与 SafeTreeWalker 的共享只读基础和回归向量；canonical/live 后续路径只复用这一套。
- 修复 Reasonix classification/normalize 回归。
- 引入 isolated preflight、显式 mode 和 transaction journal。
- 将 canonical、managed generated 与 manifest targets 一起纳入 byte-preserving commit/recovery。
- 让 normalize/promote/auto-merge 共用事务入口。

### Phase 2：Plan、backup 与 rollback

- 引入 execution context、semantic plan hash 和 saved-document rehash。
- 前移 shared state schema 3 的最小 discriminated contract、独立 root-claims reader 与 generic state-target/failpoint primitive；Phase 3 只补 transition semantics，避免 live recovery 依赖未来 artifact。
- 将 Phase 1 resolver/SafeTreeWalker 扩展到 actual live targets，并引入 stable HomeAuthority/global root claims、real-Apply hard gates 和 current-user global live-mutation lock。
- 统一 actual live roots，补齐 Reasonix custom target backup。
- 将当前一次性 retirement manifest 升级为正式 `retirement` operation，复用同一 execution context、receipt、journal、SafeTreeWalker 与 recovery；不保留 flag-only 旁路。
- 引入 unique backup receipt、backup content binding、durable journal、crash detection 和 cleanup-on-success recovery。

### Phase 3：Environment 与 task overlay

- 冻结当前完整三平台 env-lock schema 3；新增独立 shared authority state schema 3，停止把 clone-local state 当权威。
- 三平台 baseline 完整写入，并完成 plan-bound migrate/adopt/repair-adopt/takeover transition。
- activation 直接消费本次 sync receipt，不再选择“最新备份”。

### Phase 4：CI、schema 与安全契约同步

- 扩展 Phase 0 validator registry，真正校验 Phase 1–3 的全部 emitted artifacts。
- 收口 Phase 0 自动发现 runner/CI，验证全部 suites exactly-once 并保留所有非-suite gates。
- 更新其余安全相关文档和 Reasonix generated guard。
- 解除跟踪 `.reasonix/desktop-topic-*`，保留本地内容。
- 全部 interlocked fake-home、hard-kill、schema、CI 与文档契约通过后，只有另获用户 Git 授权才能创建一个包含 `ReleaseState=released` 的 reviewed release-candidate commit。public mutation测试只能在 disposable OS identity 中 clone 并运行该 **exact commit**；policy bytes/ToolchainPolicyHash 不得在 clone 内再改。失败时拒绝该 commit并创建新的 reviewed candidate，不能用 dirty patch 冒充已测版本；旧协议计划仍然不能 Apply。

各 phase 必须独立通过相关回归与当期 artifact schema 后才能进入下一阶段。Phase 0 可以单独作为“关闭危险 Apply”的止血发布；Phase 1–3 不能作为 live-capable partial release，Phase 0–4 构成一个安全协议 release unit。实现期间仍不授权真实 live Apply。

## 6. 验证矩阵

### 6.1 Canonical source

- incompatible Reasonix input 返回 quarantine，目标不存在时不报 `Remove-Item` 错误。
- existing target 成功替换且无 nested input/stale files。
- tracked manifest 已有用户 dirty bytes 时 canonical transaction 在 mutation 前拒绝，不覆盖或“恢复”用户变更。
- candidate/postcondition build/scan 失败或 hard-kill 时，canonical targets、managed generated targets 和 manifests 由 recovery copies byte-for-byte 恢复；documented runtime-exclusion/unknown generated files从未触碰。
- auto-merge batch 中任一候选失败时零 canonical partial commit。
- normalize/promote/merge 缺少显式 mode 时拒绝。
- 两个 canonical Apply 由 Git-common-dir repo lock 串行化；loser 为 lock-busy 或取得锁后 plan-stale，不能交错 swap/recovery。
- 在 old→swap-old rename 后但 `OLD_MOVED` 落盘前、staged→target rename 后但 `NEW_INSTALLED` 落盘前 hard-kill；下一进程以 target/swap-old/staged tuple 加独立 immutable preimage 调和 intent-only journal、拒绝新 mutation，并由 reviewed recovery plan 恢复。
- canonical recovery 的 checkpoint→唯一结果矩阵固定为：`PREPARED`/`FILE_PREPARED` 且零 primitive 为 abandon；old→swap-old 已发生但 `OLD_MOVED` 未落盘为 rollback；staged→target 已发生但 `NEW_INSTALLED` 未落盘为 rollback；atomic file replace/move 已发生但 `FILE_REPLACED` 未落盘为 rollback；全部 targets 已安装但尚无 flushed `POSTCONDITIONS_OK` 为 rollback；已有 flushed `POSTCONDITIONS_OK` 但尚无 COMPLETE 为 finalize；tuple/preimage/record-chain 无法唯一调和为 manual-recovery-required；已有 COMPLETE 为 clean 且旧 recovery plan stale。每个 rename/replace 与 result-record flush 间都必须有 hard-kill failpoint。
- 清理 CandidateWorkspace 或重启进程不删除 Git-private journal/CanonicalRecoveryRoot，恢复完成后才 cleanup-on-success。
- canonical input/managed tree 中指向 `.system`、ControlBase 或任意外部目录的 junction/symlink，以及指向外部文件的 hardlink sentinel，均由 SafeTreeWalker 在读取 target content 前拒绝。

### 6.2 Hook、sync 与 environment

- fresh clone 首次 bare bootstrap 只安装 inert wrapper并产生 validator/scanner/runner approval diagnostics、零 live write；显式安装 pinned validator与 pinned gitleaks scanner并批准 runner 后，下一次bootstrap先返回canonical recovery/setup status。setup缺失时只产生`canonical-setup-required`；独立setup DryRun/review/Apply成功后的又一新bootstrap才可能生成pending preview与external actionable DryRun命令。
- 未显式 install/approve 的 inert hook 只产生 `validator-install-required`、`scanner-install-required` 或 `runner-review-required`，不能下载、批准、扫描或计划；scanner cache缺失、hash/version漂移与 PATH shadow 均是 scanner diagnostic且零 artifact/live write。
- post-merge/post-checkout/post-rewrite 在canonical-ready后对 add/update/prune 产生不可直接Apply的 pending preview/event、零 live write；setup/recovery未就绪时只产生对应diagnostic。
- checkout 中的 runner/toolchain 脚本变化不会被 hook 执行，只产生 runner-review-required。
- active environment 下 hook 生成 matching environment preview和external DryRun命令；无claims/pristine时生成initial preview；无claims/non-empty时adoption diagnostic；legacy时migration diagnostic；valid claims配CORRUPT/MISSING state时repair-adopt diagnostic；corrupt claims/manual状态只返回manual-recovery-required。任何分支都不生成错误full plan或可直接消费的Git-private Apply plan。
- active `work/minimal/full` 下 direct full sync Apply 拒绝。
- 第二个 clone/linked worktree 读取同一 shared authority；fresh clone 不能把缺少 repo-local state 当成无 active state，controller change 要求 takeover plan。
- matching env/task context 可生成不可消费的 preview/event和精确 external DryRun 命令；只有该显式 DryRun 才生成 actionable plan，wrong lock/name/overlay/context 一律拒绝。
- Claude、Codex、Reasonix add/update/no-op/prune/unknown parity 均有 fake-home 断言。
- Codex `.system` 和三平台 unknown directories 始终保留。

### 6.3 Task overlay 与 authority transition

- Reasonix add 写入 lock/state baseline。
- Reasonix add 后 removal 被识别为 removal，并保持 manual-review-required。
- 缺任一平台 baseline、旧 schema 或 invalid lock 时 fail-closed。
- core 完整但 Reasonix baseline 缺失的 schema 2 state 生成带 `LegacyGap` 的 migrate plan；成功后 receipt、schema 3 state、controller 与三平台 baseline 精确匹配，失败不写 authority。
- 表列每个 legacy core 字段逐项缺失/错误时均路由 adopt，不误入 migrate；adopt 成功/失败分别验证 receipt/state 与 recovery。
- takeover parity valid 时只改变 controller metadata且 `NO_LIVE_MUTATION`；controller mismatch + parity invalid + no journal时唯一只读 route为 `controller-owner-action-required`，不伪造 recovery/adopt。state/finalize failure保持旧 controller或进入 recovery finalize。

### 6.4 Plan、backup 与 rollback

- 修改保存 plan 的 actions、paths、metadata 或 `GeneratedAtUtc` 但保留旧 `DocumentHash` 时拒绝；只伪造 `PlanHash` 也拒绝。
- action type/name 集合保持不变、但任一 lock/state/toolchain/root-claims/manifest/source/live precondition hash 改变时，current `PlanHash` 必须变化并拒绝 Apply。
- DryRun 与 Apply 必须是两个 invocation 并消费同一 create-new PlanPath；Apply 缺 plan 或隐式生成 plan 时拒绝。
- RFC 8785 canonicalization/path-identity test vectors 在不同进程、路径大小写/分隔符和 property order 下产生确定 hash。
- source/live/manifest/active state drift 后拒绝。
- reviewed plan 不能用于另一 HomeRoot 或不同 live roots。
- custom Reasonix live root 被准确备份、应用和失败恢复。
- retirement manifest 只在显式 reviewed `OperationKind=retirement` 中生效，并绑定 shared authority、active selection/lock postset、external manifest bytes、canonical absence、target hashes、receipt、state postimage 和 journal；selected target 以 `retirement-selection-conflict` 拒绝，普通 sync/hook 不能采用它。一次成功后即使重建相同 live bytes，旧 plan 也因 authority generation/receipt/journal context 变化而不可重放。
- backup tree 内容变化、receipt 变化或 receipt/plan 不匹配时拒绝 rollback。
- receipt snapshot hash 排除 `_meta`，MISSING/unknown/`.system` 范围符合契约，半写或无 COMPLETE marker 的 receipt 不可消费。
- activation receipt 持久绑定前一 authority state/root-claims 的精确 bytes 或 MISSING marker；rollback plan 必须绑定这些 immutable preimages，且 pre-rollback receipt 另行保存当前 live/state/claims。缺失、篡改或与当前 generation 不匹配时 rollback 在 mutation 前拒绝。
- live managed/snapshot/recovery tree 在 DryRun 后注入 reparse/hardlink 时，Apply/rollback 因 walker/identity drift 拒绝且不越界读取或写入；unknown/`.system` 只做 no-follow marker。
- 并发/同秒 backup 不复用目录，activation 使用精确 receipt。
- 同一用户的并发 live Apply 被 global lock 串行化，不能交叉 root-claim/backup/mutate/state commit；第二操作取得锁后必须重算 plan。
- public zero-wait loser以`operation-lock-busy`且零backup退出，public `-LockWaitSeconds`被拒绝；sealed isolated host中的bounded-wait loser在winner完成后以`reviewed-plan-stale`且零backup退出；owner hard-kill后只进入recovery-required。
- absent→created root 不改变 HomeAuthorityKey；已有 authority 上的 default↔custom Reasonix 变更以 `root-transition-not-supported` 且 old/new 零写入退出；initial/migrate/adopt 可直接建立 custom claim；两个部分重叠 root sets 被 global claims 检查拒绝。
- 注入 swap/recovery failure 后保留所有最后副本与 journal。
- 在 backup、每个 rename primitive 成功但 result record 未落盘、state file replace 前后 hard-kill 子进程；重启后按磁盘 tuple 只允许合法 abandon/rollback/finalize 或 manual-recovery-required，并验证 `apply-failed-but-restored` 与 `recovery-required` 分类。

### 6.5 Schema 与 CI

- 4.6 producer→schema 表内的每种 artifact 通过 schema positive validation。
- 缺 Reasonix、固定三平台数组重复、duplicate/乱序 action key、未知字段和 registry 不接受的 schema version negative fixtures 由其声明的 schema 或 semantic 层失败。
- CI 单一 runner job 发现并运行 `config-sync.tests.ps1` 及所有未来新增 suites；本轮不生成 shard/aggregate artifact。
- CI summary 中 suites discovered、executed、passed 数量完全一致且 failure 为零。
- unified runner 替换 suite 枚举后，parse/build/scan/doctor/parity/dangerous-file 等非-suite gates 仍被 CI 执行。
- timeout sentinel 的 child/grandchild 均被终止，test summary 的 discovery snapshot、unique SuiteId 与 aggregate counts 证明每个 suite exactly-once。

## 7. 真实机器 rollout

实现阶段只运行静态检查、isolated repository、fake-home 和 schema/CI 测试，不修改 live home、shared authority state 或 legacy repo-local `state/current-env.json`。

实现全部通过后：

1. 运行真实只读 doctor、hook status、config status、env status、task status、`canonical recover status` 与 `live recover status`；任何 unfinished transaction 先进入对应 recovery route。
2. 运行零写入 `agent-dotfiles.ps1 canonical status` 检查 exact common-dir setup-state/global claim。若返回 `canonical-setup-required`，生成并人工审查 `agent-dotfiles.ps1 canonical setup -DryRun -PlanPath <new>`，随后停止并等待独立 setup Apply 授权；setup 成功后必须在新的 invocation 从头重跑只读 status，不能在同一命令继续 live route。
3. setup 已完成后，运行 `env authority status` 决定唯一合法 live 路由：已有有效 schema 3 authority且 controller匹配才能普通 activate；schema 2 core与旧live parity均可验证才migrate，core valid但parity失败为manual；legacy artifact存在但core坏时无论live是否为空都adopt，无legacy但live非空也adopt，只有完全无legacy/claims且live pristine才initial；schema 3 state坏或MISSING但claims有效则repair-adopt；claims坏则manual recovery；不同 controller且 parity有效才takeover，不同 controller且无 journal但 parity失败则 `controller-owner-action-required` 并停止。
4. 仅对需要 environment selection 的 route，由该 authority/activation DryRun命令内部以 current HEAD 创建唯一 external EnvironmentMaterializationRoot、运行 env-build v3并把 exact root/artifact/lock绑定进同一 plan；不接受未绑定的预构建 lock，也没有第二个 CLI handoff路径。`migrate` 必须直接绑定 status验证过的 exact legacy state与匹配 old activation lock路径/hash；`adopt` 使用 `LegacyEvidence=MISSING|UNTRUSTED`，由用户显式选择 `<name>`，若旧 bytes存在只可选绑定路径/hash而不得把 old lock当前提；`repair-adopt` 同样由用户显式选择 `<name>`，并按status绑定`StateEvidence=CORRUPT`的exact ControlBase bytes/path/hash或`MISSING` marker（后者禁止path/hash）、valid claims/preimage与 fresh selected lock，old lock至多是 optional untrusted evidence。三者均不另行发明未注册 evidence artifact，也不得覆盖唯一旧 evidence或 Apply。
5. 当前审计预期在 canonical setup 完成后的新 invocation，以 exact old evidence + fresh `work` lock 生成 `env authority migrate work` dry-run；若 status 判为 adopt/repair-adopt，则只构建该 route的 fresh lock/evidence；takeover只验证现有 parity/state-only evidence；recovery只构建 transaction recovery evidence/plan而不先 env build；`controller-owner-action-required` 或 manual recovery只报告并停止，不生成 plan。不得把任何 route降级成普通 `env activate work`。receipt-backed route同时生成 backup preview。
6. 人工检查三平台 add/update/no-op/prune、LegacyGap、controller/root claims、unknown、`.system`、plan/document hashes，以及预期 backup targets/receipt schema；DryRun 阶段尚不会创建真实 receipt id/hash。
7. 停止并等待单独的真实 Apply 授权。

2026-08-09 16:29 的 activation evidence显示 legacy schema 2 state 声称 `work`，live 集合为 2/4/2，当时 lock/live parity通过且 task overlay为空；随后 cleanup commit `7d9dd08` 使 commit-bound staging lock/activation attestation stale，但 current live parity仍通过。此前 7/15/7 是已经结束的中间快照，不再是 rollout 前提。rollout 必须先生成/验证 current-HEAD fresh `work` lock，再完成 shared-authority migrate；若新的 dry-run 出现任何未解释的 live mutation，尤其 managed prune，应把它作为待重新确认的 drift 证据，而不是本设计授予的删除权限。

若未来单独批准 Apply，成功标准是：

- shared authority state、environment lock、task overlay 和三平台 managed live parity 一致。
- `.system` 与 unknown directories 保持原状。
- Apply 结果直接引用本次唯一 backup receipt。
- status 不再报告 definition/task/live drift。

不在真实 home 上做 rollback 演练；完整 rollback 行为只在 fake home 验证。

## 8. 失败语义与可恢复性

任一 gate 失败时：

- 进程非零退出。
- state commit 前的失败不写或更新 shared authority，并可在锁内同步恢复 touched targets；若 state 已原子提交而 provisional result或 final journal `Phase=COMPLETE` record publish失败，不二次改写 state/live，进入 `recover finalize` 验证分支。terminal record成功后没有后续必需 publish。
- 若尚未 mutation，不继续后续平台或 transaction phase；若 commit boundary前已有 completed operation，立即持锁按 journal/receipt逆序恢复并在完整旧状态重验后发布 `Outcome=failed-restored`。commit boundary后只保留 evidence并走 reviewed finalize/唯一恢复矩阵。
- 不删除 rollback、quarantine、pre-rollback snapshot 或 journal。
- 输出失败阶段、context/plan/receipt hashes、可恢复目录和人工下一步，不输出 secrets 或原始私有配置。

捕获异常且恢复完整时，以非零 `apply-failed-but-restored` 结束；恢复未完成或进程 hard-kill 时，durable journal 保持 in-progress/recovery-required，后续 mutation fail-closed。下一次命令先提供 recovery status，再要求单独 reviewed abandon/rollback/finalize plan。

只有所有目标、postconditions、authority/canonical commit boundary和 transaction `Phase=COMPLETE` record成功后，才可清理 CandidateWorkspace与 live/canonical mutation workspace；durable backup receipt及其独立 COMPLETE marker按既有 working-tree外备份策略保留。

## 9. 非目标

- 不在本轮建立完整的 declarative platform registry 或重写全部 PowerShell 为 module。
- 不把 config-pull、MCP registration 或 project profile Apply 接入 env activation；它们各自的 path/backup 边界另列安全后续，因此本设计的完成结论只覆盖 managed skills 与 canonical skills source 写入链。
- 不恢复 Git-triggered live auto-apply，即使是 addition-only。
- 不迁移已建立 authority 的 live root location；本轮支持在 initial/migrate/adopt 时选择 custom Reasonix root，后续 root transition 需单独双边事务设计。
- 不自动修复或切换当前真实 live environment。
- 不执行真实 rollback drill。
- 不声称 sudden power loss、storage-controller cache loss 或 filesystem metadata durability；本轮 journal/failpoint 只证明同一受支持本地 filesystem 上的 process crash/hard-kill 恢复。若未来需要 power-loss 保证，必须另行固定 write-through/fsync、directory metadata flush、filesystem capability probe 与真实故障模型。
- 不全面重写历史设计、计划和归档文档；只修正冒充当前事实的安全契约。

## 10. 主要风险与取舍

| 风险或取舍 | 处理 |
|---|---|
| preview-only hooks 降低自动便利性 | 安全优先；pending preview保留精确external DryRun后续命令但不能直接Apply，未来是否恢复受限自动化需单独设计 |
| schema bump 使现有 lock/state 失效 | 只读显示 `migration-required`；只能通过独立 reviewed migrate/adopt plan 建立 schema 3 shared authority，普通 activation 不能隐式迁移 |
| canonical preflight 复制完整 source tree，运行更慢 | skill 集合规模小；以可验证事务换取耗时，后续可在不改变接口的前提下优化 |
| 全量 CI 时间增长 | 使用统一 runner 和 suite duration 证据；可在保持全量覆盖的前提下拆 job，不跳 suite |
| 当前 live drift 在实现期间继续存在 | hooks 先止血；只读 status 持续揭示 drift，直到另行批准新的 environment Apply |
| 安全基础契约改动面较大 | Phase 0 先关闭危险入口；后续按 canonical、live protocol、state、validation 分层，使用 schema/artifact graph 和 hard-kill tests 限制 review surface |
| validator 增加固定 runtime dependency | 先以 Draft 2020-12 sentinels 做兼容性 spike，再锁定 name/version/hash；validation 时不联网，依赖不可用则 fail-closed |
| shared control state 成为 machine-private authority | current-user-only ACL、稳定 HomeAuthorityKey、全局 root claims/operation lock；tracked tree 不保存完整路径或 authority 内容 |
| plan/receipt 含机器目标上下文 | 文件必须位于 tracked working tree 外的 Git-private 或显式外部目录；tracked reports 只记录 hashes/redacted labels，secret scan 继续覆盖 tracked 内容 |

## 11. 完成定义

本设计的实现只有同时满足以下条件才算完成：

1. Phase 0–4 的回归与全量 CI 均为零失败。
2. 4.6 producer→schema 表内的所有 artifacts 通过真实 schema validation。
3. Git 操作和默认 bootstrap 的 fake-home/live-write sentinel 为零写入。
4. 三平台 plan、backup、rollback、environment 和 task overlay 契约对称。
5. 已确认的 normalize、overlay removal、custom target backup、plan tamper 和 recovery cleanup 缺陷均有回归测试。
6. stable HomeAuthority/global root claims 在第二 clone、linked worktree、absent→created 和部分重叠 roots 测试中保持单一 selection 与串行 live mutation；已有 authority 的 default→custom 请求被零写入拒绝。
7. repo-scoped canonical lock 与 current-user live lock 的 busy/wait/stale 结果确定，任何 loser 都在 backup/swap 前退出。
8. hard-kill 后的新命令检测未完成 journal，只允许 reviewed recovery transition，不丢失最后副本。
9. 原工作区的用户 `.reasonix` 内容未被读取、覆盖或删除；解除跟踪仅影响 Git index。
10. 真实机器只完成 status 与 dry-run；除非用户另行明确授权，否则没有 live Apply。
