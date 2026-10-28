// Drives the scenario editor's page in a real Chromium (playwright-core from
// DVS_PLAYWRIGHT_CORE): drags a narration edge onto a step, drags a gap, and
// picks a target in the preview. Run by tests/tscenario_ui.nim, which checks
// what the edits wrote to the scenario file.
//
//   node scenario_ui.mjs <editor base URL>

const { chromium } = await import(
  `${process.env.DVS_PLAYWRIGHT_CORE}/index.mjs`
);
const base = process.argv[2];

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1600, height: 900 } });
const fail = (msg) => {
  console.error(msg);
  process.exitCode = 1;
};

async function reloaded(action) {
  const before = await page.evaluate(() => document.body.dataset.loaded);
  await action();
  await page.waitForFunction(
    (b) => document.body.dataset.loaded !== b,
    before,
    { timeout: 30000 },
  );
}

async function drag(selector, toX) {
  const h = await page.locator(selector).boundingBox();
  const y = h.y + h.height / 2;
  await reloaded(async () => {
    await page.mouse.move(h.x + h.width / 2, y);
    await page.mouse.down();
    await page.mouse.move(toX, y, { steps: 8 });
    await page.mouse.up();
  });
}

try {
  await page.goto(base);
  await page.waitForSelector('.step[data-path="3.2"]');

  // the narration of beat 2 now runs until the typing step
  const typing = await page.locator('.step[data-path="3.2"]').boundingBox();
  await drag(
    '.span-edge[data-step="2"][data-span="narration"][data-edge="to"]',
    typing.x + 3,
  );
  const s1 = await page.textContent("#status");
  if (!s1.startsWith("anchor: narration edit")) fail(`narration drag: ${s1}`);

  // the step after the typing starts 100 px (500 ms) later
  const gap = await page.locator('.gap-handle[data-after="3.2"]').boundingBox();
  await drag('.gap-handle[data-after="3.2"]', gap.x + gap.width / 2 + 100);
  const s2 = await page.textContent("#status");
  if (!s2.startsWith("gap: timing edit")) fail(`gap drag: ${s2}`);

  // select the first click and pick the Recipes note in the preview
  await page.click('.step[data-path="2.1"]');
  await page.waitForFunction(() =>
    document.getElementById("preview").textContent.includes("Recipes"),
  );
  const at = await page.evaluate(() => {
    const pre = document.getElementById("preview");
    const lines = pre.textContent.split("\n");
    const row = lines.findIndex((l) => l.includes("Recipes"));
    const col = lines[row].indexOf("Recipes") + 2;
    const probe = document.createElement("span");
    probe.textContent = "M".repeat(100);
    probe.style.font = getComputedStyle(pre).font;
    probe.style.position = "absolute";
    document.body.appendChild(probe);
    const cw = probe.getBoundingClientRect().width / 100;
    probe.remove();
    const lh = parseFloat(getComputedStyle(pre).lineHeight);
    const r = pre.getBoundingClientRect();
    return { x: r.left + (col + 0.5) * cw, y: r.top + (row + 0.5) * lh };
  });
  await reloaded(() => page.mouse.click(at.x, at.y));
  await page.waitForFunction(
    () => document.getElementById("status").textContent.startsWith("picked"),
    null,
    { timeout: 60000 },
  );
  const s3 = await page.textContent("#status");
  if (!s3.includes('note-list/note[title="Recipes"]')) fail(`pick: ${s3}`);
  console.log(JSON.stringify({ narration: s1, gap: s2, pick: s3 }));
} catch (e) {
  fail(String((e && e.stack) || e));
} finally {
  await browser.close();
}
