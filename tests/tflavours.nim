## Several flavours at once (DemoVideoStudio-Editor §5; DVS-12).
##
## No mocks. The studio runs as its own process (`dvs-studio edit`) with two
## flavours over the conformance application — the terminal one
## (DemoVideoScript-TermAssert's host, a PTY) and the Playwright one
## (DemoVideoScript-Playwright's host, Chromium) — and is driven through its
## HTTP surface. What a switch does is observed from outside, by the kernel's
## accounting of that process: its read counters (`/proc/<pid>/io`: `rchar`
## and `syscr` count every read(2) of a file or pipe; a socket's recv does not
## count) and the set of its descendant processes. Linux only, for /proc.
##
## Needs DVS_STUDIO_BIN, DVS_TERMINAL_HOST, DVS_NOTES_TUI, DVS_ROOT,
## DVS_PLAYWRIGHT_ROOT, DVS_NOTES_WEB, node, agg and DVS_STUDIO_FONT_DIR.

import std/[httpclient, json, os, osproc, sequtils, sets, strutils, tables, times, unittest, uri]

proc need(name: string): string =
  result = getEnv(name)
  doAssert result.len > 0, name & " is not set (see the header of this file)"

let studio = need("DVS_STUDIO_BIN")
let host = need("DVS_TERMINAL_HOST")
let pwRoot = need("DVS_PLAYWRIGHT_ROOT")
let dvsRoot = need("DVS_ROOT")
for v in ["DVS_NOTES_TUI", "DVS_NOTES_WEB", "DVS_STUDIO_FONT_DIR"]: discard need(v)
let node = findExe("node")
doAssert node.len > 0, "node is not on PATH"
let packPath = dvsRoot / "conformance/pack/notes-app.pack.yaml"

let work = getTempDir() / "dvs-flavours-" & $getCurrentProcessId()
removeDir(work)
createDir(work / "scenarios")
createDir(work / "fixtures")
copyFile(dvsRoot / "conformance/fixtures/three-notes.json", work / "fixtures/three-notes.json")
let tour = work / "scenarios/tour.yaml"
copyFile(dvsRoot / "conformance/scenarios/presentation-tour.yaml", tour)

# the studio, its output to a log so its pipe never fills; `exec` keeps the pid
let log = work / "studio.log"
let server = startProcess("/bin/sh", args = @["-c", "exec \"$@\" > \"$0\" 2>&1", log, studio,
  "edit", tour, "--pack", packPath, "--port", "0",
  "--flavour", "terminal=" & host & " --serve", "--virtual-timing", "terminal",
  "--flavour", "playwright=" & node & " " & pwRoot / "src/main.ts" & " --binding " &
    pwRoot / "conformance/notes-binding.ts"])
let pid = server.processID
var base = ""
for _ in 0 ..< 600:
  if fileExists(log):
    for l in readFile(log).splitLines:
      if " on http://" in l: base = l.split(" on ")[1].strip(chars = {'/', ' '})
  if base != "": break
  sleep 100
doAssert base != "", "the studio did not start:\n" & (if fileExists(log): readFile(log) else: "")

let c = newHttpClient(timeout = 600_000)
c.headers = newHttpHeaders([("Content-Type", "application/json")])

proc get(path: string): JsonNode = parseJson(c.getContent(base & path))
proc post(path: string; body: JsonNode): (int, JsonNode) =
  let r = c.request(base & path, httpMethod = HttpPost, body = $body)
  (r.code.int, parseJson(r.body))

proc flavour(status: JsonNode; name: string): JsonNode =
  for f in status["flavours"]:
    if f["name"].getStr == name: return f

proc waitFor(pred: proc (s: JsonNode): bool; what: string): JsonNode =
  let deadline = epochTime() + 120
  while epochTime() < deadline:
    result = get("/api/flavours")
    if pred(result): return
    sleep 100
  doAssert false, "timed out waiting for " & what & ": " & $result

proc atStep(index: int): proc (s: JsonNode): bool =
  result = proc (s: JsonNode): bool =
    for name in ["terminal", "playwright"]:
      let f = s.flavour(name)
      if not f["loaded"].getBool or f["position"].getInt != index or f["catchingUp"].getBool:
        return false
    true

proc readCounters(): (int64, int64) =
  var rchar, syscr: int64
  for l in readFile("/proc/" & $pid & "/io").splitLines:
    if l.startsWith("rchar:"): rchar = parseBiggestInt(l.split(':')[1].strip)
    if l.startsWith("syscr:"): syscr = parseBiggestInt(l.split(':')[1].strip)
  (rchar, syscr)

proc descendants(root: int): HashSet[int] =
  var parent = initTable[int, int]()
  for d in walkDirs("/proc/*"):
    let n = d.lastPathPart
    if not n.allCharsInSet(Digits): continue
    try:
      let stat = readFile(d / "stat")
      let rest = stat[stat.rfind(')') + 2 .. ^1].split(' ')
      parent[parseInt(n)] = parseInt(rest[1])
    except IOError, OSError: discard
  var frontier = @[root]
  while frontier.len > 0:
    let p = frontier.pop
    for child, par in parent:
      if par == p and child notin result:
        result.incl child
        frontier.add child

proc processState(p: int): char =
  let stat = readFile("/proc/" & $p & "/stat")
  stat[stat.rfind(')') + 2]

var steps: Table[string, JsonNode]   # each flavour's step spans in its render

suite "several flavours at once":

  test "flavours are listed with their applicability before anything is loaded":
    let s = get("/api/flavours")
    for name in ["terminal", "playwright"]:
      check s.flavour(name)["applicable"].getBool
      check not s.flavour(name)["loaded"].getBool

  test "loading keeps each flavour resident; exceeding the budget asks, it does not evict":
    let (c1, j1) = post("/api/load", %*{"flavour": "terminal"})
    check c1 == 200
    steps["terminal"] = j1["steps"]
    let mem = j1["status"].flavour("terminal")["memoryBytes"].getBiggestInt
    check mem > 0
    # a budget the second flavour will not fit in
    discard post("/api/budget", %*{"bytes": mem + 1024})
    let (c2, j2) = post("/api/load", %*{"flavour": "playwright"})
    check c2 == 200
    steps["playwright"] = j2["steps"]
    let s = j2["status"]
    check s["overBudget"].getBool
    check s["unloadOneOf"].to(seq[string]).toHashSet == ["terminal", "playwright"].toHashSet
    check s.flavour("terminal")["loaded"].getBool
    check s.flavour("playwright")["loaded"].getBool
    discard post("/api/budget", %*{"bytes": 4'i64 * 1024 * 1024 * 1024})

  test "a switch reads nothing, starts nothing, and shows the other flavour at the same step":
    discard post("/api/playhead", %*{"step": "2.1", "fraction": 0.5})
    discard waitFor(atStep(1), "both sessions at step 2.1")
    discard post("/api/switch", %*{"flavour": "terminal"})
    let before = readCounters()
    let procsBefore = descendants(pid)
    let (code, v) = post("/api/switch", %*{"flavour": "playwright"})
    let png = c.getContent(base & "/api/frame")
    let after = readCounters()
    let procsAfter = descendants(pid)
    check code == 200
    checkpoint "rchar " & $before[0] & " -> " & $after[0] & ", syscr " & $before[1] & " -> " & $after[1]
    check after[0] == before[0]      # no byte read from a file or a pipe
    check after[1] == before[1]
    check procsAfter == procsBefore  # no process started (or gone)
    check png.startsWith("\x89PNG")
    # the playhead is a step position: 2.1, half-way, on this flavour's own time
    let span = steps["playwright"]["2.1"]
    let t = span["startMs"].getFloat + 0.5 * (span["endMs"].getFloat - span["startMs"].getFloat)
    check v["flavour"].getStr == "playwright"
    check v["step"].getStr == "2.1"
    check abs(v["timeMs"].getFloat - t) < 0.01
    check v["frameIndex"].getInt == int(t / 1000 * 10)
    # and on the terminal flavour, its own time for the same position
    let (_, w) = post("/api/switch", %*{"flavour": "terminal"})
    let tspan = steps["terminal"]["2.1"]
    let tt = tspan["startMs"].getFloat + 0.5 * (tspan["endMs"].getFloat - tspan["startMs"].getFloat)
    check abs(w["timeMs"].getFloat - tt) < 0.01
    check abs(tt - t) > 1.0
    check c.getContent(base & "/api/frame") != png

  test "stepping forward drives both live sessions to the step":
    discard post("/api/playhead", %*{"step": "3.1"})
    discard waitFor(atStep(4), "both sessions at step 3.1")
    for name in ["terminal", "playwright"]:
      let r = get("/api/live?flavour=" & name & "&locator=" &
                  encodeUrl("note-list/note[title=\"Recipes\"]") & "&props=selected")
      checkpoint name & ": " & $r
      check r["selected"].getBool    # step 2.1 clicked it, on each flavour

  test "a suspended session stays switchable, and is resumed before it is driven":
    let (code, _) = post("/api/suspend", %*{"flavour": "terminal"})
    check code == 200
    let hostPid = get("/api/flavours").flavour("terminal")["pids"][0].getInt
    check processState(hostPid) == 'T'
    let procsBefore = descendants(pid)
    let (c2, v) = post("/api/switch", %*{"flavour": "terminal"})
    check c2 == 200
    check v["session"].getStr == "suspended"
    check descendants(pid) == procsBefore
    discard post("/api/playhead", %*{"step": "3.2"})
    let s = waitFor(atStep(5), "both sessions at step 3.2")
    check not s.flavour("terminal")["suspended"].getBool
    check processState(hostPid) != 'T'

  test "a narration edit leaves both recordings fresh; an input edit stales both":
    let (c1, e1) = post("/api/edit", %*{"op": "narration", "step": "2", "text": "Pick a note."})
    check c1 == 200
    var s = get("/api/flavours")
    for name in ["terminal", "playwright"]:
      let stale = s.flavour(name)["stale"].to(seq[string])
      checkpoint name & " stale: " & $stale
      check "automation" notin stale
      check "local-audio" in stale
    check s["rerecord"].len == 0
    check e1["rerecord"].len == 0
    let (c2, e2) = post("/api/edit", %*{"op": "target", "step": "2.1",
                                       "locator": "note-list/note[title=\"Groceries\"]"})
    check c2 == 200
    s = get("/api/flavours")
    for name in ["terminal", "playwright"]:
      check "automation" in s.flavour(name)["stale"].to(seq[string])
    check s["rerecord"].to(seq[string]).toHashSet == ["terminal", "playwright"].toHashSet
    check e2["rerecord"].len == 2

  test "unloading is explicit and ends the live session":
    let pids = get("/api/flavours").flavour("playwright")["pids"].to(seq[int])
    discard post("/api/unload", %*{"flavour": "playwright"})
    check not get("/api/flavours").flavour("playwright")["loaded"].getBool
    sleep 500
    for p in pids: check not dirExists("/proc/" & $p)

c.close()
server.terminate()
discard server.waitForExit()
server.close()
removeDir(work)
