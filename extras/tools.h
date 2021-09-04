// Copyright 2015 Google Inc. All Rights Reserved.
//
// Use of this source code is governed by a BSD-style license
// that can be found in the COPYING file in the root of the source
// tree. An additional intellectual property rights grant can be found
// in the file PATENTS. All contributing project authors may
// be found in the AUTHORS file in the root of the source tree.
// -----------------------------------------------------------------------------
//

#ifndef WEBP_EXTRAS_TOOLS_H_
#define WEBP_EXTRAS_TOOLS_H_

#if defined(BUILD_MONOLITHIC)

#include "../src/webp/types.h"

#ifdef __cplusplus
extern "C" {
#endif

//------------------------------------------------------------------------------

WEBP_EXTERN int webp_anim_diff_main(int argc, const char** argv);
WEBP_EXTERN int webp_anim_dump_main(int argc, const char** argv);
WEBP_EXTERN int cwebp_main(int argc, const char** argv);
WEBP_EXTERN int dwebp_main(int argc, const char** argv);
WEBP_EXTERN int gif2webp_main(int argc, const char** argv);
WEBP_EXTERN int img2webp_main(int argc, const char** argv);
WEBP_EXTERN int vwebp_main(int argc, const char** argv);
WEBP_EXTERN int webpinfo_main(int argc, const char** argv);
WEBP_EXTERN int webpmux_main(int argc, const char** argv);
WEBP_EXTERN int webp_get_disto_main(int argc, const char** argv);
WEBP_EXTERN int vwebp_sdl_main(int argc, const char** argv);
WEBP_EXTERN int webp_quality_main(int argc, const char** argv);

#ifdef __cplusplus
}    // extern "C"
#endif

#endif

#endif  // WEBP_EXTRAS_EXTRAS_H_
