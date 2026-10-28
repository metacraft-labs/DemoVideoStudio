// The scenario editor's page (DemoVideoStudio-Editor §3).
//
// The timeline shows the scenario's steps on the selected flavour's measured
// times. Nothing here keeps a time: a drag is sent to the server as a point
// or a distance on that timeline, and the server writes it back to the file
// as the format's own values (an anchor, a `dwell`, a `lead-in`).

"use strict";

const PX_PER_MS = 0.2;
let view = null;
let selected = null;

const $ = (id) => document.getElementById(id);

async function api(path, body) {
  const init =
    body === undefined
      ? {}
      : {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        };
  const r = await fetch(path, init);
  const j = await r.json();
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}

function status(text, isError) {
  const s = $("status");
  s.textContent = text;
  s.style.color = isError ? "var(--error)" : "";
}

function stepByName(name) {
  return view.steps.find(
    (s) => s.id === name || (s.kind === "beat" && s.name === name),
  );
}

function spanExtent(step, span) {
  const from = span.from ? stepByName(span.from) : step;
  const to = span.to ? stepByName(span.to) : step;
  if (!from || !to || from.startMs === undefined || to.endMs === undefined)
    return null;
  return [from.startMs, to.endMs];
}

function place(el, startMs, endMs) {
  el.style.left = `${startMs * PX_PER_MS}px`;
  if (endMs !== undefined)
    el.style.width = `${Math.max(2, (endMs - startMs) * PX_PER_MS)}px`;
}

function dragX(el, onDrop) {
  el.addEventListener("mousedown", (down) => {
    down.preventDefault();
    const x0 = down.clientX;
    const left0 = parseFloat(el.style.left);
    const move = (e) => {
      el.style.left = `${left0 + e.clientX - x0}px`;
    };
    const up = (e) => {
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
      onDrop(e.clientX - x0, left0 + e.clientX - x0);
    };
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
  });
}

async function edit(body) {
  try {
    const r = await api("/api/edit", body);
    status(
      `${body.op}: ${r.class} edit; stale: ${r.invalidated.join(", ") || "nothing"}`,
    );
  } catch (e) {
    status(e.message, true);
  }
  await load();
}

function renderTimeline() {
  const width =
    Math.max(...view.steps.map((s) => s.endMs || 0)) * PX_PER_MS + 80;
  for (const id of ["ruler", "actions", "narration", "captions"]) {
    $(id).innerHTML = "";
    $(id).style.width = `${width}px`;
  }
  for (let ms = 0; ms * PX_PER_MS < width; ms += 1000) {
    const t = document.createElement("span");
    t.style.left = `${ms * PX_PER_MS}px`;
    t.textContent = `${ms / 1000}s`;
    $("ruler").appendChild(t);
  }
  const leaves = view.steps.filter(
    (s) => s.kind !== "beat" && s.startMs !== undefined,
  );
  for (const s of leaves) {
    const el = document.createElement("div");
    el.className =
      "step" +
      (s.input ? " input" : "") +
      (selected === s.path ? " selected" : "");
    el.dataset.path = s.path;
    el.title = `${s.path} ${s.kind}`;
    el.textContent = `${s.path} ${s.kind}`;
    place(el, s.startMs, s.endMs);
    el.addEventListener("click", () => select(s.path));
    $("actions").appendChild(el);
  }
  // the gap before each step: dragging it moves the step, as the previous
  // step's dwell
  for (let k = 1; k < leaves.length; k++) {
    const h = document.createElement("div");
    h.className = "gap-handle";
    h.dataset.after = leaves[k - 1].path;
    place(h, leaves[k].startMs);
    dragX(h, (dx) =>
      edit({
        op: "gap",
        after: h.dataset.after,
        deltaMs: Math.round(dx / PX_PER_MS),
      }),
    );
    $("actions").appendChild(h);
  }
  for (const [track, key] of [
    ["narration", "narration"],
    ["captions", "caption"],
  ]) {
    for (const s of view.steps) {
      const span = s[key];
      if (!span) continue;
      const ext = spanExtent(s, span);
      if (!ext) continue;
      const el = document.createElement("div");
      el.className = "span";
      el.dataset.step = s.path;
      el.textContent = span.text;
      place(el, ext[0], ext[1]);
      $(track).appendChild(el);
      for (const [edge, at] of [
        ["from", ext[0]],
        ["to", ext[1]],
      ]) {
        const h = document.createElement("div");
        h.className = "span-edge";
        h.dataset.step = s.path;
        h.dataset.span = key;
        h.dataset.edge = edge;
        place(h, at);
        dragX(h, (_dx, left) =>
          edit({
            op: "anchor",
            span: key,
            step: s.path,
            edge,
            atMs: left / PX_PER_MS,
          }),
        );
        $(track).appendChild(h);
      }
    }
  }
}

async function select(path) {
  selected = path;
  const s = view.steps.find((x) => x.path === path);
  $("sel-path").textContent = path;
  const dl = $("sel-props");
  dl.innerHTML = "";
  for (const [k, v] of Object.entries({
    kind: s.kind,
    id: s.id,
    payload: JSON.stringify(s.payload),
    "lead-in": s.leadInMs,
    dwell: s.dwellMs,
  })) {
    if (v === undefined || v === "" || v === -1) continue;
    const dt = document.createElement("dt");
    dt.textContent = k;
    const dd = document.createElement("dd");
    dd.textContent = v;
    dl.append(dt, dd);
  }
  for (const el of document.querySelectorAll(".step")) {
    el.classList.toggle("selected", el.dataset.path === path);
  }
  try {
    const still = await api(`/api/still?step=${encodeURIComponent(path)}`);
    $("preview").textContent = still.text;
    $("preview").dataset.units = still.units;
    $("preview").dataset.step = path;
  } catch (e) {
    $("preview").textContent = "";
    status(e.message, true);
  }
}

function cellSize() {
  const probe = document.createElement("span");
  probe.textContent = "M".repeat(100);
  probe.style.font = getComputedStyle($("preview")).font;
  probe.style.visibility = "hidden";
  probe.style.position = "absolute";
  document.body.appendChild(probe);
  const w = probe.getBoundingClientRect().width / 100;
  const h = probe.getBoundingClientRect().height;
  probe.remove();
  return [w, parseFloat(getComputedStyle($("preview")).lineHeight) || h];
}

$("preview").addEventListener("click", async (e) => {
  if (!selected) return;
  const r = $("preview").getBoundingClientRect();
  let x = e.clientX - r.left;
  let y = e.clientY - r.top;
  if ($("preview").dataset.units === "cell") {
    const [cw, ch] = cellSize();
    x = Math.floor(x / cw) + 0.5;
    y = Math.floor(y / ch) + 0.5;
  }
  try {
    const j = await api("/api/pick", { step: selected, x, y });
    status(`picked ${j.locator}; stale: ${j.invalidated.join(", ")}`);
  } catch (err) {
    status(err.message, true);
  }
  const keep = selected;
  await load();
  await select(keep);
});

async function load() {
  view = await api("/api/scenario");
  $("title").textContent = view.name;
  $("flavour").textContent = view.flavour ? `on ${view.flavour}` : "";
  renderTimeline();
  const ul = $("diagnostics");
  ul.innerHTML = "";
  for (const d of view.diagnostics) {
    const li = document.createElement("li");
    li.textContent = d;
    ul.appendChild(li);
  }
  document.body.dataset.loaded = String(Date.now());
}

load();
