"use strict";

const $ = (id) => document.getElementById(id);

async function api(path, options) {
  const res = await fetch(path, Object.assign({ headers: { "Content-Type": "application/json" } }, options));
  if (!res.ok) {
    let detail = res.statusText;
    try { detail = (await res.json()).detail || detail; } catch (_) { /* not json */ }
    throw new Error(res.status + ": " + detail);
  }
  return res.status === 204 ? null : res.json();
}

function showError(msg) {
  const el = $("error");
  el.hidden = !msg;
  el.textContent = msg || "";
}

async function loadInfo() {
  const badge = $("site");
  try {
    const i = await api("/api/info");
    const site = (i.site || "unknown").toLowerCase();
    const region = i.region || "unknown";
    badge.textContent = "Served from " + site.toUpperCase() + " (" + region + ")";
    badge.className = "badge " + (site === "primary" || site === "dr" ? site : "unknown");
    $("i-site").textContent = site.toUpperCase();
    $("i-region").textContent = region;
    $("i-zone").textContent = i.zone;
    $("i-node").textContent = i.node;
    $("i-db").textContent = i.db_ok ? i.db_host + (i.db_standby ? " (standby!)" : " (primary)") : "unreachable";
    $("i-gen").textContent = "node " + i.local_generation + " / db " + (i.db_generation ?? "?");
    $("i-writes").textContent = i.writes_allowed ? "allowed" : "refused";
    $("i-writes").className = i.writes_allowed ? "ok" : "bad";
  } catch (e) {
    badge.textContent = "unreachable";
    badge.className = "badge down";
  }
}

async function loadItems() {
  try {
    const items = await api("/api/items");
    const ul = $("list");
    ul.replaceChildren();
    for (const it of items) {
      const li = document.createElement("li");
      if (it.done) li.className = "done";
      const t = document.createElement("span");
      t.className = "t";
      t.textContent = it.title; // textContent: no HTML injection
      const toggle = document.createElement("button");
      toggle.textContent = it.done ? "undo" : "done";
      toggle.onclick = () => mutate(() => api("/api/items/" + it.id, { method: "PATCH", body: JSON.stringify({ done: !it.done }) }));
      const del = document.createElement("button");
      del.textContent = "delete";
      del.onclick = () => mutate(() => api("/api/items/" + it.id, { method: "DELETE" }));
      li.append(t, toggle, del);
      ul.append(li);
    }
    showError("");
  } catch (e) {
    showError(e.message);
  }
}

async function mutate(fn) {
  try { await fn(); showError(""); } catch (e) { showError(e.message); }
  loadItems();
}

$("form").addEventListener("submit", (ev) => {
  ev.preventDefault();
  const title = $("title").value.trim();
  if (!title) return;
  $("title").value = "";
  mutate(() => api("/api/items", { method: "POST", body: JSON.stringify({ title }) }));
});

function refresh() { loadInfo(); loadItems(); }
refresh();
setInterval(refresh, 5000);
