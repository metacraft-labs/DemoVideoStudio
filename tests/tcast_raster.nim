## A terminal cast is rasterised with pinned fonts only.
##
## agg's font database also loads the host's fonts, through fontconfig, the
## XDG data directories and the home directory, and falls back to them for
## every glyph the main font lacks. The calc session's toolbar
## (`fixtures/toolbar-glyphs.cast`: ↶ ↷ ⇣ ⇡ ⏴ ⏵ ⏮ ⌕, none of them in
## JetBrains Mono) was drawn with whatever the caller's environment listed.
## On 2026-11-26 that was Adwaita Mono, through usvg, 2214 times in a render
## whose agg then aborted. The studio now runs agg in an environment naming
## only the pinned fonts. This suite checks that environment, then renders the
## fixture twice: once as the dev shell leaves it, and once with a decoy font
## in the caller's XDG data path. Both must come out byte for byte the same,
## with no fallback to the decoy.
##
## The render check needs agg, DVS_STUDIO_FONT_DIR and
## DVS_STUDIO_FALLBACK_FONT_DIRS (the dev shell provides all three).

import std/[os, osproc, strtabs, strutils, unittest]
import ../src/demo_video_studio/render

let fixture = currentSourcePath().parentDir / "fixtures" / "toolbar-glyphs.cast"

suite "rasterising a cast":

  test "agg's environment names the pinned fonts and nothing of the caller's":
    let work = getTempDir() / ("tcast-raster-env-" & $getCurrentProcessId())
    createDir(work)
    defer: removeDir(work)
    putEnv("XDG_DATA_DIRS", "/usr/share:/somewhere/else")
    let env = aggFontEnv(work, @["/fonts/a", "/fonts/b"])
    let conf = readFile(env["FONTCONFIG_FILE"])
    check "<dir>/fonts/a</dir>" in conf and "<dir>/fonts/b</dir>" in conf
    check conf.count("<dir>") == 2
    check env["XDG_DATA_DIRS"].startsWith(work)
    check env["HOME"].startsWith(work)
    check not env.hasKey("LD_PRELOAD")

  test "the toolbar renders the same whatever fonts the caller's environment lists":
    let agg = getEnv("AGG_BIN", findExe("agg"))
    let fontDir = getEnv("DVS_STUDIO_FONT_DIR")
    let fallback = fallbackFontDirs()
    if agg == "" or fontDir == "" or fallback.len == 0:
      skip()
    else:
      let work = getTempDir() / ("tcast-raster-" & $getCurrentProcessId())
      createDir(work / "decoy" / "fonts")
      defer: removeDir(work)
      # a decoy: a font with arrows, on a fontconfig and an XDG data path of
      # the caller's, the way a host lists its own fonts
      for f in walkDirRec(fallback[^1]):
        if "NotoSansMath" in f.extractFilename:
          copyFile(f, work / "decoy" / "fonts" / f.extractFilename)
          break
      writeFile(work / "decoy.conf", "<?xml version=\"1.0\"?>\n<fontconfig><dir>" &
                work / "decoy" / "fonts" & "</dir></fontconfig>\n")
      let plainFc = getEnv("FONTCONFIG_FILE")
      let plainXdg = getEnv("XDG_DATA_DIRS")
      var outs: seq[string]
      for i in 0 .. 1:
        if i == 1:
          putEnv("FONTCONFIG_FILE", work / "decoy.conf")
          putEnv("XDG_DATA_DIRS", work / "decoy")
        let gif = work / ("toolbar-" & $i & ".gif")
        let sub = work / ("run-" & $i)
        createDir(sub)
        runAgg(aggArgv(agg, fixture, gif, fontDir, "JetBrains Mono", 16, fallback),
               aggFontEnv(sub, @[fontDir] & fallback), "rasterising the fixture")
        outs.add readFile(gif)
      # the control: agg run in the caller's environment, as before the fix,
      # does draw the toolbar differently with the decoy listed
      var inherited: seq[string]
      for i in 0 .. 1:
        if i == 0:
          putEnv("FONTCONFIG_FILE", plainFc)
          putEnv("XDG_DATA_DIRS", plainXdg)
        else:
          putEnv("FONTCONFIG_FILE", work / "decoy.conf")
          putEnv("XDG_DATA_DIRS", work / "decoy")
        let gif = work / ("inherited-" & $i & ".gif")
        let (o, code) = execCmdEx(quoteShellCommand(@[agg, "--quiet", "--no-loop", "--font-dir",
          fontDir, "--font-family", "JetBrains Mono", "--font-size", "16", fixture, gif]))
        check code == 0
        if code != 0: echo o
        inherited.add readFile(gif)
      check inherited[0] != inherited[1]
      check outs[0].len > 1000
      check outs[0] == outs[1]
