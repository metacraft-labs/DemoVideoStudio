## The plugin conformance kit: what every provider plugin's own suite runs
## against its provider, so that "builds against the contract" means the
## same thing in every plugin repository.
##
## Each check returns the problems it found (empty: conformant), so a suite
## reports all of them at once:
##
##   import demo_video_studio/plugins/kit
##   check talkingHeadProblems(myProvider()).len == 0
##
## Offline by default: a check never needs the provider's credentials or
## network. `generate = true` also renders (a provider whose `isAvailable` is
## true must then produce a non-empty file); a credentialed plugin passes it
## only in its gated live suite.

import std/[options, os, strutils, json]
import ./talking_head, ./speech_synthesis

proc scratchDir(tag: string): string =
  result = getTempDir() / ("dvs-studio-kit-" & tag & "-" & $getCurrentProcessId())
  createDir(result)

proc silentWav(path: string; seconds = 1.0) =
  ## A real WAV (16-bit mono PCM, 16 kHz) of silence: a narration any
  ## talking-head provider accepts.
  let rate = 16000
  let n = int(seconds * float(rate))
  var s = "RIFF"
  proc le32(v: int): string =
    result = newString(4)
    for i in 0 .. 3: result[i] = char((v shr (8 * i)) and 0xff)
  proc le16(v: int): string =
    result = newString(2)
    for i in 0 .. 1: result[i] = char((v shr (8 * i)) and 0xff)
  s.add le32(36 + 2 * n)
  s.add "WAVEfmt "
  s.add le32(16) & le16(1) & le16(1) & le32(rate) & le32(rate * 2) & le16(2) & le16(16)
  s.add "data" & le32(2 * n) & newString(2 * n)
  writeFile(path, s)

proc talkingHeadProblems*(p: TalkingHeadProvider; generate = false;
                          opts = TalkingHeadOpts()): seq[string] =
  ## The talking-head contract (version `TalkingHeadContractVersion`).
  if p.name.len == 0: result.add "the provider has no name"
  elif normalizeProviderName(p.name) != p.name:
    result.add "the name '" & p.name & "' is not canonical ('" & normalizeProviderName(p.name) &
      "'): the registry would list it under another name"
  if p.isAvailable.isNil: result.add "isAvailable is nil"
  if p.generate.isNil: result.add "generate is nil"
  if result.len > 0: return
  # registered next to another provider, it is the one its name finds,
  # whatever the case it is asked for in
  let reg = newEmptyRegistry()
  registerProvider(reg, TalkingHeadProvider(name: "kit-other",
    isAvailable: proc (): bool = false,
    generate: proc (a, b: string; o: TalkingHeadOpts) = discard))
  registerProvider(reg, p)
  for asked in [p.name, p.name.toUpperAscii]:
    try:
      if getProvider(reg, asked).name != p.name:
        result.add "the registry returns '" & getProvider(reg, asked).name & "' for '" & asked & "'"
    except TalkingHeadError as e: result.add "the registry cannot find '" & asked & "': " & e.msg
  var available = false
  try: available = p.isAvailable()
  except CatchableError as e:
    result.add "isAvailable raised " & $e.name & " (" & e.msg & "): it must answer, not fail"
    return
  let dir = scratchDir(p.name)
  defer: removeDir(dir)
  let wav = dir / "narration.wav"
  silentWav(wav)
  let mp4 = dir / "out.mp4"
  # the shared cache tells narrations, portraits and providers apart
  let wav2 = dir / "narration2.wav"
  silentWav(wav2, 2.0)
  let face = dir / "face.png"
  let face2 = dir / "face2.png"
  writeFile(face, "portrait one")
  writeFile(face2, "portrait two")
  let key = cacheKeyFor(face, wav, p.name, "auto")
  if key == cacheKeyFor(face, wav2, p.name, "auto"): result.add "the cache key ignores the narration"
  if key == cacheKeyFor(face2, wav, p.name, "auto"): result.add "the cache key ignores the portrait"
  if key == cacheKeyFor(face, wav, "kit-other", "auto"): result.add "the cache key ignores the provider"
  if not available:
    # an unavailable provider is refused by name, before it runs
    var ran = new bool
    var watched = p
    let inner = p.generate
    watched.generate = proc (a, b: string; o: TalkingHeadOpts) =
      ran[] = true
      inner(a, b, o)
    registerProvider(reg, watched)
    try:
      generateTalkingHead(reg, p.name, wav, mp4, opts)
      result.add "generating with an unavailable provider did not fail"
    except TalkingHeadError as e:
      if p.name notin e.msg: result.add "the refusal does not name the provider: " & e.msg
    except CatchableError as e:
      result.add "an unavailable provider failed with " & $e.name & ", not TalkingHeadError"
    if ran[]: result.add "an unavailable provider was run instead of refused"
  elif generate:
    var o = opts
    if o.cacheDir.isNone: o.cacheDir = some(dir / "cache")
    try:
      generateTalkingHead(reg, p.name, wav, mp4, o)
      if not fileExists(mp4) or getFileSize(mp4) == 0: result.add "generate wrote no MP4"
    except CatchableError as e:
      result.add "generate failed: " & $e.name & ": " & e.msg

proc speechSynthesisProblems*(p: SpeechSynthesisProvider; generate = false;
                              opts = SpeechSynthesisOpts()): seq[string] =
  ## The speech-synthesis contract (version `SpeechSynthesisContractVersion`).
  if p.name.len == 0: result.add "the provider has no name"
  elif normalizeSpeechProviderName(p.name) != p.name:
    result.add "the name '" & p.name & "' is not canonical ('" &
      normalizeSpeechProviderName(p.name) & "'): the registry would list it under another name"
  if p.isAvailable.isNil: result.add "isAvailable is nil"
  if p.synthesize.isNil: result.add "synthesize is nil"
  if result.len > 0: return
  let reg = newSpeechRegistry()
  registerSpeechProvider(reg, SpeechSynthesisProvider(name: "kit-other",
    isAvailable: proc (): bool = false,
    synthesize: proc (t, o: string; x: SpeechSynthesisOpts) = discard))
  registerSpeechProvider(reg, p)
  for asked in [p.name, p.name.toUpperAscii]:
    try:
      if getSpeechProvider(reg, asked).name != p.name:
        result.add "the registry returns '" & getSpeechProvider(reg, asked).name & "' for '" &
          asked & "'"
    except SpeechSynthesisError as e: result.add "the registry cannot find '" & asked & "': " & e.msg
  # the shared cache tells voices, texts and providers apart
  let k = speechCacheKeyFor("hello", p.name, "voice-a", "22050")
  if k == speechCacheKeyFor("hello", p.name, "voice-b", "22050"):
    result.add "the cache key ignores the voice"
  if k == speechCacheKeyFor("hello!", p.name, "voice-a", "22050"):
    result.add "the cache key ignores the text"
  if k == speechCacheKeyFor("hello", "kit-other", "voice-a", "22050"):
    result.add "the cache key ignores the provider"
  var available = false
  try: available = p.isAvailable()
  except CatchableError as e:
    result.add "isAvailable raised " & $e.name & " (" & e.msg & "): it must answer, not fail"
    return
  let dir = scratchDir(p.name)
  defer: removeDir(dir)
  let wav = dir / "out.wav"
  if not available:
    # the provider as registered, but noting whether it was run: an
    # unavailable provider is refused before it runs
    var ran = new bool
    var watched = p
    let inner = p.synthesize
    watched.synthesize = proc (t, o: string; x: SpeechSynthesisOpts) =
      ran[] = true
      inner(t, o, x)
    registerSpeechProvider(reg, watched)
    try:
      synthesizeWith(reg, p.name, "hello", wav, opts)
      result.add "synthesizing with an unavailable provider did not fail"
    except SpeechSynthesisError as e:
      if p.name notin e.msg: result.add "the refusal does not name the provider: " & e.msg
    except CatchableError as e:
      result.add "an unavailable provider failed with " & $e.name & ", not SpeechSynthesisError"
    if ran[]: result.add "an unavailable provider was run instead of refused"
  elif generate:
    var o = opts
    if o.cacheDir.isNone: o.cacheDir = some(dir / "cache")
    try:
      synthesizeWith(reg, p.name, "Hello from the conformance kit.", wav, o)
      if not fileExists(wav) or getFileSize(wav) <= 44: result.add "synthesize wrote no audio"
    except CatchableError as e:
      result.add "synthesize failed: " & $e.name & ": " & e.msg
