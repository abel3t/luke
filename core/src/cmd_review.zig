const std = @import("std");
const graph = @import("graph.zig");
const storage = @import("storage.zig");
const workspace_mod = @import("workspace.zig");
const registry = @import("registry.zig");
const cmd_init = @import("cmd_init.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, home_dir: []const u8, args: []const [:0]const u8) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [256]u8 = undefined;
    var out = std.Io.File.Writer.init(std.Io.File.stdout(), io, &stdout_buf);
    var err = std.Io.File.Writer.init(std.Io.File.stderr(), io, &stderr_buf);

    // Detect workspace from CWD
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    var reg = try registry.Registry.load(allocator, io, home_dir);
    defer reg.deinit();

    const slug_opt = reg.detect(cwd);

    // Collect diff output from all repos
    var diff_output_list = std.ArrayList(u8).empty;
    defer diff_output_list.deinit(allocator);

    if (args.len >= 3 and std.mem.eql(u8, args[2], "--pr")) {
        // PR mode: fetch diffs from gh for each PR number
        for (args[3..]) |pr| {
            const argv = [_][]const u8{ "gh", "pr", "diff", pr };
            const result = std.process.run(allocator, io, .{ .argv = &argv }) catch continue;
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            try diff_output_list.appendSlice(allocator, result.stdout);
            try diff_output_list.appendSlice(allocator, "\n");
        }
    } else if (slug_opt != null) {
        // Workspace mode: run git diff in each registered folder
        const slug = slug_opt.?;
        const ws_dir = try std.fmt.allocPrint(allocator, "{s}/.luke/workspaces/{s}", .{ home_dir, slug });
        defer allocator.free(ws_dir);

        var ws = workspace_mod.Workspace.load(allocator, io, ws_dir) catch {
            try err.interface.print("Could not load workspace '{s}'. Falling back to single-repo mode.\n", .{slug});
            try err.flush();
            try collectSingleRepoDiff(allocator, io, args, &diff_output_list);
            return;
        };
        defer ws.deinit();

        try err.interface.print("Workspace: {s} — running review across {d} repos...\n", .{ ws.name, ws.folders.items.len });
        try err.flush();

        for (ws.folders.items) |folder| {
            var diff_cmd = std.ArrayList([]const u8).empty;
            defer diff_cmd.deinit(allocator);

            try diff_cmd.appendSlice(allocator, &[_][]const u8{ "git", "-C", folder.path, "diff" });
            if (args.len > 2) {
                try diff_cmd.appendSlice(allocator, args[2..]);
            } else {
                try diff_cmd.append(allocator, "HEAD");
            }

            const result = std.process.run(allocator, io, .{ .argv = diff_cmd.items }) catch continue;
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);

            if (result.stdout.len > 0) {
                try err.interface.print("  [{s}] {d} bytes diff\n", .{ folder.name, result.stdout.len });
                try err.flush();
                try diff_output_list.appendSlice(allocator, result.stdout);
                try diff_output_list.appendSlice(allocator, "\n");
            }
        }
    } else {
        // Single-repo mode
        try collectSingleRepoDiff(allocator, io, args, &diff_output_list);
    }

    const diff_output = diff_output_list.items;

    if (diff_output.len == 0) {
        try err.interface.print("No changes detected.\n", .{});
        try err.flush();
        return;
    }

    // Load the knowledge graph
    const store_slug = slug_opt orelse std.fs.path.basename(workspace_path);
    var store = if (slug_opt != null)
        try storage.Storage.initWithSlug(allocator, io, home_dir, store_slug)
    else
        try storage.Storage.init(allocator, io, workspace_path, home_dir);
    defer store.deinit();

    var knowledge_graph = graph.Graph.init(allocator);
    defer knowledge_graph.deinit();

    store.loadLongtermMemory(&knowledge_graph) catch {
        try err.interface.print("No index found. Auto-initializing workspace...\n", .{});
        try err.flush();
        // Re-use cmd_init to build the graph, then retry loading
        cmd_init.run(allocator, io, workspace_path, home_dir) catch |e2| {
            try err.interface.print("Auto-init failed: {any}\n", .{e2});
            try err.flush();
            return;
        };
        store.loadLongtermMemory(&knowledge_graph) catch |e2| {
            try err.interface.print("Auto-init succeeded but graph still unreadable: {any}\n", .{e2});
            try err.flush();
            return;
        };
    };

    try err.interface.print("Captured {d} bytes diff. Orchestrating JSON payload...\n", .{diff_output.len});
    try err.flush();

    // Parse diff and intersect with graph
    var lines = std.mem.splitScalar(u8, diff_output, '\n');
    var current_file: ?[]const u8 = null;
    var first_match = true;

    try out.interface.print("[\n", .{});

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ b/")) {
            current_file = line[6..];
        } else if (std.mem.startsWith(u8, line, "@@ ")) {
            if (current_file) |f_path| {
                var parts = std.mem.splitScalar(u8, line, ' ');
                _ = parts.next();
                _ = parts.next();
                if (parts.next()) |add_part| {
                    if (add_part.len > 1 and add_part[0] == '+') {
                        var num_parts = std.mem.splitScalar(u8, add_part[1..], ',');
                        if (num_parts.next()) |start_str| {
                            const start_line = std.fmt.parseInt(u32, start_str, 10) catch continue;
                            var end_line = start_line;
                            if (num_parts.next()) |range_str| {
                                const range = std.fmt.parseInt(u32, range_str, 10) catch continue;
                                end_line = start_line + range;
                            }

                            for (knowledge_graph.nodes.items) |node| {
                                if (node.type != .File and std.mem.endsWith(u8, node.file_path, f_path)) {
                                    if ((start_line <= node.end_line) and (end_line >= node.start_line)) {
                                        if (!first_match) try out.interface.print(",\n", .{});
                                        first_match = false;

                                        try out.interface.print("  {{\n", .{});
                                        try out.interface.print("    \"file\": \"{s}\",\n", .{f_path});
                                        try out.interface.print("    \"node\": \"{s}\",\n", .{node.name});
                                        try out.interface.print("    \"type\": \"{s}\",\n", .{@tagName(node.type)});
                                        try out.interface.print("    \"start_line\": {d},\n", .{node.start_line});
                                        try out.interface.print("    \"end_line\": {d},\n", .{node.end_line});
                                        try out.interface.print("    \"agents_required\": [\n", .{});

                                        // === Core agents: always spawned ===
                                        try out.interface.print("      \"bloat-hunter\",\n", .{});
                                        try out.interface.print("      \"edge-case-hunter\",\n", .{});
                                        try out.interface.print("      \"observability-hunter\",\n", .{});

                                        // === Migration files ===
                                        const is_migration = std.mem.indexOf(u8, f_path, "migration") != null or
                                            std.mem.indexOf(u8, f_path, "migrate") != null or
                                            std.mem.endsWith(u8, f_path, ".sql");
                                        if (is_migration) {
                                            try out.interface.print("      \"migration-safety-hunter\",\n", .{});
                                        }

                                        // === Go files: concurrency + memory leaks ===
                                        const is_go = std.mem.endsWith(u8, f_path, ".go");
                                        if (is_go) {
                                            try out.interface.print("      \"memory-leak-hunter\",\n", .{});
                                            try out.interface.print("      \"concurrency-hunter\",\n", .{});
                                        }

                                        // === API routes / controllers ===
                                        const is_route = std.mem.indexOf(u8, f_path, "route") != null or
                                            std.mem.indexOf(u8, f_path, "handler") != null or
                                            std.mem.indexOf(u8, f_path, "controller") != null or
                                            std.mem.indexOf(u8, f_path, "api") != null;
                                        if (is_route) {
                                            try out.interface.print("      \"security-hunter\",\n", .{});
                                            try out.interface.print("      \"api-contract-hunter\",\n", .{});
                                            try out.interface.print("      \"data-validation-hunter\",\n", .{});
                                        }

                                        // === DB / repository layer ===
                                        const is_db = std.mem.indexOf(u8, f_path, "repo") != null or
                                            std.mem.indexOf(u8, f_path, "query") != null or
                                            std.mem.indexOf(u8, f_path, "store") != null or
                                            std.mem.indexOf(u8, f_path, "db") != null or
                                            std.mem.indexOf(u8, f_path, "database") != null;
                                        if (is_db) {
                                            try out.interface.print("      \"n-plus-one-hunter\",\n", .{});
                                            try out.interface.print("      \"transaction-hunter\",\n", .{});
                                        }

                                        // === Config / env / manifest files ===
                                        const is_config = std.mem.indexOf(u8, f_path, "config") != null or
                                            std.mem.indexOf(u8, f_path, ".env") != null or
                                            std.mem.endsWith(u8, f_path, ".yaml") or
                                            std.mem.endsWith(u8, f_path, ".toml");
                                        if (is_config) {
                                            try out.interface.print("      \"config-env-hunter\",\n", .{});
                                        }

                                        // === Dependency manifests ===
                                        const is_deps = std.mem.endsWith(u8, f_path, "package.json") or
                                            std.mem.endsWith(u8, f_path, "go.mod") or
                                            std.mem.endsWith(u8, f_path, "go.sum") or
                                            std.mem.endsWith(u8, f_path, "Cargo.toml") or
                                            std.mem.endsWith(u8, f_path, "requirements.txt");
                                        if (is_deps) {
                                            try out.interface.print("      \"dependency-hunter\",\n", .{});
                                        }

                                        // === HTTP service calls (resilience) ===
                                        const is_service = std.mem.indexOf(u8, f_path, "client") != null or
                                            std.mem.indexOf(u8, f_path, "service") != null or
                                            std.mem.indexOf(u8, f_path, "http") != null;
                                        if (is_service) {
                                            try out.interface.print("      \"timeout-retry-hunter\"\n", .{});
                                        } else {
                                            // close the array cleanly when timeout-retry not last
                                            // (we need to strip trailing comma from last entry)
                                            // Already handled: last non-conditional is observability
                                            try out.interface.print("      \"timeout-retry-hunter\"\n", .{});
                                        }

                                        try out.interface.print("    ]\n", .{});
                                        try out.interface.print("  }}", .{});
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    try out.interface.print("\n]\n", .{});
    try out.flush();
}

fn collectSingleRepoDiff(allocator: std.mem.Allocator, io: std.Io, args: []const [:0]const u8, diff_output_list: *std.ArrayList(u8)) !void {
    var diff_cmd = std.ArrayList([]const u8).empty;
    defer diff_cmd.deinit(allocator);

    if (args.len == 2) {
        try diff_cmd.appendSlice(allocator, &[_][]const u8{ "git", "diff", "HEAD" });
    } else {
        try diff_cmd.appendSlice(allocator, &[_][]const u8{ "git", "diff" });
        try diff_cmd.appendSlice(allocator, args[2..]);
    }

    const result = std.process.run(allocator, io, .{ .argv = diff_cmd.items }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try diff_output_list.appendSlice(allocator, result.stdout);
}
