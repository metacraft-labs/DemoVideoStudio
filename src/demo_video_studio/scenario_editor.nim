## The studio's scenario editor: the HTTP surface over a `ScenarioDoc`, and
## target picking through a flavour's backend (DemoVideoStudio-Editor §3).
##
## A flavour is a backend reached out of process through its JSON-lines host
## (decision D7): a command line that serves the DemoVideoScript backend
## protocol on stdio. Picking a target asks the flavour which role instance is
## at a point — the protocol's `hit` — in the state the application is in just
## before the step: a session is staged and the steps before it are run, fast.
## The locator recorded is canonical: each segment names its instance by the
## semantic keys its role declares in the pack, and by an ordinal only when it
## has none (§3.3). A point that no role covers, or a role that does not afford
## the step's action, is refused: the fix is in the pack, never a coordinate.
##
## Routes:
##   GET  /api/scenario        the timeline view (`timelineJson`)
##   GET  /api/text            the scenario file as it is on disk
##   GET  /api/stages          each stage's input hash for each flavour
##   GET  /api/still?step=P    the medium just before step P, from the run
##   GET  /api/flavours        the flavours this editor can pick through
##   POST /api/edit            an edit (`applyEdit`); 422 when refused
##   POST /api/pick            {step, x, y, field?, flavour?}; 422 when refused
##   POST /api/avatar          {keyframes: […]} (`setAvatarKeyframes`)
##   GET  /…                   the web UI (`editor-web/scenario.html`)

import std/[asyncdispatch, asynchttpserver, json, options, os, strutils, tables]
import demo_video_script/[backend, jsonlines, runner, grammar, lint]
import ./scenario_doc

type
  Flavour* = object
    name*: string
    command*: string
    args*: seq[string]
    virtualTiming*: bool    ## timing applied at render (a terminal flavour, §4.2)

  ScenarioEditor* = ref object
    doc*: ScenarioDoc
    flavours*: seq[Flavour]
    selected*: string
    webRoot*: string
    server: AsyncHttpServer
    port*: Port

  PickRefused* = object of CatchableError

proc newScenarioEditor*(doc: ScenarioDoc; flavours: seq[Flavour] = @[];
                        webRoot = ""): ScenarioEditor =
  result = ScenarioEditor(doc: doc, flavours: flavours,
                          webRoot: (if webRoot != "": webRoot
                                    else: currentSourcePath().parentDir.parentDir.parentDir /
                                          "editor-web"))
  if flavours.len > 0: result.selected = flavours[0].name

proc flavour*(ed: ScenarioEditor; name: string): Flavour =
  let n = (if name == "": ed.selected else: name)
  for f in ed.flavours:
    if f.name == n: return f
  raise newException(ValueError, "no flavour '" & n & "'")

# ---------------------------------------------------------------------------
# A session staged to just before a step
# ---------------------------------------------------------------------------

proc before(steps: seq[Step]; path: seq[int]): seq[Step] =
  ## The steps that run before the step at `path` (1-based indices).
  let k = path[0] - 1
  result = steps[0 ..< k]
  if path.len > 1:
    let beat = steps[k]
    var copy = Step()
    copy[] = beat[]
    copy.steps = before(beat.steps, path[1 .. ^1])
    copy.hasNarration = false
    copy.hasCaption = false
    copy.callouts = @[]
    result.add copy

proc sessionBefore*(ed: ScenarioEditor; f: Flavour; stepPath: string): Backend =
  ## A live session of flavour `f` with the scenario's stage done and the steps
  ## before `stepPath` run. The caller closes it.
  var idx: seq[int]
  for p in stepPath.split('.'): idx.add parseInt(p)
  var sc = ed.doc.scenario
  sc.steps = before(sc.steps, idx)
  result = spawnJsonLinesBackend(f.command, f.args, name = f.name)
  let res = runScenario(sc, ed.doc.pack, result,
    RunOptions(mode: tmFast, record: rpOff, scenarioDir: ed.doc.path.parentDir))
  if res.outcome != roPassed:
    result.close()
    raise newException(PickRefused, "the steps before " & stepPath & " did not pass on '" &
      f.name & "': " & res.message)

# ---------------------------------------------------------------------------
# Canonical locators
# ---------------------------------------------------------------------------

proc geometryOf(b: Backend; loc: Locator): Option[JsonNode] =
  let r = b.locate(locatorJson(loc))
  if r.outcome != loOne: return none(JsonNode)
  some(b.read(r.instance, @["geometry"])["geometry"])

proc sameGeometry(a, b: JsonNode): bool =
  for k in ["x", "y", "w", "h"]:
    if a{k}.getFloat != b{k}.getFloat: return false
  true

proc chooseSegment*(keyed, ordinal: Option[Segment]; original: Segment): Segment =
  ## Semantic keys over ordinals (DemoVideoScript-Format §4.2): an ordinal
  ## names an instance only when its role has no keys that tell it apart.
  if keyed.isSome: keyed.get
  elif ordinal.isSome: ordinal.get
  else: original

proc canonicalLocator*(b: Backend; doc: ScenarioDoc; text: string): string =
  ## Re-express each segment of `text` (a locator the backend answered) in the
  ## form a scenario should record.
  var loc = parseLocator(text)
  for i in 0 ..< loc.segments.len:
    let seg = loc.segments[i]
    if seg.kind != segRole: continue
    let prefix = Locator(segments: loc.segments[0 .. i])
    let here = b.geometryOf(prefix)
    if here.isNone: continue
    var keyed, ordinal: Option[Segment]
    # the keyed form, from the role's declared keys
    if doc.pack.roles.hasKey(seg.role) and doc.pack.roles[seg.role].keys.len > 0:
      let r = b.locate(locatorJson(prefix))
      if r.outcome == loOne:
        let keys = doc.pack.roles[seg.role].keys
        let vals = b.read(r.instance, keys)
        var kv: seq[KeyValue]
        for k in keys:
          let v = vals{k}
          if v != nil and v.kind in {JString, JInt, JFloat, JBool}:
            kv.add (k, (if v.kind == JString: v.getStr else: $v))
        if kv.len == keys.len:
          var s = Segment(kind: segRole, role: seg.role, keys: kv)
          var cand = Locator(segments: loc.segments[0 ..< i] & @[s])
          let g = b.geometryOf(cand)
          if g.isSome and sameGeometry(g.get, here.get): keyed = some(s)
    # the ordinal form, by position among the parent's instances of the role
    for n in 1 .. 200:
      var s = Segment(kind: segRole, role: seg.role, ordinal: n)
      let g = b.geometryOf(Locator(segments: loc.segments[0 ..< i] & @[s]))
      if g.isNone: break
      if sameGeometry(g.get, here.get):
        # a lone instance needs no ordinal
        let alone = Segment(kind: segRole, role: seg.role)
        let ga = b.geometryOf(Locator(segments: loc.segments[0 ..< i] & @[alone]))
        ordinal = some(if ga.isSome: alone else: s)
        break
    loc.segments[i] = chooseSegment(keyed, ordinal, seg)
  $loc

proc neededAffordance(s: Step; field: string): string =
  case s.kind
  of stClick:
    if s.button == btnRight: "context-click"
    elif s.count >= 2: "double-click"
    else: "click"
  of stDrag: (if field == "from": "drag-source" else: "drop-target")
  of stWheel: "wheel"
  else: ""

proc pick*(ed: ScenarioEditor; stepPath: string; x, y: float; field = "at";
           flavourName = ""): JsonNode =
  ## Record, as step `stepPath`'s target, the role instance at (x, y) on the
  ## flavour's medium (its units: cells or pixels), just before the step.
  let s = ed.doc.step(stepPath)
  let f = ed.flavour(flavourName)
  let b = ed.sessionBefore(f, stepPath)
  var locText: string
  try:
    let h = b.hit(x, y)
    if h.isNone:
      raise newException(PickRefused, "no role covers (" & $x & ", " & $y & ") on '" & f.name &
        "': add the role to the pack (" & ed.doc.packPath & "); a coordinate is never recorded")
    locText = canonicalLocator(b, ed.doc, h.get)
  finally:
    b.close()
  let role = staticRole(ed.doc.pack, parseLocator(locText))
  let need = neededAffordance(s, field)
  if need != "" and ed.doc.pack.roles.hasKey(role):
    var ok = false
    for a in ed.doc.pack.roles[role].affordances:
      if $a == need: ok = true
    if not ok:
      raise newException(PickRefused, "the " & role & " at (" & $x & ", " & $y & ") does not afford '" &
        need & "' in the pack (" & locText & ")")
  let r = ed.doc.applyEdit(%*{"op": "target", "step": stepPath, "locator": locText,
                              "field": field})
  # how the locator resolves on every flavour
  var elsewhere = newJObject()
  for other in ed.flavours:
    try:
      let ob = ed.sessionBefore(other, stepPath)
      try:
        elsewhere[other.name] = %($ob.locate(locatorJson(parseLocator(locText))).outcome)
      finally:
        ob.close()
    except CatchableError as e:
      elsewhere[other.name] = %("error: " & e.msg)
  %*{"ok": true, "locator": locText, "role": role, "class": $r.class,
     "invalidated": r.invalidated, "resolves": elsewhere}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

proc stagesJson*(ed: ScenarioEditor): JsonNode =
  result = newJObject()
  let fl = (if ed.flavours.len > 0: ed.flavours else: @[Flavour(name: "default")])
  for f in fl:
    var o = newJObject()
    for k, v in ed.doc.stageHashes(f.virtualTiming): o[k] = %v
    result[f.name] = o

proc respondJson(req: Request; code: HttpCode; body: JsonNode): Future[void] =
  req.respond(code, $body, newHttpHeaders([("Content-Type", "application/json"),
                                           ("Cache-Control", "no-store")]))

proc refused(req: Request; e: ref CatchableError; diags: JsonNode = nil): Future[void] =
  var b = %*{"ok": false, "error": e.msg}
  if diags != nil: b["diagnostics"] = diags
  respondJson(req, Http422, b)

proc editJson(r: EditResult): JsonNode =
  var diags = newJArray()
  for x in r.diagnostics: diags.add %($x)
  %*{"ok": true, "class": $r.class, "invalidated": r.invalidated, "diagnostics": diags}

proc contentType(path: string): string =
  case path.splitFile.ext
  of ".html": "text/html; charset=utf-8"
  of ".js": "text/javascript"
  of ".css": "text/css"
  of ".png": "image/png"
  of ".svg": "image/svg+xml"
  else: "application/octet-stream"

proc dispatch(ed: ScenarioEditor; req: Request) {.async.} =
  let path = req.url.path
  try:
    case req.reqMethod
    of HttpGet:
      case path
      of "/api/scenario":
        var j = ed.doc.timelineJson
        j["selected"] = %ed.selected
        await respondJson(req, Http200, j)
      of "/api/text":
        await req.respond(Http200, ed.doc.text,
                          newHttpHeaders([("Content-Type", "text/yaml; charset=utf-8")]))
      of "/api/stages": await respondJson(req, Http200, ed.stagesJson)
      of "/api/still":
        var step = ""
        for kv in req.url.query.split('&'):
          if kv.startsWith("step="): step = kv[5 .. ^1]
        try:
          await respondJson(req, Http200, %*{"units": ed.doc.units,
                                             "text": ed.doc.stillBefore(step)})
        except EditError as e: await refused(req, e)
      of "/api/flavours":
        var a = newJArray()
        for f in ed.flavours: a.add %*{"name": f.name, "virtualTiming": f.virtualTiming}
        await respondJson(req, Http200, %*{"flavours": a, "selected": ed.selected})
      else:
        var p = (if path == "/" or path == "": "/scenario.html" else: path)
        if p.contains(".."):
          await req.respond(Http404, "not found")
          return
        let abs = ed.webRoot / p[1 .. ^1]
        if not fileExists(abs):
          await req.respond(Http404, "not found")
          return
        await req.respond(Http200, readFile(abs),
                          newHttpHeaders([("Content-Type", contentType(abs))]))
    of HttpPost:
      let body = (if req.body.len > 0: parseJson(req.body) else: newJObject())
      case path
      of "/api/edit":
        try:
          await respondJson(req, Http200, editJson(ed.doc.applyEdit(body)))
        except EditError as e:
          var diags = newJArray()
          for x in e.diagnostics: diags.add %($x)
          await refused(req, e, diags)
      of "/api/pick":
        try:
          await respondJson(req, Http200, ed.pick(body{"step"}.getStr, body{"x"}.getFloat,
                            body{"y"}.getFloat, body{"field"}.getStr("at"),
                            body{"flavour"}.getStr))
        except PickRefused as e: await refused(req, e)
        except EditError as e: await refused(req, e)
      of "/api/avatar":
        try:
          await respondJson(req, Http200, editJson(ed.doc.setAvatarKeyframes(body{"keyframes"})))
        except EditError as e: await refused(req, e)
      else: await req.respond(Http404, "not found")
    else: await req.respond(Http405, "method not allowed")
  except CatchableError as e:
    await respondJson(req, Http500, %*{"ok": false, "error": e.msg})

proc start*(ed: ScenarioEditor; port = 0) =
  ed.server = newAsyncHttpServer()
  ed.server.listen(Port(port))
  ed.port = ed.server.getPort

proc pumpOnce*(ed: ScenarioEditor): Future[bool] {.async.} =
  ## Serve one request if one is waiting. False once stopped.
  if ed.server == nil: return false
  if ed.server.shouldAcceptRequest():
    # one thread serves; the document is not shared across threads
    await ed.server.acceptRequest(proc (req: Request): Future[void] {.async, gcsafe.} =
      {.cast(gcsafe).}:
        await dispatch(ed, req))
    return true
  await sleepAsync(10)
  true

proc serveForever*(ed: ScenarioEditor) =
  while ed.server != nil:
    discard waitFor ed.pumpOnce()

proc stop*(ed: ScenarioEditor) =
  if ed.server != nil:
    ed.server.close()
    ed.server = nil
