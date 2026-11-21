# Codex 的任务提示、模型选择与本机权限

本仓库用 [codex/AGENTS.md](../codex/AGENTS.md) 分发工作约定。模型、推理档位和本机权限由用户或管理员选择。`config-sync` 不同步整份 `~/.codex/config.toml` 或个人 `.rules` 文件。[配置作用域](https://learn.chatgpt.com/docs/config-file/config-basic)

## 用 GPT-6.2 交代任务

OpenAI 将 Sol 定位于日常编码与写作，例如按评审意见修订补丁；Astra 适合需要跨系统追因或权衡多组证据的工作。用户可在 Codex 的模型选择器或 CLI 的 `/model` 中选择。推理档位按调查深度决定：快速盘点可用 Medium，跨系统追一个原因可用 High，多个原因可能相互作用时可考虑 Extra High。这些是选用示例，仓库不设置默认型号或档位。[6.2 发布说明](https://learn.chatgpt.com/docs/whats-new/gpt-62-astra-sol) · [Codex 提示指南](https://learn.chatgpt.com/guides/prompting-gpt-6-2-astra)

把目标、可用输入和验收结果放在同一条请求里，让模型选择实现步骤。比如，要判断本机 Codex 规则是否需要同步，可以这样写：

> 请从仓库根目录运行 `pwsh -NoProfile -File scripts/config-pull.ps1 -Platform Codex`。这次只预览。告诉我哪个受管文件待更新，或是否已经一致；如果读不到本机文件，指出缺少的依据。

视觉任务可给一张参考图和实际展示尺寸，要求渲染后在该尺寸核对，交互交付再试用指定操作。并行调查则写明哪些问题能分别验证，最后由主代理对照同一个验收目标整合结果。[Codex 提示指南](https://learn.chatgpt.com/guides/prompting-gpt-6-2-astra)

如果文件缺失或工具调用受阻，结论中应写明它影响了哪项判断。OpenAI 在 6.2 发布评估中记录了漏报阻塞的情况；报告实际读到的证据，让读者能区分已验证和待确认的结果。[发布评估](https://openai.com/index/introducing-gpt-6-2-astra-sol/#alignment)

## 定位一次审批

在 Codex CLI 输入 `/status` 确认当前工作目录和沙箱，再查看审批所列的具体命令、目标路径或网络目的地。工作区写沙箱仍保护 `.git` 等目录，因此能编辑源文件的会话也可能在提交时请求审批。[沙箱与受保护路径](https://learn.chatgpt.com/docs/agent-approvals-security)

沙箱限定可执行范围，`approval_policy` 决定何时可以请求批准。`on-request` 允许按需申请，`never` 关闭申请渠道，原本需要提权的步骤可能失败。按实际任务决定一次性请求；推送、部署和写入本机配置仍按项目的授权范围执行。[审批策略](https://learn.chatgpt.com/docs/agent-approvals-security)

## 检查重复命中的规则

在 PowerShell 中，把实际命令的程序名、子命令和参数分别传给检查器。例如，已有个人规则文件时，可用下面的命令检查一次只读 Git 查询：

```powershell
codex execpolicy check --pretty --rules "$HOME/.codex/rules/default.rules" -- git status --short
```

检查器给出指定规则文件的匹配项及裁决，不执行示例中的 Git 命令。需要保存规则时，先核对前缀还能匹配哪些操作。例如，`pwsh -NoProfile -File` 后面可以跟任意脚本，`git branch` 也包含删除子命令。确认需要长期放行的具体动作后，再用相邻的不同命令检查匹配范围。[命令规则和检查器](https://learn.chatgpt.com/docs/agent-configuration/rules)

## 子代理历史继承（Multi-Agent V2）

在 Codex Multi-Agent V2 中，`spawn_agent` 省略 `fork_turns` 时默认继承完整父对话历史（`"all"`）。[codex/AGENTS.md](../codex/AGENTS.md) 与 `subagent-driven-development` 技能约定默认显式传 `fork_turns: "none"` 并提供自包含交接包，仅在强依赖未落盘的长对话推导或父上下文仍短时使用 `"all"`。

因为 `config.toml` 属于本机私有配置且不纳入 `config-sync`，可在 `~/.codex/config.toml` 中追加以下可选片段，将提醒直接附加到 `spawn_agent` 工具描述末尾（不覆盖内置多代理指令，也不改变 `multi_agent_v2` 的默认启用状态；不要设置会替换内置指令的 `root_agent_usage_hint_text` 或 `subagent_usage_hint_text`）：

```toml
[features.multi_agent_v2]
usage_hint_text = "Default to `fork_turns=\"none\"` with a concise, self-contained handoff (goal, non-goals, confirmed decisions/invariants/ruled-out paths, exact file/command pointers, acceptance criteria; tell the child to reply NEEDS_CONTEXT if critical context is missing). Use `fork_turns=\"all\"` only when the subtask tightly depends on extensive unpersisted parent discussion or the parent context is still small."
```

修改 `config.toml` 后重启 Codex 桌面版或开启新会话生效；可用 `codex exec --strict-config`（只读测试）确认字段被当前客户端严格接受。
