const std = @import("std");
const cmd_init = @import("cmd_init.zig");
const cmd_query = @import("cmd_query.zig");
const cmd_review = @import("cmd_review.zig");
const cmd_workspace = @import("cmd_workspace.zig");
const cmd_audit = @import("cmd_audit.zig");

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

    if (std.mem.eql(u8, command, "init")) {
        const workspace_path = if (args.len > 2) args[2] else ".";
        try cmd_init.run(allocator, io, workspace_path, home_dir);
    } else if (std.mem.eql(u8, command, "query")) {
        if (args.len < 3) {
            std.debug.print("Error: query requires a target string.\n", .{});
            return;
        }
        const target = args[2];
        try cmd_query.run(allocator, io, ".", home_dir, target);
    } else if (std.mem.eql(u8, command, "update")) {
        std.debug.print("Memory update command triggered.\n", .{});
    } else if (std.mem.eql(u8, command, "review")) {
        try cmd_review.run(allocator, io, ".", home_dir, args);
    } else if (std.mem.eql(u8, command, "audit")) {
        try cmd_audit.run(allocator, io, ".", home_dir);
    } else if (std.mem.eql(u8, command, "workspace")) {
        try cmd_workspace.run(allocator, io, home_dir, args);
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
        \\  init [path]           Crawl workspace and build the AST graph
        \\  review [args]         Create a compact, manifest-backed review plan
        \\  review start [args]   Alias for review; creates a persistent manifest
        \\  review status <id>    Show review manifest progress
        \\  review next <id>      Emit one pending review unit as JSON
        \\  review submit <id> <chunk> <result.json>  Validate and record evidence
        \\  review block <id> <chunk>  Mark a retry-exhausted claimed chunk blocked
        \\  review finalize <id>  Refuse completion while chunks remain
        \\  query <target>        Query the graph for a node or file
        \\  audit                 Structural whole-project audit (requires init)
        \\  workspace <sub>       Manage workspaces (create/add/remove/delete/list)
        \\
        \\Workspace Examples:
        \\  luke workspace create "Hako Dropship"
        \\  luke workspace add hako-dropship . backend
        \\  luke workspace add hako-dropship /path/to/fe frontend
        \\  luke workspace list
        \\
    , .{});
}
