# DemoVideoStudio

Video editor for DemoVideoScript scenarios: edits timing and narration in abstract terms and renders narrated videos through any backend.

> **Status:** ☐ Planned — design stage; no implementation yet.

DemoVideoStudio edits a [DemoVideoScript](https://github.com/metacraft-labs/DemoVideoScript)
scenario's timing and presentation — pacing, narration, captions, callouts, presenter
overlay — in terms of the scenario's steps rather than absolute timestamps, and renders it
into a narrated video by running it through a project's page objects on a chosen backend.
Several backend flavours can be loaded at once and switched between instantly. Rendering is
also available headless, for CI and documentation builds.

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
