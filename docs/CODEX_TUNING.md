# Codex 本机权限与命令规则

本仓库用 [codex/AGENTS.md](../codex/AGENTS.md) 分发工作约定。模型、推理档位和本机权限由用户或管理员选择。`config-sync` 不同步整份 `~/.codex/config.toml` 或个人 `.rules` 文件。[配置作用域](https://learn.chatgpt.com/docs/config-file/config-basic)

## 定位一次审批

在 Codex CLI 输入 `/status` 确认当前工作目录和沙箱，再查看审批所列的具体命令、目标路径或网络目的地。工作区写沙箱仍保护 `.git` 等目录，因此能编辑源文件的会话也可能在提交时请求审批。[沙箱与受保护路径](https://learn.chatgpt.com/docs/agent-approvals-security)

沙箱限定可执行范围，`approval_policy` 决定何时可以请求批准。`on-request` 允许按需申请，`never` 关闭申请渠道，原本需要提权的步骤可能失败。按实际任务决定一次性请求；推送、部署和写入本机配置仍按项目的授权范围执行。[审批策略](https://learn.chatgpt.com/docs/agent-approvals-security)

## 检查重复命中的规则

在 PowerShell 中，把实际命令的程序名、子命令和参数分别传给检查器。例如，已有个人规则文件时，可用下面的命令检查一次只读 Git 查询：

```powershell
codex execpolicy check --pretty --rules "$HOME/.codex/rules/default.rules" -- git status --short
```

检查器给出指定规则文件的匹配项及裁决，不执行示例中的 Git 命令。需要保存规则时，先核对前缀还能匹配哪些操作。例如，`pwsh -NoProfile -File` 后面可以跟任意脚本，`git branch` 也包含删除子命令。确认需要长期放行的具体动作后，再用相邻的不同命令检查匹配范围。[命令规则和检查器](https://learn.chatgpt.com/docs/agent-configuration/rules)
