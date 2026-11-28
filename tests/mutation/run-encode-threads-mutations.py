#!/usr/bin/env python3
"""The encode-threads gate: every encode a render makes is bounded.

Each arm removes the bound in one place; the kill command runs the
final-encode suite (`tests/tbrowser_composite.nim`), whose two encode-thread
tests check the generated ffmpeg arguments.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
M = "src/demo_video_studio/media.nim"
R = "src/demo_video_studio/render.nim"

ARMS = [
    Arm("E1", M, "  result = videoArgs\n  if threads <= 0: return\n",
        "  result = videoArgs\n  return\n",
        "withEncodeThreads returns the arguments unchanged: no encode is bounded"),
    Arm("E2", R, "  if opts.encodeThreads == 0: DefaultEncodeThreads\n",
        "  if opts.encodeThreads == 0: 0\n",
        "a render with no --encode-threads runs its encoders unbounded"),
    Arm("E3", M, "    if i >= 0 and i + 1 < r.len: r[i + 1] = val\n    else: r.add @[key, val]\n",
        "    r.add @[key, val]\n",
        "an option already present is repeated instead of replaced"),
]

if __name__ == "__main__":
    main("encode-threads", ROOT, ARMS, ["bash", "-c",
         "nim c -r --hints:off --warnings:off --passC:-w --threads:on --nimcache:$BUILD_DIR/nc "
         "-o:$BUILD_DIR/tbrowser_composite tests/tbrowser_composite.nim"])
