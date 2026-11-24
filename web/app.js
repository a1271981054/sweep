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

  const MIN_BYTES = 1024 * 1024;

  let groups = [];
  let selected = new Set();
  let lastOperation = null;
  let busy = false;

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

  const shortPath = (path) => {
    const home = "/Users/";
    if (path.startsWith(home)) {
      const parts = path.split("/");
      parts.splice(0, 3, "~");
      return parts.join("/");
    }
    return path;
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

  // ---------------------------------------------------------------- state

  async function loadState() {
    try {
      const res = await fetch("/api/state", { cache: "no-store" });
      const state = await res.json();
      const { disk, operations } = state;

      $("disk-free").textContent = fmt(disk.availableBytes);
      $("disk-used").textContent = Math.round((disk.usedBytes / disk.totalBytes) * 100) + "% 已用";
      $("disk-bar").style.width = Math.min(100, (disk.usedBytes / disk.totalBytes) * 100) + "%";

      if (operations && operations.length) {
        lastOperation = operations[0];
        $("undo").hidden = !lastOperation;
      }
    } catch (error) {
      toast("无法连接 sweep helper");
    }
  }

  // ---------------------------------------------------------------- scan

  async function startScan() {
    try {
      const res = await fetch("/api/scan", { method: "POST" });
      const { id } = await res.json();
      poll(id);
    } catch (error) {
      render([]);
      toast("扫描启动失败");
    }
  }

  async function poll(id) {
    try {
      const res = await fetch("/api/job?id=" + encodeURIComponent(id), { cache: "no-store" });
      const job = await res.json();
      if (job.state === "running") {
        $("sum-count").textContent = "扫描 " + Math.min(job.index + 1, job.total) + "/" + job.total;
        setTimeout(() => poll(id), 900);
        return;
      }
      groups = (job.groups || []).filter((group) => group.items > 0);
      render(groups);
    } catch (error) {
      render([]);
      toast("扫描中断");
    }
  }

  // ---------------------------------------------------------------- render

  function render(list) {
    const panel = $("panel");
    panel.innerHTML = "";

    if (!list.length) {
      const empty = document.createElement("div");
      empty.className = "empty";
      empty.textContent = "没有可清理的项目";
      panel.appendChild(empty);
      updateSum();
      return;
    }

    for (const group of list) {
      const key = group.snapshot + "|" + group.category;
      const card = document.createElement("section");
      card.className = "group";
      if (AUTO_SELECT.has(group.category)) {
        selected.add(key);
      }

      const head = document.createElement("label");
      head.className = "group__head";

      const check = document.createElement("input");
      check.type = "checkbox";
      check.className = "group__check";
      check.checked = selected.has(key);
      check.addEventListener("change", () => {
        if (check.checked) selected.add(key);
        else selected.delete(key);
        updateSum();
      });
      check.addEventListener("click", (event) => event.stopPropagation());

      const label = document.createElement("span");
      label.className = "group__label";
      label.textContent = group.label;

      const bytes = document.createElement("span");
      bytes.className = "group__bytes";
      bytes.textContent = fmt(group.bytes);

      const count = document.createElement("span");
      count.className = "group__count";
      count.textContent = group.items + " 项";

      head.append(check, label, bytes, count);
      head.addEventListener("click", (event) => {
        if (event.target === check) return;
        card.classList.toggle("is-open");
      });

      const items = document.createElement("div");
      items.className = "group__items";
      for (const item of group.top || []) {
        const row = document.createElement("div");
        row.className = "item";
        const path = document.createElement("span");
        path.className = "item__path";
        path.textContent = shortPath(item.path);
        path.title = item.path;
        const size = document.createElement("span");
        size.className = "item__bytes";
        size.textContent = fmt(item.bytes);
        row.append(path, size);
        items.append(row);
      }

      card.append(head, items);
      panel.appendChild(card);
    }

    updateSum();
  }

  function updateSum() {
    let bytes = 0;
    let count = 0;
    for (const group of groups) {
      const key = group.snapshot + "|" + group.category;
      if (!selected.has(key)) continue;
      bytes += group.bytes;
      count += group.items;
    }
    $("sum-bytes").textContent = fmt(bytes);
    $("sum-count").textContent = count ? count + " 项已选" : "未选择";
    $("clean").disabled = count === 0 || busy;
    $("clean").textContent = busy ? "清理中" : "清理";
  }

  // ---------------------------------------------------------------- actions

  function selections() {
    const bySnapshot = new Map();
    for (const group of groups) {
      const key = group.snapshot + "|" + group.category;
      if (!selected.has(key)) continue;
      if (!bySnapshot.has(group.snapshot)) bySnapshot.set(group.snapshot, []);
      bySnapshot.get(group.snapshot).push(group.category);
    }
    return [...bySnapshot.entries()].map(([snapshot, categories]) => ({ snapshot, categories }));
  }

  async function clean() {
    if (busy) return;
    busy = true;
    updateSum();
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

      lastOperation = { id: result.operationId, bytes: result.bytes };
      $("undo").hidden = false;
      toast("已清理 " + fmt(result.bytes) + (result.failedCount ? " · " + result.failedCount + " 项跳过" : ""));

      selected.clear();
      await loadState();
      await startScan();
    } catch (error) {
      toast(String(error.message || error));
    } finally {
      busy = false;
      updateSum();
    }
  }

  async function undo() {
    if (!lastOperation) return;
    try {
      const res = await fetch("/api/restore", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ operationId: lastOperation.id }),
      });
      const result = await res.json();
      if (!res.ok) throw new Error(result.error || "撤销失败");
      toast("已还原 " + result.restored + " 项");
      lastOperation = null;
      $("undo").hidden = true;
      await loadState();
      await startScan();
    } catch (error) {
      toast(String(error.message || error));
    }
  }

  $("clean").addEventListener("click", clean);
  $("undo").addEventListener("click", undo);

  loadState().then(startScan);
})();
