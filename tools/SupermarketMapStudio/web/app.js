"use strict";

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const statusNode = $("#job-status");
const mapCanvas = $("#map-canvas");
const sceneCanvas = $("#scene-canvas");
const emptyPreview = $("#empty-preview");
const previewMeta = $("#preview-meta");
let activeMode = "single";
let activePreview = "2d-color";
let activeJobId = null;
let completedJobId = null;
let activeJobKey = null;
let completedJobKey = null;
let sessionRestoreTimer = null;
let sessionSelectionToken = 0;

const viewer2d = { image: null, scale: 1, offsetX: 0, offsetY: 0, dragging: false, startX: 0, startY: 0 };
const viewerTop = { center: [0, 0, 0], distance: 1 };
const viewer3d = {
  data: null, yaw: -0.72, pitch: 0.68, distance: 1, dragging: false,
  startX: 0, startY: 0, center: [0, 0, 0], span: 1, planSpan: 1,
  gl: null, program: null, locations: null, buffers: null,
  showSurface: true, showCloud: false, showTrajectory: true, pointSize: 2,
  artifactRoot: "", surfaceLoadToken: 0,
};

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
      if (["single-output", "multi-output"].includes(inputId)) input.dataset.autoOutput = "false";
      if (inputId === "single-session") await selectSingleSession(result.path);
      else applySessionOutputDefault(inputId, result.path);
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
  if (inputId === "single-session") setOutputDefault("single-output", session, "MapStudio-Single");
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
  if (!session) {
    setStatus("就绪");
    return;
  }
  applySessionOutputDefault("single-session", session);
  await restoreExistingResult(session, token);
}

function mapOptions() {
  return {
    resolution: $("#option-resolution").value,
    trajectory_radius: $("#option-trajectory-radius").value,
    tag_snap_distance: $("#option-tag-snap").value,
    horizontal_axes: $("#option-axes").value,
    preview_3d_quality: $("#option-3d-quality").value,
  };
}

function applyRestoredOptions(map) {
  const parameters = map?.parameters || {};
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
  const hasStages = $("#stage-list").children.length > 0;
  if (hasStages) autoAlign.checked = false;
  autoAlign.disabled = hasStages;
}

function activeRequest() {
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
  const outputId = payload.kind === "multi" ? "multi-output" : "single-output";
  if ($("#" + outputId).dataset.autoOutput === "true") delete comparable.output;
  return JSON.stringify(comparable);
}

async function runActiveJob() {
  try {
    let payload = activeRequest();
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
    const previewUrl = artifacts["preview_3d.json"];
    const data = await request(previewUrl);
    load3D(data, previewUrl);
  }
  const summary = job.quality_report?.grid;
  const cloud = job.quality_report?.preview_3d;
  const surfaceText = cloud?.surface_triangle_count ? ` / ${cloud.surface_triangle_count.toLocaleString()} 面` : "";
  const cloudText = cloud?.point_count ? `  |  3D ${cloud.point_count.toLocaleString()} 点${surfaceText} / ${cloud.decoded_frames} 关键帧` : "";
  previewMeta.textContent = summary ? `${summary.width} x ${summary.height} 栅格  |  ${summary.resolution_m} m  |  ${Number(summary.area_m2).toFixed(2)} m2${cloudText}` : job.output_dir;
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
  emptyPreview.hidden = Boolean((activePreview === "2d-map" && viewer2d.image) || (activePreview !== "2d-map" && viewer3d.data));
}

function load2D(url) {
  const image = new Image();
  image.onload = () => {
    viewer2d.image = image;
    reset2D();
    syncEmptyPreview();
    if (activePreview === "2d-map") draw2D();
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
  if (!viewer2d.image || activePreview !== "2d-map") return;
  const { width, height } = canvasMetrics(mapCanvas);
  const ctx = mapCanvas.getContext("2d");
  ctx.fillStyle = cssColor("--canvas-bg", "#ecf0f2");
  ctx.fillRect(0, 0, width, height);
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(viewer2d.image, viewer2d.offsetX, viewer2d.offsetY, viewer2d.image.width * viewer2d.scale, viewer2d.image.height * viewer2d.scale);
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
      if (loaded % 8 === 0 && activePreview !== "2d-map") drawScene();
    } catch (error) {
      console.warn(error.message);
    }
  }
  if (token === viewer3d.surfaceLoadToken && activePreview !== "2d-map") drawScene();
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
  if (!viewer3d.data || activePreview === "2d-map") return;
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
  gl.uniform3fv(locations.center, topDown ? viewerTop.center : viewer3d.center);
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
  activePreview = kind;
  $$(".preview-tab").forEach((button) => {
    const selected = button.dataset.preview === kind;
    button.classList.toggle("is-active", selected);
    button.setAttribute("aria-selected", String(selected));
  });
  mapCanvas.hidden = kind !== "2d-map";
  sceneCanvas.hidden = kind === "2d-map";
  $("#scene-controls").hidden = kind !== "3d";
  syncEmptyPreview();
  if (kind === "2d-map") reset2D(); else drawScene();
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
    if (activePreview === "2d-color") {
      const metrics = canvasMetrics(sceneCanvas);
      const scale = 2 / (viewer3d.planSpan * 1.12 * viewerTop.distance);
      const worldPerPixel = 2 / (metrics.height * scale);
      viewerTop.center[0] -= (x - viewer3d.startX) * worldPerPixel;
      viewerTop.center[1] += (y - viewer3d.startY) * worldPerPixel;
    } else {
      viewer3d.yaw += (x - viewer3d.startX) / 260;
      viewer3d.pitch = Math.max(-1.35, Math.min(1.35, viewer3d.pitch + (y - viewer3d.startY) / 260));
    }
    viewer3d.startX = x; viewer3d.startY = y; drawScene();
  });
  sceneCanvas.addEventListener("pointerup", () => { viewer3d.dragging = false; });
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
  $("#inspect-single-session").addEventListener("click", () => inspectSession("single-session"));
  $("#run-single").addEventListener("click", runActiveJob);
  $("#run-multi").addEventListener("click", runActiveJob);
  $("#add-device").addEventListener("click", addDevice);
  $("#add-stage").addEventListener("click", addStage);
  $("#show-surface").addEventListener("change", (event) => { viewer3d.showSurface = event.target.checked; drawScene(); });
  $("#show-cloud").addEventListener("change", (event) => { viewer3d.showCloud = event.target.checked; drawScene(); });
  $("#show-trajectory").addEventListener("change", (event) => { viewer3d.showTrajectory = event.target.checked; drawScene(); });
  $("#point-size").addEventListener("input", (event) => { viewer3d.pointSize = Number(event.target.value); drawScene(); });
  $("#single-session").addEventListener("input", () => {
    window.clearTimeout(sessionRestoreTimer);
    sessionRestoreTimer = window.setTimeout(() => selectSingleSession($("#single-session").value.trim()), 500);
  });
  ["single-output", "multi-output"].forEach((id) => {
    $("#" + id).addEventListener("input", () => {
      $("#" + id).dataset.autoOutput = "false";
      $("#" + id).dataset.restored = "false";
    });
  });
  $("#reset-view").addEventListener("click", () => {
    if (activePreview === "2d-map") reset2D();
    else if (activePreview === "2d-color") resetTopDown();
    else reset3D();
  });
  $("#open-output").addEventListener("click", async () => {
    if (!completedJobId) return;
    try { await request(`/api/jobs/${completedJobId}/open`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({}) }); }
    catch (error) { setStatus(error.message, "failed"); }
  });
  connect2DControls(); connect3DControls();
  new ResizeObserver(() => { if (activePreview === "2d-map") draw2D(); else drawScene(); }).observe($(".canvas-wrap"));
}

bindEvents();
addDevice();
addDevice();
setStatus("就绪");
