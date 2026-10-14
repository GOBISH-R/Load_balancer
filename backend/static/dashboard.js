// Live load-balancer dashboard. Every request goes to /api through Nginx; the
// response body says which backend answered, and Nginx's X-Upstream-Addr header
// shows every backend it tried (two addresses = the request was retried).
(function () {
  "use strict";

  const STALE_MS = 4000;       // a backend silent this long while others answer is "not responding"
  const TIMELINE_SIZE = 60;
  const LOG_SIZE = 50;
  const REQUEST_TIMEOUT_MS = 15000;

  const state = {
    total: 0,
    failed: 0,
    retried: 0,
    latencySum: 0,
    backends: {},             // name -> { count, info, lastSeen, color }
    recent: [],               // newest first
    lastOkAt: 0,
    running: false,
  };

  const $ = (id) => document.getElementById(id);

  function el(tag, props, children) {
    const node = document.createElement(tag);
    if (props) {
      for (const [k, v] of Object.entries(props)) {
        if (k === "text") node.textContent = v;
        else if (k === "style") node.setAttribute("style", v);
        else if (k === "className") node.className = v;
        else node.setAttribute(k, v);
      }
    }
    for (const child of children || []) node.appendChild(child);
    return node;
  }

  function fmtDuration(totalSeconds) {
    const s = Math.max(0, Math.floor(totalSeconds));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    if (h) return `${h}h ${m}m`;
    if (m) return `${m}m ${s % 60}s`;
    return `${s}s`;
  }

  function fmtAgo(ms) {
    return ms < 1500 ? "just now" : `${fmtDuration(ms / 1000)} ago`;
  }

  function fmtTime(d) {
    return d.toLocaleTimeString([], { hour12: false });
  }

  function colorOf(name) {
    const b = state.backends[name];
    return (b && b.color) || "var(--idle)";
  }

  async function fetchWithTimeout(url) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), REQUEST_TIMEOUT_MS);
    try {
      return await fetch(url, { cache: "no-store", signal: ctrl.signal });
    } finally {
      clearTimeout(timer);
    }
  }

  // ------------------------------------------------------------------ traffic

  // Simulated processing time for the next request, from the load-test "work" setting.
  function nextWork() {
    const v = $("lt-work").value;
    if (v.startsWith("r")) return Math.floor(Math.random() * Number(v.slice(1)));
    return Number(v);
  }

  async function sendOne(work) {
    if (work === undefined) work = nextWork();
    const started = performance.now();
    const entry = { time: new Date(), status: 0, backend: null, upstream: "-", ms: 0, retried: false };
    try {
      const res = await fetchWithTimeout(work ? `/api?work=${work}` : "/api");
      entry.status = res.status;
      entry.upstream = res.headers.get("X-Upstream-Addr") || "direct (no proxy)";
      entry.backend = res.headers.get("X-Backend-Server");
      const algo = res.headers.get("X-LB-Algorithm");
      if (algo) $("h-algo").textContent = algo;
      if (res.ok) {
        const info = await res.json();
        entry.backend = info.server;
        const b = state.backends[info.server] || (state.backends[info.server] = { count: 0 });
        b.count += 1;
        b.info = info;
        b.color = info.color;
        b.lastSeen = Date.now();
        state.lastOkAt = b.lastSeen;
      }
    } catch (err) {
      entry.status = 0; // network error or timeout
    }
    entry.ms = Math.round(performance.now() - started);
    entry.retried = entry.upstream.includes(",");

    state.total += 1;
    if (entry.status !== 200) state.failed += 1;
    if (entry.retried) state.retried += 1;
    state.latencySum += entry.ms;
    state.recent.unshift(entry);
    if (state.recent.length > Math.max(TIMELINE_SIZE, LOG_SIZE)) state.recent.pop();
    scheduleRender();
    return entry;
  }

  async function sendBurst(n) {
    for (let i = 0; i < n; i++) await sendOne();
  }

  async function autoLoop() {
    while (state.running) {
      await sendOne();
      await new Promise((r) => setTimeout(r, Number($("rate").value)));
    }
  }

  function toggleAuto() {
    state.running = !state.running;
    const btn = $("btn-auto");
    btn.textContent = state.running ? "Stop auto traffic" : "Start auto traffic";
    btn.classList.toggle("running", state.running);
    if (state.running) autoLoop();
  }

  function reset() {
    Object.assign(state, { total: 0, failed: 0, retried: 0, latencySum: 0, recent: [], lastOkAt: 0 });
    for (const b of Object.values(state.backends)) b.count = 0;
    render();
  }

  // ------------------------------------------------------------------ load test

  let loadTestRunning = false;

  function percentile(sorted, p) {
    if (!sorted.length) return 0;
    return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
  }

  function fmtMs(ms) {
    return ms >= 1000 ? `${(ms / 1000).toFixed(2)} s` : `${Math.round(ms)} ms`;
  }

  async function runLoadTest() {
    const btn = $("lt-start");
    if (loadTestRunning) {
      loadTestRunning = false; // workers stop after their current request
      btn.disabled = true;     // re-enabled once the in-flight requests finish
      btn.textContent = "Stopping…";
      return;
    }
    const total = Number($("lt-total").value);
    const concurrency = Math.min(Number($("lt-concurrency").value), total);
    const fill = $("lt-progress");
    const status = $("lt-status");

    loadTestRunning = true;
    btn.textContent = "Stop load test";
    fill.classList.remove("done");
    $("lt-results").hidden = true;

    const results = [];
    let issued = 0;
    const started = performance.now();

    const tick = setInterval(() => {
      fill.style.width = `${(results.length / total) * 100}%`;
      status.textContent = `Running: ${results.length} / ${total} done, ${concurrency} at a time…`;
    }, 100);

    // N workers pull from a shared counter until all requests are issued.
    async function worker() {
      while (loadTestRunning && issued < total) {
        issued += 1;
        results.push(await sendOne());
      }
    }
    await Promise.all(Array.from({ length: concurrency }, worker));

    clearInterval(tick);
    const elapsed = performance.now() - started;
    const stopped = loadTestRunning === false && results.length < total;
    loadTestRunning = false;
    btn.disabled = false;
    btn.textContent = "Run load test";
    fill.style.width = `${(results.length / total) * 100}%`;
    fill.classList.add("done");

    const ok = results.filter((r) => r.status === 200);
    const failed = results.length - ok.length;
    const retried = results.filter((r) => r.retried).length;
    const lat = results.map((r) => r.ms).sort((a, b) => a - b);
    const split = {};
    for (const r of ok) split[r.backend] = (split[r.backend] || 0) + 1;

    $("lt-duration").textContent = fmtMs(elapsed);
    $("lt-rps").textContent = (results.length / (elapsed / 1000)).toFixed(1);
    $("lt-okfail").textContent = `${ok.length} / ${failed}`;
    $("lt-okfail").classList.toggle("bad", failed > 0);
    $("lt-split").textContent = Object.keys(split).sort()
      .map((n) => `${n}: ${split[n]} (${Math.round((split[n] / (ok.length || 1)) * 100)}%)`)
      .join("  ·  ") || "–";
    $("lt-pct").textContent = `${fmtMs(percentile(lat, 50))} / ${fmtMs(percentile(lat, 95))} / ${fmtMs(percentile(lat, 99))}`;
    $("lt-max").textContent = fmtMs(lat[lat.length - 1] || 0);
    $("lt-results").hidden = false;
    status.textContent = `${stopped ? "Stopped early" : "Finished"}: ${results.length} requests in ${fmtMs(elapsed)}` +
      (retried ? `, ${retried} retried by Nginx on the other backend` : "") + ".";
  }

  // ------------------------------------------------------------------ status

  function backendStatus(b) {
    const age = Date.now() - (b.lastSeen || 0);
    if (age < STALE_MS) return { cls: "up", label: "Serving" };
    if (state.lastOkAt - b.lastSeen > STALE_MS) return { cls: "down", label: "Not responding" };
    return { cls: "idle", label: "Idle" };
  }

  // ------------------------------------------------------------------ render

  function renderStats() {
    $("s-total").textContent = state.total;
    $("s-failed").textContent = state.failed;
    $("s-failed").classList.toggle("bad", state.failed > 0);
    $("s-retried").textContent = state.retried;
    $("s-avg").textContent = state.total ? `${Math.round(state.latencySum / state.total)} ms` : "–";
  }

  function renderDistribution() {
    const names = Object.keys(state.backends).sort();
    const ok = names.reduce((sum, n) => sum + state.backends[n].count, 0);
    const bar = $("dist-bar");
    const legend = $("dist-legend");
    bar.replaceChildren();
    legend.replaceChildren();
    if (!ok && !state.failed) {
      bar.appendChild(el("div", { className: "empty", text: "No requests yet" }));
      return;
    }
    const all = ok + state.failed;
    for (const n of names) {
      const c = state.backends[n].count;
      if (!c) continue;
      const pct = (c / all) * 100;
      bar.appendChild(el("div", {
        className: "seg",
        style: `width:${pct}%;background:${colorOf(n)}`,
        text: pct >= 12 ? `${n} ${Math.round(pct)}%` : "",
        title: `${n}: ${c}`,
      }));
    }
    if (state.failed) {
      bar.appendChild(el("div", {
        className: "seg",
        style: `width:${(state.failed / all) * 100}%;background:var(--bad)`,
        title: `failed: ${state.failed}`,
      }));
    }
    for (const n of names) {
      legend.appendChild(el("span", {}, [
        el("span", { className: "swatch", style: `--c:${colorOf(n)}` }),
        document.createTextNode(`${n}: ${state.backends[n].count}`),
      ]));
    }
    legend.appendChild(el("span", {}, [
      el("span", { className: "swatch", style: "--c:var(--bad)" }),
      document.createTextNode(`failed: ${state.failed}`),
    ]));
  }

  function renderBackendStatus() {
    const box = $("backend-status");
    const names = Object.keys(state.backends).sort();
    if (!names.length) return;
    box.replaceChildren();
    for (const n of names) {
      const b = state.backends[n];
      const st = backendStatus(b);
      box.appendChild(el("div", { className: `bcard ${st.cls === "down" ? "down" : ""}`, style: `--c:${b.color}` }, [
        el("div", { className: "head" }, [
          el("span", { className: "name", text: n }),
          el("span", { className: `badge ${st.cls}`, text: st.label }),
        ]),
        el("div", { className: "count", text: String(b.count) }),
        el("dl", {}, [
          el("dt", { text: "Private IP" }), el("dd", { className: "mono", text: b.info.private_ip }),
          el("dt", { text: "Last answer" }), el("dd", { text: fmtAgo(Date.now() - b.lastSeen) }),
        ]),
      ]));
    }
  }

  function renderServerDetails() {
    const box = $("server-details");
    const names = Object.keys(state.backends).sort();
    if (!names.length) return;
    box.replaceChildren();
    for (const n of names) {
      const b = state.backends[n];
      const i = b.info;
      const st = backendStatus(b);
      const uptime = i.uptime_seconds + (Date.now() - b.lastSeen) / 1000;
      const rows = [
        ["Hostname", i.hostname],
        ["Private IP", i.private_ip],
        ["Instance ID", i.instance_id],
        ["Availability zone", i.availability_zone],
        ["Container started", i.started_at],
        ["Uptime", st.cls === "down" ? "unknown (not responding)" : fmtDuration(uptime)],
        ["Requests handled (server)", String(i.request_count)],
        ["Answered this dashboard", String(b.count)],
        ["Last answer", fmtAgo(Date.now() - b.lastSeen)],
      ];
      const dl = el("dl");
      for (const [k, v] of rows) {
        dl.appendChild(el("dt", { text: k }));
        dl.appendChild(el("dd", { className: "mono", text: v }));
      }
      box.appendChild(el("div", { className: `bcard ${st.cls === "down" ? "down" : ""}`, style: `--c:${b.color}` }, [
        el("div", { className: "head" }, [
          el("span", { className: "name", text: n }),
          el("span", { className: `badge ${st.cls}`, text: st.label }),
        ]),
        dl,
      ]));
    }
  }

  function renderTimeline() {
    const box = $("timeline");
    box.replaceChildren();
    const items = state.recent.slice(0, TIMELINE_SIZE).reverse();
    for (let i = 0; i < TIMELINE_SIZE; i++) {
      const e = items[i];
      if (!e) {
        box.appendChild(el("div", { className: "sq blank" }));
        continue;
      }
      const cls = ["sq"];
      if (e.status !== 200) cls.push("failed");
      if (e.retried) cls.push("retried");
      box.appendChild(el("div", {
        className: cls.join(" "),
        style: `--c:${colorOf(e.backend)}`,
        title: `${fmtTime(e.time)}  ${e.status || "ERR"}  ${e.backend || "-"}  ${e.ms} ms`,
      }));
    }
  }

  function renderLog() {
    const body = $("log");
    body.replaceChildren();
    for (const e of state.recent.slice(0, LOG_SIZE)) {
      const cls = [];
      if (e.status !== 200) cls.push("failed");
      if (e.retried) cls.push("retried");
      body.appendChild(el("tr", { className: cls.join(" ") }, [
        el("td", { className: "mono", text: fmtTime(e.time) }),
        el("td", { text: e.status ? String(e.status) : "ERR" }),
        el("td", {}, [el("span", { className: "who" }, [
          el("span", { className: "swatch", style: `--c:${e.status === 200 ? colorOf(e.backend) : "var(--bad)"}` }),
          document.createTextNode(e.backend || "-"),
        ])]),
        el("td", { className: "mono", text: e.retried ? `${e.upstream}  (retried)` : e.upstream }),
        el("td", { className: "num", text: `${e.ms} ms` }),
      ]));
    }
  }

  function render() {
    renderStats();
    renderDistribution();
    renderBackendStatus();
    renderServerDetails();
    renderTimeline();
    renderLog();
  }

  // Coalesce many responses into one repaint per animation frame (load tests).
  let renderPending = false;
  function scheduleRender() {
    if (renderPending) return;
    renderPending = true;
    requestAnimationFrame(() => {
      renderPending = false;
      render();
    });
  }

  // ------------------------------------------------------------------ health

  async function checkHealth(url, textId, dotId, describe) {
    let ok = false;
    let text;
    try {
      const res = await fetchWithTimeout(url);
      ok = res.ok;
      text = ok ? await describe(res) : `HTTP ${res.status}`;
    } catch (err) {
      text = "No response";
    }
    $(textId).textContent = `${ok ? "Healthy" : "Unhealthy"}: ${text} (checked ${fmtTime(new Date())})`;
    $(dotId).className = `dot ${ok ? "up" : "down"}`;
  }

  function runHealthChecks() {
    checkHealth("/nginx-health", "h-proxy", "h-proxy-dot", async (res) => (await res.text()).trim());
    checkHealth("/health", "h-backend", "h-backend-dot", async (res) => {
      const body = await res.json();
      return `status ${body.status}, answered by ${body.server}`;
    });
  }

  // ------------------------------------------------------------------ tabs

  let healthTimer = null;

  function showTab(name) {
    document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("active", t.dataset.tab === name));
    document.querySelectorAll(".panel").forEach((p) => p.classList.toggle("active", p.id === `tab-${name}`));
    clearInterval(healthTimer);
    if (name === "health") {
      runHealthChecks();
      healthTimer = setInterval(runHealthChecks, 3000);
    }
  }

  // ------------------------------------------------------------------ wiring

  document.querySelectorAll(".tab").forEach((t) => t.addEventListener("click", () => showTab(t.dataset.tab)));
  $("btn-one").addEventListener("click", () => sendOne());
  $("btn-ten").addEventListener("click", () => sendBurst(10));
  $("btn-auto").addEventListener("click", toggleAuto);
  $("btn-reset").addEventListener("click", reset);
  $("btn-discover").addEventListener("click", () => sendBurst(4));
  $("lt-start").addEventListener("click", runLoadTest);

  // Keep "last answer" ages and up/down badges current between requests.
  setInterval(() => {
    renderBackendStatus();
    renderServerDetails();
  }, 1000);

  sendBurst(4); // discover both backends on load
})();
