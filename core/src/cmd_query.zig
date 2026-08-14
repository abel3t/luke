const std = @import("std");
const graph = @import("graph.zig");
const storage = @import("storage.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, home_dir: []const u8, args: []const []const u8) !void {
    var store = try storage.Storage.init(allocator, io, workspace_path, home_dir);
    defer store.deinit();

    var knowledge_graph = graph.Graph.init(allocator);
    defer knowledge_graph.deinit();

    try store.loadAst(&knowledge_graph);

    if (args.len == 0) {
        std.debug.print("Query target required.\n", .{});
        return;
    }

    const command = args[0];

    if (std.mem.eql(u8, command, "tree")) {
        if (args.len < 2) return std.debug.print("Usage: luke query tree <node_id>\n", .{});
        try knowledge_graph.queryTree(args[1]);
    } else if (std.mem.eql(u8, command, "impact")) {
        if (args.len < 2) return std.debug.print("Usage: luke query impact <node_id>\n", .{});
        try knowledge_graph.queryImpact(args[1]);
    } else if (std.mem.eql(u8, command, "trace")) {
        if (args.len < 3) return std.debug.print("Usage: luke query trace <A> <B>\n", .{});
        try knowledge_graph.queryTrace(args[1], args[2]);
    } else {
        // Fallback to basic search
        try knowledge_graph.query(command);
    }
}
