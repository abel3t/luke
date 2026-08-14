const std = @import("std");
const graph = @import("graph.zig");

pub const Storage = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    luke_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, home_dir: []const u8) !Storage {
        _ = home_dir; // not used anymore, storage is strictly local
        const is_absolute = std.fs.path.isAbsolute(workspace_path);
        const absolute_workspace_path = if (is_absolute)
            try allocator.dupe(u8, workspace_path)
        else blk: {
            const cwd = try std.process.currentPathAlloc(io, allocator);
            defer allocator.free(cwd);
            if (std.mem.eql(u8, workspace_path, ".")) {
                break :blk try allocator.dupe(u8, cwd);
            }
            break :blk try std.fs.path.join(allocator, &[_][]const u8{ cwd, workspace_path });
        };
        defer allocator.free(absolute_workspace_path);

        const luke_path = try std.fmt.allocPrint(allocator, "{s}/.luke", .{absolute_workspace_path});
        
        // Ensure .luke exists. If not, this is not a registered workspace.
        var check_dir = std.Io.Dir.openDirAbsolute(io, luke_path, .{}) catch {
            return error.NotARegisteredWorkspace;
        };
        check_dir.close(io);

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
