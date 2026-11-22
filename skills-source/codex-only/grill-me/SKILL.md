---
name: grill-me
description: Use when the user asks to be grilled on a decision or design, including "grill me", a decision/design interview, 拷问我 or 决策/设计访谈. Read the known facts first, then settle one decision per turn with one question and wait for the real answer.
---

# Grill Me / 拷问我

- 先读已知事实：优先用当前对话；仅在相关且被允许时读取必要的具体文件，不做宽泛或隐私搜索，也不扩展到无关工作。
- 每轮只选一个未决决策：优先最阻塞后续工作的那个；没有顺序依赖时选影响最大的那个。
- 用陈述句给出一个具体建议和依据（证据或理由）；如有有用的备选，再用一两条陈述句说明取舍。
- 整个回复只提出一次问题、只包含一个问句：直接问是否采纳建议或在有限备选中选哪个；不要用“Decision/问题”标题或换一种说法把同一问题再问一遍。
- 每轮调用当前模式可用的原生 Ask 工具。默认模式用 `request_user_input_async`，计划模式可用 `request_user_input`。卡片只含一个问题，正文不再重复。工具不可用时说明原因；只有用户选择文字访谈才改用文字。
- 卡片给出 2–3 个可点选的选项。推荐项列在首位，名称明确标注「（推荐）」或工具要求的 `(Recommended)`。每项附一句理由或取舍；工具只有字符串字段时，直接把理由写在选项文本里，并保留自由输入。
- 卡片发出后等待用户真实提交；异步工具返回的 `accepted`、界面预选和超时均不能当成答复。桌面端异步 Ask 只在当前回合进行中可答，收到 `accepted` 后保持回合打开，不能发 final（包括「等你选择」这类收尾）；用可被新输入唤醒的等待（如 `clock.sleep`）分段安静等待，等待到期就继续等。只有真实选择或自由输入，或改题、跳过、结束等新指示才推进；下一问承接用户实际提交，包括非推荐项。
- 按用户答复调整后续决策；用户选择跳过或结束即照办，不重复追问已定事项。
- 决策落定或访谈结束时，简要总结已定决策、理由和剩余未知；仅在明确授权范围内继续后续动作。
- 本技能独立使用，不依赖其他技能、包、团队或委派。
