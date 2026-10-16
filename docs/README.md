# ai-agent-dotfiles 使用说明

面向"未来的我"和接手的 Claude Code / Codex agent。必须遵守的规则以 [AGENTS.md](../AGENTS.md) 为准；
本手册只补充操作细节。全局状态见 [STATUS.md](../STATUS.md)，新电脑接入见
[ONBOARD_NEW_MACHINE.md](ONBOARD_NEW_MACHINE.md)，已删除内容见 [HISTORY.md](HISTORY.md)。

---

## 1. 项目目的

用 Git 统一管理多台电脑上的 Claude / Codex / Reasonix / ZCode skills：`skills-source/` 是唯一可信源，
`build-skills.ps1` 生成三个平台的 runtime output，`deploy-skills.ps1` 把某个环境选中的 skills 逐目录部署到
本机 live 根（默认 dry-run；ZCode 是投影平台，直接部署 Claude 生成物）。另外管理 harness 配置（§11）和项目级 harness profile（§12）。
原则：保守、可审计、默认 dry-run、绝不整目录覆盖、绝不碰平台内置目录。红线（Hard rules / Skill rules）以
[AGENTS.md](../AGENTS.md) 为准；唯一允许手工写 live 根的情形是 §8 的授权恢复。

---

## 2. 当前管理范围

生成物 `claude/skills/`、`codex/skills/`、`reasonix/skills/`（Git-ignored）中由所选环境挑出的子集部署到：

- Claude：`~/.claude/skills`
- Codex：`~/.codex/skills`；仅当它不存在时 fallback 到 `~/.agents/skills`（两者都存在时拒绝）
- Reasonix：`%APPDATA%\reasonix\skills`
- ZCode：`~/.zcode/skills`（投影平台，部署 Claude 生成物，自身没有生成根与 manifest）

不管理：Codex `.system`；deploy-skills 从未部署过的 live 目录（unknown，只报告）；部署状态与备份
（repo 外的 `%LOCALAPPDATA%\ai-agent-dotfiles.deploy`）；机器私有配置与 secrets。

---

## 3. 目录说明

| 路径 | 说明 |
|---|---|
| `bootstrap.ps1` | 新 clone 一次性入口：安装并校验 pinned gitleaks、build、打印 deploy-skills dry-run 命令；不写 live |
| `STATUS.md`、`status/active/` | 全局状态（原地更新）与进行中任务记录（完成后结论并入 `STATUS.md` 并删除） |
| `.claude/settings.json` | 项目级 harness 护栏，见 [CLAUDE.md](../CLAUDE.md) |
| `skills-source/` | 唯一可信源（`shared/`、`claude-only/`、`codex-only/`、`reasonix-only/`） |
| `claude/skills/`、`codex/skills/`、`reasonix/skills/` | 生成物，Git-ignored，勿手改 |
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

---

## 4. 日常同步流程

`deploy-skills.ps1` 按 `harness-source/envs/<name>.psd1` 的 `Skills` 清单（日常用 `work`）逐目录部署到四个 live 根
（Zcode 从 Claude 生成物投影）：

- 先跑 build 与 scan，任一失败即停止（`-SkipBuild` 跳过两者，只用于测试）。
- 每个目录给出 `install`、`update`、`unchanged`、`prune` 或 `unknown`；不带 `-Apply` 只打印计划。
- `prune` 只删除本工具上次部署过、本次不再选中的目录，或 `-Retire` 点名的目录（四平台同时生效）。
- 其余 live 目录是 unknown，只报告不碰。Codex `.system` 永不触碰；遇到 reparse point 直接拒绝。
- 替换靠整目录改名：先复制到同级 `.deploying-<name>` 再换名；文件被占用时整体失败，不留半删的 skill。
  残留的 `.deploying-*` 在下一次对该 skill 做 install/update/prune 时清理。
- `update` 和 `prune` 前先备份旧目录（§8）。
- 已部署集合记录在 `%LOCALAPPDATA%\ai-agent-dotfiles.deploy\deployed-skills.json`（每台机器各自一份）。
  没有该文件时首次运行不 prune；Apply 失败时保留旧状态。

```powershell
Set-Location '<repo-root>'
git pull --ff-only
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work -Apply
```

`-Apply` 会写真实 home：先审查 dry-run 的每一行，取得所有者授权后再执行。统一 CLI 的 `sync` 与
`env deploy <name>` 转发到同一脚本（§14）。仓库不安装 Git hooks，`git pull` 不会自动部署。
多台机器同步：一台修改并 push 后，其余机器各自 `git pull --ff-only` 再走本流程；部署状态每台机器各自
记录，互不复制。

---

## 5. 修改已有 skill 的流程

1. 只改 `skills-source/`，然后运行 `build-skills.ps1` 与 `scan-secrets.ps1`。
2. 提交 source / manifest / docs 变更（不提交 generated output），按授权 push。
3. 每台机器各自跑 deploy-skills dry-run，审查后按授权 `-Apply`。

**删除 skill** 时，build 同时从生成物和 manifest 移除名称。本机由 deploy-skills 部署过的目录下次 dry-run
显示为 `prune`；deploy-skills 从未部署过的旧目录按 unknown 保留，逐项审查后用 `-Retire` 显式点名：

```powershell
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work -Retire <old-skill>
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment work -Retire <old-skill> -Apply
```

`-Retire` 只作用于 live 中存在、未被当前环境选中的目录；`.system` 永不进入计划。其它机器各自审查后执行同一命令。

---

## 6. 新增 skill 的流程

- 跨平台放 `skills-source/shared/<name>/`，单平台放 `claude-only/`、`codex-only/` 或 `reasonix-only/` 下。
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
`%LOCALAPPDATA%\ai-agent-dotfiles.deploy`）。每次 Apply 用一个新 `<stamp>`，结束时打印本次备份目录。

```text
<StateRoot>\skill-backups\<stamp>\<Platform>\<name>
```

恢复方式：

- **从 Git 重新部署（首选）。** 受管 skill 被改坏时，检出想要的提交，跑 dry-run，审查后按授权 `-Apply`。
  被误删的受管 skill 加回环境后再部署。
- **从备份复制回来。** 需要部署前的旧内容（例如被 prune 的目录）时，经所有者授权，把备份目录复制回对应
  live 根下的 `<name>`（先确认目标不存在或已移开）。恢复后若仍被环境选中，下次 dry-run 按内容显示
  `update` 或 `unchanged`；若不再选中，则看部署状态：名字仍在状态里（prune 后尚未成功 Apply，或 Apply
  在写状态前失败）显示 `prune`，成功的 Apply 已把它从状态移除后显示 `unknown`，需要再删时用
  `-Retire` 点名。

备份不含 Codex `.system`、unknown 目录和 home 配置；整机 home 恢复由平台/所有者自行处理。
config-pull 的备份见 §11。

---

## 9. 常见问题

**dry-run 显示 `unknown`？** 那是 deploy-skills 从未部署过的 live 目录（手工安装、其它工具或旧部署方式留下的），
会一直保留。确认不再需要后用 `-Retire <name>` 删除。

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

---

## 11. Harness 配置同步（config-sync）

除 skills 外，仓库还管理 harness 配置。源是 `manifests/whitelist.psd1`（每平台的 Push/Pull items 与 ExcludedItems）。

- `config-status.ps1`：只读 drift 报告（repo ↔ home），逐项报告 in-sync / differs / repo-only / home-only，遵守 ExcludedItems。
- `config-pull.ps1`：repo → home。默认 dry-run；`-Apply` 先扫密、逐文件备份被覆盖项再复制；
  不整目录 mirror、不 prune（home-only 文件原样保留）。捕获复制异常后，尽力回滚本次已尝试写入的文件：
  更新项从备份恢复，新增项删除。单项回滚失败会告警并继续还原其他项，保留备份并重新抛出原始复制错误。
  这是异常处理中的恢复，不保证进程被强制终止后的还原。
- `config-push.ps1`：home → repo。默认 dry-run；`-Apply` 写入后过两道 gate：扫密 + 机器私有路径扫描
  （盘符/UNC 绝对路径），任一命中即回滚全部捕获。结果保持未提交，必须人工 `git diff` 审查后再提交。
  `-SkipPathScan` 仅在绝对路径确属有意时使用。
- `-Platform Reasonix` 处理 `%APPDATA%\reasonix` 下的白名单项。Codex `config.toml` 与 Reasonix
  `config.toml`/`.env` 不纳入。`reasonix/AGENTS.md` 与 `reasonix/REASONIX.md` 在首次 push 前可以不存在；
  push 仅捕获本机已有的白名单文件。
- 模板不带模型与推理档位，但这不表示可以删除个人设置：`config-pull` 按文件复制，**不按字段合并**，
  审查 dry-run 时须逐项比较并保留目标里的个人覆盖值。
- deploy-skills 不包含 config-pull；把两者合并需要单独评审。
- 回归测试：`pwsh -NoProfile -File tests/config-sync.tests.ps1`。

---

## 12. Project Harness Profiles

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
pwsh -NoProfile -File scripts/build-harness-profile.ps1 -ProjectRoot <project> -Clean
pwsh -NoProfile -File scripts/apply-harness-profile.ps1 -ProjectRoot <project>
pwsh -NoProfile -File scripts/apply-harness-profile.ps1 -ProjectRoot <project> -Apply
```

- `status-harness-profile.ps1`：只读状态/漂移报告；`-Json` 向 stdout 输出 JSON，含解析后的 profile、组件、目标与源文件。
- `build-harness-profile.ps1`：只写目标项目的 `.agent-harness/generated/`；`-Clean` 先清空该生成目录再重建。
- `apply-harness-profile.ps1`：默认 dry-run；`-Apply` 只写 allowlisted 项目输出和 `.agent-harness/backups/`
  下的项目本地 rollback backup，不写 home 或 live skills。
- 受控输出类型：Rule 写 `AGENTS.md` / `CLAUDE.md` 的 managed block，Prompt 只进
  `.agent-harness/generated/`，Claude `.claude/commands/`、`.claude/agents/` 与
  `.claude/settings.json`（结构化合并），Codex `.codex/prompts/`、`.codex/agents/`。
- Profile 的 `Components` 只列用到的 bucket（`Rules`、`Prompts`、`Commands`、`Agents`、`ClaudeSettings`、
  `CodexAgents`），没列的 bucket 视为空；未知 bucket 或未知顶层 key 会被拒绝。
- 改 profile/component 或这几个脚本后跑 `tests/harness-profile.tests.ps1`。

---

## 13. Harness Environments

环境是命名的 skills 选集：`harness-source/envs/<name>.psd1`。deploy-skills 只消费 `Skills`：必须恰好有
`Claude`、`Codex`、`Reasonix`、`Zcode` 四个键（不要 skill 的平台写 `@()`；Zcode 从 Claude 生成物投影，
只有 Claude 可构建的 skill 才能选给 Zcode），否则拒绝运行，避免把缺键误读成空选集而
prune 全部。`env list` 显示文件名与 `Description`；`SchemaVersion` 与 `Name` 是声明性元数据，脚本不校验。

当前环境：`minimal`（测试样例）、`work`（日常）、`full`（全部受管 skills）；内容与数量见 [STATUS.md](../STATUS.md)。

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env list
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env list -JsonPath <report-file>
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env deploy work -DryRun
pwsh -NoProfile -File scripts/deploy-skills.ps1 -Environment full
```

- `env list -JsonPath <report-file>` 仍打印环境列表，同时把 `Environments`（每项 `Name`、`Description`）写入 JSON 文件。
- 选集只能包含已有 generated output 的 skill，缺失时 deploy-skills 报错停止。
- 切换到较小环境时，上次由 deploy-skills 部署、本次不再选中的目录进入 `prune`（先备份）。
- 任务临时需要的 skill 不要写回 `work.psd1`；长期需要时在评审过的提交里改环境定义。
- Codex 已缓存的 skill catalog 可能要新 task/thread 才刷新。

---

## 14. 统一 CLI

`scripts/agent-dotfiles.ps1` 只负责路由，把参数原样转给底层脚本：

```text
doctor                       -> scripts/doctor.ps1
build                        -> scripts/build-skills.ps1
scan                         -> scripts/scan-secrets.ps1
sync                         -> scripts/deploy-skills.ps1
env list                     列出 harness-source/envs/*.psd1
env deploy <name>            -> scripts/deploy-skills.ps1 -Environment <name>
config status | pull | push
profile status | build | apply
skills promote               -> scripts/promote-skill.ps1
```

只读命令：`doctor`、`scan`、`env list`、`config status`、`profile status`。`build` 与 `profile build`
只生成可重建输出。会写 live home、`skills-source/` 或项目目标的命令（`sync`、`env deploy`、`config pull/push`、
`profile apply`、`skills promote`）要求显式 `-DryRun` 或 `-Apply`，统一入口不会自动补 `-Apply`。

底层命令支持 `-Json` 时可直接透传，例如 `profile status -ProjectRoot <project> -Json`；统一 CLI
会抑制自己的调用提示和结果提示，让 stdout 保持底层 JSON。`env list` 使用上面的 `-JsonPath`，不支持 `-Json`。
