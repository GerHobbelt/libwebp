// Tuning knobs and stage timers for the lossless encoder fork (webpll).
//
// Knobs are read once from environment variables; -1 (unset) keeps the stock
// libwebp behavior. Timers accumulate wall time per stage across encodes.

#ifndef WEBP_ENC_LL_TUNE_H_
#define WEBP_ENC_LL_TUNE_H_

#include <stdlib.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  int iters;           // LL_ITERS: hash chain lookups per position
  int window_rows;     // LL_WINDOW_ROWS: LZ77 window in image rows
  int trace;           // LL_TRACE: 0/1 cost-based TraceBackwards
  int lz77;            // LL_LZ77: lz77 types to try (1 standard, 2 RLE, 4 box)
  int cache_bits;      // LL_CACHE_BITS: fixed color cache bits (skip search)
  int pred_modes;      // LL_PRED_MODES: bitmask of predictor modes to try
  int cross_color;     // LL_CROSS: 0 disables the cross-color transform
  int histo_bits;      // LL_HISTO_BITS: entropy image tile bits
  int transform_bits;  // LL_TRANSFORM_BITS: predictor/cross-color tile bits
  int pred_max_bits;   // LL_PRED_MAX_BITS: largest predictor subsampling tried
  int cross_step;      // LL_CROSS_STEP: row step when estimating cross-color
  int cross_red_iters;   // LL_CROSS_RED_ITERS: green-to-red search iterations
  int cross_blue_iters;  // LL_CROSS_BLUE_ITERS: green/red-to-blue iterations
  int cross_bits;        // LL_CROSS_BITS: cross-color tile bits
  int near_copy;         // LL_NEAR_COPY: plane codes searched for length-1 copies
  int entropy_idx;       // LL_ENTROPY_IDX: force transform set (1 spatial, 3 spatial+subgreen)
} VP8LTune;

enum {
  kLLAnalyze, kLLPredict, kLLCross, kLLHashChain, kLLLz77, kLLCache,
  kLLTrace, kLLHisto, kLLWrite, kLLMainImage, kLLImport, kLLNumTimers
};

const VP8LTune* VP8LGetTune(void);
double* VP8LTuneTimers(void);
extern int VP8LTuneMainImage;
// Chosen predictor mode counts per subsampling index (LL_STATS).
extern unsigned VP8LTunePredCounts[8][14];
// Main image pixels coded as literal / cache hit / copy (LL_STATS).
extern unsigned long long VP8LTuneRefStats[4];  // + [3] misses seen before

static inline double VP8LTuneNow(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

#ifdef __cplusplus
}
#endif

#endif  // WEBP_ENC_LL_TUNE_H_
