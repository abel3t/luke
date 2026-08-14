const std = @import("std");
const graph = @import("graph.zig");
const storage = @import("storage.zig");

/// Deterministic structural audit. Findings are static candidates, not claims of
/// runtime reachability: the current graph has symbol ranges but no reliable use
/// edges yet, so dead-code assertions would be dishonest.
pub fn run(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, home_dir: []const u8) !void {
    var store = try storage.Storage.init(allocator, io, workspace_path, home_dir);
    defer store.deinit();

    var knowledge_graph = graph.Graph.init(allocator);
    defer knowledge_graph.deinit();
    store.loadAst(&knowledge_graph) catch {
        std.debug.print("Audit failed: workspace not indexed. Run `luke index` first.\n", .{});
        return;
    };

    var stdout_buf: [8192]u8 = undefined;
    var out = std.Io.File.Writer.init(std.Io.File.stdout(), io, &stdout_buf);
    var findings: usize = 0;
    try out.interface.print("{{\n  \"audit\": \"structural\",\n  \"symbols_scanned\": {d},\n  \"findings\": [", .{knowledge_graph.nodes.items.len});

    // Very large symbols are deterministic maintainability/design-risk candidates.
    for (knowledge_graph.nodes.items) |node| {
        if (node.type == .File or node.end_line < node.start_line or node.end_line - node.start_line + 1 <= 200) continue;
        if (findings > 0) try out.interface.print(",", .{});
        try out.interface.print("\n    {{\"kind\":\"large-symbol\",\"severity\":\"info\",\"file\":", .{});
        try writeJsonString(&out.interface, node.file_path);
        try out.interface.print(",\"line\":{d},\"symbol\":", .{node.start_line});
        try writeJsonString(&out.interface, node.name);
        try out.interface.print(",\"message\":\"Symbol spans {d} lines; consider splitting responsibilities.\"}}", .{node.end_line - node.start_line + 1});
        findings += 1;
    }

    // Same symbol name in distinct files is a DRY/design candidate, never an
    // automatic duplicate-code claim.
    for (knowledge_graph.nodes.items, 0..) |node, i| {
        if (node.type == .File) continue;
        for (knowledge_graph.nodes.items[i + 1 ..]) |other| {
            if (other.type == .File or std.mem.eql(u8, node.file_path, other.file_path) or !std.mem.eql(u8, node.name, other.name)) continue;
            if (findings > 0) try out.interface.print(",", .{});
            try out.interface.print("\n    {{\"kind\":\"duplicate-symbol-name\",\"severity\":\"info\",\"file\":", .{});
            try writeJsonString(&out.interface, node.file_path);
            try out.interface.print(",\"line\":{d},\"symbol\":", .{node.start_line});
            try writeJsonString(&out.interface, node.name);
            try out.interface.print(",\"message\":\"Same symbol name also exists in ", .{});
            try writeJsonString(&out.interface, other.file_path);
            try out.interface.print("; inspect for duplicated responsibility.\"}}", .{});
            findings += 1;
        }
    }

    try out.interface.print("\n  ],\n  \"limitations\": [\"Dead-code and reachability findings require import/call edges, which are not yet available.\", \"This audit reports deterministic structural candidates; validate behavior with review/tests.\"]\n}}\n", .{});
    try out.flush();
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.print("\"", .{});
    for (value) |c| switch (c) {
        '\\' => try writer.print("\\\\", .{}),
        '"' => try writer.print("\\\"", .{}),
        '\n' => try writer.print("\\n", .{}),
        '\r' => try writer.print("\\r", .{}),
        '\t' => try writer.print("\\t", .{}),
        else => try writer.print("{c}", .{c}),
    };
    try writer.print("\"", .{});
}
