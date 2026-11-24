"""How close stb_image_resize2 comes to Pillow 11.3's resize (image-backend-stb#4).

    uv run --with pillow==11.3.0 python -I scripts/resize-tolerance.py \
        > tests/fixtures/resize-tolerance.sexp
    uv run --with pillow==11.3.0 python -I scripts/resize-tolerance.py --report

image-protocol's pure-Lisp resampler equals Pillow 11.3 byte for byte. The
backend's native path (src/resize.lisp, S3) cannot: stb works in floats with
no rounding between the two passes, and clamps the kernel at the edges where
Pillow renormalises it. This script builds stb_image_resize2 with exactly the
call S3 specifies (stbir_resize, STBIR_TYPE_UINT8, STBIR_EDGE_CLAMP, layout by
channel count, :bilinear -> TRIANGLE, :bicubic -> CATMULLROM) into a probe
library, resizes the cases below with it and with Pillow, and measures each
case: the largest and the mean absolute difference over all samples, colour
samples of alpha formats compared premultiplied (c * a / 255, as the colour
looks over black), alpha and opaque samples as they are.

The bounds the Lisp test applies to every case are the worst case measured,
plus a quarter, rounded up (the max to an integer, the mean to a tenth).
--report also resizes with misconfigured calls (another filter, edge mode,
layout or data type) and shows that each breaks a bound in some case, so the
bounds are tight enough to catch them.

The header comes from native/vendor/stb_image_resize2.h, or --header PATH
(nothings/stb_image_resize @ a4f303e34a92 measured the committed fixture).
CC (default cc) compiles it, with -ffp-contract=off as stb asks for
determinism.

Inputs, rebuilt by tests/resize-test.lisp from the same formulas:
  noise   the LCG of image-protocol's parity tests: s = (s * 1103515245 +
          12345) mod 2^31, each sample bits 16-23 of s; alpha below 32 -> 0,
          above 223 -> 255.
  smooth  per colour channel ch, with a = 40 + 30 ch and b = 90 - 20 ch,
          v = floor((x a + y b) 255 / max(1, (w - 1) a + (h - 1) b)),
          inverted (255 - v) inside x in [w/4, w/2), y in [h/3, 2h/3)
          (integer division); alpha 255 - floor(255 x / max(1, w - 1)) in
          the top half (y < h/2) and 255 below.

Each line of the fixture:
  (:bounds :max N :mean M)
  (:case KIND FORMAT W H OUT-W OUT-H FILTER GAP SEED :max D :mean E)
"""
import ctypes
import math
import os
import subprocess
import sys
import tempfile

from PIL import Image

R = Image.Resampling
FILTERS = {"bilinear": R.BILINEAR, "bicubic": R.BICUBIC}
MODES = [("gray", "L", 1), ("gray-alpha", "LA", 2), ("rgb", "RGB", 3), ("rgba", "RGBA", 4)]
SIZES = [  # w h out-w out-h gap
    (64, 48, 21, 17, None),    # down, non-integer ratio
    (64, 48, 32, 24, None),    # down by 2
    (64, 48, 64, 20, None),    # one side only
    (31, 9, 7, 9, None),       # one side, short
    (13, 11, 40, 29, None),    # up
    (9, 31, 20, 12, None),     # up one side, down the other
    (37, 23, 5, 4, None),      # tiny result: edges everywhere
    (120, 90, 50, 37, 2),      # thumbnail-like, Pillow's default gap
    (200, 150, 23, 17, 2),     # large reduction, the gap's box reduce applies
]

PROBE = r"""
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#define STB_IMAGE_RESIZE_STATIC
#include "stb_image_resize2.h"

/* S3: the call the backend makes. */
int probe_resize(const unsigned char *in, int w, int h, int comp, unsigned char *out,
                 int nw, int nh, int filter) {
  static const stbir_pixel_layout layouts[] = {0, STBIR_1CHANNEL, STBIR_RA, STBIR_RGB, STBIR_RGBA};
  return stbir_resize(in, w, h, 0, out, nw, nh, 0, layouts[comp], STBIR_TYPE_UINT8,
                      STBIR_EDGE_CLAMP, (stbir_filter)filter) != 0;
}

/* --report: the same call with one setting changed. */
int probe_resize_with(const unsigned char *in, int w, int h, int comp, unsigned char *out,
                      int nw, int nh, int filter, int premultiplied, int edge, int type) {
  static const stbir_pixel_layout plain[] = {0, STBIR_1CHANNEL, STBIR_RA, STBIR_RGB, STBIR_RGBA};
  static const stbir_pixel_layout pm[] = {0, STBIR_1CHANNEL, STBIR_RA_PM, STBIR_RGB, STBIR_RGBA_PM};
  return stbir_resize(in, w, h, 0, out, nw, nh, 0, premultiplied ? pm[comp] : plain[comp],
                      (stbir_datatype)type, (stbir_edge)edge, (stbir_filter)filter) != 0;
}
"""

STBIR = {"triangle": 2, "catmullrom": 4, "cubicbspline": 3, "mitchell": 5, "box": 1,
         "point": 6, "clamp": 0, "reflect": 1, "zero": 3, "uint8": 0, "uint8-srgb": 1}
FILTER_CODE = {"bilinear": STBIR["triangle"], "bicubic": STBIR["catmullrom"]}


def build_probe(header, workdir):
    src = os.path.join(workdir, "probe.c")
    lib = os.path.join(workdir, "probe.so")
    with open(src, "w") as f:
        f.write(PROBE)
    cc = os.environ.get("CC", "cc").split()
    subprocess.run(cc + ["-O2", "-shared", "-fPIC", "-ffp-contract=off",
                         "-I", os.path.dirname(os.path.abspath(header)), "-o", lib, src],
                   check=True)
    return ctypes.CDLL(lib)


def noise(n, seed):
    s = seed
    out = bytearray(n)
    for i in range(n):
        s = (s * 1103515245 + 12345) & 0x7FFFFFFF
        out[i] = (s >> 16) & 0xFF
    return out


def make_noise(c, w, h, seed):
    data = noise(w * h * c, seed)
    if c in (2, 4):
        for p in range(c - 1, len(data), c):
            a = data[p]
            data[p] = 0 if a < 32 else 255 if a > 223 else a
    return data


def make_smooth(c, w, h, seed):
    del seed
    data = bytearray(w * h * c)
    for y in range(h):
        for x in range(w):
            for ch in range(c):
                if c in (2, 4) and ch == c - 1:
                    v = 255 - (x * 255) // max(1, w - 1) if y < h // 2 else 255
                else:
                    a, b = 40 + 30 * ch, 90 - 20 * ch
                    v = ((x * a + y * b) * 255) // max(1, (w - 1) * a + (h - 1) * b)
                    if w // 4 <= x < w // 2 and h // 3 <= y < (2 * h) // 3:
                        v = 255 - v
                data[(y * w + x) * c + ch] = v
    return data


KINDS = {"noise": make_noise, "smooth": make_smooth}


def difference(a, b, c):
    """(max, mean) absolute difference; colour of alpha formats premultiplied."""
    worst, total, n = 0.0, 0.0, 0
    for p in range(0, len(a), c):
        if c in (2, 4):
            aa, ab = a[p + c - 1], b[p + c - 1]
            ds = [abs(a[p + i] * aa - b[p + i] * ab) / 255 for i in range(c - 1)] + [abs(aa - ab)]
        else:
            ds = [abs(a[p + i] - b[p + i]) for i in range(c)]
        worst = max(worst, max(ds))
        total += sum(ds)
        n += len(ds)
    return worst, total / n


def stb(call, data, c, w, h, ow, oh, *settings):
    inp = (ctypes.c_ubyte * len(data)).from_buffer_copy(bytes(data))
    out = (ctypes.c_ubyte * (ow * oh * c))()
    if not call(inp, w, h, c, out, ow, oh, *settings):
        raise RuntimeError("stbir_resize failed")
    return bytes(out)


def cases():
    seed = 1
    for kind in KINDS:
        for fmt, mode, c in MODES:
            for fname in FILTERS:
                for w, h, ow, oh, gap in SIZES:
                    yield kind, fmt, mode, c, w, h, ow, oh, fname, gap, seed
                    seed += 1


def measure(lib, variant=None):
    """Each case measured, as (case, max, mean). VARIANT: (filter-map, pm, edge, type)."""
    rows = []
    for case in cases():
        kind, fmt, mode, c, w, h, ow, oh, fname, gap, seed = case
        data = KINDS[kind](c, w, h, seed)
        pillow = Image.frombytes(mode, (w, h), bytes(data)).resize(
            (ow, oh), FILTERS[fname], reducing_gap=gap).tobytes()
        if variant is None:
            got = stb(lib.probe_resize, data, c, w, h, ow, oh, FILTER_CODE[fname])
        else:
            fmap, pm, edge, typ = variant
            got = stb(lib.probe_resize_with, data, c, w, h, ow, oh,
                      fmap.get(fname, FILTER_CODE[fname]), pm, edge, typ)
        rows.append((case, *difference(pillow, got, c)))
    return rows


def bounds(rows):
    worst_max = max(r[1] for r in rows)
    worst_mean = max(r[2] for r in rows)
    return math.ceil(worst_max * 1.25), math.ceil(worst_mean * 1.25 * 10) / 10


def lisp_case(case, worst, mean):
    kind, fmt, _mode, _c, w, h, ow, oh, fname, gap, seed = case
    return (f"(:case :{kind} :{fmt} {w} {h} {ow} {oh} :{fname} {'nil' if gap is None else gap} "
            f"{seed} :max {worst:.2f} :mean {mean:.3f})")


def main(argv):
    header = "native/vendor/stb_image_resize2.h"
    if "--header" in argv:
        header = argv[argv.index("--header") + 1]
    if not os.path.exists(header):
        sys.exit(f"resize-tolerance.py: no {header} (vendor it, or pass --header PATH)")
    with tempfile.TemporaryDirectory() as workdir:
        lib = build_probe(header, workdir)
        rows = measure(lib)
        n, m = bounds(rows)
        if "--report" not in argv:
            print(";; scripts/resize-tolerance.py: stb_image_resize2 (src/resize.lisp, S3) against")
            print(";; Pillow 11.3. Each case: the largest and the mean sample difference measured,")
            print(";; colour of alpha formats premultiplied. Bounds: the worst case plus a quarter.")
            print(f"(:bounds :max {n} :mean {m})")
            for case, worst, mean in rows:
                print(lisp_case(case, worst, mean))
            return
        print(f"bounds: max <= {n}, mean <= {m} (worst measured: max "
              f"{max(r[1] for r in rows):.2f}, mean {max(r[2] for r in rows):.3f})")
        for case, worst, mean in sorted(rows, key=lambda r: -r[1])[:8]:
            print(f"  {lisp_case(case, worst, mean)}")
        variants = {
            "bicubic as Mitchell": ({"bicubic": STBIR["mitchell"]}, 0, STBIR["clamp"], STBIR["uint8"]),
            "bicubic as cubic B-spline": ({"bicubic": STBIR["cubicbspline"]}, 0, STBIR["clamp"], STBIR["uint8"]),
            "bilinear as box": ({"bilinear": STBIR["box"]}, 0, STBIR["clamp"], STBIR["uint8"]),
            "bilinear as point": ({"bilinear": STBIR["point"]}, 0, STBIR["clamp"], STBIR["uint8"]),
            "edge zero": ({}, 0, STBIR["zero"], STBIR["uint8"]),
            "edge reflect": ({}, 0, STBIR["reflect"], STBIR["uint8"]),
            "no alpha weighting (_PM layout)": ({}, 1, STBIR["clamp"], STBIR["uint8"]),
            "sRGB data type": ({}, 0, STBIR["clamp"], STBIR["uint8-srgb"]),
        }
        for name, variant in variants.items():
            vrows = measure(lib, variant)
            broken = [r for r in vrows if r[1] > n or r[2] > m]
            print(f"{name}: {len(broken)} of {len(vrows)} cases break a bound"
                  + (f", e.g. {lisp_case(*broken[0])}" if broken else ""))


if __name__ == "__main__":
    main(sys.argv[1:])
