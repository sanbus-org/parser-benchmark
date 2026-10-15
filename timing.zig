//! Timing protocol shared by the JSON and Python benchmark drivers, so both
//! measure every parser the same way.
const std = @import("std");

/// Warmup iterations run untimed before each measurement.
pub const warmup_runs: usize = 2;
/// Timed iterations per parser; the best (shortest) one is reported.
pub const measure_runs: usize = 5;

/// Whether a parse outcome is a success: `true`, or a non-null handle.
fn succeeded(outcome: anytype) bool {
    return switch (@typeInfo(@TypeOf(outcome))) {
        .bool => outcome,
        .optional => outcome != null,
        else => @compileError("a parse outcome is a bool or an optional handle"),
    };
}

/// Release for parsers whose outcome owns nothing.
pub fn keepOutcome(_: bool) void {}

/// Run `parse(args)` untimed `warmup_runs` times, then timed `measure_runs`
/// times, returning the best (shortest) elapsed time in nanoseconds.
/// Best-of-N suppresses scheduling and frequency noise; warmup settles
/// caches, branch predictors, and page faults before timing starts.
/// The outcome of every parse, timed or not, is passed to `release` after
/// the clock stops, so a tree returned as a handle is torn down outside the
/// timing and the timing covers building it.
pub fn timeBestNs(init: std.process.Init, parse: anytype, release: anytype, args: anytype) error{ParseFailed}!i96 {
    var i: usize = 0;
    while (i < warmup_runs) : (i += 1) {
        const outcome = @call(.auto, parse, args);
        if (!succeeded(outcome)) return error.ParseFailed;
        release(outcome);
    }
    var best: i96 = std.math.maxInt(i96);
    i = 0;
    while (i < measure_runs) : (i += 1) {
        const start = std.Io.Clock.awake.now(init.io);
        const outcome = @call(.auto, parse, args);
        const end = std.Io.Clock.awake.now(init.io);
        if (!succeeded(outcome)) return error.ParseFailed;
        release(outcome);
        const elapsed_ns = start.durationTo(end).toNanoseconds();
        if (elapsed_ns < best) best = elapsed_ns;
    }
    return best;
}
