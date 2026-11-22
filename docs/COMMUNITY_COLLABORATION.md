# Codex 协作入口

| 入口 | 何时用 | 可检查的结果 |
| --- | --- | --- |
| [grill-me](../skills-source/codex-only/grill-me/SKILL.md) | 需求还有分歧，先用原生 Ask 定一个决策 | 实际选择、理由、验收条件 |
| [swarm](../skills-source/codex-only/swarm/SKILL.md) | 同时派工、点名队友、查看共享看板或消息关系图 | 负责人、真实收件回执、提交版本和原始事件 |
| [teamwork](../skills-source/codex-only/teamwork/SKILL.md) | 任务有依赖，或要进行计划、阶段、集成审查 | 当前可执行批次、退回原因、复验证据和里程碑结果 |

在 Codex Desktop 普通聊天输入 `/grill-me`、`/swarm` 或 `/teamwork`，按 Tab 选中对应的 `prompts:名称`，接着输入任务并按回车。刚安装后，旧窗口可能仍显示「无命令」，从「文件 → 新窗口」重新打开同一聊天即可加载新入口。也可以直接输入 `$grill-me`、`$swarm` 或 `$teamwork` 调用同一技能。

在一个项目里先用 Swarm 启动成员，再用 Teamwork 验收时，第二条命令写明沿用同一运行或 manifest。这样任务、成员回复和审查都能在同一看板上追溯。原 `subagent-driven-development` 的派单规则、评审提示词和看板已并入 Swarm。已归档的 `manifest.json` 可用 Swarm 的 `scripts/coordination.py` 打开。

## 四个上游

本机保留四份完整的源码工作目录，位于仓库根目录的 `community-upstreams/`。下表的链接固定到本次采用的提交。该目录由 Git 忽略。在其他机器上复现时，分别克隆下列仓库并检出链接中的提交。

| 上游 | 已接入 Codex 的内容 | 上游原版的运行条件 |
| --- | --- | --- |
| [zetbrush/multiagents](https://github.com/zetbrush/multiagents/tree/6038986b739937aaf3f2da2346e97a25f00369b1) | 共享看板、任务复审和消息记录；可从原版 broker 的 SQLite 快照导入通信 | 原版 broker、MCP 和多种 CLI 驱动使用 Bun，实时推送针对它启动的会话 |
| [vitalysim/herdr-synapse](https://github.com/vitalysim/herdr-synapse/tree/b8a5c5f27ddc4ddb23a4b6ee929ee3adc3bb9f6a) | 定向投递、忙时排队、空闲收件、主动确认与回复串 | 原版终端通知使用 macOS/Linux 的 Herdr 会话 |
| [jlee056/agent-mission-control](https://github.com/jlee056/agent-mission-control/tree/357aec908d609748005cc190f0f64888470d56b1) | 有向通信图、边的次数和事件明细；可导出原版遥测桥接受的事件 | 原版像素办公室、遥测服务和 Web 应用留在完整源码中 |
| [gsd-build/get-shit-done](https://github.com/gsd-build/get-shit-done/tree/bdcaab2c752d9a33a1a1ca9acf3a3c81fb991815) | Grill-me 的提问线索，Teamwork 的依赖批次、目标验证、审查及里程碑交接。Teamwork 通过上游 CLI 读取已有阶段的 `PLAN.md` | 原版完整工作流和 CLI 可在下载目录中独立使用 |

Desktop 里的订阅 worker 由宿主按当前隐私结果派发。消息看板接受同一协议的多个执行端。给独立 worker 分配其工作区内可写的 outbox；只读 worker 通过宿主返回结果。投递是否成功以收件方写回的记录为准。项目决策、Git 发布、部署和账户权限仍由各自的宿主管理。
