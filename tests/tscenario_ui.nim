## The scenario editor's web page, driven by a real browser (DVS-10).
##
## No mocks: the page served by the editor, Chromium through playwright-core
## (`tests/browser/scenario_ui.mjs`), the terminal flavour's JSON-lines host
## over the conformance application, and a real realistic run for the
## timeline. The browser drags a narration edge and a gap and picks a target
## in the preview; this suite checks the scenario file those edits wrote.
##
## Needs DVS_TERMINAL_HOST, DVS_NOTES_TUI, DVS_ROOT (as tscenario_editor) and
## DVS_PLAYWRIGHT_CORE with node on PATH.

import std/[asyncdispatch, json, os, osproc, strutils, streams, unittest]
import demo_video_script/[scenario, lint, pack, model]
import demo_video_studio/[scenario_doc, scenario_editor]

proc need(name: string): string =
  result = getEnv(name)
  doAssert result.len > 0, name & " is not set (see the header of this file)"

let host = need("DVS_TERMINAL_HOST")
discard need("DVS_NOTES_TUI")
discard need("DVS_PLAYWRIGHT_CORE")
let dvsRoot = need("DVS_ROOT")
let packPath = dvsRoot / "conformance/pack/notes-app.pack.yaml"
let node = findExe("node")
doAssert node.len > 0, "node is not on PATH"

let work = getTempDir() / "dvs-scenario-ui-" & $getCurrentProcessId()
removeDir(work)
createDir(work / "scenarios")
createDir(work / "fixtures")
copyFile(dvsRoot / "conformance/fixtures/three-notes.json", work / "fixtures/three-notes.json")
let scenarioPath = work / "scenarios/tour.yaml"
copyFile(dvsRoot / "conformance/scenarios/presentation-tour.yaml", scenarioPath)

let (runOut, runCode) = execCmdEx(quoteShellCommand(@[host, "run", scenarioPath, "--pack", packPath,
  "--backend", "termassert", "--mode", "realistic", "--record", "always", "--out", work / "run"]))
doAssert runCode == 0, runOut

let doc = loadScenarioDoc(scenarioPath, packPath)
doc.attachRun(work / "run/manifest.json")
# aim the first click elsewhere, so the pick in the browser changes it back
discard doc.applyEdit(%*{"op": "target", "step": "2.1",
                         "locator": "note-list/note[title=\"Groceries\"]"})
let ed = newScenarioEditor(doc, @[Flavour(name: "terminal", command: host, args: @["--serve"],
                                          virtualTiming: true)])

suite "the scenario editor's page, in a real browser":

  test "dragging a narration edge, dragging a gap and picking a target":
    ed.start(0)
    let base = "http://127.0.0.1:" & $int(ed.port)
    let p = startProcess(node, args = @[currentSourcePath().parentDir / "browser/scenario_ui.mjs", base],
                         options = {poStdErrToStdOut})
    proc driver() {.async.} =
      proc serve() {.async.} =
        while true:
          try:
            if not await ed.pumpOnce(): break
          except CatchableError:
            break
      let s = serve()
      while p.running: await sleepAsync(100)
      ed.stop()
      try: await s
      except CatchableError: discard
    waitFor driver()
    let output = p.outputStream.readAll
    let code = p.waitForExit
    p.close
    checkpoint output
    check code == 0
    let text = readFile(scenarioPath)
    check text.contains("""narration: { text: "Open a note by clicking it.", voice: narrator, to: type-3-2 }""")
    check text.contains("        dwell: 1500ms\n")
    check text.contains("""      - click: { at: 'note-list/note[title="Recipes"]', pace:""")
    let (sc, d1) = parseScenarioFile(scenarioPath)
    let (pk, _) = parsePackFile(packPath)
    var errors: seq[string]
    for d in d1 & lintScenario(sc, pk):
      if d.severity == sevError: errors.add $d
    check errors.len == 0
    removeDir(work)
