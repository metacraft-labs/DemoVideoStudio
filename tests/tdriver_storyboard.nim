## The keyframe-script driver and the storyboard, end to end
##
## The test file hosts:
##
##   * `e2e_terminal_action_injection` (M2) — PTY driver timing precision.
##   * `verify_agent_storyboard_generation` (M4) — prompt-to-script.
##
## (Moved from GuiAssert's tgui_assert.nim, whose frame-validation and SSIM
## suites stay there with the modules they test.)
##
## All tests perform real work: real PTY subprocesses and real ffmpeg. No
## mocks. No graceful skips.

import std/[options, os, osproc, sequtils, streams, strformat, strtabs, strutils, unittest]

import ../src/demo_video_studio/parser
import ../src/demo_video_studio/driver
import ../src/demo_video_studio/storyboard
import ../src/demo_video_studio/media

# ---------------------------------------------------------------------------
# Shared ffmpeg helper — pick a binary with drawtext support so we can
# render synthetic OCR fixtures. Mirrors the tmedia.nim discovery logic.
# ---------------------------------------------------------------------------

proc ffmpegFiltersOutput(path: string): string =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       path.startsWith("/nix/"):
      continue
    env[k] = v
  let p = startProcess(
    command = path,
    args = @["-hide_banner", "-filters"],
    env = env,
    options = {poStdErrToStdOut}
  )
  result = p.outputStream().readAll()
  discard p.waitForExit()
  p.close()

proc hasDrawtext(path: string): bool =
  try:
    let listing = ffmpegFiltersOutput(path)
    result = listing.splitLines.anyIt(it.contains(" drawtext "))
  except CatchableError:
    result = false

proc discoverFfmpegWithDrawtext(): string =
  let envBin = getEnv("FFMPEG_BIN")
  if envBin.len > 0 and fileExists(envBin) and hasDrawtext(envBin):
    return envBin
  let pathBin = findExe("ffmpeg")
  if pathBin.len > 0 and hasDrawtext(pathBin):
    return pathBin
  var candidates: seq[string] = @[]
  if dirExists("/nix/store"):
    for entry in walkDir("/nix/store"):
      if entry.kind == pcDir:
        let base = entry.path.extractFilename
        if "ffmpeg" in base and base.endsWith("-bin"):
          let bin = entry.path / "bin" / "ffmpeg"
          if fileExists(bin):
            candidates.add(bin)
  for c in candidates:
    if "ffmpeg-full" in c and hasDrawtext(c):
      return c
  for c in candidates:
    if hasDrawtext(c):
      return c
  raise newException(
    ValueError,
    "No ffmpeg binary with `drawtext` filter found. Searched $FFMPEG_BIN, " &
    "$PATH, and /nix/store/*ffmpeg*-bin/bin/ffmpeg."
  )

let ffmpegPath = discoverFfmpegWithDrawtext()
putEnv("FFMPEG_BIN", ffmpegPath)
echo "Using ffmpeg: ", ffmpegPath

proc runFfmpegEx(args: seq[string]): tuple[output: string, exitCode: int] =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if (k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH") and
       ffmpegPath.startsWith("/nix/"):
      continue
    env[k] = v
  let p = startProcess(
    command = ffmpegPath,
    args = args,
    env = env,
    options = {poStdErrToStdOut}
  )
  result.output = p.outputStream().readAll()
  result.exitCode = p.waitForExit()
  p.close()

# ===========================================================================
# M2: e2e_terminal_action_injection (unchanged from the original file)
# ===========================================================================

suite "e2e_terminal_action_injection":

  test "PTY driver fires three keystrokes within +/-50ms of schedule":
    const yaml = """
metadata:
  title: "PTY timing test"
timeline:
  - time: 0.0
    action: type_text
    params:
      text: "hello\n"
  - time: 0.5
    action: type_text
    params:
      text: "world\n"
  - time: 1.0
    action: type_text
    params:
      text: "ok\n"
"""
    let script = parseScriptYaml(yaml)
    check script.timeline.len == 3

    # `cat` from PATH: /bin/cat is not on every host (NixOS has only /bin/sh)
    var driver = newPtyDriver(["cat"])
    defer: closeDriver(driver)

    let events = playScriptOnPty(driver, script)
    check events.len == 3

    let expectedEcho = "hello\nworld\nok\n"
    discard waitForByteCount(driver, expectedEcho.len, timeoutMs = 2000)

    for ev in events:
      let driftMs = abs(ev.drift) * 1000.0
      checkpoint "kf=" & $ev.keyframeIndex &
                 " sched=" & $ev.scheduledOffset &
                 " actual=" & $ev.actualOffset &
                 " drift_ms=" & $driftMs
      check driftMs <= 50.0

    let outBuf = driver.output
    check expectedEcho in outBuf

# ===========================================================================
# M4: verify_agent_storyboard_generation
# ===========================================================================

suite "verify_agent_storyboard_generation":

  test "rule-based backend produces valid scripts for three goal keywords":
    let backend = newRuleBasedBackend()
    let goals = @[
      "Demonstrate recursive stepping through fibonacci",
      "Set a breakpoint and inspect variables",
      "Show the hot-reload workflow end to end"
    ]
    for goal in goals:
      let req = StoryboardRequest(
        goal: goal,
        durationSec: 15.0,
        resolution: "1920x1080",
        fps: 30
      )
      let yaml = generateScriptYaml(backend, req)
      checkpoint "goal: " & goal
      check yaml.len > 0
      # Must round-trip through the M2 parser without raising.
      let script = parseScriptYaml(yaml)
      validateScript(script)
      check script.timeline.len > 0
      check script.metadata.resolution == "1920x1080"
      check script.metadata.fps == 30

  test "the app and workspace root come from the request, not the engine":
    # GuiAssert is a project-agnostic engine consumed by several repos, so no
    # recipe may name a particular product.  This asserts BOTH directions: a
    # caller's values reach every generated keyframe, and the shipped defaults
    # name nothing product-specific.  A regression to a hardcoded app would
    # fail the `notin` checks even while every other storyboard test passed.
    let backend = newRuleBasedBackend()
    for goal in ["Demonstrate recursive stepping",
                 "Set a breakpoint and inspect variables",
                 "Show the hot-reload workflow end to end",
                 "An unknown demo theme nobody recognises"]:
      let req = StoryboardRequest(
        goal: goal,
        durationSec: 15.0,
        resolution: "1920x1080",
        fps: 30,
        app: "my-editor",
        workspaceRoot: "/srv/demos"
      )
      let yaml = generateScriptYaml(backend, req)
      checkpoint "goal: " & goal
      validateScript(parseScriptYaml(yaml))
      check "my-editor" in yaml
      check "codetracer" notin yaml
      check "./examples/" notin yaml

    # Defaults: still runnable, still naming no product.
    let dflt = StoryboardRequest(
      goal: "Demonstrate recursive stepping",
      durationSec: 15.0, resolution: "1920x1080", fps: 30)
    let dfltYaml = generateScriptYaml(backend, dflt)
    validateScript(parseScriptYaml(dfltYaml))
    check DefaultStoryboardApp in dfltYaml
    check "codetracer" notin dfltYaml

  test "unrecognised goal falls back to a sensible default":
    let backend = newRuleBasedBackend()
    let req = StoryboardRequest(
      goal: "An unknown demo theme nobody recognises",
      durationSec: 10.0,
      resolution: "1280x720",
      fps: 24
    )
    let yaml = generateScriptYaml(backend, req)
    let script = parseScriptYaml(yaml)
    validateScript(script)
    check script.timeline.len == 3
    check script.metadata.fps == 24
    check script.metadata.resolution == "1280x720"

  test "narration timings respect the M2 150-wpm overlap rule":
    # Drive every recipe and confirm none of them produces a script that the
    # parser would flag as overlapping. The parser's `validateScript` is the
    # ground truth; if it returns without raising we are good.
    let backend = newRuleBasedBackend()
    for goal in @["recursive", "breakpoint", "hot-reload", "completely unknown"]:
      let req = StoryboardRequest(
        goal: goal,
        durationSec: 20.0,
        resolution: "1920x1080",
        fps: 30
      )
      let yaml = generateScriptYaml(backend, req)
      let script = parseScriptYaml(yaml)
      validateScript(script)

  test "backend seam: a synthetic translator can be swapped in":
    # Demonstrates the extension point — a real LLM caller would supply a
    # closure here instead of the rule-based one.
    var stubBackend = StoryboardBackend(
      translate: proc(req: StoryboardRequest): string {.closure.} =
        result =
          "metadata:\n" &
          "  title: \"stub\"\n" &
          "  resolution: \"" & req.resolution & "\"\n" &
          "  fps: " & $req.fps & "\n" &
          "timeline:\n" &
          "  - time: 0.0\n" &
          "    action: launch_app\n" &
          "    narration: \"Hello stub\"\n" &
          "  - time: 3.0\n" &
          "    action: pause\n"
    )
    let req = StoryboardRequest(
      goal: "anything", durationSec: 5.0,
      resolution: "800x600", fps: 60
    )
    let yaml = generateScriptYaml(stubBackend, req)
    let script = parseScriptYaml(yaml)
    check script.metadata.resolution == "800x600"
    check script.metadata.fps == 60
    check script.timeline.len == 2

  test "backend producing invalid YAML raises StoryboardError":
    var bad = StoryboardBackend(
      translate: proc(req: StoryboardRequest): string {.closure.} =
        # `time` is missing on the second keyframe → ScriptParseError.
        result =
          "timeline:\n" &
          "  - time: 0.0\n" &
          "    action: click\n" &
          "  - action: click\n"
    )
    let req = StoryboardRequest(goal: "x", durationSec: 1.0,
                                resolution: "100x100", fps: 30)
    expect StoryboardError:
      discard generateScriptYaml(bad, req)
