// Opens a cast page from file:// in a real Chromium (playwright-core from
// DVS_PLAYWRIGHT_CORE), plays it, and reports what the player shows and
// every request the page made that was not to a file:// URL.
//
//   node cast_page.mjs <page.html> <seconds to play>

const { chromium } = await import(
  `${process.env.DVS_PLAYWRIGHT_CORE}/index.mjs`
);
const [pagePath, seconds] = process.argv.slice(2);
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
  const network = [];
  const errors = [];
  page.on("request", (r) => {
    if (!r.url().startsWith("file:") && !r.url().startsWith("data:")) network.push(r.url());
  });
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto(`file://${pagePath}`);
  await page.waitForFunction(() => window.player !== undefined, null, { timeout: 15000 });
  const duration = await page.evaluate(async () => {
    await window.player.play();
    return window.player.getDuration();
  });
  await page.waitForTimeout(Number(seconds) * 1000);
  const shown = await page.evaluate(() => ({
    time: window.player.getCurrentTime(),
    text: document.querySelector(".ap-player")?.innerText ?? "",
  }));
  console.log(JSON.stringify({ duration, ...shown, network, errors }));
} finally {
  await browser.close();
}
