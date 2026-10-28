// Opens a failing run in the studio's run page, in a real Chromium
// (playwright-core from DVS_PLAYWRIGHT_CORE), and reports what it shows:
// the selected step, its message, its stills and its observed state.
//
//   node run_ui.mjs <run page base URL>

const { chromium } = await import(
  `${process.env.DVS_PLAYWRIGHT_CORE}/index.mjs`
);
const base = process.argv[2];
const browser = await chromium.launch();
try {
  const page = await browser.newPage({
    viewport: { width: 1400, height: 900 },
  });
  await page.goto(base);
  await page.waitForFunction(
    () => document.body.dataset.selected !== undefined,
    null,
    { timeout: 30000 },
  );
  const shown = await page.evaluate(() => ({
    selected: document.querySelector("#steps li.selected")?.dataset.path,
    selectedClass: document.querySelector("#steps li.selected")?.className,
    message: document.getElementById("sel-message").textContent,
    stills: document.querySelectorAll("#stills .still").length,
    textStill: [...document.querySelectorAll("#stills pre.still")]
      .map((p) => p.textContent)
      .join("\n"),
    state: document.getElementById("state").textContent,
    failure: [...document.querySelectorAll("#failure a")].map(
      (a) => a.textContent,
    ),
    statuses: [...document.querySelectorAll("#steps li")].map(
      (li) => `${li.dataset.path}:${li.className.split(" ")[0]}`,
    ),
  }));
  console.log(JSON.stringify(shown));
} finally {
  await browser.close();
}
