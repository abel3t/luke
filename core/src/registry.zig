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
        errdefer reg.deinit();

        const luke_dir = try std.fmt.allocPrint(allocator, "{s}/.luke", .{home_dir});
        defer allocator.free(luke_dir);

        loadJson(&reg, luke_dir) catch {};
        return reg;
    }

    pub fn save(self: *Registry) !void {
        const luke_dir = try std.fmt.allocPrint(self.allocator, "{s}/.luke", .{self.home_dir});
        defer self.allocator.free(luke_dir);
        _ = std.process.run(self.allocator, self.io, .{ .argv = &[_][]const u8{ "mkdir", "-p", luke_dir } }) catch {};

        const reg_path = try std.fmt.allocPrint(self.allocator, "{s}/registry.json", .{luke_dir});
        defer self.allocator.free(reg_path);

        var file = try std.Io.Dir.createFileAbsolute(self.io, reg_path, .{});
        defer file.close(self.io);

        var buf: [8192]u8 = undefined;
        var w = file.writer(self.io, &buf);
        try w.interface.print("{{\n  \"version\": 1,\n  \"entries\": [\n", .{});
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) try w.interface.print(",\n", .{});
            try w.interface.print("    {{ \"path\": ", .{});
            try writeJsonString(&w.interface, e.path);
            try w.interface.print(", \"slug\": ", .{});
            try writeJsonString(&w.interface, e.slug);
            try w.interface.print(" }}", .{});
        }
        try w.interface.print("\n  ]\n}}\n", .{});
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

    fn loadJson(self: *Registry, luke_dir: []const u8) !void {
        var dir = try std.Io.Dir.openDirAbsolute(self.io, luke_dir, .{});
        defer dir.close(self.io);

        const limit = @as(std.Io.Limit, @enumFromInt(1024 * 1024));
        const content = try dir.readFileAlloc(self.io, "registry.json", self.allocator, limit);
        defer self.allocator.free(content);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const entries = root.get("entries") orelse return error.InvalidRegistryJson;
        if (entries != .array) return error.InvalidRegistryJson;

        for (entries.array.items) |item| {
            if (item != .object) return error.InvalidRegistryJson;
            const path = item.object.get("path") orelse return error.InvalidRegistryJson;
            const slug = item.object.get("slug") orelse return error.InvalidRegistryJson;
            if (path != .string or slug != .string) return error.InvalidRegistryJson;
            try self.register(path.string, slug.string);
        }
    }

};

fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}
