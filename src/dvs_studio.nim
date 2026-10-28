## `dvs-studio`: DemoVideoStudio's command line.
##
##   dvs-studio edit <scenario.yaml> --pack <pack.yaml>
##       [--flavour NAME=COMMAND]… [--virtual-timing NAME]… [--run <manifest.json>]
##       [--port N]
##   dvs-studio open <run-dir> [--port N]
##   dvs-studio convert <keyframe-script> --pack <pack.yaml> --out <scenario.yaml>
##       [--target LEGACY=LOCATOR]… [--name NAME] [--report <report.json>]
##   dvs-studio storyboard "<goal>" --pack <pack.yaml> --out <scenario.yaml>
##       [--app NAME] [--target LEGACY=LOCATOR]… [--report <report.json>]
##   dvs-studio render <scenario.yaml> --pack <pack.yaml> --backend NAME=COMMAND
##       [--virtual-timing] --out <video.mp4> [--font-dir DIR] [--font-family F]
##       [--font-size PX] [--speech PROVIDER|none] [--voice NAME=VOICE]…
##       [--avatar <video>] [--json]
##
## `edit` serves the scenario editor (DemoVideoStudio-Editor §3) on
## http://127.0.0.1:N/ (default 7700). A flavour is a backend's JSON-lines host
## (decision D7), e.g. `--flavour "terminal=dvs-termassert-notes --serve"`; the
## first one named is selected. `--run` lays the timeline out on that run's
## measured times. `--virtual-timing NAME`: the flavour applies timing at
## render (a terminal flavour), so pacing edits do not stale its recording.
##
## `render` runs the scenario on the backend with recording on and composes the
## video (DemoVideoStudio-Editor §4). `--virtual-timing`: a terminal flavour,
## recorded fast and timed at render, rasterised through the pinned font.
##
## `open` shows a test-run recording read-only: its steps with their results,
## the failing step selected, its stills and observed state (§5.6).
##
## `convert` turns an absolute-time keyframe script into a scenario for the
## pack, and reports every keyframe it could not express and why (Format §10);
## `storyboard` writes the storyboard engine's script for a goal as a scenario
## the same way.
##
## Exit status: 0 done, 1 the run did not pass (`render`: no video; the failing
## step is reported) or some keyframes were not expressed (`convert`,
## `storyboard`: the scenario is written without them), 2 error, 64 usage.

import std/[json, os, parseopt, strutils, tables]
import demo_video_script/pack as dvspack
import demo_video_studio/[scenario_doc, scenario_editor, render, run_view, parser, storyboard]

const Usage = """usage:
  dvs-studio open <run-dir> [--port N]
  dvs-studio convert <keyframe-script> --pack <pack.yaml> --out <scenario.yaml>
      [--target LEGACY=LOCATOR]... [--name NAME] [--report <report.json>]
  dvs-studio storyboard "<goal>" --pack <pack.yaml> --out <scenario.yaml>
      [--app NAME] [--target LEGACY=LOCATOR]... [--report <report.json>]
  dvs-studio edit <scenario.yaml> --pack <pack.yaml>
      [--flavour NAME=COMMAND]... [--virtual-timing NAME]... [--run <manifest.json>] [--port N]
  dvs-studio render <scenario.yaml> --pack <pack.yaml> --backend NAME=COMMAND
      [--virtual-timing] --out <video.mp4> [--font-dir DIR] [--font-family F] [--font-size PX]
      [--speech PROVIDER|none] [--voice NAME=VOICE]... [--avatar <video>] [--json]
"""

proc usage(msg = "") {.noreturn.} =
  if msg != "": stderr.writeLine "dvs-studio: " & msg
  stderr.write Usage
  quit 64

proc cmdEdit(args: seq[string]) =
  var scenarioPath, packPath, runPath: string
  var port = 7700
  var flavours: seq[Flavour]
  var virtual: seq[string]
  # a non-empty longNoVal lets every other option take the next word as its value
  var p = initOptParser(args, shortNoVal = {'h'}, longNoVal = @["help"])
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      if scenarioPath != "": usage("one scenario at a time")
      scenarioPath = key
    of cmdLongOption, cmdShortOption:
      case key
      of "pack": packPath = val
      of "run": runPath = val
      of "port": port = parseInt(val)
      of "virtual-timing": virtual.add val
      of "flavour":
        let eq = val.find('=')
        if eq <= 0: usage("--flavour NAME=COMMAND")
        let cmd = parseCmdLine(val[eq + 1 .. ^1])
        if cmd.len == 0: usage("--flavour " & val[0 ..< eq] & " has no command")
        flavours.add Flavour(name: val[0 ..< eq], command: cmd[0], args: cmd[1 .. ^1])
      else: usage("unknown option --" & key)
    of cmdEnd: discard
  if scenarioPath == "" or packPath == "": usage("edit needs a scenario and --pack")
  for f in flavours.mitems:
    f.virtualTiming = f.name in virtual
  try:
    let doc = loadScenarioDoc(scenarioPath, packPath)
    if runPath != "": doc.attachRun(runPath)
    let ed = newScenarioEditor(doc, flavours)
    ed.start(port)
    echo "dvs-studio: editing ", scenarioPath, " on http://127.0.0.1:", int(ed.port), "/"
    flushFile(stdout)
    ed.serveForever()
  except EditError as e:
    stderr.writeLine "dvs-studio: " & e.msg
    for d in e.diagnostics: stderr.writeLine "  " & $d
    quit 2

proc cmdRender(args: seq[string]) =
  var scenarioPath, packPath, backendSpec: string
  var opts: RenderOptions
  var virtual, asJson: bool
  var p = initOptParser(args, shortNoVal = {'h'},
                        longNoVal = @["help", "virtual-timing", "json"])
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      if scenarioPath != "": usage("one scenario at a time")
      scenarioPath = key
    of cmdLongOption, cmdShortOption:
      case key
      of "pack": packPath = val
      of "backend": backendSpec = val
      of "virtual-timing": virtual = true
      of "out": opts.outPath = val
      of "font-dir": opts.fontDir = val
      of "font-family": opts.fontFamily = val
      of "font-size": opts.fontSize = parseInt(val)
      of "speech": opts.speech = val
      of "avatar": opts.avatarVideo = val
      of "json": asJson = true
      of "voice":
        let eq = val.find('=')
        if eq <= 0: usage("--voice NAME=VOICE")
        opts.voices[val[0 ..< eq]] = val[eq + 1 .. ^1]
      else: usage("unknown option --" & key)
    of cmdEnd: discard
  if scenarioPath == "" or packPath == "" or backendSpec == "" or opts.outPath == "":
    usage("render needs a scenario, --pack, --backend and --out")
  let eq = backendSpec.find('=')
  if eq <= 0: usage("--backend NAME=COMMAND")
  let cmd = parseCmdLine(backendSpec[eq + 1 .. ^1])
  if cmd.len == 0: usage("--backend has no command")
  let f = Flavour(name: backendSpec[0 ..< eq], command: cmd[0], args: cmd[1 .. ^1],
                  virtualTiming: virtual)
  try:
    let doc = loadScenarioDoc(scenarioPath, packPath)
    let r = renderScenario(doc, f, opts)
    if asJson: echo $reportJson(r)
    elif r.ok: echo "dvs-studio: rendered ", r.video
    else:
      echo "dvs-studio: no video: step ", r.failedStep, " (", r.failedKind, ") did not pass on '",
        r.flavour, "': ", r.message
      if r.recording != "": echo "  recording up to the step: ", r.recording
      if r.failureDir != "": echo "  failure: ", r.failureDir
    quit(if r.ok: 0 else: 1)
  except EditError as e:
    stderr.writeLine "dvs-studio: " & e.msg
    for d in e.diagnostics: stderr.writeLine "  " & $d
    quit 2
  except RenderError as e:
    stderr.writeLine "dvs-studio: " & e.msg
    quit 2

proc cmdOpen(args: seq[string]) =
  var dir = ""
  var port = 7701
  var p = initOptParser(args, shortNoVal = {'h'}, longNoVal = @["help"])
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument: dir = key
    of cmdLongOption, cmdShortOption:
      if key == "port": port = parseInt(val) else: usage("unknown option --" & key)
    of cmdEnd: discard
  if dir == "": usage("open needs a run directory")
  try:
    let v = openRun(dir)
    v.start(port)
    echo "dvs-studio: showing the run ", v.dir, " on http://127.0.0.1:", int(v.port), "/"
    flushFile(stdout)
    v.serveForever()
  except RunViewError as e:
    stderr.writeLine "dvs-studio: " & e.msg
    quit 2

proc writeConversion(c: Conversion; outPath, reportPath: string) =
  createDir(outPath.parentDir)
  writeFile(outPath, c.text)
  if reportPath != "": writeFile(reportPath, pretty(reportJson(c)))
  stdout.write reportText(c)
  echo "dvs-studio: wrote ", outPath
  quit(if c.unexpressed.len == 0: 0 else: 1)

proc cmdConvert(args: seq[string]; storyboardMode: bool) =
  var input, packPath, outPath, reportPath, app: string
  var opts: ConvertOptions
  var p = initOptParser(args, shortNoVal = {'h'}, longNoVal = @["help"])
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      if input != "": usage("one input at a time")
      input = key
    of cmdLongOption, cmdShortOption:
      case key
      of "pack": packPath = val
      of "out": outPath = val
      of "report": reportPath = val
      of "name": opts.name = val
      of "app": app = val
      of "target":
        let eq = val.find('=')
        if eq <= 0: usage("--target LEGACY=LOCATOR")
        opts.targets[val[0 ..< eq]] = val[eq + 1 .. ^1]
      else: usage("unknown option --" & key)
    of cmdEnd: discard
  if input == "" or packPath == "" or outPath == "":
    usage((if storyboardMode: "storyboard needs a goal" else: "convert needs a script") &
          ", --pack and --out")
  let (pk, pdiags) = dvspack.parsePackFile(packPath)
  if pdiags.hasErrors:
    for d in pdiags: stderr.writeLine "  " & $d
    quit 2
  try:
    if storyboardMode:
      opts.source = "the storyboard for \"" & input & "\""
      writeConversion(generateScenario(newRuleBasedBackend(),
        StoryboardRequest(goal: input, app: app), pk, opts), outPath, reportPath)
    else:
      opts.source = input.extractFilename
      let text = readFile(input)
      let script = (if input.endsWith(".json"): parseScriptJson(text) else: parseScriptYaml(text))
      writeConversion(convertScript(script, pk, opts), outPath, reportPath)
  except ConvertError, ScriptParseError, ScriptValidationError, StoryboardError, IOError:
    stderr.writeLine "dvs-studio: " & getCurrentExceptionMsg()
    quit 2

when isMainModule:
  let args = commandLineParams()
  if args.len == 0: usage()
  case args[0]
  of "edit": cmdEdit(args[1 .. ^1])
  of "render": cmdRender(args[1 .. ^1])
  of "open": cmdOpen(args[1 .. ^1])
  of "convert": cmdConvert(args[1 .. ^1], false)
  of "storyboard": cmdConvert(args[1 .. ^1], true)
  of "-h", "--help": (stdout.write Usage; quit 0)
  else: usage("unknown command '" & args[0] & "'")
