# CI 失败诊断规则

本文件把 GitHub 上可查的 `Validate` 工作流失败提炼成**规则**，供后续任务直接套用。
[`STATUS.md`](../STATUS.md) 是带日期的日志（只记当时发生什么），本文件是判据与处置；
冲突时以实际代码、当前工作流和当次运行日志为准。

**授权边界：本文件只授权「读取日志并分类」。** 重跑 CI、改动测试或门禁、改动预算、推送、
解除 Phase 0 联锁、导出或使用凭据，都要按 `AGENTS.md` 与受控 Policy 各自取得授权。
历史频数是窗口观察，**不能替代当次日志**。

统计窗口：2026-06-20 首次运行至 2026-09-17，共 123 次运行、**57 次 failure**（其余 66 次 success，
全部 `completed`、全部 `push` 事件；窗口内没有 cancelled/skipped）。窗口数据已由独立复算核对。

## 1. GitHub 上能看到什么

一个 run 只有 3 层：run → job（固定唯一 `Validate repository`）→ step。统计窗口内的工作流有
**13 个 named step**（Checkout、Show PowerShell version、两个 install-verify、Validate registered JSON
artifacts、Run repository doctor、Scan for secrets、Build generated skills、Verify build leaves Git
clean、Validate machine-readable schemas and build evidence、Parse every current-worktree PowerShell
file、Run every root regression suite exactly once、Reject dangerous tracked files）。
**2026-09-19 起工作流改为 `validate-gates` + `validate-tests-1..3` 四个作业**（详见 R2 与第 4 节），
本节与下表的步骤名对应旧单作业结构。

- **annotations 不含根因**：57 次非成功里 **55 次**含 `Process completed with exit code 1.`
  （其中 54 条的 annotation 恰好只有这一行；run `29331454091` 另有 1 条 Node.js 20 deprecation
  warning），另 2 条是 hosted runner 失联说明。**不要用页面标注做定位，尤其是不要用它下结论。**
- 失联那两次的 job 日志返回 **HTTP 404**，即根本没有日志可读（curl exit 22）。
- 失败步骤分布（**窗口历史频数，不是完整门禁清单**）：

  | 失败步骤 | 次数 | 类别 |
  |---|---|---|
  | `Run every root regression suite exactly once` | 36 | 测试矩阵：断言失败、超时、夹具抖动 |
  | `Validate machine-readable schemas and build evidence` | 10 | 产物契约漂移（R5） |
  | `Run repository doctor` | 5 | 全新检出缺目录（R6） |
  | `Run MCP tests` | 2 | 已验证退休的步骤，不再适用 |
  | `Scan for secrets` | 2 | secret 门禁命中（R8） |
  | （无失败步骤） | 2 | runner 失联（R1） |

  表外步骤（JSON artifacts、syntax、build clean、dangerous files 等）在窗口内没有失败样本：
  **它们若失败，本文件的 R1–R3 不适用**，按第 3 节读该步日志。

取数（`GET /repos/<owner>/<repo>/actions/runs`、`.../runs/<id>/jobs`、`.../jobs/<id>/logs`）：

- 首选 `gh auth login`（交互式、可撤销）。**如需改用本机已存的 Git 凭据做只读取数，先取得所有者
  同意**；本文件不记录凭据获取配方，凭据不得打印、落盘或入库。
- **日志端点会 302 到对象存储，必须用 `curl -L`**：保留 `Authorization` 头跟随重定向的客户端
  （例如 Python `urllib`）会被对象存储以 401 `Server failed to authenticate` 拒绝，看着像没权限。
  ```bash
  curl -sSL -f -H "Authorization: Bearer $TOK" \
    "https://api.github.com/repos/<owner>/<repo>/actions/jobs/<job_id>/logs" -o log.txt
  ```

## 2. 规则

### R1 先分流：基建失败不要改代码

**判据**：annotation 是 `The hosted runner lost communication with the server. ...`，`failed_steps`
为空，日志 404 取不到。

**规则**：这是 runner 侧失联（资源/网络/进程被杀），不是代码缺陷。**同一 SHA 重跑**；只有同一
SHA 反复失联才升级为资源问题排查，并在记录里写清是重跑。

**证据**（独立核验）：runs `35166789288`、`35166625038`（2026-09-17，提交 `0c5ca92`/`6488182`）。

### R2 套件超时不是断言失败（`failed=0; timed-out>0`）

**判据**：失败步骤是测试矩阵，摘要形如 `Test summary: FAIL; discovered=39; passed=38; failed=0; timed-out=1`。
日志里该套件的块**只有一行 `test-runner-suite-timeout`、没有任何 `PASS`/`FAIL` 记录**。

> 陷阱：`test-runner.tests.ps1` 自身的超时夹具也会打印同一串标记，但它周围有 `PASS` 记录。
> 判据必须按「该套件块内零测试记录」判断，否则会把夹具误判成超时。

**规则**：

- 超时**不代表断言失败**；不要按失败用例去改断言。
- **先确认该套件的「生效」上限**：`tests/test-timeouts.psd1` 里没有显式条目的套件走
  `DefaultTimeoutSeconds = 120`，个别套件会因此悄悄挂在最短档上。把本机实测与生效上限对照，
  才能分开「预算不足」与「实现变慢」——**实现变慢时不得先抬预算**，也不得用记忆里的耗时推断。
- 本仓 CI 与本地耗时之比是**窗口观察**（`881047a` 那组重套件曾约 2×；`automation-safety` 实测
  约 1.3×），**不是配额**。定档时以该套件自己的实测与 CI 墙钟为准，并参考同类既有档位。
- 改预算后 `tests/test-runner.tests.ps1` 会校验发现集与预算契约（2026-09-19 起为 **per-shard**
  形式）：每个测试 shard 作业的 `timeout-minutes × 60` 必须**严格大于**
  `SetupAndNonSuiteBudgetSeconds + Σ该shard生效超时 + MarginSeconds`（默认档计入 Σ），且低于
  360 分钟平台上限。**仅当该不等式不再成立时才需要抬高对应作业的 `timeout-minutes`**；不是每次
  改预算都要改工作流。
- **平台另有硬上限，2026-09-19 起由 shard 结构消解**：GitHub 文档规定「Each job in a workflow
  can run for up to 6 hours of execution time. If a job reaches this limit, the job is terminated
  and fails.」——托管 runner 的作业上限是 **360 分钟**。旧结构里单一作业声明 `timeout-minutes: 460`
  高于平台上限，而已证预算合计本就放不进一个作业（2026-09-19 拆分时为 459.25 分钟 /
  27555 秒，2026-09-26 按 R2 重算为 509.25 分钟 / 30555 秒）；所有者已裁决**拆分测试矩阵**：
  `validate-gates`（非套件门禁与产物链，orchestrator 以
  test-only `-SkipGates unified-test-runner` 运行，这是该参数的一次受评审的 CI 用法）+
  `validate-tests-1..3`（静态分区 `tests/test-shards.psd1`，按套件预算配平，canonical-hard-kill
  单独占 shard 1）。每个 shard 作业的 `timeout-minutes` 取「该 shard 预算 + 300 + 120 向上取整 +
  余量」，必须 < 360 分钟；`tests/test-runner.tests.ps1` 断言该 per-shard 合同，
  `scripts/run-tests.ps1 -ShardCount/-ShardIndex` 在分区与发现集不一致时失败关闭——**新增套件必须
  同步 `tests/test-shards.psd1`**（文件头有重平衡步骤）。本地 `run-tests.ps1 -All` 与 orchestrator
  的非 shard 调用不受影响。
- 反复超时的套件应给显式预算并记录实测，而不是压缩测试内容。

**证据**（CI 侧已独立核验）：`881047a` 的预算改动本身（`git show 881047a`：420/240/1800/240 →
900/600/3600/900，工作流 310 → 380 分钟），以及 run `34415557457` 里四个套件在 runner 上**恰好
打满旧预算**（420.05/240.02/1800.16/240.02 秒）。该提交信息与 `STATUS.md` 里的**本地**实测
（231/187/1511/197 秒）属**本仓自述，未独立复现**，不要当作可核验证据引用。
另：`5e99c07`（sync 900 → 1200）、`fa53b7c`（给 harness-authority 显式预算）、`6db9760`
（automation-safety：本机实测 80.1/86.5 秒，CI 绿那次 112.6 秒、失败三次恰好 120.0 秒被杀 →
600 秒；改后合同 40 套件、25935 秒总预算、所需 439.25 分钟）。
窗口内 22 次套件级超时的分布（**窗口历史**）：canonical-command-result 4；automation-safety、
canonical-production-seams、root-claims-registry、harness-authority 各 3；harness-env 2；
harness-profile、live-recovery、sync、task-skills 各 1。
同窗口的**接近预算**信号（下一次红灯的候选）：`harness-authority` 绿 584 秒、一次 849 秒，对
900 秒档占用到 94%；`harness-env` 最大 526/600（88%）。给这三类套件加测试前先重估预算。

**2026-09-26 shard 3 重估（R2 的最新一次执行）**：run
[#147](https://github.com/MaginaLW/ai-agent-dotfiles/actions/runs/36146730327) 的 shard 3 作业
（`Run test shard 3 of 3` 步骤 14:20:04Z→15:50:21Z = 5417 s，`timeout-minutes: 195`）注解为
`discovered=27 passed=24 failed=0 timed-out=3`，被杀的是 `canonical-command-result`（900 s 档）、
`harness-authority`（900 s 档）、`harness-env`（600 s 档）——三者都是**打满预算被杀**，不是断言
失败。该注解本轮由 check-runs API 独立取回（HTTP 200），job 日志仍 403 admin-only，所以**逐套件
CI 耗时确实不可得**，倍率只能给区间、不能当已测定的点值：
- **三个下界**（被杀 + 五次干净实测最大值，C2/C3/C4/C6 与 `validation-01`）：
  `canonical-command-result` ≥1.31（689 s 被杀于 900）、`harness-env` ≥1.46（410 s 被杀于 600）、
  `harness-authority` ≥1.60（561 s 被杀于 900）。注意 `561 × 1.5 < 900`——**「最大实测 × 1.5」解释不了
  authority 为什么被杀**，真实倍率高于 1.5。
- **残差上界**：其余 24 个套件在 `5417 − 2400 = 3017 s` 内跑完（不扣 `SetupAndNonSuiteBudgetSeconds`
  ——那是津贴，不是这一步量到的开销），对干净配对 `validation-c6-02` 的 1883.1 s ⇒ **≤1.60×**；
  换配对会移动该上界：c2 的 1706 s ⇒ 1.77×、c3 的 2061 s ⇒ 1.46×、c4 的 2126 s ⇒ 1.42×
  （后两次中 c3 有失败套件）。同一次 c6 的 shard 2 为 `(3668−300)/2862` ≈ 1.18×（其重套件 CPU 密集
  而非 spawn 密集，但这也只是单次配对，不是配额）。
据此把**三个被杀套件**重新定档到干净最大值的约两倍：`canonical-command-result` 900→1800、
`harness-authority` 900→1500、`harness-env` 600→1200。`live-recovery`（477–598 s，对 900 s 档
占用 ≤66%）经独立审查判定**不属越档**，保持 900 s 不改——本仓历史上「接近预算」的例子是 94% 与
88%，用别套件的超时给它加预算不符合 R2 的「按该套件自己的实测与 CI 墙钟定档」。shard 3 合同秒数
10095→12195（168.25→203.25 分钟），作业 `timeout-minutes` 195→230（合同之上余量仍为 1605 s，
与「只为三个被杀套件加 35 分钟」一致）；分片 1/2 未触不等式，未改动。同 run 的 gates 作业 173 s、
shard 1 4018 s、shard 2 3668 s 均已绿。
**未决**：新档位尚无一次全绿 CI 证明；失败注解目前不含逐套件时长，建议后续把
`DurationMilliseconds` 写进注解（受 700 字上限约束），否则下一次仍只能做减法。

**2026-09-26 shard 2 二次定档（同一天的第二轮，证据来自 CI 本身）**：同晚三份候选
（`c962f41`、`6682587`、`27e435f` 的 run #148/#149/#150）**分片 3 两次转绿**（第三份仍在跑），
证明三个被杀套件的上调解决了分片 3；但三份**都**在分片 2 红，注解一致为
`discovered=8 passed=7 failed=0 timed-out=1 failing=[backup-recovery.tests.ps1:timed-out:exit=-1]`——
`backup-recovery` 打满 900 s 档被杀，其余七只通过。五次干净实测该套件 520–692 s（占旧档 58–77%），
属「实测显示不足」，按同一「约为干净最大值两倍」的规则提到 **1500 s**（`692 × 1.5 = 1038`、
`× 2 = 1384` 都在档内）。分片 2 合同 9600→**10200 s**（160→170 分钟），作业 `timeout-minutes` 185
不变（余量 1500 s）；聚合 29655→**30255 s**。这一次不再有「用别套件的超时给它加预算」的问题：
被杀记录就是它自己的。

**2026-09-26 shard 3 第三次定档：`live-recovery`（撤回→再抬）**。本窗口第一版曾把它 900→1200，
独立审查以「`598 × 1.5 = 897 < 900`，无实测接近档位」为由撤回，这是对的——**当时**它没有属于
自己的失败记录。随后 run #150 在 shard 3 上把它杀在 900 s
（`failing=[live-recovery.tests.ps1:timed-out:exit=-1]`，同一晚的 #148/#149 分别以 1200/900 档通过），
于是它有了自己的杀点：实测 477–598 s（占旧档 53–66%），新档 **1200 s**（约为干净最大值两倍）。
按审查给的条件，作业 `timeout-minutes` 230→**235**，把该档吃掉的 300 s 还回合同之上的余量
（12495 + 1605 = 14100 s）。聚合 30255→**30555 s**。
**教训**：`--`「没记录就先抬」与「有记录才抬」在本窗口各被验证一次——两次判断本身都对，
差别只在证据出现的时间顺序。

### R3 占用/时序类红灯：先按同一 SHA 对照，复发就修夹具

**判据**：错误是 `Exception calling "ReadAllText" with "N" argument(s): "The process cannot access the
file '<夹具输出或 header 文件>' because it is being used by another process."`，通常出现在读刚被杀
掉的子进程留下的输出/头文件的夹具辅助函数里（如 `Invoke-AuthorityCliKilledAtCheckpoint`、
`Get-SealedLiveJournalChain`）。

**规则**：

- **红灯仍是失败，不得据此忽略。** 判定「与当前提交无关」需要**同一 SHA 重跑**才成立；跨提交
  对照（例如红提交与绿提交之间 `tests/` 无差异）只是弱证据，不足以结案。
- **同一次红灯里若还有别的失败腿（断言失败、其他套件），必须先处置那一条**——超时或占用可能
  只是伴随现象（run `34991068832`、`35086695635` 都同时有真实失败）。
- 复发即按夹具自身的同步语义修（等句柄释放、明确 `FileShare`、按发布顺序读），**禁止**把重试、
  `Start-Sleep`、抢占式重读写进生产脚本。
- 本仓已有故意制造并断言发布竞争的夹具（`b1fe6e1`），这类领域是本仓的正常建模对象，不要一概
  当作抖动。

**证据**（独立核验）：`34991068832`（harness-authority.tests.ps1:1522 与 live-recovery.tests.ps1:2494
两处同因）、`35086695635`（harness-authority.tests.ps1:1605）；`5807727a` → `71b8e74` 之间
`git diff --name-only ... -- tests/` 为空（只动 STATUS/ZCODE/`check-powershell-syntax.ps1`），
且两次运行 run `35086695635`（failure）→ `35097541381`（success）。

### R4 本地绿不等于 CI 绿：环境差异要先假设

两类已实证的差异，新增夹具/断言时按 CI 约束设计：

- **owner 语义**：hosted runner 以提权管理员令牌运行，新建对象默认 owner 是
  `BUILTIN\Administrators`（`S-1-5-32-544`），而 `current-user-only` 校验比对的是 access-token 用户
  SID，于是 CI 上 fail-closed、本地（非提权）全绿。`9583aed` 的修法是**放宽 owner 集合**为
  {用户 SID, token 默认 owner}（`WindowsIdentity.Owner` 语义）；**DACL 与私有性拒绝语义不变，
  仍是 fail-closed**——不要把这条读成「生产校验可以放宽」。
- **路径长度**：CI 用户名为 `runneradmin`，比本地长；registry 夹具名过长会让 ADS 文件超 MAX_PATH。
  **常规 .NET I/O 在 runner 上走长路径，PowerShell provider 的 `Set-Content -Stream`（ADS）仍受
  MAX_PATH 限制**（`6540681` 缩短夹具名）。对毫秒级竞争窗口的攻击夹具要先预热一轮探测——这只
  适用于这类短窗口夹具，不是普遍夹具写法。
- **本地化**：断言要钉稳定的错误 ID/令牌，不要钉 PowerShell 本地化资源串——本机 UI 文化是
  zh-CN 而 CI 是 en-US，绑资源串会出现「本机红、CI 绿」的反向差异。

**证据**：`9583aed`、`6540681`（2026-08-28 修复，终结 2026-08-09 起的连红）。
owner/路径两条已由仓库记录交叉印证；本地化一条来自仓库既有教训。

### R5 产物契约漂移：版本断言、必填字段与 schema 必须同源

**判据**：`Harness environment build JSON is invalid.`（9 次）或
`Harness environment lock is missing required field: <字段>`（1 次）。

**根因**：产物 schema/必填字段升级，而 `.github/workflows/validate.yml` 的断言没跟着改
（`3d3aa7f` 把 env-build sidecar 升到 schema 3，断言仍写 `SchemaVersion -ne 2`，于是每次都在测试
矩阵之前就死）。

**规则**：改产物格式的**同一个提交**里同步四处——`SchemaVersion` 断言、**必填字段列表**、
schema 文件本身、以及注册契约（该步骤还调 `scripts/validate-json-artifacts.ps1`，并检查
build-report 与 env-lock/env-list/env-status 的版本与字段）。只搜 `SchemaVersion` 会漏掉字段类漂移。
本地按 CI 同一断言链重放（`build-harness-env.ps1` → lock → `list-harness-env.ps1` →
`status-harness-env.ps1`）后再提交。修复声明必须绑定修复提交。

**证据**（独立核验）：9 次 `build JSON is invalid`（`34245344523` … `34415191929`）与 1 次
`lock is missing required field: ManagedPluginDeclaration`（`30925873505`）；修复 `895c54f`。

### R6 doctor 只在它的必需清单上 FAIL

**判据**：doctor 步骤输出 `[FAIL] status\active is missing or is not a Directory.` 且
`Doctor result: FAIL`。

**根因**：该目录当时只有本机未跟踪文件，**Git 不跟踪空目录**，CI 全新检出后目录不存在；本机因为
目录一直在而看不到问题。

**规则**：`scripts/doctor.ps1` 只对它的必需结构清单判 FAIL——命中本条说明**清单里的**某个目录在
全新检出里不存在。修法是在同一次提交里给该目录放一个 tracked 占位文件（`c25fdd4` 加入
`status/active/README.md`）。**不要**把这条推广成「任何新目录都必须有 tracked 文件」：清单外目录
不会以本规则红灯出现。

**证据**（独立核验）：5 次同因失败（`31304804911`、`31507208506`、`32032684310`、`32109626676`、
`32130048501`，2026-08-09 至 08-18），每次日志里 `[FAIL]` 只有这一条。

### R7 机器私有状态与临时诊断脚本不入库（配套规则，不是步骤失败类）

本条的实例来自同一窗口的修复提交，但它不是某个 step 的失败：`c25fdd4` 在修 R6 的同时删除了已入库的
Reasonix 任务状态与 `.tmp-*.ps1` 诊断脚本，并补 `.gitignore`。维护要求见 `AGENTS.md` 的 hard rules：
本机运行状态、临时脚本、缓存与日志一律不入库；新增工具产生此类文件时同提交更新忽略规则。

### R8 secret 门禁命中：判定真伪，只改被拦内容

**判据**：`ERROR: gitleaks reported one or more findings.`（日志里只有 `leaks found: N`，不显示明细）。

**根因（本次实例）**：`scripts/scan-secrets.ps1`（模式名 `Literal secret assignment`）与 `.gitleaks.toml`
（规则 id `quoted-secret-value`）使用同一条正则，要求「`api_key`/`token`/`secret`/`password` 等关键字 +
赋值号 + 引号字面值（长度 ≥ 8 且不以 `$` 开头）」。`root-claims-registry-common.ps1` 当时把消息串直接
写成了 `MessageToken` 属性上的引号字面值，于是被命中——与它是不是真密钥无关。

**规则**：

- 先判真伪。**误报只改被拦内容**；修法是让那个值先经非关键字变量再引用，语义不变。
- **不得为了过门禁而改结构把真实密钥藏起来，也不得新增白名单、放宽正则或绕过扫描器**——那需要
  所有者明确批准（`AGENTS.md` hard rules）。本仓既有的 `[allowlist]` 与 `# scan-ok` 是**受控机制**，
  只在人工复核后按各自规则使用。
- 判定与取证走仓库入口 `pwsh -NoProfile -File ./scripts/scan-secrets.ps1 -RepoRoot <root>`。
  需要隔离复现单个模式时可用钉住的 8.30.0（`gitleaks dir <目录> --config .gitleaks.toml --no-banner
  --redact -v`，该子命令在 8.30.0 存在），但**结论以 `scan-secrets.ps1` 为准**。
- **写诊断记录时不要复现被拦的字面形态**：门禁按模式扫描，记录里的示例同样会被扫到。本文件初稿
  即因照抄该形态被 `scan-secrets.ps1` 拦下，改为拆开描述后通过。

**证据**（独立核验）：runs `34044662672`、`34044956596`（提交 `45b95102`、`cf9d6b36`，日志均为
`leaks found: 1`）；修复 `8b859e5`；误报形态已用钉住的 8.30.0 隔离复现（改前 1 处命中、改后
`no leaks found`）。

### R9 计数/清单断言必须由清单派生

**判据**：`FAIL: registry lists six negative fixtures`（live-plan.tests.ps1）。

**规则**：断言不要写死条目数量，从被验证的清单本身派生；改清单的提交必须同步检查这类断言。

**证据**：5 次同因失败（2026-09-12，`34670776794`、`34672767004`、`34674850024`、`34676257352`、
`34677219278`）。

### R10 重写前的 SHA 才会不可解析

**判据**：对该 run 的 `head_sha` 执行 `git cat-file -t <sha>` 失败，且该提交早于已授权的隐私重写
publish head `bbba28f`。

**规则**：仅此时跳过本地复现，改用 run 日志与页面作为证据。「老」不是判据——重写之后的 SHA
（含本窗口的全部提交）在本地完全可解析，照常 `git show`/`git diff`。

**证据**：2026-08 前后的 run 引用的 SHA 在本地 `git show` 与 GitHub 对象 API 双双报不可解析，
而本地同期历史存在（同一时间窗、不同 SHA）；重写记录见 `STATUS.md` 与待办 8。

### R11 ReleaseState 翻转或文档改写必须同提交适配全部 pin（含未被 policy-aware 化的套件）

**判据**：shard 作业成片红（可三 shard 同时）而 gates 作业绿；失败断言集中在
`canonical-apply-interlocked` / `canonical-recovery-apply-interlocked` /
`safety-protocol-upgrade-required` / `Code -eq 75` 一类 interlock 行为 pin，或
repository-policy 的文档字符串 pin；红灯首次出现在 policy 翻转提交或其后的文档提交之后。

**根因（首次 shard 运行的实例）**：`bffa7d7` 翻转 `ReleaseState` 前只验证了四个 policy-aware
套件（`15deede` 覆盖 automation-safety、backup-recovery、live-recovery、repository-policy）；
其余套件中还有 9 个持有未被 policy-aware 化的 interlock 行为 pin（approved-runner、
canonical-command-result、canonical-recovery、canonical-transaction、doctor、harness-authority、
harness-env、skills-import、task-skills），翻转后从未在 released 树上跑过；`67bfdc6` 的
文档集中化又改写了 AGENTS.md/README.md 中的 interlock 段落，打破 repository-policy 的文档
pin。CI 首两次 shard 运行（#129、#130）三 shard 全红，gates 作业两次全绿。

**规则**：

- 改 `scripts/live-safety-policy.psd1` 的提交，提交前必须对 `tests/` 静态筛查全部
  interlock token 引用（`safety-protocol-upgrade-required`、`canonical-apply-interlocked`、
  `canonical-recovery-apply-interlocked`、`ReleaseState`），确认每处要么已 policy-aware、
  要么确与 policy 无关；并在翻转树上全量跑（`-All` 或三分片），不是只跑 focused 套件。
- 改 AGENTS.md/README.md/CLAUDE.md 被断言语句的提交，同步检查 repository-policy 的文档 pin
  （R9 的文档形态）。
- released 分支 pin 的是观察契约：精确 exit code + 精确 token + 结果文档结构（`Result` /
  `MessageToken` / `LifecycleKind` / `PlanHash` 绑定），不得放宽为任意非零退出；
  interlocked 分支 byte-for-byte 保留原有 fail-closed pin。
- **gate 本身环境敏感时（owner/DACL、真实 home 状态），released 分支改 pin 环境无关的结构
  契约**（非零退出 + 未产生 plan/claims 等可核对的零写入状态），并在注释里写明 token 为何
  不可跨环境 pin。已证实的两种环境依赖：gate 链在提权 CI runner 与普通用户机上停在不同的
  拒绝面（`home-authority-bootstrap-manual-recovery-required` vs 后续 gate）；无 internal
  capability 的 sync DryRun 在有 live roots 的机器上停在 `live-plan-selection-mismatch`、
  在全新 CI home 上继续更远。环境无关的 pin 只对**该断言的 fail-closed 语义**成立，不得借它
  跳过精确契约的观察。
- 观察到的 released 契约随 surface 而异，必须逐处观察后 pin，不得从另一 surface 类推：
  实例中 setup/normalize Apply 在未完成 bootstrap 的 fixture 上 fail-closed 于
  `manual-recovery-required` 或 `canonical-setup-required`（exit 1），而 recover-abandon
  Apply 在 released 下直接完成评审过的 abandon（exit 0，`canonical-recovery-applied`，
  `no-transaction`，ControlBase 零写入）。

**证据**（runs #129 `35448682368`（`eeedc46`）、#130 `35521668044`（`67bfdc6`）、
#131 `35606400281`（`cef82f9`）与本地 67bfdc6 worktree 复现一致）：三 shard 全红、gates 绿；
本地逐套件复现锁定上述 9 个套件 + repository-policy 文档 pin，修复随本窗口
（policy-aware 分支 + 文档 pin 对齐）。

### R11 补充核定：released public sync 的成功路径（2026-09-23）

固定 run `35733693990` attempt 1、head `51044a55` 的完整日志为 42 套件、40 passed、
2 failed、0 timed-out。gates 与 shard 1 通过；shard 2 的 root-claims 子进程命中内部
15 秒期限，shard 3 的 sync 在 `Code -ne 0` 断言失败。这不是两个 suite timeout，
也不是历史 run `34851206631` 的失败复发。

本轮隔离复现更正 R11 上述“无 capability 的 sync 总是非零且零 plan”的归纳：
released public resolver 在有效、pristine 的身份上可以合法产出 schema 3 plan 并返回 0。
测试必须在复制工具链中仅替换 OS 身份/默认路径适配器，使用虚拟 home 并清除真实继承的
internal capability，分别校验该成功路径的对象、摘要、fake-home 绑定和无 live 写入，
以及缺 known-folder 的精确拒绝和零 plan；不能依赖操作者 home 恰好触发后续拒绝。
interlocked 的精确拒绝契约仍然保留，生产 resolver、Policy 与门禁均不修改。

root-claims 的原日志没有保留下被杀子进程的 stdout/stderr；不能把后来发现的夹具身份
错配直接当作这次 15 秒失败的已证原因。应保留超时现场输出，并在固定候选完整 CI
重新观察 released 路径。当前本机测试 token 在既有 fixture 的 SetOwner 操作被拒绝，
仅修改 DACL 的独立探针则通过；这是完整本地套件的宿主前提限制，不是 GREEN。
完整定位与回执见 [2026-09-23 CI 修复窗口](../status/active/live-safety-hardening.md)。

## 3. 处置流程

**按失败步骤名分流**，不要对所有红灯套同一套动作：

1. 取失败步骤名（`.../runs/<id>/jobs`）。
2. **无失败步骤 + runner 失联** → R1（同 SHA 重跑，不改代码）。
3. **`Scan for secrets`** → R8；**`Run repository doctor`** → R6；
   **`Validate machine-readable schemas and build evidence`** → R5；
   **`Run every root regression suite exactly once`** → 先读该步日志的 `Test summary:` 行：
   `failed=0; timed-out>0` 走 R2，`ReadAllText ... being used by another process` 走 R3，
   否则是真实断言失败（第 5 步）。
4. **表外步骤**（JSON artifacts、syntax、build clean、dangerous files 等）→ 读该步自己的日志定位，
   不要把 R1–R3 套上去。
5. 有真实断言失败时，按日志给出的 `tests/<套件>.ps1:<行号>` 定位断言再改代码或夹具；改动落在
   `tests/`（尤其新增/加重套件）时按 R2 重估预算、按 R5 核对同提交的契约断言。
6. 本地验证走仓库既有入口：`git diff --check`、`scripts/scan-secrets.ps1`、
   `scripts/check-powershell-syntax.ps1`；涉及套件预算时加 `tests/test-runner.tests.ps1`；
   需要全量时 `scripts/run-tests.ps1 -All -JsonSummaryPath <外部临时路径>`。**本地通过不能替代 CI。**

## 4. 未决项

- ~~**聚合预算已越过平台作业上限**（R2）~~ **已收口（2026-09-19，所有者裁决拆分测试矩阵）**：
  工作流改为 `validate-gates` + `validate-tests-1..3` 三路 shard（静态分区 `tests/test-shards.psd1`），
  42 套件的已证预算 30555 秒（509.25 分钟；2026-09-19 拆分时为 27555 秒）被拆进三个并行作业，
  每个作业的合同秒数（shard 预算 + 300 + 120）分别为 8700/10200/12495 秒
  （145/170/208.25 分钟），对应声明 `timeout-minutes` 170/185/235，全部低于 360 分钟平台上限。
  现行规则见 R2。
- ~~**2026-09-19 起 shard 工作流尚无一次真实 CI 运行样本**~~ **已有样本（2026-09-19/21）**：
  #128（`68e9903`）是旧单作业结构的最后一次运行，success——顺带关闭了 R3 的 e0bb9d7 复发项
  （harness-authority 在含修复的树上不再复发）。#129（`eeedc46`）、#130（`67bfdc6`）与
  #131（`cef82f9`）是 shard 结构的前三次运行，三个 shard 作业全红、gates 作业三次全绿
  （#131 的树已含 harness-env 双 policy 修复，其余八个套件仍待修）：shard 路径本身（分区、
  fail-closed、超时合同）无缺陷，红灯全部是 R11 的 released pin 漂移。per-shard 失败分布
  从此按本文件第 1 节的 shard 作业名（`Validate test shard N of 3`）取数。
- **run `34851206631` 已更正归因（2026-09-22）**：`Task skill dry-run failed (exit 1)`
  是预期拒绝路径的输出，`task-skills` 实际为 22 passed / 0 failed，`automation-safety` 也通过。
  原始日志汇总为 39 套件、36 passed、1 failed、2 timed-out：唯一失败是 `canonical-hard-kill`
  加载时的 reviewed-load hash 不匹配；两项超时分别为 `harness-authority` 300 秒和
  `harness-env` 180 秒。受检提交 `45e9a50` 沿用了 `8e27e4a` 的脚本字节和旧 pin；
  `b86b8b1` 更新 pin，`06d1902` 记载后续本地 318/0，**不等于该 CI run 重跑通过**。
  原始日志、Git 字节核对及对旧记录的追加更正见
  [归因更正记录](../status/active/live-safety-hardening.md#2026-09-22-ci-run-34851206631-attribution-correction)。
- 2026-09-17 两次 runner 失联中，`35166789288`（`0c5ca92`）已由第三次尝试转绿关闭
  （2026-09-19 记录）；`35166625038`（`6488182`）仍无同 SHA 重跑样本。
- 早期 `Run MCP tests` 步骤已随 MCP 工具退休从工作流移除，其历史失败不再适用（不是未决）。

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
| `34415557457` | 2026-09-09 | 测试矩阵 | 四套件在 runner 上恰好打满旧预算 | R2 | `881047a`、`5e99c07` |
| `34670776794` … `34677219278` | 2026-09-12 | 测试矩阵 | 负例计数断言漂移 + 夹具 PID 竞争 | R9、R3 | 已修 |
| `34770673201` `34771649051` | 2026-09-13 | 测试矩阵 | production-seams 反射清单/摘要未重钉；live-recovery 超时 | — | 随该窗口修复 |
| `34788238413` `34909047517` | 2026-09-13~09-14 | 测试矩阵 | harness-* / task-skills 超时（沿用原记录，本次未重核） | R2、未决 | `fa53b7c` 等；本次不变更处置 |
| `34851206631` | 2026-09-14 | 测试矩阵 | canonical-hard-kill reviewed-load hash 不匹配；harness-authority 300 秒、harness-env 180 秒超时；task-skills / automation-safety 通过 | R2、加载摘要校验 | `b86b8b1` 更新 pin；`06d1902` 记载后续本地 318/0；原失败 CI 保留，见上述归因更正 |
| `34957472014` `34991068832` `35086695635` | 2026-09-15~09-16 | 测试矩阵 | automation-safety 恰好 120.0 秒被杀；`34991068832`/`35086695635` 另有 killed 进程夹具共享冲突 | R2、R3 | `6db9760`（预算）/ 共享冲突待同 SHA 复核 |
| `35097541381` | 2026-09-16 | — | 绿（40 套件，automation-safety 112.6 秒） | — | 参考基线 |
| `35166625038` `35166789288` | 2026-09-17 | 无 | hosted runner 失联 | R1 | `35166789288` 已转绿；`35166625038` 待同 SHA 重跑 |
| `128`（`68e9903`，旧单作业结构收官） | 2026-09-19 | 无 | 绿（含 R3 修复树） | — | R3 复发项关闭 |
| `129` `35448682368`（`eeedc46`）<br>`130` `35521668044`（`67bfdc6`）<br>`131` `35606400281`（`cef82f9`） | 2026-09-19/21 | 三个 shard 作业（gates 三次绿） | released 树上 9 个未 policy-aware 套件的 interlock 行为 pin + repository-policy 文档 pin 漂移 | R11 | 随本窗口修复 |

窗口数据由三路独立复算核对（2026-09-17）：run/step/annotation 计数与 22 次超时的套件分布均一致；
唯一被判「不可独立核验」的是 R2 证据里那组本地实测秒数，现已标注来源。
