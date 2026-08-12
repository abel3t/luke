const std = @import("std");

pub const WorkspaceWalker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ignore_list: std.ArrayList([]const u8),
    dir: std.Io.Dir,
    walker: std.Io.Dir.Walker,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, absolute_workspace_path: []const u8) !WorkspaceWalker {
        var dir = try std.Io.Dir.openDirAbsolute(io, absolute_workspace_path, .{ .iterate = true });

        var ignore_list = std.ArrayList([]const u8).empty;
        try ignore_list.append(allocator, ".git"); // Always ignore .git
        try ignore_list.append(allocator, "node_modules"); // Default failsafe
        try ignore_list.append(allocator, "zig-cache");
        try ignore_list.append(allocator, "zig-out");

        // Load .gitignore if it exists
        const limit = @as(std.Io.Limit, @enumFromInt(1024 * 1024));
        if (dir.readFileAlloc(io, ".gitignore", allocator, limit)) |content| {
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \r\t");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;
                const rule = std.mem.trimEnd(u8, trimmed, "/");
                try ignore_list.append(allocator, rule);
            }
        } else |_| {}

        const walker = try dir.walk(allocator);

        return WorkspaceWalker{
            .allocator = allocator,
            .io = io,
            .ignore_list = ignore_list,
            .dir = dir,
            .walker = walker,
        };
    }

    pub fn deinit(self: *WorkspaceWalker) void {
        self.ignore_list.deinit(self.allocator);
        self.walker.deinit();
        self.dir.close(self.io);
    }

    pub fn next(self: *WorkspaceWalker) !?std.Io.Dir.Walker.Entry {
        while (try self.walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;

            var should_skip = false;
            for (self.ignore_list.items) |rule| {
                if (std.mem.indexOf(u8, entry.path, rule) != null) {
                    should_skip = true;
                    break;
                }
            }
            
            if (!should_skip) {
                return entry;
            }
        }
        return null;
    }
};
