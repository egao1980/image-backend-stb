/*
 * stb-cl: the C ABI image-backend-stb binds. Built over the vendored,
 * Fedora-patched stb (native/vendor/), compiled privately into this library
 * (STB_IMAGE_STATIC / STB_IMAGE_WRITE_STATIC), so stb's process-wide flags
 * belong to us alone.
 *
 * Hardening (see cl-stack docs/research/image-libraries.md):
 * - STBI_NO_STDIO: Lisp reads files; stb only sees memory.
 * - Only the formats we expose are compiled in (no PIC).
 * - STBI_MAX_DIMENSIONS lowered; the protocol's limits apply before decoding.
 * - No global setters are called at decode time. The PNG compression level is
 *   a write global, so writes take a lock and set it per call.
 * - GIF frames are decoded one at a time (stbi__gif_load_next), keeping only
 *   the two frames disposal needs, instead of stb allocating every frame.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define STBI_NO_STDIO
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_GIF
#define STBI_ONLY_BMP
#define STBI_ONLY_PSD
#define STBI_ONLY_HDR
#define STBI_ONLY_PNM
#define STBI_ONLY_TGA
#define STBI_MAX_DIMENSIONS (1 << 15)
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#include "vendor/stb_image.h"

#define STBI_WRITE_NO_STDIO
#define STB_IMAGE_WRITE_STATIC
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "vendor/stb_image_write.h"

#if defined(_WIN32)
#include <windows.h>
#define CL_API __declspec(dllexport)
static SRWLOCK write_lock = SRWLOCK_INIT;
#define LOCK() AcquireSRWLockExclusive(&write_lock)
#define UNLOCK() ReleaseSRWLockExclusive(&write_lock)
#else
#include <pthread.h>
#define CL_API __attribute__((visibility("default")))
static pthread_mutex_t write_lock = PTHREAD_MUTEX_INITIALIZER;
#define LOCK() pthread_mutex_lock(&write_lock)
#define UNLOCK() pthread_mutex_unlock(&write_lock)
#endif

#define STB_CL_ABI 1

CL_API int stbcl_abi(void) { return STB_CL_ABI; }

/* stb keeps its failure reason per thread only with STBI_THREAD_LOCAL; the
 * caller reads it right after a failed call on the same thread. */
CL_API const char *stbcl_failure_reason(void) {
  const char *r = stbi_failure_reason();
  return r ? r : "unknown";
}

CL_API void stbcl_free(void *p) { stbi_image_free(p); }

/* Header probe. → 1 and the size, native channel count and 16-bit flag. */
CL_API int stbcl_info(const uint8_t *data, int len, int *w, int *h, int *comp, int *is16) {
  if (!stbi_info_from_memory(data, len, w, h, comp)) return 0;
  *is16 = stbi_is_16_bit_from_memory(data, len);
  return 1;
}

/* Decode in the native channel count. → pixels (free with stbcl_free) or NULL.
 * With *is16 set on entry, 16-bit samples are returned (2 bytes each, native
 * endianness); the protocol reduces them to 8 bits with rounding. */
CL_API void *stbcl_load(const uint8_t *data, int len, int want16, int *w, int *h, int *comp) {
  if (want16) return stbi_load_16_from_memory(data, len, w, h, comp, 0);
  return stbi_load_from_memory(data, len, w, h, comp, 0);
}

/* ---- GIF, one composited RGBA frame at a time ------------------------- */

typedef struct stbcl_gif {
  stbi__context ctx;
  stbi__gif g;
  stbi_uc *prev, *prev2;   /* last two frames, for disposal "previous" */
  int frames;
} stbcl_gif;

CL_API stbcl_gif *stbcl_gif_open(const uint8_t *data, int len) {
  stbcl_gif *gif = calloc(1, sizeof *gif);
  if (!gif) return NULL;
  stbi__start_mem(&gif->ctx, data, len);
  if (!stbi__gif_test(&gif->ctx)) { free(gif); return NULL; }
  return gif;
}

/* → 1 with the next frame's canvas size, delay and RGBA pixels (valid until
 * the next call), 0 at the end, -1 on error. */
CL_API int stbcl_gif_next(stbcl_gif *gif, int *w, int *h, int *delay_ms, const uint8_t **pixels) {
  int comp = 0;
  stbi_uc *u = stbi__gif_load_next(&gif->ctx, &gif->g, &comp, 4, gif->prev2);
  if (u == (stbi_uc *)&gif->ctx) return 0;   /* stb's end-of-animation marker */
  if (!u) return gif->frames ? 0 : -1;
  {
    size_t stride = (size_t)gif->g.w * (size_t)gif->g.h * 4;
    stbi_uc *copy = malloc(stride ? stride : 1);
    if (!copy) return -1;
    memcpy(copy, u, stride);
    free(gif->prev2);
    gif->prev2 = gif->prev;
    gif->prev = copy;
  }
  gif->frames++;
  *w = gif->g.w;
  *h = gif->g.h;
  *delay_ms = gif->g.delay;
  *pixels = gif->prev;
  return 1;
}

CL_API void stbcl_gif_close(stbcl_gif *gif) {
  if (!gif) return;
  STBI_FREE(gif->g.out);
  STBI_FREE(gif->g.history);
  STBI_FREE(gif->g.background);
  free(gif->prev);
  free(gif->prev2);
  free(gif);
}

/* ---- Encoding ----------------------------------------------------------- */

typedef struct { uint8_t *data; size_t len, cap; int failed; } buffer;

static void append(void *ctx, void *data, int size) {
  buffer *b = ctx;
  if (b->failed || size <= 0) return;
  if (b->len + (size_t)size > b->cap) {
    size_t cap = b->cap ? b->cap * 2 : 4096;
    while (cap < b->len + (size_t)size) cap *= 2;
    uint8_t *p = realloc(b->data, cap);
    if (!p) { b->failed = 1; return; }
    b->data = p;
    b->cap = cap;
  }
  memcpy(b->data + b->len, data, (size_t)size);
  b->len += (size_t)size;
}

/* format: 0 PNG, 1 JPEG, 2 BMP, 3 TGA. level: PNG 0–9 (zlib scale);
 * quality: JPEG 1–100. → encoded bytes (free with stbcl_free_buffer) or NULL. */
CL_API uint8_t *stbcl_encode(int format, int w, int h, int comp, const uint8_t *pixels,
                             int level, int quality, size_t *out_len) {
  buffer b = {0};
  int ok = 0;
  LOCK();
  switch (format) {
  case 0: {
    int saved = stbi_write_png_compression_level;
    stbi_write_png_compression_level = level;
    ok = stbi_write_png_to_func(append, &b, w, h, comp, pixels, w * comp);
    stbi_write_png_compression_level = saved;
    break;
  }
  case 1: ok = stbi_write_jpg_to_func(append, &b, w, h, comp, pixels, quality); break;
  case 2: ok = stbi_write_bmp_to_func(append, &b, w, h, comp, pixels); break;
  case 3: ok = stbi_write_tga_to_func(append, &b, w, h, comp, pixels); break;
  }
  UNLOCK();
  if (!ok || b.failed) { free(b.data); return NULL; }
  *out_len = b.len;
  return b.data;
}

CL_API void stbcl_free_buffer(uint8_t *p) { free(p); }
