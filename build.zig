const std = @import("std");

const FeatureLevel = struct {
    name: []const u8,
};

const Linkage = enum {
    static,
    dynamic,
};

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});

    const strict_floating_point = builder.option(bool, "strict_fp", "Use strict floating point (disable fast-math and FMA)") orelse false;
    const linkage = builder.option(Linkage, "linkage", "Library linkage") orelse .static;

    const fastnoise = builder.dependency("fastnoise", .{});
    const fastsimd = builder.dependency("fastsimd", .{});

    const module = builder.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    const library = builder.addLibrary(.{
        .name = "noise",
        .linkage = switch (linkage) {
            .static => .static,
            .dynamic => .dynamic,
        },
        .root_module = module,
    });

    const include_paths = [_]std.Build.LazyPath{
        fastnoise.path("include"),
        fastsimd.path("include"),
        fastsimd.path("dispatch"),
        fastnoise.path("src"),
    };

    for (&include_paths) |path| {
        module.addIncludePath(path);
    }

    module.addCMacro("FASTNOISE2_VERSION", "\"1.1.0\"");
    module.addCMacro("FASTSIMD_DISPATCH_CLASS", "1");

    switch (linkage) {
        .static => {
            module.addCMacro("FASTNOISE_STATIC_LIB", "1");
            module.addCMacro("FASTSIMD_STATIC_LIB", "1");
        },
        .dynamic => {
            module.addCMacro("FASTNOISE_EXPORT", "1");
            module.addCMacro("FASTSIMD_EXPORT", "1");
        },
    }

    const core_flags: []const []const u8 = &.{"-std=c++17"};

    module.addCSourceFile(.{ .file = fastsimd.path("src/FastSIMD.cpp"), .flags = core_flags });
    module.addCSourceFile(.{ .file = fastnoise.path("src/FastNoise/Metadata.cpp"), .flags = core_flags });
    module.addCSourceFile(.{ .file = fastnoise.path("src/FastNoise/SmartNode.cpp"), .flags = core_flags });
    module.addCSourceFile(.{ .file = fastnoise.path("src/FastNoise/FastNoise_C.cpp"), .flags = core_flags });

    const cpu_architecture = target.result.cpu.arch;
    const write_files = builder.addWriteFiles();

    module.addIncludePath(write_files.getDirectory());

    const feature_levels: []const FeatureLevel = switch (cpu_architecture) {
        .x86_64, .x86 => &.{
            .{ .name = "SSE2" },
            .{ .name = "SSE41" },
            .{ .name = "AVX2" },
            .{ .name = "AVX512" },
        },
        .aarch64 => &.{
            .{ .name = "AARCH64" },
        },
        .arm => &.{
            .{ .name = "NEON" },
        },
        .wasm32, .wasm64 => &.{
            .{ .name = "WASM" },
        },
        else => &.{},
    };

    var feature_list: []const u8 = "";

    for (feature_levels) |level| {
        feature_list = builder.fmt("{s},FastSIMD::FeatureSet::{s}\n", .{ feature_list, level.name });
    }

    _ = write_files.add("FastSIMD/FastSIMD_FastNoise_config.h", builder.fmt(
        "#pragma once\n\n" ++
            "#include <FastSIMD/Utility/ArchDetect.h>\n" ++
            "#include <FastSIMD/Utility/FeatureSetList.h>\n\n" ++
            "namespace FastSIMD {{\n" ++
            "namespace FastSIMD_FastNoise {{\n" ++
            "using CompiledFeatureSets = FeatureSetList<0\n" ++
            "{s}>;\n" ++
            "}}\n" ++
            "}}\n",
        .{feature_list},
    ));

    var common_flags_list: std.ArrayList([]const u8) = .empty;

    common_flags_list.ensureTotalCapacity(builder.allocator, 8) catch @panic("OOM");
    common_flags_list.appendAssumeCapacity("-std=c++17");
    common_flags_list.appendAssumeCapacity("-fno-stack-protector");
    common_flags_list.appendAssumeCapacity("-Wno-nan-infinity-disabled");
    common_flags_list.appendAssumeCapacity("-DFASTSIMD_LIBRARY_NAME=FastSIMD_FastNoise");

    if (!strict_floating_point) common_flags_list.appendAssumeCapacity("-ffast-math");

    const dispatch_flags = common_flags_list.items;

    for (feature_levels) |level| {
        const dispatch_content = builder.fmt(
            "#define FASTSIMD_MAX_FEATURE_SET {s}\n" ++
                "#include <FastSIMD/Utility/ArchDetect.h>\n" ++
                "#if 1\n" ++
                "#include <FastSIMD/FastSIMD_FastNoise_config.h>\n" ++
                "#include <impl/DispatchClassImpl.h>\n" ++
                "#include <FastNoise/FastSIMD_Build.inl>\n" ++
                "#endif\n",
            .{level.name},
        );

        const dispatch_file = write_files.add(
            builder.fmt("FastSIMD_FastNoise_{s}.cpp", .{level.name}),
            dispatch_content,
        );

        var query = target.query;

        if (cpu_architecture == .x86_64 or cpu_architecture == .x86) {
            const x86 = std.Target.x86;

            if (std.mem.eql(u8, level.name, "SSE41")) {
                query.cpu_features_add = x86.featureSet(&.{.sse4_1});
            } else if (std.mem.eql(u8, level.name, "AVX2")) {
                query.cpu_features_add = if (!strict_floating_point)
                    x86.featureSet(&.{ .avx2, .fma })
                else
                    x86.featureSet(&.{.avx2});
            } else if (std.mem.eql(u8, level.name, "AVX512")) {
                query.cpu_features_add = if (!strict_floating_point)
                    x86.featureSet(&.{ .avx512f, .avx512dq, .avx512vl, .avx512bw, .evex512, .fma })
                else
                    x86.featureSet(&.{ .avx512f, .avx512dq, .avx512vl, .avx512bw, .evex512 });
            }

            if (strict_floating_point and (std.mem.eql(u8, level.name, "AVX2") or std.mem.eql(u8, level.name, "AVX512"))) {
                query.cpu_features_sub = x86.featureSet(&.{.fma});
            }
        }

        const level_target = builder.resolveTargetQuery(query);
        const dispatch_module = builder.createModule(.{
            .target = level_target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });

        for (&include_paths) |path| dispatch_module.addIncludePath(path);

        dispatch_module.addIncludePath(write_files.getDirectory());
        dispatch_module.addCMacro("FASTNOISE2_VERSION", "\"1.1.0\"");
        dispatch_module.addCMacro("FASTSIMD_DISPATCH_CLASS", "1");

        switch (linkage) {
            .static => {
                dispatch_module.addCMacro("FASTNOISE_STATIC_LIB", "1");
                dispatch_module.addCMacro("FASTSIMD_STATIC_LIB", "1");
            },
            .dynamic => {
                dispatch_module.addCMacro("FASTNOISE_EXPORT", "1");
                dispatch_module.addCMacro("FASTSIMD_EXPORT", "1");
            },
        }

        dispatch_module.addCSourceFile(.{
            .file = dispatch_file,
            .flags = dispatch_flags,
        });

        const object = builder.addObject(.{
            .name = builder.fmt("fastnoise2_{s}", .{level.name}),
            .root_module = dispatch_module,
        });

        dispatch_module.addObjectFile(object.getEmittedBin());
    }

    library.installHeader(fastnoise.path("include/FastNoise/FastNoise_C.h"), "FastNoise/FastNoise_C_impl.h");

    library.installHeader(
        write_files.add("FastNoise_C.h", "#include <stdbool.h>\n" ++ "#include \"FastNoise_C_impl.h\"\n"),
        "FastNoise/FastNoise_C.h",
    );

    library.installHeader(fastnoise.path("include/FastNoise/FastNoise.h"), "FastNoise/FastNoise.h");
    library.installHeader(fastnoise.path("include/FastNoise/Metadata.h"), "FastNoise/Metadata.h");
    library.installHeadersDirectory(fastnoise.path("include/FastNoise/Generators"), "FastNoise/Generators", .{});
    library.installHeadersDirectory(fastnoise.path("include/FastNoise/Utility"), "FastNoise/Utility", .{});
    library.installHeadersDirectory(fastsimd.path("include/FastSIMD/Utility"), "FastSIMD/Utility", .{});
    library.installHeader(fastsimd.path("include/FastSIMD/DispatchClass.h"), "FastSIMD/DispatchClass.h");
    builder.installArtifact(library);

    const bindings_module = builder.addModule("noise", .{
        .root_source_file = builder.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    bindings_module.linkLibrary(library);
}
