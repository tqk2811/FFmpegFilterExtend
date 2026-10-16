"""Score a capcut/* effect against a demo exported from CapCut.

usage: python scripts/capcut-compare.py <effect_dir> <capcut_id> --data <CapcutDatas>
           [--params k=v:k=v] [--feed overlap|same] [--start 23] [--frames 14] [--out DIR]
needs: numpy, Pillow, ffmpeg (PATH or --ffmpeg), gpufx CLI (target/release by default)

Layout of <CapcutDatas>:
  Demos/<clip>.mp4                    the two clips fed to CapCut (A then B, see --clips)
  Transitions/<id>.json               CapCut metadata (name, duration, is_overlap)
  Transitions/<id>.<id>.mp4.demo      CapCut render: 60 frames @30fps 1080x1080

Timeline of the demos: clip A then clip B, both stills scaled 1024->1080 (bilinear, full frame).
The transition always covers frames start..start+frames with progress p = (k-start)/frames,
whatever the json duration says. Outside that window the plain clips are shown.
It also checks that the effect returns the plain clips at progress 0 and 1 (psnr_ends, 99 = identical)
and warns otherwise.
Output in <out>: frames.csv (per-frame PSNR/SSIM), summary.json, contact.png (demo | ours | |diff|x3),
ours.mp4 (the gpufx render) and side.mp4 (demo | ours).
"""
import argparse, json, os, shutil, subprocess, sys
import numpy as np
from PIL import Image, ImageDraw

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
N = 1080
DEFAULT_CLIPS = "2509fb68-042f-4f02-ab5f-9ae8a7933405,7fd780b8-35ca-4c28-9b1d-c7c69a18f811"


def default_gpufx():
    exe = "gpufx.exe" if os.name == "nt" else "gpufx"
    return os.path.join(REPO, "target", "release", exe)


def decode(ff, path, gray=False):
    pix, ch = ("gray", 1) if gray else ("rgb24", 3)
    raw = subprocess.run([ff, "-v", "error", "-i", path, "-vf", f"scale={N}:{N}:flags=area",
                          "-f", "rawvideo", "-pix_fmt", pix, "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(-1, N, N, ch)


def psnr(a, b):
    e = ((a.astype(np.float64) - b.astype(np.float64)) ** 2).mean()
    return 99.0 if e == 0 else 10 * np.log10(255.0 ** 2 / e)


def box(x, r=4):
    # (2r+1)^2 mean filter over the valid region, via an integral image
    c = np.pad(x, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
    w = 2 * r + 1
    return (c[w:, w:] - c[:-w, w:] - c[w:, :-w] + c[:-w, :-w]) / (w * w)


def ssim(a, b):
    luma = lambda im: im.astype(np.float64) @ [0.299, 0.587, 0.114]
    x, z = luma(a), luma(b)
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    mx, mz = box(x), box(z)
    sx, sz, sxz = box(x * x) - mx * mx, box(z * z) - mz * mz, box(x * z) - mx * mz
    return float((((2 * mx * mz + c1) * (2 * sxz + c2)) / ((mx * mx + mz * mz + c1) * (sx + sz + c2))).mean())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("effect")
    ap.add_argument("id")
    ap.add_argument("--data", default=os.environ.get("CAPCUT_DATA"), help="CapcutDatas folder (or CAPCUT_DATA)")
    ap.add_argument("--clips", default=DEFAULT_CLIPS, help="names of clip A,B under Demos/")
    ap.add_argument("--gpufx", default=default_gpufx())
    ap.add_argument("--ffmpeg", default=shutil.which("ffmpeg") or "ffmpeg")
    ap.add_argument("--backend", default="auto")
    ap.add_argument("--params", default="", help="extra effect params, k=v:k=v")
    ap.add_argument("--start", type=int, default=23)
    ap.add_argument("--frames", type=int, default=14)
    ap.add_argument("--feed", choices=["overlap", "same"], default="overlap",
                    help="overlap: (A,B) always, as in ffmpeg; same: (A,A) below p=0.5 then (B,B), "
                         "the way CapCut feeds non-overlap transitions")
    ap.add_argument("--effect-outside", action="store_true", help="run the effect at p=0/1 instead of showing the plain clips")
    ap.add_argument("--out")
    o = ap.parse_args()
    if not o.data:
        sys.exit("--data (or CAPCUT_DATA) is required")

    o.effect = os.path.normpath(o.effect)  # a trailing slash would end up inside the gpufx graph string
    name = os.path.basename(o.effect)
    out = o.out or os.path.join(REPO, "target", "capcut-compare", name)
    os.makedirs(out, exist_ok=True)
    tdir = os.path.join(o.data, "Transitions")
    with open(os.path.join(tdir, f"{o.id}.json"), encoding="utf-8") as f:
        meta = json.load(f)
    demo = decode(o.ffmpeg, os.path.join(tdir, f"{o.id}.{o.id}.mp4.demo"))

    inputs = []
    for tag, clip in zip("AB", o.clips.split(",")):
        png = os.path.join(out, f"in_{tag}.png")
        subprocess.run([o.ffmpeg, "-v", "error", "-y", "-i", os.path.join(o.data, "Demos", clip + ".mp4"),
                        "-frames:v", "1", "-vf", f"scale={N}:{N}:flags=bilinear", png], check=True)
        inputs.append(png)

    log = open(os.path.join(out, "gpufx.log"), "w", encoding="utf-8")
    cache = {}

    def render(p):
        key = round(p, 6)
        if key in cache:
            return cache[key]
        if key in (0.0, 1.0) and not o.effect_outside:
            cache[key] = np.asarray(Image.open(inputs[int(key)]).convert("RGB"))
            return cache[key]
        if o.feed == "same":
            pair = (inputs[0], inputs[0]) if key < 0.5 else (inputs[1], inputs[1])
        else:
            pair = tuple(inputs)
        png = os.path.join(out, f"ours_p{key:.4f}.png")
        arg = f"{o.effect}=progress={key}" + (":" + o.params if o.params else "")
        r = subprocess.run([o.gpufx, "run", arg, "-i", pair[0], "-i", pair[1], "-o", png, "--backend", o.backend],
                           capture_output=True, text=True)
        log.write(f"$ {arg}\n{r.stdout}{r.stderr}\n")
        if r.returncode:
            sys.exit(f"gpufx failed at p={key}: {r.stderr.strip()}")
        cache[key] = np.asarray(Image.open(png).convert("RGB"))
        return cache[key]

    rows = []
    for k in range(len(demo)):
        p = min(max((k - o.start) / o.frames, 0.0), 1.0)
        ours = render(p)
        rows.append(dict(frame=k, progress=round(p, 4), psnr=round(psnr(ours, demo[k]), 3), ssim=round(ssim(ours, demo[k]), 5)))
    # The effect must hand over the plain clips at both ends, or cutting in/out of it jumps.
    ends = []
    for p in (0.0, 1.0):
        png = os.path.join(out, f"end_p{p:.0f}.png")
        arg = f"{o.effect}=progress={p}" + (":" + o.params if o.params else "")
        r = subprocess.run([o.gpufx, "run", arg, "-i", inputs[0], "-i", inputs[1], "-o", png, "--backend", o.backend],
                           capture_output=True, text=True)
        if r.returncode:
            sys.exit(f"gpufx failed at p={p}: {r.stderr.strip()}")
        ends.append(round(psnr(np.asarray(Image.open(png).convert("RGB")),
                               np.asarray(Image.open(inputs[int(p)]).convert("RGB"))), 2))
    if min(ends) < 99.0:
        print(f"warning: output at progress 0/1 is not the plain clip (PSNR {ends[0]} / {ends[1]} dB)", file=sys.stderr)

    win = [r for r in rows if 0 < r["progress"] < 1]
    worst = min(win, key=lambda r: r["psnr"])
    summary = dict(effect=name, id=o.id, capcut_name=meta["name"], json_duration_us=meta["duration"],
                   is_overlap=meta["is_overlap"], feed=o.feed, window=[o.start, o.start + o.frames],
                   psnr_ends=ends,
                   psnr_window=round(float(np.mean([r["psnr"] for r in win])), 2),
                   ssim_window=round(float(np.mean([r["ssim"] for r in win])), 4), psnr_min=worst,
                   psnr_all=round(float(np.mean([r["psnr"] for r in rows])), 2),
                   ssim_all=round(float(np.mean([r["ssim"] for r in rows])), 4))
    with open(os.path.join(out, "frames.csv"), "w") as f:
        f.write("frame,progress,psnr,ssim\n")
        for r in rows:
            f.write(f"{r['frame']},{r['progress']},{r['psnr']},{r['ssim']}\n")
    with open(os.path.join(out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1)

    # contact sheet: every 2nd frame of the window plus the middle and the worst frame
    ks = sorted(set(range(o.start, o.start + o.frames + 1, 2)) | {worst["frame"], o.start + o.frames // 2})
    t = 240
    sheet = Image.new("RGB", (3 * t + 60, len(ks) * t), "white")
    draw = ImageDraw.Draw(sheet)
    for j, k in enumerate(ks):
        p = rows[k]["progress"]
        ours, ref = render(p), demo[k]
        diff = np.clip(np.abs(ours.astype(int) - ref.astype(int)) * 3, 0, 255).astype(np.uint8)
        for c, im in enumerate((ref, ours, diff)):
            sheet.paste(Image.fromarray(im).resize((t, t), Image.BILINEAR), (60 + c * t, j * t))
        draw.text((2, j * t + 4), f"f{k}\np={p:.2f}\n{rows[k]['psnr']:.1f}dB\n{rows[k]['ssim']:.3f}", fill="black")
    sheet.save(os.path.join(out, "contact.png"))

    # ours.mp4: the gpufx render on the demo's timeline; side.mp4: demo | ours
    for fname, pick in (("ours.mp4", lambda k, ours: ours), ("side.mp4", lambda k, ours: np.hstack((demo[k], ours)))):
        first = pick(0, render(rows[0]["progress"]))
        h, w = first.shape[:2]
        enc = subprocess.Popen([o.ffmpeg, "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}",
                                "-r", "30", "-i", "-", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "16",
                                os.path.join(out, fname)], stdin=subprocess.PIPE)
        for r in rows:
            enc.stdin.write(np.ascontiguousarray(pick(r["frame"], render(r["progress"]))).tobytes())
        enc.stdin.close()
        if enc.wait():
            sys.exit(f"ffmpeg failed writing {fname}")
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
