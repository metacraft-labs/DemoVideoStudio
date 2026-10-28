## The keyframe-script converter, and the storyboard emitting scenarios
## (DemoVideoScript-Format §10; DemoVideoStudio-Editor §6; DVS-13).
##
## No mocks: a real keyframe script (`fixtures/legacy-tour.yaml`, every legacy
## action) is read by the legacy parser, converted for the conformance pack,
## and the scenario is parsed and linted by DemoVideoScript itself. The
## command line is run as a process.
##
## Needs DVS_ROOT (the conformance pack) and DVS_STUDIO_BIN.

import std/[json, os, osproc, strutils, tables, unittest]
import demo_video_script/[scenario, lint, model]
from demo_video_script/pack as dvspack import parsePackFile
import demo_video_studio/[parser, convert, storyboard]

proc need(name: string): string =
  result = getEnv(name)
  doAssert result.len > 0, name & " is not set (see the header of this file)"

let dvsRoot = need("DVS_ROOT")
let studio = need("DVS_STUDIO_BIN")
let packPath = dvsRoot / "conformance/pack/notes-app.pack.yaml"
let (pk, _) = parsePackFile(packPath)
let legacy = currentSourcePath().parentDir / "fixtures/legacy-tour.yaml"
let targets = {"recipes-note": "note-list/note[title=\"Recipes\"]"}.toTable

proc lintErrors(text: string): seq[string] =
  let (sc, d1) = parseScenarioText(text, "converted.yaml")
  for d in d1 & (if d1.hasStructuralErrors: @[] else: lintScenario(sc, pk)):
    if d.severity == sevError: result.add $d

suite "converting a keyframe script":

  test "every legacy action: what the pack can express becomes steps; the rest is reported":
    let c = convertScript(parseScriptYaml(readFile(legacy)), pk,
                          ConvertOptions(targets: targets, source: "legacy-tour.yaml"))
    checkpoint c.text
    check lintErrors(c.text).len == 0
    # exactly the keyframes the pack cannot express, each with its reason
    var reported: seq[(int, string)]
    for u in c.unexpressed: reported.add (u.index, u.action)
    check reported == @[(9, "navigate"), (10, "open_file"), (11, "set_breakpoint"),
                        (12, "step_over"), (13, "focus_window"), (14, "move_cursor"),
                        (15, "click")]
    for u in c.unexpressed:
      case u.index
      of 9, 10, 11, 12, 13: check "not user input" in u.why
      of 14: check "no role in the pack for the target 'editor.line(8)'" in u.why
      of 15: check "a coordinate is never recorded" in u.why
      else: discard
    # and what each expressed keyframe became
    let t = c.text
    check "stage:\n  - use: launch-app\n" in t
    check "  - move: { at: 'search-field' }\n" in t
    check "  - click: { at: 'search-field' }\n" in t          # where the cursor was
    check "  - type: { text: \"rec\", pace: { key-mean: 120ms } }\n" in t
    check "  - chord: Mod+a\n" in t
    check "  - key: Esc\n" in t
    check "  - wheel: { at: 'note-list', direction: down, amount: 3 }\n" in t
    check "  - click: { at: 'note-list/note[title=\"Recipes\"]', button: right }\n" in t
    check "  - flow: rename-note\n    with: { title: \"Recipes\", to: \"Cooking\" }\n" in t
    # narrations stay on steps: the first one's keyframe became the stage, so it
    # opens the first step; the unexpressed step_over's moves to the next step
    check "narration: { text: \"The notes application.\" }" in t
    check "narration: { text: \"This narration moves on.\" }" in t
    # times became pacing, never times
    check "time" notin t.toLowerAscii.replace("timeline", "")
    check "dwell: " in t
    # a dwell spans the gap to the next keyframe of the script, not the time the
    # keyframes that were not expressed took
    check "button: right }\n    dwell: 2400ms\n" in t

  test "the command line writes the scenario and the report":
    let dir = getTempDir() / "dvs-convert-" & $getCurrentProcessId()
    defer: removeDir(dir)
    let (o, code) = execCmdEx(quoteShellCommand(@[studio, "convert", legacy, "--pack", packPath,
      "--target", "recipes-note=note-list/note[title=\"Recipes\"]",
      "--out", dir / "tour.yaml", "--report", dir / "report.json"]))
    checkpoint o
    check code == 1                      # some keyframes were not expressed
    check "7 keyframe(s) not expressed" in o
    check lintErrors(readFile(dir / "tour.yaml")).len == 0
    check parseFile(dir / "report.json")["notExpressed"].len == 7

  test "the storyboard emits a scenario for a pack":
    let c = generateScenario(newRuleBasedBackend(),
                             StoryboardRequest(goal: "hot-reload", app: "notes"), pk)
    checkpoint c.text & "\n" & reportText(c)
    check lintErrors(c.text).len == 0
    check "  - type: " in c.text
    check "  - chord: Mod+s" in c.text
    # the recipe's windows and app are not this pack's: reported, not guessed
    var actions: seq[string]
    for u in c.unexpressed: actions.add u.action
    check "focus_window" in actions
