const std = @import("std");
const graph = @import("graph.zig");
const storage = @import("storage.zig");
const workspace_mod = @import("workspace.zig");
const registry = @import("registry.zig");
const cmd_init = @import("cmd_init.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, home_dir: []const u8, args: []const [:0]const u8) !void {
    if (args.len >= 4 and std.mem.eql(u8, args[2], "status")) return reviewStatus(allocator, io, home_dir, args[3]);
    if (args.len >= 4 and std.mem.eql(u8, args[2], "finalize")) return reviewFinalize(allocator, io, home_dir, args[3]);
    if (args.len >= 5 and std.mem.eql(u8, args[2], "complete")) return reviewComplete(allocator, io, home_dir, args[3], args[4]);

    const start_mode = args.len >= 3 and std.mem.eql(u8, args[2], "start");
    const review_args = if (start_mode) args[3..] else args[2..];

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

    if (review_args.len >= 1 and std.mem.eql(u8, review_args[0], "--pr")) {
        // PR mode: never let gh infer the repo in a multi-repo workspace.
        // Accepted forms:
        //   luke review --pr https://github.com/owner/repo/pull/123
        //   luke review --pr owner/repo#123
        //   luke review --pr owner/repo 123
        //   luke review --pr -R owner/repo 123
        var specs = try parsePrArgs(allocator, review_args[1..]);
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
                if (review_args.len > 0) {
                    try diff_cmd.appendSlice(allocator, review_args);
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
            try collectSingleRepoDiff(allocator, io, review_args, &diff_output_list);
        }
    } else {
        // Single-repo mode
        try collectSingleRepoDiff(allocator, io, review_args, &diff_output_list);
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

    // Deterministically assign every changed line to exactly one review chunk.
    // The model may later inspect chunks, but it does not control coverage.
    var chunks = try planReviewChunks(allocator, diff_output, &knowledge_graph);
    defer deinitChunks(allocator, &chunks);

    if (start_mode) {
        const run_id = try saveReviewManifest(allocator, io, home_dir, &chunks);
        defer allocator.free(run_id);
        try err.interface.print("Review run created: {s}. Use `luke review status {s}`.\n", .{ run_id, run_id });
        try err.flush();
    }

    var eligible_lines: u64 = 0;
    for (chunks.items) |chunk| {
        for (chunk.changed_ranges.items) |range| eligible_lines += range.count;
    }

    try out.interface.print("{{\n  \"coverage\": {{\n", .{});
    try out.interface.print("    \"eligible_changed_lines\": {d},\n", .{eligible_lines});
    try out.interface.print("    \"assigned_changed_lines\": {d},\n", .{eligible_lines});
    try out.interface.print("    \"uncovered_changed_lines\": 0,\n", .{});
    try out.interface.print("    \"chunks\": {d}\n", .{chunks.items.len});
    try out.interface.print("  }},\n  \"chunks\": [\n", .{});

    for (chunks.items, 0..) |chunk, i| {
        if (i > 0) try out.interface.print(",\n", .{});
        try out.interface.print("    {{\n      \"file\": ", .{});
        try writeJsonString(&out.interface, chunk.file);
        try out.interface.print(",\n      \"node\": ", .{});
        try writeJsonString(&out.interface, chunk.node);
        try out.interface.print(",\n      \"type\": ", .{});
        try writeJsonString(&out.interface, @tagName(chunk.node_type));
        try out.interface.print(",\n      \"start_line\": {d},\n      \"end_line\": {d},\n", .{ chunk.start_line, chunk.end_line });
        try out.interface.print("      \"changed_ranges\": [", .{});
        for (chunk.changed_ranges.items, 0..) |range, range_i| {
            if (range_i > 0) try out.interface.print(", ", .{});
            try out.interface.print("{{ \"start\": {d}, \"end\": {d} }}", .{ range.start_line, range.end_line });
        }
        try out.interface.print("],\n      \"review_lenses\": [\n", .{});

        var first_lens = true;
        for (review_lenses) |lens| {
            if (shouldUseLens(chunk.file, lens)) try writeLens(&out.interface, &first_lens, lens);
        }
        try out.interface.print("\n      ]\n    }}", .{});
    }

    try out.interface.print("\n  ]\n}}\n", .{});
    try out.flush();
}

const ChangedRange = struct {
    start_line: u32,
    end_line: u32,
    count: u32,
};

const ReviewChunk = struct {
    file: []const u8,
    node: []const u8,
    node_type: graph.NodeType,
    start_line: u32,
    end_line: u32,
    changed_ranges: std.ArrayList(ChangedRange),
};

fn planReviewChunks(allocator: std.mem.Allocator, diff_output: []const u8, knowledge_graph: *graph.Graph) !std.ArrayList(ReviewChunk) {
    var chunks = std.ArrayList(ReviewChunk).empty;
    errdefer deinitChunks(allocator, &chunks);

    var lines = std.mem.splitScalar(u8, diff_output, '\n');
    var current_file: ?[]const u8 = null;

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ b/")) {
            current_file = line[6..];
            continue;
        }
        if (!std.mem.startsWith(u8, line, "@@ ")) continue;
        const file = current_file orelse continue;
        const range = parseAddedRange(line) orelse continue;

        const best = smallestCoveringNode(knowledge_graph, file, range);
        const node = if (best) |found| found else null;
        const chunk_file = file;
        const chunk_name = if (node) |found| found.name else file;
        const chunk_type = if (node) |found| found.type else graph.NodeType.File;
        const chunk_start = if (node) |found| found.start_line else range.start_line;
        const chunk_end = if (node) |found| found.end_line else range.end_line;

        var matched: ?*ReviewChunk = null;
        for (chunks.items) |*chunk| {
            if (std.mem.eql(u8, chunk.file, chunk_file) and
                std.mem.eql(u8, chunk.node, chunk_name) and
                chunk.start_line == chunk_start and
                chunk.end_line == chunk_end)
            {
                matched = chunk;
                break;
            }
        }

        if (matched) |chunk| {
            try chunk.changed_ranges.append(allocator, range);
        } else {
            var ranges = std.ArrayList(ChangedRange).empty;
            try ranges.append(allocator, range);
            try chunks.append(allocator, .{
                .file = chunk_file,
                .node = chunk_name,
                .node_type = chunk_type,
                .start_line = chunk_start,
                .end_line = chunk_end,
                .changed_ranges = ranges,
            });
        }
    }

    return chunks;
}

fn deinitChunks(allocator: std.mem.Allocator, chunks: *std.ArrayList(ReviewChunk)) void {
    for (chunks.items) |*chunk| chunk.changed_ranges.deinit(allocator);
    chunks.deinit(allocator);
}

fn parseAddedRange(hunk_header: []const u8) ?ChangedRange {
    var parts = std.mem.splitScalar(u8, hunk_header, ' ');
    _ = parts.next(); // @@
    _ = parts.next(); // old range
    const added = parts.next() orelse return null;
    if (added.len < 2 or added[0] != '+') return null;

    var numbers = std.mem.splitScalar(u8, added[1..], ',');
    const start = std.fmt.parseInt(u32, numbers.next() orelse return null, 10) catch return null;
    const count = if (numbers.next()) |raw| std.fmt.parseInt(u32, raw, 10) catch return null else 1;
    return .{
        .start_line = start,
        .end_line = hunkEndLine(start, count),
        .count = count,
    };
}

fn smallestCoveringNode(knowledge_graph: *graph.Graph, file: []const u8, range: ChangedRange) ?*graph.Node {
    var best: ?*graph.Node = null;
    for (knowledge_graph.nodes.items) |*node| {
        if (node.type == .File or !std.mem.endsWith(u8, node.file_path, file)) continue;
        if (range.count > 0 and !(node.start_line <= range.start_line and node.end_line >= range.end_line)) continue;

        if (best == null or node.end_line - node.start_line < best.?.end_line - best.?.start_line) {
            best = node;
        }
    }
    return best;
}

fn reviewManifestPath(allocator: std.mem.Allocator, home_dir: []const u8, run_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/.luke/reviews/{s}.json", .{ home_dir, run_id });
}

fn saveReviewManifest(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, chunks: *std.ArrayList(ReviewChunk)) ![]const u8 {
    const run_id = try std.fmt.allocPrint(allocator, "review-{d}", .{std.c.getpid()});
    errdefer allocator.free(run_id);
    const reviews_dir = try std.fmt.allocPrint(allocator, "{s}/.luke/reviews", .{home_dir});
    defer allocator.free(reviews_dir);
    _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "mkdir", "-p", reviews_dir } }) catch {};

    const path = try reviewManifestPath(allocator, home_dir, run_id);
    defer allocator.free(path);
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.print("{{\n  \"version\": 1,\n  \"run_id\": ", .{});
    try writeJsonString(&writer.interface, run_id);
    try writer.interface.print(",\n  \"chunks\": [\n", .{});
    for (chunks.items, 0..) |chunk, index| {
        if (index > 0) try writer.interface.print(",\n", .{});
        try writer.interface.print("    {{ \"id\": {d}, \"status\": \"pending\", \"file\": ", .{index});
        try writeJsonString(&writer.interface, chunk.file);
        try writer.interface.print(", \"node\": ", .{});
        try writeJsonString(&writer.interface, chunk.node);
        try writer.interface.print(", \"start_line\": {d}, \"end_line\": {d} }}", .{ chunk.start_line, chunk.end_line });
    }
    try writer.interface.print("\n  ]\n}}\n", .{});
    try writer.flush();
    return run_id;
}

fn readReviewManifest(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, run_id: []const u8) ![]u8 {
    const path = try reviewManifestPath(allocator, home_dir, run_id);
    defer allocator.free(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, std.fs.path.dirname(path).?, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, std.fs.path.basename(path), allocator, @fromBackingInt(@intCast(1024 * 1024)));
}

fn reviewStatus(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, run_id: []const u8) !void {
    const content = readReviewManifest(allocator, io, home_dir, run_id) catch {
        std.debug.print("Review run not found: {s}\n", .{run_id});
        return;
    };
    defer allocator.free(content);
    const pending = countOccurrences(content, "\"status\": \"pending\"");
    const complete = countOccurrences(content, "\"status\": \"complete\"");
    const failed = countOccurrences(content, "\"status\": \"failed\"");
    std.debug.print("Review {s}: {d} complete, {d} pending, {d} failed\n", .{ run_id, complete, pending, failed });
}

fn reviewFinalize(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, run_id: []const u8) !void {
    const content = readReviewManifest(allocator, io, home_dir, run_id) catch {
        std.debug.print("Review run not found: {s}\n", .{run_id});
        return;
    };
    defer allocator.free(content);
    const pending = countOccurrences(content, "\"status\": \"pending\"");
    const failed = countOccurrences(content, "\"status\": \"failed\"");
    if (pending != 0 or failed != 0) {
        std.debug.print("Review incomplete: {d} pending, {d} failed.\n", .{ pending, failed });
        return;
    }
    const path = try reviewManifestPath(allocator, home_dir, run_id);
    defer allocator.free(path);
    _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "rm", "-f", path } }) catch {};
    std.debug.print("Review complete: all chunks have terminal success status. Cleared run data.\n", .{});
}

fn reviewComplete(allocator: std.mem.Allocator, io: std.Io, home_dir: []const u8, run_id: []const u8, chunk_id: []const u8) !void {
    const index = std.fmt.parseInt(usize, chunk_id, 10) catch {
        std.debug.print("Chunk id must be a number.\n", .{});
        return;
    };
    const content = readReviewManifest(allocator, io, home_dir, run_id) catch {
        std.debug.print("Review run not found: {s}\n", .{run_id});
        return;
    };
    defer allocator.free(content);

    const chunk_marker = try std.fmt.allocPrint(allocator, "\"id\": {d}, \"status\": \"pending\"", .{index});
    defer allocator.free(chunk_marker);
    const chunk_pos = std.mem.indexOf(u8, content, chunk_marker) orelse {
        std.debug.print("Pending chunk {d} not found.\n", .{index});
        return;
    };
    const marker = "\"status\": \"pending\"";
    const pos = chunk_pos + std.mem.indexOf(u8, chunk_marker, marker).?;

    var next = std.ArrayList(u8).empty;
    defer next.deinit(allocator);
    try next.appendSlice(allocator, content[0..pos]);
    try next.appendSlice(allocator, "\"status\": \"complete\"");
    try next.appendSlice(allocator, content[pos + marker.len ..]);

    const path = try reviewManifestPath(allocator, home_dir, run_id);
    defer allocator.free(path);
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, next.items);
    std.debug.print("Marked chunk {d} complete.\n", .{index});
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, start, needle)) |pos| {
        count += 1;
        start = pos + needle.len;
    }
    return count;
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

const review_lenses = [_][]const u8{
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

fn shouldUseLens(f_path: []const u8, agent: []const u8) bool {
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

fn writeLens(writer: anytype, first_agent: *bool, name: []const u8) !void {
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

test "review planner assigns every changed hunk to one smallest AST chunk" {
    var knowledge_graph = graph.Graph.init(std.testing.allocator);
    defer knowledge_graph.deinit();
    try knowledge_graph.addNode("node://repo.ts/Repository", .Class, "Repository", "src/repo.ts", 1, 100);
    try knowledge_graph.addNode("node://repo.ts/applyFilters", .Function, "applyFilters", "src/repo.ts", 20, 40);

    const diff =
        \\diff --git a/src/repo.ts b/src/repo.ts
        \\+++ b/src/repo.ts
        \\@@ -22,2 +22,3 @@
        \\@@ -60 +61 @@
    ;
    var chunks = try planReviewChunks(std.testing.allocator, diff, &knowledge_graph);
    defer deinitChunks(std.testing.allocator, &chunks);

    try std.testing.expectEqual(@as(usize, 2), chunks.items.len);
    try std.testing.expectEqualStrings("applyFilters", chunks.items[0].node);
    try std.testing.expectEqual(@as(u32, 20), chunks.items[0].start_line);
    try std.testing.expectEqual(@as(u32, 40), chunks.items[0].end_line);
    try std.testing.expectEqual(@as(u32, 3), chunks.items[0].changed_ranges.items[0].count);
    try std.testing.expectEqualStrings("Repository", chunks.items[1].node);
}

test "review lens selection covers file classes" {
    try std.testing.expect(shouldUseLens("src/api-client.ts", "bloat-hunter"));
    try std.testing.expect(shouldUseLens("src/api-client.ts", "async-hunter"));
    try std.testing.expect(shouldUseLens("src/api-client.ts", "security-hunter"));
    try std.testing.expect(shouldUseLens("src/api-client.ts", "api-contract-hunter"));
    try std.testing.expect(shouldUseLens("src/api-client.ts", "data-validation-hunter"));
    try std.testing.expect(shouldUseLens("src/api-client.ts", "timeout-retry-hunter"));

    try std.testing.expect(shouldUseLens("internal/server.go", "memory-leak-hunter"));
    try std.testing.expect(shouldUseLens("internal/server.go", "concurrency-hunter"));
    try std.testing.expect(!shouldUseLens("internal/server.go", "async-hunter"));

    try std.testing.expect(shouldUseLens("db/migrations/001_init.sql", "migration-safety-hunter"));
    try std.testing.expect(shouldUseLens("src/user-repo.ts", "n-plus-one-hunter"));
    try std.testing.expect(shouldUseLens("src/user-repo.ts", "transaction-hunter"));
    try std.testing.expect(shouldUseLens("config/app.yaml", "config-env-hunter"));
    try std.testing.expect(shouldUseLens("package.json", "dependency-hunter"));
    try std.testing.expect(!shouldUseLens("src/plain.ts", "timeout-retry-hunter"));
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

fn collectSingleRepoDiff(allocator: std.mem.Allocator, io: std.Io, review_args: []const [:0]const u8, diff_output_list: *std.ArrayList(u8)) !void {
    var diff_cmd = std.ArrayList([]const u8).empty;
    defer diff_cmd.deinit(allocator);

    if (review_args.len == 0) {
        try diff_cmd.appendSlice(allocator, &[_][]const u8{ "git", "diff", "HEAD" });
    } else {
        try diff_cmd.appendSlice(allocator, &[_][]const u8{ "git", "diff" });
        try diff_cmd.appendSlice(allocator, review_args);
    }

    const result = std.process.run(allocator, io, .{ .argv = diff_cmd.items }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try diff_output_list.appendSlice(allocator, result.stdout);
}
