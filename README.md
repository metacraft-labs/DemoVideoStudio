# DemoVideoStudio

Video editor for DemoVideoScript scenarios: edits timing and narration in abstract terms and renders narrated videos through any backend.

> **Status:** scenario files are edited in scenario terms (`dvs-studio edit`), rendered
> through a pack on a chosen backend (`dvs-studio render`) and shown on several flavours at
> once; test-run recordings open read-only (`dvs-studio open`), and keyframe scripts convert
> to scenarios (`dvs-studio convert`). The keyframe-script editor and render pipeline moved
> here from GuiAssert, with their history; the keyframe format retires once its last
> scripts are converted.

DemoVideoStudio edits a [DemoVideoScript](https://github.com/metacraft-labs/DemoVideoScript)
scenario's timing and presentation — pacing, narration, captions, callouts, presenter
overlay — in terms of the scenario's steps rather than absolute timestamps, and renders it
into a narrated video by running it through a project's page objects on a chosen backend.
Several backend flavours can be loaded at once and switched between instantly. Rendering is
also available headless, for CI and documentation builds.

## What is here

| Module (`src/demo_video_studio/`)          |                                                                                                                                                                           |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scenario_doc`                             | a scenario file as the editor's document: edits written back as anchors, `dwell`, `lead-in`, pacing and locators, comments kept                                           |
| `scenario_editor`, `editor-web/scenario.*` | the scenario editor's HTTP surface and page, and target picking through a flavour's `hit`                                                                                 |
| `render`                                   | a render: the run on a flavour, narration, captions, callouts and the presenter placed on its step offsets, composition                                                   |
| `flavour`, `resident`                      | flavours loaded at once: each one's render in memory and its live session, a step-position playhead they follow in lockstep, a memory budget that asks rather than evicts |
| `run_view`, `editor-web/run.*`             | a test-run recording opened read-only: its steps with results, the failing step, stills and observed state                                                                |
| `convert`                                  | a keyframe script as a scenario for a pack, with a report of every keyframe it could not express                                                                          |
| `editor_backend`, `editor-web/`            | the timeline editor: an HTTP surface and its web UI, with a three-tier preview cache                                                                                      |
| `media`                                    | composition: ffmpeg filter graphs for captions, overlays and the presenter                                                                                                |
| `speech_synthesis`, `speech_synth`         | narration, through provider plugins (macOS `say` built in)                                                                                                                |
| `talking_head`, `avatar_track`, `emotive`  | the presenter overlay and its provider contract                                                                                                                           |
| `artifact_project`                         | the per-stage artifact layout and its staleness rules                                                                                                                     |
| `storyboard`                               | a scenario from a goal: the recipe's script, converted for a pack                                                                                                         |
| `parser`, `driver`                         | the keyframe-script format the editor edits today, and its driver                                                                                                         |

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

## Several flavours at once

In the editor, the Flavours panel lists each `--flavour` with whether the scenario applies
there. Loading one renders it and keeps it resident — its render in memory and a live
session — until it is unloaded; switching between loaded flavours reads and runs nothing.
The playhead is a step (double-click one on the timeline); every live session follows it.
A memory budget being exceeded is reported with the flavours that could be unloaded;
nothing is unloaded without asking.

## A failing run, and old keyframe scripts

`dvs-studio open <run-dir>` shows a DemoVideoScript run recording read-only on
<http://127.0.0.1:7701/>: its steps with their results, the failing step selected, and that
step's stills and observed state.

`dvs-studio convert <script.yaml> --pack <pack.yaml> --out <scenario.yaml>` turns a keyframe
script into a scenario. Targets become locators only where the pack resolves them (or
`--target LEGACY=LOCATOR` maps them); every keyframe it could not express is reported with
the reason, and the command exits 1. `dvs-studio storyboard "<goal>"` writes the storyboard
engine's script for a goal as a scenario the same way.

## Rendering a scenario

```sh
build/bin/dvs-studio render scenarios/tour.yaml --pack pack/app.pack.yaml \
  --backend "terminal=dvs-termassert-notes --serve" --virtual-timing --out build/tour.mp4
```

runs the scenario on the backend with recording on and composes the video: every
narration, caption, callout and avatar keyframe is placed on the run's own step offsets, so
the same scenario renders in step on every flavour. A terminal flavour (`--virtual-timing`)
is recorded fast, timed at render and rasterised through a pinned font. A run that does not
pass renders nothing; the command names the failing step, the run's `failure/` directory
and the recording up to that step, and exits 1. `--json` prints the report.

## Developing

The siblings in `.github/sibling-repos` are expected next to this checkout (or at
`GUI_ASSERT_SRC`, `DVS_SRC`, `DVS_TERMASSERT_ROOT`, `TERM_ASSERT_SRC`, `NIM_PTY_SRC`,
`NIM_LIBVTERM_SRC`, `TERM_ASSERT_CLIENT_SRC`, `DVS_PLAYWRIGHT_ROOT`). `just test` builds the
terminal and Playwright flavours from them; the dev shell provides node, Playwright's
browsers, `agg` and the pinned font.

| Recipe                                         | Does                                                                                       |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `just test`                                    | every suite: the editor through HTTP and in a real browser, composition with a real ffmpeg |
| `just build`                                   | `build/bin/dvs-studio`                                                                     |
| `just mutate dvs10`                            | planted defects in the scenario editor must turn its suite red                             |
| `just mutate dvs11`                            | planted defects in the render must turn its suite red                                      |
| `just mutate dvs12`                            | planted defects in the resident flavours must turn their suite red                         |
| `just mutate dvs13`                            | planted defects in the converter must turn its suite red                                   |
| `just lint`                                    | `nim check` of every suite, `nixfmt`                                                       |
| `python3 tests/mutation/run-dvs8-mutations.py` | planted defects in the moved code must turn the suites red                                 |
| `python3 tests/mutation/run-dvs9-mutations.py` | planted defects in the plugin contract must turn its conformance suite red                 |

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
