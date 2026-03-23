// Copyright 2025 Google Inc. All Rights Reserved.
//
// Use of this source code is governed by a BSD-style license
// that can be found in the COPYING file in the root of the source
// tree. An additional intellectual property rights grant can be found
// in the file PATENTS. All contributing project authors may
// be found in the AUTHORS file in the root of the source tree.
// -----------------------------------------------------------------------------
//
// Windows-only tool: decodes an animated WebP file and writes each composited
// frame as PNG into a new folder next to the file, named like the file without
// its extension (e.g. clip.webp -> folder "clip" with 0000.png, 0001.png, ...).
// With --ffmpeg-bmp (or --ffmpeg-raw), writes BMP frames to stdout for ffmpeg
// image2pipe (no -video_size needed).

#ifndef _WIN32

#include <stdio.h>

int main(void) {
  fprintf(stderr, "webp_anim2png: this example is only built for Windows.\n");
  return 1;
}

#else

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <windows.h>

#include "../imageio/image_enc.h"
#include "../imageio/imageio_util.h"
#include "./unicode.h"
#include "webp/decode.h"
#include "webp/demux.h"
#include "webp/mux_types.h"
#include "webp/types.h"

static void CleanupTransparentPixels(uint32_t* rgba, uint32_t width,
                                     uint32_t height) {
  const uint32_t* const rgba_end = rgba + width * height;
  while (rgba < rgba_end) {
    const uint8_t alpha = (*rgba >> 24) & 0xff;
    if (alpha == 0) {
      *rgba = 0;
    }
    ++rgba;
  }
}

// Same decode + per-frame cleanup as the PNG path, without writing files.
// Prints wall time for comparison with full export.
static int BenchmarkDecodeOnly(const WebPData* const webp_data) {
  WebPAnimDecoderOptions dec_options;
  WebPAnimDecoder* dec = NULL;
  WebPAnimInfo anim_info;
  LARGE_INTEGER freq, t0, t1;
  uint32_t frame_index = 0;
  double seconds;

  if (!WebPAnimDecoderOptionsInit(&dec_options)) {
    fprintf(stderr, "WebPAnimDecoderOptionsInit failed.\n");
    return 0;
  }
  dec_options.color_mode = MODE_BGRA;

  dec = WebPAnimDecoderNew(webp_data, &dec_options);
  if (dec == NULL) {
    fprintf(stderr, "Could not open as an animated WebP (or demux failed).\n");
    return 0;
  }
  if (!WebPAnimDecoderGetInfo(dec, &anim_info)) {
    fprintf(stderr, "WebPAnimDecoderGetInfo failed.\n");
    WebPAnimDecoderDelete(dec);
    return 0;
  }

  if (!QueryPerformanceFrequency(&freq) || !QueryPerformanceCounter(&t0)) {
    fprintf(stderr, "QueryPerformanceCounter failed.\n");
    WebPAnimDecoderDelete(dec);
    return 0;
  }

  while (WebPAnimDecoderHasMoreFrames(dec)) {
    uint8_t* rgba = NULL;
    int timestamp = 0;
    if (!WebPAnimDecoderGetNext(dec, &rgba, &timestamp)) {
      fprintf(stderr, "Error decoding frame #%u\n", frame_index);
      WebPAnimDecoderDelete(dec);
      return 0;
    }
    (void)timestamp;
    CleanupTransparentPixels((uint32_t*)rgba, anim_info.canvas_width,
                             anim_info.canvas_height);
    ++frame_index;
  }

  if (!QueryPerformanceCounter(&t1)) {
    fprintf(stderr, "QueryPerformanceCounter failed.\n");
    WebPAnimDecoderDelete(dec);
    return 0;
  }

  seconds = (double)(t1.QuadPart - t0.QuadPart) / (double)freq.QuadPart;
  printf("decode-only benchmark: %u frame(s) in %.3f s", frame_index, seconds);
  if (frame_index > 0) {
    printf(" (%.2f ms/frame)", 1000.0 * seconds / (double)frame_index);
  }
  printf("\n");

  WebPAnimDecoderDelete(dec);
  return 1;
}

// One BMP per frame (headers include size) for: ffmpeg -f image2pipe -i - ...
// Does not set stdout binary mode or print the ffmpeg hint (caller does once).
static int StreamBmpFramesForFfmpeg(const WebPData* const webp_data) {
  WebPAnimDecoderOptions dec_options;
  WebPAnimDecoder* dec = NULL;
  WebPAnimInfo anim_info;
  uint32_t frame_index = 0;

  if (!WebPAnimDecoderOptionsInit(&dec_options)) {
    fprintf(stderr, "WebPAnimDecoderOptionsInit failed.\n");
    return 0;
  }
  dec_options.color_mode = MODE_BGRA;

  dec = WebPAnimDecoderNew(webp_data, &dec_options);
  if (dec == NULL) {
    fprintf(stderr, "Could not open as an animated WebP (or demux failed).\n");
    return 0;
  }
  if (!WebPAnimDecoderGetInfo(dec, &anim_info)) {
    fprintf(stderr, "WebPAnimDecoderGetInfo failed.\n");
    WebPAnimDecoderDelete(dec);
    return 0;
  }

  while (WebPAnimDecoderHasMoreFrames(dec)) {
    uint8_t* rgba = NULL;
    int timestamp = 0;
    WebPDecBuffer buffer;

    if (!WebPAnimDecoderGetNext(dec, &rgba, &timestamp)) {
      fprintf(stderr, "Error decoding frame #%u\n", frame_index);
      WebPAnimDecoderDelete(dec);
      return 0;
    }
    (void)timestamp;
    CleanupTransparentPixels((uint32_t*)rgba, anim_info.canvas_width,
                             anim_info.canvas_height);

    if (!WebPInitDecBuffer(&buffer)) {
      fprintf(stderr, "WebPInitDecBuffer failed.\n");
      WebPAnimDecoderDelete(dec);
      return 0;
    }
    buffer.colorspace = MODE_BGRA;
    buffer.is_external_memory = 1;
    buffer.width = anim_info.canvas_width;
    buffer.height = anim_info.canvas_height;
    buffer.u.RGBA.rgba = rgba;
    buffer.u.RGBA.stride =
        (int)(anim_info.canvas_width * sizeof(uint32_t));
    buffer.u.RGBA.size =
        (size_t)buffer.u.RGBA.stride * anim_info.canvas_height;

    if (!WebPWriteBMP(stdout, &buffer)) {
      fprintf(stderr, "WebPWriteBMP failed at frame #%u\n", frame_index);
      WebPFreeDecBuffer(&buffer);
      WebPAnimDecoderDelete(dec);
      return 0;
    }
    WebPFreeDecBuffer(&buffer);
    ++frame_index;
  }

  WebPAnimDecoderDelete(dec);
  return 1;
}

static int IsFfmpegBmpPipeArg(const char* const s) {
  return !strcmp(s, "--ffmpeg-bmp") || !strcmp(s, "--ffmpeg-raw");
}

// Truncates 'path' in place at the last extension dot after the last path
// separator ('\\' or '/'). Returns 0 if no suitable dot was found.
static int StripFileExtension(W_CHAR* path) {
  W_CHAR* last_sep = WSTRRCHR(path, '\\');
#if defined(_WIN32) && defined(_UNICODE)
  {
    W_CHAR* const s2 = wcsrchr(path, L'/');
    if (s2 != NULL && (last_sep == NULL || s2 > last_sep)) last_sep = s2;
  }
#else
  {
    char* const s2 = strrchr((char*)path, '/');
    if (s2 != NULL &&
        (last_sep == NULL || s2 > (char*)last_sep)) {
      last_sep = (W_CHAR*)s2;
    }
  }
#endif
  W_CHAR* const last_dot = WSTRRCHR(path, '.');
  if (last_dot == NULL) return 0;
  if (last_sep != NULL && last_dot <= last_sep) return 0;
  *last_dot = 0;
  return 1;
}

static int EnsureOutputFolder(const W_CHAR* path) {
#if defined(_UNICODE)
  if (CreateDirectoryW(path, NULL)) return 1;
  return GetLastError() == ERROR_ALREADY_EXISTS;
#else
  if (CreateDirectoryA((const char*)path, NULL)) return 1;
  return GetLastError() == ERROR_ALREADY_EXISTS;
#endif
}

static void PrintUsage(void) {
  printf("Usage: webp_anim2png <animated.webp>\n");
  printf(
      "       webp_anim2png --decode-only <animated.webp>\n"
      "       webp_anim2png --ffmpeg-bmp <animated.webp> [<animated.webp> ...]\n"
      "Creates a folder with the same base name as the file (without "
      "extension)\n"
      "and saves each decoded frame as PNG (0000.png, 0001.png, ...).\n"
      "--decode-only decodes to memory only and prints timing (no PNG files).\n"
      "--ffmpeg-bmp writes one BMP per frame to stdout for ffmpeg -f image2pipe "
      "(alias: --ffmpeg-raw). Multiple inputs are concatenated in file order.\n");
}

int main(int argc, const char* argv[]) {
  WebPAnimDecoder* dec = NULL;
  WebPData webp_data;
  int exit_code = EXIT_FAILURE;
  uint32_t frame_index = 0;

  INIT_WARGV(argc, argv);

  if (argc < 2) {
    PrintUsage();
    FREE_WARGV_AND_RETURN(EXIT_FAILURE);
  }
  if (!strcmp(argv[1], "-h") || !strcmp(argv[1], "-help")) {
    if (argc != 2) {
      PrintUsage();
      FREE_WARGV_AND_RETURN(EXIT_FAILURE);
    }
    PrintUsage();
    FREE_WARGV_AND_RETURN(EXIT_SUCCESS);
  }
  if (!strcmp(argv[1], "--decode-only")) {
    if (argc != 3) {
      PrintUsage();
      FREE_WARGV_AND_RETURN(EXIT_FAILURE);
    }
  } else if (IsFfmpegBmpPipeArg(argv[1])) {
    if (argc < 3) {
      PrintUsage();
      FREE_WARGV_AND_RETURN(EXIT_FAILURE);
    }
  } else if (argc != 2) {
    PrintUsage();
    FREE_WARGV_AND_RETURN(EXIT_FAILURE);
  }

  WebPDataInit(&webp_data);

  {
    const int decode_only =
        (argc == 3 && !strcmp(argv[1], "--decode-only"));
    const int ffmpeg_bmp = IsFfmpegBmpPipeArg(argv[1]);
    const int arg_input = (argc >= 3 && !ffmpeg_bmp) ? 2 : 1;
    WebPAnimDecoderOptions dec_options;
    const W_CHAR* const in_path = GET_WARGV(argv, arg_input);
    W_CHAR folder_path[1024];

    if (ffmpeg_bmp) {
      fprintf(stderr,
              "BMP sequence on stdout. Example: ffmpeg -f image2pipe "
              "-framerate "
              "30 -i - -c:v libx264 -pix_fmt yuv420p out.mp4\n");
      fflush(stderr);
      if (ImgIoUtilSetBinaryMode(stdout) == NULL) {
        goto End;
      }
      {
        int arg_i;
        for (arg_i = 2; arg_i < argc; ++arg_i) {
          const W_CHAR* const in_path_ff = GET_WARGV(argv, arg_i);
          WebPDataClear(&webp_data);
          WebPDataInit(&webp_data);
          if (!ImgIoUtilReadFile((const char*)in_path_ff, &webp_data.bytes,
                                 &webp_data.size)) {
            goto End;
          }
          if (!WebPGetInfo(webp_data.bytes, webp_data.size, NULL, NULL)) {
            WFPRINTF(stderr, "Not a WebP file: %s\n", in_path_ff);
            goto End;
          }
          if (!StreamBmpFramesForFfmpeg(&webp_data)) {
            goto End;
          }
        }
      }
      exit_code = EXIT_SUCCESS;
      goto End;
    }

    if (WSTRLEN(in_path) + 1 > sizeof(folder_path) / sizeof(folder_path[0])) {
      WFPRINTF(stderr, "Path too long: %s\n", in_path);
      goto End;
    }
    memcpy(folder_path, in_path,
           (WSTRLEN(in_path) + 1) * sizeof(W_CHAR));

    if (!decode_only) {
      if (!StripFileExtension(folder_path)) {
        WFPRINTF(stderr,
                 "Could not derive output folder name from: %s\n"
                 "(expected a file name with an extension, e.g. anim.webp)\n",
                 in_path);
        goto End;
      }
    }

    if (!ImgIoUtilReadFile((const char*)in_path, &webp_data.bytes,
                           &webp_data.size)) {
      goto End;
    }

    if (!WebPGetInfo(webp_data.bytes, webp_data.size, NULL, NULL)) {
      WFPRINTF(stderr, "Not a WebP file: %s\n", in_path);
      goto End;
    }

    if (decode_only) {
      if (!BenchmarkDecodeOnly(&webp_data)) {
        goto End;
      }
      exit_code = EXIT_SUCCESS;
      goto End;
    }

    if (!WebPAnimDecoderOptionsInit(&dec_options)) {
      fprintf(stderr, "WebPAnimDecoderOptionsInit failed.\n");
      goto End;
    }
    // WIC-based PNG output treats pixels as BGRA; decode in BGRA so channels
    // match (default MODE_RGBA would be misinterpreted and look blue-shifted).
    dec_options.color_mode = MODE_BGRA;

    dec = WebPAnimDecoderNew(&webp_data, &dec_options);
    if (dec == NULL) {
      WFPRINTF(
          stderr,
          "Could not open as an animated WebP (or demux failed): %s\n",
          in_path);
      goto End;
    }

    if (!EnsureOutputFolder(folder_path)) {
      WFPRINTF(stderr, "Could not create folder: %s\n", folder_path);
      goto End;
    }

    {
      WebPAnimInfo anim_info;
      if (!WebPAnimDecoderGetInfo(dec, &anim_info)) {
        fprintf(stderr, "WebPAnimDecoderGetInfo failed.\n");
        goto End;
      }

      while (WebPAnimDecoderHasMoreFrames(dec)) {
        uint8_t* rgba = NULL;
        int timestamp = 0;
        WebPDecBuffer buffer;
        W_CHAR out_file[1024];

        if (!WebPAnimDecoderGetNext(dec, &rgba, &timestamp)) {
          fprintf(stderr, "Error decoding frame #%u\n", frame_index);
          goto End;
        }
        (void)timestamp;

        CleanupTransparentPixels((uint32_t*)rgba, anim_info.canvas_width,
                                 anim_info.canvas_height);

        if (!WebPInitDecBuffer(&buffer)) {
          fprintf(stderr, "WebPInitDecBuffer failed.\n");
          goto End;
        }
        buffer.colorspace = MODE_BGRA;
        buffer.is_external_memory = 1;
        buffer.width = anim_info.canvas_width;
        buffer.height = anim_info.canvas_height;
        buffer.u.RGBA.rgba = rgba;
        buffer.u.RGBA.stride =
            (int)(anim_info.canvas_width * sizeof(uint32_t));
        buffer.u.RGBA.size =
            (size_t)buffer.u.RGBA.stride * anim_info.canvas_height;

        WSNPRINTF(out_file, sizeof(out_file), "%s\\%.4d.png", folder_path,
                  frame_index);
        if (!WebPSaveImage(&buffer, PNG, (const char*)out_file)) {
          WFPRINTF(stderr, "Error writing: %s\n", out_file);
          WebPFreeDecBuffer(&buffer);
          goto End;
        }
        WebPFreeDecBuffer(&buffer);
        ++frame_index;
      }
    }

    WPRINTF("Wrote %u frame(s) to %s\\\n", frame_index, folder_path);
    exit_code = EXIT_SUCCESS;
  }

End:
  WebPAnimDecoderDelete(dec);
  WebPDataClear(&webp_data);
  FREE_WARGV_AND_RETURN(exit_code);
}

#endif  // _WIN32
