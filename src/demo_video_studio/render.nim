## Rendering a scenario through a flavour (DemoVideoStudio-Editor §4).
##
## A render is a run plus composition. The scenario is run by the
## DemoVideoScript runner with the project's pack on the flavour's backend —
## reached out of process through its JSON-lines host (decision D7) — with
## recording on. A terminal flavour runs with *virtual* timing: it is recorded
## at the speed the application allows and its realistic timeline is applied
## here, at render (§4.2); a flavour recording real video runs in realistic
## mode.
##
## The run's manifest gives each step's start and end on that flavour. Every
## narration, caption, callout and avatar keyframe is placed on those offsets —
## the media time of a step, never a second written anywhere — so the same
## scenario renders in step on every flavour. A run that does not pass renders
## nothing: the report names the failing step, the run's failure directory, and
## the recording up to that step (§4.3).
##
## Terminal recordings are casts, rasterised with `agg` (asciinema's renderer)
## through a pinned font at a declared size.

import std/[algorithm, json, math, options, os, osproc, strutils, tables]
import demo_video_script/[backend, jsonlines, runner, model]
import gui_assert/ffmpeg_tools
import ./[scenario_doc, flavour, media, avatar_track, speech_synthesis]
import ./speech_synthesis/core as speech_core

export flavour

type
  RenderOptions* = object
    outPath*: string
    workDir*: string          ## the run and intermediates; default `<outPath>.render/`
    fontDir*: string          ## a terminal flavour's pinned font: a directory of TTFs
    fontFamily*: string
    fontSize*: int            ## in pixels; default 16
    speech*: string           ## the narration provider; "" = the host's engine; "none" = silent
    voices*: Table[string, string]
      ## a scenario's voice name -> the provider's voice; a voice not named
      ## here is the provider's default (a scenario names voices for the
      ## production, not for an engine)
    avatarVideo*: string      ## the presenter's source video; "" = no presenter
    canvasWidth*, canvasHeight*: int
    stepCapMs*: float
      ## The longest a step is shown for; 0 = as long as it took. A step that
      ## took longer — a wait on a loaded machine, a backend reading a window
      ## by OCR — keeps its first half of this at its own pace (an input's
      ## pointer motion, the change it caused) and the rest is sped up to fit
      ## the other half. What is shown is still every frame's order and
      ## content from the one run; only the time a screen stood still is cut.
    settleTimeoutMs*, stageTimeoutMs*: int
      ## The run's limits, as a lane gives them (0 = the runner's defaults).
    fromRun*: string
      ## A run directory a render (or `dvs run --record always`) already
      ## recorded: composed again, without running the scenario. Its media is
      ## the one its manifest names, or the `session.*` beside it when the
      ## manifest names none (a backend stopped while it was still writing).

  Placement* = object
    kind*: string             ## narration, caption, callout, avatar
    step*: string             ## the step (or beat) it starts with
    text*: string
    startMs*, endMs*: float   ## in the video

  RenderReport* = object
    ok*: bool
    video*: string
    flavour*: string
    runDir*: string
    outcome*: string
    failedStep*, failedKind*, message*: string
    failureDir*: string
    recording*: string        ## the run's recording up to the failing step
    stepsMs*: OrderedTable[string, (float, float)]   ## each step's span in the video
    placements*: seq[Placement]

  RenderError* = object of CatchableError

  MStep = object
    path: string
    startMs, endMs, vStart, vEnd: float
    pStart, pEnd: float       ## its span in the video, once the cap is applied
    dwellMs, leadInMs: float  ## the scenario's own pauses after and before it (0: none)
    gapShown, gapKeep: float  ## the gap before it, as shown: its length and the part at its own pace

proc renderError(msg: string): ref RenderError = newException(RenderError, msg)

proc defaultFontDir(): string = getEnv("DVS_STUDIO_FONT_DIR")

# ---------------------------------------------------------------------------
# Media time: where a moment of the run is in the video
# ---------------------------------------------------------------------------

type MediaClock = object
  steps: seq[MStep]           ## sorted by startMs
  recStart: float             ## the runner's ms when recording began
  leadMs: float               ## how far into the video recording began
  virtual: bool
  cap: float                  ## `RenderOptions.stepCapMs`
  preCut: float               ## the start of the video the cap leaves out

proc capped*(d, cap: float): float =
  ## How long a step that took `d` is shown for under `cap` (0: no cap).
  if cap <= 0 or d <= cap: d else: cap

proc squeezed*(u, d, shown, keep: float): float =
  ## Where the moment `u` into a stretch that took `d` is shown when it is
  ## shown for `shown`: its first `keep` at its own pace, the rest sped up.
  if d <= shown: return u
  if u <= keep: u
  else: keep + (min(u, d) - keep) * (shown - keep) / (d - keep)

proc cappedOffset*(u, d, cap: float): float =
  ## Where the moment `u` into a step that took `d` is shown, under `cap`:
  ## the first half of the cap at the step's own pace, the rest sped up.
  if cap <= 0 or d <= cap: u else: squeezed(u, d, cap, cap / 2)

proc baseSpan(c: MediaClock; s: MStep): (float, float) =
  ## A step's span on the run's own timeline: virtual or real.
  if c.virtual: (s.vStart, s.vEnd) else: (s.startMs, s.endMs)

proc gapBefore(c: MediaClock; k: int): float =
  ## The time between step k-1 and step k on the run's own timeline.
  if k == 0: return 0.0
  let (_, pb1) = c.baseSpan(c.steps[k - 1])
  let (b0, _) = c.baseSpan(c.steps[k])
  max(0.0, b0 - pb1)

const PreRollMs = 1500.0
  ## What a real-time video keeps, under a cap, of what it recorded before
  ## the first step.

const GapSlackMs = 300.0
  ## What a gap between two steps keeps beyond the scenario's own pauses
  ## under a cap: the time a reader takes to see the next input coming.

proc layOut(c: var MediaClock) =
  ## Each step's span in the video, each step as long as `capped` says. A
  ## gap between steps — a real-time run's `dwell` sleeps there, and so does
  ## the backend's still of the step, which can take seconds on a loaded
  ## host — keeps, under a cap, the scenario's own pauses (the dwell after
  ## the step before, the lead-in of the next) and `GapSlackMs`; the rest of
  ## it is sped up into its last 150 ms.
  if c.steps.len == 0: return
  let first = c.steps[0]
  let pre = c.leadMs + first.startMs - c.recStart
  # before the first step (the application opening): under a cap, its last
  # `PreRollMs` only
  c.preCut = (if c.cap > 0 and not c.virtual: max(0.0, pre - PreRollMs) else: 0.0)
  var cursor = pre - c.preCut + (if c.virtual: first.vStart else: 0.0)
  for k in 0 ..< c.steps.len:
    let (b0, b1) = c.baseSpan(c.steps[k])
    if k > 0:
      let g = c.gapBefore(k)
      var shown = g
      if c.cap > 0:
        let own = (if c.virtual: 0.0 else: c.steps[k - 1].dwellMs) + c.steps[k].leadInMs
        shown = min(g, own + GapSlackMs)
      c.steps[k].gapShown = shown
      c.steps[k].gapKeep = max(0.0, shown - 150.0)
      cursor += shown
    c.steps[k].pStart = cursor
    cursor += capped(b1 - b0, c.cap)
    c.steps[k].pEnd = cursor

proc mediaMs(c: MediaClock; ms: float): float =
  ## The video time of the runner's `ms`.
  if c.steps.len == 0 or (not c.virtual and c.cap <= 0): return c.leadMs + ms - c.recStart
  let first = c.steps[0]
  # before the first step: real time; the step timeline starts where the
  # first step started
  if ms < first.startMs: return max(0.0, c.leadMs + ms - c.recStart - c.preCut)
  for k, s in c.steps:
    if ms <= s.endMs:
      let (b0, b1) = c.baseSpan(s)
      if ms >= s.startMs:
        let f = (if s.endMs > s.startMs: (ms - s.startMs) / (s.endMs - s.startMs) else: 1.0)
        return s.pStart + cappedOffset(f * (b1 - b0), b1 - b0, c.cap)
      # in the gap before step k
      let p = c.steps[k - 1]
      let g = c.gapBefore(k)
      let f = (if s.startMs > p.endMs: (ms - p.endMs) / (s.startMs - p.endMs) else: 1.0)
      return p.pEnd + squeezed(f * g, g, s.gapShown, s.gapKeep)
  let last = c.steps[^1]
  last.pEnd + (ms - last.endMs)

proc cutStretches(c: MediaClock): seq[(float, float, float)] =
  ## A real-time recording's stretches the cap shortens, in its own time
  ## (ms): (where the sped-up part starts, how long it is, the fraction of
  ## it that is cut).
  if c.virtual or c.cap <= 0: return
  if c.preCut > 0: result.add (0.0, c.preCut, 1.0)
  for k, s in c.steps:
    if k > 0:
      let p = c.steps[k - 1]
      let g = s.startMs - p.endMs
      if g > s.gapShown and g > s.gapKeep:
        result.add (c.leadMs + p.endMs - c.recStart + s.gapKeep, g - s.gapKeep,
                    1 - (s.gapShown - s.gapKeep) / (g - s.gapKeep))
    let d = s.endMs - s.startMs
    if d > c.cap:
      let keep = c.cap / 2
      result.add (c.leadMs + s.startMs - c.recStart + keep, d - keep,
                  1 - (c.cap - keep) / (d - keep))

proc removedMs(c: MediaClock): float =
  ## How much shorter the cap makes a real-time recording.
  for (_, L, lose) in c.cutStretches: result += L * lose

proc retimeExpression(c: MediaClock): string =
  ## A real-time recording's timestamps (`T`, seconds) as the video's under
  ## the cap, by an ffmpeg expression for `setpts`: every stretch the cap
  ## shortens loses the time `squeezed` takes from it.
  var terms: seq[string]
  for (a, L, lose) in c.cutStretches:
    terms.add "clip(T-" & formatFloat(a / 1000, ffDecimal, 4) & ",0," &
              formatFloat(L / 1000, ffDecimal, 4) & ")*" & formatFloat(lose, ffDecimal, 6)
  if terms.len == 0: return ""
  "(T-" & terms.join("-") & ")/TB"

proc span(c: MediaClock; path: string): (float, float) =
  ## A step's (or a beat's, or a flow call's) span in the video.
  var found = false
  for s in c.steps:
    if s.path == path or s.path.startsWith(path & ".") or s.path.startsWith(path & ">") or
        s.path.startsWith(path & "~"):
      let a = c.mediaMs(s.startMs)
      let b = c.mediaMs(s.endMs)
      if not found: result = (a, b)
      else: result = (min(result[0], a), max(result[1], b))
      found = true
  if not found: raise renderError("step " & path & " did not run on this flavour")

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

proc run(cmd: seq[string]; what: string) =
  let (output, code) = execCmdEx(quoteShellCommand(cmd))
  if code != 0: raise renderError(what & " failed (" & $code & "):\n" & output)

proc ffprobeDuration(path: string): float =
  ## The media's duration in seconds. A WebM a recorder stopped without
  ## finalising (Playwright's Electron recordings) carries none in its
  ## header (`N/A`): then it is its last video packet's time.
  let probe = getEnv("FFPROBE_BIN", findExe("ffprobe"))
  let (o, code) = execCmdEx(quoteShellCommand(@[probe, "-v", "error", "-show_entries",
    "format=duration", "-of", "default=nw=1:nk=1", path]))
  if code != 0: raise renderError("ffprobe " & path & ": " & o)
  try: return parseFloat(o.strip)
  except ValueError: discard
  let (p, pcode) = execCmdEx(quoteShellCommand(@[probe, "-v", "error", "-select_streams", "v:0",
    "-show_entries", "packet=pts_time", "-of", "csv=p=0", path]))
  if pcode != 0: raise renderError("ffprobe " & path & ": " & p)
  result = -1.0
  for l in p.splitLines:
    try: result = max(result, parseFloat(l.strip.strip(chars = {','})))
    except ValueError: discard
  if result < 0: raise renderError("ffprobe " & path & ": no duration and no video packets")

proc videoSize(path: string): (int, int) =
  let probe = getEnv("FFPROBE_BIN", findExe("ffprobe"))
  let (o, code) = execCmdEx(quoteShellCommand(@[probe, "-v", "error", "-select_streams", "v:0",
    "-show_entries", "stream=width,height", "-of", "csv=p=0", path]))
  if code != 0: raise renderError("ffprobe " & path & ": " & o)
  let p = o.strip.split(',')
  (parseInt(p[0]), parseInt(p[1]))

proc toMp4(src, dst: string; minSeconds: float; retime = ""; removedMs = 0.0) =
  ## The recording as an H.264 video `minSeconds` long (its last frame held
  ## when it is shorter, cut when it is longer), even-sized for yuv420p;
  ## `retime` (a `setpts` expression) moves its frames first, shortening it by
  ## `removedMs`.
  let have = ffprobeDuration(src) - removedMs / 1000
  let pad = max(0.0, minSeconds - have)
  run(@[resolveFfmpegBinary(), "-y", "-hide_banner", "-loglevel", "error", "-i", src,
        "-vf", (if retime.len > 0: "setpts='" & retime & "'," else: "") &
          "scale=trunc(iw/2)*2:trunc(ih/2)*2,fps=30,tpad=stop_mode=clone:stop_duration=" &
          formatFloat(pad + 0.5, ffDecimal, 3),
        # and no longer: what a real-time recording holds after the last step
        # (the application closing, the recorder finishing) is not the run's
        "-t", formatFloat(minSeconds + 0.5, ffDecimal, 3),
        "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-an", dst],
      "converting the recording")

# ---------------------------------------------------------------------------
# Terminal casts
# ---------------------------------------------------------------------------

proc retimeCast(src, dst: string; c: MediaClock; untilMs = -1.0) =
  ## Rewrite a cast's event times into video time (virtual timing applied),
  ## optionally keeping only what happened before the runner's `untilMs`.
  var lines = readFile(src).splitLines
  var res = @[lines[0]]
  var last = 0.0
  for l in lines[1 .. ^1]:
    if l.strip.len == 0: continue
    let ev = parseJson(l)
    let ms = c.recStart + ev[0].getFloat * 1000
    if untilMs >= 0 and ms > untilMs: break
    let t = max(last, c.mediaMs(ms) - c.leadMs) / 1000
    last = t * 1000
    ev.elems[0] = %t
    res.add $ev
  writeFile(dst, res.join("\n") & "\n")

proc rasteriseCast(castPath, mp4: string; opts: RenderOptions; minSeconds: float) =
  let agg = getEnv("AGG_BIN", findExe("agg"))
  if agg.len == 0: raise renderError("agg (asciinema's cast renderer) is not on PATH")
  let fontDir = (if opts.fontDir != "": opts.fontDir else: defaultFontDir())
  if fontDir == "" or not dirExists(fontDir):
    raise renderError("no pinned font: give a font directory (--font-dir or DVS_STUDIO_FONT_DIR)")
  let gif = mp4.changeFileExt(".gif")
  run(@[agg, "--quiet", "--no-loop", "--font-dir", fontDir,
        "--font-family", (if opts.fontFamily != "": opts.fontFamily else: "JetBrains Mono"),
        "--font-size", $(if opts.fontSize > 0: opts.fontSize else: 16),
        "--idle-time-limit", "100000", "--last-frame-duration", "1", "--fps-cap", "30",
        "--theme", "asciinema", castPath, gif], "rasterising the cast")
  toMp4(gif, mp4, minSeconds)

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc cutRecording(media: string; c: MediaClock; untilMs: float; dir: string): string =
  ## The run's recording up to the runner's `untilMs`.
  if media.endsWith(".cast"):
    result = dir / "recording-to-failure.cast"
    retimeCast(media, result, MediaClock(steps: c.steps, recStart: c.recStart), untilMs)
  else:
    result = dir / ("recording-to-failure" & media.splitFile.ext)
    let t = max(0.1, (c.leadMs + untilMs - c.recStart) / 1000)
    run(@[resolveFfmpegBinary(), "-y", "-hide_banner", "-loglevel", "error", "-i", media,
          "-t", formatFloat(t, ffDecimal, 3), "-c", "copy", result], "cutting the recording")

proc anchorPaths(doc: ScenarioDoc): Table[string, string] =
  for p in doc.stepPaths:
    let s = doc.step(p)
    if s.id != "": result[s.id] = p
    if s.kind == stBeat: result[s.name] = p

proc spanPaths(doc: ScenarioDoc; anchors: Table[string, string]; own, fromId, toId: string):
    (string, string) =
  let a = (if fromId == "": own else: anchors.getOrDefault(fromId, ""))
  let b = (if toId == "": own else: anchors.getOrDefault(toId, ""))
  if a == "" or b == "": raise renderError("an anchor of step " & own & " names no step")
  (a, b)

proc narrationTrack(clips: seq[(string, float)]; dst: string) =
  ## One audio track with each clip starting at its offset (ms).
  var args = @[resolveFfmpegBinary(), "-y", "-hide_banner", "-loglevel", "error"]
  var filt: seq[string]
  var mix = ""
  for k, (wav, ms) in clips:
    args.add @["-i", ffmpegInputUrl(wav)]
    let d = $int(round(ms))
    filt.add "[" & $k & ":a]aresample=44100,adelay=" & d & ":all=1[a" & $k & "]"
    mix.add "[a" & $k & "]"
  filt.add mix & "amix=inputs=" & $clips.len & ":duration=longest:normalize=0[out]"
  args.add @["-filter_complex", filt.join(";"), "-map", "[out]", "-c:a", "pcm_s16le", dst]
  run(args, "mixing the narration")

proc renderScenario*(doc: ScenarioDoc; flavour: Flavour; opts: RenderOptions): RenderReport =
  ## Run `doc` on `flavour` and compose the video at `opts.outPath`. A run that
  ## does not pass produces no video (and removes an earlier one at that path).
  result.flavour = flavour.name
  let work = (if opts.workDir != "": opts.workDir else: opts.outPath & ".render")
  if opts.fromRun != "" and absolutePath(opts.fromRun).startsWith(absolutePath(work) & "/"):
    raise renderError("--from-run " & opts.fromRun & " is inside the render's own work " &
                      "directory, which a render starts by clearing: move it out first")
  removeDir(work)
  createDir(work)
  let runDir = work / "run"
  result.runDir = runDir
  if fileExists(opts.outPath): removeFile(opts.outPath)
  # 1. the run
  var res: RunResult
  if opts.fromRun != "":
    # composed again from a recorded run: a copy, the original left as it is
    if not fileExists(opts.fromRun / "manifest.json"):
      raise renderError(opts.fromRun & " holds no run (no manifest.json)")
    copyDir(opts.fromRun, runDir)
    res.outcome = roPassed
    for s in parseFile(runDir / "manifest.json"){"steps"}.getElems:
      if s{"status"}.getStr != "passed":
        raise renderError("the run in " & opts.fromRun & " did not pass: step " &
                          s{"path"}.getStr & " is " & s{"status"}.getStr)
  else:
    let b = spawnJsonLinesBackend(flavour.command, flavour.args, name = flavour.name)
    try:
      res = runScenario(doc.scenario, doc.pack, b, RunOptions(
        mode: (if flavour.virtualTiming: tmVirtual else: tmRealistic), record: rpAlways,
        runDir: runDir, scenarioDir: doc.path.parentDir,
        settleTimeoutMs: opts.settleTimeoutMs, stageTimeoutMs: opts.stageTimeoutMs))
    finally:
      b.close()
  result.outcome = $res.outcome
  let manifestPath = runDir / "manifest.json"
  var clock = MediaClock(virtual: flavour.virtualTiming, cap: opts.stepCapMs)
  var media = ""
  if fileExists(manifestPath):
    let m = parseFile(manifestPath)
    clock.recStart = m{"recordingStartMs"}.getFloat
    for s in m{"steps"}.getElems:
      if s{"status"}.getStr == "not-run": continue
      clock.steps.add MStep(path: s{"path"}.getStr, startMs: s{"startMs"}.getFloat,
                            endMs: s{"endMs"}.getFloat, vStart: s{"virtualStartMs"}.getFloat,
                            vEnd: s{"virtualEndMs"}.getFloat)
    clock.steps.sort(proc (a, b: MStep): int = cmp(a.startMs, b.startMs))
    for st in clock.steps.mitems:
      try:
        let sd = doc.step(st.path)
        st.dwellMs = max(0.0, float(sd.dwell))
        st.leadInMs = max(0.0, float(sd.leadIn))
      except CatchableError: discard
    for f in m{"media"}.getElems:
      if f.getStr.endsWith(".cast") or f.getStr.endsWith(".webm") or f.getStr.endsWith(".mp4"):
        media = f.getStr
    if opts.fromRun != "":
      # the copy's own media, under its new directory
      if media != "": media = runDir / media.extractFilename
      if media == "" or not fileExists(media):
        for name in ["session.cast", "session.webm", "session.mp4"]:
          if fileExists(runDir / name): media = runDir / name
  let videoJson = runDir / "session.video.json"
  if fileExists(videoJson): clock.leadMs = parseFile(videoJson){"leadMs"}.getFloat
  clock.layOut()
  # 2. a run that did not pass is shown as a failure, never rendered past
  if res.outcome != roPassed:
    result.ok = false
    result.message = res.message
    for s in res.steps:
      if s.status == ssFailed:
        result.failedStep = s.path
        result.failedKind = s.kind
        result.message = s.message
        if media != "" and fileExists(media):
          result.recording = cutRecording(media, clock, s.endMs, runDir)
        break
    if dirExists(runDir / "failure"): result.failureDir = runDir / "failure"
    return
  if media == "" or not fileExists(media):
    raise renderError("the run on '" & flavour.name & "' recorded no media")
  for s in doc.stepPaths:
    try: result.stepsMs[s] = clock.span(s)
    except RenderError: discard
  # 3. placements, on this flavour's offsets
  let anchors = anchorPaths(doc)
  var captions: seq[Caption]
  var narration: seq[(Placement, string)]   # (placement, voice)
  for p in doc.stepPaths:
    let s = doc.step(p)
    if s.hasNarration:
      let (a, z) = spanPaths(doc, anchors, p, s.narration.fromId, s.narration.toId)
      let pl = Placement(kind: "narration", step: a, text: s.narration.text,
                         startMs: clock.span(a)[0], endMs: clock.span(z)[1])
      result.placements.add pl
      narration.add (pl, s.narration.voice)
    if s.hasCaption:
      let (a, z) = spanPaths(doc, anchors, p, s.caption.fromId, s.caption.toId)
      let pl = Placement(kind: "caption", step: a, text: s.caption.text,
                         startMs: clock.span(a)[0], endMs: clock.span(z)[1])
      result.placements.add pl
      captions.add Caption(text: pl.text, startTime: pl.startMs / 1000, endTime: pl.endMs / 1000)
    for c in s.callouts:
      let (a, z) = spanPaths(doc, anchors, p, c.fromId, c.toId)
      result.placements.add Placement(kind: "callout", step: a, text: c.text,
                                      startMs: clock.span(a)[0], endMs: clock.span(z)[1])
  var avatar: seq[AvatarKeyframe]
  if fileExists(doc.avatarPath):
    for k in parseFile(doc.avatarPath){"keyframes"}.getElems:
      let p = anchors.getOrDefault(k{"anchor"}.getStr, "")
      if p == "": raise renderError("an avatar keyframe anchors to '" & k{"anchor"}.getStr &
                                    "', which names no step")
      let t = clock.span(p)[0] + float(parseDurationText(k{"offset"}.getStr))
      result.placements.add Placement(kind: "avatar", step: p, startMs: t, endMs: t)
      var kf = defaultAvatarKeyframe(t / 1000)
      let sc = k["srcCrop"]
      let ds = k["dstRect"]
      kf.srcCrop = initRectF(sc["x"].getFloat, sc["y"].getFloat, sc["w"].getFloat, sc["h"].getFloat)
      kf.dstRect = initRectF(ds["x"].getFloat, ds["y"].getFloat, ds["w"].getFloat, ds["h"].getFloat)
      avatar.add kf
  # 4. the base video
  var endMs = 0.0
  for pl in result.placements: endMs = max(endMs, pl.endMs)
  for _, sp in result.stepsMs: endMs = max(endMs, sp[1])
  let base = work / "base.mp4"
  if media.endsWith(".cast"):
    let timed = work / "timed.cast"
    retimeCast(media, timed, clock)
    rasteriseCast(timed, base, opts, endMs / 1000 + 0.5)
  else:
    toMp4(media, base, endMs / 1000 + 0.5,
          retime = clock.retimeExpression, removedMs = clock.removedMs)
  # callouts, at their target's geometry when the run noted it
  let (bw, bh) = videoSize(base)
  let cw = (if opts.canvasWidth > 0: opts.canvasWidth else: 1920)
  let ch = (if opts.canvasHeight > 0: opts.canvasHeight else: 1080)
  let scale = min(cw / bw, ch / bh)
  let ox = (float(cw) - float(bw) * scale) / 2
  let oy = (float(ch) - float(bh) * scale) / 2
  if fileExists(manifestPath):
    # a medium unit in the base video's pixels: a cell is agg's line (font
    # size × its 1.4 line height) high, inside an equal padding on every side
    var unit = (1.0, 1.0)
    var pad = 0.0
    if media.endsWith(".cast"):
      let header = parseJson(readFile(media).splitLines[0])
      let rows = float(header{"height"}.getInt(24))
      let cols = float(header{"width"}.getInt(80))
      let lineH = float(if opts.fontSize > 0: opts.fontSize else: 16) * 1.4
      pad = max(0.0, (float(bh) - rows * lineH) / 2)
      unit = ((float(bw) - 2 * pad) / cols, lineH)
    for s in parseFile(manifestPath){"steps"}.getElems:
      for c in s{"resolved"}{"callouts"}.getElems:
        let g = c{"geometry"}
        var cap = Caption(text: "→ " & c{"text"}.getStr)
        for pl in result.placements:
          if pl.kind == "callout" and pl.text == c{"text"}.getStr:
            cap.startTime = pl.startMs / 1000
            cap.endTime = pl.endMs / 1000
        if g != nil and g.kind == JObject:
          let x = ox + (pad + (g{"x"}.getFloat + g{"w"}.getFloat) * unit[0]) * scale
          let y = oy + (pad + g{"y"}.getFloat * unit[1]) * scale
          # beside the target, kept inside the canvas when the target is wide
          cap.x = some("min(" & $int(x + 10) & "\\,w-text_w-24)")
          cap.y = some($int(y))
        else:
          cap.y = some("h/12")
        captions.add cap
  # 5. composition: the screencast with its captions and callouts, the
  # presenter, then the narration
  var composeOpts = defaultComposeOptions()
  composeOpts.canvasWidth = cw
  composeOpts.canvasHeight = ch
  let silent = work / "silent.mp4"
  composeSilentVideo(base, silent, captions, composeOpts)
  var picture = silent
  if opts.avatarVideo != "" and avatar.len > 0:
    let (sw, sh) = videoSize(opts.avatarVideo)
    picture = work / "presenter.mp4"
    composeVideoWithAvatarTrack(silent, opts.avatarVideo, picture,
      AvatarTrack(sourceVideo: opts.avatarVideo, keyframes: avatar), cw, ch, sw, sh,
      useAvatarAudio = false)
  createDir(opts.outPath.parentDir)
  if narration.len == 0 or opts.speech == "none":
    copyFile(picture, opts.outPath)
  else:
    let reg = newDefaultSpeechRegistry()
    let provider = (if opts.speech != "": opts.speech else: defaultHostProviderName())
    var clips: seq[(string, float)]
    for k, (pl, voice) in narration:
      let wav = work / ("narration-" & $k & ".wav")
      var so = SpeechSynthesisOpts()
      if voice in opts.voices: so.voiceId = some(opts.voices[voice])
      synthesizeWith(reg, provider, pl.text, wav, so)
      clips.add (wav, pl.startMs)
    let track = work / "narration.wav"
    narrationTrack(clips, track)
    run(@[resolveFfmpegBinary(), "-y", "-hide_banner", "-loglevel", "error",
          "-i", picture, "-i", track, "-map", "0:v", "-map", "1:a", "-c:v", "copy",
          "-af", "apad", "-c:a", "aac", "-b:a", "192k", "-shortest", opts.outPath],
        "adding the narration")
  result.ok = true
  result.video = opts.outPath

proc reportJson*(r: RenderReport): JsonNode =
  var steps = newJObject()
  for k, v in r.stepsMs: steps[k] = %*{"startMs": v[0], "endMs": v[1]}
  var pls = newJArray()
  for p in r.placements:
    pls.add %*{"kind": p.kind, "step": p.step, "text": p.text, "startMs": p.startMs,
               "endMs": p.endMs}
  result = %*{"ok": r.ok, "flavour": r.flavour, "outcome": r.outcome, "video": r.video,
              "runDir": r.runDir, "steps": steps, "placements": pls}
  if not r.ok:
    result["failure"] = %*{"step": r.failedStep, "kind": r.failedKind, "message": r.message,
                           "failureDir": r.failureDir, "recording": r.recording}
