## A failing test run opened in the studio, read-only (DemoVideoStudio-Editor
## §5.6; DVS-13).
##
## No mocks: the failing run is a real run of the conformance tour with a
## broken expectation on the terminal flavour (DemoVideoScript-TermAssert's
## host over the application in a PTY), recorded as DemoVideoScript keeps a
## failing run (Format §9.1). It is opened through the run page's HTTP surface
## and in a real Chromium.
##
## Needs DVS_TERMINAL_HOST, DVS_NOTES_TUI, DVS_ROOT, DVS_PLAYWRIGHT_CORE and node.

import std/[asyncdispatch, httpclient, json, os, osproc, streams, strutils, unittest]
import demo_video_studio/run_view

proc need(name: string): string =
  result = getEnv(name)
  doAssert result.len > 0, name & " is not set (see the header of this file)"

let host = need("DVS_TERMINAL_HOST")
discard need("DVS_NOTES_TUI")
discard need("DVS_PLAYWRIGHT_CORE")
let dvsRoot = need("DVS_ROOT")
let node = findExe("node")
doAssert node.len > 0, "node is not on PATH"

let work = getTempDir() / "dvs-open-" & $getCurrentProcessId()
removeDir(work)
createDir(work / "scenarios")
createDir(work / "fixtures")
copyFile(dvsRoot / "conformance/fixtures/three-notes.json", work / "fixtures/three-notes.json")
let broken = work / "scenarios/broken.yaml"
writeFile(broken, readFile(dvsRoot / "conformance/scenarios/presentation-tour.yaml").replace(
  "      - expect: { at: search-field, value: rec }", "      - expect: { at: search-field, value: nope }"))
let runDir = work / "run"
let (runOut, runCode) = execCmdEx(quoteShellCommand(@[host, "run", broken, "--pack",
  dvsRoot / "conformance/pack/notes-app.pack.yaml", "--backend", "termassert",
  "--record", "on-failure", "--out", runDir]))
doAssert runCode == 1, "the broken tour was expected to fail:\n" & runOut
doAssert fileExists(runDir / "manifest.json"), runOut

suite "a failing run, opened":

  test "through HTTP: the steps with results, the failing step, its stills and state":
    let v = openRun(runDir)
    v.start(0)
    let base = "http://127.0.0.1:" & $int(v.port)
    proc driver() {.async.} =
      proc serve() {.async.} =
        while true:
          if not await v.pumpOnce(): break
      let s = serve()
      let c = newAsyncHttpClient()
      let run = parseJson(await c.getContent(base & "/api/run"))
      check run["outcome"].getStr == "failed"
      check run["failing"].getStr == "3.4"
      check run["readOnly"].getBool
      var statuses: seq[string]
      for st in run["steps"]: statuses.add st["path"].getStr & ":" & st["status"].getStr
      check "3.3:passed" in statuses
      check "3.4:failed" in statuses
      check "4:not-run" in statuses
      var failing: JsonNode
      for st in run["steps"]:
        if st["path"].getStr == "3.4": failing = st
      check "nope" in failing["message"].getStr
      check failing["stills"].len > 0
      for u in failing["stills"]:
        let r = await c.get(base & u.getStr)
        check r.code == Http200
      let txt = await c.getContent(base & (block:
        var t = ""
        for u in failing["stills"]:
          if u.getStr.endsWith(".txt"): t = u.getStr
        t))
      check "rec" in txt                          # what the screen showed
      let state = parseJson(await c.getContent(base & failing["state"].getStr))
      check "rec" in $state                       # the observed value
      check run["failure"].len > 0
      # read-only
      let p = await c.request(base & "/api/edit", httpMethod = HttpPost, body = "{}")
      check p.code == Http405
      # nothing outside the run directory
      let esc = await c.get(base & "/files/..%2F..%2Fetc%2Fpasswd")
      check esc.code == Http404
      c.close()
      v.stop()
      try: await s
      except CatchableError: discard
    waitFor driver()

  test "in a real browser: the failing step selected, with its still and observed state":
    let v = openRun(runDir)
    v.start(0)
    let base = "http://127.0.0.1:" & $int(v.port)
    let p = startProcess(node, args = @[currentSourcePath().parentDir / "browser/run_ui.mjs", base],
                         options = {poStdErrToStdOut})
    proc driver() {.async.} =
      proc serve() {.async.} =
        while true:
          if not await v.pumpOnce(): break
      let s = serve()
      while p.running: await sleepAsync(100)
      v.stop()
      try: await s
      except CatchableError: discard
    waitFor driver()
    let output = p.outputStream.readAll
    let code = p.waitForExit
    p.close
    checkpoint output
    check code == 0
    var shown: JsonNode
    for l in output.splitLines:
      if l.startsWith("{"): shown = parseJson(l)
    check shown != nil
    if shown != nil:
      check shown["selected"].getStr == "3.4"
      check shown["selectedClass"].getStr.startsWith("failed")
      check "nope" in shown["message"].getStr
      check shown["stills"].getInt > 0
      check "rec" in shown["textStill"].getStr
      check "rec" in shown["state"].getStr
      check shown["failure"].len > 0
      check "4:not-run" in shown["statuses"].to(seq[string])
    removeDir(work)
