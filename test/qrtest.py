#!/usr/bin/env python3
"""End-to-end test for the QR engine in src/SCRIPTS/TELEMETRY/qrPos.lua.

For each input string it runs the script with a desktop Lua interpreter,
renders the ASCII frame it prints (and the qr_temp.bmp it writes) to PNG,
decodes both with zbar, and checks the decoded text equals the input.
Decoding with an independent reader is the only way to catch encoder bugs
that still produce a plausible-looking QR (wrong ECC, wrong masking, ...).

Requirements: lua (5.3+), zbarimg (package zbar-tools), Pillow.

Usage:
  python3 test/qrtest.py                 # fixed suite: prefixes x coords, length sweep, yield modes
  python3 test/qrtest.py --random 200    # add 200 random GPS coordinates (deterministic seed)
  python3 test/qrtest.py "geo:1,2" ...   # test only the given strings
  python3 test/qrtest.py --script other.lua   # test a different copy of the engine

Exit status is non-zero if any case fails.
"""
import argparse
import os
import random
import re
import subprocess
import sys
import tempfile

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SCRIPT = os.path.join(ROOT, "src", "SCRIPTS", "TELEMETRY", "qrPos.lua")

PREFIXES = ["", "geo:", "comgooglemaps://?q=", "cm://map?ll=", "GURU://"]
COORDS = [
    (37.87133, -122.31750), (-37.87133, 122.31750), (-37.87133, -122.31750),
    (0.0, 0.0), (90.0, 180.0), (-90.0, -180.0), (1.0, 2.0), (-0.000001, -0.000001),
    (45.123456, 7.123456), (-33.9, 151.2), (89.999999, -179.999999),
]
# Byte-mode capacity of version 4 at ECC level L; longer inputs are unsupported by design.
MAX_LEN = 78


def gps_string(prefix, lat, lon):
    return prefix + "%.6f,%.6f" % (lat, lon)


class Harness:
    def __init__(self, script, workdir, lua="lua"):
        self.script = script
        self.workdir = workdir
        self.lua = lua

    def run_lua(self, s):
        p = subprocess.run([self.lua, self.script, s], cwd=self.workdir,
                           capture_output=True, text=True, timeout=120)
        return p.stdout, p.stderr

    @staticmethod
    def parse_frame(out):
        """Return the ASCII QR as a list of rows of booleans, or None."""
        lines = [l for l in out.splitlines() if l and set(l) <= {"#", " "} and "#" in l]
        if not lines:
            return None
        w = max(len(l) for l in lines)
        return [[l.ljust(w)[i] == "#" for i in range(0, w, 2)] for l in lines]

    @staticmethod
    def frame_to_png(rows, path, scale=8, quiet=4):
        h, w = len(rows), len(rows[0])
        img = Image.new("L", ((w + 2 * quiet) * scale, (h + 2 * quiet) * scale), 255)
        px = img.load()
        for y, row in enumerate(rows):
            for x, black in enumerate(row):
                if black:
                    for dy in range(scale):
                        for dx in range(scale):
                            px[(x + quiet) * scale + dx, (y + quiet) * scale + dy] = 0
        img.save(path)

    @staticmethod
    def decode(path):
        p = subprocess.run(["zbarimg", "-q", "--raw", "-Sbinary", path],
                           capture_output=True, timeout=60)
        if p.returncode != 0:
            return None
        return p.stdout.decode("latin-1").rstrip("\n")

    def decode_bmp(self, path):
        """Composite the 32-bit BGRA BMP over white, upscale, decode."""
        try:
            im = Image.open(path).convert("RGBA")
        except Exception as e:  # noqa: BLE001
            return "BMP-OPEN-FAIL: %s" % e
        bg = Image.new("RGBA", im.size, (255, 255, 255, 255))
        bg.alpha_composite(im)
        big = bg.convert("L").resize((im.size[0] * 8, im.size[1] * 8), Image.NEAREST)
        out = os.path.join(self.workdir, "bmp_big.png")
        big.save(out)
        return self.decode(out)

    def test(self, s, label=None):
        bmp = os.path.join(self.workdir, "qr_temp.bmp")
        if os.path.exists(bmp):
            os.remove(bmp)
        out, err = self.run_lua(s)
        m = re.search(r"finished calculating version \[(\d+)\] width \[(\d+)\]", out)
        ver = m.group(1) if m else "?"
        problems = []
        if err.strip():
            problems.append("LUA-ERR: " + err.strip().splitlines()[-1][:120])
        if "finished with usage" not in out:
            problems.append("NOT-FINISHED (progress %s)" % (re.findall(r"progress\s+(\d+)", out) or ["?"])[-1])
        rows = self.parse_frame(out)
        if rows:
            png = os.path.join(self.workdir, "frame.png")
            self.frame_to_png(rows, png)
            dec = self.decode(png)
            if dec is None:
                problems.append("UNDECODABLE")
            elif dec != s:
                problems.append("MISMATCH decoded=%r" % dec)
            bmpd = self.decode_bmp(bmp)
            if bmpd != s:
                problems.append("BMP-MISMATCH decoded=%r" % bmpd)
        else:
            problems.append("NO-FRAME")
        ok = not problems
        print("%s len=%2d v=%s %s  %s" % ("OK  " if ok else "FAIL", len(s), ver,
                                          label or repr(s), " | ".join(problems)))
        return ok


def make_yield_variant(script, workdir, mode):
    """Write a copy of the engine whose CLI getUsage() stub never / always reports overload.

    'never' exercises the pure computation; 'always' yields at every check, which
    proves every stage makes progress per call (a stage without a progress guard
    would spin forever on a radio under sustained load).
    """
    src = open(script, encoding="latin-1").read()
    stub = "return math.floor((os.clock() - startTime) * 500000)"
    assert stub in src, "CLI getUsage() stub not found; harness needs updating"
    src = src.replace(stub, "return 0" if mode == "never" else "return 100")
    if mode == "always":
        src = src.replace("if loopc > 100 then return 1 end", "if loopc > 20000 then return 1 end")
        src = src.replace("for i = 0, 100 do -- Run until", "for i = 0, 20000 do -- Run until")
        src = src.replace("repeat until (os.clock() - startTime) > 0.01", "")
    path = os.path.join(workdir, "qrPos_%s.lua" % mode)
    open(path, "w", encoding="latin-1").write(src)
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="*", help="only test these strings")
    ap.add_argument("--script", default=DEFAULT_SCRIPT)
    ap.add_argument("--lua", default="lua")
    ap.add_argument("--random", type=int, default=0, metavar="N", help="also test N random GPS strings")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    fails = total = 0
    with tempfile.TemporaryDirectory(prefix="qrtest-") as work:
        h = Harness(args.script, work, args.lua)

        def run(s, label=None):
            nonlocal fails, total
            total += 1
            fails += not h.test(s, label)

        if args.inputs:
            for s in args.inputs:
                run(s)
        else:
            print("--- prefixes x coordinates (timed yields, as on the CLI) ---")
            for p in PREFIXES:
                for lat, lon in COORDS:
                    run(gps_string(p, lat, lon))
                run(p + "no gps")
            print("--- length sweep 2..%d ---" % MAX_LEN)
            for n in range(2, MAX_LEN + 1):
                run(("geo:" + "1234567890" * 9)[:n])
            print("--- pure computation (never yields) ---")
            hn = Harness(make_yield_variant(args.script, work, "never"), work, args.lua)
            for p in PREFIXES:
                total += 1
                fails += not hn.test(gps_string(p, 37.87133, -122.31750))
            print("--- progress guarantees (yields at every check) ---")
            ha = Harness(make_yield_variant(args.script, work, "always"), work, args.lua)
            for s in ["geo:1,2", "geo:37.871330,-122.317500",
                      "cm://map?ll=-37.871330,-122.317500",
                      "comgooglemaps://?q=-37.871330,-122.317500" + "x" * 30]:
                total += 1
                fails += not ha.test(s)

        if args.random:
            print("--- %d random GPS strings (seed %d) ---" % (args.random, args.seed))
            rnd = random.Random(args.seed)
            for _ in range(args.random):
                run(gps_string(rnd.choice(PREFIXES), rnd.uniform(-90, 90), rnd.uniform(-180, 180)))

    print("\n%d/%d passed" % (total - fails, total))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
