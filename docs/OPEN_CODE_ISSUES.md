# 五项代码问题与修复验证

以下五项已修复，并在隔离测试目录中逐项通过回归。问题描述和验收条件保留自 2026-11-21 对 `main` 提交 `ee2fe15` 的盘点。

| 项目 | 修复提交 | 已验证的结果 |
|---|---|---|
| 1 · 插件升级 | `5c1126a` | 原生卸载模拟失败后，状态查询和预览均报告未决尝试。再次 Apply 被阻止，卸载和安装调用计数不变，首次标记与备份可读。[插件回归](../tests/antigravity-plugins.tests.ps1#L326) |
| 2 · 并发保存 | `019d63e` | 扫描期间保存个人段落或创建同名文件，旧计划均退出并保留所保存的内容。无并发编辑时，正常更新保留受管块外的段落。[配置回归](../tests/config-sync.tests.ps1#L280) |
| 3 · MCP 诊断 | `3e952dc` | MCP 状态 JSON、JSON 文件和统一状态 JSON 均定位到环境变量和请求头的漂移字段。每份报告均得到两项 `update`、一项 `unchanged`，且不含四个虚构配置值。[CLI 回归](../tests/agent-dotfiles.tests.ps1#L318) |
| 4 · 技能归属 | `c167673`、`3ed5b04` | 取消选择后，未登记的同内容手工技能显示 `unknown` 并保留，部署器安装的对照技能显示 `prune` 并被清理。旧版状态缺少来源信息，已登记目录沿用原记录。[部署回归](../tests/deploy-skills.tests.ps1#L174) |
| 5 · 备份边界 | `1d538f7` | pull 和 push 均拒绝仓库根、相对和绝对子目录，以及通过目录联接指回仓库的路径。拒绝发生在备份、暂存和写入前。使用仓库外同级目录的备份与回滚用例通过。[路径回归](../tests/config-sync.tests.ps1#L355) |

## 1. 高优先级 · 插件升级失败后仍可再次卸载

Antigravity 升级时，如果原生卸载失败、旧版仍完整注册且文件匹配收据，下一次规划会先返回 `update`，跳过对 `pending-install.json` 的检查。再次 Apply 会覆盖该标记指向的尝试记录，并再次调用卸载。第一次尝试的备份仍在。[升级规划](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/scripts/antigravity-plugins.ps1#L489) · [标记写入](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/scripts/antigravity-plugins.ps1#L640)

**修复验收。** 延续现有卸载失败用例，再走一次状态查询、预览和模拟 Apply。预期报告未决尝试，标记仍指向首次尝试，原备份可读，模拟卸载和安装的调用次数均保持不变。[插件测试](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/tests/antigravity-plugins.tests.ps1#L327)

## 2. 高优先级 · 配置同步可能覆盖同时保存的个人内容

`config pull -Apply` 在秘密扫描前读取目标文件，将合并后的整份 `AGENTS.md` 放入计划。扫描后写入时仍使用该快照，期间保存的个人段落可能被覆盖。如果规划为新增、期间却出现了同名文件，该文件还会错过覆盖前备份。[合并快照](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/scripts/config-pull.ps1#L75) · [备份选择](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/scripts/config-pull.ps1#L114) · [写入](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/scripts/config-pull.ps1#L131)

**修复验收。** 在临时 home 中，把一次个人段落编辑和一次同名文件创建分别安排在规划之后、写入之前。旧计划不能覆盖这两份新内容。目标无变化时，正常更新仍应替换受管块并保留个人段落。[配置同步测试](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/tests/config-sync.tests.ps1#L221)

## 3. 高优先级 · MCP 的 JSON 诊断可能包含私有字段值

受管条目出现漂移时，计划的 `Before` 可包含本机环境变量或请求头的原值。`mcp status -Json`、`-JsonPath` 和统一 `status -Json` 都会序列化报告。用户分享报告时可能一并分享这些值。定位漂移只需要平台、条目、动作和变更字段路径。[漂移条目](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/scripts/mcp-sync.ps1#L877) · [JSON 输出](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/scripts/mcp-sync.ps1#L1290) · [统一状态](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/scripts/agent-dotfiles.ps1#L440)

**修复验收。** 在隔离条目中给环境变量和请求头填入可检索的虚构值。解析上述三种输出，确认仍能定位漂移字段，且整份输出均不含虚构原值。相同条目与漂移条目仍应分别判为 `unchanged` 和 `update`。[MCP 测试](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/tests/mcp-sync.tests.ps1) · [统一 CLI 测试](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/tests/agent-dotfiles.tests.ps1)

## 4. 中优先级 · 手工安装的同内容技能可能被后续部署清理

此前未登记的手工目录若与选中的技能内容一致，预览显示 `unchanged`。Apply 会将全部选中名称写入部署状态。切换到不含该技能的环境后，该手工目录就可能被列为 `prune`。[内容判定](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/scripts/deploy-skills.ps1#L130) · [可清理目录](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/scripts/deploy-skills.ps1#L143) · [状态写入](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/scripts/deploy-skills.ps1#L218)

**修复验收。** 在无部署记录的临时 live 根预置一个同内容技能，再部署包含它的环境并切换到不含它的环境。手工目录应保留，预览应报告 `unknown`。同一用例中由部署器实际安装的对照目录仍应按原规则清理。[技能部署测试](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/tests/deploy-skills.tests.ps1)

## 5. 中优先级 · 配置备份目录可以落入仓库

`config pull` 要求 `-BackupRoot` 位于仓库外，但创建备份前没有验证解析后的路径。若参数指向仓库内，完整旧 home 配置可能在秘密扫描结束后被复制进工作区。`config push` 的暂存目录有同一边界问题，它保存的是被覆盖前的仓库文件。[pull 备份](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/scripts/config-pull.ps1#L113) · [push 暂存](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/scripts/config-push.ps1#L146)

**修复验收。** 对 pull 和 push 分别传入仓库根本身，以及指向仓库子目录的相对和绝对路径。预期在创建备份、暂存或修改目标前拒绝。使用仓库外的同级目录时，正常备份和回滚仍通过。[配置备份与回滚测试](https://github.com/MaginaLW/ai-agent-dotfiles/blob/ee2fe15b8300dcfc376aaa51ab5860826cb65ccb/tests/config-sync.tests.ps1#L298)
