## The final encode and the browser composite.
##
## A render's screencast is lossy once: the named codecs are its final
## encode, every intermediate is lossless RGB, and a presenter is overlaid in
## 4:4:4. A render can instead be written as a page that composites while it
## plays (`writeBrowserComposite`): the screencast encoded once on its own,
## the presenter its own video, captions WebVTT, callouts HTML. Real ffmpeg
## and ffprobe on synthetic media; no mocks.

import std/[json, options, os, osproc, strutils, unittest]
import ../src/demo_video_studio/[media, avatar_track, render]

proc tool(name: string): string =
  if name == "ffmpeg" and getEnv("FFMPEG_BIN").len > 0: return getEnv("FFMPEG_BIN")
  result = findExe(name)
  doAssert result.len > 0, name & " is required and was not found on PATH"

proc run(cmd: seq[string]): string =
  let (output, code) = execCmdEx(quoteShellCommand(cmd))
  doAssert code == 0, cmd.join(" ") & " failed:\n" & output
  output

proc streams(path: string): JsonNode =
  parseJson(run(@[tool("ffprobe"), "-v", "error", "-print_format", "json",
                  "-show_streams", path]))["streams"]

suite "the final encode":

  test "every named codec has encoder arguments, an unknown one is refused":
    for name in VideoCodecNames:
      let a = videoCodecArgs(name)
      check a.len > 2
      check a[0] == "-c:v"
    expect ValueError:
      discard videoCodecArgs("mjpeg")

  test "WebM codecs carry Opus, MP4 codecs AAC":
    check audioArgsFor(videoCodecArgs("vp9-444"))[1] == "libopus"
    check audioArgsFor(videoCodecArgs("av1"))[1] == "libopus"
    check audioArgsFor(videoCodecArgs("h264"))[1] == "aac"
    check audioArgsFor(videoCodecArgs("hevc"))[1] == "aac"

  test "the default encode is H.264 4:4:4, its colour said in the stream":
    let i = UiVideoArgs.find("-pix_fmt")
    check UiVideoArgs[i + 1] == "yuv444p"
    check "-colorspace" in UiVideoArgs
    for name in VideoCodecNames:
      if name != "lossless": check "-color_primaries" in videoCodecArgs(name)

  test "a composition's encode is the one asked for":
    var o = defaultComposeOptions()
    o.videoArgs = videoCodecArgs("h264")
    let argv = buildSilentComposeArgv("in.mp4", "out.mp4", @[], o)
    let i = argv.find("-pix_fmt")
    check i > 0 and argv[i + 1] == "yuv420p"

  test "the intermediate is lossless RGB":
    check "libx264rgb" in LosslessVideoArgs
    check "-qp" in LosslessVideoArgs

  test "a circle presenter is cut out by alpha and overlaid in 4:4:4":
    var k = defaultAvatarKeyframe()
    k.keyMethod = akmCircle
    check "hypot" in avatarKeyFilterExpr(k)
    check parseKeyMethod("circle") == akmCircle
    let f = buildAvatarTrackFilter(AvatarTrack(sourceVideo: "head.mp4", keyframes: @[k]),
                                   640, 360, 320, 320)
    check "format=yuv444[vout]" in f

suite "a browser composite":

  test "the page carries the screencast, presenter, WebVTT and callouts":
    let dir = getTempDir() / "dvs-browser-composite-" & $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    let base = dir / "base.mp4"
    let head = dir / "head.mp4"
    let wav = dir / "narration.wav"
    discard run(@[tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
                  "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30:duration=2",
                  ] & LosslessVideoArgs & @[base])
    discard run(@[tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
                  "-f", "lavfi", "-i", "testsrc2=size=256x256:rate=25:duration=2",
                  "-pix_fmt", "yuv420p", head])
    discard run(@[tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
                  "-f", "lavfi", "-i", "sine=frequency=440:duration=2", wav])
    var k = defaultAvatarKeyframe()
    k.keyMethod = akmCircle
    k.dstRect = initRectF(440, 160, 176, 176)
    let caps = @[
      Caption(text: "the narration's line", startTime: 0.2, endTime: 1.4),
      Caption(text: "→ the failing call", startTime: 0.5, endTime: 1.5,
              x: some("min(210\\,w-text_w-24)"), y: some("90")),
      Caption(text: "→ a banner", startTime: 1.0, endTime: 1.8, y: some("h/12"))]
    let page = dir / "page"
    writeBrowserComposite(page, base, wav, head, @[k], caps, 640, 360,
                          @["vp9-444", "h264-444"], "calc <tour>")
    for f in ["index.html", "ui-vp9-444.webm", "ui-h264-444.mp4", "presenter.mp4", "captions.vtt"]:
      check fileExists(page / f)
    var kinds: seq[string]
    for s in streams(page / "ui-h264-444.mp4"):
      kinds.add s["codec_type"].getStr & "/" & s["codec_name"].getStr
      if s["codec_type"].getStr == "video":
        # the screencast at its own size: never rescaled for the page
        check s["width"].getInt == 640
        check s["pix_fmt"].getStr == "yuv444p"
        check s["color_space"].getStr == "smpte170m"
    check "video/h264" in kinds
    check "audio/aac" in kinds
    let vtt = readFile(page / "captions.vtt")
    check vtt.startsWith("WEBVTT")
    check "00:00:00.200 --> 00:00:01.400\nthe narration's line" in vtt
    check "failing call" notin vtt   # a callout is HTML, not a cue
    let html = readFile(page / "index.html")
    check "calc &lt;tour&gt;" in html
    # the sources in the order asked, each with the type a browser skips by
    let a = html.find("src=\"ui-vp9-444.webm\" type='video/webm; codecs=\"vp09.01")
    let b = html.find("src=\"ui-h264-444.mp4\" type='video/mp4; codecs=\"avc1.F4")
    check a > 0 and b > a
    check "src=\"presenter.mp4\"" in html
    check "addCue(new VTTCue" in html and "the narration's line" in html
    check "the failing call" in html
    check "\"left\":32.8125" in html   # 210 of 640
    check "\"center\":true" in html
    check "left:68.750%;top:44.444%;width:27.500%" in html

  test "no presenter means no presenter video":
    let dir = getTempDir() / "dvs-browser-composite-webm-" & $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    let base = dir / "base.mp4"
    discard run(@[tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
                  "-f", "lavfi", "-i", "testsrc=size=320x180:rate=30:duration=1",
                  ] & LosslessVideoArgs & @[base])
    let page = dir / "page"
    writeBrowserComposite(page, base, "", "", @[], @[], 320, 180, @["vp9-444"], "t")
    check fileExists(page / "ui-vp9-444.webm")
    check not fileExists(page / "presenter.mp4")
    let s = streams(page / "ui-vp9-444.webm")
    check s.len == 1
    check s[0]["codec_name"].getStr == "vp9"
    check s[0]["pix_fmt"].getStr == "yuv444p"
    check "class=\"head\"" notin readFile(page / "index.html")

suite "a browser composite, played":

  test "in Chromium the presenter follows the screencast and the callouts show":
    if getEnv("DVS_PLAYWRIGHT_CORE") == "" or findExe("node") == "":
      skip()
    else:
      let dir = getTempDir() / "dvs-browser-composite-play-" & $getCurrentProcessId()
      createDir(dir)
      defer: removeDir(dir)
      let base = dir / "base.mp4"
      let head = dir / "head.webm"
      discard run(@[tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "testsrc=size=640x360:rate=30:duration=3",
                    ] & LosslessVideoArgs & @[base])
      # Playwright's Chromium decodes no H.264: the page's media are VP9 here
      discard run(@[tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "testsrc2=size=256x256:rate=25:duration=3",
                    "-c:v", "libvpx-vp9", "-deadline", "realtime", head])
      var k = defaultAvatarKeyframe()
      k.keyMethod = akmCircle
      k.dstRect = initRectF(440, 160, 176, 176)
      let caps = @[
        Caption(text: "a cue", startTime: 0.0, endTime: 2.5),
        Caption(text: "→ early", startTime: 0.0, endTime: 1.2,
                x: some("min(100\\,w-text_w-24)"), y: some("40"))]
      let page = dir / "page"
      writeBrowserComposite(page, base, "", head, @[k], caps, 640, 360,
                            @["vp9", "h264"], "played")
      let o = run(@[findExe("node"), currentSourcePath().parentDir / "browser/composite_page.mjs",
                    page / "index.html"])
      let r = parseJson(o.strip.splitLines[^1])
      check r["errors"].len == 0
      check r["playing"].getBool
      check r["headPlaying"].getBool
      check r["maxDrift"].getFloat < 0.25
      check "→ early" in $r["callouts"]
      check "a cue" in $r["cues"]
