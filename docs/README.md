# ai-agent-dotfiles 使用说明

面向"未来的我"和"接手的 Claude Code / Codex agent"。看完这份手册即可独立维护本项目。

全局状态见 [STATUS.md](../STATUS.md)；新电脑接入见 [ONBOARD_NEW_MACHINE.md](ONBOARD_NEW_MACHINE.md)；当前局部任务见 [status/active/](../status/active/)；历史状态见 [status/archived/](../status/archived/)；恢复操作见 [RESTORE.md](RESTORE.md)。

---

## 1. 项目目的

统一管理多台电脑上的 Claude / Codex skills：

- 用 Git 维护**唯一可信源** `skills-source/`。
- 用 `scripts/build-skills.ps1` 从源生成 Claude / Codex 的 runtime output。
- 用 `scripts/sync.ps1` 安全地把生成结果部署到本机 live skills 目录。
- 用 `scripts/backup.ps1` 在每次 Apply 前保留可恢复副本。
- 用 repo-local Git hooks 在相关 `git pull` / rebase / branch checkout 后自动运行受控同步。

设计原则：保守、可审计、默认 dry-run、绝不整目录覆盖、绝不碰平台内置目录。

---

## 2. 当前管理范围

### 会同步
- `skills-source/shared/*`（跨平台，Claude + Codex 都装）
- `skills-source/claude-only/*`
- `skills-source/codex-only/*`
- `skills-source/openclaw-only/*`
- `openclaw/plugins/managed-plugins.json`（托管插件清单）
- 生成到 `claude/skills/`、`codex/skills/` 和 `openclaw/skills/`（Git-ignored）
- 部署到本机 live：
  - Claude：`~/.claude/skills`
  - Codex：`~/.codex/skills`；仅当它不存在时才 fallback 到 `~/.agents/skills`
  - OpenClaw：`~/.openclaw/skills`

### 不会同步
- Codex `~/.codex/skills/.system`（平台内置，永远保留）
- `imports/`（原始导入、归档、隔离）
- `backup`（备份目录，在 repo 外）
- 整个 live home 目录
- generated output 不进 Git
- 机器私有配置、API keys / tokens / secrets
- 临时日志
- quarantine 原始副本
- OpenClaw identity、credentials、devices、sessions、caches、npm installs、node launchers、workspace memory
- `~/.openclaw/plugins/installs.json`（机器私有状态，由 OpenClaw CLI 管理）

---

## 3. 目录说明

| 路径 | 说明 |
|---|---|
| `bootstrap.ps1` | 新 clone 的固定入口：安装 auto-sync hooks，并默认执行首次 live sync |
| `STATUS.md` | 唯一全局状态文件，直接更新，不重复新建总体状态报告 |
| `status/active/` | 当前正在进行的局部任务状态 |
| `status/archived/` | 已完成和历史局部任务状态 |
| `.claude/settings.json` | 项目级 harness 护栏（deny 编辑生成物/`.system`、禁 robocopy；allow 安全校验命令） |
| `skills-source/` | **唯一可信源**，手工维护的 skill 树 |
| `skills-source/shared/` | 跨平台 skill（生成到 Claude 和 Codex 两边） |
| `skills-source/claude-only/` | 仅 Claude 的 skill |
| `skills-source/codex-only/` | 仅 Codex 的 skill（如 `hatch-pet`） |
| `claude/skills/` | **生成物**，Git-ignored，勿手改 |
| `codex/skills/` | **生成物**，Git-ignored，勿手改 |
| `openclaw/skills/` | **生成物**，Git-ignored，勿手改 |
| `openclaw/plugins/managed-plugins.json` | 托管 OpenClaw 插件清单（期望状态） |
| `manifests/managed-skills.txt` | 本仓库托管的 skill 名单（sync 的 prune 只作用于名单内条目） |
| `scripts/build-skills.ps1` | 从源生成 runtime output，并刷新 manifest |
| `scripts/scan-secrets.ps1` | secret 扫描（gitleaks + 自定义回退扫描器） |
| `scripts/backup.ps1` | 备份 live Claude/Codex skills（含 `.system`）到 repo 外 |
| `scripts/sync.ps1` | manifest 限定的受控同步，默认 dry-run |
| `scripts/config-status.ps1` | 只读 config drift 报告（repo ↔ home），见 §14 |
| `scripts/config-pull.ps1` | 部署 harness 配置 repo→home，默认 dry-run，`-Apply` gated |
| `scripts/config-push.ps1` | 捕获 harness 配置 home→repo，双 gate（扫密 + 私有路径），默认 dry-run |
| `scripts/auto-sync-after-git.ps1` | Git hook runner；相关路径变化后调用 `sync.ps1 -Apply` |
| `scripts/apply-hooks.ps1` | 安装 repo-local Git auto-sync hooks |
| `imports/skills-inbox/` | 待审计的原始导入 skill |
| `imports/skills-archive/` | 已处理的导入归档 |
| `imports/skills-quarantine/` | 含 secret/异常、被隔离的 skill |
| `docs/archive/` | 历史计划与支持文档；历史状态报告已迁入 `status/archived/` |

---

## 4. 日常同步流程

Git 出于安全原因不会在 `git clone` 时执行仓库里的 hook。每个新 clone 的固定入口是：

```powershell
git clone <repo-url> C:\Repos\ai-agent-dotfiles
cd C:\Repos\ai-agent-dotfiles
pwsh -NoProfile -File .\bootstrap.ps1
```

`bootstrap.ps1` 会安装 repo-local auto-sync hooks，并立即通过 `auto-sync-after-git.ps1 -Force`
执行一次 `sync.ps1 -Apply`，所以初次 clone 后不会再漏掉 live skills 同步。

手动维护流程仍然可用：

```powershell
cd C:\Repos\ai-agent-dotfiles
git pull --ff-only

pwsh -NoProfile -File scripts/build-skills.ps1     # 从源生成 runtime output
pwsh -NoProfile -File scripts/scan-secrets.ps1     # 检查 secrets
pwsh -NoProfile -File scripts/sync.ps1             # dry-run：预览会同步什么
pwsh -NoProfile -File scripts/sync.ps1 -Apply      # 真实同步（自动先 build + scan + backup）
```

`sync.ps1` 默认是 **dry-run**，只打印计划、不动 live；只有 `-Apply` 才会真正修改。

如果只想安装 hooks、不执行首次 live 同步：

```powershell
pwsh -NoProfile -File .\bootstrap.ps1 -SkipInitialSync
```

安装后，`post-merge`、`post-checkout`、`post-rewrite` 会在 skill 管理相关路径变化时自动调用
`sync.ps1 -Apply`。自动同步仍然走 build、secret scan、backup、manifest-scoped sync 和 `.system`
保护；日志写在 `.git/ai-agent-dotfiles/auto-sync.log`。

---

## 5. 修改已有 skill 的流程

1. 只改 `skills-source/`（**不要**直接改 `claude/skills/` 或 `codex/skills/`）。
2. `scripts/build-skills.ps1`
3. `scripts/scan-secrets.ps1`
4. `scripts/sync.ps1`（dry-run 预览）
5. `scripts/sync.ps1 -Apply`
6. 提交 source / manifest / docs 变更（**不要**提交 generated output）。
7. `git push`
8. 其它电脑若已安装 auto-sync hooks，`git pull --ff-only` 后会自动同步；否则手动运行 `sync.ps1 -Apply`。

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
- 不要手改 `openclaw/skills/`（它是生成物）。
- 不要提交 `openclaw/skills/`。
- `~/.openclaw/plugins/installs.json` 是机器管理的状态文件——禁止提交、禁止手改。
- OpenClaw 插件的安装/卸载/启用/禁用必须通过 CLI 命令，禁止直接编辑 `installs.json`。

---

## 8. Codex `.system` 规则

- `.system` 是 Codex CLI **平台内置目录**（标记文件 `.codex-system-skills.marker`）。
- 含平台能力：`imagegen`、`openai-docs`、`plugin-creator`、`skill-creator`、`skill-installer`。
- backup 会**完整备份**它。
- sync **永远跳过**它（不更新、不删除）。
- 它**不属于** repo-managed skill。
- 删除它可能破坏 Codex 原生能力。

---

## 9. backup / restore

- `sync.ps1 -Apply` 会**自动 backup**（在改动前）。
- 手动备份：
  ```powershell
  pwsh -NoProfile -File scripts/backup.ps1
  ```
- 预览备份（不复制）：
  ```powershell
  pwsh -NoProfile -File scripts/backup.ps1 -DryRun
  ```
- 默认备份位置（repo 外）：
  ```text
  %USERPROFILE%\.ai-agent-dotfiles-backups
  ```
- 恢复操作详见 [RESTORE.md](RESTORE.md)。

---

## 10. 多电脑同步流程

一台电脑修改并 push 后，另一台：

```powershell
cd C:\Repos\ai-agent-dotfiles
pwsh -NoProfile -File .\bootstrap.ps1                  # 每个 clone 运行一次；安装 hooks 并首次同步
git pull --ff-only                                     # 后续相关更新会由 hooks 自动同步
```

如果没有安装 auto-sync hooks，仍可使用手动流程：

```powershell
pwsh -NoProfile -File scripts/build-skills.ps1
pwsh -NoProfile -File scripts/scan-secrets.ps1
pwsh -NoProfile -File scripts/sync.ps1
pwsh -NoProfile -File scripts/sync.ps1 -Apply
```

---

## 11. OpenClaw 插件管理

OpenClaw 插件通过 `openclaw/plugins/managed-plugins.json` 声明期望的插件状态。
这是一个人工审核过的声明文件，不包含 secrets、本地绝对路径或机器私有数据。

同步插件前，先运行 dry-run：
```powershell
pwsh -NoProfile -File scripts/sync-openclaw-plugins.ps1
```

确认无误后 apply：
```powershell
pwsh -NoProfile -File scripts/sync-openclaw-plugins.ps1 -Apply
```

规则：
- 插件的安装、更新、启用、禁用、卸载必须通过 OpenClaw CLI（`openclaw plugins install` 等），禁止直接编辑 `~/.openclaw/plugins/installs.json`。
- `installs.json` 是机器管理的状态文件，包含绝对路径和生成元数据，**绝不提交**。
- Bundled（内置）插件只能管理 enablement，不能卸载。
- 插件同步会在 `sync.ps1` 中自动调用（当 `managed-plugins.json` 存在时）。

---

## 12. 当前状态

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
A：`git clone` → `bootstrap.ps1`。bootstrap 会安装 auto-sync hooks，并立即走 `sync.ps1 -Apply` 的 build、secret scan、backup、manifest-scoped sync、`.system` 保护流程。之后相关 `git pull` / rebase / branch checkout 会自动同步。Claude live 目录不存在时会自动创建。

**Q：scan-secrets 报 false positive 怎么办？**
A：优先**改写源文档/示例措辞**让它不再像真实密钥——例如把"给 `secret` 键直接赋一个带引号的明文字符串"这类示例，改写成描述性文字（说明应从环境变量或密钥管理器读取）。**不要** whitelist，**不要**削弱 scan gate。改完重新 build + scan。

---

## 14. Harness 配置同步（config-sync）

除 skills 外，仓库还管理 agent harness 配置本身。源同样是 `manifests/whitelist.psd1`
（per-platform 的 Push/Pull items 与 ExcludedItems）。

- `.claude/settings.json`（项目级、已提交）：把硬规则变成 harness 强制 `permissions.deny`
  （禁止 `Edit`/`Write` 生成物 `claude|codex|openclaw/skills/**` 与 Codex `.system`、禁止 robocopy
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
  Codex 侧只同步 `AGENTS.md`/`prompts`。OpenClaw 插件状态仍由 `sync-openclaw-plugins.ps1` 管理。
- 回归测试：`pwsh -NoProfile -File tests/config-sync.tests.ps1`（覆盖三脚本 + 两个 gate、no-prune、幂等）。
