const std = @import("std");
const workspace = @import("workspace.zig");
const registry = @import("registry.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, args: []const [:0]const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var out = std.Io.File.Writer.init(std.Io.File.stdout(), io, &stdout_buf);
    var err = std.Io.File.Writer.init(std.Io.File.stderr(), io, &stderr_buf);

    if (args.len < 3) {
        try printUsage(&out);
        return;
    }

    const subcmd = args[2];

    if (std.mem.eql(u8, subcmd, "create")) {
        try cmdCreate(allocator, io, home_dir, args, &out, &err);
    } else if (std.mem.eql(u8, subcmd, "add")) {
        try cmdAdd(allocator, io, home_dir, args, &out, &err);
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        try cmdRemove(allocator, io, home_dir, args, &out, &err);
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        try cmdDelete(allocator, io, home_dir, args, &out, &err);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try cmdList(allocator, io, home_dir, &out, &err);
    } else {
        try err.interface.print("Unknown subcommand: {s}\n", .{subcmd});
        try err.flush();
        try printUsage(&out);
    }
}

fn printUsage(out: *std.Io.File.Writer) !void {
    try out.interface.print(
        \\Luke Workspace Manager
        \\Usage: luke workspace <subcommand>
        \\
        \\Subcommands:
        \\  create <name>                  Create a new workspace
        \\  add <slug> [path] [folder-name] Register a folder into a workspace
        \\  remove <slug> [path]           Unregister a folder from a workspace
        \\  delete <slug>                  Delete a workspace and its index
        \\  list                           List all workspaces and their folders
        \\
        \\Examples:
        \\  luke workspace create "Hako Dropship"
        \\  luke workspace add hako-dropship . backend
        \\  luke workspace add hako-dropship /path/to/fe frontend
        \\  luke workspace list
        \\  luke workspace delete hako-dropship
        \\
    , .{});
    try out.flush();
}

fn workspaceDir(allocator: std.mem.Allocator, home_dir: []const u8, slug: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/.luke/workspaces/{s}", .{ home_dir, slug });
}

fn cmdCreate(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, args: []const [:0]const u8, out: *std.Io.File.Writer, err: *std.Io.File.Writer) !void {
    if (args.len < 4) {
        try err.interface.print("Usage: luke workspace create <name>\n", .{});
        try err.flush();
        return;
    }
    const name = args[3];
    var ws = try workspace.Workspace.create(allocator, name);
    defer ws.deinit();

    const ws_dir = try workspaceDir(allocator, home_dir, ws.slug);
    defer allocator.free(ws_dir);

    _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "mkdir", "-p", ws_dir } }) catch {};
    try ws.save(io, ws_dir);

    try out.interface.print("✓ Workspace '{s}' created. (slug: {s})\n", .{ name, ws.slug });
    try out.interface.print("  Now add folders: luke workspace add {s} <path> <name>\n", .{ws.slug});
    try out.flush();
}

fn cmdAdd(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, args: []const [:0]const u8, out: *std.Io.File.Writer, err: *std.Io.File.Writer) !void {
    if (args.len < 4) {
        try err.interface.print("Usage: luke workspace add <slug> [path] [folder-name]\n", .{});
        try err.flush();
        return;
    }

    const slug = args[3];
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const folder_path_raw = if (args.len >= 5) @as([]const u8, args[4]) else cwd;
    const folder_path = if (std.fs.path.isAbsolute(folder_path_raw))
        try allocator.dupe(u8, folder_path_raw)
    else
        try std.fs.path.join(allocator, &[_][]const u8{ cwd, folder_path_raw });
    defer allocator.free(folder_path);

    const folder_name = if (args.len >= 6)
        @as([]const u8, args[5])
    else
        std.fs.path.basename(folder_path);

    // Load or load workspace
    const ws_dir = try workspaceDir(allocator, home_dir, slug);
    defer allocator.free(ws_dir);

    var ws = workspace.Workspace.load(allocator, io, ws_dir) catch |e| {
        try err.interface.print("Workspace '{s}' not found. Create it first: luke workspace create\nError: {any}\n", .{ slug, e });
        try err.flush();
        return;
    };
    defer ws.deinit();

    try ws.addFolder(folder_name, folder_path);
    try ws.save(io, ws_dir);

    // Update registry
    var reg = try registry.Registry.load(allocator, io, home_dir);
    defer reg.deinit();
    try reg.register(folder_path, slug);
    try reg.save();

    try out.interface.print("✓ Added '{s}' ({s}) to workspace '{s}'\n", .{ folder_name, folder_path, slug });
    try out.flush();
}

fn cmdRemove(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, args: []const [:0]const u8, out: *std.Io.File.Writer, err: *std.Io.File.Writer) !void {
    if (args.len < 4) {
        try err.interface.print("Usage: luke workspace remove <slug> [path]\n", .{});
        try err.flush();
        return;
    }

    const slug = args[3];
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const folder_path_raw = if (args.len >= 5) @as([]const u8, args[4]) else cwd;
    const folder_path = if (std.fs.path.isAbsolute(folder_path_raw))
        try allocator.dupe(u8, folder_path_raw)
    else
        try std.fs.path.join(allocator, &[_][]const u8{ cwd, folder_path_raw });
    defer allocator.free(folder_path);

    const ws_dir = try workspaceDir(allocator, home_dir, slug);
    defer allocator.free(ws_dir);

    var ws = workspace.Workspace.load(allocator, io, ws_dir) catch {
        try err.interface.print("Workspace '{s}' not found.\n", .{slug});
        try err.flush();
        return;
    };
    defer ws.deinit();

    ws.removeFolder(folder_path);
    try ws.save(io, ws_dir);

    var reg = try registry.Registry.load(allocator, io, home_dir);
    defer reg.deinit();
    reg.unregister(folder_path);
    try reg.save();

    try out.interface.print("✓ Removed '{s}' from workspace '{s}'\n", .{ folder_path, slug });
    try out.flush();
}

fn cmdDelete(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, args: []const [:0]const u8, out: *std.Io.File.Writer, err: *std.Io.File.Writer) !void {
    if (args.len < 4) {
        try err.interface.print("Usage: luke workspace delete <slug>\n", .{});
        try err.flush();
        return;
    }

    const slug = args[3];
    const ws_dir = try workspaceDir(allocator, home_dir, slug);
    defer allocator.free(ws_dir);

    _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "rm", "-rf", ws_dir } }) catch {};

    var reg = try registry.Registry.load(allocator, io, home_dir);
    defer reg.deinit();
    reg.unregisterAll(slug);
    try reg.save();

    try out.interface.print("✓ Deleted workspace '{s}' and its index.\n", .{slug});
    try out.flush();
}

fn cmdList(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, out: *std.Io.File.Writer, err: *std.Io.File.Writer) !void {
    const workspaces_dir = try std.fmt.allocPrint(allocator, "{s}/.luke/workspaces", .{home_dir});
    defer allocator.free(workspaces_dir);

    var dir = std.Io.Dir.openDirAbsolute(io, workspaces_dir, .{ .iterate = true }) catch {
        try out.interface.print("No workspaces found. Create one: luke workspace create \"Name\"\n", .{});
        try out.flush();
        return;
    };
    defer dir.close(io);

    try out.interface.print("Workspaces:\n\n", .{});

    var it = try dir.walk(allocator);
    defer it.deinit();

    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        // entry.basename is the slug
        const slug = entry.basename;
        const ws_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspaces_dir, slug });
        defer allocator.free(ws_dir);

        var ws = workspace.Workspace.load(allocator, io, ws_dir) catch {
            try err.interface.print("  [{s}] (could not read workspace.txt)\n", .{slug});
            try err.flush();
            continue;
        };
        defer ws.deinit();

        try out.interface.print("  {s} ({s})\n", .{ ws.name, slug });
        for (ws.folders.items) |f| {
            try out.interface.print("    → {s}: {s}\n", .{ f.name, f.path });
        }
        try out.interface.print("\n", .{});
    }

    try out.flush();
}
