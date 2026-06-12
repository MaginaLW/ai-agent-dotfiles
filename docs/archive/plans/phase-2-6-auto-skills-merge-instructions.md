# Phase 2.6-auto：Skills 自动收集、查重、分类、整合

> 直接交给 Codex 执行的阶段性指令。
> 项目目录：`C:\Repos\ai-agent-dotfiles`
> 当前目标：在进入真实 sync 阶段之前，实现多电脑 Claude Code / Codex skills 的自动收集、自动查重、自动分类与自动整合流程。
> 本阶段只使用 fake home 测试，不写入真实 `~/.claude`、`~/.codex`、`~/.agents/skills`。

---

## 0. 当前背景

现在继续处理：

```text
C:\Repos\ai-agent-dotfiles
```

该项目用于同步 Claude Code 与 Codex 的全局配置、prompts、commands、agents、skills 等内容。

当前阶段：

```text
phase 1 / phase 2 已完成
phase 3 真实同步尚未开始
GitHub 私有仓库尚未创建或尚未接入远程同步
真实 HOME 目录尚未写入
```

现在新增阶段：

```text
phase 2.6-auto：skills 自动收集、查重、分类、整合
```

---

## 1. 本阶段目标

我有多台电脑，每台电脑上可能已有 Claude Code / Codex skills。

我希望这个项目后续能够：

1. 自动收集各电脑已有 skills。
2. 自动识别重复 skills。
3. 自动判断 skill 应归入：
   - `shared`
   - `claude-only`
   - `codex-only`
4. 自动合并重复或相似 skills。
5. 自动生成最终统一的 `skills-source/`。
6. 自动隔离疑似有风险的 skill。
7. 不需要我人工逐个挑选、逐个 promote。
8. 人工只需要查看最终报告和 quarantine 数量。

---

## 2. 总原则

必须遵守以下原则：

1. 自动整合，而不是只生成报告等待人工挑选。
2. `skills-source/` 是最终统一源。
3. 各电脑导入的原始 skills 先进入 `imports/skills-inbox/`。
4. 自动合并结果写入：
   - `skills-source/shared/`
   - `skills-source/claude-only/`
   - `skills-source/codex-only/`
5. 原始导入内容保留在 inbox，不删除真实电脑上的原始 skills。
6. 不修改真实电脑上的原始 skills。
7. 若发现疑似真实密钥、登录态、私钥、token，相关 skill 不自动合并，放入 quarantine。
8. 若发现本机绝对路径，尽量自动改写为通用路径或变量；无法安全改写时放入 quarantine。
9. 整合后自动运行：
   - `build-skills.ps1`
   - `scan-secrets.ps1`
10. 本阶段不要 commit。
11. 本阶段不要 push。
12. 本阶段不要添加 remote。
13. 本阶段不要执行真实 sync。
14. 本阶段不要写入真实 HOME。

---

## 3. 硬性限制

本阶段禁止：

```text
写入真实 ~/.claude
写入真实 ~/.codex
写入真实 ~/.agents/skills
修改真实 ~/.claude.json
读取或复制 auth.json
读取或复制 .credentials.json
读取或复制 SSH key
读取或复制 Git credential
添加 git remote
git push
执行真实 sync.ps1 pull
执行真实 sync.ps1 push
自动激活 hooks
```

所有测试必须使用：

```text
C:\Repos\ai-agent-dotfiles\tests\fixtures\fake-home
```

除非后续我明确允许，否则不得对真实 HOME 执行 inventory。

---

## 4. 新增目录

请创建或补齐以下目录：

```text
imports/
  skills-inbox/
    README.md
  skills-quarantine/
    README.md
  skills-archive/
    README.md
  skills-reports/
    README.md

docs/
  skills-auto-merge-workflow.md
```

目录用途：

```text
imports/skills-inbox/
  各电脑导入的原始 skills 暂存区。
  默认不入库。

imports/skills-quarantine/
  疑似有风险、无法安全自动合并的 skills。
  默认不入库。

imports/skills-archive/
  被自动判定为重复、已合并或被替代的原始副本。
  默认不入库。

imports/skills-reports/
  自动分析、查重、合并报告。
  可以入库，但报告中不得包含密钥原文。
```

---

## 5. 更新 `.gitignore`

请更新 `.gitignore`，加入以下规则：

```gitignore
# raw imported skills awaiting review
imports/skills-inbox/**
imports/skills-quarantine/**
imports/skills-archive/**

# keep documentation placeholders and generated reports
!imports/skills-inbox/README.md
!imports/skills-quarantine/README.md
!imports/skills-archive/README.md
!imports/skills-reports/
!imports/skills-reports/README.md
```

要求：

1. `imports/skills-inbox/` 原始导入内容默认不入库。
2. `imports/skills-quarantine/` 默认不入库。
3. `imports/skills-archive/` 默认不入库。
4. `imports/skills-reports/` 可以入库。
5. 不得误忽略 `skills-source/`。
6. 继续保持 `claude/skills/` 和 `codex/skills/` 被忽略，因为它们是 build 生成物。

---

## 6. 新增脚本

请实现以下脚本：

```text
scripts/inventory-skills.ps1
scripts/analyze-skills.ps1
scripts/auto-merge-skills.ps1
scripts/normalize-skill.ps1
scripts/dedupe-skills.ps1
```

可以保留或创建以下备用脚本，但本阶段默认不依赖人工 promote：

```text
scripts/promote-skill.ps1
```

所有脚本要求：

1. 仅支持 PowerShell 7+。
2. 脚本开头必须检测 PowerShell 版本。
3. 写文件必须使用 UTF-8 without BOM。
4. 路径使用参数传入，不写死用户名。
5. 支持 `-RepoRoot` 参数。
6. 涉及 HOME 的脚本必须支持 `-HomeRoot` 参数。
7. 默认不写入真实 HOME。
8. 任何 destructive 操作必须支持 `-DryRun` 或显式确认。

---

# 7. `inventory-skills.ps1`

## 7.1 作用

扫描某台电脑已有 Claude Code / Codex skills，并复制到 inbox。

## 7.2 参数

```powershell
-RepoRoot <path>
-HomeRoot <path>
-MachineId <string>
-IncludeClaude
-IncludeCodex
-DryRun
```

## 7.3 扫描来源

Claude Code user skills：

```text
<HomeRoot>\.claude\skills
```

Codex user skills：

```text
<HomeRoot>\.agents\skills
```

## 7.4 输出位置

```text
imports/skills-inbox/<MachineId>/claude/<skill-name>/
imports/skills-inbox/<MachineId>/codex/<skill-name>/
imports/skills-reports/<MachineId>-inventory.json
imports/skills-reports/<MachineId>-inventory.md
```

## 7.5 每个 skill 需要记录的信息

```text
source_tool
machine_id
source_path
skill_dir_name
frontmatter_name
frontmatter_description
has_skill_md
file_count
total_size
sha256_of_skill_md
sha256_tree_hash
possible_platform_specific_features
possible_secret_findings
possible_local_path_findings
```

## 7.6 不得扫描或复制

```text
~/.claude/projects
~/.claude/logs
~/.claude/.credentials.json
~/.codex/auth.json
~/.codex/sessions
~/.codex/log
~/.codex/cache
~/.ssh
.env
```

## 7.7 风险检测

扫描时检测：

### Claude-only 疑似特征

```text
${CLAUDE_SKILL_DIR}
allowed-tools
disable-model-invocation
user-invocable
Claude hooks
output-styles
subagents
```

### Codex-only 疑似特征

```text
agents/openai.yaml
Codex plugin metadata
Codex UI metadata
Codex-specific tool dependencies
```

### 本机路径疑似项

```text
C:\Users\
C:/Users/
%USERPROFILE%
$env:USERPROFILE
/home/
```

### 密钥风险

调用现有：

```text
scripts/scan-secrets.ps1
```

或复用其规则。

报告中不得写密钥原文，只写：

```text
文件名
规则名
风险等级
```

---

# 8. `analyze-skills.ps1`

## 8.1 作用

分析 `imports/skills-inbox/` 和现有 `skills-source/`，为自动合并提供结构化数据。

## 8.2 参数

```powershell
-RepoRoot <path>
```

## 8.3 输出

```text
imports/skills-reports/skills-analysis.json
imports/skills-reports/skills-analysis.md
```

## 8.4 分析维度

```text
1. exact duplicate
   整个 skill tree hash 一致。

2. same skill md
   SKILL.md hash 一致，但附件不同。

3. same name
   frontmatter name 或目录名一致。

4. similar purpose
   description、标题、关键词高度相似。

5. platform-specific
   Claude-only / Codex-only / shared 候选。

6. risk
   疑似密钥、本机路径、未知二进制、大体积文件。

7. quality score
   根据 description 清晰度、结构完整性、references/scripts、平台专用字段等打分。
```

## 8.5 报告要求

报告需要包含：

```text
总 skill 数
Claude 来源 skill 数
Codex 来源 skill 数
当前 skills-source 已托管 skill 数
exact duplicate 分组
same-name duplicate 分组
similar-purpose 分组
suspected shared skills
suspected Claude-only skills
suspected Codex-only skills
suspected risk skills
quality score 排名
recommended merge plan
```

报告不得包含密钥原文。

---

# 9. `normalize-skill.ps1`

## 9.1 作用

把单个 skill 标准化为可合并格式。

## 9.2 参数

```powershell
-RepoRoot <path>
-InputSkillPath <path>
-OutputSkillPath <path>
-TargetType shared|claude-only|codex-only
```

## 9.3 标准化规则

1. 确保存在 `SKILL.md`。
2. 确保 frontmatter 有 `name` 和 `description`。
3. `name` 改为 kebab-case，与目录名一致。
4. `description` 控制在清晰、短、可触发的范围内。
5. 去掉明显重复、空洞、过长的说明。
6. shared skill 不允许保留 Claude-only / Codex-only 字段。
7. Claude-only skill 可以保留 Claude 专用字段。
8. Codex-only skill 可以保留 Codex 专用配置。
9. 本机绝对路径尽量改写为：
   - `$HOME`
   - `${VAR_NAME}`
   - 通用说明
10. 如果无法安全改写，返回 quarantine 状态。
11. 不把真实密钥、token、私钥写入输出。

---

# 10. `auto-merge-skills.ps1`

## 10.1 作用

自动把 inbox 中的 skills 整合进 `skills-source/`。

## 10.2 参数

```powershell
-RepoRoot <path>
-Apply
-DryRun
```

默认使用：

```powershell
-DryRun
```

只有显式使用：

```powershell
-Apply
```

才实际写入 `skills-source/`。

---

## 10.3 自动分类规则

### shared

满足以下条件时归为 shared：

```text
1. 没有 Claude-only 特征。
2. 没有 Codex-only 特征。
3. 没有真实密钥风险。
4. 没有无法改写的本机路径。
5. 内容是通用流程、写作、代码审查、排错、总结、规划等。
```

输出到：

```text
skills-source/shared/<skill-name>/
```

### claude-only

满足以下条件时归为 claude-only：

```text
1. 含 Claude 专用字段或语法。
2. 不含 Codex 专用配置。
3. 没有真实密钥风险。
```

输出到：

```text
skills-source/claude-only/<skill-name>/
```

### codex-only

满足以下条件时归为 codex-only：

```text
1. 含 Codex 专用配置，例如 agents/openai.yaml。
2. 不含 Claude 专用字段。
3. 没有真实密钥风险。
```

输出到：

```text
skills-source/codex-only/<skill-name>/
```

### 同时含 Claude-only 和 Codex-only 特征

如果一个 skill 同时含 Claude 和 Codex 专用内容：

```text
1. 自动拆分成两个 skill。
2. 通用主体尽量抽取为 shared。
3. Claude 专用增强放入 claude-only。
4. Codex 专用增强放入 codex-only。
5. 如果无法可靠拆分，放入 quarantine。
```

### 有风险的 skill

发现以下情况，不自动合并：

```text
真实 API key
真实 token
私钥
登录态
cookie
无法改写的本机绝对路径
未知大体积二进制
可疑执行脚本
```

移动到：

```text
imports/skills-quarantine/<reason>/<machine>/<tool>/<skill-name>/
```

报告中写明原因，但不得写密钥原文。

---

# 11. 自动查重与合并规则

## 11.1 exact duplicate

如果 tree hash 完全一致：

```text
1. 只保留一个 canonical 版本。
2. 优先选择已经在 skills-source 中的版本。
3. 如果都来自 inbox，优先选择 quality score 高的版本。
4. 其他副本归档到 imports/skills-archive/。
```

## 11.2 same SKILL.md，附件不同

如果 `SKILL.md` 完全相同但 references/scripts 不同：

```text
1. 保留同一个 SKILL.md。
2. 合并 supporting files。
3. 若文件名冲突但 hash 不同，重命名为 <original-name>.<machine-id>.<ext>。
4. 在 MERGE_NOTES.md 记录来源。
```

## 11.3 same name / similar purpose

如果 name 相同或用途高度相似：

```text
1. 自动生成一个 canonical skill。
2. canonical SKILL.md 应综合多个版本的优点。
3. description 使用更清晰、更短、更通用的版本。
4. steps 合并去重。
5. output format 合并去重。
6. supporting files 合并。
7. 原始版本归档。
8. 在 MERGE_NOTES.md 记录合并来源和处理摘要。
```

## 11.4 已存在 skills-source 版本

如果目标 skill 已经存在于 `skills-source/`：

```text
1. 不直接覆盖。
2. 自动生成合并后的新版本到：
   imports/skills-reports/merged-preview/<skill-name>/
3. 如果合并风险低，自动替换 skills-source 中的版本，并把旧版本备份到：
   imports/skills-archive/previous-source/<skill-name>/
4. 如果合并风险高，放入 quarantine。
```

低风险定义：

```text
1. 无密钥风险。
2. 无无法改写的本机路径。
3. 目标类型不冲突。
4. 合并后 frontmatter 合法。
5. scan-secrets 通过。
6. build-skills 通过。
```

---

# 12. 输出报告

自动整合后生成：

```text
imports/skills-reports/auto-merge-report.md
imports/skills-reports/auto-merge-report.json
```

报告内容：

```text
1. 扫描到的总 skill 数。
2. 自动合并到 shared 的数量和名称。
3. 自动合并到 claude-only 的数量和名称。
4. 自动合并到 codex-only 的数量和名称。
5. exact duplicate 数量。
6. similar purpose 合并组。
7. 被归档的副本。
8. 被隔离的风险 skill。
9. 自动改写的本机路径。
10. 被跳过的原因。
11. 最终 skills-source 结构。
12. build-skills 结果。
13. scan-secrets 结果。
```

报告中不得包含密钥原文。

---

# 13. fake home 测试

请在 fake home 中构造测试数据：

```text
tests/fixtures/fake-home/.claude/skills/git-review/SKILL.md
tests/fixtures/fake-home/.claude/skills/paper-polish/SKILL.md
tests/fixtures/fake-home/.agents/skills/git-review/SKILL.md
tests/fixtures/fake-home/.agents/skills/codex-repo-maintainer/SKILL.md
tests/fixtures/fake-home/.agents/skills/path-risk/SKILL.md
tests/fixtures/fake-home/.agents/skills/placeholder-ok/SKILL.md
```

测试数据要求：

1. Claude 和 Codex 各放一个 `git-review`，内容相似但不完全相同，用来测试自动合并。
2. `paper-polish` 应被自动归入 shared。
3. `codex-repo-maintainer` 包含 `agents/openai.yaml`，应被自动归入 codex-only。
4. `path-risk` 包含本机用户目录示例路径，测试路径改写；如果可改写则合并，不可改写则隔离。
5. `placeholder-ok` 包含 `${GITHUB_PAT}` 和 `bearer_token_env_var = "GITHUB_PAT"`，不得被误判为真实泄密。
6. 不要放真实 token。

---

# 14. fake home 测试命令

运行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\inventory-skills.ps1 `
  -RepoRoot C:\Repos\ai-agent-dotfiles `
  -HomeRoot C:\Repos\ai-agent-dotfiles\tests\fixtures\fake-home `
  -MachineId fake-pc `
  -IncludeClaude `
  -IncludeCodex

pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\analyze-skills.ps1 `
  -RepoRoot C:\Repos\ai-agent-dotfiles

pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\auto-merge-skills.ps1 `
  -RepoRoot C:\Repos\ai-agent-dotfiles `
  -DryRun

pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\auto-merge-skills.ps1 `
  -RepoRoot C:\Repos\ai-agent-dotfiles `
  -Apply

pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-skills.ps1 `
  -RepoRoot C:\Repos\ai-agent-dotfiles

pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-secrets.ps1 `
  -RepoRoot C:\Repos\ai-agent-dotfiles
```

---

# 15. 测试验收标准

确认：

```text
1. git-review 自动合并成一个 canonical skill。
2. paper-polish 进入 skills-source/shared/。
3. codex-repo-maintainer 进入 skills-source/codex-only/。
4. placeholder-ok 不被误判。
5. path-risk 被自动改写或隔离。
6. 生成 auto-merge-report.md/json。
7. build-skills 成功。
8. scan-secrets 成功。
9. 没有写入真实 ~/.claude、~/.codex、~/.agents/skills。
10. imports/skills-inbox/ 被 gitignore。
11. imports/skills-quarantine/ 被 gitignore。
12. imports/skills-archive/ 被 gitignore。
13. imports/skills-reports/ 可以被 git 跟踪。
```

---

# 16. 多电脑真实收集流程说明

本轮不要执行真实 HOME 收集。

后续每台电脑可以执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\inventory-skills.ps1 `
  -RepoRoot C:\Repos\ai-agent-dotfiles `
  -HomeRoot $HOME `
  -MachineId <computer-name> `
  -IncludeClaude `
  -IncludeCodex
```

然后统一执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\analyze-skills.ps1 `
  -RepoRoot C:\Repos\ai-agent-dotfiles

pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\auto-merge-skills.ps1 `
  -RepoRoot C:\Repos\ai-agent-dotfiles `
  -DryRun

pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\auto-merge-skills.ps1 `
  -RepoRoot C:\Repos\ai-agent-dotfiles `
  -Apply

pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-skills.ps1 `
  -RepoRoot C:\Repos\ai-agent-dotfiles

pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-secrets.ps1 `
  -RepoRoot C:\Repos\ai-agent-dotfiles
```

但本阶段只允许 fake home 测试。

---

# 17. 文档更新

新增：

```text
docs/skills-auto-merge-workflow.md
```

文档说明：

```text
1. 每台电脑 inventory 到 inbox。
2. analyze 生成结构化分析。
3. auto-merge 自动合并低风险 skills。
4. 高风险 skill 自动进入 quarantine。
5. 重复 skill 自动 archive。
6. 最终统一结果进入 skills-source。
7. build-skills 生成 Claude / Codex 分发版本。
8. scan-secrets 通过后才允许后续 commit。
```

强调：

```text
人工不需要逐个挑选 skill。
人工只需要查看最终报告和 quarantine 数量。
低风险重复项和相似项自动整合。
高风险项不会自动进入 skills-source。
```

---

# 18. 本阶段完成后停止

完成后不要：

```text
commit
push
添加 remote
执行真实 sync
写入真实 HOME
```

完成后输出：

```text
1. 新增/修改文件列表。
2. 新增脚本说明。
3. fake home 测试命令和结果。
4. 自动合并进入 shared / claude-only / codex-only 的 skill 名单。
5. quarantine 名单与原因。
6. archive 名单。
7. auto-merge-report 路径。
8. build-skills 结果。
9. scan-secrets 结果。
10. 是否有任何真实 HOME 写入。
11. 当前 git status --short --ignored。
12. 下一步建议。
```

---

## 19. 最终提醒

本阶段的核心目标不是同步，而是建立“自动整合 skills”的能力。

正确顺序是：

```text
收集 -> 分析 -> 自动合并 -> 隔离风险 -> 生成报告 -> build -> scan
```

而不是：

```text
直接把某台电脑的 skills 覆盖到另一台电脑
```

只要没有完成自动整合与安全扫描，就不要进入真实 sync 阶段。
