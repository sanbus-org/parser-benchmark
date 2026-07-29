const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const optimized_c_flags = &.{ "-O3", "-DNDEBUG", "-std=c99" };

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = false,
    });

    const exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = root_module,
    });

    // Tree-sitter Core
    exe.root_module.addIncludePath(b.path("tree-sitter/lib/include"));
    exe.root_module.addIncludePath(b.path("tree-sitter/lib/src"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("tree-sitter/lib/src/lib.c"),
        .flags = &.{ "-O3", "-DNDEBUG", "-std=c99", "-D_GNU_SOURCE" },
    });

    // Tree-sitter JSON Parser
    exe.root_module.addIncludePath(b.path("tree-sitter-json/src"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("tree-sitter-json/src/parser.c"),
        .flags = optimized_c_flags,
    });

    // Generate the Bison/Flex parser into Zig's cache.
    const generate_bison_parser = b.addSystemCommand(&.{
        "sh",
        "scripts/generate-bison-parser.sh",
    });
    const parser_c = generate_bison_parser.addOutputFileArg("parser.c");
    const parser_h = generate_bison_parser.addOutputFileArg("parser.h");
    const lexer_c = generate_bison_parser.addOutputFileArg("lexer.c");
    generate_bison_parser.addFileArg(b.path("src/json.y"));
    generate_bison_parser.addFileArg(b.path("src/json.l"));

    exe.root_module.addIncludePath(parser_h.dirname());
    exe.root_module.addCSourceFile(.{
        .file = parser_c,
        .flags = optimized_c_flags,
    });
    exe.root_module.addCSourceFile(.{
        .file = lexer_c,
        .flags = &.{ "-O3", "-DNDEBUG", "-std=c99", "-D_GNU_SOURCE" },
    });

    // LALRPOP (Rust) static library
    const cargo_build = b.addSystemCommand(&.{ "cargo", "build", "--release" });
    cargo_build.setCwd(b.path("lalrpop-bench"));
    exe.step.dependOn(&cargo_build.step);
    exe.root_module.addObjectFile(b.path("lalrpop-bench/target/release/liblalrpop_bench.a"));
    if (target.result.os.tag == .linux) {
        exe.root_module.linkSystemLibrary("gcc_s", .{});
    }

    // Build simdjson + RapidJSON as a shared library using system clang++.
    // This avoids triggering Zig 0.16's broken libcxx sub-compilation on macOS.
    const build_cpplib = b.addSystemCommand(&.{"clang++"});
    build_cpplib.addArgs(&.{
        "-O3",
        "-std=c++17",
        "-fPIC",
        "-Wno-deprecated-literal-operator",
        "-Wno-nullability-completeness",
        "-Isrc",
        "-Isimdjson/singleheader",
        "-Irapidjson/include",
        "simdjson/singleheader/simdjson.cpp",
        "src/simdjson_wrapper.cpp",
        "src/rapidjson_wrapper.cpp",
    });
    const cpplib_name = switch (target.result.os.tag) {
        .macos => "libparsers.dylib",
        .linux => "libparsers.so",
        else => @panic("parser-benchmark supports macOS and Linux"),
    };
    build_cpplib.addArg(switch (target.result.os.tag) {
        .macos => "-dynamiclib",
        .linux => "-shared",
        else => unreachable,
    });
    build_cpplib.addArg("-o");
    const cpplib = build_cpplib.addOutputFileArg(cpplib_name);
    build_cpplib.setCwd(b.path("."));

    exe.root_module.addLibraryPath(cpplib.dirname());
    exe.root_module.addRPath(cpplib.dirname());
    exe.root_module.linkSystemLibrary("parsers", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        if (args.len > 0) {
            const external_dataset = externalDataset(args[0]);
            if (external_dataset) |dataset| {
                const fetch_dataset = b.addSystemCommand(&.{
                    "sh",
                    "scripts/fetch-dataset.sh",
                    dataset.name,
                });
                run_cmd.step.dependOn(&fetch_dataset.step);
                run_cmd.addArg(dataset.path);
                run_cmd.addArgs(args[1..]);
            } else {
                run_cmd.addArgs(args);
            }
        } else {
            addExternalDataset(b, run_cmd, .{
                .name = "twitter",
                .path = "datasets/twitter.json",
            });
        }
    } else {
        addExternalDataset(b, run_cmd, .{
            .name = "twitter",
            .path = "datasets/twitter.json",
        });
    }

    const run_step = b.step("run", "Run the benchmark");
    run_step.dependOn(&run_cmd.step);
}

const ExternalDataset = struct {
    name: []const u8,
    path: []const u8,
};

fn externalDataset(argument: []const u8) ?ExternalDataset {
    const datasets = [_]ExternalDataset{
        .{ .name = "canada", .path = "datasets/canada.json" },
        .{ .name = "citm_catalog", .path = "datasets/citm_catalog.json" },
        .{ .name = "twitter", .path = "datasets/twitter.json" },
    };

    for (datasets) |dataset| {
        if (std.mem.eql(u8, argument, dataset.name) or
            std.mem.eql(u8, argument, dataset.path))
        {
            return dataset;
        }
    }
    return null;
}

fn addExternalDataset(
    b: *std.Build,
    run_cmd: *std.Build.Step.Run,
    dataset: ExternalDataset,
) void {
    const fetch_dataset = b.addSystemCommand(&.{
        "sh",
        "scripts/fetch-dataset.sh",
        dataset.name,
    });
    run_cmd.step.dependOn(&fetch_dataset.step);
    run_cmd.addArg(dataset.path);
}
