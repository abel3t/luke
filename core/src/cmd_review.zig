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
    var active_slug = slug_opt;

    // Collect diff output from all repos
    var diff_output_list = std.ArrayList(u8).empty;
    defer diff_output_list.deinit(allocator);

    if (args.len >= 3 and std.mem.eql(u8, args[2], "--pr")) {
        // PR mode: never let gh infer the repo in a multi-repo workspace.
        // Accepted forms:
        //   luke review --pr https://github.com/owner/repo/pull/123
        //   luke review --pr owner/repo#123
        //   luke review --pr owner/repo 123
        //   luke review --pr -R owner/repo 123
        var specs = try parsePrArgs(allocator, args[3..]);
        defer {
            for (specs.items) |spec| {
                allocator.free(spec.repo);
                allocator.free(spec.pr);
            }
            specs.deinit(allocator);
        }

        if (specs.items.len == 0) {
            try err.interface.print(
                "Not enough PR info. Use: luke review --pr https://github.com/owner/repo/pull/123 or luke review --pr owner/repo#123\n",
                .{},
            );
            try err.flush();
            return;
        }

        for (specs.items) |spec| {
            const argv = [_][]const u8{ "gh", "pr", "diff", spec.pr, "-R", spec.repo };
            const result = std.process.run(allocator, io, .{ .argv = &argv }) catch |e| {
                try err.interface.print("Failed to run gh for {s}#{s}: {any}\n", .{ spec.repo, spec.pr, e });
                try err.flush();
                continue;
            };
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (!result.term.success()) {
                try err.interface.print("gh pr diff failed for {s}#{s}: {s}\n", .{ spec.repo, spec.pr, result.stderr });
                try err.flush();
                continue;
            }
            try diff_output_list.appendSlice(allocator, result.stdout);
            try diff_output_list.appendSlice(allocator, "\n");
        }
    } else if (slug_opt != null) {
        // Workspace mode: run git diff in each registered folder
        const slug = slug_opt.?;
        const ws_dir = try std.fmt.allocPrint(allocator, "{s}/.luke/workspaces/{s}", .{ home_dir, slug });
        defer allocator.free(ws_dir);

        if (workspace_mod.Workspace.load(allocator, io, ws_dir)) |loaded_ws| {
            var ws = loaded_ws;
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
        } else |_| {
            try err.interface.print("Could not load workspace '{s}'. Falling back to single-repo mode.\n", .{slug});
            try err.flush();
            active_slug = null;
            try collectSingleRepoDiff(allocator, io, args, &diff_output_list);
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
    const store_slug = active_slug orelse std.fs.path.basename(workspace_path);
    var store = if (active_slug != null)
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
                                end_line = hunkEndLine(start_line, range);
                            }

                            for (knowledge_graph.nodes.items) |node| {
                                if (node.type != .File and std.mem.endsWith(u8, node.file_path, f_path)) {
                                    if ((start_line <= node.end_line) and (end_line >= node.start_line)) {
                                        if (!first_match) try out.interface.print(",\n", .{});
                                        first_match = false;

                                        try out.interface.print("  {{\n", .{});
                                        try out.interface.print("    \"file\": ", .{});
                                        try writeJsonString(&out.interface, f_path);
                                        try out.interface.print(",\n", .{});
                                        try out.interface.print("    \"node\": ", .{});
                                        try writeJsonString(&out.interface, node.name);
                                        try out.interface.print(",\n", .{});
                                        try out.interface.print("    \"type\": ", .{});
                                        try writeJsonString(&out.interface, @tagName(node.type));
                                        try out.interface.print(",\n", .{});
                                        try out.interface.print("    \"start_line\": {d},\n", .{node.start_line});
                                        try out.interface.print("    \"end_line\": {d},\n", .{node.end_line});
                                        try out.interface.print("    \"agents_required\": [\n", .{});

                                        var first_agent = true;
                                        for (agent_names) |agent| {
                                            if (shouldUseAgent(f_path, agent)) {
                                                try writeAgent(&out.interface, &first_agent, agent);
                                            }
                                        }

                                        try out.interface.print("\n    ]\n", .{});
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

const PrSpec = struct {
    repo: []const u8,
    pr: []const u8,
};

fn parsePrArgs(allocator: std.mem.Allocator, raw_args: []const [:0]const u8) !std.ArrayList(PrSpec) {
    var specs = std.ArrayList(PrSpec).empty;
    errdefer {
        for (specs.items) |spec| {
            allocator.free(spec.repo);
            allocator.free(spec.pr);
        }
        specs.deinit(allocator);
    }

    var i: usize = 0;
    while (i < raw_args.len) {
        const arg = raw_args[i];

        if (std.mem.eql(u8, arg, "-R") or std.mem.eql(u8, arg, "--repo")) {
            if (i + 2 >= raw_args.len) break;
            try appendPrSpec(&specs, allocator, raw_args[i + 1], raw_args[i + 2]);
            i += 3;
            continue;
        }

        if (parseGithubPrUrl(allocator, arg)) |spec| {
            try specs.append(allocator, spec);
            i += 1;
            continue;
        } else |_| {}

        if (parseRepoHashPr(allocator, arg)) |spec| {
            try specs.append(allocator, spec);
            i += 1;
            continue;
        } else |_| {}

        if (looksLikeRepo(arg) and i + 1 < raw_args.len and looksLikePrNumber(raw_args[i + 1])) {
            try appendPrSpec(&specs, allocator, arg, raw_args[i + 1]);
            i += 2;
            continue;
        }

        // Bare PR numbers are ambiguous in multi-repo workspaces. Ignore them so
        // callers get the "not enough PR info" message instead of a wrong review.
        i += 1;
    }

    return specs;
}

fn appendPrSpec(specs: *std.ArrayList(PrSpec), allocator: std.mem.Allocator, repo: []const u8, pr: []const u8) !void {
    try specs.append(allocator, .{
        .repo = try allocator.dupe(u8, repo),
        .pr = try allocator.dupe(u8, pr),
    });
}

fn parseGithubPrUrl(allocator: std.mem.Allocator, value: []const u8) !PrSpec {
    const marker = "github.com/";
    const start = (std.mem.indexOf(u8, value, marker) orelse return error.InvalidPrSpec) + marker.len;
    const rest = value[start..];

    var parts = std.mem.splitScalar(u8, rest, '/');
    const owner = parts.next() orelse return error.InvalidPrSpec;
    const repo = parts.next() orelse return error.InvalidPrSpec;
    const pull = parts.next() orelse return error.InvalidPrSpec;
    const pr = parts.next() orelse return error.InvalidPrSpec;
    if (!std.mem.eql(u8, pull, "pull") or !looksLikePrNumber(pr)) return error.InvalidPrSpec;

    const repo_full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ owner, repo });
    errdefer allocator.free(repo_full);
    return .{ .repo = repo_full, .pr = try allocator.dupe(u8, pr) };
}

fn parseRepoHashPr(allocator: std.mem.Allocator, value: []const u8) !PrSpec {
    const sep = std.mem.indexOfScalar(u8, value, '#') orelse return error.InvalidPrSpec;
    const repo = value[0..sep];
    const pr = value[sep + 1 ..];
    if (!looksLikeRepo(repo) or !looksLikePrNumber(pr)) return error.InvalidPrSpec;
    return .{ .repo = try allocator.dupe(u8, repo), .pr = try allocator.dupe(u8, pr) };
}

fn looksLikeRepo(value: []const u8) bool {
    const sep = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    return sep > 0 and sep + 1 < value.len;
}

fn looksLikePrNumber(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

const agent_names = [_][]const u8{
    "bloat-hunter",
    "edge-case-hunter",
    "observability-hunter",
    "migration-safety-hunter",
    "memory-leak-hunter",
    "concurrency-hunter",
    "async-hunter",
    "security-hunter",
    "api-contract-hunter",
    "data-validation-hunter",
    "n-plus-one-hunter",
    "transaction-hunter",
    "config-env-hunter",
    "dependency-hunter",
    "timeout-retry-hunter",
};

fn hunkEndLine(start_line: u32, range: u32) u32 {
    return if (range == 0) start_line else start_line + range - 1;
}

fn shouldUseAgent(f_path: []const u8, agent: []const u8) bool {
    if (std.mem.eql(u8, agent, "bloat-hunter") or
        std.mem.eql(u8, agent, "edge-case-hunter") or
        std.mem.eql(u8, agent, "observability-hunter")) return true;

    if (std.mem.eql(u8, agent, "migration-safety-hunter")) return isMigration(f_path);
    if (std.mem.eql(u8, agent, "memory-leak-hunter")) return isGo(f_path);
    if (std.mem.eql(u8, agent, "concurrency-hunter")) return isGo(f_path);
    if (std.mem.eql(u8, agent, "async-hunter")) return isJsTs(f_path);
    if (std.mem.eql(u8, agent, "security-hunter")) return isRoute(f_path);
    if (std.mem.eql(u8, agent, "api-contract-hunter")) return isRoute(f_path);
    if (std.mem.eql(u8, agent, "data-validation-hunter")) return isRoute(f_path);
    if (std.mem.eql(u8, agent, "n-plus-one-hunter")) return isDb(f_path);
    if (std.mem.eql(u8, agent, "transaction-hunter")) return isDb(f_path);
    if (std.mem.eql(u8, agent, "config-env-hunter")) return isConfig(f_path);
    if (std.mem.eql(u8, agent, "dependency-hunter")) return isDeps(f_path);
    if (std.mem.eql(u8, agent, "timeout-retry-hunter")) return isService(f_path);
    return false;
}

fn isMigration(f_path: []const u8) bool {
    return std.mem.indexOf(u8, f_path, "migration") != null or
        std.mem.indexOf(u8, f_path, "migrate") != null or
        std.mem.endsWith(u8, f_path, ".sql");
}

fn isGo(f_path: []const u8) bool {
    return std.mem.endsWith(u8, f_path, ".go");
}

fn isJsTs(f_path: []const u8) bool {
    return std.mem.endsWith(u8, f_path, ".ts") or
        std.mem.endsWith(u8, f_path, ".tsx") or
        std.mem.endsWith(u8, f_path, ".js") or
        std.mem.endsWith(u8, f_path, ".jsx");
}

fn isRoute(f_path: []const u8) bool {
    return std.mem.indexOf(u8, f_path, "route") != null or
        std.mem.indexOf(u8, f_path, "handler") != null or
        std.mem.indexOf(u8, f_path, "controller") != null or
        std.mem.indexOf(u8, f_path, "api") != null;
}

fn isDb(f_path: []const u8) bool {
    return std.mem.indexOf(u8, f_path, "repo") != null or
        std.mem.indexOf(u8, f_path, "query") != null or
        std.mem.indexOf(u8, f_path, "store") != null or
        std.mem.indexOf(u8, f_path, "db") != null or
        std.mem.indexOf(u8, f_path, "database") != null;
}

fn isConfig(f_path: []const u8) bool {
    return std.mem.indexOf(u8, f_path, "config") != null or
        std.mem.indexOf(u8, f_path, ".env") != null or
        std.mem.endsWith(u8, f_path, ".yaml") or
        std.mem.endsWith(u8, f_path, ".toml");
}

fn isDeps(f_path: []const u8) bool {
    return std.mem.endsWith(u8, f_path, "package.json") or
        std.mem.endsWith(u8, f_path, "go.mod") or
        std.mem.endsWith(u8, f_path, "go.sum") or
        std.mem.endsWith(u8, f_path, "Cargo.toml") or
        std.mem.endsWith(u8, f_path, "requirements.txt");
}

fn isService(f_path: []const u8) bool {
    return std.mem.indexOf(u8, f_path, "client") != null or
        std.mem.indexOf(u8, f_path, "service") != null or
        std.mem.indexOf(u8, f_path, "http") != null;
}

fn writeAgent(writer: anytype, first_agent: *bool, name: []const u8) !void {
    if (!first_agent.*) try writer.print(",\n", .{});
    first_agent.* = false;
    try writer.print("      ", .{});
    try writeJsonString(writer, name);
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.print("\"", .{});
    for (value) |c| {
        switch (c) {
            '\\' => try writer.print("\\\\", .{}),
            '"' => try writer.print("\\\"", .{}),
            '\n' => try writer.print("\\n", .{}),
            '\r' => try writer.print("\\r", .{}),
            '\t' => try writer.print("\\t", .{}),
            else => try writer.print("{c}", .{c}),
        }
    }
    try writer.print("\"", .{});
}

test "hunk end line uses inclusive git range" {
    try std.testing.expectEqual(@as(u32, 12), hunkEndLine(10, 3));
    try std.testing.expectEqual(@as(u32, 10), hunkEndLine(10, 1));
    try std.testing.expectEqual(@as(u32, 10), hunkEndLine(10, 0));
}

test "agent selection covers file classes" {
    try std.testing.expect(shouldUseAgent("src/api-client.ts", "bloat-hunter"));
    try std.testing.expect(shouldUseAgent("src/api-client.ts", "async-hunter"));
    try std.testing.expect(shouldUseAgent("src/api-client.ts", "security-hunter"));
    try std.testing.expect(shouldUseAgent("src/api-client.ts", "api-contract-hunter"));
    try std.testing.expect(shouldUseAgent("src/api-client.ts", "data-validation-hunter"));
    try std.testing.expect(shouldUseAgent("src/api-client.ts", "timeout-retry-hunter"));

    try std.testing.expect(shouldUseAgent("internal/server.go", "memory-leak-hunter"));
    try std.testing.expect(shouldUseAgent("internal/server.go", "concurrency-hunter"));
    try std.testing.expect(!shouldUseAgent("internal/server.go", "async-hunter"));

    try std.testing.expect(shouldUseAgent("db/migrations/001_init.sql", "migration-safety-hunter"));
    try std.testing.expect(shouldUseAgent("src/user-repo.ts", "n-plus-one-hunter"));
    try std.testing.expect(shouldUseAgent("src/user-repo.ts", "transaction-hunter"));
    try std.testing.expect(shouldUseAgent("config/app.yaml", "config-env-hunter"));
    try std.testing.expect(shouldUseAgent("package.json", "dependency-hunter"));
    try std.testing.expect(!shouldUseAgent("src/plain.ts", "timeout-retry-hunter"));
}

const TestWriter = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator) TestWriter {
        return .{ .allocator = allocator, .buf = std.ArrayList(u8).empty };
    }

    fn deinit(self: *TestWriter) void {
        self.buf.deinit(self.allocator);
    }

    fn print(self: *TestWriter, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(s);
        try self.buf.appendSlice(self.allocator, s);
    }
};

test "json strings are escaped" {
    var w = TestWriter.init(std.testing.allocator);
    defer w.deinit();

    try writeJsonString(&w, "a\\b\"c\n");
    try std.testing.expectEqualStrings("\"a\\\\b\\\"c\\n\"", w.buf.items);
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
