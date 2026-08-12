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
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/workspace.txt", .{dir_path});
        defer self.allocator.free(file_path);

        var file = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.print("name={s}\n", .{self.name});
        for (self.folders.items) |f| {
            try w.interface.print("folder={s}|{s}\n", .{ f.name, f.path });
        }
        try w.flush();
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !Workspace {
        var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
        defer dir.close(io);

        const limit = @as(std.Io.Limit, @enumFromInt(1024 * 64));
        const content = try dir.readFileAlloc(io, "workspace.txt", allocator, limit);
        defer allocator.free(content);

        var ws = Workspace{
            .allocator = allocator,
            .name = try allocator.dupe(u8, ""),
            .slug = try allocator.dupe(u8, ""),
            .folders = std.ArrayList(Folder).empty,
        };

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \r\t");
            if (t.len == 0) continue;
            if (std.mem.startsWith(u8, t, "name=")) {
                allocator.free(ws.name);
                allocator.free(ws.slug);
                ws.name = try allocator.dupe(u8, t[5..]);
                ws.slug = try slugify(allocator, ws.name);
            } else if (std.mem.startsWith(u8, t, "folder=")) {
                const rest = t[7..];
                if (std.mem.indexOf(u8, rest, "|")) |sep| {
                    try ws.folders.append(allocator, .{
                        .name = try allocator.dupe(u8, rest[0..sep]),
                        .path = try allocator.dupe(u8, rest[sep + 1 ..]),
                    });
                }
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
