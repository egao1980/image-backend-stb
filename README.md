# image-backend-stb

[`image-protocol`](https://github.com/egao1980/image-protocol) backend on stb_image and stb_image_write. Loading it registers the backend.

| | |
|---|---|
| Decode | PNG, JPEG, GIF (composited frames), BMP; plus PSD, HDR (tone-mapped to 8 bits, gamma 2.2), PNM and TGA when enabled through `*enabled-formats*` |
| Encode | PNG (levels 0–9), JPEG (quality 1–100; stb uses 4:2:0 at quality ≤ 90 and baseline only), BMP, TGA |
| 16-bit | Samples come back as 16 bits and the protocol reduces them with rounding |

**Hardening** (from the [research notes](https://github.com/egao1980/cl-stack/blob/main/docs/research/image-libraries.md)):
- **Patched sources.** Upstream stb still has the GHSL-2023 CVEs open. `native/vendor/` is stb at Fedora's pinned commit with Fedora's whole patch set, reproduced by `scripts/vendor-stb.sh` and recorded with hashes in `native/vendor/PROVENANCE.md`. The same script vendors `stb_image_resize2.h` unpatched at a pinned commit, and fails unless its SHA-256 is the pinned one.
- **Build flags.** `STBI_NO_STDIO`, only the formats above compiled in (no PIC), and `STBI_MAX_DIMENSIONS` 2¹⁵ as a second line behind the protocol's limits. stb is compiled privately into `libstb-cl` (`STB_IMAGE_STATIC`), so its process-wide flags are ours alone, and no setter is called at decode time.
- **Locked writes.** PNG writing sets stb's global compression level under a lock.
- **GIF frame by frame.** GIF goes through `stbi__gif_load_next` one frame at a time, keeping only the two frames disposal needs, and checks the frame and byte budget each step. Plain stb would allocate every frame first.
- **No native memory escapes.** Pixels are copied into Lisp and freed in `unwind-protect`. Resize writes straight into a pinned Lisp vector, so no native buffer comes back (stb frees its own scratch memory before returning).

## Native resize (0.3.0)

A method on image-protocol 0.3.0's `backend-resize` resizes with [stb_image_resize2](https://github.com/nothings/stb_image_resize) (2.51). It runs only when the caller names the backend; loading this system registers it for decoding and encoding only.

```lisp
(stack-image:resize-image img 800 600 :filter :bicubic
                          :backend (make-instance 'image-backend-stb:stb-backend))
```

| | |
|---|---|
| Served | `:bilinear` (stb's triangle) and `:bicubic` (Catmull-Rom, which is Pillow's Keys cubic with a = −0.5), in every pixel format, in sRGB values. A `:reducing-gap` is accepted and not applied |
| Declined | `:lanczos3` (stb has no Lanczos-3), `:box` (stb's trapezoid matches Pillow's box only at integer ratios), `:nearest`, `:linear t`. The protocol's pure-Lisp resampler does these |
| Closeness | Close to the protocol's Pillow-equal samples, not equal: stb keeps floats between its passes and clamps the kernel at the edges. Over every case of `tests/fixtures/resize-tolerance.sexp`, with edges included and colour compared premultiplied, the largest sample difference is at most 43 and the mean at most 3.2. That is the worst case measured against Pillow 11.3 plus a quarter (`scripts/resize-tolerance.py`; `--report` shows that a wrong filter, edge mode, alpha layout or data type breaks these bounds) |

The rules (S1–S8: the C call, ABI 2, vendoring, memory, failure) are in `src/resize.lisp`, and the tests are in `tests/resize-test.lisp`.

`scripts/build-stb-cl.sh [os-arch …]` cross-builds the overlays with `zig cc` (linux amd64/arm64, darwin arm64, windows amd64). `scripts/make-fixtures.py` regenerates the test fixtures with Pillow.

## License

MIT. Embedded stb: public domain / MIT ([NOTICE](NOTICE)).
