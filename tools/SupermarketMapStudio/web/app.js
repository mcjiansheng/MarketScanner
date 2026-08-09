"use strict";

const launchParameters = new URLSearchParams(window.location.hash.slice(1));
const launchToken = launchParameters.get("token") || "";
if (launchToken) {
  window.history.replaceState(null, "", `${window.location.pathname}${window.location.search}`);
}
let sessionToken = launchToken;
const SESSION_REFRESH_INTERVAL_MS = 5 * 60 * 1000;
let sessionRefreshTimer = null;

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const statusNode = $("#job-status");
const mapCanvas = $("#map-canvas");
const sceneCanvas = $("#scene-canvas");
const emptyPreview = $("#empty-preview");
const previewMeta = $("#preview-meta");
const processingProgress = $("#processing-progress");
const progressBar = $("#progress-bar");
const progressStage = $("#progress-stage");
const progressPercent = $("#progress-percent");
let activeMode = "single";
let activePreview = "2d-color";
let activeJobId = null;
let completedJobId = null;
let activeJobKey = null;
let completedJobKey = null;
let sessionRestoreTimer = null;
let sessionSelectionToken = 0;
let currentSingleScanMode = null;
let currentSingleOfflineSupported = null;
let currentCheckpointCleanupEvidence = null;
const localizedReview = {
  data: null,
  selectedTagId: null,
  versionId: null,
  revision: null,
  publishState: null,
  publishedVersionId: null,
  publishedRevision: null,
  publishedState: null,
  reviewArtifactUrl: null,
  fieldQualification: null,
  fieldQualificationPath: null,
  anchorDraft: null,
  anchorDragging: false,
  canvasProjection: null,
};

const viewer2d = {
  images: { "2d-map": null, "2d-shelf": null },
  scale: 1, offsetX: 0, offsetY: 0, dragging: false, startX: 0, startY: 0,
};
const shelfTuning = {
  evidence: null,
  cellMap: null,
  cells: [],
  groundCells: new Set(),
  elevatedCells: new Set(),
  stableElevatedCells: new Set(),
  freeSpaceCells: new Set(),
  elevatedObservationCounts: new Map(),
  defaults: null,
  loadToken: 0,
  renderTimer: null,
  loading: false,
  profileLabel: "balanced",
};
const manualMerge = {
  active: false,
  baseJobId: null,
  available: false,
  regions: [],
  draft: null,
  selecting: false,
  preview: null,
  spacePressed: false,
};
const viewerTop = { center: [0, 0, 0], distance: 1 };
const viewer3d = {
  data: null, yaw: -0.72, pitch: 0.68, distance: 1, dragging: false,
  startX: 0, startY: 0, center: [0, 0, 0], viewCenter: [0, 0, 0], span: 1, planSpan: 1,
  dragMode: "rotate", dragGesture: "rotate",
  gl: null, program: null, locations: null, buffers: null,
  showSurface: true, showCloud: false, showTrajectory: true, pointSize: 2,
  artifactRoot: "", surfaceLoadToken: 0,
};

function setStatus(text, tone = "") {
  statusNode.textContent = text;
  statusNode.className = `status ${tone}`;
}

function renderJobProgress(job) {
  const progress = Math.max(0, Math.min(100, Number(job?.progress || 0)));
  processingProgress.hidden = false;
  progressBar.value = progress;
  progressBar.textContent = `${progress}%`;
  progressStage.textContent = job?.stage || "正在处理";
  progressPercent.textContent = `${progress}%`;
  const cancellable = ["queued", "running", "cancelling"].includes(job?.status);
  $("#cancel-job").hidden = !cancellable;
  $("#cancel-job").disabled = job?.status === "cancelling";
}

function renderJobLogs(logs = []) {
  const output = $("#job-log-output");
  const summary = $("#job-log-summary");
  const recent = logs.slice(-300);
  summary.textContent = logs.length ? `${logs.length} 条处理事件${logs.length > recent.length ? "（显示最近 300 条）" : ""}` : "任务启动后显示";
  output.textContent = recent.length
    ? recent.map((item) => `[${item.timestamp || ""}] ${item.progress ?? 0}% ${item.stage || ""} — ${item.message || ""}`).join("\n")
    : "尚无日志";
  output.scrollTop = output.scrollHeight;
}

function renderScanLogs(scanLogs = {}) {
  const output = $("#scan-log-output");
  const summary = $("#scan-log-summary");
  const events = scanLogs.events || [];
  if (!scanLogs.available) {
    summary.textContent = "该会话没有结构化扫描日志（可能由旧版 App 生成）";
    output.textContent = "尚无日志";
    return;
  }
  const suffix = scanLogs.truncated ? "（仅显示最近事件）" : "";
  const malformed = scanLogs.malformed_lines ? `，${scanLogs.malformed_lines} 行无法解析` : "";
  summary.textContent = `${scanLogs.event_count || events.length} 条扫描事件${suffix}${malformed}`;
  output.textContent = events.map((item) => {
    const fields = item.fields && Object.keys(item.fields).length ? ` ${JSON.stringify(item.fields)}` : "";
    return `[${item.timestamp || ""}] ${(item.level || "info").toUpperCase()} ${item.event || "event"} — ${item.message || ""}${fields}`;
  }).join("\n") || "日志文件为空";
  output.scrollTop = output.scrollHeight;
}

function setBusy(busy) {
  $$(".primary").forEach((button) => { button.disabled = busy; });
  $$(".secondary").forEach((button) => {
    button.disabled = busy && !["reset-view", "preview-fullscreen", "cancel-job"].includes(button.id);
  });
  $$(".tab").forEach((button) => { button.disabled = busy; });
  if (!busy) updateSingleAlignmentState();
  if (!busy) syncLocalizedStateButtons();
}

function syncLocalizedStateButtons() {
  const state = localizedReview.publishState;
  $("#localized-submit-review").disabled = state !== "draft";
  $("#localized-publish").disabled = (
    state !== "review" || localizedReview.publishedState === "published"
    || !localizedReview.fieldQualification
  );
  $("#localized-revoke").disabled = localizedReview.publishedState !== "published";
}

async function request(path, options = {}) {
  const requestOptions = { ...options };
  if ((requestOptions.method || "GET").toUpperCase() === "POST") {
    const headers = new Headers(requestOptions.headers || {});
    if (sessionToken) headers.set("X-MarketScanner-Session-Token", sessionToken);
    requestOptions.headers = headers;
  }
  const response = await fetch(path, requestOptions);
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(payload.error || `Request failed (${response.status})`);
    error.status = response.status;
    error.payload = payload;
    throw error;
  }
  return payload;
}

async function bootstrapSession() {
  if (!sessionToken) return;
  const response = await fetch("/api/session/bootstrap", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-MarketScanner-Session-Token": sessionToken,
    },
    body: JSON.stringify({}),
  });
  if (!response.ok) throw new Error("本地安全会话初始化失败，请从启动器重新打开 Map Studio。");
  sessionToken = "";
}

async function refreshSession(reportFailure = false) {
  try {
    await request("/api/session/refresh", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    return true;
  } catch (error) {
    if (reportFailure) {
      setStatus("本地安全会话已到期，请从启动器重新打开 Map Studio。", "failed");
    }
    return false;
  }
}

function startSessionRefresh() {
  if (sessionRefreshTimer !== null) return;
  sessionRefreshTimer = window.setInterval(
    () => refreshSession(document.visibilityState === "visible"),
    SESSION_REFRESH_INTERVAL_MS,
  );
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") refreshSession(true);
  });
  window.addEventListener("focus", () => refreshSession(true));
}

async function renderRuntimeMode() {
  const about = await request("/api/about");
  const production = about.runtime_mode === "production";
  $("#runtime-mode-banner").textContent = production
    ? "PRODUCTION MODE"
    : "DEVELOPMENT / NOT QUALIFIED FOR PRODUCTION";
}

async function inspectFieldQualification() {
  const status = $("#localized-field-evidence-status");
  try {
    const selected = await request("/api/dialog", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ mode: "file", title: "选择现场验收证据 JSON" }),
    });
    if (!selected.path) return;
    const evidence = await request("/api/qualification/field/inspect", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path: selected.path }),
    });
    localizedReview.fieldQualification = evidence;
    localizedReview.fieldQualificationPath = selected.path;
    status.textContent = `VERIFIED/PASS · ${evidence.site_id} · ${evidence.run_count} runs · ${evidence.tag_control_count} tags · release ${evidence.release_git_sha.slice(0, 12)} · prior ${evidence.prior_map_sha256.slice(0, 12)}`;
  } catch (error) {
    localizedReview.fieldQualification = null;
    localizedReview.fieldQualificationPath = null;
    status.textContent = error.message;
  }
  syncLocalizedStateButtons();
}

async function choosePath(inputId, title, mode = "directory") {
  try {
    setStatus(mode === "file" ? "正在打开系统文件选择器" : "正在打开系统文件夹选择器", "running");
    const result = await request("/api/dialog", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ mode, title }),
    });
    if (result.path) {
      const input = $("#" + inputId);
      input.value = result.path;
      if (["single-output", "multi-output"].includes(inputId)) input.dataset.autoOutput = "false";
      if (inputId === "single-session") await selectSingleSession(result.path);
      else {
        applySessionOutputDefault(inputId, result.path);
        setStatus("路径已选择", "complete");
      }
    }
    else {
      setStatus("已取消选择");
    }
    return result.path || "";
  } catch (error) {
    setStatus(error.message, "failed");
    return "";
  }
}

async function showAboutAndRecovery() {
  try {
    const [about, recovery] = await Promise.all([
      request("/api/about"),
      request("/api/recovery"),
    ]);
    const failedChecks = (about.startup_diagnostics?.checks || [])
      .filter((item) => !item.ok)
      .map((item) => `${item.name}: ${item.detail}`);
    const interrupted = recovery.interrupted_jobs || [];
    window.alert([
      `${about.product} ${about.version}`,
      `Git SHA: ${about.git_sha}`,
      `Python: ${about.python}`,
      failedChecks.length ? `启动检查未通过:\n${failedChecks.join("\n")}` : "启动检查：通过",
      interrupted.length ? `中断任务：${interrupted.length}（原输入和旧 current 均保留）` : "中断任务：0",
      ...(recovery.actions || []),
    ].join("\n\n"));
  } catch (error) {
    setStatus(error.message, "failed");
  }
}

async function exportDiagnostics() {
  try {
    const selected = await request("/api/dialog", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ mode: "directory", title: "选择诊断包保存目录" }),
    });
    if (!selected.path) return;
    const result = await request("/api/diagnostics/export", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ output_directory: selected.path }),
    });
    setStatus(`诊断包已生成：${result.path}（SHA-256 ${result.sha256}）`, "complete");
  } catch (error) {
    setStatus(error.message, "failed");
  }
}

function timestampForPath() {
  const now = new Date();
  const pad = (value) => String(value).padStart(2, "0");
  return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
}

function defaultOutputPath(session, prefix) {
  return `${session.replace(/[\\/]+$/, "")}/${prefix}-${timestampForPath()}`;
}

function setOutputDefault(outputId, session, prefix) {
  const output = $("#" + outputId);
  if (!output || (output.value.trim() && output.dataset.autoOutput !== "true")) return;
  output.value = defaultOutputPath(session, prefix);
  output.dataset.autoOutput = "true";
}

function applySessionOutputDefault(inputId, session) {
  if (inputId === "single-session") setOutputDefault("single-output", session, "MapStudio-Single");
  if (inputId === "localized-session") setOutputDefault("localized-output", session, "MapStudio-Localized");
}

async function selectSingleSession(session) {
  const token = ++sessionSelectionToken;
  const output = $("#single-output");
  completedJobId = null;
  completedJobKey = null;
  $("#open-output").disabled = true;
  output.value = "";
  output.dataset.autoOutput = "true";
  output.dataset.restored = "false";
  currentSingleScanMode = null;
  currentSingleOfflineSupported = null;
  currentCheckpointCleanupEvidence = null;
  $("#cleanup-finalized-checkpoint").hidden = true;
  renderJobLogs([]);
  $("#option-offline-optimize").checked = true;
  updateSingleAlignmentState();
  if (!session) {
    setStatus("就绪");
    return;
  }
  applySessionOutputDefault("single-session", session);
  try {
    const inspection = await request("/api/session/inspect", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ session }),
    });
    if (token !== sessionSelectionToken || $("#single-session").value.trim() !== session) return;
    renderInspection(inspection);
    applyInspectionCapabilities(inspection);
    if (inspection.active_job) {
      output.value = inspection.active_job.output_dir;
      output.dataset.autoOutput = "false";
      output.dataset.restored = "false";
      activeJobId = inspection.active_job.id;
      activeJobKey = activeRequestKey(activeRequest());
      setBusy(true);
      renderJobProgress(inspection.active_job);
      renderJobLogs(inspection.active_job.logs || []);
      setStatus(`${inspection.active_job.stage || "正在处理"} · ${inspection.active_job.progress || 0}%`, "running");
      pollJob();
      return;
    }
  } catch (error) {
    if (token !== sessionSelectionToken) return;
    setStatus(error.message, "failed");
    return;
  }
  await restoreExistingResult(session, token);
}

function mapOptions() {
  return {
    offline_optimize: $("#option-offline-optimize").checked,
    reprocess_binary: $("#option-reprocess-binary").value.trim(),
    pc_threads: $("#option-pc-threads").value,
    pc_local_staging: $("#option-pc-local-staging").checked,
    gpu_backend: $("#option-gpu-backend").value,
    gpu_helper: $("#option-gpu-helper").value.trim(),
    resolution: $("#option-resolution").value,
    trajectory_radius: $("#option-trajectory-radius").value,
    tag_snap_distance: $("#option-tag-snap").value,
    horizontal_axes: $("#option-axes").value,
    preview_3d_quality: $("#option-3d-quality").value,
  };
}

function applyRestoredOptions(map) {
  const parameters = map?.parameters || {};
  // Missing marker means this is an older phone-pose-only result. Do not let
  // it masquerade as equivalent to a newly requested PC-optimized result.
  $("#option-offline-optimize").checked = Boolean(map?.pc_offline_processing?.enabled);
  const execution = map?.pc_offline_processing?.execution || {};
  if (execution.thread_count != null) $("#option-pc-threads").value = execution.thread_count;
  if (execution.local_staging != null) $("#option-pc-local-staging").checked = Boolean(execution.local_staging);
  const acceleration = map?.pc_acceleration || {};
  if (["auto", "cpu", "apple_metal", "nvidia_cuda"].includes(acceleration.requested_backend)) {
    $("#option-gpu-backend").value = acceleration.requested_backend;
  }
  if (parameters.resolution != null) $("#option-resolution").value = parameters.resolution;
  if (parameters.trajectory_radius != null) $("#option-trajectory-radius").value = parameters.trajectory_radius;
  if (parameters.tag_snap_distance != null) $("#option-tag-snap").value = parameters.tag_snap_distance;
  if (["xz", "xy"].includes(parameters.horizontal_axes)) $("#option-axes").value = parameters.horizontal_axes;
  if (["quick", "detailed", "maximum"].includes(map?.preview_3d_quality)) {
    $("#option-3d-quality").value = map.preview_3d_quality;
  }
  if (!$("#stage-list").children.length) {
    $("#single-auto-align").checked = Boolean(parameters.auto_align_segments);
  }
}

function clearNode(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
}

function appendText(parent, tag, text, className = "") {
  const node = document.createElement(tag);
  if (className) node.className = className;
  node.textContent = text;
  parent.appendChild(node);
  return node;
}

function renderInspection(data) {
  const target = $("#inspection");
  clearNode(target);
  const streaming = data.scan_mode === "continuous_streaming";
  const mode = streaming ? "连续流式单库" : (data.scan_mode === "segmented" ? "传统分段" : "兼容单库");
  const strategy = data.merge_required ? "需要段间合并/校正" : "无需段间合并";
  appendText(target, "div", `${mode}  |  ${data.database_count} 个数据库  |  ${data.node_count} 个节点`);
  appendText(target, "div", strategy, streaming ? "complete" : "");
  const pc = data.pc_processing || {};
  if (pc.uses_optimized_poses) {
    appendText(target, "div", "数据库已包含 PC 全局优化位姿", "complete");
  } else if (pc.reprocess_available) {
    appendText(target, "div", `PC 离线优化器已就绪：${pc.reprocess_binary}`);
  } else if (streaming) {
    appendText(target, "div", "未检测到 rtabmap-reprocess；生成前请构建 RTAB-Map 工具或填写二进制路径", "warning");
  }
  if (data.active_job) {
    appendText(
      target,
      "div",
      `检测到正在运行的任务 ${data.active_job.id}：${data.active_job.stage} · ${data.active_job.progress}%（将自动接回，不会重复启动）`,
      "complete",
    );
  }
  const cleanup = data.checkpoint_cleanup || {};
  currentCheckpointCleanupEvidence = cleanup.available ? cleanup : null;
  const cleanupButton = $("#cleanup-finalized-checkpoint");
  cleanupButton.hidden = !currentCheckpointCleanupEvidence;
  if (currentCheckpointCleanupEvidence) {
    appendText(
      target,
      "div",
      `发现已完成会话的旧 checkpoint：identity ${cleanup.tracking_session_id}，提交时间 ${cleanup.finalized_at_unix}。清理只删除旧 checkpoint，不修复扫描数据。`,
      "warning",
    );
  }
  const coverage = data.structure_coverage || {};
  const coverageSummary = coverage.summary || null;
  if (coverage.available && coverageSummary) {
    const stable = Number(coverageSummary.stableStructureCellCount || 0);
    const multiView = Number(coverageSummary.multiViewStructureCellCount || 0);
    const conflicts = Number(coverageSummary.groundConflictCellCount || 0);
    const score = Math.round(Number(coverageSummary.coverageScore || 0) * 100);
    const rate = Number(coverageSummary.currentDetectionRateHz || 0).toFixed(1);
    appendText(
      target,
      "div",
      `手机结构覆盖：${stable} 个稳定栅格 / ${multiView} 个多视角（${score}%），地面冲突 ${conflicts}，结束时 ${rate} Hz`,
      multiView > 0 ? "complete" : "warning",
    );
  } else if ((coverage.malformed_files || []).length) {
    appendText(target, "div", "手机结构覆盖 sidecar 无法解析；原始 RGB-D 数据库仍可继续处理", "warning");
  }
  const list = document.createElement("ul");
  data.segments.forEach((segment) => {
    const warning = segment.warnings?.length ? `；${segment.warnings.join(" ")}` : "";
    const label = streaming ? "连续数据库" : `分段 ${segment.index}`;
    const optimized = segment.optimized_poses ? `，${segment.optimized_poses} 个优化位姿` : "";
    appendText(list, "li", `${label}: ${segment.nodes} 节点${optimized}${warning}`);
  });
  target.appendChild(list);
  renderScanLogs(data.scan_logs || {});
}

async function loadGpuCapabilities() {
  const target = $("#gpu-capability");
  try {
    const payload = await request("/api/gpu/capabilities");
    const metal = payload.backends?.apple_metal || {};
    const cuda = payload.backends?.nvidia_cuda || {};
    const labels = [];
    labels.push(metal.available ? `Metal 已就绪：${metal.device || "Apple GPU"}` : "Metal 不可用");
    labels.push(cuda.available ? `CUDA 已就绪：${cuda.device || "NVIDIA GPU"}` : "CUDA 不可用");
    target.textContent = labels.join("  |  ");
    target.className = `field-hint ${metal.available || cuda.available ? "complete" : "warning"}`;
  } catch (error) {
    target.textContent = `GPU 检测失败：${error.message}`;
    target.className = "field-hint warning";
  }
}

function applyInspectionCapabilities(data) {
  currentSingleScanMode = data?.scan_mode || null;
  currentSingleOfflineSupported = data?.database_count === 1;
  updateSingleAlignmentState();
  $("#run-single").textContent = currentSingleScanMode === "continuous_streaming"
    ? "PC 优化并生成地图"
    : "生成单设备地图";
}

async function inspectSession(inputId) {
  const session = $("#" + inputId).value.trim();
  if (!session) {
    setStatus("请选择扫描会话", "failed");
    return;
  }
  try {
    setStatus("正在检查会话", "running");
    const inspection = await request("/api/session/inspect", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ session }),
    });
    renderInspection(inspection);
    if (inputId === "single-session") applyInspectionCapabilities(inspection);
    setStatus("会话检查完成", "complete");
  } catch (error) {
    setStatus(error.message, "failed");
  }
}

async function cleanupFinalizedCheckpoint() {
  const session = $("#single-session").value.trim();
  const evidence = currentCheckpointCleanupEvidence;
  if (!session || !evidence) {
    setStatus("请先检查并确认存在可清理的 finalized checkpoint", "failed");
    return;
  }
  const confirmed = window.confirm(
    `只删除会话 ${evidence.tracking_session_id} 的旧 checkpoint。此操作不会修复扫描数据，证据变化时服务端会拒绝。是否继续？`,
  );
  if (!confirmed) return;
  try {
    setStatus("正在验证并清理旧 checkpoint", "running");
    await request("/api/session/cleanup-finalized-checkpoint", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        session,
        confirmed: true,
        expected_tracking_session_id: evidence.tracking_session_id,
        expected_finalized_at_unix: evidence.finalized_at_unix,
        expected_metadata_sha256: evidence.metadata_sha256,
        expected_checkpoint_sha256: evidence.checkpoint_sha256,
      }),
    });
    currentCheckpointCleanupEvidence = null;
    $("#cleanup-finalized-checkpoint").hidden = true;
    setStatus("旧 checkpoint 已清理；正在重新检查会话", "complete");
    await inspectSession("single-session");
  } catch (error) {
    setStatus(error.message, "failed");
  }
}

async function restoreExistingResult(session, token = sessionSelectionToken) {
  if (!session || activeMode !== "single") return false;
  try {
    setStatus("正在查找已有合并结果", "running");
    const result = await request("/api/session/result", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ session }),
    });
    if (token !== sessionSelectionToken || $("#single-session").value.trim() !== session) return false;
    if (!result.found) {
      setStatus("未找到已有结果，可以开始生成");
      return false;
    }
    const output = $("#single-output");
    output.value = result.job.output_dir;
    output.dataset.autoOutput = "false";
    output.dataset.restored = "true";
    completedJobId = result.job.id;
    applyRestoredOptions(result.job.map);
    completedJobKey = activeRequestKey(activeRequest());
    $("#open-output").disabled = false;
    await renderJob(result.job);
    setStatus("已加载会话中的已有合并结果", "complete");
    return true;
  } catch (error) {
    if (token !== sessionSelectionToken) return false;
    setStatus(error.message, "failed");
    return false;
  }
}

function deviceRows() {
  return $$(".device-row").map((row) => ({
    id: row.querySelector(".device-id").value.trim(),
    session: row.querySelector(".device-session").value.trim(),
    dx: row.querySelector(".device-dx").value,
    dy: row.querySelector(".device-dy").value,
    yaw_deg: row.querySelector(".device-yaw").value,
  }));
}

function labelledInput(label, className, type, value = "", step = "") {
  const field = document.createElement("label");
  field.textContent = label;
  const input = document.createElement("input");
  input.className = className;
  input.type = type;
  input.value = value;
  input.spellcheck = false;
  if (step) input.step = step;
  field.appendChild(input);
  return field;
}

function addDevice() {
  const list = $("#device-list");
  const number = list.children.length + 1;
  const row = document.createElement("div");
  row.className = "device-row";
  const sessionField = labelledInput("会话", "device-session", "text");
  sessionField.classList.add("device-path");
  row.appendChild(sessionField);
  row.appendChild(labelledInput("ID", "device-id", "text", `device_${number}`));
  row.appendChild(labelledInput("dx (m)", "device-dx", "number", "0", "0.1"));
  row.appendChild(labelledInput("dy (m)", "device-dy", "number", "0", "0.1"));
  row.appendChild(labelledInput("yaw (deg)", "device-yaw", "number", "0", "0.1"));
  const choose = document.createElement("button");
  choose.className = "secondary choose-device";
  choose.type = "button";
  choose.textContent = "选择";
  choose.addEventListener("click", async () => {
    const selected = await choosePath(sessionField.querySelector("input").id, "选择设备扫描会话");
    if (selected && !$("#multi-output").value.trim()) setOutputDefault("multi-output", selected, "MapStudio-Multi");
  });
  const sessionInput = sessionField.querySelector("input");
  sessionInput.id = `device-session-${number}-${Date.now()}`;
  sessionInput.addEventListener("input", () => {
    if (sessionInput.value.trim() && !$("#multi-output").value.trim()) {
      setOutputDefault("multi-output", sessionInput.value.trim(), "MapStudio-Multi");
    }
  });
  row.appendChild(choose);
  const remove = document.createElement("button");
  remove.className = "remove-device";
  remove.type = "button";
  remove.textContent = "删除";
  remove.setAttribute("aria-label", "删除设备");
  remove.addEventListener("click", () => row.remove());
  row.appendChild(remove);
  list.appendChild(row);
}

function parseSegments(raw) {
  const values = new Set();
  raw.split(",").map((part) => part.trim()).filter(Boolean).forEach((part) => {
    const range = part.match(/^(\d+)(?:\s*-\s*(\d+))?$/);
    if (!range) throw new Error(`无效的分段范围: ${part}`);
    const first = Number(range[1]);
    const last = Number(range[2] || range[1]);
    if (first < 1 || last < first || last - first > 10000) throw new Error(`无效的分段范围: ${part}`);
    for (let index = first; index <= last; index += 1) values.add(index);
  });
  return [...values].sort((a, b) => a - b);
}

function stageConfig() {
  if (currentSingleScanMode === "continuous_streaming") return undefined;
  const rows = $$(".stage-row");
  if (!rows.length) return undefined;
  const assigned = new Set();
  const stages = rows.map((row, index) => {
    const name = row.querySelector(".stage-name").value.trim() || `阶段 ${index + 1}`;
    const segments = parseSegments(row.querySelector(".stage-segments").value.trim());
    if (!segments.length) throw new Error(`${name} 未设置分段`);
    segments.forEach((segment) => {
      if (assigned.has(segment)) throw new Error(`分段 ${segment} 被分配到多个阶段`);
      assigned.add(segment);
    });
    return {
      id: `stage_${index + 1}`,
      name,
      role: index === 0 ? "anchor" : "normal",
      segments,
      transform: {
        dx: row.querySelector(".stage-dx").value,
        dy: row.querySelector(".stage-dy").value,
        yaw_deg: row.querySelector(".stage-yaw").value,
      },
    };
  });
  return { format: "SupermarketStageConfig", version: 1, stages };
}

function addStage() {
  if (currentSingleScanMode === "continuous_streaming") return;
  const list = $("#stage-list");
  const number = list.children.length + 1;
  const row = document.createElement("div");
  row.className = "stage-row";
  row.appendChild(labelledInput("名称", "stage-name", "text", `阶段 ${number}`));
  row.appendChild(labelledInput("分段", "stage-segments", "text"));
  row.appendChild(labelledInput("dx (m)", "stage-dx", "number", "0", "0.1"));
  row.appendChild(labelledInput("dy (m)", "stage-dy", "number", "0", "0.1"));
  row.appendChild(labelledInput("yaw (deg)", "stage-yaw", "number", "0", "0.1"));
  const remove = document.createElement("button");
  remove.className = "remove-device";
  remove.type = "button";
  remove.textContent = "删除";
  remove.setAttribute("aria-label", "删除阶段");
  remove.addEventListener("click", () => {
    row.remove();
    updateSingleAlignmentState();
  });
  row.appendChild(remove);
  list.appendChild(row);
  updateSingleAlignmentState();
}

function updateSingleAlignmentState() {
  const autoAlign = $("#single-auto-align");
  const legacyOptions = $("#legacy-segment-options");
  const hasStages = $("#stage-list").children.length > 0;
  const streaming = currentSingleScanMode === "continuous_streaming";
  const offlineOptimize = $("#option-offline-optimize");
  const offlineUnsupported = activeMode === "single" && currentSingleOfflineSupported === false;
  if (hasStages || streaming) autoAlign.checked = false;
  autoAlign.disabled = hasStages || streaming;
  legacyOptions.hidden = streaming;
  if (streaming) legacyOptions.open = false;
  $("#add-stage").disabled = streaming;
  $$("#stage-list input, #stage-list button").forEach((control) => { control.disabled = streaming; });
  if (offlineUnsupported) offlineOptimize.checked = false;
  offlineOptimize.disabled = offlineUnsupported;
  const pcExecutionDisabled = offlineUnsupported || !offlineOptimize.checked;
  $("#option-pc-threads").disabled = pcExecutionDisabled;
  $("#option-pc-local-staging").disabled = pcExecutionDisabled;
  offlineOptimize.title = offlineUnsupported
    ? "传统多段会话应先按边界信息合并；当前逐库离线重处理仅接受每台设备一个连续数据库。"
    : "";
}

function updatePriorLegacyState() {
  const legacy = $("#prior-legacy-element-only").checked;
  const storeID = $("#prior-store-id");
  const mapName = $("#prior-name");
  storeID.required = legacy;
  mapName.required = legacy;
  $("#prior-store-id-label").textContent = legacy ? "门店 ID（旧版必填）" : "门店 ID 断言（可选）";
  $("#prior-name-label").textContent = legacy ? "地图名称（旧版必填）" : "地图名称断言（可选）";
  storeID.placeholder = legacy ? "例如：STORE-6599" : "默认读取 Basic Info.storeCode";
  mapName.placeholder = legacy ? "例如：6599 门店货架图" : "默认读取 Basic Info.map_name";
  $("#prior-legacy-hint").textContent = legacy
    ? "已开启旧版兼容：只读取 Element Info；门店 ID 和地图名称由操作者提供并写入地图包，源 Excel 仍保持只读。"
    : "默认关闭并按正式模板严格校验。旧版兼容模式必须由操作者明确开启，并填写真实门店 ID 和地图名称。";
}

function activeRequest() {
  if (activeMode === "prior") {
    const mapName = $("#prior-name").value;
    const storeID = $("#prior-store-id").value;
    return {
      kind: "prior_map",
      xlsx: $("#prior-xlsx").value.trim(),
      output: $("#prior-output").value.trim(),
      store_id: storeID === "" ? null : storeID,
      name: mapName === "" ? null : mapName,
      allow_legacy_element_only: $("#prior-legacy-element-only").checked,
    };
  }
  if (activeMode === "single") {
    const stages = stageConfig();
    return {
      kind: stages ? "stage" : "map",
      session: $("#single-session").value.trim(),
      output: $("#single-output").value.trim(),
      points_csv: $("#single-points").value.trim() ? [$("#single-points").value.trim()] : [],
      auto_align_segments: $("#single-auto-align").checked,
      stage_config: stages,
      options: mapOptions(),
    };
  }
  if (activeMode === "localized") {
    return {
      kind: "localized",
      prior_map: $("#localized-prior-map").value.trim(),
      session: $("#localized-session").value.trim(),
      manual_edits: $("#localized-edits").value.trim(),
      output: $("#localized-output").value.trim(),
      diagnostic_mode: $("#localized-diagnostic-mode").checked,
      options: { ...mapOptions(), offline_optimize: true },
    };
  }
  return {
    kind: "multi",
    devices: deviceRows(),
    output: $("#multi-output").value.trim(),
    align_common_start: $("#multi-common-start").checked,
    options: mapOptions(),
  };
}

function activeRequestKey(payload) {
  const comparable = JSON.parse(JSON.stringify(payload));
  const outputId = payload.kind === "multi"
    ? "multi-output"
    : (payload.kind === "prior_map"
      ? "prior-output"
      : (payload.kind === "localized" ? "localized-output" : "single-output"));
  if ($("#" + outputId).dataset.autoOutput === "true") delete comparable.output;
  return JSON.stringify(comparable);
}

async function runActiveJob() {
  try {
    let payload = activeRequest();
    if (payload.kind === "prior_map") {
      if (payload.store_id !== null && payload.store_id.trim() !== payload.store_id) {
        throw new Error("门店 ID 断言不能包含首尾空格");
      }
      if (payload.name !== null && payload.name.trim() !== payload.name) {
        throw new Error("地图名称不能包含首尾空格");
      }
      if (payload.allow_legacy_element_only && payload.store_id === null) {
        throw new Error("旧版仅 Element Info 导入必须填写真实门店 ID");
      }
      if (payload.allow_legacy_element_only && payload.name === null) {
        throw new Error("旧版仅 Element Info 导入必须填写地图名称");
      }
    }
    let requestKey = activeRequestKey(payload);
    if (completedJobId && completedJobKey === requestKey) {
      setStatus("当前设置已经生成，继续显示上次结果", "complete");
      return;
    }
    if (activeMode === "single" && $("#single-output").dataset.restored === "true") {
      const output = $("#single-output");
      output.value = defaultOutputPath(payload.session, "MapStudio-Single");
      output.dataset.autoOutput = "true";
      output.dataset.restored = "false";
      payload = activeRequest();
      requestKey = activeRequestKey(payload);
    }
    setBusy(true);
    setStatus("正在创建任务", "running");
    const endpoint = payload.kind === "prior_map" ? "/api/prior-map/convert" : "/api/jobs";
    const job = await request(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    activeJobId = job.id;
    activeJobKey = requestKey;
    renderJobProgress(job);
    renderJobLogs(job.logs || []);
    pollJob();
  } catch (error) {
    activeJobKey = null;
    setBusy(false);
    setStatus(error.message, "failed");
  }
}

async function pollJob() {
  if (!activeJobId) return;
  try {
    const job = await request(`/api/jobs/${activeJobId}`);
    renderJobProgress(job);
    renderJobLogs(job.logs || []);
    if (["queued", "running", "cancelling"].includes(job.status)) {
      setStatus(`${job.stage || "正在处理"} · ${job.progress || 0}%`, "running");
      window.setTimeout(pollJob, 650);
      return;
    }
    activeJobId = null;
    setBusy(false);
    if (["failed", "cancelled", "interrupted"].includes(job.status)) {
      activeJobKey = null;
      const label = job.status === "cancelled" ? "任务已取消" : (job.status === "interrupted" ? "任务因服务重启而中断" : "任务失败");
      setStatus(job.error || label, "failed");
      return;
    }
    completedJobId = job.id;
    completedJobKey = activeJobKey;
    activeJobKey = null;
    $("#open-output").disabled = false;
    const warningCount = (job.quality_report?.warnings || []).length
      + (job.quality_report?.multi_device_summary?.alignment_warnings || []).length;
    const completionLabel = job.kind === "prior_map"
      ? "先验地图导入完成"
      : (job.kind === "localized" ? "先验地图会话优化完成" : "地图生成完成");
    setStatus(warningCount ? `${completionLabel}（${warningCount} 条警告）` : completionLabel, "complete");
    await renderJob(job);
  } catch (error) {
    activeJobId = null;
    activeJobKey = null;
    setBusy(false);
    setStatus(error.message, "failed");
  }
}

async function restoreLatestJob() {
  try {
    const payload = await request("/api/jobs");
    const latest = (payload.jobs || [])[0];
    if (!latest) return;
    renderJobProgress(latest);
    renderJobLogs(latest.logs || []);
    if (["queued", "running", "cancelling"].includes(latest.status)) {
      activeJobId = latest.id;
      setBusy(true);
      setStatus(`已恢复任务连接 · ${latest.stage || "正在处理"}`, "running");
      pollJob();
      return;
    }
    if (latest.status === "complete") {
      const complete = await request(`/api/jobs/${latest.id}`);
      completedJobId = complete.id;
      $("#open-output").disabled = false;
      setStatus("已恢复上次完成任务", "complete");
      await renderJob(complete);
      return;
    }
    if (latest.status === "interrupted") {
      setStatus(latest.error || "上次任务因服务重启而中断；旧成果指针保持不变", "failed");
    }
  } catch (error) {
    setStatus(`任务历史恢复失败：${error.message}`, "failed");
  }
}

async function renderJob(job) {
  exitManualMerge();
  manualMerge.baseJobId = job.id;
  manualMerge.available = Boolean(
    job.status === "complete" &&
    job.artifacts?.["preview_layers.json"] &&
    ["map", "merge"].includes(job.kind),
  );
  $("#merge-toggle").hidden = !manualMerge.available;
  $("#localized-review-editor").hidden = job.kind !== "localized";
  if (job.kind === "localized") {
    localizedReview.versionId = job.localized?.version_id || null;
    localizedReview.revision = Number.isInteger(job.localized?.revision)
      ? job.localized.revision
      : null;
    localizedReview.publishState = job.localized?.publish_state || null;
    localizedReview.publishedVersionId = job.localized?.published?.version_id || null;
    localizedReview.publishedRevision = Number.isInteger(job.localized?.published?.revision)
      ? job.localized.published.revision
      : null;
    localizedReview.publishedState = job.localized?.published?.publish_state || null;
    localizedReview.reviewArtifactUrl = job.artifacts?.["localized_review.json"] || null;
    syncLocalizedStateButtons();
  } else {
    localizedReview.versionId = null;
    localizedReview.revision = null;
    localizedReview.publishState = null;
    localizedReview.publishedVersionId = null;
    localizedReview.publishedRevision = null;
    localizedReview.publishedState = null;
    localizedReview.reviewArtifactUrl = null;
  }
  const shelfLoadToken = ++shelfTuning.loadToken;
  clearShelfTuning(Boolean(job.artifacts?.["shelf_outline_evidence.json"]));
  renderJobProgress(job);
  renderJobLogs(job.logs || []);
  renderReview(job.quality_report || {}, job.review_items || { items: [] });
  renderArtifacts(job.artifacts || {});
  const artifacts = job.artifacts || {};
  if (job.kind === "prior_map") {
    clearShelfTuning(false);
    $("#merge-toggle").hidden = true;
    viewer2d.images["2d-map"] = null;
    viewer2d.images["2d-shelf"] = null;
    if (artifacts["preview.png"]) {
      await load2D(artifacts["preview.png"], "2d-map");
      updatePreview("2d-map");
    }
    const manifest = job.map || {};
    const stats = manifest.element_statistics || {};
    const floors = (manifest.floors || []).map((item) => item.id).join("、") || "无";
    const bounds = manifest.bounds || {};
    previewMeta.textContent = `先验地图 ${manifest.name || ""}  |  楼层 ${floors}  |  ${Number(bounds.width_m || 0).toFixed(2)} × ${Number(bounds.height_m || 0).toFixed(2)} m  |  ${Number(manifest.element_count || 0).toLocaleString()} 个元素`;
    const inspection = $("#inspection");
    clearNode(inspection);
    appendText(inspection, "div", `地图 ID：${manifest.prior_map_id || "未知"}`, "complete");
    appendText(inspection, "div", `源文件 SHA-256：${manifest.source_sha256 || "缺失"}`);
    appendText(inspection, "div", `楼层：${floors}；货架 ${Number(manifest.shelf_count ?? stats.MapShelf ?? 0).toLocaleString()}，固定结构 ${Number(manifest.fixed_structure_count ?? 0).toLocaleString()}，道路 ${Number(manifest.road_element_count ?? 0).toLocaleString()}，忽略展示元素 ${Number(manifest.presentation_ignored_count ?? 0).toLocaleString()}`);
    appendText(inspection, "div", "阶段二实验能力：已启用有界 LiDAR 结构匹配；正式真机场测和大范围自动恢复尚未完成。", "warning");
    return;
  }
  viewer2d.images["2d-map"] = null;
  viewer2d.images["2d-shelf"] = null;
  $("#shelf-preview-tab").hidden = true;
  if (activePreview === "2d-shelf" && !artifacts["shelf_outline.png"]) updatePreview("2d-map");
  if (artifacts["preview.png"]) load2D(artifacts["preview.png"], "2d-map");
  const shelfImagePromise = artifacts["shelf_outline.png"]
    ? load2D(artifacts["shelf_outline.png"], "2d-shelf")
    : Promise.resolve(null);
  const evidencePromise = artifacts["shelf_outline_evidence.json"]
    ? request(artifacts["shelf_outline_evidence.json"]).catch(() => null)
    : Promise.resolve(null);
  await shelfImagePromise;
  const evidence = await evidencePromise;
  if (shelfLoadToken === shelfTuning.loadToken) {
    shelfTuning.loading = false;
    if (evidence) installShelfEvidence(evidence);
    else syncShelfTuningVisibility();
  }
  if (artifacts["preview_3d.json"]) {
    const previewUrl = artifacts["preview_3d.json"];
    const data = await request(previewUrl);
    load3D(data, previewUrl);
  }
  const summary = job.quality_report?.grid;
  const cloud = job.quality_report?.preview_3d;
  const qualityLabels = { quick: "快速", detailed: "详细", maximum: "最高" };
  const quality = job.map?.preview_3d_quality;
  const qualityText = qualityLabels[quality] ? ` / ${qualityLabels[quality]}质量` : "";
  const surfaceText = cloud?.surface_triangle_count ? ` / ${cloud.surface_triangle_count.toLocaleString()} 面` : "";
  const cloudText = cloud?.point_count ? `  |  3D ${cloud.point_count.toLocaleString()} 点${surfaceText} / ${cloud.decoded_frames} 关键帧${qualityText}` : "";
  const shelf = job.quality_report?.shelf_outline;
  const shelfText = shelf?.cell_count
    ? `  |  闭合货架轮廓 ${Number(shelf.closed_contour_count || shelf.region_count || shelf.component_count || 0).toLocaleString()} 个 / ${Number(shelf.area_m2 || 0).toFixed(1)} m² 占地 / 拆分 ${Number(shelf.bridge_split_count || 0).toLocaleString()} 处粘连`
    : "";
  previewMeta.textContent = summary ? `${summary.width} x ${summary.height} 栅格  |  ${summary.resolution_m} m  |  ${Number(summary.area_m2).toFixed(2)} m2${shelfText}${cloudText}` : job.output_dir;
  if (job.kind === "localized" && job.artifacts?.["localization_report.json"]) {
    const report = await request(job.artifacts["localization_report.json"]);
    const inspection = $("#inspection");
    clearNode(inspection);
    if (report.diagnostic_only === true) {
      appendText(
        inspection,
        "div",
        `测试诊断草稿：已忽略 ${Number(report.ignored_conflicting_source_constraint_count || 0)} 条冲突手机定位约束；仅用于准确率、累计误差和人工复核，禁止发布。`,
        "warning",
      );
    }
    appendText(
      inspection,
      "div",
      report.publish_gate?.passed === true
        ? "发布门禁：已通过，仍需明确现场验收"
        : "发布门禁：未通过，仅限草稿/人工复核",
      report.publish_gate?.passed === true ? "complete" : "warning",
    );
    appendText(
      inspection,
      "div",
      `成果状态 ${job.localized?.publish_state || report.publish_state || "未知"} · 版本 ${localizedReview.versionId || "缺失"} · revision ${localizedReview.revision ?? "缺失"}`,
    );
    appendText(inspection, "div", `轨迹节点 ${report.node_count || 0} · 地图约束接受率 ${Math.round(Number(report.map_constraint_acceptance_rate || 0) * 100)}% · 最大修正 ${Number(report.maximum_correction_m || 0).toFixed(2)} m`);
    const correction = report.correction_distribution_m || {};
    appendText(
      inspection,
      "div",
      `累计修正 中位 ${Number(correction.median || 0).toFixed(3)} m · P95 ${Number(correction.p95 || 0).toFixed(3)} m · 最大 ${Number(correction.maximum || 0).toFixed(3)} m · weak/lost ${Number(report.weak_lost_duration_seconds || 0).toFixed(1)} s`,
    );
    appendText(
      inspection,
      "div",
      `轨迹长度 在线 ${Number(report.online_trajectory_length_m || 0).toFixed(2)} m · RTAB-Map ${Number(report.rtabmap_trajectory_length_m || 0).toFixed(2)} m · 离线 ${Number(report.offline_trajectory_length_m || 0).toFixed(2)} m · 求解器 ${report.solver?.type || "未知"}`,
    );
    appendText(inspection, "div", `价签 ${report.tag_total || 0} · 已确认 ${report.tag_confirmed || 0} · 待复核 ${report.tag_needs_review || 0}`);
    appendText(inspection, "div", "人工锚点、禁用约束和价签修改保存在 manual_edits.json；重新处理会校验地图/会话 hash 后重放。");
    await loadLocalizedReview(job.artifacts?.["localized_review.json"]);
  }
}

function localizedTagPosition(tag) {
  const position = tag.final_map_position || tag.online_map_position || tag.snapped_map_position;
  if (!position) return null;
  const x = Number(position.x_m);
  const y = Number(position.y_m);
  return Number.isFinite(x) && Number.isFinite(y) ? [x, y] : null;
}

function localizedReviewBounds(data) {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  const include = (point) => {
    const x = Number(point?.[0]);
    const y = Number(point?.[1]);
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    minX = Math.min(minX, x);
    minY = Math.min(minY, y);
    maxX = Math.max(maxX, x);
    maxY = Math.max(maxY, y);
  };
  (data.elements || []).forEach((element) => {
    (element.geometry?.coordinates || []).forEach(include);
  });
  (data.trajectory?.features || []).forEach((feature) => {
    (feature.geometry?.coordinates || []).forEach(include);
  });
  (data.tags || []).forEach((tag) => {
    const point = localizedTagPosition(tag);
    if (point) include(point);
  });
  return Number.isFinite(minX) ? [minX, minY, maxX, maxY] : [-1, -1, 1, 1];
}

function drawLocalizedReview() {
  const canvas = $("#localized-review-canvas");
  const data = localizedReview.data;
  if (!canvas || !data) return;
  const ratio = window.devicePixelRatio || 1;
  const width = Math.max(1, Math.floor(canvas.clientWidth * ratio));
  const height = Math.max(1, Math.floor(canvas.clientHeight * ratio));
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d");
  context.fillStyle = cssColor("--canvas-bg", "#ecf0f2");
  context.fillRect(0, 0, width, height);
  const [minX, minY, maxX, maxY] = localizedReviewBounds(data);
  const padding = 18 * ratio;
  const scale = Math.min(
    (width - padding * 2) / Math.max(1.0e-6, maxX - minX),
    (height - padding * 2) / Math.max(1.0e-6, maxY - minY),
  );
  const project = (point) => [
    padding + (Number(point[0]) - minX) * scale,
    height - padding - (Number(point[1]) - minY) * scale,
  ];
  localizedReview.canvasProjection = {
    ratio,
    project,
    unproject: (point) => [
      minX + (Number(point[0]) - padding) / scale,
      minY + (height - padding - Number(point[1])) / scale,
    ],
  };
  context.lineJoin = "round";
  (data.elements || []).forEach((element) => {
    const points = element.geometry?.coordinates || [];
    if (points.length < 2) return;
    context.beginPath();
    points.forEach((point, index) => {
      const projected = project(point);
      if (index) context.lineTo(projected[0], projected[1]);
      else context.moveTo(projected[0], projected[1]);
    });
    if (element.geometry?.type === "Polygon") context.closePath();
    context.strokeStyle = cssColor("--structure", "#343b40");
    context.globalAlpha = 0.55;
    context.lineWidth = Math.max(1, ratio);
    context.stroke();
  });
  context.globalAlpha = 1;
  const colors = {
    online_localization: "#d88921",
    rtabmap_optimized: "#3988d1",
    prior_map_offline_optimized: "#18a06b",
  };
  (data.trajectory?.features || []).forEach((feature) => {
    const points = feature.geometry?.coordinates || [];
    context.beginPath();
    points.forEach((point, index) => {
      const projected = project(point);
      if (index) context.lineTo(projected[0], projected[1]);
      else context.moveTo(projected[0], projected[1]);
    });
    context.strokeStyle = colors[feature.properties?.layer] || "#888";
    context.lineWidth = 2.2 * ratio;
    context.stroke();
  });
  (data.tags || []).forEach((tag) => {
    const point = localizedTagPosition(tag);
    if (!point) return;
    const projected = project(point);
    const selected = String(tag.tag_id) === localizedReview.selectedTagId;
    context.beginPath();
    context.arc(projected[0], projected[1], (selected ? 6 : 4) * ratio, 0, Math.PI * 2);
    context.fillStyle = tag.needs_review ? "#d88921" : "#18a06b";
    context.fill();
    if (selected) {
      context.strokeStyle = "#ffffff";
      context.lineWidth = 2 * ratio;
      context.stroke();
    }
  });
  const anchor = localizedReview.anchorDraft;
  if (anchor) {
    const source = project([anchor.source_x_m, anchor.source_y_m]);
    const target = project([anchor.x_m, anchor.y_m]);
    context.save();
    context.strokeStyle = "#e04f3f";
    context.fillStyle = "#e04f3f";
    context.lineWidth = 2 * ratio;
    context.setLineDash([5 * ratio, 4 * ratio]);
    context.beginPath();
    context.moveTo(source[0], source[1]);
    context.lineTo(target[0], target[1]);
    context.stroke();
    context.setLineDash([]);
    context.translate(target[0], target[1]);
    context.rotate(-anchor.yaw_rad);
    context.beginPath();
    context.moveTo(0, -10 * ratio);
    context.lineTo(6 * ratio, 7 * ratio);
    context.lineTo(0, 4 * ratio);
    context.lineTo(-6 * ratio, 7 * ratio);
    context.closePath();
    context.fill();
    context.restore();
  }
}

function localizedCanvasPoint(event) {
  const canvas = $("#localized-review-canvas");
  const rect = canvas.getBoundingClientRect();
  return [
    (event.clientX - rect.left) * canvas.width / Math.max(1, rect.width),
    (event.clientY - rect.top) * canvas.height / Math.max(1, rect.height),
  ];
}

function updateLocalizedAnchorSummary() {
  const anchor = localizedReview.anchorDraft;
  $("#localized-map-anchor-summary").textContent = anchor
    ? `节点 ${anchor.node_id ?? "—"} · 时间 ${Number(anchor.timestamp).toFixed(2)} s · 目标 ${anchor.x_m.toFixed(2)}, ${anchor.y_m.toFixed(2)} m`
    : "尚未选择轨迹点";
  if (anchor) {
    const degrees = Math.round(anchor.yaw_rad * 180 / Math.PI);
    $("#localized-map-anchor-yaw").value = String(degrees);
    $("#localized-map-anchor-yaw-value").value = `${degrees}°`;
  }
}

function beginLocalizedAnchor(event) {
  if ($("#localized-edit-type").value !== "set_anchor" || !localizedReview.data) return;
  const projection = localizedReview.canvasProjection;
  if (!projection) return;
  const point = localizedCanvasPoint(event);
  const feature = (localizedReview.data.trajectory?.features || []).find(
    (item) => item.properties?.layer === "prior_map_offline_optimized",
  );
  const coordinates = feature?.geometry?.coordinates || [];
  const timestamps = feature?.properties?.timestamps || [];
  const nodeIds = feature?.properties?.node_ids || [];
  if (!coordinates.length || timestamps.length !== coordinates.length) {
    $("#localized-edit-status").textContent = "当前结果缺少轨迹时间索引，请用修复后的版本重新处理";
    return;
  }
  let bestIndex = -1;
  let bestDistance = Infinity;
  coordinates.forEach((coordinate, index) => {
    const projected = projection.project(coordinate);
    const distance = Math.hypot(projected[0] - point[0], projected[1] - point[1]);
    if (distance < bestDistance) {
      bestDistance = distance;
      bestIndex = index;
    }
  });
  if (bestIndex < 0 || bestDistance > 32 * projection.ratio) {
    $("#localized-edit-status").textContent = "请先点击绿色离线轨迹附近的节点";
    return;
  }
  const nextIndex = Math.min(coordinates.length - 1, bestIndex + 1);
  const previousIndex = Math.max(0, bestIndex - 1);
  const directionStart = coordinates[previousIndex];
  const directionEnd = coordinates[nextIndex];
  const yaw = Math.atan2(
    Number(directionEnd[1]) - Number(directionStart[1]),
    Number(directionEnd[0]) - Number(directionStart[0]),
  );
  localizedReview.anchorDraft = {
    timestamp: Number(timestamps[bestIndex]),
    node_id: nodeIds[bestIndex] ?? null,
    source_x_m: Number(coordinates[bestIndex][0]),
    source_y_m: Number(coordinates[bestIndex][1]),
    x_m: Number(coordinates[bestIndex][0]),
    y_m: Number(coordinates[bestIndex][1]),
    yaw_rad: yaw,
  };
  localizedReview.anchorDragging = true;
  event.currentTarget.setPointerCapture?.(event.pointerId);
  updateLocalizedAnchorSummary();
  drawLocalizedReview();
  event.preventDefault();
}

function dragLocalizedAnchor(event) {
  if (!localizedReview.anchorDragging || !localizedReview.anchorDraft) return;
  const point = localizedCanvasPoint(event);
  const mapPoint = localizedReview.canvasProjection?.unproject(point);
  if (!mapPoint) return;
  localizedReview.anchorDraft.x_m = mapPoint[0];
  localizedReview.anchorDraft.y_m = mapPoint[1];
  updateLocalizedAnchorSummary();
  drawLocalizedReview();
  event.preventDefault();
}

function endLocalizedAnchor(event) {
  if (!localizedReview.anchorDragging) return;
  localizedReview.anchorDragging = false;
  event.currentTarget.releasePointerCapture?.(event.pointerId);
  event.preventDefault();
}

function renderLocalizedReviewList() {
  const target = $("#localized-review-list");
  const data = localizedReview.data;
  clearNode(target);
  if (!data) {
    target.textContent = "该结果没有联动复核数据";
    return;
  }
  const status = $("#localized-tag-filter").value;
  const shelf = $("#localized-shelf-filter").value.trim().toLowerCase();
  const tags = (data.tags || []).filter((tag) => {
    if (status === "review" && tag.needs_review !== true) return false;
    if (status === "approved" && !["approved", "auto_approved"].includes(tag.approval_status)) return false;
    return !shelf || String(tag.shelf_code || "").toLowerCase().includes(shelf);
  });
  tags.forEach((tag) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `localized-review-item${tag.needs_review ? " warning" : ""}`;
    if (String(tag.tag_id) === localizedReview.selectedTagId) button.classList.add("is-selected");
    button.textContent = `${tag.payload || tag.tag_id} · ${tag.shelf_code || "未关联"} ${tag.shelf_side || ""} · ${tag.needs_review ? "待复核" : "已确认"}`;
    button.addEventListener("click", () => {
      localizedReview.selectedTagId = String(tag.tag_id);
      $("#localized-edit-object").value = String(tag.tag_id);
      $("#localized-edit-type").value = tag.needs_review ? "edit_tag" : "approve_tag";
      updateLocalizedEditHelp();
      renderLocalizedReviewList();
      drawLocalizedReview();
    });
    target.appendChild(button);
  });
  (data.review_items || []).slice(0, 100).forEach((item) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "localized-review-item warning";
    button.textContent = item.message || item.id;
    button.addEventListener("click", () => {
      const objectId = item.object_id || item.details?.constraint_id || item.id || "";
      $("#localized-edit-object").value = String(objectId);
      $("#localized-edit-type").value = item.type === "rejected_constraint"
        ? "disable_constraint"
        : "set_anchor";
      updateLocalizedEditHelp();
    });
    target.appendChild(button);
  });
  if (!target.children.length) target.textContent = "当前筛选条件下没有价签或问题";
}

async function loadLocalizedReview(url) {
  localizedReview.data = url ? await request(url) : null;
  localizedReview.selectedTagId = null;
  localizedReview.anchorDraft = null;
  localizedReview.anchorDragging = false;
  updateLocalizedAnchorSummary();
  renderLocalizedReviewList();
  drawLocalizedReview();
}

function updateLocalizedEditHelp() {
  const type = $("#localized-edit-type").value;
  const examples = {
    set_anchor: ["轨迹锚点", '{"timestamp":12.4,"x_m":3.2,"y_m":-5.1,"yaw_rad":0}'],
    disable_constraint: ["输入问题列表中的 constraint ID", "true"],
    assign_interval_to_aisle: ["可填写区间备注 ID", '{"aisle_id":"C1","start_timestamp":12.0,"end_timestamp":30.0}'],
    edit_tag: ["输入 tag ID", '{"shelf_code":"S12","shelf_side":"A","distance_from_shelf_start_cm":125,"height_cm":120}'],
    approve_tag: ["输入 tag ID", ""],
    batch_approve_tags: ["可留空", '["tag-1","tag-2"]'],
  };
  const [objectHelp, valueExample] = examples[type];
  $("#localized-edit-object").placeholder = objectHelp;
  $("#localized-edit-value").placeholder = valueExample || "该操作不需要新值";
  $("#localized-edit-help").textContent = `当前操作：${objectHelp}${valueExample ? `；新值示例 ${valueExample}` : "；无需填写新值"}`;
  const mapAnchor = type === "set_anchor";
  $("#localized-map-anchor-controls").hidden = !mapAnchor;
  $("#localized-map-anchor-help").hidden = !mapAnchor;
  $("#localized-edit-object-field").hidden = mapAnchor;
  $("#localized-edit-value-field").hidden = mapAnchor;
  $("#localized-review-canvas").classList.toggle("anchor-mode", mapAnchor);
  if (mapAnchor) {
    $("#localized-edit-help").textContent = "在画布点击绿色离线轨迹节点，按住拖到正确地图位置；用滑块调整朝向。对象 ID 和 JSON 将自动生成。";
  }
}

async function applyLocalizedEdit(action) {
  if (!completedJobId) {
    setStatus("请先完成一次先验地图会话优化", "failed");
    return;
  }
  const status = $("#localized-edit-status");
  try {
    setBusy(true);
    status.textContent = action === "undo" ? "正在撤销并重放…" : (action === "redo" ? "正在重做并重放…" : "正在应用并重放…");
    if (!localizedReview.versionId || !Number.isInteger(localizedReview.revision)) {
      throw new Error("当前结果缺少版本或 revision，请重新加载任务");
    }
    const payload = {
      action,
      expected_version_id: localizedReview.versionId,
      expected_revision: localizedReview.revision,
    };
    if (action === "append") {
      let newValue = null;
      const type = $("#localized-edit-type").value;
      if (type === "set_anchor") {
        if (!localizedReview.anchorDraft) {
          throw new Error("请先在轨迹画布点击一个节点并拖到正确位置");
        }
        newValue = {
          timestamp: localizedReview.anchorDraft.timestamp,
          x_m: localizedReview.anchorDraft.x_m,
          y_m: localizedReview.anchorDraft.y_m,
          yaw_rad: localizedReview.anchorDraft.yaw_rad,
        };
      } else {
        const text = $("#localized-edit-value").value.trim();
        if (text) {
          try { newValue = JSON.parse(text); }
          catch (_error) { throw new Error("新值必须是有效 JSON"); }
        }
      }
      payload.event = {
        type,
        object_id: type === "set_anchor"
          ? `map-anchor-${localizedReview.anchorDraft.node_id ?? localizedReview.anchorDraft.timestamp}`
          : $("#localized-edit-object").value.trim(),
        new_value: newValue,
        reason: $("#localized-edit-reason").value.trim(),
      };
    }
    const result = await request(`/api/jobs/${completedJobId}/localized/edit`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    status.textContent = `已重放 ${result.cursor}/${result.event_count} 条人工编辑`;
    await renderJob(result.job);
    setStatus("人工编辑已应用，派生结果已重新计算", "complete");
  } catch (error) {
    if (error.status === 409 && completedJobId) {
      try {
        const latest = await request(`/api/jobs/${completedJobId}`);
        await renderJob(latest);
        status.textContent = "版本冲突：已刷新最新结果，请确认后重新应用编辑";
        setStatus(status.textContent, "warning");
        return;
      } catch (_refreshError) {
        // Fall through to the original conflict if refresh also fails.
      }
    }
    status.textContent = error.message;
    setStatus(error.message, "failed");
  } finally {
    setBusy(false);
  }
}

async function applyLocalizedState(action) {
  const expectedVersionId = action === "revoke"
    ? localizedReview.publishedVersionId
    : localizedReview.versionId;
  const expectedRevision = action === "revoke"
    ? localizedReview.publishedRevision
    : localizedReview.revision;
  if (!completedJobId || !expectedVersionId || !Number.isInteger(expectedRevision)) {
    setStatus("当前结果缺少可操作的版本信息", "failed");
    return;
  }
  const reason = $("#localized-edit-reason").value.trim();
  const stateStatus = $("#localized-state-status");
  if (!reason) {
    stateStatus.textContent = "请先填写复核原因/审核说明";
    setStatus(stateStatus.textContent, "failed");
    return;
  }
  try {
    setBusy(true);
    if (action === "publish") {
      if (!$("#localized-field-accepted").checked) {
        throw new Error("发布前必须明确勾选现场验收确认");
      }
      if (!localizedReview.fieldQualification || !localizedReview.fieldQualificationPath) {
        throw new Error("必须先选择并通过服务端验证现场验收证据");
      }
    }
    const result = await request(`/api/jobs/${completedJobId}/localized/state`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action,
        reason,
        expected_version_id: expectedVersionId,
        expected_revision: expectedRevision,
        ...(action === "publish" ? {
          operator_confirmed: true,
          qualification_evidence_path: localizedReview.fieldQualificationPath,
          qualification_evidence_sha256: localizedReview.fieldQualification.file_sha256,
        } : {}),
      }),
    });
    stateStatus.textContent = `状态已更新为 ${result.publish_state}（${result.version_id}）`;
    await renderJob(result.job);
    setStatus("本地化状态已原子更新", "complete");
  } catch (error) {
    if (error.status === 409 && completedJobId) {
      const latest = await request(`/api/jobs/${completedJobId}`).catch(() => null);
      if (latest) await renderJob(latest);
      stateStatus.textContent = "版本冲突：已刷新最新结果";
    } else if (error.status === 422) {
      const codes = (error.payload?.blockers || []).map((item) => item.code).join("、");
      stateStatus.textContent = `${error.message}${codes ? ` 阻断项：${codes}` : ""}`;
    } else {
      stateStatus.textContent = error.message;
    }
    setStatus(stateStatus.textContent, "failed");
  } finally {
    setBusy(false);
  }
}

function renderReview(report, review) {
  const target = $("#review");
  clearNode(target);
  const warnings = [...(report.warnings || []), ...(report.multi_device_summary?.alignment_warnings || [])];
  const items = review.items || [];
  const warningMessages = new Set(warnings.map((warning) => typeof warning === "string" ? warning : warning.message || JSON.stringify(warning)));
  const reviewItems = items.filter((item) => !warningMessages.has(item.message || JSON.stringify(item)));
  appendText(target, "div", `${warnings.length} 条警告  |  ${reviewItems.length} 个待复核项`);
  const optimization = report.pc_offline_processing?.error_optimization;
  if (optimization) {
    const status = optimization.status === "pass" ? "通过" : "需要复核";
    appendText(
      target,
      "div",
      `纯软件误差优化：${status}  |  质量分 ${optimization.quality_score ?? 0}/100  |  未使用 AprilTag/地标先验`,
      optimization.status === "pass" ? "complete" : "warning",
    );
  }
  const acceleration = report.pc_acceleration;
  if (acceleration) {
    const device = acceleration.device ? ` · ${acceleration.device}` : "";
    const projected = acceleration.projected_frames ? ` · GPU 投影 ${acceleration.projected_frames} 帧` : "";
    const accelerationWarning = Boolean(
      acceleration.runtime_failures?.length ||
      acceleration.rtabmap_gpu_fallback_detected ||
      acceleration.warnings?.length
    );
    appendText(
      target,
      "div",
      `计算后端：${acceleration.effective_backend || acceleration.projection_backend || "cpu"}${device}${projected}`,
      accelerationWarning ? "warning" : "complete",
    );
  }
  const list = document.createElement("ul");
  warnings.slice(0, 6).forEach((warning) => appendText(list, "li", typeof warning === "string" ? warning : warning.message || JSON.stringify(warning), "warning"));
  reviewItems.slice(0, 6).forEach((item) => appendText(list, "li", item.message || JSON.stringify(item)));
  if (!warnings.length && !reviewItems.length) appendText(list, "li", "未发现待复核项");
  target.appendChild(list);
}

function renderArtifacts(artifacts) {
  const target = $("#artifacts");
  clearNode(target);
  Object.entries(artifacts).forEach(([name, url]) => {
    const link = document.createElement("a");
    link.className = "artifact-link";
    link.href = url;
    link.target = "_blank";
    link.rel = "noopener";
    link.textContent = name;
    target.appendChild(link);
  });
}

function canvasMetrics(canvas) {
  const rect = canvas.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  const width = Math.max(1, Math.floor(rect.width * ratio));
  const height = Math.max(1, Math.floor(rect.height * ratio));
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
  }
  return { width, height, ratio };
}

function cssColor(name, fallback) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback;
}

function isPlanPreview(kind = activePreview) {
  return kind === "2d-map" || kind === "2d-shelf";
}

function current2DImage() {
  return isPlanPreview() ? viewer2d.images[activePreview] : null;
}

function syncEmptyPreview() {
  emptyPreview.hidden = Boolean((isPlanPreview() && current2DImage()) || (!isPlanPreview() && viewer3d.data));
}

function load2D(url, kind) {
  const image = new Image();
  return new Promise((resolve) => {
    image.onload = () => {
      viewer2d.images[kind] = image;
      if (kind === "2d-shelf") $("#shelf-preview-tab").hidden = false;
      if (activePreview === kind) reset2D();
      syncEmptyPreview();
      syncShelfTuningVisibility();
      if (activePreview === kind) draw2D();
      resolve(image);
    };
    image.onerror = () => resolve(null);
    image.src = `${url}?v=${Date.now()}`;
  });
}

function clearShelfTuning(loading = false) {
  window.clearTimeout(shelfTuning.renderTimer);
  shelfTuning.evidence = null;
  shelfTuning.cellMap = null;
  shelfTuning.cells = [];
  shelfTuning.groundCells = new Set();
  shelfTuning.elevatedCells = new Set();
  shelfTuning.stableElevatedCells = new Set();
  shelfTuning.freeSpaceCells = new Set();
  shelfTuning.elevatedObservationCounts = new Map();
  shelfTuning.defaults = null;
  shelfTuning.loading = loading;
  shelfTuning.profileLabel = "balanced";
  syncShelfTuningVisibility();
}

function syncShelfTuningVisibility() {
  const panel = $("#shelf-tuning");
  const visible = activePreview === "2d-shelf" && !$("#shelf-preview-tab").hidden;
  panel.hidden = !visible;
  if (!visible) return;
  const available = Boolean(shelfTuning.evidence);
  $("#shelf-tuning-controls").hidden = !available;
  $("#shelf-tuning-unavailable").hidden = available;
  $("#shelf-tuning-unavailable").textContent = shelfTuning.loading
    ? "正在载入可调货架证据…"
    : "此结果没有可调证据数据；重新生成地图后即可实时调整货架轮廓。";
}

function boundedNumber(value, fallback, minimum, maximum) {
  const number = Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.max(minimum, Math.min(maximum, number));
}

function normalizedShelfParameters(raw = {}) {
  return {
    minimum_height_span_m: boundedNumber(raw.minimum_height_span_m, 0.38, 0.05, 2),
    minimum_height_above_floor_m: boundedNumber(raw.minimum_height_above_floor_m, 0.48, 0.05, 2.5),
    minimum_verticality: boundedNumber(raw.minimum_verticality, 0.56, 0, 1),
    minimum_triangle_count: Math.round(boundedNumber(raw.minimum_triangle_count, 2, 1, 20)),
    minimum_orientation_coherence: boundedNumber(raw.minimum_orientation_coherence, 0.40, 0, 1),
    minimum_observation_count: Math.round(boundedNumber(raw.minimum_observation_count, 2, 1, 10)),
    minimum_ground_observation_count: Math.round(boundedNumber(raw.minimum_ground_observation_count, 2, 1, 10)),
    maximum_ground_conflict_ratio: boundedNumber(raw.maximum_ground_conflict_ratio, 0.66, 0, 1),
    maximum_fill_distance_m: boundedNumber(raw.maximum_fill_distance_m, 0.62, 0.10, 1.50),
    maximum_ground_search_m: boundedNumber(raw.maximum_ground_search_m, 1.12, 0.20, 2.00),
    minimum_region_area_m2: boundedNumber(raw.minimum_region_area_m2, 0.40, 0.02, 5.00),
    morphology_radius_cells: Math.round(boundedNumber(raw.morphology_radius_cells, 1, 0, 4)),
    minimum_elevated_observation_count: Math.round(boundedNumber(raw.minimum_elevated_observation_count, 2, 1, 10)),
    maximum_hole_area_m2: boundedNumber(raw.maximum_hole_area_m2, 0.90, 0, 3.00),
    minimum_free_observation_count: Math.round(boundedNumber(raw.minimum_free_observation_count, 12, 1, 100000)),
    free_space_margin_m: boundedNumber(raw.free_space_margin_m, 0.0, 0, 0.30),
    maximum_bridge_width_m: boundedNumber(raw.maximum_bridge_width_m, 0.50, 0, 1.00),
    boundary_thickness_cells: Math.round(boundedNumber(raw.boundary_thickness_cells, 2, 1, 4)),
  };
}

function installShelfEvidence(payload) {
  if (payload?.format !== "SupermarketShelfOutlineEvidence" || ![4, 5, 6].includes(payload.version)) return;
  const width = Math.max(1, Math.round(Number(payload.width)));
  const height = Math.max(1, Math.round(Number(payload.height)));
  const rows = Array.isArray(payload.evidence_cells) ? payload.evidence_cells : [];
  if (!Number.isFinite(width) || !Number.isFinite(height)) return;
  const cells = [];
  const cellMap = new Map();
  rows.forEach((row) => {
    if (!Array.isArray(row) || row.length < 6) return;
    const x = Math.round(Number(row[0]));
    const y = Math.round(Number(row[1]));
    const minimumHeight = Number(row[2]);
    const maximumHeight = Number(row[3]);
    const triangleCount = Math.max(1, Number(row[4]));
    const verticality = boundedNumber(row[5], 0, 0, 1);
    if (![x, y, minimumHeight, maximumHeight, triangleCount].every(Number.isFinite)) return;
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    const observationCount = row.length >= 10 ? Math.max(1, Number(row[6])) : 1;
    const orientationCos2 = row.length >= 10 ? Number(row[7]) : 0;
    const orientationSin2 = row.length >= 10 ? Number(row[8]) : 0;
    const orientationCoherence = row.length >= 10 ? boundedNumber(row[9], 0, 0, 1) : 0;
    const orientationWeight = row.length >= 11
      ? boundedNumber(row[10], triangleCount, 0, Number.MAX_SAFE_INTEGER)
      : triangleCount;
    const groundObservationCount = row.length >= 14 ? Math.max(0, Number(row[11])) : 0;
    const groundTriangleCount = row.length >= 14 ? Math.max(0, Number(row[12])) : 0;
    const cell = {
      x, y, minimumHeight, maximumHeight, triangleCount, verticality,
      observationCount, orientationCos2, orientationSin2, orientationCoherence, orientationWeight,
      groundObservationCount, groundTriangleCount,
    };
    cells.push(cell);
    cellMap.set(y * width + x, cell);
  });
  shelfTuning.evidence = {
    width,
    height,
    resolution: boundedNumber(payload.resolution_m, 0.05, 0.001, 10),
    floorHeight: payload.floor_height_m !== null && Number.isFinite(Number(payload.floor_height_m))
      ? Number(payload.floor_height_m)
      : null,
    hasOrientation: payload.has_orientation_evidence ?? (payload.version >= 2),
    hasGroundConflict: payload.has_ground_conflict_evidence ?? (payload.version >= 3),
    sourceFrames: {
      available: Math.max(0, Math.round(Number(payload.source_frames?.available) || 0)),
      sampled: Math.max(0, Math.round(Number(payload.source_frames?.sampled) || 0)),
      decoded: Math.max(0, Math.round(Number(payload.source_frames?.decoded) || 0)),
      pixelStep: Math.max(0, Math.round(Number(payload.source_frames?.pixel_step) || 0)),
    },
  };
  const decodeRuns = (runs) => {
    const decoded = new Set();
    (Array.isArray(runs) ? runs : []).forEach((run) => {
      if (!Array.isArray(run) || run.length < 3) return;
      const imageY = Math.round(Number(run[0]));
      const start = Math.round(Number(run[1]));
      const length = Math.max(0, Math.round(Number(run[2])));
      const y = height - 1 - imageY;
      if (![imageY, start, length].every(Number.isFinite) || y < 0 || y >= height) return;
      for (let x = Math.max(0, start); x < Math.min(width, start + length); x += 1) {
        decoded.add(y * width + x);
      }
    });
    return decoded;
  };
  shelfTuning.cells = cells;
  shelfTuning.cellMap = cellMap;
  shelfTuning.groundCells = decodeRuns(payload.ground_runs);
  shelfTuning.elevatedCells = decodeRuns(payload.elevated_runs);
  shelfTuning.stableElevatedCells = decodeRuns(payload.stable_elevated_runs);
  shelfTuning.freeSpaceCells = decodeRuns(payload.free_space_runs);
  shelfTuning.elevatedObservationCounts = new Map();
  (Array.isArray(payload.elevated_observation_cells) ? payload.elevated_observation_cells : []).forEach((row) => {
    if (!Array.isArray(row) || row.length < 3) return;
    const x = Math.round(Number(row[0]));
    const y = Math.round(Number(row[1]));
    const count = Math.max(1, Math.round(Number(row[2])));
    if (![x, y, count].every(Number.isFinite) || x < 0 || y < 0 || x >= width || y >= height) return;
    shelfTuning.elevatedObservationCounts.set(y * width + x, count);
  });
  shelfTuning.defaults = normalizedShelfParameters(payload.defaults);
  $("#shelf-completeness").value = "50";
  setShelfParameterFields(shelfTuning.defaults);
  updateShelfProfileLabel(50, "balanced");
  syncShelfTuningVisibility();
  renderShelfOutline(shelfTuning.defaults);
}

function interpolateShelfParameters(start, end, fraction) {
  const linear = (key) => start[key] + (end[key] - start[key]) * fraction;
  return normalizedShelfParameters({
    minimum_height_span_m: linear("minimum_height_span_m"),
    minimum_height_above_floor_m: linear("minimum_height_above_floor_m"),
    minimum_verticality: linear("minimum_verticality"),
    minimum_triangle_count: Math.round(linear("minimum_triangle_count")),
    minimum_orientation_coherence: linear("minimum_orientation_coherence"),
    minimum_observation_count: Math.round(linear("minimum_observation_count")),
    minimum_ground_observation_count: Math.round(linear("minimum_ground_observation_count")),
    maximum_ground_conflict_ratio: linear("maximum_ground_conflict_ratio"),
    maximum_fill_distance_m: linear("maximum_fill_distance_m"),
    maximum_ground_search_m: linear("maximum_ground_search_m"),
    minimum_region_area_m2: linear("minimum_region_area_m2"),
    morphology_radius_cells: Math.round(linear("morphology_radius_cells")),
    minimum_elevated_observation_count: Math.round(linear("minimum_elevated_observation_count")),
    maximum_hole_area_m2: linear("maximum_hole_area_m2"),
    minimum_free_observation_count: start.minimum_free_observation_count,
    free_space_margin_m: linear("free_space_margin_m"),
    maximum_bridge_width_m: linear("maximum_bridge_width_m"),
    boundary_thickness_cells: Math.round(linear("boundary_thickness_cells")),
  });
}

function shelfParametersForScore(score) {
  const balanced = shelfTuning.defaults || normalizedShelfParameters();
  const strict = normalizedShelfParameters({
    minimum_height_span_m: Math.max(0.75, balanced.minimum_height_span_m),
    minimum_height_above_floor_m: Math.max(0.80, balanced.minimum_height_above_floor_m),
    minimum_verticality: Math.max(0.78, balanced.minimum_verticality),
    minimum_triangle_count: Math.max(7, balanced.minimum_triangle_count),
    minimum_orientation_coherence: Math.max(0.70, balanced.minimum_orientation_coherence),
    minimum_observation_count: Math.max(3, balanced.minimum_observation_count),
    minimum_ground_observation_count: Math.min(2, balanced.minimum_ground_observation_count),
    maximum_ground_conflict_ratio: Math.min(0.45, balanced.maximum_ground_conflict_ratio),
    maximum_fill_distance_m: Math.min(0.40, balanced.maximum_fill_distance_m),
    maximum_ground_search_m: Math.min(0.80, balanced.maximum_ground_search_m),
    minimum_region_area_m2: Math.max(0.90, balanced.minimum_region_area_m2),
    morphology_radius_cells: Math.max(2, balanced.morphology_radius_cells),
    minimum_elevated_observation_count: Math.max(3, balanced.minimum_elevated_observation_count),
    maximum_hole_area_m2: Math.min(0.25, balanced.maximum_hole_area_m2),
    free_space_margin_m: Math.max(0.05, balanced.free_space_margin_m),
    maximum_bridge_width_m: Math.max(0.55, balanced.maximum_bridge_width_m),
    boundary_thickness_cells: balanced.boundary_thickness_cells,
  });
  const complete = normalizedShelfParameters({
    minimum_height_span_m: Math.min(0.20, balanced.minimum_height_span_m),
    minimum_height_above_floor_m: Math.min(0.30, balanced.minimum_height_above_floor_m),
    minimum_verticality: Math.min(0.45, balanced.minimum_verticality),
    minimum_triangle_count: 1,
    minimum_orientation_coherence: Math.min(0.30, balanced.minimum_orientation_coherence),
    minimum_observation_count: 1,
    minimum_ground_observation_count: Math.max(3, balanced.minimum_ground_observation_count),
    maximum_ground_conflict_ratio: Math.max(0.80, balanced.maximum_ground_conflict_ratio),
    maximum_fill_distance_m: Math.max(0.70, balanced.maximum_fill_distance_m),
    maximum_ground_search_m: Math.max(1.30, balanced.maximum_ground_search_m),
    minimum_region_area_m2: Math.min(0.20, balanced.minimum_region_area_m2),
    morphology_radius_cells: Math.min(1, balanced.morphology_radius_cells),
    minimum_elevated_observation_count: 1,
    maximum_hole_area_m2: Math.max(1.20, balanced.maximum_hole_area_m2),
    free_space_margin_m: 0,
    maximum_bridge_width_m: Math.min(0.25, balanced.maximum_bridge_width_m),
    boundary_thickness_cells: balanced.boundary_thickness_cells,
  });
  return score <= 50
    ? interpolateShelfParameters(strict, balanced, score / 50)
    : interpolateShelfParameters(balanced, complete, (score - 50) / 50);
}

const shelfParameterFields = {
  minimum_height_span_m: "#shelf-min-span",
  minimum_height_above_floor_m: "#shelf-min-height",
  minimum_verticality: "#shelf-min-verticality",
  minimum_triangle_count: "#shelf-min-triangles",
  minimum_orientation_coherence: "#shelf-min-orientation",
  minimum_observation_count: "#shelf-min-observations",
  minimum_ground_observation_count: "#shelf-min-ground-observations",
  maximum_ground_conflict_ratio: "#shelf-max-ground-conflict",
  maximum_fill_distance_m: "#shelf-fill-distance",
  maximum_ground_search_m: "#shelf-ground-search",
  minimum_region_area_m2: "#shelf-min-area",
  morphology_radius_cells: "#shelf-morph-radius",
  minimum_elevated_observation_count: "#shelf-min-elevated-observations",
  maximum_hole_area_m2: "#shelf-max-hole-area",
  free_space_margin_m: "#shelf-free-margin",
  maximum_bridge_width_m: "#shelf-bridge-width",
  boundary_thickness_cells: "#shelf-boundary-thickness",
};

function setShelfParameterFields(parameters) {
  Object.entries(shelfParameterFields).forEach(([key, selector]) => {
    const integer = ["minimum_triangle_count", "minimum_observation_count", "minimum_ground_observation_count", "morphology_radius_cells", "minimum_elevated_observation_count", "boundary_thickness_cells"].includes(key);
    $(selector).value = integer ? String(parameters[key]) : Number(parameters[key]).toFixed(2);
  });
}

function shelfParametersFromFields() {
  const values = {};
  Object.entries(shelfParameterFields).forEach(([key, selector]) => { values[key] = $(selector).value; });
  return normalizedShelfParameters({ ...(shelfTuning.defaults || {}), ...values });
}

function updateShelfProfileLabel(score, label = null) {
  const resolved = label || (score < 35 ? "strict" : score > 65 ? "complete" : "balanced");
  shelfTuning.profileLabel = resolved;
  const names = { strict: "严格降噪", balanced: "平衡", complete: "优先补全", custom: "自定义" };
  $("#shelf-completeness-value").textContent = resolved === "custom" ? names[resolved] : `${names[resolved]} · ${score}`;
  $$('[data-shelf-preset]').forEach((button) => {
    button.classList.toggle("is-active", resolved !== "custom" && Number(button.dataset.shelfPreset) === score);
  });
}

function applyShelfScore(score) {
  const normalizedScore = Math.max(0, Math.min(100, Math.round(score)));
  $("#shelf-completeness").value = String(normalizedScore);
  const parameters = shelfParametersForScore(normalizedScore);
  setShelfParameterFields(parameters);
  updateShelfProfileLabel(normalizedScore);
  scheduleShelfRender(parameters);
}

function scheduleShelfRender(parameters = shelfParametersFromFields()) {
  window.clearTimeout(shelfTuning.renderTimer);
  $("#shelf-tuning-stats").textContent = "正在重算闭合货架轮廓…";
  shelfTuning.renderTimer = window.setTimeout(() => renderShelfOutline(parameters), 80);
}

function orientedShelfCells(candidates, width, height, resolution, parameters) {
  const directions = Array.from({ length: 8 }, (_, index) => {
    const angle = index * Math.PI / 8;
    return [Math.cos(angle), Math.sin(angle)];
  });
  const xy = (key) => {
    const y = Math.floor(key / width);
    return [key - y * width, y];
  };
  const keyAt = (x, y) => y * width + x;
  const inBounds = (x, y) => x >= 0 && y >= 0 && x < width && y < height;
  const compatible = (first, second) => {
    if (first === null || second === null) return true;
    const difference = Math.abs(first - second);
    return Math.min(difference, directions.length - difference) <= 1;
  };
  const rasterLine = (first, second) => {
    let [x0, y0] = first;
    const [x1, y1] = second;
    const dx = Math.abs(x1 - x0);
    const sx = x0 < x1 ? 1 : -1;
    const dy = -Math.abs(y1 - y0);
    const sy = y0 < y1 ? 1 : -1;
    let error = dx + dy;
    const result = [];
    while (true) {
      if (inBounds(x0, y0)) result.push(keyAt(x0, y0));
      if (x0 === x1 && y0 === y1) return result;
      const doubled = 2 * error;
      if (doubled >= dy) { error += dy; x0 += sx; }
      if (doubled <= dx) { error += dx; y0 += sy; }
    }
  };

  let thinned = new Map(candidates);
  const radius = parameters.duplicate_suppression_cells;
  if (radius > 0) {
    thinned = new Map();
    candidates.forEach((metadata, key) => {
      const [x, y] = xy(key);
      const [axisX, axisY] = directions[metadata.direction];
      let suppressed = false;
      for (let oy = -radius; oy <= radius && !suppressed; oy += 1) {
        for (let ox = -radius; ox <= radius; ox += 1) {
          if (ox === 0 && oy === 0) continue;
          const along = Math.abs(ox * axisX + oy * axisY);
          const across = Math.abs(-ox * axisY + oy * axisX);
          if (along > 0.75 || across > radius + 0.25 || !inBounds(x + ox, y + oy)) continue;
          const neighborKey = keyAt(x + ox, y + oy);
          const neighbor = candidates.get(neighborKey);
          if (!neighbor || !compatible(neighbor.direction, metadata.direction)) continue;
          if (neighbor.score > metadata.score || (neighbor.score === metadata.score && neighborKey < key)) {
            suppressed = true;
            break;
          }
        }
      }
      if (!suppressed) thinned.set(key, metadata);
    });

    const supported = new Map();
    const supportRadius = Math.max(2, Math.ceil(parameters.minimum_component_length_m / resolution));
    thinned.forEach((metadata, key) => {
      const [x, y] = xy(key);
      const [axisX, axisY] = directions[metadata.direction];
      const slots = new Set([0]);
      for (let oy = -supportRadius; oy <= supportRadius; oy += 1) {
        for (let ox = -supportRadius; ox <= supportRadius; ox += 1) {
          if (ox === 0 && oy === 0) continue;
          const along = ox * axisX + oy * axisY;
          const across = Math.abs(-ox * axisY + oy * axisX);
          if (Math.abs(along) > supportRadius + 0.5 || across > 1.1 || !inBounds(x + ox, y + oy)) continue;
          const neighbor = thinned.get(keyAt(x + ox, y + oy));
          if (neighbor && compatible(neighbor.direction, metadata.direction)) slots.add(Math.round(along));
        }
      }
      if (slots.size >= 3) supported.set(key, metadata);
    });
    thinned = supported;
  }

  const closed = new Set(thinned.keys());
  const closedDirections = new Map(Array.from(thinned, ([key, value]) => [key, value.direction]));
  thinned.forEach((metadata, key) => {
    const [x, y] = xy(key);
    const [axisX, axisY] = directions[metadata.direction];
    const searchRadius = parameters.maximum_gap_cells + 2;
    let best = null;
    let bestAlong = Infinity;
    for (let oy = -searchRadius; oy <= searchRadius; oy += 1) {
      for (let ox = -searchRadius; ox <= searchRadius; ox += 1) {
        if (!inBounds(x + ox, y + oy)) continue;
        const farKey = keyAt(x + ox, y + oy);
        const far = thinned.get(farKey);
        if (!far || !compatible(far.direction, metadata.direction)) continue;
        const along = Math.abs(ox * axisX + oy * axisY);
        const across = Math.abs(-ox * axisY + oy * axisX);
        if (along <= 1.1 || along > parameters.maximum_gap_cells + 1.6 || across > 0.8) continue;
        if (along < bestAlong) { best = [x + ox, y + oy]; bestAlong = along; }
      }
    }
    if (best) rasterLine([x, y], best).slice(1, -1).forEach((middle) => {
      closed.add(middle);
      closedDirections.set(middle, metadata.direction);
    });
  });

  const minimumCells = Math.max(1, Math.ceil(parameters.minimum_component_length_m / resolution));
  const minimumFragmentCells = Math.max(3, Math.ceil(minimumCells * 0.25));
  const remaining = new Set(closed);
  const components = [];
  while (remaining.size) {
    const start = remaining.values().next().value;
    remaining.delete(start);
    const queue = [start];
    const component = [start];
    for (let index = 0; index < queue.length; index += 1) {
      const key = queue[index];
      const [x, y] = xy(key);
      for (let ny = y - 1; ny <= y + 1; ny += 1) {
        for (let nx = x - 1; nx <= x + 1; nx += 1) {
          if (!inBounds(nx, ny)) continue;
          const neighborKey = keyAt(nx, ny);
          if (!remaining.has(neighborKey)) continue;
          if (!compatible(closedDirections.get(key), closedDirections.get(neighborKey))) continue;
          remaining.delete(neighborKey);
          queue.push(neighborKey);
          component.push(neighborKey);
        }
      }
    }
    if (component.length >= minimumFragmentCells) components.push(component);
  }

  const records = components.map((component) => {
    const counts = new Map();
    component.forEach((key) => {
      const direction = closedDirections.get(key);
      if (direction !== undefined) counts.set(direction, (counts.get(direction) || 0) + 1);
    });
    if (!counts.size) return null;
    const direction = Array.from(counts).sort((a, b) => b[1] - a[1])[0][0];
    const [axisX, axisY] = directions[direction];
    const values = component.map((key) => xy(key));
    const along = values.map(([x, y]) => x * axisX + y * axisY);
    const across = values.map(([x, y]) => -x * axisY + y * axisX).sort((a, b) => a - b);
    return {
      component,
      measured: component.filter((key) => thinned.has(key)),
      direction,
      minimum: Math.min(...along),
      maximum: Math.max(...along),
      normal: across[Math.floor(across.length / 2)],
    };
  }).filter(Boolean);

  const parents = records.map((_, index) => index);
  const find = (index) => {
    let current = index;
    while (parents[current] !== current) { parents[current] = parents[parents[current]]; current = parents[current]; }
    return current;
  };
  const unite = (first, second) => { const a = find(first); const b = find(second); if (a !== b) parents[b] = a; };
  const maxMergeGap = Math.max(12, Math.min(36, parameters.maximum_gap_cells * 3 + 6));
  const maxNormalDistance = Math.max(2.5, parameters.duplicate_suppression_cells + 2);
  records.forEach((first, i) => records.slice(i + 1).forEach((second, offset) => {
    const j = i + 1 + offset;
    if (first.direction !== second.direction || Math.abs(first.normal - second.normal) > maxNormalDistance) return;
    const gap = Math.max(0, first.minimum - second.maximum, second.minimum - first.maximum);
    if (gap <= maxMergeGap) unite(i, j);
  }));

  const grouped = new Map();
  records.forEach((record, index) => {
    const root = find(index);
    if (!grouped.has(root)) grouped.set(root, { direction: record.direction, keys: [], measured: [] });
    grouped.get(root).keys.push(...record.component);
    grouped.get(root).measured.push(...record.measured);
  });
  const fitted = [];
  grouped.forEach((group) => {
    const [axisX, axisY] = directions[group.direction];
    const values = group.keys.map((key) => xy(key));
    const along = values.map(([x, y]) => x * axisX + y * axisY);
    const across = values.map(([x, y]) => -x * axisY + y * axisX).sort((a, b) => a - b);
    const minimum = Math.min(...along);
    const maximum = Math.max(...along);
    const normal = across[Math.floor(across.length / 2)];
    const pointAt = (longitudinal) => [
      Math.round(longitudinal * axisX - normal * axisY),
      Math.round(longitudinal * axisY + normal * axisX),
    ];
    const keys = rasterLine(pointAt(minimum), pointAt(maximum));
    const measuredSlots = new Set(group.measured.map((key) => {
      const [x, y] = xy(key);
      return Math.round(x * axisX + y * axisY);
    }));
    const supportRatio = measuredSlots.size / Math.max(1, keys.length);
    if (keys.length >= minimumCells && supportRatio >= parameters.minimum_line_support_ratio) {
      fitted.push({ direction: group.direction, minimum, maximum, normal, keys, supportRatio });
    }
  });
  const retained = Array.from(new Set(fitted.flatMap((record) => record.keys)));
  return {
    retained,
    componentCount: fitted.length,
    lineCandidateCount: fitted.length,
  };
}

function renderShelfOutlineLegacy(rawParameters) {
  const evidence = shelfTuning.evidence;
  if (!evidence || !shelfTuning.cellMap) return;
  const parameters = normalizedShelfParameters(rawParameters);
  const { width, height, resolution, floorHeight, hasOrientation, hasGroundConflict } = evidence;
  const candidates = hasOrientation ? new Map() : new Set();
  let groundConflictRejected = 0;
  shelfTuning.cells.forEach((source) => {
    let minimumHeight = Infinity;
    let maximumHeight = -Infinity;
    let triangleCount = 0;
    let weightedVerticality = 0;
    let observationCount = 1;
    let orientationCos2 = 0;
    let orientationSin2 = 0;
    let orientationWeight = 0;
    for (let y = source.y - 1; y <= source.y + 1; y += 1) {
      for (let x = source.x - 1; x <= source.x + 1; x += 1) {
        if (x < 0 || y < 0 || x >= width || y >= height) continue;
        const neighbor = shelfTuning.cellMap.get(y * width + x);
        if (!neighbor) continue;
        minimumHeight = Math.min(minimumHeight, neighbor.minimumHeight);
        maximumHeight = Math.max(maximumHeight, neighbor.maximumHeight);
        triangleCount += neighbor.triangleCount;
        weightedVerticality += neighbor.verticality * neighbor.triangleCount;
        observationCount = Math.max(observationCount, neighbor.observationCount);
        orientationCos2 += neighbor.orientationCos2 * neighbor.orientationWeight;
        orientationSin2 += neighbor.orientationSin2 * neighbor.orientationWeight;
        orientationWeight += neighbor.orientationWeight;
      }
    }
    if (maximumHeight - minimumHeight < parameters.minimum_height_span_m) return;
    if (floorHeight !== null && maximumHeight < floorHeight + parameters.minimum_height_above_floor_m) return;
    if (triangleCount < parameters.minimum_triangle_count) return;
    const verticality = weightedVerticality / Math.max(1, triangleCount);
    if (verticality < parameters.minimum_verticality) return;
    const coherence = Math.min(1, Math.hypot(orientationCos2, orientationSin2) / Math.max(1e-9, orientationWeight));
    if (hasOrientation && coherence < parameters.minimum_orientation_coherence) return;
    const groundObservationCount = source.groundObservationCount || 0;
    const groundConflictRatio = groundObservationCount / Math.max(1, groundObservationCount + observationCount);
    if (
      hasGroundConflict
      && groundObservationCount >= parameters.minimum_ground_observation_count
      && groundConflictRatio > parameters.maximum_ground_conflict_ratio
    ) {
      groundConflictRejected += 1;
      return;
    }
    const key = source.y * width + source.x;
    if (hasOrientation) {
      let angle = 0.5 * Math.atan2(orientationSin2, orientationCos2);
      if (angle < 0) angle += Math.PI;
      const direction = Math.round(angle / (Math.PI / 8)) % 8;
      const score = triangleCount * Math.max(0.05, verticality) * (0.5 + coherence) * (1 + Math.log1p(observationCount));
      candidates.set(key, { score, direction, coherence });
    } else {
      candidates.add(key);
    }
  });

  if (hasOrientation) {
    const result = orientedShelfCells(candidates, width, height, resolution, parameters);
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d");
    const pixels = context.createImageData(width, height);
    pixels.data.fill(255);
    result.retained.forEach((key) => {
      const y = Math.floor(key / width);
      const x = key - y * width;
      const offset = ((height - 1 - y) * width + x) * 4;
      pixels.data[offset] = 12;
      pixels.data[offset + 1] = 16;
      pixels.data[offset + 2] = 18;
    });
    context.putImageData(pixels, 0, 0);
    const previous = viewer2d.images["2d-shelf"];
    viewer2d.images["2d-shelf"] = canvas;
    if (activePreview === "2d-shelf") {
      if (!previous || previous.width !== width || previous.height !== height) reset2D();
      else draw2D();
    }
    syncEmptyPreview();
    $("#shelf-tuning-stats").textContent = `${result.lineCandidateCount.toLocaleString()} 条连续轮廓候选 · 过滤 ${groundConflictRejected.toLocaleString()} 个地面冲突 · ${result.retained.length.toLocaleString()} 栅格`;
    return;
  }

  const closed = new Set(candidates);
  for (let gap = 1; gap <= parameters.maximum_gap_cells; gap += 1) {
    candidates.forEach((key) => {
      const y = Math.floor(key / width);
      const x = key - y * width;
      [[1, 0], [0, 1], [1, 1], [1, -1]].forEach(([dx, dy]) => {
        const farX = x + (gap + 1) * dx;
        const farY = y + (gap + 1) * dy;
        if (farX < 0 || farY < 0 || farX >= width || farY >= height) return;
        if (!candidates.has(farY * width + farX)) return;
        for (let step = 1; step <= gap; step += 1) {
          closed.add((y + step * dy) * width + x + step * dx);
        }
      });
    });
  }

  const minimumCells = Math.max(1, Math.ceil(parameters.minimum_component_length_m / resolution));
  const remaining = new Set(closed);
  const retained = [];
  let componentCount = 0;
  while (remaining.size) {
    const start = remaining.values().next().value;
    remaining.delete(start);
    const queue = [start];
    const component = [start];
    for (let index = 0; index < queue.length; index += 1) {
      const key = queue[index];
      const y = Math.floor(key / width);
      const x = key - y * width;
      for (let neighborY = y - 1; neighborY <= y + 1; neighborY += 1) {
        for (let neighborX = x - 1; neighborX <= x + 1; neighborX += 1) {
          if (neighborX < 0 || neighborY < 0 || neighborX >= width || neighborY >= height) continue;
          const neighborKey = neighborY * width + neighborX;
          if (!remaining.delete(neighborKey)) continue;
          queue.push(neighborKey);
          component.push(neighborKey);
        }
      }
    }
    if (component.length < minimumCells) continue;
    retained.push(...component);
    componentCount += 1;
  }

  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d");
  const pixels = context.createImageData(width, height);
  pixels.data.fill(255);
  retained.forEach((key) => {
    const y = Math.floor(key / width);
    const x = key - y * width;
    const offset = ((height - 1 - y) * width + x) * 4;
    pixels.data[offset] = 12;
    pixels.data[offset + 1] = 16;
    pixels.data[offset + 2] = 18;
  });
  context.putImageData(pixels, 0, 0);
  const previous = viewer2d.images["2d-shelf"];
  viewer2d.images["2d-shelf"] = canvas;
  if (activePreview === "2d-shelf") {
    if (!previous || previous.width !== width || previous.height !== height) reset2D();
    else draw2D();
  }
  syncEmptyPreview();
  $("#shelf-tuning-stats").textContent = `${componentCount.toLocaleString()} 组 · ${retained.length.toLocaleString()} 栅格 · 候选 ${candidates.size.toLocaleString()}`;
}

function renderShelfOutline(rawParameters) {
  const evidence = shelfTuning.evidence;
  if (!evidence || !shelfTuning.cellMap) return;
  const parameters = normalizedShelfParameters(rawParameters);
  const { width, height, resolution, floorHeight, hasOrientation, hasGroundConflict } = evidence;
  const keyAt = (x, y) => y * width + x;
  const xy = (key) => {
    const y = Math.floor(key / width);
    return [key - y * width, y];
  };
  const inBounds = (x, y) => x >= 0 && y >= 0 && x < width && y < height;
  const offsetCache = new Map();
  const diskOffsets = (radius) => {
    if (!offsetCache.has(radius)) {
      const offsets = [];
      for (let dy = -radius; dy <= radius; dy += 1) {
        for (let dx = -radius; dx <= radius; dx += 1) {
          if (dx * dx + dy * dy <= radius * radius) offsets.push([dx, dy]);
        }
      }
      offsetCache.set(radius, offsets);
    }
    return offsetCache.get(radius);
  };
  const dilate = (cells, radius) => {
    if (radius <= 0) return new Set(cells);
    const result = new Set();
    const offsets = diskOffsets(radius);
    cells.forEach((key) => {
      const [x, y] = xy(key);
      offsets.forEach(([dx, dy]) => {
        if (inBounds(x + dx, y + dy)) result.add(keyAt(x + dx, y + dy));
      });
    });
    return result;
  };
  const erode = (cells, radius) => {
    if (radius <= 0) return new Set(cells);
    const result = new Set();
    const offsets = diskOffsets(radius);
    cells.forEach((key) => {
      const [x, y] = xy(key);
      if (offsets.every(([dx, dy]) => inBounds(x + dx, y + dy) && cells.has(keyAt(x + dx, y + dy)))) {
        result.add(key);
      }
    });
    return result;
  };
  const subtract = (cells, blocked) => {
    const result = new Set();
    cells.forEach((key) => { if (!blocked.has(key)) result.add(key); });
    return result;
  };
  const publish = (cells, status) => {
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d");
    const pixels = context.createImageData(width, height);
    pixels.data.fill(255);
    cells.forEach((key) => {
      const [x, y] = xy(key);
      const offset = ((height - 1 - y) * width + x) * 4;
      pixels.data[offset] = 12;
      pixels.data[offset + 1] = 16;
      pixels.data[offset + 2] = 18;
    });
    context.putImageData(pixels, 0, 0);
    const previous = viewer2d.images["2d-shelf"];
    viewer2d.images["2d-shelf"] = canvas;
    if (activePreview === "2d-shelf") {
      if (!previous || previous.width !== width || previous.height !== height) reset2D();
      else draw2D();
    }
    syncEmptyPreview();
    $("#shelf-tuning-stats").textContent = status;
  };

  const verticalCandidates = new Set();
  let groundConflictRejected = 0;
  shelfTuning.cells.forEach((source) => {
    let minimumHeight = Infinity;
    let maximumHeight = -Infinity;
    let triangleCount = 0;
    let weightedVerticality = 0;
    let observationCount = 1;
    let orientationCos2 = 0;
    let orientationSin2 = 0;
    let orientationWeight = 0;
    for (let y = source.y - 1; y <= source.y + 1; y += 1) {
      for (let x = source.x - 1; x <= source.x + 1; x += 1) {
        if (!inBounds(x, y)) continue;
        const neighbor = shelfTuning.cellMap.get(keyAt(x, y));
        if (!neighbor) continue;
        minimumHeight = Math.min(minimumHeight, neighbor.minimumHeight);
        maximumHeight = Math.max(maximumHeight, neighbor.maximumHeight);
        triangleCount += neighbor.triangleCount;
        weightedVerticality += neighbor.verticality * neighbor.triangleCount;
        observationCount = Math.max(observationCount, neighbor.observationCount);
        orientationCos2 += neighbor.orientationCos2 * neighbor.orientationWeight;
        orientationSin2 += neighbor.orientationSin2 * neighbor.orientationWeight;
        orientationWeight += neighbor.orientationWeight;
      }
    }
    if (maximumHeight - minimumHeight < parameters.minimum_height_span_m) return;
    if (floorHeight !== null && maximumHeight < floorHeight + parameters.minimum_height_above_floor_m) return;
    if (triangleCount < parameters.minimum_triangle_count) return;
    if (weightedVerticality / Math.max(1, triangleCount) < parameters.minimum_verticality) return;
    const coherence = Math.min(1, Math.hypot(orientationCos2, orientationSin2) / Math.max(1e-9, orientationWeight));
    if (hasOrientation && coherence < parameters.minimum_orientation_coherence) return;
    if (observationCount < parameters.minimum_observation_count) return;
    const groundObservationCount = source.groundObservationCount || 0;
    const conflictRatio = groundObservationCount / Math.max(1, groundObservationCount + observationCount);
    if (
      hasGroundConflict
      && groundObservationCount >= parameters.minimum_ground_observation_count
      && conflictRatio > parameters.maximum_ground_conflict_ratio
    ) {
      groundConflictRejected += 1;
      return;
    }
    if (observationCount < parameters.minimum_observation_count) return;
    verticalCandidates.add(keyAt(source.x, source.y));
  });

  const ground = shelfTuning.groundCells;
  const freeSupport = new Set(ground);
  shelfTuning.freeSpaceCells.forEach((key) => freeSupport.add(key));
  if (!freeSupport.size || !verticalCandidates.size) {
    publish(new Set(), !freeSupport.size
      ? "缺少地板或稳定自由空间证据，未推断未知区域"
      : "当前阈值下没有可靠的货架种子");
    return;
  }
  const stableElevated = new Set();
  if (shelfTuning.elevatedObservationCounts.size) {
    shelfTuning.elevatedCells.forEach((key) => {
      if ((shelfTuning.elevatedObservationCounts.get(key) || 0) >= parameters.minimum_elevated_observation_count) {
        stableElevated.add(key);
      }
    });
  } else {
    shelfTuning.stableElevatedCells.forEach((key) => stableElevated.add(key));
  }

  const nearVertical = dilate(verticalCandidates, Math.max(1, Math.ceil(0.20 / resolution)));
  const measuredSeeds = new Set(verticalCandidates);
  stableElevated.forEach((key) => measuredSeeds.add(key));
  shelfTuning.elevatedCells.forEach((key) => { if (nearVertical.has(key)) measuredSeeds.add(key); });
  ground.forEach((key) => measuredSeeds.delete(key));

  const freeMargin = Math.max(0, Math.ceil(parameters.free_space_margin_m / resolution));
  const protectedFree = dilate(freeSupport, freeMargin);
  measuredSeeds.forEach((key) => protectedFree.delete(key));
  const fillRadius = Math.max(1, Math.ceil(parameters.maximum_fill_distance_m / resolution));
  const groundRadius = Math.max(1, Math.ceil(parameters.maximum_ground_search_m / resolution));
  const grown = subtract(dilate(measuredSeeds, fillRadius), protectedFree);
  const directionPairs = [
    [[1, 0], [-1, 0]],
    [[0, 1], [0, -1]],
    [[1, 1], [-1, -1]],
    [[1, -1], [-1, 1]],
  ];
  const hitsGround = (x, y, dx, dy) => {
    for (let step = 1; step <= groundRadius; step += 1) {
      const targetX = x + dx * step;
      const targetY = y + dy * step;
      if (!inBounds(targetX, targetY)) return false;
      if (freeSupport.has(keyAt(targetX, targetY))) return true;
    }
    return false;
  };
  let footprint = new Set();
  grown.forEach((key) => {
    const [x, y] = xy(key);
    if (directionPairs.some(([first, second]) => (
      hitsGround(x, y, first[0], first[1]) && hitsGround(x, y, second[0], second[1])
    ))) footprint.add(key);
  });
  if (parameters.morphology_radius_cells > 0) {
    const radius = parameters.morphology_radius_cells;
    footprint = dilate(erode(footprint, radius), radius);
    footprint = erode(dilate(footprint, radius), radius);
    footprint = subtract(footprint, protectedFree);
  }

  const smoothed = new Set();
  dilate(footprint, 1).forEach((key) => {
    if (protectedFree.has(key)) return;
    const [x, y] = xy(key);
    let neighbors = 0;
    for (let neighborY = y - 1; neighborY <= y + 1; neighborY += 1) {
      for (let neighborX = x - 1; neighborX <= x + 1; neighborX += 1) {
        if (inBounds(neighborX, neighborY) && footprint.has(keyAt(neighborX, neighborY))) neighbors += 1;
      }
    }
    if (neighbors >= 5 || (footprint.has(key) && neighbors >= 4)) smoothed.add(key);
  });
  footprint = smoothed;

  const connectedComponents = (cells) => {
    const remaining = new Set(cells);
    const components = [];
    while (remaining.size) {
      const start = remaining.values().next().value;
      remaining.delete(start);
      const component = new Set([start]);
      const queue = [start];
      for (let index = 0; index < queue.length; index += 1) {
        const [x, y] = xy(queue[index]);
        for (let neighborY = y - 1; neighborY <= y + 1; neighborY += 1) {
          for (let neighborX = x - 1; neighborX <= x + 1; neighborX += 1) {
            if (!inBounds(neighborX, neighborY) || (neighborX === x && neighborY === y)) continue;
            const neighbor = keyAt(neighborX, neighborY);
            if (!remaining.delete(neighbor)) continue;
            component.add(neighbor);
            queue.push(neighbor);
          }
        }
      }
      components.push(component);
    }
    return components;
  };

  const boundsFor = (component) => {
    let componentMinimumX = width;
    let componentMaximumX = 0;
    let componentMinimumY = height;
    let componentMaximumY = 0;
    component.forEach((key) => {
      const [x, y] = xy(key);
      componentMinimumX = Math.min(componentMinimumX, x);
      componentMaximumX = Math.max(componentMaximumX, x);
      componentMinimumY = Math.min(componentMinimumY, y);
      componentMaximumY = Math.max(componentMaximumY, y);
    });
    return {
      minimumX: Math.max(0, componentMinimumX - 1),
      maximumX: Math.min(width - 1, componentMaximumX + 1),
      minimumY: Math.max(0, componentMinimumY - 1),
      maximumY: Math.min(height - 1, componentMaximumY + 1),
    };
  };

  const exteriorBackground = (component) => {
    const { minimumX, maximumX, minimumY, maximumY } = boundsFor(component);
    const background = new Set();
    for (let y = minimumY; y <= maximumY; y += 1) {
      for (let x = minimumX; x <= maximumX; x += 1) {
        const key = keyAt(x, y);
        if (!component.has(key)) background.add(key);
      }
    }
    const exterior = new Set();
    const queue = [];
    background.forEach((key) => {
      const [x, y] = xy(key);
      if (x === minimumX || x === maximumX || y === minimumY || y === maximumY) {
        exterior.add(key);
        queue.push(key);
      }
    });
    for (let index = 0; index < queue.length; index += 1) {
      const [x, y] = xy(queue[index]);
      [[1, 0], [-1, 0], [0, 1], [0, -1]].forEach(([dx, dy]) => {
        if (!inBounds(x + dx, y + dy)) return;
        const neighbor = keyAt(x + dx, y + dy);
        if (!background.has(neighbor) || exterior.has(neighbor)) return;
        exterior.add(neighbor);
        queue.push(neighbor);
      });
    }
    return { background, exterior };
  };

  const maximumHoleCells = Math.floor(parameters.maximum_hole_area_m2 / (resolution * resolution));
  const fillHoles = (component) => {
    if (!component.size || maximumHoleCells <= 0) return component;
    const { background, exterior } = exteriorBackground(component);
    const interior = new Set();
    background.forEach((key) => { if (!exterior.has(key)) interior.add(key); });
    const filled = new Set(component);
    connectedComponents(interior).forEach((hole) => {
      if (hole.size <= maximumHoleCells) hole.forEach((key) => filled.add(key));
    });
    return filled;
  };

  const minimumCells = Math.max(1, Math.ceil(parameters.minimum_region_area_m2 / (resolution * resolution)));
  let bridgeSplitCount = 0;
  const splitNarrowBridges = (component) => {
    if (parameters.maximum_bridge_width_m <= 0) return [component];
    const splitRadius = Math.max(1, Math.ceil(parameters.maximum_bridge_width_m / (2 * resolution)));
    const coreComponents = connectedComponents(erode(component, splitRadius))
      .filter((core) => core.size >= Math.max(4, Math.floor(minimumCells / 8)));
    if (coreComponents.length <= 1) return [component];

    const owner = new Map();
    const distance = new Map();
    const queue = [];
    coreComponents.forEach((core, label) => {
      core.forEach((key) => {
        owner.set(key, label);
        distance.set(key, 0);
        queue.push(key);
      });
    });
    for (let index = 0; index < queue.length; index += 1) {
      const key = queue[index];
      const label = owner.get(key);
      if (label < 0) continue;
      const [x, y] = xy(key);
      const candidateDistance = distance.get(key) + 1;
      for (let neighborY = y - 1; neighborY <= y + 1; neighborY += 1) {
        for (let neighborX = x - 1; neighborX <= x + 1; neighborX += 1) {
          if (!inBounds(neighborX, neighborY) || (neighborX === x && neighborY === y)) continue;
          const neighbor = keyAt(neighborX, neighborY);
          if (!component.has(neighbor)) continue;
          if (!distance.has(neighbor)) {
            distance.set(neighbor, candidateDistance);
            owner.set(neighbor, label);
            queue.push(neighbor);
          } else if (distance.get(neighbor) === candidateDistance && owner.get(neighbor) !== label) {
            owner.set(neighbor, -1);
          }
        }
      }
    }

    const seam = new Set();
    owner.forEach((label, key) => { if (label < 0) seam.add(key); });
    owner.forEach((label, key) => {
      if (label < 0) return;
      const [x, y] = xy(key);
      for (let neighborY = y - 1; neighborY <= y + 1; neighborY += 1) {
        for (let neighborX = x - 1; neighborX <= x + 1; neighborX += 1) {
          const neighborLabel = owner.has(keyAt(neighborX, neighborY))
            ? owner.get(keyAt(neighborX, neighborY))
            : label;
          if (neighborLabel >= 0 && neighborLabel !== label) seam.add(key);
        }
      }
    });
    const groups = [];
    coreComponents.forEach((_core, label) => {
      const owned = new Set();
      owner.forEach((cellLabel, key) => {
        if (cellLabel === label && !seam.has(key)) owned.add(key);
      });
      connectedComponents(owned).forEach((part) => {
        if (part.size >= minimumCells) groups.push(part);
      });
    });
    if (groups.length >= 2) {
      bridgeSplitCount += groups.length - 1;
      return groups;
    }
    return [component];
  };

  const outerBoundary = (component) => {
    const { exterior } = exteriorBackground(component);
    let boundary = new Set();
    component.forEach((key) => {
      const [x, y] = xy(key);
      if ([[1, 0], [-1, 0], [0, 1], [0, -1]].some(([dx, dy]) => exterior.has(keyAt(x + dx, y + dy)))) {
        boundary.add(key);
      }
    });
    if (parameters.boundary_thickness_cells > 1) {
      const thickened = dilate(boundary, parameters.boundary_thickness_cells - 1);
      boundary = new Set([...thickened].filter((key) => component.has(key)));
    }
    return boundary;
  };

  const footprintComponents = [];
  connectedComponents(footprint).forEach((component) => {
    if (component.size < minimumCells) return;
    splitNarrowBridges(fillHoles(component)).forEach((instance) => {
      if (instance.size >= minimumCells) footprintComponents.push(instance);
    });
  });
  const retainedFootprint = new Set();
  const contours = new Set();
  footprintComponents.forEach((component) => {
    component.forEach((key) => retainedFootprint.add(key));
    outerBoundary(component).forEach((key) => contours.add(key));
  });
  const area = retainedFootprint.size * resolution * resolution;
  let directlySupported = 0;
  retainedFootprint.forEach((key) => { if (measuredSeeds.has(key)) directlySupported += 1; });
  const directSupportRatio = retainedFootprint.size
    ? Math.round((directlySupported / retainedFootprint.size) * 100)
    : 0;
  const sourceFrames = evidence.sourceFrames || {};
  const frameStatus = sourceFrames.sampled
    ? ` · 证据 ${sourceFrames.decoded.toLocaleString()}/${sourceFrames.sampled.toLocaleString()} 帧`
    : "";
  publish(contours, `${footprintComponents.length.toLocaleString()} 个闭合货架轮廓 · ${area.toFixed(1)} m² 占地 · 直接扫描支持 ${directSupportRatio}%${frameStatus} · 拆分 ${bridgeSplitCount.toLocaleString()} 处粘连 · 过滤 ${groundConflictRejected.toLocaleString()} 个地面冲突`);
}

function downloadCurrentShelfOutline() {
  const image = viewer2d.images["2d-shelf"];
  if (!image) return;
  const canvas = document.createElement("canvas");
  canvas.width = image.width;
  canvas.height = image.height;
  canvas.getContext("2d").drawImage(image, 0, 0);
  canvas.toBlob((blob) => {
    if (!blob) return;
    const link = document.createElement("a");
    const suffix = shelfTuning.profileLabel === "custom" ? "custom" : $("#shelf-completeness").value;
    link.href = URL.createObjectURL(blob);
    link.download = `shelf_closed_contours_${suffix}.png`;
    link.click();
    URL.revokeObjectURL(link.href);
  }, "image/png");
}

function reset2D() {
  const image = current2DImage();
  if (!image) return;
  const { width, height } = canvasMetrics(mapCanvas);
  const scale = Math.min(width / image.width, height / image.height) * 0.92;
  viewer2d.scale = scale;
  viewer2d.offsetX = (width - image.width * scale) / 2;
  viewer2d.offsetY = (height - image.height * scale) / 2;
  draw2D();
}

function draw2D() {
  const image = current2DImage();
  if (!image || !isPlanPreview()) return;
  const { width, height, ratio } = canvasMetrics(mapCanvas);
  const ctx = mapCanvas.getContext("2d");
  ctx.fillStyle = activePreview === "2d-shelf" ? "#ffffff" : cssColor("--canvas-bg", "#ecf0f2");
  ctx.fillRect(0, 0, width, height);
  // Downscaling a large metric grid benefits from the browser's best filter;
  // zoomed-in cells remain exact and unsmoothed for engineering inspection.
  ctx.imageSmoothingEnabled = viewer2d.scale / ratio < 1;
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(image, viewer2d.offsetX, viewer2d.offsetY, image.width * viewer2d.scale, image.height * viewer2d.scale);
  drawManualMergeOverlay(ctx, ratio);
}

function imageToCanvas(point) {
  return [
    viewer2d.offsetX + point[0] * viewer2d.scale,
    viewer2d.offsetY + point[1] * viewer2d.scale,
  ];
}

function canvasToImage(point) {
  const image = current2DImage();
  if (!image) return [0, 0];
  return [
    Math.max(0, Math.min(image.width - 1, (point[0] - viewer2d.offsetX) / viewer2d.scale)),
    Math.max(0, Math.min(image.height - 1, (point[1] - viewer2d.offsetY) / viewer2d.scale)),
  ];
}

function normalizedMergeRect(region) {
  const [x0, y0, x1, y1] = region.rect_pixels;
  return [Math.min(x0, x1), Math.min(y0, y1), Math.max(x0, x1), Math.max(y0, y1)];
}

function drawMergeRect(ctx, region, label, color, ratio, dashed = false) {
  const [x0, y0, x1, y1] = normalizedMergeRect(region);
  const start = imageToCanvas([x0, y0]);
  const end = imageToCanvas([x1, y1]);
  ctx.save();
  ctx.strokeStyle = color;
  ctx.fillStyle = color;
  ctx.globalAlpha = 0.95;
  ctx.lineWidth = 2 * ratio;
  ctx.setLineDash(dashed ? [7 * ratio, 5 * ratio] : []);
  ctx.strokeRect(start[0], start[1], end[0] - start[0], end[1] - start[1]);
  ctx.setLineDash([]);
  ctx.font = `${12 * ratio}px -apple-system, BlinkMacSystemFont, sans-serif`;
  ctx.fillRect(start[0], Math.max(0, start[1] - 19 * ratio), 22 * ratio, 18 * ratio);
  ctx.fillStyle = "#ffffff";
  ctx.fillText(label, start[0] + 6 * ratio, Math.max(13 * ratio, start[1] - 5 * ratio));
  ctx.restore();
}

function drawManualMergeOverlay(ctx, ratio) {
  if (!manualMerge.active || activePreview !== "2d-map") return;
  const colors = ["#16825d", "#d36a21"];
  manualMerge.regions.forEach((region, index) => {
    drawMergeRect(ctx, region, index ? "B" : "A", colors[index], ratio);
  });
  if (manualMerge.draft) {
    drawMergeRect(
      ctx,
      { rect_pixels: [...manualMerge.draft.start, ...manualMerge.draft.end] },
      manualMerge.regions.length ? "B" : "A",
      colors[manualMerge.regions.length] || colors[1],
      ratio,
      true,
    );
  }
  const preview = manualMerge.preview;
  if (!preview || manualMerge.regions.length !== 2) return;
  const region = normalizedMergeRect(manualMerge.regions[1]);
  const center = [(region[0] + region[2]) / 2, (region[1] + region[3]) / 2];
  const resolution = Number(preview.geometry?.resolution_m || 0);
  if (!(resolution > 0)) return;
  const dx = Number(preview.alignment?.dx_m || 0) / resolution;
  const dy = -Number(preview.alignment?.dy_m || 0) / resolution;
  const theta = -Number(preview.alignment?.yaw_deg || 0) * Math.PI / 180;
  const cosine = Math.cos(theta);
  const sine = Math.sin(theta);
  const corners = [
    [region[0], region[1]], [region[2], region[1]],
    [region[2], region[3]], [region[0], region[3]],
  ].map((point) => {
    const localX = point[0] - center[0];
    const localY = point[1] - center[1];
    return imageToCanvas([
      center[0] + dx + cosine * localX - sine * localY,
      center[1] + dy + sine * localX + cosine * localY,
    ]);
  });
  ctx.save();
  ctx.strokeStyle = "#8e44ad";
  ctx.lineWidth = 2 * ratio;
  ctx.setLineDash([8 * ratio, 5 * ratio]);
  ctx.beginPath();
  ctx.moveTo(corners[0][0], corners[0][1]);
  corners.slice(1).forEach((point) => ctx.lineTo(point[0], point[1]));
  ctx.closePath();
  ctx.stroke();
  ctx.restore();
}

function setMergeStatus(message, tone = "") {
  const node = $("#merge-status");
  node.textContent = message;
  node.className = tone;
}

function invalidateMergePreview(message = "区域或微调参数已变化，请重新预览约束") {
  manualMerge.preview = null;
  $("#merge-confirm").checked = false;
  $("#merge-apply").disabled = true;
  if (manualMerge.active) setMergeStatus(message);
  draw2D();
}

function resetManualMergeSelection() {
  manualMerge.regions = [];
  manualMerge.draft = null;
  manualMerge.selecting = false;
  manualMerge.preview = null;
  $("#merge-dx").value = "";
  $("#merge-dy").value = "";
  $("#merge-yaw").value = "0";
  $("#merge-confirm").checked = false;
  $("#merge-apply").disabled = true;
  setMergeStatus("尚未选择区域");
  $("#merge-instruction").textContent = "先框选正确的基准区域 A，再框选需要对齐的重影区域 B。按住空格可平移视图。";
  draw2D();
}

function beginManualMerge() {
  if (!manualMerge.available || !manualMerge.baseJobId) return;
  manualMerge.active = true;
  $("#merge-editor").hidden = false;
  mapCanvas.classList.add("merge-selecting");
  updatePreview("2d-map");
  resetManualMergeSelection();
}

function exitManualMerge() {
  manualMerge.active = false;
  manualMerge.regions = [];
  manualMerge.draft = null;
  manualMerge.selecting = false;
  manualMerge.preview = null;
  manualMerge.spacePressed = false;
  const editor = $("#merge-editor");
  if (editor) editor.hidden = true;
  if (mapCanvas) mapCanvas.classList.remove("merge-selecting");
  const apply = $("#merge-apply");
  if (apply) apply.disabled = true;
  if (current2DImage() && isPlanPreview()) draw2D();
}

function manualMergePayload(confirmed = false) {
  if (manualMerge.regions.length !== 2) {
    throw new Error("请先框选基准区域 A 和重影区域 B");
  }
  const alignment = {};
  [
    ["dx_m", "#merge-dx"],
    ["dy_m", "#merge-dy"],
    ["yaw_deg", "#merge-yaw"],
  ].forEach(([key, selector]) => {
    const raw = $(selector).value.trim();
    if (raw !== "") alignment[key] = Number(raw);
  });
  return {
    regions: manualMerge.regions,
    alignment,
    information_level: $("#merge-information").value,
    confirmed,
    points_csv: $("#single-points").value.trim() ? [$("#single-points").value.trim()] : [],
    options: { ...mapOptions(), offline_optimize: true },
  };
}

async function previewManualMerge() {
  try {
    setMergeStatus("正在把框选区域映射到位姿图…");
    const preview = await request(`/api/jobs/${manualMerge.baseJobId}/merge/preview`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(manualMergePayload(false)),
    });
    manualMerge.preview = preview;
    $("#merge-dx").value = Number(preview.alignment.dx_m).toFixed(3);
    $("#merge-dy").value = Number(preview.alignment.dy_m).toFixed(3);
    $("#merge-yaw").value = Number(preview.alignment.yaw_deg).toFixed(2);
    const summary = preview.summary || {};
    const warnings = preview.warnings || [];
    const details = `评分 ${preview.alignment.score}/100 · A ${summary.target_node_count || 0} 节点 · B ${summary.source_node_count || 0} 节点 · ${summary.constraint_count || 0} 条人工闭环 · 中位对应残差 ${summary.median_preview_residual_m ?? "—"} m`;
    setMergeStatus(
      warnings.length ? `${details}；${warnings.join(" ")}` : details,
      preview.can_apply ? (warnings.length ? "warning" : "complete") : "warning",
    );
    $("#merge-confirm").checked = false;
    $("#merge-apply").disabled = true;
    draw2D();
  } catch (error) {
    manualMerge.preview = null;
    setMergeStatus(error.message, "warning");
    $("#merge-apply").disabled = true;
  }
}

async function applyManualMerge() {
  if (!manualMerge.preview?.can_apply || !$("#merge-confirm").checked) return;
  try {
    setBusy(true);
    setStatus("正在创建人工误差修复版本", "running");
    const job = await request(`/api/jobs/${manualMerge.baseJobId}/merge/apply`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(manualMergePayload(true)),
    });
    activeJobId = job.id;
    activeJobKey = null;
    renderJobProgress(job);
    renderJobLogs(job.logs || []);
    pollJob();
  } catch (error) {
    setBusy(false);
    setStatus(error.message, "failed");
  }
}

function previewIsExpanded() {
  const panel = $(".preview-panel");
  return document.fullscreenElement === panel || panel.classList.contains("is-expanded");
}

function updatePreviewFullscreenButton() {
  const expanded = previewIsExpanded();
  const button = $("#preview-fullscreen");
  button.textContent = expanded ? "退出全屏" : "全屏预览";
  button.setAttribute("aria-pressed", String(expanded));
  document.body.classList.toggle("preview-overlay-open", expanded && !document.fullscreenElement);
}

function redrawExpandedPreview() {
  window.requestAnimationFrame(() => {
    if (isPlanPreview()) reset2D();
    else drawScene();
  });
}

async function togglePreviewFullscreen() {
  const panel = $(".preview-panel");
  if (panel.classList.contains("is-expanded")) {
    panel.classList.remove("is-expanded");
  } else if (document.fullscreenElement) {
    await document.exitFullscreen();
  } else if (panel.requestFullscreen) {
    try {
      await panel.requestFullscreen();
    } catch (_error) {
      panel.classList.add("is-expanded");
    }
  } else {
    panel.classList.add("is-expanded");
  }
  updatePreviewFullscreenButton();
  redrawExpandedPreview();
}

function load3D(data, previewUrl = "") {
  const minima = [Infinity, Infinity, Infinity];
  const maxima = [-Infinity, -Infinity, -Infinity];
  let positionCount = 0;
  const includePosition = (point) => {
    if (!point || point.length < 3) return;
    for (let index = 0; index < 3; index += 1) {
      const value = point[index];
      minima[index] = Math.min(minima[index], value);
      maxima[index] = Math.max(maxima[index], value);
    }
    positionCount += 1;
  };
  (data.segments || []).forEach((segment) => (segment.trajectory || []).forEach(includePosition));
  (data.points || []).forEach((point) => includePosition(point.position));
  (data.price_tags || []).forEach((tag) => includePosition(tag.position));
  (data.point_cloud?.points || []).forEach(includePosition);
  (data.point_cloud?.surface_frames || []).forEach((frame) => (frame.vertices || []).forEach(includePosition));
  viewer3d.data = positionCount ? data : null;
  viewer3d.artifactRoot = previewUrl ? previewUrl.slice(0, previewUrl.lastIndexOf("/") + 1) : "";
  viewer3d.surfaceLoadToken += 1;
  const hasSurfaces = Boolean(data.point_cloud?.surface_frames?.length && viewer3d.artifactRoot);
  viewer3d.showSurface = hasSurfaces;
  viewer3d.showCloud = !hasSurfaces;
  $("#show-surface").checked = viewer3d.showSurface;
  $("#show-cloud").checked = viewer3d.showCloud;
  if (positionCount) {
    viewer3d.center = minima.map((value, index) => (value + maxima[index]) / 2);
    viewer3d.viewCenter = [...viewer3d.center];
    viewer3d.span = Math.max(1, maxima[0] - minima[0], maxima[1] - minima[1], maxima[2] - minima[2]);
    viewer3d.planSpan = Math.max(1, maxima[0] - minima[0], maxima[1] - minima[1]);
    viewerTop.center = [...viewer3d.center];
    viewerTop.distance = 1;
  }
  build3DBuffers();
  reset3D();
  syncEmptyPreview();
}

function reset3D() {
  viewer3d.yaw = -0.72;
  viewer3d.pitch = 0.68;
  viewer3d.distance = 1;
  viewer3d.viewCenter = [...viewer3d.center];
  if (activePreview === "3d") drawScene();
}

function resetTopDown() {
  viewerTop.center = [...viewer3d.center];
  viewerTop.distance = 1;
  if (activePreview === "2d-color") drawScene();
}

function compile3DShader(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(shader) || "3D shader compilation failed");
  }
  return shader;
}

function ensure3DRenderer() {
  if (viewer3d.gl && viewer3d.program) return viewer3d.gl;
  const gl = sceneCanvas.getContext("webgl", { antialias: true, alpha: false, depth: true });
  if (!gl) throw new Error("当前浏览器无法创建 WebGL 三维视图");
  const vertex = compile3DShader(gl, gl.VERTEX_SHADER, `
    attribute vec3 a_position;
    attribute vec3 a_color;
    uniform vec3 u_center;
    uniform float u_yaw;
    uniform float u_pitch;
    uniform float u_scale;
    uniform float u_aspect;
    uniform float u_point_size;
    varying vec3 v_color;
    void main() {
      vec3 p = a_position - u_center;
      float cy = cos(u_yaw);
      float sy = sin(u_yaw);
      float cp = cos(u_pitch);
      float sp = sin(u_pitch);
      float rx = p.x * cy - p.y * sy;
      float ry = p.x * sy + p.y * cy;
      float screen_y = p.z * cp - ry * sp;
      float depth = p.z * sp + ry * cp;
      gl_Position = vec4(rx * u_scale / u_aspect, screen_y * u_scale, depth * u_scale * 0.18, 1.0);
      gl_PointSize = u_point_size;
      v_color = a_color;
    }
  `);
  const fragment = compile3DShader(gl, gl.FRAGMENT_SHADER, `
    precision mediump float;
    uniform float u_round_points;
    varying vec3 v_color;
    void main() {
      if (u_round_points > 0.5 && distance(gl_PointCoord, vec2(0.5)) > 0.5) discard;
      gl_FragColor = vec4(v_color, 1.0);
    }
  `);
  const program = gl.createProgram();
  gl.attachShader(program, vertex);
  gl.attachShader(program, fragment);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(program) || "3D shader linking failed");
  }
  viewer3d.gl = gl;
  viewer3d.program = program;
  viewer3d.locations = {
    position: gl.getAttribLocation(program, "a_position"),
    color: gl.getAttribLocation(program, "a_color"),
    center: gl.getUniformLocation(program, "u_center"),
    yaw: gl.getUniformLocation(program, "u_yaw"),
    pitch: gl.getUniformLocation(program, "u_pitch"),
    scale: gl.getUniformLocation(program, "u_scale"),
    aspect: gl.getUniformLocation(program, "u_aspect"),
    pointSize: gl.getUniformLocation(program, "u_point_size"),
    roundPoints: gl.getUniformLocation(program, "u_round_points"),
  };
  return gl;
}

function webGLBuffer(gl, positions, colors, mode) {
  if (!positions.length) return null;
  const positionBuffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(positions), gl.STATIC_DRAW);
  const colorBuffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, colorBuffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(colors), gl.STATIC_DRAW);
  return { positionBuffer, colorBuffer, count: positions.length / 3, mode };
}

function webGLIndexedBuffer(gl, positions, colors, indices) {
  if (!positions.length || !indices.length) return null;
  const buffer = webGLBuffer(gl, positions, colors, gl.TRIANGLES);
  const indexBuffer = gl.createBuffer();
  gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuffer);
  gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint16Array(indices), gl.STATIC_DRAW);
  return { ...buffer, indexBuffer, count: indices.length, indexed: true };
}

function repeatedColor(color, count) {
  return Array.from({ length: count }, () => color).flat();
}

function dispose3DBuffers() {
  if (!viewer3d.gl || !viewer3d.buffers) return;
  const buffers = [
    viewer3d.buffers.cloud,
    viewer3d.buffers.structure,
    viewer3d.buffers.tags,
    viewer3d.buffers.grid,
    ...(viewer3d.buffers.trajectories || []),
    ...(viewer3d.buffers.surfaces || []),
  ].filter(Boolean);
  buffers.forEach((buffer) => {
    viewer3d.gl.deleteBuffer(buffer.positionBuffer);
    viewer3d.gl.deleteBuffer(buffer.colorBuffer);
    if (buffer.indexBuffer) viewer3d.gl.deleteBuffer(buffer.indexBuffer);
  });
  viewer3d.buffers = null;
}

function build3DBuffers() {
  dispose3DBuffers();
  if (!viewer3d.data) {
    return;
  }
  const gl = ensure3DRenderer();
  const data = viewer3d.data;
  const cloudPositions = [];
  const cloudColors = [];
  (data.point_cloud?.points || []).forEach((point) => {
    cloudPositions.push(point[0], point[1], point[2]);
    cloudColors.push((point[3] || 70) / 255, (point[4] || 130) / 255, (point[5] || 150) / 255);
  });
  const structurePositions = [];
  (data.points || []).forEach((point) => structurePositions.push(...point.position));
  const tagPositions = [];
  (data.price_tags || []).forEach((tag) => tagPositions.push(...tag.position));
  const segmentColors = [[0.05, 0.49, 0.53], [0.18, 0.48, 0.79], [0.58, 0.35, 0.67], [0.74, 0.42, 0.20], [0.35, 0.49, 0.21]];
  const trajectories = (data.segments || []).map((segment, index) => {
    const positions = (segment.trajectory || []).flat();
    return webGLBuffer(gl, positions, repeatedColor(segmentColors[index % segmentColors.length], positions.length / 3), gl.LINE_STRIP);
  }).filter(Boolean);
  const span = viewer3d.span * 0.65;
  const gridPositions = [];
  for (let index = -5; index <= 5; index += 1) {
    const x = viewer3d.center[0] + (index / 5) * span;
    gridPositions.push(x, viewer3d.center[1] - span, 0, x, viewer3d.center[1] + span, 0);
    const y = viewer3d.center[1] + (index / 5) * span;
    gridPositions.push(viewer3d.center[0] - span, y, 0, viewer3d.center[0] + span, y, 0);
  }
  viewer3d.buffers = {
    cloud: webGLBuffer(gl, cloudPositions, cloudColors, gl.POINTS),
    structure: webGLBuffer(gl, structurePositions, repeatedColor([0.20, 0.23, 0.25], structurePositions.length / 3), gl.POINTS),
    tags: webGLBuffer(gl, tagPositions, repeatedColor([0.65, 0.33, 0.10], tagPositions.length / 3), gl.POINTS),
    trajectories,
    surfaces: [],
    grid: webGLBuffer(gl, gridPositions, repeatedColor([0.70, 0.74, 0.77], gridPositions.length / 3), gl.LINES),
  };
  loadSurfaceBuffers(data.point_cloud?.surface_frames || [], viewer3d.surfaceLoadToken);
}

function imageFromUrl(url) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error(`无法读取彩色帧: ${url}`));
    image.src = url;
  });
}

function artifactFrameUrl(path) {
  return viewer3d.artifactRoot + path.split("/").map((part) => encodeURIComponent(part)).join("/");
}

async function loadSurfaceBuffers(frames, token) {
  if (!frames.length || !viewer3d.artifactRoot || !viewer3d.buffers) return;
  const gl = viewer3d.gl;
  const sampleCanvas = document.createElement("canvas");
  const context = sampleCanvas.getContext("2d", { willReadFrequently: true });
  if (!context) return;
  let loaded = 0;
  for (const frame of frames) {
    if (token !== viewer3d.surfaceLoadToken || !viewer3d.buffers) return;
    try {
      const image = await imageFromUrl(artifactFrameUrl(frame.image));
      if (token !== viewer3d.surfaceLoadToken || !viewer3d.buffers) return;
      sampleCanvas.width = image.naturalWidth;
      sampleCanvas.height = image.naturalHeight;
      context.drawImage(image, 0, 0);
      const pixels = context.getImageData(0, 0, sampleCanvas.width, sampleCanvas.height).data;
      const positions = (frame.vertices || []).flat();
      const colors = [];
      (frame.uv || []).forEach(([u, v]) => {
        const x = Math.max(0, Math.min(sampleCanvas.width - 1, Math.round(u * (sampleCanvas.width - 1))));
        const y = Math.max(0, Math.min(sampleCanvas.height - 1, Math.round(v * (sampleCanvas.height - 1))));
        const offset = (y * sampleCanvas.width + x) * 4;
        colors.push(pixels[offset] / 255, pixels[offset + 1] / 255, pixels[offset + 2] / 255);
      });
      const surface = webGLIndexedBuffer(gl, positions, colors, frame.indices || []);
      if (surface) viewer3d.buffers.surfaces.push(surface);
      loaded += 1;
      if (loaded % 8 === 0 && !isPlanPreview()) drawScene();
    } catch (error) {
      console.warn(error.message);
    }
  }
  if (token === viewer3d.surfaceLoadToken && !isPlanPreview()) drawScene();
}

function draw3DBuffer(buffer, pointSize = 1, roundPoints = false) {
  if (!buffer) return;
  const gl = viewer3d.gl;
  const locations = viewer3d.locations;
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer.positionBuffer);
  gl.vertexAttribPointer(locations.position, 3, gl.FLOAT, false, 0, 0);
  gl.enableVertexAttribArray(locations.position);
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer.colorBuffer);
  gl.vertexAttribPointer(locations.color, 3, gl.FLOAT, false, 0, 0);
  gl.enableVertexAttribArray(locations.color);
  gl.uniform1f(locations.pointSize, pointSize);
  gl.uniform1f(locations.roundPoints, roundPoints ? 1 : 0);
  if (buffer.indexed) {
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, buffer.indexBuffer);
    gl.drawElements(buffer.mode, buffer.count, gl.UNSIGNED_SHORT, 0);
  } else {
    gl.drawArrays(buffer.mode, 0, buffer.count);
  }
}

function drawScene() {
  if (!viewer3d.data || isPlanPreview()) return;
  const topDown = activePreview === "2d-color";
  const metrics = canvasMetrics(sceneCanvas);
  const gl = ensure3DRenderer();
  gl.viewport(0, 0, metrics.width, metrics.height);
  gl.clearColor(0.925, 0.941, 0.949, 1);
  gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
  gl.enable(gl.DEPTH_TEST);
  gl.depthFunc(gl.LEQUAL);
  gl.useProgram(viewer3d.program);
  const locations = viewer3d.locations;
  gl.uniform3fv(locations.center, topDown ? viewerTop.center : viewer3d.viewCenter);
  gl.uniform1f(locations.yaw, topDown ? 0 : viewer3d.yaw);
  gl.uniform1f(locations.pitch, topDown ? -Math.PI / 2 : viewer3d.pitch);
  const span = topDown ? viewer3d.planSpan * 1.12 * viewerTop.distance : viewer3d.span * 1.45 * viewer3d.distance;
  gl.uniform1f(locations.scale, 2 / span);
  gl.uniform1f(locations.aspect, metrics.width / metrics.height);
  if (!topDown) draw3DBuffer(viewer3d.buffers?.grid, 1, false);
  if (topDown || viewer3d.showSurface) {
    (viewer3d.buffers?.surfaces || []).forEach((buffer) => draw3DBuffer(buffer, 1, false));
  }
  if ((!viewer3d.buffers?.surfaces?.length && topDown) || viewer3d.showCloud) {
    draw3DBuffer(viewer3d.buffers?.cloud, Math.max(1, metrics.ratio * viewer3d.pointSize), true);
  }
  if (!topDown && viewer3d.showTrajectory) {
    (viewer3d.buffers?.trajectories || []).forEach((buffer) => draw3DBuffer(buffer, 1, false));
  }
  if (!topDown) {
    draw3DBuffer(viewer3d.buffers?.structure, Math.max(2, metrics.ratio * 2), true);
    draw3DBuffer(viewer3d.buffers?.tags, Math.max(5, metrics.ratio * 4), true);
  }
}

function updatePreview(kind) {
  if (manualMerge.active && kind !== "2d-map") exitManualMerge();
  activePreview = kind;
  $$(".preview-tab").forEach((button) => {
    const selected = button.dataset.preview === kind;
    button.classList.toggle("is-active", selected);
    button.setAttribute("aria-selected", String(selected));
  });
  const planPreview = isPlanPreview(kind);
  mapCanvas.hidden = !planPreview;
  sceneCanvas.hidden = planPreview;
  mapCanvas.setAttribute("aria-label", kind === "2d-shelf" ? "二维货架和竖直结构轮廓预览" : "二维结构地图预览");
  sceneCanvas.dataset.dragMode = kind === "2d-color" ? "pan" : viewer3d.dragMode;
  $("#scene-controls").hidden = kind !== "3d";
  syncShelfTuningVisibility();
  syncEmptyPreview();
  if (planPreview) reset2D(); else drawScene();
}

function pointerPosition(event, canvas) {
  const rect = canvas.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  return [(event.clientX - rect.left) * ratio, (event.clientY - rect.top) * ratio];
}

function connect2DControls() {
  mapCanvas.addEventListener("pointerdown", (event) => {
    if (!current2DImage()) return;
    const [x, y] = pointerPosition(event, mapCanvas);
    if (manualMerge.active && !manualMerge.spacePressed) {
      event.preventDefault();
      if (manualMerge.regions.length >= 2) resetManualMergeSelection();
      manualMerge.selecting = true;
      const point = canvasToImage([x, y]);
      manualMerge.draft = { start: point, end: point };
      mapCanvas.setPointerCapture(event.pointerId);
      draw2D();
      return;
    }
    viewer2d.dragging = true; viewer2d.startX = x - viewer2d.offsetX; viewer2d.startY = y - viewer2d.offsetY;
    mapCanvas.setPointerCapture(event.pointerId);
  });
  mapCanvas.addEventListener("pointermove", (event) => {
    if (manualMerge.selecting && manualMerge.draft) {
      manualMerge.draft.end = canvasToImage(pointerPosition(event, mapCanvas));
      draw2D();
      return;
    }
    if (!viewer2d.dragging) return;
    const [x, y] = pointerPosition(event, mapCanvas);
    viewer2d.offsetX = x - viewer2d.startX; viewer2d.offsetY = y - viewer2d.startY; draw2D();
  });
  mapCanvas.addEventListener("pointerup", () => {
    viewer2d.dragging = false;
    if (!manualMerge.selecting || !manualMerge.draft) return;
    const rectangle = normalizedMergeRect({
      rect_pixels: [...manualMerge.draft.start, ...manualMerge.draft.end],
    });
    manualMerge.selecting = false;
    manualMerge.draft = null;
    if (rectangle[2] - rectangle[0] < 4 || rectangle[3] - rectangle[1] < 4) {
      setMergeStatus("框选区域过小，请重新拖动");
      draw2D();
      return;
    }
    manualMerge.regions.push({ rect_pixels: rectangle });
    invalidateMergePreview(
      manualMerge.regions.length === 1
        ? "已选择基准区域 A，请继续框选需要对齐的重影区域 B"
        : "两个区域已选择，请点击“预览约束”检查自动对应",
    );
    $("#merge-instruction").textContent = manualMerge.regions.length === 1
      ? "现在框选同一货架或通道的重影区域 B。"
      : "紫色虚线将在预览后显示 B 对齐到 A 的目标位置。";
  });
  mapCanvas.addEventListener("pointercancel", () => {
    viewer2d.dragging = false;
    manualMerge.selecting = false;
    manualMerge.draft = null;
    draw2D();
  });
  mapCanvas.addEventListener("wheel", (event) => {
    if (!current2DImage()) return;
    event.preventDefault();
    const [x, y] = pointerPosition(event, mapCanvas);
    const factor = event.deltaY < 0 ? 1.12 : 0.89;
    viewer2d.offsetX = x - (x - viewer2d.offsetX) * factor;
    viewer2d.offsetY = y - (y - viewer2d.offsetY) * factor;
    viewer2d.scale = Math.max(0.00001, viewer2d.scale * factor); draw2D();
  }, { passive: false });
}

function connect3DControls() {
  sceneCanvas.addEventListener("pointerdown", (event) => {
    if (!viewer3d.data) return;
    const [x, y] = pointerPosition(event, sceneCanvas);
    viewer3d.dragGesture = activePreview === "2d-color" || viewer3d.dragMode === "pan" || event.shiftKey || event.button === 1 || event.button === 2
      ? "pan"
      : "rotate";
    viewer3d.dragging = true; viewer3d.startX = x; viewer3d.startY = y;
    sceneCanvas.classList.add("is-dragging");
    sceneCanvas.setPointerCapture(event.pointerId);
  });
  sceneCanvas.addEventListener("pointermove", (event) => {
    if (!viewer3d.dragging) return;
    const [x, y] = pointerPosition(event, sceneCanvas);
    if (activePreview === "2d-color") {
      const metrics = canvasMetrics(sceneCanvas);
      const scale = 2 / (viewer3d.planSpan * 1.12 * viewerTop.distance);
      const worldPerPixel = 2 / (metrics.height * scale);
      viewerTop.center[0] -= (x - viewer3d.startX) * worldPerPixel;
      viewerTop.center[1] += (y - viewer3d.startY) * worldPerPixel;
    } else if (viewer3d.dragGesture === "pan") {
      const metrics = canvasMetrics(sceneCanvas);
      const scale = 2 / (viewer3d.span * 1.45 * viewer3d.distance);
      const worldPerPixel = 2 / (metrics.height * scale);
      const dx = (x - viewer3d.startX) * worldPerPixel;
      const dy = (y - viewer3d.startY) * worldPerPixel;
      const cy = Math.cos(viewer3d.yaw);
      const sy = Math.sin(viewer3d.yaw);
      const cp = Math.cos(viewer3d.pitch);
      const sp = Math.sin(viewer3d.pitch);
      viewer3d.viewCenter[0] += -cy * dx - sy * sp * dy;
      viewer3d.viewCenter[1] += sy * dx - cy * sp * dy;
      viewer3d.viewCenter[2] += cp * dy;
    } else {
      viewer3d.yaw += (x - viewer3d.startX) / 260;
      viewer3d.pitch = Math.max(-1.35, Math.min(1.35, viewer3d.pitch + (y - viewer3d.startY) / 260));
    }
    viewer3d.startX = x; viewer3d.startY = y; drawScene();
  });
  const finishDrag = () => {
    viewer3d.dragging = false;
    sceneCanvas.classList.remove("is-dragging");
  };
  sceneCanvas.addEventListener("pointerup", finishDrag);
  sceneCanvas.addEventListener("pointercancel", finishDrag);
  sceneCanvas.addEventListener("contextmenu", (event) => event.preventDefault());
  sceneCanvas.addEventListener("wheel", (event) => {
    if (!viewer3d.data) return;
    event.preventDefault();
    if (activePreview === "2d-color") {
      viewerTop.distance = Math.max(0.2, Math.min(6, viewerTop.distance * (event.deltaY < 0 ? 0.88 : 1.14)));
    } else {
      viewer3d.distance = Math.max(0.35, Math.min(4, viewer3d.distance * (event.deltaY < 0 ? 0.88 : 1.14)));
    }
    drawScene();
  }, { passive: false });
}

function set3DDragMode(mode) {
  viewer3d.dragMode = mode;
  sceneCanvas.dataset.dragMode = activePreview === "2d-color" ? "pan" : mode;
  [["drag-rotate", "rotate"], ["drag-pan", "pan"]].forEach(([id, value]) => {
    const button = $("#" + id);
    const selected = value === mode;
    button.classList.toggle("is-active", selected);
    button.setAttribute("aria-pressed", String(selected));
  });
}

function switchMode(mode) {
  activeMode = mode;
  $$(".tab").forEach((button) => button.classList.toggle("is-active", button.dataset.mode === mode));
  $$(".mode-panel").forEach((panel) => panel.classList.toggle("is-active", panel.dataset.panel === mode));
  $$("[data-scan-options]").forEach((panel) => { panel.hidden = mode === "prior"; });
  updateSingleAlignmentState();
}

function bindEvents() {
  $("#show-about").addEventListener("click", showAboutAndRecovery);
  $("#export-diagnostics").addEventListener("click", exportDiagnostics);
  $$(".tab").forEach((button) => button.addEventListener("click", () => switchMode(button.dataset.mode)));
  $$(".preview-tab").forEach((button) => button.addEventListener("click", () => updatePreview(button.dataset.preview)));
  $$('[data-pick]').forEach((button) => button.addEventListener("click", () => choosePath(button.dataset.pick, button.dataset.title)));
  $$('[data-pick-file]').forEach((button) => button.addEventListener("click", () => choosePath(button.dataset.pickFile, button.dataset.title, "file")));
  $("#inspect-single-session").addEventListener("click", () => inspectSession("single-session"));
  $("#cleanup-finalized-checkpoint").addEventListener("click", cleanupFinalizedCheckpoint);
  $("#run-single").addEventListener("click", runActiveJob);
  $("#run-multi").addEventListener("click", runActiveJob);
  $("#run-prior").addEventListener("click", runActiveJob);
  $("#run-localized").addEventListener("click", runActiveJob);
  $("#localized-apply-edit").addEventListener("click", () => applyLocalizedEdit("append"));
  $("#localized-undo").addEventListener("click", () => applyLocalizedEdit("undo"));
  $("#localized-redo").addEventListener("click", () => applyLocalizedEdit("redo"));
  $("#localized-submit-review").addEventListener("click", () => applyLocalizedState("submit_review"));
  $("#localized-publish").addEventListener("click", () => applyLocalizedState("publish"));
  $("#localized-field-evidence").addEventListener("click", inspectFieldQualification);
  $("#localized-revoke").addEventListener("click", () => applyLocalizedState("revoke"));
  $("#localized-edit-type").addEventListener("change", updateLocalizedEditHelp);
  $("#localized-review-canvas").addEventListener("pointerdown", beginLocalizedAnchor);
  $("#localized-review-canvas").addEventListener("pointermove", dragLocalizedAnchor);
  $("#localized-review-canvas").addEventListener("pointerup", endLocalizedAnchor);
  $("#localized-review-canvas").addEventListener("pointercancel", endLocalizedAnchor);
  $("#localized-map-anchor-yaw").addEventListener("input", (event) => {
    const degrees = Number(event.target.value);
    $("#localized-map-anchor-yaw-value").value = `${degrees}°`;
    if (localizedReview.anchorDraft) {
      localizedReview.anchorDraft.yaw_rad = degrees * Math.PI / 180;
      drawLocalizedReview();
    }
  });
  $("#localized-tag-filter").addEventListener("change", renderLocalizedReviewList);
  $("#localized-shelf-filter").addEventListener("input", renderLocalizedReviewList);
  window.addEventListener("resize", drawLocalizedReview);
  updateLocalizedEditHelp();
  $("#add-device").addEventListener("click", addDevice);
  $("#add-stage").addEventListener("click", addStage);
  $("#option-offline-optimize").addEventListener("change", updateSingleAlignmentState);
  $("#prior-legacy-element-only").addEventListener("change", updatePriorLegacyState);
  $("#show-surface").addEventListener("change", (event) => { viewer3d.showSurface = event.target.checked; drawScene(); });
  $("#show-cloud").addEventListener("change", (event) => { viewer3d.showCloud = event.target.checked; drawScene(); });
  $("#show-trajectory").addEventListener("change", (event) => { viewer3d.showTrajectory = event.target.checked; drawScene(); });
  $("#point-size").addEventListener("input", (event) => { viewer3d.pointSize = Number(event.target.value); drawScene(); });
  $("#shelf-completeness").addEventListener("input", (event) => applyShelfScore(Number(event.target.value)));
  $$('[data-shelf-preset]').forEach((button) => button.addEventListener("click", () => applyShelfScore(Number(button.dataset.shelfPreset))));
  Object.values(shelfParameterFields).forEach((selector) => {
    $(selector).addEventListener("input", () => {
      updateShelfProfileLabel(Number($("#shelf-completeness").value), "custom");
      scheduleShelfRender();
    });
  });
  $("#shelf-reset").addEventListener("click", () => applyShelfScore(50));
  $("#shelf-download").addEventListener("click", downloadCurrentShelfOutline);
  $("#merge-toggle").addEventListener("click", beginManualMerge);
  $("#merge-exit").addEventListener("click", exitManualMerge);
  $("#merge-reset").addEventListener("click", resetManualMergeSelection);
  $("#merge-preview").addEventListener("click", previewManualMerge);
  $("#merge-apply").addEventListener("click", applyManualMerge);
  $("#merge-confirm").addEventListener("change", (event) => {
    $("#merge-apply").disabled = !(event.target.checked && manualMerge.preview?.can_apply);
  });
  ["#merge-dx", "#merge-dy", "#merge-yaw", "#merge-information"].forEach((selector) => {
    $(selector).addEventListener("input", () => invalidateMergePreview());
  });
  $("#drag-rotate").addEventListener("click", () => set3DDragMode("rotate"));
  $("#drag-pan").addEventListener("click", () => set3DDragMode("pan"));
  $("#single-session").addEventListener("input", () => {
    currentSingleScanMode = null;
    currentSingleOfflineSupported = null;
    updateSingleAlignmentState();
    window.clearTimeout(sessionRestoreTimer);
    sessionRestoreTimer = window.setTimeout(() => selectSingleSession($("#single-session").value.trim()), 500);
  });
  ["single-output", "multi-output", "prior-output", "localized-output"].forEach((id) => {
    $("#" + id).addEventListener("input", () => {
      $("#" + id).dataset.autoOutput = "false";
      $("#" + id).dataset.restored = "false";
    });
  });
  $("#reset-view").addEventListener("click", () => {
    if (isPlanPreview()) reset2D();
    else if (activePreview === "2d-color") resetTopDown();
    else reset3D();
  });
  $("#preview-fullscreen").addEventListener("click", togglePreviewFullscreen);
  document.addEventListener("fullscreenchange", () => {
    updatePreviewFullscreenButton();
    redrawExpandedPreview();
  });
  document.addEventListener("keydown", (event) => {
    const panel = $(".preview-panel");
    if (
      manualMerge.active &&
      event.code === "Space" &&
      !["INPUT", "SELECT", "TEXTAREA"].includes(event.target.tagName)
    ) {
      manualMerge.spacePressed = true;
      mapCanvas.classList.remove("merge-selecting");
      event.preventDefault();
    }
    if (event.key === "Escape" && panel.classList.contains("is-expanded")) {
      panel.classList.remove("is-expanded");
      updatePreviewFullscreenButton();
      redrawExpandedPreview();
    }
  });
  document.addEventListener("keyup", (event) => {
    if (manualMerge.active && event.code === "Space") {
      manualMerge.spacePressed = false;
      mapCanvas.classList.add("merge-selecting");
    }
  });
  $("#open-output").addEventListener("click", async () => {
    if (!completedJobId) return;
    try { await request(`/api/jobs/${completedJobId}/open`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({}) }); }
    catch (error) { setStatus(error.message, "failed"); }
  });
  $("#cancel-job").addEventListener("click", async () => {
    if (!activeJobId) return;
    try {
      const job = await request(`/api/jobs/${activeJobId}/cancel`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({}),
      });
      renderJobProgress(job);
      setStatus("正在安全停止子进程并保留旧成果", "running");
    } catch (error) {
      setStatus(error.message, "failed");
    }
  });
  connect2DControls(); connect3DControls();
  new ResizeObserver(() => { if (isPlanPreview()) draw2D(); else drawScene(); }).observe($(".canvas-wrap"));
}

async function initializeApplication() {
  bindEvents();
  updatePriorLegacyState();
  try {
    await bootstrapSession();
    await renderRuntimeMode();
    startSessionRefresh();
    setStatus("就绪", "");
    loadGpuCapabilities();
    restoreLatestJob();
  } catch (error) {
    setStatus(error.message, "failed");
  }
  set3DDragMode("rotate");
  addDevice();
  addDevice();
}

initializeApplication();
