const std = @import("std");
const generator = @import("galley_generator");

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    if (args.len != 5) return error.InvalidArguments;

    const grammar_path = std.mem.span(args[1]);
    const parser_type = generator.ParserType.parse(std.mem.span(args[2])) orelse
        return error.InvalidParserType;
    const with_ast = if (std.mem.eql(u8, std.mem.span(args[3]), "ast"))
        true
    else if (std.mem.eql(u8, std.mem.span(args[3]), "no-ast"))
        false
    else
        return error.InvalidAstMode;
    const output_path = std.mem.span(args[4]);
    const grammar = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        grammar_path,
        init.gpa,
        .limited(1024 * 1024),
    );
    defer init.gpa.free(grammar);

    const parser_source = try generator.generateParserAlloc(
        init.arena.allocator(),
        grammar,
        parser_type,
        .{
            .with_ast = with_ast,
            .with_procedures = false,
            .with_error_recovery = false,
            .with_position_tracking = false,
            .with_input_streaming = false,
        },
    );
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = output_path,
        .data = parser_source,
    });
}
