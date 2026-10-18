//! Hjson for Zig: a port of hjson-cpp (https://github.com/hjson/hjson-cpp).
//!
//! ```zig
//! var parsed = try hjson.unmarshal(gpa, text, .{});
//! defer parsed.deinit();
//!
//! const rate = parsed.value.get("rate") orelse return error.Missing;
//! std.debug.print("rate = {d}\n", .{try rate.asI64()});
//!
//! const out = try hjson.marshal(gpa, &parsed.value, .{});
//! defer gpa.free(out);
//! ```
//!
//! Memory: a Value tree never frees itself. `unmarshal` returns a `Parsed`
//! that owns an arena with the whole tree; when you build or merge trees
//! yourself, use one arena allocator for everything and free it at once.

const options = @import("options.zig");
const value = @import("value.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");

pub const DecoderOptions = options.DecoderOptions;
pub const EncoderOptions = options.EncoderOptions;

pub const Value = value.Value;
pub const Type = value.Type;
pub const Comments = value.Comments;
pub const Vector = value.Vector;
pub const Map = value.Map;
pub const MutateError = value.MutateError;
pub const AccessError = value.AccessError;
pub const ConvertError = value.ConvertError;
pub const merge = value.merge;
pub const sortedOrder = value.sortedOrder;

pub const Parsed = decode.Parsed;
pub const Diagnostic = decode.Diagnostic;
pub const UnmarshalError = decode.Error;
pub const unmarshal = decode.unmarshal;
pub const unmarshalWithDiagnostic = decode.unmarshalWithDiagnostic;
pub const trimFileTail = decode.trimFileTail;

pub const marshal = encode.marshal;
pub const marshalJson = encode.marshalJson;

test {
    _ = @import("tests.zig");
}
