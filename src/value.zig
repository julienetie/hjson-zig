//! The Hjson value tree. Port of hjson_value.cpp.
//!
//! Ownership model (differs from the C++ shared_ptr model): a Value tree does
//! not free anything by itself. Allocate every Value tree (and every string
//! and key stored in it) from ONE arena allocator and free the arena when
//! done. `decode.Parsed` does exactly that for parsed documents.
//!
//! Values are plain values: copying a `Value` copies the struct, and for
//! Vector/Map that aliases the same backing storage. Use `clone()` for a deep
//! copy.

const std = @import("std");
const Allocator = std.mem.Allocator;
const number = @import("number.zig");

/// Same variants as Hjson::Type. (`undef`/`nil`/`boolean` avoid Zig keywords.)
pub const Type = enum { undef, nil, boolean, double, int64, string, vector, map };

pub const Comments = struct {
    before: []const u8 = "",
    key: []const u8 = "",
    inside: []const u8 = "",
    after: []const u8 = "",

    pub fn clone(self: Comments, a: Allocator) Allocator.Error!Comments {
        return .{
            .before = try a.dupe(u8, self.before),
            .key = try a.dupe(u8, self.key),
            .inside = try a.dupe(u8, self.inside),
            .after = try a.dupe(u8, self.after),
        };
    }
};

/// Hjson::type_mismatch / Hjson::index_out_of_bounds equivalents.
pub const MutateError = error{ OutOfMemory, TypeMismatch };
pub const AccessError = error{ TypeMismatch, IndexOutOfBounds };
pub const ConvertError = error{TypeMismatch};

pub const Vector = std.ArrayList(Value);
/// Insertion-ordered string map.
pub const Map = std.StringArrayHashMapUnmanaged(Value);

pub const Value = struct {
    data: Data = .undef,
    comments: Comments = .{},

    pub const Data = union(Type) {
        undef,
        nil,
        boolean: bool,
        double: f64,
        int64: i64,
        string: []const u8,
        vector: Vector,
        map: Map,
    };

    // ---- construction ----------------------------------------------------

    pub fn initNull() Value {
        return .{ .data = .nil };
    }

    pub fn initBool(b: bool) Value {
        return .{ .data = .{ .boolean = b } };
    }

    pub fn initInt(i: i64) Value {
        return .{ .data = .{ .int64 = i } };
    }

    pub fn initDouble(d: f64) Value {
        return .{ .data = .{ .double = d } };
    }

    /// Copies `s` into `a`.
    pub fn initString(a: Allocator, s: []const u8) Allocator.Error!Value {
        return .{ .data = .{ .string = try a.dupe(u8, s) } };
    }

    pub fn initVector() Value {
        return .{ .data = .{ .vector = .empty } };
    }

    pub fn initMap() Value {
        return .{ .data = .{ .map = .empty } };
    }

    pub fn fromNumber(n: number.Number) Value {
        return switch (n) {
            .int => |i| Value.initInt(i),
            .double => |d| Value.initDouble(d),
        };
    }

    // ---- inspection --------------------------------------------------------

    pub fn getType(self: *const Value) Type {
        return std.meta.activeTag(self.data);
    }

    /// True if the type is anything else than Undefined.
    pub fn isDefined(self: *const Value) bool {
        return self.getType() != .undef;
    }

    /// True for Undefined, Null, empty String, empty Vector and empty Map.
    pub fn isEmpty(self: *const Value) bool {
        return switch (self.data) {
            .undef, .nil => true,
            .string => |s| s.len == 0,
            .vector => |v| v.items.len == 0,
            .map => |m| m.count() == 0,
            else => false,
        };
    }

    pub fn isContainer(self: *const Value) bool {
        return switch (self.data) {
            .vector, .map => true,
            else => false,
        };
    }

    pub fn isNumeric(self: *const Value) bool {
        return switch (self.data) {
            .double, .int64 => true,
            else => false,
        };
    }

    /// Number of child elements for Vector/Map, 0 for everything else.
    pub fn size(self: *const Value) usize {
        return switch (self.data) {
            .vector => |v| v.items.len,
            .map => |m| m.count(),
            else => 0,
        };
    }

    // ---- access ----------------------------------------------------------

    /// Lenient lookup: null if this is not a Map or the key is missing.
    /// (Replaces the const `operator[](string)` that returned Undefined.)
    pub fn get(self: *const Value, key: []const u8) ?*const Value {
        return switch (self.data) {
            .map => |m| m.getPtr(key),
            else => null,
        };
    }

    /// Mutable variant of `get`.
    pub fn getMut(self: *Value, key: []const u8) ?*Value {
        return switch (self.data) {
            .map => |m| m.getPtr(key),
            else => null,
        };
    }

    /// Strict lookup (Value::at): IndexOutOfBounds if the key is missing or
    /// this Value is Undefined, TypeMismatch if it is not a Map.
    pub fn at(self: *Value, key: []const u8) AccessError!*Value {
        switch (self.data) {
            .undef => return error.IndexOutOfBounds,
            .map => |m| return m.getPtr(key) orelse error.IndexOutOfBounds,
            else => return error.TypeMismatch,
        }
    }

    /// Strict access by index (Vector index, or Map insertion index).
    pub fn atIndex(self: *Value, i: usize) AccessError!*Value {
        switch (self.data) {
            .undef => return error.IndexOutOfBounds,
            .vector => |v| {
                if (i >= v.items.len) return error.IndexOutOfBounds;
                return &v.items[i];
            },
            .map => |m| {
                const vals = m.values();
                if (i >= vals.len) return error.IndexOutOfBounds;
                return &vals[i];
            },
            else => return error.TypeMismatch,
        }
    }

    /// Key by zero-based insertion index.
    pub fn keyAt(self: *const Value, i: usize) AccessError![]const u8 {
        switch (self.data) {
            .undef => return error.IndexOutOfBounds,
            .map => |m| {
                const ks = m.keys();
                if (i >= ks.len) return error.IndexOutOfBounds;
                return ks[i];
            },
            else => return error.TypeMismatch,
        }
    }

    // ---- mutation --------------------------------------------------------

    fn ensureMap(self: *Value) error{TypeMismatch}!void {
        switch (self.data) {
            .undef => self.data = .{ .map = .empty },
            .map => {},
            else => return error.TypeMismatch,
        }
    }

    /// C++ `map[key] = v`. An Undefined `self` becomes a Map. An existing,
    /// defined element keeps its own comments; a new (or Undefined) element
    /// takes the comments of `v`. The key is copied into `a`.
    pub fn put(self: *Value, a: Allocator, key: []const u8, v: Value) MutateError!void {
        try self.ensureMap();
        if (self.data.map.getPtr(key)) |slot| {
            const keep = slot.comments;
            const was_defined = slot.isDefined();
            slot.* = v;
            if (was_defined) slot.comments = keep;
            return;
        }
        const owned = try a.dupe(u8, key);
        try self.data.map.put(a, owned, v);
    }

    /// C++ `map[key].assign_with_comments(v)`: like `put`, but the element
    /// always takes the comments of `v`.
    pub fn putWithComments(self: *Value, a: Allocator, key: []const u8, v: Value) MutateError!void {
        try self.ensureMap();
        if (self.data.map.getPtr(key)) |slot| {
            slot.* = v;
            return;
        }
        const owned = try a.dupe(u8, key);
        try self.data.map.put(a, owned, v);
    }

    /// Like `putWithComments` but stores `key` without copying it. `key` must
    /// already live in the same arena as the rest of the tree.
    pub fn putOwnedKey(self: *Value, a: Allocator, key: []const u8, v: Value) MutateError!void {
        try self.ensureMap();
        if (self.data.map.getPtr(key)) |slot| {
            slot.* = v;
            return;
        }
        try self.data.map.put(a, key, v);
    }

    /// Appends to a Vector. An Undefined `self` becomes a Vector.
    pub fn pushBack(self: *Value, a: Allocator, v: Value) MutateError!void {
        switch (self.data) {
            .undef => self.data = .{ .vector = .empty },
            .vector => {},
            else => return error.TypeMismatch,
        }
        try self.data.vector.append(a, v);
    }

    /// Removes all children of a Vector or Map. No-op for other types.
    pub fn clear(self: *Value) void {
        switch (self.data) {
            .vector => |*v| v.clearRetainingCapacity(),
            .map => |*m| m.clearRetainingCapacity(),
            else => {},
        }
    }

    /// Removes one child by index (Vector index or Map insertion index).
    pub fn eraseIndex(self: *Value, i: usize) AccessError!void {
        switch (self.data) {
            .undef => return error.IndexOutOfBounds,
            .vector => |*v| {
                if (i >= v.items.len) return error.IndexOutOfBounds;
                _ = v.orderedRemove(i);
            },
            .map => |*m| {
                if (i >= m.count()) return error.IndexOutOfBounds;
                m.orderedRemoveAt(i);
            },
            else => return error.TypeMismatch,
        }
    }

    /// Removes a Map child by key. Returns the number of erased elements
    /// (0 or 1). Undefined yields 0.
    pub fn eraseKey(self: *Value, key: []const u8) ConvertError!usize {
        switch (self.data) {
            .undef => return 0,
            .map => |*m| return if (m.orderedRemove(key)) 1 else 0,
            else => return error.TypeMismatch,
        }
    }

    /// Value::move. If `from < to` the element ends up at index `to - 1`.
    /// For a Map this changes the insertion order.
    pub fn move(self: *Value, a: Allocator, from: usize, to: usize) (Allocator.Error || AccessError)!void {
        switch (self.data) {
            .undef, .vector, .map => {},
            else => return error.TypeMismatch,
        }
        const n = self.size();
        if (from >= n or to > n) return error.IndexOutOfBounds;
        if (from == to) return;

        const perm = try a.alloc(usize, n);
        for (perm, 0..) |*slot, i| slot.* = i;
        const item = perm[from];
        if (from < to) {
            var i = from;
            while (i + 1 < to) : (i += 1) perm[i] = perm[i + 1];
            perm[to - 1] = item;
        } else {
            var i = from;
            while (i > to) : (i -= 1) perm[i] = perm[i - 1];
            perm[to] = item;
        }

        switch (self.data) {
            .vector => |*v| {
                const copy = try a.dupe(Value, v.items);
                for (perm, 0..) |src, dst| v.items[dst] = copy[src];
            },
            .map => |*m| {
                var nm: Map = .empty;
                try nm.ensureTotalCapacity(a, n);
                const ks = m.keys();
                const vs = m.values();
                for (perm) |src| nm.putAssumeCapacity(ks[src], vs[src]);
                m.* = nm; // the old storage stays in the arena
            },
            else => unreachable,
        }
    }

    // ---- comments --------------------------------------------------------

    pub fn setCommentBefore(self: *Value, a: Allocator, s: []const u8) Allocator.Error!void {
        self.comments.before = try a.dupe(u8, s);
    }

    pub fn setCommentKey(self: *Value, a: Allocator, s: []const u8) Allocator.Error!void {
        self.comments.key = try a.dupe(u8, s);
    }

    pub fn setCommentInside(self: *Value, a: Allocator, s: []const u8) Allocator.Error!void {
        self.comments.inside = try a.dupe(u8, s);
    }

    pub fn setCommentAfter(self: *Value, a: Allocator, s: []const u8) Allocator.Error!void {
        self.comments.after = try a.dupe(u8, s);
    }

    /// Copies all comments from `other` (shares the slices; same arena).
    pub fn setComments(self: *Value, other: *const Value) void {
        self.comments = other.comments;
    }

    pub fn clearComments(self: *Value) void {
        self.comments = .{};
    }

    // ---- copy / compare ----------------------------------------------------

    /// Deep copy (comments included) into allocator `a`. Unlike the C++
    /// code, empty Vectors and Maps keep their type.
    pub fn clone(self: *const Value, a: Allocator) Allocator.Error!Value {
        var out: Value = .{ .comments = try self.comments.clone(a) };
        switch (self.data) {
            .undef, .nil, .boolean, .double, .int64 => out.data = self.data,
            .string => |s| out.data = .{ .string = try a.dupe(u8, s) },
            .vector => |v| {
                var nv: Vector = .empty;
                try nv.ensureTotalCapacity(a, v.items.len);
                for (v.items) |*e| {
                    nv.appendAssumeCapacity(try e.clone(a));
                }
                out.data = .{ .vector = nv };
            },
            .map => |m| {
                var nm: Map = .empty;
                try nm.ensureTotalCapacity(a, m.count());
                for (m.keys(), m.values()) |k, *v| {
                    nm.putAssumeCapacity(try a.dupe(u8, k), try v.clone(a));
                }
                out.data = .{ .map = nm };
            },
        }
        return out;
    }

    /// Deep equality (Value::deep_equal). Comments are ignored, Int64 and
    /// Double compare numerically, Map comparison ignores insertion order.
    pub fn eql(self: *const Value, other: *const Value) bool {
        switch (self.data) {
            .double => |x| switch (other.data) {
                .int64 => |y| return x == @as(f64, @floatFromInt(y)),
                else => {},
            },
            .int64 => |x| switch (other.data) {
                .double => |y| return @as(f64, @floatFromInt(x)) == y,
                else => {},
            },
            else => {},
        }
        if (self.getType() != other.getType()) return false;
        switch (self.data) {
            .undef, .nil => return true,
            .boolean => |x| return x == other.data.boolean,
            .double => |x| return x == other.data.double,
            .int64 => |x| return x == other.data.int64,
            .string => |x| return std.mem.eql(u8, x, other.data.string),
            .vector => |x| {
                const y = other.data.vector;
                if (x.items.len != y.items.len) return false;
                for (x.items, y.items) |*l, *r| {
                    if (!l.eql(r)) return false;
                }
                return true;
            },
            .map => |x| {
                const y = other.data.map;
                if (x.count() != y.count()) return false;
                for (x.keys(), x.values()) |k, *l| {
                    const r = y.getPtr(k) orelse return false;
                    if (!l.eql(r)) return false;
                }
                return true;
            },
        }
    }

    // ---- conversion --------------------------------------------------------

    /// C++ `operator bool`.
    pub fn truthy(self: *const Value) bool {
        return switch (self.data) {
            .double => |d| d != 0,
            .int64 => |i| i != 0,
            .boolean => |b| b,
            else => !self.isEmpty(),
        };
    }

    /// Strict accessors: TypeMismatch unless the Value has exactly this type
    /// (numbers convert between Int64 and Double).
    pub fn asBool(self: *const Value) ConvertError!bool {
        return switch (self.data) {
            .boolean => |b| b,
            else => error.TypeMismatch,
        };
    }

    pub fn asF64(self: *const Value) ConvertError!f64 {
        return switch (self.data) {
            .double => |d| d,
            .int64 => |i| @as(f64, @floatFromInt(i)),
            else => error.TypeMismatch,
        };
    }

    pub fn asI64(self: *const Value) ConvertError!i64 {
        return switch (self.data) {
            .double => |d| saturatingI64(d),
            .int64 => |i| i,
            else => error.TypeMismatch,
        };
    }

    pub fn asString(self: *const Value) ConvertError![]const u8 {
        return switch (self.data) {
            .string => |s| s,
            else => error.TypeMismatch,
        };
    }

    /// Value::to_double: lenient. Undefined/Null -> 0, Bool -> 0/1, strings
    /// are parsed (0.0 on failure). Vector/Map -> TypeMismatch.
    pub fn toF64(self: *const Value) ConvertError!f64 {
        return switch (self.data) {
            .undef, .nil => 0.0,
            .boolean => |b| if (b) 1.0 else 0.0,
            .double => |d| d,
            .int64 => |i| @as(f64, @floatFromInt(i)),
            .string => |s| number.parseLooseF64(s) orelse 0.0,
            .vector, .map => error.TypeMismatch,
        };
    }

    /// Value::to_int64: lenient, see `toF64`. Out-of-range doubles saturate.
    pub fn toI64(self: *const Value) ConvertError!i64 {
        return switch (self.data) {
            .undef, .nil => 0,
            .boolean => |b| if (b) 1 else 0,
            .double => |d| saturatingI64(d),
            .int64 => |i| i,
            .string => |s| number.parseLooseI64(s) orelse saturatingI64(number.parseLooseF64(s) orelse 0.0),
            .vector, .map => error.TypeMismatch,
        };
    }

    /// Value::to_string. Caller owns the returned slice.
    pub fn toStringAlloc(self: *const Value, a: Allocator) (Allocator.Error || ConvertError)![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(a);
        switch (self.data) {
            .undef => {},
            .nil => try list.appendSlice(a, "null"),
            .boolean => |b| try list.appendSlice(a, if (b) "true" else "false"),
            .double => |d| try number.appendDouble(&list, a, d),
            .int64 => |i| try number.appendInt(&list, a, i),
            .string => |s| try list.appendSlice(a, s),
            .vector, .map => return error.TypeMismatch,
        }
        return list.toOwnedSlice(a);
    }
};

fn saturatingI64(d: f64) i64 {
    if (std.math.isNan(d)) return 0;
    if (d >= 9223372036854775807.0) return std.math.maxInt(i64);
    if (d <= -9223372036854775808.0) return std.math.minInt(i64);
    return @intFromFloat(d);
}

fn bytesLess(x: []const u8, y: []const u8) bool {
    const n = @min(x.len, y.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (x[i] != y[i]) return x[i] < y[i];
    }
    return x.len < y.len;
}

/// Indices of the map's entries sorted by key (byte-wise, like std::map).
/// Caller frees the result with `gpa`.
pub fn sortedOrder(gpa: Allocator, map: *const Map) Allocator.Error![]usize {
    const idx = try gpa.alloc(usize, map.count());
    for (idx, 0..) |*slot, i| slot.* = i;
    const Ctx = struct {
        keys: []const []const u8,
        fn lessThan(ctx: @This(), l: usize, r: usize) bool {
            return bytesLess(ctx.keys[l], ctx.keys[r]);
        }
    };
    std.mem.sort(usize, idx, Ctx{ .keys = map.keys() }, Ctx.lessThan);
    return idx;
}

/// Returns a Value tree that is a combination of `base` and `ext`.
///
/// If both have a map at the same place, the result has the union of their
/// keys (ext keys first, then base-only keys); for keys in both, `ext` wins
/// unless its value is Undefined. Vectors are not merged: `ext` wins.
/// If `ext` is Undefined a clone of `base` is returned. Everything in the
/// result is cloned into `a`.
///
/// Recursive in the depth of the trees.
pub fn merge(a: Allocator, base: *const Value, ext: *const Value) Allocator.Error!Value {
    if (!ext.isDefined()) {
        return base.clone(a);
    }
    if (base.getType() == .map and ext.getType() == .map) {
        var merged = Value.initMap();
        const mm = &merged.data.map;
        const base_map = base.data.map;
        const ext_map = ext.data.map;

        try mm.ensureTotalCapacity(a, ext_map.count() + base_map.count());

        for (ext_map.keys(), ext_map.values()) |k, *ev| {
            const owned = try a.dupe(u8, k);
            if (base.get(k)) |bv| {
                if (bv.isDefined()) {
                    mm.putAssumeCapacity(owned, try merge(a, bv, ev));
                    continue;
                }
            }
            mm.putAssumeCapacity(owned, try ev.clone(a));
        }

        for (base_map.keys(), base_map.values()) |k, *bv| {
            if (mm.getPtr(k)) |slot| {
                if (!slot.isDefined()) {
                    slot.* = try bv.clone(a);
                }
            } else {
                mm.putAssumeCapacity(try a.dupe(u8, k), try bv.clone(a));
            }
        }

        merged.comments = try ext.comments.clone(a);
        return merged;
    }
    return ext.clone(a);
}
