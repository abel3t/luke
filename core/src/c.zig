const std = @import("std");

pub const TSNode = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const anyopaque,
};

pub const TSPoint = extern struct {
    row: u32,
    column: u32,
};

pub const TSQueryError = enum(c_int) {
    None = 0,
    Syntax,
    NodeType,
    Field,
    Capture,
    Structure,
    Language,
};

pub const TSQueryCapture = extern struct {
    node: TSNode,
    index: u32,
};

pub const TSQueryMatch = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: [*c]const TSQueryCapture,
};

pub const TSLanguage = opaque {};
pub const TSParser = opaque {};
pub const TSTree = opaque {};
pub const TSQuery = opaque {};
pub const TSQueryCursor = opaque {};

pub extern "c" fn ts_parser_new() ?*TSParser;
pub extern "c" fn ts_parser_delete(parser: ?*TSParser) void;
pub extern "c" fn ts_parser_set_language(self: ?*TSParser, language: ?*const TSLanguage) bool;
pub extern "c" fn ts_parser_parse_string(
    self: ?*TSParser,
    old_tree: ?*const TSTree,
    string: [*c]const u8,
    length: u32,
) ?*TSTree;

pub extern "c" fn ts_tree_delete(tree: ?*TSTree) void;
pub extern "c" fn ts_tree_root_node(tree: ?*TSTree) TSNode;
pub extern "c" fn ts_node_string(node: TSNode) [*c]u8;
pub extern "c" fn ts_node_start_byte(node: TSNode) u32;
pub extern "c" fn ts_node_end_byte(node: TSNode) u32;
pub extern "c" fn ts_node_start_point(node: TSNode) TSPoint;
pub extern "c" fn ts_node_end_point(node: TSNode) TSPoint;

pub extern "c" fn ts_query_new(
    language: ?*const TSLanguage,
    source: [*c]const u8,
    source_len: u32,
    error_offset: [*c]u32,
    error_type: [*c]TSQueryError,
) ?*TSQuery;

pub extern "c" fn ts_query_delete(query: ?*TSQuery) void;
pub extern "c" fn ts_query_cursor_new() ?*TSQueryCursor;
pub extern "c" fn ts_query_cursor_delete(cursor: ?*TSQueryCursor) void;
pub extern "c" fn ts_query_cursor_exec(cursor: ?*TSQueryCursor, query: ?*const TSQuery, node: TSNode) void;
pub extern "c" fn ts_query_cursor_next_match(cursor: ?*TSQueryCursor, match: [*c]TSQueryMatch) bool;
pub extern "c" fn ts_query_capture_name_for_id(query: ?*const TSQuery, id: u32, length: [*c]u32) [*c]const u8;

// Core Parsers
pub extern "c" fn tree_sitter_typescript() ?*const TSLanguage;
pub extern "c" fn tree_sitter_tsx() ?*const TSLanguage;
pub extern "c" fn tree_sitter_go() ?*const TSLanguage;
