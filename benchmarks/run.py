#!/usr/bin/env python3
"""Builds every benchmark for each target and prints the best time of three runs.

    python3 benchmarks/run.py [path/to/onyx]

The JVM target needs the compiler written in Onyx (see docs/selfhost.md) and
`java`; with the compiler written in Rust, that column stays empty.
"""
import os, subprocess, sys, tempfile, time

here = os.path.dirname(os.path.abspath(__file__))
onyx = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "target", "release", "onyx")
names = sorted(f[:-3] for f in os.listdir(here) if f.endswith(".ox"))
java_env = dict(os.environ)
java_env.pop("JAVA_TOOL_OPTIONS", None)

def best_time(cmd):
    best = None
    for _ in range(3):
        start = time.perf_counter()
        result = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=java_env)
        elapsed = time.perf_counter() - start
        if result.returncode != 0:
            return None
        best = elapsed if best is None else min(best, elapsed)
    return best

def show(t):
    return "        -" if t is None else f"{t * 1000:7.0f} ms"

with tempfile.TemporaryDirectory() as tmp:
    print(f"{'benchmark':10} {'native':>10} {'node':>10} {'jvm':>10} {'size':>10}")
    for name in names:
        source = os.path.join(here, name + ".ox")
        exe = os.path.join(tmp, name)
        js, jar = exe + ".js", exe + ".jar"
        native = node = jvm = None
        size = ""
        if subprocess.run([onyx, "build", "--target", "native", source, "-o", exe], capture_output=True).returncode == 0:
            native = best_time([exe])
            size = f"{os.path.getsize(exe)} B"
        if subprocess.run([onyx, "build", source, "-o", js], capture_output=True).returncode == 0:
            node = best_time(["node", js])
        if subprocess.run([onyx, "build", "--target", "jvm", source, "-o", jar], capture_output=True).returncode == 0:
            jvm = best_time(["java", "-jar", jar])
        print(f"{name:10} {show(native):>10} {show(node):>10} {show(jvm):>10} {size:>10}")
