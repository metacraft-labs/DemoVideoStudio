#!/usr/bin/env python3
"""DVS-13 verification gate: the keyframe-script converter.

Each arm is a defect in the converter; the kill command builds `dvs-studio`
and runs the converter's suite (`tests/tconvert.nim`) against the conformance
pack.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
C = "src/demo_video_studio/convert.nim"

ARMS = [
    Arm("C1", C, "      if kf.isCoordinate:\n", "      if false:\n",
        "a converter that guesses where a coordinate pointed"),
    Arm("C2", C, "      result.unexpressed.add Unexpressed(index: index, time: kf.time, action: kf.action,",
        "      if kf.action != \"navigate\": result.unexpressed.add Unexpressed(index: index, "
        "time: kf.time, action: kf.action,",
        "an unexpressible keyframe dropped from the report"),
]

if __name__ == "__main__":
    main("dvs13", ROOT, ARMS, ["bash", "-c",
         "nim c --hints:off --warnings:off --passC:-w --threads:on --nimcache:$BUILD_DIR/nc-cli "
         "-o:$BUILD_DIR/dvs-studio src/dvs_studio.nim && DVS_STUDIO_BIN=$BUILD_DIR/dvs-studio "
         "nim c -r --hints:off --warnings:off --passC:-w --threads:on --nimcache:$BUILD_DIR/nc "
         "-o:$BUILD_DIR/tconvert tests/tconvert.nim"])
