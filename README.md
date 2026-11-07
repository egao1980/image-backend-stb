# image-backend-stb

[`image-protocol`](https://github.com/egao1980/image-protocol) backend on stb_image and stb_image_write. Loading it registers the backend.

| | |
|---|---|
| Decode | PNG, JPEG, GIF (composited frames), BMP; plus PSD, HDR (tone-mapped to 8 bits, gamma 2.2), PNM and TGA when enabled through `*enabled-formats*` |
| Encode | PNG (levels 0–9), JPEG (quality 1–100; stb uses 4:2:0 at quality ≤ 90 and baseline only), BMP, TGA |
| 16-bit | Samples come back as 16 bits and the protocol reduces them with rounding |

**Hardening** (from the [research notes](https://github.com/egao1980/cl-stack/blob/main/docs/research/image-libraries.md)):
- **Patched sources.** Upstream stb still has the GHSL-2023 CVEs open. `native/vendor/` is stb at Fedora's pinned commit with Fedora's whole patch set, reproduced by `scripts/vendor-stb.sh` and recorded with hashes in `native/vendor/PROVENANCE.md`.
- **Build flags.** `STBI_NO_STDIO`, only the formats above compiled in (no PIC), and `STBI_MAX_DIMENSIONS` 2¹⁵ as a second line behind the protocol's limits. stb is compiled privately into `libstb-cl` (`STB_IMAGE_STATIC`), so its process-wide flags are ours alone, and no setter is called at decode time.
- **Locked writes.** PNG writing sets stb's global compression level under a lock.
- **GIF frame by frame.** GIF goes through `stbi__gif_load_next` one frame at a time, keeping only the two frames disposal needs, and checks the frame and byte budget each step. Plain stb would allocate every frame first.
- **No native memory escapes.** Pixels are copied into Lisp and freed in `unwind-protect`.

`scripts/build-stb-cl.sh [os-arch …]` cross-builds the overlays with `zig cc` (linux amd64/arm64, darwin arm64, windows amd64). `scripts/make-fixtures.py` regenerates the test fixtures with Pillow.

## License

MIT. Embedded stb: public domain / MIT ([NOTICE](NOTICE)).
