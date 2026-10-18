//! Hjson encoder. Port of hjson_encode.cpp.
//!
//! The C++ code used std::regex; here each regex is a hand-written byte
//! predicate with the same semantics (the regexes were byte based, not UTF-8
//! aware, so these are too). Like the C++ original this is an explicit state
//! machine, so deeply nested values cannot overflow the stack.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const number = @import("number.zig");
const EncoderOptions = @import("options.zig").EncoderOptions;

const EncodeState = enum {
    value_begin,
    value_end,
    vector_elem_begin,
    map_elem_begin,
};

const EncodeParent = struct {
    p_val: *const Value,
    index: usize = 0,
    is_empty: bool = true,
    comment_after: []const u8 = "",
    // Sorted entry indices, only used when !preserve_insertion_order.
    order: ?[]usize = null,
    order_pos: usize = 0,
};

const Encoder = struct {
    gpa: Allocator,
    opt: EncoderOptions,
    out: std.ArrayList(u8) = .empty,
    indent: isize = 0,
    v_state: std.ArrayList(EncodeState) = .empty,
    v_parent: std.ArrayList(EncodeParent) = .empty,

    fn deinit(e: *Encoder) void {
        for (e.v_parent.items) |ep| {
            if (ep.order) |o| e.gpa.free(o);
        }
        e.out.deinit(e.gpa);
        e.v_state.deinit(e.gpa);
        e.v_parent.deinit(e.gpa);
    }

    fn w(e: *Encoder, s: []const u8) Allocator.Error!void {
        try e.out.appendSlice(e.gpa, s);
    }

    fn top(e: *Encoder) *EncodeParent {
        return &e.v_parent.items[e.v_parent.items.len - 1];
    }

    fn topState(e: *Encoder) *EncodeState {
        return &e.v_state.items[e.v_state.items.len - 1];
    }

    // True if the current value is a map element and a separating space is
    // needed after the "key:".
    fn sepNeeded(e: *Encoder) bool {
        const n = e.v_state.items.len;
        return n > 1 and e.v_state.items[n - 2] == .map_elem_begin and
            (!e.opt.comments or e.top().p_val.comments.key.len == 0);
    }
};

// ---- byte predicates replacing the C++ regexes ------------------------------

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= 0x09 and c <= 0x0d);
}

fn contains(s: []const u8, c: u8) bool {
    for (s) |x| {
        if (x == c) return true;
    }
    return false;
}

// Length of a "commonRange" multi-byte match at s[i], or 0:
//   \xc2\xad | \xd8[\x80-\x84] | \xdc\x8f | \xe1\x9e[\xb4\xb5] |
//   \xe2\x80[\x8c\x8f] | \xe2\x80[\xa8-\xaf] | \xe2\x81[\xa0-\xaf] |
//   \xef\xbb\xbf | \xef\xbf[\xb0-\xbf]
fn commonRangeLen(s: []const u8, i: usize) usize {
    const r = s[i..];
    switch (r[0]) {
        0xc2 => {
            if (r.len >= 2 and r[1] == 0xad) return 2;
        },
        0xd8 => {
            if (r.len >= 2 and r[1] >= 0x80 and r[1] <= 0x84) return 2;
        },
        0xdc => {
            if (r.len >= 2 and r[1] == 0x8f) return 2;
        },
        0xe1 => {
            if (r.len >= 3 and r[1] == 0x9e and (r[2] == 0xb4 or r[2] == 0xb5)) return 3;
        },
        0xe2 => {
            if (r.len >= 3) {
                if (r[1] == 0x80 and (r[2] == 0x8c or r[2] == 0x8f)) return 3;
                if (r[1] == 0x80 and r[2] >= 0xa8 and r[2] <= 0xaf) return 3;
                if (r[1] == 0x81 and r[2] >= 0xa0 and r[2] <= 0xaf) return 3;
            }
        },
        0xef => {
            if (r.len >= 3) {
                if (r[1] == 0xbb and r[2] == 0xbf) return 3;
                if (r[1] == 0xbf and r[2] >= 0xb0 and r[2] <= 0xbf) return 3;
            }
        },
        else => {},
    }
    return 0;
}

// needsEscape: [\\"\x00-\x1f] | commonRange. Returns the match length at
// s[i] or 0.
fn escapeMatchLen(s: []const u8, i: usize) usize {
    const c = s[i];
    if (c == '\\' or c == '"' or c <= 0x1f) return 1;
    return commonRangeLen(s, i);
}

fn needsEscape(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (escapeMatchLen(s, i) != 0) return true;
    }
    return false;
}

// needsQuotes: ^\s | ^" | ^' | ^# | ^/\* | ^// | ^\{ | ^\} | ^\[ | ^\] | ^: |
//              ^, | \s$ | [\x00-\x1f] | commonRange
fn needsQuotes(s: []const u8) bool {
    if (s.len == 0) return false;
    const c0 = s[0];
    if (isSpace(c0) or c0 == '"' or c0 == '\'' or c0 == '#' or c0 == '{' or
        c0 == '}' or c0 == '[' or c0 == ']' or c0 == ':' or c0 == ',')
    {
        return true;
    }
    if (c0 == '/' and s.len >= 2 and (s[1] == '*' or s[1] == '/')) return true;
    if (isSpace(s[s.len - 1])) return true;

    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] <= 0x1f) return true;
        if (commonRangeLen(s, i) != 0) return true;
    }
    return false;
}

// needsEscapeML: ''' | ^[\s]+$ | [\x00-\x08\x0b\x0c\x0e-\x1f] | commonRange
fn needsEscapeML(s: []const u8) bool {
    var all_ws = s.len > 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (!isSpace(c)) all_ws = false;
        if (c == '\'' and i + 2 < s.len and s[i + 1] == '\'' and s[i + 2] == '\'') return true;
        if (c <= 0x08 or c == 0x0b or c == 0x0c or (c >= 0x0e and c <= 0x1f)) return true;
        if (commonRangeLen(s, i) != 0) return true;
    }
    return all_ws;
}

// startsWithKeyword: ^(true|false|null)\s*((,|\]|\}|#|//|/\*).*)?$
// (`.` does not match \n or \r.)
fn startsWithKeyword(s: []const u8) bool {
    const keywords = [_][]const u8{ "true", "false", "null" };
    for (keywords) |kw| {
        if (s.len < kw.len or !std.mem.eql(u8, s[0..kw.len], kw)) continue;

        var i: usize = kw.len;
        while (i < s.len and isSpace(s[i])) i += 1;
        if (i == s.len) return true;

        var rest_start: usize = undefined;
        const c = s[i];
        if (c == ',' or c == ']' or c == '}' or c == '#') {
            rest_start = i + 1;
        } else if (c == '/' and i + 1 < s.len and (s[i + 1] == '/' or s[i + 1] == '*')) {
            rest_start = i + 2;
        } else {
            return false;
        }
        for (s[rest_start..]) |x| {
            if (x == '\n' or x == '\r') return false;
        }
        return true;
    }
    return false;
}

// needsEscapeName: [,\{\[\}\]\s:#"'] | // | /\*
fn needsEscapeName(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == ',' or c == '{' or c == '[' or c == '}' or c == ']' or isSpace(c) or
            c == ':' or c == '#' or c == '"' or c == '\'')
        {
            return true;
        }
        if (c == '/' and i + 1 < s.len and (s[i + 1] == '/' or s[i + 1] == '*')) return true;
    }
    return false;
}

// lineBreak: \r|\n|\r\n -- ECMAScript alternation is leftmost-first, so every
// '\r' and every '\n' is a separate one-byte match (a "\r\n" is two matches).
// This mirrors the C++ behaviour.
fn findLineBreak(s: []const u8, from: usize) ?usize {
    var i = from;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\r' or s[i] == '\n') return i;
    }
    return null;
}

// ---- writing ----------------------------------------------------------------

// table of character substitutions
fn meta(c: u8) ?[]const u8 {
    return switch (c) {
        0x08 => "\\b",
        '\t' => "\\t",
        '\n' => "\\n",
        0x0c => "\\f",
        '\r' => "\\r",
        '"' => "\\\"",
        '\\' => "\\\\",
        else => null,
    };
}

fn writeIndent(e: *Encoder, indent: isize) Allocator.Error!void {
    try e.w(e.opt.eol);

    if (e.opt.indent_by.len != 0) {
        var i: isize = 0;
        while (i < indent) : (i += 1) {
            try e.w(e.opt.indent_by);
        }
    }
}

// Decodes one code point and advances `s`. Null if not (well enough) UTF-8.
fn fromUtf8(s: *[]const u8) ?u32 {
    const cur = s.*;
    if (cur.len == 0) return null;

    var n_s: usize = undefined;
    var ret: u32 = undefined;
    const c0 = cur[0];
    if (c0 < 0x80) {
        n_s = 1;
        ret = c0;
    } else if (c0 < 0xc0) {
        return null;
    } else if (c0 < 0xe0) {
        n_s = 2;
        ret = c0 & 0x1f;
    } else if (c0 < 0xf0) {
        n_s = 3;
        ret = c0 & 0xf;
    } else if (c0 < 0xf8) {
        n_s = 4;
        ret = c0 & 0x7;
    } else {
        return null;
    }

    if (cur.len < n_s) return null;

    var k: usize = 1;
    while (k < n_s) : (k += 1) {
        if (cur[k] < 0x80) return null;
        ret = (ret << 6) | (cur[k] & 0x3f);
    }

    s.* = cur[n_s..];
    return ret;
}

fn writeHex4(e: *Encoder, cp: u32) Allocator.Error!void {
    const hex = "0123456789abcdef";
    var buf: [8]u8 = undefined;
    var n: usize = 0;
    // At least 4 digits, lowercase, zero padded (like setw(4) + hex).
    var started = false;
    var shift: i32 = 28;
    while (shift >= 0) : (shift -= 4) {
        const nib: u8 = @intCast((cp >> @as(u5, @intCast(shift))) & 0xf);
        if (nib != 0) started = true;
        if (started or shift < 16) {
            buf[n] = hex[nib];
            n += 1;
        }
    }
    try e.w("\\u");
    try e.w(buf[0..n]);
}

fn quoteReplace(e: *Encoder, text: []const u8) Allocator.Error!void {
    var index_start: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        const len = escapeMatchLen(text, i);
        if (len == 0) {
            i += 1;
            continue;
        }

        if (i > index_start) {
            // Append non-matching text.
            try e.w(text[index_start..i]);
        }

        if (meta(text[i])) |rep| {
            try e.w(rep);
        } else {
            var rest: []const u8 = text[i .. i + len];
            while (rest.len != 0) {
                const cp = fromUtf8(&rest) orelse {
                    // Not UTF8. Just dump it.
                    try e.w(rest);
                    break;
                };
                try writeHex4(e, cp);
            }
        }

        i += len;
        index_start = i;
    }

    if (index_start < text.len) {
        // Append remaining text.
        try e.w(text[index_start..]);
    }
}

// wrap the string into the ''' (multiline) format
fn mlString(e: *Encoder, value: []const u8) Allocator.Error!void {
    var index_start: usize = 0;
    var pos = findLineBreak(value, 0);

    if (pos == null) {
        if (e.sepNeeded()) {
            try e.w(" ");
        }
        // The string contains only a single line. We still use the multiline
        // format as it avoids escaping the \ character (e.g. when used in a
        // regex).
        try e.w("'''");
        try e.w(value);
    } else {
        try writeIndent(e, e.indent + 1);
        try e.w("'''");

        while (pos) |m_pos| {
            var indent = e.indent + 1;
            if (m_pos == index_start) {
                indent = 0;
            }
            try writeIndent(e, indent);
            if (m_pos > index_start) {
                try e.w(value[index_start..m_pos]);
            }
            index_start = m_pos + 1;
            pos = findLineBreak(value, index_start);
        }

        if (index_start < value.len) {
            // Append remaining text.
            try writeIndent(e, e.indent + 1);
            try e.w(value[index_start..]);
        } else {
            // Trailing line feed.
            try writeIndent(e, 0);
        }

        try writeIndent(e, e.indent + 1);
    }

    try e.w("'''");
}

// Check if we can insert this string without quotes
// see hjson syntax (must not parse as true, false, null or number)
fn quote(e: *Encoder, value: []const u8, has_comment_after: bool) Allocator.Error!void {
    const b_sep = e.sepNeeded();

    if (value.len == 0) {
        if (b_sep) try e.w(" ");
        try e.w("\"\"");
    } else if (e.opt.quote_always or
        needsQuotes(value) or
        number.tryParse(value, true) != null or
        startsWithKeyword(value) or
        has_comment_after)
    {
        // If the string contains no control characters, no quote characters,
        // and no backslash characters, then we can safely slap some quotes
        // around it. Otherwise we first check if the string can be expressed
        // in multiline format or we must replace the offending characters
        // with safe escape sequences.
        if (!needsEscape(value)) {
            if (b_sep) try e.w(" ");
            try e.w("\"");
            try e.w(value);
            try e.w("\"");
        } else if (!e.opt.quote_always and !needsEscapeML(value) and e.v_parent.items.len > 1) {
            try mlString(e, value);
        } else {
            if (b_sep) try e.w(" ");
            try e.w("\"");
            try quoteReplace(e, value);
            try e.w("\"");
        }
    } else {
        if (b_sep) try e.w(" ");
        // return without quotes
        try e.w(value);
    }
}

fn quoteName(e: *Encoder, name: []const u8) Allocator.Error!void {
    if (name.len == 0) {
        try e.w("\"\"");
    } else if (e.opt.quote_keys or needsEscapeName(name) or needsEscape(name)) {
        try e.w("\"");
        try quoteReplace(e, name);
        try e.w("\"");
    } else {
        // without quotes
        try e.w(name);
    }
}

fn quoteForComment(e: *Encoder, comment: []const u8) bool {
    if (!e.opt.comments) return false;

    for (comment) |ch| {
        switch (ch) {
            '\r', '\n' => return false,
            '/', '#' => return true,
            else => {},
        }
    }
    return false;
}

// Returns true if we are inside a comment after outputting the string
// (i.e. the string contains an unterminated line comment).
// Also returns true for '/* # */' and similar, but that should be uncommon and
// will only cause an unnecessary line feed after the comment.
fn isInComment(comment: []const u8) bool {
    var ends_inside_comment = false;
    var prev: u8 = ' ';

    for (comment) |ch| {
        switch (ch) {
            '\n' => ends_inside_comment = false,
            '#' => ends_inside_comment = true,
            '/' => {
                if (prev == '/') ends_inside_comment = true;
            },
            else => {},
        }
        prev = ch;
    }

    return ends_inside_comment;
}

// Produce a string from value.
fn writeValueBegin(e: *Encoder) Allocator.Error!void {
    const value = e.top().p_val;

    if (e.opt.comments) {
        try e.w(value.comments.key);
    }

    switch (value.data) {
        .double => |d| {
            if (!std.math.isFinite(d)) {
                try e.w("null");
            } else if (!e.opt.allow_minus_zero and d == 0 and std.math.signbit(d)) {
                try e.w("0");
            } else {
                try number.appendDouble(&e.out, e.gpa, d);
            }
        },
        .string => |s| try quote(e, s, quoteForComment(e, value.comments.after)),
        .vector => {
            try e.w("[");
            e.indent += 1;
            e.top().comment_after = value.comments.inside;
            e.topState().* = .vector_elem_begin;
            return;
        },
        .map => |m| {
            if (!e.opt.omit_root_braces or e.v_parent.items.len > 1 or m.count() == 0) {
                try e.w("{");
                e.indent += 1;
            }
            const order: ?[]usize = if (e.opt.preserve_insertion_order)
                null
            else
                try value_mod.sortedOrder(e.gpa, &m);
            const t = e.top();
            t.comment_after = value.comments.inside;
            t.order = order;
            t.order_pos = 0;
            e.topState().* = .map_elem_begin;
            return;
        },
        .undef => {},
        .nil => try e.w("null"),
        .boolean => |b| try e.w(if (b) "true" else "false"),
        .int64 => |i| try number.appendInt(&e.out, e.gpa, i),
    }

    e.topState().* = .value_end;
}

fn writeValueEnd(e: *Encoder) void {
    const n = e.v_parent.items.len;
    if (e.v_parent.items[n - 1].order) |o| {
        e.gpa.free(o);
    }
    e.v_state.shrinkRetainingCapacity(e.v_state.items.len - 1);
    e.v_parent.shrinkRetainingCapacity(n - 1);
}

fn writeVectorElemBegin(e: *Encoder) Allocator.Error!void {
    const pi = e.v_parent.items.len - 1;
    const value = e.v_parent.items[pi].p_val;
    const items = value.data.vector.items;

    var idx = e.v_parent.items[pi].index;
    while (idx < items.len) : (idx += 1) {
        const elem = &items[idx];
        if (elem.isDefined()) {
            const ep = &e.v_parent.items[pi];
            var should_indent = (!e.opt.comments or elem.comments.key.len == 0);

            if (ep.is_empty) {
                ep.is_empty = false;

                if (e.opt.comments and ep.comment_after.len != 0) {
                    try e.w(ep.comment_after);
                    // This is the first element, so comment_after is the
                    // inner comment of the parent vector. The inner comment
                    // probably expects "]" to come after it and therefore
                    // needs one more level of indentation.
                    try e.w(e.opt.indent_by);
                    should_indent = false;
                }
            } else {
                if (e.opt.separator) {
                    try e.w(",");
                }

                if (e.opt.comments) {
                    try e.w(ep.comment_after);
                }
            }

            if (e.opt.comments and elem.comments.before.len != 0) {
                if (!e.opt.separator and !contains(elem.comments.before, '\n')) {
                    try writeIndent(e, e.indent);
                }
                try e.w(elem.comments.before);
            } else if (should_indent) {
                try writeIndent(e, e.indent);
            }

            ep.comment_after = elem.comments.after;
            ep.index = idx + 1;
            // Appending invalidates `ep`; do not use it afterwards.
            try e.v_parent.append(e.gpa, .{ .p_val = elem });
            try e.v_state.append(e.gpa, .value_begin);
            return;
        }
    }

    const tail = &e.v_parent.items[pi];
    if (e.opt.comments and tail.comment_after.len != 0) {
        try e.w(tail.comment_after);
    }
    if (!tail.is_empty and (!e.opt.comments or tail.comment_after.len == 0 or
        (!e.opt.separator and !contains(tail.comment_after, '\n'))))
    {
        try writeIndent(e, e.indent - 1);
    }

    try e.w("]");
    e.indent -= 1;
    e.topState().* = .value_end;
}

fn objElem(
    e: *Encoder,
    key: []const u8,
    value: *const Value,
    is_first: *bool,
    comment_after_prev: []const u8,
) Allocator.Error!void {
    const has_comment_before = (e.opt.comments and value.comments.before.len != 0);

    if (is_first.*) {
        is_first.* = false;
        const should_indent = ((!e.opt.omit_root_braces or e.v_parent.items.len > 1) and !has_comment_before);

        if (e.opt.comments and comment_after_prev.len != 0) {
            try e.w(comment_after_prev);
            // This is the first element, so comment_after_prev is the inner
            // comment of the parent map. The inner comment probably expects
            // "}" to come after it and therefore needs one more level of
            // indentation, unless this is the root object without braces.
            if (should_indent) {
                try e.w(e.opt.indent_by);
            }
        } else if (should_indent) {
            try writeIndent(e, e.indent);
        }
    } else {
        if (e.opt.separator) {
            try e.w(",");
        }
        if (e.opt.comments) {
            try e.w(comment_after_prev);
        }
        if (!has_comment_before or
            (!e.opt.separator and !contains(value.comments.before, '\n')))
        {
            try writeIndent(e, e.indent);
        }
    }

    if (has_comment_before) {
        try e.w(value.comments.before);
    }

    try quoteName(e, key);
    try e.w(":");
    if (!e.opt.braces_same_line and
        value.isContainer() and
        (!value.isEmpty() or (e.opt.comments and value.comments.inside.len != 0)) and
        (!e.opt.comments or value.comments.key.len == 0))
    {
        try writeIndent(e, e.indent);
    } else if (value.getType() != .string and (!e.opt.comments or value.comments.key.len == 0)) {
        try e.w(" ");
    }
    // Appending invalidates `is_first`; it is not used afterwards.
    try e.v_parent.append(e.gpa, .{ .p_val = value });
    try e.v_state.append(e.gpa, .value_begin);
}

fn writeMapElemBegin(e: *Encoder) Allocator.Error!void {
    const pi = e.v_parent.items.len - 1;
    const value = e.v_parent.items[pi].p_val;
    const keys = value.data.map.keys();
    const vals = value.data.map.values();

    if (e.opt.preserve_insertion_order) {
        var idx = e.v_parent.items[pi].index;
        while (idx < vals.len) : (idx += 1) {
            const elem = &vals[idx];
            if (elem.isDefined()) {
                const ep = &e.v_parent.items[pi];
                try objElem(e, keys[idx], elem, &ep.is_empty, ep.comment_after);

                e.v_parent.items[pi].comment_after = elem.comments.after;
                e.v_parent.items[pi].index = idx + 1;
                return;
            }
        }
    } else {
        const order = e.v_parent.items[pi].order.?;
        var pos = e.v_parent.items[pi].order_pos;
        while (pos < order.len) : (pos += 1) {
            const idx = order[pos];
            const elem = &vals[idx];
            if (elem.isDefined()) {
                const ep = &e.v_parent.items[pi];
                try objElem(e, keys[idx], elem, &ep.is_empty, ep.comment_after);

                e.v_parent.items[pi].comment_after = elem.comments.after;
                e.v_parent.items[pi].order_pos = pos + 1;
                return;
            }
        }
    }

    const tail = &e.v_parent.items[pi];
    if (e.opt.comments and tail.comment_after.len != 0) {
        try e.w(tail.comment_after);
    }
    if (!tail.is_empty and (!e.opt.omit_root_braces or e.v_parent.items.len > 1) and
        (!e.opt.comments or tail.comment_after.len == 0 or
            (!e.opt.separator and !contains(tail.comment_after, '\n'))))
    {
        try writeIndent(e, e.indent - 1);
    }

    if (!e.opt.omit_root_braces or e.v_parent.items.len > 1 or value.isEmpty()) {
        e.indent -= 1;
        if (e.v_parent.items.len == 1 and e.opt.comments and tail.comment_after.len != 0 and
            isInComment(tail.comment_after))
        {
            try writeIndent(e, e.indent);
        }
        try e.w("}");
    }

    e.topState().* = .value_end;
}

fn marshalLoop(e: *Encoder) Allocator.Error!void {
    while (e.v_state.items.len != 0) {
        switch (e.v_state.items[e.v_state.items.len - 1]) {
            .value_begin => try writeValueBegin(e),
            .value_end => writeValueEnd(e),
            .vector_elem_begin => try writeVectorElemBegin(e),
            .map_elem_begin => try writeMapElemBegin(e),
        }
    }
}

/// Returns a properly indented Hjson text representation of `v`. Caller owns
/// the returned slice (allocated with `gpa`).
///
/// Strings encode as Hjson strings (quoteless, multiline or JSON), Doubles
/// always get a decimal point, NaN/Infinity encode as null, maps encode in
/// insertion order unless `preserve_insertion_order` is false. Undefined
/// elements in maps and vectors are skipped.
pub fn marshal(gpa: Allocator, v: *const Value, options: EncoderOptions) Allocator.Error![]u8 {
    var e = Encoder{ .gpa = gpa, .opt = options };
    defer e.deinit();

    if (e.opt.separator) {
        e.opt.quote_always = true;
    }

    try e.v_parent.append(gpa, .{ .p_val = v });
    try e.v_state.append(gpa, .value_begin);
    if (e.opt.comments) {
        try e.w(v.comments.before);
    }
    try marshalLoop(&e);
    if (e.opt.comments) {
        try e.w(v.comments.after);
    }

    return e.out.toOwnedSlice(gpa);
}

/// Returns a JSON text representation of `v`: default options plus
/// braces_same_line, quote_always, quote_keys and separator, no comments.
pub fn marshalJson(gpa: Allocator, v: *const Value) Allocator.Error![]u8 {
    const opt = EncoderOptions{
        .braces_same_line = true,
        .quote_always = true,
        .quote_keys = true,
        .separator = true,
        .comments = false,
    };
    return marshal(gpa, v, opt);
}
