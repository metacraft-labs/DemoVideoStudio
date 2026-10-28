## A test-run recording, opened in the studio read-only
## (DemoVideoStudio-Editor §5.6; DemoVideoScript-Format §9.1).
##
## The page is the same timeline: the run's steps with their results, the
## failing step selected, and for the selected step its stills and the
## observed state the run recorded. Nothing can be edited, and nothing outside
## the run directory is served.
##
## Routes:
##   GET /api/run          the run: its steps, results, stills and the failing step
##   GET /files/<path>     a file of the run directory
##   GET /…                the page (`editor-web/run.html`)

import std/[asyncdispatch, asynchttpserver, json, os, strutils, uri]

type
  RunView* = ref object
    dir*: string
    manifest*: JsonNode
    webRoot*: string
    server: AsyncHttpServer
    accepting: Future[void]
    port*: Port

  RunViewError* = object of CatchableError

proc openRun*(dir: string; webRoot = ""): RunView =
  let m = dir / "manifest.json"
  if not fileExists(m):
    raise newException(RunViewError, "'" & dir & "' is not a run directory: it has no manifest.json")
  RunView(dir: dir.absolutePath, manifest: parseFile(m),
          webRoot: (if webRoot != "": webRoot
                    else: currentSourcePath().parentDir.parentDir.parentDir / "editor-web"))

proc rel(v: RunView; path: string): string =
  ## A run file's path as served: relative to the run directory.
  let a = (if path.isAbsolute: path else: v.dir / path)
  relativePath(a, v.dir).replace('\\', '/')

proc runJson*(v: RunView): JsonNode =
  let m = v.manifest
  var steps = newJArray()
  var failing = ""
  for s in m{"steps"}.getElems:
    let index = s{"index"}.getInt
    var stills = newJArray()
    for a in s{"artifacts"}.getElems:
      if fileExists(if a.getStr.isAbsolute: a.getStr else: v.dir / a.getStr):
        stills.add %("/files/" & v.rel(a.getStr))
    let state = "steps/" & $index & "-state.json"
    let status = s{"status"}.getStr
    if status == "failed" and failing == "": failing = s{"path"}.getStr
    steps.add %*{"index": index, "path": s{"path"}.getStr, "kind": s{"kind"}.getStr,
                 "beat": s{"beat"}.getStr, "status": status, "message": s{"message"}.getStr,
                 "description": s{"description"}.getStr,
                 "startMs": s{"startMs"}.getFloat, "endMs": s{"endMs"}.getFloat,
                 "stills": stills,
                 "state": (if fileExists(v.dir / state): %("/files/" & state) else: newJNull())}
  var failure = newJArray()
  if dirExists(v.dir / "failure"):
    for f in walkDirRec(v.dir / "failure"): failure.add %("/files/" & v.rel(f))
  var media = newJArray()
  for f in m{"media"}.getElems:
    if fileExists(if f.getStr.isAbsolute: f.getStr else: v.dir / f.getStr):
      media.add %("/files/" & v.rel(f.getStr))
  let be = m{"backend"}
  %*{"dir": v.dir, "scenario": m{"scenario"}.getStr, "outcome": m{"outcome"}.getStr,
     "message": m{"message"}.getStr,
     "backend": (if be != nil and be.kind == JObject: be{"backend"}.getStr else: be.getStr),
     "failing": failing, "steps": steps, "failure": failure, "media": media,
     "readOnly": true}

proc contentType(path: string): string =
  case path.splitFile.ext
  of ".html": "text/html; charset=utf-8"
  of ".js": "text/javascript"
  of ".css": "text/css"
  of ".png": "image/png"
  of ".svg": "image/svg+xml"
  of ".json": "application/json"
  of ".webm": "video/webm"
  of ".txt", ".log", ".cast": "text/plain; charset=utf-8"
  else: "application/octet-stream"

proc dispatch(v: RunView; req: Request) {.async.} =
  let path = req.url.path
  if req.reqMethod != HttpGet:
    await req.respond(Http405, "a recording is opened read-only")
    return
  if path == "/api/run":
    await req.respond(Http200, $v.runJson, newHttpHeaders([("Content-Type", "application/json")]))
    return
  var abs = ""
  if path.startsWith("/files/"):
    let r = decodeUrl(path[7 .. ^1])
    if ".." notin r: abs = v.dir / r
  else:
    let p = (if path == "/" or path == "": "run.html" else: path[1 .. ^1])
    if ".." notin p: abs = v.webRoot / p
  if abs == "" or not fileExists(abs):
    await req.respond(Http404, "not found")
    return
  await req.respond(Http200, readFile(abs), newHttpHeaders([("Content-Type", contentType(abs))]))

proc start*(v: RunView; port = 0) =
  v.server = newAsyncHttpServer()
  v.server.listen(Port(port))
  v.port = v.server.getPort

proc pumpOnce*(v: RunView): Future[bool] {.async.} =
  if v.server == nil: return false
  if v.accepting == nil or v.accepting.finished:
    v.accepting = v.server.acceptRequest(proc (req: Request): Future[void] {.async, gcsafe.} =
      {.cast(gcsafe).}:
        await dispatch(v, req))
  await sleepAsync(10)
  true

proc serveForever*(v: RunView) =
  while v.server != nil:
    discard waitFor v.pumpOnce()

proc stop*(v: RunView) =
  if v.server != nil:
    v.server.close()
    v.server = nil
