#!/usr/bin/env python3
"""DVS-12 verification gate: several flavours at once.

Each arm is a defect in the resident flavours; the kill command builds
`dvs-studio` and runs the flavours suite (`tests/tflavours.nim`), which starts
it as its own process and watches the kernel's accounting of it.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
F = "src/demo_video_studio/resident.nim"

ARMS = [
    Arm("F1", F, "  let idx = min(r.frames.high, max(0, int(t / 1000 * PreviewFps)))\n  let live =",
        "  let idx = min(r.frames.high, max(0, int(t / 1000 * PreviewFps)))\n"
        "  discard readFile(r.report.video)\n  let live =",
        "a switch that re-reads the render"),
    Arm("F2", F, '  fs.resident[name] = r\n  if fs.displayed == "": fs.displayed = name',
        '  fs.resident[name] = r\n  if fs.displayed == "": fs.displayed = name\n'
        '  var others: seq[string]\n  for k, _ in fs.resident:\n    if k != name: others.add k\n'
        '  for k in others:\n    if fs.overBudget:\n'
        '      fs.resident[k].session.close()\n      fs.resident.del k',
        "an eviction without asking"),
    Arm("F3", F, "  fs.displayed = name\n  let (a, b) = r.report.stepsMs[fs.playheadStep]",
        "  let (a, b) = fs.resident.getOrDefault(fs.displayed, r).report.stepsMs[fs.playheadStep]\n"
        "  fs.displayed = name",
        "a playhead kept as a time"),
]

if __name__ == "__main__":
    main("dvs12", ROOT, ARMS, ["bash", "-c",
         "nim c --hints:off --warnings:off --passC:-w --threads:on --nimcache:$BUILD_DIR/nc-cli "
         "-o:$BUILD_DIR/dvs-studio src/dvs_studio.nim && DVS_STUDIO_BIN=$BUILD_DIR/dvs-studio "
         "nim c -r --hints:off --warnings:off --passC:-w --threads:on --nimcache:$BUILD_DIR/nc "
         "-o:$BUILD_DIR/tflavours tests/tflavours.nim"])
