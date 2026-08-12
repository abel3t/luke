const std = @import("std");

pub const Folder = struct {
    name: []const u8,
    path: []const u8,
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    slug: []const u8,
    folders: std.ArrayList(Folder),

    pub fn create(allocator: std.mem.Allocator, name: []const u8) !Workspace {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .slug = try slugify(allocator, name),
            .folders = std.ArrayList(Folder).empty,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.name);
        self.allocator.free(self.slug);
        for (self.folders.items) |f| {
            self.allocator.free(f.name);
            self.allocator.free(f.path);
        }
        self.folders.deinit(self.allocator);
    }

    pub fn addFolder(self: *Workspace, name: []const u8, path: []const u8) !void {
        try self.folders.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .path = try self.allocator.dupe(u8, path),
        });
    }

    pub fn removeFolder(self: *Workspace, path: []const u8) void {
        var i: usize = 0;
        while (i < self.folders.items.len) {
            if (std.mem.eql(u8, self.folders.items[i].path, path)) {
                self.allocator.free(self.folders.items[i].name);
                self.allocator.free(self.folders.items[i].path);
                _ = self.folders.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn save(self: *Workspace, io: std.Io, dir_path: []const u8) !void {
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/workspace.json", .{dir_path});
        defer self.allocator.free(file_path);

        var file = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.print("{{\n  \"version\": 1,\n  \"name\": ", .{});
        try writeJsonString(&w.interface, self.name);
        try w.interface.print(",\n  \"slug\": ", .{});
        try writeJsonString(&w.interface, self.slug);
        try w.interface.print(",\n  \"folders\": [\n", .{});
        for (self.folders.items, 0..) |f, i| {
            if (i > 0) try w.interface.print(",\n", .{});
            try w.interface.print("    {{ \"name\": ", .{});
            try writeJsonString(&w.interface, f.name);
            try w.interface.print(", \"path\": ", .{});
            try writeJsonString(&w.interface, f.path);
            try w.interface.print(" }}", .{});
        }
        try w.interface.print("\n  ]\n}}\n", .{});
        try w.flush();
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !Workspace {
        var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
        defer dir.close(io);

        const limit = @as(std.Io.Limit, @enumFromInt(1024 * 64));
        const content = try dir.readFileAlloc(io, "workspace.json", allocator, limit);
        defer allocator.free(content);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const name = root.get("name") orelse return error.InvalidWorkspaceJson;
        const slug = root.get("slug") orelse return error.InvalidWorkspaceJson;
        if (name != .string or slug != .string) return error.InvalidWorkspaceJson;

        var ws = Workspace{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name.string),
            .slug = try allocator.dupe(u8, slug.string),
            .folders = std.ArrayList(Folder).empty,
        };
        errdefer ws.deinit();

        if (root.get("folders")) |folders| {
            if (folders != .array) return error.InvalidWorkspaceJson;
            for (folders.array.items) |item| {
                if (item != .object) return error.InvalidWorkspaceJson;
                const folder_name = item.object.get("name") orelse return error.InvalidWorkspaceJson;
                const folder_path = item.object.get("path") orelse return error.InvalidWorkspaceJson;
                if (folder_name != .string or folder_path != .string) return error.InvalidWorkspaceJson;
                try ws.addFolder(folder_name.string, folder_path.string);
            }
        }

        return ws;
    }
};

pub fn slugify(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const slug = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        slug[i] = if (c == ' ' or c == '_') '-' else std.ascii.toLower(c);
    }
    return slug;
}

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
