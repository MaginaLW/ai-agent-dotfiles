# ai-agent-dotfiles 使用说明

> **发布与验收边界：** 以 [STATUS.md 当前状态](../STATUS.md#current-state) 和
> [受控 policy](../scripts/live-safety-policy.psd1) 为准。代码可进入 released 路径不等于
> 完成 lab 验收或获得 live 部署授权；不得依赖历史 Phase 0 的机械联锁承诺。
> production sync（含 retirement）/environment/authority/task/rollback 与 canonical setup/recover
> 的 Apply 仍须满足当前验收、授权、计划审查及适用 host/identity/扫密门禁。
> 公共 `backup.ps1` 已退役：无论是否带 `-DryRun`，均零写退出并返回
> `backup-is-transaction-internal`（exit 1）；受管快照只由事务宿主从绑定 ReceiptIntent 创建。
> host resolver 优先接受有效 sandbox capability 和注入根；released 分支可解析真实 Windows
> identity，不能把裸调用当作安全隔离。维护验证按 `AGENTS.md` 在 internal sandbox 中运行 DryRun；
> 逐机只读/DryRun 检查则按明确的机器范围执行，不把该证据当作 Apply 授权。
> Git hooks 只生成 preview/event。`apply-harness-profile.ps1 -Apply` 仅写允许清单中的项目输出
> 和项目本地 rollback backup，不提供 production live 部署权限。

面向"未来的我"和"接手的 Claude Code / Codex agent"。看完这份手册即可独立维护本项目。

全局状态见 [STATUS.md](../STATUS.md)；新电脑接入见 [ONBOARD_NEW_MACHINE.md](ONBOARD_NEW_MACHINE.md)；skills 合并规则见 [MERGE_POLICY.md](MERGE_POLICY.md)；当前局部任务见 [status/active/](../status/active/)；历史状态见 [status/archived/](../status/archived/)；恢复操作见 [RESTORE.md](RESTORE.md)；CI 红灯的诊断与处置规则见 [CI_FAILURE_RULES.md](CI_FAILURE_RULES.md)。

---

## 1. 项目目的

统一管理多台电脑上的 Claude / Codex / Reasonix skills：

- 用 Git 维护**唯一可信源** `skills-source/`。
- 用 `scripts/build-skills.ps1` 从源生成 Claude / Codex / Reasonix 的 runtime output。
- 用 `scripts/sync.ps1` 生成并审查部署到本机 live skills 目录的 schema 3 语义计划；
  公共 DryRun 面只产出 pristine-initial 与显式 retirement 两个 OperationKind；
  本手册采用 internal sandbox（capability + host 注入根）验证，不据此执行 production Apply。
- 可恢复副本由事务协议经 backup-receipt 在 Apply 前创建；公共 standalone backup 入口已退役
  （`backup-is-transaction-internal`，零写退出）。
- 用 repo-local Git hooks 在相关 `git pull` / rebase / branch checkout 后记录 preview/event。

设计原则：保守、可审计、默认 dry-run、绝不整目录覆盖、绝不碰平台内置目录。

---

## 2. 当前管理范围

### 会同步
- `skills-source/shared/*`（跨平台，Claude + Codex + Reasonix 都装）
- `skills-source/claude-only/*`
- `skills-source/codex-only/*`
- 生成到 `claude/skills/`、`codex/skills/` 和 `reasonix/skills/`（Git-ignored）
- 部署到本机 live：
  - Claude：`~/.claude/skills`
  - Codex：`~/.codex/skills`；仅当它不存在时才 fallback 到 `~/.agents/skills`
  - Reasonix：`%APPDATA%\reasonix\skills`（`config.toml`/`.env` 等机器私有状态永不纳入）

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
| `bootstrap.ps1` | 新 clone 的固定入口：安装 inert wrapper，依次检查 validator/scanner/runner；只输出 preview/diagnostic，不 Apply |
| `STATUS.md` | 唯一全局状态文件，直接更新，不重复新建总体状态报告 |
| `status/active/` | 当前正在进行的局部任务状态 |
| `status/archived/` | 已完成和历史局部任务状态 |
| `.claude/settings.json` | 项目级 harness 护栏（deny 编辑生成物/`.system`、禁 robocopy；allow 安全校验命令） |
| `skills-source/` | **唯一可信源**，手工维护的 skill 树 |
| `skills-source/shared/` | 跨平台 skill（生成到 Claude、Codex、Reasonix） |
| `skills-source/claude-only/` | 仅 Claude 的 skill |
| `skills-source/codex-only/` | 仅 Codex 的 skill（如 `hatch-pet`） |
| `skills-source/reasonix-only/` | 仅 Reasonix 的 skill |
| `claude/skills/` | **生成物**，Git-ignored，勿手改 |
| `codex/skills/` | **生成物**，Git-ignored，勿手改 |
| `reasonix/skills/` | **生成物**，Git-ignored，勿手改 |
| `manifests/managed-skills.txt` | 三平台 union inventory；实际 prune authority 使用各平台 manifest，旧 live 名称默认按 unknown 保留 |
| `scripts/build-skills.ps1` | 从源生成 runtime output，并刷新 manifest |
| `scripts/scan-secrets.ps1` | secret 扫描（gitleaks + 自定义回退扫描器） |
| `scripts/backup.ps1` | 公共 standalone 入口已退役：零写、非零 `backup-is-transaction-internal` 诊断；受管快照由事务宿主经 backup-receipt 创建 |
| `scripts/sync.ps1` | schema 3 语义计划 producer（pristine-initial / 显式 retirement）；由 host resolver 解析 sandbox 或受控 Windows identity，Apply 消费审查过的同一计划 |
| `scripts/config-status.ps1` | 只读 config drift 报告（repo ↔ home），见 §14 |
| `scripts/config-pull.ps1` | 部署 harness 配置 repo→home，默认 dry-run，`-Apply` gated |
| `scripts/config-push.ps1` | 捕获 harness 配置 home→repo，双 gate（扫密 + 私有路径），默认 dry-run |
| `harness-source/` | Project Harness Profiles 的 component/profile 源库，见 §15 |
| `.agent-harness/generated/` | Project Harness Profiles 的项目本地生成物，默认 Git-ignored，可随时重建 |
| `scripts/status-harness-profile.ps1` | 只读查看可用 profile/component 与项目生成状态，见 §15 |
| `scripts/build-harness-profile.ps1` | 从 `harness-source/` 生成项目本地 harness output，见 §15 |
| `scripts/apply-harness-profile.ps1` | 默认 dry-run；`-Apply` 仅写 allowlisted 项目输出和项目本地 rollback backup，见 §15 |
| `harness-source/envs/` | Harness Environments 的环境定义（tracked 源），见 §16 |
| `.agent-harness/task-skills.psd1` | 当前分支/worktree 的共享 task skill overlay，见 §16 |
| `envs/` | 环境构建 staging，**生成物**，Git-ignored，勿手改，见 §16 |
| `state/current-env.json` | 当前激活环境记录，机器私有，Git-ignored，见 §16 |
| `scripts/list-harness-env.ps1` | 只读枚举环境定义并标记激活环境，见 §16 |
| `scripts/status-harness-env.ps1` | 只读环境状态/staging 新旧报告，见 §16 |
| `scripts/build-harness-env.ps1` | 构建 `envs/<name>/` staging，只写该目录，见 §16 |
| `scripts/activate-harness-env.ps1` | gated 环境切换：dry-run 产出外部 `environment` 计划，apply 消费同一计划并经 receipt-backed host 部署，见 §16 |
| `scripts/task-skills.ps1` | task overlay 的校验、dry-run、preview/event 和显式 close 合同，见 §16 |
| `scripts/auto-sync-after-git.ps1` | Git-private approved runner；只写 non-consumable preview/event 和外部 DryRun 命令 |
| `scripts/apply-hooks.ps1` | 显式批准 runner 后安装 preview-only hooks |
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

`bootstrap.ps1` 先安装 inert wrappers，然后依次检查 pinned validator、pinned gitleaks 和
Git-private approved runner。缺失时只输出一个固定 token 和一条绝对安装/批准命令；执行该命令
后再次运行 bootstrap。获准 runner 只生成 preview/diagnostic，不生成可消费 plan 或执行 Apply。
Git hooks 也只能写 non-consumable preview/event，并打印显式外部 DryRun 命令。

手动维护流程仍然可用：

```powershell
Set-Location $RepoRoot
git pull --ff-only

pwsh -NoProfile -File scripts/agent-dotfiles.ps1 build # 从源生成 runtime output
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 scan  # 检查 secrets
if ($LASTEXITCODE -ne 0) { throw 'Secret scan failed.' }
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-sync-sandbox-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $sandbox | Out-Null
$plan = Join-Path $sandbox 'sync-plan.json'
# 本示例通过 internal sandbox 运行：capability + 三个注入根
# （AI_AGENT_DOTFILES_INTERNAL_{HOME_ROOT,BACKUP_ROOT,CONTROL_BASE}）必须齐备。
# released policy 下裸调用可能解析真实 identity，不可用它代替 sandbox。
# pristine-initial producer 物化 named full 环境并 create-new 写 schema 3 计划；
# tests/sync.tests.ps1 与 tests/helpers/safety-sandbox.ps1 是可执行的调用示例。
& pwsh -NoProfile -File scripts/internal/live-transaction-host.ps1 `
    -SandboxRoot $sandbox `
    -ScriptPath (Join-Path (Get-Location) 'scripts/sync.ps1') `
    -ArgumentsBase64 ([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(
        (ConvertTo-Json @('-SkipBuild','-SkipSecretScan','-DryRun','-PlanPath',$plan) -Compress))))
if ($LASTEXITCODE -ne 0) { throw 'Sandbox DryRun failed.' }
# 本验证流程到此停止；production Apply 另须满足当前验收与授权要求。
```

`sync.ps1` 的 schema 3 计划面默认是 **dry-run**，会写外部计划、绑定的物化材料及运行报告，不动 live；plan 走 create-new（重跑同路径返回 `live-plan-path-collision`）。统一 CLI 仍要求显式 `-DryRun`。`-Apply` 只消费同一份计划；校验文档完整性、绑定物化现势、selection context 和 DocumentHash 未消费，retirement 还重算当前 PlanHash。initial 的 control prefix 会由随后独立执行的 canonical setup 建立，因此由宿主在锁内重新校验该特例，不能用普通 retirement 重算替代。执行资格以 [当前状态](../STATUS.md#current-state) 为准，不以历史联锁保证无写入。

**逐机路由：** 先运行 `canonical status`；若为 `canonical-ready`，再以新的命令调用
`env authority status`，按其唯一 route 选择环境、迁移、接管或恢复。普通 sync 只产生 pristine
initial 与显式 retirement 计划，不是已有 authority 的日常更新入口。pristine initial 必须在
control base 和三个 live skills 根均不存在时先生成 sync DryRun 计划；之后才生成、审查并按
授权 Apply canonical setup，最后在新进程 Apply 原 initial 计划。若先 setup 再试图重建 initial
计划，会被 `live-plan-authority-present` 拒绝。完整顺序和 route 参数见
[接入指南第 5 节](ONBOARD_NEW_MACHINE.md#5-select-the-machine-route)。canonical setup 的 Windows
identity 不由普通 live sandbox helper 隔离；不得把本节的 sync 示例推广成 canonical Apply 测试。

如果只想跳过初始 preview diagnostic：

```powershell
pwsh -NoProfile -File .\bootstrap.ps1 -SkipInitialPlan
```

安装后，`post-merge`、`post-checkout`、`post-rewrite` 只调用已批准的 Git-private runner。
toolchain 漂移返回 `runner-review-required`；data-only 变化最多产生不可作为 `-PlanPath` 的
Git-private preview/event。用户必须另行把明确的 `-DryRun -PlanPath <external>` 命令写到 repo/Git
私有目录之外，并满足 host 条件，才会得到可审查的 actionable plan。hook 永不自动 backup/apply/prune/rollback。

---

## 5. 修改已有 skill 的流程

1. 只改 `skills-source/`（**不要**直接改 `claude/skills/` 或 `codex/skills/`）。
2. `scripts/build-skills.ps1`
3. `scripts/scan-secrets.ps1`
4. 在 internal sandbox 内以 pristine-initial producer 生成 schema 3 计划并审查
   （调用形态见 §4；重跑同 `-PlanPath` 返回 `live-plan-path-collision`）
5. 本流程停在计划审查；Apply 必须另行满足[当前验收与授权要求](../STATUS.md#current-state)，不能用试跑 Apply 检测联锁。
6. 提交 source / manifest / docs 变更（**不要**提交 generated output）。
7. 取得适用发布授权后再 `git push`。
8. 其它电脑的 hook 只生成 non-consumable preview/event；每台机器都必须显式生成并审查自己的外部 DryRun 计划，满足验收与授权后才能 Apply。

如果这次修改是**删除 canonical skill**，build 会同时从 generated output 和当前 manifest
移除名称；旧 live 目录因此会按 unknown 保留，不会被普通 sync 猜测性删除。完成逐项审查后，
为当前机器在 repo 和 live roots 之外创建一次性 JSON（不要提交）：

```json
{
  "SchemaVersion": 1,
  "Claude": ["retired-skill"],
  "Codex": ["retired-skill"],
  "Reasonix": []
}
```

然后把同一个文件传给 dry-run 和 apply：

```powershell
# 仍在 internal sandbox 内运行（见 §4 的 host 调用形态）；-RetireManifestPath
# 选择 retirement producer：读取注入 control base 上的 schema 3 authority state，
# 逐平台验证 stale unknown 目标 ∉ reviewed postset，绑定 manifest 字节哈希。
$plan = Join-Path $sandbox 'retire-plan.json'
$retire = Join-Path $sandbox 'ai-agent-dotfiles-retire-skills.json'
# 经 live-transaction-host.ps1 传参：'-DryRun','-PlanPath',$plan,'-RetireManifestPath',$retire
# 逐平台审查 retirement-authorized prune、unknown 和 .system 状态
# 仅描述合同；执行前须满足 STATUS.md 当前验收、授权及 host 要求：
# pwsh -NoProfile -File scripts/sync.ps1 -Apply -PlanPath $plan -RetireManifestPath $retire
```

retirement manifest 必须严格列出三个平台、至少一个小写安全名称；`.system`、仍在
canonical/generated/current manifest 的名称、缺失的 live 目录以及 junction/symlink 都会被拒绝。
即使 `-RepoRoot` 指向 env staging 或测试 fixture，脚本仍会把自身所在主仓作为不可替换的 canonical
authority。retirement 文件的规范化绝对路径、原始 bytes hash、平台名称、source/live roots、
canonical authority/逐名称缺失证据与每个目标 tree hash 都进入计划指纹；apply 前漂移会在 backup
前失败，backup 后发生的内容漂移也会在实际删除前失败并恢复原目录。

这里的“一次性”表示授权不会写入长期 managed 状态；事务终态还保存已消费的 DocumentHash，
同一计划重放会被拒绝。成功后删除外部 plan 与 retirement JSON，并妥善保管 receipt、journal
和脱敏运行摘要；不要删除事务证据来尝试重新使用计划。auto-sync hook 不会自动读取或创建 retirement manifest；
其它机器若也有这批旧目录，必须各自执行人工审查的同一流程。

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
- backup 不会复制它：受管快照只记录 `.system` 根条目标记（marker-only），从不遍历或完整备份。
- sync **永远跳过**它（不更新、不删除）。
- 它**不属于** repo-managed skill。
- 删除它可能破坏 Codex 原生能力。

---

## 9. backup / restore

- 受管 `sync.ps1 -Apply` 合同包含变更前备份；能否执行以[当前验收与授权状态](../STATUS.md#current-state)为准。
- 公共 standalone `scripts/backup.ps1` 已退役：带不带 `-DryRun` 都是零写退出，诊断为
  `backup-is-transaction-internal`（exit 1），不创建任何 backup；受管快照由 live transaction
  host 从绑定的 ReceiptIntent 创建，其 preview 来自审查过的计划（见 §4），不是公共入口。
- 备份根由 Windows Known Folder 派生并绑定到 authority，通常位于（repo 外）：
  ```text
  %LOCALAPPDATA%\ai-agent-dotfiles\backups
  ```
- 恢复操作详见 [RESTORE.md](RESTORE.md)。

---

## 10. 多电脑同步流程

一台电脑修改并 push 后，另一台：

```powershell
Set-Location $RepoRoot
pwsh -NoProfile -File .\bootstrap.ps1                  # 每个 clone 运行一次；安装 preview-only hooks
git pull --ff-only                                     # hooks 只记录 preview/event，不 Apply
```

如果没有安装 auto-sync hooks，仍可使用手动流程（build/scan 同 §4；离线验证按 §4 的
`scripts/internal/live-transaction-host.ps1` 形态隔离调用，不能假定裸调用会被拒绝）：

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 build
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 scan
# sandbox sync DryRun：按 §4 的 host 调用形态生成外部计划（plan 走 create-new）
# 本验证流程到此停止；production Apply 另须满足当前验收与授权要求。
```

---

## 11. 当前状态

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
A：`git clone` → `bootstrap.ps1` → 按输出依次安装 validator/scanner、显式批准 runner → 再次 bootstrap 生成 preview/diagnostic。`-SkipInitialSync` 仅为 `-SkipInitialPlan` 的弃用警告别名。hook 只生成 preview/event；实际部署须满足[当前验收与授权要求](../STATUS.md#current-state)，并先审查该机器的外部 DryRun 计划。

**Q：scan-secrets 报 false positive 怎么办？**
A：优先**改写源文档/示例措辞**让它不再像真实密钥——例如把"给 `secret` 键直接赋一个带引号的明文字符串"这类示例，改写成描述性文字（说明应从环境变量或密钥管理器读取）。**不要** whitelist，**不要**削弱 scan gate。改完重新 build + scan。

---

## 14. Harness 配置同步（config-sync）

除 skills 外，仓库还管理 agent harness 配置本身。源同样是 `manifests/whitelist.psd1`
（per-platform 的 Push/Pull items 与 ExcludedItems）。

- `.claude/settings.json`（项目级、已提交）：把硬规则变成 harness 强制 `permissions.deny`
  （禁止 `Edit`/`Write` 生成物 `claude|codex/skills/**` 与 Codex `.system`、禁止 robocopy
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
  Codex 侧只同步 `AGENTS.md`/`prompts`。
- Agent 规则与可复用模板按统筹、实施、审核等职责和所需能力编写，不固定具体模型或推理档位。
  尊重用户的明确选择和既有个人配置；未指定时沿用当前会话/运行时默认，任务覆盖值必须由当前
  运行时支持。历史记录中的模型名、路由与档位保留为当时证据，不作为当前默认指令。
- 模板省略模型与推理档位覆盖值，不表示可以删除个人设置。`config-pull.ps1` 按文件复制，
  **不会按字段合并个人配置**；部署审查时须逐项比较目标中的个人覆盖值并保留，不能用缺少这些
  字段的通用模板直接覆盖它们。模型选择不改变权限、并发上限或独立审核要求。
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
- `scripts/apply-harness-profile.ps1`：默认 dry-run；`-Apply` 只写 allowlisted 项目输出以及
  `.agent-harness/backups/` 下的项目本地 rollback backup/manifest。

这是项目本地操作边界：该 `-Apply` 不写 home 或 live skills，也不触发 repo 外
production backup、production rollback 或 production transaction state；其 rollback 数据
只位于目标项目内，不扩展为 production live 部署权限。

当前受控输出类型包括 Claude `.claude/commands/` 与 `.claude/agents/`、Codex
`.codex/prompts/` 与 `.codex/agents/`。
每种类型由 component `Kind` 和独立 output contract 校验；build 会把文件型输出复制到
`.agent-harness/generated/files/`，apply 仍只写对应项目路径。

安全规则：

- `harness-source/` 是 profile/component 的源码；不要手改 `.agent-harness/generated/`。
- `.agent-harness/generated/` 是 disposable generated output，默认 Git-ignored，可删除后重建。
- 第一版 `apply-harness-profile.ps1` 不写 `~/.claude`、`~/.codex`，也不安装或同步 live skills。
- 第一版不安装 project-local skills，不承诺自动切换全局 harness。
- 变更 profile/component 后，先运行 status/build dry-run 和 `tests/harness-profile.tests.ps1`。
- 多平台输出变更后还应运行 `tests/harness-multiplatform.tests.ps1`。

非目标：

- 不替代 `scripts/sync.ps1` 的 live skills 同步。
- 不替代 §14 的 home-level harness config-sync。
- 不管理 Codex `.system`、secrets、session/cache/state。
- 不把项目本地 profile apply 扩展为全局机器配置切换。

---

## 16. Harness Environments

Harness Environments 是 conda 式的命名环境层：每个环境声明一个 profile 和
各平台受管 skills 的子集，构建为可随时重建的 staging 目录，
并可经门控的 `env activate` 切换到 live home。
设计见 `docs/superpowers/specs/2026-07-10-harness-env-design.md`。

> 本节的 environment/task `-Apply` 命令描述接口合同，不提供执行授权；执行前须核对
> [当前发布与验收状态](../STATUS.md#current-state)。Git hook 不代为 Apply，
> 只记录 non-consumable preview/event。日常离线维护停在 status/build/sandbox DryRun。

### 16.1 Task skill overlay（按任务热插拔）

`work.psd1` 是稳定的基础集合，Claude/Codex/Reasonix 各保留 `systematic-debugging` 一个 skill；
其余源 skill 保留在 `full` 中，按任务需要选择，`minimal` 保留测试样例选集。
任务临时需要的已管理 skill 不会被永久写回基础环境，
而是记录在当前分支/worktree 的 `.agent-harness/task-skills.psd1`。它是 Git 可审查的请求，
不是 generated output，也不是 live home 状态；默认空文件形状为：

```powershell
@{
    SchemaVersion = 1
    BaseEnv = 'work'
    Skills = @{
        Claude = @()
        Codex = @()
        Reasonix = @()
    }
}
```

常用命令：

```powershell
pwsh -File scripts/agent-dotfiles.ps1 env task status
$BaseEnv = '<reviewed-base-env>'
# 三组是独立操作；每组先审查新计划，再按适用授权消费同一计划。
pwsh -File scripts/agent-dotfiles.ps1 env task ensure-skill verification-before-completion -Platform Codex -BaseEnv $BaseEnv -DryRun -PlanPath '<external-ensure-plan.json>'
pwsh -File scripts/agent-dotfiles.ps1 env task ensure-skill verification-before-completion -Platform Codex -BaseEnv $BaseEnv -Apply -PlanPath '<external-ensure-plan.json>'
pwsh -File scripts/agent-dotfiles.ps1 env task sync -BaseEnv $BaseEnv -DryRun -PlanPath '<external-task-sync-plan.json>'
pwsh -File scripts/agent-dotfiles.ps1 env task sync -BaseEnv $BaseEnv -Apply -PlanPath '<external-task-sync-plan.json>'
pwsh -File scripts/agent-dotfiles.ps1 env task close -BaseEnv $BaseEnv -DryRun -PlanPath '<external-close-plan.json>'
pwsh -File scripts/agent-dotfiles.ps1 env task close -BaseEnv $BaseEnv -Apply -PlanPath '<external-close-plan.json>'
```

行为边界：

- `ensure-skill` 只接受对应平台 manifest、`skills-source/` 和 generated output 都存在的 skill；
  未管理、隔离、路径型或扫密失败的内容会在 live 写入前拒绝。
- `BaseEnv` 默认 `work`，但操作必须匹配已审查的共享 authority/overlay 基线；initial 建立的是
  `full`，不能因此自动选择 `work`，也不能复用绑定了其他 base 的计划。DryRun 额外创建计划旁的
  candidate overlay；Apply 消费它，不自动重建计划。
- 每次变更都先构造临时 overlay，运行 build → scan → 环境 staging → fingerprint-bound sync dry-run；
  `-Apply` 合同原子更新 tracked overlay 并进入事务部署，执行须满足当前验收与授权要求。
- `close` 会删除 overlay 并可能 prune 任务增加的 managed skill；必须显式 DryRun、审查后再按授权 Apply。
- Git hook 在其它电脑 checkout/pull 后只记录 non-consumable preview/event，不自动重建或应用
  addition/removal；人工必须先完成 `env task sync -DryRun` 审查并满足当前执行要求。
- 共享范围是提交该 overlay 的 branch/worktree；机器只根据 source + overlay 重建，不复制另一台机器的 home。
  新 clone 仍需先运行 `bootstrap.ps1` 安装 hooks；Git 不会自动安装仓库内 hook。
- Codex 应用已经缓存的 skill catalog 可能需要新 task/thread 才刷新。仓库可以热插拔文件、环境和状态，
  但不能强制应用层未公开的 catalog reload。

`list` / `status` 只读；`build` 只写可删除、可重建的 `envs/<name>/` staging，不写 home。
`activate` 的 DryRun 必须显式给 `-PlanPath` 写外部计划；`-Apply` 只消费该计划并经
receipt-backed live transaction host 部署。执行前须满足当前验收与授权要求，不可假定 Apply 无副作用。
**Phase 2 范围收窄**：activate 只切换 skills 子集并写共享 authority 状态；home 级配置部署
（config-pull 接入）因当前没有任何环境差异化的 home 配置组件而暂缓，接入需单独评审。

常用命令：

```powershell
pwsh -File scripts/agent-dotfiles.ps1 env list          # 枚举环境 + 标记激活
pwsh -File scripts/agent-dotfiles.ps1 env status        # 定义有效性 + staging 新旧 + 激活漂移
pwsh -File scripts/agent-dotfiles.ps1 env status -ProjectRoot <p>  # 另检查项目 RequiredEnv 是否匹配
pwsh -File scripts/agent-dotfiles.ps1 env build <name>  # 构建 envs/<name>/ staging
pwsh -File scripts/agent-dotfiles.ps1 env activate <name> -DryRun -PlanPath <external-plan.json>  # 维护验证须经 sandbox host
# 以下 Apply 仅描述合同；满足当前验收、授权和 host 要求后才可执行
pwsh -File scripts/agent-dotfiles.ps1 env activate <name> -Apply -PlanPath <external-plan.json>
pwsh -File scripts/agent-dotfiles.ps1 env rollback -ReceiptPath <complete-environment-receipt> -DryRun -PlanPath <external-plan.json>
pwsh -File scripts/agent-dotfiles.ps1 env rollback -ReceiptPath <complete-environment-receipt> -Apply -PlanPath <external-plan.json>
```

`env activate` 的 dry-run gate 链（任一步失败即止、不写状态文件）为：
build-skills → scan-secrets → staging 重建 → 绑定 materialization 并写外部 `environment` 计划；
apply 只消费该计划并经 host 写 shared authority 状态（repo-local `state/current-env.json` 保持 legacy 证据、永不写入）。入口层强制显式 `-DryRun` 或 `-Apply`（与 sync 同款）；
不能把 Apply 当作默认动作，也不能以历史 Phase 0 描述代替当前验收判断。
切换语义：staging 携带全量 manifest 副本而 skills 只含环境子集，sync 的
manifest-scoped prune 因此在切换到较小环境时自动裁剪多余受管 skills；
未知 live 目录与 Codex `.system` 一如既往永不触碰。

目录与文件：

- `harness-source/envs/<name>.psd1`：环境定义（tracked 源真相）。字段：
  `SchemaVersion`、`Name`（须与文件名一致）、`Description`、`Profile`
  （引用 `harness-source/profiles/`，继承其 Extends 链）、`Skills.Claude`/`Skills.Codex`/`Skills.Reasonix`
  （必须是对应 `manifests/managed-skills.<platform>.txt` 的子集）。
- `envs/<name>/`：`env build` 的 staging 输出，Git-ignored，可删除重建。内容：
  skills 子集副本、`manifest.claude.txt`/`manifest.codex.txt`
  （环境子集，供人读）、`manifests/managed-skills.<platform>.txt`（**全量**仓库 manifest
  副本，驱动 sync 的切换裁剪语义）、`profile/`（渲染的 profile 组件输出）、`env.lock.json`
  （可验证的定义、源/生成树、manifest、profile 和 staging 文件哈希；`env status`
  用它判定 lock validity 和 built/stale，而不是只看文件是否存在）。
   `envs/<name>/reports/` 是 activation 期间 `sync.ps1` 写入的运行证据，不属于构建
   产物，lock attestation 会忽略它。
- `state/current-env.json`：legacy（Phase 3 起不再写入，保留为机器私有、Git-ignored 的迁移证据）；
  当前激活环境记录在 shared authority 状态（`ControlBase/homes/<key>/current-env.json`，schema 3），由激活 apply 的事务安装，
  记录定义/锁/task overlay hash 与 final managed hashes，`status` 用它们检测“激活后定义或任务 overlay 又变了”。

安全规则：

- `env build` 只写 `envs/<name>/`，删除重建前有前缀断言；`list`/`status` 不写任何文件。
- `env activate` 是受管环境切换路径：先显式 DryRun 并审查计划；
  `-Apply` 进入同一事务协议且不能跳过 backup；home-only 文件（credentials、sessions、缓存、
  Codex `.system`、Codex `config.toml`）永不随切换变动；production 根由当前 identity/claims 绑定，
  不用任意 `HomeRoot` 模拟机器身份。
- `env status` 对当前环境报告 `lock validity`、`definition drift`、`live parity`、
  Codex `.system` 状态和 `backup reference`；这些是状态证据，不是备份内容。
- `env rollback` 不是 whole-home restore：恢复对象由所选 environment receipt 的
  Claude/Codex/Reasonix managed snapshot targets 及派生的审查计划限定，而非重新枚举当前 manifest。
  它永不触碰 unknown live 目录、Codex `.system`、
  credentials、sessions、cache、Codex `config.toml`。
  `-Apply` 必须带同一 DryRun 生成的 `-PlanPath`，并通过选定 activation
  backup 的元数据校验。
- 每台机器首次真实 `-Apply` 前必须人工审查 DryRun 计划（prune 列表尤其要过目）；
  计划审查不代替当前验收和部署授权。
- task overlay 无自动 Apply 路径；任何 addition/removal/prune 都须显式审查和授权。
- `envs/` 与 `state/` 永不提交；环境定义变更后先跑 `env status` 和回归测试。
- 环境层只做编排：受管 skills 写入统一经 receipt-backed live transaction host；
  不新增旁路写 home 的实现。未来接入配置部署需单独评审并复用 `config-pull.ps1`。

项目联动（Phase 3）：

- 项目 `.agent-harness/profile.psd1` 可声明可选字段 `RequiredEnv = '<name>'`。
- `env status -ProjectRoot <p>` 报告当前激活环境是否匹配项目声明，不匹配时给出
  建议命令的操作方向（实际调用须补 `env activate <name> -DryRun -PlanPath <external-plan.json>`）。
  **只检测提醒，绝不自动 activate。**
- 本仓库自身声明 `RequiredEnv = 'work'` 作为示例。

非目标（当前）：

- 不部署 home 级配置（config-pull 接入 deferred，见上）。
- 不自动切换环境（进入项目不触发任何写操作，联动仅为提醒）。
- 不把一个任务的 overlay 永久合并回 `harness-source/envs/work.psd1`；任务结束后应显式 close，
  是否提交 overlay 由任务协作者按 branch/worktree 需求决定。
- 不做 lockfile 跨机复现或 secrets 管理；`env.lock.json` 当前用于
  本机 staging/activation 的可验证证据，不是跨机传输 credential 或 machine state 的载体。

---

## 17. 统一 CLI 与真实边界

统一入口是 `scripts/agent-dotfiles.ps1`。它只负责路由和参数门控，不复制底层脚本的实现。
当前主要命令面如下（`inventory` / `analyze` / `merge` 是对应 skills 命令的顶层别名，另有 `plans`）：

```text
doctor
build
scan
backup
sync
canonical status | setup | recover status | recover abandon | recover rollback | recover finalize
live recover status | recover abandon | recover rollback | recover finalize
config status | pull | push
profile status | build | apply
skills inventory | analyze | dedupe | merge | normalize | promote
env list | status | build | activate | rollback | task status | task ensure-skill | task sync | task close
env authority status | migrate | adopt | repair-adopt | takeover
```

读操作包括 `doctor`、`scan`、`config status`、`profile status`、`skills inventory`、
`skills analyze`、`skills dedupe`、`env list` 和 `env status`。`build`、`profile build`
和 `env build` 只生成可重建的派生/staging 输出；standalone `backup` 已退役，
带不带 `-DryRun` 都零写返回 `backup-is-transaction-internal`，不提供快照预览。
它们都不把 live home 或 canonical source 当作任意写入目标。

所有会改变 live、canonical source 或项目目标的动作都必须先走 dry-run；统一入口不会
自动补 `-Apply`。对支持模式的写操作，必须明确选择且只能选择一个 `-DryRun` 或
`-Apply`；省略模式会被拒绝，而不是隐式执行。`sync` 的 `-Apply` 还必须使用同一份
经审查的 `-PlanPath`。`config pull/push`、`profile apply`、`skills merge/promote`
也保持默认 dry-run/显式 apply 的保守边界。

`env activate` 和 `env rollback` 的 apply 需要更严格的计划绑定：两者都要求外部 dry-run 生成的同一 `-PlanPath`，
激活计划是 `OperationKind=environment`（Phase 3 Task 6），并在
执行前重新验证环境状态、备份元数据和计划哈希。`config pull` 是独立的 home-level
配置同步入口；the underlying `config-pull` is not part of `env activate`，环境切换当前
只处理受 manifest 管理的 Claude/Codex/Reasonix skills 和环境状态。

以上 production sync/environment/task/rollback 的执行边界统一见
[当前发布与验收状态](../STATUS.md#current-state)及[受控 policy](../scripts/live-safety-policy.psd1)；
policy 值不代表验收通过或部署授权，hook 仍只写 preview/event。
`apply-harness-profile.ps1 -Apply` 只写 allowlisted 项目输出与项目本地 rollback backup，
不提供 production live Apply 授权。
