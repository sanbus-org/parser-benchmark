const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const optimized_c_flags = &.{ "-O3", "-DNDEBUG", "-std=c99" };

    const root_module = b.createModule(.{
        .root_source_file = b.path("json/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = false,
    });

    const exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = root_module,
    });

    // Generate and assemble Galley's LL/LR, AST/non-AST JSON parsers through
    // its public API.
    // Use a local Galley checkout instead of the pinned `galley/`
    // submodule when GALLEY_LOCAL_PATH holds a filesystem path. Implemented
    // by refreshing the `galley-local` symlink (resolved through the
    // `galley_dev` path dependency), so any absolute — or root-relative —
    // checkout works:
    //   GALLEY_LOCAL_PATH=$PWD/../.. zig build -Doptimize=ReleaseFast run -- twitter
    const galley = if (localGalleyRoot(b)) |local_path| blk: {
        // The package manager snapshots the `galley-local` symlink before
        // build() runs, so a freshly created link only takes effect on the
        // next invocation. When the link is missing or stale, refresh it and
        // stop with instructions instead of silently benchmarking the pinned
        // tree.
        const root = b.build_root.handle;
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const current_len = root.readLink(b.graph.io, "galley-local", &link_buf) catch null;
        const want = std.mem.trimEnd(u8, local_path, "/");
        const current: ?[]const u8 = if (current_len) |len| link_buf[0..len] else null;
        if (current == null or !std.mem.eql(u8, current.?, want)) {
            root.deleteFile(b.graph.io, "galley-local") catch |err| switch (err) {
                error.FileNotFound => {},
                else => @panic("GALLEY_LOCAL_PATH: cannot replace galley-local"),
            };
            root.symLink(b.graph.io, want, "galley-local", .{}) catch
                @panic("GALLEY_LOCAL_PATH: cannot link local galley");
            std.debug.print(
                "GALLEY_LOCAL_PATH: linked galley-local, re-run the same command\n",
                .{},
            );
            std.process.exit(1);
        }
        break :blk b.dependency("galley_dev", .{
            .target = target,
            .optimize = optimize,
        });
    } else b.dependency("galley", .{
        .target = target,
        .optimize = optimize,
    });
    const generator_tool = b.addExecutable(.{
        .name = "generate-galley-json",
        .root_module = b.createModule(.{
            .root_source_file = b.path("json/generate_galley_json.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "galley_generator",
                    .module = galley.module("galley_generator"),
                },
            },
        }),
    });
    inline for ([_]GalleyVariant{
        .{ .name = "galley-ll-no-ast", .symbol_suffix = "ll_no_ast", .parser_type = "ll", .with_ast = false },
        .{ .name = "galley-ll-ast", .symbol_suffix = "ll_ast", .parser_type = "ll", .with_ast = true },
        .{ .name = "galley-lr-no-ast", .symbol_suffix = "lr_no_ast", .parser_type = "lr", .with_ast = false },
        .{ .name = "galley-lr-ast", .symbol_suffix = "lr_ast", .parser_type = "lr", .with_ast = true },
    }) |variant| {
        root_module.addObject(
            addGalleyVariant(b, target, optimize, galley, generator_tool, variant),
        );
    }

    // Tree-sitter Core
    exe.root_module.addIncludePath(b.path("tree-sitter/lib/include"));
    exe.root_module.addIncludePath(b.path("tree-sitter/lib/src"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("tree-sitter/lib/src/lib.c"),
        .flags = &.{ "-O3", "-DNDEBUG", "-std=c99", "-D_GNU_SOURCE" },
    });

    // Tree-sitter JSON Parser
    exe.root_module.addIncludePath(b.path("json/tree-sitter-json/src"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("json/tree-sitter-json/src/parser.c"),
        .flags = optimized_c_flags,
    });

    // Generate the Bison/Flex parser into Zig's cache.
    const generate_bison_parser = b.addSystemCommand(&.{
        "sh",
        "json/scripts/generate-bison-parser.sh",
    });
    const parser_c = generate_bison_parser.addOutputFileArg("parser.c");
    const parser_h = generate_bison_parser.addOutputFileArg("parser.h");
    const lexer_c = generate_bison_parser.addOutputFileArg("lexer.c");
    generate_bison_parser.addFileArg(b.path("json/json.y"));
    generate_bison_parser.addFileArg(b.path("json/json.l"));

    exe.root_module.addIncludePath(parser_h.dirname());
    exe.root_module.addCSourceFile(.{
        .file = parser_c,
        .flags = optimized_c_flags,
    });
    exe.root_module.addCSourceFile(.{
        .file = lexer_c,
        .flags = &.{ "-O3", "-DNDEBUG", "-std=c99", "-D_GNU_SOURCE" },
    });

    // yyjson DOM parser.
    exe.root_module.addIncludePath(b.path("json/yyjson/src"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("json/yyjson/src/yyjson.c"),
        .flags = optimized_c_flags,
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("json/yyjson_wrapper.c"),
        .flags = optimized_c_flags,
    });

    // LALRPOP (Rust) static library
    const cargo_build = b.addSystemCommand(&.{ "cargo", "build", "--release" });
    cargo_build.setCwd(b.path("json/lalrpop-bench"));
    exe.step.dependOn(&cargo_build.step);
    exe.root_module.addObjectFile(b.path("json/lalrpop-bench/target/release/liblalrpop_bench.a"));
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
        "-Ijson",
        "-Ijson/simdjson/singleheader",
        "-Ijson/rapidjson/include",
    });
    build_cpplib.addFileArg(b.path("json/simdjson/singleheader/simdjson.cpp"));
    build_cpplib.addFileArg(b.path("json/simdjson_wrapper.cpp"));
    build_cpplib.addFileArg(b.path("json/rapidjson_wrapper.cpp"));
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
            for (args) |arg| {
                if (externalDataset(arg)) |dataset| {
                    addExternalDataset(b, run_cmd, dataset);
                } else {
                    run_cmd.addArg(arg);
                }
            }
        } else {
            for (external_datasets) |dataset| {
                addExternalDataset(b, run_cmd, dataset);
            }
        }
    } else {
        for (external_datasets) |dataset| {
            addExternalDataset(b, run_cmd, dataset);
        }
    }

    const run_step = b.step("run", "Run the benchmark");
    run_step.dependOn(&run_cmd.step);
}

/// Filesystem path of a local Galley checkout when GALLEY_LOCAL_PATH holds
/// a non-empty value, otherwise null (use the pinned `galley/` submodule).
/// Refreshing the `galley-local` symlink happens at the dependency selection
/// site; this getter stays side-effect free so variant setup can reuse it.
fn localGalleyRoot(b: *std.Build) ?[]const u8 {
    const path = b.graph.environ_map.get("GALLEY_LOCAL_PATH") orelse return null;
    if (path.len == 0) return null;
    return path;
}

const GalleyVariant = struct {
    name: []const u8,
    symbol_suffix: []const u8,
    parser_type: []const u8,
    with_ast: bool,
};

fn addGalleyVariant(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    galley: *std.Build.Dependency,
    generator_tool: *std.Build.Step.Compile,
    variant: GalleyVariant,
) *std.Build.Step.Compile {
    const local_root = localGalleyRoot(b);
    const grammar_source: std.Build.LazyPath = if (local_root) |root|
        .{ .cwd_relative = b.fmt("{s}/languages/json-unicode/{s}.grm", .{ root, variant.parser_type }) }
    else
        galley.path(b.fmt(
            "languages/json-unicode/{s}.grm",
            .{variant.parser_type},
        ));
    const procedures_source: std.Build.LazyPath = if (local_root) |root|
        .{ .cwd_relative = b.fmt("{s}/languages/json-unicode/procedures.zig", .{root}) }
    else
        b.path("json/galley_procedures.zig");
    const error_messages_source: std.Build.LazyPath = if (local_root) |root|
        .{ .cwd_relative = b.fmt("{s}/languages/json-unicode/{s}_error_messages.zig", .{ root, variant.parser_type }) }
    else
        b.path("json/galley_error_messages.zig");
    // The generated parser reads `config.ast` at compile time, so each
    // variant needs its own config. Values mirror Galley's own benchmark
    // matrix (no procedures, no terminal AST, no error recovery); only `ast`
    // varies. The pinned flow keeps its single shared config file.
    const config_source: std.Build.LazyPath = if (local_root != null) blk: {
        const config_wf = b.addWriteFiles();
        break :blk config_wf.add("config.zig", b.fmt(
            \\pub const ast = {s};
            \\pub const procedures = false;
            \\pub const allow_no_ast_tree_procedures = false;
            \\pub const require_reduction_procedures = false;
            \\pub const error_recovery = false;
            \\pub const ast_for_terminals = false;
            \\pub const position_tracking: ?bool = null;
            \\pub const input_streaming = false;
            \\pub const indentation_syntax = false;
            \\pub const error_messages = .{{}};
            \\
        , .{if (variant.with_ast) "true" else "false"}));
    } else b.path("json/galley_config.zig");
    const generate = b.addRunArtifact(generator_tool);
    generate.addFileArg(grammar_source);
    generate.addArg(variant.parser_type);
    generate.addArg(if (variant.with_ast) "ast" else "no-ast");
    const parser_source = generate.addOutputFileArg(b.fmt(
        "_{s}-{s}-parser.zig",
        .{ variant.parser_type, if (variant.with_ast) "ast" else "no-ast" },
    ));

    const runtime_options = b.addOptions();
    runtime_options.addOption(bool, "include_tests", false);
    runtime_options.addOption(bool, "ast_memory_benchmark", false);
    const adapter_options = b.addOptions();
    adapter_options.addOption(
        []const u8,
        "create_symbol",
        b.fmt("benchmark_galley_{s}_create", .{variant.symbol_suffix}),
    );
    adapter_options.addOption(
        []const u8,
        "parse_symbol",
        b.fmt("benchmark_galley_{s}_parse", .{variant.symbol_suffix}),
    );
    adapter_options.addOption(
        []const u8,
        "destroy_symbol",
        b.fmt("benchmark_galley_{s}_destroy", .{variant.symbol_suffix}),
    );
    const procedures = b.createModule(.{
        .root_source_file = procedures_source,
        .target = target,
        .optimize = optimize,
    });
    const config = b.createModule(.{
        .root_source_file = config_source,
        .target = target,
        .optimize = optimize,
    });
    const error_messages = b.createModule(.{
        .root_source_file = error_messages_source,
        .target = target,
        .optimize = optimize,
    });
    const parser = b.createModule(.{
        .root_source_file = parser_source,
        .target = target,
        .optimize = optimize,
    });
    const runtime = b.createModule(.{
        .root_source_file = galley.path("src/runtime/api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = switch (target.result.os.tag) {
            .linux, .macos => true,
            else => null,
        },
        .imports = &.{
            .{ .name = "procedures", .module = procedures },
            .{ .name = "config", .module = config },
            .{ .name = "error_messages", .module = error_messages },
            .{ .name = "parser", .module = parser },
            .{ .name = "runtime_options", .module = runtime_options.createModule() },
        },
    });
    runtime.addImport("galley", runtime);
    procedures.addImport("galley", runtime);
    config.addImport("galley", runtime);
    error_messages.addImport("galley", runtime);
    parser.addImport("galley", runtime);

    const adapter = b.createModule(.{
        .root_source_file = b.path("json/galley_adapter.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "galley", .module = runtime },
            .{ .name = "adapter_options", .module = adapter_options.createModule() },
        },
    });
    return b.addObject(.{
        .name = variant.name,
        .root_module = adapter,
    });
}

const ExternalDataset = struct {
    name: []const u8,
    path: []const u8,
};

const external_datasets = [_]ExternalDataset{
    .{ .name = "canada", .path = "datasets/json/canada.json" },
    .{ .name = "citm_catalog", .path = "datasets/json/citm_catalog.json" },
    .{ .name = "fgo", .path = "datasets/json/fgo.json" },
    .{ .name = "github_events", .path = "datasets/json/github_events.json" },
    .{ .name = "gsoc-2018", .path = "datasets/json/gsoc-2018.json" },
    .{ .name = "lottie", .path = "datasets/json/lottie.json" },
    .{ .name = "otfcc", .path = "datasets/json/otfcc.json" },
    .{ .name = "poet", .path = "datasets/json/poet.json" },
    .{ .name = "twitter", .path = "datasets/json/twitter.json" },
    .{ .name = "twitterescaped", .path = "datasets/json/twitterescaped.json" },
};

fn externalDataset(argument: []const u8) ?ExternalDataset {
    for (external_datasets) |dataset| {
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
        "json/scripts/fetch-dataset.sh",
        dataset.name,
    });
    run_cmd.step.dependOn(&fetch_dataset.step);
    run_cmd.addArg(dataset.path);
}
