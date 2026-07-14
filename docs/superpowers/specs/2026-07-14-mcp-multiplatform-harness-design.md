# MCP 与多平台 Project Harness 扩展设计

## 目标

在现有“源文件 → disposable staging/generated → dry-run → gated apply”模型上，补齐两条独立能力：

1. Project Harness 能为 Claude、Codex 和 OpenClaw 生成受控的项目级输出。
2. MCP 模板能被验证、审查、注册、更新和移除，但不把凭据或整份用户配置纳入仓库。

本轮不管理 OpenClaw 的 identity、credentials、sessions、cache、plugins 或机器级配置，也不切换全局 home harness。

## Harness 输出契约

每个 component 的 `Kind` 决定允许的输出模式和目标根：

| Kind | Mode | 允许目标 |
|---|---|---|
| `Command` | `DirectoryFiles` | `.claude/commands/` |
| `ClaudeAgent` | `DirectoryFiles` | `.claude/agents/` |
| `CodexPrompt` | `DirectoryFiles` | `.codex/prompts/` |
| `CodexAgent` | `DirectoryFiles` | `.codex/agents/` |
| `OpenClawConfig` | `StructuredMerge` | `.openclaw/project.json` |

上述目录是项目级 allowlist，不是 home 目录。所有 target 都必须是相对路径，禁止 URL、盘符、UNC、`~`、`.`、`..` 和符号链接逃逸。`OpenClawConfig` 只允许有限的项目配置键，绝不接受 credentials、tokens、devices、identity、sessions、cache 或 plugin install 字段。

Build 将这些输出复制到 `.agent-harness/generated/` 供审查；Apply 默认 dry-run，Apply 前为每个将被覆盖的项目文件创建备份，写入失败时按 manifest 逆序恢复。重复执行相同输入必须是 `noop`。

## MCP 模板契约

MCP 模板位于 `harness-source/components/mcp-templates/<id>/`，模板声明只包含：服务器 id、描述、stdio command/args、需要的环境变量名和作用域。命令、参数和模板 id 不得包含 secret 或机器私有路径；环境变量只以 `${NAME}` 占位符出现。

`apply-mcp.ps1` 的计划记录模板 hash、目标服务器、动作和缺失变量名，不记录变量值。Dry-run 只读；Apply 必须绑定同一 `-PlanPath`，并通过 Claude CLI 对单个服务器执行 add/update/remove，禁止整体覆盖 `~/.claude.json`。Apply 的 backup/operation evidence 记录在 repo 外；CLI 部分失败时，报告已完成和未完成动作，并提供可审查的恢复命令/证据。

MCP 不随 `env activate` 自动写入 home。`env build` 可以把所选模板复制到 staging，激活后仍需显式执行 MCP dry-run/apply，这样环境切换不会隐式触发凭据相关操作。

## 验证门

- 每种 Harness 输出类型覆盖成功、空集合、非法路径、重复执行和 apply 失败回滚。
- MCP 覆盖 dry-run、缺失环境变量、值脱敏、模板路径边界、update/remove、plan drift、CLI 失败和部分成功。
- 所有 apply 都要求明确模式、计划绑定和备份/证据；不触碰 Codex `.system`。
- PowerShell 语法检查、项目回归、env 回归、secret scan、JSON Schema、CI 入口和 `git diff --check` 全部通过。
