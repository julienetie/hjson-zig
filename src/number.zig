//! Number parsing and formatting.
//!
//! Port of hjson_parsenumber.cpp plus the double/int formatting that
//! hjson_value.cpp does in Value::to_string().

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Number = union(enum) {
    int: i64,
    double: f64,
};

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= 0x09 and c <= 0x0d);
}

const NumberParser = struct {
    data: []const u8,
    index_next: usize = 0,
    ch: u8 = ' ',

    fn next(p: *NumberParser) bool {
        // get the next character.
        if (p.index_next < p.data.len) {
            p.ch = p.data[p.index_next];
            p.index_next += 1;
            return true;
        }
        if (p.index_next == p.data.len) {
            p.index_next += 1;
        }
        p.ch = 0;
        return false;
    }
};

fn parseFloatStrict(text: []const u8) ?f64 {
    const d = std.fmt.parseFloat(f64, text) catch return null;
    if (!std.math.isFinite(d)) return null;
    return d;
}

/// Parse a number value. Returns null if `text` is not a valid Hjson number.
/// Integers that do not fit in an i64 become doubles.
pub fn tryParse(text: []const u8, stop_at_next: bool) ?Number {
    var p = NumberParser{ .data = text };

    var leading_zeros: i32 = 0;
    var test_leading = true;

    _ = p.next();

    if (p.ch == '-') {
        _ = p.next();
    }

    while (p.ch >= '0' and p.ch <= '9') {
        if (test_leading) {
            if (p.ch == '0') {
                leading_zeros += 1;
            } else {
                test_leading = false;
            }
        }
        _ = p.next();
    }

    if (test_leading) {
        leading_zeros -= 1;
    } // single 0 is allowed

    if (p.ch == '.') {
        while (p.next() and p.ch >= '0' and p.ch <= '9') {}
    }
    if (p.ch == 'e' or p.ch == 'E') {
        _ = p.next();
        if (p.ch == '-' or p.ch == '+') {
            _ = p.next();
        }
        while (p.ch >= '0' and p.ch <= '9') {
            _ = p.next();
        }
    }

    const end = p.index_next;

    // skip white/to (newline)
    while (p.ch > 0 and p.ch <= ' ') {
        _ = p.next();
    }

    if (stop_at_next) {
        // end scan if we find a punctuator character like ,}] or a comment
        if (p.ch == ',' or p.ch == '}' or p.ch == ']' or p.ch == '#' or
            (p.index_next < text.len and p.ch == '/' and
                (text[p.index_next] == '/' or text[p.index_next] == '*')))
        {
            p.ch = 0;
        }
    }

    if (p.ch > 0 or leading_zeros != 0) {
        // Invalid number.
        return null;
    }

    const num_text = text[0 .. end - 1];

    if (std.fmt.parseInt(i64, num_text, 10)) |i| {
        return Number{ .int = i };
    } else |_| {}

    if (parseFloatStrict(num_text)) |d| {
        return Number{ .double = d };
    }

    return null;
}

/// Lenient string -> f64 used by Value.toF64(): leading whitespace is
/// skipped, trailing garbage or non-finite results yield null.
pub fn parseLooseF64(s: []const u8) ?f64 {
    var i: usize = 0;
    while (i < s.len and isSpace(s[i])) i += 1;
    const t = s[i..];
    if (t.len == 0) return null;
    return parseFloatStrict(t);
}

/// Lenient string -> i64 used by Value.toI64().
pub fn parseLooseI64(s: []const u8) ?i64 {
    var i: usize = 0;
    while (i < s.len and isSpace(s[i])) i += 1;
    const t = s[i..];
    if (t.len == 0) return null;
    return std.fmt.parseInt(i64, t, 10) catch null;
}

pub fn appendUsize(list: *std.ArrayList(u8), a: Allocator, v: usize) Allocator.Error!void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try list.appendSlice(a, s);
}

pub fn appendInt(list: *std.ArrayList(u8), a: Allocator, v: i64) Allocator.Error!void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    try list.appendSlice(a, s);
}

/// Formats a double like C's "%.15g" (what the C++ library does), then makes
/// sure a decimal point is present so the value reads back as a double.
///
/// Deviation from the C++ code: for exponent notation with a one-digit
/// mantissa the C++ code produced e.g. "1e+20.0" (which does not parse back
/// as a number). Here ".0" is inserted before the exponent: "1.0e+20".
pub fn appendDouble(list: *std.ArrayList(u8), a: Allocator, d: f64) Allocator.Error!void {
    if (std.math.isNan(d)) return list.appendSlice(a, "nan");
    if (std.math.isInf(d)) return list.appendSlice(a, if (d < 0) "-inf" else "inf");

    // 15 significant digits in scientific notation, then re-layout as %g.
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{e:.14}", .{d}) catch unreachable;

    var i: usize = 0;
    const negative = s.len > 0 and s[0] == '-';
    if (negative) i = 1;

    var digits: [32]u8 = undefined;
    var nd: usize = 0;
    while (i < s.len and s[i] != 'e' and s[i] != 'E') : (i += 1) {
        if (s[i] >= '0' and s[i] <= '9' and nd < digits.len) {
            digits[nd] = s[i];
            nd += 1;
        }
    }

    var exp: i32 = 0;
    if (i < s.len) {
        i += 1; // skip 'e'
        var exp_negative = false;
        if (i < s.len and (s[i] == '-' or s[i] == '+')) {
            exp_negative = s[i] == '-';
            i += 1;
        }
        while (i < s.len) : (i += 1) {
            if (s[i] >= '0' and s[i] <= '9') {
                exp = exp * 10 + @as(i32, s[i] - '0');
            }
        }
        if (exp_negative) exp = -exp;
    }

    if (nd == 0) {
        digits[0] = '0';
        nd = 1;
    }

    // Number of significant digits after removing trailing zeros (min 1).
    var n = nd;
    while (n > 1 and digits[n - 1] == '0') n -= 1;

    if (negative) try list.append(a, '-');

    if (exp < -4 or exp >= 15) {
        // Exponent notation.
        try list.append(a, digits[0]);
        try list.append(a, '.');
        if (n > 1) {
            try list.appendSlice(a, digits[1..n]);
        } else {
            try list.append(a, '0');
        }
        try list.append(a, 'e');
        try list.append(a, if (exp < 0) '-' else '+');
        const abs_exp: u32 = @intCast(if (exp < 0) -exp else exp);
        if (abs_exp < 10) try list.append(a, '0');
        try appendUsize(list, a, abs_exp);
    } else if (exp >= 0) {
        const int_len: usize = @intCast(exp + 1);
        var k: usize = 0;
        while (k < int_len) : (k += 1) {
            try list.append(a, if (k < n) digits[k] else '0');
        }
        try list.append(a, '.');
        if (n > int_len) {
            try list.appendSlice(a, digits[int_len..n]);
        } else {
            try list.append(a, '0');
        }
    } else {
        try list.appendSlice(a, "0.");
        var z: i32 = -exp - 1;
        while (z > 0) : (z -= 1) {
            try list.append(a, '0');
        }
        try list.appendSlice(a, digits[0..n]);
    }
}
