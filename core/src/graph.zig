const std = @import("std");

pub const NodeType = enum {
    File,
    Function,
    Struct,
    Class,
};

pub const RelationType = enum {
    Imports,
    Calls,
    Defines,
};

pub const Node = struct {
    id: []const u8,
    type: NodeType,
    name: []const u8,
    file_path: []const u8,
    start_line: u32,
    end_line: u32,
};

pub const Edge = struct {
    source_id: []const u8,
    target_id: []const u8,
    relation: RelationType,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node),
    edges: std.ArrayList(Edge),

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(Node).empty,
            .edges = std.ArrayList(Edge).empty,
        };
    }

    pub fn deinit(self: *Graph) void {
        for (self.nodes.items) |node| {
            self.allocator.free(node.id);
            self.allocator.free(node.name);
            self.allocator.free(node.file_path);
        }
        self.nodes.deinit(self.allocator);

        for (self.edges.items) |edge| {
            self.allocator.free(edge.source_id);
            self.allocator.free(edge.target_id);
        }
        self.edges.deinit(self.allocator);
    }

    pub fn addNode(self: *Graph, id: []const u8, node_type: NodeType, name: []const u8, file_path: []const u8, start_line: u32, end_line: u32) !void {
        try self.nodes.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, id),
            .type = node_type,
            .name = try self.allocator.dupe(u8, name),
            .file_path = try self.allocator.dupe(u8, file_path),
            .start_line = start_line,
            .end_line = end_line,
        });
    }

    pub fn addEdge(self: *Graph, source_id: []const u8, target_id: []const u8, relation: RelationType) !void {
        try self.edges.append(self.allocator, .{
            .source_id = try self.allocator.dupe(u8, source_id),
            .target_id = try self.allocator.dupe(u8, target_id),
            .relation = relation,
        });
    }

    pub fn writeZon(self: *Graph, writer: anytype) !void {
        try writer.print(".{{\n", .{});
        try writer.print("  .nodes = .{{\n", .{});
        for (self.nodes.items) |node| {
            try writer.print("    .{{\n", .{});
            try writer.print("      .id = \"{s}\",\n", .{node.id});
            try writer.print("      .type = .{s},\n", .{@tagName(node.type)});
            try writer.print("      .name = \"{s}\",\n", .{node.name});
            try writer.print("      .file_path = \"{s}\",\n", .{node.file_path});
            try writer.print("      .start_line = {d},\n", .{node.start_line});
            try writer.print("      .end_line = {d},\n", .{node.end_line});
            try writer.print("    }},\n", .{});
        }
        try writer.print("  }},\n", .{});
        
        try writer.print("  .edges = .{{\n", .{});
        for (self.edges.items) |edge| {
            try writer.print("    .{{\n", .{});
            try writer.print("      .source_id = \"{s}\",\n", .{edge.source_id});
            try writer.print("      .target_id = \"{s}\",\n", .{edge.target_id});
            try writer.print("      .relation = .{s},\n", .{@tagName(edge.relation)});
            try writer.print("    }},\n", .{});
        }
        try writer.print("  }},\n", .{});
        try writer.print("}}\n", .{});
    }

    pub fn loadZon(self: *Graph, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        
        var current_id: ?[]const u8 = null;
        var current_type: ?NodeType = null;
        var current_name: ?[]const u8 = null;
        var current_file_path: ?[]const u8 = null;
        var current_start_line: ?u32 = null;
        var current_end_line: ?u32 = null;
        
        var current_source_id: ?[]const u8 = null;
        var current_target_id: ?[]const u8 = null;
        var current_relation: ?RelationType = null;
        
        var in_nodes = false;
        var in_edges = false;

        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r\t");
            if (line.len == 0) continue;

            if (std.mem.eql(u8, line, ".nodes = .{")) {
                in_nodes = true;
                in_edges = false;
                continue;
            } else if (std.mem.eql(u8, line, ".edges = .{")) {
                in_nodes = false;
                in_edges = true;
                continue;
            }

            if (std.mem.eql(u8, line, "},") or std.mem.eql(u8, line, "}") or std.mem.eql(u8, line, "},")) {
                if (in_nodes and current_id != null and current_name != null and current_file_path != null) {
                    try self.addNode(current_id.?, current_type orelse .File, current_name.?, current_file_path.?, current_start_line orelse 0, current_end_line orelse 0);
                    current_id = null;
                    current_type = null;
                    current_name = null;
                    current_file_path = null;
                    current_start_line = null;
                    current_end_line = null;
                } else if (in_edges and current_source_id != null and current_target_id != null) {
                    try self.addEdge(current_source_id.?, current_target_id.?, current_relation orelse .Imports);
                    current_source_id = null;
                    current_target_id = null;
                    current_relation = null;
                }
                continue;
            }

            if (in_nodes) {
                if (std.mem.startsWith(u8, line, ".id = \"")) {
                    const val = line[7..line.len - 2];
                    current_id = val;
                } else if (std.mem.startsWith(u8, line, ".type = .")) {
                    const val = line[9..line.len - 1];
                    if (std.mem.eql(u8, val, "File")) current_type = .File;
                    if (std.mem.eql(u8, val, "Function")) current_type = .Function;
                    if (std.mem.eql(u8, val, "Struct")) current_type = .Struct;
                    if (std.mem.eql(u8, val, "Class")) current_type = .Class;
                } else if (std.mem.startsWith(u8, line, ".name = \"")) {
                    const val = line[9..line.len - 2];
                    current_name = val;
                } else if (std.mem.startsWith(u8, line, ".file_path = \"")) {
                    const val = line[14..line.len - 2];
                    current_file_path = val;
                } else if (std.mem.startsWith(u8, line, ".start_line = ")) {
                    const val = line[14..line.len - 1];
                    current_start_line = std.fmt.parseInt(u32, val, 10) catch 0;
                } else if (std.mem.startsWith(u8, line, ".end_line = ")) {
                    const val = line[12..line.len - 1];
                    current_end_line = std.fmt.parseInt(u32, val, 10) catch 0;
                }
            } else if (in_edges) {
                if (std.mem.startsWith(u8, line, ".source_id = \"")) {
                    const val = line[14..line.len - 2];
                    current_source_id = val;
                } else if (std.mem.startsWith(u8, line, ".target_id = \"")) {
                    const val = line[14..line.len - 2];
                    current_target_id = val;
                } else if (std.mem.startsWith(u8, line, ".relation = .")) {
                    const val = line[13..line.len - 1];
                    if (std.mem.eql(u8, val, "Imports")) current_relation = .Imports;
                    if (std.mem.eql(u8, val, "Calls")) current_relation = .Calls;
                    if (std.mem.eql(u8, val, "Defines")) current_relation = .Defines;
                }
            }
        }
    }

    pub fn query(self: *Graph, target: []const u8) !void {
        var found_nodes = std.ArrayList(*Node).empty;
        defer found_nodes.deinit(self.allocator);

        for (self.nodes.items) |*node| {
            if (std.mem.indexOf(u8, node.name, target) != null or std.mem.indexOf(u8, node.file_path, target) != null) {
                try found_nodes.append(self.allocator, node);
            }
        }

        if (found_nodes.items.len == 0) {
            std.debug.print("No nodes found matching: {s}\n", .{target});
            return;
        }

        for (found_nodes.items) |node| {
            std.debug.print("\n[NODE] {s} ({s}) -> {s}\n", .{node.name, @tagName(node.type), node.file_path});

            // Find dependents (what imports/calls this node)
            for (self.edges.items) |edge| {
                if (std.mem.eql(u8, edge.target_id, node.id)) {
                    // find the source node
                    for (self.nodes.items) |*source_node| {
                        if (std.mem.eql(u8, source_node.id, edge.source_id)) {
                            std.debug.print("  [USED_BY] {s} -> {s}\n", .{@tagName(edge.relation), source_node.file_path});
                        }
                    }
                }
            }
            
            // Find dependencies (what this node imports/calls)
            for (self.edges.items) |edge| {
                if (std.mem.eql(u8, edge.source_id, node.id)) {
                    for (self.nodes.items) |*target_node| {
                        if (std.mem.eql(u8, target_node.id, edge.target_id)) {
                            std.debug.print("  [USES] {s} -> {s}\n", .{@tagName(edge.relation), target_node.file_path});
                        }
                    }
                }
            }
        }
    }
};
