//! Head-to-head Python parsing benchmark: Galley LL (No AST / AST),
//! Tree-sitter (CST), Ruff (AST), and CPython (ast.parse / compile).
//! Same 2-warmup + best-of-5 methodology and `[Name - Mode]` result
//! format as `json/main.zig`; CPython runs in a spawned interpreter and
//! times itself in-process (see `cpython_bench.py`).
const std = @import("std");
const timing = @import("timing");

const timeBestNs = timing.timeBestNs;
const keepOutcome = timing.keepOutcome;

extern fn benchmark_galley_ll_no_ast_create() ?*anyopaque;
extern fn benchmark_galley_ll_no_ast_parse(context: ?*anyopaque, ptr: [*]const u8, len: usize) bool;
extern fn benchmark_galley_ll_no_ast_destroy(context: ?*anyopaque) void;
extern fn benchmark_galley_ll_ast_create() ?*anyopaque;
extern fn benchmark_galley_ll_ast_parse(context: ?*anyopaque, ptr: [*]const u8, len: usize) bool;
extern fn benchmark_galley_ll_ast_destroy(context: ?*anyopaque) void;

/// Hand-written C ABI bindings for the slice of the Tree-sitter API this
/// harness uses (Zig 0.17 removed `@cImport`); signatures from
/// `tree_sitter/api.h`, as in `json/main.zig`.
const ts = struct {
    const TSLanguage = opaque {};
    const TSParser = opaque {};
    const TSTree = opaque {};
    const TSNode = extern struct {
        context: [4]u32,
        id: ?*const anyopaque,
        tree: ?*const TSTree,
    };

    extern "c" fn ts_parser_new() ?*TSParser;
    extern "c" fn ts_parser_delete(self: ?*TSParser) void;
    extern "c" fn ts_parser_set_language(self: ?*TSParser, language: ?*const TSLanguage) bool;
    extern "c" fn ts_parser_parse_string(
        self: ?*TSParser,
        old_tree: ?*const TSTree,
        string: [*]const u8,
        length: u32,
    ) ?*TSTree;
    extern "c" fn ts_tree_delete(self: ?*TSTree) void;
    extern "c" fn ts_tree_root_node(self: ?*const TSTree) TSNode;
    extern "c" fn ts_node_end_byte(self: TSNode) u32;
    extern "c" fn ts_node_has_error(self: TSNode) bool;

    extern "c" fn tree_sitter_python() *const TSLanguage;
};

/// One Tree-sitter parse on a long-lived parser. The tree is returned for
/// the caller to delete after the clock stops; null when the input has
/// errors or is not fully consumed.
fn treeSitterParse(parser: *ts.TSParser, source: []const u8) ?*ts.TSTree {
    const tree = ts.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse return null;
    const root = ts.ts_tree_root_node(tree);
    if (ts.ts_node_has_error(root) or ts.ts_node_end_byte(root) != source.len) {
        ts.ts_tree_delete(tree);
        return null;
    }
    return tree;
}

extern fn benchmark_ruff_parse_module(ptr: [*]const u8, len: usize) ?*anyopaque;
extern fn benchmark_ruff_free(handle: ?*anyopaque) void;

const Result = struct {
    name: []const u8,
    mode: []const u8,
    mbps: f64,
    duration_ns: i96,
    parsed_bytes: usize,
};

/// Minimum bytes per timed parse. The input is concatenated with itself
/// enough times to reach at least this size (a 10 KB corpus file repeats
/// ~400x into ~4 MB, a 2 MB file repeats 2x), so every parse lasts long
/// enough for best-of-5 to be stable while large files stay unpadded.
/// Keep in sync with the driver contract in python/cpython_bench.py
/// (the count is passed on the command line there).
const min_parse_bytes: usize = 4 * 1024 * 1024;

fn benchmarkGalley(
    comptime create: fn () callconv(.c) ?*anyopaque,
    comptime parse: fn (?*anyopaque, [*]const u8, usize) callconv(.c) bool,
    comptime destroy: fn (?*anyopaque) callconv(.c) void,
    init: std.process.Init,
    file_content: []const u8,
    mode: []const u8,
) !Result {
    const session = create() orelse return error.GalleySessionInitFailed;
    defer destroy(session);

    const elapsed_ns = timeBestNs(init, parse, keepOutcome, .{ session, file_content.ptr, file_content.len }) catch
        return error.GalleyParseFailed;
    const duration_secs = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    return .{
        .name = "Galley (Zig)",
        .mode = mode,
        .mbps = @as(f64, @floatFromInt(file_content.len)) / (1024 * 1024) / duration_secs,
        .duration_ns = elapsed_ns,
        .parsed_bytes = file_content.len,
    };
}

/// Run one CPython mode in a spawned interpreter. `cpython_bench.py`
/// repeats the input `repeats` times (the count is passed in, keeping the
/// effective input identical to the in-process adapters), runs the same
/// 2 warmup + best-of-5 protocol in-process (so interpreter startup stays
/// outside the measurement), and prints seconds per parse; a compile failure exits
/// nonzero and surfaces as a parse error here.
fn benchmarkCPython(init: std.process.Init, file_path: []const u8, mode: []const u8, repeats: usize) !Result {
    var repeat_buf: [20]u8 = undefined;
    const repeat_str = try std.fmt.bufPrint(&repeat_buf, "{d}", .{repeats});
    const result = try std.process.run(init.gpa, init.io, .{
        .argv = &.{ "python3", "python/cpython_bench.py", file_path, mode, repeat_str },
    });
    defer init.gpa.free(result.stdout);
    defer init.gpa.free(result.stderr);
    if (!result.term.success()) return error.CPythonParseFailed;

    // The last non-empty stdout line is the float; anything before it
    // (site hooks, warnings) is ignored.
    var seconds: ?f64 = null;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        seconds = std.fmt.parseFloat(f64, trimmed) catch continue;
    }
    const secs_per_parse = seconds orelse return error.CPythonMeasurementFailed;

    // cpython_bench.py parses the file repeated `repeats` times, so the
    // throughput denominator matches the other adapters' repeated input.
    const bytes = (try fileLen(init, file_path)) * repeats;
    return .{
        .name = "CPython (Python)",
        .mode = if (std.mem.eql(u8, mode, "ast")) "AST" else "AST + codegen",
        .mbps = @as(f64, @floatFromInt(bytes)) / (1024 * 1024) / secs_per_parse,
        .duration_ns = @intFromFloat(secs_per_parse * 1e9),
        .parsed_bytes = bytes,
    };
}

fn fileLen(init: std.process.Init, file_path: []const u8) !usize {
    const stat = try std.Io.Dir.cwd().statFile(init.io, file_path, .{});
    return @intCast(stat.size);
}

const general_parser_color = "\x1b[36m";
const galley_color = "\x1b[1;35m";
const reset_color = "\x1b[0m";

fn resultColor(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "Galley (Zig)")) return galley_color;
    return general_parser_color;
}

fn astMarker(mode: []const u8) []const u8 {
    if (std.mem.indexOf(u8, mode, "AST") != null and
        std.mem.indexOf(u8, mode, "No AST") == null)
    {
        return "🌳";
    }
    return "  ";
}

fn writeResultsToFile(
    io: @TypeOf(@as(std.process.Init, undefined).io),
    input_path: []const u8,
    repeats: usize,
    results: []const Result,
) !void {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "benchmark_results/python");

    const filename = std.fs.path.basename(input_path);

    var buf: [512]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&buf, "benchmark_results/python/{s}.txt", .{filename});

    const file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &write_buffer);
    const writer = &file_writer.interface;

    try writer.print("Language: python\n", .{});
    try writer.print("Input: {s} (repeated {d}x per parse)\n", .{ input_path, repeats });
    try writer.print("----------------------------------------\n", .{});

    for (results) |r| {
        try writer.print("[{s} - {s}]\n", .{ r.name, r.mode });
        try writer.print("Parsed bytes: {d:.2} MB\n", .{@as(f64, @floatFromInt(r.parsed_bytes)) / (1024 * 1024)});
        try writer.print("Duration: {d} ns\n", .{r.duration_ns});
        try writer.print("Throughput: {d:.2} MB/s\n", .{r.mbps});
        try writer.print("Nodes allocated: 0\n\n", .{});
    }
    try file_writer.flush();
}

fn benchmarkFile(init: std.process.Init, file_path: []const u8) !void {
    const file_content = try std.Io.Dir.cwd().readFileAlloc(init.io, file_path, init.gpa, .unlimited);
    defer init.gpa.free(file_content);

    // Every timed parse consumes the input repeated enough times to reach
    // min_parse_bytes, so the measured run lasts long enough for stable
    // best-of-5 timings. CPython repeats identically (the count is passed
    // to cpython_bench.py), so all six adapters see the same effective
    // input.
    const repeats = if (file_content.len == 0) 1 else (min_parse_bytes + file_content.len - 1) / file_content.len;
    const input = try init.gpa.alloc(u8, file_content.len * repeats);
    defer init.gpa.free(input);
    for (0..repeats) |i| {
        @memcpy(input[i * file_content.len ..][0..file_content.len], file_content);
    }

    var results: [6]Result = undefined;
    var result_count: usize = 0;

    // 1. Galley LL (No AST mode)
    results[result_count] = try benchmarkGalley(
        benchmark_galley_ll_no_ast_create,
        benchmark_galley_ll_no_ast_parse,
        benchmark_galley_ll_no_ast_destroy,
        init,
        input,
        "LL No AST",
    );
    result_count += 1;

    // 2. Galley LL (AST mode)
    results[result_count] = try benchmarkGalley(
        benchmark_galley_ll_ast_create,
        benchmark_galley_ll_ast_parse,
        benchmark_galley_ll_ast_destroy,
        init,
        input,
        "LL AST",
    );
    result_count += 1;

    // 3. Tree-sitter (CST mode). The parser lives across parses, like the
    // Galley session, and each tree is deleted after the clock stops.
    {
        const parser = ts.ts_parser_new() orelse return error.TreeSitterInitFailed;
        defer ts.ts_parser_delete(parser);
        if (!ts.ts_parser_set_language(parser, ts.tree_sitter_python())) return error.TreeSitterInitFailed;
        const elapsed_ns = timeBestNs(init, treeSitterParse, ts.ts_tree_delete, .{ parser, input }) catch
            return error.TreeSitterParseFailed;
        const duration_secs = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
        results[result_count] = .{
            .name = "Tree-sitter (C)",
            .mode = "CST",
            .mbps = @as(f64, @floatFromInt(input.len)) / (1024 * 1024) / duration_secs,
            .duration_ns = elapsed_ns,
            .parsed_bytes = input.len,
        };
        result_count += 1;
    }

    // 4. Ruff full parse (AST mode).
    {
        const elapsed_ns = timeBestNs(init, benchmark_ruff_parse_module, benchmark_ruff_free, .{ input.ptr, input.len }) catch
            return error.RuffParseFailed;
        const duration_secs = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
        results[result_count] = .{
            .name = "Ruff (Rust)",
            .mode = "AST",
            .mbps = @as(f64, @floatFromInt(input.len)) / (1024 * 1024) / duration_secs,
            .duration_ns = elapsed_ns,
            .parsed_bytes = input.len,
        };
        result_count += 1;
    }

    // 5. CPython ast.parse (AST mode)
    results[result_count] = try benchmarkCPython(init, file_path, "ast", repeats);
    result_count += 1;

    // 6. CPython compile (AST + codegen mode)
    results[result_count] = try benchmarkCPython(init, file_path, "compile", repeats);
    result_count += 1;

    const completed_results = results[0..result_count];
    std.sort.insertion(Result, completed_results, {}, struct {
        fn fasterThan(_: void, lhs: Result, rhs: Result) bool {
            return lhs.mbps > rhs.mbps;
        }
    }.fasterThan);

    // Print the final table in descending throughput order.
    std.debug.print("\nDataset: {s}\n", .{file_path});
    std.debug.print("Input: repeated {d}x per parse ({d:.2} MB)\n", .{ repeats, @as(f64, @floatFromInt(input.len)) / (1024 * 1024) });
    std.debug.print("Timing: {d} warmup + best of {d} runs\n", .{ timing.warmup_runs, timing.measure_runs });
    std.debug.print(
        "Legend: {s}general-purpose{s}  {s}Galley{s}  🌳 AST\n",
        .{ general_parser_color, reset_color, galley_color, reset_color },
    );
    std.debug.print("+------------------------------------+------------------+-----------------+\n", .{});
    std.debug.print("| Parser Benchmark                   | Mode             | Throughput      |\n", .{});
    std.debug.print("+------------------------------------+------------------+-----------------+\n", .{});
    for (completed_results) |r| {
        std.debug.print(
            "| {s} {s}{s} {s: <30}{s}| {s: <16} | {d: >10.2} MB/s |\n",
            .{
                " ",
                astMarker(r.mode),
                resultColor(r.name),
                r.name,
                reset_color,
                r.mode,
                r.mbps,
            },
        );
    }
    std.debug.print("+------------------------------------+------------------+-----------------+\n\n", .{});

    // Write machine-readable output to file
    writeResultsToFile(init.io, file_path, repeats, completed_results) catch |err| {
        std.debug.print("Failed to write results to file: {}\n", .{err});
    };
}

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    if (args.len > 1) {
        for (args[1..]) |arg| {
            try benchmarkFile(init, std.mem.span(arg));
        }
        return;
    }

    const default_datasets = [_][]const u8{
        "datasets/python/asyncio-queues.py",
        "datasets/python/base-tasks.py",
        "datasets/python/graphlib.py",
        "datasets/python/numpy-globals.py",
        "datasets/python/opcode-metadata.py",
        "datasets/python/warnings.py",
        "datasets/python/weakrefset.py",
    };
    for (default_datasets) |file_path| {
        try benchmarkFile(init, file_path);
    }
}
