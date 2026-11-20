# 三端统一扩展方案（MCP、第三方插件与跨端多模态接入）

日期：2026-11-15。
状态：**已立项并完成轨道 A → B → C 源码合并：轨道 A（`multimodal-generation` PR #19 `112f418`）、轨道 B（`ExternalPlugins` PR #23 `faeece9`）、轨道 C 规则修订（PR #24 `c9e71dc`）与 `mcp-sync` 实现（PR #25 `7a63a13`）均已并入 `main`；当前仅余 Antigravity 端 `blender` `/args` 实机对齐与 T3 端到端实测验收。**

## 1. 背景与目标

结合在下游项目（如 Unity + Blender 游戏开发）中的实际需求，后续需要在 **Antigravity、Codex、ZCode** 三个客户端之间共享以下扩展能力，而非只配置在单一客户端内：

1. **受管 MCP Servers 跨端分发**：例如 `mcp-for-blender`（原 `blender-mcp`，通过 `uvx mcp-for-blender` 运行）以及后续可能引入的 Unity / 媒体类 MCP Server。
2. **Antigravity 第三方插件期望清单托管**：例如 `antigravity-plugins-official/plugin/gemini-api`、`antigravity-plugins-partners/plugin/unity` 等 Marketplace 插件。
3. **跨三端一致的多模态调用规范**：将“图像、视频、音频/音乐”的调用方法与约束封装成 `skills-source/shared/` 下的共享 Skill，使三端在自然语言指令下执行同一套规则与落盘约定。

## 2. 相对当前基线的边界变化

按当前仓库状态（[README](../README.md)、[手册 §15](README.md#15-antigravity-插件)、[plugins.psd1](../harness-source/antigravity/plugins.psd1)），现有边界明确为：

- 不注册、不同步 MCP Servers；
- 不同步 Codex `config.toml`、私有 `.env` 或凭据；
- `harness-source/antigravity/plugins.psd1` 的 `ExternalPlugins = @()` 为空，第三方插件仅做只读报告，不打包 `mcpServers` 也不自动安装第三方插件；
- Antigravity 插件的更新/回滚合同仍保持阻塞。

若实施本方案（路径 B），需在后续正式立项任务中**显式放开并受控重构以下三点**（仍保留现有 `work` 技能部署授权的严格边界，新范围不得沿用旧 standing grant）：

1. **MCP 分段受管同步**：只同步受管清单声明的 MCP Server 区块，严禁整文件覆盖 `config.toml` 或个人全局配置。
2. **第三方插件声明式校验与安装**：利用 `ExternalPlugins` 声明期望目录 ID，在明确授权下通过官方 `agy plugin` 命令安装缺失项，不手写原生注册文件。
3. **凭据零入库原则维持不变**：所有 API Key / Token 只通过环境变量占位符（如 `${GEMINI_API_KEY}`）引用，由本机用户环境提供，继续受 `gitleaks` 扫描门禁约束。

## 3. 拟定架构设计（草案）

### 3.1 单一声明源（已落地）

1. **MCP 定义源（`harness-source/mcp/servers.psd1`）**
   - 统一声明受管 MCP Server（当前声明 `blender`），记录 `Name`、`Transport`（`stdio` / `streamable-http`）、`Command`、`Args`、`Env`（仅键名或 `${ENV_VAR}` 占位符，不含明文凭据）、`Enabled` 及适用平台（`Antigravity` / `Codex` / `ZCode`）。
2. **Antigravity 第三方清单（`harness-source/antigravity/plugins.psd1`）**
   - 保留 `ManagedPlugin` 承载本项目自维护插件 `ai-agent-dotfiles`（当前 `0.4.0`）；
   - 通过 `ExternalPlugins` 声明第三方条目（当前为 `unity@antigravity-plugins-partners`）。
3. **共享多模态 Skill（`skills-source/shared/multimodal-generation/`）**
   - 统一描述三端共同遵守的订阅额度优先、落盘规范、落盘校验及敏感凭据约束。

### 3.2 三端部署投影（已落地于 `scripts/mcp-sync.ps1`：先 DryRun 预览，再显式 Apply）

| 目标客户端 | 实际落点与合并策略 | 第三方插件 / 技能落点 |
| --- | --- | --- |
| **Antigravity** | 结构化逐项合并写入 `~/.gemini/config/mcp_config.json` 的 `mcpServers.<name>`（保留非托管条目与其余配置）。 | `ExternalPlugins` 通过显式 `-ExternalPlugin <name>` 触发官方 `agy plugin install <name>@<source>`；共享 Skill 随 `ai-agent-dotfiles` 插件更新。 |
| **Codex** | 仅通过官方 `codex mcp list/get/add/remove` CLI 逐项投影声明条目，**不直接改写**整个 `config.toml`，完整保留用户模型选择、审批档位与个人配置。 | 共享 Skill 继续通过 `deploy-skills.ps1` 部署至 `~/.codex/skills`（或 `~/.agents/skills`）。 |
| **ZCode** | 结构化逐项合并写入 `~/.zcode/cli/config.json` 的 `mcp.servers.<name>`（`type: "stdio"` / `http`，保留 `model`、`provider`、`plugins` 与非托管条目）。 | 方案落地时共享 Skill 使用 Claude 构建产物。现从 `zcode/skills/` 部署至 `~/.zcode/skills`。 |

### 3.3 安全与回滚门禁

- 沿用现有“**DryRun 必现完整逐项 diff → 显式 Apply → 失败保留 pre-Apply 备份并停止链条**”模式；
- 禁止把本机路径、用户名、Token 写入 `harness-source/` 或生成预览；
- 不得把 `Skill rules 10`（仅覆盖 `work` 环境下 Codex/ZCode 技能更新）自动外推到 MCP 配置或 Antigravity 第三方插件安装。

## 4. 关于多模态“Pro 订阅零额外费用 + 全自动”选型核对记录

在落地多模态 Skill / CLI 之前，以下能力边界需在选型阶段明确，避免后续返工：

1. **消费级 Google AI Pro 网页端额度（Gemini App / Google Flow 网页端）**：
   - 官方未开放可供第三方终端直接消耗网页版 Video / Music 额度的命令行 API 密钥；
   - 因此 Codex / ZCode 无法在无浏览器环境下通过官方 CLI 直接扣减网页版 Flow 额度（且不得通过逆向私有接口或绕过验证码实现）。
2. **命令行全自动 + Pro 订阅关联额度（`gemini-api` CLI / `google-genai` Python SDK）**：
   - 可在 Antigravity、Codex、ZCode 中以纯自然语言驱动命令行直接落盘图像（Imagen）、视频（Veo）与音乐（Lyria / Interactions API）；
   - 该通道走 **Google AI Studio（`GEMINI_API_KEY`）** 或 **Google Cloud Vertex AI**，可通过领取 Google AI Pro 附带的 **每月 \$10 Google Cloud 开发者额度**抵扣，但若绑定结算账号且未设预算拦截，超出部分会产生按量计费。
3. **Antigravity 内置能力（仅限 Antigravity 端）**：
   - 图像生成/读图校验可直接走内置 `image-generator` 与视觉读图能力（走当前订阅配额，无额外 API 账单）；
   - 如确需在不产生 API 账单的前提下调度网页端 Flow 视频/音乐，在 Antigravity 中只能通过内置 `browser` 子代理操作已登录网页（需人工先完成登录与验证），跨端到 Codex / ZCode 仍需独立浏览器自动化或改走 API 额度方案。

## 5. 实施前置核验清单（正式立项时依次完成）

1. **T0 实机调查**：核对 ZCode 实际 MCP 配置格式与路径；确认 `mcp-for-blender` 在 `Blender 5.3` + `uvx` 下的 Stdio 参数与守护插件启用流程；验证 `agy plugin install <marketplace-id>` 的官方返回值与幂等性。
2. **T1 Schema 与 DryRun 规划器**：设计 `harness-source/mcp/` 校验规则、Codex `config.toml` 受管节合并器与完整预览输出。
3. **T2 测试与安全扫描**：补充 Pester 隔离夹具测试（合并保留个人配置、防冲突、环境变量占位校验），并确保 `run-tests.ps1` 与 `gitleaks` 全通过。
4. **T3 获准部署与三端实测**：在 Antigravity、Codex、ZCode 分别完成一次真实自然语言调用 MCP（如检查 Blender 场景）及一次多模态输出落盘验收。

## 6. 所有者决策记录（2026-11-15）

1. **Codex MCP 管理规则**：同意修订 AGENTS.md 硬规则，允许只经官方 CLI（`codex mcp add/get/remove/list`）或精确表项管理 `harness-source/mcp/` 声明的 MCP Server；整文件同步、私有路径与凭据值仍禁止。规则修订在轨道 C 内以独立审阅提交完成，修订前不写 `config.toml`。
2. **Antigravity MCP 落点**：采用选项二，结构化合并 `~/.gemini/config/mcp_config.json` 的受管条目并保留非托管条目；不打包进 `ai-agent-dotfiles` 插件。
3. **多模态费用策略**：尽量只用 Google 订阅自带额度，不新增费用。
   - 默认通道：Antigravity 内置图像生成与视觉读图；视频/音乐优先由用户在已登录网页端（Gemini App / Flow）完成，或在用户在场、自行完成登录与验证的前提下由 Antigravity 内置浏览器操作。
   - Codex / ZCode 默认不发起任何计费调用，只产出可交给 Antigravity 或网页端执行的生成简报，并对回收的文件做落盘校验。
   - API 通道（Pro 附带每月 \$10 Google Cloud 开发者额度）默认关闭：需要绑定付款方式的结算账号，预算提醒不是硬性上限，超出即计费。仅在所有者针对具体任务显式开启并确认预算拦截后使用。
   - 消费级 `agy` 被第三方编码代理包装调用存在账号风险（见 `antigravity-delegation` 说明），不作为多模态默认路径。
4. **实施顺序**：A（共享多模态 Skill）→ B（Antigravity 第三方插件声明）→ C（MCP 受管分发），各自独立分支、PR 与授权。

## 7. 轨道 B/C T0 实机调查记录（2026-11-15）

- **ZCode MCP 格式已实机核实**（来自本机 `zcode-guide` 0.3.0 `diagnosing-mcp` 技能与 `~/.zcode/cli/config.json`）：
  - 用户级配置文件为 `~/.zcode/cli/config.json`，字段为 `mcp.servers.<name>`（对象内含 `model`、`provider`、`plugins` 等字段，必须结构化合并并保留其余键和非托管 server）。
  - Stdio 规范字段为 `type: "stdio"`、`command`（字符串）、`args`（字符串数组）、`env`（键值对象；**禁用 `environment` 等旧字段，schema 严格且未知键会被丢弃，配置文件不展开 `${...}` 模板**）、`enabled`、`timeoutMs`。
- **Codex MCP CLI 已实机核实**（`codex mcp`）：
  - 支持 `list --json`、`get <name> --json`、`add <name> [--env KEY=VALUE ...] -- <command> <args...>`、`remove <name>`；通过官方 CLI 仅维护声明条目，可完全保留 `[projects.*]`、`[model_providers.*]`、个人配置及非托管 `[mcp_servers.*]`。
- **Antigravity MCP 格式已实机核实**：
  - 全局配置为 `~/.gemini/config/mcp_config.json`，字段为 `mcpServers.<name>`（`command` / `args` / `env` 或 `url`），结构化合并保留非托管条目。
- **`mcp-for-blender`（`2.3.0`）与 Blender 5.3**：
  - `uvx mcp-for-blender` 可直接作为 Stdio server 运行（默认连接 `BLENDER_HOST=localhost`、`BLENDER_PORT=9876`，无需 API 密钥）；
  - 本机已安装 `Blender 5.3`，但用户配置目录 `%APPDATA%\Blender Foundation\Blender\5.3` 尚未生成（`uvx mcp-for-blender addon-paths` 返回空），正式 T3 验收前需先启动一次 Blender 5.3 或运行 `uvx mcp-for-blender install-addon` 并启用插件。
