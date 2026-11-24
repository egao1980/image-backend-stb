(in-package #:image-backend-stb)

;;; Native resize (0.3.0; image-backend-stb#4): a method on image-protocol
;;; 0.3.0's BACKEND-RESIZE over stb_image_resize2. image-protocol's pure-Lisp
;;; resampler stays the reference (it equals Pillow 11.3 byte for byte); this
;;; path is faster and close to it, not equal (S8). The protocol's rules R1–R8
;;; (image-protocol src/ops.lisp, "Backend fast path") apply: by the time the
;;; method runs, every argument is checked, the output size is within
;;; *IMAGE-LIMITS*, and IMAGE is an 8-bit image of at least 1 × 1.
;;;
;;; S1  Opt-in. The method serves only callers that name the backend:
;;;       (img:resize-image image w h :filter :bicubic
;;;                         :backend (make-instance 'stb-backend))
;;;     or bind IMG:*RESIZE-BACKENDS*. Loading this system registers the
;;;     backend for decoding and encoding, as before, and binds nothing.
;;;
;;; S2  What it serves. FILTER :BILINEAR or :BICUBIC with LINEAR NIL, for
;;;     every pixel format (:GRAY :GRAY-ALPHA :RGB :RGBA). It declines (NIL)
;;;     everything else, so the protocol's resampler runs:
;;;       :LANCZOS3  stb_image_resize2 has no Lanczos-3 kernel (its LANCZOS4
;;;                  and LANCZOS5 are other windows).
;;;       :BOX       stb's BOX is a trapezoid. It equals Pillow's box only at
;;;                  integer ratios; enlarging noise, the two are up to 125
;;;                  apart.
;;;       :NEAREST   no gain over the protocol's plain copy, and stb's point
;;;                  sampling need not pick Pillow's pixel at ties.
;;;       LINEAR T   the protocol's linear-light path has no Pillow reference
;;;                  to measure against.
;;;     REDUCING-GAP is accepted and not applied. stb resamples the whole
;;;     source directly, and S8's bounds cover the cases with a gap.
;;;
;;; S3  The call. One stbir_resize (stb's medium API) per resize:
;;;       filter   :BILINEAR → STBIR_FILTER_TRIANGLE (2); :BICUBIC →
;;;                STBIR_FILTER_CATMULLROM (4): Keys' cubic, a = -0.5, which
;;;                is Pillow's BICUBIC.
;;;       layout   by channel count: STBIR_1CHANNEL, STBIR_RA, STBIR_RGB,
;;;                STBIR_RGBA. Straight alpha in and out; stb weights colour
;;;                by alpha itself.
;;;       type     STBIR_TYPE_UINT8: the stored values, no sRGB conversion.
;;;       edge     STBIR_EDGE_CLAMP.
;;;       rows     packed (stride 0 in and out).
;;;     scripts/resize-tolerance.py builds this call into a probe and measured
;;;     tests/fixtures/resize-tolerance.sexp with it.
;;;
;;; S4  C ABI, native/stb-cl.c, ABI 2 (STB_CL_ABI and +ABI+ become 2):
;;;       int stbcl_resize(const uint8_t *in, int w, int h, int comp,
;;;                        uint8_t *out, int nw, int nh, int filter);
;;;     FILTER is the stbir_filter value of S3. → 1 once OUT holds the
;;;     NW × NH × COMP result. → 0 without writing OUT when FILTER is not 2
;;;     or 4, COMP is not 1–4, a side is below 1, or stbir_resize fails.
;;;     The Lisp binding is %RESIZE (cffi:defcfun "stbcl_resize"). stb
;;;     keeps no global state here, so the call takes no lock.
;;;     Build: native/vendor/stb_image_resize2.h is
;;;     nothings/stb_image_resize @ a4f303e34a92d1410d510cbe85a1781ce4b8c9fd
;;;     (2.51; the header left nothings/stb, and Fedora's stb pin has none).
;;;     scripts/vendor-stb.sh fetches it at that commit and records its
;;;     SHA-256 (9a653683b5fafba0f5c7911d163ede7d92c64dcd1e482407bd8b44aa155925ce)
;;;     in native/vendor/PROVENANCE.md, and NOTICE names it (public domain /
;;;     MIT). stb-cl.c includes it with STB_IMAGE_RESIZE_IMPLEMENTATION and
;;;     STB_IMAGE_RESIZE_STATIC. scripts/build-stb-cl.sh adds
;;;     -ffp-contract=off, which stb needs to give the same bytes on every
;;;     target.
;;;
;;; S5  Memory. OUT is a Lisp octet vector of NW × NH × COMP. It and IMAGE's
;;;     pixels are pinned for the call (cffi:with-pointer-to-vector-data), so no
;;;     native memory escapes and nothing is freed.
;;;
;;; S6  Answer. → a fresh IMAGE of WIDTH × HEIGHT in IMAGE's format, depth 8,
;;;     with those pixels. The protocol copies IMAGE's metadata onto the result
;;;     (R6). IMAGE is not modified.
;;;
;;; S7  Failure. When stbcl_resize returns 0 for a call S2 serves, the method
;;;     signals IMG:IMAGE-NATIVE-UNAVAILABLE with BACKEND the backend and CAUSE
;;;     "stbir_resize failed". The protocol's TRY-NEXT-BACKEND restart (R7)
;;;     then falls back to the next backend or to Lisp.
;;;
;;; S8  Closeness. stb resamples in floats with no rounding between its two
;;;     passes, and it clamps the kernel at the edges where Pillow renormalises
;;;     it, so equal bytes are not expected. For every case of
;;;     tests/fixtures/resize-tolerance.sexp, the result is compared with the
;;;     protocol's own (:BACKEND NIL) over all samples. Colour samples of alpha
;;;     formats are compared premultiplied (c · a / 255); alpha and opaque
;;;     samples are compared as they are. The largest difference must be at
;;;     most the fixture's :MAX and the mean at most its :MEAN. Those bounds
;;;     are the worst case measured against Pillow 11.3, plus a quarter
;;;     (max 43, mean 3.2). They reject a wrong filter, edge mode, alpha
;;;     layout or data type (scripts/resize-tolerance.py --report).
;;;
;;; S2's decline is the CASE below. S3's call is %RESIZE (backend.lisp, with
;;; the rest of the C ABI).

(defmethod img:backend-resize ((backend stb-backend) image width height
                               &key filter reducing-gap linear)
  "S2–S7: IMAGE resized by stb_image_resize2 for :BILINEAR and :BICUBIC
without LINEAR; NIL (declined) otherwise."
  (declare (ignore reducing-gap))       ; S2: accepted, not applied
  (let ((code (and (not linear)
                   (case filter (:bilinear 2) (:bicubic 4))))) ; S3: TRIANGLE, CATMULLROM
    (when code
      (let* ((format (img:image-format image))
             (comp (img:channels format))
             (pixels (img:image-pixels image))
             (out (make-array (* width height comp) :element-type '(unsigned-byte 8)))
             (status (cffi:with-pointer-to-vector-data (in pixels) ; S5: pinned, no copy
                       (cffi:with-pointer-to-vector-data (o out)
                         (%resize in (img:image-width image) (img:image-height image) comp
                                  o width height code)))))
        ;; S7, signalled once both pins are released. The protocol's
        ;; TRY-NEXT-BACKEND (R7) is the recovery; nothing is established here.
        (when (zerop status)
          (error 'img:image-native-unavailable :backend backend :cause "stbir_resize failed"))
        (img:make-image :width width :height height :format format :depth 8 :pixels out)))))
