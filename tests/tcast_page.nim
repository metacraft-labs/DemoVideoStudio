## A terminal recording as a page (`cast_page`): asciinema's own player, the
## flake's pinned release, inlined with the cast so the page plays from
## `file://`. The page is checked as written and then played in a real
## Chromium (playwright-core, as tscenario_ui): the terminal shows the cast's
## text and the page asks the network for nothing.
##
## Needs DVS_ASCIINEMA_PLAYER_DIR (the dev shell sets it); the played check
## also DVS_PLAYWRIGHT_CORE with node on PATH.

import std/[json, os, osproc, strutils, unittest]
import ../src/demo_video_studio/cast_page

let player = defaultPlayerDir()
doAssert player.len > 0, "DVS_ASCIINEMA_PLAYER_DIR is not set (see the header of this file)"

const sample = """{"version":2,"width":40,"height":6,"timestamp":1795579611}
[0.1,"o","$ ct record calc\r\n"]
[0.4,"o","recording </script> calc\r\n"]
[0.9,"o","\u001b[1mtrace saved\u001b[0m\r\n"]
"""

suite "a cast page":

  test "a cast that is not asciicast v2 or v3 is refused":
    expect CastPageError: checkCast("")
    expect CastPageError: checkCast("not json\n")
    expect CastPageError: checkCast("""{"version":1}""" & "\n")
    expect CastPageError: checkCast("""{"version":2,"width":1,"height":1}""" & "\n[0.1, \"o\"]\n")
    checkCast(sample)

  test "the page inlines the player and the cast, and nothing ends its scripts early":
    let page = castPage(sample, readFile(player / "asciinema-player.min.js"),
                        readFile(player / "asciinema-player.css"), "calc <demo>")
    check "<title>calc &lt;demo&gt;</title>" in page
    check "asciinema-player " & AsciinemaPlayerVersion in page
    check "AsciinemaPlayer.create({ data: cast }" in page
    check "recording <\\/script> calc" in page
    check page.count("</script>") == 2
    # nothing is fetched: no external script, stylesheet or font
    check "<script src" notin page and "<link" notin page and "url(http" notin page

  test "the page plays from file:// with no network":
    if getEnv("DVS_PLAYWRIGHT_CORE") == "" or findExe("node") == "":
      skip()
    else:
      let dir = getTempDir() / "dvs-cast-page-" & $getCurrentProcessId()
      createDir(dir)
      defer: removeDir(dir)
      writeFile(dir / "t.cast", sample)
      writeCastPage(dir / "t.cast", dir / "t.html", player)
      let (o, code) = execCmdEx(quoteShellCommand(@[findExe("node"),
        currentSourcePath().parentDir / "browser/cast_page.mjs", dir / "t.html", "1.5"]))
      check code == 0
      let r = parseJson(o.strip.splitLines[^1])
      check r["errors"].len == 0
      check r["network"].len == 0
      check abs(r["duration"].getFloat - 0.9) < 0.05
      check r["time"].getFloat >= 0.85
      check "trace saved" in r["text"].getStr
      check "recording </script> calc" in r["text"].getStr
