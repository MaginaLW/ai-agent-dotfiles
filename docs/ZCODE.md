# 在 ZCode 中维护本仓库

从仓库根目录新建任务。ZCode 依次读取 `~/.zcode/AGENTS.md` 和当前工作区根目录的 `AGENTS.md`，不会递归合并子目录规则或展开导入。将项目必须遵守的规则留在根文件，修改后用新任务验证加载。[官方规则](https://zcode.z.ai/en/docs/agents)

| 维护对象 | 本仓入口 | 如何验证 |
|---|---|---|
| 全局规则 | 编辑 [zcode/AGENTS.md](../zcode/AGENTS.md)，运行 `pwsh -NoProfile -File scripts/config-pull.ps1 -Platform ZCode` 预览受管块 | 获准同步后查配置状态，保留块外个人内容 |
| 技能 | 修改 `skills-source/`，构建 `zcode/skills/`，再将环境选中的技能部署到 `~/.zcode/skills` | 在新任务用 `$技能名` 指定技能，给出符合其触发条件的任务并检查结果 |
| MCP | 修改 [受管服务注册表](../harness-source/mcp/servers.psd1)，用 `pwsh -NoProfile -File scripts/agent-dotfiles.ps1 mcp status` 查看配置 | 要确认可用性，在 ZCode 中发现该工具并执行已授权的只读调用 |

ZCode 按名称和简短描述发现技能，因此触发场景应写在描述开头。已启用的插件还可能提供 hooks 和 MCP。原生 `~/.zcode/cli/config.json` 的 `mcp.servers` 已有服务时，ZCode 会跳过同一作用域的兼容 MCP 文件。[技能](https://zcode.z.ai/en/docs/skill) · [插件](https://zcode.z.ai/en/docs/plugin) · [MCP](https://zcode.z.ai/en/docs/mcp-services)

按[项目规则](../AGENTS.md)审查部署预览。第 10 条覆盖符合条件的 `work` 技能更新。全局配置和 MCP Apply 各需覆盖其具体范围的授权。

## harness-model 反馈闭环（已暂停）

该试点于 2026-10-10 暂停，恢复需所有者重新登记。[历史记录](HISTORY.md)
