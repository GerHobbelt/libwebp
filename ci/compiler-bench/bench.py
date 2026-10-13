"""Benchmark driver for .github/workflows/windows-x64-compilers.yml (runs on the Windows runner).

Every build (one dir per <compiler>-<variant> with webp_bench.exe and info.txt) runs on the SAME machine
in interleaved rounds whose order rotates, so runner drift / noisy neighbours hit all builds alike.
webp_bench is single-threaded and pinned to one core (not core 0) at high priority; numbers are medians.

  1. corpus: images -> .rawi (RGB, or RGBA when the image has real transparency), at most --max-mpix
  2. the baseline build encodes the q75 / lossless bitstreams that every build then decodes
  3. correctness pass: every build runs every test once; decoder and rescaler output must be identical
     to the baseline (integer code paths), lossless round trips are verified inside webp_bench
  4. timed rounds; summary.md (also appended to the job summary), results.json, ranking.json
"""
import argparse
import glob
import json
import math
import os
import platform
import statistics
import struct
import subprocess
import sys
import time

HIGH = getattr(subprocess, "HIGH_PRIORITY_CLASS", 0)
PIN1 = 0b10  # CPU 1


def run(cmd, affinity=0, timeout=3600):
    """High priority; affinity = CPU mask. Returns (returncode, stdout, stderr)."""
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         encoding="utf-8", errors="replace", creationflags=HIGH)
    if affinity and os.name == "nt":
        import ctypes
        ctypes.windll.kernel32.SetProcessAffinityMask(int(p._handle), affinity)
    out, err = p.communicate(timeout=timeout)
    return p.returncode, out, err


def parse_csv(out):
    """test,file,width,height,iters,seconds,mpix_per_s,bytes,hash -> {(test, file): row}"""
    rows = {}
    for line in out.splitlines()[1:]:
        f = line.strip().split(",")
        if len(f) == 9:
            rows[(f[0], f[1])] = {"mpps": float(f[6]), "iters": int(f[4]), "bytes": int(f[7]), "hash": f[8],
                                  "mpix": int(f[2]) * int(f[3]) / 1e6}
    return rows


def make_corpus(images, out_dir, max_mpix):
    from PIL import Image
    os.makedirs(out_dir, exist_ok=True)
    files = []
    for path in images:
        im = Image.open(path)
        im.load()
        if im.mode in ("RGBA", "LA") or (im.mode == "P" and "transparency" in im.info):
            im = im.convert("RGBA")
            if im.getchannel("A").getextrema()[0] == 255:
                im = im.convert("RGB")  # fully opaque
        else:
            im = im.convert("RGB")
        mp = im.width * im.height / 1e6
        if mp > max_mpix:
            s = math.sqrt(max_mpix / mp)
            im = im.resize((int(im.width * s), int(im.height * s)), Image.LANCZOS)
        name = os.path.splitext(os.path.basename(path))[0].replace(",", "_").replace(" ", "_")
        dst = os.path.join(out_dir, f"{name}-{im.width}x{im.height}-{im.mode.lower()}.rawi")
        n = 1
        while dst in files:  # e.g. two img0.jpg from different folders
            n += 1
            dst = os.path.join(out_dir, f"{name}_{n}-{im.width}x{im.height}-{im.mode.lower()}.rawi")
        with open(dst, "wb") as f:
            f.write(b"RAWI" + struct.pack("<III", im.width, im.height, len(im.mode)) + im.tobytes())
        files.append(dst)
        print(f"corpus: {path} -> {os.path.basename(dst)}", flush=True)
    return files


def cpu_name():
    if os.name == "nt":
        try:
            import winreg
            k = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\CentralProcessor\0")
            return winreg.QueryValueEx(k, "ProcessorNameString")[0].strip()
        except OSError:
            pass
    return platform.processor()


def median(xs):
    return statistics.median(xs) if xs else float("nan")


def geomean(xs):
    xs = [x for x in xs if x > 0 and not math.isnan(x)]
    return math.exp(sum(map(math.log, xs)) / len(xs)) if xs else float("nan")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--builds-dir", required=True)
    ap.add_argument("--images", nargs="+", required=True)
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--min-time", type=float, default=0.5, help="seconds per test per run")
    ap.add_argument("--max-mpix", type=float, default=4.0)
    ap.add_argument("--baseline", default="gcc17-base")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    builds = sorted(d for d in os.listdir(a.builds_dir)
                    if os.path.isfile(os.path.join(a.builds_dir, d, "webp_bench.exe")))
    if not builds:
        sys.exit("no builds found")
    exe = {b: os.path.join(a.builds_dir, b, "webp_bench.exe") for b in builds}
    info = {}
    for b in builds:
        p = os.path.join(a.builds_dir, b, "info.txt")
        info[b] = dict(l.split(":", 1) for l in open(p, encoding="utf-8").read().splitlines() if ":" in l) \
            if os.path.exists(p) else {}
    base = a.baseline if a.baseline in builds else builds[0]

    corpus_dir = os.path.join(a.out, "corpus")
    raws = make_corpus(a.images, corpus_dir, a.max_mpix)
    rc, out, err = run([exe[base], "-t", "0", "-o", corpus_dir] + raws)
    if rc != 0:
        sys.exit(f"baseline {base} failed ({rc}):\n{err}")
    files = raws + sorted(glob.glob(os.path.join(corpus_dir, "*.webp")))
    print(err.strip(), flush=True)

    # ------------------------------------------------------------ correctness pass (also warms up)
    ref = parse_csv(out)
    checks, failed = {}, {}
    for b in builds:
        rc, out, err = run([exe[b], "-t", "0"] + files)
        rows = parse_csv(out)
        if rc != 0:
            failed[b] = f"exit code {rc}: {err.strip()[-500:]}"
            continue
        if b == base:
            ref = rows
        checks[b] = rows
    for b in list(checks):
        bad = [f"{t} {f}" for (t, f), r in checks[b].items()
               if (t.startswith("dec-") or t.startswith("rescale")) and ref.get((t, f), {}).get("hash") != r["hash"]]
        if bad:
            failed[b] = "output differs from baseline: " + ", ".join(bad)
            del checks[b]
    good = [b for b in builds if b in checks]
    if base not in good:
        sys.exit(f"baseline {base} failed: {failed.get(base)}")
    print("correctness:", {b: ("ok" if b in good else failed[b]) for b in builds}, flush=True)

    # ------------------------------------------------------------ timed rounds
    raw = {b: [] for b in good}
    t0 = time.time()

    def rotation(r):
        order = good[r % len(good):] + good[:r % len(good)]
        return order[::-1] if r % 2 else order

    for r in range(a.rounds):
        for b in rotation(r):
            rc, out, err = run([exe[b], "-t", str(a.min_time)] + files, PIN1)
            if rc != 0:
                sys.exit(f"{b} failed in round {r + 1}: {err}")
            raw[b].append({f"{t}|{f}": v["mpps"] for (t, f), v in parse_csv(out).items()})
            print(f"[{time.time() - t0:6.0f}s] round {r + 1}/{a.rounds} {b}", flush=True)

    keys = list(raw[base][0])
    med = {b: {k: median([x[k] for x in raw[b]]) for k in keys} for b in good}
    score = {b: geomean([med[b][k] / med[base][k] for k in keys]) for b in good}
    tests = sorted({k.split("|")[0] for k in keys})
    tscore = {b: {t: geomean([med[b][k] / med[base][k] for k in keys if k.startswith(t + "|")]) for t in tests}
              for b in good}
    ranking = sorted(good, key=lambda x: -score[x])
    spread = {b: geomean([(max(x[k] for x in raw[b]) / min(x[k] for x in raw[b])) for k in keys]) for b in good}

    with open(os.path.join(a.out, "results.json"), "w", encoding="utf-8") as f:
        json.dump({"cpu": cpu_name(), "baseline": base, "info": info, "failed": failed, "raw": raw,
                   "median": med, "score": score}, f, indent=1)
    with open(os.path.join(a.out, "ranking.json"), "w", encoding="utf-8") as f:
        json.dump({"baseline": base, "ranking": [{"build": b, "score": score[b]} for b in ranking],
                   "failed": failed}, f, indent=1)

    # ------------------------------------------------------------ summary (markdown)
    md = ["## libwebp Windows x64 compiler benchmark", "",
          f"CPU: {cpu_name()} ({os.cpu_count()} logical); {a.rounds} interleaved rounds (rotating order), "
          f"single thread pinned to CPU 1, >= {a.min_time}s per test and run; medians. "
          f"Scores are geometric means of speed ratios vs `{base}` (higher is better).", "",
          "### Ranking", "", "| rank | build | score | " + " | ".join(tests) + " | round spread |",
          "|---:|---|---:|" + "---:|" * len(tests) + "---:|"]
    for i, b in enumerate(ranking, 1):
        md.append(f"| {i} | {b} | **{score[b]:.3f}** | " + " | ".join(f"{tscore[b][t]:.3f}" for t in tests)
                  + f" | {(spread[b] - 1) * 100:.1f}% |")
    if failed:
        md += ["", "### Excluded builds (failed correctness checks)", ""]
        md += [f"* `{b}`: {why}" for b, why in failed.items()]
    md += ["", "### Builds", "", "| build | compiler | flags | ymm instr. |", "|---|---|---|---:|"]
    for b in builds:
        i = info.get(b, {})
        md.append(f"| {b} | {i.get('compiler', '').strip()} | `{i.get('flags', '').strip()}` | "
                  f"{(i.get('ymm') or ' ').split()[0]} |")
    md += ["", "### Speed per test and image (megapixels/s) - higher is better", "",
           "| test | image | " + " | ".join(good) + " |", "|---|---|" + "---:|" * len(good)]
    for k in keys:
        t, f = k.split("|")
        best = max(med[b][k] for b in good)
        md.append(f"| {t} | {f} | " + " | ".join((f"**{med[b][k]:.2f}**" if med[b][k] == best else f"{med[b][k]:.2f}")
                                                for b in good) + " |")
    md += ["", "### Encoder output vs baseline (bytes; decoder/rescaler output is bit-identical in all listed builds)",
           "", "| test | image | " + " | ".join(good) + " |", "|---|---|" + "---:|" * len(good)]
    for (t, f), r in ref.items():
        if t.startswith("enc-"):
            md.append(f"| {t} | {f} | " + " | ".join(
                ("=" if checks[b][(t, f)]["hash"] == r["hash"] else f"{checks[b][(t, f)]['bytes'] - r['bytes']:+d}")
                for b in good) + " |")
    md.append(f"\n`=`: identical bitstream to `{base}`; otherwise the size difference in bytes.")

    text = "\n".join(md) + "\n"
    with open(os.path.join(a.out, "summary.md"), "w", encoding="utf-8") as f:
        f.write(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(text)
    print(text)


if __name__ == "__main__":
    main()
