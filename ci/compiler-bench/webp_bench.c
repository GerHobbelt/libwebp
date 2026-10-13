// Single-threaded libwebp encode/decode benchmark for .github/workflows/windows-x64-compilers.yml.
// It is linked against the same libwebp objects as the webp4j JNI DLL of the same build.
//
// Usage: webp_bench [-t min_seconds] [-o out_dir] file...
//   *.rawi  raw image written by bench.py: "RAWI", uint32 LE width, height, channels (3|4), pixels (RGB[A])
//           -> encode tests; lossless output is decoded and must match the input exactly;
//              with -o the q75 and lossless bitstreams are written to out_dir as <name>.q75.webp/.ll.webp
//   *.webp  -> decode test (BGRA, as webp4j's decodeInto)
// Prints CSV rows: test,file,width,height,iters,seconds,mpix_per_s,bytes,hash
// Every test runs once untimed (warm-up), then repeats until min_seconds have passed (at least twice).
// Exit code != 0 on any error or lossless round-trip mismatch.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "webp/decode.h"
#include "webp/encode.h"

#if defined(_WIN32)
#include <windows.h>
static double Now(void) {
  LARGE_INTEGER f, c;
  QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&c);
  return (double)c.QuadPart / (double)f.QuadPart;
}
#else
#include <time.h>
static double Now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}
#endif

static double min_seconds = 1.0;

static uint64_t Fnv1a(const uint8_t* p, size_t n) {
  uint64_t h = 0xcbf29ce484222325ull;
  while (n--) h = (h ^ *p++) * 0x100000001b3ull;
  return h;
}

static uint8_t* LoadFile(const char* path, size_t* size) {
  FILE* f = fopen(path, "rb");
  uint8_t* buf = NULL;
  long n;
  if (f == NULL) return NULL;
  if (fseek(f, 0, SEEK_END) == 0 && (n = ftell(f)) > 0 && fseek(f, 0, SEEK_SET) == 0) {
    buf = (uint8_t*)malloc((size_t)n);
    if (buf != NULL && fread(buf, 1, (size_t)n, f) != (size_t)n) {
      free(buf);
      buf = NULL;
    }
    *size = (size_t)n;
  }
  fclose(f);
  return buf;
}

static int SaveFile(const char* path, const uint8_t* data, size_t size) {
  FILE* f = fopen(path, "wb");
  int ok = (f != NULL) && fwrite(data, 1, size, f) == size;
  if (f != NULL) ok = (fclose(f) == 0) && ok;
  return ok;
}

static uint32_t Le32(const uint8_t* p) {
  return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}

static const char* BaseName(const char* path) {
  const char* b = path;
  for (const char* p = path; *p; ++p) {
    if (*p == '/' || *p == '\\') b = p + 1;
  }
  return b;
}

static int EndsWith(const char* s, const char* suffix) {
  const size_t n = strlen(s), m = strlen(suffix);
  return n >= m && strcmp(s + n - m, suffix) == 0;
}

static void Report(const char* test, const char* file, int w, int h, int iters, double secs,
                   size_t bytes, uint64_t hash) {
  printf("%s,%s,%d,%d,%d,%.6f,%.4f,%u,%016llx\n", test, file, w, h, iters, secs,
         (double)iters * w * h / secs / 1e6, (unsigned)bytes, (unsigned long long)hash);
  fflush(stdout);
}

typedef struct {
  int w, h, ch;
  const uint8_t* px;
} Image;

typedef struct {
  const char* name;
  float quality;
  int method;
  int lossless;
  int sharp_yuv;
  const char* out_suffix;  // with -o: write this test's output as <name><suffix>
} EncTest;

static const EncTest kEncTests[] = {
  {"enc-lossy-q75-m4", 75.f, 4, 0, 0, ".q75.webp"},  // cwebp defaults
  {"enc-lossy-q90-m6-sharpyuv", 90.f, 6, 0, 1, NULL},
  {"enc-lossless-q75-m4", 75.f, 4, 1, 0, ".ll.webp"},  // cwebp -lossless -exact
};

static int Encode(const Image* img, const EncTest* t, WebPMemoryWriter* out) {
  WebPConfig config;
  WebPPicture pic;
  int ok;
  if (!WebPConfigInit(&config) || !WebPPictureInit(&pic)) return 0;
  config.quality = t->quality;
  config.method = t->method;
  config.lossless = t->lossless;
  config.exact = t->lossless;
  config.use_sharp_yuv = t->sharp_yuv;
  config.thread_level = 0;
  if (!WebPValidateConfig(&config)) return 0;
  pic.width = img->w;
  pic.height = img->h;
  pic.use_argb = t->lossless;
  ok = (img->ch == 4) ? WebPPictureImportRGBA(&pic, img->px, img->w * 4)
                      : WebPPictureImportRGB(&pic, img->px, img->w * 3);
  WebPMemoryWriterInit(out);
  if (ok) {
    pic.writer = WebPMemoryWrite;
    pic.custom_ptr = out;
    ok = WebPEncode(&config, &pic);
  }
  WebPPictureFree(&pic);
  if (!ok) WebPMemoryWriterClear(out);
  return ok;
}

static int Rescale(const Image* img, uint64_t* hash) {
  WebPPicture pic;
  int ok;
  if (!WebPPictureInit(&pic)) return 0;
  pic.width = img->w;
  pic.height = img->h;
  pic.use_argb = 1;
  ok = (img->ch == 4) ? WebPPictureImportRGBA(&pic, img->px, img->w * 4)
                      : WebPPictureImportRGB(&pic, img->px, img->w * 3);
  ok = ok && WebPPictureRescale(&pic, img->w / 2, img->h / 2);
  if (ok && hash != NULL) {
    *hash = Fnv1a((const uint8_t*)pic.argb, (size_t)pic.argb_stride * pic.height * 4);
  }
  WebPPictureFree(&pic);
  return ok;
}

static int VerifyLossless(const Image* img, const WebPMemoryWriter* bits) {
  int w, h, ok;
  uint8_t* dec = (img->ch == 4) ? WebPDecodeRGBA(bits->mem, bits->size, &w, &h)
                                : WebPDecodeRGB(bits->mem, bits->size, &w, &h);
  ok = dec != NULL && w == img->w && h == img->h &&
       memcmp(dec, img->px, (size_t)w * h * img->ch) == 0;
  WebPFree(dec);
  return ok;
}

static int BenchRaw(const char* path, const uint8_t* data, size_t size, const char* out_dir) {
  const char* name = BaseName(path);
  Image img;
  size_t i;
  if (size < 16 || memcmp(data, "RAWI", 4) != 0) return 0;
  img.w = (int)Le32(data + 4);
  img.h = (int)Le32(data + 8);
  img.ch = (int)Le32(data + 12);
  img.px = data + 16;
  if (img.w <= 0 || img.h <= 0 || (img.ch != 3 && img.ch != 4) ||
      size != 16 + (size_t)img.w * img.h * img.ch) {
    return 0;
  }

  for (i = 0; i < sizeof(kEncTests) / sizeof(kEncTests[0]); ++i) {
    const EncTest* t = &kEncTests[i];
    WebPMemoryWriter first;
    int iters = 0;
    double start, secs;
    uint64_t hash;
    if (!Encode(&img, t, &first)) return 0;  // warm-up; its output is the one reported/verified
    hash = Fnv1a(first.mem, first.size);
    if (t->lossless && !VerifyLossless(&img, &first)) {
      fprintf(stderr, "%s: %s round trip mismatch\n", name, t->name);
      return 0;
    }
    if (out_dir != NULL && t->out_suffix != NULL) {
      char out[4096];
      snprintf(out, sizeof(out), "%s/%.*s%s", out_dir, (int)(strlen(name) - 5), name, t->out_suffix);
      if (!SaveFile(out, first.mem, first.size)) return 0;
    }
    start = Now();
    do {
      WebPMemoryWriter w;
      if (!Encode(&img, t, &w)) return 0;
      WebPMemoryWriterClear(&w);
      ++iters;
      secs = Now() - start;
    } while (secs < min_seconds || iters < 2);
    Report(t->name, name, img.w, img.h, iters, secs, first.size, hash);
    WebPMemoryWriterClear(&first);
  }

  {
    int iters = 0;
    double start, secs;
    uint64_t hash;
    if (!Rescale(&img, &hash)) return 0;
    start = Now();
    do {
      if (!Rescale(&img, NULL)) return 0;
      ++iters;
      secs = Now() - start;
    } while (secs < min_seconds || iters < 2);
    Report("rescale-50pct-argb", name, img.w, img.h, iters, secs, 0, hash);
  }
  return 1;
}

static int BenchWebP(const char* path, const uint8_t* data, size_t size) {
  WebPBitstreamFeatures f;
  uint8_t* out;
  size_t out_size;
  int iters = 0, stride;
  double start, secs;
  uint64_t hash;
  if (WebPGetFeatures(data, size, &f) != VP8_STATUS_OK) return 0;
  stride = f.width * 4;
  out_size = (size_t)stride * f.height;
  out = (uint8_t*)malloc(out_size);
  if (out == NULL || WebPDecodeBGRAInto(data, size, out, out_size, stride) == NULL) {
    free(out);
    return 0;
  }
  hash = Fnv1a(out, out_size);
  start = Now();
  do {
    if (WebPDecodeBGRAInto(data, size, out, out_size, stride) == NULL) {
      free(out);
      return 0;
    }
    ++iters;
    secs = Now() - start;
  } while (secs < min_seconds || iters < 2);
  Report(f.format == 2 ? "dec-lossless-bgra" : "dec-lossy-bgra", BaseName(path), f.width,
         f.height, iters, secs, size, hash);
  free(out);
  return 1;
}

int main(int argc, char* argv[]) {
  const char* out_dir = NULL;
  int i, ok = 1;
  for (i = 1; i < argc && argv[i][0] == '-'; ++i) {
    if (!strcmp(argv[i], "-t") && i + 1 < argc) {
      min_seconds = atof(argv[++i]);
    } else if (!strcmp(argv[i], "-o") && i + 1 < argc) {
      out_dir = argv[++i];
    } else {
      fprintf(stderr, "Usage: %s [-t min_seconds] [-o out_dir] file.rawi|file.webp...\n", argv[0]);
      return 2;
    }
  }
  {
    const int enc = WebPGetEncoderVersion(), dec = WebPGetDecoderVersion();
    fprintf(stderr, "libwebp encoder %d.%d.%d, decoder %d.%d.%d\n", enc >> 16, (enc >> 8) & 0xff,
            enc & 0xff, dec >> 16, (dec >> 8) & 0xff, dec & 0xff);
  }
  printf("test,file,width,height,iters,seconds,mpix_per_s,bytes,hash\n");
  for (; i < argc; ++i) {
    size_t size = 0;
    uint8_t* data = LoadFile(argv[i], &size);
    int r = 0;
    if (data == NULL) {
      fprintf(stderr, "cannot read %s\n", argv[i]);
    } else if (EndsWith(argv[i], ".rawi")) {
      r = BenchRaw(argv[i], data, size, out_dir);
    } else if (EndsWith(argv[i], ".webp")) {
      r = BenchWebP(argv[i], data, size);
    } else {
      fprintf(stderr, "unknown file type: %s\n", argv[i]);
    }
    if (!r) {
      fprintf(stderr, "FAILED: %s\n", argv[i]);
      ok = 0;
    }
    free(data);
  }
  return ok ? 0 : 1;
}
