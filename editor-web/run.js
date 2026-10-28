// A test-run recording, read-only (DemoVideoStudio-Editor §5.6): the steps
// with their results, the failing step selected, its stills and the observed
// state the run recorded.

"use strict";

const $ = (id) => document.getElementById(id);
let run = null;

async function select(path) {
  const s = run.steps.find((x) => x.path === path);
  if (!s) return;
  for (const li of document.querySelectorAll("#steps li")) {
    li.classList.toggle("selected", li.dataset.path === path);
  }
  $("sel-path").textContent = `${s.path} ${s.kind}`;
  $("sel-status").textContent = s.status;
  $("sel-message").textContent = s.message;
  const stills = $("stills");
  stills.innerHTML = "";
  for (const url of s.stills) {
    if (url.endsWith(".txt")) {
      const pre = document.createElement("pre");
      pre.className = "still";
      pre.textContent = await (await fetch(url)).text();
      stills.appendChild(pre);
    } else {
      const img = document.createElement("img");
      img.className = "still";
      img.alt = `step ${s.path} still`;
      img.src = url;
      stills.appendChild(img);
    }
  }
  $("state").textContent = s.state
    ? JSON.stringify(await (await fetch(s.state)).json(), null, 2)
    : "(none recorded)";
  document.body.dataset.selected = path;
}

async function load() {
  run = await (await fetch("/api/run")).json();
  $("title").textContent = run.scenario;
  $("flavour").textContent = `on ${run.backend}`;
  $("outcome").textContent =
    run.outcome + (run.message ? `: ${run.message}` : "");
  const ol = $("steps");
  for (const s of run.steps) {
    const li = document.createElement("li");
    li.className = s.status;
    li.dataset.path = s.path;
    li.textContent = `${s.path} ${s.kind} — ${s.status}`;
    li.addEventListener("click", () => select(s.path));
    ol.appendChild(li);
  }
  for (const f of run.failure) {
    const li = document.createElement("li");
    const a = document.createElement("a");
    a.href = f;
    a.textContent = f.replace("/files/", "");
    li.appendChild(a);
    $("failure").appendChild(li);
  }
  await select(run.failing || run.steps[0].path);
}

load();
