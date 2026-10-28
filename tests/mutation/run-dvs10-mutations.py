#!/usr/bin/env python3
"""DVS-10 verification gate: editing in scenario terms.

Each arm is a defect in the scenario editor; the kill command runs the
editor's HTTP suite (`tests/tscenario_editor.nim`) against the terminal
flavour, which needs DVS_TERMINAL_HOST, DVS_NOTES_TUI and DVS_ROOT (the
Justfile's `build-flavours`).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
D = "src/demo_video_studio/scenario_doc.nim"
E = "src/demo_video_studio/scenario_editor.nim"

ARMS = [
    Arm("T1", D, '      delta = int64(req["startMs"].getFloat - d.measured(nxt).startMs + 0.5)',
        '      delta = int64(req["startMs"].getFloat + 0.5)',
        "an absolute time written back"),
    Arm("T2", E, "  if keyed.isSome: keyed.get\n  elif ordinal.isSome: ordinal.get",
        "  if ordinal.isSome: ordinal.get\n  elif keyed.isSome: keyed.get",
        "an ordinal preferred over a key"),
    Arm("T3", D, '  PresentationKeys = ["id", "lead-in", "dwell", "chapter", "narration", "caption", "callout"]',
        '  PresentationKeys = ["id", "lead-in", "dwell", "chapter", "caption", "callout"]',
        "a presentation edit invalidating automation"),
]

if __name__ == "__main__":
    main("dvs10", ROOT, ARMS, ["bash", "-c",
         "nim c -r --hints:off --warnings:off --passC:-w --threads:on --nimcache:$BUILD_DIR/nc "
         "-o:$BUILD_DIR/tscenario_editor tests/tscenario_editor.nim"])
