const std = @import("std");
const graph = @import("graph.zig");
const walker_mod = @import("walker.zig");
const storage = @import("storage.zig");
const engine = @import("engine.zig");
const workspace_mod = @import("workspace.zig");
const registry = @import("registry.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, home_dir: []const u8) !void {
    var stderr_buf: [256]u8 = undefined;
    var err = std.Io.File.Writer.init(std.Io.File.stderr(), io, &stderr_buf);

    // Try to detect workspace from CWD via registry
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    var reg = try registry.Registry.load(allocator, io, home_dir);
    defer reg.deinit();

    if (reg.detect(cwd)) |slug| {
        // Workspace mode: load all folders from workspace definition
        const ws_dir = try std.fmt.allocPrint(allocator, "{s}/.luke/workspaces/{s}", .{ home_dir, slug });
        defer allocator.free(ws_dir);

        var ws = workspace_mod.Workspace.load(allocator, io, ws_dir) catch {
            try err.interface.print("Could not load workspace '{s}'. Falling back to single-folder mode.\n", .{slug});
            try err.flush();
            try runSingleFolder(allocator, io, workspace_path, home_dir);
            return;
        };
        defer ws.deinit();

        try err.interface.print("Workspace: {s} ({d} folders)\n", .{ ws.name, ws.folders.items.len });
        try err.flush();

        var store = try storage.Storage.initWithSlug(allocator, io, home_dir, slug);
        defer store.deinit();

        var knowledge_graph = graph.Graph.init(allocator);
        defer knowledge_graph.deinit();

        var ast_engine = try engine.AstEngine.init(allocator, io);
        defer ast_engine.deinit();

        var total_files: u32 = 0;

        for (ws.folders.items) |folder| {
            try err.interface.print("Scanning: {s} ({s})...\n", .{ folder.name, folder.path });
            try err.flush();

            var ws_walker = walker_mod.WorkspaceWalker.init(allocator, io, folder.path) catch continue;
            defer ws_walker.deinit();

            while (try ws_walker.next()) |entry| {
                if (std.mem.endsWith(u8, entry.basename, ".ts") or
                    std.mem.endsWith(u8, entry.basename, ".tsx") or
                    std.mem.endsWith(u8, entry.basename, ".go"))
                {
                    try ast_engine.extractKnowledge(folder.path, entry.path, entry.basename, &knowledge_graph);
                    total_files += 1;
                }
            }
        }

        try err.interface.print("\nDone! Parsed {d} files across {d} repos. Saving...\n", .{ total_files, ws.folders.items.len });
        try err.flush();
        try store.saveLongTermMemory(&knowledge_graph);
    } else {
        // Single-folder mode
        try runSingleFolder(allocator, io, workspace_path, home_dir);
    }
}

fn runSingleFolder(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, home_dir: []const u8) !void {
    var stderr_buf: [512]u8 = undefined;
    var err = std.Io.File.Writer.init(std.Io.File.stderr(), io, &stderr_buf);

    std.debug.print("Luke Engine: Scanning Workspace: {s}...\n\n", .{workspace_path});

    var ast_engine = try engine.AstEngine.init(allocator, io);
    defer ast_engine.deinit();

    var knowledge_graph = graph.Graph.init(allocator);
    defer knowledge_graph.deinit();

    var store = try storage.Storage.init(allocator, io, workspace_path, home_dir);
    defer store.deinit();

    const absolute_workspace_path = if (std.fs.path.isAbsolute(workspace_path))
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

    var check_dir = std.Io.Dir.openDirAbsolute(io, absolute_workspace_path, .{}) catch {
        try err.interface.print(
            "Luke init failed: workspace path not found: {s}\n\nTry from a repo root with:\n  luke init .\n\nOr pass an absolute path:\n  luke init /path/to/repo\n",
            .{absolute_workspace_path},
        );
        try err.flush();
        return;
    };
    check_dir.close(io);

    var ws_walker = try walker_mod.WorkspaceWalker.init(allocator, io, absolute_workspace_path);
    defer ws_walker.deinit();

    var ts_files_found: u32 = 0;
    while (try ws_walker.next()) |entry| {
        if (std.mem.endsWith(u8, entry.basename, ".ts") or
            std.mem.endsWith(u8, entry.basename, ".tsx") or
            std.mem.endsWith(u8, entry.basename, ".go"))
        {
            try ast_engine.extractKnowledge(absolute_workspace_path, entry.path, entry.basename, &knowledge_graph);
            ts_files_found += 1;
        }
    }

    std.debug.print("\nDone! Successfully parsed {d} files. Saving database...\n", .{ts_files_found});
    try store.saveLongTermMemory(&knowledge_graph);
}
