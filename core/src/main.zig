const std = @import("std");
const cmd_init = @import("cmd_init.zig");
const cmd_query = @import("cmd_query.zig");
const cmd_review = @import("cmd_review.zig");
const cmd_audit = @import("cmd_audit.zig");
const cmd_task = @import("cmd_task.zig");
const cmd_sweep = @import("cmd_sweep.zig");
const cmd_status = @import("cmd_status.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];
    const io = init.io;

    const home_dir = init.minimal.environ.getAlloc(allocator, "HOME") catch try allocator.dupe(u8, ".");
    defer allocator.free(home_dir);

    if (std.mem.eql(u8, command, "index")) {
        const workspace_path = if (args.len > 2) args[2] else ".";
        try cmd_init.run(allocator, io, workspace_path, home_dir);
    } else if (std.mem.eql(u8, command, "workspace")) {
        if (args.len < 4 or !std.mem.eql(u8, args[2], "init")) {
            std.debug.print("Usage: luke workspace init <name>\n", .{});
            return;
        }
        const name = args[3];
        const slug = try allocator.dupe(u8, name);
        for (slug) |*c| {
            if (c.* == ' ') c.* = '-';
            c.* = std.ascii.toLower(c.*);
        }

        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);

        const workspaces_dir = try std.fmt.allocPrint(allocator, "{s}/.luke/workspaces/{s}", .{home_dir, slug});
        defer allocator.free(workspaces_dir);

        _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "mkdir", "-p", workspaces_dir } }) catch {};

        const json_path = try std.fmt.allocPrint(allocator, "{s}/workspace.json", .{workspaces_dir});
        defer allocator.free(json_path);

        var file = try std.Io.Dir.createFileAbsolute(io, json_path, .{});
        defer file.close(io);

        const json_content = try std.fmt.allocPrint(allocator,
            \\{{
            \\  "version": 1,
            \\  "name": "{s}",
            \\  "slug": "{s}",
            \\  "folders": [
            \\    {{ "name": "default", "path": "{s}" }}
            \\  ]
            \\}}
            , .{ name, slug, cwd }
        );
        defer allocator.free(json_content);

        var write_buf: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buf);
        _ = try writer.interface.writeAll(json_content);
        try writer.flush();
        
        std.debug.print("Workspace '{s}' (slug: {s}) initialized globally for {s}\n", .{name, slug, cwd});
    } else if (std.mem.eql(u8, command, "query")) {
        if (args.len < 3) {
            std.debug.print("Error: query requires a target string.\n", .{});
            return;
        }
        try cmd_query.run(allocator, io, ".", home_dir, args[2..]);
    } else if (std.mem.eql(u8, command, "update")) {
        std.debug.print("Memory update command triggered.\n", .{});
    } else if (std.mem.eql(u8, command, "review")) {
        try cmd_review.run(allocator, io, ".", home_dir, args);
    } else if (std.mem.eql(u8, command, "task")) {
        try cmd_task.run(allocator, io, ".", home_dir, args[2..]);
    } else if (std.mem.eql(u8, command, "sweep")) {
        try cmd_sweep.run(allocator, io, ".", home_dir, args[2..]);
    } else if (std.mem.eql(u8, command, "audit")) {
        try cmd_audit.run(allocator, io, ".", home_dir);
    } else if (std.mem.eql(u8, command, "status")) {
        try cmd_status.run(allocator, io, ".", home_dir, args[2..]);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\Luke Core Engine
        \\Usage: luke <command> [args]
        \\
        \\Commands:
        \\  workspace init        Create a local .luke workspace boundary
        \\  index [path]          Crawl workspace and build the AST graph
        \\  review [args]         Create a compact, manifest-backed review plan
        \\  review start [args]   Alias for review; creates a persistent manifest
        \\  review status <id>    Show review manifest progress
        \\  review next <id>      Emit one pending review unit as JSON
        \\  review submit <id> <chunk> <result.json>  Validate and record evidence
        \\  review block <id> <chunk>  Mark a retry-exhausted claimed chunk blocked
        \\  review finalize <id>  Refuse completion while chunks remain
        \\  query <target>        Query the graph for a node or file
        \\  audit                 Structural whole-project audit (requires init)
        \\
    , .{});
}
