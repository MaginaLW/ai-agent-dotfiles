# Antigravity 插件接入执行计划

日期：2026-11-13（Asia/Singapore）。
状态：首版接入及获准验收已完成（2026-11-14，Asia/Singapore）。PR #9 已合并，精确 head 与合并 main 的 Validate 均通过；A01 覆盖的首装和 App/CLI 各三个合成会话已完成。下文保留原执行约束；结果与证据限制见文末及 STATUS.md。后续更新、回滚和新增范围不继承本次有限授权。

## 1. 交付目标与范围

把 Antigravity 自身使用的插件纳入本项目：源码可审阅、构建可复现、安装前可预览、安装后可核对，并能在原生会话中确认实际使用。首版提供一个仅含技能的本项目插件，以及第三方插件的只读清单核对。

采用独立插件入口，保留现有 Claude/Codex/ZCode 三平台环境与部署行为。技能正文继续只保存在 skills-source/；不增加一份人工维护的 Antigravity 技能副本。

首版固定范围：

- 插件名 ai-agent-dotfiles，首版版本 0.1.0；重名时拒绝接管，不能擅自改名绕过冲突。
- 选入 shared/git-review 和 shared/boring-engineering；审核全部附属文件及相对引用后打包。
- 仅使用官方 agy plugin 安装与管理能力；不手改安装目录或全局注册配置。
- 第三方插件首版仅记录与比较来源、版本和启用状态，不自动安装、更新、启停或删除。
- 首版不包含 rules、MCP、hooks、自定义 agents、模型默认值或推理档位，不变更内置 swarm。
- 不打包 codex-only/antigravity-delegation，不调用 Bridge 或从 Codex 包装发起 Antigravity 模型任务。
- approval-feedback、tool-scope、科研写作等其他技能逐项复核后再扩充；shared 标签不等于已经适配。
- 不做市场发布、账户迁移、凭据同步、自动升级、定时任务或跨平台部署框架重构。

## 2. 已有依据与必须刷新的状态

规划所用已提交基线为 2c95d35556b8e293070f71ae4783f51b22c522d1。实施开始时重新记录实际目标 SHA，不把该基线当作永远最新。

| 对象 | 本次规划已有证据 | 实施前处理 |
|---|---|---|
| 主检出 | antigravity-delegation 分支和活动记录占用主树，存在未提交选择、源码及 manifest 改动 | 只读使用；从稳定已提交基线建独立工作树，不携带该 WIP |
| 本机软件 | 桌面端文件版本 2.31.2；agy --version 为 1.5.8 | 重新核对版本、实际可执行文件和支持的子命令 |
| 用户插件 | 前次 agy plugin list --json 为 []；共享插件目录为空 | 重新查询，区分用户插件与内置组件；空清单不证明当前会话没有内置能力 |
| 内置能力 | 桌面端存在 swarm 与内置技能 | 原样保留，不纳入清理或替换范围 |
| 自定义技能 | 前次未发现共享全局、兼容目录及本仓库项目技能 | 仅复核目标项目和已知发现入口；不扫描所有项目或整个用户目录 |
| 现有部署 | 环境严格限定 Claude/Codex/ZCode，组合部署还会 config-pull | 首版不修改 work/full/minimal 选择和默认 sync 行为 |
| 长期授权 | AGENTS.md Skill rules 10 只覆盖匹配条件下的 Codex/ZCode 更新 | 不继承到 Antigravity 首装、启停、卸载或配置修改 |

官方依据（2026-11-13 查阅，具体本机行为仍按下面的合同核验）：

- [插件构建](https://antigravity.google/docs/build-plugins/)：原生插件格式、校验与本地路径安装。
- [定制内容发现](https://antigravity.google/docs/customization-discovery)：插件技能命名空间、规则累加与客户端加载来源。
- [技能](https://antigravity.google/docs/skills)：技能结构、App/CLI 共享目录及旧目录差异。
- [插件市场与管理](https://antigravity.google/docs/marketplace/)：官方插件管理入口和加载能力。

计划中的防冲突选择基于这些事实：插件技能使用 <plugin>:<skill> 命名空间；规则会累加；CLI 的部分旧技能目录不被 App 读取。仍需检查功能重复，不能把名称不冲突理解成行为一定不冲突。

## 3. 工作树、分工与依赖

所有源码、测试夹具和可控制的临时材料留在实施工作树内。写入前使用现有工作区落盘预检脚本核对真实 cwd、路径和临时目录；Git 管理元数据及部署获准后的原生应用状态按精确例外处理。不得通过扩大工作区根或改 HOME 来假装隔离。

任务按下表推进。委派遵守当前 AGENTS.md 和宿主额度，不为凑人数拆分；共享文件和本机 Apply 始终只有一个写者。

| 任务 | 负责人和写入范围 | 依赖 | 完成输出 |
|---|---|---|---|
| T0 基线与原生合同 | 主执行者；只读调查 | 无 | 当前 SHA、WIP 边界、CLI 能力、未知项 |
| T1 包配置、构建和测试 | 可委派给一个实现者；包配置、单一插件脚本及对应套件 | T0 确定包合同 | 可重建、通过严格校验的双技能包 |
| T2 状态、预览与生命周期 | 主执行者或独立实现者；与 T1 同一脚本时必须串行交接写权 | T1 接口固定；可提前准备输入夹具 | 身份核对、准确预览、受限 Apply 和失败读回 |
| T3 CLI、规则与使用说明 | 主执行者串行整合 | T1/T2 接口固定 | 显式入口、精确规则差异、文档 |
| T4 交付边界审阅与检查 | 主执行者整合；必要时一个独立审阅者 | T1–T3 | 相关测试、本地全套、当前头 CI |
| T5 获准的本机部署与原生验收 | 一个执行者；仅目标插件及原生必需状态 | T4、有效部署许可和平台权限 | 安装读回、App/CLI 加载、实际使用结果 |
| T6 收尾 | 主执行者 | T5 或明确保留部署阻塞 | 状态、版本、证据限制及后续项 |

T0 的原生合同调查与源技能兼容性阅读可并行。缺少部署许可时继续完成 T1–T4，不冻结源码准备。T2 不得假定官方未确认的隔离、覆盖或降级行为。合入主树须等当前主写者释放并获适用整合许可，不要求其他任务为此停止工作。

## 4. 拟修改文件与接口

这些是实施目标，尚未存在的命令不得在当前树直接执行。

| 路径 | 计划内容 |
|---|---|
| harness-source/antigravity/plugins.psd1 | 唯一插件选择与元数据配置；本项目插件身份、版本、技能清单，以及空的第三方期望清单 |
| scripts/antigravity-plugins.ps1 | 一个薄入口，Action 为 Build、Status、Deploy；内部复用现有技能复制、路径防护和固定扫描工具 |
| scripts/agent-dotfiles.ps1 | 增加显式 antigravity 子命令和帮助；不改 sync/env deploy 的默认语义 |
| tests/antigravity-plugins.tests.ps1 | 包、状态、预览、生命周期与拒绝错误目标的必要行为测试 |
| tests/agent-dotfiles.tests.ps1 | 仅补新路由、帮助和模式传递验证 |
| AGENTS.md | 精确补充受管插件构建/部署边界，不扩大现有长期授权；变更后按项目要求在新任务加载规则 |
| docs/README.md、README.md | 使用、状态判读、恢复限制及入口说明；避免重复整份计划 |
| STATUS.md、status/active/antigravity-plugins.md | 按现有约定记录当前结果与任务进度；收尾移除活动记录 |

生成包拟放 tmp/antigravity/plugins/ai-agent-dotfiles/，沿用已有忽略目录。默认不增加新的生成根、扫描排除或 .gitignore 规则；包路径只能作为可重建材料，不能成为技能源码。

配置拟定最小合同：

~~~powershell
@{
    SchemaVersion = 1
    NativeValidationComponents = @('agents', 'hooks', 'mcpServers', 'rules', 'sidecars', 'skills')
    ManagedPlugin = @{
        Name = 'ai-agent-dotfiles'
        DisplayName = 'AI Agent Dotfiles'
        Version = '0.1.0'
        Description = 'Reviewed skills maintained by this repository.'
        Skills = @('boring-engineering', 'git-review')
    }
    ExternalPlugins = @()
}
~~~

第三方清单为空表示本项目暂不托管任何第三方插件，不表示要求本机第三方插件为零。以后列入时记录精确插件身份、公开来源、可核实的版本或 revision 与期望启用状态；本机路径、账户和令牌不进 Git。来源或版本未知时输出 UNKNOWN，不猜测，不自动修复。

接口约定：

- Build：只写工作树生成目录；无 agy 时仍可准备包，但原生校验标为未完成。
- Status：只读本机与候选包；不构建、不安装、不启停、不自动修复，不存在的候选包报 missing。
- Deploy：底层默认 dry run；只有显式 -Apply 才可调用原生变更命令。
- 统一 CLI 的 deploy 延续现有约定，要求恰好一个 -DryRun 或 -Apply；Build/Status 不接收 Apply。
- 支持 RepoRoot 和 JsonPath，语义沿用现有脚本；不暴露未经证明有效的原生 HomeRoot/ConfigRoot 参数。
- 依赖的 agy 路径在本机解析并核实，不写入 tracked 配置；所有外部命令检查退出码。
- JSON 使用实现时实际读取并验证的字段，不先假造 agy 输出 schema；对缺失或未知字段失败关闭，报告兼容性缺口。
- 不新增后台服务、通用插件注册中心、依赖下载器或第二套权限引擎。

## 5. T0 原生合同核对

先运行当前已存在的只读入口：

~~~powershell
git status --short --branch
git rev-parse HEAD
agy --version
agy plugin help
agy plugin validate --help
agy plugin list --json
~~~

然后核对选定的 Antigravity 项目：

1. App/CLI 实际使用同一个全局配置根还是不同来源；只读取所需字段，不输出整个配置。
2. 已安装插件实际 JSON 的名字、安装路径、版本、启用状态和组件表示方式。
3. 同名冲突按 manifest name 判断；安装目录名只能作位置证据。
4. 全局、项目及兼容技能目录、发现 manifest 和项目规则是否重复提供同一能力。
5. 本项目插件是否已经由其他任务安装；若有，先识别归属，不重复首装。
6. 只检查当前目标项目及其实际加载链，不把所有本机项目纳入扫描。

必须明确的未知项：

| 问题 | 求证方式 | 未求证时的处理 |
|---|---|---|
| 同名本地 install 是覆盖、拒绝还是并存 | 官方说明、当前实现/帮助；获准后的最小实际读回 | 禁止把再次 install 当已验证更新；首装可独立准备 |
| 降级旧包是否受支持 | 正式机制或获准的实际生命周期验证 | 不承诺一键回滚，不自动卸载重装 |
| 安装失败是否部分写入 | 注册状态和目标文件读回 | UNKNOWN/partial，停止该写入链，不盲重试 |
| 原生命令是否支持隔离配置根 | 官方支持且能证明落点 | 不靠改 HOME/USERPROFILE 猜测；离线夹具只证明脚本逻辑 |
| 本地路径是复制还是持续引用 | 安装后路径和内容读回 | 确认前保留构建包和工作树，不能清理 |
| 更新是否保留启停选择、移除旧文件 | 更新前后读回 | 更新功能不得宣称验收通过 |

本机 1.5.8 没有 plugin update/rollback 子命令；顶层 agy update 是另一件事。不得发明命令或用未公开 RPC 规避。

不为隔离自动创建 Windows 账户、改系统设置或安装另一套客户端。若无官方隔离能力，采用离线夹具完成开发验证，准备一次精确的真实目标首装；后续真实更新的缺口单独报告，不阻断已可完成的首装准备。

## 6. T1 构建双技能插件

执行顺序：

1. 审核两个技能的 SKILL.md、附属文件、外部链接和运行依赖；记录需要保留的相对路径。
2. 校验配置、重复名字和来源位置；只允许清单中存在的 shared 技能，拒绝链接、越界路径与未识别组件。
3. 从 canonical 源复制，复用 Copy-SkillTree 的边界检查和现有运行期排除合同（包括 CREATION-LOG.md）。不把 Claude/Codex 生成物作为输入。
4. 生成原生 plugin.json 与 skills/<name>/，不引入 rules/MCP/hooks/agents。
5. 输出确定性的相对文件清单与 SHA-256。内容不含构建时间戳、主机路径和账户信息。
6. 连续两次相同输入构建，包内容与 digest 一致；清理只限该任务确认归属的生成目录，不触及任何 live 根。
7. 在工作树仓库根运行 agy plugin validate tmp/antigravity/plugins/ai-agent-dotfiles --strict --json 检查整个包，任何 error/warning 均先解释和修复。

生成目录在 tmp/，现有仓库扫描会排除它。因此必须同时扫描 canonical 输入，并用项目已校验的 pinned gitleaks 和同一 .gitleaks.toml 扫描最终包；不能只凭 tmp/ 被忽略就称“包已扫描”。复用 pinned-tool.ps1，不新增扫描白名单或手改锁文件。

版本合同：每次发布新的包内容必须递增插件版本；已部署的同名同版本与候选 digest 不同时为 blocked，不允许原地覆盖。同名版本相同且内容一致才是 unchanged。已安装内容偏离该版本已记录的包时判为本地漂移；没有可信旧包/记录时判为 unknown，不能误判成普通更新。

T1 验收：仅有两个选定技能及必要元数据；文件与已扫描源/确定性生成合同一致；所有相对引用可解析；严格原生校验通过；两个既有生成根和 manifests 没有非预期改动。

## 7. T2 状态、预览和受限部署

状态结果分层输出：

| 结果 | 含义 | 自动变更 |
|---|---|---|
| install | 目标身份不存在，可准备首次安装 | 仅获准 Apply |
| unchanged | 身份、内容、版本与期望一致 | 不调用原生变更命令 |
| update | 已确认本项目管理，候选内容不同且更新合同已证明 | 仅覆盖已审阅范围的 Apply |
| blocked/unknown | 同名未知、漂移、合同未明、字段不兼容或其他写者 | 不写入 |
| external | 本任务之外的插件或内置组件 | 仅报告、原样保留 |

预览应展示：

- 实际 agy 版本和目标配置根，目标 manifest 身份及安装目录证据。
- 源 revision、候选版本、候选包 digest、选入技能。
- 相对文件 added/changed/removed 和当前启用状态；不能只显示“update”。
- 将调用的原生动作、它会写入的精确范围、已知原生必需状态及剩余未知项。
- 未被管理的插件摘要，不把它们当作需卸载的差异。
- 扫描/校验结果；未满足条件时输出阻塞，不继续 Apply。

Apply 流程：

1. 确认审阅的是当前包、有效许可覆盖目标和实际动作；校验源、包及 live 状态未发生变化。
2. 确认无其他部署或已知插件管理写者；脚本重入锁只约束本脚本，不能声称已锁住 Antigravity App。
3. 在第一次原生写入前保存本插件的候选包、相关 pre-state 和可用旧包；只保存恢复所需最小信息，备份不入 Git。
4. 通过官方 agy plugin install <package-directory> 执行获准的安装。首次安装可能立即启用技能，许可必须覆盖这一实际影响。
5. 退出码无论成功或失败都读回注册状态、安装位置和文件。成功不能只看一行 SUCCESS；失败也不能直接认定零副作用。
6. 核对原生生成元数据与技能内容，分别校验版本、启用和包内容；原生生成文件不能伪装成源漂移。
7. 重跑同一部署预览，期望 unchanged；没有变化就不再 Apply。

首次部署不故意制造多个版本或失败来测试真实 home。更新使用离线夹具验证规划逻辑；真实更新/恢复合同未证明时保持 blocked，并在下一次确有版本变更的获准任务中补验。

第三方清单比较只做外部状态；不要调用 plugin import 把整个 Claude/Gemini 环境导入，也不自动安装推荐项。

## 8. T3 正式规则与使用入口

实施时先提交可审阅的最小规则差异，拟对 Skill rules 2–3 补充以下含义：

> Antigravity 插件包由 scripts/antigravity-plugins.ps1 从已审阅的 skills-source/shared/ 选择生成到任务生成目录，不手改生成包。Antigravity 插件变更仅通过该受管入口调用官方 agy plugin 管理命令，不手写 live 插件或注册配置。先审阅完整预览，再在明确覆盖目标身份、版本、启用影响及恢复范围的授权内 Apply；保留未知插件与内置组件。该路由不属于 Skill rules 10 的 Codex/ZCode 长期部署授权。

此处是提案，不是生效规则，也不自行授予持续许可。最终文字须与实现一致，保留 owner 授权与平台审批边界；规则改动后按项目要求由新任务重新加载。

新命令拟采用以下接口；只有 T1–T3 完成并通过检查后才可运行：

~~~powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity build
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity status
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity deploy -DryRun
~~~

统一 CLI 只分派到薄脚本，不触发 Codex config-pull、旧三平台部署或全局指令同步。手册同时写明命令的当前生效版本、状态含义、恢复限制和两端加载检查方式。

## 9. T4 离线检查与 Git 交付

必要行为覆盖，集中在一个新套件及受影响的 CLI 套件，不为每段实现另写镜像测试：

| 检查 | 必须证明 |
|---|---|
| 包选择与安全边界 | 未选入技能不出现；越界/reparse/未知组件拒绝；运行期排除生效 |
| 预览零变更 | 不调用 install/enable/disable/uninstall，不改变 live/state；实际原生 CLI 的自管理日志不误称为完全零磁盘写入 |
| 幂等与身份 | 同内容 unchanged；同名未知拒绝；无关插件保留 |
| 生命周期夹具 | 安装/更新规划正确；失败后读回；启停选择不擅改；无支持的更新/恢复合同则 blocked |
| CLI 路由 | 帮助与参数一致；Apply/DryRun 不混用；旧 sync/env/config 不变 |
| 漂移与竞态 | 源/候选/live 发生变化则停止；不沿用旧预览继续写 |
| 凭据与扫描 | 源和包均扫描；不扫描并输出账户或会话原文；未使用 bypass |
| 构建回归 | 现有 Claude/Codex 生成与 manifest 合同保持正确；不恢复 Claude live 部署 |

拟执行的现有检查：

~~~powershell
pwsh -NoProfile -File scripts/check-powershell-syntax.ps1
pwsh -NoProfile -File scripts/build-skills.ps1
pwsh -NoProfile -File scripts/scan-secrets.ps1
pwsh -NoProfile -File tests/antigravity-plugins.tests.ps1
pwsh -NoProfile -File tests/agent-dotfiles.tests.ps1
git diff --check
~~~

按实际改动补受影响 suite。脚本/测试改动合并前运行一次完整 run-tests.ps1，并取得该 PR 当前精确 head 的 Validate 成功；先估算耗时并通知，全机只运行一个完整检查或 live Apply。已有覆盖相同版本的证据复用，不重复等价扫描。

小步提交建议：①配置与包构建；②状态/部署/CLI及对应测试；③最终说明和结果。规则差异与真正实现同批审阅；AGENTS.md 变更后启动新任务加载，不在旧会话假装已生效。仅提交已审阅任务文件，生成包、备份和本机状态不入库。

正常推送前核对 origin、owner、visibility 和写权限，使用适用授权；公开仓库仅发布无敏感信息的项目内容。合并仍需 owner 授权及当前 CI，不能用本计划或 local PASS 推定许可。

## 10. T5 首次部署与实际使用验收

准备好以下信息后，一次集中处理尚缺的实际许可，而非逐步骤重复询问：

- 目标：当前机器 Antigravity 原生共享插件根中的 ai-agent-dotfiles，候选 0.1.0、两个技能、确定的包 digest。
- 动作：本地安装与安装后可能启用、只读核对和必要范围内的恢复；普通插件安装不购买 credits。
- 范围：目标插件及已识别原生注册/状态；不改其他插件、规则、MCP、默认模型、凭据或 Codex/ZCode。
- 恢复：首次安装后停用该插件的有限恢复范围是否被覆盖；卸载和旧版本重装必须分别明确，不由“恢复”一词无限推导。
- 原生会话验收：是否覆盖 App/CLI 的最小任务，以及已有订阅额度或付费边界；不从 Codex 额外发起未获准模型调用。
- 停止：同名归属不明、包/hash 或目标变化、未知副作用、其他写者、认证/区域/预算问题。

获准后才运行拟新增入口：

~~~powershell
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity deploy -Apply
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity status
pwsh -NoProfile -File scripts/agent-dotfiles.ps1 antigravity deploy -DryRun
~~~

App 与 CLI 验收分别记录，按真实客户端界面使用插件面板、项目 Customizations 和 /skills；需要时用 /skills reload 或新会话，不假定所有旧会话已经更新。

| 用例 | 操作 | 通过证据 |
|---|---|---|
| 发现 | 在 App 与 CLI 查看本插件及两个技能 | 来源、插件身份、加载路径和版本对应当前包；启用状态明确 |
| 显式使用 | 在原生会话选择 git-review 技能审阅一个仅含合成数据的小 diff | 读到当前正文，指出夹具中预设的实际缺陷；不修改真实项目 |
| 自然触发 | 在独立原生会话给出小型结构设计题，不点名 boring-engineering | 有实际读取该技能的证据，方案符合任务要求；口头声称使用不够 |
| 无关任务 | 在独立会话提出简单翻译等与两个技能无关的问题 | 可见工具轨迹/加载证据中未调用这两个技能；没有可见性时标 UNKNOWN |

使用工作树内的可丢弃 fixture；固定题目与预期结果，避免向外发送真实业务数据。为减少干扰，负例与自然触发不用已显式加载技能的同一会话。

不以一句“遵守了技能”推断读取，也不以一次成功声称长期改善。无模型调用许可时可以完成安装与加载检查，实际使用层保持待验收；缺少某客户端能力只暂停该层。

## 11. 异常与恢复

| 情况 | 动作 |
|---|---|
| 首次写入前失败 | 证明确实无 live 副作用后修正准备；复用原范围许可，不重新请求同一授权 |
| 安装退出非零/超时 | 先读回文件和注册状态；未知或 partial 时停止该写入链并报告，不直接重试 |
| 安装成功但技能未启用 | 核对原生启停与加载来源；不直接改 config.json |
| 技能加载但任务不使用 | 查触发描述、来源和实际调用证据；避免用重复规则强制注入来掩盖问题 |
| 同名未知/本地修改 | 保留原状态，只暂停目标插件接管；无关工作继续 |
| 已安装技能造成干扰 | 若已有明确恢复许可，用官方 disable 仅停用该身份，读回；否则保留证据并提出精确决定 |
| 更新后需降级 | 只在官方恢复路径已验证、旧包来源可靠且许可覆盖时执行；否则保持 disabled/blocked 的实际状态 |
| 需要卸载 | 先核实卸载对插件数据的实际影响及明确许可；只用官方卸载，不删除整个插件根或配置根 |

不备份/覆盖整个 .gemini/config；最小 pre-state 中也不带入凭据。恢复成功必须由读回证明，不能只看命令退出码。恢复链未知时清楚保留限制，不宣称事务性或一键恢复。

## 12. 完成定义与后续扩充

源码交付完成需要：

- [x] 双技能插件可复现构建，canonical 与最终包扫描、原生 strict 校验通过。
- [x] 状态、预览和显式 Apply 入口及必要测试完成；旧默认部署行为不变。
- [x] 精确规则路由、文档和当前版本检查结果一致，工作树内容可审阅。
- [x] 必需本地检查及当前头 CI 满足实际阶段要求；提交只含本任务内容。
- [x] 更新/恢复未被证明的能力明确保持 blocked，不伪装为已验收。

接入完成还需要：

- [x] 明确目标范围的部署许可与平台权限有效，安装结果与 approved 包一致。
- [x] 状态读回正确，同一预览为 unchanged，无其他 live 目标被改写。
- [x] App 和 CLI 的加载层分别核对；支持的实际使用用例通过，缺口明确。
- [x] 最终汇报区分 built / validated / installed / enabled / loaded / used；未测量时不报 outcome-improved。
- [x] STATUS 更新为当前事实，活动记录收尾；备份保留，任务工作树在确认不被原生引用且交付已有稳定位置后按宿主归档规则处理。

后续只在真实需要时扩充技能。对 approval-feedback 先验证 Antigravity 客户端身份、询问形式、私有台账权限与脚本可达性；对 subagent 类技能核对原生能力和现有 swarm，避免重复编排。第三方插件需要写入管理时另行补充其真实来源、更新/恢复合同和授权，不借首版空清单自动获得这些能力。

### 2026-11-14 执行结果

- 源码：PR #9 合并为 `fad4433`；精确 head `3900374` 的 Validate `43450482705` 和合并 main 的 Validate `43451810536` 均成功。CLI 114 项、生命周期 91 项及受影响补验通过。首次本地完整运行的 12/15 FAIL 保留在私有证据中；home 外检出补验 profile 82 项，并修复新增套件预算与组件校验集成问题，未放宽既有门禁。
- 验收文档交付：PR #10 合并为 `19e9c4c`；精确 head `b302a7d` 的 Validate `43475060639` 和合并 main 的 Validate `43476333032` 均成功，PR 日志明确 15 个套件全部通过。该结果不覆盖之后的新提交。
- 包：`ai-agent-dotfiles@0.1.0`，12 个文件，SHA-256 digest 为 `7d4e1e8eeaf42c4b53c2343404b36f631ea0c3ee4dc57cffb9ae5ba2936d4a27`。原生 CLI `1.5.8` 的 strict 校验、canonical/最终包扫描和重复构建均通过。
- 安装：A01 明确批准后只执行一次受管首次安装。安装目录为普通副本而非工作树链接，文件 map 与批准包一致，启用为 true，最终预览为 unchanged。首装前后原生 config 文件字节相同。稳定包、归属记录、候选备份和运行证据保存在主检出的 ignored `tmp/antigravity/`，不随临时工作树清理而移除。
- 原生验收：App/CLI 各三个独立会话，共 6/6 次；没有新增购买、Bridge 调用、模型默认值或权限覆盖。以下使用证据是本次合成场景的结果，不外推长期改善。

| 用例 | App 证据 | CLI 证据 |
|---|---|---|
| 发现与显式使用 | 插件页显示 0.1.0 和两个技能；从 `AI Agent Dotfiles` 选择 `git-review`，正确指出合成 diff 的差一错误及 count=0 问题 | init 的 expanded_commands 指明 `ai-agent-dotfiles:git-review`，原生展开日志与当前安装内容绑定；结果指出预设缺陷 |
| 自然触发 | 未点名技能；原生 `Explored file` 轨迹指向安装包的 `boring-engineering/SKILL.md#L1-130`，返回单文件 CSV 方案 | DONE 的 read_file 指向同一安装包正文，返回不需要插件注册表或服务层的方案 |
| 无关任务 | 新会话只返回译文，可见历史无技能读取或工具活动块 | 新 conversation ID，SUCCESS、无展开命令且无完成工具调用 |

安装、启用、加载和使用层均有上述证据；outcome-improved 未测量。更新/降级/恢复合同仍未获真实生命周期证明，继续 blocked。六次原生会话预算已用尽，不继续调用模型。原生诊断日志可能包含账户信息，保持私有，不将原始日志或会话数据提交到仓库。

收尾与复用：临时验证 clone 在确认干净、无 reparse point 并保存六份测试日志后已删除。两个托管工作树未归档：宿主分别以“任务的主检出不能移除”和“仍有其他活动任务使用”为由拒绝；保持原状，不手工删除绕过保护。所有任务分支保留。主检出存在无关 WIP，本次未快进其 local main；远端 main 的已合并状态与本地主树是否同步分别判断。稳定证据位于主检出的 ignored `tmp/antigravity/`，其中 `closeout.json` 保存最终 CI 与清理回执，`local-checks/` 保存测试日志。后续清理先确认包及证据不依赖临时树，再按宿主允许的归档方式处理；本次拒绝不证明今后仍会拒绝，也不要求自动重试。

本次有限授权与实施结果不授予后续安装、启停、卸载、模型调用、合并或额外付费的持续权限。
