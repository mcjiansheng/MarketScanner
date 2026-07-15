"use strict";

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const statusNode = $("#job-status");
const mapCanvas = $("#map-canvas");
const sceneCanvas = $("#scene-canvas");
const emptyPreview = $("#empty-preview");
const previewMeta = $("#preview-meta");
let activeMode = "map";
let activePreview = "2d";
let activeJobId = null;
let completedJobId = null;
let activeJobKey = null;
let completedJobKey = null;

const viewer2d = { image: null, scale: 1, offsetX: 0, offsetY: 0, dragging: false, startX: 0, startY: 0 };
const viewer3d = { data: null, yaw: -0.72, pitch: 0.68, distance: 1, dragging: false, startX: 0, startY: 0, center: [0, 0, 0], span: 1 };

function setStatus(text, tone = "") {
  statusNode.textContent = text;
  statusNode.className = `status ${tone}`;
}

function setBusy(busy) {
  $$(".primary").forEach((button) => { button.disabled = busy; });
  $$(".secondary").forEach((button) => { button.disabled = busy && button.id !== "reset-view"; });
  $$(".tab").forEach((button) => { button.disabled = busy; });
}

async function request(path, options = {}) {
  const response = await fetch(path, options);
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || `Request failed (${response.status})`);
  return payload;
}

async function choosePath(inputId, title, mode = "directory") {
  try {
    const result = await request("/api/dialog", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ mode, title }),
    });
    if (result.path) {
      const input = $("#" + inputId);
      input.value = result.path;
      if (["map-output", "stage-output", "multi-output"].includes(inputId)) input.dataset.autoOutput = "false";
      applySessionOutputDefault(inputId, result.path);
    }
    return result.path || "";
  } catch (error) {
    setStatus(error.message, "failed");
    return "";
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
  if (inputId === "map-session") setOutputDefault("map-output", session, "MapStudio-2D");
  if (inputId === "stage-session") setOutputDefault("stage-output", session, "MapStudio-Stage");
}

function mapOptions() {
  return {
    resolution: $("#option-resolution").value,
    trajectory_radius: $("#option-trajectory-radius").value,
    tag_snap_distance: $("#option-tag-snap").value,
    horizontal_axes: $("#option-axes").value,
  };
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
  appendText(target, "div", `${data.segment_count} 个分段  |  ${data.node_count} 个节点  |  ${data.price_tag_count} 个价签`);
  const list = document.createElement("ul");
  data.segments.forEach((segment) => {
    const warning = segment.warnings?.length ? `；${segment.warnings.join(" ")}` : "";
    appendText(list, "li", `分段 ${segment.index}: ${segment.nodes} 节点，${segment.price_tags} 价签${warning}`);
  });
  target.appendChild(list);
}

async function inspectSession(inputId) {
  const session = $("#" + inputId).value.trim();
  if (!session) {
    setStatus("请选择扫描会话", "failed");
    return;
  }
  try {
    setStatus("正在检查会话", "running");
    renderInspection(await request("/api/session/inspect", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ session }),
    }));
    setStatus("会话检查完成", "complete");
  } catch (error) {
    setStatus(error.message, "failed");
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
  remove.addEventListener("click", () => row.remove());
  row.appendChild(remove);
  list.appendChild(row);
}

function activeRequest() {
  if (activeMode === "map") {
    return {
      kind: "map",
      session: $("#map-session").value.trim(),
      output: $("#map-output").value.trim(),
      points_csv: $("#map-points").value.trim() ? [$("#map-points").value.trim()] : [],
      auto_align_segments: $("#map-auto-align").checked,
      options: mapOptions(),
    };
  }
  if (activeMode === "stage") {
    return {
      kind: "stage",
      session: $("#stage-session").value.trim(),
      output: $("#stage-output").value.trim(),
      points_csv: $("#stage-points").value.trim() ? [$("#stage-points").value.trim()] : [],
      stage_config: stageConfig(),
      options: mapOptions(),
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
  const outputId = payload.kind === "map" ? "map-output" : payload.kind === "stage" ? "stage-output" : "multi-output";
  if ($("#" + outputId).dataset.autoOutput === "true") delete comparable.output;
  return JSON.stringify(comparable);
}

async function runActiveJob() {
  try {
    const payload = activeRequest();
    const requestKey = activeRequestKey(payload);
    if (completedJobId && completedJobKey === requestKey) {
      setStatus("当前设置已经生成，继续显示上次结果", "complete");
      return;
    }
    setBusy(true);
    setStatus("正在创建任务", "running");
    const job = await request("/api/jobs", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    activeJobId = job.id;
    activeJobKey = requestKey;
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
    if (job.status === "queued" || job.status === "running") {
      setStatus(`正在处理 ${job.kind === "multi" ? "多设备地图" : "地图"}`, "running");
      window.setTimeout(pollJob, 650);
      return;
    }
    activeJobId = null;
    setBusy(false);
    if (job.status === "failed") {
      activeJobKey = null;
      setStatus(job.error || "任务失败", "failed");
      return;
    }
    completedJobId = job.id;
    completedJobKey = activeJobKey;
    activeJobKey = null;
    $("#open-output").disabled = false;
    const warningCount = (job.quality_report?.warnings || []).length
      + (job.quality_report?.multi_device_summary?.alignment_warnings || []).length;
    setStatus(warningCount ? `地图生成完成（${warningCount} 条警告）` : "地图生成完成", "complete");
    await renderJob(job);
  } catch (error) {
    activeJobId = null;
    activeJobKey = null;
    setBusy(false);
    setStatus(error.message, "failed");
  }
}

async function renderJob(job) {
  renderReview(job.quality_report || {}, job.review_items || { items: [] });
  renderArtifacts(job.artifacts || {});
  const artifacts = job.artifacts || {};
  if (artifacts["preview.png"]) load2D(artifacts["preview.png"]);
  if (artifacts["preview_3d.json"]) {
    const data = await request(artifacts["preview_3d.json"]);
    load3D(data);
  }
  const summary = job.quality_report?.grid;
  previewMeta.textContent = summary ? `${summary.width} x ${summary.height} 栅格  |  ${summary.resolution_m} m  |  ${Number(summary.area_m2).toFixed(2)} m2` : job.output_dir;
}

function renderReview(report, review) {
  const target = $("#review");
  clearNode(target);
  const warnings = [...(report.warnings || []), ...(report.multi_device_summary?.alignment_warnings || [])];
  const items = review.items || [];
  const warningMessages = new Set(warnings.map((warning) => typeof warning === "string" ? warning : warning.message || JSON.stringify(warning)));
  const reviewItems = items.filter((item) => !warningMessages.has(item.message || JSON.stringify(item)));
  appendText(target, "div", `${warnings.length} 条警告  |  ${reviewItems.length} 个待复核项`);
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

function syncEmptyPreview() {
  emptyPreview.hidden = Boolean((activePreview === "2d" && viewer2d.image) || (activePreview === "3d" && viewer3d.data));
}

function load2D(url) {
  const image = new Image();
  image.onload = () => {
    viewer2d.image = image;
    reset2D();
    syncEmptyPreview();
    if (activePreview === "2d") draw2D();
  };
  image.src = `${url}?v=${Date.now()}`;
}

function reset2D() {
  if (!viewer2d.image) return;
  const { width, height } = canvasMetrics(mapCanvas);
  const scale = Math.min(width / viewer2d.image.width, height / viewer2d.image.height) * 0.92;
  viewer2d.scale = scale;
  viewer2d.offsetX = (width - viewer2d.image.width * scale) / 2;
  viewer2d.offsetY = (height - viewer2d.image.height * scale) / 2;
  draw2D();
}

function draw2D() {
  if (!viewer2d.image || activePreview !== "2d") return;
  const { width, height } = canvasMetrics(mapCanvas);
  const ctx = mapCanvas.getContext("2d");
  ctx.fillStyle = cssColor("--canvas-bg", "#ecf0f2");
  ctx.fillRect(0, 0, width, height);
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(viewer2d.image, viewer2d.offsetX, viewer2d.offsetY, viewer2d.image.width * viewer2d.scale, viewer2d.image.height * viewer2d.scale);
}

function load3D(data) {
  const positions = [];
  (data.segments || []).forEach((segment) => positions.push(...(segment.trajectory || [])));
  (data.points || []).forEach((point) => positions.push(point.position));
  (data.price_tags || []).forEach((tag) => positions.push(tag.position));
  viewer3d.data = positions.length ? data : null;
  if (positions.length) {
    const minima = [Infinity, Infinity, Infinity];
    const maxima = [-Infinity, -Infinity, -Infinity];
    positions.forEach((point) => point.forEach((value, index) => {
      minima[index] = Math.min(minima[index], value);
      maxima[index] = Math.max(maxima[index], value);
    }));
    viewer3d.center = minima.map((value, index) => (value + maxima[index]) / 2);
    viewer3d.span = Math.max(1, maxima[0] - minima[0], maxima[1] - minima[1], maxima[2] - minima[2]);
  }
  reset3D();
  syncEmptyPreview();
}

function reset3D() {
  viewer3d.yaw = -0.72;
  viewer3d.pitch = 0.68;
  viewer3d.distance = 1;
  if (activePreview === "3d") draw3D();
}

function project3D(point, width, height) {
  const [cx, cy, cz] = viewer3d.center;
  const x = point[0] - cx;
  const y = point[1] - cy;
  const z = point[2] - cz;
  const cosYaw = Math.cos(viewer3d.yaw);
  const sinYaw = Math.sin(viewer3d.yaw);
  const cosPitch = Math.cos(viewer3d.pitch);
  const sinPitch = Math.sin(viewer3d.pitch);
  const rx = x * cosYaw - y * sinYaw;
  const ry = x * sinYaw + y * cosYaw;
  const rz = z;
  const py = ry * cosPitch - rz * sinPitch;
  const pz = ry * sinPitch + rz * cosPitch;
  const depth = viewer3d.span * (2.8 * viewer3d.distance) + py;
  const scale = Math.min(width, height) / Math.max(1, viewer3d.span * 3.6 * viewer3d.distance);
  return [width / 2 + rx * scale, height / 2 - pz * scale, depth];
}

function drawLine(ctx, points, color, width, metrics) {
  if (points.length < 2) return;
  ctx.beginPath();
  points.forEach((point, index) => {
    const [x, y] = project3D(point, metrics.width, metrics.height);
    if (index === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  });
  ctx.strokeStyle = color;
  ctx.lineWidth = width * metrics.ratio;
  ctx.stroke();
}

function draw3D() {
  if (!viewer3d.data || activePreview !== "3d") return;
  const metrics = canvasMetrics(sceneCanvas);
  const ctx = sceneCanvas.getContext("2d");
  ctx.fillStyle = cssColor("--canvas-bg", "#ecf0f2");
  ctx.fillRect(0, 0, metrics.width, metrics.height);
  const muted = cssColor("--line", "#cbd3d8");
  const accent = cssColor("--accent", "#0c7c86");
  const warning = cssColor("--warning", "#a65419");
  const segmentColors = [
    accent,
    cssColor("--segment-2", "#2f7bca"),
    cssColor("--segment-3", "#9b5eae"),
    cssColor("--segment-4", "#bd6a32"),
    cssColor("--segment-5", "#587d35"),
  ];
  const span = viewer3d.span * 0.65;
  for (let index = -5; index <= 5; index += 1) {
    const coordinate = viewer3d.center[0] + (index / 5) * span;
    drawLine(ctx, [[coordinate, viewer3d.center[1] - span, 0], [coordinate, viewer3d.center[1] + span, 0]], muted, 0.55, metrics);
    const other = viewer3d.center[1] + (index / 5) * span;
    drawLine(ctx, [[viewer3d.center[0] - span, other, 0], [viewer3d.center[0] + span, other, 0]], muted, 0.55, metrics);
  }
  (viewer3d.data.segments || []).forEach((segment, index) => drawLine(ctx, segment.trajectory || [], segmentColors[index % segmentColors.length], 1.45, metrics));
  const structure = viewer3d.data.points || [];
  ctx.fillStyle = cssColor("--structure", "#343b40");
  structure.forEach((point) => {
    const [x, y] = project3D(point.position, metrics.width, metrics.height);
    ctx.fillRect(x - metrics.ratio, y - metrics.ratio, metrics.ratio * 2, metrics.ratio * 2);
  });
  ctx.fillStyle = warning;
  (viewer3d.data.price_tags || []).forEach((tag) => {
    const [x, y] = project3D(tag.position, metrics.width, metrics.height);
    ctx.beginPath();
    ctx.arc(x, y, 3 * metrics.ratio, 0, Math.PI * 2);
    ctx.fill();
  });
}

function updatePreview(kind) {
  activePreview = kind;
  $$(".preview-tab").forEach((button) => {
    const selected = button.dataset.preview === kind;
    button.classList.toggle("is-active", selected);
    button.setAttribute("aria-selected", String(selected));
  });
  mapCanvas.hidden = kind !== "2d";
  sceneCanvas.hidden = kind !== "3d";
  syncEmptyPreview();
  if (kind === "2d") draw2D(); else draw3D();
}

function pointerPosition(event, canvas) {
  const rect = canvas.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  return [(event.clientX - rect.left) * ratio, (event.clientY - rect.top) * ratio];
}

function connect2DControls() {
  mapCanvas.addEventListener("pointerdown", (event) => {
    if (!viewer2d.image) return;
    const [x, y] = pointerPosition(event, mapCanvas);
    viewer2d.dragging = true; viewer2d.startX = x - viewer2d.offsetX; viewer2d.startY = y - viewer2d.offsetY;
    mapCanvas.setPointerCapture(event.pointerId);
  });
  mapCanvas.addEventListener("pointermove", (event) => {
    if (!viewer2d.dragging) return;
    const [x, y] = pointerPosition(event, mapCanvas);
    viewer2d.offsetX = x - viewer2d.startX; viewer2d.offsetY = y - viewer2d.startY; draw2D();
  });
  mapCanvas.addEventListener("pointerup", () => { viewer2d.dragging = false; });
  mapCanvas.addEventListener("wheel", (event) => {
    if (!viewer2d.image) return;
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
    viewer3d.dragging = true; viewer3d.startX = x; viewer3d.startY = y; sceneCanvas.setPointerCapture(event.pointerId);
  });
  sceneCanvas.addEventListener("pointermove", (event) => {
    if (!viewer3d.dragging) return;
    const [x, y] = pointerPosition(event, sceneCanvas);
    viewer3d.yaw += (x - viewer3d.startX) / 260;
    viewer3d.pitch = Math.max(-1.35, Math.min(1.35, viewer3d.pitch + (y - viewer3d.startY) / 260));
    viewer3d.startX = x; viewer3d.startY = y; draw3D();
  });
  sceneCanvas.addEventListener("pointerup", () => { viewer3d.dragging = false; });
  sceneCanvas.addEventListener("wheel", (event) => {
    if (!viewer3d.data) return;
    event.preventDefault(); viewer3d.distance = Math.max(0.35, Math.min(4, viewer3d.distance * (event.deltaY < 0 ? 0.88 : 1.14))); draw3D();
  }, { passive: false });
}

function switchMode(mode) {
  activeMode = mode;
  $$(".tab").forEach((button) => button.classList.toggle("is-active", button.dataset.mode === mode));
  $$(".mode-panel").forEach((panel) => panel.classList.toggle("is-active", panel.dataset.panel === mode));
}

function bindEvents() {
  $$(".tab").forEach((button) => button.addEventListener("click", () => switchMode(button.dataset.mode)));
  $$(".preview-tab").forEach((button) => button.addEventListener("click", () => updatePreview(button.dataset.preview)));
  $$('[data-pick]').forEach((button) => button.addEventListener("click", () => choosePath(button.dataset.pick, button.dataset.title)));
  $$('[data-pick-file]').forEach((button) => button.addEventListener("click", () => choosePath(button.dataset.pickFile, button.dataset.title, "file")));
  $("#inspect-map-session").addEventListener("click", () => inspectSession("map-session"));
  $("#inspect-stage-session").addEventListener("click", () => inspectSession("stage-session"));
  $("#run-map").addEventListener("click", runActiveJob);
  $("#run-stage").addEventListener("click", runActiveJob);
  $("#run-multi").addEventListener("click", runActiveJob);
  $("#add-device").addEventListener("click", addDevice);
  $("#add-stage").addEventListener("click", addStage);
  ["map-session", "stage-session"].forEach((id) => {
    $("#" + id).addEventListener("input", () => applySessionOutputDefault(id, $("#" + id).value.trim()));
  });
  ["map-output", "stage-output", "multi-output"].forEach((id) => {
    $("#" + id).addEventListener("input", () => { $("#" + id).dataset.autoOutput = "false"; });
  });
  $("#reset-view").addEventListener("click", () => { if (activePreview === "2d") reset2D(); else reset3D(); });
  $("#open-output").addEventListener("click", async () => {
    if (!completedJobId) return;
    try { await request(`/api/jobs/${completedJobId}/open`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({}) }); }
    catch (error) { setStatus(error.message, "failed"); }
  });
  connect2DControls(); connect3DControls();
  new ResizeObserver(() => { if (activePreview === "2d") draw2D(); else draw3D(); }).observe($(".canvas-wrap"));
}

bindEvents();
addDevice();
addDevice();
setStatus("就绪");
