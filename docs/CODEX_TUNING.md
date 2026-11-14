# Codex 本机调优与减打断指南

> 本文记录**机器私有配置**（`~/.codex/config.toml`、`~/.codex/rules/default.rules`）的推荐设置。按 [AGENTS.md](../AGENTS.md) 规则，这些文件不纳入仓库 `config-sync` 同步范围，需在各自机器按需本地配置并保管。

---

## 1. 为什么只靠 Skill 和 `AGENTS.md` 还不够

- **过度工程与全量测试惯性**：编码模型在 `high` 推理档位下更容易主动推演边缘故障并补写冗余防御与测试；除了保持 `codex/AGENTS.md` 与 `boring-engineering` 的硬性负向约束外，配合 `personality = "pragmatic"` 能减少废话与套路化扩张。
- **频繁原生弹窗的根因（尤其 Windows + PowerShell）**：
  1. `approval_policy = "on-request"` + 空 `default.rules` 时，任何触及受保护路径（如 `.git` 写操作、工作区外目录、联网请求）或被判定不够明确的子命令都会触发审批；
  2. Windows 下命令常被外层 `pwsh`/`powershell -Command` 包装，若命令包含 `&&` 串接、复杂管道或未加引号的逗号参数（如 `gh ... --json a,b,c`），极易导致“点过允许”的命令在下次变体中失配并再次弹窗；
  3. 开启 `approvals_reviewer = "auto_review"` 后，审查模型偏保守，常因“未见明确人类授权”拒绝无害操作并产生额外 token 开销。

---

## 2. 本机 `~/.codex/config.toml` 推荐配置（保留用户既有 `model_reasoning_effort`）

保留你偏好的 `model` 与 `model_reasoning_effort`（不降低默认推理档位），重点收敛交互人格、沙箱可写根与审批策略：

```toml
# 保留你自己的 model 与 model_reasoning_effort 设置
personality = "pragmatic"

# 方案 A（推荐日常本地 Git 仓库使用）：保留工作区写沙箱，但取消工作区内交互弹窗
sandbox_mode = "workspace-write"
approval_policy = "never"

# 方案 B（若需保留敏感操作人工确认）：改用 on-request，并配合下节 default.rules 白名单
# approval_policy = "on-request"
# 若开启 auto_review 仍经常误杀或消耗过高，可注释/移除下面这行，改用确定性 default.rules
# approvals_reviewer = "auto_review"

[sandbox_workspace_write]
# 将高频需要写入的工作区外目录（例如包缓存、私有反馈台账目录）加入可写根
writable_roots = [
    # "${LOCALAPPDATA}/ai-agent-dotfiles.feedback"
]
network_access = false
```

说明：
- `approval_policy = "never"` **不会关闭沙箱**；写入仍受 `sandbox_mode = "workspace-write"` 和 `writable_roots` 约束，越界操作会被沙箱拦截，只是不再把每次常规边界试探都弹成人工确认。
- 在 Windows 上尽量避免将敏感或高权限系统目录加入 `writable_roots`；若某项目长期需要运行重型 Linux 工具链或频繁被 PowerShell 包装规则卡住，可考虑在 WSL2 中运行 Codex。

---

## 3. 本机 `%USERPROFILE%\.codex\rules\default.rules` 白名单模板

若保留 `approval_policy = "on-request"`，不要依赖弹窗里的临时记忆，建议把高频安全命令显式写入 `~/.codex/rules/default.rules`：

```python
# 只读 Git 与仓库检查
prefix_rule(
    pattern = ["git", ["status", "diff", "log", "branch", "rev-parse", "show"]],
    decision = "allow",
    justification = "Allow read-only git inspection"
)

# 常用 PowerShell 脚本执行（与仓库 AGENTS.md 约定一致）
prefix_rule(
    pattern = ["pwsh", "-NoProfile", "-File"],
    decision = "allow",
    justification = "Allow explicit script execution via pwsh -NoProfile -File"
)

# 只读 GitHub CLI 查询
prefix_rule(
    pattern = ["gh", ["pr", "issue", "repo"], ["view", "list", "status"]],
    decision = "allow",
    justification = "Allow read-only GitHub CLI queries"
)

# 强制保留人工确认的高风险动作
prefix_rule(
    pattern = ["git", "push"],
    decision = "prompt",
    justification = "Always confirm before pushing"
)
```

写完后在 PowerShell 用官方检查器验证真实命令是否命中规则：

```powershell
codex execpolicy check --rules "$HOME\.codex\rules\default.rules" -- git status
codex execpolicy check --rules "$HOME\.codex\rules\default.rules" -- pwsh -NoProfile -File scripts/build-skills.ps1
```
