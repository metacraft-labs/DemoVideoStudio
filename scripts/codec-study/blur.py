#!/usr/bin/env python3
"""Where the delivered videos lose sharpness: each suspected step applied alone to a
lossless capture (a step still the run wrote, PNG at the window's size), decoded back to
RGB, and compared with the capture on text crops (SSIM and PSNR, ffmpeg's filters)."""
import subprocess, sys, os, re, json
src = sys.argv[1]; work = sys.argv[2]; os.makedirs(work, exist_ok=True)
W, H = 1600, 1000
CROPS = {"code": "390:440:330:60", "calltrace": "435:270:1165:60"}   # w:h:x:y

def run(args): subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

def metric(png, crop):
    out = subprocess.run(["ffmpeg", "-v", "info", "-i", png, "-i", src, "-lavfi",
        f"[0]crop={crop},format=rgb24[a];[1]crop={crop},format=rgb24[b];[a][b]ssim;[0]crop={crop},format=rgb24[c];[1]crop={crop},format=rgb24[d];[c][d]psnr",
        "-f", "null", "-"], capture_output=True, text=True).stderr
    ssim = float(re.search(r"SSIM .*All:([0-9.]+)", out).group(1))
    psnr = re.search(r"PSNR .*average:([0-9.inf]+)", out).group(1)
    return ssim, psnr

def enc(name, vargs, decode_scale=None, ext="mp4", encode_input=None):
    vid = f"{work}/{name}.{ext}"; png = f"{work}/{name}.png"
    run(["ffmpeg", "-y", "-loop", "1", "-framerate", "30", "-t", "1", "-i", encode_input or src] + vargs + [vid])
    vf = ["-vf", decode_scale + ",format=rgb24"] if decode_scale else ["-vf", "format=rgb24"]
    run(["ffmpeg", "-y", "-ss", "0.5", "-i", vid, "-frames:v", "1"] + vf + [png])
    return png, os.path.getsize(vid)

rows = []
def row(label, png, size=None):
    r = {"step": label, "size": size}
    for k, c in CROPS.items():
        s, p = metric(png, c); r[k] = (round(s, 4), p)
    rows.append(r); print(json.dumps(r), flush=True)

# 1. chroma subsampling alone: lossless 4:4:4 vs lossless 4:2:0
row("x264 lossless 4:4:4 (control)", *enc("l444", ["-c:v", "libx264rgb", "-qp", "0"]))
row("x264 lossless 4:2:0 (chroma only)", *enc("l420", ["-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p"]))
# 2. the rescale alone: 1600x1000 -> 1728x1080 (what composition did to fit 1920x1080), shown back at 1600x1000
run(["ffmpeg", "-y", "-i", src, "-vf", "scale=1728:1080", f"{work}/up.png"])
run(["ffmpeg", "-y", "-i", f"{work}/up.png", "-vf", "scale=1600:1000:flags=lanczos", f"{work}/up-back.png"])
row("rescale 1600->1728->1600 (bicubic up, lanczos back)", f"{work}/up-back.png")
# 3. quantisation alone, at 4:4:4: the CRFs the pipeline used
for crf in (23, 18):
    row(f"x264 4:4:4 crf {crf}", *enc(f"q444-{crf}", ["-c:v", "libx264rgb", "-crf", str(crf), "-preset", "medium"]))
# 4. the delivered chain: capture encode (ultrafast crf 23 4:2:0), toMp4 (veryfast crf 23),
#    composition (scale to 1728x1080 in 1920x1080, medium crf 18), shown back at 1600x1000
c1, _ = enc("g1", ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"])
row("generation 1: capture encode (ultrafast, crf 23, 4:2:0)", c1)
c2, _ = enc("g2", ["-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p"], encode_input=c1)
row("generation 2: + toMp4 (veryfast, crf 23)", c2)
c3, sz = enc("g3", ["-vf", "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2",
                    "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p"],
             decode_scale="crop=1728:1080:96:0,scale=1600:1000:flags=lanczos", encode_input=c2)
row("generation 3: + composition (1728x1080 in 1920x1080, crf 18) = delivered", c3, sz)
json.dump(rows, open(f"{work}/blur.json", "w"), indent=1)
