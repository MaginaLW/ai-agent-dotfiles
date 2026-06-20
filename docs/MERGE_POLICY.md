# Skills Import and Merge Policy

本文定义 Claude Code、Codex 和仓库已支持的其它 skill 目标在多电脑场景下的导入、去重、合并、隔离、canonical 选择和删除规则。它是 agent 与自动化脚本的规范性决策依据；若脚本行为比本文更宽松，agent **必须**采用本文的更保守规则并输出冲突报告。

## 规范用语

- **MUST / 必须**：不可省略的要求；不满足即停止当前操作。
- **MUST NOT / 禁止**：任何自动或人工流程都不得执行。
- **SHOULD / 应当**：默认执行；只有记录了明确理由时才可偏离。
- **MAY / 可以**：满足前置条件后允许执行，但不是必需步骤。

## 1. 术语定义

| 术语 | 规范定义 |
|---|---|
| **live skills** | 当前机器上被 Claude Code、Codex 或其它目标工具实际加载的 runtime skill 目录，例如 `~/.claude/skills`、`~/.codex/skills`、fallback `~/.agents/skills`。它们是部署目标，不是仓库真相来源。 |
| **imports / skills inbox** | `imports/skills-inbox/<computername>/` 下按机器和工具暂存的原始导入副本。内容在扫描、分类、去重和合并前均视为不可信候选。 |
| **skills-source** | `skills-source/shared/`、`claude-only/`、`codex-only/`、`openclaw-only/` 的集合，是唯一允许手工维护和提交的 canonical source。 |
| **generated output** | 由 `scripts/build-skills.ps1` 从 `skills-source/` 生成的 `claude/skills/`、`codex/skills/`、`openclaw/skills/`。它们是可重建、Git-ignored 的派生物。 |
| **canonical version** | 某个规范化 skill 名称当前被接受的权威文件树。canonical 必须位于 `skills-source/`，通过 secret scan，并具有明确的平台归属。 |
| **quarantine** | `imports/skills-quarantine/` 下的隔离区，用于保存不能安全自动采用的候选及其原因。隔离不是删除，也不是 canonical 候选的自动批准。 |
| **unknown skill** | 存在于 live skills，但不在当前 generated output 且不在对应 managed manifest 中的目录。unknown 只报告和保留，不自动删除。 |
| **`.system`** | Codex 平台管理的内置 skill 目录。它不属于 repo-managed skills，不进入 canonical、import merge 或 prune 决策。 |
| **manifest-scoped sync** | 只对 per-platform managed manifest 中的名称执行受控 add/update/prune；不对整个 live 根目录做 mirror，也不删除 unknown。 |
| **fingerprint** | skill 文件树的确定性内容指纹。当前实现使用相对路径、文件大小和逐文件 SHA-256 组合得到 `sha256_tree_hash`，并单独记录 `SKILL.md` 的 SHA-256。 |

## 2. 不可违反的总体原则

1. `skills-source/` **必须**是唯一 canonical source。
2. generated output **必须**由构建脚本重新生成，**禁止**直接编辑或作为反向合并源覆盖 `skills-source/`。
3. imports **必须**只作为暂存和审计区，**禁止**直接把 inbox 当作最终 source 或 live 部署源。
4. live skills **必须**被视为目标环境和候选输入；它们 **禁止**强制反向覆盖已有 canonical。
5. Codex `.system` **必须**在 inventory、import、merge、sync 和 prune 中排除，并 **永远禁止**删除、移动、覆盖或改写。
6. 任何会修改 live skills 的 sync **必须**先成功完成 backup；无法确认 backup 路径时 **禁止**继续。
7. 任何 Apply **必须**有同一输入集上的成功 dry-run；dry-run 结果变化后 **必须**重新审阅。
8. secret scan 失败时 **必须**停止 build promotion、merge Apply 和 sync Apply。
9. 自动化 **必须**保留来源、fingerprint、决策和原因；**禁止**静默覆盖或静默丢弃候选。
10. 对本文没有确定性规则的情况，默认结果 **必须**是 `CONFLICT` 或 `QUARANTINE`，不得猜测性覆盖。

## 3. 决策结果状态

每个候选或同名组 **必须**得到以下一个明确结果：

| 状态 | 含义 | 允许的自动动作 |
|---|---|---|
| `DEDUPLICATED` | 候选与 canonical 或同组候选的 tree fingerprint 完全一致。 | 保留一个 canonical/候选引用；其余副本记录为 skipped/duplicate，可归档但不得静默删除原始证据。 |
| `CANONICAL_RETAINED` | 已有 `skills-source` 版本通过 scan，冲突候选不得替换它。 | 保持 canonical 不变；对不同内容生成冲突报告。 |
| `PROMOTE_CANDIDATE` | 没有已有 canonical，且唯一有效候选满足自动晋升全部条件。 | dry-run 可计划晋升；Apply 前仍需报告、scan 和明确模式切换。 |
| `REBUILD_GENERATED` | generated 与 source 不一致。 | 删除并重建 repo 内 generated output；不得把 generated 反向复制到 source。 |
| `CONFLICT` | 同名内容不同，或证据不足以确定安全合并。 | 只生成报告并保持所有输入；禁止覆盖 canonical。 |
| `QUARANTINED` | 候选触发隔离条件。 | 复制/移动候选到 quarantine 的原因目录并记录来源；禁止自动晋升。 |
| `UNKNOWN_REPORTED` | live 中存在 unknown skill。 | 报告并保留 live；可在 backup 后选择性复制到该机器 inbox。 |
| `PRUNE_PLANNED` | 旧 live 项目属于 managed manifest，但已从 generated/source 移除。 | 只进入 dry-run 删除计划；满足删除门禁后才可 Apply。 |

## 4. 同名 skill 决策矩阵

同名比较 **必须**使用规范化名称分组，并收集：来源集合、文件数、总大小、`SKILL.md` fingerprint、tree fingerprint、scan 结果、平台分类、manifest/build 证据和可用的 modified time。

| 条件 | 必须执行的决定 |
|---|---|
| tree fingerprint 完全一致 | 标记 `DEDUPLICATED`。已有 canonical 时保留 canonical；没有 canonical 时按第 5 节优先级选择一个来源，且所有相同 fingerprint 的副本必须记录。 |
| `SKILL.md` fingerprint 一致，但文件数量或 tree fingerprint 不同 | 标记 `CONFLICT` 并报告新增、缺失和路径冲突文件。禁止仅因入口文件相同而覆盖整个目录。 |
| 文件数量不同 | 必须生成冲突报告，列出双方相对路径集合、仅一方存在的文件和同路径不同 fingerprint。文件数本身不得决定 canonical。 |
| 同路径文件内容不同 | 必须报告双方 fingerprint。若已有通过 scan 的 `skills-source` canonical，结果为 `CANONICAL_RETAINED`；候选不得覆盖它。 |
| live 版本与 inbox 版本同名且内容不同 | 默认 `CONFLICT`。禁止把任一候选直接覆盖已有 canonical；没有 canonical 时也不得仅根据来源或时间猜测性选择。 |
| generated 与 `skills-source` 同名但内容不同 | `skills-source` 优先，结果为 `REBUILD_GENERATED`。禁止从 generated 回写 source。 |
| 不同工具候选同名，且一个明确为 Claude-only、另一个明确为 Codex-only | 标记平台冲突并 `QUARANTINED`，除非存在经过审查的分名/拆分规则；禁止自动合并为 shared。 |
| 同名组只包含一个有效候选、没有 canonical、scan 通过且平台分类唯一 | 可以标记 `PROMOTE_CANDIDATE`；仍必须先 dry-run、报告目标类型并在 Apply 后重新 build/scan。 |

### Fingerprint、modified time 与 manifest 的解释顺序

1. **Fingerprint 是内容相等性的唯一自动证据。** tree fingerprint 相同才可自动认定完全一致。
2. **Modified time 只能作为调查证据。** 文件复制、解压、Git checkout、时钟漂移和时区差异都会改变时间；modified time **禁止**单独决定 canonical 或覆盖方向。
3. 报告 modified time 时，应当使用 UTC，并注明其来源；无法可靠收集时写 `not-collected`，禁止推断。
4. **Manifest 表示管理归属，不表示内容相等或版本更新。** manifest 中只有名称时，必须结合产生该 manifest 的 source fingerprint 和最近成功 build 证据使用。
5. “最近成功构建”只有在报告能关联 commit、source fingerprint、manifest 和成功 build 结果时才是有效证据；单独的 generated 目录时间戳无效。

## 5. Canonical 选择优先级

选择顺序如下，低优先级候选 **禁止**静默覆盖高优先级候选：

1. 已位于 `skills-source/`、结构有效且通过当前 secret scan 的版本。
2. 有 managed manifest 记录，并能关联最近一次成功构建所使用 source fingerprint 的版本。
3. 来自 live skills、文件完整、排除 `.system`、通过 scan 且平台分类明确的候选。
4. 来自 `imports/skills-inbox/<computername>/`、文件完整并通过 scan 的候选。
5. quarantine 中的内容不在选择序列中，**禁止**自动成为 canonical。

优先级只解决“哪个安全候选可以作为基线”，不授权覆盖内容冲突。自动晋升还 **必须**同时满足：

- 没有现存 canonical。
- 最高优先级层只有一个不同 fingerprint，或该层所有候选 fingerprint 完全一致。
- 所有必要入口文件存在且非空。
- 不含 secret、私钥、机器状态、缓存、VPS/节点配置或未处理的绝对路径。
- 平台分类为 shared、claude-only、codex-only 或 openclaw-only 中唯一明确的一类。
- 没有同路径不同内容、未知二进制或无法解释的大文件。

任何一项不满足时，结果 **必须**为 `CONFLICT` 或 `QUARANTINED`。

## 6. 自动 quarantine 条件

以下任一条件成立时，候选 **必须**自动隔离，并产生稳定 reason code：

| 条件 | Reason code |
|---|---|
| 目录为空 | `empty-directory` |
| 只包含 `.gitkeep`、空 README、占位说明或其它无执行内容的占位文件 | `placeholder-only` |
| 缺少目标工具所需入口文件；当前 Claude/Codex skill 至少需要非空 `SKILL.md` | `missing-entrypoint` |
| 目录本身或主要内容疑似缓存/runtime state，例如 `node_modules`、`__pycache__`、`.cache`、`.venv`、日志、session、SQLite/cache 数据库 | `cache-or-runtime-state` |
| secret scanner 或导入信号发现疑似 key、token、password、credential、私钥或认证材料 | `possible-secret` |
| 含未知二进制、无法解释的大文件或不允许进入 skill source 的安装包 | `binary-or-large-file` |
| 存在未处理的本机绝对路径、设备路径或机器私有配置，且无法安全确定性重写 | `machine-private-path` |
| 文件结构、frontmatter、工具专用特性或目录布局与目标平台不兼容 | `platform-incompatible` |
| 同名候选内容冲突，且 fingerprint、平台证据和 canonical 优先级无法给出确定结果 | `unresolved-name-conflict` |
| Claude-only 与 Codex-only 特征同时出现且无法安全拆分 | `platform-conflict` |

Quarantine 操作 **必须**：

- 保留原 machine id、source tool、原相对路径、fingerprint 和 reason code。
- 不把原始敏感值写入报告；只记录文件、行号和 detector 类型。
- 不自动复制回 live 或 `skills-source/`。
- 在解除隔离前重新 scan、重新 fingerprint，并生成新的决策记录。
- 不提交 quarantine 原始副本；仓库当前策略将 `imports/` 保持为非提交区域。

## 7. Unknown live skills 处理

1. Unknown live skill **禁止**直接删除、覆盖或假定为垃圾。
2. Sync dry-run **必须**将它列入 `Unknown live skills`，包含平台、名称和 live 根目录标识，但不得输出敏感文件内容。
3. 在需要评估时，可以在完成 backup 后将其复制到 `imports/skills-inbox/<computername>/<tool>/`；复制时必须排除 `.system` 和机器状态目录。
4. 进入 inbox 后，必须执行 scan、fingerprint、平台分类、同名比较和 quarantine 检查。
5. 只有满足第 5 节自动晋升条件或经过明确审查后，unknown 候选才可进入 `skills-source/`。
6. Unknown 未被采用时，live 中仍必须保留；sync 的 prune 逻辑不得把它当作 managed stale skill。

## 8. 删除与 prune 策略

- **禁止直接删除 live skills。** 所有删除必须通过 manifest-scoped sync 的受控路径。
- 只有名称曾属于对应 managed manifest、当前不在 generated output，并且目标是 live 根目录的直接 skill 子目录时，才可产生 `PRUNE_PLANNED`。
- 删除前 **必须**成功创建 repo 外 backup，并在报告中记录 backup 标识或路径。
- 删除前 **必须**由 dry-run 明确显示平台、名称和 `-` / prune 数量。
- Dry-run 后 source、manifest、generated、live 或 scan 结果发生变化时，原批准失效，必须重新 dry-run。
- Unknown live skill **禁止**进入 prune 列表。
- Codex `.system` 以及其任何子路径 **永远禁止**进入删除、更新、移动或 prune 列表。
- 禁止对 live 根目录使用 `robocopy /MIR` 或任何 whole-directory mirror。

## 9. Import、build 与 sync 报告要求

每次 import、merge、build 和 sync **应当**生成机器可读记录和人类可读摘要。若当前脚本不支持某字段，agent 必须在摘要中写明 `not-reported-by-current-tool`，不得假装已验证。

### 必须的汇总类别

- `Added`
- `Modified`
- `Removed`
- `Skipped`
- `Conflicts`
- `Quarantined`
- `Unknown live skills`
- `.system preserved`
- `Secrets scan result`

### 每个 skill 决策记录必须包含

- 规范化名称和平台目标。
- operation mode：`dry-run` 或 `apply`。
- machine id、source collection 和 repo-relative source path。
- 文件数、总大小、`SKILL.md` fingerprint 和 tree fingerprint。
- modified time（UTC + 来源）或 `not-collected`。
- manifest/build 证据或 `none`。
- scan 状态；敏感发现只记录位置和 detector，不记录值。
- 决策状态、reason code、选中的 canonical 来源和未采用候选。
- 对文件差异列出 added/removed/modified relative paths。
- backup 结果、unknown 数量、prune 计划和 `.system` preservation 结果。

报告 **禁止**包含 secret 值、私钥正文、VPS 节点内容、完整认证配置或 machine-private cache 内容。

## 10. 多电脑合并策略

1. 每台电脑 **必须**使用独立目录：`imports/skills-inbox/<computername>/`，下分 `claude/`、`codex/` 等工具目录。
2. Machine id 必须稳定、可追踪；同一机器重复导入不得静默覆盖旧 inbox，应先归档或显式创建新的受控批次。
3. 每台电脑的接入和 canonical 变化 **应当**使用单独 commit，建议格式：

   ```text
   onboarding(<computername>): reconcile managed skills
   ```

4. 不同电脑的同名不同 fingerprint **必须**生成 conflict group，列出所有 machine id；禁止按导入顺序“最后写入者胜出”。
5. 多台电脑提供完全相同 fingerprint 时可以自动去重，并保留全部来源记录。
6. 自动合并无法满足本文确定性条件时，必须输出 `CONFLICT`/`QUARANTINED` 报告并保持 canonical 不变，禁止猜测性覆盖。
7. 单台机器的 modified time 不得压过其它机器的 fingerprint、scan 或 canonical 证据。

## 11. Agent 执行算法

Agent 在处理一个 import batch 时 **必须**按以下顺序执行：

1. 确认 Git 工作树符合当前任务预期；未经解释的变更必须先停止。
2. 记录 machine id 和 inbox batch，确保不会覆盖另一个机器或旧批次。
3. 在任何 live 变更前执行 backup；仅 inventory/import 时也应先有可恢复副本。
4. 收集候选并排除 `.system`、cache、runtime state 和非 skill 目录。
5. 对所有候选运行 secret scan；阻断项立即 quarantine。
6. 计算文件数、大小、入口 fingerprint 和 tree fingerprint，并收集平台/路径信号。
7. 按规范化名称分组，先处理 quarantine，再处理完全一致去重，再处理内容冲突。
8. 已有有效 `skills-source` canonical 时默认保留；不同 fingerprint 候选只报告，不覆盖。
9. 没有 canonical 时按第 5 节决定唯一 `PROMOTE_CANDIDATE`；证据不唯一则 conflict/quarantine。
10. 任何 promotion/merge Apply 后重新 build，再重新 scan。
11. 运行 sync dry-run，审阅 add/update/prune/unknown 和 `.system preserved`。
12. 只有 backup、scan、报告和 dry-run 全部满足门禁时才可 Apply。
13. Apply 后重新 scan、检查 Git 状态、记录结果，并使用独立 commit 提交经过审查的 canonical/manifest/docs 变更。

### 允许自动执行的范围

- 完全相同 tree fingerprint 的去重。
- 已有有效 canonical 时保留 canonical。
- generated/source 漂移时重建 generated。
- 确定性触发 quarantine 并生成原因报告。
- Unknown live skill 的报告和保留。
- 唯一、完整、通过 scan、分类明确且无任何同名内容冲突的候选晋升计划。

### 禁止自动执行的范围

- 用 modified time 单独选择版本。
- 用 quality score 单独覆盖不同 fingerprint。
- 把 generated 或 live 整树反向覆盖 `skills-source/`。
- 合并同路径不同内容而不生成 conflict。
- 删除 unknown 或 `.system`。
- 在 scan、backup 或 dry-run 失败后继续 Apply。

## 12. 当前脚本能力与政策差距

当前脚本已经提供 tree SHA-256、`SKILL.md` SHA-256、文件数、大小、平台信号、secret/binary/path 信号、quality score、分析报告、dry-run、manifest-scoped prune、unknown 报告和 `.system` 保护。

以下限制 **必须**被 agent 明确处理：

- 当前 `Get-SkillRecord` 不记录 modified time；报告必须写 `not-collected`，不得虚构时间证据。
- Managed manifest 当前主要记录名称；它不能单独证明某个内容 fingerprint 是最近成功版本。
- 当前 auto-merge 在没有 existing source 时可能按 quality score 选择候选。若同名候选 fingerprint 不同，本文要求优先输出 `CONFLICT`，不得仅凭 quality score Apply。
- 当前自动 quarantine 已覆盖 missing `SKILL.md`、possible secret、binary/large file 和平台冲突，但 placeholder-only、cache/runtime state、机器私有路径及所有 unresolved-name-conflict 仍必须由 agent 补充检查。
- 当前工具未输出本文所有统一报告字段时，agent 必须指出缺项；不得把“没有字段”解释为“没有风险”。

在脚本完全实现本文前，任何超出现有确定性检查的 merge Apply 都必须保持 dry-run/report-only。

## 13. 安全边界

- 禁止提交 API key、access token、password、cookie、credential 或认证状态。
- 禁止提交 SSH 私钥、其它私钥或 `.ssh` 内容。
- 禁止提交 VPS 节点配置、代理/订阅数据、设备身份、approval state 或 session 数据。
- 禁止提交 Claude、Anthropic、OpenAI、GitHub 或其它服务 token。
- 禁止提交本机绝对路径缓存、日志、数据库、npm installs、launchers、runtime history 或 workspace memory。
- 禁止提交 backup；当前仓库策略要求 backup 位于 repo 外。只有经过明确政策变更和人工审查后才能改变此规则。
- 禁止提交 generated output、imports 原始副本、quarantine 原件或 live home 文件。
- 禁止削弱、绕过或未经批准 whitelist `scripts/scan-secrets.ps1`。
- 报告必须使用 metadata 描述敏感发现，禁止复制敏感值本身。

## 14. 最低完成标准

一个 import/merge/sync 批次只有同时满足以下条件，才可标记完成：

- 每个候选都有来源、fingerprint、scan 状态和确定性决策。
- 所有同名不同内容都有 conflict 或 quarantine 记录，没有静默覆盖。
- Canonical 只存在于 `skills-source/`，generated 可由它重建。
- Unknown live skills 被报告且未删除。
- 所有 prune 都是 manifest-scoped、已 backup、已 dry-run。
- `.system preserved` 明确为成功；任何不确定结果都阻断完成。
- Secrets scan 通过且报告不含敏感值。
- 多电脑来源可追踪，并使用独立、经过审查的 commit 记录 canonical 变化。
