const std = @import("std");
const graph = @import("graph.zig");
const storage = @import("storage.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, home_dir: []const u8, target: []const u8) !void {
    var store = try storage.Storage.init(allocator, io, workspace_path, home_dir);
    defer store.deinit();

    var knowledge_graph = graph.Graph.init(allocator);
    defer knowledge_graph.deinit();

    try store.loadLongtermMemory(&knowledge_graph);
    try knowledge_graph.query(target);
}
