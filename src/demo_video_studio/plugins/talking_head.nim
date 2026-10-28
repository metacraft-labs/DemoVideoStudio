## The talking-head provider contract, version 1: what a presenter-overlay
## plugin builds against.
##
## A plugin builds a `TalkingHeadProvider` — a canonical `name`, an
## `isAvailable` probe (cheap: no inference, no network) and a `generate`
## proc that writes an MP4 for a narration WAV or raises `TalkingHeadError` —
## and registers it with `registerProvider`. `cacheKeyFor` and `applyCache`
## give every plugin the same on-disk cache. `plugins/kit` is the conformance
## kit a plugin's own suite runs against its provider.
##
## A change to anything exported here that breaks a plugin raises
## `TalkingHeadContractVersion`.

import ../talking_head
export talking_head

const TalkingHeadContractVersion* = 1
