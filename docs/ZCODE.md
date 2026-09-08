# 在 ZCode 中维护本仓库

本仓库是 `harness-model` 轻量协作规则的首个跨项目 ZCode 试用点。接入方式是项目根目录的
[`AGENTS.md`](../AGENTS.md)：在 ZCode 中打开本仓库根目录，再启动新任务即可，无需专用关键词、
Skill 或斜杠命令。ZCode 对项目指令的加载方式见[官方说明](https://zcode.z.ai/en/docs/agents)。
首次接手时让 Agent 显式读取并简述项目规则，核对内容与工作区是否正确；这证明文件可读，
不能仅凭模型自述证明自动注入机制。已有任务应重新读取 `AGENTS.md`，不要假定新增规则
已进入旧上下文；本次接入准备未执行 ZCode 任务，实际加载仍待首次使用时核对。

这里的 ZCode 是维护仓库的工作工具。此接入没有把 ZCode 增加为 live skills 部署平台，没有
安装完整 AI Flow 引擎、创建其任务账本或修改用户全局配置，也不会自动将其他项目纳入规则。
后续真实任务的简要记录可用于 `harness-model` 阶段三的人工评估输入；目前没有自动回传、
跨项目数据汇总或后台采集。

## 接手和完成任务

先读 `AGENTS.md` 和 [`STATUS.md`](../STATUS.md)，核对当前分支、工作区改动与用户给出的工作项。
只在相关时读取 [`status/active/`](../status/active/) 中的任务记录；状态摘要与后续证据不一致时，
先核对具体记录与代码，不凭摘要自行决定推进阶段。

用户提供具体任务后，在已授权范围内连续完成必要阅读、实现、验证、复核和小步提交。
保留已有改动，提交只包含本任务已复核的文件；缺少会改变方向的决定或实际所需权限时才停下说明。
普通文档、代码和 Git 工作按 `AGENTS.md` 的 Scope trigger 判断是否需要完整 skill-management
workflow，不因使用 ZCode 就额外启动技能安装或同步流程。

沿用用户选择的主会话、模型和推理设置；没有明确覆盖时使用当前运行时默认。实现与独立审查
按职责安排，不固定型号，也不根据历史记录推断当前模型身份。具体产品权限、运行时能力和
现有独立审查要求继续适用。

Phase 0 引入的生产联锁仍是实际执行边界。当前 `ReleaseState=interlocked` 下，生产
Apply、rollback、retirement 和非 DryRun 的 standalone backup 等受保护入口会返回
`safety-protocol-upgrade-required`；bootstrap/hooks 只能生成预览或事件。接入 ZCode 不是
解除联锁或执行 live 部署的授权。具体范围以当前项目规则和受控 Policy 为准；不得通过改
Policy、替换入口或手工操作 live 目录绕过它。`apply-harness-profile.ps1 -Apply` 的项目本地
允许清单例外继续按原规则执行，不扩展为 production live 部署权限。

## 验证沿用现有入口

本仓使用 PowerShell 7+。根据实际改动选择检查，检查命令、结果和未执行项要如实交代。
普通文档改动先检查链接、差异和 secret scan；涉及代码行为时执行对应测试，按现有要求完成
全量验证。CI 的完整门禁以 [`.github/workflows/validate.yml`](../.github/workflows/validate.yml)
为准，不因轻量接入而缩减；本地局部检查通过不代表完整 CI 通过。

在仓库根目录运行以下现有入口；每条执行后确认退出码与输出，再决定下一步：

```powershell
git diff --check
$repoRoot = (Get-Location).Path
pwsh -NoProfile -File .\scripts\scan-secrets.ps1 -RepoRoot $repoRoot
pwsh -NoProfile -File .\scripts\check-powershell-syntax.ps1 -RepoRoot $repoRoot
```

需要完整回归时使用统一入口，它会发现并运行全部根目录测试套件。摘要写入外部临时目录，
不要把含本机信息的原始报告加入 Git：

```powershell
$summaryPath = Join-Path ([System.IO.Path]::GetTempPath()) ('ai-agent-dotfiles-tests-' + [guid]::NewGuid().ToString('N') + '.json')
pwsh -NoProfile -File .\scripts\run-tests.ps1 -RepoRoot $repoRoot -All -JsonSummaryPath $summaryPath
```

检查依赖缺失或测试失败时保留失败事实，按脚本提示与项目约定处理；不能把跳过、未运行或历史
成功写成当前通过。涉及 skill/config 等受管理范围时，再按 `AGENTS.md` 加上它要求的构建、
扫描和预览检查，不将本页当作该流程的替代品。

## 留下可接续的最小事实

复用既有提交、检查结果和状态记录，不为 ZCode 新建一套必填表单或额外任务账本。
仓库整体状态变化时原地更新 `STATUS.md`；局部任务沿用 `status/active/`，已完成记录按
现有约定归入 [`status/archived/`](../status/archived/)。不要为了记录一次普通任务而复制
整份项目状态，也不在本页持续追加执行日志。

在适用的现有记录或交付说明中，简要写明任务与改动、关联提交、验证命令及实际结果、剩余问题
和下一步。能够核实的模型/配置、重试返工、人工介入、耗时和费用可一并记录；没有可靠来源的
模型、费用、人时或缺陷情况写 `unknown`，不可用零替代，也不根据助手自述猜测模型身份。
这些是评估事实的提示，不要求为补齐字段额外采集或推算数据。

只保留脱敏摘要与必要的代码/提交引用，不保存原始会话、凭据、账户信息、本机绝对路径或
未经清理的运行日志；不新增自动采集、后台监控或付费调用。

## 可复制的首次接手提示词

```text
请在 ai-agent-dotfiles 项目根目录接手。先读取 AGENTS.md、STATUS.md 和 docs/ZCODE.md，
核对当前分支、工作区改动，并只读取与本次工作相关的现有任务记录。

本次工作项：尚未指定，请先只读报告当前状态、未完成事项及建议的下一步，不修改文件或推进任务。

等我给出具体工作项后，在授权范围内连续完成实现、必要验证、复核和小步提交，保留无关改动。
沿用我的模型与主会话选择，遵守产品权限及现有独立审查要求。不要因本次接手启动后续阶段、
重启已完成阶段、解除 production interlock、部署 live skills 或修改全局配置。
收尾复用现有状态记录，记录实际验证与限制；无法核实的数据写 unknown，不收集原始会话。
```

需要直接开始真实工作时，将提示词中的“本次工作项”替换为具体目标和验收条件；无需再增加
`harness` 触发词。
