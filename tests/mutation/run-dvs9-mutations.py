#!/usr/bin/env python3
"""DVS-9 verification gate: the provider plugin contract and its kit.

Each arm is a defect in the contract the plugins build against; the kill
command runs the contract's conformance suite against the built-in providers.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SC = "src/demo_video_studio/speech_synthesis/core.nim"
TC = "src/demo_video_studio/talking_head/core.nim"

ARMS = [
    Arm("P1", SC, '  ctx.update(voiceId)\n', '  discard voiceId\n', "a cache key ignoring the voice"),
    Arm("P2", TC, "  result = r.providers[canonical]",
        "  for p in r.providers.values:\n    return p\n  result = r.providers[canonical]",
        "a registry returning the wrong provider"),
    Arm("P3", SC, '''  if not provider.isAvailable():
    raise newException(SpeechSynthesisError,''', '''  if false:
    raise newException(SpeechSynthesisError,''', "an unavailable provider run instead of refused"),
]

if __name__ == "__main__":
    main("dvs9", ROOT, ARMS, ["bash", "-c", "nim c -r --hints:off --passC:-w --nimcache:$BUILD_DIR/nc -o:$BUILD_DIR/tplugin_contract tests/tplugin_contract.nim"])
