//! Unit tests. The expected strings were derived by hand-tracing the C++
//! algorithms (no Zig compiler or C++ build was available while porting), so
//! a failing test may be a wrong expectation as much as a bug: compare
//! against the original hjson-cpp when in doubt. Porting hjson-cpp's own
//! test/ directory (the .hjson/.json asset pairs) is the next step.

const std = @import("std");
const testing = std.testing;
const hjson = @import("root.zig");

test "decode: README sample, comments land on the element" {
    const parsed = try hjson.unmarshal(testing.allocator,
        \\{
        \\  # specify rate in requests/second
        \\  rate: 1000
        \\  array:
        \\  [
        \\    foo
        \\    bar
        \\  ]
        \\}
    , .{});
    defer parsed.deinit();

    const root = &parsed.value;
    try testing.expectEqual(hjson.Type.map, root.getType());

    const rate = root.get("rate").?;
    try testing.expectEqual(@as(i64, 1000), rate.data.int64);
    try testing.expectEqualStrings(
        "\n  # specify rate in requests/second\n  ",
        rate.comments.before,
    );

    const arr = root.get("array").?;
    try testing.expectEqual(@as(usize, 2), arr.size());
    try testing.expectEqualStrings("foo", arr.data.vector.items[0].data.string);
    try testing.expectEqualStrings("bar", arr.data.vector.items[1].data.string);
}

test "encode: basic map keeps insertion order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = hjson.Value.initMap();
    try m.put(a, "apple", hjson.Value.initInt(5));
    try m.put(a, "lettuce", hjson.Value.initInt(7));

    const out = try hjson.marshal(testing.allocator, &m, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\n  apple: 5\n  lettuce: 7\n}", out);
}

test "encode: alphabetical order when preserve_insertion_order is false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = hjson.Value.initMap();
    try m.put(a, "b", hjson.Value.initInt(1));
    try m.put(a, "a", hjson.Value.initInt(2));

    const out = try hjson.marshal(testing.allocator, &m, .{ .preserve_insertion_order = false });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\n  a: 2\n  b: 1\n}", out);
}

test "round trip: comment before a key" {
    const src = "{\n  # comment\n  a: 1\n}";
    const parsed = try hjson.unmarshal(testing.allocator, src, .{});
    defer parsed.deinit();

    const out = try hjson.marshal(testing.allocator, &parsed.value, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "decode: numbers" {
    const parsed = try hjson.unmarshal(testing.allocator,
        \\a: 007
        \\b: 1e5
        \\c: 9223372036854775807
        \\d: 9223372036854775808
        \\e: -0
        \\f: 1.50
    , .{});
    defer parsed.deinit();
    const root = &parsed.value;

    // Leading zeros: not a number, so a quoteless string.
    try testing.expectEqualStrings("007", root.get("a").?.data.string);
    try testing.expectEqual(@as(f64, 100000.0), root.get("b").?.data.double);
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), root.get("c").?.data.int64);
    // Does not fit in an int64: becomes a double.
    try testing.expectEqual(@as(f64, 9223372036854775808.0), root.get("d").?.data.double);
    try testing.expectEqual(@as(i64, 0), root.get("e").?.data.int64);
    try testing.expectEqual(@as(f64, 1.5), root.get("f").?.data.double);
}

test "decode: quoteless strings and keywords" {
    const parsed = try hjson.unmarshal(testing.allocator,
        \\a: foo bar
        \\b: true
        \\c: null
        \\d: "x\ty\u0041"
        \\e: [1, 2,]
    , .{});
    defer parsed.deinit();
    const root = &parsed.value;

    try testing.expectEqualStrings("foo bar", root.get("a").?.data.string);
    try testing.expectEqual(true, root.get("b").?.data.boolean);
    try testing.expectEqual(hjson.Type.nil, root.get("c").?.getType());
    try testing.expectEqualStrings("x\tyA", root.get("d").?.data.string);
    try testing.expectEqual(@as(usize, 2), root.get("e").?.size());
}

test "decode: root may be a single JSON value or empty" {
    {
        const p = try hjson.unmarshal(testing.allocator, "\"hi\"", .{});
        defer p.deinit();
        try testing.expectEqualStrings("hi", p.value.data.string);
    }
    {
        const p = try hjson.unmarshal(testing.allocator, "42", .{});
        defer p.deinit();
        try testing.expectEqual(@as(i64, 42), p.value.data.int64);
    }
    {
        const p = try hjson.unmarshal(testing.allocator, "true", .{});
        defer p.deinit();
        try testing.expectEqual(true, p.value.data.boolean);
    }
    {
        const p = try hjson.unmarshal(testing.allocator, "", .{});
        defer p.deinit();
        try testing.expectEqual(hjson.Type.map, p.value.getType());
        try testing.expectEqual(@as(usize, 0), p.value.size());

        const out = try hjson.marshal(testing.allocator, &p.value, .{});
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("{}", out);
    }
}

test "round trip: multiline string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = hjson.Value.initMap();
    try m.put(a, "s", try hjson.Value.initString(a, "a\nb"));

    const out = try hjson.marshal(testing.allocator, &m, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\n  s:\n    '''\n    a\n    b\n    '''\n}", out);

    const parsed = try hjson.unmarshal(testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("a\nb", parsed.value.get("s").?.data.string);
}

fn encodeStr(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var m = hjson.Value.initMap();
    try m.put(a, "s", try hjson.Value.initString(a, s));
    return hjson.marshal(testing.allocator, &m, .{});
}

test "encode: when strings get quoted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "true", .want = "{\n  s: \"true\"\n}" },
        .{ .in = "123", .want = "{\n  s: \"123\"\n}" },
        .{ .in = "", .want = "{\n  s: \"\"\n}" },
        .{ .in = " lead", .want = "{\n  s: \" lead\"\n}" },
        .{ .in = "abc def", .want = "{\n  s: abc def\n}" },
    };
    for (cases) |c| {
        const out = try encodeStr(a, c.in);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c.want, out);
    }
}

test "encode: marshalJson" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var m = hjson.Value.initMap();
    try m.put(a, "a", hjson.Value.initInt(1));
    try m.put(a, "b", try hjson.Value.initString(a, "x"));

    const out = try hjson.marshalJson(testing.allocator, &m);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\n  \"a\": 1,\n  \"b\": \"x\"\n}", out);
}

test "merge: ext wins, maps merge recursively, ext keys first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try hjson.unmarshal(testing.allocator, "a: 1\nb: {\n  c: 2\n  d: 3\n}\n", .{ .comments = false });
    defer base.deinit();
    const ext = try hjson.unmarshal(testing.allocator, "b: {\n  c: 9\n}\ne: 5\n", .{ .comments = false });
    defer ext.deinit();

    const merged = try hjson.merge(a, &base.value, &ext.value);

    const out = try hjson.marshal(testing.allocator, &merged, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\n  b: {\n    c: 9\n    d: 3\n  }\n  e: 5\n  a: 1\n}", out);
}

test "merge: empty containers keep their type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var base = hjson.Value.initMap();
    try base.put(a, "x", hjson.Value.initVector());
    const undef: hjson.Value = .{};

    const merged = try hjson.merge(a, &base, &undef);
    try testing.expectEqual(hjson.Type.vector, merged.get("x").?.getType());
}

test "decode: duplicate key exception reports a diagnostic" {
    var diag: hjson.Diagnostic = .{};
    defer diag.deinit(testing.allocator);

    try testing.expectError(
        error.SyntaxError,
        hjson.unmarshalWithDiagnostic(testing.allocator, "{a: 1, a: 2}", .{ .duplicate_key_exception = true }, &diag),
    );
    const prefix = "Found duplicate of key 'a'";
    try testing.expect(diag.message.len >= prefix.len);
    try testing.expect(std.mem.startsWith(u8, diag.message, prefix));
}

test "decode: unterminated object is a syntax error" {
    try testing.expectError(
        error.SyntaxError,
        hjson.unmarshal(testing.allocator, "{a: 1", .{}),
    );
}

test "value: lenient conversions" {
    const d = hjson.Value.initDouble(1.5);
    const i = hjson.Value.initInt(7);
    try testing.expectEqual(@as(f64, 7.0), try i.asF64());
    try testing.expectEqual(@as(i64, 1), try d.asI64());
    try testing.expectError(error.TypeMismatch, d.asString());

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try hjson.Value.initString(arena.allocator(), "2.5");
    try testing.expectEqual(@as(f64, 2.5), try s.toF64());
}

test "value: double to string" {
    const cases = [_]struct { d: f64, want: []const u8 }{
        .{ .d = 1.0, .want = "1.0" },
        .{ .d = 0.1, .want = "0.1" },
        .{ .d = 123.456, .want = "123.456" },
        .{ .d = -2.5, .want = "-2.5" },
        .{ .d = 100000.0, .want = "100000.0" },
        .{ .d = 1e20, .want = "1.0e+20" },
        .{ .d = 1.5e-7, .want = "1.5e-07" },
    };
    for (cases) |c| {
        const v = hjson.Value.initDouble(c.d);
        const s = try v.toStringAlloc(testing.allocator);
        defer testing.allocator.free(s);
        try testing.expectEqualStrings(c.want, s);
    }
}
