const std = @import("std");
const graph = @import("graph.zig");

pub const Storage = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    luke_path: []const u8,

    /// Use this when you know the workspace slug (workspace mode).
    pub fn initWithSlug(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, slug: []const u8) !Storage {
        const luke_path = try std.fmt.allocPrint(allocator, "{s}/.luke/workspaces/{s}", .{ home_dir, slug });
        _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "mkdir", "-p", luke_path } }) catch {};
        return .{ .allocator = allocator, .io = io, .luke_path = luke_path };
    }

    /// Fallback: single-folder mode — derives slug from workspace basename.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, home_dir: []const u8) !Storage {
        const is_absolute = std.fs.path.isAbsolute(workspace_path);
        const absolute_workspace_path = if (is_absolute)
            try allocator.dupe(u8, workspace_path)
        else blk: {
            const cwd = try std.process.currentPathAlloc(io, allocator);
            defer allocator.free(cwd);
            break :blk try std.fs.path.join(allocator, &[_][]const u8{ cwd, workspace_path });
        };
        defer allocator.free(absolute_workspace_path);

        const workspace_name = std.fs.path.basename(absolute_workspace_path);
        return initWithSlug(allocator, io, home_dir, workspace_name);
    }

    pub fn deinit(self: *Storage) void {
        self.allocator.free(self.luke_path);
    }

    pub fn saveLongTermMemory(self: *Storage, knowledge_graph: *graph.Graph) !void {
        const longterm_path = try std.fmt.allocPrint(self.allocator, "{s}/longterm.zon", .{self.luke_path});
        defer self.allocator.free(longterm_path);

        var file = try std.Io.Dir.createFileAbsolute(self.io, longterm_path, .{});
        defer file.close(self.io);

        var write_buf: [4096]u8 = undefined;
        var writer = file.writer(self.io, &write_buf);
        try knowledge_graph.writeZon(&writer.interface);
        try writer.flush();

        std.debug.print("Long-term memory successfully saved to: {s}\n", .{longterm_path});
    }

    pub fn loadLongtermMemory(self: *Storage, knowledge_graph: *graph.Graph) !void {
        var dir = std.Io.Dir.openDirAbsolute(self.io, self.luke_path, .{}) catch {
            std.debug.print("No knowledge graph found. Run `luke init` first.\n", .{});
            return error.NoDatabaseFound;
        };
        defer dir.close(self.io);

        const limit = @as(std.Io.Limit, @enumFromInt(1024 * 1024 * 50)); // 50MB
        const content = dir.readFileAlloc(self.io, "longterm.zon", self.allocator, limit) catch {
            std.debug.print("No database found. Run `luke init` first.\n", .{});
            return error.NoDatabaseFound;
        };
        defer self.allocator.free(content);

        try knowledge_graph.loadZon(content);
    }
};
