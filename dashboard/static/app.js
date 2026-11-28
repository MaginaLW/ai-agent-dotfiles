"use strict";

const byId = id => document.getElementById(id);
const csrfToken = (() => {
  const meta = document.querySelector('meta[name="dashboard-token"]');
  return meta ? (meta.getAttribute("content") || "") : "";
})();

const state = {
  autoRefresh: true,
  pollTimer: null,
  jobPollTimer: null,
  overview: null,
  syncStatus: null,
  github: null,
  testSuites: null,
  jobs: [],
  jobDetails: new Map(),
  openDiffs: new Map(),
  openJobLogs: new Set(),
  closedJobLogs: new Set(),
  sectionFingerprints: new Map(),
  activeJobId: null,
  currentPreviewJob: null,
  skillFilter: "all",
  skillSearch: "",
  toastTimer: null,
  lastHandledPreviewJobId: null
};

const TARGET_LABELS = {
  "codex-env": "Codex 完整同步",
  "codex-skills": "Codex 仅技能同步",
  "antigravity-config": "Antigravity 全局规则同步",
  "antigravity-plugin": "Antigravity 插件部署",
  "mcp": "受管 MCP 同步"
};

function el(tag, text, className) {
  const node = document.createElement(tag);
  if (text != null) node.textContent = String(text);
  if (className) node.className = className;
  return node;
}

function shouldRenderSection(sectionKey, fingerprintInput) {
  const next = JSON.stringify(fingerprintInput);
  if (state.sectionFingerprints.get(sectionKey) === next) {
    return false;
  }
  state.sectionFingerprints.set(sectionKey, next);
  return true;
}

function safeHref(rawUrl) {
  if (!rawUrl || typeof rawUrl !== "string") return null;
  try {
    const u = new URL(rawUrl, window.location.origin);
    if (u.protocol === "http:" || u.protocol === "https:") return u.href;
  } catch {
    return null;
  }
  return null;
}

function externalLink(label, rawUrl, className) {
  const href = safeHref(rawUrl);
  if (!href) return el("span", label, "muted");
  const a = el("a", label, className);
  a.href = href;
  a.target = "_blank";
  a.rel = "noopener noreferrer";
  return a;
}

function showToast(msg) {
  const t = byId("toast");
  t.textContent = msg;
  t.classList.add("show");
  if (state.toastTimer) clearTimeout(state.toastTimer);
  state.toastTimer = setTimeout(() => t.classList.remove("show"), 2600);
}

async function copyText(text, toastMsg) {
  const content = String(text || "");
  if (!content) {
    showToast("没有可复制的内容");
    return;
  }
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(content);
      showToast(toastMsg || "已复制，可直接粘贴给 AI");
      return;
    }
  } catch {
    // Fallback below.
  }
  try {
    const area = document.createElement("textarea");
    area.value = content;
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.focus();
    area.select();
    const ok = document.execCommand("copy");
    document.body.removeChild(area);
    if (ok) {
      showToast(toastMsg || "已复制，可直接粘贴给 AI");
      return;
    }
  } catch {
    // Ignored.
  }
  showToast("浏览器未允许剪贴板访问，请手动复制");
}

function formatTime(iso) {
  if (!iso) return "--";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso);
  return d.toLocaleString("zh-CN", { hour12: false });
}

function levelClass(level) {
  if (level === "ok" || level === "success" || level === "succeeded" || level === "PASS") return "ok";
  if (level === "error" || level === "fail" || level === "failed" || level === "FAIL") return "error";
  if (level === "warn" || level === "WARN" || level === "cancelled") return "warn";
  return "info";
}

function levelBadge(level, text) {
  return el("span", text, "badge " + levelClass(level));
}

async function apiGet(path) {
  const res = await fetch(path, { cache: "no-store" });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(data.error || data.message_zh || ("HTTP " + res.status));
  }
  return data;
}

async function apiPost(path, payload) {
  const res = await fetch(path, {
    method: "POST",
    cache: "no-store",
    headers: {
      "Content-Type": "application/json",
      "X-Dashboard-Token": csrfToken
    },
    body: JSON.stringify(payload || {})
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(data.error || data.message_zh || ("HTTP " + res.status));
  }
  return data;
}

function setConnectionState(ok, message) {
  const dot = byId("connDot");
  const text = byId("connText");
  dot.className = "dot " + (ok ? "ok" : "error");
  text.textContent = message;
}

function isJobBusy() {
  return Boolean(state.activeJobId || (state.overview && state.overview.active_job));
}

function updateActionDisabledState() {
  const busy = isJobBusy();
  for (const btn of document.querySelectorAll(".js-action-btn, .js-preview-btn")) {
    btn.disabled = busy;
  }
  const active = (state.overview && state.overview.active_job) || state.jobs.find(j => j.status === "running");
  const pill = byId("runningJobPill");
  if (active && active.status === "running") {
    pill.style.display = "inline-flex";
    pill.textContent = "执行中：" + (active.label_zh || active.kind || active.id);
    byId("actionLockNote").textContent = "当前已有任务正在执行，其余检查与同步按钮已临时锁定";
  } else {
    pill.style.display = "none";
    byId("actionLockNote").textContent = "所有写操作均强制“先预览 → 二次确认 → 再执行”";
  }
  syncApplyButtonState();
}

function syncApplyButtonState() {
  const btn = byId("applyPreviewBtn");
  const cb = byId("previewConfirmCheckbox");
  const preview = state.currentPreviewJob && state.currentPreviewJob.preview;
  const canApply = Boolean(preview && preview.can_apply === true && cb.checked && !isJobBusy());
  btn.disabled = !canApply;
}

function renderHeaderAndKpis() {
  const ov = state.overview;
  if (!ov) return;
  const repo = ov.repo || {};
  const branchText = (repo.branch || "未知分支") + (repo.head_short ? (" @ " + repo.head_short) : "");
  byId("branchBadge").textContent = branchText;
  byId("headSubject").textContent = repo.head_subject ? ("最近提交：" + repo.head_subject) : "仓库已连接";
  byId("lastUpdatedLabel").textContent = "概览更新：" + formatTime(ov.generated_at);
  byId("repoMeta").textContent = (repo.name || "ai-agent-dotfiles") + " · " + branchText;

  const upBadge = byId("upstreamBadge");
  if (repo.upstream) {
    upBadge.style.display = "inline-flex";
    const ahead = Number(repo.ahead || 0);
    const behind = Number(repo.behind || 0);
    upBadge.textContent = repo.upstream + " (领先 " + ahead + " / 落后 " + behind + ")";
    upBadge.className = "badge " + (behind > 0 ? "warn" : (ahead > 0 ? "info" : "ok"));
  } else {
    upBadge.style.display = "none";
  }

  // KPI 1: Sync Status
  const kpiSync = byId("kpiSync");
  const sync = state.syncStatus;
  if (!sync) {
    kpiSync.className = "kpi-card";
    byId("kpiSyncBadge").className = "badge";
    byId("kpiSyncBadge").textContent = "查询中";
    byId("kpiSyncValue").textContent = "待读取";
    byId("kpiSyncSub").textContent = "正在查询双端同步状态…";
  } else {
    const lvl = sync.summary_level || (sync.ok ? "ok" : "error");
    kpiSync.className = "kpi-card level-" + (lvl === "ok" ? "ok" : (lvl === "warn" ? "warn" : "error"));
    byId("kpiSyncBadge").className = "badge " + levelClass(lvl);
    byId("kpiSyncBadge").textContent = lvl === "ok" ? "已对齐" : (lvl === "warn" ? "存在差异" : "异常");
    const envName = (sync.environment && (sync.environment.recorded || sync.environment.Recorded)) || "未记录";
    const skillsInfo = sync.skills;
    let kpiVal = "Codex 环境: " + envName;
    if (skillsInfo && skillsInfo.state === "checked" && skillsInfo.summary) {
      const unch = Number(skillsInfo.summary.unchanged || 0);
      const total = unch + Number(skillsInfo.summary.install || 0) + Number(skillsInfo.summary.update || 0);
      const pending = Number(skillsInfo.pending_count || 0);
      kpiVal = envName + " · " + unch + "/" + total + (pending > 0 ? " 待同步" : " 一致");
    } else if (skillsInfo && skillsInfo.state === "build-required") {
      kpiVal = envName + " · 需先构建";
    }
    byId("kpiSyncValue").textContent = kpiVal;
    byId("kpiSyncSub").textContent = sync.summary_zh || sync.error || "已获取本机双端状态";
  }

  // KPI 2: Workspace Dirty
  const kpiDirty = byId("kpiDirty");
  const totalChanges = Number(repo.total_changes || 0);
  const dirtyLvl = totalChanges === 0 ? "ok" : "warn";
  kpiDirty.className = "kpi-card level-" + dirtyLvl;
  byId("kpiDirtyBadge").className = "badge " + dirtyLvl;
  byId("kpiDirtyBadge").textContent = totalChanges === 0 ? "工作区干净" : "有未提交改动";
  byId("kpiDirtyValue").textContent = totalChanges === 0 ? "0 处改动" : (totalChanges + " 个文件改动");
  const catSummary = (repo.categories || []).slice(0, 3).map(c => c.label + "(" + c.count + ")").join("、");
  byId("kpiDirtySub").textContent = catSummary || "无未提交文件";

  // KPI 3: GitHub CI
  const kpiCi = byId("kpiCi");
  const gh = state.github;
  if (!gh) {
    kpiCi.className = "kpi-card";
    byId("kpiCiBadge").className = "badge";
    byId("kpiCiBadge").textContent = "查询中";
    byId("kpiCiValue").textContent = "--";
    byId("kpiCiSub").textContent = "等待查询 GitHub…";
  } else if (gh.offline || !gh.available) {
    kpiCi.className = "kpi-card level-warn";
    byId("kpiCiBadge").className = "badge warn";
    byId("kpiCiBadge").textContent = "离线";
    byId("kpiCiValue").textContent = "仅本地模式";
    byId("kpiCiSub").textContent = gh.message_zh || "当前离线或无法连接 GitHub（不影响本地监控）";
  } else {
    const runs = gh.ci_runs || [];
    const prs = gh.open_prs || [];
    const latest = runs[0];
    let ciLvl = "ok";
    let ciBadgeText = "正常";
    let ciVal = "暂无 CI 记录";
    if (latest) {
      const concl = latest.conclusion || latest.status || "";
      if (concl === "failure" || concl === "cancelled" || concl === "timed_out") {
        ciLvl = "error";
        ciBadgeText = "CI 失败";
      } else if (latest.status !== "completed") {
        ciLvl = "warn";
        ciBadgeText = "CI 运行中";
      } else {
        ciLvl = "ok";
        ciBadgeText = "CI 通过";
      }
      ciVal = (latest.workflowName || "Validate") + " · " + (latest.conclusion || latest.status || "未知");
    }
    kpiCi.className = "kpi-card level-" + ciLvl;
    byId("kpiCiBadge").className = "badge " + ciLvl;
    byId("kpiCiBadge").textContent = ciBadgeText;
    byId("kpiCiValue").textContent = ciVal;
    byId("kpiCiSub").textContent = "开放 PR " + prs.length + " 个 · 最近运行 " + runs.length + " 次";
  }

  // KPI 4: Swarm Boards
  const kpiSwarm = byId("kpiSwarm");
  const boards = (ov.swarm && ov.swarm.boards) || [];
  const runningBoards = boards.filter(b => b.running);
  kpiSwarm.className = "kpi-card" + (runningBoards.length > 0 ? " level-ok" : "");
  byId("kpiSwarmBadge").className = "badge " + (runningBoards.length > 0 ? "ok" : "info");
  byId("kpiSwarmBadge").textContent = runningBoards.length > 0 ? "运行中" : "空闲";
  byId("kpiSwarmValue").textContent = runningBoards.length + " 个运行中 / 共 " + boards.length + " 个";
  byId("kpiSwarmSub").textContent = runningBoards.length > 0
    ? ("活跃任务：" + (runningBoards[0].run || "协作看板"))
    : "可在下方手动探测 manifest.json";
}

function renderAttention() {
  const ov = state.overview;
  const items = [];
  if (ov && Array.isArray(ov.attention)) items.push(...ov.attention);
  if (state.syncStatus && Array.isArray(state.syncStatus.attention)) {
    for (const sItem of state.syncStatus.attention) {
      if (!items.some(x => x.title === sItem.title && x.detail === sItem.detail)) {
        items.push(sItem);
      }
    }
  }
  const envTarget = byId("syncEnvSelect") ? byId("syncEnvSelect").value : "work";
  if (!shouldRenderSection("attention", { items, envTarget })) return;

  const list = byId("attentionList");
  list.replaceChildren();
  byId("attentionCount").textContent = items.length + " 项";
  if (!items.length) {
    const empty = el("div", null, "attention-card level-ok");
    const body = el("div", null, "attention-body");
    body.append(el("strong", "当前没有需要立即处理的事项"), el("small", "仓库、同步与服务检查均处于正常状态。"));
    empty.append(body);
    list.append(empty);
    return;
  }
  for (const item of items) {
    const lvl = item.level || "warn";
    const card = el("div", null, "attention-card level-" + (lvl === "error" ? "error" : (lvl === "ok" ? "ok" : "warn")));
    const body = el("div", null, "attention-body");
    const titleRow = el("div", null, "row");
    titleRow.append(levelBadge(lvl, lvl === "error" ? "需处理" : (lvl === "ok" ? "正常" : "提醒")), el("strong", item.title || "待关注事项"));
    body.append(titleRow);
    if (item.detail) body.append(el("small", item.detail));
    card.append(body);

    const actions = el("div", null, "row");
    if (item.action_type === "doctor") {
      const btn = el("button", item.action_label || "运行健康体检", "sm primary js-action-btn");
      btn.dataset.action = "doctor";
      btn.onclick = () => triggerAction("doctor");
      actions.append(btn);
    } else if (item.action_type === "preview") {
      const btn = el("button", item.action_label || "去预览同步", "sm primary");
      btn.onclick = () => {
        if (item.target) {
          triggerPreview(item.target, item.environment || byId("syncEnvSelect").value);
        } else {
          byId("sec-actions").scrollIntoView({ behavior: "smooth" });
        }
      };
      actions.append(btn);
    }
    if (item.ai_prompt) {
      const copyBtn = el("button", "复制指令给 AI", "sm");
      copyBtn.onclick = () => copyText(item.ai_prompt, "已复制，可直接粘贴给 AI");
      actions.append(copyBtn);
    }
    if (actions.childNodes.length) card.append(actions);
    list.append(card);
  }
  updateActionDisabledState();
}

function renderDiffContent(container, diffText, truncated) {
  container.replaceChildren();
  if (!diffText) {
    container.append(el("span", "（暂无可显示的文本差异）", "muted"));
    return;
  }
  const lines = diffText.split(/\r?\n/);
  for (const line of lines) {
    let cls = "diff-line";
    if (line.startsWith("+") && !line.startsWith("+++")) cls += " diff-add";
    else if (line.startsWith("-") && !line.startsWith("---")) cls += " diff-del";
    else if (line.startsWith("@@")) cls += " diff-hunk";
    container.append(el("span", line, cls));
  }
  if (truncated) {
    container.append(el("small", "（内容过长，已截断，仅展示部分预览）", "muted"));
  }
}

async function toggleFileDiff(filePath, boxEl, btnEl) {
  if (state.openDiffs.has(filePath)) {
    state.openDiffs.delete(filePath);
    state.sectionFingerprints.delete("workspaceChanges");
    boxEl.style.display = "none";
    btnEl.setAttribute("aria-expanded", "false");
    return;
  }
  btnEl.setAttribute("aria-expanded", "true");
  boxEl.style.display = "block";
  boxEl.replaceChildren(el("span", "正在加载差异…", "muted"));
  try {
    const data = await apiGet("/api/diff?path=" + encodeURIComponent(filePath));
    state.openDiffs.set(filePath, data);
    state.sectionFingerprints.delete("workspaceChanges");
    renderDiffContent(boxEl, data.diff, data.truncated);
  } catch (err) {
    boxEl.replaceChildren(el("span", "读取差异失败：" + err.message, "muted"));
  }
}

function buildWorkspaceAiPrompt(mode) {
  const repo = (state.overview && state.overview.repo) || {};
  const cats = repo.categories || [];
  const total = Number(repo.total_changes || 0);
  const lines = cats.map(c => "- " + c.label + " (" + c.count + "): " + (c.files || []).map(f => f.path + " [" + (f.status_zh || f.code) + "]").join(", "));
  if (mode === "explain") {
    return "请检查当前仓库分支 `" + (repo.branch || "HEAD") + "` 的工作区改动（共 " + total + " 个文件），用中文向我逐项解释改动目的与影响：\n" + (lines.join("\n") || "（当前工作区干净）");
  }
  return "请复核当前仓库分支 `" + (repo.branch || "HEAD") + "` 的工作区改动（共 " + total + " 个文件），运行必要检查后按规范给出提交建议或帮我提交：\n" + (lines.join("\n") || "（当前工作区干净）");
}

function renderWorkspaceChanges() {
  const repo = (state.overview && state.overview.repo) || {};
  const total = Number(repo.total_changes || 0);
  const cats = repo.categories || [];
  if (!shouldRenderSection("workspaceChanges", {
    total,
    cats,
    openKeys: Array.from(state.openDiffs.keys()).sort()
  })) return;

  const badge = byId("changesBadge");
  badge.textContent = total + " 处";
  badge.className = "badge " + (total === 0 ? "ok" : "warn");

  byId("copyExplainDiffBtn").disabled = total === 0;
  byId("copyReviewCommitBtn").disabled = total === 0;

  const container = byId("changesContainer");
  container.replaceChildren();
  if (!cats.length || total === 0) {
    container.append(el("div", "当前工作区干净，没有未提交改动。", "notice ok"));
    return;
  }
  for (const cat of cats) {
    if (!cat.files || !cat.files.length) continue;
    const group = el("div", null, "cat-group");
    const header = el("div", null, "cat-header");
    header.append(el("span", cat.label || cat.id), el("span", (cat.count ?? cat.files.length) + " 个", "badge"));
    group.append(header);

    for (const file of cat.files) {
      const row = el("div", null, "file-row");
      const btn = el("button", null, "file-btn");
      btn.type = "button";
      const isOpen = state.openDiffs.has(file.path);
      btn.setAttribute("aria-expanded", String(isOpen));
      btn.append(el("span", file.path, "file-path"), el("span", file.status_zh || file.code || "改动", "badge"));

      const diffBox = el("div", null, "diff-box");
      diffBox.style.display = isOpen ? "block" : "none";
      if (isOpen) {
        const cached = state.openDiffs.get(file.path);
        renderDiffContent(diffBox, cached.diff, cached.truncated);
      }
      btn.onclick = () => toggleFileDiff(file.path, diffBox, btn);
      row.append(btn, diffBox);
      group.append(row);
    }
    container.append(group);
  }
}

function renderStatusTasks() {
  const doc = (state.overview && state.overview.status_doc) || {};
  if (!shouldRenderSection("statusTasks", doc)) return;

  byId("statusDocDate").textContent = doc.last_updated ? ("STATUS.md 更新于 " + doc.last_updated) : "";
  const container = byId("statusTasksContainer");
  container.replaceChildren();

  const activeTasks = doc.active_tasks || [];
  const openItems = doc.open_items || [];
  if (!activeTasks.length && !openItems.length) {
    container.append(el("p", "暂无记录中的进行中任务或待办项。", "muted"));
    return;
  }
  for (const task of activeTasks) {
    const card = el("div", null, "item-card");
    const top = el("div", null, "bar");
    top.append(el("strong", task.title || task.file), el("span", "进行中", "badge info"));
    card.append(top);
    if (task.file) card.append(el("small", task.file, "mono"));
    if (task.excerpt) card.append(el("small", task.excerpt));
    container.append(card);
  }
  for (const item of openItems) {
    const card = el("div", null, "item-card");
    const top = el("div", null, "bar");
    top.append(el("strong", item.title || "待办事项"), el("span", "待办 / 延后", "badge warn"));
    card.append(top);
    if (item.summary) card.append(el("small", item.summary));
    container.append(card);
  }
}

function renderCommitsAndGithub() {
  const repo = (state.overview && state.overview.repo) || {};
  const commits = repo.recent_commits || [];
  const gh = state.github;
  if (!shouldRenderSection("commitsGithub", { commits, gh })) return;

  const commitsBox = byId("recentCommitsContainer");
  commitsBox.replaceChildren();
  if (!commits.length) {
    commitsBox.append(el("p", "暂无最近提交记录。", "muted"));
  } else {
    for (const c of commits) {
      const card = el("div", null, "item-card");
      const top = el("div", null, "bar");
      top.append(el("span", c.hash || "", "badge mono"), el("small", c.relative || c.date || ""));
      card.append(top, el("span", c.subject || ""));
      commitsBox.append(card);
    }
  }

  const noticeBox = byId("githubStatusNotice");
  const prBox = byId("githubPrContainer");
  const ciBox = byId("githubCiContainer");
  noticeBox.replaceChildren();
  prBox.replaceChildren();
  ciBox.replaceChildren();

  if (!gh) {
    noticeBox.append(el("div", "正在加载 GitHub PR 与 CI 状态…", "notice"));
    return;
  }
  if (gh.offline || !gh.available) {
    noticeBox.append(el("div", gh.message_zh || "当前离线或无法连接 GitHub（不影响本地监控）", "notice warn"));
    return;
  }

  const prs = gh.open_prs || [];
  prBox.append(el("strong", "开放 Pull Requests (" + prs.length + ")", ""));
  if (!prs.length) {
    prBox.append(el("small", "当前没有开放中的 PR。", "muted"));
  } else {
    for (const pr of prs) {
      const card = el("div", null, "item-card");
      const top = el("div", null, "bar");
      top.append(externalLink("#" + pr.number + " " + (pr.title || ""), pr.url), el("span", pr.headRefName || "", "badge mono"));
      card.append(top);
      if (pr.updatedAt) card.append(el("small", "更新：" + formatTime(pr.updatedAt)));
      prBox.append(card);
    }
  }

  const runs = gh.ci_runs || [];
  ciBox.append(el("strong", "近期 CI 运行 (" + runs.length + ")", ""));
  if (!runs.length) {
    ciBox.append(el("small", "暂无近期 GitHub Actions 记录。", "muted"));
  } else {
    for (const run of runs) {
      const card = el("div", null, "item-card");
      const top = el("div", null, "bar");
      const stateStr = run.conclusion || run.status || "unknown";
      const lvl = stateStr === "success" ? "ok" : ((stateStr === "failure" || stateStr === "cancelled" || stateStr === "timed_out") ? "error" : "warn");
      top.append(externalLink((run.workflowName || "Workflow") + " · " + (run.displayTitle || ("#" + run.databaseId)), run.url), levelBadge(lvl, stateStr));
      card.append(top, el("small", (run.headBranch || "") + (run.createdAt ? (" · " + formatTime(run.createdAt)) : "")));
      ciBox.append(card);
    }
  }
}

function renderSwarmBoards() {
  const boards = (state.overview && state.overview.swarm && state.overview.swarm.boards) || [];
  if (!shouldRenderSection("swarmBoards", boards)) return;

  byId("swarmCountBadge").textContent = boards.length + " 个";
  const container = byId("swarmBoardsContainer");
  container.replaceChildren();
  if (!boards.length) {
    container.append(el("p", "暂未发现本地 Swarm / Teamwork 协作看板。可输入 manifest.json 路径手动探测。", "muted"));
    return;
  }
  for (const b of boards) {
    const card = el("div", null, "item-card");
    const top = el("div", null, "bar");
    top.append(el("strong", b.run || "未命名协作看板"), levelBadge(b.running ? "ok" : "warn", b.running ? "运行中" : "已停止"));
    card.append(top);
    if (b.manifest_path_display) card.append(el("small", b.manifest_path_display, "mono"));
    const stats = "事件 " + Number(b.event_count || 0) + " · 页面访问 " + Number(b.ui_gets || 0) + " · 状态轮询 " + Number(b.state_polls || 0);
    const bottom = el("div", null, "bar");
    bottom.append(el("small", stats));
    if (b.url) {
      const link = externalLink("打开协作看板", b.url, "badge info");
      bottom.append(link);
    }
    card.append(bottom);
    container.append(card);
  }
}

function renderSyncAssetCard(title, badgeText, badgeLvl, lines) {
  const card = el("div", null, "subpanel stack");
  card.style.gap = "8px";
  const top = el("div", null, "bar");
  top.append(el("h3", title), levelBadge(badgeLvl, badgeText));
  card.append(top);
  const body = el("div", null, "stack");
  body.style.gap = "4px";
  for (const line of lines) {
    body.append(el("small", line));
  }
  card.append(body);
  return card;
}

function normalizeItems(obj, keys) {
  if (!obj) return [];
  if (Array.isArray(obj)) return obj;
  for (const k of keys) {
    if (Array.isArray(obj[k])) return obj[k];
  }
  return [];
}

function renderSyncSection() {
  const sync = state.syncStatus;
  if (!shouldRenderSection("syncSection", sync)) return;

  const grid = byId("syncCardsGrid");
  grid.replaceChildren();
  const note = byId("syncSummaryNote");

  if (!sync) {
    byId("syncSummaryBadge").className = "badge";
    byId("syncSummaryBadge").textContent = "加载中";
    byId("rawSyncJson").textContent = "正在加载双端状态…";
    return;
  }

  const lvl = sync.summary_level || (sync.ok ? "ok" : "error");
  byId("syncSummaryBadge").className = "badge " + levelClass(lvl);
  byId("syncSummaryBadge").textContent = lvl === "ok" ? "正常" : (lvl === "warn" ? "需关注" : "异常");
  byId("syncFetchedAt").textContent = sync.fetched_at ? ("采集于 " + formatTime(sync.fetched_at)) : "";

  if (sync.summary_zh || sync.error) {
    note.style.display = "block";
    note.className = "notice " + (lvl === "ok" ? "ok" : (lvl === "warn" ? "warn" : "error"));
    note.textContent = sync.summary_zh || sync.error;
  } else {
    note.style.display = "none";
  }

  // Card 1: Codex environment & live skills consistency
  const env = sync.environment || {};
  const recorded = env.recorded || env.Recorded || "未记录";
  const avail = Array.isArray(env.available || env.Available) ? (env.available || env.Available).join(" / ") : "work / full / minimal";
  const envFailed = Boolean(env.failed || env.Failed || env.error || env.Error);
  const skillsInfo = sync.skills;
  let card1Badge = envFailed ? "异常" : recorded;
  let card1Lvl = envFailed ? "error" : (recorded === "未记录" ? "warn" : "ok");
  const envLines = [
    "已记录环境：" + recorded,
    "可选环境：" + avail
  ];
  if (skillsInfo) {
    const skState = skillsInfo.state || "unavailable";
    if (skState === "error") {
      card1Badge = "异常";
      card1Lvl = "error";
    } else if (skState === "build-required") {
      card1Badge = "需先构建";
      card1Lvl = "warn";
    } else if (skState === "checked" && skillsInfo.summary) {
      const unch = Number(skillsInfo.summary.unchanged || 0);
      const total = unch + Number(skillsInfo.summary.install || 0) + Number(skillsInfo.summary.update || 0);
      const pending = Number(skillsInfo.pending_count || 0);
      if (pending > 0) {
        card1Badge = "待同步";
        card1Lvl = "warn";
      } else {
        card1Badge = unch + "/" + total + " 一致";
        card1Lvl = envFailed ? "error" : "ok";
      }
    } else if (skState === "unavailable") {
      card1Badge = recorded === "未记录" ? "未部署" : recorded;
      card1Lvl = envFailed ? "error" : "warn";
    }
    envLines.push("技能实时状态：" + (skillsInfo.summary_zh || skState));
    if (skillsInfo.live_root) {
      envLines.push("实时目录：" + skillsInfo.live_root);
    }
  } else {
    envLines.push(env.reason || env.Reason ? ("说明：" + (env.reason || env.Reason)) : "提示：记录仅反映上次受管部署，请以预览为准");
  }
  grid.append(renderSyncAssetCard("Codex 环境与技能", card1Badge, card1Lvl, envLines));

  // Card 2: Global Rules (Codex & Antigravity)
  const cfg = sync.config || {};
  const cfgItems = normalizeItems(cfg, ["items", "Items"]);
  let cfgInSync = 0;
  let cfgDiff = 0;
  const cfgLines = [];
  if (cfgItems.length) {
    for (const it of cfgItems) {
      const st = it.status || it.Status || "";
      if (st === "in-sync") cfgInSync++;
      else cfgDiff++;
      const plat = it.platform || it.Platform || "";
      const name = it.item || it.Item || "规则";
      cfgLines.push(plat + " · " + name + "：" + (it.status_zh || st || "未知"));
    }
  } else if (cfg.summary_zh || cfg.error || cfg.Error) {
    cfgLines.push(cfg.summary_zh || cfg.error || cfg.Error);
  } else {
    cfgLines.push("暂无受管全局规则明细");
  }
  const cfgLvl = (cfg.error || cfg.Error) ? "error" : (cfgDiff > 0 ? "warn" : "ok");
  grid.append(renderSyncAssetCard("全局规则与提示词", cfgDiff > 0 ? (cfgDiff + " 项有差异") : ("已同步 " + cfgInSync + " 项"), cfgLvl, cfgLines.slice(0, 4)));

  // Card 3: Antigravity Plugins
  const ag = sync.antigravity || {};
  const agName = ag.name || ag.Name || "ai-agent-dotfiles";
  const agVer = ag.version || ag.Version || "";
  const agAction = ag.action || ag.Action || ag.status || "unknown";
  const agExts = normalizeItems(ag, ["external", "externals", "ExternalExpectations"]);
  const agLines = [
    "主插件：" + agName + (agVer ? (" v" + agVer) : "") + " (" + (ag.action_zh || agAction) + ")"
  ];
  for (const ext of agExts.slice(0, 3)) {
    agLines.push("外部插件 " + (ext.name || ext.Name) + "：" + (ext.action_zh || ext.action || ext.Action || ext.reason || ext.Reason || "未知"));
  }
  if (ag.error || ag.Error) agLines.push("错误：" + (ag.error || ag.Error));
  const agLvl = (ag.error || ag.Error || agAction === "error" || agAction === "blocked") ? "error" : (agAction === "unchanged" ? "ok" : "warn");
  grid.append(renderSyncAssetCard("Antigravity 插件", agAction === "unchanged" ? "已对齐" : agAction, agLvl, agLines));

  // Card 4: Managed MCP
  const mcpObj = sync.mcp || {};
  const mcpItems = normalizeItems(mcpObj, ["items", "Items", "servers"]);
  let mcpBlocked = 0;
  let mcpPending = 0;
  const mcpLines = [];
  if (mcpItems.length) {
    for (const it of mcpItems) {
      const act = it.action || it.Action || "unknown";
      if (act === "blocked") mcpBlocked++;
      else if (act !== "unchanged") mcpPending++;
      mcpLines.push((it.server || it.Server || "mcp") + " → " + (it.platform || it.Platform || "") + "：" + (it.action_zh || act));
    }
  } else if (mcpObj.error || mcpObj.Error) {
    mcpLines.push("错误：" + (mcpObj.error || mcpObj.Error));
  } else {
    mcpLines.push("暂无受管 MCP 投影项");
  }
  const mcpLvl = (mcpObj.error || mcpObj.Error || mcpBlocked > 0) ? "error" : (mcpPending > 0 ? "warn" : "ok");
  grid.append(renderSyncAssetCard("受管 MCP 服务器", mcpBlocked > 0 ? "被阻塞" : (mcpPending > 0 ? "待同步" : "已对齐"), mcpLvl, mcpLines.slice(0, 4)));

  if (sync.raw_sanitized != null) {
    byId("rawSyncJson").textContent = typeof sync.raw_sanitized === "string"
      ? sync.raw_sanitized
      : JSON.stringify(sync.raw_sanitized, null, 2);
  } else {
    byId("rawSyncJson").textContent = JSON.stringify(sync, null, 2);
  }
}

function renderSkillsBrowser() {
  const catalog = state.overview && state.overview.skills_catalog;
  if (!shouldRenderSection("skillsBrowser", {
    catalog,
    filter: state.skillFilter,
    search: state.skillSearch
  })) return;

  const grid = byId("skillsGrid");
  grid.replaceChildren();
  if (!catalog) {
    byId("skillsTotalBadge").textContent = "0 项";
    return;
  }
  const allSkills = catalog.skills || [];
  const q = state.skillSearch.trim().toLowerCase();
  const filtered = allSkills.filter(sk => {
    if (state.skillFilter === "shared" && sk.scope !== "shared") return false;
    if (state.skillFilter === "codex-only" && sk.scope !== "codex-only") return false;
    if (state.skillFilter === "work" && !(sk.in_envs || []).includes("work")) return false;
    if (state.skillFilter === "antigravity" && !sk.in_antigravity_plugin) return false;
    if (!q) return true;
    const hay = [sk.name, sk.scope_zh, sk.description, sk.path, ...(sk.in_envs || [])].join(" ").toLowerCase();
    return hay.includes(q);
  });

  byId("skillsTotalBadge").textContent = filtered.length + " / " + (catalog.total ?? allSkills.length) + " 项";
  if (!filtered.length) {
    grid.append(el("p", "没有匹配当前筛选条件的技能。", "muted"));
    return;
  }
  for (const sk of filtered) {
    const card = el("button", null, "skill-card");
    card.type = "button";
    const top = el("div", null, "bar");
    top.append(el("strong", sk.name), el("span", sk.scope_zh || sk.scope, "badge " + (sk.scope === "shared" ? "ok" : "info")));
    card.append(top);

    const tags = el("div", null, "row");
    for (const envName of (sk.in_envs || [])) {
      tags.append(el("span", envName, "badge"));
    }
    if (sk.in_antigravity_plugin) {
      tags.append(el("span", "Antigravity 插件", "badge ok"));
    }
    card.append(tags);
    card.append(el("p", sk.description || "暂无描述", "skill-desc"));
    card.onclick = () => openSkillModal(sk.name);
    grid.append(card);
  }
}

async function openSkillModal(skillName) {
  byId("skillModalTitle").textContent = skillName;
  byId("skillModalMeta").textContent = "正在读取 SKILL.md…";
  byId("skillModalBody").textContent = "加载中…";
  byId("skillModalBackdrop").classList.add("open");
  try {
    const data = await apiGet("/api/skill?name=" + encodeURIComponent(skillName));
    byId("skillModalTitle").textContent = data.name || skillName;
    byId("skillModalMeta").textContent = (data.scope_zh || data.scope || "") + (data.path ? (" · " + data.path) : "");
    byId("skillModalBody").textContent = data.content || "（文件内容为空）";
  } catch (err) {
    byId("skillModalMeta").textContent = "读取失败";
    byId("skillModalBody").textContent = err.message;
  }
}

function renderTestSuites() {
  const suites = (state.testSuites && state.testSuites.suites) || [];
  if (!shouldRenderSection("testSuites", suites)) return;

  const select = byId("testSuiteSelect");
  const prev = select.value;
  select.replaceChildren();
  if (!suites.length) {
    select.add(new Option("暂无可用测试套件", ""));
    byId("runSelectedSuiteBtn").disabled = true;
    return;
  }
  for (const s of suites) {
    const label = s.name + (s.timeout_sec ? (" (" + s.timeout_sec + "s)") : "");
    select.add(new Option(label, s.name));
  }
  if (suites.some(s => s.name === prev)) select.value = prev;
  updateActionDisabledState();
}

function renderDoctorChecks(structured) {
  const wrap = el("div", null, "stack");
  wrap.style.gap = "6px";
  const checks = Array.isArray(structured.checks) ? structured.checks : [];
  if (checks.length) {
    const row = el("div", null, "row");
    for (const chk of checks) {
      if (typeof chk === "string") {
        const m = chk.match(/^\[(PASS|WARN|FAIL|INFO)\]\s*(.*)$/i);
        if (m) row.append(levelBadge(m[1].toUpperCase(), m[1].toUpperCase() + " " + m[2]));
        else row.append(el("span", chk, "badge"));
      } else {
        const lvl = String(chk.level || "INFO").toUpperCase();
        const txt = chk.label || chk.name || chk.message || chk.text || "";
        row.append(levelBadge(lvl, lvl + " " + txt));
      }
    }
    wrap.append(row);
  }
  const blockers = Array.isArray(structured.blockers) ? structured.blockers : [];
  if (blockers.length) {
    const box = el("div", null, "notice error");
    box.append(el("strong", "部署阻断项："));
    for (const b of blockers) {
      box.append(el("div", typeof b === "string" ? b : JSON.stringify(b)));
    }
    wrap.append(box);
  }
  return wrap;
}

function jobStatusLabel(status) {
  if (status === "running") return "运行中";
  if (status === "succeeded") return "成功";
  if (status === "cancelled") return "已中止";
  return "失败";
}

async function cancelJob(jobId, btnEl) {
  if (btnEl) btnEl.disabled = true;
  try {
    const res = await apiPost("/api/jobs/" + encodeURIComponent(jobId) + "/cancel", {});
    const job = res.job || res;
    if (job && job.id) {
      state.jobDetails.set(job.id, job);
      const idx = state.jobs.findIndex(j => j.id === job.id);
      if (idx >= 0) state.jobs[idx] = job;
      if (state.activeJobId === job.id) state.activeJobId = null;
    }
    showToast("已中止任务");
    await refreshOverview();
    await refreshJobs();
  } catch (err) {
    if (btnEl) btnEl.disabled = false;
    showToast("中止失败：" + err.message);
  }
}

function renderJobsList() {
  const list = state.jobs.length ? state.jobs : ((state.overview && state.overview.recent_jobs) || []);
  const resolvedList = list.map(summaryJob => state.jobDetails.get(summaryJob.id) || summaryJob);
  if (!shouldRenderSection("jobsList", {
    jobs: resolvedList,
    openLogs: Array.from(state.openJobLogs).sort(),
    closedLogs: Array.from(state.closedJobLogs).sort()
  })) return;

  const container = byId("jobsListContainer");
  const prevScrolls = new Map();
  for (const preNode of container.querySelectorAll("pre.log[data-job-id]")) {
    const jid = preNode.dataset.jobId;
    const atBottom = (preNode.scrollHeight - preNode.clientHeight - preNode.scrollTop) < 24;
    prevScrolls.set(jid, { top: preNode.scrollTop, atBottom });
  }

  container.replaceChildren();
  byId("jobsCountBadge").textContent = resolvedList.length + " 条";
  if (!resolvedList.length) {
    container.append(el("p", "本次会话尚未执行检查或同步任务。", "muted"));
    return;
  }
  for (const job of resolvedList) {
    const isRunning = job.status === "running";
    const isApplyJob = typeof job.kind === "string" && job.kind.startsWith("apply:");
    if (isRunning && !state.closedJobLogs.has(job.id)) {
      state.openJobLogs.add(job.id);
    }

    const card = el("div", null, "item-card");
    const top = el("div", null, "bar");
    const left = el("div", null, "row");
    left.append(
      levelBadge(job.status, jobStatusLabel(job.status)),
      el("strong", job.label_zh || job.kind || job.id)
    );
    if (job.duration_sec != null) left.append(el("span", Number(job.duration_sec).toFixed(2) + "s", "badge mono"));
    if (job.exit_code != null) left.append(el("span", "exit " + job.exit_code, "badge mono"));
    top.append(left);

    const right = el("div", null, "row");
    if (job.started_at) right.append(el("small", formatTime(job.started_at)));
    if (isRunning && !isApplyJob) {
      const stopBtn = el("button", "停止任务", "sm danger");
      stopBtn.onclick = () => cancelJob(job.id, stopBtn);
      right.append(stopBtn);
    }
    if (job.status === "failed") {
      const copyErrBtn = el("button", "复制报错给 AI 排查", "sm");
      copyErrBtn.onclick = async () => {
        const detailed = state.jobDetails.get(job.id) || await fetchJobDetail(job.id) || job;
        const prompt = detailed.ai_prompt || ("执行任务 `" + (detailed.label_zh || detailed.kind) + "` 失败（exit " + detailed.exit_code + "），请帮我排查以下脱敏日志：\n\n" + (detailed.output_sanitized || detailed.summary_zh || ""));
        copyText(prompt, "已复制，可直接粘贴给 AI");
      };
      right.append(copyErrBtn);
    }
    if (job.preview) {
      const openPrevBtn = el("button", "查看预览结果", "sm");
      openPrevBtn.onclick = () => openPreviewModal(job);
      right.append(openPrevBtn);
    }
    top.append(right);
    card.append(top);

    if (job.summary_zh) card.append(el("small", job.summary_zh));
    if (job.structured && (Array.isArray(job.structured.checks) || Array.isArray(job.structured.blockers))) {
      card.append(renderDoctorChecks(job.structured));
    }

    const details = document.createElement("details");
    const sum = el("summary", isRunning ? "查看实时脱敏输出日志" : "展开脱敏输出日志");
    const initialText = job.output_sanitized != null
      ? (job.output_sanitized || (isRunning ? "正在等待任务输出…" : "（无输出）"))
      : "展开后自动加载日志…";
    const pre = el("pre", initialText, "log");
    pre.dataset.jobId = job.id;
    pre.style.marginTop = "6px";
    details.append(sum, pre);
    const ensureJobLogLoaded = async () => {
      const cached = state.jobDetails.get(job.id);
      if (cached && cached.output_sanitized != null) {
        pre.textContent = cached.output_sanitized || (isRunning ? "正在等待任务输出…" : "（无输出）");
        return;
      }
      if (job.output_sanitized == null) {
        const full = await fetchJobDetail(job.id);
        if (full) {
          pre.textContent = full.output_sanitized || (full.status === "running" ? "正在等待任务输出…" : "（无输出）");
        }
      }
    };
    details.open = state.openJobLogs.has(job.id);
    if (details.open && job.output_sanitized == null) {
      ensureJobLogLoaded();
    }
    details.ontoggle = async () => {
      if (details.open) {
        state.openJobLogs.add(job.id);
        state.closedJobLogs.delete(job.id);
        await ensureJobLogLoaded();
      } else {
        state.openJobLogs.delete(job.id);
        if (isRunning) state.closedJobLogs.add(job.id);
      }
    };
    card.append(details);
    container.append(card);

    const saved = prevScrolls.get(job.id);
    if (saved) {
      pre.scrollTop = saved.atBottom ? pre.scrollHeight : saved.top;
    } else if (isRunning && details.open) {
      pre.scrollTop = pre.scrollHeight;
    }
  }
}

function openPreviewModal(job) {
  state.currentPreviewJob = job;
  const preview = job.preview || {};
  const targetLabel = TARGET_LABELS[preview.target] || preview.target || job.label_zh || "同步预览";
  byId("previewModalTitle").textContent = "同步预览：" + targetLabel;
  byId("previewModalMeta").textContent = (preview.environment ? ("环境 " + preview.environment + " · ") : "")
    + (preview.repo_head_sha ? ("基线 " + String(preview.repo_head_sha).slice(0, 8) + " · ") : "")
    + (job.summary_zh || "");

  const alertBox = byId("previewAlertBox");
  alertBox.replaceChildren();
  const isBlocked = preview.blocked != null
    ? Boolean(preview.blocked)
    : (preview.items || []).some(it => it.action === "blocked");
  if (preview.has_prune) {
    alertBox.append(el("div", "警告：此预览包含旧目录清理 (prune) 操作，请务必核对清单并确认！", "notice error"));
  }
  if (isBlocked) {
    alertBox.append(el("div", preview.summary_zh || "存在被阻断的变更项或前置条件未满足，禁止直接 Apply。请根据日志排查或复制给 AI 处理。", "notice error"));
  } else if (preview.no_changes) {
    alertBox.append(el("div", preview.summary_zh || "当前所有项目均已同步，无需执行写入。", "notice ok"));
  } else if (!preview.can_apply) {
    alertBox.append(el("div", preview.summary_zh || "预览未能通过可执行检查（can_apply=false），无法执行写入。", "notice warn"));
  }

  const tableWrap = byId("previewTableWrap");
  tableWrap.replaceChildren();
  const items = preview.items || [];
  if (items.length) {
    const tbl = document.createElement("table");
    const thead = document.createElement("thead");
    const hrow = document.createElement("tr");
    hrow.append(el("th", "操作"), el("th", "对象"), el("th", "说明"));
    thead.append(hrow);
    tbl.append(thead);

    const tbody = document.createElement("tbody");
    for (const it of items) {
      const tr = document.createElement("tr");
      const act = it.action || "";
      const tdAct = document.createElement("td");
      const lvl = act === "blocked" || act === "prune" ? "error" : (act === "unchanged" ? "ok" : "warn");
      tdAct.append(levelBadge(lvl, it.action_zh || act || "变更"));
      tr.append(tdAct, el("td", it.name || "--", "mono"), el("td", it.detail || ""));
      tbody.append(tr);
    }
    tbl.append(tbody);
    tableWrap.append(tbl);
  } else {
    tableWrap.append(el("p", "未解析到逐项变更条目，请展开下方原始预览日志核对。", "muted"));
  }

  const riskBox = byId("previewRiskBox");
  riskBox.textContent = preview.risk_notice_zh || "执行写入只会修改受管目标并在本机保留备份；不会执行 Git 提交或推送。";
  byId("previewRawLog").textContent = job.output_sanitized || "（无日志输出）";

  const cb = byId("previewConfirmCheckbox");
  cb.checked = false;
  cb.disabled = !(preview.can_apply === true);
  byId("previewConfirmLabel").style.display = preview.can_apply === true ? "flex" : "none";
  syncApplyButtonState();
  byId("previewModalBackdrop").classList.add("open");
}

async function fetchJobDetail(jobId) {
  try {
    const data = await apiGet("/api/jobs/" + encodeURIComponent(jobId));
    const job = data.job || data;
    state.jobDetails.set(job.id, job);
    return job;
  } catch {
    return null;
  }
}

async function refreshJobs() {
  try {
    const data = await apiGet("/api/jobs");
    state.jobs = data.jobs || data || [];
    renderJobsList();
    updateActionDisabledState();
  } catch {
    // Keep existing list.
  }
}

async function pollActiveJob(jobId) {
  state.activeJobId = jobId;
  updateActionDisabledState();
  if (state.jobPollTimer) clearTimeout(state.jobPollTimer);

  const step = async () => {
    const job = await fetchJobDetail(jobId);
    if (!job) {
      state.activeJobId = null;
      updateActionDisabledState();
      return;
    }
    const idx = state.jobs.findIndex(j => j.id === job.id);
    if (idx >= 0) state.jobs[idx] = job;
    else state.jobs.unshift(job);
    renderJobsList();

    if (job.status === "running") {
      state.jobPollTimer = setTimeout(step, 800);
      return;
    }

    state.activeJobId = null;
    await refreshOverview();
    await refreshJobs();
    updateActionDisabledState();

    if (job.status === "cancelled") {
      showToast((job.label_zh || "任务") + " 已手动中止");
    } else if (job.preview && state.lastHandledPreviewJobId !== job.id) {
      state.lastHandledPreviewJobId = job.id;
      openPreviewModal(job);
    } else if (typeof job.kind === "string" && job.kind.startsWith("apply:")) {
      showToast(job.status === "succeeded" ? "写入完成，正在刷新双端状态…" : "写入失败，请查看执行日志");
      await refreshSyncStatus(true);
    } else {
      showToast((job.label_zh || "任务") + (job.status === "succeeded" ? " 执行完成" : " 执行失败"));
    }
  };
  await step();
}

async function triggerAction(action, extra) {
  if (isJobBusy()) {
    showToast("已有任务正在执行，请等待完成");
    return;
  }
  try {
    const payload = { action };
    if (extra && extra.suite) payload.suite = extra.suite;
    const res = await apiPost("/api/actions/run", payload);
    const job = res.job;
    if (job && job.id) {
      state.jobDetails.set(job.id, job);
      state.jobs.unshift(job);
      state.openJobLogs.add(job.id);
      renderJobsList();
      showToast("已启动：" + (job.label_zh || action));
      pollActiveJob(job.id);
    }
  } catch (err) {
    showToast("启动失败：" + err.message);
  }
}

async function triggerPreview(target, environment) {
  if (isJobBusy()) {
    showToast("已有任务正在执行，请等待完成");
    return;
  }
  try {
    const res = await apiPost("/api/sync/preview", { target, environment });
    const job = res.job;
    if (job && job.id) {
      state.jobDetails.set(job.id, job);
      state.jobs.unshift(job);
      state.openJobLogs.add(job.id);
      renderJobsList();
      showToast("正在生成预览：" + (TARGET_LABELS[target] || target));
      pollActiveJob(job.id);
    }
  } catch (err) {
    showToast("预览请求失败：" + err.message);
  }
}

async function triggerApply() {
  const preview = state.currentPreviewJob && state.currentPreviewJob.preview;
  if (!preview || !preview.can_apply || !byId("previewConfirmCheckbox").checked) return;
  try {
    const res = await apiPost("/api/sync/apply", {
      preview_id: preview.preview_id,
      confirm: true
    });
    byId("previewModalBackdrop").classList.remove("open");
    const job = res.job;
    if (job && job.id) {
      state.jobDetails.set(job.id, job);
      state.jobs.unshift(job);
      state.openJobLogs.add(job.id);
      renderJobsList();
      showToast("已确认写入，正在执行 Apply…");
      pollActiveJob(job.id);
    }
  } catch (err) {
    showToast("执行写入被拒绝：" + err.message);
  }
}

async function refreshOverview() {
  try {
    const data = await apiGet("/api/overview");
    state.overview = data;
    if (Array.isArray(data.recent_jobs)) {
      state.jobs = data.recent_jobs.map(j => state.jobDetails.get(j.id) || j);
    }
    setConnectionState(true, "实时连接");
    renderHeaderAndKpis();
    renderAttention();
    renderWorkspaceChanges();
    renderStatusTasks();
    renderCommitsAndGithub();
    renderSwarmBoards();
    renderSkillsBrowser();
    renderJobsList();
    updateActionDisabledState();
    if (data.active_job && data.active_job.id && state.activeJobId !== data.active_job.id) {
      pollActiveJob(data.active_job.id);
    }
  } catch {
    setConnectionState(false, "连接中断 · 重试中");
  }
}

async function refreshSyncStatus(force, syncOverview = force) {
  try {
    const data = await apiGet("/api/sync-status" + (force ? "?refresh=1" : ""));
    state.syncStatus = data;
    renderHeaderAndKpis();
    renderAttention();
    renderSyncSection();
    if (syncOverview) await refreshOverview();
  } catch (err) {
    state.syncStatus = { ok: false, summary_level: "error", summary_zh: "同步状态读取失败：" + err.message };
    renderHeaderAndKpis();
    renderAttention();
    renderSyncSection();
  }
}

async function refreshGithub(force, syncOverview = force) {
  try {
    const data = await apiGet("/api/github" + (force ? "?refresh=1" : ""));
    state.github = data;
    renderHeaderAndKpis();
    renderCommitsAndGithub();
    if (syncOverview) await refreshOverview();
  } catch (err) {
    state.github = { available: false, offline: true, message_zh: "GitHub 查询失败：" + err.message, open_prs: [], ci_runs: [] };
    renderHeaderAndKpis();
    renderCommitsAndGithub();
  }
}

async function refreshTestSuites() {
  try {
    const data = await apiGet("/api/test-suites");
    state.testSuites = data;
    renderTestSuites();
  } catch {
    renderTestSuites();
  }
}

function scheduleOverviewPoll() {
  if (state.pollTimer) {
    clearTimeout(state.pollTimer);
    state.pollTimer = null;
  }
  if (!state.autoRefresh || document.visibilityState === "hidden") return;
  state.pollTimer = setTimeout(async () => {
    if (document.visibilityState === "hidden" || !state.autoRefresh) return;
    await refreshOverview();
    scheduleOverviewPoll();
  }, 8000);
}

document.addEventListener("visibilitychange", async () => {
  if (document.visibilityState === "hidden") {
    if (state.pollTimer) {
      clearTimeout(state.pollTimer);
      state.pollTimer = null;
    }
    return;
  }
  if (document.visibilityState === "visible" && state.autoRefresh) {
    await refreshOverview();
    scheduleOverviewPoll();
  }
});

// Event Bindings
byId("autoRefreshBtn").onclick = () => {
  state.autoRefresh = !state.autoRefresh;
  byId("autoRefreshBtn").setAttribute("aria-pressed", String(state.autoRefresh));
  byId("autoRefreshBtn").textContent = state.autoRefresh ? "自动刷新：开启 (8s)" : "自动刷新：已暂停";
  if (state.autoRefresh) {
    refreshOverview();
    scheduleOverviewPoll();
  } else if (state.pollTimer) {
    clearTimeout(state.pollTimer);
    state.pollTimer = null;
  }
};

byId("fullRefreshBtn").onclick = async () => {
  byId("fullRefreshBtn").disabled = true;
  showToast("正在全面刷新仓库、同步与 GitHub…");
  await Promise.all([refreshSyncStatus(true, false), refreshGithub(true, false), refreshJobs()]);
  await refreshOverview();
  byId("fullRefreshBtn").disabled = false;
  showToast("全面刷新完成");
};

byId("runningJobPill").onclick = () => byId("sec-jobs").scrollIntoView({ behavior: "smooth" });
byId("refreshSyncBtn").onclick = () => refreshSyncStatus(true);
byId("refreshGithubBtn").onclick = () => refreshGithub(true);
byId("refreshJobsBtn").onclick = () => refreshJobs();

byId("copyExplainDiffBtn").onclick = () => copyText(buildWorkspaceAiPrompt("explain"), "已复制，可直接粘贴给 AI");
byId("copyReviewCommitBtn").onclick = () => copyText(buildWorkspaceAiPrompt("review"), "已复制，可直接粘贴给 AI");

byId("swarmProbeForm").onsubmit = async (ev) => {
  ev.preventDefault();
  const input = byId("swarmManifestInput");
  const notice = byId("swarmProbeNotice");
  const pathVal = input.value.trim();
  notice.replaceChildren();
  if (!pathVal) {
    notice.append(el("div", "请输入 manifest.json 路径。", "notice warn"));
    return;
  }
  byId("swarmProbeBtn").disabled = true;
  try {
    const res = await apiPost("/api/swarm/probe", { manifest_path: pathVal });
    const board = res.board || res;
    notice.append(el("div", "已探测看板：" + (board.run || pathVal) + (board.running ? "（运行中）" : "（未运行）"), board.running ? "notice ok" : "notice warn"));
    await refreshOverview();
  } catch (err) {
    notice.append(el("div", "探测失败：" + err.message, "notice error"));
  } finally {
    byId("swarmProbeBtn").disabled = false;
  }
};

byId("skillSearchInput").oninput = (ev) => {
  state.skillSearch = ev.target.value;
  renderSkillsBrowser();
};

for (const btn of byId("skillFilterPills").querySelectorAll("button")) {
  btn.onclick = () => {
    state.skillFilter = btn.dataset.filter;
    for (const other of byId("skillFilterPills").querySelectorAll("button")) {
      other.setAttribute("aria-pressed", String(other === btn));
    }
    renderSkillsBrowser();
  };
}

for (const btn of document.querySelectorAll(".js-action-btn")) {
  btn.onclick = () => {
    const action = btn.dataset.action;
    if (action === "test-suite") {
      const suite = byId("testSuiteSelect").value;
      if (!suite) {
        showToast("请先选择一个测试套件");
        return;
      }
      triggerAction("test-suite", { suite });
    } else {
      triggerAction(action);
    }
  };
}

for (const btn of document.querySelectorAll(".js-preview-btn")) {
  btn.onclick = () => triggerPreview(btn.dataset.target, byId("syncEnvSelect").value);
}

byId("previewConfirmCheckbox").onchange = syncApplyButtonState;
byId("applyPreviewBtn").onclick = triggerApply;
byId("copyPreviewToAiBtn").onclick = () => {
  const job = state.currentPreviewJob;
  if (!job) return;
  const preview = job.preview || {};
  const lines = (preview.items || []).map(it => "- [" + (it.action_zh || it.action) + "] " + it.name + (it.detail ? (" — " + it.detail) : ""));
  const prompt = "请帮我评估以下同步预览结果，判断是否安全可执行 Apply：\n目标："
    + (TARGET_LABELS[preview.target] || preview.target || job.label_zh)
    + (preview.environment ? ("（环境：" + preview.environment + "）") : "")
    + "\n摘要：" + (job.summary_zh || preview.summary_zh || "")
    + "\n变更清单：\n" + (lines.join("\n") || "（无逐项条目）")
    + "\n\n原始脱敏日志：\n" + (job.output_sanitized || "");
  copyText(prompt, "已复制，可直接粘贴给 AI");
};

byId("closeSkillModalBtn").onclick = () => byId("skillModalBackdrop").classList.remove("open");
byId("skillModalBackdrop").onclick = (ev) => {
  if (ev.target === byId("skillModalBackdrop")) byId("skillModalBackdrop").classList.remove("open");
};

const closePreviewModal = () => byId("previewModalBackdrop").classList.remove("open");
byId("closePreviewModalBtn").onclick = closePreviewModal;
byId("cancelPreviewBtn").onclick = closePreviewModal;
byId("previewModalBackdrop").onclick = (ev) => {
  if (ev.target === byId("previewModalBackdrop")) closePreviewModal();
};

document.addEventListener("keydown", (ev) => {
  if (ev.key === "Escape") {
    byId("skillModalBackdrop").classList.remove("open");
    byId("previewModalBackdrop").classList.remove("open");
  }
});

// Initial Load
(async function init() {
  await refreshOverview();
  await Promise.all([refreshSyncStatus(false), refreshGithub(false), refreshTestSuites(), refreshJobs()]);
  await refreshOverview();
  scheduleOverviewPoll();
})();
