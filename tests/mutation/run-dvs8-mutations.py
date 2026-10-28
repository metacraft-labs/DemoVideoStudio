#!/usr/bin/env python3
"""DVS-8 verification gate: the moved video-production modules.

Each arm is a defect in the code that moved from GuiAssert; the kill command is
`just test` (the moved suites, with a real ffmpeg), run in this repository, so
the suites still catch what they caught where they came from.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
P = "src/demo_video_studio/artifact_project.nim"
M = "src/demo_video_studio/media.nim"

ARMS = [
    Arm("S1", P, "      if s.inputHash == expectedHash: return ssFresh\n      else: return ssStale",
        "      if s.inputHash != expectedHash: return ssFresh\n      else: return ssStale",
        "a staleness rule inverted"),
    Arm("S2", P, "  if getFileSize(path) <= 0: return ssMissing", "  discard",
        "an empty stage output counted as present"),
    Arm("M1", M, '    "[bg][avatar]overlay=" & overlayExpression(opts)',
        '    "[bg]null"', "a filter graph dropping the overlay"),
    Arm("M2", M, '      pieces.add(buildDrawtextFilter(c, opts))', '      discard c',
        "a filter graph dropping the captions"),
]

if __name__ == "__main__":
    main("dvs8", ROOT, ARMS, ["just", "test"])
