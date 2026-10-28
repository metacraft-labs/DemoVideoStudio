# DemoVideoStudio

Video editor for DemoVideoScript scenarios: edits timing and narration in abstract terms and renders narrated videos through any backend.

> **Status:** scenario files are edited in scenario terms (`dvs-studio edit`); rendering
> through a pack on a chosen backend comes next. The keyframe-script editor and render
> pipeline moved here from GuiAssert, with their history.

DemoVideoStudio edits a [DemoVideoScript](https://github.com/metacraft-labs/DemoVideoScript)
scenario's timing and presentation — pacing, narration, captions, callouts, presenter
overlay — in terms of the scenario's steps rather than absolute timestamps, and renders it
into a narrated video by running it through a project's page objects on a chosen backend.
Several backend flavours can be loaded at once and switched between instantly. Rendering is
also available headless, for CI and documentation builds.

## What is here

| Module (`src/demo_video_studio/`)          |                                                                                                                                 |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| `scenario_doc`                             | a scenario file as the editor's document: edits written back as anchors, `dwell`, `lead-in`, pacing and locators, comments kept |
| `scenario_editor`, `editor-web/scenario.*` | the scenario editor's HTTP surface and page, and target picking through a flavour's `hit`                                       |
| `editor_backend`, `editor-web/`            | the timeline editor: an HTTP surface and its web UI, with a three-tier preview cache                                            |
| `media`                                    | composition: ffmpeg filter graphs for captions, overlays and the presenter                                                      |
| `speech_synthesis`, `speech_synth`         | narration, through provider plugins (macOS `say` built in)                                                                      |
| `talking_head`, `avatar_track`, `emotive`  | the presenter overlay and its provider contract                                                                                 |
| `artifact_project`                         | the per-stage artifact layout and its staleness rules                                                                           |
| `storyboard`                               | a script from a goal                                                                                                            |
| `parser`, `driver`                         | the keyframe-script format the editor edits today, and its driver                                                               |

### The provider plugin contract

`demo_video_studio/plugins/talking_head` and `demo_video_studio/plugins/speech_synthesis`
are the contract presenter and narration plugins build against (version 1:
`TalkingHeadContractVersion`, `SpeechSynthesisContractVersion`), and
`demo_video_studio/plugins/kit` is its conformance kit: every plugin's own suite runs
`talkingHeadProblems(provider)` or `speechSynthesisProblems(provider)` — the name, the
registration, the availability probe, the cache key, and an unavailable provider refused
by name before it runs — offline, with no credentials. The `GuiAssert-*` plugins
(HeyGen, ElevenLabs, D-ID, Synthesia, Tavus, SadTalker, Wav2Lip, MuseTalk) build against
it.

Capture, OCR, image math and the PTY stay in [GuiAssert](https://github.com/metacraft-labs/GuiAssert),
which this repository depends on. Narration and the presenter are optional: a silent
render needs no provider and no network.

## Editing a scenario

```sh
just build
build/bin/dvs-studio edit scenarios/tour.yaml --pack pack/app.pack.yaml \
  --flavour "terminal=dvs-termassert-notes --serve" --virtual-timing terminal \
  --run build/runs/tour/manifest.json
```

opens the editor on <http://127.0.0.1:7700/>. A flavour is a backend's JSON-lines host. The
timeline is laid out on the `--run`'s measured step times; every edit is written to the
scenario file as the format's own values, never a time, and an edit that would not lint is
refused. Clicking the preview picks the selected step's target: the role instance there,
named by its semantic keys.

## Developing

The siblings in `.github/sibling-repos` are expected next to this checkout (or at
`GUI_ASSERT_SRC`, `DVS_SRC`, `DVS_TERMASSERT_ROOT`, `TERM_ASSERT_SRC`, `NIM_PTY_SRC`,
`NIM_LIBVTERM_SRC`, `TERM_ASSERT_CLIENT_SRC`). `just test` builds the terminal flavour from
them; the dev shell provides node and Playwright's browsers for the page's suite.

| Recipe                                         | Does                                                                                       |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `just test`                                    | every suite: the editor through HTTP and in a real browser, composition with a real ffmpeg |
| `just build`                                   | `build/bin/dvs-studio`                                                                     |
| `just mutate dvs10`                            | planted defects in the scenario editor must turn its suite red                             |
| `just lint`                                    | `nim check` of every suite, `nixfmt`                                                       |
| `python3 tests/mutation/run-dvs8-mutations.py` | planted defects in the moved code must turn the suites red                                 |
| `python3 tests/mutation/run-dvs9-mutations.py` | planted defects in the plugin contract must turn its conformance suite red                 |

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
