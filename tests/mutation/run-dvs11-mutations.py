#!/usr/bin/env python3
"""DVS-11 verification gate: rendering through a pack on a chosen backend.

Each arm is a defect in the render; the kill command runs the render suite
(`tests/trender.nim`) on the terminal and Playwright flavours (the Justfile's
`build-flavours` and the dev shell provide them).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
R = "src/demo_video_studio/render.nim"

ARMS = [
    Arm("R1", R, '''      let pl = Placement(kind: "narration", step: a, text: s.narration.text,
                         startMs: clock.span(a)[0], endMs: clock.span(z)[1])''',
        '''      let pl = Placement(kind: "narration", step: a, text: s.narration.text,
                         startMs: 2000.0, endMs: clock.span(z)[1])''',
        "narration placed at an absolute second"),
    Arm("R2", R, "  if res.outcome != roPassed:", "  if res.outcome notin {roPassed, roFailed}:",
        "a render continuing past a failed step"),
]

if __name__ == "__main__":
    main("dvs11", ROOT, ARMS, ["bash", "-c",
         "nim c -r --hints:off --warnings:off --passC:-w --threads:on --nimcache:$BUILD_DIR/nc "
         "-o:$BUILD_DIR/trender tests/trender.nim"])
