const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dynamic = b.option(bool, "dynamic", "build dynamic library (default: false)") orelse false;
    const opts = .{
        .name = "webp",
        .target = target,
        .optimize = optimize,
    };

    const lib: *std.Build.Step.Compile = if (dynamic) b.addSharedLibrary(opts) else b.addStaticLibrary(opts);

    var c_flags = std.ArrayList([]const u8).init(b.allocator);
    defer c_flags.deinit();
    try c_flags.appendSlice(&.{
        "-fno-sanitize=undefined",
        "-fvisibility=hidden",
        "-Wextra",
        "-Wold-style-definition",
        "-Wmissing-prototypes",
        "-Wmissing-declarations",
        "-Wdeclaration-after-statement",
        "-Wshadow",
        "-Wformat-security",
        "-Wformat-nonliteral",
        "-I.",
        "-Isrc/",
        "-Wall",
        "-lm",
    });

    // Platform-specific flags
    {
        const t = lib.target_info.target;
        // For 32bit x86 platform
        if (have_x86_feat(t, .@"32bit_mode") and !have_x86_feat(t, .@"64bit"))
            try c_flags.append("-m32");
        // SSE4.1-specific flags:
        if (have_x86_feat(t, .sse4_1)) {
            lib.defineCMacro("WEBP_HAVE_SSE41", null);
            try c_flags.append("-msse4.1");
        }
        // NEON-specific flags:
        if (have_arm_feat(t, .neon) or have_aarch64_feat(t, .neon)) {
            try c_flags.appendSlice(&.{ "-march=armv7-a", "-mfloat-abi=hard", "-mfpu=neon", "-mtune=cortex-a8" });
        }
        // MIPS (MSA) 32-bit build specific flags for mips32r5 (p5600):
        if (have_mips_feat(t, .mips32r5))
            try c_flags.appendSlice(&.{ "-mips32r5", "-mabi=32", "-mtune=p5600", "-mmsa", "-mfp64", "-msched-weight", "-mload-store-pairs" });
        // MIPS (MSA) 64-bit build specific flags for mips64r6 (i6400):
        if (have_mips_feat(t, .mips64r6))
            try c_flags.appendSlice(&.{ "-mips64r6", "-mabi=64", "-mtune=i6400", "-mmsa", "-mfp64", "-msched-weight", "-mload-store-pairs" });
    }

    lib.addCSourceFiles(.{ .files = libwebp_srsc, .flags = c_flags.items });
    lib.force_pic = true;
    lib.linkLibC();
    lib.addIncludePath(.{ .path = "." });
    const headers = .{ "decode.h", "demux.h", "encode.h", "mux_types.h", "mux.h", "types.h" };
    inline for (headers) |h| lib.installHeader("src/webp/" ++ h, h);
    lib.defineCMacro("WEBP_USE_THREAD", null);
    lib.linkSystemLibrary("pthread");

    b.installArtifact(lib);
}

const StrSlice = []const []const u8;

const libsharpyuv_srsc = sharpyuv_srcs;
const libwebpdecoder_srsc = dec_srcs ++ dsp_dec_srsc ++ utils_dec_srsc;
const libwebp_srsc = libwebpdecoder_srsc ++ enc_srsc ++ dsp_enc_srcs ++ utils_enc_srcs ++ libsharpyuv_srsc;
// const libwebpmux_srsc = mux_srcs;
// const libwebpdemux_srsc = demux_srcs;
// const libwebpextra = extra_srsc;

const sharpyuv_srcs: StrSlice = &.{
    "sharpyuv/sharpyuv.c",
    "sharpyuv/sharpyuv_cpu.c",
    "sharpyuv/sharpyuv_csp.c",
    "sharpyuv/sharpyuv_dsp.c",
    "sharpyuv/sharpyuv_gamma.c",
    "sharpyuv/sharpyuv_neon.c",
    "sharpyuv/sharpyuv_sse2.c",
};

const dec_srcs: StrSlice = &.{
    "src/dec/alpha_dec.c",
    "src/dec/buffer_dec.c",
    "src/dec/frame_dec.c",
    "src/dec/idec_dec.c",
    "src/dec/io_dec.c",
    "src/dec/quant_dec.c",
    "src/dec/tree_dec.c",
    "src/dec/vp8_dec.c",
    "src/dec/vp8l_dec.c",
    "src/dec/webp_dec.c",
};

// const demux_srcs: StrSlice = &.{
//     "src/demux/anim_decode.c",
//     "src/demux/demux.c",
// };

const dsp_dec_srsc: StrSlice = &.{
    "src/dsp/alpha_processing.c",
    "src/dsp/alpha_processing_mips_dsp_r2.c",
    "src/dsp/alpha_processing_neon.c",
    "src/dsp/alpha_processing_sse2.c",
    "src/dsp/alpha_processing_sse41.c",
    "src/dsp/cpu.c",
    "src/dsp/dec.c",
    "src/dsp/dec_clip_tables.c",
    "src/dsp/dec_mips32.c",
    "src/dsp/dec_mips_dsp_r2.c",
    "src/dsp/dec_msa.c",
    "src/dsp/dec_neon.c",
    "src/dsp/dec_sse2.c",
    "src/dsp/dec_sse41.c",
    "src/dsp/filters.c",
    "src/dsp/filters_mips_dsp_r2.c",
    "src/dsp/filters_msa.c",
    "src/dsp/filters_neon.c",
    "src/dsp/filters_sse2.c",
    "src/dsp/lossless.c",
    "src/dsp/lossless_mips_dsp_r2.c",
    "src/dsp/lossless_msa.c",
    "src/dsp/lossless_neon.c",
    "src/dsp/lossless_sse2.c",
    "src/dsp/lossless_sse41.c",
    "src/dsp/rescaler.c",
    "src/dsp/rescaler_mips32.c",
    "src/dsp/rescaler_mips_dsp_r2.c",
    "src/dsp/rescaler_msa.c",
    "src/dsp/rescaler_neon.c",
    "src/dsp/rescaler_sse2.c",
    "src/dsp/upsampling.c",
    "src/dsp/upsampling_mips_dsp_r2.c",
    "src/dsp/upsampling_msa.c",
    "src/dsp/upsampling_neon.c",
    "src/dsp/upsampling_sse2.c",
    "src/dsp/upsampling_sse41.c",
    "src/dsp/yuv.c",
    "src/dsp/yuv_mips32.c",
    "src/dsp/yuv_mips_dsp_r2.c",
    "src/dsp/yuv_neon.c",
    "src/dsp/yuv_sse2.c",
    "src/dsp/yuv_sse41.c",
};

const dsp_enc_srcs: StrSlice = &.{
    "src/dsp/cost.c",
    "src/dsp/cost_mips32.c",
    "src/dsp/cost_mips_dsp_r2.c",
    "src/dsp/cost_neon.c",
    "src/dsp/cost_sse2.c",
    "src/dsp/enc.c",
    "src/dsp/enc_mips32.c",
    "src/dsp/enc_mips_dsp_r2.c",
    "src/dsp/enc_msa.c",
    "src/dsp/enc_neon.c",
    "src/dsp/enc_sse2.c",
    "src/dsp/enc_sse41.c",
    "src/dsp/lossless_enc.c",
    "src/dsp/lossless_enc_mips32.c",
    "src/dsp/lossless_enc_mips_dsp_r2.c",
    "src/dsp/lossless_enc_msa.c",
    "src/dsp/lossless_enc_neon.c",
    "src/dsp/lossless_enc_sse2.c",
    "src/dsp/lossless_enc_sse41.c",
    "src/dsp/ssim.c",
    "src/dsp/ssim_sse2.c",
};

const enc_srsc: StrSlice = &.{
    "src/enc/alpha_enc.c",
    "src/enc/analysis_enc.c",
    "src/enc/backward_references_cost_enc.c",
    "src/enc/backward_references_enc.c",
    "src/enc/config_enc.c",
    "src/enc/cost_enc.c",
    "src/enc/filter_enc.c",
    "src/enc/frame_enc.c",
    "src/enc/histogram_enc.c",
    "src/enc/iterator_enc.c",
    "src/enc/near_lossless_enc.c",
    "src/enc/picture_enc.c",
    "src/enc/picture_csp_enc.c",
    "src/enc/picture_psnr_enc.c",
    "src/enc/picture_rescale_enc.c",
    "src/enc/picture_tools_enc.c",
    "src/enc/predictor_enc.c",
    "src/enc/quant_enc.c",
    "src/enc/syntax_enc.c",
    "src/enc/token_enc.c",
    "src/enc/tree_enc.c",
    "src/enc/vp8l_enc.c",
    "src/enc/webp_enc.c",
};

// const mux_srcs: StrSlice = &.{
//     "src/mux/anim_encode.c",
//     "src/mux/muxedit.c",
//     "src/mux/muxinternal.c",
//     "src/mux/muxread.c",
// };

const utils_dec_srsc: StrSlice = &.{
    "src/utils/bit_reader_utils.c",
    "src/utils/color_cache_utils.c",
    "src/utils/filters_utils.c",
    "src/utils/huffman_utils.c",
    "src/utils/palette.c",
    "src/utils/quant_levels_dec_utils.c",
    "src/utils/random_utils.c",
    "src/utils/rescaler_utils.c",
    "src/utils/thread_utils.c",
    "src/utils/utils.c",
};

const utils_enc_srcs: StrSlice = &.{
    "src/utils/bit_writer_utils.c",
    "src/utils/huffman_encode_utils.c",
    "src/utils/quant_levels_utils.c",
};

// const extra_srsc: StrSlice = &.{
//     "extras/extras.c",
//     "extras/quality_estimate.c",
// };

fn have_x86_feat(t: std.Target, feat: std.Target.x86.Feature) bool {
    return switch (t.cpu.arch) {
        .x86, .x86_64 => std.Target.x86.featureSetHas(t.cpu.features, feat),
        else => false,
    };
}

fn have_arm_feat(t: std.Target, feat: std.Target.arm.Feature) bool {
    return switch (t.cpu.arch) {
        .arm, .armeb => std.Target.arm.featureSetHas(t.cpu.features, feat),
        else => false,
    };
}

fn have_aarch64_feat(t: std.Target, feat: std.Target.aarch64.Feature) bool {
    return switch (t.cpu.arch) {
        .aarch64,
        .aarch64_be,
        .aarch64_32,
        => std.Target.aarch64.featureSetHas(t.cpu.features, feat),

        else => false,
    };
}

fn have_mips_feat(t: std.Target, feat: std.Target.mips.Feature) bool {
    return switch (t.cpu.arch) {
        .mips, .mipsel, .mips64, .mips64el => std.Target.mips.featureSetHas(t.cpu.features, feat),
        else => false,
    };
}
