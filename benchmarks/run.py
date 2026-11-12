#!/usr/bin/env python3
"""Builds every benchmark for both targets and prints the best time of three runs.

    python3 benchmarks/run.py [path/to/onyx]
"""
import os, subprocess, sys, tempfile, time

here = os.path.dirname(os.path.abspath(__file__))
onyx = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "target", "release", "onyx")
names = sorted(f[:-3] for f in os.listdir(here) if f.endswith(".ox"))

def best_time(cmd):
    best = None
    for _ in range(3):
        start = time.perf_counter()
        result = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        elapsed = time.perf_counter() - start
        if result.returncode != 0:
            return None
        best = elapsed if best is None else min(best, elapsed)
    return best

def show(t):
    return "   failed" if t is None else f"{t * 1000:7.0f} ms"

with tempfile.TemporaryDirectory() as tmp:
    print(f"{'benchmark':10} {'native':>10} {'node':>10} {'size':>10}")
    for name in names:
        source = os.path.join(here, name + ".ox")
        exe, js = os.path.join(tmp, name), os.path.join(tmp, name + ".js")
        native = node = None
        size = ""
        if subprocess.run([onyx, "build", "--target", "native", source, "-o", exe], capture_output=True).returncode == 0:
            native = best_time([exe])
            size = f"{os.path.getsize(exe)} B"
        if subprocess.run([onyx, "build", source, "-o", js], capture_output=True).returncode == 0:
            node = best_time(["node", js])
        print(f"{name:10} {show(native):>10} {show(node):>10} {size:>10}")
