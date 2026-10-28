#!/usr/bin/env python3
"""The plugins' gate: every GuiAssert-* plugin's own conformance suite turns red
on a planted cache-key defect in the contract it builds against.

For each plugin checkout (next to this one, or under PLUGINS_DIR), the defect
its kind of provider relies on is planted in this repository's contract — a
talking-head cache key that ignores the narration, or a speech cache key that
ignores the voice — the plugin's `tests/tcontract.nim` is built and run against
it, and the contract is restored. A plugin is KILLED when its suite fails.

    run-gadv3-plugin-gate.py            grade (writes gadv3-plugin-gate-results.txt)
"""
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import scrub  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PLUGINS = Path(os.environ.get("PLUGINS_DIR", ROOT.parent))
GUI_ASSERT_SRC = os.environ.get("GUI_ASSERT_SRC", str(ROOT.parent / "GuiAssert/src"))
TH = ("src/demo_video_studio/talking_head/core.nim", "  ctx.update(narrationDigest)\n",
      "  discard narrationDigest\n", "a talking-head cache key ignoring the narration")
SP = ("src/demo_video_studio/speech_synthesis/core.nim", "  ctx.update(voiceId)\n",
      "  discard voiceId\n", "a speech cache key ignoring the voice")
PLUGINS_KINDS = [("Did", TH), ("ElevenLabs", SP), ("HeyGen", TH), ("MuseTalk", TH),
                 ("SadTalker", TH), ("Synthesia", TH), ("Tavus", TH), ("Wav2Lip", TH)]


def checkout(name):
    for c in [PLUGINS / f"GuiAssert-{name}", PLUGINS / f"gadv3-{name}"]:
        if (c / "tests/tcontract.nim").exists():
            return c
    sys.exit(f"no checkout of GuiAssert-{name} with tests/tcontract.nim under {PLUGINS}")


def main():
    build = tempfile.mkdtemp(prefix="gadv3-gate-")
    lines = [f"# gadv3 plugin gate — {time.strftime('%Y-%m-%d %H:%M:%S %z')}", ""]
    survived = 0
    for name, (path, old, new, why) in PLUGINS_KINDS:
        repo = checkout(name)
        subject = ROOT / path
        saved = subject.read_text()
        assert saved.count(old) == 1, f"needle not found once in {path}"
        try:
            subject.write_text(saved.replace(old, new, 1))
            t0 = time.time()
            r = subprocess.run(["nim", "c", "-r", "--hints:off", "--path:src", f"--path:{ROOT}/src",
                                f"--path:{GUI_ASSERT_SRC}", f"--nimcache:{build}/{name}",
                                f"-o:{build}/{name}-tcontract", "tests/tcontract.nim"],
                               cwd=repo, capture_output=True, text=True)
            dt = time.time() - t0
        finally:
            subject.write_text(saved)
        verdict = "KILLED" if r.returncode != 0 else "SURVIVED"
        survived += verdict == "SURVIVED"
        lines.append(f"{verdict:8} GuiAssert-{name:11} {dt:6.1f}s  {why}")
        for t in [l for l in (r.stdout + r.stderr).splitlines() if "cache key" in l][-1:]:
            lines.append(f"           | {scrub(t.strip(), ROOT, build)[:160]}")
        print(lines[-1] if verdict == "SURVIVED" else lines[-2 if len(lines) > 2 else -1], flush=True)
    lines += ["", f"{len(PLUGINS_KINDS) - survived}/{len(PLUGINS_KINDS)} killed, {survived} survived"]
    (Path(__file__).resolve().parent / "gadv3-plugin-gate-results.txt").write_text("\n".join(lines) + "\n")
    print(lines[-1])
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
