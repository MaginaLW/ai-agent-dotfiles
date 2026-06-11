# AI Agent 配置与 Skills 同步方案（v2，已按审查意见修订）

> 审阅对象：Claude Code + Codex 在多台 Windows 电脑之间的配置与 skills 同步方案。
> 目标：使用一个 GitHub 私有仓库同步可复用配置、prompts、commands、agents、skills 等内容；明确排除密钥、登录态、运行历史、缓存、项目级配置和本机专用配置。
>
> **v2 修订摘要**（相对 v1）：
> 1. Secret scan 从"关键词匹配"改为"真实密钥模式匹配 + 占位符放行"，并引入 gitleaks 作为主扫描器，解决 v1 会被自己推荐的 `bearer_token_env_var` / `Bearer ${GITHUB_PAT}` 写法卡死的自相矛盾。
> 2. 明确 skills **单向流动**：skills-source → 生成 → 本机；push 白名单排除一切 skills 目录，新增 drift 检测。
> 3. 生成物（claude/skills、codex/skills）**不入库**，由 pull 时本地生成，消灭一类合并冲突。
> 4. `--prune` 改为基于 manifest 的受控删除，避免误删 Codex `$skill-installer` 等装入的非托管 skills。
> 5. `.gitignore` 移除 `*token*`、`*auth*`、`*secret*` 等过宽通配（会静默忽略正常文件），收窄为具体文件名；宽匹配只保留在扫描脚本里作为提示。
> 6. 明确 `settings.json` 的 `env` 块 / `apiKeyHelper` 为重点扫描对象；本机专用键一律放 `.local` 文件（不同步）。
> 7. MCP 模板补齐"落地"步骤：通过 `claude mcp add --scope user` 注册，禁止整体覆盖 `~/.claude.json`。
> 8. 新增 `setup.ps1`：强制 PowerShell 7+、检查执行策略、安装 pre-commit hook、写入 `.gitattributes`。
> 9. 所有写文件操作强制 `-Encoding utf8NoBOM`；仓库统一 LF，消灭 CRLF 噪音 diff。
> 10. Hooks 改为"pull 后默认不激活，确认后启用"。
> 11. 新增 `VERSIONS.md` 轻量版本记录 + 同步脚本路径存在性检查。
> 12. 补充排除项：Codex 状态库（state db）、volumes/；Claude `ide/`、`downloads/`、`file-history/`、`local/`。
> 13. 日常流程去掉重复的 `git pull`。

---

## 0. 总体目标

使用一个 **GitHub 私有仓库**，在多台 Windows 电脑之间同步：

1. Claude Code 的全局配置、commands、agents、skills、output styles。
2. Codex 的全局配置、prompts、AGENTS.md、skills。
3. 一个统一维护的通用 skills 源目录（唯一人工维护源）。
4. 通过脚本将通用 skills 分发为 Claude Code 和 Codex 各自可用的版本（生成物不入库）。
5. 严格排除所有密钥、登录态、运行历史、缓存、项目级配置和本机专用配置。

最终希望达到：

> 换电脑后，只需要 clone 私有仓库、运行 `setup.ps1` + `sync.ps1 pull`、在本机重新登录 Claude Code/Codex 或配置环境变量，即可恢复主要 AI Agent 工作环境。

---

## 1. 总体原则

### 1.1 使用复制式同步，不使用 symlink

Windows 环境下不使用 symlink，原因：

- 可能需要管理员权限或开发者模式。
- 跨电脑迁移时容易出现路径问题。
- 某些工具、备份软件、杀毒软件对 symlink 处理不稳定。
- 复制式同步更直观、更容易回滚。

同步关系：

```text
仓库 <-> 本机 Home 目录
```

通过 PowerShell 7+ 脚本复制白名单文件。

### 1.2 只做白名单同步

禁止递归复制整个目录：

```text
~/.claude
~/.codex
~/.agents
```

只能复制明确列出的文件和目录。排除清单（第 4 节）仅作为第二道防线和文档说明，不依赖它保证安全。

### 1.3 密钥、登录态、运行时数据绝不进入仓库

即使是私有仓库，也禁止提交：API key、token、`auth.json`、`.credentials.json`、`.env`、SSH key、GitHub PAT、session、cache、logs、history、项目运行记录、本机代理配置、本机绝对路径。

密钥处理采用二选一：

1. 每台机器单独登录 Claude Code / Codex。
2. 每台机器单独配置环境变量，例如 `ANTHROPIC_API_KEY`、`OPENAI_API_KEY`、`GITHUB_PAT`。

### 1.4 Skills 单向流动（v2 强化）

```text
skills-source/  --build-->  本地生成目录（gitignore）  --pull-->  ~/.claude/skills 与 ~/.agents/skills
```

铁律：

1. `skills-source/` 是唯一人工维护源。
2. `claude/skills/`、`codex/skills/` 是 build 生成物，**加入 .gitignore，不提交**。
3. **push 永远不把本机 skills 目录拷回仓库**。本机对已安装 skill 的任何修改都视为漂移（drift）。
4. `sync.ps1 push` 时运行 drift 检测：对比本机已安装的托管 skills 与最新生成结果，发现不一致则警告"请到 skills-source 修改后重新 build"，并列出差异文件。

### 1.5 本机专用配置一律放 `.local` 文件

- Claude Code：本机代理、本机路径、机器专属 `env` 变量放 `~/.claude/settings.local.json` 类的本地文件（`*.local.json` 永不同步）。
- Codex：机器专属内容放 `config.local.toml` 等（`*.local.toml` 永不同步）；被同步的 `config.toml` 保持跨机器通用。

---

## 2. 推荐仓库结构

```text
ai-agent-dotfiles/
  README.md
  VERSIONS.md                  # 轻量记录各机器 Claude Code / Codex CLI 版本（排障用）
  .gitignore
  .gitattributes               # 统一 LF，消灭 CRLF 噪音
  .gitleaks.toml               # gitleaks 配置与 allowlist

  skills-source/
    shared/                    # Claude Code 和 Codex 都能用
      git-review/
        SKILL.md
        references/
        scripts/
      paper-polish/
        SKILL.md
      powershell-safe-edit/
        SKILL.md
    claude-only/               # Claude Code 专用
      claude-output-style-writer/
        SKILL.md
    codex-only/                # Codex 专用（可含 agents/openai.yaml）
      codex-repo-maintainer/
        SKILL.md
        agents/
          openai.yaml

  claude/
    settings.json              # 重点扫描对象（env 块 / apiKeyHelper）
    CLAUDE.md
    commands/
    agents/
    output-styles/
    skills/                    # build 生成物，gitignore，不提交
    mcp/
      claude-user-mcp.template.json
      apply-mcp.ps1            # 通过 claude mcp add --scope user 落地，绝不覆盖 ~/.claude.json

  codex/
    config.toml
    AGENTS.md
    prompts/
    skills/                    # build 生成物，gitignore，不提交

  manifests/
    managed-skills.txt         # 本仓库托管的 skill 名单（--prune 只作用于名单内条目）
    whitelist.psd1             # push/pull 白名单的单一定义（脚本共用）

  scripts/
    setup.ps1                  # 首次初始化：环境检查、hook 安装、.gitattributes
    sync.ps1                   # push / pull / dry-run / prune
    build-skills.ps1
    scan-secrets.ps1           # gitleaks + 自定义补充检查
    backup.ps1
    check-hooks.ps1
    apply-hooks.ps1            # 确认后才激活 hooks

  docs/
    setup-windows.md
    restore.md
    security.md
```

---

## 3. 同步范围

### 3.1 Claude Code 同步范围

本机来源：`%USERPROFILE%\.claude`，仓库目标：`claude/`。

**push 白名单**（本机 → 仓库）：

```text
settings.json        # 同步前重点扫描 env 块、apiKeyHelper、proxy 类键
CLAUDE.md
commands/
agents/
output-styles/
```

**pull 时额外写入本机**（仓库/生成物 → 本机）：

```text
claude/skills/  -> ~/.claude/skills        # 仅 pull 方向，来源是 build 生成物
```

不直接同步 `~/.claude.json`（注意它位于 home 根目录，不在 `.claude` 内）：

- 它混有 user-scope MCP server 配置、项目历史、onboarding 状态等大量本机运行时数据。
- 可能含 token、header、本机路径、端口。
- 如需迁移 MCP，只同步脱敏模板（第 10 节），通过 `apply-mcp.ps1` 落地。

### 3.2 Codex 同步范围

本机来源：`%USERPROFILE%\.codex`，仓库目标：`codex/`。

**push 白名单**：

```text
config.toml          # 不得含明文 token / 本机代理 / 绝对路径；机器专属内容放 *.local.toml
AGENTS.md
prompts/
```

**pull 时额外写入本机**：

```text
codex/skills/  -> ~/.agents/skills         # 仅 pull 方向，来源是 build 生成物
```

> Codex 用户级 skills 的官方位置是 `$HOME/.agents/skills`（仓库级为项目内 `.agents/skills`），不是 `~/.codex/skills`。`~/.codex/config.toml` 中的 `[[skills.config]]` 仅用于启用/禁用某个 skill。

---

## 4. 绝对排除范围（第二道防线，白名单为主）

### 4.1 Claude Code 排除

```text
.credentials.json
projects/
history*
todos/
statsig/
shell-snapshots/
logs/
plugins/repos/
agent-memory/
ide/
downloads/
file-history/
local/                 # CLI 自更新的二进制
*.local.json
```

### 4.2 Codex 排除

```text
auth.json
sessions/
log/
cache/
history.jsonl
*.sqlite* / state db   # agent jobs 等可恢复运行时状态库
volumes/
*.local.toml
```

### 4.3 通用排除

```text
.env
.env.*
*.key
*.pem
*.p12
*.pfx
id_rsa
id_ed25519
.ssh/
backup/
tmp/
*.bak
*.tmp
```

> v2 变更：移除了 `*credential*`、`*secret*`、`*token*`、`*auth*` 这类过宽通配。它们会把 `github-auth-flow`、`token-counter` 之类的正常 skill 静默忽略且无任何提示。宽匹配只在 `scan-secrets.ps1` 中作为"提示级"检查存在（命中后人工确认，而非直接忽略文件）。

---

## 5. `.gitignore` 与 `.gitattributes`

### 5.1 `.gitignore`

```gitignore
# secrets（具体文件名，不用宽通配）
.env
.env.*
*.key
*.pem
*.p12
*.pfx
auth.json
.credentials.json
id_rsa
id_ed25519
.ssh/

# build 生成物（不入库）
claude/skills/
codex/skills/

# Claude runtime / local
claude/**/*.local.json

# Codex runtime / local
codex/**/*.local.toml

# generated / backup / temp
backup/
tmp/
*.bak
*.tmp
```

### 5.2 `.gitattributes`（v2 新增，必须）

```gitattributes
* text=auto eol=lf
*.ps1 text eol=lf
*.md text eol=lf
*.json text eol=lf
*.toml text eol=lf
*.png binary
*.jpg binary
```

理由：两台 Windows 机器之间若不统一换行，会产生大量 CRLF 噪音 diff，淹没真实改动，也干扰 push 前的人工 diff 审查。

> `.gitignore` 只是最后防线，真正可靠的是：白名单复制 + secret scan + git diff 人工确认 + pre-commit hook。

---

## 6. Skills 整理策略

### 6.1 统一源目录

```text
skills-source/shared/       # Claude Code 和 Codex 都能用
skills-source/claude-only/  # Claude Code 专用
skills-source/codex-only/   # Codex 专用
```

### 6.2 shared skills 要求

`shared/` 下的 `SKILL.md` 只使用通用 Markdown 和最小 frontmatter（`name` + `description`）。这是 Claude Code 与 Codex 共同遵循的开放 agent skills 标准的最小集合，双方对未识别字段都会忽略，不会损失调用效果。

```markdown
---
name: git-review
description: Review git changes, summarize modifications, identify risks, and suggest commit messages. Use when asked to inspect diffs, review code changes, or prepare commits.
---

# Git Review

## Purpose
Review current repository changes and produce a concise risk-oriented summary.

## Steps
1. Inspect changed files and diffs.
2. Summarize functional changes.
3. Identify risks, missing tests, hardcoded values, or unsafe behavior.
4. Suggest a commit message if requested.

## Output
- Summary
- Risks
- Suggested tests
- Optional commit message
```

约定：frontmatter 的 `name` 与目录名保持一致，避免两边解析行为差异。

### 6.3 shared skills 禁止内容

不使用 Claude 专用语法：`${CLAUDE_SKILL_DIR}`、`allowed-tools`、`disable-model-invocation`、`user-invocable`、Claude hooks / output-styles / subagents。

不使用 Codex 专用配置：`agents/openai.yaml`、Codex plugin/UI metadata、Codex-specific tool dependencies。

这些内容放入 `claude-only/`、`codex-only/`，或同一 skill 的平台适配子目录。

### 6.4 skills 生成规则

```powershell
.\scripts\build-skills.ps1
```

执行：

```text
1. 清空 claude/skills/ 与 codex/skills/（仅生成目录，安全）。
2. skills-source/shared/*      -> claude/skills/* 与 codex/skills/*
3. skills-source/claude-only/* -> claude/skills/*
4. skills-source/codex-only/*  -> codex/skills/*
5. 检查命名冲突：同名 skill 同时出现在 shared 与 only 目录时报错退出（不允许静默覆盖）。
6. 重新生成 manifests/managed-skills.txt（全部托管 skill 名单）。
```

先清空再生成，保证生成目录不会残留已删除的旧 skill。

### 6.5 去重原则

去重不按文件名，而按用途和触发场景。`code-review` / `git-review` / `review-diff` 这类本质相同的合并为一个；`paper-polish` / `thesis-summary` / `latex-check` / `reference-format` 这类触发场景不同的不合并。

### 6.6 skills 数量控制

第一批只整理 10–20 个高频 skills。原则：

- description 短而明确，前置关键触发词。
- 不要写太泛（误触发），不要写太长（浪费上下文）。
- 不确定是否通用的，先放 only 目录，不放 shared。

---

## 7. 脚本设计

### 7.1 入口与通用要求

```powershell
.\scripts\setup.ps1                 # 首次初始化
.\scripts\sync.ps1 push [--dry-run]
.\scripts\sync.ps1 pull [--dry-run] [--prune]
```

所有脚本硬性要求：

1. 仅支持 **PowerShell 7+（pwsh）**，脚本开头检测版本，5.1 直接报错退出。原因：Windows PowerShell 5.1 的 `Out-File` 默认编码会写出 UTF-16/BOM，破坏 json/toml。
2. 所有写文件操作显式 `-Encoding utf8NoBOM`。
3. 路径只用 `$HOME` / `$env:USERPROFILE`，不写死用户名。
4. 白名单定义集中在 `manifests/whitelist.psd1`，push/pull/dry-run/backup 共用同一份，避免多处维护漂移。
5. **路径存在性检查**：同步前检查 `~/.claude`、`~/.codex`、`~/.agents/skills` 等目标是否存在；不存在时报错并提示"CLI 版本可能已变更目录约定，请核对官方文档"，而不是静默创建。这是对两个快速迭代的 CLI 最现实的"版本风险"防御。
6. dry-run 用 `robocopy /L` 或 `Compare-Object` 实现，输出将要 复制/覆盖/跳过 的完整清单。

### 7.2 setup.ps1（v2 新增）

```text
1. 检查 pwsh >= 7，否则退出。
2. 检查 git 可用。
3. 检查执行策略；若受限，提示运行：
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
4. 检查/下载 gitleaks（单个 exe），放入 tools/ 或提示用户安装。
5. 安装 git pre-commit hook：强制运行 scan-secrets.ps1，
   保证手动 git commit 也无法绕过扫描。
6. 确认 .gitattributes 存在并已生效（git add --renormalize . 提示）。
7. 写入/更新 VERSIONS.md：记录本机 claude --version 与 codex --version。
8. 输出环境检查报告。
```

### 7.3 push 行为（本机配置 → 仓库）

```text
1. 从本机读取白名单文件（仅第 3 节 push 白名单；不含任何 skills 目录）。
2. 复制到仓库 claude/、codex/。
3. 运行 build-skills.ps1（刷新本地生成物与 managed-skills.txt）。
4. 运行 drift 检测：对比本机已安装托管 skills 与生成物，
   不一致则警告并列出差异，提示到 skills-source 修改。
5. 运行 scan-secrets.ps1（gitleaks + 自定义检查）。
6. 显示 git diff 摘要。
7. 用户确认后 commit。
8. 用户确认后 push 到 GitHub。
```

默认不允许无确认自动 commit。

### 7.4 pull 行为（仓库 → 本机配置）

```text
1. git pull 获取最新仓库。
2. 运行 scan-secrets.ps1（防御他机误提交）。
3. 运行 build-skills.ps1（本地生成 claude/skills、codex/skills）。
4. 备份即将被覆盖的本机文件（第 8 节）。
5. 将 claude/ 白名单内容复制到 ~/.claude。
6. 将 codex/ 白名单内容复制到 ~/.codex。
7. 将生成的 claude/skills/ 复制到 ~/.claude/skills。
8. 将生成的 codex/skills/ 复制到 ~/.agents/skills。
9. 运行 check-hooks.ps1，新增/变更 hooks 默认不激活（第 11 节）。
10. 输出同步报告（复制数 / 跳过数 / 备份位置 / 敏感字段 / git status）。
```

默认只覆盖白名单文件，不删除目标目录中仓库没有的文件。

### 7.5 --prune（基于 manifest 的受控删除，v2 重做）

```powershell
.\scripts\sync.ps1 pull --prune
```

规则：

1. prune **只作用于 `manifests/managed-skills.txt` 名单内的条目**。
2. 即：只删除"曾由本仓库托管、但现已从 skills-source 移除"的 skill。
3. 永不触碰名单外的目录 —— `~/.agents/skills` 不是本仓库独占的，Codex 的 `$skill-installer` 和其他工具也会往里装东西，不能整目录对齐删除。
4. 删除前列出清单并要求确认。

---

## 8. 备份规则

每次 `pull` 前必须备份将被覆盖的文件。

```text
backup/YYYYMMDD-HHMMSS/
  claude/settings.json
  claude/CLAUDE.md
  codex/config.toml
  agents/skills/git-review/SKILL.md
```

同步完成后输出备份位置；恢复说明写入 `docs/restore.md`。`backup/` 已 gitignore。

---

## 9. Secret Scan 规则（v2 重做）

### 9.1 主扫描器：gitleaks

`scan-secrets.ps1` 优先调用 gitleaks（单个 exe，Windows 友好），扫描暂存区/工作区。配置写入 `.gitleaks.toml`。

### 9.2 自定义补充检查：匹配真实密钥模式，而非裸关键词

**阻断级**（命中即停止 commit）——匹配真实密钥的形态：

```text
sk-ant-[A-Za-z0-9_-]{20,}          # Anthropic key
sk-(proj-)?[A-Za-z0-9_-]{20,}      # OpenAI key
ghp_[A-Za-z0-9]{36}                # GitHub classic PAT
github_pat_[A-Za-z0-9_]{22,}       # GitHub fine-grained PAT
xox[bpars]-[A-Za-z0-9-]{10,}       # Slack token
-----BEGIN (RSA|OPENSSH|EC) PRIVATE KEY-----
Bearer\s+[A-Za-z0-9._-]{20,}       # 真实 Bearer token（见 9.3 放行规则）
"(api_key|token|secret|password|client_secret|refresh_token|access_token)"\s*[:=]\s*"[^$][^"]{8,}"
                                   # 键值对中带"非占位符"的字面值
高熵字符串（可选，Shannon entropy 阈值）
```

**提示级**（输出警告，人工确认后可继续）——裸关键词：

```text
api_key / apikey / token / secret / password / passwd / credential /
authorization / bearer / cookie / private_key / OPENAI_API_KEY /
ANTHROPIC_API_KEY / GITHUB_TOKEN
```

### 9.3 占位符放行规则（解决 v1 自我卡死问题）

以下形态**明确放行**，不触发阻断：

```text
${VAR_NAME}                        # 模板占位符，如 Bearer ${GITHUB_PAT}
*_env_var = "..."                  # 如 bearer_token_env_var = "GITHUB_PAT"
仅出现环境变量名而无值                # 如 ANTHROPIC_API_KEY（无 = 实值）
行尾带  # scan-ok  注释的行          # 显式人工豁免，diff 中可见
```

> v1 的"发现 token / bearer / authorization 关键词直接停止"会被本方案自己推荐的 MCP 写法（`bearer_token_env_var`、`Bearer ${GITHUB_PAT}`）每次卡死。v2 的原则：**阻断真实密钥的"形"，放行引用密钥的"名"**。

### 9.4 重点检查文件

```text
claude/settings.json     # 特别检查 env 块、apiKeyHelper、proxy 类键
claude/CLAUDE.md
claude/mcp/*.json
codex/config.toml        # 特别检查 model_providers 自定义 base_url + key、代理
codex/AGENTS.md
skills-source/**/*.md
skills-source/**/*.json
skills-source/**/*.toml
skills-source/**/*.ps1
```

CLAUDE.md / AGENTS.md 还需提示检查：个人身份信息、本机绝对路径。

### 9.5 防绕过

`setup.ps1` 安装 git pre-commit hook，强制执行本扫描；不通过 `sync.ps1` 的手动 commit 同样被拦截。

发现疑似敏感信息时输出：

```text
ERROR: Possible secret found.
File: xxx
Pattern: ghp_*
Action: remove it, replace with environment variable, or append "# scan-ok" if false positive.
```

---

## 10. MCP 处理规则

### 10.1 Claude Code MCP（v2 补齐落地步骤）

不直接同步 `~/.claude.json`（含 user-scope MCP、token、header、本机路径及大量运行时状态）。

模板：`claude/mcp/claude-user-mcp.template.json`

```json
{
  "mcpServers": {
    "github": {
      "type": "http",
      "url": "${GITHUB_MCP_URL}",
      "headers": {
        "Authorization": "Bearer ${GITHUB_PAT}"
      }
    }
  }
}
```

**落地方式（二选一，写入 docs/setup-windows.md）：**

- **推荐：`apply-mcp.ps1` 调用 CLI 注册**。脚本读取模板，校验所需环境变量已设置，然后逐个执行 `claude mcp add --scope user ...`，让 Claude Code 自己管理 `~/.claude.json` 的写入。
- 备选：脚本对 `~/.claude.json` 做 **JSON merge**（读入现有文件，仅替换/合并 `mcpServers` 键，写回时 utf8NoBOM）。

**硬性禁止**：任何脚本不得整体覆盖写入 `~/.claude.json` —— 它混有大量其他运行时状态，整体覆盖会破坏登录与项目历史。

每台机器自己提供环境变量：`GITHUB_MCP_URL`、`GITHUB_PAT`。

### 10.2 Codex MCP

写在 `~/.codex/config.toml`，随 config.toml 同步。

允许同步：MCP server 名称、command、args、url、`bearer_token_env_var`、env 变量**名**。

禁止同步：明文 token、明文 Authorization header、本机绝对路径、临时代理地址、本机专用端口（这些放 `*.local.toml`）。

推荐写法：

```toml
[mcp_servers.github]
url = "https://example.com/mcp"
bearer_token_env_var = "GITHUB_PAT"
```

（此写法已被 9.3 的放行规则覆盖，不会触发误报。）

---

## 11. Hooks 处理规则（v2：默认不激活）

注意 hooks 的实际载体：

- Claude Code hooks 定义在 **settings.json 的 `hooks` 键**里（随 settings.json 同步）。
- Codex hooks 定义在 **config.toml 的 hooks 表**里（随 config.toml 同步）。

所以 `check-hooks.ps1` 解析的就是这两个文件。

允许同步的 hook 类型：格式化、检查、只读分析、安全提示、非破坏性脚本。

禁止：自动删除文件、自动 git commit/push、自动安装未知包、自动执行远程脚本、含 token 的命令、写死本机路径的命令。

**v2 流程（先确认后生效）：**

```text
1. pull 时，若检测到新增或变更的 hooks：
   - 不直接写入生效位置；
   - 将 hooks 内容剥离到待确认区（pending-hooks.json / pending-hooks.toml），
     写入本机的 settings.json / config.toml 时暂不包含这些 hooks。
2. check-hooks.ps1 输出全部待确认 hook 命令：

   Pending hooks (NOT active):
   Claude:
   - PreToolUse: powershell -File scripts/check.ps1
   Codex:
   - after_agent_turn: powershell -File scripts/format.ps1

3. 用户逐条确认后，运行 apply-hooks.ps1 激活。
4. 未变更的已确认 hooks 正常保留。
```

---

## 12. GitHub 认证方式

使用 SSH key。每台电脑单独生成自己的 SSH key，不同步 `.ssh/`。

禁止同步：`~/.ssh/`、GitHub token、Git credential manager 缓存。

```powershell
git remote add origin git@github.com:<your-name>/ai-agent-dotfiles.git
```

---

## 13. 第一台电脑初始化流程

```powershell
mkdir ai-agent-dotfiles
cd ai-agent-dotfiles

git init
git branch -M main

# 建立目录结构、放入 .gitignore / .gitattributes / .gitleaks.toml 后：
.\scripts\setup.ps1

.\scripts\sync.ps1 push --dry-run
.\scripts\sync.ps1 push

git remote add origin git@github.com:<your-name>/ai-agent-dotfiles.git
git push -u origin main
```

---

## 14. 第二台电脑落地流程

```powershell
git clone git@github.com:<your-name>/ai-agent-dotfiles.git
cd ai-agent-dotfiles

.\scripts\setup.ps1               # 环境检查 + pre-commit hook

.\scripts\sync.ps1 pull --dry-run # 确认将覆盖哪些文件
.\scripts\sync.ps1 pull
```

然后在本机单独完成：

```text
Claude Code 登录
Codex 登录
ANTHROPIC_API_KEY / OPENAI_API_KEY 环境变量配置
GitHub SSH key 配置
必要 MCP 环境变量配置（GITHUB_MCP_URL、GITHUB_PAT 等）
.\claude\mcp\apply-mcp.ps1        # 注册 user-scope MCP
.\scripts\apply-hooks.ps1         # 逐条确认后激活 hooks
```

---

## 15. 日常使用流程

### 15.1 开始工作前

```powershell
cd ai-agent-dotfiles
.\scripts\sync.ps1 pull           # 内部已含 git pull，不再单独执行
```

### 15.2 修改配置后

```powershell
cd ai-agent-dotfiles
.\scripts\sync.ps1 push --dry-run
.\scripts\sync.ps1 push
```

### 15.3 修改 skills 后

只在 `skills-source/` 中修改，然后：

```powershell
cd ai-agent-dotfiles
.\scripts\build-skills.ps1        # 本地重新生成
.\scripts\sync.ps1 pull           # 把生成物装回本机（skills 只走 pull 方向）
.\scripts\sync.ps1 push --dry-run # 提交的只有 skills-source 的改动
.\scripts\sync.ps1 push
```

> 不要直接修改 `~/.claude/skills` 或 `~/.agents/skills` 里的托管 skill —— push 时 drift 检测会警告，且改动不会进入仓库。

---

## 16. 冲突处理原则

如果两台电脑都改了同一个文件（`claude/settings.json`、`codex/config.toml`、`skills-source/shared/git-review/SKILL.md` 等）：

```text
1. git pull。
2. 查看冲突，手工合并。
3. 运行 scan-secrets.ps1。
4. 运行 build-skills.ps1。
5. 再 push。
```

降低冲突面的根本手段（优于更细的 merge 策略）：

- 易变、本机相关的键一律放 `*.local.json` / `*.local.toml`，让被同步的 settings.json / config.toml 尽量稳定。
- 生成物不入库（v2 已落实），skills 冲突只可能发生在 skills-source 的源文件上，语义清晰、易于手工合并。

---

## 17. 验收标准

### 17.1 Claude Code

确认存在：

```text
~/.claude/settings.json
~/.claude/CLAUDE.md
~/.claude/commands/
~/.claude/agents/
~/.claude/skills/          # 由生成物 pull 而来
~/.claude/output-styles/
```

确认不存在被同步的敏感文件：

```text
~/.claude/.credentials.json   # 本机自有，但绝不在仓库中
仓库内无 projects/ logs/ ide/ file-history/ 等运行时目录
```

### 17.2 Codex

确认存在：

```text
~/.codex/config.toml
~/.codex/AGENTS.md
~/.codex/prompts/
~/.agents/skills/          # 由生成物 pull 而来
```

确认仓库中不存在：`auth.json`、`sessions/`、`log/`、`cache/`、状态库文件。

### 17.3 Git 仓库

```powershell
git status        # 应显示 working tree clean
```

- gitleaks / scan-secrets.ps1 通过：`No obvious secrets found.`
- `git ls-files` 中不出现 `claude/skills/`、`codex/skills/`（生成物未入库）。
- `git ls-files | Select-String -Pattern "auth.json|credentials"` 无结果。

### 17.4 行为验收（v2 新增）

```text
1. 在 codex/config.toml 写入 bearer_token_env_var = "GITHUB_PAT" 后 push：
   应当顺利通过扫描（占位符放行规则生效）。
2. 在任意文件写入一个形如 ghp_ 开头的 36 位假 token 后 commit：
   应当被 pre-commit hook 阻断。
3. 直接修改 ~/.claude/skills 下某托管 skill 后运行 sync.ps1 push：
   应当出现 drift 警告。
4. 从 skills-source 删除一个 skill，build 后 pull --prune：
   仅该 skill 被从本机删除；本机手装的非托管 skill 不受影响。
5. 在仓库的 settings.json 中加入新 hook 后另一台机器 pull：
   hook 处于 pending 状态，apply-hooks.ps1 确认后才生效。
```

---

## 18. 交给 Codex 执行的硬性要求

```text
请按照本方案实现 Windows PowerShell 脚本和仓库结构。要求：

1. 只能使用白名单复制，不允许递归复制整个 ~/.claude、~/.codex、~/.agents。
   白名单集中定义在 manifests/whitelist.psd1，所有脚本共用。
2. pull 前必须备份即将覆盖的目标文件，备份目录格式为 backup/YYYYMMDD-HHMMSS/。
3. pull 默认只覆盖白名单文件，不删除目标目录中仓库没有的文件；
   --prune 只允许删除 manifests/managed-skills.txt 名单内、且已从
   skills-source 移除的 skill，删除前列出清单并要求确认。
4. push 前必须运行 scan-secrets.ps1：优先调用 gitleaks；自定义检查按
   "阻断真实密钥模式（sk-ant-、sk-、ghp_、github_pat_、PRIVATE KEY、
   真实 Bearer token、键值对字面密钥）/ 提示裸关键词 / 放行 ${VAR}、
   *_env_var、# scan-ok"三级规则执行。发现阻断级立即停止。
5. setup.ps1 必须安装 git pre-commit hook 强制执行 secret scan，
   防止绕过 sync.ps1 的手动 commit。
6. push 前必须显示 git diff 摘要，不能无确认自动 commit。
7. 不同步 ~/.ssh、Git credential、GitHub token、Claude 登录态、
   Codex auth.json、Claude .credentials.json、~/.claude.json。
8. MCP：同步脱敏模板 + apply-mcp.ps1；落地用 claude mcp add --scope user
   或对 ~/.claude.json 做 JSON merge；严禁整体覆盖写入 ~/.claude.json。
9. Codex config.toml 可以同步，但不得包含明文 token、Authorization header、
   机器绝对路径或本机专用代理地址；机器专属内容放 *.local.toml（不同步）。
10. hooks 可以同步，但 pull 后新增/变更的 hooks 默认不激活，进入 pending
    状态；check-hooks.ps1 列出全部待确认命令；apply-hooks.ps1 确认后激活。
11. 所有脚本仅支持 PowerShell 7+（开头检测版本，5.1 报错退出）；
    写文件一律 -Encoding utf8NoBOM；路径用 $HOME / $env:USERPROFILE。
12. 仓库必须包含 .gitattributes（统一 LF），setup.ps1 检查其生效。
13. Codex user skills 同步到 $HOME/.agents/skills，不是 ~/.codex/skills。
14. skills-source 是唯一人工维护源；claude/skills 和 codex/skills 是
    build-skills.ps1 的生成物，加入 .gitignore，不提交；skills 只走
    pull 方向（生成物 → 本机），push 白名单不含任何 skills 目录。
15. build-skills.ps1 先清空生成目录再生成；同名 skill 出现在多个源目录
    时报错退出；每次重建 manifests/managed-skills.txt。
16. sync.ps1 push 必须做 drift 检测：本机已安装托管 skills 与生成物
    不一致时警告并列出差异。
17. 同步前检查目标目录（~/.claude、~/.codex、~/.agents/skills）存在性，
    不存在时报错提示 CLI 目录约定可能已变更，不得静默创建。
18. 每次同步完成后输出检查清单：复制文件数、跳过文件数、备份位置、
    是否发现敏感字段、pending hooks 数、当前 git status。
19. setup.ps1 维护 VERSIONS.md：记录本机 claude / codex CLI 版本号
    （仅作排障参考，不强制对齐）。
```

---

## 19. 最终方案定位

这个仓库负责同步：

```text
AI Agent 全局配置（settings.json / config.toml 的跨机器通用部分）
通用 prompts
通用 skills（仅 skills-source 源文件）
Claude Code commands / agents / output-styles
Codex AGENTS.md / prompts
脱敏 MCP 模板 + 落地脚本
经确认的 hooks
```

这个仓库不负责同步：

```text
登录态 / API key / token / SSH key
运行历史 / 项目级配置 / 缓存 / 日志 / 状态库
skills 生成物（本地 build）
插件 bundle / 本机手装的非托管 skills
本机专用代理配置与 *.local.* 文件
```

一句话定位：

> 这是一个用于多电脑同步 Claude Code 与 Codex 工作环境的私有 dotfiles 仓库；它以白名单方式同步可复用配置和 skills 源文件，skills 单向分发、生成物不入库，密钥只以环境变量名的形式被引用，任何真实密钥、登录态、缓存、运行历史和本机专用状态都不进入仓库。
