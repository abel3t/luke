const std = @import("std");
const graph = @import("graph.zig");

pub const Storage = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    luke_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, home_dir: []const u8) !Storage {
        _ = workspace_path;
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);

        const workspaces_dir = try std.fmt.allocPrint(allocator, "{s}/.luke/workspaces", .{home_dir});
        defer allocator.free(workspaces_dir);

        var dir = std.fs.openDirAbsolute(workspaces_dir, .{ .iterate = true }) catch return error.NotARegisteredWorkspace;
        defer dir.close();

        var slug: ?[]const u8 = null;
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .directory) {
                const json_path = try std.fmt.allocPrint(allocator, "{s}/{s}/workspace.json", .{ workspaces_dir, entry.name });
                defer allocator.free(json_path);
                
                const file = std.fs.openFileAbsolute(json_path, .{}) catch continue;
                defer file.close();
                
                const content = file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
                defer allocator.free(content);
                
                if (std.mem.indexOf(u8, content, cwd) != null) {
                    slug = try allocator.dupe(u8, entry.name);
                    break;
                }
            }
        }

        if (slug == null) {
            return error.NotARegisteredWorkspace;
        }

        const luke_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspaces_dir, slug.? });
        allocator.free(slug.?);

        return .{ .allocator = allocator, .io = io, .luke_path = luke_path };
    }

    pub fn deinit(self: *Storage) void {
        self.allocator.free(self.luke_path);
    }

    pub fn saveAst(self: *Storage, knowledge_graph: *graph.Graph) !void {
        // Create longterm folder for future semantic memories
        const longterm_dir = try std.fmt.allocPrint(self.allocator, "{s}/longterm", .{self.luke_path});
        defer self.allocator.free(longterm_dir);
        _ = std.process.run(self.allocator, self.io, .{ .argv = &[_][]const u8{ "mkdir", "-p", longterm_dir } }) catch {};

        const ast_path = try std.fmt.allocPrint(self.allocator, "{s}/ast.zon", .{self.luke_path});
        defer self.allocator.free(ast_path);

        var file = try std.Io.Dir.createFileAbsolute(self.io, ast_path, .{});
        defer file.close(self.io);

        var write_buf: [4096]u8 = undefined;
        var writer = file.writer(self.io, &write_buf);
        try knowledge_graph.writeZon(&writer.interface);
        try writer.flush();

        std.debug.print("AST Knowledge Graph successfully saved to: {s}\n", .{ast_path});
    }

    pub fn loadAst(self: *Storage, knowledge_graph: *graph.Graph) !void {
        var dir = std.Io.Dir.openDirAbsolute(self.io, self.luke_path, .{}) catch {
            std.debug.print("No workspace found. Run `luke workspace init` and `luke index` first.\n", .{});
            return error.NoDatabaseFound;
        };
        defer dir.close(self.io);

        const limit = @as(std.Io.Limit, @enumFromInt(1024 * 1024 * 50)); // 50MB
        const content = dir.readFileAlloc(self.io, "ast.zon", self.allocator, limit) catch {
            std.debug.print("No database found. Run `luke init` first.\n", .{});
            return error.NoDatabaseFound;
        };
        defer self.allocator.free(content);

        try knowledge_graph.loadZon(content);
    }
};
