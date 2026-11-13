# AI Agent Dotfiles

在 Windows 上统一维护 Codex 和 ZCode 的日常 skills 与受管配置；保留 Claude 兼容构建与显式工具入口。
使用 PowerShell 7+；先预览，再按已授权范围执行 Apply。个人配置、凭据、会话和缓存不入库。

## 先选你的操作

| 想做什么 | 从这里开始 |
|---|---|
| 第一次在新电脑安装 | 下方“首次安装”及[新电脑接入说明](docs/ONBOARD_NEW_MACHINE.md) |
| 更新当前电脑 | 下方“日常更新” |
| 只检查，不部署 | 下方“查看状态与帮助” |
| 部署失败或想恢复旧内容 | 下方“失败与恢复”及[手册 §8](docs/README.md#8-备份与恢复) |
| 使用 Antigravity 双技能插件 | [手册 §15](docs/README.md#15-antigravity-插件) |
| 修改或新增 skill | [手册 §5–6](docs/README.md#5-修改已有-skill-的流程) |

## 首次安装

在 PowerShell 7+ 中克隆仓库并进入仓库根目录：

```powershell
$RepoRoot = '<repo-root>'
git clone <repo-url> $RepoRoot
Set-Location $RepoRoot
pwsh -NoProfile -File .\bootstrap.ps1
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 doctor
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env list
```

Bootstrap 安装并校验固定版本的 gitleaks，构建 skills，并打印下一步预览命令；不写 live skills 或 home 配置。
检查 doctor 的 FAIL 和 Deploy blockers；普通 WARN 也需按提示判断，但不等同于部署阻塞。
环境 `work` 是日常集合，`full` 包含全部受管 skills，`minimal` 是最小验证样例。

## 日常更新

在仓库根目录更新源码，明确本次使用的环境，再预览：

```powershell
git pull --ff-only
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env list
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env deploy work -DryRun
```

`work` 是示例，更新已有机器时沿用实际需要的环境；从 `full` 切到 `work` 可能移除此前部署的 skills。
逐项审查 install、update、prune、unknown 和配置计划。预览会重建仓库内可再生的输出，不写 live home 或部署状态。
仅更新 skills 时，使用 `scripts/deploy-skills.ps1 -Environment <name>`。

所有者授权本次部署范围后，执行对应 Apply：

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env deploy work -Apply
```

源码、目标或状态变化时重新预览。Apply 不会停下来等确认；授权规则见 [AGENTS.md](AGENTS.md)。
联合 Apply 会先完成 skills 和 config 的规划预检，再开始写入；权限、锁或并发变化仍可能导致运行时失败。
完成后按[部署后复核](docs/README.md#部署后的只读复核)检查：选中 skills 应为 unchanged，受管配置应无待更新项。
磁盘一致不代表旧聊天已加载新 skill，也不代表实际任务效果已经改善。

## 查看状态与帮助

以下命令只读；`env list` 显示的上次 Apply 环境只是记录，不验证 live 内容：

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 doctor
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env list
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 config status
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 help config
```

`config help` 与 `help config` 等价；`env`、`profile`、`skills`、`antigravity` 也支持分组帮助。
`config pull` 是仓库 → 本机，`config push` 是本机 → 仓库的配置捕获，和 Git push 无关。
捕获的 diff 必须由人审查后才能提交。`env list -JsonPath <file>` 会写报告文件，属于只读列表的显式写出例外。

## 失败与恢复

先读失败阶段、部署预览和备份提示，再按[手册 §8](docs/README.md#8-备份与恢复)处理。
`Preflight failed` 表示尚未写 live 或部署状态；`Skills stage completed; config stage failed` 表示 skills 已完成，配置阶段失败。
联合部署的 skills 与 config 不构成原子事务；发生运行时失败时，已完成的 skills 可能仍然保留。
unknown 目录默认保留，不能据此认定是垃圾；恢复、退休旧 skill 或重新 Apply 都应先核对具体对象和授权范围。
不要手工清理 Codex `.system` 或整目录镜像 live skills。

## Antigravity 插件

Antigravity 使用独立入口，首版 `ai-agent-dotfiles` 版本为 `0.1.0`，只含 `boring-engineering` 与 `git-review`：

```powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity build
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity status
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity deploy -DryRun
```

构建从 canonical 源生成到 `tmp/antigravity/plugins/ai-agent-dotfiles/`，不会安装；`status` 不构建或修复。
第三方插件只读核对，原有 `sync`、`env deploy` 与三平台选择保持不变。首次安装可能立即启用技能，
须先审阅预览并取得覆盖具体身份、版本和启用影响的许可；原生模型验收另须覆盖实际调用范围。
未证明的更新与回滚保持 blocked。安装、启用、加载和实际使用分别验收，详见[手册 §15](docs/README.md#15-antigravity-插件)。

## 管理范围

- `skills-source/` 是 skills 唯一源；build 生成 `claude/skills/`、`codex/skills/`，生成物不提交。
- 环境定义位于 `harness-source/envs/`。当前 `work` 的 Claude/Codex/ZCode 为 0/9/8，
  `subagent-driven-development` 仅选入 Codex 的 `work`；`full` 在三平台均包含它。
- 部署逐个 skill 目录进行，只 prune 本工具记录过或显式 `-Retire` 点名的目录；未知目录保留，Codex `.system` 不受管。
- 配置 status/pull/push 及组合部署默认只处理 Codex，不会重建 Claude live 配置；旧 Claude 配置工具须显式 `-Platform Claude`。Codex `AGENTS.md` 只更新受管 block，保留 block 外文本。
- ZCode 继续从 Claude 生成物投影部署；这不需要 Claude 账号、CLI 或 live 根。共享 `base`/`coding` profile 默认只生成 Codex 项目目标。Codex 同时存在 `~/.codex/skills` 与 `~/.agents/skills` 时拒绝部署，需先人工判断。
- 不同步 Codex `config.toml`、私有 `.env`、凭据、会话或缓存；不注册 MCP servers。
  需要外部能力时使用当前会话可用的连接器，并核实访问权限。

## 进一步阅读

- [使用手册](docs/README.md)：部署、恢复、配置、项目 profile、环境、CLI 与维护检查。
- [新电脑接入](docs/ONBOARD_NEW_MACHINE.md)、[ZCode 使用说明](docs/ZCODE.md)。
- [当前状态与未完成事项](STATUS.md)、[进行中任务](status/active/)、[历史索引](docs/HISTORY.md)。
- [Agent 工作规则](AGENTS.md)：源文件、权限、部署、检查与提交边界。
