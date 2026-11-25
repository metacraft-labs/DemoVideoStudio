// Opens a browser composite (`dvs-studio render --html`) from file:// in a
// real Chromium, plays it, and reports whether the presenter followed the
// screencast's clock, which callouts showed, and the captions track's cues.
//
//   node composite_page.mjs <index.html>

const { chromium } = await import(
  `${process.env.DVS_PLAYWRIGHT_CORE}/index.mjs`
);
const [pagePath] = process.argv.slice(2);
const browser = await chromium.launch({ args: ["--autoplay-policy=no-user-gesture-required"] });
try {
  const page = await browser.newPage({ viewport: { width: 1000, height: 700 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto(`file://${pagePath}`);
  await page.waitForFunction(() => document.getElementById("ui").readyState >= 3, null, { timeout: 15000 });
  const seen = await page.evaluate(async () => {
    const ui = document.getElementById("ui");
    const head = document.getElementById("head");
    ui.muted = true;
    await ui.play();
    const samples = [];
    const shown = new Set();
    const start = performance.now();
    while (performance.now() - start < 1500) {
      await new Promise((r) => setTimeout(r, 100));
      samples.push(head ? Math.abs(head.currentTime - ui.currentTime) : 0);
      for (const el of document.querySelectorAll(".callout"))
        if (el.style.display === "block") shown.add(el.textContent);
    }
    const track = ui.textTracks[0];
    track.mode = "hidden";
    await new Promise((r) => setTimeout(r, 300));
    return {
      playing: !ui.paused,
      headPlaying: head ? !head.paused : null,
      maxDrift: Math.max(...samples.slice(3)),
      callouts: [...shown],
      cues: track.cues ? [...track.cues].map((c) => c.text) : [],
    };
  });
  console.log(JSON.stringify({ ...seen, errors }));
} finally {
  await browser.close();
}
