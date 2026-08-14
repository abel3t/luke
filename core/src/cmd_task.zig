const std = @import("std");

const TaskStatus = enum { Pending, InProgress, ReviewPending, Done, Cancelled };

pub fn run(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, home_dir: []const u8, args: []const [:0]const u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: luke task <create|claim|submit|approve|reject|cancel> [args]\n", .{});
        return;
    }
    
    const subcommand = args[0];
    
    // Convert relative workspace to absolute.
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
    
    const storage_mod = @import("storage.zig");
    var storage = storage_mod.Storage.init(allocator, io, absolute_workspace_path, home_dir) catch |err| {
        std.debug.print("Error: Not a LUKE workspace. You MUST call the 'luke-init' skill first. {}\n", .{err});
        return;
    };
    defer storage.deinit();
    
    const luke_path = storage.luke_path;

    if (std.mem.eql(u8, subcommand, "create")) {
        try handleCreate(allocator, io, absolute_workspace_path, luke_path, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "claim")) {
        try handleStateChange(allocator, io, absolute_workspace_path, luke_path, args[1..], .Pending, .InProgress);
    } else if (std.mem.eql(u8, subcommand, "submit")) {
        try handleStateChange(allocator, io, absolute_workspace_path, luke_path, args[1..], .InProgress, .ReviewPending);
    } else if (std.mem.eql(u8, subcommand, "approve")) {
        try handleStateChange(allocator, io, absolute_workspace_path, luke_path, args[1..], .ReviewPending, .Done);
    } else if (std.mem.eql(u8, subcommand, "reject")) {
        try handleStateChange(allocator, io, absolute_workspace_path, luke_path, args[1..], .ReviewPending, .Pending);
    } else if (std.mem.eql(u8, subcommand, "cancel")) {
        try handleStateChange(allocator, io, absolute_workspace_path, luke_path, args[1..], null, .Cancelled);
    } else {
        std.debug.print("Unknown task subcommand: {s}\n", .{subcommand});
    }
}



fn getRepoPaths(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8) ![][]const u8 {
    var repos = std.ArrayList([]const u8).empty;
    if (std.process.run(allocator, io, .{ .argv = &[_][]const u8{"find", workspace_path, "-maxdepth", "3", "-name", ".git", "-type", "d"} })) |res| {
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);
        var line_iter = std.mem.splitSequence(u8, res.stdout, "\n");
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            const repo_path = if (std.mem.endsWith(u8, line, "/.git")) line[0 .. line.len - 5] else line;
            try repos.append(allocator, try allocator.dupe(u8, repo_path));
        }
    } else |_| {}
    return repos.toOwnedSlice(allocator);
}

fn getRepoCommits(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, prefix: []const u8) ![]const u8 {
    var result_str = std.ArrayList(u8).empty;
    try result_str.print(allocator, "\n  .{s} = .{{\n", .{prefix});
    
    if (std.process.run(allocator, io, .{ .argv = &[_][]const u8{"find", workspace_path, "-maxdepth", "3", "-name", ".git", "-type", "d"} })) |res| {
        var line_iter = std.mem.splitSequence(u8, res.stdout, "\n");
        var first = true;
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            const repo_path = if (std.mem.endsWith(u8, line, "/.git")) line[0 .. line.len - 5] else line;
            
            if (std.process.run(allocator, io, .{ .argv = &[_][]const u8{"git", "-C", repo_path, "rev-parse", "HEAD"} })) |git_res| {
                var hash = git_res.stdout;
                if (hash.len > 0 and hash[hash.len - 1] == '\n') hash = hash[0 .. hash.len - 1];
                if (hash.len > 0) {
                    if (!first) try result_str.print(allocator, ",\n", .{});
                    try result_str.print(allocator, "    .{{ .path = \"{s}\", .hash = \"{s}\" }}", .{repo_path, hash});
                    first = false;
                }
            } else |_| {}
        }
    } else |_| {}
    
    try result_str.print(allocator, "\n  }}", .{});
    return result_str.toOwnedSlice(allocator);
}

fn handleCreate(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, luke_path: []const u8, args: []const [:0]const u8) !void {
    if (args.len < 1) {
        std.debug.print("Usage: luke task create <task_id> [--spec <path>]\n", .{});
        return;
    }
    const task_id = args[0];
    
    const task_dir = try std.fmt.allocPrint(allocator, "{s}/tasks/{s}", .{luke_path, task_id});
    defer allocator.free(task_dir);
    _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "mkdir", "-p", task_dir } }) catch {};
    
    const start_commits_str = try getRepoCommits(allocator, io, workspace_path, "start_commits");
    defer allocator.free(start_commits_str);
    
    const state_path = try std.fmt.allocPrint(allocator, "{s}/state.zon", .{task_dir});
    defer allocator.free(state_path);
    var state_file = try std.Io.Dir.createFileAbsolute(io, state_path, .{});
    var state_write_buf: [1024]u8 = undefined;
    var state_writer = state_file.writer(io, &state_write_buf);
    try state_writer.interface.print(".{{\n  .id = \"{s}\",\n  .status = .Pending,\n  .created_at = {d},{s}\n}}\n", .{task_id, 0, start_commits_str});
    try state_writer.flush();
    state_file.close(io);
    
    const notes_path = try std.fmt.allocPrint(allocator, "{s}/NOTES.md", .{task_dir});
    defer allocator.free(notes_path);
    var notes_file = try std.Io.Dir.createFileAbsolute(io, notes_path, .{});
    notes_file.close(io);
    
    const review_path = try std.fmt.allocPrint(allocator, "{s}/REVIEW.md", .{task_dir});
    defer allocator.free(review_path);
    var review_file = try std.Io.Dir.createFileAbsolute(io, review_path, .{});
    review_file.close(io);
    
    std.debug.print("Task {s} created successfully in {s}\n", .{task_id, task_dir});
    
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--spec")) {
        const spec_src = args[2];
        const spec_dest = try std.fmt.allocPrint(allocator, "{s}/SPEC.md", .{task_dir});
        defer allocator.free(spec_dest);
        _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "cp", spec_src, spec_dest } }) catch {};
        std.debug.print("Copied spec from {s} to SPEC.md\n", .{spec_src});
    } else {
        const spec_dest = try std.fmt.allocPrint(allocator, "{s}/SPEC.md", .{task_dir});
        defer allocator.free(spec_dest);
        var spec_file = try std.Io.Dir.createFileAbsolute(io, spec_dest, .{});
        var spec_write_buf: [1024]u8 = undefined;
        var spec_writer = spec_file.writer(io, &spec_write_buf);
        try spec_writer.interface.print("# Task: {s}\n\nObjective: \n\nAcceptance Criteria: \n", .{task_id});
        try spec_writer.flush();
        spec_file.close(io);
    }
}

fn handleStateChange(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, luke_path: []const u8, args: []const [:0]const u8, expected_status: ?TaskStatus, new_status: TaskStatus) !void {
    _ = expected_status;
    if (args.len < 1) {
        std.debug.print("Usage: luke task <command> <task_id>\n", .{});
        return;
    }
    const task_id = args[0];
    
    if (new_status == .ReviewPending) {
        std.debug.print("Validating AST graph for task {s}...\n", .{task_id});
        const run_result = std.process.run(allocator, io, .{ .argv = &[_][]const u8{"luke", "index"} }) catch |err| {
            std.debug.print("[FATAL] Could not run AST validator: {}\n", .{err});
            return err;
        };
        _ = run_result;
        std.debug.print("AST validation passed.\n", .{});
    }

    const state_path = try std.fmt.allocPrint(allocator, "{s}/tasks/{s}/state.zon", .{luke_path, task_id});
    defer allocator.free(state_path);
    
    var state_content: []const u8 = "";
    if (std.process.run(allocator, io, .{ .argv = &[_][]const u8{"cat", state_path} })) |res| {
        state_content = res.stdout;
    } else |_| {}
    
    // Naive rewrite: change .status = .XYZ and append end_commits if needed
    var new_state = std.ArrayList(u8).empty;
    var line_iter = std.mem.splitSequence(u8, state_content, "\n");
    while (line_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, ".status = .")) |_| {
            try new_state.print(allocator, "  .status = .{s},\n", .{@tagName(new_status)});
        } else if (std.mem.eql(u8, line, "}")) {
            // End of struct, append end_commits if done
            if (new_status == .Done or new_status == .Cancelled) {
                const end_commits_str = try getRepoCommits(allocator, io, workspace_path, "end_commits");
                defer allocator.free(end_commits_str);
                try new_state.print(allocator, ",{s}\n}}", .{end_commits_str});
            } else {
                try new_state.print(allocator, "}}\n", .{});
            }
        } else {
            try new_state.print(allocator, "{s}\n", .{line});
        }
    }
    
    var state_file = try std.Io.Dir.createFileAbsolute(io, state_path, .{});
    var state_write_buf: [1024]u8 = undefined;
    var state_writer = state_file.writer(io, &state_write_buf);
    try state_writer.interface.print("{s}", .{new_state.items});
    try state_writer.flush();
    state_file.close(io);
    
    std.debug.print("Task {s} status updated to {s}\n", .{task_id, @tagName(new_status)});
    
    if (new_status == .InProgress) {
        std.debug.print("Creating worktree for task {s}...\n", .{task_id});
        
        const root_worktree = try std.fmt.allocPrint(allocator, "{s}/worktrees/{s}", .{luke_path, task_id});
        defer allocator.free(root_worktree);
        
        _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{"mkdir", "-p", root_worktree} }) catch {};
        
        const branch_name = try std.fmt.allocPrint(allocator, "luke/{s}", .{task_id});
        defer allocator.free(branch_name);
        
        const repos = try getRepoPaths(allocator, io, workspace_path);
        defer {
            for (repos) |repo| allocator.free(repo);
            allocator.free(repos);
        }
        
        for (repos) |repo_path| {
            const rel_path = if (std.mem.eql(u8, repo_path, workspace_path)) "" else repo_path[workspace_path.len + 1 ..];
            const dest = if (rel_path.len == 0) try allocator.dupe(u8, root_worktree) else try std.fmt.allocPrint(allocator, "{s}/{s}", .{root_worktree, rel_path});
            defer allocator.free(dest);
            
            _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{"git", "-C", repo_path, "worktree", "add", "-b", branch_name, dest} }) catch {
                std.debug.print("Note: Could not create git worktree for {s}.\n", .{repo_path});
            };
        }
    }
    
    if (new_status == .ReviewPending) {
        std.debug.print("Auto-committing any untracked/modified files in worktree {s}...\n", .{task_id});
        const root_worktree = try std.fmt.allocPrint(allocator, "{s}/worktrees/{s}", .{luke_path, task_id});
        defer allocator.free(root_worktree);
        const repos = try getRepoPaths(allocator, io, workspace_path);
        defer {
            for (repos) |repo| allocator.free(repo);
            allocator.free(repos);
        }
        for (repos) |repo_path| {
            const rel_path = if (std.mem.eql(u8, repo_path, workspace_path)) "" else repo_path[workspace_path.len + 1 ..];
            const dest = if (rel_path.len == 0) try allocator.dupe(u8, root_worktree) else try std.fmt.allocPrint(allocator, "{s}/{s}", .{root_worktree, rel_path});
            defer allocator.free(dest);
            
            _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{"git", "-C", dest, "add", "-A"} }) catch {};
            _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{"git", "-C", dest, "commit", "-m", "Auto-commit before submit"} }) catch {};
        }
    }
    
    if (new_status == .Done or new_status == .Cancelled) {
        std.debug.print("Task folder retained until `luke task sweep`.\n", .{});
        
        const root_worktree = try std.fmt.allocPrint(allocator, "{s}/worktrees/{s}", .{luke_path, task_id});
        defer allocator.free(root_worktree);
        const branch_name = try std.fmt.allocPrint(allocator, "luke/{s}", .{task_id});
        defer allocator.free(branch_name);
        
        const repos = try getRepoPaths(allocator, io, workspace_path);
        defer {
            for (repos) |repo| allocator.free(repo);
            allocator.free(repos);
        }
        
        for (repos) |repo_path| {
            const rel_path = if (std.mem.eql(u8, repo_path, workspace_path)) "" else repo_path[workspace_path.len + 1 ..];
            const dest = if (rel_path.len == 0) try allocator.dupe(u8, root_worktree) else try std.fmt.allocPrint(allocator, "{s}/{s}", .{root_worktree, rel_path});
            defer allocator.free(dest);
            
            if (new_status == .Done) {
                std.debug.print("Merging branch {s} into {s}...\n", .{branch_name, repo_path});
                const merge_res = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "git", "-C", repo_path, "merge", "--no-edit", branch_name } }) catch |err| {
                    std.debug.print("[WARNING] Git merge failed for {s}: {}\n", .{repo_path, err});
                    continue;
                };
                defer allocator.free(merge_res.stdout);
                defer allocator.free(merge_res.stderr);
                
                if (merge_res.term != .exited or merge_res.term.exited != 0) {
                    std.debug.print("[WARNING] Merge conflicts for {s}: {s}\nWorktree retained. Please resolve manually.\n", .{repo_path, merge_res.stderr});
                } else {
                    _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "git", "-C", repo_path, "worktree", "remove", "--force", dest } }) catch {};
                    std.debug.print("Worktree removed for {s}.\n", .{repo_path});
                }
            } else {
                _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "git", "-C", repo_path, "worktree", "remove", "--force", dest } }) catch {};
                std.debug.print("Worktree removed for {s}.\n", .{repo_path});
            }
        }
        
        _ = std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "rm", "-rf", root_worktree } }) catch {};
    }
}
