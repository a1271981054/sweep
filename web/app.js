(() => {
  const $ = (id) => document.getElementById(id);

  // Categories that only hold rebuildable caches; everything else starts
  // unselected so the user opts in to files that matter.
  const AUTO_SELECT = new Set([
    "package_manager_caches",
    "user_caches",
    "ai_tool_caches",
    "ide_caches",
    "system_caches",
    "user_logs",
    "system_logs",
    "xcode_junk",
  ]);

  const MODULES = [
    { id: "all", label: "全部", short: "全部" },
    { id: "system-junk", label: "系统垃圾", short: "系统" },
    { id: "project-junk", label: "项目垃圾", short: "项目" },
    { id: "duplicates", label: "重复文件", short: "重复" },
    { id: "installers", label: "安装包", short: "安装" },
  ];

  const RISKS = [
    { id: "all", label: "全部建议" },
    { id: "safe", label: "推荐清理" },
    { id: "confirm", label: "按需确认" },
    { id: "caution", label: "谨慎保留" },
  ];

  const MODULE_ORDER = ["system-junk", "project-junk", "duplicates", "installers"];
  const MIN_BYTES = 1024 * 1024;
  const MATRIX_CELLS = 64;
  const MEM_CELLS = 12;
  const RING_CIRC = 2 * Math.PI * 34; // ~213.63

  let groups = [];
  let cards = [];
  let selectionMap = new Map();
  let cleanedIds = new Set();
  let cleanedByCard = new Map();
  let cleanedStatsByCard = new Map();
  let seenCardKeys = new Set();
  let mountedKeys = new Set();

  let activeModule = "all";
  let activeRisk = "all";
  let boardQuery = "";
  let boardSort = "bytes";
  let lastOperation = null;
  let busy = false;
  let scanning = false;
  let scanStatus = "扫描中";
  let scanStage = "准备扫描";
  let scanPercent = 0;
  let scanProgress = 0;
  let scanModuleProgress = 0;
  let scanIndex = 0;
  let scanTotal = MODULE_ORDER.length;
  let liveBytes = 0;
  let liveItems = 0;
  let renderedSignature = "";

  let diskStats = { totalBytes: 0, availableBytes: 0, freeBytes: 0, purgeableBytes: 0, usedBytes: 0, usedPercent: 0 };
  let cpuHistory = [];
  let metricsTimer = null;
  let agentMode = "confirm";

  let trashState = {
    open: false,
    items: 0,
    bytes: 0,
    digest: "",
    denied: false,
    top: [],
    loading: false,
  };

  let inspector = {
    open: false,
    card: null,
    q: "",
    risk: "",
    sort: "size",
    offset: 0,
    limit: 100,
    total: 0,
    entries: [],
    loading: false,
    searchTimer: null,
  };

  // ---------------------------------------------------------------- Grainient WebGL (Figure 1)

  function initGrainient() {
    const canvas = $("grainient");
    if (!canvas) return;
    const gl = canvas.getContext("webgl", { alpha: false, antialias: false, preserveDrawingBuffer: false });
    if (!gl) return;

    const vertSrc = `
      attribute vec2 aPos;
      varying vec2 vUv;
      void main() {
        vUv = aPos * 0.5 + 0.5;
        gl_Position = vec4(aPos, 0.0, 1.0);
      }
    `;

    const fragSrc = `
      precision highp float;
      varying vec2 vUv;
      uniform float uTime;
      uniform vec2 uRes;
      uniform float uLight;

      float hash21(vec2 p) {
        p = fract(p * vec2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
      }

      float noise(vec2 p) {
        vec2 i = floor(p);
        vec2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = hash21(i);
        float b = hash21(i + vec2(1.0, 0.0));
        float c = hash21(i + vec2(0.0, 1.0));
        float d = hash21(i + vec2(1.0, 1.0));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
      }

      void main() {
        float t = uTime * 0.25;
        vec2 uv = vUv;
        float aspect = uRes.x / max(uRes.y, 1.0);
        vec2 p = (uv - 0.5) * vec2(aspect, 1.0);

        float freq = 5.0;
        float strength = 1.0;

        float n1 = noise(p * (freq * 0.42) + vec2(t * 0.6, -t * 0.4));
        float n2 = noise(p * (freq * 0.65) + vec2(-t * 0.5, t * 0.7) + n1 * 1.4);

        vec2 warped = uv;
        warped.x += sin(uv.y * freq + t + n1 * 2.2) * 0.14 * strength;
        warped.y += cos(uv.x * freq * 0.8 - t * 0.8 + n2 * 2.0) * 0.12 * strength;

        vec3 c1 = vec3(0.282, 0.678, 0.600);
        vec3 c2 = vec3(0.322, 0.153, 1.000);
        vec3 c3 = vec3(0.125, 0.584, 0.812);
        vec3 bg = vec3(0.024, 0.000, 0.063);

        float x = clamp(warped.x + (n2 - 0.5) * 0.18, 0.0, 1.0);
        float band1 = smoothstep(0.05, 0.58, x);
        float band2 = smoothstep(0.42, 0.96, x);

        vec3 grad = mix(c1, c2, band1);
        grad = mix(grad, c3, band2);
        grad = mix(bg, grad, 0.90 + 0.10 * sin(n1 * 3.14159));

        float grain = (hash21(gl_FragCoord.xy + fract(t * 43.0) * 100.0) - 0.5) * 0.11;
        grad = clamp(grad + grain, 0.0, 1.0);

        if (uLight > 0.5) {
          vec3 lightBase = vec3(0.96, 0.975, 1.0);
          grad = mix(lightBase, grad, 0.24) + grain * 0.25;
        }

        gl_FragColor = vec4(clamp(grad, 0.0, 1.0), 1.0);
      }
    `;

    const compile = (type, src) => {
      const sh = gl.createShader(type);
      gl.shaderSource(sh, src);
      gl.compileShader(sh);
      return gl.getShaderParameter(sh, gl.COMPILE_STATUS) ? sh : null;
    };

    const vs = compile(gl.VERTEX_SHADER, vertSrc);
    const fs = compile(gl.FRAGMENT_SHADER, fragSrc);
    if (!vs || !fs) return;

    const prog = gl.createProgram();
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return;

    gl.useProgram(prog);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);

    const aPos = gl.getAttribLocation(prog, "aPos");
    gl.enableVertexAttribArray(aPos);
    gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

    const uTime = gl.getUniformLocation(prog, "uTime");
    const uRes = gl.getUniformLocation(prog, "uRes");
    const uLight = gl.getUniformLocation(prog, "uLight");

    const lightQuery = window.matchMedia("(prefers-color-scheme: light)");
    const reduceQuery = window.matchMedia("(prefers-reduced-motion: reduce)");

    const resize = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
      canvas.width = Math.max(1, Math.floor(window.innerWidth * dpr));
      canvas.height = Math.max(1, Math.floor(window.innerHeight * dpr));
      gl.viewport(0, 0, canvas.width, canvas.height);
    };

    resize();
    window.addEventListener("resize", resize);

    let rafId = 0;
    const start = performance.now();

    const draw = (now) => {
      const elapsed = reduceQuery.matches ? 0 : (now - start) / 1000;
      gl.uniform1f(uTime, elapsed);
      gl.uniform2f(uRes, canvas.width, canvas.height);
      gl.uniform1f(uLight, lightQuery.matches ? 1.0 : 0.0);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
      if (!reduceQuery.matches) {
        rafId = requestAnimationFrame(draw);
      }
    };

    const restart = () => {
      cancelAnimationFrame(rafId);
      draw(performance.now());
    };

    lightQuery.addEventListener("change", () => {
      if (reduceQuery.matches) draw(performance.now());
    });
    reduceQuery.addEventListener("change", restart);
    restart();
  }

  initGrainient();

  // ---------------------------------------------------------------- utils

  const fmt = (bytes) => {
    if (!bytes) return "0 B";
    const units = ["B", "KB", "MB", "GB", "TB"];
    let i = 0;
    let n = bytes;
    while (n >= 1024 && i < units.length - 1) {
      n /= 1024;
      i += 1;
    }
    return (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)) + " " + units[i];
  };

  const fmtCompact = (bytes) => {
    if (!bytes) return "0G";
    const gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 100) return Math.round(gb) + "G";
    if (gb >= 1) return gb.toFixed(1) + "G";
    const mb = bytes / (1024 * 1024);
    if (mb >= 1) return Math.round(mb) + "M";
    return Math.round(bytes / 1024) + "K";
  };

  const fmtCount = (n) => {
    if (n >= 10000) return Math.round(n / 1000) + "k 项";
    if (n >= 1000) return (n / 1000).toFixed(1).replace(/\.0$/, "") + "k 项";
    return n + " 项";
  };

  const fmtAge = (days) => {
    if (days === undefined || days === null) return "";
    if (days === 0) return "今天";
    return days + " 天前";
  };

  const shortPath = (path) => {
    const home = "/Users/";
    if (path.startsWith(home)) {
      const parts = path.split("/");
      parts.splice(0, 3, "~");
      return parts.join("/");
    }
    return path;
  };

  const fileName = (path) => {
    const idx = path.lastIndexOf("/");
    return idx >= 0 ? path.slice(idx + 1) || path : path;
  };

  const toast = (message) => {
    const el = $("toast");
    el.textContent = message;
    el.hidden = false;
    requestAnimationFrame(() => el.classList.add("is-shown"));
    clearTimeout(toast._timer);
    toast._timer = setTimeout(() => {
      el.classList.remove("is-shown");
      setTimeout(() => (el.hidden = true), 500);
    }, 2600);
  };

  const attachGlow = (el) => {
    el.setAttribute("data-glow", "");
    el.addEventListener("pointermove", (event) => {
      const rect = el.getBoundingClientRect();
      el.style.setProperty("--gx", Math.round(event.clientX - rect.left) + "px");
      el.style.setProperty("--gy", Math.round(event.clientY - rect.top) + "px");
    });
  };

  document.querySelectorAll("[data-glow]").forEach(attachGlow);

  // Build static matrix cells once
  (function initMatrices() {
    const diskMat = $("disk-matrix");
    for (let i = 0; i < MATRIX_CELLS; i += 1) {
      const cell = document.createElement("div");
      cell.className = "dot-cell";
      diskMat.appendChild(cell);
    }
    const memStrip = $("mem-strip");
    for (let i = 0; i < MEM_CELLS; i += 1) {
      const cell = document.createElement("div");
      cell.className = "mem-cell";
      memStrip.appendChild(cell);
    }
  })();

  // ---------------------------------------------------------------- selection model

  function getSelection(cardKey) {
    if (!selectionMap.has(cardKey)) {
      selectionMap.set(cardKey, {
        mode: "none",
        excluded: new Map(),
        included: new Map(),
      });
    }
    return selectionMap.get(cardKey);
  }

  function cardSelectedStats(card) {
    const sel = selectionMap.get(card.key);
    if (!sel || sel.mode === "none") return { state: "none", bytes: 0, count: 0 };

    if (sel.mode === "all") {
      return { state: "all", bytes: card.cleanableBytes, count: card.cleanableItems };
    }
    if (sel.mode === "exclude") {
      let exBytes = 0;
      for (const b of sel.excluded.values()) exBytes += b;
      const remCount = Math.max(0, card.cleanableItems - sel.excluded.size);
      const remBytes = Math.max(0, card.cleanableBytes - exBytes);
      if (remCount === 0) return { state: "none", bytes: 0, count: 0 };
      return { state: "partial", bytes: remBytes, count: remCount };
    }
    if (sel.mode === "include") {
      if (!sel.included.size) return { state: "none", bytes: 0, count: 0 };
      let inBytes = 0;
      for (const b of sel.included.values()) inBytes += b;
      const isAll = sel.included.size >= card.items;
      return { state: isAll ? "all" : "partial", bytes: inBytes, count: sel.included.size };
    }
    return { state: "none", bytes: 0, count: 0 };
  }

  function isEntrySelected(card, entry) {
    const sel = selectionMap.get(card.key);
    if (!sel || sel.mode === "none") return false;
    if (sel.mode === "all") return true;
    if (sel.mode === "exclude") return !sel.excluded.has(entry.id);
    if (sel.mode === "include") return sel.included.has(entry.id);
    return false;
  }

  function toggleCardSelection(card, checked) {
    selectionMap.set(card.key, {
      mode: checked ? "all" : "none",
      excluded: new Map(),
      included: new Map(),
    });
  }

  function toggleEntrySelection(card, entry, checked) {
    const sel = getSelection(card.key);
    if (sel.mode === "none" && checked) {
      sel.mode = "include";
      sel.included.set(entry.id, entry.bytes);
    } else if (sel.mode === "include") {
      if (checked) sel.included.set(entry.id, entry.bytes);
      else sel.included.delete(entry.id);
      if (sel.included.size === 0) sel.mode = "none";
    } else if (sel.mode === "all" && !checked) {
      sel.mode = "exclude";
      sel.excluded.set(entry.id, entry.bytes);
    } else if (sel.mode === "exclude") {
      if (checked) sel.excluded.delete(entry.id);
      else sel.excluded.set(entry.id, entry.bytes);
      if (sel.excluded.size === 0) sel.mode = "all";
    }
  }

  // ---------------------------------------------------------------- build fine cards

  function rebuildCards() {
    const nextCards = [];
    for (const group of groups) {
      const subs = group.subgroups || [];
      if (subs.length) {
        for (const sub of subs) {
          const key = group.snapshot + "|" + group.category + "|" + sub.id;
          const card = {
            key,
            snapshot: group.snapshot,
            module: group.module,
            category: group.category,
            parentLabel: group.label,
            subCategory: sub.id,
            label: sub.label,
            bytes: sub.bytes,
            items: sub.items,
            cleanableBytes: sub.cleanableBytes !== undefined ? sub.cleanableBytes : sub.bytes,
            cleanableItems: sub.cleanableItems !== undefined ? sub.cleanableItems : sub.items,
            risk: sub.risk || "confirm",
            riskLabel: sub.riskLabel || "按需确认",
            safeBytes: sub.safeBytes || 0,
            confirmBytes: sub.confirmBytes || 0,
            cautionBytes: sub.cautionBytes || 0,
            staleCount: sub.staleCount || 0,
            advice: sub.advice || "",
            top: sub.top || [],
          };
          if (!seenCardKeys.has(key)) {
            seenCardKeys.add(key);
            if (AUTO_SELECT.has(group.category) && card.risk === "safe" && card.cleanableItems > 0) {
              selectionMap.set(key, {
                mode: "all",
                excluded: new Map(),
                included: new Map(),
              });
            }
          }
          const cleanedDelta = cleanedStatsByCard.get(key);
          if (cleanedDelta) {
            card.items = Math.max(0, card.items - cleanedDelta.items);
            card.bytes = Math.max(0, card.bytes - cleanedDelta.bytes);
            card.cleanableItems = Math.max(0, card.cleanableItems - cleanedDelta.items);
            card.cleanableBytes = Math.max(0, card.cleanableBytes - cleanedDelta.bytes);
          }
          if (card.items > 0) nextCards.push(card);
        }
      } else {
        const key = group.snapshot + "|" + group.category + "|*";
        const card = {
          key,
          snapshot: group.snapshot,
          module: group.module,
          category: group.category,
          parentLabel: group.label,
          subCategory: "",
          label: group.label,
          bytes: group.bytes,
          items: group.items,
          cleanableBytes: group.bytes,
          cleanableItems: group.items,
          risk: "confirm",
          riskLabel: "按需确认",
          safeBytes: 0,
          confirmBytes: group.bytes,
          cautionBytes: 0,
          staleCount: 0,
          advice: "",
          top: (group.top || []).slice(0, 3).map((e) => ({
            id: e.id,
            name: fileName(e.path),
            path: e.path,
            bytes: e.bytes,
            ageDays: e.ageDays,
            risk: e.risk || "confirm",
          })),
        };
        if (!seenCardKeys.has(key)) {
          seenCardKeys.add(key);
          if (AUTO_SELECT.has(group.category)) {
            selectionMap.set(key, { mode: "all", excluded: new Map(), included: new Map() });
          }
        }
        const cleanedDelta = cleanedStatsByCard.get(key);
        if (cleanedDelta) {
          card.items = Math.max(0, card.items - cleanedDelta.items);
          card.bytes = Math.max(0, card.bytes - cleanedDelta.bytes);
          card.cleanableItems = Math.max(0, card.cleanableItems - cleanedDelta.items);
          card.cleanableBytes = Math.max(0, card.cleanableBytes - cleanedDelta.bytes);
        }
        if (card.items > 0) nextCards.push(card);
      }
    }
    nextCards.sort((a, b) => b.bytes - a.bytes);
    cards = nextCards;
  }

  // ---------------------------------------------------------------- state & live metrics

  function renderDiskCard(foundBytes) {
    const { totalBytes, availableBytes, freeBytes, purgeableBytes, usedBytes } = diskStats;
    if (!totalBytes) return;

    const junkBytes = Math.min(usedBytes, foundBytes);
    const coreUsed = Math.max(0, usedBytes - junkBytes);
    const pct = Math.round((usedBytes / totalBytes) * 1000) / 10;

    $("disk-free").textContent = fmt(availableBytes);
    $("disk-total").textContent = "/ " + fmt(totalBytes);
    $("disk-used").textContent = pct.toFixed(1).replace(/\.0$/, "") + "%";
    $("disk-stat-used").textContent = fmtCompact(coreUsed);
    $("disk-stat-junk").textContent = fmtCompact(junkBytes);
    $("disk-stat-purge").textContent = fmtCompact(purgeableBytes);
    $("disk-stat-free").textContent = fmtCompact(freeBytes || availableBytes);

    let usedCells = Math.round((coreUsed / totalBytes) * MATRIX_CELLS);
    let junkCells = junkBytes > 0 ? Math.max(1, Math.round((junkBytes / totalBytes) * MATRIX_CELLS)) : 0;
    let purgeCells = purgeableBytes > 0 ? Math.max(1, Math.round((purgeableBytes / totalBytes) * MATRIX_CELLS)) : 0;
    const totalFill = usedCells + junkCells + purgeCells;
    if (totalFill > MATRIX_CELLS) {
      usedCells = Math.max(0, MATRIX_CELLS - junkCells - purgeCells);
    }

    const cells = $("disk-matrix").children;
    for (let i = 0; i < MATRIX_CELLS; i += 1) {
      const cell = cells[i];
      if (!cell) continue;
      if (i < usedCells) cell.className = "dot-cell dot-cell--used";
      else if (i < usedCells + junkCells) cell.className = "dot-cell dot-cell--junk";
      else if (i < usedCells + junkCells + purgeCells) cell.className = "dot-cell dot-cell--purge";
      else cell.className = "dot-cell";
    }
  }

  function renderTelemetry(data) {
    if (!data) return;
    if (data.disk) {
      diskStats = data.disk;
    }

    const modeLabels = { confirm: "确认模式", auto: "自动模式", readonly: "只读模式" };
    const agent = data.agent || {};
    if (agent.mode) agentMode = agent.mode;
    $("agent-mode").textContent = modeLabels[agent.mode] || agent.mode || "--";
    $("agent-fda").textContent = agent.fullDiskAccess ? "全盘权限" : "受限权限";
    if (trashState.denied && agent.fullDiskAccess && !trashState.loading) loadTrash();

    const cpu = data.cpu || {};
    const cpuPct = typeof cpu.usagePercent === "number" ? cpu.usagePercent : 0;
    $("cpu-val").textContent = Math.round(cpuPct) + "% · " + (cpu.cores || "--") + "C";
    cpuHistory.push(Math.min(100, Math.max(2, cpuPct)));
    if (cpuHistory.length > 20) cpuHistory.shift();

    const pts = cpuHistory.length === 1 ? [cpuHistory[0], cpuHistory[0]] : cpuHistory;
    const w = 120;
    const h = 34;
    const polyPts = pts.map((val, idx) => {
      const x = (idx / (pts.length - 1)) * w;
      const y = h - 3 - (val / 100) * (h - 6);
      return x.toFixed(1) + "," + y.toFixed(1);
    }).join(" ");
    $("cpu-line").setAttribute("points", polyPts);
    $("cpu-area").setAttribute("points", "0," + h + " " + polyPts + " " + w + "," + h);

    const mem = data.memory || {};
    const memTotal = mem.totalBytes || 0;
    const memUsed = mem.usedBytes || 0;
    $("mem-val").textContent = fmtCompact(memUsed) + "/" + fmtCompact(memTotal);
    $("mem-sub").textContent = "负载 " + (cpu.load1 !== undefined ? cpu.load1.toFixed(2) : "--") + " · " + Math.round(mem.usedPercent || 0) + "%";

    const memCells = $("mem-strip").children;
    if (memTotal > 0) {
      let activeC = Math.round(((mem.activeBytes || 0) / memTotal) * MEM_CELLS);
      let wiredC = Math.round(((mem.wiredBytes || 0) / memTotal) * MEM_CELLS);
      let compC = Math.round(((mem.compressedBytes || 0) / memTotal) * MEM_CELLS);
      if (activeC + wiredC + compC > MEM_CELLS) {
        activeC = Math.max(0, MEM_CELLS - wiredC - compC);
      }
      for (let i = 0; i < MEM_CELLS; i += 1) {
        const cell = memCells[i];
        if (!cell) continue;
        if (i < activeC) cell.className = "mem-cell mem-cell--active";
        else if (i < activeC + wiredC) cell.className = "mem-cell mem-cell--wired";
        else if (i < activeC + wiredC + compC) cell.className = "mem-cell mem-cell--comp";
        else cell.className = "mem-cell";
      }
    }

    const hist = data.history || {};
    $("hist-total").textContent = fmt(hist.totalCleanedBytes || 0);
    $("hist-ops").textContent = (hist.totalOperations || 0) + " 次 · " + fmtCount(hist.totalMovedItems || 0);

    const daily = hist.daily || [];
    const maxBytes = Math.max(1, ...daily.map((d) => d.bytes || 0));
    const barsEl = $("hist-bars");
    barsEl.innerHTML = "";
    for (const day of daily) {
      const col = document.createElement("div");
      col.className = "act-col";
      col.title = day.label + " · " + fmt(day.bytes || 0) + " · " + (day.ops || 0) + " 次";

      const track = document.createElement("div");
      track.className = "act-track";

      const fill = document.createElement("div");
      const hasOps = (day.ops || 0) > 0;
      fill.className = "act-fill" + (hasOps ? " has-ops" : "");
      const ratio = hasOps ? Math.max(0.24, Math.min(1, (day.bytes || 0) / maxBytes)) : 0.12;
      fill.style.transform = "scaleY(" + ratio + ")";

      const lbl = document.createElement("span");
      lbl.className = "act-day";
      lbl.textContent = (day.label || "").slice(3);

      track.appendChild(fill);
      col.append(track, lbl);
      barsEl.appendChild(col);
    }

    updateChrome();
  }

  async function loadMetrics() {
    try {
      const res = await fetch("/api/metrics", { cache: "no-store" });
      if (!res.ok) return;
      const data = await res.json();
      renderTelemetry(data);
    } catch (_) {
      // keep existing metrics on transient failure
    }
  }

  async function loadState() {
    try {
      const res = await fetch("/api/state", { cache: "no-store" });
      const state = await res.json();
      const { disk, operations } = state;

      diskStats.totalBytes = disk.totalBytes;
      diskStats.availableBytes = disk.availableBytes;
      diskStats.usedBytes = disk.usedBytes;
      if (!diskStats.freeBytes) diskStats.freeBytes = disk.availableBytes;

      if (state.mode) agentMode = state.mode;
      if (operations && operations.length && !lastOperation) {
        lastOperation = operations[operations.length - 1];
        $("undo").hidden = !lastOperation;
      }
      updateChrome();
    } catch (error) {
      scanStatus = "离线";
      updateChrome();
      toast("离线");
    }
  }

  // ---------------------------------------------------------------- scan

  async function startScan() {
    if (scanning) return;
    groups = [];
    cards = [];
    selectionMap.clear();
    cleanedIds.clear();
    cleanedByCard.clear();
    cleanedStatsByCard.clear();
    seenCardKeys.clear();
    mountedKeys.clear();
    renderedSignature = "";
    scanning = true;
    scanIndex = 0;
    scanTotal = MODULE_ORDER.length;
    scanPercent = 0;
    scanProgress = 0;
    scanModuleProgress = 0;
    scanStage = "准备扫描";
    liveBytes = 0;
    liveItems = 0;
    scanStatus = "扫描 1/" + scanTotal + " · 0%";
    updateChrome();
    renderRail();
    renderGrid(true);

    try {
      const res = await fetch("/api/scan", { method: "POST" });
      const { id } = await res.json();
      poll(id);
    } catch (error) {
      scanning = false;
      scanStatus = "失败";
      scanStage = "扫描启动失败";
      updateChrome();
      renderRail();
      renderGrid(true);
      toast("扫描失败");
    }
  }

  async function poll(id) {
    try {
      const res = await fetch("/api/job?id=" + encodeURIComponent(id), { cache: "no-store" });
      const job = await res.json();

      groups = (job.groups || []).filter((group) => group.items > 0);
      rebuildCards();

      if (typeof job.progress === "number") scanProgress = job.progress;
      if (typeof job.percent === "number") scanPercent = job.percent;
      if (typeof job.moduleProgress === "number") scanModuleProgress = job.moduleProgress;
      if (job.stage) scanStage = job.stage;
      if (typeof job.liveBytes === "number") liveBytes = job.liveBytes;
      if (typeof job.liveItems === "number") liveItems = job.liveItems;

      if (job.state === "running") {
        scanIndex = job.index || 0;
        scanTotal = job.total || MODULE_ORDER.length;
        scanStatus = "扫描 " + Math.min(scanIndex + 1, scanTotal) + "/" + scanTotal + " · " + scanPercent + "%";
        updateChrome();
        renderRail();
        renderGrid(false);
        setTimeout(() => poll(id), 450);
        return;
      }

      if (job.state === "cancelled") return;

      scanning = false;
      scanIndex = MODULE_ORDER.length;
      scanPercent = 100;
      scanProgress = 1;
      scanModuleProgress = 1;
      scanStatus = "就绪";
      scanStage = "完成";
      updateChrome();
      renderRail();
      renderGrid(true);
      loadMetrics();
    } catch (error) {
      scanning = false;
      scanStatus = "中断";
      scanStage = "扫描中断";
      updateChrome();
      renderRail();
      renderGrid(true);
      toast("扫描中断");
    }
  }

  // ---------------------------------------------------------------- render

  function renderScanViz(foundBytes, selectedBytes) {
    let safeBytes = 0;
    let confirmBytes = 0;
    let cautionBytes = 0;
    const byMod = new Map(MODULE_ORDER.map((m) => [m, 0]));

    for (const card of cards) {
      if (card.risk === "safe") safeBytes += card.bytes;
      else if (card.risk === "caution") cautionBytes += card.bytes;
      else confirmBytes += card.bytes;
      if (card.module) byMod.set(card.module, (byMod.get(card.module) || 0) + card.bytes);
    }

    const denom = Math.max(1, safeBytes + confirmBytes + cautionBytes);

    $("bar-safe-val").textContent = fmt(safeBytes);
    $("bar-confirm-val").textContent = fmt(confirmBytes);
    $("bar-caution-val").textContent = fmt(cautionBytes);
    $("bar-safe-fill").style.transform = "scaleX(" + (safeBytes / denom) + ")";
    $("bar-confirm-fill").style.transform = "scaleX(" + (confirmBytes / denom) + ")";
    $("bar-caution-fill").style.transform = "scaleX(" + (cautionBytes / denom) + ")";

    const safeLen = (safeBytes / denom) * RING_CIRC;
    const confirmLen = (confirmBytes / denom) * RING_CIRC;
    const cautionLen = (cautionBytes / denom) * RING_CIRC;

    const rSafe = $("ring-safe");
    const rConfirm = $("ring-confirm");
    const rCaution = $("ring-caution");

    rSafe.setAttribute("stroke-dasharray", safeLen.toFixed(1) + " " + RING_CIRC.toFixed(1));
    rSafe.setAttribute("stroke-dashoffset", "0");

    rConfirm.setAttribute("stroke-dasharray", confirmLen.toFixed(1) + " " + RING_CIRC.toFixed(1));
    rConfirm.setAttribute("stroke-dashoffset", (-safeLen).toFixed(1));

    rCaution.setAttribute("stroke-dasharray", cautionLen.toFixed(1) + " " + RING_CIRC.toFixed(1));
    rCaution.setAttribute("stroke-dashoffset", (-(safeLen + confirmLen)).toFixed(1));

    if (scanning && foundBytes === 0) {
      $("ring-label").textContent = "扫描";
      $("ring-val").textContent = scanPercent + "%";
    } else {
      $("ring-label").textContent = "已选";
      $("ring-val").textContent = fmtCompact(selectedBytes);
    }

    const segs = $("mod-segments");
    segs.innerHTML = "";
    for (const mod of MODULES.slice(1)) {
      const b = byMod.get(mod.id) || 0;
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "mod-seg" + (activeModule === mod.id ? " is-active" : "");
      btn.textContent = mod.short + (b > 0 ? " " + fmtCompact(b) : "");
      btn.addEventListener("click", () => {
        activeModule = activeModule === mod.id ? "all" : mod.id;
        mountedKeys.clear();
        updateChrome();
        renderRail();
        renderGrid(true);
      });
      segs.appendChild(btn);
    }
  }

  function updateChrome() {
    $("scan-status").textContent = scanStatus;
    const dot = $("status-dot");
    dot.classList.toggle("is-scanning", scanning);
    dot.classList.toggle("is-ready", !scanning && scanStatus === "就绪");
    $("rescan").disabled = scanning || busy;
    renderTrashPill();

    const scanRatio = !scanning && scanStatus === "就绪" ? 1 : Math.min(1, Math.max(0, scanProgress));
    const pctText = (!scanning && scanStatus === "就绪" ? 100 : scanPercent) + "%";
    $("scan-bar").style.transform = "scaleX(" + scanRatio + ")";
    $("scan-pct").textContent = pctText;
    $("scan-stage").textContent = scanning ? scanStage : (scanStatus === "就绪" ? "全部 4 项已完成" : scanStage);

    let foundBytes = 0;
    let foundCount = 0;
    for (const card of cards) {
      foundBytes += card.bytes;
      foundCount += card.items;
    }
    const displayFoundBytes = Math.max(foundBytes, scanning ? liveBytes : 0);
    const displayFoundCount = Math.max(foundCount, scanning ? liveItems : 0);

    $("found-bytes").textContent = fmt(displayFoundBytes);
    $("found-count").textContent = fmtCount(displayFoundCount);

    renderDiskCard(displayFoundBytes);
    const { bytes: selectedBytes } = updateSum();
    renderScanViz(displayFoundBytes, selectedBytes);
  }

  function renderRail() {
    const rail = $("rail");
    rail.innerHTML = "";

    const byModule = new Map();
    for (const mod of MODULE_ORDER) byModule.set(mod, 0);
    let totalBytes = 0;

    const byRisk = new Map([["safe", 0], ["confirm", 0], ["caution", 0]]);
    const byRiskBytes = new Map([["safe", 0], ["confirm", 0], ["caution", 0]]);
    for (const card of cards) {
      totalBytes += card.bytes;
      if (card.module) byModule.set(card.module, (byModule.get(card.module) || 0) + card.bytes);
      byRisk.set(card.risk, (byRisk.get(card.risk) || 0) + 1);
      byRiskBytes.set(card.risk, (byRiskBytes.get(card.risk) || 0) + card.bytes);
    }
    const modDenom = Math.max(1, totalBytes);

    const modSection = document.createElement("div");
    modSection.className = "rail__section";
    const modTitle = document.createElement("div");
    modTitle.className = "rail__title";
    modTitle.textContent = "模块";
    modSection.appendChild(modTitle);

    for (const mod of MODULES) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "rail__item" + (activeModule === mod.id ? " is-active" : "");

      const row = document.createElement("div");
      row.className = "rail__row";

      const nameWrap = document.createElement("span");
      nameWrap.className = "rail__name";
      const dot = document.createElement("span");
      dot.className = "rail__dot";
      const label = document.createElement("span");
      label.className = "rail__label";
      label.textContent = mod.label;
      nameWrap.append(dot, label);

      const meta = document.createElement("span");
      meta.className = "rail__meta";

      let barRatio = 0;
      if (mod.id === "all") {
        const displayTot = Math.max(totalBytes, scanning ? liveBytes : 0);
        meta.textContent = fmt(displayTot);
        barRatio = displayTot > 0 ? 1 : 0;
      } else {
        const idx = MODULE_ORDER.indexOf(mod.id);
        const modB = byModule.get(mod.id) || 0;
        if (scanning && idx === scanIndex) {
          meta.textContent = Math.round(scanModuleProgress * 100) + "%";
          barRatio = scanModuleProgress;
        } else if (scanning && idx > scanIndex) {
          meta.textContent = "--";
          barRatio = 0;
        } else {
          meta.textContent = fmt(modB);
          barRatio = modB / modDenom;
        }
      }

      row.append(nameWrap, meta);

      const bar = document.createElement("div");
      bar.className = "rail__bar";
      const fill = document.createElement("div");
      fill.className = "rail__bar-fill";
      fill.style.transform = "scaleX(" + Math.min(1, Math.max(0, barRatio)) + ")";
      bar.appendChild(fill);

      btn.append(row, bar);
      btn.addEventListener("click", () => {
        if (activeModule === mod.id) return;
        activeModule = mod.id;
        mountedKeys.clear();
        updateChrome();
        renderRail();
        renderGrid(true);
      });
      modSection.appendChild(btn);
    }

    const riskSection = document.createElement("div");
    riskSection.className = "rail__section";
    const riskTitle = document.createElement("div");
    riskTitle.className = "rail__title";
    riskTitle.textContent = "清理建议";
    riskSection.appendChild(riskTitle);

    for (const r of RISKS) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "rail__item" + (activeRisk === r.id ? " is-active" : "");

      const row = document.createElement("div");
      row.className = "rail__row";

      const nameWrap = document.createElement("span");
      nameWrap.className = "rail__name";
      const dot = document.createElement("span");
      dot.className = "rail__dot" + (r.id !== "all" ? " rail__dot--" + r.id : "");
      const label = document.createElement("span");
      label.className = "rail__label";
      label.textContent = r.label;
      nameWrap.append(dot, label);

      const meta = document.createElement("span");
      meta.className = "rail__meta";
      const rBytes = r.id === "all" ? totalBytes : (byRiskBytes.get(r.id) || 0);
      const rCount = r.id === "all" ? cards.length : (byRisk.get(r.id) || 0);
      meta.textContent = rCount ? rCount + " · " + fmtCompact(rBytes) : "0";

      row.append(nameWrap, meta);

      const bar = document.createElement("div");
      bar.className = "rail__bar";
      const fill = document.createElement("div");
      fill.className = "rail__bar-fill" + (r.id !== "all" ? " rail__bar-fill--" + r.id : "");
      fill.style.transform = "scaleX(" + Math.min(1, Math.max(0, rBytes / modDenom)) + ")";
      bar.appendChild(fill);

      btn.append(row, bar);
      btn.addEventListener("click", () => {
        if (activeRisk === r.id) return;
        activeRisk = r.id;
        mountedKeys.clear();
        renderRail();
        renderGrid(true);
      });
      riskSection.appendChild(btn);
    }

    const quick = document.createElement("div");
    quick.className = "rail__quick";

    let selBytes = 0;
    for (const c of cards) selBytes += cardSelectedStats(c).bytes;
    const selPct = totalBytes > 0 ? Math.round((selBytes / totalBytes) * 100) : 0;

    const qHead = document.createElement("div");
    qHead.className = "rail__quick-head";
    qHead.innerHTML = '<span>已选占比</span><span class="rail__quick-pct">' + selPct + '%</span>';

    const qDots = document.createElement("div");
    qDots.className = "rail__dots";
    const onCount = Math.round((selPct / 100) * 10);
    for (let i = 0; i < 10; i += 1) {
      const dc = document.createElement("div");
      dc.className = "rail__dcell" + (i < onCount ? " is-on" : "");
      qDots.appendChild(dc);
    }

    const safeBtn = document.createElement("button");
    safeBtn.type = "button";
    safeBtn.className = "pill-btn";
    safeBtn.textContent = "仅选推荐清理";
    safeBtn.disabled = !cards.some((c) => c.risk === "safe" && c.cleanableItems > 0) || busy;
    safeBtn.addEventListener("click", () => {
      for (const c of cards) {
        toggleCardSelection(c, c.risk === "safe" && c.cleanableItems > 0);
      }
      updateChrome();
      renderRail();
    });

    quick.append(qHead, qDots, safeBtn);
    rail.append(modSection, riskSection, quick);
  }

  function visibleCards() {
    const q = boardQuery.toLowerCase();
    const list = cards.filter((card) => {
      if (activeModule !== "all" && card.module !== activeModule) return false;
      if (activeRisk !== "all" && card.risk !== activeRisk) return false;
      if (q) {
        const hitLabel = card.label.toLowerCase().includes(q) || card.parentLabel.toLowerCase().includes(q);
        const hitTop = (card.top || []).some((t) => (t.path || "").toLowerCase().includes(q) || (t.name || "").toLowerCase().includes(q));
        if (!hitLabel && !hitTop) return false;
      }
      return true;
    });

    const riskRank = { safe: 0, confirm: 1, caution: 2 };
    if (boardSort === "items") {
      list.sort((a, b) => b.items - a.items);
    } else if (boardSort === "risk") {
      list.sort((a, b) => (riskRank[a.risk] ?? 9) - (riskRank[b.risk] ?? 9) || b.bytes - a.bytes);
    } else {
      list.sort((a, b) => b.bytes - a.bytes);
    }
    return list;
  }

  function renderGrid(force) {
    const list = visibleCards();
    const listBytes = list.reduce((acc, c) => acc + c.bytes, 0);
    $("board-meta").textContent = list.length + " 类 · " + fmt(listBytes);

    const sig = activeModule + "::" + activeRisk + "::" + boardQuery + "::" + boardSort + "::" +
      (scanning ? "1" : "0") + "::" + list.map((c) => c.key + ":" + c.items + ":" + c.bytes).join("|");
    if (!force && sig === renderedSignature) return;
    renderedSignature = sig;

    const totalAllBytes = Math.max(1, cards.reduce((acc, c) => acc + c.bytes, 0));
    const grid = $("grid");
    grid.innerHTML = "";

    if (!list.length) {
      if (scanning) {
        const count = activeModule === "all" ? 4 : 2;
        for (let i = 0; i < count; i += 1) {
          const sk = document.createElement("div");
          sk.className = "skeleton__card";
          grid.appendChild(sk);
        }
      } else {
        const empty = document.createElement("div");
        empty.className = "empty";
        empty.textContent = "0 项";
        grid.appendChild(empty);
      }
      updateSum();
      return;
    }

    let enterIdx = 0;
    const nextMounted = new Set();

    for (const cardData of list) {
      nextMounted.add(cardData.key);
      const isNew = !mountedKeys.has(cardData.key);
      const card = document.createElement("section");
      card.className = "group" + (isNew ? " is-entering" : "");
      card.dataset.cardKey = cardData.key;
      if (isNew) {
        card.style.setProperty("--delay", Math.min(enterIdx, 8) * 35 + "ms");
        enterIdx += 1;
      }
      attachGlow(card);

      const head = document.createElement("div");
      head.className = "group__head";

      const top = document.createElement("div");
      top.className = "group__top";

      const badges = document.createElement("div");
      badges.className = "group__badges";

      const parentBadge = document.createElement("span");
      parentBadge.className = "badge badge--neutral";
      parentBadge.textContent = cardData.parentLabel;

      const riskBadge = document.createElement("span");
      riskBadge.className = "badge badge--" + cardData.risk;
      riskBadge.textContent = cardData.riskLabel;

      const sharePct = Math.max(0.1, (cardData.bytes / totalAllBytes) * 100);
      const shareBadge = document.createElement("span");
      shareBadge.className = "badge badge--neutral";
      shareBadge.textContent = (sharePct >= 10 ? Math.round(sharePct) : sharePct.toFixed(1)) + "%";

      badges.append(parentBadge, riskBadge, shareBadge);

      const stats = cardSelectedStats(cardData);
      if (stats.state !== "none") card.classList.add("is-selected");

      const check = document.createElement("input");
      check.type = "checkbox";
      check.className = "group__check";
      check.checked = stats.state === "all";
      check.indeterminate = stats.state === "partial";
      check.disabled = cardData.cleanableItems === 0 && stats.state === "none";
      check.setAttribute("aria-label", cardData.label);
      check.addEventListener("change", () => {
        toggleCardSelection(cardData, check.checked);
        updateChrome();
        renderRail();
      });
      check.addEventListener("click", (event) => event.stopPropagation());

      top.append(badges, check);

      const titleRow = document.createElement("div");
      titleRow.className = "group__title-row";

      const label = document.createElement("div");
      label.className = "group__label";
      label.textContent = cardData.label;

      const bytes = document.createElement("span");
      bytes.className = "group__bytes";
      bytes.textContent = fmt(cardData.bytes);

      titleRow.append(label, bytes);

      // 12-cell visual distribution strip (Ref 2 & 3 style)
      const dotStrip = document.createElement("div");
      dotStrip.className = "group__dot-strip";
      const totalC = Math.max(1, cardData.bytes);
      const filledTotal = Math.max(1, Math.min(12, Math.round((cardData.bytes / totalAllBytes) * 24)));
      const safeCells = Math.round((cardData.safeBytes / totalC) * filledTotal);
      const confirmCells = Math.round((cardData.confirmBytes / totalC) * filledTotal);
      const cautionCells = Math.max(0, filledTotal - safeCells - confirmCells);
      for (let i = 0; i < 12; i += 1) {
        const c = document.createElement("div");
        if (i < safeCells) c.className = "gcell gcell--safe";
        else if (i < safeCells + confirmCells) c.className = "gcell gcell--confirm";
        else if (i < safeCells + confirmCells + cautionCells) c.className = "gcell gcell--caution";
        else c.className = "gcell";
        dotStrip.appendChild(c);
      }

      // Top sample files preview with inline proportional bars
      const visibleTop = (cardData.top || []).filter((t) => !cleanedIds.has(t.id)).slice(0, 3);
      let previewsEl = null;
      if (visibleTop.length) {
        previewsEl = document.createElement("div");
        previewsEl.className = "card-previews";
        const topMax = Math.max(1, visibleTop[0].bytes || 1);
        for (const t of visibleTop) {
          const itemWrap = document.createElement("div");
          itemWrap.className = "preview-item";

          const pRow = document.createElement("div");
          pRow.className = "preview-row";

          const pName = document.createElement("span");
          pName.className = "preview-name";
          pName.textContent = t.name || fileName(t.path || "");
          pName.title = t.path || "";

          const pRight = document.createElement("span");
          pRight.className = "preview-right";
          const age = fmtAge(t.ageDays);
          if (age) {
            const pAge = document.createElement("span");
            pAge.className = "preview-age";
            pAge.textContent = age;
            pRight.appendChild(pAge);
          }
          const pBytes = document.createElement("span");
          pBytes.className = "preview-bytes";
          pBytes.textContent = fmt(t.bytes);
          pRight.appendChild(pBytes);

          pRow.append(pName, pRight);

          const pTrack = document.createElement("div");
          pTrack.className = "preview-track";
          const pFill = document.createElement("div");
          pFill.className = "preview-fill";
          pFill.style.transform = "scaleX(" + Math.max(0.08, Math.min(1, t.bytes / topMax)) + ")";
          pTrack.appendChild(pFill);

          itemWrap.append(pRow, pTrack);
          previewsEl.appendChild(itemWrap);
        }
      }

      let adviceEl = null;
      if (cardData.advice) {
        adviceEl = document.createElement("div");
        adviceEl.className = "card-advice";
        adviceEl.innerHTML = '<span class="card-advice__tag">建议</span><span class="card-advice__text"></span>';
        adviceEl.querySelector(".card-advice__text").textContent = cardData.advice;
      }

      const meta = document.createElement("div");
      meta.className = "group__meta";

      const statsEl = document.createElement("div");
      statsEl.className = "group__stats";

      const count = document.createElement("span");
      count.className = "group__count";
      count.textContent = cardData.cleanableItems < cardData.items
        ? fmtCount(cardData.items) + " · 直清 " + fmtCompact(cardData.cleanableBytes)
        : fmtCount(cardData.items) + (cardData.staleCount ? " · 陈旧 " + cardData.staleCount : "");

      statsEl.appendChild(count);

      const inspect = document.createElement("button");
      inspect.type = "button";
      inspect.className = "group__inspect";
      inspect.innerHTML = '<span>全部文件</span><svg class="group__chevron" viewBox="0 0 16 16" aria-hidden="true"><path d="M6 3.5L10.5 8L6 12.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
      inspect.addEventListener("click", (event) => {
        event.stopPropagation();
        openInspector(cardData);
      });

      meta.append(statsEl, inspect);
      head.append(top, titleRow, dotStrip);
      if (previewsEl) head.appendChild(previewsEl);
      if (adviceEl) head.appendChild(adviceEl);
      head.appendChild(meta);

      head.addEventListener("click", (event) => {
        if (event.target === check || event.target.closest(".group__inspect")) return;
        if (check.disabled) return;
        const liveStats = cardSelectedStats(cardData);
        const nextChecked = liveStats.state !== "all";
        toggleCardSelection(cardData, nextChecked);
        updateChrome();
        renderRail();
      });

      card.appendChild(head);
      grid.appendChild(card);
    }

    if (scanning && (activeModule === "all" || activeModule === MODULE_ORDER[scanIndex])) {
      const sk = document.createElement("div");
      sk.className = "skeleton__card";
      grid.appendChild(sk);
    }

    mountedKeys = nextMounted;
    updateChrome();
  }

  function syncGridCheckboxes() {
    const grid = $("grid");
    for (const cardEl of grid.querySelectorAll(".group")) {
      const key = cardEl.dataset.cardKey;
      const cardData = cards.find((c) => c.key === key);
      const check = cardEl.querySelector(".group__check");
      if (!cardData || !check) continue;
      const stats = cardSelectedStats(cardData);
      check.checked = stats.state === "all";
      check.indeterminate = stats.state === "partial";
      check.disabled = cardData.cleanableItems === 0 && stats.state === "none";
      cardEl.classList.toggle("is-selected", stats.state !== "none");
    }
  }

  function selectableVisibleCards() {
    return visibleCards().filter((card) => card.cleanableItems > 0);
  }

  function areAllVisibleSelected() {
    const list = selectableVisibleCards();
    if (!list.length) return false;
    return list.every((card) => cardSelectedStats(card).state === "all");
  }

  function toggleSelectAll() {
    const list = selectableVisibleCards();
    if (!list.length || busy) return;
    const next = !areAllVisibleSelected();
    for (const card of list) {
      toggleCardSelection(card, next);
    }
    updateChrome();
  }

  function updateSum() {
    let bytes = 0;
    let count = 0;
    for (const card of cards) {
      const stats = cardSelectedStats(card);
      bytes += stats.bytes;
      count += stats.count;
    }
    $("sum-bytes").textContent = fmt(bytes);
    $("sum-count").textContent = scanning
      ? "扫描 " + scanPercent + "%" + (count ? " · " + fmtCount(count) : "")
      : fmtCount(count);

    const selectable = selectableVisibleCards();
    const allSel = areAllVisibleSelected();
    $("select-all").disabled = selectable.length === 0 || busy;
    $("select-all").textContent = allSel ? "全不选" : "全选";

    $("clean").disabled = count === 0 || busy;
    $("clean").textContent = busy ? "清理中" : "清理";
    syncGridCheckboxes();
    updateDrawerSelectionSummary();
    return { bytes, count };
  }

  // ---------------------------------------------------------------- File Inspector Drawer

  function openInspector(cardData) {
    inspector.open = true;
    inspector.card = cardData;
    inspector.q = "";
    inspector.risk = "";
    inspector.sort = "size";
    inspector.offset = 0;
    inspector.entries = [];

    $("drawer-search").value = "";
    $("drawer-sort").value = "size";
    for (const chip of $("drawer-risk-chips").querySelectorAll(".chip")) {
      chip.classList.toggle("is-active", chip.dataset.risk === "");
    }

    $("drawer-parent").textContent = cardData.parentLabel;
    $("drawer-risk").className = "badge badge--" + cardData.risk;
    $("drawer-risk").textContent = cardData.riskLabel;
    $("drawer-title").textContent = cardData.label;
    $("drawer-totals").textContent = fmtCount(cardData.items) + " · " + fmt(cardData.bytes);
    $("drawer").hidden = false;
    updateDrawerSelectionSummary();
    fetchInspectorPage(false);
  }

  function closeInspector() {
    inspector.open = false;
    $("drawer").hidden = true;
  }

  function updateDrawerSelectionSummary() {
    if (!inspector.open || !inspector.card) return;
    const stats = cardSelectedStats(inspector.card);
    $("drawer-sel").textContent = "已选 " + fmtCount(stats.count) + " · " + fmt(stats.bytes);
  }

  async function fetchInspectorPage(append) {
    const card = inspector.card;
    if (!card) return;
    inspector.loading = true;
    const listEl = $("drawer-list");
    if (!append) {
      inspector.offset = 0;
      listEl.innerHTML = '<div class="skeleton__card"></div><div class="skeleton__card"></div>';
      $("drawer-more").hidden = true;
    }

    const params = new URLSearchParams({
      path: card.snapshot,
      category: card.category,
      sort: inspector.sort,
      offset: String(inspector.offset),
      limit: String(inspector.limit),
    });
    if (card.subCategory) params.set("sub", card.subCategory);
    if (inspector.risk) params.set("risk", inspector.risk);
    if (inspector.q) params.set("q", inspector.q);

    try {
      const res = await fetch("/api/snapshot?" + params.toString(), { cache: "no-store" });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "读取快照失败");

      inspector.total = data.total || 0;
      const incoming = data.entries || [];
      inspector.entries = append ? inspector.entries.concat(incoming) : incoming;
      inspector.offset = inspector.entries.length;

      const displayTotal = !inspector.q && !inspector.risk ? card.items : Math.max(0, (data.total || 0) - (cleanedByCard.get(card.key)?.size || 0));
      const displayBytes = !inspector.q && !inspector.risk ? card.bytes : (data.totalBytes || 0);
      $("drawer-totals").textContent = fmtCount(displayTotal) + " · " + fmt(displayBytes);
      renderDrawerEntries();
    } catch (error) {
      listEl.innerHTML = '<div class="empty">加载失败</div>';
      toast(String(error.message || error));
    } finally {
      inspector.loading = false;
    }
  }

  function renderDrawerEntries() {
    const listEl = $("drawer-list");
    listEl.innerHTML = "";
    const card = inspector.card;
    if (!card) return;

    const visibleEntries = inspector.entries.filter((entry) => !cleanedIds.has(entry.id));
    if (!visibleEntries.length) {
      const empty = document.createElement("div");
      empty.className = "empty";
      empty.textContent = "0 项";
      listEl.appendChild(empty);
      $("drawer-more").hidden = true;
      return;
    }

    for (const entry of visibleEntries) {
      const row = document.createElement("div");
      row.className = "file-row";

      const head = document.createElement("div");
      head.className = "file-row__head";

      const left = document.createElement("div");
      left.className = "file-row__left";

      const check = document.createElement("input");
      check.type = "checkbox";
      check.className = "group__check";
      check.checked = isEntrySelected(card, entry);
      check.setAttribute("aria-label", fileName(entry.path));
      check.addEventListener("change", () => {
        toggleEntrySelection(card, entry, check.checked);
        updateChrome();
      });

      const nameEl = document.createElement("span");
      nameEl.className = "file-row__name";
      nameEl.textContent = fileName(entry.path);
      nameEl.title = entry.path;

      left.append(check, nameEl);

      const right = document.createElement("div");
      right.className = "file-row__right";

      const riskBadge = document.createElement("span");
      riskBadge.className = "badge badge--" + (entry.risk || "confirm");
      riskBadge.textContent = entry.riskLabel || "按需确认";

      const ageText = fmtAge(entry.ageDays);
      if (ageText) {
        const ageBadge = document.createElement("span");
        ageBadge.className = "badge badge--neutral";
        ageBadge.textContent = ageText;
        right.appendChild(ageBadge);
      }

      const bytesEl = document.createElement("span");
      bytesEl.className = "file-row__bytes";
      bytesEl.textContent = fmt(entry.bytes);

      right.append(riskBadge, bytesEl);
      head.append(left, right);

      const pathEl = document.createElement("div");
      pathEl.className = "file-row__path";
      pathEl.textContent = shortPath(entry.path);

      const analysisEl = document.createElement("div");
      analysisEl.className = "file-row__analysis";

      const purposeLine = document.createElement("div");
      purposeLine.className = "analysis-line";
      const purposeTag = document.createElement("span");
      purposeTag.className = "analysis-tag";
      purposeTag.textContent = "用途";
      const purposeText = document.createElement("span");
      purposeText.textContent = entry.purpose || "--";
      purposeLine.append(purposeTag, purposeText);

      const adviceLine = document.createElement("div");
      adviceLine.className = "analysis-line";
      const adviceTag = document.createElement("span");
      adviceTag.className = "analysis-tag analysis-tag--advice";
      adviceTag.textContent = "建议";
      const adviceText = document.createElement("span");
      adviceText.textContent = entry.advice || "--";
      adviceLine.append(adviceTag, adviceText);

      analysisEl.append(purposeLine, adviceLine);
      row.append(head, pathEl, analysisEl);
      listEl.appendChild(row);
    }

    const remaining = Math.max(0, inspector.total - inspector.entries.length);
    $("drawer-more").hidden = remaining === 0;
    $("drawer-load-more").textContent = "加载更多（" + inspector.entries.length + " / " + inspector.total + "）";
  }

  $("drawer-close").addEventListener("click", closeInspector);
  $("drawer-done").addEventListener("click", closeInspector);
  $("drawer-backdrop").addEventListener("click", closeInspector);
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      if (trashState.open) closeTrashModal();
      else if (inspector.open) closeInspector();
    }
  });

  $("drawer-search").addEventListener("input", (event) => {
    clearTimeout(inspector.searchTimer);
    inspector.q = event.target.value.trim();
    inspector.searchTimer = setTimeout(() => fetchInspectorPage(false), 200);
  });

  $("drawer-sort").addEventListener("change", (event) => {
    inspector.sort = event.target.value;
    fetchInspectorPage(false);
  });

  $("drawer-risk-chips").addEventListener("click", (event) => {
    const chip = event.target.closest(".chip");
    if (!chip) return;
    inspector.risk = chip.dataset.risk || "";
    for (const c of $("drawer-risk-chips").querySelectorAll(".chip")) {
      c.classList.toggle("is-active", c === chip);
    }
    fetchInspectorPage(false);
  });

  $("drawer-select-all").addEventListener("click", () => {
    if (!inspector.card) return;
    toggleCardSelection(inspector.card, true);
    updateChrome();
    renderDrawerEntries();
  });

  $("drawer-clear-all").addEventListener("click", () => {
    if (!inspector.card) return;
    toggleCardSelection(inspector.card, false);
    updateChrome();
    renderDrawerEntries();
  });

  $("drawer-load-more").addEventListener("click", () => {
    if (!inspector.loading) fetchInspectorPage(true);
  });

  // ---------------------------------------------------------------- Trash modal & empty

  function fmtDateShort(iso) {
    if (!iso) return "";
    const ms = Date.parse(iso);
    if (!Number.isFinite(ms)) return "";
    const days = Math.max(0, Math.floor((Date.now() - ms) / 86400000));
    return fmtAge(days);
  }

  function renderTrashPill() {
    const pill = $("trash-pill");
    const label = $("trash-summary");
    const btn = $("trash-open");
    if (!pill || !label || !btn) return;

    if (trashState.denied) {
      pill.classList.remove("has-items");
      label.textContent = "废纸篓 需授权";
      btn.textContent = "查看";
      btn.disabled = busy;
      return;
    }

    if (trashState.items > 0) {
      pill.classList.add("has-items");
      label.textContent = "废纸篓 " + fmt(trashState.bytes) + " · " + fmtCount(trashState.items);
      btn.textContent = "清空废纸篓";
      btn.disabled = busy;
    } else {
      pill.classList.remove("has-items");
      label.textContent = "废纸篓 已空";
      btn.textContent = "清空废纸篓";
      btn.disabled = true;
    }
  }

  function renderTrashModal() {
    if (!trashState.open) return;

    const listEl = $("trash-list");
    const totalsEl = $("trash-modal-totals");
    const warnTextEl = $("trash-modal-warn-text");
    const confirmBtn = $("trash-confirm");

    if (trashState.denied) {
      totalsEl.textContent = "无法读取";
      warnTextEl.textContent = "Sweep Helper 尚未获得 ~/.Trash 的完全磁盘访问权限。请打开「系统设置 → 隐私与安全性 → 完全磁盘访问权限」，确认已启用 Sweep Helper.app。";
      listEl.innerHTML = '<div class="empty">无权访问废纸篓 (~/.Trash)</div>';
      confirmBtn.disabled = true;
      confirmBtn.textContent = "确认清空";
      return;
    }

    totalsEl.textContent = fmtCount(trashState.items) + " · " + fmt(trashState.bytes);
    if (agentMode === "readonly") {
      warnTextEl.textContent = "当前处于 readonly 只读模式，清空废纸篓操作已被锁定。";
    } else {
      warnTextEl.textContent = "清空后将从磁盘永久删除废纸篓中的全部内容并释放空间；此前清理进入废纸篓的文件将无法通过「撤销」找回。";
    }

    listEl.innerHTML = "";
    if (trashState.loading && !trashState.top.length) {
      listEl.innerHTML = '<div class="skeleton__card"></div>';
    } else if (!trashState.items) {
      listEl.innerHTML = '<div class="empty">废纸篓已为空</div>';
    } else {
      for (const entry of trashState.top) {
        const row = document.createElement("div");
        row.className = "trash-row";

        const left = document.createElement("div");
        left.className = "trash-row__left";

        const kind = document.createElement("span");
        kind.className = "trash-row__kind";
        kind.textContent = entry.isDirectory ? "目录" : "文件";

        const nameEl = document.createElement("span");
        nameEl.className = "trash-row__name";
        nameEl.textContent = entry.name || fileName(entry.path || "");
        nameEl.title = entry.path || "";

        left.append(kind, nameEl);

        const right = document.createElement("div");
        right.className = "trash-row__right";

        const ageText = fmtDateShort(entry.modified);
        if (ageText) {
          const dateEl = document.createElement("span");
          dateEl.className = "trash-row__date";
          dateEl.textContent = ageText;
          right.appendChild(dateEl);
        }

        const bytesEl = document.createElement("span");
        bytesEl.className = "trash-row__bytes";
        bytesEl.textContent = fmt(entry.bytes);
        right.appendChild(bytesEl);

        row.append(left, right);
        listEl.appendChild(row);
      }
      if (trashState.items > trashState.top.length) {
        const more = document.createElement("div");
        more.className = "trash-row__date";
        more.style.textAlign = "center";
        more.style.padding = "4px 0";
        more.textContent = "另含 " + (trashState.items - trashState.top.length) + " 项较小项目，也将一并清空";
        listEl.appendChild(more);
      }
    }

    const canEmpty = !busy && !trashState.loading && agentMode !== "readonly" && trashState.items > 0;
    confirmBtn.disabled = !canEmpty;
    confirmBtn.textContent = busy
      ? "清空中…"
      : (trashState.items > 0 ? "确认清空 · " + fmt(trashState.bytes) : "确认清空");
  }

  async function loadTrash() {
    trashState.loading = true;
    try {
      const res = await fetch("/api/trash", { cache: "no-store" });
      if (!res.ok) return;
      const data = await res.json();
      trashState.items = data.items || 0;
      trashState.bytes = data.bytes || 0;
      trashState.digest = data.digest || "";
      trashState.denied = Boolean(data.denied);
      trashState.top = Array.isArray(data.top) ? data.top : [];
      renderTrashPill();
      renderTrashModal();
    } catch (_) {
      // keep existing trash state on transient error
    } finally {
      trashState.loading = false;
      renderTrashModal();
    }
  }

  function openTrashModal() {
    trashState.open = true;
    $("trash-modal").hidden = false;
    renderTrashModal();
    loadTrash();
  }

  function closeTrashModal() {
    trashState.open = false;
    $("trash-modal").hidden = true;
  }

  async function confirmEmptyTrash() {
    if (busy || trashState.denied || trashState.items === 0) return;
    busy = true;
    updateChrome();
    renderTrashModal();
    try {
      const res = await fetch("/api/trash/empty", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ digest: trashState.digest }),
      });
      const result = await res.json();
      if (!res.ok) throw new Error(result.error || "清空废纸篓失败");

      lastOperation = null;
      $("undo").hidden = true;
      closeTrashModal();

      const msg = result.deletedCount > 0
        ? "已永久清空废纸篓 " + fmt(result.deletedBytes) + (result.failedCount ? " · 跳过 " + result.failedCount : "")
        : "废纸篓已为空";
      toast(msg);

      await Promise.all([loadState(), loadMetrics(), loadTrash()]);
    } catch (error) {
      toast(String(error.message || error));
      await loadTrash();
    } finally {
      busy = false;
      updateChrome();
      renderTrashModal();
    }
  }

  // ---------------------------------------------------------------- actions

  function selections() {
    const out = [];
    const bySnapshotCat = new Map();

    for (const card of cards) {
      const sel = selectionMap.get(card.key);
      if (!sel || sel.mode === "none") continue;

      if (sel.mode === "include") {
        if (!sel.included.size) continue;
        out.push({
          snapshot: card.snapshot,
          categories: [card.category],
          ids: [...sel.included.keys()],
        });
        continue;
      }

      if (card.subCategory) {
        const key = card.snapshot + "|" + card.category;
        if (!bySnapshotCat.has(key)) {
          bySnapshotCat.set(key, {
            snapshot: card.snapshot,
            categories: [card.category],
            subCategories: [],
            excludeIds: [],
          });
        }
        const entry = bySnapshotCat.get(key);
        entry.subCategories.push(card.subCategory);
        if (sel.mode === "exclude" && sel.excluded.size) {
          for (const id of sel.excluded.keys()) entry.excludeIds.push(id);
        }
        const alreadyCleaned = cleanedByCard.get(card.key);
        if (alreadyCleaned && alreadyCleaned.size) {
          for (const id of alreadyCleaned) entry.excludeIds.push(id);
        }
      } else {
        out.push({
          snapshot: card.snapshot,
          categories: [card.category],
        });
      }
    }

    for (const item of bySnapshotCat.values()) {
      if (!item.excludeIds.length) delete item.excludeIds;
      else item.excludeIds = [...new Set(item.excludeIds)];
      out.push(item);
    }
    return out;
  }

  function applyCleanDelta(result) {
    const newIds = result.cleanedIds || [];
    const subDeltas = result.subDeltas || [];
    const affectedSnapshot = [];

    for (const id of newIds) cleanedIds.add(id);

    const deltaBySub = new Map();
    for (const d of subDeltas) {
      deltaBySub.set(d.category + "|" + d.subCategory, d);
    }

    const updatedCards = [];
    for (const card of cards) {
      const sel = selectionMap.get(card.key);
      const subKey = card.category + "|" + card.subCategory;
      const d = deltaBySub.get(subKey);

      if (sel && sel.mode !== "none" && d) {
        const prevCard = { ...card };
        affectedSnapshot.push(prevCard);

        const nextItems = Math.max(0, card.items - d.items);
        const nextBytes = Math.max(0, card.bytes - d.bytes);
        const nextCleanItems = Math.max(0, card.cleanableItems - d.items);
        const nextCleanBytes = Math.max(0, card.cleanableBytes - d.bytes);

        if (!cleanedByCard.has(card.key)) cleanedByCard.set(card.key, new Set());
        const cardSet = cleanedByCard.get(card.key);
        for (const id of d.ids || newIds) cardSet.add(id);

        const prevStats = cleanedStatsByCard.get(card.key) || { bytes: 0, items: 0 };
        cleanedStatsByCard.set(card.key, {
          bytes: prevStats.bytes + d.bytes,
          items: prevStats.items + d.items,
        });

        selectionMap.delete(card.key);
        if (nextItems > 0) {
          card.items = nextItems;
          card.bytes = nextBytes;
          card.cleanableItems = nextCleanItems;
          card.cleanableBytes = nextCleanBytes;
          updatedCards.push(card);
        }
      } else {
        updatedCards.push(card);
      }
    }

    cards = updatedCards;
    return { ids: newIds, prevCards: affectedSnapshot, subDeltas };
  }

  function revertCleanDelta(delta) {
    if (!delta) return;
    for (const id of delta.ids || []) cleanedIds.delete(id);

    const deltaBySub = new Map();
    for (const d of delta.subDeltas || []) {
      deltaBySub.set(d.category + "|" + d.subCategory, d);
    }

    const byKey = new Map(cards.map((c) => [c.key, c]));
    for (const prev of delta.prevCards || []) {
      const cur = byKey.get(prev.key);
      if (cur) {
        cur.items = prev.items;
        cur.bytes = prev.bytes;
        cur.cleanableItems = prev.cleanableItems;
        cur.cleanableBytes = prev.cleanableBytes;
      } else {
        cards.push(prev);
      }
      cleanedByCard.delete(prev.key);
      const d = deltaBySub.get(prev.category + "|" + prev.subCategory);
      if (d && cleanedStatsByCard.has(prev.key)) {
        const curStats = cleanedStatsByCard.get(prev.key);
        const remBytes = Math.max(0, curStats.bytes - d.bytes);
        const remItems = Math.max(0, curStats.items - d.items);
        if (remItems === 0) cleanedStatsByCard.delete(prev.key);
        else cleanedStatsByCard.set(prev.key, { bytes: remBytes, items: remItems });
      } else {
        cleanedStatsByCard.delete(prev.key);
      }
    }
    cards.sort((a, b) => b.bytes - a.bytes);
  }

  async function clean() {
    if (busy) return;
    busy = true;
    updateChrome();
    try {
      const planRes = await fetch("/api/plan", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ selections: selections(), minBytes: MIN_BYTES }),
      });
      const plan = await planRes.json();
      if (!planRes.ok) throw new Error(plan.error || "计划失败");

      const applyRes = await fetch("/api/apply", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ planId: plan.planId, digest: plan.digest }),
      });
      const result = await applyRes.json();
      if (!applyRes.ok) throw new Error(result.error || "清理失败");

      const delta = applyCleanDelta(result);
      lastOperation = { id: result.operationId, bytes: result.bytes, delta };
      $("undo").hidden = false;
      toast("已清理 " + fmt(result.bytes) + (result.failedCount ? " · 跳过 " + result.failedCount : ""));

      if (inspector.open) closeInspector();
      await Promise.all([loadState(), loadMetrics(), loadTrash()]);
      mountedKeys.clear();
      updateChrome();
      renderRail();
      renderGrid(true);
    } catch (error) {
      toast(String(error.message || error));
    } finally {
      busy = false;
      updateChrome();
    }
  }

  async function undo() {
    if (!lastOperation || busy) return;
    busy = true;
    updateChrome();
    try {
      const res = await fetch("/api/restore", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ operationId: lastOperation.id }),
      });
      const result = await res.json();
      if (!res.ok) throw new Error(result.error || "撤销失败");
      toast("已还原 " + result.restored + " 项");

      const delta = lastOperation.delta;
      lastOperation = null;
      $("undo").hidden = true;
      if (inspector.open) closeInspector();

      if (delta) {
        revertCleanDelta(delta);
        await Promise.all([loadState(), loadMetrics(), loadTrash()]);
        mountedKeys.clear();
        updateChrome();
        renderRail();
        renderGrid(true);
      } else {
        await Promise.all([loadState(), loadMetrics(), loadTrash()]);
      }
    } catch (error) {
      toast(String(error.message || error));
    } finally {
      busy = false;
      updateChrome();
    }
  }

  $("board-search").addEventListener("input", (event) => {
    boardQuery = event.target.value.trim();
    mountedKeys.clear();
    renderGrid(true);
  });

  $("board-sort").addEventListener("click", (event) => {
    const chip = event.target.closest(".chip");
    if (!chip) return;
    boardSort = chip.dataset.sort || "bytes";
    for (const c of $("board-sort").querySelectorAll(".chip")) {
      c.classList.toggle("is-active", c === chip);
    }
    mountedKeys.clear();
    renderGrid(true);
  });

  $("select-all").addEventListener("click", toggleSelectAll);
  $("clean").addEventListener("click", clean);
  $("undo").addEventListener("click", undo);
  $("rescan").addEventListener("click", startScan);
  $("trash-open").addEventListener("click", openTrashModal);
  $("trash-close").addEventListener("click", closeTrashModal);
  $("trash-cancel").addEventListener("click", closeTrashModal);
  $("trash-backdrop").addEventListener("click", closeTrashModal);
  $("trash-confirm").addEventListener("click", confirmEmptyTrash);

  Promise.all([loadState(), loadMetrics(), loadTrash()]).then(() => {
    startScan();
    clearInterval(metricsTimer);
    metricsTimer = setInterval(loadMetrics, 2500);
  });
})();
