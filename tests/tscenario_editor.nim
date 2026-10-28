## Editing a scenario in abstract terms, through the editor's HTTP surface
## (DemoVideoStudio-Editor §3; DVS-10).
##
## No mocks. The flavour is DemoVideoScript-TermAssert's JSON-lines host driving
## the conformance application's terminal build in a real PTY; the timeline's
## times come from a real realistic run of the scenario on it. Every edit goes
## through HTTP, is written to the file, and the file is parsed and linted
## again by DemoVideoScript itself.
##
## Needs (the Justfile's `build-flavours` provides them):
##   DVS_TERMINAL_HOST  the `dvs-termassert-notes` host
##   DVS_NOTES_TUI      the conformance application's terminal build
##   DVS_ROOT           a DemoVideoScript checkout (its conformance pack, fixtures)

import std/[asyncdispatch, httpclient, json, os, osproc, re, strutils, tables, unittest]
import demo_video_script/[scenario, lint, pack, model, backend, runner, grammar]
import demo_video_studio/[scenario_doc, scenario_editor]

proc need(name: string): string =
  result = getEnv(name)
  doAssert result.len > 0, name & " is not set (see the header of this file)"

let host = need("DVS_TERMINAL_HOST")
discard need("DVS_NOTES_TUI")
let dvsRoot = need("DVS_ROOT")
let packPath = dvsRoot / "conformance/pack/notes-app.pack.yaml"

let work = getTempDir() / "dvs-scenario-editor-" & $getCurrentProcessId()
removeDir(work)
createDir(work / "scenarios")
createDir(work / "fixtures")
copyFile(dvsRoot / "conformance/fixtures/three-notes.json", work / "fixtures/three-notes.json")

# the conformance tour, with comments the editor must keep
let original = "# The tour, as a production edits it.\n" &
  readFile(dvsRoot / "conformance/scenarios/presentation-tour.yaml").multiReplace(
    ("steps:\n", "steps:\n  # opening shot\n"),
    ("  - beat: write\n", "  # the typing part\n  - beat: write\n"),
    ("      - wait: { until: idle }\n", "      - wait: { until: idle }  # let the list filter\n"))
let scenarioPath = work / "scenarios/tour.yaml"
writeFile(scenarioPath, original)

let terminal = Flavour(name: "terminal", command: host, args: @["--serve"], virtualTiming: true)

proc realisticRun(): string =
  ## A realistic run of the scenario as it is now, on the terminal flavour.
  let dir = work / "run"
  removeDir(dir)
  let (output, code) = execCmdEx(quoteShellCommand(@[host, "run", scenarioPath, "--pack", packPath,
    "--backend", "termassert", "--mode", "realistic", "--record", "always", "--out", dir]))
  doAssert code == 0, "the realistic run failed:\n" & output
  dir / "manifest.json"

proc withEditor(ed: ScenarioEditor; body: proc (base: string): Future[void]) =
  ed.start(0)
  let base = "http://127.0.0.1:" & $int(ed.port)
  proc driver() {.async.} =
    proc serve() {.async.} =
      while true:
        try:
          if not await ed.pumpOnce(): break
        except CatchableError:
          break
    let s = serve()
    await body(base)
    # closing the socket ends the accept the loop is waiting in
    ed.stop()
    try: await s
    except CatchableError: discard
  waitFor driver()

proc post(c: AsyncHttpClient; url: string; body: JsonNode): Future[(int, JsonNode)] {.async.} =
  let r = await c.request(url, httpMethod = HttpPost, body = $body)
  let text = await r.body
  return (r.code.int, (if text.len > 0 and text[0] == '{': parseJson(text) else: %*{"raw": text}))

proc lintsClean(path: string): seq[string] =
  let (sc, d1) = parseScenarioFile(path)
  let (pk, _) = parsePackFile(packPath)
  var ds = d1
  if not d1.hasStructuralErrors: ds.add lintScenario(sc, pk)
  for d in ds:
    if d.severity == sevError: result.add $d

proc isSubsequence(small, big: seq[string]): bool =
  var i = 0
  for l in big:
    if i < small.len and l == small[i]: inc i
  i == small.len

let doc = loadScenarioDoc(scenarioPath, packPath)
doc.attachRun(realisticRun())
let ed = newScenarioEditor(doc, @[terminal])

suite "editing in scenario terms (HTTP)":

  test "the timeline is the steps, on the flavour's measured times":
    withEditor(ed, proc (base: string) {.async.} =
      let c = newAsyncHttpClient()
      defer: c.close()
      let j = parseJson(await c.getContent(base & "/api/scenario"))
      check j["flavour"].getStr == "termassert"
      var paths: seq[string]
      for s in j["steps"]:
        paths.add s["path"].getStr
        if s["kind"].getStr != "beat": check s.hasKey("startMs")
      check paths == @["1", "2", "2.1", "2.2", "2.3", "3", "3.1", "3.2", "3.3", "3.4", "4", "5",
                        "6", "7"])

  test "dragging a narration edge re-anchors it to the step under it":
    let typing = doc.measured("3.2")
    withEditor(ed, proc (base: string) {.async.} =
      let c = newAsyncHttpClient()
      defer: c.close()
      let (code, j) = await c.post(base & "/api/edit", %*{"op": "anchor", "span": "narration",
        "step": "2", "edge": "to", "atMs": typing.startMs + 1.0})
      check code == 200
      check j["class"].getStr == "narration"
      let inv = j["invalidated"].to(seq[string])
      check "automation" notin inv
      check "local-audio" in inv
      check "final" in inv)
    let text = readFile(scenarioPath)
    # the step under the point had no name; it was given one, and the span
    # anchors to it — a name, not a time
    check text.contains("""narration: { text: "Open a note by clicking it.", voice: narrator, to: type-3-2 }""")
    check text.contains("        id: type-3-2\n")
    check lintsClean(scenarioPath).len == 0

  test "dragging a gap edits the earlier step's dwell, or the later one's lead-in":
    let next = doc.measured("3.3")
    let stagesBefore = ed.stagesJson
    withEditor(ed, proc (base: string) {.async.} =
      let c = newAsyncHttpClient()
      defer: c.close()
      # the step after the typing should start half a second later
      let (code, j) = await c.post(base & "/api/edit", %*{"op": "gap", "after": "3.2",
        "startMs": next.startMs + 500.0})
      check code == 200
      check j["class"].getStr == "timing"
      let (code2, _) = await c.post(base & "/api/edit", %*{"op": "gap", "after": "2.1",
        "deltaMs": 250, "side": "lead-in"})
      check code2 == 200)
    let text = readFile(scenarioPath)
    check text.contains("        dwell: 1500ms\n")      # was 1s
    check text.contains("      - wait: { until: settled }\n        lead-in: 250ms\n")
    check lintsClean(scenarioPath).len == 0
    # the terminal flavour applies timing at render: its recording is not stale
    check ed.stagesJson["terminal"]["automation"] == stagesBefore["terminal"]["automation"]
    check ed.stagesJson["terminal"]["final"] != stagesBefore["terminal"]["final"]

  test "a pacing edit is written as pacing":
    withEditor(ed, proc (base: string) {.async.} =
      let c = newAsyncHttpClient()
      defer: c.close()
      let (code, _) = await c.post(base & "/api/edit", %*{"op": "pace", "step": "3.1",
        "pace": "careful"})
      check code == 200)
    check readFile(scenarioPath).contains("      - click: { at: search-field, pace: careful }\n")
    check lintsClean(scenarioPath).len == 0

  test "picking a point records the semantic locator; a point on no role is refused":
    # aim the click elsewhere first, so the pick has something to change
    let stagesBefore = ed.stagesJson
    discard doc.applyEdit(%*{"op": "target", "step": "2.1",
                             "locator": "note-list/note[title=\"Groceries\"]"})
    check ed.stagesJson["terminal"]["automation"] != stagesBefore["terminal"]["automation"]
    # where the Recipes note and the status bar are, just before the click
    let s = ed.sessionBefore(terminal, "2.1")
    proc centre(loc: string): (float, float) =
      let r = s.locate(locatorJson(parseLocator(loc)))
      doAssert r.outcome == loOne, loc
      let g = s.read(r.instance, @["geometry"])["geometry"]
      (g["x"].getFloat + g["w"].getFloat / 2, g["y"].getFloat + g["h"].getFloat / 2)
    let recipes = centre("note-list/note[title=\"Recipes\"]")
    let status = centre("status-bar")
    s.close()
    withEditor(ed, proc (base: string) {.async.} =
      let c = newAsyncHttpClient()
      defer: c.close()
      let (code, j) = await c.post(base & "/api/pick", %*{"step": "2.1",
        "x": recipes[0], "y": recipes[1]})
      check code == 200
      check j["locator"].getStr == "note-list/note[title=\"Recipes\"]"
      check j["role"].getStr == "note"
      check j["class"].getStr == "semantic"
      check j["resolves"]["terminal"].getStr == "one"
      let textBefore = readFile(scenarioPath)
      # off the medium: no role covers it
      let (c1, j1) = await c.post(base & "/api/pick", %*{"step": "2.1", "x": -5, "y": -5})
      check c1 == 422
      check j1["error"].getStr.contains("no role covers")
      # on a role that cannot be clicked
      let (c2, j2) = await c.post(base & "/api/pick", %*{"step": "2.1",
        "x": status[0], "y": status[1]})
      check c2 == 422
      check j2["error"].getStr.contains("does not afford 'click'")
      check readFile(scenarioPath) == textBefore)
    check readFile(scenarioPath).contains(
      """      - click: { at: 'note-list/note[title="Recipes"]', pace: { preset: careful""")
    check lintsClean(scenarioPath).len == 0

  test "an edit that would not lint is refused, and the file is left alone":
    let textBefore = readFile(scenarioPath)
    withEditor(ed, proc (base: string) {.async.} =
      let c = newAsyncHttpClient()
      defer: c.close()
      let (code, j) = await c.post(base & "/api/edit", %*{"op": "insert", "after": "5",
        "yaml": "click: no-such-role"})
      check code == 422
      check j["diagnostics"].len > 0)
    check readFile(scenarioPath) == textBefore

  test "avatar keyframes are canvas geometry at a time relative to a step":
    let at = doc.measured("3.2").startMs + 400.0
    withEditor(ed, proc (base: string) {.async.} =
      let c = newAsyncHttpClient()
      defer: c.close()
      let (code, j) = await c.post(base & "/api/avatar", %*{"keyframes": [
        {"atMs": at, "srcCrop": {"x": 0, "y": 0, "w": 512, "h": 512},
         "dstRect": {"x": 1500, "y": 760, "w": 320, "h": 320}}]})
      check code == 200
      check j["invalidated"].to(seq[string]) == @["final"])
    let kf = parseFile(doc.avatarPath)["keyframes"][0]
    check kf["anchor"].getStr == "type-3-2"
    check kf["offset"].getStr == "400ms"
    check kf["dstRect"]["x"].getInt == 1500

  test "the saved scenario keeps its comments and key order, and holds no time":
    let saved = readFile(scenarioPath)
    for l in original.splitLines:
      if l.strip.startsWith("#"): check l in saved.splitLines
    check saved.contains("      - wait: { until: idle }  # let the list filter\n")
    # every line the edits did not touch is still there, in order
    var untouched: seq[string]
    for l in original.splitLines:
      if not (l.contains("narration:") or l.contains("click:") or l.contains("dwell:") or
              l.contains("pace:")): untouched.add l
    check isSubsequence(untouched, saved.splitLines)
    # the only durations are the format's relative ones
    for m in saved.findAll(re"[a-z-]+: [0-9.]+m?s\b"):
      check m.split(':')[0] in ["lead-in", "dwell", "timeout", "for", "key-mean", "key-min",
                                "key-max", "hover"]
    check lintsClean(scenarioPath).len == 0
    removeDir(work)
