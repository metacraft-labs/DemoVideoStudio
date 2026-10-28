## Several flavours at once (DemoVideoStudio-Editor §5).
##
## A loaded flavour is resident: its live session (the backend attached to a
## running application, the stage done), its last render decoded to frames in
## memory, and the stage inputs that render was made from. It stays until the
## user unloads it; a configured memory budget being exceeded is reported, with
## the flavours that could be unloaded, and nothing is ever evicted silently
## (§5.2, decision D10). A live session may be suspended — its processes
## stopped, its render still resident — and is resumed before it is driven.
##
## The playhead is a step position (a step, and how far through it), never a
## time: on each flavour it maps to that flavour's own time (§5.3). Switching
## the displayed flavour reads nothing, starts nothing and runs nothing: the
## frame comes from memory. The live sessions follow the playhead by step, in
## lockstep (§5.4): `advance` drives them one step at a time between requests,
## and a backwards seek re-stages a session and drives it forward again, the
## preview showing the render meanwhile.

import std/[json, os, osproc, posix, streams, strutils, tables]
import demo_video_script/[backend, jsonlines, runner, model, grammar]
import ./[scenario_doc, flavour, render]

const
  PreviewFps* = 10.0
  DefaultBudget* = 4'i64 * 1024 * 1024 * 1024   ## decision D10

type
  Resident* = ref object
    flavour*: Flavour
    report*: RenderReport
    frames*: seq[string]       ## the last render, as PNG frames at PreviewFps
    framesBytes*: int64
    session*: Backend
    pids*: seq[int]            ## the live session's processes: its host and descendants
    position*: int             ## leaf steps the live session has run; -1: to be re-staged
    suspended*: bool
    catchingUp*: bool
    hashes*: OrderedTable[string, string]   ## the stage inputs the render was made from
    error*: string

  Flavours* = ref object
    doc*: ScenarioDoc
    available*: seq[Flavour]
    hellos*: Table[string, Hello]
    resident*: OrderedTable[string, Resident]
    displayed*: string
    budget*: int64
    playheadStep*: string
    playheadFraction*: float
    renderDir*: string
    speech*: string

  FlavourError* = object of CatchableError

proc flavourError(msg: string): ref FlavourError = newException(FlavourError, msg)

proc newFlavours*(doc: ScenarioDoc; available: seq[Flavour]; renderDir = ""): Flavours =
  result = Flavours(doc: doc, available: available, budget: DefaultBudget,
                    renderDir: (if renderDir != "": renderDir
                                else: getTempDir() / "dvs-studio-" & $getCurrentProcessId()))
  let leaves = doc.stepPaths
  if leaves.len > 0: result.playheadStep = leaves[0]

proc flavourNamed(fs: Flavours; name: string): Flavour =
  for f in fs.available:
    if f.name == name: return f
  raise flavourError("no flavour '" & name & "'")

proc leaves*(fs: Flavours): seq[string] =
  ## The steps the playhead moves over, in run order (beats are their steps).
  for p in fs.doc.stepPaths:
    if fs.doc.step(p).kind != stBeat: result.add p

proc leafIndex(fs: Flavours; path: string): int =
  ## How many steps run before `path` (a beat: before its first step).
  let ls = fs.leaves
  for k, p in ls:
    if p == path or p.startsWith(path & "."): return k
  raise flavourError("no step " & path)

# ---------------------------------------------------------------------------
# Processes
# ---------------------------------------------------------------------------

proc childrenOf(pid: int): seq[int] =
  let (o, _) = execCmdEx("pgrep -P " & $pid)
  for l in o.splitLines:
    if l.strip.len > 0: result.add parseInt(l.strip)

proc treeOf(pid: int): seq[int] =
  result = @[pid]
  for c in childrenOf(pid): result.add treeOf(c)

proc newestChild(): int =
  let (o, _) = execCmdEx("pgrep -n -P " & $getCurrentProcessId())
  if o.strip.len == 0: raise flavourError("the flavour's host did not start")
  parseInt(o.strip)

proc rssBytes(pids: seq[int]): int64 =
  if pids.len == 0: return 0
  var ps: seq[string]
  for p in pids: ps.add $p
  let (o, _) = execCmdEx("ps -o rss= -p " & ps.join(","))
  for l in o.splitLines:
    if l.strip.len > 0: result += parseBiggestInt(l.strip) * 1024

proc signalTree(r: Resident; sig: cint) =
  for p in r.pids:
    discard posix.kill(Pid(p), sig)

proc suspend*(fs: Flavours; name: string) =
  let r = fs.resident.getOrDefault(name)
  if r == nil: raise flavourError("'" & name & "' is not loaded")
  if r.suspended: return
  r.pids = treeOf(r.pids[0])
  r.signalTree(SIGSTOP)
  r.suspended = true

proc resume*(fs: Flavours; name: string) =
  let r = fs.resident.getOrDefault(name)
  if r == nil or not r.suspended: return
  for k in countdown(r.pids.high, 0): discard posix.kill(Pid(r.pids[k]), SIGCONT)
  r.suspended = false

# ---------------------------------------------------------------------------
# Applicability, before loading (§5.1)
# ---------------------------------------------------------------------------

proc helloOf(fs: Flavours; f: Flavour): Hello =
  if f.name notin fs.hellos:
    let b = spawnJsonLinesBackend(f.command, f.args, name = f.name)
    try: fs.hellos[f.name] = b.hello()
    finally: b.close()
  fs.hellos[f.name]

proc applicabilityJson*(fs: Flavours; f: Flavour): JsonNode =
  let missing = applicability(fs.doc.scenario, fs.doc.pack, fs.helloOf(f))
  var ex = newJArray()
  for m in missing: ex.add %*{"step": m.path, "capability": m.capability}
  %*{"applicable": missing.len == 0, "excludedBy": ex}

# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

proc decodeFrames(video: string): seq[string] =
  ## The video's frames as PNGs at PreviewFps, 640 px wide.
  let ff = getEnv("FFMPEG_BIN", findExe("ffmpeg"))
  # stdout alone: the frames (ffmpeg's few error lines go to stderr, read after)
  let p = startProcess(ff, args = @["-hide_banner", "-loglevel", "error", "-nostdin",
    "-i", video, "-vf", "fps=" & $PreviewFps & ",scale=640:-2", "-f", "image2pipe",
    "-c:v", "png", "-"], options = {})
  let o = p.outputStream.readAll
  let errors = p.errorStream.readAll
  let code = p.waitForExit
  p.close
  if code != 0: raise flavourError("decoding the render: " & errors)
  const sig = "\x89PNG\r\n\x1a\n"
  var i = 0
  while i + 8 <= o.len:
    if o[i ..< i + 8] != sig: raise flavourError("decoding the render: not a PNG stream")
    var j = i + 8
    while true:
      let n = (ord(o[j]) shl 24) or (ord(o[j + 1]) shl 16) or (ord(o[j + 2]) shl 8) or ord(o[j + 3])
      let kind = o[j + 4 ..< j + 8]
      j += 12 + n
      if kind == "IEND": break
    result.add o[i ..< j]
    i = j

proc stripped(s: Step): Step =
  ## A step as a live session runs it on its own: its presentation (which may
  ## anchor to steps not in a one-step scenario) left out.
  result = Step()
  result[] = s[]
  result.hasNarration = false
  result.hasCaption = false
  result.callouts = @[]

proc stageSession(fs: Flavours; r: Resident; upTo: int) =
  ## A new live session for `r`, staged, with the first `upTo` steps run.
  if r.session != nil:
    if r.suspended: fs.resume(r.flavour.name)
    r.session.close()
    r.session = nil
  r.session = spawnJsonLinesBackend(r.flavour.command, r.flavour.args, name = r.flavour.name)
  r.pids = treeOf(newestChild())
  var sc = fs.doc.scenario
  sc.steps = @[]
  let ls = fs.leaves
  for k in 0 ..< upTo: sc.steps.add stripped(fs.doc.step(ls[k]))
  let res = runScenario(sc, fs.doc.pack, r.session,
    RunOptions(mode: tmFast, scenarioDir: fs.doc.path.parentDir))
  if res.outcome != roPassed:
    r.error = "staging '" & r.flavour.name & "': " & res.message
    raise flavourError(r.error)
  r.position = upTo
  r.pids = treeOf(r.pids[0])

proc memoryOf*(r: Resident): int64 = r.framesBytes + rssBytes(r.pids)

proc totalMemory*(fs: Flavours): int64 =
  for _, r in fs.resident: result += r.memoryOf

proc overBudget*(fs: Flavours): bool = fs.totalMemory > fs.budget

proc load*(fs: Flavours; name: string): RenderReport =
  ## Render the flavour, decode the render into memory, and bring up its live
  ## session at the playhead. A render that fails loads nothing.
  let f = fs.flavourNamed(name)
  if name in fs.resident: return fs.resident[name].report
  createDir(fs.renderDir)
  let rep = renderScenario(fs.doc, f, RenderOptions(outPath: fs.renderDir / (name & ".mp4"),
                                                    speech: fs.speech))
  if not rep.ok: return rep
  var r = Resident(flavour: f, report: rep, hashes: fs.doc.stageHashes(f.virtualTiming))
  r.frames = decodeFrames(rep.video)
  for fr in r.frames: r.framesBytes += fr.len
  fs.stageSession(r, fs.leafIndex(fs.playheadStep))
  fs.resident[name] = r
  if fs.displayed == "": fs.displayed = name
  rep

proc unload*(fs: Flavours; name: string) =
  let r = fs.resident.getOrDefault(name)
  if r == nil: return
  if r.suspended: fs.resume(name)
  if r.session != nil: r.session.close()
  fs.resident.del name
  if fs.displayed == name:
    fs.displayed = ""
    for k, _ in fs.resident:
      fs.displayed = k
      break

# ---------------------------------------------------------------------------
# The playhead, the switch and lockstep
# ---------------------------------------------------------------------------

proc setPlayhead*(fs: Flavours; step: string; fraction = 0.0) =
  discard fs.leafIndex(step)
  fs.playheadStep = step
  fs.playheadFraction = min(max(fraction, 0.0), 1.0)

proc view*(fs: Flavours; name: string): JsonNode =
  ## Display flavour `name` at the playhead. Reads only what is resident: no
  ## file, no process, no run.
  let r = fs.resident.getOrDefault(name)
  if r == nil: raise flavourError("'" & name & "' is not loaded")
  fs.displayed = name
  let (a, b) = r.report.stepsMs[fs.playheadStep]
  let t = a + fs.playheadFraction * (b - a)
  let idx = min(r.frames.high, max(0, int(t / 1000 * PreviewFps)))
  let live = r.position == fs.leafIndex(fs.playheadStep) and not r.catchingUp
  %*{"flavour": name, "step": fs.playheadStep, "fraction": fs.playheadFraction,
     "timeMs": t, "frameIndex": idx, "frames": r.frames.len,
     "session": (if r.suspended: "suspended" elif live: "live" else: "catching up"),
     "showing": "render"}

proc frame*(fs: Flavours; name: string): string =
  let r = fs.resident.getOrDefault(name)
  if r == nil: raise flavourError("'" & name & "' is not loaded")
  let (a, b) = r.report.stepsMs[fs.playheadStep]
  let t = a + fs.playheadFraction * (b - a)
  r.frames[min(r.frames.high, max(0, int(t / 1000 * PreviewFps)))]

proc advance*(fs: Flavours): bool =
  ## One unit of lockstep work: drive one live session one step toward the
  ## playhead, or re-stage one that must go back. False when all are there.
  let target = fs.leafIndex(fs.playheadStep)
  for name, r in fs.resident:
    if r.error != "" or r.position == target: continue
    if r.suspended: fs.resume(name)
    if r.position < 0 or target < r.position:
      # a live application cannot go back: stage it again and drive it forward
      r.catchingUp = true
      try: fs.stageSession(r, target)
      except CatchableError as e: r.error = e.msg
      r.catchingUp = false
      return true
    var one = fs.doc.scenario
    one.steps = @[stripped(fs.doc.step(fs.leaves[r.position]))]
    let res = runScenario(one, fs.doc.pack, r.session,
      RunOptions(mode: tmFast, staged: true, scenarioDir: fs.doc.path.parentDir))
    if res.outcome != roPassed:
      r.error = "step " & fs.leaves[r.position] & " on '" & name & "': " & res.message
    else:
      inc r.position
    return true
  false

proc invalidate*(fs: Flavours; changed: seq[string]) =
  ## After an edit: a session whose recording an input edit staled is
  ## re-staged on the scenario as it now is.
  discard changed
  for name, r in fs.resident:
    if fs.doc.stageHashes(r.flavour.virtualTiming)["automation"] != r.hashes["automation"]:
      r.position = -1
      r.error = ""

proc readLive*(fs: Flavours; name, locator: string; props: seq[string]): JsonNode =
  ## Read the live session (for inspection): the instance's properties.
  let r = fs.resident.getOrDefault(name)
  if r == nil: raise flavourError("'" & name & "' is not loaded")
  if r.suspended: raise flavourError("'" & name & "' is suspended")
  let lr = r.session.locate(locatorJson(parseLocator(locator)))
  if lr.outcome != loOne: return %*{"outcome": $lr.outcome}
  result = r.session.read(lr.instance, props)
  result["outcome"] = %"one"

proc statusJson*(fs: Flavours): JsonNode =
  var list = newJArray()
  var rerecord: seq[string]
  for f in fs.available:
    var o = %*{"name": f.name, "virtualTiming": f.virtualTiming, "loaded": f.name in fs.resident}
    try:
      for k, v in fs.applicabilityJson(f): o[k] = v
    except CatchableError as e:
      o["applicable"] = %false
      o["error"] = %e.msg
    let r = fs.resident.getOrDefault(f.name)
    if r != nil:
      r.pids = (if r.suspended: r.pids else: treeOf(r.pids[0]))
      var stale = newJArray()
      let now = fs.doc.stageHashes(f.virtualTiming)
      for k, v in r.hashes:
        if now.getOrDefault(k) != v: stale.add %k
      if "automation" in stale.to(seq[string]): rerecord.add f.name
      o["memoryBytes"] = %r.memoryOf
      o["suspended"] = %r.suspended
      o["position"] = %r.position
      o["catchingUp"] = %r.catchingUp
      o["stale"] = stale
      o["error"] = %r.error
      o["pids"] = %r.pids
    list.add o
  let target = (if fs.playheadStep != "": fs.leafIndex(fs.playheadStep) else: 0)
  var asks = newJArray()
  if fs.overBudget:
    for k, _ in fs.resident: asks.add %k
  %*{"flavours": list, "displayed": fs.displayed,
     "playhead": {"step": fs.playheadStep, "fraction": fs.playheadFraction, "index": target},
     "budgetBytes": fs.budget, "residentBytes": fs.totalMemory,
     "overBudget": fs.overBudget, "unloadOneOf": asks, "rerecord": rerecord}
