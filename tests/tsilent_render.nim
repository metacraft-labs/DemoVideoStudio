## A silent render: no narration, no presenter, no provider compiled in.
##
## Narration and the presenter overlay are optional stages (Editor §6):
## a render with neither consults no speech or talking-head provider and
## needs no network. This suite imports only the composition module —
## the compile-time check below fails the build if a provider contract
## is reachable from it — and renders a real video with real ffmpeg and
## ffprobe from a synthetic screencast. No mocks.

import std/[json, os, osproc, sequtils, strutils, unittest]
import ../src/demo_video_studio/media

when declared(TalkingHeadProvider) or declared(SpeechSynthesisProvider):
  {.error: "a provider contract is compiled into the silent render".}

proc tool(name: string): string =
  if name == "ffmpeg" and getEnv("FFMPEG_BIN").len > 0: return getEnv("FFMPEG_BIN")
  result = findExe(name)
  doAssert result.len > 0, name & " is required and was not found on PATH"

proc run(cmd: seq[string]): string =
  let (output, code) = execCmdEx(quoteShellCommand(cmd))
  doAssert code == 0, cmd.join(" ") & " failed:\n" & output
  output

suite "a silent render":

  test "the screencast and its captions render offline, with no provider":
    let dir = getTempDir() / "dvs-silent-render-" & $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    let screencast = dir / "screencast.mp4"
    let output = dir / "silent.mp4"
    discard run(@[tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
                  "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30:duration=3",
                  "-pix_fmt", "yuv420p", screencast])

    let argv = buildSilentComposeArgv(screencast, output,
      @[Caption(text: "no narration", startTime: 0.5, endTime: 2.5)])
    # nothing is fetched: every input is a local file or a lavfi source
    for a in argv:
      check not a.contains("http")
    check argv.countIt(it == "-i") == 2  # the screencast and a silent source

    composeSilentVideo(screencast, output,
      @[Caption(text: "no narration", startTime: 0.5, endTime: 2.5)])
    check fileExists(output)

    let probe = parseJson(run(@[tool("ffprobe"), "-v", "error", "-print_format", "json",
                                "-show_streams", "-show_format", output]))
    var kinds: seq[string]
    for s in probe["streams"]:
      kinds.add s["codec_type"].getStr & "/" & s["codec_name"].getStr
      if s["codec_type"].getStr == "video":
        check s["width"].getInt == 1920
        check s["height"].getInt == 1080
    check "video/h264" in kinds
    check "audio/aac" in kinds
    let duration = probe["format"]["duration"].getStr.parseFloat
    check abs(duration - 3.0) < 0.25

    # the audio is silence, not narration
    let vol = execCmdEx(quoteShellCommand(@[tool("ffmpeg"), "-hide_banner", "-i", output,
                                            "-map", "0:a", "-af", "volumedetect", "-f", "null", "-"])).output
    var maxVolume = 0.0
    for line in vol.splitLines:
      if "max_volume:" in line:
        maxVolume = line.split("max_volume:")[1].strip.split(' ')[0].parseFloat
    check maxVolume <= -90.0

  test "a caption with a quote, a colon and a percent is drawn as written, and only it":
    # The caption's text is escaped for the filter graph, for drawtext's
    # option parser and for its expansion alike: an apostrophe escaped for a
    # shell once ended the text early and the rest of the clause
    # (`:fontsize=…:enable=…`) was drawn as text instead, and a bare `%`
    # stops drawtext. On a black screencast the caption shows where it
    # belongs, at the bottom, and nothing is drawn at the top.
    let dir = getTempDir() / "dvs-silent-caption-" & $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    let screencast = dir / "black.mp4"
    let output = dir / "captioned.mp4"
    discard run(@[tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
                  "-f", "lavfi", "-i", "color=c=black:size=640x360:rate=30:duration=2",
                  "-pix_fmt", "yuv420p", screencast])
    composeSilentVideo(screencast, output,
      @[Caption(text: "Step over the module's definitions: 100% done", startTime: 0.0, endTime: 2.0)])
    proc maxLuma(crop: string): int =
      let (raw, code) = execCmdEx(quoteShellCommand(@[tool("ffmpeg"), "-hide_banner",
        "-loglevel", "error", "-ss", "1", "-i", output, "-frames:v", "1",
        "-vf", "crop=" & crop & ",format=gray", "-f", "rawvideo", "-"]))
      doAssert code == 0, raw
      for ch in raw: result = max(result, ord(ch))
    check maxLuma("1920:200:0:0") < 40      # the top: nothing drawn
    check maxLuma("1920:300:0:780") > 200   # the bottom: the caption

  test "a missing screencast is refused":
    expect MediaCompositionError:
      composeSilentVideo("/nonexistent/screencast.mp4", getTempDir() / "never.mp4")
