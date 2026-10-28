## The provider plugin contract, run through its conformance kit against the
## built-in providers: `stock_avatar` renders a real MP4 with ffmpeg, the host
## speech engine (`espeak` on Linux, `say` on macOS) synthesizes a real WAV,
## and the engines this host lacks are refused by name. No stand-ins: every
## provider is the real one; the kit's registry neighbour is a provider
## without an engine, which is what the kit is checking against.

import std/[unittest, os]
import ../src/demo_video_studio/plugins/[talking_head, speech_synthesis, kit]

suite "the plugin contract (version 1)":
  test "the contract versions are published":
    check TalkingHeadContractVersion == 1
    check SpeechSynthesisContractVersion == 1

  test "stock_avatar conforms and renders offline":
    let problems = talkingHeadProblems(newStockAvatarProvider(), generate = true)
    checkpoint $problems
    check problems.len == 0

  test "the host speech engine conforms and synthesizes offline":
    let problems = speechSynthesisProblems(defaultHostProvider(), generate = true)
    checkpoint $problems
    check problems.len == 0

  test "an engine this host lacks is refused by name, not run":
    for p in [sayProvider(), sapiProvider(), espeakProvider()]:
      if p.isAvailable(): continue
      let problems = speechSynthesisProblems(p)
      checkpoint p.name & ": " & $problems
      check problems.len == 0
