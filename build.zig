const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const optimized_c_flags = &.{ "-O3", "-DNDEBUG", "-std=c99" };

    const timing_module = b.createModule(.{
        .root_source_file = b.path("timing.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("json/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = false,
    });

    root_module.addImport("timing", timing_module);

    const exe = b.addExecutable(.{
        .name = "benchmark-json",
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
        const root = b.root.root_dir.handle;
        var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
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
        .name = "generate-galley",
        .root_module = b.createModule(.{
            .root_source_file = b.path("generate_galley.zig"),
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
        .{ .name = "galley-ll-no-ast", .symbol_suffix = "ll_no_ast", .parser_type = "ll", .with_ast = false, .repo_json_stubs = true },
        .{ .name = "galley-ll-ast", .symbol_suffix = "ll_ast", .parser_type = "ll", .with_ast = true, .repo_json_stubs = true },
        .{ .name = "galley-lr-no-ast", .symbol_suffix = "lr_no_ast", .parser_type = "lr", .with_ast = false, .repo_json_stubs = true },
        .{ .name = "galley-lr-ast", .symbol_suffix = "lr_ast", .parser_type = "lr", .with_ast = true, .repo_json_stubs = true },
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
    // This avoids depending on Zig's bundled C++ standard library.
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

    // Python benchmark: Galley LL (No AST / AST) from `languages/python`
    // plus the Ruff static library. CPython runs in a spawned `python3`
    // (see python/cpython_bench.py), so nothing links libpython here.
    const python_root_module = b.createModule(.{
        .root_source_file = b.path("python/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    python_root_module.addImport("timing", timing_module);
    const python_exe = b.addExecutable(.{
        .name = "benchmark-python",
        .root_module = python_root_module,
    });
    inline for ([_]GalleyVariant{
        .{
            .name = "python-galley-ll-no-ast",
            .symbol_suffix = "ll_no_ast",
            .parser_type = "ll",
            .with_ast = false,
            .language = "python",
            .validate_utf8 = true,
            .indentation_syntax = true,
            .newline_after_block_end = true,
        },
        .{
            .name = "python-galley-ll-ast",
            .symbol_suffix = "ll_ast",
            .parser_type = "ll",
            .with_ast = true,
            .language = "python",
            .validate_utf8 = true,
            .indentation_syntax = true,
            .newline_after_block_end = true,
            .procedures = true,
        },
    }) |variant| {
        python_root_module.addObject(
            addGalleyVariant(b, target, optimize, galley, generator_tool, variant),
        );
    }

    // Tree-sitter core plus the Python grammar and its external scanner.
    python_root_module.addIncludePath(b.path("tree-sitter/lib/include"));
    python_root_module.addIncludePath(b.path("tree-sitter/lib/src"));
    python_root_module.addCSourceFile(.{
        .file = b.path("tree-sitter/lib/src/lib.c"),
        .flags = &.{ "-O3", "-DNDEBUG", "-std=c99", "-D_GNU_SOURCE" },
    });
    python_root_module.addIncludePath(b.path("python/tree-sitter-python/src"));
    python_root_module.addCSourceFiles(.{
        .root = b.path("python/tree-sitter-python/src"),
        .files = &.{ "parser.c", "scanner.c" },
        .flags = optimized_c_flags,
    });

    // Ruff (Rust) static library, mirroring the LALRPOP wiring above.
    const ruff_cargo_build = b.addSystemCommand(&.{ "cargo", "build", "--release" });
    ruff_cargo_build.setCwd(b.path("python/ruff-bench"));
    python_exe.step.dependOn(&ruff_cargo_build.step);
    python_exe.root_module.addObjectFile(b.path("python/ruff-bench/target/release/libruff_bench.a"));
    if (target.result.os.tag == .linux) {
        python_exe.root_module.linkSystemLibrary("gcc_s", .{});
    }

    b.installArtifact(exe);
    b.installArtifact(python_exe);

    // Zig 0.17 no longer hands the arguments after `--` to build() (`b.args`
    // is gone); a run step receives them through `addPassthruArgs`. Dataset
    // selection therefore lives in the wrapper scripts: the top-level
    // dispatcher routes each argument to the JSON or Python wrapper by
    // language (dataset name or file extension), each wrapper fetches the
    // named standard datasets, and the matching benchmark runs with the
    // resolved paths. With no arguments both languages run their full
    // default sets:
    //   zig build -Doptimize=ReleaseFast run -- twitter canada
    //   zig build -Doptimize=ReleaseFast run -- pydoc datasets/python/ast.py
    const run_cmd = b.addSystemCommand(&.{ "sh", "scripts/run-benchmark.sh" });
    run_cmd.addArtifactArg(exe);
    run_cmd.addArtifactArg(python_exe);
    run_cmd.addPassthruArgs();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the JSON and Python benchmarks");
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
    /// Directory under Galley's `languages/` providing the grammar.
    language: []const u8 = "json-unicode",
    /// The historical JSON pinned flow reads this repo's stub
    /// procedures/error-messages modules instead of the language tree's;
    /// JSON local flow and every other language use the tree's own files.
    repo_json_stubs: bool = false,
    /// Check that the whole input is valid UTF-8 inside every timed parse.
    /// For grammars that leave some bytes unchecked (comments and raw
    /// strings are captured verbatim), so Galley pays for the same encoding
    /// check the rival parsers do.
    validate_utf8: bool = false,
    /// Indentation-aware lexing (Python-style significant indentation).
    indentation_syntax: bool = false,
    /// Emit a control byte after each dedent; requires indentation_syntax
    /// and must stay on for grammars whose statement lists continue across
    /// dedents (Python).
    newline_after_block_end: bool = false,
    /// Generate the parser with procedure-hook call sites and set
    /// `procedures` in the generated config (Python's AST hooks flatten
    /// lists and resolve expression structure).
    procedures: bool = false,
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
        .{ .cwd_relative = b.fmt("{s}/languages/{s}/{s}.grm", .{ root, variant.language, variant.parser_type }) }
    else
        galley.path(b.fmt(
            "languages/{s}/{s}.grm",
            .{ variant.language, variant.parser_type },
        ));
    const procedures_source: std.Build.LazyPath = if (local_root) |root|
        .{ .cwd_relative = b.fmt("{s}/languages/{s}/procedures.zig", .{ root, variant.language }) }
    else if (variant.repo_json_stubs)
        b.path("json/galley_procedures.zig")
    else
        galley.path(b.fmt("languages/{s}/procedures.zig", .{variant.language}));
    const error_messages_source: std.Build.LazyPath = if (local_root) |root|
        .{ .cwd_relative = b.fmt("{s}/languages/{s}/{s}_error_messages.zig", .{ root, variant.language, variant.parser_type }) }
    else if (variant.repo_json_stubs)
        b.path("json/galley_error_messages.zig")
    else
        galley.path(b.fmt(
            "languages/{s}/{s}_error_messages.zig",
            .{ variant.language, variant.parser_type },
        ));
    // The generated parser reads the config module at compile time, so each
    // variant needs its own config. Values mirror Galley's own benchmark
    // matrix (no terminal AST, no error recovery); only `ast`, `procedures`,
    // and the language's lexer flags vary between variants.
    const config_wf = b.addWriteFiles();
    const config_source = config_wf.add("config.zig", b.fmt(
        \\pub const ast = {s};
        \\pub const procedures = {s};
        \\pub const allow_no_ast_tree_procedures = false;
        \\pub const require_reduction_procedures = false;
        \\pub const error_recovery = false;
        \\pub const ast_for_terminals = false;
        \\pub const position_tracking: ?bool = null;
        \\pub const input_streaming = false;
        \\pub const indentation_syntax = {s};
        \\pub const newline_after_block_end = {s};
        \\pub const error_messages = .{{}};
        \\
    , .{
        if (variant.with_ast) "true" else "false",
        if (variant.procedures) "true" else "false",
        if (variant.indentation_syntax) "true" else "false",
        if (variant.newline_after_block_end) "true" else "false",
    }));
    const generate = b.addRunArtifact(generator_tool);
    generate.addFileArg(grammar_source);
    generate.addArg(variant.parser_type);
    generate.addArg(if (variant.with_ast) "ast" else "no-ast");
    generate.addArg(if (variant.procedures) "procedures" else "no-procedures");
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
    adapter_options.addOption(bool, "validate_utf8", variant.validate_utf8);
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
            .{ .name = "signals", .module = galley.module("galley_signals") },
        },
    });
    runtime.addImport("galley", runtime);
    procedures.addImport("galley", runtime);
    config.addImport("galley", runtime);
    error_messages.addImport("galley", runtime);
    parser.addImport("galley", runtime);

    const adapter = b.createModule(.{
        .root_source_file = b.path("galley_adapter.zig"),
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
