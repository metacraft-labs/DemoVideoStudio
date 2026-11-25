## A terminal recording as a page: an asciicast v2 played by asciinema's own
## player (asciinema-player, Apache-2.0), with the player's script, its
## stylesheet and the cast all inlined, so the one file plays from `file://`
## with no network and no server.
##
## The player is the pinned release the flake fetches
## (`DVS_ASCIINEMA_PLAYER_DIR`: its `dist/bundle`, holding
## `asciinema-player.min.js` and `asciinema-player.css`).

import std/[json, os, strutils]

const AsciinemaPlayerVersion* = "3.17.0"
  ## the release `flake.nix` pins; the page names it

type CastPageError* = object of CatchableError

proc castPageError(msg: string): ref CastPageError = newException(CastPageError, msg)

proc defaultPlayerDir*(): string = getEnv("DVS_ASCIINEMA_PLAYER_DIR")

proc checkCast*(text: string) =
  ## Refuses what asciinema-player would not play: a first line that is not
  ## an asciicast v2 or v3 header, or an event line that is not
  ## `[time, code, data]`.
  let lines = text.splitLines
  if lines.len == 0 or lines[0].strip == "": raise castPageError("the cast is empty")
  var header: JsonNode
  try: header = parseJson(lines[0])
  except JsonParsingError: raise castPageError("the cast's first line is not a JSON header")
  if header.kind != JObject or header{"version"}.getInt notin [2, 3]:
    raise castPageError("the cast is not asciicast v2 or v3")
  for i in 1 ..< lines.len:
    let l = lines[i].strip
    if l == "" or l.startsWith("#"): continue
    var e: JsonNode
    try: e = parseJson(l)
    except JsonParsingError: raise castPageError("cast line " & $(i + 1) & " is not JSON")
    if e.kind != JArray or e.len != 3 or e[0].kind notin {JFloat, JInt} or e[1].kind != JString:
      raise castPageError("cast line " & $(i + 1) & " is not [time, code, data]")

proc scriptSafe(s: string): string =
  ## Text that can sit inside a `<script>` element: no `</` ends it early.
  s.replace("</", "<\\/")

proc castPage*(text, playerJs, playerCss: string; title = "terminal";
               fit = "width"): string =
  ## The page for the cast `text`, with the player's script and stylesheet inlined.
  checkCast(text)
  let esc = title.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))
  result = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="generator" content="DemoVideoStudio, asciinema-player """ & AsciinemaPlayerVersion & """">
<title>""" & esc & """</title>
<style>
""" & playerCss.replace("</", "<\\/") & """
</style>
<style>
:root { color-scheme: dark; }
body { margin: 0; padding: 16px; background: #121314; }
main { max-width: 1600px; margin: 0 auto; }
</style>
</head><body>
<main><div id="player"></div></main>
<script>
""" & scriptSafe(playerJs) & """
</script>
<script>
const cast = """ & scriptSafe($(%text)) & """;
window.player = AsciinemaPlayer.create({ data: cast }, document.getElementById("player"),
  { fit: """ & $(%fit) & """, preload: true, autoPlay: false, controls: true });
</script>
</body></html>
"""

proc writeCastPage*(castPath, outPath: string; playerDir = defaultPlayerDir();
                    title = "") =
  ## Writes `castPath`'s page to `outPath`, the player read from `playerDir`.
  if playerDir == "":
    raise castPageError("no asciinema-player: set DVS_ASCIINEMA_PLAYER_DIR (the flake's dev shell does)")
  let js = playerDir / "asciinema-player.min.js"
  let css = playerDir / "asciinema-player.css"
  for f in [js, css]:
    if not fileExists(f): raise castPageError("asciinema-player file missing: " & f)
  if not fileExists(castPath): raise castPageError("no cast at " & castPath)
  let t = if title != "": title else: castPath.splitFile.name
  let dir = outPath.parentDir
  if dir != "": createDir(dir)
  writeFile(outPath, castPage(readFile(castPath), readFile(js), readFile(css), t))
