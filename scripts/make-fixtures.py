import struct, zlib, sys, os
from PIL import Image
out = sys.argv[1]
exp = []
def save(name, img, fmt, **kw):
    img.save(os.path.join(out, name), fmt, **kw)
def expect(name, w, h, mode, data):
    exp.append('(:name "%s" :width %d :height %d :format :%s :pixels "%s")' % (name, w, h, mode, data.hex()))

rgb = Image.new("RGB", (3, 2)); rgb.putdata([(255,0,0),(0,255,0),(0,0,255),(10,20,30),(200,100,50),(255,255,255)])
save("rgb.png", rgb, "PNG"); expect("rgb.png", 3, 2, "rgb", rgb.tobytes())
save("rgb.bmp", rgb, "BMP"); expect("rgb.bmp", 3, 2, "rgb", rgb.tobytes())
save("interlaced.png", rgb, "PNG", interlace=1)  # Pillow may ignore; harmless
expect("interlaced.png", 3, 2, "rgb", rgb.tobytes())

rgba = Image.new("RGBA", (2, 2)); rgba.putdata([(255,0,0,255),(0,255,0,128),(0,0,255,0),(9,8,7,200)])
save("rgba.png", rgba, "PNG"); expect("rgba.png", 2, 2, "rgba", rgba.tobytes())

gray = Image.new("L", (4, 1)); gray.putdata([0, 64, 128, 255])
save("gray.png", gray, "PNG"); expect("gray.png", 4, 1, "gray", gray.tobytes())

pal = rgb.convert("P"); save("palette.png", pal, "PNG")
expect("palette.png", 3, 2, "rgb", pal.convert("RGB").tobytes())

# 16-bit gray written by hand: samples 0, 32768, 65535 → 8-bit 0, 128, 255 (rounded).
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
raw = b"\x00" + struct.pack(">HHH", 0, 32768, 65535)
png16 = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 3, 1, 16, 0, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
open(os.path.join(out, "gray16.png"), "wb").write(png16)
expect("gray16.png", 3, 1, "gray", bytes([0, 128, 255]))

# Bomb: a valid IHDR claiming 50000 × 50000, no pixel data.
bomb = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 50000, 50000, 8, 2, 0, 0, 0)) + chunk(b"IEND", b"")
open(os.path.join(out, "bomb.png"), "wb").write(bomb)
data = open(os.path.join(out, "rgb.png"), "rb").read()
open(os.path.join(out, "truncated.png"), "wb").write(data[: len(data) // 2])

# Animated GIF: 3 frames, 2 × 2, delays 100/200/300 ms.
frames = []
for c in [(255,0,0), (0,255,0), (0,0,255)]:
    f = Image.new("RGB", (2, 2), c); frames.append(f)
frames[0].save(os.path.join(out, "anim.gif"), "GIF", save_all=True, append_images=frames[1:], duration=[100,200,300], loop=0)

# JPEG with EXIF orientation 6 (rotate 90° clockwise to display), 8 × 4.
j = Image.new("RGB", (8, 4), (120, 60, 30))
for x in range(4): j.putpixel((x, 0), (250, 250, 250))
exif = Image.Exif(); exif[0x0112] = 6
save("oriented.jpg", j, "JPEG", quality=95, exif=exif.tobytes())
expect("oriented.jpg", 8, 4, "rgb", j.tobytes())

open(os.path.join(out, "expected.sexp"), "w").write(";;;; Expected pixels, written by Pillow when the fixtures were made.\n" + "\n".join(exp) + "\n")
print("ok", len(exp))
