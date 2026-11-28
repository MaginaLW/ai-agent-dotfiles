# ai-agent-dotfiles 使用说明

日常工作环境是 Codex；Antigravity 另有插件与全局规则。操作权限见 [AGENTS.md](../AGENTS.md)。首次安装见[新电脑接入](ONBOARD_NEW_MACHINE.md)，配置排查见 [Codex 本机指南](CODEX_TUNING.md)，当前进展见 [STATUS.md](../STATUS.md)。

## 目录

- **基础与日常同步：** [1. 项目目的](#1-项目目的) · [2. 当前管理范围](#2-当前管理范围) · [3. 目录说明](#3-目录说明) · [4. 日常同步流程](#4-日常同步流程)（[部署后复核](#部署后的只读复核)）
- **Skills 与维护：** [5. 修改已有 skill](#5-修改已有-skill-的流程) · [6. 新增 skill](#6-新增-skill-的流程) · [7. Codex `.system`](#7-codex-system-规则) · [8. 备份与恢复](#8-备份与恢复) · [9. 常见问题](#9-常见问题) · [10. 检查与 CI](#10-检查与-ci)
- **配置、环境与工具：** [11. Harness 配置同步](#11-harness-配置同步config-sync) · [12. Project Harness Profiles](#12-project-harness-profiles) · [13. Harness Environments](#13-harness-environments) · [14. 统一 CLI](#14-统一-cli)
- **Antigravity、MCP 与监控台：** [15. Antigravity 插件](#15-antigravity-插件) · [16. 受管 MCP 分发](#16-受管-mcp-分发mcp-sync) · [17. 本地可视化监控台](#17-本地可视化监控台dashboard)

## 1. 项目目的

跨项目偏好写入各宿主的全局文件。某个仓库特有的构建命令、验收条件和批准范围写进该项目入口。Antigravity 的受管全局路径适用于 App 和 CLI。各宿主加载行为见 [Codex](https://learn.chatgpt.com/docs/agent-configuration/agents-md) 和 [Antigravity](https://antigravity.google/docs/rules/)。

重复流程写成 skill，描述开头点明适用任务，详细步骤和资料随用随读。需要一起分发的技能或连接才组成插件。需要读取实时数据或执行外部动作时，再为对应宿主声明 MCP 服务并核实工具调用结果。[GPT-6.2 任务示例](CODEX_TUNING.md#用-gpt-62-交代任务) · [技能与 MCP 的分工](https://developers.openai.com/plugins/concepts/skills)

同步默认预览，部署逐目录进行。手工恢复 live 技能仅限 §8 的已授权恢复。

---

## 2. 当前管理范围

每个环境从构建目录中选取要部署到 Codex 的技能。

- Codex 从 `codex/skills/` 部署到 `~/.codex/skills`。只有该目标不存在时才使用 `~/.agents/skills`，两者都存在时拒绝部署。

不管理：Codex `.system`；未选中、未记录在部署状态且未被 `-Retire` 点名的 live 目录（unknown，只报告）；部署状态与备份
（repo 外的 `%LOCALAPPDATA%\ai-agent-dotfiles.deploy`）；机器私有配置与 secrets。

---

## 3. 目录说明

| 路径 | 说明 |
|---|---|
| `bootstrap.ps1` | 新 clone 一次性入口：安装并校验 pinned gitleaks、build、打印联合 deploy dry-run 命令；不写 live |
| `STATUS.md`、`status/active/` | 全局状态（原地更新）与进行中任务记录（完成后结论并入 `STATUS.md` 并删除） |
| `codex/AGENTS.md`、`antigravity/AGENTS.md` | Codex / Antigravity 全局工作协议源（受管 block 分别同步至 `~/.codex/AGENTS.md`、`~/.gemini/config/AGENTS.md`，§11） |
| `skills-source/` | 技能源目录，分为 `shared/`、`codex-only/` |
| `codex/skills/` | 构建生成的 Codex 技能目录，Git 忽略，勿手改 |
| `manifests/managed-skills.codex.txt` | Codex 受管技能名单，由 build 刷新 |
| `manifests/whitelist.psd1` | config-sync 的 Push/Pull items 与 ExcludedItems（§11） |
| `harness-source/` | 环境定义 `envs/`（§13）、profile/component 源（§12）、Antigravity 插件清单（§15）与受管 MCP 注册表 `mcp/servers.psd1`（§16） |
| `.agent-harness/profile.psd1` | 当前项目的 profile 声明（§12） |
| `.agent-harness/generated/` | 项目本地 profile 生成物，Git-ignored，可重建 |
| `tools/gitleaks/` | pinned gitleaks 的版本、下载地址与校验锁 |
| `.gitleaks.toml` | 仓库秘密扫描规则 |
| `scripts/` | build、scan、deploy（§4）、promote（§6）、config（§11）、profile（§12）、测试与校验入口（§10）、只读 `doctor.ps1`、统一 CLI（§14） |
| `dashboard/` | 本地中文可视化监控台源码（`server.py`、`lib/` 模块、`index.html` 与 `static/` 静态资源，纯 Python 标准库，仅监听 `127.0.0.1`，§17） |
| `start-dashboard.cmd` | Windows 一键双击启动入口（纯 ASCII + CRLF），转调 `scripts/dashboard.ps1` 打开本地中文监控台（§17） |

`scripts/pinned-tool.ps1` 从调用方传入的 `-LockPath` 读取工具锁文件；gitleaks 的锁路径由
`scripts/install-gitleaks.ps1`、扫描和 doctor 等调用方传入，不在通用 helper 中固定。
直接 release 下载失败时，按锁定的 owner／repo／tag／asset 名称查询官方 GitHub Releases
API；下载结果仍必须通过锁文件中的压缩包与可执行文件 SHA-256 双重校验。

---

## 4. 日常同步流程

`deploy.ps1` 是日常联合入口：先按 `harness-source/envs/<name>.psd1` 的 `Skills` 清单（日常用 `work`）部署 skills，
再按 Codex-only 默认运行 `config-pull.ps1`。Apply 前先顺序运行两阶段现有的 dry-run 规划器，规划失败时不写 live skills、
config 或部署状态；skills 预检完成的 build/scan 在紧接的 skills Apply 中复用，config Apply 仍保留写前扫描。
预检不验证所有写权限、备份可用性或并发变化，也不冻结计划；两阶段不是原子事务，运行时 config 阶段失败时
已完成的 skill 阶段保持完成，并明确报告边界。
`deploy-skills.ps1` 按所选环境把技能逐目录部署到 Codex 的 live 根。

- 默认先跑 build 与 scan，任一失败即停止。`-SkipBuild` 同时跳过两者；除隔离测试外，只有已有成功结果覆盖当前未变的源码、构建输入和生成物时，才可在同一已授权部署链或只读复核中复用，不能把它当作省略必需检查的入口。
- 每个目录给出 `install`、`update`、`unchanged`、`prune` 或 `unknown`；不带 `-Apply` 不写 live 根或部署状态。
  对状态中没有记录的同名目录，`update` 会提示其归属未知且将备份后覆盖；状态缺失不代表目录一定未受管。
- 预览显示实际目标目录（`~/.codex/skills` 或 `~/.agents/skills`）。`prune` 只删除本工具上次部署过、本次不再选中的目录，或 `-Retire` 点名的未选中目录。
- 其余 live 目录是 unknown，只报告不碰。Codex `.system` 永不触碰；遇到 reparse point 直接拒绝。
- 替换靠整目录改名：先复制到同级 `.deploying-<name>` 再换名；文件被占用时不会半删旧目录。
  两次改名之间中断时目标可能暂时缺失。计划会报告 `.deploying-*` 残留及备份根；再次对该 skill 做
  install/update/prune 时，先备份该操作的两个残留路径再清理；其他残留只报告，不自动清理。
  合法名称可能使一个 skill 的暂存路径与另一个 skill 的旧目录路径重合，所以不能仅凭名称判断其归属。
- `update` 和 `prune` 前先备份旧目录（§8）。
- 逐项计划后显示各操作的数量汇总；汇总不能代替逐项审查。仅在预览模式（未传 `-Apply`）时支持 `-Json`，抑制控制台文本并向 stdout 输出 `SchemaVersion = 1` 的结构化计划（含 `Mode`、`Environment`、`LiveRoot`、`Summary`、`Items`、`UnrecordedUpdates`、`InterruptedRemnants`，不含本机 `HomeRoot`/`StateRoot` 绝对路径）；`-Json` 与 `-Apply` 同时传入会报错停止。
- 显示上次记录的环境 → 本次目标环境（记录不证明 live 内容）；prune 区分“此前受管、本次未选中”
  和显式 `-Retire`。install/update 复用现有文件哈希比较，列出相对文件名的 add/change/remove，
  不打印文件内容或哈希。文件名本身也可能包含私有信息，分享输出前仍需审查。
- 每台机器上次部署的环境和技能记录在 `%LOCALAPPDATA%\ai-agent-dotfiles.deploy\deployed-skills.json`。旧记录中的已退役平台键（Claude、Zcode、Reasonix）会被忽略，本机已有对应目录由用户管理。
  没有该文件时，首次运行只会清理显式 `-Retire` 的目录。已有记录不可读或结构无效时，部署会在生成计划前停止。旧记录可缺少环境名，其 `Codex` 字段必须是技能名称数组。Apply 先在状态目录写入唯一临时文件，写完后替换正式状态；
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
当前 work 持续授权仅覆盖 Codex；选择变化、首次退役/prune、config Apply 仍按实际批准范围执行。
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
   `deploy-skills.ps1`；combined `deploy.ps1` 及 `full` 部署需获得覆盖实际范围的许可（§4）。

**删除 skill** 时，build 同时从生成物和 manifest 移除名称。本机由 deploy-skills 部署过的目录下次 dry-run
显示为 `prune`；deploy-skills 从未部署过的旧目录按 unknown 保留，逐项审查后用 `-Retire` 显式点名：

```powershell
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work -Retire <old-skill>
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work -Retire <old-skill> -Apply
```

`-Retire` 只作用于 live 中存在、未被当前环境选中的目录。点名仍在选集内的技能会在构建前报错，请先确认目标环境及其选集。`.system` 永不进入计划。其它机器各自审查后执行同一命令。

---

## 6. 新增 skill 的流程

- 跨端共享（供 Codex 及可选 Antigravity 插件复用）的技能放 `skills-source/shared/<name>/`。仅限 Codex 的技能放 `skills-source/codex-only/<name>/`。
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
| `Skills preview failed` 或 `config preview failed` | 当前是 dry run，live 目录和部署状态均未写入 | 按出错阶段修正输入，重新预览 |
| `Preflight failed` | 两个预览中的具体错误；预检可能重建仓库生成物，但尚未写 live 或部署状态 | 修复该阻塞，重新预览后按原授权范围执行 |
| `Skills Apply failed before the config stage` | 配置阶段尚未开始，核对已处理的 skills、部署状态及本次备份 | 按实际写入结果处理失败项，重新预览 |
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

**Teamwork 看板与 Goal 怎么用？** 调用 `$teamwork` 或 `/teamwork` 进入执行或交付（非纯规划、非 Plan Mode，
且用户未显式说明不用 Goal）时，会自动先调用 `get_goal` 检查状态：有匹配的未完成 Goal 则续接，存在冲突的未完成
Goal 则先询问，若无未完成 Goal 则按用户请求的完整计划或里程碑自动调用 `create_goal`；仅制定计划时既不创建
Goal 也不启动看板。Lead 不会把 Goal 缩窄为首批子集，也不会在后续波次或可询问的收尾/门禁授权仍未处理时提前标记
`complete`。看板方面，用 `coordination.py --manifest ... --reuse` 启动或复用运行中看板并在原会话右侧打开；
工具返回 `queued` 后保持原请求等待，并通过 `run.py status --manifest ...` 或 `GET /api/health` 核实
`uiGets >= 1`、`statePolls >= 1` 与实时事件。可写队友互审走 `requires_review: true` 门禁签名；
`readonly` 订阅审查通过宿主返回，由 Lead 将外部任务 ID、核对版本和结论记入 `release --text` 与验收报告。
注意：Codex Desktop 会在已打开窗口中缓存 `~/.codex/prompts/`（更新 slash prompt 后需使用
File -> New Window / 文件 → 新窗口或重启以重新加载），而 `$teamwork` 的 `SKILL.md` 在每次调用时从磁盘读取
（仍在运行中的旧会话仍需重新调用或重新读取更新后的技能文本）。具体步骤见
[teamwork SKILL.md](../skills-source/codex-only/teamwork/SKILL.md) 与
[swarm SKILL.md](../skills-source/codex-only/swarm/SKILL.md)。

---

## 10. 检查与 CI

运行全量测试前，先确认当前检出位于 `$env:USERPROFILE` 之外。`harness-profile` 套件会在创建测试目录前拒绝位于用户主目录内的检出。若当前工作树在主目录内，请从主目录外的干净检出核对 `git rev-parse HEAD` 与待验提交一致，再运行下面的命令。[本地检查与 CI](../AGENTS.md#checks-and-ci)

```powershell
pwsh -NoProfile -File scripts/run-tests.ps1
pwsh -NoProfile -File scripts/run-tests.ps1 -MaxParallel 2
pwsh -NoProfile -File scripts/run-tests.ps1 -Suite repository-policy
```

它按 `tests/test-timeouts.psd1` 预算从长到短（LPT）并发调度测试套件，默认 `-MaxParallel` 为 `min(4, max(1, CPU 核数))`（有效范围 `1..32`，指定 `-Suite` 时自动以 `1` 串行运行）；每个套件缓冲独立输出并在结束后整块打印以避免并发日志交错，超时后终止进程树并执行 `config-sync` 清理契约，任一套件失败或超时即以 1 退出。
CI 同款的全量验证入口是 `scripts/run-repository-validation.ps1`（PowerShell 与 Python 语法、gitleaks 校验、build、秘密扫描、
doctor、manifest 一致性、全部测试套件、危险文件检查与干净树，逐 gate 执行；GitHub Actions 使用 `actions/cache@v4` 按 `tools/gitleaks/gitleaks.lock.json` 缓存固定版本 gitleaks，仍通过 `install-gitleaks.ps1` 执行压缩包与可执行文件双重 SHA-256 校验）。

config-sync 测试的 repo/home/backup fixtures 位于忽略的 `tmp/tests/config-sync/<run-id>/`。
正常失败会先在 `receipts/` 保存小型记录再清理；超时或跳过 finalization 的子进程保留其所属目录。
父进程退出和输出排空不证明所有 writer 已停止；`cleanup_requested` 只表示清理意图。
profile fixtures 位于 `tmp/tests/harness-profile/`，成功清理、失败保留。清理前核对实际目录、归属和 writer 状态。

部署规划会拒绝被普通文件占用的选中 skill 目标。profile build/apply 拒绝目标路径及祖先的 reparse point；
profile 写失败时，将当前尝试写入的文件也纳入 best-effort rollback。

---

## 11. Harness 配置同步（config-sync）

配置 status/pull/push 默认只处理 Codex。传入 `-Platform Antigravity` 可选择 `antigravity/AGENTS.md` 与 `~/.gemini/config/AGENTS.md`。
组合部署沿用 Codex-only 默认。

除 skills 外，仓库还管理 harness 配置。源是 `manifests/whitelist.psd1`（每平台的 Push/Pull items 与
ExcludedItems，以及所有平台都不捕获的 `CommonExcludedItems`：密钥、证书、备份与临时文件类）。

- `config-status.ps1`：只读 drift 报告（repo ↔ home），逐项报告 in-sync / differs / repo-only / home-only，遵守 ExcludedItems。
  Codex 与 Antigravity `AGENTS.md` 均比较受管 block；缺少 block 时报告 `managed block missing`，不能按整文件相同视为已同步。
  `-Json` 输出文件级状态数组。
- `config-pull.ps1`：repo → home。默认 dry-run（仅预览模式支持 `-Json`，抑制控制台文本并输出 `SchemaVersion = 1` 的结构化计划，含 `Platforms`、`Summary`、`Items`，不含 `HomeRoot` 或文件内容，禁止与 `-Apply` 同用）；`-Apply` 先扫密、逐文件备份被覆盖项再写入。
  Codex 与 Antigravity `AGENTS.md` 分别只更新 `<!-- BEGIN AI-AGENT-DOTFILES: codex/AGENTS.md -->` /
  `<!-- BEGIN AI-AGENT-DOTFILES: antigravity/AGENTS.md -->` 对应的受管 block，block 外的个人文本保留。
  已有文件没有 block 时，仅当内容已等于 repo 才自动包裹；否则 fail closed，要求先手工放置 block。
  备份默认写入 `~\.ai-agent-dotfiles-backups\config-backup-<UTC 时间戳>\`（`-BackupRoot` 可改）；
  不整目录 mirror、不 prune（home-only 文件原样保留）。捕获复制异常后，尽力回滚本次已尝试写入的文件：
  更新项从备份恢复，新增项删除。单项回滚失败会告警并继续还原其他项，保留备份并重新抛出原始复制错误。
  这是异常处理中的恢复，不保证进程被强制终止后的还原。
- `config-push.ps1`：home → repo。默认 dry-run；`-Apply` 先把捕获写入暂存目录
  `~\.ai-agent-dotfiles-backups\config-push-stage-<UTC 时间戳>\`，再过两道 gate：扫密 + 机器私有路径扫描
  （盘符/UNC 绝对路径），任一命中即回滚全部捕获。结果保持未提交，必须人工 `git diff` 审查后再提交。
  `-SkipPathScan` 仅在绝对路径确属有意时使用。
  Codex 与 Antigravity 的 `AGENTS.md` 只捕获对应受管块的正文。已有文件缺少该块时，预览和捕获都会停止。先核对要共享的规则、标出受管范围，再重新预览，个人规则留在块外。
- Codex `config.toml` 和私有 `.env` 不纳入；push 仅捕获本机已有的白名单文件。
- 模板沿用用户选择的模型与推理档位，同步前按 dry-run 核对受管内容。
- `deploy.ps1` 把 skills 与 config-pull 串成一个 dry-run/apply 入口；两阶段不原子，
  config 失败不会回滚已完成的 skills。只用 skills 时直接运行 `deploy-skills.ps1`。
- 回归测试：`pwsh -NoProfile -File tests/config-sync.tests.ps1` 和
  `pwsh -NoProfile -File tests/deploy.tests.ps1`。

排查漂移时，先在仓库根目录运行只读状态报告：

```powershell
pwsh -NoProfile -File scripts/config-status.ps1
```

`differs` 表示文件内容或受管块存在差异。Codex `AGENTS.md` 在同步时只比较受管块。如需查看整个文件，可在本机运行以下命令。

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
- 项目 profile 仅支持 Codex。Rule 更新 `AGENTS.md` 的受管块，已有文件缺少 `BEGIN/END AGENT-HARNESS` 标记时跳过。
  Prompt 仅写入 `.agent-harness/generated/`。CodexPrompt、CodexAgent 分别写入 `.codex/prompts/`、`.codex/agents/`。
- `Components` 可按需列出 `Rules`、`Prompts`、`CodexAgents`。省略的分组视为空，未知的分组或顶层键会导致规划失败。
  已有项目使用退役的 Claude 平台或组件时，先修改 profile 选择。Apply 只处理当前项目清单中的目标，旧 Claude 文件继续由用户管理。
- 改 profile/component 或这几个脚本后跑 `tests/harness-profile.tests.ps1`。

---

## 13. Harness Environments

`harness-source/envs/<name>.psd1` 定义命名的 skills 选集。`Skills` 必须恰好包含 `Codex` 键。
不选技能时，显式写 `@()`。缺键或包含已退役平台键会导致规划失败。只能选取构建目录内的技能。
`env list` 显示文件名、`Description` 与 Codex 的技能名称和数量。`SchemaVersion` 与 `Name` 是声明性元数据。

当前环境：`minimal`（测试样例）、`work`（日常）、`full`（全部受管 skills）；内容与数量见 [STATUS.md](../STATUS.md)。
`work` 为 Codex 选择 10 个技能，`full` 选择 20 个，`minimal` 选择 1 个。
委派权限及并发上限以 [AGENTS.md](../AGENTS.md) 和宿主限制为准。三个协作入口和上游版本见 [Codex 协作入口](COMMUNITY_COLLABORATION.md)。

新增受管 skill 时，除放入 `skills-source/` 外，还要在目标环境的各平台 `Skills` 数组中选入；
`full` 也是显式清单，需要同步维护。用 `env list` 核对选择，再用部署 dry-run 核对实际计划。
构建及部署准备的当前结果见 [STATUS.md](../STATUS.md)。

日常交互与工程克制以 [codex/AGENTS.md](../codex/AGENTS.md) 为准：先复用项目既有有效授权；仅缺业务方向、超常设授权（含授权/策略变更）或高风险外部动作时集中确认。
同一项目反复扩权时，检查权限源文件的分类、冲突和继承入口，先做最小权限规则归整而非叠加临时例外；
按是否改变实际权限区分处理，不以编辑了源文件就一律增加审批：

| 情形 | 处理 |
|---|---|
| 整理、合并、澄清，权限含义不变 | 直接完成并在原任务结果中通知用户 |
| 新增权限，或在源文件中永久改变有效权限及其边界 | 先给出精确差异、原因、风险和继承范围，由用户审批后落实 |
| 已批准范围内的写入、验证及所列执行 | 连续完成；后续任务读取有效正式条款后继承，不为同一权限重复审批 |

相关变更真正超出授权、用户撤销或平台强制审批时，才补相应决定；纯整理不以“权限修正”为名扩大权限。
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
  普通文件占用状态根时报告 `state-root-not-directory`，状态文件位置被目录占用时报告 `state-path-is-directory`。统一 `status` 遇到路径冲突、读取失败或无效记录会保留其余分项并返回非零退出码。首次机器没有记录或旧记录缺少环境名时仍可正常查询。
  不打印原始记录或异常内容；该原因不能用来推断 live skills 是否存在。
- `env list -JsonPath <report-file>` 仍打印上述列表，同时把 `Environments`（每项仅有 `Name`、`Description`）写入 JSON 文件。
- 选集只能包含已有 generated output 的 skill，缺失时 deploy-skills 报错停止。
- 切换到较小环境时，上次由 deploy-skills 部署、本次不再选中的目录进入 `prune`（先备份）。
- 任务临时需要的 skill 不要写回 `work.psd1`；长期需要时在评审过的提交里改环境定义。
- Codex 官方行为是自动检测 skill 变更；若更新未出现，重启 Codex。已在同一上下文中加载的旧
  `SKILL.md` 正文不会因目录刷新而改写，因此版本或路径不明确时应重新读取当前有效入口与文件。
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
status                       -> 统一只读状态汇总（环境、Codex Live Skills、config、antigravity、mcp）[-Json]
dashboard                    -> scripts/dashboard.ps1（启动或复用本地中文监控台）
doctor                       -> scripts/doctor.ps1
build                        -> scripts/build-skills.ps1
scan                         -> scripts/scan-secrets.ps1
sync                         -> scripts/deploy.ps1
env list                     列出 harness-source/envs/*.psd1
env deploy <name>            -> scripts/deploy.ps1 -Environment <name>
config status | pull | push
profile status | build | apply
skills promote               -> scripts/promote-skill.ps1
antigravity build | status | deploy -> scripts/antigravity-plugins.ps1 -Action <action>
mcp status | deploy          -> scripts/mcp-sync.ps1 -Action <action>
```

用 `pwsh -NoProfile -File scripts/agent-dotfiles.ps1 help` 查看命令概览。
用 `help config` 或 `config help` 查看分组帮助；`status`、`dashboard`、`env`、`profile`、`skills`、`antigravity`、`mcp` 支持相同拼法。
帮助说明操作方向、写入范围和常用示例，不执行子脚本。`config push` 仅捕获本机配置到仓库，不是 Git push。

doctor 的 WARN 和退出码保持原有语义，摘要另列已检测到的 `Deploy blockers`。
Codex 的两个 live 根同时存在时会阻塞部署。对于缺少平台根目录、dirty tree 或跳过 secret scan 等提醒，按各项提示判断。
`none detected by these checks` 也不表示部署已通过预检，仍须审查 dry-run。

只读命令：`status`、`doctor`、`scan`、不带 `-JsonPath` 的 `env list`、`config status`、`profile status`、`antigravity status`、`mcp status`。`build` 与 `profile build`
只生成可重建输出；`env list -JsonPath`、`antigravity` 与 `mcp` 传入 `-JsonPath` 还会写入指定的报告文件。会写 live home、`skills-source/` 或项目目标的命令（`sync`、`env deploy`、`config pull/push`、
`profile apply`、`skills promote`、`antigravity deploy`、`mcp deploy`）要求显式 `-DryRun` 或 `-Apply`，统一入口不会自动补 `-Apply`。
`sync` 与 `env deploy` 都串行执行 skills 和 config；两阶段不原子。直接运行低层脚本可只执行单个阶段。

顶层 `status` 命令并发拉取 `config-status.ps1`、`antigravity-plugins.ps1`、`mcp-sync.ps1` 及（在已记录环境且本地构建存在时）`deploy-skills.ps1 -Environment <recorded> -SkipBuild -Json`，在文本输出中呈现 `[Codex Live Skills]` 摘要，在 `-Json` 中输出顶层 `Skills`（`State` 为 `checked` / `build-required` / `unavailable` / `error`）与 `Summary.Skills`。当已记录环境为 `unavailable` 或尚未生成 `codex/skills/` 时，仅标为 `unavailable` / `build-required` 而不触发非零退出码；遇到双 live 根冲突、重解析点或文件占坑等真实 live 根异常时才置为 `error` 并返回非零。底层命令支持 `-Json` 时也可直接透传（如 `profile status -ProjectRoot <project> -Json`、`mcp status -Json`、`deploy-skills.ps1 -Environment work -Json`、`config-pull.ps1 -Platform Antigravity -Json`），统一 CLI 会抑制自己的调用提示和结果提示，让 stdout 保持底层 JSON。`env list` 使用上面的 `-JsonPath`，不支持 `-Json`。


## 15. Antigravity 插件

受管插件 `ai-agent-dotfiles`（目标版本 `0.5.0`）包含 canonical `skills-source/shared/` 中的 9 个跨端共享技能：`brainstorming`、`git-review`、`meng-cmame-writing`、`multimodal-generation`、`paper-polish`、`session-learnings`、`systematic-debugging`、`verification-before-completion` 和 `writing-plans` 及其附属文件（`tool-scope` 面向 Codex Desktop 订阅委派，保留在 `skills-source/shared/` 但不打包进本插件）。选择与元数据来自
`harness-source/antigravity/plugins.psd1`；`ExternalPlugins` 现声明 `unity`（`Source = 'antigravity-plugins-partners'`、`Version = 'ANY'`、`Enabled = $true`）。第三方来源、版本和启用状态在 `status` 与 `deploy -DryRun` 中对比报告（`unchanged` / `missing` / `different` / `blocked` / `UNKNOWN`）。仅当明确传入 `-ExternalPlugin <name>` 并经 `-DryRun` 审阅及单独授权后，`deploy -Apply` 才对 `missing` 的 marketplace 项调用一次 `agy plugin install <name>@<source>`；默认 `deploy -Apply` 不触碰第三方插件，已安装、漂移或未登记同名目录均保持只读阻塞（不自动重装或卸载）。
本入口不打包 rules、MCP、hooks 或 agents。

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity build
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity status
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity deploy -DryRun
```

`build` 只生成 `tmp/antigravity/plugins/ai-agent-dotfiles/`，扫描 canonical 输入与最终包，
并在有 `agy` 时运行原生严格校验。无 `agy` 可准备包，但原生校验未完成。
不要手改生成包；同输入应生成相同文件与 digest，包内容发布变化须递增版本。
`status` 只读候选包和原生插件状态，不构建、不安装、不启停、不修复；包不存在时报告 missing。
原生 CLI 可能写自己的日志，因此只读不等于承诺完全零磁盘写入。
两个命令均不接受 `-DryRun` 或 `-Apply`。三种动作均可传 `-RepoRoot` 和 `-JsonPath`，
其中 `-JsonPath` 显式写报告；不提供未证明可用的原生 HomeRoot/ConfigRoot 隔离参数。

`deploy` 在统一 CLI 中要求恰好一个 `-DryRun` 或 `-Apply`；底层脚本默认 dry run。
用 `antigravity deploy -ExternalPlugin unity -DryRun` 预览指定插件时，JSON 首项 `SelectedExternalPlugins` 按请求顺序列出插件名、动作与原因。后面的 `Action` 属于受管插件 `ai-agent-dotfiles`，完整的外部插件清单保存在 `ExternalExpectations` 中。
预览应核对原生版本与目标根、插件身份、候选版本与 digest、选中技能、相对文件差异、
启用状态、扫描与校验结果，以及保留的外部插件。它不运行现有 `sync`、`env deploy` 或 Codex config-pull。

| 结果 | 操作含义 |
|---|---|
| install | 可准备首装；只有获得具体许可的 Apply 才调用官方安装 |
| unchanged | 身份、内容与版本一致；不执行原生变更 |
| update | 版本递增且线上内容无漂移。若提示重建，先运行 `antigravity build` 并重新预览。候选包就绪且取得授权后，Apply 执行备份、卸载、安装与读回校验 |
| blocked / unknown | 同名未知、内容漂移、同版本异内容或合同不明；停止目标写入 |
| external | 非本项目管理或内置组件；报告并保留 |

首次安装可能立即启用技能。审阅当前完整预览后，所有者许可须明确覆盖目标插件身份、版本、包、
原生目标根与注册状态、启用影响和有限恢复范围；Codex 的 standing work grant 不覆盖此安装。
许可有效且源、包、目标与状态未变时，才运行：

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity deploy -Apply
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity status
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity deploy -DryRun
```

安装与更新只通过受管入口调用官方 `agy plugin` 命令，不手写 live 插件或注册配置。无论安装或更新返回成功还是失败，
都读取注册和目标文件；结果未知或 partial 时保留包与最小 pre-state，停止写入链，不盲重试。
不备份整个原生配置根，不把凭据写入仓库。受控更新通过写前备份 live 目录到 attempt/backup，
随后顺序执行官方 `agy plugin uninstall` 与 `agy plugin install` 并进行全量读回校验与外部插件无变动验证；
降级与自动盲目回滚仍保持阻塞，卸载、停用与手动恢复须有覆盖实际动作的许可。
构建候选包保存在工作区 `tmp/antigravity/`；本机部署收据、尝试记录与 pending 标记持久化在 `%LOCALAPPDATA%\ai-agent-dotfiles.deploy\antigravity\`（可通过内部 `-StateRoot` 参数进行隔离测试），解除了跨工作树部署归属割裂问题。`status` 命令直接解耦对比 live 文件与源码 digest，无需依赖本地未构建包或受门禁改动干扰。未解决的尝试保留 pending 标记阻止继续变更；先审阅读回，不能删除标记来盲重试。原生路径覆写变量非空时拒绝猜测目标。Windows 下若在运行中的 Antigravity IDE 会话内执行 `antigravity deploy -Apply` 并遇到 `plugins/` 目录重命名 `Access is denied`，请先彻底退出 Antigravity IDE，审阅保留的 attempt 结果后在外部 PowerShell 7 窗口按需归档阻塞的 `pending-install.json`（及已失效的旧 `installed.json`），再执行 `-DryRun` 与 `-Apply` 完成收敛（切勿删除备份或盲目重试）。

安装读回、启用、加载与使用分别记录为 built / validated / installed / enabled / loaded / used。
在 App 和 CLI 中分别核对插件面板、项目 Customizations、`/skills` 的身份、版本、来源与加载路径；
需要时使用 `/skills reload` 或新会话，不推断旧聊天已经加载。
实际使用验收在原生会话中以合成小 diff 显式调用 `git-review`，以典型排错/核验场景检查 `systematic-debugging` / `verification-before-completion` 触发，
并在另一会话用无关问题检查非触发。须有读取正文或工具轨迹证据，口头声称使用不算证明；不可见时记 UNKNOWN。
原生模型任务需要覆盖客户端、实际调用和已有订阅/付费预算的具体许可，不从 Codex 包装发起。
未测量时不报告 outcome-improved。任一客户端或使用层未完成时，准确保留缺口，不把静态测试当作原生使用结果。

已安装后，App 可在输入框键入 `/git-review` 并选择来源 `AI Agent Dotfiles`；CLI 使用原生命名空间：

```powershell
agy --print "/ai-agent-dotfiles:git-review <synthetic-diff>" --output-format stream-json
```

CLI 新进程不传 `--continue` 或 `--conversation` 时为独立会话。显式 skill 展开可能直接内联正文，
以 init 的 expanded_commands、原生展开日志及安装文件 readback 核对；自然触发仍需实际正文读取轨迹。
`--mode plan` 是提示前缀，不能当作只读权限隔离。原生诊断日志可能含账户信息，保持在私有 ignored
目录，对外仅发布必要的脱敏结论。0.1.0 的历史归档记录与获取命令见[历史索引](HISTORY.md)。

---

## 16. 受管 MCP 分发（mcp-sync）

`harness-source/mcp/servers.psd1`（`SchemaVersion = 1`、`Servers`）声明跨 **Antigravity、Codex** 双端投影的受管 MCP server（当前声明 `blender`），严禁写入明文密钥、Token、回车换行或本机盘符/UNC 路径：

- **支持的传输与字段**：`stdio`（`Command`、`Args`、`Env`）与 `streamable-http`（`Url`、可选 `BearerTokenEnvVar`、`Headers`），并带 `Name`、`Enabled`、`Platforms` 与可选 `EnabledPolicy`（`'enforce'` 默认强制启用态同步，或 `'preserve-disabled'`）。当 `Enabled = $true` 且 `EnabledPolicy = 'preserve-disabled'`（当前 `blender` 采用此策略）时，若 Codex 本机已存在条目且仅 `enabled = false` 而命令、参数、环境变量等其余字段一致，规划器记为 `unchanged`（原因 `managed-entry-match-local-disabled`）；一旦发生命令或环境漂移仍报 `update`。未知 `EnabledPolicy` 值会在读取阶段被拒绝。
- **凭据与平台约束**：注册表读取阶段要求 `Env` 中敏感键名（`api_key` / `token` / `secret` / `password` / `passwd` / `credential`）必须写成 `${ENV_VAR}` 占位符，而 `Codex` 投影器目前不支持 `${...}` 环境变量模板展开；遇到不兼容项、重复键、非法 JSON 或缺失 `codex` CLI 时，规划器 fail closed 报告 `blocked`，不会猜测或写入。

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 mcp status
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 mcp deploy -DryRun
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 mcp deploy -Platform Antigravity -Server blender -DryRun
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 mcp deploy -Apply
```

常用参数：`-Platform Antigravity|Codex`（可逗号分隔）、`-Server <name>`、`-Json`、`-JsonPath <file>`、`-BackupRoot <path>`、`-SkipSecretScan`（仅 `deploy` 接受 `-DryRun` / `-Apply` / `-BackupRoot` / `-SkipSecretScan`）。

各端按条目投影并保留非托管条目与个人设置：

| 客户端 | 落点与投影方式 | 保留内容 |
|---|---|---|
| **Antigravity** | `~/.gemini/config/mcp_config.json` 下的 `mcpServers.<name>`（结构化 JSON 合并） | 其他非托管 `mcpServers` 与顶层字段 |
| **Codex** | 仅通过官方 `codex mcp list/get/add/remove` CLI 逐项投影 | `[projects.*]`、`[model_providers.*]`、模型设置与非托管 `[mcp_servers.*]`（不整文件改写 `config.toml`） |

安全与回滚门禁：

- `mcp status` 与 `mcp deploy -DryRun` 只读不写；若 plan 存在任何 `blocked` 项，`-Apply` 直接拒绝执行。
- 存在待写入的 `add` / `update` 项时，`-Apply` 先执行秘密扫描门禁（除非显式 `-SkipSecretScan`）并复核最新计划，写前将已存在的目标配置文件备份到 `~/.ai-agent-dotfiles-backups/mcp-backup-<UTC 时间戳>\`（`-BackupRoot` 可改）。
- JSON 写入失败时尽力按反序从本次备份恢复或清理新建目标文件；`-Apply` 完成后执行读回校验，确认受管条目收敛为 `unchanged` 且非托管数量未减少。
- `mcp deploy` 独立于 `sync` / `deploy.ps1`，`AGENTS.md` Skill rules 10 不覆盖 MCP Apply；每次执行 `-Apply` 前须审查完整 dry-run 并获得明确授权。
- 回归测试：`pwsh -NoProfile -File tests/mcp-sync.tests.ps1`。

---

## 17. 本地可视化监控台（dashboard）

`scripts/dashboard.ps1`（或根目录双击 `start-dashboard.cmd`）启动或复用一个仅面向本机的中文 Web 监控与交互控制台。后端拆分为入口 `dashboard/server.py` 与 `dashboard/lib/` 模块（`security.py`、`collectors.py`、`sync_preview.py`、`jobs.py`），前端为 `dashboard/index.html` + `dashboard/static/app.css` + `dashboard/static/app.js`（纯 Python 3.11+ 标准库与原生 Web 技术，无外部 CDN/npm 依赖；`/static/` 仅按精确白名单放行并执行重解析点与 `nosniff` 校验）。`start-dashboard.cmd` 采用纯 ASCII + Windows CRLF 换行（由 `.gitattributes` 锁定），也可在桌面创建快捷方式并设置为最小化窗口启动，需要停止本地服务时直接关闭任务栏中的对应窗口即可。

```powershell
# 直接启动并自动打开浏览器（若同仓库实例已健康运行则复用）
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 dashboard

# 常用选项：指定端口、不自动打开浏览器、离线跳过 GitHub 查询、只校验环境 JSON
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 dashboard -Port 8765 -NoBrowser -Offline
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 dashboard -Check
```

常用参数：`-Port <port>`、`-NoBrowser`、`-Check`、`-Offline`、`-RepoRoot <path>`、`-HomeRoot <path>`、`-StateRoot <path>`（后两项用于隔离测试转发，不改变正常本机默认路径）。

主要功能：

- **开发进展监控**：按中文分类汇总当前工作区改动与按需 Diff、读取 `STATUS.md` 待办与 `status/active/` 进行中任务、展示近期提交与 GitHub PR / CI（离线时优雅降级），并自动探测或手动加入 Swarm / Teamwork 协作看板。
- **双端资产与状态总览**：汇总 Codex 环境记录、Codex Live Skills 漂移（`sync.skills`：`10/10 一致` / `待同步` / `需先构建`）、Codex 与 Antigravity 受管 `AGENTS.md`、Antigravity 自研与第三方插件、受管 MCP 分发状态，并提供按目录 mtime 缓存的可搜索技能浏览器（点击查看脱敏后的 `SKILL.md`）。前端轮询在页面隐藏（`visibilityState === "hidden"`）时暂停并在切回可见时立即刷新，按区块指纹跳过未变化 DOM 的重绘。
- **实时流式日志、安全取消与排障指令复制**：支持只读/本地构建类操作（`doctor`、`scan`、`build`、`antigravity build`、单项或并发全量测试），运行中任务通过增量流式管道实时输出日志到 `GET /api/jobs/<id>` 详情抽屉，并支持一键复制脱敏后的 AI 解释、复核提交或报错排查指令；所有运行中操作受全局单执行锁保护（并发请求返回 HTTP 409）。仅限运行中的只读/测试/预览任务（`action:*`、`preview:*`）可调用 `POST /api/jobs/<id>/cancel`（UI 显示“停止任务”）终止整棵子进程树并标记为 `cancelled`；写入类任务（`apply:*`）严格返回 HTTP `403` 禁止中途取消，以防本机状态半写。

安全边界与写入门禁：

- **仅限本机回环与 CSRF 防护**：服务端仅绑定 `127.0.0.1`（拒绝非回环主机），运行时状态 `server.json` 仅写入仓库下忽略的 `tmp/dashboard/`（拒绝符号链接/重解析点）。每次启动生成随机会话 Token（`X-Dashboard-Token`），所有 `POST` 请求必须同时通过 Token、`Host` 与 `Origin` 校验（不匹配返回 HTTP 403），前端所有文件严格禁止使用 `innerHTML` / `outerHTML` 插入非信任文本，API 响应与复制指令均对用户主目录与仓库绝对路径做脱敏处理。
- **强制先预览后确认（DryRun -> Apply）**：所有写入本机的同步按钮（Codex 完整/仅技能同步、Antigravity 全局规则/插件部署、受管 MCP 同步）只能先触发 `-DryRun` 预览（其中 `codex-skills`、`antigravity-config` 与 `mcp` 消费结构化 `-Json` 输出）。预览成功后生成绑定当前 `git HEAD` 与受管工作区源码指纹、300 秒有效且原子单次消费的 `preview_id`；若出现 `blocked`、需重建插件包、当前已全部同步无变更或提交记录/受管源码指纹发生变化，Apply 按钮保持禁用或被后端拒绝。只有在预览无阻塞、存在待变更项且人工勾选确认框后，才允许执行对应的 `-Apply`，完成后自动刷新状态读回。
- **高风险操作边界**：Git 提交/推送、`config push`（本机回抓）与 `-Retire`（删除旧技能）不提供面板一键写入，仍须在 AI 对话中审查后执行。
- 回归测试：`pwsh -NoProfile -File scripts/run-tests.ps1 -Suite dashboard`（或直接运行 `pwsh -NoProfile -File tests/dashboard.tests.ps1`）会同时执行 `tests/dashboard_server_test.py` 单元测试与隔离 PowerShell 集成测试。
