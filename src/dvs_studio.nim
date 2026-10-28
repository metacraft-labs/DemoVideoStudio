## `dvs-studio`: DemoVideoStudio's command line.
##
##   dvs-studio edit <scenario.yaml> --pack <pack.yaml>
##       [--flavour NAME=COMMAND]… [--virtual-timing NAME]… [--run <manifest.json>]
##       [--port N]
##
## `edit` serves the scenario editor (DemoVideoStudio-Editor §3) on
## http://127.0.0.1:N/ (default 7700). A flavour is a backend's JSON-lines host
## (decision D7), e.g. `--flavour "terminal=dvs-termassert-notes --serve"`; the
## first one named is selected. `--run` lays the timeline out on that run's
## measured times. `--virtual-timing NAME`: the flavour applies timing at
## render (a terminal flavour), so pacing edits do not stale its recording.
##
## Exit status: 0 done, 2 error, 64 usage.

import std/[os, parseopt, strutils]
import demo_video_studio/[scenario_doc, scenario_editor]

const Usage = """usage:
  dvs-studio edit <scenario.yaml> --pack <pack.yaml>
      [--flavour NAME=COMMAND]... [--virtual-timing NAME]... [--run <manifest.json>] [--port N]
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
    ed.serveForever()
  except EditError as e:
    stderr.writeLine "dvs-studio: " & e.msg
    for d in e.diagnostics: stderr.writeLine "  " & $d
    quit 2

when isMainModule:
  let args = commandLineParams()
  if args.len == 0: usage()
  case args[0]
  of "edit": cmdEdit(args[1 .. ^1])
  of "-h", "--help": (stdout.write Usage; quit 0)
  else: usage("unknown command '" & args[0] & "'")
