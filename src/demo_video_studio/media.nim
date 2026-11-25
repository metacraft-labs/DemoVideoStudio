## GuiAssert Media Composition Pipeline
##
## Builds the ffmpeg invocation that stitches together:
##   * a raw screencast video (for example one recorded with
##     `gui_assert/capture`),
##   * a narration WAV produced by the speech synthesizer (this milestone),
##   * a "talking head" avatar video clipped into a circle and parked in the
##     bottom-right corner,
##   * one or more time-bounded captions rendered with `drawtext`,
##
## into a single faststart-flagged MP4 ready for distribution.
##
## The implementation is split into two procs:
##
##   * `buildComposeArgv` is pure: it constructs the argv that would be
##     handed to ffmpeg. This lets tests inspect the filter graph and assert
##     on its shape without paying the cost of an actual render.
##
##   * `composeVideoWithOverlay` is effectful: it calls `buildComposeArgv`
##     and then runs ffmpeg as a subprocess, surfacing failures as a typed
##     `MediaCompositionError`.
##
## The filter graph:
##
##   [0:v] scale=W:H,setsar=1                                         -> [bg]
##   [2:v] scale=AVATAR_W:AVATAR_H,format=yuva420p,
##         geq=lum='p(X,Y)':a='if(...circle mask...)'                 -> [avatar]
##   [bg][avatar] overlay=W-overlay_w-MARGIN:H-overlay_h-MARGIN       -> [vbase]
##   [vbase] drawtext=...,drawtext=...                                -> [vout]
##   [0:a][1:a] amix=inputs=2:duration=longest:dropout_transition=0   -> [aout]
##
## Input streams are wired as:
##
##   -i screencast.mp4    (index 0, has video and possibly silent audio)
##   -i narration.wav     (index 1, audio only)
##   -i avatar.mp4        (index 2, video only — audio is ignored even if present)
##
## When the screencast has no audio track ffmpeg's amix would fail; we
## sidestep that by always synthesising a silent stereo source via the
## `anullsrc` lavfi pseudo-input. The amix then mixes narration with that
## silent base, producing audio that is exactly the narration but routed
## through a stable filter graph regardless of source audio presence.

import std/[options, os, osproc, streams, strformat, strtabs, strutils]

import ./avatar_track
export avatar_track
import gui_assert/ffmpeg_tools
export ffmpeg_tools

type
  Caption* = object
    ## A single time-bounded subtitle overlay rendered through ffmpeg's
    ## `drawtext` filter.
    text*: string
    startTime*: float
    endTime*: float
    x*: Option[string]
      ## Optional ffmpeg-expression override for the X coordinate. When
      ## absent the caption is centered horizontally: `(w-text_w)/2`.
    y*: Option[string]
      ## Optional ffmpeg-expression override for the Y coordinate. When
      ## absent the caption is placed in the lower third, above the avatar:
      ## `h-(h/6)-text_h`.
    textFile*: Option[string]
      ## Optional path to a file holding the caption text. When set, the
      ## clause uses drawtext's `textfile=` instead of `text=`. This is the
      ## robust way to render multi-line captions (real newlines) and text
      ## with awkward characters (apostrophes, colons): the file content is
      ## read verbatim, sidestepping the filtergraph escaping rules that make
      ## inline `text=` unsafe for wrapped, punctuated sentences. When absent,
      ## the inline `text` field is used as before.

  OverlayMode* = enum
    ## How the avatar source is composited onto the screencast.
    omCircle = "circle"
      ## Classic bottom-right circular crop (the historical default).
      ## `avatarWidth` x `avatarHeight` are honoured verbatim, and a
      ## hard alpha-circle mask is drawn via the `geq` filter.
    omChromaKey = "chromakey"
      ## Green-screen extraction (default for the new presenter
      ## layout). The avatar source is scaled to `avatarHeight`
      ## preserving aspect, its chosen colour is removed via
      ## `chromakey`, and the remaining pixels are anchored to the
      ## canvas's bottom edge so the figure naturally extends to
      ## the lower edge of the video.

  OverlayAnchor* = enum
    oaBottomLeft = "bottom_left"
    oaBottomRight = "bottom_right"
    oaBottomCenter = "bottom_center"

  KeyMethod* = enum
    ## How the avatar's background colour is removed in `omChromaKey`
    ## mode.  Different backends emit different background characters
    ## so different ffmpeg filters key them cleanly:
    kmChroma = "chroma"
      ## `chromakey` — YUV-space difference against the target colour.
      ## Best fit for *chromatic* backgrounds (green / blue screens)
      ## where the chrominance is far from any pixel in the foreground.
      ## Falls down on neutral-toned backgrounds (white / grey) where
      ## every grayscale pixel shares the target's chrominance and the
      ## filter mistakenly keys out parts of the figure.
    kmColor = "color"
      ## `colorkey` — RGB-space distance against the target colour.
      ## Best fit for *solid neutral* backgrounds (white, black, grey)
      ## or any single RGB tone the figure does not contain.  Use this
      ## for the white-studio outputs HeyGen / D-ID / Synthesia emit
      ## by default, where the presenter is in colour and the
      ## background is near-white.
    kmLuma = "luma"
      ## `lumakey` — luminance-only threshold.  Useful when the
      ## background is the brightest (or darkest) thing in frame and
      ## the figure contains the target colour too — e.g. a presenter
      ## in a white shirt on a slightly-grey wall, where colorkey on
      ## white would eat the shirt.

  CropPolicy* = enum
    ## Pre-key crop applied to the avatar source.  Picks a roughly
    ## centred subregion before scaling so callers can isolate just
    ## the head (or head + shoulders) of a portrait-framed avatar.
    cpFull = "full"
      ## No crop — the entire source is used.  Equivalent to the
      ## historical behaviour.
    cpHeadOnly = "head_only"
      ## Crop to the upper-centre 35 % x 35 % of the source.  Suits
      ## "head shot" placement where only the face shows.
    cpHeadShoulders = "head_shoulders"
      ## Crop to the upper-centre 55 % x 55 % of the source.  Keeps
      ## the chest line so the figure has a natural lower edge.
    cpUpperBody = "upper_body"
      ## Crop to the upper-centre 75 % x 75 % of the source.  Closer
      ## to the historical "all of the frame" layout but trims wide
      ## studio padding.
    cpCustom = "custom"
      ## Use the explicit `cropRegion` rectangle verbatim.

  CropRegion* = object
    ## Pixel rectangle within the *source* video, used only when
    ## `CropPolicy = cpCustom`.  All fields are in source pixels;
    ## `w` / `h` of 0 mean "full source extent on that axis".
    x*, y*, w*, h*: int

  OverlayPosition* = enum
    ## Where the keyed avatar lands on the canvas.
    opAnchor = "anchor"
      ## Use `overlayAnchor` plus the per-mode anchor expressions
      ## (`oaBottomLeft` / `oaBottomRight` / `oaBottomCenter`).
    opAbsolute = "absolute"
      ## Use `overlayX` / `overlayY` directly as pixel coordinates.
    opFractional = "fractional"
      ## Use `overlayFracX` / `overlayFracY` as 0..1 fractions of
      ## the *remaining canvas after the overlay's own dimensions*
      ## (i.e. `0,0` = top-left, `1,1` = bottom-right, `0.5,0.5` =
      ## centre).  Convenient when the avatar size is also expressed
      ## as a fraction.

  ChromaKeyConfig* = object
    ## Tuning for the background-removal filter applied in
    ## `omChromaKey` mode.  Defaults are picked so HeyGen / Synthesia
    ## / D-ID green-screen outputs key cleanly without hand-tuning.
    `method`*: KeyMethod
      ## Picks `chromakey` vs `colorkey` vs `lumakey`.  See `KeyMethod`
      ## for the trade-offs.  Defaults to `kmChroma` so the
      ## green-screen path keeps working without an explicit setting.
    color*: string         ## ffmpeg colour expression, e.g. "0x00ff00"
    similarity*: float     ## 0.01 .. 0.5 — how close to `color` counts
    blend*: float          ## 0.0 .. 1.0 — soft edge falloff
    lumaThreshold*: float  ## 0.0 .. 1.0 — only used by `kmLuma`
    lumaTolerance*: float  ## 0.0 .. 1.0 — only used by `kmLuma`
    despill*: bool         ## apply `despill` after keying to fix edge bleed
    despillType*: string   ## "green" (default) or "blue"

  ComposeOptions* = object
    ## Tunable parameters for the composition. Default values match the
    ## defaults documented in the milestones file: 1920x1080 canvas,
    ## 320x320 circular avatar, 30 px margin.
    canvasWidth*: int
    canvasHeight*: int
    avatarWidth*: int
    avatarHeight*: int
    margin*: int
    overlayMode*: OverlayMode
    overlayAnchor*: OverlayAnchor
    chromaKey*: ChromaKeyConfig
    cropPolicy*: CropPolicy
    cropRegion*: CropRegion
    overlayPosition*: OverlayPosition
    overlayX*: int                ## pixels — used by `opAbsolute`
    overlayY*: int
    overlayFracX*: float          ## 0..1 — used by `opFractional`
    overlayFracY*: float
    fontFile*: Option[string]
      ## Optional absolute path to a TTF font. When omitted we rely on
      ## ffmpeg's drawtext defaults (which on macOS falls back to the
      ## fontconfig-discovered system font).
    fontSize*: int
    fontColor*: string
    boxColor*: string
      ## ffmpeg color expression for the caption background box (e.g.
      ## "black@0.5" for 50%-opaque black). Set to the empty string to
      ## disable the background box entirely.
    videoArgs*: seq[string]
      ## The final encode's codec arguments (`UiVideoArgs` by default): the
      ## one lossy generation a composition makes.
    useAvatarAudio*: bool
      ## When `true`, the output's audio is taken directly from the
      ## avatar (input 2) — useful when the avatar source is a
      ## talking-head render that already contains the spoken line and
      ## the caller does not want to mix in a separately-synthesized
      ## narration WAV.  When `false` (the historical default) the
      ## narration WAV (input 1) is mixed with a synthesised silent
      ## stereo source to produce the output audio.

proc sanitizedEnvForFfmpeg(ffmpegPath: string): StringTableRef =
  ## Build an environment for invoking the chosen ffmpeg. On macOS, when the
  ## binary lives in `/nix/store`, we strip `DYLD_LIBRARY_PATH` so the dynamic
  ## linker does not splice in incompatible libraries from `/opt/homebrew/lib`
  ## (a common situation on Apple Silicon dev boxes where Homebrew's ffmpeg
  ## libs co-exist with the Nix-built ones).
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k == "DYLD_LIBRARY_PATH" or k == "DYLD_FALLBACK_LIBRARY_PATH":
      when defined(macosx):
        if ffmpegPath.startsWith("/nix/"): continue
    result[k] = v

proc defaultChromaKey*(): ChromaKeyConfig =
  ## Defaults tuned for the green-screen outputs HeyGen / Synthesia /
  ## D-ID emit when their `background` field is set to a solid green.
  ChromaKeyConfig(`method`: kmChroma, color: "0x00ff00",
                  similarity: 0.18, blend: 0.08,
                  lumaThreshold: 0.9, lumaTolerance: 0.05,
                  despill: true, despillType: "green")

proc whiteScreenChromaKey*(): ChromaKeyConfig =
  ## RGB-space `colorkey` against pure white, tuned to extract a
  ## presenter from the default HeyGen / D-ID / Synthesia studio
  ## background without keying the figure's skin highlights.  Use
  ## this when you have an existing render whose background is white
  ## and you don't want to spend a credit re-rendering with
  ## `background = green_screen`.
  ChromaKeyConfig(`method`: kmColor, color: "white",
                  similarity: 0.10, blend: 0.05,
                  lumaThreshold: 0.9, lumaTolerance: 0.05,
                  despill: false, despillType: "")

const
  ColorTags* = @["-colorspace", "smpte170m", "-color_primaries", "bt709",
                 "-color_trc", "bt709", "-color_range", "tv"]
    ## What ffmpeg's RGB to YUV conversion produces (the BT.601 matrix,
    ## limited range, of sRGB-primaried pixels), said in the stream, so no
    ## player has to guess it. Untagged, Safari and Chrome guessed apart.
  UiVideoArgs* = @["-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv444p",
                   "-g", "60"] & ColorTags
    ## The default final encode of a UI screencast: H.264 High 4:4:4, which
    ## keeps the chroma of coloured text that 4:2:0 halves, and plays in
    ## Chrome and Safari (not Firefox: the page offers it AV1 first). See
    ## DemoVideoScript-pm spec/Codec-Study.md.
  LosslessVideoArgs* = @["-c:v", "libx264rgb", "-preset", "ultrafast", "-qp", "0"]
    ## An intermediate: RGB, lossless, fast. A composition's inputs are kept
    ## in it so that only the final encode loses anything.

const VideoCodecNames* = ["h264", "h264-444", "hevc", "hevc-444", "vp9", "vp9-444",
                          "av1", "av1-444", "lossless"]

proc videoCodecArgs*(name: string): seq[string] =
  ## The encoder arguments for one of the named final encodes
  ## (`VideoCodecNames`). Every one keeps a keyframe every two seconds at
  ## 30 fps, so a browser can seek. Raises ValueError for an unknown name.
  case name
  of "h264": @["-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-g", "60"] & ColorTags
  of "h264-444": UiVideoArgs
  of "hevc": @["-c:v", "libx265", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p",
               "-tag:v", "hvc1", "-x265-params", "keyint=60:log-level=error"] & ColorTags
  of "hevc-444": @["-c:v", "libx265", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv444p",
                   "-tag:v", "hvc1", "-x265-params", "keyint=60:log-level=error"] & ColorTags
  of "vp9": @["-c:v", "libvpx-vp9", "-crf", "28", "-b:v", "0", "-pix_fmt", "yuv420p",
              "-row-mt", "1", "-deadline", "good", "-cpu-used", "2", "-g", "60"] & ColorTags
  of "vp9-444": @["-c:v", "libvpx-vp9", "-crf", "28", "-b:v", "0", "-pix_fmt", "yuv444p",
                  "-profile:v", "1", "-row-mt", "1", "-deadline", "good", "-cpu-used", "2", "-g", "60"] & ColorTags
  of "av1": @["-c:v", "libsvtav1", "-crf", "28", "-preset", "6", "-pix_fmt", "yuv420p",
              "-svtav1-params", "scm=1:keyint=60"] & ColorTags
  of "av1-444": @["-c:v", "libaom-av1", "-crf", "28", "-b:v", "0", "-cpu-used", "6",
                  "-row-mt", "1", "-tune-content", "screen", "-pix_fmt", "yuv444p", "-g", "60"] & ColorTags
  of "lossless": LosslessVideoArgs
  else: raise newException(ValueError, "unknown codec '" & name & "' (one of " &
                           VideoCodecNames.join(", ") & ")")

proc videoArgsOf(opts: ComposeOptions): seq[string] =
  if opts.videoArgs.len > 0: opts.videoArgs else: UiVideoArgs

proc audioArgsFor*(videoArgs: seq[string]): seq[string] =
  ## AAC beside H.264/HEVC in MP4; Opus beside VP9/AV1 in WebM.
  for a in videoArgs:
    if a.startsWith("libvpx") or a.startsWith("libaom") or a.startsWith("libsvtav1"):
      return @["-c:a", "libopus", "-b:a", "128k"]
  @["-c:a", "aac", "-b:a", "192k"]

proc defaultComposeOptions*(): ComposeOptions =
  ## Returns the canonical composition options used by the verification
  ## harness and by callers who do not pass overrides.
  ComposeOptions(
    canvasWidth: 1920,
    canvasHeight: 1080,
    avatarWidth: 320,
    avatarHeight: 320,
    margin: 30,
    overlayMode: omCircle,
    overlayAnchor: oaBottomRight,
    chromaKey: defaultChromaKey(),
    cropPolicy: cpFull,
    cropRegion: CropRegion(),
    overlayPosition: opAnchor,
    overlayX: 0, overlayY: 0,
    overlayFracX: 0.0, overlayFracY: 1.0,
    fontFile: none(string),
    fontSize: 36,
    fontColor: "white",
    boxColor: "black@0.5"
  )

proc presenterComposeOptions*(): ComposeOptions =
  ## Returns options for the green-screen presenter layout: the
  ## avatar's green background is chroma-keyed out and the remaining
  ## figure is anchored to the canvas's bottom-left edge so the
  ## human body extends naturally to the lower edge of the video.
  result = defaultComposeOptions()
  result.overlayMode = omChromaKey
  result.overlayAnchor = oaBottomLeft
  # Avatar height defaults to ~60% of canvas height so the head fits
  # within the upper portion while the body extends to the bottom.
  result.avatarHeight = int(float(result.canvasHeight) * 0.6)
  result.avatarWidth = -1                 ## preserve aspect

# ---------------------------------------------------------------------------
# drawtext escaping
# ---------------------------------------------------------------------------
#
# ffmpeg's filter graph syntax is famously irritating. Inside a filter
# argument we must escape backslashes, single quotes, colons, percents, and
# any other separator-like character. A value is wrapped in single quotes and
# read twice: first by the filter graph, where a quoted run is literal and
# `\` escapes one character outside quotes, then by the option parser, which
# reads `\` the same way. So a single quote closes the quoted run, appears
# as `\\\'` (the graph leaves `\'`, the option parser `'`) and reopens it.
# Written as the shell's `'\''` instead, the option parser met a bare `'` and
# read the rest of the clause — `:fontsize=…:enable=…` — as the caption's text
# ("Step over the module's definitions" drew its own options). A percent is
# read a third time, by drawtext's own expansion, which wants `\%`: so it is
# `\\%` here.

proc escapeDrawtext*(s: string): string =
  ## Escape a string for inclusion as a `drawtext` option value, wrapped
  ## inside single quotes by the caller.
  result = newStringOfCap(s.len + 16)
  for ch in s:
    case ch
    of '\\': result.add("\\\\")
    of '\'': result.add("'\\\\\\''")
    of ':':  result.add("\\:")
    of '%':  result.add("\\\\%")
    else:    result.add(ch)

proc buildDrawtextFilter(c: Caption, opts: ComposeOptions): string =
  ## Build a single `drawtext=...` clause for a `Caption`. The clause is
  ## ready to be joined into a longer filter chain with commas.
  let xExpr =
    if c.x.isSome: c.x.get
    else: "(w-text_w)/2"
  let yExpr =
    if c.y.isSome: c.y.get
    else: "h-(h/6)-text_h"
  var parts: seq[string] = @[]
  if c.textFile.isSome:
    # `textfile=` reads the caption text verbatim from disk — the robust path
    # for multi-line / punctuated captions (no filtergraph escaping hazards).
    # Only the path itself needs escaping for the filter argument.
    parts.add("textfile='" & escapeDrawtext(c.textFile.get) & "'")
  else:
    parts.add("text='" & escapeDrawtext(c.text) & "'")
  if opts.fontFile.isSome:
    parts.add("fontfile='" & escapeDrawtext(opts.fontFile.get) & "'")
  parts.add("fontsize=" & $opts.fontSize)
  parts.add("fontcolor=" & opts.fontColor)
  parts.add("borderw=2")
  parts.add("bordercolor=black")
  if opts.boxColor.len > 0:
    parts.add("box=1")
    parts.add("boxcolor=" & opts.boxColor)
    parts.add("boxborderw=12")
  parts.add("x=" & xExpr)
  parts.add("y=" & yExpr)
  parts.add(&"enable=between(t\\,{c.startTime:.3f}\\,{c.endTime:.3f})")
  result = "drawtext=" & parts.join(":")

# ---------------------------------------------------------------------------
# Filter graph assembly
# ---------------------------------------------------------------------------

proc cropFilterFraction(fracW, fracH: float): string =
  ## ffmpeg `crop=` expression for a centred-upper subregion sized as
  ## a fraction of the source.  `(in_w-out_w)/2` centres horizontally;
  ## `0` anchors vertically to the top so head-only crops keep the
  ## face in view.
  &"crop=in_w*{fracW:.3f}:in_h*{fracH:.3f}:(in_w-out_w)/2:0"

proc cropFilterFor(opts: ComposeOptions): string =
  ## Build the optional `crop=...,` prefix applied to the avatar
  ## source before scaling.  Returns an empty string for `cpFull`
  ## so the legacy code path is unchanged.
  case opts.cropPolicy
  of cpFull: ""
  of cpHeadOnly: cropFilterFraction(0.35, 0.35) & ","
  of cpHeadShoulders: cropFilterFraction(0.55, 0.55) & ","
  of cpUpperBody: cropFilterFraction(0.75, 0.75) & ","
  of cpCustom:
    let r = opts.cropRegion
    let w = if r.w > 0: $r.w else: "in_w"
    let h = if r.h > 0: $r.h else: "in_h"
    &"crop={w}:{h}:{r.x}:{r.y},"

proc avatarFilterCircle(opts: ComposeOptions): string =
  ## Build the avatar chain for `omCircle` mode (legacy default).
  ## Crops the input to a square (preserving aspect ratio), scales the
  ## source down to the configured target size, promotes to yuva420p
  ## so the `geq` filter can write an alpha channel, and draws a hard
  ## circular alpha mask leaving Y/U/V untouched.
  let cropFilter =
    if opts.cropPolicy == cpFull:
      "crop='min(iw,ih):min(iw,ih)',"
    else:
      cropFilterFor(opts) & "crop='min(iw,ih):min(iw,ih)',"
  &"[2:v]{cropFilter}scale={opts.avatarWidth}:{opts.avatarHeight}," &
    "format=yuva420p," &
    "geq=lum='p(X,Y)':cb='p(X,Y)':cr='p(X,Y)':" &
    "a='if(lte(hypot(X-W/2,Y-H/2),W/2),255,0)'[avatar]"

proc avatarFilterChromaKey(opts: ComposeOptions): string =
  ## Build the avatar chain for `omChromaKey` mode.  Optionally
  ## crops the source first (head-only / head + shoulders / upper
  ## body / custom rectangle), then scales preserving aspect
  ## (passing `width = -1` so ffmpeg derives the proportional
  ## width), promotes to `yuva420p` so the chosen keying filter can
  ## write into the alpha channel, removes the configured
  ## background via one of three filters (`chromakey` / `colorkey`
  ## / `lumakey`), and applies an optional `despill` pass to fix
  ## the residual green or blue spill at the figure's edges.
  let w =
    if opts.avatarWidth <= 0: -1
    else: opts.avatarWidth
  let ck = opts.chromaKey
  let keyExpr =
    case ck.`method`
    of kmChroma:
      &"chromakey={ck.color}:{ck.similarity}:{ck.blend}"
    of kmColor:
      &"colorkey=color={ck.color}:similarity={ck.similarity}:blend={ck.blend}"
    of kmLuma:
      &"lumakey=threshold={ck.lumaThreshold}:tolerance={ck.lumaTolerance}"
  let despillExpr =
    if ck.despill:
      ",despill=type=" & (if ck.despillType.len > 0: ck.despillType else: "green")
    else: ""
  let cropPrefix = cropFilterFor(opts)
  &"[2:v]" & cropPrefix &
    &"scale={w}:{opts.avatarHeight}," &
    "format=yuva420p," &
    keyExpr & despillExpr & "[avatar]"

proc overlayExpression(opts: ComposeOptions): string =
  ## Compute the `overlay=x:y` expression for the configured anchor
  ## or explicit position.  `H`/`W` resolve to the canvas dimensions
  ## and `overlay_w`/`overlay_h` to the scaled avatar dimensions.
  case opts.overlayPosition
  of opAbsolute:
    &"{opts.overlayX}:{opts.overlayY}"
  of opFractional:
    &"(W-overlay_w)*{opts.overlayFracX:.4f}:(H-overlay_h)*{opts.overlayFracY:.4f}"
  of opAnchor:
    case opts.overlayAnchor
    of oaBottomRight:
      &"W-overlay_w-{opts.margin}:H-overlay_h-{opts.margin}"
    of oaBottomLeft:
      case opts.overlayMode
      of omCircle:
        &"{opts.margin}:H-overlay_h-{opts.margin}"
      of omChromaKey:
        &"{opts.margin}:H-overlay_h"
    of oaBottomCenter:
      case opts.overlayMode
      of omCircle:
        &"(W-overlay_w)/2:H-overlay_h-{opts.margin}"
      of omChromaKey:
        "(W-overlay_w)/2:H-overlay_h"

proc buildFilterComplex*(
    captions: seq[Caption], opts: ComposeOptions): string =
  ## Build the full `-filter_complex` argument value.
  let bgScale = &"[0:v]scale={opts.canvasWidth}:{opts.canvasHeight}:force_original_aspect_ratio=decrease," &
                &"pad={opts.canvasWidth}:{opts.canvasHeight}:(ow-iw)/2:(oh-ih)/2,setsar=1[bg]"

  let avatarFilter =
    case opts.overlayMode
    of omCircle:    avatarFilterCircle(opts)
    of omChromaKey: avatarFilterChromaKey(opts)

  let overlayFilter =
    "[bg][avatar]overlay=" & overlayExpression(opts)

  # Captions chain. If there are no captions we close out the overlay
  # straight into [vout] so downstream `-map [vout]` still works.
  var captionChain = ""
  if captions.len > 0:
    var pieces: seq[string] = @[]
    for c in captions:
      pieces.add(buildDrawtextFilter(c, opts))
    captionChain = "," & pieces.join(",")
  let videoChain = overlayFilter & captionChain & "[vout]"

  # Audio: by default mix narration (input 1) with a synthesised silent
  # base (input 3 via the `anullsrc` lavfi pseudo-input added in
  # `buildComposeArgv`).  This keeps the graph stable whether or not the
  # screencast itself has audio.  When `useAvatarAudio` is true the
  # avatar's own audio stream (input 2) is used verbatim — letting
  # talking-head renders carry through the provider's TTS rather than
  # the locally synthesised narration.
  let audioChain =
    if opts.useAvatarAudio:
      "[2:a]aresample=async=1:first_pts=0,asetpts=PTS-STARTPTS[aout]"
    else:
      "[3:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0[aout]"

  result = @[
    bgScale,
    avatarFilter,
    videoChain,
    audioChain
  ].join(";")

# ---------------------------------------------------------------------------
# Full argv assembly
# ---------------------------------------------------------------------------

proc buildComposeArgv*(
    screencastPath, narrationWavPath, avatarVideoPath, outputPath: string,
    captions: seq[Caption],
    opts: ComposeOptions = defaultComposeOptions(),
    ffmpegBin: string = "ffmpeg"): seq[string] =
  ## Build the complete ffmpeg argv. The result is suitable both for direct
  ## subprocess invocation and for inspection in unit tests. `ffmpegBin`
  ## defaults to the bare token "ffmpeg" so the argv reads naturally in
  ## tests; pass `resolveFfmpegBinary()` when actually shelling out.
  let filter = buildFilterComplex(captions, opts)
  result = @[
    ffmpegBin,
    "-y",
    "-hide_banner",
    "-loglevel", "error",
    "-i", ffmpegInputUrl(screencastPath),
    "-i", ffmpegInputUrl(narrationWavPath),
    "-i", ffmpegInputUrl(avatarVideoPath),
    "-f", "lavfi", "-t", "3600",
    "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
    "-filter_complex", filter,
    "-map", "[vout]",
    "-map", "[aout]"] & videoArgsOf(opts) & audioArgsFor(videoArgsOf(opts)) & @[
    "-movflags", "+faststart",
    "-shortest",
    outputPath
  ]

# ---------------------------------------------------------------------------
# Avatar track — piecewise-linear ffmpeg expression assembly
# ---------------------------------------------------------------------------

proc fmtFloat(f: float): string =
  ## Format a float for an ffmpeg filter expression without locale
  ## surprises.  Produces `0.2`, `0`, `1.5` — never scientific
  ## notation, never a trailing decimal point.
  result = formatFloat(f, ffDecimal, precision = 4)
  if '.' in result:
    while result.len > 1 and result[^1] == '0':
      result.setLen(result.len - 1)
    if result.len > 1 and result[^1] == '.':
      result.setLen(result.len - 1)

proc piecewiseExpr(times, values: seq[float]): string =
  ## Build a piecewise-linear expression in `t` for the given keyframe
  ## (time, value) sequence.  Outside the range we hold the boundary
  ## value; between consecutive keyframes we linearly interpolate.
  doAssert times.len == values.len and times.len > 0,
    "piecewise expression needs at least one keyframe"
  if times.len == 1:
    return fmtFloat(values[0])
  # Build nested `if(lt(t, t_i), seg_i, ...)` from the inside out.
  # The innermost else is the final value (held).
  var expr = fmtFloat(values[^1])
  for i in countdown(times.len - 1, 1):
    let t0 = fmtFloat(times[i - 1])
    let t1 = fmtFloat(times[i])
    let v0 = fmtFloat(values[i - 1])
    let v1 = fmtFloat(values[i])
    # Linear ramp between (t0, v0) and (t1, v1).
    let segment =
      "(" & v0 & "+(" & v1 & "-" & v0 & ")*(t-" & t0 & ")/(" & t1 & "-" & t0 & "))"
    expr = "if(lt(t," & t1 & ")," & segment & "," & expr & ")"
  # Hold the first value before t0.
  let t0 = fmtFloat(times[0])
  let v0 = fmtFloat(values[0])
  expr = "if(lt(t," & t0 & ")," & v0 & "," & expr & ")"
  result = expr

type
  AvatarExprSet* = object
    ## Per-axis piecewise-linear expressions extracted from an
    ## `AvatarTrack`, ready to splice into an ffmpeg filter graph.
    srcCropX*, srcCropY*, srcCropW*, srcCropH*: string
    dstX*, dstY*, dstW*, dstH*: string

proc avatarExprsFor*(track: AvatarTrack;
                     srcWidth, srcHeight: int): AvatarExprSet =
  ## Build piecewise-linear ffmpeg expressions for every animatable
  ## axis of the avatar geometry.  Zero / negative crop dimensions in
  ## a keyframe are resolved to the source's full extent.
  doAssert track.keyframes.len > 0, "avatar track must have at least one keyframe"
  var times: seq[float] = @[]
  var sx, sy, sw, sh, dx, dy, dw, dh: seq[float] = @[]
  for k in track.keyframes:
    times.add k.time
    sx.add k.srcCrop.x
    sy.add k.srcCrop.y
    let kw =
      if k.srcCrop.w > 0: k.srcCrop.w
      else: float(srcWidth) - k.srcCrop.x
    let kh =
      if k.srcCrop.h > 0: k.srcCrop.h
      else: float(srcHeight) - k.srcCrop.y
    sw.add kw
    sh.add kh
    dx.add k.dstRect.x
    dy.add k.dstRect.y
    dw.add k.dstRect.w
    dh.add k.dstRect.h
  result = AvatarExprSet(
    srcCropX: piecewiseExpr(times, sx),
    srcCropY: piecewiseExpr(times, sy),
    srcCropW: piecewiseExpr(times, sw),
    srcCropH: piecewiseExpr(times, sh),
    dstX: piecewiseExpr(times, dx),
    dstY: piecewiseExpr(times, dy),
    dstW: piecewiseExpr(times, dw),
    dstH: piecewiseExpr(times, dh),
  )

proc avatarKeyFilterExpr*(k: AvatarKeyframe): string =
  ## ffmpeg keying filter for the avatar's chrominance / luminance /
  ## colour key as configured by the *first* keyframe of the track.
  ## (Key parameters do not animate — only geometry does.)
  case k.keyMethod
  of akmChroma:
    "chromakey=" & k.keyColor & ":" & fmtFloat(k.keySimilarity) &
      ":" & fmtFloat(k.keyBlend)
  of akmColor:
    "colorkey=color=" & k.keyColor &
      ":similarity=" & fmtFloat(k.keySimilarity) &
      ":blend=" & fmtFloat(k.keyBlend)
  of akmLuma:
    "lumakey=threshold=" & fmtFloat(k.lumaThreshold) &
      ":tolerance=" & fmtFloat(k.lumaTolerance)
  of akmCircle:
    # a presenter filmed on any background, shown in a circle (the crop
    # before it is square)
    "geq=lum='p(X,Y)':cb='p(X,Y)':cr='p(X,Y)':" &
      "a='if(lte(hypot(X-W/2,Y-H/2),min(W,H)/2),255,0)'"

proc buildAvatarTrackFilter*(track: AvatarTrack;
                             canvasWidth, canvasHeight: int;
                             srcWidth, srcHeight: int): string =
  ## Build the `-filter_complex` value for `composeVideoWithAvatarTrack`.
  ## Inputs: `[0:v]` = screencast, `[1:v]` = avatar source.
  ## Outputs: `[vout]` (no audio mixing — caller chooses an audio map).
  doAssert track.keyframes.len > 0
  let e = avatarExprsFor(track, srcWidth, srcHeight)
  let k0 = track.keyframes[0]
  let keyExpr = avatarKeyFilterExpr(k0)
  let despill =
    if k0.despill: ",despill=type=" &
      (if k0.despillType.len > 0: k0.despillType else: "green")
    else: ""
  let bg = &"[0:v]scale={canvasWidth}:{canvasHeight}:" &
           "force_original_aspect_ratio=decrease," &
           &"pad={canvasWidth}:{canvasHeight}:(ow-iw)/2:(oh-ih)/2," &
           "setsar=1[bg]"
  # Source crop with per-frame expressions for x/y/w/h; then scale to
  # dst-rect dimensions (also per-frame); then key + optional despill.
  let av = "[1:v]" &
    &"crop=w='{e.srcCropW}':h='{e.srcCropH}':x='{e.srcCropX}':y='{e.srcCropY}':exact=1," &
    &"scale=w='{e.dstW}':h='{e.dstH}':eval=frame:flags=bicubic," &
    "format=yuva420p," &
    keyExpr & despill & "[avatar]"
  # in 4:4:4, so the screencast under the presenter keeps its chroma until
  # the final encode
  let ov = &"[bg][avatar]overlay=x='{e.dstX}':y='{e.dstY}':eval=frame:format=yuv444[vout]"
  result = @[bg, av, ov].join(";")

proc composeVideoWithAvatarTrack*(
    screencastPath, avatarVideoPath, outputPath: string;
    track: AvatarTrack;
    canvasWidth, canvasHeight: int;
    srcWidth, srcHeight: int;
    useAvatarAudio = true; videoArgs: seq[string] = @[]) =
  ## Run ffmpeg with an animated avatar overlay derived from `track`.
  ## `srcWidth` and `srcHeight` are the pixel dimensions of the avatar
  ## source video (the caller probes them with ffprobe).
  if not fileExists(screencastPath):
    raise newException(MediaCompositionError,
      "Screencast not found: " & screencastPath)
  if not fileExists(avatarVideoPath):
    raise newException(MediaCompositionError,
      "Avatar video not found: " & avatarVideoPath)
  if track.keyframes.len == 0:
    raise newException(MediaCompositionError,
      "Avatar track has no keyframes")
  validate(track)
  let parent = outputPath.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  let ffmpegBin = resolveFfmpegBinary()
  let filter = buildAvatarTrackFilter(track,
                                      canvasWidth, canvasHeight,
                                      srcWidth, srcHeight)
  var argv = @[
    ffmpegBin, "-y", "-hide_banner", "-loglevel", "error",
    "-i", ffmpegInputUrl(screencastPath),
    "-i", ffmpegInputUrl(avatarVideoPath),
    "-filter_complex", filter,
    "-map", "[vout]",
  ]
  if useAvatarAudio:
    argv.add @["-map", "1:a?"]
  else:
    argv.add @["-map", "0:a?"]
  let vargs = if videoArgs.len > 0: videoArgs else: UiVideoArgs
  argv.add vargs & audioArgsFor(vargs) & @[
    "-movflags", "+faststart",
    "-shortest",
    outputPath
  ]
  let env = sanitizedEnvForFfmpeg(ffmpegBin)
  let process = startProcess(
    command = argv[0],
    args = argv[1 .. ^1],
    env = env,
    options = {poStdErrToStdOut}
  )
  let output = process.outputStream().readAll()
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    raise newException(
      MediaCompositionError,
      "ffmpeg exited with code " & $exitCode & ":\n" & output
    )
  if not fileExists(outputPath) or getFileSize(outputPath) <= 0:
    raise newException(
      MediaCompositionError,
      "ffmpeg produced no usable file at " & outputPath
    )

proc composeVideoWithOverlay*(
    screencastPath, narrationWavPath, avatarVideoPath, outputPath: string,
    captions: seq[Caption],
    opts: ComposeOptions = defaultComposeOptions()) =
  ## Run ffmpeg with the argv produced by `buildComposeArgv` and validate
  ## that an output file landed at `outputPath`. Raises
  ## `MediaCompositionError` on any failure.
  if not fileExists(screencastPath):
    raise newException(MediaCompositionError, "Screencast not found: " & screencastPath)
  if not fileExists(narrationWavPath):
    raise newException(MediaCompositionError, "Narration WAV not found: " & narrationWavPath)
  if not fileExists(avatarVideoPath):
    raise newException(MediaCompositionError, "Avatar video not found: " & avatarVideoPath)

  let parent = outputPath.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)

  let ffmpegBin = resolveFfmpegBinary()
  let argv = buildComposeArgv(
    screencastPath, narrationWavPath, avatarVideoPath, outputPath,
    captions, opts, ffmpegBin
  )

  let envForFfmpeg = sanitizedEnvForFfmpeg(ffmpegBin)
  let process = startProcess(
    command = argv[0],
    args = argv[1 .. ^1],
    env = envForFfmpeg,
    options = {poStdErrToStdOut}
  )
  let output = process.outputStream().readAll()
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    raise newException(
      MediaCompositionError,
      "ffmpeg exited with code " & $exitCode & ":\n" & output
    )
  if not fileExists(outputPath):
    raise newException(
      MediaCompositionError,
      "ffmpeg reported success but no file at " & outputPath
    )
  if getFileSize(outputPath) <= 0:
    raise newException(
      MediaCompositionError,
      "ffmpeg produced a zero-byte file at " & outputPath
    )

# ---------------------------------------------------------------------------
# Silent render — no narration, no presenter, no provider
# ---------------------------------------------------------------------------
#
# Narration and the presenter overlay are optional stages: a render with
# neither needs no speech or talking-head provider and no network. It is
# the screencast on the canvas, with its captions, and a silent stereo
# track so every render has the same stream layout.

proc buildSilentComposeArgv*(
    screencastPath, outputPath: string,
    captions: seq[Caption],
    opts: ComposeOptions = defaultComposeOptions(),
    ffmpegBin: string = "ffmpeg"): seq[string] =
  ## The ffmpeg argv for a silent render (see `composeSilentVideo`).
  var video = &"[0:v]scale={opts.canvasWidth}:{opts.canvasHeight}:force_original_aspect_ratio=decrease," &
              &"pad={opts.canvasWidth}:{opts.canvasHeight}:(ow-iw)/2:(oh-ih)/2,setsar=1"
  for c in captions:
    video.add "," & buildDrawtextFilter(c, opts)
  video.add "[vout]"
  result = @[
    ffmpegBin, "-y", "-hide_banner", "-loglevel", "error",
    "-i", ffmpegInputUrl(screencastPath),
    "-f", "lavfi", "-t", "3600",
    "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
    "-filter_complex", video,
    "-map", "[vout]",
    "-map", "1:a",
    ] & videoArgsOf(opts) & audioArgsFor(videoArgsOf(opts)) & @[
    "-movflags", "+faststart",
    "-shortest",
    outputPath
  ]

proc composeSilentVideo*(
    screencastPath, outputPath: string,
    captions: seq[Caption] = @[],
    opts: ComposeOptions = defaultComposeOptions()) =
  ## Render the screencast with its captions and no narration or
  ## presenter: no provider is consulted and nothing leaves the host.
  ## Raises `MediaCompositionError` on any failure.
  if not fileExists(screencastPath):
    raise newException(MediaCompositionError, "Screencast not found: " & screencastPath)
  let parent = outputPath.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  let ffmpegBin = resolveFfmpegBinary()
  let argv = buildSilentComposeArgv(screencastPath, outputPath, captions, opts, ffmpegBin)
  let process = startProcess(
    command = argv[0],
    args = argv[1 .. ^1],
    env = sanitizedEnvForFfmpeg(ffmpegBin),
    options = {poStdErrToStdOut}
  )
  let output = process.outputStream().readAll()
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    raise newException(MediaCompositionError,
      "ffmpeg exited with code " & $exitCode & ":\n" & output)
  if not fileExists(outputPath) or getFileSize(outputPath) <= 0:
    raise newException(MediaCompositionError,
      "ffmpeg produced no usable file at " & outputPath)
