# ai-agent-dotfiles 使用说明

面向"未来的我"和"接手的 Claude Code / Codex agent"。看完这份手册即可独立维护本项目。

全局状态见 [STATUS.md](../STATUS.md)；新电脑接入见 [ONBOARD_NEW_MACHINE.md](ONBOARD_NEW_MACHINE.md)；skills 导入与合并规则见 [MERGE_POLICY.md](MERGE_POLICY.md)；当前局部任务见 [status/active/](../status/active/)；历史状态见 [status/archived/](../status/archived/)；已删除的代码与文档见 [HISTORY.md](HISTORY.md)。

---

## 1. 项目目的

统一管理多台电脑上的 Claude / Codex / Reasonix skills：

- 用 Git 维护**唯一可信源** `skills-source/`。
- 用 `scripts/build-skills.ps1` 从源生成 Claude / Codex / Reasonix 的 runtime output。
- 用 `scripts/deploy-skills.ps1` 把某个环境选中的 skills 逐目录部署到本机 live skills 目录；
  默认只打印计划，`-Apply` 才写入。
- 另外管理 harness 配置（§14 config-sync）和项目级 harness profile（§15）。

设计原则：保守、可审计、默认 dry-run、绝不整目录覆盖、绝不碰平台内置目录。

---

## 2. 当前管理范围

### 会部署
- `skills-source/shared/*`（跨平台，Claude + Codex + Reasonix 都生成）
- `skills-source/claude-only/*`、`skills-source/codex-only/*`、`skills-source/reasonix-only/*`
- 生成到 `claude/skills/`、`codex/skills/` 和 `reasonix/skills/`（Git-ignored）
- 由所选环境（`harness-source/envs/<name>.psd1`）挑出的子集部署到本机 live：
  - Claude：`~/.claude/skills`
  - Codex：`~/.codex/skills`；仅当它不存在时才 fallback 到 `~/.agents/skills`（两者都存在时拒绝）
  - Reasonix：`%APPDATA%\reasonix\skills`（`config.toml`/`.env` 等机器私有状态永不纳入）

### 不会部署
- Codex `~/.codex/skills/.system`（平台内置，永远保留）
- live 根下 deploy-skills 从未部署过的目录（unknown，只报告）
- `imports/`（原始导入、归档、隔离）
- 部署状态与备份（在 repo 外，`%LOCALAPPDATA%\ai-agent-dotfiles.deploy`）
- generated output 不进 Git
- 机器私有配置、API keys / tokens / secrets、临时日志

---

## 3. 目录说明

| 路径 | 说明 |
|---|---|
| `bootstrap.ps1` | 新 clone 的一次性入口：安装并校验 pinned gitleaks、build skills、打印 deploy-skills dry-run 命令；不写 live |
| `STATUS.md` | 唯一全局状态文件，直接更新，不重复新建总体状态报告 |
| `status/active/`、`status/archived/` | 当前局部任务记录与历史记录 |
| `.claude/settings.json` | 项目级 harness 护栏（deny 编辑生成物/`.system`、禁 robocopy；allow build-skills 与 scan-secrets） |
| `skills-source/` | **唯一可信源**，手工维护的 skill 树（`shared/`、`claude-only/`、`codex-only/`、`reasonix-only/`） |
| `claude/skills/`、`codex/skills/`、`reasonix/skills/` | **生成物**，Git-ignored，勿手改 |
| `manifests/managed-skills.<platform>.txt` | build 刷新的每平台受管名单 |
| `manifests/managed-skills.txt` | 三平台 union inventory，由 build 刷新，勿手改 |
| `manifests/whitelist.psd1` | config-sync 的 Push/Pull items 与 ExcludedItems，见 §14 |
| `harness-source/envs/` | 环境定义（每平台选哪些 skills），见 §16 |
| `harness-source/` 其余目录 | Project Harness Profiles 的 component/profile 源库，见 §15 |
| `.agent-harness/generated/` | 项目本地 profile 生成物，Git-ignored，可随时重建 |
| `scripts/build-skills.ps1` | 从源生成 runtime output，并刷新 manifest |
| `scripts/scan-secrets.ps1` | secret 扫描（pinned gitleaks + 自定义回退扫描器） |
| `scripts/deploy-skills.ps1` | 按环境部署 skills 到三个 live 根，默认 dry-run，见 §4 |
| `scripts/config-status.ps1` / `config-pull.ps1` / `config-push.ps1` | harness 配置同步，见 §14 |
| `scripts/status-/build-/apply-harness-profile.ps1` | Project Harness Profiles，见 §15 |
| `scripts/inventory-/analyze-/dedupe-skills.ps1`、`promote-skill.ps1`、`normalize-skill.ps1`、`auto-merge-skills.ps1` | skills 导入与合并工具，见 [MERGE_POLICY.md](MERGE_POLICY.md) |
| `scripts/doctor.ps1` | 只读健康检查 |
| `scripts/agent-dotfiles.ps1` | 统一 CLI，见 §17 |
| `imports/skills-inbox/`、`skills-archive/`、`skills-quarantine/`、`skills-reports/` | 导入暂存、归档、隔离与报告；内容不提交 |

---

## 4. 日常同步流程

`scripts/deploy-skills.ps1` 按 `harness-source/envs/<name>.psd1` 的 `Skills` 清单（默认环境 `work`），
逐个 skill 目录部署到三个 live 根：

- 先跑 `build-skills.ps1` 与 `scan-secrets.ps1`，任一失败即停止（`-SkipBuild` 跳过这两步，只用于测试）。
- 逐目录给出 `install`（选中、live 缺失）、`update`（选中、内容不同）、`unchanged`、`prune` 或 `unknown`。
  不带 `-Apply` 时只打印计划。
- `prune` 只删除本工具上次部署过、本次不再选中的目录，或 `-Retire` 显式点名的目录。
  `-Retire` 对三个平台同时生效，先看 dry-run。
- 其余 live 目录是 unknown：只报告不碰。Codex `.system` 永不触碰；遇到 reparse point 直接拒绝。
- live 目录只通过整目录改名替换：先复制到同级 `.deploying-<name>`，再换名；文件被占用时改名整体失败，
  不会留下半删的 skill。残留的 `.deploying-*` 在下次运行时清理。
- `update` 和 `prune` 之前，先把旧目录复制到
  `%LOCALAPPDATA%\ai-agent-dotfiles.deploy\skill-backups\<时间戳>\<Platform>\<name>`。
- 已部署集合记录在机器私有的 `%LOCALAPPDATA%\ai-agent-dotfiles.deploy\deployed-skills.json`。
  没有这个文件时，首次运行不会 prune 任何目录；Apply 失败时保留旧状态。

```powershell
Set-Location '<repo-root>'
git pull --ff-only
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work -Apply
```

`-Apply` 会写真实 home：先审查 dry-run 的每一行，取得所有者授权后再执行。统一 CLI 的
`sync` 与 `env deploy <name>` 转发到同一个脚本（§17）。

新 clone 先运行一次 `bootstrap.ps1`（见 [接入指南](ONBOARD_NEW_MACHINE.md)）；仓库不安装 Git hooks，
`git pull` 之后不会自动部署任何东西。

---

## 5. 修改已有 skill 的流程

1. 只改 `skills-source/`（**不要**直接改 `claude/skills/`、`codex/skills/` 或 `reasonix/skills/`）。
2. `scripts/build-skills.ps1`
3. `scripts/scan-secrets.ps1`
4. 提交 source / manifest / docs 变更（**不要**提交 generated output），按授权 push。
5. 每台机器各自运行 deploy-skills dry-run，审查后按授权 `-Apply`。

如果这次修改是**删除 skill**，build 会同时从 generated output 和 manifest 移除名称：

- 本机由 deploy-skills 部署过的目录，下次 dry-run 显示为 `prune`。
- 旧 live 名称默认按 unknown 保留（例如旧安装方式留下的目录），不会被猜测性删除。
  逐项审查后，用 `-Retire` 显式点名：

```powershell
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work -Retire <old-skill>
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work -Retire <old-skill> -Apply
```

`-Retire` 只作用于 live 中存在、未被当前环境选中的目录；`.system` 永不进入计划。
其它机器若也有这批旧目录，各自审查后执行同一命令。

---

## 6. 新增 skill 的流程

- 跨平台：`skills-source/shared/<skill-name>/`
- 单平台：`skills-source/claude-only/`、`codex-only/` 或 `reasonix-only/` 下的 `<skill-name>/`
- 每个 skill 至少要有 `SKILL.md`。
- 若来自其它电脑或 inbox，先按 [MERGE_POLICY.md](MERGE_POLICY.md) 审计：是否重复、是否含 secrets、
  是否含机器私有路径（如 `C:\Users\<name>`）、该归哪个平台目录。
- manifest 由 `build-skills.ps1` 自动刷新（名单来自源目录），不要手改。
- build 后确认各平台 `Built ... skills: N` 数量变化符合预期。
- 要部署到本机，把名称加入相应环境（§16），再走 §4。

---

## 7. 不能做的事情

- 不要手动编辑 generated output（`claude/skills/`、`codex/skills/`、`reasonix/skills/`）。
- 不要提交 generated output、`imports/` 内容、备份、部署状态或 live home 目录。
- 不要删除 `~/.codex/skills/.system`。
- 不要对 live skills 根用整目录 `robocopy /MIR` 或任何 mirror。
- 不要手工复制进或删除 live 根下的目录（§9 的授权恢复除外）。
- 不要 whitelist 或削弱 secret scan gate。
- 不要把明文 key / token 写进 skill。

---

## 8. Codex `.system` 规则

- `.system` 是 Codex CLI **平台内置目录**（标记文件 `.codex-system-skills.marker`）。
- 含平台能力：`imagegen`、`openai-docs`、`plugin-creator`、`skill-creator`、`skill-installer`。
- deploy-skills、build、inventory 都**永远跳过**它（不读取内容、不更新、不删除、不备份）。
- doctor 只检查它的根条目，不遍历内容。
- 它**不属于** repo-managed skill；删除它可能破坏 Codex 原生能力。

---

## 9. 备份与恢复

deploy-skills 在 `update` 或 `prune` 一个目录之前，把旧目录复制到：

```text
%LOCALAPPDATA%\ai-agent-dotfiles.deploy\skill-backups\<stamp>\<Platform>\<name>
```

每次 Apply 用一个新的 `<stamp>`；Apply 结束时打印本次备份目录。恢复有两种方式：

- **从 Git 重新部署（首选）。** 被改坏的是受管 skill 时，检出想要的提交，运行 deploy-skills
  dry-run，审查后按授权 `-Apply`。被误删的受管 skill 加回环境后再部署即可。
- **从备份复制回来。** 需要恢复的是部署前的旧内容（例如 prune 掉的目录）时，经所有者授权，
  把 `<StateRoot>\skill-backups\<stamp>\<Platform>\<name>` 复制回对应 live 根下的 `<name>`
  （先确认目标不存在或已移开）。`<StateRoot>` 默认是 `%LOCALAPPDATA%\ai-agent-dotfiles.deploy`。
  恢复后的目录若仍被环境选中，下次 dry-run 会显示 `update`；若不再选中且曾由本工具部署，
  会显示 `prune`，先调整环境再 Apply。

备份不含 Codex `.system`、unknown 目录和 home 配置；整机 home 恢复是平台/所有者自己的操作。
config-pull 的逐文件备份见 §14。

---

## 10. 多电脑同步流程

一台电脑修改并 push 后，另一台：

```powershell
Set-Location '<repo-root>'
git pull --ff-only
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 build
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 scan
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work
```

审查 dry-run 后按授权加 `-Apply`。每台机器的部署状态各自记录，互不复制。

---

## 11. 当前状态

- 全局状态、managed counts、机器部署情况、风险和下一步统一维护在 [STATUS.md](../STATUS.md)。
- 当前局部任务只放在 [status/active/](../status/active/)；任务完成后移动到 [status/archived/](../status/archived/)。

---

## 12. 常见问题

**Q：dry-run 显示 `unknown` 怎么办？**
A：那是 deploy-skills 从未部署过的 live 目录（手工安装、其它工具或旧部署方式留下的）。它会一直保留。
确认不再需要后用 `-Retire <name>` 显式删除；需要保留就不用管它。

**Q：为什么 Codex 比 repo-managed 数量多一个 `.system`？**
A：`.system` 是 Codex 平台自带目录，不由本仓库管理，部署时永远跳过。

**Q：为什么 generated output 不提交？**
A：它由 `build-skills.ps1` 从 `skills-source/` 生成，属派生物，已 Git-ignored；提交它会造成源与产物双份维护和漂移。

**Q：新电脑第一次部署怎么办？**
A：按 [ONBOARD_NEW_MACHINE.md](ONBOARD_NEW_MACHINE.md)：clone → `bootstrap.ps1` → 审查 deploy-skills dry-run → 所有者授权后 `-Apply`。

**Q：scan-secrets 报 false positive 怎么办？**
A：优先**改写源文档/示例措辞**让它不再像真实密钥（例如说明应从环境变量或密钥管理器读取）。
**不要** whitelist，**不要**削弱 scan gate。改完重新 build + scan。

---

## 13. 检查与 CI

- 本地检查清单见 `AGENTS.md` 的 Checks and CI：每次改动 `git diff --check` + `scan-secrets.ps1`；
  脚本改动另跑语法检查、受影响套件，合并前跑全量：

```powershell
$summary = Join-Path ([IO.Path]::GetTempPath()) ('ai-agent-dotfiles-tests-' + [guid]::NewGuid().ToString('N') + '.json')
pwsh -NoProfile -File scripts/run-tests.ps1 -All -JsonSummaryPath $summary
```

- CI 是一个 `Validate` 作业，在 push 到 `main`、pull request 和手动触发时运行
  `scripts/run-repository-validation.ps1`：PowerShell 语法、gitleaks 校验、build、扫密、doctor、
  manifest 一致性、全部测试套件、危险跟踪文件和工作树干净检查。
- 红灯先读失败步骤的日志，不看 annotation 下结论；runner 失联或下载失败就重跑，不改代码；
  同一提交重跑一次判断是否偶发，复现就修测试或夹具。永远不删除或削弱套件、门禁、超时预算或扫密。

---

## 14. Harness 配置同步（config-sync）

除 skills 外，仓库还管理 agent harness 配置本身。源是 `manifests/whitelist.psd1`
（per-platform 的 Push/Pull items 与 ExcludedItems）。

- `.claude/settings.json`（项目级、已提交）：把硬规则变成 harness 强制 `permissions.deny`
  （禁止 `Edit`/`Write` 生成物 `claude|codex|reasonix/skills/**` 与 Codex `.system`
  ——`~/.codex/skills/.system` 和任意 `.codex/skills/.system` 两种写法都拦——、禁止 robocopy
  整目录 mirror），并 `allow` 安全的校验命令（build-skills / scan-secrets）。
  `deploy-skills.ps1` **故意不在** allow 名单，保证 `-Apply` 始终经过授权。
- `scripts/config-status.ps1`：只读 drift 报告（repo ↔ home），逐项报告
  in-sync / differs / repo-only / home-only，遵守 ExcludedItems，**绝不写**。
- `scripts/config-pull.ps1`：部署 repo→home。默认 dry-run；`-Apply` 先扫密、逐文件备份被覆盖项再复制；
  **绝不整目录 mirror、绝不 prune**（home-only 文件原样保留）。
- `scripts/config-push.ps1`：捕获 home→repo。默认 dry-run；`-Apply` 写入后**双 gate**——扫密 +
  机器私有路径扫描（盘符/UNC 绝对路径），任一命中即**回滚全部捕获**；结果保持未提交供人审。
  `-SkipPathScan` 仅在绝对路径确属有意时使用。
- `-Platform Reasonix` 处理 `%APPDATA%\reasonix` 下的白名单项。

规则：

- pull/push 默认 dry-run，`-Apply` 才动，与 `deploy-skills.ps1` 同款保守姿态。
- **config-push 捕获的内容必须人工 `git diff` 审查后再提交**——扫密只挡 token，挡不了机器私有路径。
- Codex `config.toml` 与 Reasonix `config.toml`/`.env` **不纳入** config-sync（混杂机器私有状态）。
- Agent 规则与可复用模板按统筹、实施、审核等职责和所需能力编写，不固定具体模型或推理档位。
  尊重用户的明确选择和既有个人配置；未指定时沿用当前会话/运行时默认。历史记录中的模型名、
  路由与档位保留为当时证据，不作为当前默认指令。
- 模板省略模型与推理档位覆盖值，不表示可以删除个人设置。`config-pull.ps1` 按文件复制，
  **不会按字段合并个人配置**；部署审查时须逐项比较目标中的个人覆盖值并保留。
- 环境部署（deploy-skills）不包含 config-pull；把两者合并需要单独评审。
- 回归测试：`pwsh -NoProfile -File tests/config-sync.tests.ps1`。

---

## 15. Project Harness Profiles

Project Harness Profiles 把可复用的 component/profile 定义放在 `harness-source/`，然后为某个项目
生成 `.agent-harness/generated/` 下的本地输出。这套能力只处理项目本地文件，不切换全局 home harness。

```powershell
pwsh -NoProfile -File scripts/status-harness-profile.ps1 -ProjectRoot <project>
pwsh -NoProfile -File scripts/build-harness-profile.ps1 -ProjectRoot <project>
pwsh -NoProfile -File scripts/apply-harness-profile.ps1 -ProjectRoot <project>
pwsh -NoProfile -File scripts/apply-harness-profile.ps1 -ProjectRoot <project> -Apply
pwsh -NoProfile -File tests/harness-profile.tests.ps1
```

- `status-harness-profile.ps1`：只读状态/漂移报告。
- `build-harness-profile.ps1`：只写目标项目的 `.agent-harness/generated/`。
- `apply-harness-profile.ps1`：默认 dry-run；`-Apply` 只写 allowlisted 项目输出以及
  `.agent-harness/backups/` 下的项目本地 rollback backup。它不写 home 或 live skills。
- 受控输出类型：Claude `.claude/commands/` 与 `.claude/agents/`、Codex `.codex/prompts/` 与 `.codex/agents/`。
- 不要手改 `.agent-harness/generated/`；变更 profile/component 后跑 `tests/harness-profile.tests.ps1`，
  多平台输出变更再跑 `tests/harness-multiplatform.tests.ps1`。

---

## 16. Harness Environments

环境是命名的 skills 选集：`harness-source/envs/<name>.psd1`。字段：`SchemaVersion`、`Name`
（须与文件名一致）、`Description`、`Profile`（引用 `harness-source/profiles/`）和
`Skills`。`Skills` 必须恰好有 `Claude`、`Codex`、`Reasonix` 三个键（某平台不要 skill 时写 `@()`），
否则 deploy-skills 拒绝运行，避免把缺键误读成空选集而 prune 全部。

当前环境：`minimal`（测试样例）、`work`（日常：`boring-engineering`、`systematic-debugging`）、
`full`（全部受管 skills）。数量见 [STATUS.md](../STATUS.md)。

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env list
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env deploy work
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment full
```

- 选集只能包含已有 generated output 的 skill；缺失时 deploy-skills 报错停止。
- 切换到较小环境时，上一次由 deploy-skills 部署、本次不再选中的目录会进入 `prune`（先备份）。
- 一个任务临时需要的 skill 不要写回 `work.psd1`；需要长期使用时在评审过的提交里改环境定义。
- Codex 应用已缓存的 skill catalog 可能需要新 task/thread 才刷新。

---

## 17. 统一 CLI

统一入口是 `scripts/agent-dotfiles.ps1`。它只负责路由，把参数原样转给底层脚本：

```text
doctor                       -> scripts/doctor.ps1
build                        -> scripts/build-skills.ps1
scan                         -> scripts/scan-secrets.ps1
sync                         -> scripts/deploy-skills.ps1
env list                     列出 harness-source/envs/*.psd1
env deploy <name>            -> scripts/deploy-skills.ps1 -Environment <name>
config status | pull | push
profile status | build | apply
skills inventory | analyze | dedupe | merge | normalize | promote
inventory | analyze | merge  （skills 命令的顶层别名）
```

只读命令：`doctor`、`scan`、`env list`、`config status`、`profile status`、`skills inventory`、
`skills analyze`、`skills dedupe`。`build` 与 `profile build` 只生成可重建输出。
会写 live home、`skills-source/` 或项目目标的命令（`sync`、`env deploy`、`config pull/push`、
`profile apply`、`skills merge/normalize/promote`）默认 dry-run，统一入口不会自动补 `-Apply`。
