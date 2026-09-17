# CI 失败诊断规则

本文件把 GitHub 上可查的 `Validate` 工作流失败提炼成**规则**，供后续任务直接套用。
[`STATUS.md`](../STATUS.md) 是带日期的日志（只记当时发生什么），本文件是可复用的判据与处置；
两者冲突时以实际代码、当前工作流和当次运行日志为准。

适用范围：任何一次 `Validate` 红灯的定位与处置；以及会改动 CI 门禁、测试预算、schema 产物、
`tests/` 夹具或 `.github/workflows/validate.yml` 的工作。**本文件不授权重跑以外的任何写操作**，
推送、合并、部署、解除联锁仍按 `AGENTS.md` 与受控 Policy 执行。

统计窗口：2026-06-20 首次运行至 2026-09-17，共 123 次运行、57 次非成功。

## 1. GitHub 上能看到什么

一个 run 只有 3 层：run → job（固定唯一 `Validate repository`）→ step（15 个）。

- **annotations 只有一行 `Process completed with exit code 1.`**（57 次里 55 次如此）。
  它说明不了任何根因；真实错误只存在于 job 日志。**不要用 GitHub 页面的红色标注做定位。**
- runner 进程失联类给的是基础设施说明文字，且**没有日志可下载**（见 R1）。
- 失败步骤分布（57 次）：

  | 失败步骤 | 次数 | 类别 |
  |---|---|---|
  | `Run every root regression suite exactly once` | 36 | 测试矩阵：断言失败、超时、夹具抖动 |
  | `Validate machine-readable schemas and build evidence` | 10 | 产物契约漂移（R5） |
  | `Run repository doctor` | 5 | 全新检出缺目录（R6） |
  | `Run MCP tests` | 2 | 已退休步骤，不再适用 |
  | `Scan for secrets` | 2 | secret 门禁命中（R8） |
  | （无失败步骤） | 2 | runner 失联（R1） |

取数用 GitHub API（`GET /repos/<owner>/<repo>/actions/runs`、`.../runs/<id>/jobs`、
`.../jobs/<id>/logs`）：

- `gh` 现在未认证；要长期可用先 `gh auth login`。替代方式是用本机已存的 Git 凭据做只读取数
  （`git credential fill` 取令牌，**只放进进程环境变量，不打印、不落盘、不入库**）。
- **日志端点会 302 到对象存储，必须用 `curl -L`**：会保留 `Authorization` 头跟随重定向的客户端
  （例如 Python `urllib`）会被对象存储以 401 `Server failed to authenticate` 拒绝，看起来像没权限。
  ```bash
  curl -sSL -f -H "Authorization: Bearer $TOK" \
    "https://api.github.com/repos/<owner>/<repo>/actions/jobs/<job_id>/logs" -o log.txt
  ```
- 老 run 引用的 SHA 可能是重写前的对象，本地 `git show` 与 GitHub 对象 API 都报不可解析（R10）。

## 2. 规则

### R1 先分流：基建失败不要改代码

**判据**：annotation 是 `The hosted runner lost communication with the server. ...`，`failed_steps`
为空，日志下不到。

**规则**：这是 runner 侧失联（资源/网络/进程被杀），不是代码缺陷。**同一提交重跑**；只有同一提交
反复失联才升级为资源问题排查。

**证据**：runs `35166789288`、`35166625038`（2026-09-17，提交 `0c5ca92`/`6488182`）。

### R2 套件超时不是断言失败（`failed=0; timed-out>0`）

**判据**：失败步骤是测试矩阵，摘要形如 `Test summary: FAIL; discovered=39; passed=38; failed=0; timed-out=1`。
日志里该套件的块**只有一行 `test-runner-suite-timeout`、没有任何 `PASS`/`FAIL` 记录**。

> 陷阱：`test-runner.tests.ps1` 自身的超时夹具也会打印同一串标记，但它周围有 `PASS` 记录。
> 判据必须按「该套件块内零测试记录」判断，否则会把夹具误判成超时。

**规则**：

- 超时**不代表断言失败**；不要按失败用例去改断言。
- **先确认该套件的「生效」上限**：`tests/test-timeouts.psd1` 里没有显式条目的套件走
  `DefaultTimeoutSeconds = 120`，于是个别套件会悄悄挂在最短档上。把本机实测与生效上限对照，
  才能分开「预算不足」与「实现变慢」——不要拿记忆里的耗时推断。
- 新套件或加重的套件必须给显式预算；CI 时长约为本机 **2 倍**，按本地实测乘 2 再留余量，
  本仓既有预算大致落在本地实测的 3–4 倍。
- 改预算后 `tests/test-runner.tests.ps1` 会校验发现集与预算契约；默认档也算进总额，
  workflow `timeout-minutes` 必须同步抬高（含默认档的总预算 > 工作流上限即失败）。
- 反复超时的套件应给显式预算并记录实测，而不是压缩测试内容。

**证据**：`881047a`（四套件预算 420/240/1800/240 → 900/600/3600/900，工作流 380 分钟；本地同树实测
231/187/1511/197 秒）、`5e99c07`（sync 900 → 1200）、`fa53b7c`（给 harness-authority 显式预算）、
`6db9760`（automation-safety：本地实测 80.1 秒，继承的 120 秒默认档不足 → 600 秒；改后合同复算
40 套件、所需 439.25 分钟 < 工作流 460 分钟，无需改工作流）。
本窗口 22 次套件级超时分布在：canonical-command-result 4、automation-safety 3、
canonical-production-seams 3、root-claims-registry 3、harness-authority 3、harness-env 2，其余各 1。

### R3 时序/占用类红灯：同代码重跑即绿，不要防御性改码

**判据**：错误是 `Exception calling "ReadAllText" with "N" argument(s): "The process cannot access the
file '<fixture 输出或 header 文件>' because it is being used by another process."` —— 夹具在刚被杀掉的
子进程还没释放句柄时去读它的输出/头文件。

**规则**：判定为抖动前先做**对照**：`git diff <红提交> <绿提交> -- tests/` 为空（只有文档/无关脚本变化）
且下一次运行直接绿，即可认定与代码无关。**不要把重试、`Start-Sleep`、抢占式重读写进生产代码**来
掩盖抖动；如需稳健化，只改夹具本身的同步语义（等句柄释放后再读）。

**证据**：`34991068832`（harness-authority.tests.ps1:1522 与 live-recovery.tests.ps1:2494 两处同因）、
`35086695635`（harness-authority.tests.ps1:1605）；`5807727a` → `71b8e74` 两次运行之间只改了文档与
`scripts/check-powershell-syntax.ps1`，下一次运行即绿。

### R4 本地绿不等于 CI 绿：环境差异要先假设

两类已实证的差异，新增夹具时按 CI 约束设计：

- **owner 语义**：hosted runner 以提权管理员令牌运行，新建对象默认 owner 是
  `BUILTIN\Administrators`（`S-1-5-32-544`），而 `current-user-only` 校验比对的是 access-token 用户
  SID，于是 CI 上 fail-closed、本地（非提权）全绿。修复 `9583aed` 改为接受 token 默认 owner。
- **路径长度**：CI 用户名为 `runneradmin`，比本地长；registry 夹具名过长会让 ADS 文件超 MAX_PATH。
  **常规 .NET I/O 在 runner 上走长路径，PowerShell provider 的 `Set-Content -Stream`（ADS）仍受
  MAX_PATH 限制**。修复 `6540681`（缩短夹具名、预热父租约攻击探测）。

**规则**：夹具名保持短且唯一；不要依赖「当前用户即对象 owner」；对毫秒级竞争窗口的夹具要先预热。

### R5 硬编码断言与产物契约必须同源（最易连续红的类）

**判据**：`Harness environment build JSON is invalid.`（9 次）或
`Harness environment lock is missing required field: <字段>`（1 次）。

**根因**：产物 schema/必填字段升级，而 `.github/workflows/validate.yml` 的断言没跟着改
（`3d3aa7f` 把 env-build sidecar 升到 schema 3，断言仍写 `SchemaVersion -ne 2`，从而每次都在测试矩阵前就死）。

**规则**：

- **改 schema 版本或必填字段的同一个提交里**，grep 工作流中全部 `SchemaVersion -ne/-eq` 断言与必填字段
  列表并同步；不要留给 CI 告诉你。
- 本地按 CI 的同一断言链重放（build → lock → list → status 四段），不要只跑单元测试。
- 修复声明必须绑定修复提交：曾出现过「文档写已修复、代码未改」的记录错误。

**证据**：`895c54f`（断言改 3）；对照 run `34415191929`（红，失败于该步骤）与 `34415557457`
（同步骤通过，失败点后移到测试矩阵）。更早一例为 `30925873505`（env-lock 必填字段漂移）。

### R6 Git 不跟踪空目录：新增目录必须带 tracked 文件

**判据**：doctor 步骤输出 `[FAIL] status\active is missing or is not a Directory.` 且
`Doctor result: FAIL`。

**根因**：该目录当时只有本机未跟踪文件（或为空），**Git 不跟踪空目录**，CI 全新 checkout 后目录不存在；
本机因为目录一直在而看不到问题。

**规则**：新增或依赖某个目录时，**同一次提交里放入一个 tracked 文件**（如 `README.md`）作为占位；
不要依赖本机既有目录、也不要依赖构建产物创建它。

**证据**：5 次同因失败（`31304804911`、`31507208506`、`32032684310`、`32109626676`、`32130048501`，
2026-08-09 至 08-18）；`c25fdd4` 加入 `status/active/README.md` 后消除。

### R7 机器私有状态与临时诊断脚本不入库

**规则**：本机运行状态（如 Reasonix 任务状态）、临时诊断 `ps1`、缓存与日志一律不入库；新增工具产生
此类文件时**同提交更新 `.gitignore`**。

**证据**：`c25fdd4` 在修 R6 的同时删除了已入库的 `.reasonix/tasks/**` 与 `.tmp-*.ps1`，并补
`/.reasonix/tasks/`、`/.tmp-*` 忽略规则。

### R8 secret 门禁命中：改代码结构，绝不改扫描器

**判据**：`ERROR: gitleaks reported one or more findings.`（日志里只有 `leaks found: N`，不显示明细）。

**根因（本次实例）**：`scripts/scan-secrets.ps1`（模式名 `Literal secret assignment`）与 `.gitleaks.toml`
（规则 id `quoted-secret-value`）使用同一条正则，要求「`api_key`/`token`/`secret`/`password` 等关键字 +
赋值号 + 引号字面值（长度 ≥ 8 且不以 `$` 开头）」。
`root-claims-registry-common.ps1` 当时把消息串直接写成了 `MessageToken` 属性上的引号字面值，于是被命中
——与它是不是真密钥无关。

**修法**：把字面值先赋给**非关键字变量名**，该属性右侧改成以 `$` 开头的变量引用（被规则排除），语义不变。

**注意**：文档、注释与提交信息里也不要照抄这一命中形态，否则门禁会拦下文档本身
（本文件初稿即被 `scan-secrets.ps1` 拦下，改为拆开描述后通过）。需要引用时拆开写，不要给出完整赋值形态。

**本地复现**（钉住的 8.30.0，改前 1 处命中、改后 `no leaks found`）：
```bash
"$LOCALAPPDATA/ai-agent-dotfiles/tool-cache/secret-scanner/8.30.0/bin/gitleaks.exe" \
  dir <目录> --config .gitleaks.toml --no-banner --redact -v
```

**规则**：**永不白名单、永不削弱或绕过 `scripts/scan-secrets.ps1` 与 `.gitleaks.toml`**；命中先判真伪，
再用代码结构规避（例如变量间接、拆分字面值）；确属真密钥走轮换并按既定流程处置。

**证据**：`8b859e5`（runs `34044662672`、`34044956596`）。

### R9 计数/清单断言必须由清单派生

**判据**：`FAIL: registry lists six negative fixtures`（live-plan.tests.ps1）。

**规则**：断言不要写死条目数量，从被验证的清单本身派生；改清单的提交必须同步检查这类断言。
写死数量时，新增一条负例就会让整条链变红。

**证据**：5 次同因失败（2026-09-12，如 `34670776794`、`34672767004`、`34674850024`、`34676257352`）。

### R10 重写前的 SHA 不可解析

**规则**：诊断老 run 时**只用 run 日志与 run 页面**，不要承诺用该 SHA 在本地复现或 diff；引用老 SHA 时
注明不可解析原因（已授权的隐私重写，publish head `bbba28f`）。

**证据**：2026-08 前后 run 引用的 SHA 在本地 `git show` 与 GitHub 对象 API 双双报不可解析，而本地
同期历史存在（同一时间窗、不同 SHA）。

## 3. 处置流程

1. **取失败步骤名**（`.../runs/<id>/jobs`）→ 按第 1 节分布表归类。
2. 若是 runner 失联（无失败步骤）→ 走 R1，同提交重跑，不要改代码。
3. **拉日志**（`.../jobs/<id>/logs`，注意 R1 末尾的 `curl -L` 要求）。
4. 在日志里依次看：`Test summary:` 行 → `timed-out` 数 → 该套件块内的失败记录。
   `failed=0; timed-out>0` 直接走 R2；`ReadAllText ... being used by another process` 走 R3。
5. 有真实断言失败时，按日志给出的 `tests/<套件>.ps1:<行号>` 定位断言，再改代码或夹具；
   改动落到 `tests/`（尤其新增/加重套件）时同步核对预算（R2）与工作流断言（R5）。
6. 本地验证：相关套件单独跑，必要时 `scripts/run-tests.ps1 -All`；本地通过**不能**替代 CI。

## 4. 未决项

（本文件初稿记录的「`automation-safety.tests.ps1` 无显式预算而反复超时」已由 `6db9760` 修复，
预算与合同复算见 R2。）

- `task-skills.tests.ps1` 的 `Task skill dry-run failed (exit 1); overlay was not changed.`
  （run `34851206631`）只到外层提示，未定位到根因。
- 2026-09-17 两次 runner 失联尚未在同一提交上重跑确认。
- 早期 `Run MCP tests` 步骤已随 MCP 工具退休从工作流移除，其历史失败不再适用。

## 5. 证据索引

| run | 日期 | 失败步骤 | 真实根因 | 规则 | 修复/状态 |
|---|---|---|---|---|---|
| `29331454091` `29336806518` | 2026-07-14 | Run MCP tests | mcp.tests.ps1 断言失败 | — | 步骤已退休 |
| `30925873505` | 2026-08-04 | schema/build evidence | env-lock 必填字段漂移 | R5 | 已修 |
| `31304804911` … `32130048501` | 2026-08-09~08-18 | Run repository doctor | `status\active` 未跟踪、CI 无此目录 | R6 | `c25fdd4` |
| `32382198540` … `33075009777` | 2026-08-20~08-27 | 测试矩阵 | 提权 owner 语义 + 父租约窗口 + 夹具路径过长 | R4 | `9583aed`、`6540681` |
| `33405252337` `33410778745` | 2026-08-31 | 测试矩阵 | 两套件预算不足（超时） | R2 | `881047a` |
| `34044662672` `34044956596` | 2026-09-06 | Scan for secrets | `quoted-secret-value` 误报 | R8 | `8b859e5` |
| `34245344523` … `34415191929` | 2026-09-08~09-09 | schema/build evidence | env-build schema 2 → 3 断言未同步 | R5 | `895c54f` |
| `34159245642` `34163548245` `34169118876` | 2026-09-07 | 测试矩阵 | canonical-command-result 预算不足（超时） | R2 | `881047a` |
| `34415557457` | 2026-09-09 | 测试矩阵 | 四套件预算不足（超时） | R2 | `881047a`、`5e99c07` |
| `34670776794` … `34677219278` | 2026-09-12 | 测试矩阵 | 负例计数断言漂移 + 夹具 PID 竞争 | R9、R3 | 已修 |
| `34770673201` `34771649051` | 2026-09-13 | 测试矩阵 | production-seams 反射清单/摘要未重钉 | — | 随该窗口修复 |
| `34788238413` `34851206631` `34909047517` | 2026-09-13~09-14 | 测试矩阵 | 套件超时（harness-* / task-skills） | R2 | `fa53b7c` 等 |
| `34957472014` `34991068832` `35086695635` | 2026-09-15~09-16 | 测试矩阵 | automation-safety 超时；killed 进程夹具共享冲突 | R2、R3 | 未决 / 重跑即绿 |
| `35097541381` | 2026-09-16 | — | 绿（40 套件） | — | 参考基线 |
| `35166625038` `35166789288` | 2026-09-17 | 无 | hosted runner 失联 | R1 | 待重跑 |
