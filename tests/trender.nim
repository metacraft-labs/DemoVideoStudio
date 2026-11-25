## Rendering through a pack on a chosen backend (DemoVideoStudio-Editor §4; DVS-11).
##
## No mocks. The conformance tour is run by the DemoVideoScript runner on two
## flavours — the terminal one (DemoVideoScript-TermAssert's JSON-lines host
## over the application's terminal build in a PTY, rasterised with `agg`) and
## the Playwright one (DemoVideoScript-Playwright's host driving Chromium over
## the application's web build) — and composed with real ffmpeg and the host's
## speech engine. Where the narration starts is measured in the rendered audio
## and compared with the offset the run's own manifest gives for the step it is
## anchored to, on each flavour.
##
## Needs DVS_TERMINAL_HOST, DVS_NOTES_TUI, DVS_ROOT, DVS_PLAYWRIGHT_ROOT (a
## DemoVideoScript-Playwright checkout with playwright-core linked),
## DVS_NOTES_WEB (the web build), node, agg and DVS_STUDIO_FONT_DIR (the
## Justfile's `build-flavours` and the dev shell provide them).

import std/[json, os, osproc, strutils, tables, unittest]
import demo_video_studio/[scenario_doc, scenario_editor, render]

proc need(name: string): string =
  result = getEnv(name)
  doAssert result.len > 0, name & " is not set (see the header of this file)"

let host = need("DVS_TERMINAL_HOST")
discard need("DVS_NOTES_TUI")
discard need("DVS_NOTES_WEB")
discard need("DVS_STUDIO_FONT_DIR")
let pwRoot = need("DVS_PLAYWRIGHT_ROOT")
let dvsRoot = need("DVS_ROOT")
let packPath = dvsRoot / "conformance/pack/notes-app.pack.yaml"
let node = findExe("node")
doAssert node.len > 0, "node is not on PATH"

let work = getTempDir() / "dvs-render-" & $getCurrentProcessId()
removeDir(work)
createDir(work / "scenarios")
createDir(work / "fixtures")
copyFile(dvsRoot / "conformance/fixtures/three-notes.json", work / "fixtures/three-notes.json")
let tour = work / "scenarios/tour.yaml"
copyFile(dvsRoot / "conformance/scenarios/presentation-tour.yaml", tour)
# the same tour with an expectation that does not hold at step 3.4
let broken = work / "scenarios/broken.yaml"
writeFile(broken, readFile(tour).replace("      - expect: { at: search-field, value: rec }",
                                         "      - expect: { at: search-field, value: nope }"))

let terminal = Flavour(name: "terminal", command: host, args: @["--serve"], virtualTiming: true)
let playwright = Flavour(name: "playwright", command: node,
  args: @[pwRoot / "src/main.ts", "--binding", pwRoot / "conformance/notes-binding.ts"])

proc ffprobe(args: seq[string]): string =
  let (o, code) = execCmdEx(quoteShellCommand(@[getEnv("FFPROBE_BIN", findExe("ffprobe"))] & args))
  doAssert code == 0, o
  o

proc firstSoundSeconds(video: string): float =
  ## When the audio first rises above silence.
  let ff = getEnv("FFMPEG_BIN", findExe("ffmpeg"))
  let (o, _) = execCmdEx(quoteShellCommand(@[ff, "-hide_banner", "-i", video, "-map", "0:a",
    "-af", "silencedetect=noise=-40dB:d=0.1", "-f", "null", "-"]))
  for l in o.splitLines:
    if "silence_end:" in l:
      return parseFloat(l.split("silence_end:")[1].strip.split(' ')[0])
  -1.0

proc expectedNarrationMs(runDir: string; virtual: bool): float =
  ## Where the run's manifest says the narration's step (2.1, the first of
  ## beat "open") is in the video, computed here from the manifest alone.
  let m = parseFile(runDir / "manifest.json")
  let rec = m["recordingStartMs"].getFloat
  var first, s21: JsonNode
  for s in m["steps"]:
    if first == nil: first = s
    if s["path"].getStr == "2.1": s21 = s
  if virtual:
    # the virtual timeline begins where the first step started
    (first["startMs"].getFloat - rec) + s21["virtualStartMs"].getFloat
  else:
    let lead = parseFile(runDir / "session.video.json")["leadMs"].getFloat
    lead + s21["startMs"].getFloat - rec

proc checkRender(f: Flavour; name: string) =
  let doc = loadScenarioDoc(tour, packPath)
  let outFile = work / (name & ".mp4")
  let r = renderScenario(doc, f, RenderOptions(outPath: outFile))
  checkpoint $reportJson(r)
  check r.ok
  check fileExists(outFile)
  let streams = ffprobe(@["-v", "error", "-show_entries", "stream=codec_type,codec_name",
                          "-of", "csv=p=0", outFile])
  check "h264,video" in streams
  check "aac,audio" in streams
  let duration = parseFloat(ffprobe(@["-v", "error", "-show_entries", "format=duration",
                                      "-of", "default=nw=1:nk=1", outFile]).strip)
  check duration * 1000 >= r.stepsMs["7"][1]
  var narration: Placement
  for p in r.placements:
    if p.kind == "narration": narration = p
  check narration.step == "2"
  let expected = expectedNarrationMs(r.runDir, f.virtualTiming)
  check abs(narration.startMs - expected) < 1.0
  let heard = firstSoundSeconds(outFile)
  checkpoint "narration placed at " & $narration.startMs & " ms; first sound at " & $heard & " s"
  check heard >= expected / 1000 - 0.05
  check heard <= expected / 1000 + 0.4
  # captions and callouts are placed on the same offsets
  var kinds: seq[string]
  for p in r.placements: kinds.add p.kind
  check "caption" in kinds
  check "callout" in kinds

suite "rendering through a pack on a chosen backend":

  test "the terminal flavour: a cast, timed at render, rasterised, narrated on the step":
    checkRender(terminal, "terminal")

  test "the Playwright flavour: real video, narrated on the same step":
    checkRender(playwright, "playwright")

  test "a step cap: no step is shown longer than the cap, the narration stays on its step":
    # A real-time flavour: the cap cuts the time a screen stood still out of
    # the recording itself (ffmpeg `setpts`), and every placement follows.
    let doc = loadScenarioDoc(tour, packPath)
    let outFile = work / "capped.mp4"
    let r = renderScenario(doc, playwright, RenderOptions(outPath: outFile, stepCapMs: 300))
    checkpoint $reportJson(r)
    check r.ok
    for path, sp in r.stepsMs:
      if '.' in path: check sp[1] - sp[0] <= 300.5
    let duration = parseFloat(ffprobe(@["-v", "error", "-show_entries", "format=duration",
                                        "-of", "default=nw=1:nk=1", outFile]).strip)
    check duration * 1000 >= r.stepsMs["7"][1]
    # the video was shortened, not padded: it ends within a second of the
    # last step (plus the composition's half-second tail)
    check duration * 1000 <= r.stepsMs["7"][1] + 1600
    var narration: Placement
    for p in r.placements:
      if p.kind == "narration": narration = p
    check abs(narration.startMs - r.stepsMs["2.1"][0]) < 1.0
    let heard = firstSoundSeconds(outFile)
    checkpoint "narration placed at " & $narration.startMs & " ms; first sound at " & $heard & " s"
    check heard >= narration.startMs / 1000 - 0.05
    check heard <= narration.startMs / 1000 + 0.4

  test "a recorded run is composed again without running the scenario":
    # The terminal flavour's run from the first case, moved out of its
    # render's work directory; the flavour's command does not exist, so
    # nothing can have run.
    let kept = work / "kept-run"
    copyDir(work / "terminal.mp4.render" / "run", kept)
    let doc = loadScenarioDoc(tour, packPath)
    let outFile = work / "again.mp4"
    let r = renderScenario(doc, Flavour(name: "terminal", command: work / "no-such-host",
                                        virtualTiming: true),
                           RenderOptions(outPath: outFile, fromRun: kept))
    checkpoint $reportJson(r)
    check r.ok
    check fileExists(outFile)
    var narration: Placement
    for p in r.placements:
      if p.kind == "narration": narration = p
    check abs(narration.startMs - expectedNarrationMs(r.runDir, true)) < 1.0
    # a run directory inside the render's own work directory is refused:
    # the render would clear it first
    expect RenderError:
      discard renderScenario(doc, terminal, RenderOptions(outPath: outFile,
        fromRun: outFile & ".render" / "run"))

  test "a run that fails renders nothing and reports the failing step":
    let doc = loadScenarioDoc(broken, packPath)
    let outFile = work / "broken.mp4"
    writeFile(outFile, "an earlier render")
    let r = renderScenario(doc, terminal, RenderOptions(outPath: outFile))
    checkpoint $reportJson(r)
    check not r.ok
    check r.failedStep == "3.4"
    check r.failedKind == "expect"
    check "nope" in r.message
    check not fileExists(outFile)
    check r.failureDir != "" and dirExists(r.failureDir)
    # the recording up to the failing step, no further
    check fileExists(r.recording)
    let m = parseFile(r.runDir / "manifest.json")
    var failedEnd = 0.0
    for s in m["steps"]:
      if s["path"].getStr == "3.4": failedEnd = s["endMs"].getFloat
    let limit = (failedEnd - m["recordingStartMs"].getFloat) / 1000
    var events = 0
    for l in readFile(r.recording).splitLines[1 .. ^1]:
      if l.strip.len == 0: continue
      inc events
      check parseJson(l)[0].getFloat <= limit + 0.001
    check events > 0
    removeDir(work)
