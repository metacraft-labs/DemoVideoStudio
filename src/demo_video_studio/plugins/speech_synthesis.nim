## The speech-synthesis provider contract, version 1: what a narration plugin
## builds against.
##
## A plugin builds a `SpeechSynthesisProvider` — a canonical `name`, an
## `isAvailable` probe (cheap: no synthesis, no network) and a `synthesize`
## proc that writes a WAV for a text or raises `SpeechSynthesisError` — and
## registers it with `registerSpeechProvider`. `speechCacheKeyFor` and
## `applySpeechCache` give every plugin the same on-disk cache.
## `plugins/kit` is the conformance kit a plugin's own suite runs against its
## provider.
##
## A change to anything exported here that breaks a plugin raises
## `SpeechSynthesisContractVersion`.

import ../speech_synthesis
export speech_synthesis

const SpeechSynthesisContractVersion* = 1
