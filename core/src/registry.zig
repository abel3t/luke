const std = @import("std");

pub const Entry = struct {
    path: []const u8,
    slug: []const u8,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    entries: std.ArrayList(Entry),

    pub fn load(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8) !Registry {
        var reg = Registry{
            .allocator = allocator,
            .io = io,
            .home_dir = home_dir,
            .entries = std.ArrayList(Entry).empty,
        };

        const luke_dir = try std.fmt.allocPrint(allocator, "{s}/.luke", .{home_dir});
        defer allocator.free(luke_dir);

        var dir = std.Io.Dir.openDirAbsolute(io, luke_dir, .{}) catch return reg;
        defer dir.close(io);

        const limit = @as(std.Io.Limit, @enumFromInt(1024 * 1024));
        const content = dir.readFileAlloc(io, "registry.txt", allocator, limit) catch return reg;
        defer allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \r\t");
            if (t.len == 0) continue;
            if (std.mem.indexOf(u8, t, "\t")) |tab| {
                try reg.entries.append(allocator, .{
                    .path = try allocator.dupe(u8, t[0..tab]),
                    .slug = try allocator.dupe(u8, t[tab + 1 ..]),
                });
            }
        }
        return reg;
    }

    pub fn save(self: *Registry) !void {
        const luke_dir = try std.fmt.allocPrint(self.allocator, "{s}/.luke", .{self.home_dir});
        defer self.allocator.free(luke_dir);
        _ = std.process.run(self.allocator, self.io, .{ .argv = &[_][]const u8{ "mkdir", "-p", luke_dir } }) catch {};

        const reg_path = try std.fmt.allocPrint(self.allocator, "{s}/registry.txt", .{luke_dir});
        defer self.allocator.free(reg_path);

        var file = try std.Io.Dir.createFileAbsolute(self.io, reg_path, .{});
        defer file.close(self.io);

        var buf: [8192]u8 = undefined;
        var w = file.writer(self.io, &buf);
        for (self.entries.items) |e| {
            try w.interface.print("{s}\t{s}\n", .{ e.path, e.slug });
        }
        try w.flush();
    }

    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.path);
            self.allocator.free(e.slug);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn register(self: *Registry, path: []const u8, slug: []const u8) !void {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.path, path) and std.mem.eql(u8, e.slug, slug)) return;
        }
        try self.entries.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .slug = try self.allocator.dupe(u8, slug),
        });
    }

    pub fn unregister(self: *Registry, path: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[i].path, path)) {
                self.allocator.free(self.entries.items[i].path);
                self.allocator.free(self.entries.items[i].slug);
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn unregisterAll(self: *Registry, slug: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[i].slug, slug)) {
                self.allocator.free(self.entries.items[i].path);
                self.allocator.free(self.entries.items[i].slug);
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    // Returns the workspace slug for the given path, or null if not registered.
    // Checks exact match first, then prefix match (cwd inside a registered folder).
    pub fn detect(self: *Registry, cwd: []const u8) ?[]const u8 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.path, cwd)) return e.slug;
        }
        for (self.entries.items) |e| {
            if (std.mem.startsWith(u8, cwd, e.path)) return e.slug;
        }
        return null;
    }
};
