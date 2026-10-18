//! Hjson decoder. Port of hjson_decode.cpp.
//!
//! Like the C++ original this is an explicit state machine (no recursion), so
//! deeply nested documents cannot overflow the stack.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const number = @import("number.zig");
const DecoderOptions = @import("options.zig").DecoderOptions;

pub const Error = error{SyntaxError} || Allocator.Error;

/// Receives the human readable message of a `error.SyntaxError`.
pub const Diagnostic = struct {
    message: []const u8 = "",

    pub fn deinit(self: *Diagnostic, gpa: Allocator) void {
        if (self.message.len != 0) gpa.free(self.message);
        self.message = "";
    }
};

/// A decoded document. Everything in `value` lives in `arena`; call
/// `deinit()` to free it all at once.
pub const Parsed = struct {
    arena: *std.heap.ArenaAllocator,
    gpa: Allocator,
    value: Value,

    /// The arena allocator that owns the tree. Use it to build onto or clone
    /// from the tree.
    pub fn allocator(self: Parsed) Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: Parsed) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }
};

const ParseState = enum {
    value_begin,
    value_end,
    vector_begin,
    vector_elem_end,
    map_begin,
    map_elem_begin,
    map_elem_end,
};

const CommentInfo = struct {
    has_comment: bool = false,
    // cm_start is the first char of the comment, cm_end is the first char
    // after the comment.
    cm_start: usize = 0,
    cm_end: usize = 0,
};

const DecodeParent = struct {
    val: Value = .{},
    ci_before: CommentInfo = .{},
    ci_key: CommentInfo = .{},
    ci_elem_before: CommentInfo = .{},
    ci_elem_extra: CommentInfo = .{},
    key: []const u8 = "",
};

const Parser = struct {
    gpa: Allocator, // temporary buffers
    a: Allocator, // the arena that owns the result
    data: []const u8,
    index_next: usize = 0,
    ch: u8 = ' ',
    without_braces: bool = false,
    opt: DecoderOptions,
    v_state: std.ArrayList(ParseState) = .empty,
    v_parent: std.ArrayList(DecodeParent) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    err: std.ArrayList(u8) = .empty,

    fn deinit(p: *Parser) void {
        p.v_state.deinit(p.gpa);
        p.v_parent.deinit(p.gpa);
        p.scratch.deinit(p.gpa);
        p.err.deinit(p.gpa);
    }

    // get the next character.
    fn next(p: *Parser) bool {
        if (p.index_next < p.data.len) {
            p.ch = p.data[p.index_next];
            p.index_next += 1;
            return true;
        }
        p.index_next += 1;
        p.ch = 0;
        return false;
    }

    fn peek(p: *const Parser, offs: isize) u8 {
        const pos = @as(isize, @intCast(p.index_next)) + offs;
        if (pos >= 0 and pos < @as(isize, @intCast(p.data.len))) {
            return p.data[@intCast(pos)];
        }
        return 0;
    }

    fn top(p: *Parser) *DecodeParent {
        return &p.v_parent.items[p.v_parent.items.len - 1];
    }

    fn topState(p: *Parser) *ParseState {
        return &p.v_state.items[p.v_state.items.len - 1];
    }

    fn popState(p: *Parser) void {
        p.v_state.shrinkRetainingCapacity(p.v_state.items.len - 1);
    }

    fn popParent(p: *Parser) DecodeParent {
        const last = p.v_parent.items[p.v_parent.items.len - 1];
        p.v_parent.shrinkRetainingCapacity(p.v_parent.items.len - 1);
        return last;
    }

    // Slice of the input, clamped to the input bounds.
    fn text(p: *const Parser, start: usize, end: usize) []const u8 {
        const e = @min(end, p.data.len);
        const s = @min(start, e);
        return p.data[s..e];
    }

    /// Builds the error message (message + " at line L,C >>> sample") and
    /// returns the error to propagate.
    fn fail(p: *Parser, parts: []const []const u8) Error {
        p.err.clearRetainingCapacity();
        p.buildMessage(parts) catch return error.OutOfMemory;
        return error.SyntaxError;
    }

    fn buildMessage(p: *Parser, parts: []const []const u8) Allocator.Error!void {
        for (parts) |s| {
            try p.err.appendSlice(p.gpa, s);
        }

        const n = p.data.len;
        if (n != 0 and p.index_next <= n) {
            const decoder_index = @max(@as(usize, 1), @min(n, p.index_next)) - 1;
            var i = decoder_index;
            var col: usize = 0;
            var line: usize = 1;

            while (i > 0 and p.data[i] != '\n') : (i -= 1) {
                col += 1;
            }
            while (i > 0) : (i -= 1) {
                if (p.data[i] == '\n') line += 1;
            }

            const start = decoder_index - col;
            const sam_end = @min(@as(usize, 20), n - start);

            try p.err.appendSlice(p.gpa, " at line ");
            try number.appendUsize(&p.err, p.gpa, line);
            try p.err.append(p.gpa, ',');
            try number.appendUsize(&p.err, p.gpa, col);
            try p.err.appendSlice(p.gpa, " >>> ");
            try p.err.appendSlice(p.gpa, p.data[start .. start + sam_end]);
        }
    }
};

fn resetAt(p: *Parser) void {
    p.index_next = 0;
    _ = p.next();
}

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= 0x09 and c <= 0x0d);
}

fn isPunctuatorChar(c: u8) bool {
    return c == '{' or c == '}' or c == '[' or c == ']' or c == ',' or c == ':';
}

fn escapee(c: u8) u8 {
    return switch (c) {
        '"', '\'', '\\', '/' => c,
        'b' => 0x08,
        'f' => 0x0c,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        else => 0,
    };
}

fn concat(a: Allocator, x: []const u8, y: []const u8) Allocator.Error![]const u8 {
    const out = try a.alloc(u8, x.len + y.len);
    @memcpy(out[0..x.len], x);
    @memcpy(out[x.len..], y);
    return out;
}

fn cmText(p: *Parser, ci: CommentInfo) Allocator.Error![]const u8 {
    return p.a.dupe(u8, p.text(ci.cm_start, ci.cm_end));
}

fn setComment1(p: *Parser, val: *Value, comptime field: []const u8, ci: CommentInfo) Allocator.Error!void {
    if (ci.has_comment) {
        @field(val.comments, field) = try cmText(p, ci);
    }
}

fn setComment2(
    p: *Parser,
    val: *Value,
    comptime field: []const u8,
    ci_a: CommentInfo,
    ci_b: CommentInfo,
) Allocator.Error!void {
    if (ci_a.has_comment and ci_b.has_comment) {
        @field(val.comments, field) = try concat(p.a, p.text(ci_a.cm_start, ci_a.cm_end), p.text(ci_b.cm_start, ci_b.cm_end));
    } else if (!ci_a.has_comment and !ci_b.has_comment) {
        @field(val.comments, field) = "";
    } else {
        try setComment1(p, val, field, ci_a);
        try setComment1(p, val, field, ci_b);
    }
}

fn toUtf8(list: *std.ArrayList(u8), gpa: Allocator, u: u32) Allocator.Error!void {
    if (u < 0x80) {
        try list.append(gpa, @intCast(u));
    } else if (u < 0x800) {
        try list.append(gpa, @intCast(0xc0 | ((u >> 6) & 0x1f)));
        try list.append(gpa, @intCast(0x80 | (u & 0x3f)));
    } else if (u < 0x10000) {
        try list.append(gpa, @intCast(0xe0 | ((u >> 12) & 0xf)));
        try list.append(gpa, @intCast(0x80 | ((u >> 6) & 0x3f)));
        try list.append(gpa, @intCast(0x80 | (u & 0x3f)));
    } else {
        try list.append(gpa, @intCast(0xf0 | ((u >> 18) & 0x7)));
        try list.append(gpa, @intCast(0x80 | ((u >> 12) & 0x3f)));
        try list.append(gpa, @intCast(0x80 | ((u >> 6) & 0x3f)));
        try list.append(gpa, @intCast(0x80 | (u & 0x3f)));
    }
}

fn skipIndent(p: *Parser, indent: isize) void {
    var skip = indent;
    while (p.ch > 0 and p.ch <= ' ' and p.ch != '\n' and skip > 0) {
        skip -= 1;
        _ = p.next();
    }
}

// Parse a multiline string value.
fn readMLString(p: *Parser) Error![]const u8 {
    p.scratch.clearRetainingCapacity();
    var triple: u8 = 0;

    // we are at ''' +1 - get indent
    var indent: isize = 0;
    while (true) {
        const c = p.peek(-indent - 5);
        if (c == 0 or c == '\n') break;
        indent += 1;
    }

    // skip white/to (newline)
    while (p.ch > 0 and p.ch <= ' ' and p.ch != '\n') {
        _ = p.next();
    }
    if (p.ch == '\n') {
        _ = p.next();
        skipIndent(p, indent);
    }

    // When parsing multiline string values, we must look for ' characters.
    var last_lf = false;
    while (true) {
        if (p.ch == 0) {
            return p.fail(&.{"Bad multiline string"});
        } else if (p.ch == '\'') {
            triple += 1;
            _ = p.next();
            if (triple == 3) {
                var s: []const u8 = p.scratch.items;
                if (last_lf) {
                    s = s[0 .. s.len - 1]; // remove last EOL
                }
                return p.a.dupe(u8, s);
            }
            continue;
        } else {
            while (triple > 0) {
                try p.scratch.append(p.gpa, '\'');
                triple -= 1;
                last_lf = false;
            }
        }
        if (p.ch == '\n') {
            try p.scratch.append(p.gpa, '\n');
            last_lf = true;
            _ = p.next();
            skipIndent(p, indent);
        } else {
            if (p.ch != '\r') {
                try p.scratch.append(p.gpa, p.ch);
                last_lf = false;
            }
            _ = p.next();
        }
    }
}

// Parse a string value.
// callers make sure that (ch === '"' || ch === "'")
// When parsing for string values, we must look for " and \ characters.
fn readString(p: *Parser, allow_ml: bool) Error![]const u8 {
    // The result is built in a scratch buffer, because its length may differ
    // from the length in the input data.
    p.scratch.clearRetainingCapacity();

    const exit_ch = p.ch;
    while (p.next()) {
        if (p.ch == exit_ch) {
            _ = p.next();
            if (allow_ml and exit_ch == '\'' and p.ch == '\'' and p.scratch.items.len == 0) {
                // ''' indicates a multiline string
                _ = p.next();
                return readMLString(p);
            } else {
                return p.a.dupe(u8, p.scratch.items);
            }
        }
        if (p.ch == '\\') {
            _ = p.next();
            if (p.ch == 'u') {
                var uffff: u32 = 0;
                var i: usize = 0;
                while (i < 4) : (i += 1) {
                    _ = p.next();
                    const hex: u32 = if (p.ch >= '0' and p.ch <= '9')
                        @as(u32, p.ch - '0')
                    else if (p.ch >= 'a' and p.ch <= 'f')
                        @as(u32, p.ch - 'a') + 10
                    else if (p.ch >= 'A' and p.ch <= 'F')
                        @as(u32, p.ch - 'A') + 10
                    else {
                        const c1 = [1]u8{p.ch};
                        return p.fail(&.{ "Bad \\u char ", &c1 });
                    };
                    uffff = uffff * 16 + hex;
                }
                try toUtf8(&p.scratch, p.gpa, uffff);
            } else {
                const ech = escapee(p.ch);
                if (ech != 0) {
                    try p.scratch.append(p.gpa, ech);
                } else {
                    const c1 = [1]u8{p.ch};
                    return p.fail(&.{ "Bad escape \\", &c1 });
                }
            }
        } else if (p.ch == '\n' or p.ch == '\r') {
            return p.fail(&.{"Bad string containing newline"});
        } else {
            try p.scratch.append(p.gpa, p.ch);
        }
    }

    return p.fail(&.{"Bad string"});
}

// quotes for keys are optional in Hjson
// unless they include {}[],: or whitespace.
fn readKeyname(p: *Parser) Error![]const u8 {
    if (p.ch == '"' or p.ch == '\'') {
        return readString(p, false);
    }

    // key_start is the index for the first char of the key.
    const key_start: usize = p.index_next - 1;
    // key_end is the index for the first char after the key.
    var key_end: usize = key_start;
    var first_space: isize = -1;
    while (true) {
        if (p.ch == ':') {
            if (key_end <= key_start) {
                return p.fail(&.{"Found ':' but no key name (for an empty key name use quotes)"});
            } else if (first_space >= 0 and first_space != @as(isize, @intCast(key_end))) {
                p.index_next = @intCast(first_space + 1);
                return p.fail(&.{"Found whitespace in your key name (use quotes to include)"});
            }
            return p.a.dupe(u8, p.text(key_start, key_end));
        } else if (p.ch <= ' ') {
            if (p.ch == 0) {
                return p.fail(&.{"Found EOF while looking for a key name (check your syntax)"});
            }
            if (first_space < 0) {
                first_space = @intCast(p.index_next - 1);
            }
        } else {
            if (isPunctuatorChar(p.ch)) {
                const c1 = [1]u8{p.ch};
                return p.fail(&.{
                    "Found '",                                                                                                                      &c1,
                    "' where a key name was expected (check your syntax or use quotes if the key name includes {}[],: or whitespace)",
                });
            }
            key_end = p.index_next;
        }
        _ = p.next();
    }
}

fn skipComments(p: *Parser, ci: *CommentInfo, stop_at_eol: bool) void {
    while (p.ch > 0) {
        // Skip whitespace (only until EOL when `stop_at_eol`).
        if (stop_at_eol) {
            while (p.ch > 0 and p.ch <= ' ' and p.ch != '\n') {
                _ = p.next();
            }
        } else {
            while (p.ch > 0 and p.ch <= ' ') {
                _ = p.next();
            }
        }
        // Hjson allows comments
        if (p.ch == '#' or (p.ch == '/' and p.peek(0) == '/')) {
            if (p.opt.comments) ci.has_comment = true;
            while (p.ch > 0 and p.ch != '\n') {
                _ = p.next();
            }
        } else if (p.ch == '/' and p.peek(0) == '*') {
            if (p.opt.comments) ci.has_comment = true;
            _ = p.next();
            _ = p.next();
            while (p.ch > 0 and !(p.ch == '*' and p.peek(0) == '/')) {
                _ = p.next();
            }
            if (p.ch > 0) {
                _ = p.next();
                _ = p.next();
            }
        } else {
            break;
        }
    }
}

fn white(p: *Parser) CommentInfo {
    var ci = CommentInfo{ .cm_start = p.index_next - 1 };
    skipComments(p, &ci, false);

    // cm_end is the first char after the comment.
    ci.cm_end = p.index_next - 1;
    ci.has_comment = ci.has_comment or (p.opt.whitespace_as_comments and ci.cm_end > ci.cm_start);
    return ci;
}

fn getCommentAfter(p: *Parser) CommentInfo {
    var ci = CommentInfo{
        .has_comment = p.opt.whitespace_as_comments,
        .cm_start = p.index_next - 1,
    };
    skipComments(p, &ci, true);

    ci.cm_end = p.index_next - 1;
    return ci;
}

// Hjson strings can be quoteless
// returns string, true, false, or null.
fn readTfnns2(p: *Parser, val_end: *usize) Error!Value {
    if (isPunctuatorChar(p.ch)) {
        const c1 = [1]u8{p.ch};
        return p.fail(&.{
            "Found a punctuator character '", &c1,
            "' when expecting a quoteless string (check your syntax)",
        });
    }
    var val_start: usize = p.index_next - 1;

    if (isSpace(p.ch)) {
        val_start += 1;
    } else {
        // val_end is the first char after the value.
        val_end.* = p.index_next;
    }

    while (true) {
        _ = p.next();
        const is_eol = (p.ch == '\r' or p.ch == '\n' or p.ch == 0);
        if (is_eol or
            p.ch == ',' or p.ch == '}' or p.ch == ']' or
            p.ch == '#' or
            (p.ch == '/' and (p.peek(0) == '/' or p.peek(0) == '*')))
        {
            const val_text = p.text(val_start, val_end.*);
            var result: ?Value = null;

            if (val_text.len > 0) {
                switch (val_text[0]) {
                    'f' => {
                        if (std.mem.eql(u8, val_text, "false")) result = Value.initBool(false);
                    },
                    'n' => {
                        if (std.mem.eql(u8, val_text, "null")) result = Value.initNull();
                    },
                    't' => {
                        if (std.mem.eql(u8, val_text, "true")) result = Value.initBool(true);
                    },
                    else => {
                        if (val_text[0] == '-' or (val_text[0] >= '0' and val_text[0] <= '9')) {
                            if (number.tryParse(val_text, false)) |n| {
                                result = Value.fromNumber(n);
                            }
                        }
                    },
                }
            }

            if (result) |r| return r;

            if (is_eol) {
                return Value{ .data = .{ .string = try p.a.dupe(u8, val_text) } };
            }
        }
        if (isSpace(p.ch)) {
            if (val_end.* <= val_start) {
                val_start += 1;
            }
        } else {
            // val_end is the first char after the value.
            val_end.* = p.index_next;
        }
    }
}

fn readTfnns(p: *Parser) Error!Value {
    var val_end: usize = 0;
    const ret = try readTfnns2(p, &val_end);
    // Make sure that we include whitespace after the value in the
    // after-comment.
    p.index_next = val_end;
    _ = p.next();
    return ret;
}

fn pushVec(p: *Parser, elem: Value) Error!void {
    p.top().val.pushBack(p.a, elem) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TypeMismatch => unreachable,
    };
}

fn putMap(p: *Parser, key: []const u8, elem: Value) Error!void {
    p.top().val.putOwnedKey(p.a, key, elem) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TypeMismatch => unreachable,
    };
}

// Parse an array value.
// assuming ch == '['
fn readArrayBegin(p: *Parser) Error!void {
    // Skip '['.
    _ = p.next();
    const ci = white(p);

    const t = p.top();
    t.val = Value.initVector();
    t.ci_elem_before = ci;
    t.ci_elem_extra = .{};

    if (p.ch == ']') {
        try setComment1(p, &t.val, "inside", t.ci_elem_before);
        _ = p.next();
        p.topState().* = .value_end;
    } else {
        p.topState().* = .vector_elem_end;
        try p.v_state.append(p.gpa, .value_begin);
    }
}

fn readArrayElemEnd(p: *Parser) Error!void {
    var elem = p.popParent().val;

    {
        const t = p.top();
        try setComment2(p, &elem, "before", t.ci_elem_before, t.ci_elem_extra);
    }
    const ci_after = white(p);
    // in Hjson the comma is optional and trailing commas are allowed
    if (p.ch == ',') {
        _ = p.next();
        // It is unlikely that someone writes a comment after the value but
        // before the comma, so we include any such comment in "comment_after".
        const ci = white(p);
        p.top().ci_elem_extra = ci;
    } else {
        p.top().ci_elem_extra = .{};
    }
    if (p.ch == ']') {
        const existing_after = elem.comments.after;
        try setComment2(p, &elem, "after", ci_after, p.top().ci_elem_extra);
        if (existing_after.len != 0) {
            elem.comments.after = try concat(p.a, existing_after, elem.comments.after);
        }
        _ = p.next();
        p.topState().* = .value_end;
    } else {
        if (p.ch == 0) {
            return p.fail(&.{"End of input while parsing an array (did you forget a closing ']'?)"});
        }
        p.top().ci_elem_before = ci_after;
        try p.v_state.append(p.gpa, .value_begin);
    }
    try pushVec(p, elem);
}

fn readObjectBegin(p: *Parser) Error!void {
    p.top().val = Value.initMap();

    if (p.ch == '{') {
        _ = p.next();
        const ci = white(p);
        p.top().ci_elem_before = ci;
    } else {
        const t = p.top();
        t.ci_elem_before = t.ci_before;
        t.ci_before = .{};
    }

    // (The C++ condition `!(vParent.empty() && withoutBraces)` is always true
    // here because vParent is never empty; kept for fidelity.)
    if (p.ch == '}' and !(p.v_parent.items.len == 0 and p.without_braces)) {
        const t = p.top();
        try setComment1(p, &t.val, "inside", t.ci_elem_before);
        _ = p.next();
        p.topState().* = .value_end;
    } else {
        p.topState().* = .map_elem_begin;
    }
}

fn readObjectElemBegin(p: *Parser) Error!void {
    if (p.ch == 0) {
        if (p.v_parent.items.len == 1 and p.without_braces) {
            const t = p.top();
            if (t.val.isEmpty()) {
                try setComment1(p, &t.val, "inside", t.ci_elem_before);
            } else {
                const vals = t.val.data.map.values();
                const last = &vals[vals.len - 1];
                try setComment2(p, last, "after", t.ci_elem_before, t.ci_elem_extra);
            }
            p.topState().* = .value_end;
            return;
        } else {
            return p.fail(&.{"End of input while parsing an object (did you forget a closing '}'?)"});
        }
    }

    const key = try readKeyname(p);
    p.top().key = key;
    if (p.opt.duplicate_key_exception) {
        if (p.top().val.get(key)) |existing| {
            if (existing.isDefined()) {
                return p.fail(&.{ "Found duplicate of key '", key, "'" });
            }
        }
    }
    const ci_key = white(p);
    p.top().ci_key = ci_key;
    if (p.ch != ':') {
        const c1 = [1]u8{p.ch};
        return p.fail(&.{ "Expected ':' instead of '", &c1, "'" });
    }
    _ = p.next();
    p.topState().* = .map_elem_end;
    try p.v_state.append(p.gpa, .value_begin);
}

fn readObjectElemEnd(p: *Parser) Error!void {
    var elem = p.popParent().val;
    {
        const t = p.top();
        try setComment1(p, &elem, "key", t.ci_key);
        if (elem.comments.before.len != 0) {
            elem.comments.key = try concat(p.a, elem.comments.key, elem.comments.before);
            elem.comments.before = "";
        }
        try setComment2(p, &elem, "before", t.ci_elem_before, t.ci_elem_extra);
    }
    const ci_after = white(p);

    // in Hjson the comma is optional and trailing commas are allowed
    if (p.ch == ',') {
        _ = p.next();
        // It is unlikely that someone writes a comment after the value but
        // before the comma, so we include any such comment in "comment_after".
        const ci = white(p);
        p.top().ci_elem_extra = ci;
    } else {
        p.top().ci_elem_extra = .{};
    }

    const key = p.top().key;
    if (p.ch == '}' and !(p.v_parent.items.len == 1 and p.without_braces)) {
        const existing_after = elem.comments.after;
        try setComment2(p, &elem, "after", ci_after, p.top().ci_elem_extra);
        if (existing_after.len != 0) {
            elem.comments.after = try concat(p.a, existing_after, elem.comments.after);
        }
        try putMap(p, key, elem);
        _ = p.next();
        p.topState().* = .value_end;
    } else {
        try putMap(p, key, elem);
        p.top().ci_elem_before = ci_after;
        p.topState().* = .map_elem_begin;
    }
}

// Parse a Hjson value. It could be an object, an array, a string, a number or a word.
fn readValueBegin(p: *Parser) Error!void {
    try p.v_parent.append(p.gpa, .{});
    const ci = white(p);
    p.top().ci_before = ci;

    switch (p.ch) {
        '{' => p.topState().* = .map_begin,
        '[' => p.topState().* = .vector_begin,
        '"', '\'' => {
            const s = try readString(p, true);
            p.top().val = Value{ .data = .{ .string = s } };
            p.topState().* = .value_end;
        },
        else => {
            const v = try readTfnns(p);
            p.top().val = v;
            p.topState().* = .value_end;
        },
    }
}

fn readValueEnd(p: *Parser) Error!void {
    const ci_after = getCommentAfter(p);

    const t = p.top();
    try setComment1(p, &t.val, "before", t.ci_before);
    try setComment1(p, &t.val, "after", ci_after);

    p.popState();
}

fn hasTrailing(p: *Parser, ci: *CommentInfo) bool {
    ci.* = white(p);
    return p.ch > 0;
}

fn parseLoop(p: *Parser) Error!void {
    while (p.v_state.items.len != 0) {
        switch (p.v_state.items[p.v_state.items.len - 1]) {
            .value_begin => try readValueBegin(p),
            .value_end => try readValueEnd(p),
            .map_begin => try readObjectBegin(p),
            .map_elem_begin => try readObjectElemBegin(p),
            .map_elem_end => try readObjectElemEnd(p),
            .vector_begin => try readArrayBegin(p),
            .vector_elem_end => try readArrayElemEnd(p),
        }
    }
}

fn attempt(p: *Parser, ci_extra: *CommentInfo) Error!void {
    try parseLoop(p);
    if (hasTrailing(p, ci_extra)) {
        return p.fail(&.{"Syntax error, found trailing characters"});
    }
}

// Braces for the root object are optional
fn rootValue(p: *Parser) Error!Value {
    var ci_extra: CommentInfo = .{};

    try p.v_parent.append(p.gpa, .{});
    const ci0 = white(p);
    p.top().ci_before = ci0;

    if (p.ch == '[') {
        try p.v_state.append(p.gpa, .vector_begin);
    } else {
        if (p.ch != '{') {
            // Assume root object without braces
            p.without_braces = true;
        }
        try p.v_state.append(p.gpa, .map_begin);
    }

    if (attempt(p, &ci_extra)) |_| {} else |e1| {
        if (e1 != error.SyntaxError or !p.without_braces) return e1;

        // test if we are dealing with a single JSON value instead
        // (true/false/null/num/"")
        var saved: std.ArrayList(u8) = .empty;
        defer saved.deinit(p.gpa);
        try saved.appendSlice(p.gpa, p.err.items);

        resetAt(p);
        p.v_parent.clearRetainingCapacity();
        p.v_state.clearRetainingCapacity();
        try p.v_state.append(p.gpa, .value_begin);

        if (attempt(p, &ci_extra)) |_| {} else |e2| {
            if (e2 == error.SyntaxError) {
                // Report the error from the first attempt.
                p.err.clearRetainingCapacity();
                try p.err.appendSlice(p.gpa, saved.items);
            }
            return e2;
        }
    }

    var ret = p.top().val;
    if (ci_extra.has_comment) {
        const existing_after = ret.comments.after;
        try setComment1(p, &ret, "after", ci_extra);
        if (existing_after.len != 0) {
            ret.comments.after = try concat(p.a, existing_after, ret.comments.after);
        }
    }

    return ret;
}

/// Unmarshal parses the Hjson-encoded `data` and returns a tree of Values.
/// `data` does not need to outlive the result: all text is copied.
pub fn unmarshal(gpa: Allocator, data: []const u8, options: DecoderOptions) Error!Parsed {
    return unmarshalWithDiagnostic(gpa, data, options, null);
}

/// Like `unmarshal`, but on `error.SyntaxError` stores the message (with line
/// and column) in `diag`. Free it with `diag.deinit(gpa)`.
pub fn unmarshalWithDiagnostic(
    gpa: Allocator,
    data: []const u8,
    options: DecoderOptions,
    diag: ?*Diagnostic,
) Error!Parsed {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var p = Parser{
        .gpa = gpa,
        .a = arena.allocator(),
        .data = data,
        .opt = options,
    };
    defer p.deinit();

    if (p.opt.whitespace_as_comments) {
        p.opt.comments = true;
    }

    resetAt(&p);

    const root = rootValue(&p) catch |err| {
        if (err == error.SyntaxError) {
            if (diag) |d| {
                d.deinit(gpa);
                const msg: []const u8 = gpa.dupe(u8, p.err.items) catch "";
                d.message = msg;
            }
        }
        return err;
    };

    return Parsed{ .arena = arena, .gpa = gpa, .value = root };
}

/// Mirrors what UnmarshalFromFile does to the bytes it read: strips trailing
/// NUL bytes, then one trailing '\n', then one trailing '\r'. Use it on file
/// contents before calling `unmarshal` (file reading itself is left to the
/// caller, since std's file API changed across recent Zig releases).
pub fn trimFileTail(bytes: []const u8) []const u8 {
    var len = bytes.len;
    while (len > 0 and bytes[len - 1] == 0) len -= 1;
    if (len > 0 and bytes[len - 1] == '\n') len -= 1;
    if (len > 0 and bytes[len - 1] == '\r') len -= 1;
    return bytes[0..len];
}
