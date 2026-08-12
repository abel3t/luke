const std = @import("std");
const c = @import("c.zig");
const graph = @import("graph.zig");

pub const AstEngine = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    parser: *c.TSParser,
    ts_language: *const c.TSLanguage,
    tsx_language: *const c.TSLanguage,
    go_language: *const c.TSLanguage,
    ts_query: *c.TSQuery,
    tsx_query: *c.TSQuery,
    go_query: *c.TSQuery,
    query_cursor: *c.TSQueryCursor,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !AstEngine {
        const parser = c.ts_parser_new() orelse return error.TSParserInitFailed;

        const ts_language = c.tree_sitter_typescript().?;
        const tsx_language = c.tree_sitter_tsx().?;
        const go_language = c.tree_sitter_go().?;

        const query_src = @embedFile("queries/typescript-tags.scm");
        const go_query_src = @embedFile("queries/go-tags.scm");

        var error_offset: u32 = 0;
        var error_type: c.TSQueryError = .None;

        const ts_query = c.ts_query_new(ts_language, query_src.ptr, @intCast(query_src.len), &error_offset, &error_type) orelse return error.TSQueryCompilationFailed;
        const tsx_query = c.ts_query_new(tsx_language, query_src.ptr, @intCast(query_src.len), &error_offset, &error_type) orelse return error.TSXQueryCompilationFailed;
        const go_query = c.ts_query_new(go_language, go_query_src.ptr, @intCast(go_query_src.len), &error_offset, &error_type) orelse return error.GoQueryCompilationFailed;

        const query_cursor = c.ts_query_cursor_new() orelse return error.TSQueryCursorInitFailed;

        return AstEngine{
            .allocator = allocator,
            .io = io,
            .parser = parser,
            .ts_language = ts_language,
            .tsx_language = tsx_language,
            .go_language = go_language,
            .ts_query = ts_query,
            .tsx_query = tsx_query,
            .go_query = go_query,
            .query_cursor = query_cursor,
        };
    }

    pub fn deinit(self: *AstEngine) void {
        c.ts_query_cursor_delete(self.query_cursor);
        c.ts_query_delete(self.ts_query);
        c.ts_query_delete(self.tsx_query);
        c.ts_query_delete(self.go_query);
        c.ts_parser_delete(self.parser);
    }

    pub fn extractKnowledge(self: *AstEngine, absolute_workspace_path: []const u8, entry_path: []const u8, entry_basename: []const u8, knowledge_graph: *graph.Graph) !void {
        const is_tsx = std.mem.endsWith(u8, entry_basename, ".tsx");
        const is_go = std.mem.endsWith(u8, entry_basename, ".go");
        
        const lang = if (is_go) self.go_language else if (is_tsx) self.tsx_language else self.ts_language;
        const query = if (is_go) self.go_query else if (is_tsx) self.tsx_query else self.ts_query;
        _ = c.ts_parser_set_language(self.parser, lang);
        
        const limit = @as(std.Io.Limit, @enumFromInt(1024 * 1024));
        // We open the workspace directory to read the file relative to it
        var dir = try std.Io.Dir.openDirAbsolute(self.io, absolute_workspace_path, .{});
        defer dir.close(self.io);
        const content = dir.readFileAlloc(self.io, entry_path, self.allocator, limit) catch return;
        defer self.allocator.free(content);
        
        const tree = c.ts_parser_parse_string(self.parser, null, content.ptr, @intCast(content.len));
        defer c.ts_tree_delete(tree);
        
        // Add File Node to Graph
        const file_id = try std.fmt.allocPrint(self.allocator, "file://{s}", .{entry_path});
        try knowledge_graph.addNode(file_id, .File, entry_basename, entry_path, 0, 0);

        // Execute Query on this file
        const root_node = c.ts_tree_root_node(tree);
        c.ts_query_cursor_exec(self.query_cursor, query, root_node);

        var match: c.TSQueryMatch = undefined;
        while (c.ts_query_cursor_next_match(self.query_cursor, &match)) {
            if (match.capture_count > 0) {
                const capture = match.captures[0];
                var capture_len: u32 = 0;
                const capture_name_ptr = c.ts_query_capture_name_for_id(query, capture.index, &capture_len);
                const capture_name = capture_name_ptr[0..capture_len];
                
                const start = c.ts_node_start_byte(capture.node);
                const end = c.ts_node_end_byte(capture.node);
                if (start < end and end <= content.len) {
                    const node_text = content[start..end];
                    
                    // Convert tree-sitter capture tag to Graph NodeType
                    var n_type = graph.NodeType.Function;
                    if (std.mem.indexOf(u8, capture_name, "class") != null) n_type = .Class;
                    if (std.mem.indexOf(u8, capture_name, "struct") != null) n_type = .Struct;
                    
                    if (node_text.len < 150) {
                        const start_point = c.ts_node_start_point(capture.node);
                        const end_point = c.ts_node_end_point(capture.node);
                        
                        const node_id = try std.fmt.allocPrint(self.allocator, "node://{s}/{s}", .{entry_path, node_text});
                        try knowledge_graph.addNode(node_id, n_type, node_text, entry_path, start_point.row + 1, end_point.row + 1);
                        try knowledge_graph.addEdge(node_id, file_id, .Defines);
                        self.allocator.free(node_id);
                    }
                }
            }
        }
        self.allocator.free(file_id);
    }
};
