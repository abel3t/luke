const std = @import("std");

pub fn run(allocator: std.mem.Allocator, io: std.Io, workspace_path: []const u8, home_dir: []const u8, args: []const [:0]const u8) !void {
    _ = home_dir;
    _ = args;

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

    const luke_path = try std.fmt.allocPrint(allocator, "{s}/.luke", .{absolute_workspace_path});
    defer allocator.free(luke_path);

    // 1. Check if workspace is initialized
    var luke_dir = std.Io.Dir.openDirAbsolute(io, luke_path, .{}) catch {
        std.debug.print("Error: Not a LUKE workspace. No BRAIN.md found.\n", .{});
        return;
    };
    defer luke_dir.close(io);

    // 2. Check for BRAIN.md at workspace root
    const brain_path = try std.fmt.allocPrint(allocator, "{s}/BRAIN.md", .{absolute_workspace_path});
    defer allocator.free(brain_path);
    
    var has_brain = false;
    if (std.Io.Dir.openFileAbsolute(io, brain_path, .{})) |*f| {
        has_brain = true;
        f.close(io);
    } else |_| {}

    // 3. Check for workspace.lock
    const lock_path = try std.fmt.allocPrint(allocator, "{s}/workspace.lock", .{luke_path});
    defer allocator.free(lock_path);
    
    var is_locked = false;
    if (std.Io.Dir.openFileAbsolute(io, lock_path, .{})) |*f| {
        is_locked = true;
        f.close(io);
    } else |_| {}

    // Find the active task if locked, or any pending tasks
    const tasks_path = try std.fmt.allocPrint(allocator, "{s}/tasks", .{luke_path});
    defer allocator.free(tasks_path);

    var active_task_id: ?[]const u8 = null;
    var active_status: []const u8 = "Unknown";
    
    if (std.Io.Dir.openDirAbsolute(io, tasks_path, .{})) |*tasks_dir_ptr| {
        var tasks_dir = tasks_dir_ptr.*;
        defer tasks_dir.close(io);
        
        // We cheat a bit with run command to find the task since std.fs.Dir.iterate is not easily available in std.Io yet
        if (std.process.run(allocator, io, .{ .argv = &[_][]const u8{"ls", "-1", tasks_path} })) |res| {
            var line_iter = std.mem.splitSequence(u8, res.stdout, "\n");
            while (line_iter.next()) |task_id| {
                if (task_id.len == 0) continue;
                
                const state_path = try std.fmt.allocPrint(allocator, "{s}/{s}/state.zon", .{tasks_path, task_id});
                defer allocator.free(state_path);
                
                if (std.process.run(allocator, io, .{ .argv = &[_][]const u8{"cat", state_path} })) |cat_res| {
                    if (std.mem.indexOf(u8, cat_res.stdout, ".status = .InProgress")) |_| {
                        active_task_id = try allocator.dupe(u8, task_id);
                        active_status = "InProgress";
                    } else if (std.mem.indexOf(u8, cat_res.stdout, ".status = .ReviewPending")) |_| {
                        active_task_id = try allocator.dupe(u8, task_id);
                        active_status = "ReviewPending";
                    }
                } else |_| {}
            }
        } else |_| {}
    } else |_| {}

    std.debug.print("Workspace: {s}. Brain: {s}. State: ", .{
        if (is_locked) "Locked" else "Active",
        if (has_brain) "Loaded" else "Missing"
    });

    if (active_task_id) |tid| {
        std.debug.print("Active Task: {s} (Status: {s}).\n", .{tid, active_status});
    } else {
        std.debug.print("Idle.\n", .{});
    }
}
