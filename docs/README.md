# ai-agent-dotfiles 使用说明

面向"未来的我"和接手的 Claude Code / Codex agent。必须遵守的规则以 [AGENTS.md](../AGENTS.md) 为准；
本手册只补充操作细节。全局状态见 [STATUS.md](../STATUS.md)，新电脑接入见
[ONBOARD_NEW_MACHINE.md](ONBOARD_NEW_MACHINE.md)，已删除内容见 [HISTORY.md](HISTORY.md)。

---

## 1. 项目目的

用 Git 统一管理多台电脑上的 Claude / Codex / ZCode skills：`skills-source/` 是唯一可信源，
`build-skills.ps1` 生成两个平台的 runtime output；`deploy.ps1` 把某个环境选中的 skills 逐目录部署到
本机 live 根（默认 dry-run；ZCode 是投影平台，直接部署 Claude 生成物）。另外管理 harness 配置（§11）和项目级 harness profile（§12）。
原则：保守、可审计、默认 dry-run、绝不整目录覆盖、绝不碰平台内置目录。红线（Hard rules / Skill rules）以
[AGENTS.md](../AGENTS.md) 为准；唯一允许手工写 live 根的情形是 §8 的授权恢复。

---

## 2. 当前管理范围

生成物 `claude/skills/`、`codex/skills/`（Git-ignored）中由所选环境挑出的子集部署到：

- Claude：`~/.claude/skills`
- Codex：`~/.codex/skills`；仅当它不存在时 fallback 到 `~/.agents/skills`（两者都存在时拒绝）
- ZCode：`~/.zcode/skills`（投影平台，部署 Claude 生成物，自身没有生成根与 manifest）

不管理：Codex `.system`；未选中、未记录在部署状态且未被 `-Retire` 点名的 live 目录（unknown，只报告）；部署状态与备份
（repo 外的 `%LOCALAPPDATA%\ai-agent-dotfiles.deploy`）；机器私有配置与 secrets。

---

## 3. 目录说明

| 路径 | 说明 |
|---|---|
| `bootstrap.ps1` | 新 clone 一次性入口：安装并校验 pinned gitleaks、build、打印联合 deploy dry-run 命令；不写 live |
| `STATUS.md`、`status/active/` | 全局状态（原地更新）与进行中任务记录（完成后结论并入 `STATUS.md` 并删除） |
| `claude/settings.json`、`claude/CLAUDE.md` | 仅供显式旧平台配置同步的分发模板；本仓 Claude 开发入口已退役 |
| `skills-source/` | 唯一可信源（`shared/`、`claude-only/`、`codex-only/`） |
| `claude/skills/`、`codex/skills/` | 生成物，Git-ignored，勿手改 |
| `manifests/managed-skills.<platform>.txt` | 每平台受管名单，由 build 刷新，勿手改 |
| `manifests/whitelist.psd1` | config-sync 的 Push/Pull items 与 ExcludedItems（§11） |
| `harness-source/` | 环境定义 `envs/`（§13）与 profile/component 源（§12） |
| `.agent-harness/profile.psd1` | 当前项目的 profile 声明（§12） |
| `.agent-harness/generated/` | 项目本地 profile 生成物，Git-ignored，可重建 |
| `tools/gitleaks/` | pinned gitleaks 的版本、下载地址与校验锁 |
| `.gitleaks.toml` | 仓库秘密扫描规则 |
| `scripts/` | build、scan、deploy（§4）、promote（§6）、config（§11）、profile（§12）、测试与校验入口（§10）、只读 `doctor.ps1`、统一 CLI（§14） |

`scripts/pinned-tool.ps1` 从调用方传入的 `-LockPath` 读取工具锁文件；gitleaks 的锁路径由
`scripts/install-gitleaks.ps1`、扫描和 doctor 等调用方传入，不在通用 helper 中固定。
直接 release 下载失败时，按锁定的 owner／repo／tag／asset 名称查询官方 GitHub Releases
API；下载结果仍必须通过锁文件中的压缩包与可执行文件 SHA-256 双重校验。

---

## 4. 日常同步流程

`deploy.ps1` 是日常联合入口：先按 `harness-source/envs/<name>.psd1` 的 `Skills` 清单（日常用 `work`）部署 skills，
再按 Codex-only 默认运行 `config-pull.ps1`；不会恢复 Claude live 配置。Apply 前先顺序运行两阶段现有的 dry-run 规划器，规划失败时不写 live skills、
config 或部署状态；skills 预检完成的 build/scan 在紧接的 skills Apply 中复用，config Apply 仍保留写前扫描。
预检不验证所有写权限、备份可用性或并发变化，也不冻结计划；两阶段不是原子事务，运行时 config 阶段失败时
已完成的 skill 阶段保持完成，并明确报告边界。
`deploy-skills.ps1` 仍是只部署 skills 的底层入口，按同一环境逐目录部署到三个 live 根
（Zcode 从 Claude 生成物投影）：

- 默认先跑 build 与 scan，任一失败即停止。`-SkipBuild` 同时跳过两者；除隔离测试外，只有已有成功结果覆盖当前未变的源码、构建输入和生成物时，才可在同一已授权部署链或只读复核中复用，不能把它当作省略必需检查的入口。
- 每个目录给出 `install`、`update`、`unchanged`、`prune` 或 `unknown`；不带 `-Apply` 不写 live 根或部署状态。
  对状态中没有记录的同名目录，`update` 会提示其归属未知且将备份后覆盖；状态缺失不代表目录一定未受管。
- `prune` 只删除本工具上次部署过、本次不再选中的目录，或 `-Retire` 点名的目录（三平台同时生效）。
- 其余 live 目录是 unknown，只报告不碰。Codex `.system` 永不触碰；遇到 reparse point 直接拒绝。
- 替换靠整目录改名：先复制到同级 `.deploying-<name>` 再换名；文件被占用时不会半删旧目录。
  两次改名之间中断时目标可能暂时缺失。计划会报告 `.deploying-*` 残留及备份根；再次对该 skill 做
  install/update/prune 时，先备份该操作的两个残留路径再清理；其他残留只报告，不自动清理。
  合法名称可能使一个 skill 的暂存路径与另一个 skill 的旧目录路径重合，所以不能仅凭名称判断其归属。
- `update` 和 `prune` 前先备份旧目录（§8）。
- 逐项计划后显示各操作的数量汇总；汇总不能代替逐项审查。
- 显示上次记录的环境 → 本次目标环境（记录不证明 live 内容）；prune 区分“此前受管、本次未选中”
  和显式 `-Retire`。install/update 复用现有文件哈希比较，列出相对文件名的 add/change/remove，
  不打印文件内容或哈希。文件名本身也可能包含私有信息，分享输出前仍需审查。
- 已部署集合记录在 `%LOCALAPPDATA%\ai-agent-dotfiles.deploy\deployed-skills.json`（每台机器各自一份）。
  没有该文件时首次运行不 prune。Apply 先在状态目录写入唯一临时文件，写完后替换正式状态；
  写入或替换失败且正式文件未被外部改动时保留旧状态，但此前成功的 live 操作不会因此回滚。

```powershell
Set-Location '<repo-root>'
git pull --ff-only
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work -Apply
pwsh -NoProfile -File scripts/deploy.ps1 -Environment work
pwsh -NoProfile -File scripts/deploy.ps1 -Environment work -Apply
```

`-Apply` 会写真实 home：先审查 dry-run 的每一行，复用覆盖实际范围的有效所有者授权；缺少授权时才询问。
`AGENTS.md` Skill rules 10 的已批准持续授权覆盖 `work` 环境已选技能的更新；满足该节条件时，
后续任务可用 `deploy-skills.ps1` 完成部署和复核，无需再次申请同范围许可，不覆盖 combined/config Apply。
旧 Skill rules 9 的三平台 full 窄例外已随 Claude 退役，不再提供执行授权。
当前 work 持续授权仅覆盖 Codex/ZCode；选择变化、首次退役/prune、config Apply 仍按实际批准范围执行。
统一 CLI 的 `sync` 与 `env deploy <name>` 转发到 `deploy.ps1`；直接运行 `deploy-skills.ps1` 只处理
skills（§14）。仓库不安装 Git hooks，`git pull` 不会自动部署。
dry-run 和 Apply 各自重新计算计划；审核后如果源、live 目标或部署状态变化，重新 dry-run 并审核；
例外范围内条件不变时无需再次询问，任一变化即停止。
Apply 显示其计划后立即开始执行，不会暂停等待确认。
多台机器同步：一台修改并 push 后，其余机器各自 `git pull --ff-only` 再走本流程；部署状态每台机器各自
记录，互不复制。

### 部署后的只读复核

先从当前上下文或既有记录确定要证明的结论、版本、部署环境与已通过的检查，不另建台账。
若 build 和 scan 的输入未变，复用它们后运行以下现有入口；`<current-environment>` 使用实际部署集合，
例如当前记录为 `full` 时不改用较小的默认 `work`：

```powershell
pwsh -NoProfile -File scripts/config-status.ps1 -Platform Codex
pwsh -NoProfile -File scripts/deploy.ps1 -Environment <current-environment> -SkipBuild
```

逐项读回配置状态与部署计划。请求的文件均 in-sync、技能均 unchanged 且无未解释项时结束；
该结果只证明当前磁盘一致，不证明所有旧聊天已重载或开发速度已提升。若只问其中一类，只运行对应入口。
源码、构建输入或生成物变动、构建证据缺失时，先补 build 与 scan；有真实差异时只定位相关项。
源码与 runtime 的映射及排除由 build 定义，不另写全树比较去补回 `CREATION-LOG.md` 等源端备注。
已读取实际输出且覆盖当前版本的子代理检查直接复用；只有冲突、缺项、状态变化或必需独审才补相应检查。

---

## 5. 修改已有 skill 的流程

1. 只改 `skills-source/`，然后运行 `build-skills.ps1` 与 `scan-secrets.ps1`。
2. 提交 source / manifest / docs 变更（不提交 generated output），按授权 push。
3. 每台机器各自跑 dry-run，审查后按有效授权 `-Apply`。`work` 技能更新的持续授权只走
   `deploy-skills.ps1`；combined `deploy.ps1` 及 `full` 窄例外的边界见 §4。

**删除 skill** 时，build 同时从生成物和 manifest 移除名称。本机由 deploy-skills 部署过的目录下次 dry-run
显示为 `prune`；deploy-skills 从未部署过的旧目录按 unknown 保留，逐项审查后用 `-Retire` 显式点名：

```powershell
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work -Retire <old-skill>
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work -Retire <old-skill> -Apply
```

`-Retire` 只作用于 live 中存在、未被当前环境选中的目录；`.system` 永不进入计划。其它机器各自审查后执行同一命令。

---

## 6. 新增 skill 的流程

- 跨平台放 `skills-source/shared/<name>/`，单平台放 `claude-only/` 或 `codex-only/` 下。
- 至少要有 `SKILL.md`，不能含符号链接或 junction；`.system` 不是合法名称。
- 放进来前先审查：不重复、无 secrets / tokens、无机器私有路径（如 `C:\Users\<name>`）、无缓存或运行时状态。
- 可以手工复制，也可以用 `promote-skill.ps1`（先 dry-run，确认后 `-Apply`，会自动 build 并扫描）：

  ```powershell
  pwsh -NoProfile -File scripts/promote-skill.ps1 -Path <dir> -Name <name> -Type shared
  pwsh -NoProfile -File scripts/promote-skill.ps1 -Path <dir> -Name <name> -Type shared -Apply
  ```

  同名 skill 已存在时拒绝；`-Replace` 只替换同一类型，旧版本先移到 `tmp/skill-backups/<时间戳>/<Type>/<name>/`。
  build 或扫描失败时文件留在工作区等待审查，用 Git 回退。
- `CREATION-LOG.md` 这类备注文件可以留在源里，build 按 `RuntimeExcludePatterns` 从生成物剔除；备注里不要写机器名或本机路径。
- build 后确认各平台 `Built ... skills: N` 的变化符合预期。
- 要部署到本机，把名称加入相应环境（§13），再走 §4。

---

## 7. Codex `.system` 规则

`.system` 是 Codex 平台内置目录（标记文件 `.codex-system-skills.marker`），不受本仓库管理：build 与
deploy-skills 永远跳过它，doctor 只检查根条目。装有 Codex CLI 且 live 根没有 unknown 目录时，Codex live 根
会比受管数量多出这一个 `.system` 目录。规则见
[Hard rules](../AGENTS.md#hard-rules)。

---

## 8. 备份与恢复

deploy-skills 在 `update` 或 `prune` 一个目录前，把旧目录复制到下面的路径（`<StateRoot>` 默认是
`%LOCALAPPDATA%\ai-agent-dotfiles.deploy`）。每次 Apply 用一个新 `<stamp>`，成功或捕获异常时打印已创建的备份目录。
进程被强制终止可能来不及打印，重新 dry-run 查看残留并在备份根下查找对应时间和平台。

```text
<StateRoot>\skill-backups\<stamp>\<Platform>\<name>
<StateRoot>\skill-backups\<stamp>\interrupted\<Platform>\<name>
<StateRoot>\skill-backups\<stamp>\interrupted-staging\<Platform>\<name>
```

后两种路径分别保存本次操作所用的旧目录路径和暂存路径上的残留。名称可能重合，内容不一定属于本次操作的
skill；先检查残留、备份和目标内容，决定是按以下方式恢复旧内容，还是在审查计划并取得授权后再次 Apply
安装当前选集。不要根据残留名称推断它一定是完整备份。

若状态写入失败，先检查 live 目录与已报告的备份，再运行新的 dry-run 并逐项审查；旧状态可能仍记录已改变
的目录。强制终止可能留下 `deployed-skills.*.tmp`，不要把残留当作已提交状态；检查其归属和内容后再决定处理方式。
同目录替换保护正常写入或替换失败时的旧状态，不保证断电或强制终止时的持久化结果。

恢复方式：

- **从 Git 重新部署（首选）。** 受管 skill 被改坏时，检出想要的提交，跑 dry-run，审查后按授权 `-Apply`。
  被误删的受管 skill 加回环境后再部署。
- **从备份复制回来。** 需要部署前的旧内容（例如被 prune 的目录）时，经所有者授权，把备份目录复制回对应
  live 根下的 `<name>`（先确认目标不存在或已移开）。恢复后若仍被环境选中，下次 dry-run 按内容显示
  `update` 或 `unchanged`；若不再选中，则看部署状态：名字仍在状态里（prune 后尚未成功 Apply，或 Apply
  在写状态前失败）显示 `prune`，成功的 Apply 已把它从状态移除后显示 `unknown`，需要再删时用
  `-Retire` 点名。

备份不含 Codex `.system`、未选中且未点名退休的 unknown 目录和 home 配置；整机 home 恢复由平台/所有者自行处理。
config-pull 的备份见 §11。

按失败阶段选择下一步：

| 看到的结果 | 先核对什么 | 后续操作 |
|---|---|---|
| `Preflight failed` | 两个预览中的具体错误；预检可能重建仓库生成物，但尚未写 live 或部署状态 | 修复该阻塞，重新预览后按原授权范围执行 |
| `Skills stage completed; config stage failed` | skills 当前内容、部署状态、config 错误与其备份 | 不假定整体回滚；释放文件占用等阻塞后，重新预览所需阶段 |
| `Deployment state update failed` | live 目录与本次备份；此前成功操作可能已生效 | 不依据旧状态认定未部署，核对新的逐项计划 |
| `.deploying-*` 残留或强制终止 | writer 是否停止、精确残留和备份内容 | 不按名称批量删除；依本节恢复说明逐项判断 |

恢复或重试不能扩大授权范围；原授权要求失败即停或结果未知时保留其边界。

---

## 9. 常见问题

**dry-run 显示 `unknown`？** 该目录未被当前环境选中，也不在部署状态或 `-Retire` 中；它可能来自手工安装、
其它工具或旧部署，状态文件丢失时也可能是本工具以前部署的目录。当前计划只报告并保留它；确认不再需要后，
先用 `-Retire <name>` 预演，再按授权 Apply。

**scan-secrets 报 false positive？** 改写源文档或示例措辞，让它不再像真实密钥（例如说明从环境变量读取），
然后重新 build + scan。不要 whitelist 或削弱扫描。

---

## 10. 检查与 CI

本地检查清单、CI 和红灯处理见 AGENTS.md 的 [Checks and CI](../AGENTS.md#checks-and-ci)。全量测试：

```powershell
pwsh -NoProfile -File scripts/run-tests.ps1
```

它打印汇总，任一套件失败或超时即以 1 退出；每个套件的时间预算在 `tests/test-timeouts.psd1`。
CI 同款的全量验证入口是 `scripts/run-repository-validation.ps1`（语法、gitleaks 校验、build、秘密扫描、
doctor、manifest 一致性、全部测试套件、危险文件检查与干净树，逐 gate 顺序执行）。

config-sync 测试的 repo/home/backup fixtures 位于忽略的 `tmp/tests/config-sync/<run-id>/`。
正常失败会先在 `receipts/` 保存小型记录再清理；超时或跳过 finalization 的子进程保留其所属目录。
父进程退出和输出排空不证明所有 writer 已停止；`cleanup_requested` 只表示清理意图。
profile fixtures 位于 `tmp/tests/harness-profile/`，成功清理、失败保留；仓库位于用户 home 内时拒绝生成 fixtures，
不回落到其他目录。清理前核对实际目录、归属和 writer 状态。

部署规划会拒绝被普通文件占用的选中 skill 目标。profile build/apply 拒绝目标路径及祖先的 reparse point；
profile 写失败时，将当前尝试写入的文件也纳入 best-effort rollback。

---

## 11. Harness 配置同步（config-sync）

配置 status/pull/push 默认仅处理 Codex；只有显式 `-Platform Claude` 才会读写旧 Claude 配置。
组合部署沿用 Codex-only 默认。

除 skills 外，仓库还管理 harness 配置。源是 `manifests/whitelist.psd1`（每平台的 Push/Pull items 与
ExcludedItems，以及所有平台都不捕获的 `CommonExcludedItems`：密钥、证书、备份与临时文件类）。

- `config-status.ps1`：只读 drift 报告（repo ↔ home），逐项报告 in-sync / differs / repo-only / home-only，遵守 ExcludedItems。
  Claude `settings.json` 两侧都是不同的 JSON 对象时，普通文本输出还显示字段的 JSON Pointer 路径：
  `home-only` 字段会由结构化合并保留，`repo-only` 字段会新增，`changed` 或 `type-changed` 字段会替换。
  `in-sync` 也可能带 `home-only field(s) preserved` 说明；文件字节不同不代表需要同步。
  输出字段名但不输出字段值；字段名本身可能包含私有信息，分享终端输出前须审查。数组按整体比较。
  Codex `AGENTS.md` 比较受管 block；缺少 block 时报告 `managed block missing`，不能按整文件相同视为已同步。
  JSON 无效、键重复或根不是对象时报告无法比较，须手工检查。
  非 JSON 文件仍只报告文件级差异；`-Json` 保持原有文件级数组格式，不包含字段摘要。
- `config-pull.ps1`：repo → home。默认 dry-run；`-Apply` 先扫密、逐文件备份被覆盖项再写入。
  Claude `settings.json` 递归合并对象：repo 中的键和值覆盖 home，数组整体替换，home-only 键保留；
  repo 中不存在的 home 键不会被删除，因此字段删除仍需人工审查。
  Codex `AGENTS.md` 只更新 `<!-- BEGIN AI-AGENT-DOTFILES: codex/AGENTS.md -->` 与
  `<!-- END AI-AGENT-DOTFILES: codex/AGENTS.md -->` 之间的内容，block 外的个人文本保留。
  已有文件没有 block 时，仅当内容已等于 repo 才自动包裹；否则 fail closed，要求先手工放置 block。
  备份默认写入 `~\.ai-agent-dotfiles-backups\config-backup-<UTC 时间戳>\`（`-BackupRoot` 可改）；
  不整目录 mirror、不 prune（home-only 文件原样保留）。捕获复制异常后，尽力回滚本次已尝试写入的文件：
  更新项从备份恢复，新增项删除。单项回滚失败会告警并继续还原其他项，保留备份并重新抛出原始复制错误。
  这是异常处理中的恢复，不保证进程被强制终止后的还原。
- `config-push.ps1`：home → repo。默认 dry-run；`-Apply` 先把捕获写入暂存目录
  `~\.ai-agent-dotfiles-backups\config-push-stage-<UTC 时间戳>\`，再过两道 gate：扫密 + 机器私有路径扫描
  （盘符/UNC 绝对路径），任一命中即回滚全部捕获。结果保持未提交，必须人工 `git diff` 审查后再提交。
  `-SkipPathScan` 仅在绝对路径确属有意时使用。
  Codex `AGENTS.md` 有受管 block 时只捕获 block 正文，block 外的个人文本不写入 repo。
- Codex `config.toml` 和私有 `.env` 不纳入；push 仅捕获本机已有的白名单文件。
- Claude 配置模板启用 `codex@openai-codex`；模板市场声明不代表插件已经安装或加载。
- 模板不带模型与推理档位，但这不表示可以删除个人设置：结构化合并会保留 home-only 顶层和嵌套字段；
  审查 dry-run 时仍须确认 repo 管理的字段变化。
- `deploy.ps1` 把 skills 与 config-pull 串成一个 dry-run/apply 入口；两阶段不原子，
  config 失败不会回滚已完成的 skills。只用 skills 时直接运行 `deploy-skills.ps1`。
- 回归测试：`pwsh -NoProfile -File tests/config-sync.tests.ps1` 和
  `pwsh -NoProfile -File tests/deploy.tests.ps1`。

排查漂移时，先在仓库根目录运行只读状态报告：

```powershell
pwsh -NoProfile -File scripts/config-status.ps1
```

`differs` 只表示当前同步口径不同，不代表可以盲目覆盖。Claude 字段摘要显示路径而不显示值；
home-only 字段由结构化合并保留。Codex `AGENTS.md` 的状态按受管 block 比较，仍可在自己的终端本地检查：

```powershell
git --no-pager diff --no-index --no-ext-diff -- codex/AGENTS.md "$env:USERPROFILE/.codex/AGENTS.md"
```

先确认两侧文件可访问并检查错误输出：成功比较时退出码 `0` 表示相同，`1` 表示有差异；
访问失败等错误也可能返回 `1`，不能只凭退出码判断比较成功。差异可能包含个人内容，
不要直接粘贴、分享、重定向或提交到仓库。先区分仓库更新和个人覆盖，再审查对应的 config-pull 或 config-push
dry-run；保留需要的个人覆盖，live `config-pull -Apply` 仍须在审核后取得所有者授权。不要因为发现漂移就直接覆盖。

---

## 12. Project Harness Profiles

Build and apply reject reparse points in profile, generated, output and backup paths,
including their existing ancestors. If an Apply write fails after changing its destination,
best-effort rollback includes that current file as well as earlier attempted writes.

`harness-source/` 存放可复用的 component/profile 定义，为某个项目生成 `.agent-harness/generated/` 下的本地输出。
项目用 `.agent-harness/profile.psd1` 声明选择；只处理项目本地文件，不切换全局 home harness。

项目与库 profile 的合法顶层键相同：`SchemaVersion`（必须为 `1`）、`Name`、`TargetPlatforms` 为必填，
`Extends` 与 `Components` 可选。`Extends` 只接受 `harness-source/profiles/<id>.psd1` 的 profile id，
不接受路径；库 profile 也能继续继承，循环会被拒绝。解析顺序为父先子后、项目最后，列表按该顺序合并去重。
当前库链是 `coding` 继承 `base`；本仓项目继承 `coding`，因此依次应用 `base`、`coding`、项目声明。

```powershell
pwsh -NoProfile -File scripts/status-harness-profile.ps1 -ProjectRoot <project>
pwsh -NoProfile -File scripts/status-harness-profile.ps1 -ProjectRoot <project> -Json
pwsh -NoProfile -File scripts/build-harness-profile.ps1 -ProjectRoot <project>
pwsh -NoProfile -File scripts/apply-harness-profile.ps1 -ProjectRoot <project>
pwsh -NoProfile -File scripts/apply-harness-profile.ps1 -ProjectRoot <project> -Apply
```

- `status-harness-profile.ps1`：只读状态/漂移报告；`-Json` 向 stdout 输出 JSON，含解析后的 profile、组件、目标与源文件。
- `build-harness-profile.ps1`：只写目标项目的 `.agent-harness/generated/`；每次构建先确认该目录是普通目录
  （reparse point 直接拒绝），然后整树替换再重建，manifest 只列本次产物。`-Clean` 仍被接受，仅为兼容
  旧命令行的空开关。
- `apply-harness-profile.ps1`：默认 dry-run；`-Apply` 只写 allowlisted 项目输出和 `.agent-harness/backups/`
  下的项目本地 rollback backup，不写 home 或 live skills。
- 受控输出类型：Rule 写 `AGENTS.md` / `CLAUDE.md` 的 managed block——已存在但没有任何
  `BEGIN/END AGENT-HARNESS` 标记的文件按 skip 处理（不插入），只替换已有标记块；Prompt 只进
  `.agent-harness/generated/`，Claude `.claude/commands/`、`.claude/agents/` 与
  `.claude/settings.json`（结构化合并），Codex `.codex/prompts/`、`.codex/agents/`。
- Profile 的 `Components` 只列用到的 bucket（`Rules`、`Prompts`、`Commands`、`Agents`、`ClaudeSettings`、
  `CodexAgents`），没列的 bucket 视为空；未知 bucket 或未知顶层 key 会被拒绝。
- 改 profile/component 或这几个脚本后跑 `tests/harness-profile.tests.ps1`。

---

## 13. Harness Environments

环境是命名的 skills 选集：`harness-source/envs/<name>.psd1`。deploy-skills 只消费 `Skills`：必须恰好有
`Claude`、`Codex`、`Zcode` 三个键（不要 skill 的平台写 `@()`；Zcode 从 Claude 生成物投影，
只有 Claude 可构建的 skill 才能选给 Zcode），否则拒绝运行，避免把缺键误读成空选集而
prune 全部。`env list` 显示文件名、`Description` 与各平台的 skill 名称和数量；`SchemaVersion` 与 `Name` 是声明性元数据，脚本不校验。

当前环境：`minimal`（测试样例）、`work`（日常）、`full`（全部受管 skills）；内容与数量见 [STATUS.md](../STATUS.md)。
`work.Claude` 为空；`claude/skills/` 仍为 ZCode 提供构建投影，保留共享源和生成链。
共享 `base`/`coding` 及本仓 profile 默认仅 Codex，不再自动选择 ClaudeSettings；旧 Claude 组件仍可显式选择。
当前 `work` 为 Claude/Codex/ZCode 0/9/8：shared `subagent-driven-development` 仅在 Codex `work` 选入，
`full` 三平台均包含。该 Skill 是委派执行约定，不授予新权限；具体额度以 [AGENTS.md](../AGENTS.md)
和当前宿主限制为准，操作细节见 [Skill](../skills-source/shared/subagent-driven-development/SKILL.md)。

新增受管 skill 时，除放入 `skills-source/` 外，还要在目标环境的各平台 `Skills` 数组中选入；
`full` 也是显式清单，需要同步维护。用 `env list` 核对选择，再用部署 dry-run 核对实际计划。
构建及部署准备的当前结果见 [STATUS.md](../STATUS.md)。

`approval-feedback` 已选入 Codex/ZCode `work`；兼容 `full` 仍包含三平台，以全局 Skill 发现方式使用。它在准备执行确认、
收到评分反馈或定位重复审批旧规则时介入，先复用已有授权；评分只评价打断价值，不授予权限。
收到 0／1 分或“纠错未落实”的反馈时，在当前响应中处理具体来源：纠正执行误读并完成已授权工作，
或立即提出项目级持续扩权：给出精确规则差异、原因、风险、继承范围和撤销方式，由用户一次审批规则写入
及所列执行范围。批准后落到项目正式入口，后续任务／会话读取有效条款后直接继承，不重复批准同类动作；
不等更多评分或多个独立任务。平台硬审批保留。源码、部署、加载与实际行为效果分别报告。
同一项目反复扩权时，检查权限源文件的分类、冲突和继承入口，合并同类规则而非叠加临时例外；
按是否改变实际权限区分处理，不以编辑了源文件就一律增加审批：

| 情形 | 处理 |
|---|---|
| 整理、合并、澄清，权限含义不变 | 直接完成并在原任务结果中通知用户 |
| 新增权限，或在源文件中永久改变有效权限及其边界 | 先给出精确差异、原因、风险和继承范围，由用户审批后落实 |
| 已批准范围内的写入、验证及所列执行 | 连续完成；后续任务读取有效正式条款后继承，不为同一权限重复审批 |

相关变更真正超出授权、用户撤销或平台强制审批时，才补相应决定；纯整理不以“权限修正”为名扩大权限。
退役前 `work` 部署的三平台读回及 25 项不变历史结果见 [STATUS.md](../STATUS.md)，这不代表未来会话效果已验证。
详细交互、私有台账、失败处理和效果核验以
[Skill](../skills-source/shared/approval-feedback/SKILL.md) 及其 `references/` 为准；
安装 Skill 与新增免重复确认规则分别授权。部署仍先审阅实际 dry-run，再按覆盖实际范围的有效授权 Apply；
客户端是否需要新任务加载另行验证。

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env list
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env list -JsonPath <report-file>
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env deploy work -DryRun
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment full
```

- 列表末尾显示部署状态中记录的上次成功 Apply 环境；记录缺失、结构无效、无环境名或无法读取时显示 `unavailable`。
  这只是记录，不验证 live 内容。`env list -StateRoot <path>` 可指定部署状态目录，默认与 deploy-skills 相同。
  `unavailable` 后另列固定原因：`missing-state`（文件不存在）、`invalid-json`（无法解析）、
  `invalid-state`（结构或环境值无效）、`missing-environment`（缺少或空白环境名）、`read-error`（读取失败）。
  不打印原始记录或异常内容；该原因不能用来推断 live skills 是否存在。
- `env list -JsonPath <report-file>` 仍打印上述列表，同时把 `Environments`（每项仅有 `Name`、`Description`）写入 JSON 文件。
- 选集只能包含已有 generated output 的 skill，缺失时 deploy-skills 报错停止。
- 切换到较小环境时，上次由 deploy-skills 部署、本次不再选中的目录进入 `prune`（先备份）。
- 任务临时需要的 skill 不要写回 `work.psd1`；长期需要时在评审过的提交里改环境定义。
- Codex 官方行为是自动检测 skill 变更；若更新未出现，重启 Codex。已在同一上下文中加载的旧
  `SKILL.md` 正文不会因目录刷新而改写，因此 `approval-feedback` 要求版本不明时重新读取当前文件。
  参考 [Build skills](https://learn.chatgpt.com/docs/build-skills)。

技能使用效果沿用 [STATUS.md](../STATUS.md) 的证据层级：部署后先确认客户端发现并读取当前版本，
再在下一次自然发生的适用任务中观察是否实际采用、是否减少重复确认或排障绕路。
例如需要沉淀经验时可说“把这次排障中值得复用的经验沉淀到项目文档”，核对是否得到有适用条件、
有效做法和验证依据的内容。用当前任务记录保留有证据的结果和未测项；不为验证 skill 人造审批、
启动后台采集或额外付费调用，一次采用也不能证明长期效果提升。

---

## 14. 统一 CLI

`scripts/agent-dotfiles.ps1` 只负责路由，把参数原样转给底层脚本：

```text
help                         显示用法
doctor                       -> scripts/doctor.ps1
build                        -> scripts/build-skills.ps1
scan                         -> scripts/scan-secrets.ps1
sync                         -> scripts/deploy.ps1
env list                     列出 harness-source/envs/*.psd1
env deploy <name>            -> scripts/deploy.ps1 -Environment <name>
config status | pull | push
profile status | build | apply
skills promote               -> scripts/promote-skill.ps1
```

用 `pwsh -NoProfile -File scripts/agent-dotfiles.ps1 help` 查看命令概览。
用 `help config` 或 `config help` 查看分组帮助；`env`、`profile`、`skills` 支持相同拼法。
帮助说明操作方向、写入范围和常用示例，不执行子脚本。`config push` 仅捕获本机配置到仓库，不是 Git push。

doctor 的 WARN 和退出码保持原有语义，摘要另列已检测到的 `Deploy blockers`。
双 Codex live 根会阻塞部署；未安装的平台根、dirty tree 和跳过 secret scan 等提醒不自动归为阻塞。
`none detected by these checks` 也不表示部署已通过预检，仍须审查 dry-run。

只读命令：`doctor`、`scan`、不带 `-JsonPath` 的 `env list`、`config status`、`profile status`。`build` 与 `profile build`
只生成可重建输出；`env list -JsonPath` 还会写入指定的报告文件。会写 live home、`skills-source/` 或项目目标的命令（`sync`、`env deploy`、`config pull/push`、
`profile apply`、`skills promote`）要求显式 `-DryRun` 或 `-Apply`，统一入口不会自动补 `-Apply`。
`sync` 与 `env deploy` 都串行执行 skills 和 config；两阶段不原子。直接运行低层脚本可只执行单个阶段。

底层命令支持 `-Json` 时可直接透传，例如 `profile status -ProjectRoot <project> -Json`；统一 CLI
会抑制自己的调用提示和结果提示，让 stdout 保持底层 JSON。`env list` 使用上面的 `-JsonPath`，不支持 `-Json`。
