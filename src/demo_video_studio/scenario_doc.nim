## The scenario document the studio edits (DemoVideoStudio-Editor §3).
##
## The editor's document is a DemoVideoScript scenario file. Every edit is
## written back to that file as the abstract values the format has — a step's
## `dwell` or `lead-in`, its pacing, a span's `from` / `to` anchor, a target's
## locator — never as a time: a time on the timeline is a measurement from a
## flavour's run (`attachRun`), and an edit made against it is converted to
## those values here.
##
## Edits are patches of the file's text at the positions the YAML reader
## reports, so everything an edit does not touch — comments, key order, quoting,
## blank lines — stays byte for byte. After each edit the file is parsed and
## linted again; an edit that would introduce a lint error is refused and the
## file is left as it was.
##
## Each edit is classified (§3.4): a *semantic* edit changes what the
## application does (a target, a chord, a step added or removed) and stales
## every flavour's `automation` stage; a *timing* edit (pacing, `dwell`,
## `lead-in`) stales the stages that read timing; a *narration* or
## *presentation* edit stales only the stages that read it. What is stale is
## not decided by the class but measured: `stageHashes` hashes exactly the part
## of the scenario each stage reads, and an edit reports the stages whose hash
## changed.

import std/[hashes, json, os, strutils, tables]
import demo_video_script/[model, yaml, scenario, lint, emit, pack]
import ./artifact_project

export model

type
  EditError* = object of CatchableError
    diagnostics*: Diagnostics

  EditClass* = enum
    ecSemantic = "semantic"
    ecTiming = "timing"
    ecNarration = "narration"
    ecPresentation = "presentation"

  MeasuredStep* = object
    path*: string
    startMs*, endMs*: float          ## relative to the run's first step

  ScenarioDoc* = ref object
    path*: string
    packPath*: string
    text*: string
    root*: YNode
    scenario*: Scenario
    pack*: Pack
    diagnostics*: Diagnostics
    run*: seq[MeasuredStep]          ## the selected flavour's last run; empty when none
    stills*: seq[(string, string)]   ## (step path as run, its text still), in run order
    units*: string                   ## the run's medium: "cell" or "px"
    runBackend*: string
    nodes: Table[string, YNode]      ## step path -> the step's mapping node
    steps: Table[string, Step]
    order: seq[string]               ## step paths in file order

  EditResult* = object
    class*: EditClass
    invalidated*: seq[string]        ## stage names whose input hash changed
    diagnostics*: Diagnostics

proc editError(msg: string; diags: Diagnostics = @[]): ref EditError =
  result = newException(EditError, msg)
  result.diagnostics = diags

# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

proc index(d: ScenarioDoc; items: YNode; steps: seq[Step]; prefix: string) =
  if items == nil or items.kind != ySeq: return
  if items.items.len != steps.len:
    raise editError("the steps of '" & d.path & "' did not parse one for one")
  for k, s in steps:
    let path = prefix & $(k + 1)
    let n = items.items[k]
    if s == nil or n.kind != yMap or s.line != n.line:
      raise editError("step " & path & " of '" & d.path & "' did not parse")
    d.nodes[path] = n
    d.steps[path] = s
    d.order.add path
    if s.kind == stBeat:
      d.index(n.get("steps"), s.steps, path & ".")

proc parseText(d: ScenarioDoc; text: string): Diagnostics =
  ## Read, parse and lint `text` into `d`. Raises `EditError` when the text is
  ## not a readable scenario.
  var root: YNode
  try:
    root = readYaml(text)
  except YamlError as e:
    raise editError("the scenario is not readable YAML: " & e.msg)
  let (sc, diags) = parseScenarioNode(root, d.path)
  var all = diags
  if not diags.hasStructuralErrors and d.pack != nil:
    all.add lintScenario(sc, d.pack)
  d.text = text
  d.root = root
  d.scenario = sc
  d.diagnostics = all
  d.nodes.clear
  d.steps.clear
  d.order.setLen 0
  if not diags.hasStructuralErrors:
    d.index(root.get("steps"), sc.steps, "")
  all

proc loadScenarioDoc*(path, packPath: string): ScenarioDoc =
  result = ScenarioDoc(path: path, packPath: packPath)
  let (pk, pdiags) = parsePackFile(packPath)
  if pdiags.hasErrors:
    raise editError("the pack '" & packPath & "' has errors", pdiags)
  result.pack = pk
  discard result.parseText(readFile(path))

proc stepPaths*(d: ScenarioDoc): seq[string] = d.order
proc step*(d: ScenarioDoc; path: string): Step =
  if path notin d.steps: raise editError("no step " & path)
  d.steps[path]

# ---------------------------------------------------------------------------
# The selected flavour's run: where the timeline's times come from
# ---------------------------------------------------------------------------

proc attachRun*(d: ScenarioDoc; manifestPath: string) =
  ## Lay the timeline out on a run's measured step times (a run directory's
  ## `manifest.json`). Steps inside a flow or an alternative are measured on
  ## the step that calls them.
  let m = parseFile(manifestPath)
  d.run.setLen 0
  let be = m{"backend"}
  d.runBackend = (if be != nil and be.kind == JObject: be{"backend"}.getStr else: be.getStr)
  d.units = (if be != nil and be.kind == JObject: be{"units"}.getStr("px") else: "px")
  d.stills.setLen 0
  var t0 = -1.0
  var byPath = initOrderedTable[string, MeasuredStep]()
  for s in m{"steps"}.getElems:
    if s{"status"}.getStr == "not-run": continue
    for a in s{"artifacts"}.getElems:
      if a.getStr.endsWith(".txt"):
        let f = (if a.getStr.isAbsolute: a.getStr else: manifestPath.parentDir / a.getStr)
        if fileExists(f): d.stills.add (s{"path"}.getStr, readFile(f))
    var p = s{"path"}.getStr
    for sep in [">", "~"]:
      let i = p.find(sep)
      if i >= 0: p = p[0 ..< i]
    let a = s{"startMs"}.getFloat
    let b = s{"endMs"}.getFloat
    if t0 < 0: t0 = a
    if p in byPath:
      byPath[p].endMs = max(byPath[p].endMs, b - t0)
    else:
      byPath[p] = MeasuredStep(path: p, startMs: a - t0, endMs: b - t0)
  for _, v in byPath: d.run.add v

proc measured*(d: ScenarioDoc; path: string): MeasuredStep =
  for m in d.run:
    if m.path == path: return m
  # a beat spans its steps
  var found = false
  for m in d.run:
    if m.path.startsWith(path & "."):
      if not found:
        result = MeasuredStep(path: path, startMs: m.startMs, endMs: m.endMs)
        found = true
      else:
        result.startMs = min(result.startMs, m.startMs)
        result.endMs = max(result.endMs, m.endMs)
  if not found:
    raise editError("step " & path & " has no measurement in the selected flavour's run")

proc stillBefore*(d: ScenarioDoc; path: string): string =
  ## The medium as it was just before step `path` ran: the text still of the
  ## step run before it (or, for the first, its own).
  var prev = ""
  for (p, text) in d.stills:
    if p == path or p.startsWith(path & ".") or p.startsWith(path & ">"):
      return (if prev != "": prev else: text)
    prev = text
  raise editError("the selected flavour's run has no still before step " & path)

proc stepAt*(d: ScenarioDoc; ms: float): string =
  ## The step the timeline shows at `ms`: the last one started by then.
  if d.run.len == 0:
    raise editError("no run is selected: a point on the timeline has no step")
  result = d.run[0].path
  for m in d.run:
    if m.startMs <= ms: result = m.path

# ---------------------------------------------------------------------------
# Text positions
# ---------------------------------------------------------------------------

proc lineStarts(t: string): seq[int] =
  result = @[0]
  for i, c in t:
    if c == '\n': result.add i + 1

proc offsetOf(t: string; n: YNode): int =
  let ls = lineStarts(t)
  ls[n.line - 1] + n.col - 1

proc lineEnd(t: string; at: int): int =
  result = at
  while result < t.len and t[result] != '\n': inc result

proc lineNo(t: string; at: int): int =
  result = 1
  for i in 0 ..< min(at, t.len):
    if t[i] == '\n': inc result

proc scanQuoted(t: string; at: int): int =
  ## `at` is on an opening quote; returns the offset after the closing one.
  var i = at + 1
  if t[at] == '"':
    while i < t.len and t[i] != '"':
      if t[i] == '\\': inc i
      inc i
    return i + 1
  while i < t.len:
    if t[i] == '\'':
      if i + 1 < t.len and t[i + 1] == '\'': i += 2
      else: return i + 1
    else: inc i
  i

proc scanValueEnd(t: string; at: int; flow: bool): int =
  ## The end (exclusive) of the scalar or flow collection that starts at `at`.
  case t[at]
  of '{', '[':
    var depth = 0
    var i = at
    var prev = ' '
    while i < t.len:
      let c = t[i]
      if c in {'"', '\''} and prev in {'{', '[', ',', ':', ' '}:
        i = scanQuoted(t, i)
        prev = 'x'
        continue
      if c in {'{', '['}: inc depth
      elif c in {'}', ']'}:
        dec depth
        if depth == 0: return i + 1
      if c notin {' ', '\n'}: prev = c
      elif c == ' ' and prev in {',', ':', '{', '['}: discard
      else: prev = ' '
      inc i
    raise editError("an unterminated flow collection at line " & $lineNo(t, at))
  of '"', '\'': scanQuoted(t, at)
  of '|', '>':
    raise editError("a block scalar at line " & $lineNo(t, at) & " is edited in the file, not here")
  else:
    var i = at
    while i < t.len and t[i] != '\n':
      if t[i] == '#' and i > at and t[i - 1] == ' ': break
      if flow and t[i] in {',', '}', ']'}: break
      inc i
    while i > at and t[i - 1] == ' ': dec i
    i

proc keyColon(t: string; key: YNode): int =
  ## The offset of the `:` after a mapping key.
  var i = offsetOf(t, key)
  if t[i] in {'"', '\''}: i = scanQuoted(t, i)
  while i < t.len and not (t[i] == ':' and (i + 1 >= t.len or t[i + 1] in {' ', '\n'})):
    inc i
  i

proc isFlow(t: string; n: YNode): bool = t[offsetOf(t, n)] in {'{', '['}

proc indentOfLine(line: string): int =
  while result < line.len and line[result] == ' ': inc result

proc extentLastLine(t: string; key, value: YNode): int =
  ## The last line (1-based) that belongs to `key: value` in a block mapping.
  let lines = t.split('\n')
  let vOff = offsetOf(t, value)
  let inline = value.line == key.line and value.kind notin {yMap, ySeq} and
    t[vOff] notin {'|', '>'}
  let inlineFlow = value.line == key.line and t[vOff] in {'{', '['}
  if inline or inlineFlow:
    return lineNo(t, scanValueEnd(t, vOff, false) - 1)
  let c = key.col - 1
  result = key.line
  for ln in key.line + 1 .. lines.len:
    let s = lines[ln - 1]
    let st = s.strip
    if st.len == 0 or st.startsWith("#"): continue
    let ind = indentOfLine(s)
    if ind > c or (ind == c and value.kind == ySeq and (st == "-" or st.startsWith("- "))):
      result = ln
    else: break

proc mapLastLine(t: string; m: YNode): int =
  if isFlow(t, m): return lineNo(t, scanValueEnd(t, offsetOf(t, m), true) - 1)
  extentLastLine(t, m.keys[^1], m.values[^1])

proc replaceRange(t: string; a, b: int; s: string): string = t[0 ..< a] & s & t[b .. ^1]

proc lineRange(t: string; first, last: int): (int, int) =
  ## Offsets covering lines first..last including the final newline.
  let ls = lineStarts(t)
  let a = ls[first - 1]
  let b = (if last < ls.len: ls[last] else: t.len)
  (a, b)

# ---------------------------------------------------------------------------
# Text primitives on mapping nodes. Each returns the new text.
# ---------------------------------------------------------------------------

proc keyIndex(m: YNode; key: string): int =
  for i, k in m.keys:
    if k.s == key: return i
  -1

proc setKeyText(t: string; m: YNode; key, value: string): string =
  ## `key: value` in mapping `m` (block or flow), replacing the value's text
  ## when the key is present and adding the key after the last one when not.
  let i = m.keyIndex(key)
  if isFlow(t, m):
    if i >= 0:
      let a = offsetOf(t, m.values[i])
      return replaceRange(t, a, scanValueEnd(t, a, true), value)
    let close = scanValueEnd(t, offsetOf(t, m), true) - 1
    var k = close - 1
    while k > 0 and t[k] in {' ', '\n'}: dec k
    let sep = (if t[k] == '{': " " else: ", ")
    return replaceRange(t, k + 1, close, sep & key & ": " & value & " ")
  if i >= 0:
    let v = m.values[i]
    let vOff = offsetOf(t, v)
    if v.line == m.keys[i].line and v.kind != yNull and t[vOff] notin {'|', '>'} and
        not (v.kind in {yMap, ySeq} and not isFlow(t, v)):
      return replaceRange(t, vOff, scanValueEnd(t, vOff, false), value)
    # a block value (or none): the key's whole extent becomes one line
    let colon = keyColon(t, m.keys[i])
    let last = extentLastLine(t, m.keys[i], v)
    let ls = lineStarts(t)
    let stop = lineEnd(t, ls[last - 1])
    return replaceRange(t, colon + 1, stop, " " & value)
  let last = mapLastLine(t, m)
  let ls = lineStarts(t)
  let at = lineEnd(t, ls[last - 1])
  replaceRange(t, at, at, "\n" & spaces(m.keys[0].col - 1) & key & ": " & value)

proc removeKeyText(t: string; m: YNode; key: string): string =
  let i = m.keyIndex(key)
  if i < 0: return t
  if isFlow(t, m):
    let a = offsetOf(t, m.keys[i])
    let e = scanValueEnd(t, offsetOf(t, m.values[i]), true)
    if i + 1 < m.keys.len:
      return replaceRange(t, a, offsetOf(t, m.keys[i + 1]), "")
    if i > 0:
      let pe = scanValueEnd(t, offsetOf(t, m.values[i - 1]), true)
      return replaceRange(t, pe, e, "")
    return replaceRange(t, a, e, "")
  if i == 0:
    raise editError("'" & key & "' is what the step is; it cannot be removed")
  let (a, b) = lineRange(t, m.keys[i].line, extentLastLine(t, m.keys[i], m.values[i]))
  replaceRange(t, a, b, "")

proc sourceOf(t: string; n: YNode; flow: bool): string =
  let a = offsetOf(t, n)
  t[a ..< scanValueEnd(t, a, flow)]

# ---------------------------------------------------------------------------
# Values as YAML text
# ---------------------------------------------------------------------------

proc yamlString(s: string): string =
  ## A string as a YAML double-quoted scalar (YAML's escapes include JSON's).
  $(%s)

proc yamlLocator(s: string): string =
  ## A locator, quoted (DemoVideoScript decision D1): single quotes, so the
  ## double quotes of its key values need no escaping.
  "'" & s.replace("'", "''") & "'"

proc yamlValue(j: JsonNode): string =
  case j.kind
  of JString: yamlString(j.getStr)
  of JInt, JFloat, JBool: $j
  of JObject:
    var parts: seq[string]
    for k, v in j: parts.add k & ": " & yamlValue(v)
    "{ " & parts.join(", ") & " }"
  of JArray:
    var parts: seq[string]
    for v in j: parts.add yamlValue(v)
    "[" & parts.join(", ") & "]"
  of JNull: "null"

# ---------------------------------------------------------------------------
# Stage inputs: what each render stage reads
# ---------------------------------------------------------------------------

const
  PresentationKeys = ["id", "lead-in", "dwell", "chapter", "narration", "caption", "callout"]
  TimingKeys = ["lead-in", "dwell"]
  PayloadTimingKeys = ["pace", "for"]

proc stripped(steps: JsonNode; drop: openArray[string]; dropPayload: openArray[string]): JsonNode =
  result = newJArray()
  for s in steps:
    var o = newJObject()
    for k, v in s:
      if k in drop: continue
      if k == "steps": o[k] = stripped(v, drop, dropPayload)
      elif k == "alternatives":
        var a = newJObject()
        for g, alt in v: a[g] = stripped(alt, drop, dropPayload)
        o[k] = a
      elif v.kind == JObject:
        var p = newJObject()
        for pk, pv in v:
          if pk notin dropPayload: p[pk] = pv
        o[k] = p
      else: o[k] = v
    result.add o

proc semanticSig(sc: Scenario): JsonNode =
  ## What the application is made to do: the stage and the steps without
  ## their presentation and timing annotations.
  result = emitScenario(sc)
  result["steps"] = stripped(result["steps"], PresentationKeys, PayloadTimingKeys)
  result.delete("summary")

proc flat(steps: seq[Step]; prefix = ""): seq[(string, Step)] =
  for k, s in steps:
    let path = prefix & $(k + 1)
    result.add (path, s)
    if s.kind == stBeat: result.add flat(s.steps, path & ".")

proc timingSig(sc: Scenario): JsonNode =
  result = newJObject()
  for (path, s) in flat(sc.steps):
    let e = emitStep(s)
    var o = newJObject()
    for k in TimingKeys:
      if e.hasKey(k): o[k] = e[k]
    for _, v in e:
      if v.kind == JObject:
        for k in PayloadTimingKeys:
          if v.hasKey(k): o[k] = v[k]
    if o.len > 0: result[path] = o

proc narrationSig(sc: Scenario): JsonNode =
  result = newJObject()
  for (path, s) in flat(sc.steps):
    if s.hasNarration:
      result[path] = %*{"text": s.narration.text, "voice": s.narration.voice,
                        "from": s.narration.fromId, "to": s.narration.toId,
                        "id": s.id, "beat": (if s.kind == stBeat: s.name else: "")}

proc presentationSig(sc: Scenario): JsonNode =
  result = newJObject()
  for (path, s) in flat(sc.steps):
    let e = emitStep(s)
    var o = newJObject()
    for k in ["id", "chapter", "caption", "callout"]:
      if e.hasKey(k): o[k] = e[k]
    if o.len > 0: result[path] = o

proc avatarPath*(d: ScenarioDoc): string = projectDir(d.path) / "avatar.json"

proc hashOf(j: JsonNode): string = toHex(int64(hash($j)), 16).toLowerAscii

proc stageHashes*(d: ScenarioDoc; virtualTiming = false): OrderedTable[string, string] =
  ## The input hash of each render stage for one flavour. `virtualTiming`: the
  ## flavour applies timing at render (a terminal flavour, §4.2), so its
  ## recording does not read the pacing.
  let sc = d.scenario
  let sem = semanticSig(sc)
  let timing = timingSig(sc)
  let narration = narrationSig(sc)
  let avatar = (if fileExists(d.avatarPath): parseFile(d.avatarPath) else: newJNull())
  result["automation"] =
    if virtualTiming: hashOf(%*{"semantic": sem})
    else: hashOf(%*{"semantic": sem, "timing": timing})
  result["local-audio"] = hashOf(%*{"narration": narration})
  result["local-head"] = hashOf(%*{"narration": narration})
  result["commercial-audio"] = hashOf(%*{"narration": narration})
  result["commercial-head"] = hashOf(%*{"narration": narration})
  result["final"] = hashOf(%*{"semantic": sem, "timing": timing, "narration": narration,
                              "presentation": presentationSig(sc), "avatar": avatar})

proc changedStages(a, b: OrderedTable[string, string]): seq[string] =
  for k, v in a:
    if b.getOrDefault(k) != v: result.add k

# ---------------------------------------------------------------------------
# Edits
# ---------------------------------------------------------------------------

proc errorsOf(ds: Diagnostics): seq[string] =
  for x in ds:
    if x.severity == sevError: result.add x.rule & ": " & x.message

proc commit(d: ScenarioDoc; newText: string; before: string) =
  ## Re-parse and lint the edited text; refuse it when it is unreadable or adds
  ## an error the file did not have. The file is written only when accepted.
  let had = d.diagnostics.errorsOf
  var diags: Diagnostics
  try:
    diags = d.parseText(newText)
  except EditError as e:
    discard d.parseText(before)
    raise e
  var added: Diagnostics
  for x in diags:
    if x.severity == sevError and (x.rule & ": " & x.message) notin had: added.add x
  if added.len > 0:
    discard d.parseText(before)
    var msgs: seq[string]
    for x in added: msgs.add $x
    raise editError("the edit was refused: " & msgs.join("; "), added)

proc mapOf(d: ScenarioDoc; path: string): YNode =
  if path notin d.nodes: raise editError("no step " & path)
  d.nodes[path]

proc payloadKey(s: Step): string =
  case s.kind
  of stBeat: "beat"
  else: $s.kind

proc existingIds(d: ScenarioDoc): seq[string] =
  for p in d.order:
    let s = d.steps[p]
    if s.id != "": result.add s.id
    if s.kind == stBeat: result.add s.name

proc anchorName*(d: ScenarioDoc; path: string): string =
  ## The name a span uses to anchor to step `path`: its id, or a beat's name.
  ## A step without one is given an id (written to the file).
  let s = d.step(path)
  if s.kind == stBeat: return s.name
  if s.id != "": return s.id
  let taken = d.existingIds
  var base = $s.kind & "-" & path.replace(".", "-")
  var name = base
  var n = 2
  while name in taken:
    name = base & "-" & $n
    inc n
  let before = d.text
  d.commit(setKeyText(d.text, d.mapOf(path), "id", name), before)
  name

proc spanNode(d: ScenarioDoc; path, span: string): YNode =
  d.mapOf(path).get(span)

proc setSpanKey(d: ScenarioDoc; path, span, key, value: string) =
  let before = d.text
  let m = d.mapOf(path)
  let sn = m.get(span)
  if sn == nil:
    if key != "text":
      raise editError("step " & path & " has no " & span & "; give it a text first")
    d.commit(setKeyText(d.text, m, span, "{ text: " & value & " }"), before)
    return
  if sn.kind != yMap: raise editError("the " & span & " of step " & path & " is not a mapping")
  d.commit(setKeyText(d.text, sn, key, value), before)

proc setPayloadKey(d: ScenarioDoc; path, key, value: string; primary: string) =
  ## A key of the step's payload (`click: { at: …, pace: … }`). A scalar payload
  ## is first written as a mapping of its `primary` field, keeping its text.
  let before = d.text
  let m = d.mapOf(path)
  let s = d.step(path)
  let pk = payloadKey(s)
  let v = m.get(pk)
  if v == nil: raise editError("step " & path & " has no '" & pk & "'")
  if v.kind == yMap:
    d.commit(setKeyText(d.text, v, key, value), before)
    return
  if primary == "":
    raise editError("the '" & pk & "' of step " & path & " has no '" & key & "'")
  if key == primary:
    d.commit(setKeyText(d.text, m, pk, value), before)
    return
  let orig = sourceOf(d.text, v, false)
  d.commit(setKeyText(d.text, m, pk, "{ " & primary & ": " & orig & ", " & key & ": " &
           value & " }"), before)

proc primaryOf(s: Step): string =
  case s.kind
  of stType: "text"
  of stMove, stHover, stClick, stWheel: "at"
  of stKey: "key"
  else: ""

proc nextPath(d: ScenarioDoc; path: string): string =
  let i = d.order.find(path)
  # the next step at the same level
  let parts = path.split('.')
  var p = parts
  p[^1] = $(parseInt(parts[^1]) + 1)
  let cand = p.join(".")
  if cand in d.steps: return cand
  if i >= 0 and i + 1 < d.order.len: return d.order[i + 1]
  ""

proc applyEdit*(d: ScenarioDoc; req: JsonNode): EditResult =
  ## Apply one edit request to the document and write the file. Requests:
  ##
  ## - `{op: "narration"|"caption", step, text?, voice?, style?}`
  ## - `{op: "anchor", span: "narration"|"caption", step, edge: "from"|"to",
  ##    to: <step path>}` or `atMs` (a point on the selected flavour's timeline)
  ## - `{op: "gap", after: <step path>, deltaMs | startMs, side?: "dwell"|"lead-in"}`:
  ##   the next step starts `deltaMs` later (or at `startMs` on the timeline)
  ## - `{op: "dwell"|"lead-in", step, ms}`
  ## - `{op: "pace", step, pace: <preset> | {…}}`
  ## - `{op: "target", step, locator, field?: "at"|"from"|"to"}`
  ## - `{op: "text", step, text}`, `{op: "chord", step, chord}`, `{op: "key", step, key}`
  ## - `{op: "delete", step}`, `{op: "insert", after|before: <step path>, yaml}`
  let before = d.text
  let hashesBefore = d.stageHashes
  let op = req{"op"}.getStr
  let path = req{"step"}.getStr
  case op
  of "narration", "caption":
    result.class = (if op == "narration": ecNarration else: ecPresentation)
    discard d.step(path)
    if req.hasKey("text"): d.setSpanKey(path, op, "text", yamlString(req["text"].getStr))
    for k in ["voice", "style"]:
      if req.hasKey(k): d.setSpanKey(path, op, k, yamlString(req[k].getStr))
  of "anchor":
    let span = req{"span"}.getStr("narration")
    result.class = (if span == "narration": ecNarration else: ecPresentation)
    let edge = req{"edge"}.getStr
    if edge notin ["from", "to"]: raise editError("an anchor edge is 'from' or 'to'")
    if d.spanNode(path, span) == nil: raise editError("step " & path & " has no " & span)
    let target =
      if req.hasKey("to"): req["to"].getStr
      elif req.hasKey("atMs"): d.stepAt(req["atMs"].getFloat)
      else: raise editError("an anchor names a step ('to') or a point ('atMs')")
    let name = d.anchorName(target)
    d.setSpanKey(path, span, edge, name)
  of "gap":
    result.class = ecTiming
    let after = req{"after"}.getStr
    let s = d.step(after)
    let nxt = d.nextPath(after)
    let side = req{"side"}.getStr("dwell")
    var delta: int64
    if req.hasKey("deltaMs"): delta = req["deltaMs"].getBiggestInt
    elif req.hasKey("startMs"):
      if nxt == "": raise editError("step " & after & " is the last; there is no gap after it")
      delta = int64(req["startMs"].getFloat - d.measured(nxt).startMs + 0.5)
    else: raise editError("a gap edit gives 'deltaMs' or 'startMs'")
    if side == "dwell":
      let cur = max(s.dwell, 0)
      d.commit(setKeyText(d.text, d.mapOf(after), "dwell", formatDuration(max(cur + delta, 0))),
               before)
    elif side == "lead-in":
      if nxt == "": raise editError("step " & after & " is the last; there is no step to lead in")
      let n = d.step(nxt)
      let cur = max(n.leadIn, 0)
      d.commit(setKeyText(d.text, d.mapOf(nxt), "lead-in", formatDuration(max(cur + delta, 0))),
               before)
    else: raise editError("a gap's side is 'dwell' or 'lead-in'")
  of "dwell", "lead-in":
    result.class = ecTiming
    discard d.step(path)
    let ms = req{"ms"}.getBiggestInt(-1)
    if ms < 0: raise editError("'" & op & "' takes 'ms', a duration of zero or more")
    d.commit(setKeyText(d.text, d.mapOf(path), op, formatDuration(ms)), before)
  of "pace":
    result.class = ecTiming
    let s = d.step(path)
    if s.kind notin {stType, stMove, stHover, stClick, stDrag}:
      raise editError("a " & $s.kind & " step has no pacing")
    let p = req{"pace"}
    if p == nil: raise editError("'pace' takes a preset name or parameters")
    d.setPayloadKey(path, "pace", (if p.kind == JString: p.getStr else: yamlValue(p)), s.primaryOf)
  of "target":
    result.class = ecSemantic
    let s = d.step(path)
    let field = req{"field"}.getStr("at")
    let loc = req{"locator"}.getStr
    if loc == "": raise editError("'target' takes a locator")
    if s.kind == stDrag:
      if field notin ["from", "to"]: raise editError("a drag's target is its 'from' or 'to'")
      d.setPayloadKey(path, field, yamlLocator(loc), "")
    elif s.kind in PointerTargetKinds or (s.kind in {stPress, stRelease} and s.isButton):
      if field != "at": raise editError("a " & $s.kind & " step's target is its 'at'")
      d.setPayloadKey(path, "at", yamlLocator(loc), s.primaryOf)
    else: raise editError("a " & $s.kind & " step has no target")
  of "text":
    result.class = ecSemantic
    let s = d.step(path)
    if s.kind != stType: raise editError("only a type step has text")
    d.setPayloadKey(path, "text", yamlString(req{"text"}.getStr), "text")
  of "chord", "key":
    result.class = ecSemantic
    let s = d.step(path)
    if $s.kind != op: raise editError("step " & path & " is not a " & op & " step")
    d.commit(setKeyText(d.text, d.mapOf(path), op, yamlString(req{op}.getStr)), before)
  of "delete":
    result.class = ecSemantic
    let n = d.mapOf(path)
    let first = n.line
    let last = mapLastLine(d.text, n)
    let (a, b) = lineRange(d.text, first, last)
    d.commit(replaceRange(d.text, a, b, ""), before)
  of "insert":
    result.class = ecSemantic
    let yamlText = req{"yaml"}.getStr.strip(leading = false)
    if yamlText.len == 0: raise editError("'insert' takes the step's YAML")
    let ref0 = (if req.hasKey("after"): req["after"].getStr else: req{"before"}.getStr)
    let n = d.mapOf(ref0)
    let dash = n.col - 3
    var lines = yamlText.split('\n')
    var blk = spaces(dash) & "- " & lines[0]
    for l in lines[1 .. ^1]: blk.add "\n" & spaces(dash + 2) & l
    let ls = lineStarts(d.text)
    if req.hasKey("after"):
      let at = lineEnd(d.text, ls[mapLastLine(d.text, n) - 1])
      d.commit(replaceRange(d.text, at, at, "\n" & blk), before)
    else:
      let at = ls[n.line - 1]
      d.commit(replaceRange(d.text, at, at, blk & "\n"), before)
  else:
    raise editError("unknown edit '" & op & "'")
  writeFile(d.path, d.text)
  result.invalidated = changedStages(hashesBefore, d.stageHashes)
  result.diagnostics = d.diagnostics

# ---------------------------------------------------------------------------
# Avatar keyframes: canvas geometry, at times relative to a step (§3.2)
# ---------------------------------------------------------------------------

proc checkRect(j: JsonNode; what: string) =
  if j == nil or j.kind != JObject: raise editError("an avatar keyframe needs '" & what & "'")
  for k in ["x", "y", "w", "h"]:
    if not j.hasKey(k) or j[k].kind notin {JInt, JFloat}:
      raise editError("'" & what & "' needs a numeric '" & k & "' (canvas pixels)")

proc setAvatarKeyframes*(d: ScenarioDoc; frames: JsonNode): EditResult =
  ## Replace the avatar keyframes. Each is `{anchor: <step path>, offsetMs}` or
  ## `{atMs}` (a point on the selected flavour's timeline), with `srcCrop` and
  ## `dstRect` in canvas pixels; stored as `{anchor: <step name>, offset:
  ## <duration>, srcCrop, dstRect}` in the project's `avatar.json`.
  result.class = ecPresentation
  let hashesBefore = d.stageHashes
  var stored = newJArray()
  for f in frames:
    checkRect(f{"srcCrop"}, "srcCrop")
    checkRect(f{"dstRect"}, "dstRect")
    var path, offset: string
    var off: float
    if f.hasKey("atMs"):
      path = d.stepAt(f["atMs"].getFloat)
      off = f["atMs"].getFloat - d.measured(path).startMs
    elif f.hasKey("anchor"):
      path = f["anchor"].getStr
      off = f{"offsetMs"}.getFloat(0)
    else: raise editError("an avatar keyframe gives 'anchor' or 'atMs'")
    if off < 0: raise editError("an avatar keyframe's offset is not negative")
    offset = formatDuration(int64(off + 0.5))
    stored.add %*{"anchor": d.anchorName(path), "offset": offset,
               "srcCrop": f["srcCrop"], "dstRect": f["dstRect"]}
  createDir(projectDir(d.path))
  writeFile(d.avatarPath, pretty(%*{"keyframes": stored}))
  result.invalidated = changedStages(hashesBefore, d.stageHashes)
  result.diagnostics = d.diagnostics

# ---------------------------------------------------------------------------
# The view the editor shows
# ---------------------------------------------------------------------------

proc spanJson(sp: Span): JsonNode =
  %*{"text": sp.text, "from": sp.fromId, "to": sp.toId, "voice": sp.voice, "style": sp.style}

proc timelineJson*(d: ScenarioDoc): JsonNode =
  ## The steps and their annotations, with the selected flavour's measured
  ## times when a run is attached. Times here are measurements, never values
  ## of the file.
  var items = newJArray()
  for p in d.order:
    let s = d.steps[p]
    var o = %*{"path": p, "kind": $s.kind, "id": s.id,
               "name": (if s.kind == stBeat: s.name else: ""),
               "input": s.kind in InputKinds,
               "leadInMs": s.leadIn, "dwellMs": s.dwell}
    let e = emitStep(s)
    if e.hasKey($s.kind): o["payload"] = e[$s.kind]
    if s.hasNarration: o["narration"] = spanJson(s.narration)
    if s.hasCaption: o["caption"] = spanJson(s.caption)
    if s.callouts.len > 0: o["callouts"] = e["callout"]
    if s.chapter != "": o["chapter"] = %s.chapter
    try:
      let m = d.measured(p)
      o["startMs"] = %m.startMs
      o["endMs"] = %m.endMs
    except EditError: discard
    items.add o
  var diags = newJArray()
  for x in d.diagnostics: diags.add %($x)
  %*{"file": d.path, "name": d.scenario.name, "flavour": d.runBackend,
     "steps": items, "diagnostics": diags,
     "avatar": (if fileExists(d.avatarPath): parseFile(d.avatarPath) else: newJNull())}
