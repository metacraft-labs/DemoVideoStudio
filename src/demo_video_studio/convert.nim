## The keyframe-script converter (DemoVideoScript-Format §10; DVS-13).
##
## An absolute-time keyframe script (`parser.nim`'s format) becomes a scenario
## for a pack. Keyframes become steps, times become pacing, and free-form
## targets become locators — but only where the pack has a role for them. What
## cannot be expressed is reported, keyframe by keyframe, with the reason; it
## is never guessed. In particular no coordinate is ever recorded, and a target
## is never matched to a role by resemblance: it is a locator the pack
## resolves, or it is named in the target map, or it is reported.
##
## What each legacy action becomes:
##
## - `move_cursor {target}` → `move`; `click {target?, button?}` → `click` (with
##   no target: on the last pointer target, where the cursor is);
##   `scroll {target?, deltaY}` → `wheel` (100 px a notch); `type_text {text,
##   wpm?, target?}` → `type` (a target is clicked first; `wpm` becomes the
##   pacing's `key-mean`, five characters a word); `hot_key {keys}` → `key` or
##   `chord` (Cmd is `Mod`).
## - `launch_app` → the pack's `launch-app` stage, when the keyframe opens the
##   script and its parameters are the stage's.
## - Any other action → the pack's flow of the same name (`open_file` →
##   `open-file`), when its parameters are the flow's; otherwise it is not user
##   input (Format §4.3.1) and is reported.
##
## Times: the gap from a keyframe to the next one in the script, less what its
## step is expected to take, becomes that step's `dwell` (an estimate, stated in the
## report's notes: a realistic run times the steps themselves). A narration
## goes on the step its keyframe became, or — when that keyframe could not be
## expressed — on the next step.

import std/[json, math, options, os, strutils, tables]
import demo_video_script/[model, grammar, lint, scenario, pack]
import ./parser

type
  Unexpressed* = object
    index*: int        ## the keyframe's position in the script, from 1
    time*: float
    action*: string
    why*: string

  ConvertOptions* = object
    name*: string                     ## the scenario's name; default from the title
    targets*: Table[string, string]   ## a legacy target -> a locator
    source*: string                   ## the script's file, for the header

  Conversion* = object
    text*: string                     ## the scenario file
    steps*: seq[(int, string)]        ## keyframe index -> the step it became
    unexpressed*: seq[Unexpressed]
    notes*: seq[string]

  ConvertError* = object of CatchableError

  Out = object
    kind: string        ## move, click, wheel, type, key, chord, flow
    yaml: string        ## the payload, as YAML
    estimateMs: float
    keyframe: int
    time: float
    narration: seq[string]
    extra: seq[string]  ## further annotation lines (`with:` for a flow)

proc kebab(s: string): string = s.replace('_', '-').toLowerAscii

proc yq(s: string): string = $(%s)
proc locq(s: string): string = "'" & s.replace("'", "''") & "'"

proc slug(s: string): string =
  var prevDash = true
  for c in s.toLowerAscii:
    if c in {'a'..'z', '0'..'9'}:
      result.add c
      prevDash = false
    elif not prevDash:
      result.add '-'
      prevDash = true
  result = result.strip(chars = {'-'})
  if result.len == 0: result = "script"

proc param(kf: Keyframe; key: string): JsonNode =
  if kf.params != nil and kf.params.kind == JObject and kf.params.hasKey(key): kf.params[key]
  else: nil

proc paramStr(kf: Keyframe; key: string): string =
  let p = kf.param(key)
  if p == nil: "" elif p.kind == JString: p.getStr else: $p

proc locatorFor(pack: Pack; opts: ConvertOptions; target: string; why: var string): string =
  ## The locator for a legacy target, or "" with `why`.
  if target in opts.targets:
    let t = opts.targets[target]
    try:
      if staticRole(pack, parseLocator(t)) != "": return t
    except GrammarError: discard
    why = "the target map gives '" & target & "' the locator '" & t & "', which the pack does not resolve"
    return ""
  try:
    let loc = parseLocator(target)
    if staticRole(pack, loc) != "": return $loc
  except GrammarError: discard
  why = "no role in the pack for the target '" & target & "' (map it with --target, or add the role)"
  ""

proc isCoordinate(kf: Keyframe): bool =
  kf.param("x") != nil or kf.param("y") != nil or kf.paramStr("target").contains(',') and
    kf.paramStr("target").replace(",", "").replace(" ", "").replace(".", "").allCharsInSet(Digits)

proc chordFor(keys: JsonNode; why: var string): (string, bool) =
  ## (chord text, is a chord) for `hot_key`'s keys; "" with `why`.
  if keys == nil or keys.kind != JArray or keys.len == 0:
    why = "hot_key has no keys"
    return ("", false)
  var mods: seq[string]
  var key = ""
  for k in keys.elems:
    let s = k.getStr
    case s.toLowerAscii
    of "cmd", "command", "mod": mods.add "Mod"
    of "ctrl", "control": mods.add "Ctrl"
    of "alt", "option", "opt": mods.add "Alt"
    of "shift": mods.add "Shift"
    of "meta", "super", "win": mods.add "Meta"
    else:
      if key != "":
        why = "hot_key presses two keys (" & key & ", " & s & ")"
        return ("", false)
      key = s
  if key == "":
    why = "hot_key has only modifiers"
    return ("", false)
  var named = ""
  for n in NamedKeys:
    if n.toLowerAscii == key.toLowerAscii: named = n
  if key.toLowerAscii in ["escape"]: named = "Esc"
  if key.toLowerAscii in ["return"]: named = "Enter"
  let k = (if named != "": named elif key.len == 1: key.toLowerAscii else: "")
  if k == "" or not isKeyName(k):
    why = "hot_key's key '" & key & "' is not a key the format names"
    return ("", false)
  if mods.len == 0: return (k, false)
  ((mods & @[k]).join("+"), true)

proc paramsMatch(kf: Keyframe; declared: seq[string]; why: var string; what: string): bool =
  if kf.params == nil or kf.params.kind != JObject: return true
  for k, _ in kf.params:
    if kebab(k) notin declared:
      why = "'" & k & "' is not a parameter of " & what
      return false
  true

proc convertScript*(script: Script; pk: Pack; opts: ConvertOptions = ConvertOptions()): Conversion =
  ## Convert `script` into a scenario for `pk`. Raises `ConvertError` only when
  ## nothing at all can be expressed.
  var outs: seq[Out]
  var stage: seq[string]
  var pendingNarration: seq[string]
  var lastPointer = ""
  let tl = script.timeline
  for k, kf in tl:
    let index = k + 1
    var why = ""
    var made: seq[Out]
    case kf.action
    of "move_cursor", "click", "scroll":
      if kf.isCoordinate:
        why = "a coordinate is never recorded: give the target a role in the pack"
      else:
        var loc = ""
        let target = kf.paramStr("target")
        if target != "": loc = locatorFor(pk, opts, target, why)
        elif kf.action != "move_cursor" and lastPointer != "": loc = lastPointer
        elif kf.action == "move_cursor": why = "move_cursor has no target"
        else: why = kf.action & " has no target, and no pointer target precedes it"
        if loc != "":
          lastPointer = loc
          case kf.action
          of "move_cursor":
            made.add Out(kind: "move", yaml: "{ at: " & locq(loc) & " }", estimateMs: 600)
          of "click":
            let b = kf.paramStr("button")
            var y = "{ at: " & locq(loc)
            if b in ["right", "middle"]: y.add ", button: " & b
            made.add Out(kind: "click", yaml: y & " }", estimateMs: 600)
          else:
            let dy = (if kf.param("deltaY") != nil: kf.param("deltaY").getFloat else: 0.0)
            if dy == 0:
              why = "scroll has no deltaY"
            else:
              let amount = max(1, int(round(abs(dy) / 100)))
              made.add Out(kind: "wheel", yaml: "{ at: " & locq(loc) & ", direction: " &
                (if dy > 0: "down" else: "up") & ", amount: " & $amount & " }", estimateMs: 300)
    of "type_text":
      let text = kf.paramStr("text")
      let target = kf.paramStr("target")
      if text == "": why = "type_text has no text"
      else:
        var ok = true
        if target != "":
          let loc = locatorFor(pk, opts, target, why)
          if loc == "": ok = false
          else:
            lastPointer = loc
            made.add Out(kind: "click", yaml: "{ at: " & locq(loc) & " }", estimateMs: 600)
        if ok:
          let wpm = (if kf.param("wpm") != nil: kf.param("wpm").getFloat else: 0.0)
          if wpm > 0:
            let mean = int(round(60000.0 / (wpm * 5)))
            made.add Out(kind: "type", yaml: "{ text: " & yq(text) & ", pace: { key-mean: " &
              $mean & "ms } }", estimateMs: float(text.len * mean))
          else:
            made.add Out(kind: "type", yaml: yq(text), estimateMs: float(text.len) * 120)
    of "hot_key":
      let (c, isChord) = chordFor(kf.param("keys"), why)
      if c != "":
        made.add Out(kind: (if isChord: "chord" else: "key"), yaml: c, estimateMs: 100)
    of "launch_app":
      if outs.len > 0 or stage.len > 0:
        why = "launch_app after the steps began: a stage runs before the steps"
      elif not pk.stages.hasKey("launch-app"):
        why = "the pack has no 'launch-app' stage"
      else:
        var declared: seq[string]
        for p, _ in pk.stages["launch-app"].params: declared.add p
        if paramsMatch(kf, declared, why, "the pack's launch-app stage"):
          var line = "  - use: launch-app"
          if kf.params != nil and kf.params.kind == JObject and kf.params.len > 0:
            var parts: seq[string]
            for p, v in kf.params: parts.add kebab(p) & ": " & (if v.kind == JString: yq(v.getStr) else: $v)
            line.add "\n    with: { " & parts.join(", ") & " }"
          stage.add line
    else:
      let flowName = kebab(kf.action)
      var found = false
      for sig, fl in pk.flows:
        if fl.sig.name == flowName:
          found = true
          var declared: seq[string]
          for a in fl.sig.params: declared.add a
          if paramsMatch(kf, declared, why, "the pack's flow '" & flowName & "'"):
            var o = Out(kind: "flow", yaml: flowName, estimateMs: 1000)
            if kf.params != nil and kf.params.kind == JObject and kf.params.len > 0:
              var parts: seq[string]
              for p, v in kf.params: parts.add kebab(p) & ": " & (if v.kind == JString: yq(v.getStr) else: $v)
              o.extra.add "with: { " & parts.join(", ") & " }"
            made.add o
      if not found:
        why = "'" & kf.action & "' is not user input (Format §4.3.1), and the pack has no flow '" &
          flowName & "'"
    if kf.narration.isSome: pendingNarration.add kf.narration.get
    if made.len == 0 and stage.len > 0 and kf.action == "launch_app" and why == "":
      # became the stage
      result.steps.add (index, "stage")
      continue
    if made.len == 0:
      result.unexpressed.add Unexpressed(index: index, time: kf.time, action: kf.action,
        why: (if why != "": why else: "nothing to express"))
      continue
    for m in made.mitems:
      m.keyframe = index
      m.time = kf.time
    made[0].narration = pendingNarration
    pendingNarration = @[]
    outs.add made
  if outs.len == 0:
    raise newException(ConvertError, "no keyframe of the script could be expressed for the pack '" &
      pk.name & "'")
  if pendingNarration.len > 0:
    outs[^1].narration.add pendingNarration
    result.notes.add "the narration of the last keyframes, which could not be expressed, is on the last step"
  # the steps' paths, and the dwell from each gap
  var y = ""
  if opts.source != "": y.add "# Converted from " & opts.source & " by dvs-studio convert.\n"
  y.add "scenario: 1\n"
  let title = (if script.metadata.title != "": script.metadata.title else: "converted")
  y.add "name: " & (if opts.name != "": opts.name else: "converted/" & slug(title)) & "\n"
  y.add "pack: " & pk.name & "\n"
  y.add "summary: " & yq(title) & "\n"
  if stage.len > 0:
    y.add "\nstage:\n" & stage.join("\n") & "\n"
  y.add "\nsteps:\n"
  var estimated = false
  for k, o in outs:
    y.add "  - " & o.kind & ": " & o.yaml & "\n"
    for e in o.extra: y.add "    " & e & "\n"
    if o.narration.len > 0:
      y.add "    narration: { text: " & yq(o.narration.join(" ")) & " }\n"
    # the gap to the next keyframe of the script (an action not expressed takes
    # no time in the scenario), after the last step its keyframe became
    if k + 1 < outs.len and outs[k + 1].keyframe != o.keyframe and o.keyframe < tl.len:
      let gap = (tl[o.keyframe].time - o.time) * 1000
      let dwell = int(round(gap - o.estimateMs))
      if dwell > 0:
        y.add "    dwell: " & formatDuration(dwell) & "\n"
        estimated = true
    result.steps.add (o.keyframe, $(k + 1))
  if estimated:
    result.notes.add "each dwell is the gap to the next keyframe less an estimate of the step " &
      "(600 ms a pointer move or click, 300 ms a wheel, 100 ms a key, the typing at its pace): " &
      "a realistic run times the steps itself"
  result.text = y
  # the scenario must be one the pack lints clean
  let (sc, d1) = parseScenarioText(y, opts.source & ".scenario.yaml")
  var errors: seq[string]
  for d in d1 & (if d1.hasStructuralErrors: @[] else: lintScenario(sc, pk)):
    if d.severity == sevError: errors.add $d
  if errors.len > 0:
    raise newException(ConvertError, "the converted scenario does not lint (a converter defect): " &
      errors.join("; ") & "\n" & y)

proc reportJson*(c: Conversion): JsonNode =
  var un = newJArray()
  for u in c.unexpressed:
    un.add %*{"keyframe": u.index, "time": u.time, "action": u.action, "why": u.why}
  var st = newJArray()
  for (k, p) in c.steps: st.add %*{"keyframe": k, "step": p}
  %*{"steps": st, "notExpressed": un, "notes": c.notes}

proc reportText*(c: Conversion): string =
  if c.unexpressed.len == 0: result = "every keyframe was expressed\n"
  else:
    result = $c.unexpressed.len & " keyframe(s) not expressed:\n"
    for u in c.unexpressed:
      result.add "  keyframe " & $u.index & " (" & u.action & " at " &
        formatFloat(u.time, ffDecimal, 2) & " s): " & u.why & "\n"
  for n in c.notes: result.add "note: " & n & "\n"
