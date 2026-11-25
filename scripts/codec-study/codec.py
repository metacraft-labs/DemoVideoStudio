#!/usr/bin/env python3
"""Codec study for crisp UI: a 30 fps clip made of a real run's lossless window captures
(the GPUI flavour's step stills, 1600x1000, each held 0.5 s), encoded by each candidate at
the window's own size; text crops of the decoded frames compared with the captures."""
import subprocess, sys, os, re, json, glob
work = sys.argv[1]; os.makedirs(work, exist_ok=True)   # usage: codec.py <work dir> <stills dir> [candidate...]
srcdir = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("CODEC_STUDY_STILLS", "stills")
stills = sorted(glob.glob(srcdir + "/*.png"))
HOLD = 0.5
CROPS = {"code": "390:440:330:60", "calltrace": "435:270:1165:60", "vars": "430:240:725:100"}
SAMPLES = list(range(2, len(stills), 6))
def run(a): subprocess.run(a, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
lst = f"{work}/src.txt"
with open(lst, "w") as fh:
    for s in stills: fh.write(f"file '{s}'\nduration {HOLD}\n")
    fh.write(f"file '{stills[-1]}'\n")
SRC = ["-f", "concat", "-safe", "0", "-i", lst, "-vf", "fps=30"]
G = ["-g", "60"]   # a key frame every 2 s: seeking stays cheap
CANDIDATES = {
  "h264-420-crf18": ["-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart"] + G,
  "h264-420-crf12": ["-c:v", "libx264", "-preset", "slow", "-crf", "12", "-pix_fmt", "yuv420p", "-movflags", "+faststart"] + G,
  "h264-444-crf18": ["-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv444p", "-movflags", "+faststart"] + G,
  "hevc-420-crf20": ["-c:v", "libx265", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p", "-tag:v", "hvc1", "-movflags", "+faststart", "-x265-params", "keyint=60:log-level=error"],
  "hevc-444-crf20": ["-c:v", "libx265", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv444p", "-tag:v", "hvc1", "-movflags", "+faststart", "-x265-params", "keyint=60:log-level=error"],
  "vp9-420-crf28": ["-c:v", "libvpx-vp9", "-crf", "28", "-b:v", "0", "-pix_fmt", "yuv420p", "-row-mt", "1", "-cpu-used", "2"] + G,
  "vp9-444-crf28": ["-c:v", "libvpx-vp9", "-crf", "28", "-b:v", "0", "-pix_fmt", "yuv444p", "-row-mt", "1", "-cpu-used", "2"] + G,
  "av1-420-svt-scm": ["-c:v", "libsvtav1", "-crf", "28", "-preset", "6", "-pix_fmt", "yuv420p", "-svtav1-params", "scm=1:keyint=60"],
  "av1-444-aom-screen": ["-c:v", "libaom-av1", "-crf", "28", "-b:v", "0", "-cpu-used", "6", "-row-mt", "1", "-pix_fmt", "yuv444p", "-tune-content", "screen"] + G,
}
only = sys.argv[3:] or list(CANDIDATES)
res = {}
if os.path.exists(f"{work}/codec.json"): res = json.load(open(f"{work}/codec.json"))
for name in only:
    a = CANDIDATES[name]
    ext = "webm" if a[1].startswith("libvpx") or "av1" in a[1] else "mp4"
    out = f"{work}/{name}.{ext}"
    import time; t0 = time.time()
    run(["ffmpeg", "-y"] + SRC + a + [out]); enc_s = time.time() - t0
    dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", out], capture_output=True, text=True).stdout)
    scores = {k: [] for k in CROPS}
    for k in SAMPLES:
        t = k * HOLD + HOLD / 2
        png = f"{work}/{name}-{k}.png"
        run(["ffmpeg", "-y", "-ss", f"{t:.3f}", "-i", out, "-frames:v", "1", "-vf", "format=rgb24", png])
        for c, crop in CROPS.items():
            o = subprocess.run(["ffmpeg", "-i", png, "-i", stills[k], "-lavfi",
                f"[0]crop={crop}[a];[1]crop={crop}[b];[a][b]ssim", "-f", "null", "-"], capture_output=True, text=True).stderr
            scores[c].append(float(re.search(r"All:([0-9.]+)", o).group(1)))
        os.remove(png)
    res[name] = {"bytes": os.path.getsize(out), "MB_per_min": round(os.path.getsize(out) / dur * 60 / 1e6, 2),
                 "encode_s": round(enc_s, 1), **{c: round(sum(v) / len(v), 4) for c, v in scores.items()},
                 "min_ssim": round(min(min(v) for v in scores.values()), 4)}
    print(name, json.dumps(res[name]), flush=True)
    json.dump(res, open(f"{work}/codec.json", "w"), indent=1)
