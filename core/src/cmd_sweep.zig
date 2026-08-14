const std = @import("std");

pub fn run(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, home_dir: []const u8, args: []const [:0]const u8) !void {
    const storage_mod = @import("storage.zig");
    var storage = storage_mod.Storage.init(allocator, io, workspace_path, home_dir) catch |err| {
        std.debug.print("Error: Not a LUKE workspace. You MUST call the 'luke-init' skill first. {}\n", .{err});
        return;
    };
    defer storage.deinit();
    const luke_path = storage.luke_path;
    if (args.len == 0) {
        std.debug.print("Usage: luke sweep <prepare|finalize> <task_id> [memory_string]\n", .{});
        return;
    }

    const subcommand = args[0];
    if (std.mem.eql(u8, subcommand, "prepare")) {
        try handlePrepare(allocator, io, workspace_path, luke_path, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "finalize")) {
        try handleFinalize(allocator, io, workspace_path, luke_path, args[1..]);
    } else {
        std.debug.print("Unknown sweep subcommand: {s}\n", .{subcommand});
    }
}

fn handlePrepare(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, luke_path: []const u8, args: []const [:0]const u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: luke sweep prepare <task_id>\n", .{});
        return;
    }
    const task_id = args[0];
    const task_dir = try std.fmt.allocPrint(allocator, "{s}/tasks/{s}", .{luke_path, task_id});
    defer allocator.free(task_dir);

    const state_path = try std.fmt.allocPrint(allocator, "{s}/state.zon", .{task_dir});
    defer allocator.free(state_path);

    var state_content: []const u8 = "";
    if (std.process.run(allocator, io, .{ .argv = &[_][]const u8{"cat", state_path} })) |res| {
        state_content = res.stdout;
    } else |_| {
        std.debug.print("[FATAL] Task {s} not found or state.zon missing.\n", .{task_id});
        return;
    }

    var start_map = std.StringHashMap([]const u8).init(allocator);
    var end_map = std.StringHashMap([]const u8).init(allocator);
    
    var in_start = false;
    var in_end = false;
    var line_iter = std.mem.splitSequence(u8, state_content, "\n");
    while (line_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, ".start_commits =")) |_| { in_start = true; in_end = false; continue; }
        if (std.mem.indexOf(u8, line, ".end_commits =")) |_| { in_end = true; in_start = false; continue; }
        if (std.mem.indexOf(u8, line, "  }")) |_| { in_start = false; in_end = false; continue; }
        
        if (std.mem.indexOf(u8, line, ".path = \"")) |p_idx| {
            const p_start = p_idx + 9;
            const p_end = std.mem.indexOf(u8, line[p_start..], "\"") orelse 0;
            const path = line[p_start .. p_start + p_end];
            
            if (std.mem.indexOf(u8, line, ".hash = \"")) |h_idx| {
                const h_start = h_idx + 9;
                const h_end = std.mem.indexOf(u8, line[h_start..], "\"") orelse 0;
                const hash = line[h_start .. h_start + h_end];
                
                if (in_start) {
                    try start_map.put(path, hash);
                } else if (in_end) {
                    try end_map.put(path, hash);
                }
            }
        }
    }

    std.debug.print("Task: {s}\n", .{task_id});
    std.debug.print("Commits by Repo:\n", .{});
    
    var has_commits = false;
    
    var it = end_map.iterator();
    while (it.next()) |entry| {
        const repo_path = entry.key_ptr.*;
        const end_hash = entry.value_ptr.*;
        const start_hash = start_map.get(repo_path) orelse continue;
        
        if (std.mem.eql(u8, start_hash, end_hash)) {
            continue; // No changes in this repo
        }
        
        const rev_range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{start_hash, end_hash});
        defer allocator.free(rev_range);
        
        const full_repo_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{workspace_path, repo_path});
        defer allocator.free(full_repo_path);
        
        if (std.process.run(allocator, io, .{ .argv = &[_][]const u8{"git", "-C", full_repo_path, "log", "--format=%H", rev_range} })) |res| {
            var commit_iter = std.mem.splitSequence(u8, res.stdout, "\n");
            var repo_has_commits = false;
            while (commit_iter.next()) |commit| {
                if (commit.len > 0) {
                    if (!repo_has_commits) {
                        std.debug.print("[{s}]\n", .{repo_path});
                        repo_has_commits = true;
                        has_commits = true;
                    }
                    std.debug.print("{s}\n", .{commit});
                }
            }
        } else |_| {}
    }
    
    if (!has_commits) {
        std.debug.print("(Not available - no code changes or git reset)\n", .{});
    }
}

fn handleFinalize(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, luke_path: []const u8, args: []const [:0]const u8) !void {
    if (args.len < 2) {
        std.debug.print("Usage: luke sweep finalize <task_id> <memory_string>\n", .{});
        return;
    }
    const task_id = args[0];
    const memory = args[1];

    const task_dir = try std.fmt.allocPrint(allocator, "{s}/tasks/{s}", .{luke_path, task_id});
    defer allocator.free(task_dir);
    
    const state_path = try std.fmt.allocPrint(allocator, "{s}/state.zon", .{task_dir});
    defer allocator.free(state_path);
    
    var state_content: []const u8 = "";
    if (std.process.run(allocator, io, .{ .argv = &[_][]const u8{"cat", state_path} })) |res| {
        state_content = res.stdout;
    } else |_| {}
    
    var start_map = std.StringHashMap([]const u8).init(allocator);
    var end_map = std.StringHashMap([]const u8).init(allocator);
    
    var in_start = false;
    var in_end = false;
    var line_iter = std.mem.splitSequence(u8, state_content, "\n");
    while (line_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, ".start_commits =")) |_| { in_start = true; in_end = false; continue; }
        if (std.mem.indexOf(u8, line, ".end_commits =")) |_| { in_end = true; in_start = false; continue; }
        if (std.mem.indexOf(u8, line, "  }")) |_| { in_start = false; in_end = false; continue; }
        
        if (std.mem.indexOf(u8, line, ".path = \"")) |p_idx| {
            const p_start = p_idx + 9;
            const p_end = std.mem.indexOf(u8, line[p_start..], "\"") orelse 0;
            const path = line[p_start .. p_start + p_end];
            
            if (std.mem.indexOf(u8, line, ".hash = \"")) |h_idx| {
                const h_start = h_idx + 9;
                const h_end = std.mem.indexOf(u8, line[h_start..], "\"") orelse 0;
                const hash = line[h_start .. h_start + h_end];
                
                if (in_start) {
                    try start_map.put(path, hash);
                } else if (in_end) {
                    try end_map.put(path, hash);
                }
            }
        }
    }
    
    var commits_json = std.ArrayList(u8).empty;
    defer commits_json.deinit(allocator);
    try commits_json.print(allocator, "{{", .{});
    
    var first_repo = true;
    var it = end_map.iterator();
    while (it.next()) |entry| {
        const repo_path = entry.key_ptr.*;
        const end_hash = entry.value_ptr.*;
        const start_hash = start_map.get(repo_path) orelse continue;
        
        if (std.mem.eql(u8, start_hash, end_hash)) {
            continue;
        }
        
        if (!first_repo) try commits_json.print(allocator, ", ", .{});
        try commits_json.print(allocator, "\"{s}\": [", .{repo_path});
        first_repo = false;
        
        const rev_range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{start_hash, end_hash});
        defer allocator.free(rev_range);
        
        const full_repo_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{workspace_path, repo_path});
        defer allocator.free(full_repo_path);
        
        var first_commit = true;
        if (std.process.run(allocator, io, .{ .argv = &[_][]const u8{"git", "-C", full_repo_path, "log", "--format=%H", rev_range} })) |res| {
            var commit_iter = std.mem.splitSequence(u8, res.stdout, "\n");
            while (commit_iter.next()) |commit| {
                if (commit.len > 0) {
                    if (!first_commit) try commits_json.print(allocator, ", ", .{});
                    try commits_json.print(allocator, "\"{s}\"", .{commit});
                    first_commit = false;
                }
            }
        } else |_| {}
        try commits_json.print(allocator, "]", .{});
    }
    try commits_json.print(allocator, "}}", .{});
    
    const history_path = try std.fmt.allocPrint(allocator, "{s}/history.jsonl", .{workspace_path});
    defer allocator.free(history_path);

    const summary = try std.fmt.allocPrint(allocator, "{{\"task_id\": \"{s}\", \"commits\": {s}, \"memory\": \"{s}\"}}\n", .{task_id, commits_json.items, memory});
    defer allocator.free(summary);

    const echo_cmd = try std.fmt.allocPrint(allocator, "echo '{s}' >> {s}", .{summary, history_path});
    defer allocator.free(echo_cmd);
    _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "sh", "-c", echo_cmd } }) catch {};

    _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "rm", "-rf", task_dir } }) catch {};

    std.debug.print("Task {s} permanently archived to history and deleted.\n", .{task_id});
}
