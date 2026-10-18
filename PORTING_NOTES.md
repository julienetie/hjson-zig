# hjson-zig: porting notes

Port of [hjson-cpp](https://github.com/hjson/hjson-cpp) (`hjson_decode.cpp`,
`hjson_encode.cpp`, `hjson_value.cpp`, `hjson_parsenumber.cpp`, `hjson.h`) to
Zig 0.17.0.

**Status: written without a Zig compiler.** The sandbox had no toolchain and
no network, so none of this has been compiled or run. Expect to fix a handful
of compile errors on first `zig build test`. Everything was written against
the 0.17.0 release notes; std calls that those notes flag as renamed or
deprecated (`std.builtin`, `@intFromEnum`, `fmt.allocPrint`, `ArrayList.getLast*`,
`**`, `DebugAllocator`) are avoided.

## Layout

| File | C++ origin |
|---|---|
| `src/options.zig` | `DecoderOptions`, `EncoderOptions` in hjson.h |
| `src/number.zig` | `hjson_parsenumber.cpp` + number formatting from `Value::to_string` |
| `src/value.zig` | `hjson_value.cpp` (+ `Merge`) |
| `src/decode.zig` | `hjson_decode.cpp` |
| `src/encode.zig` | `hjson_encode.cpp` |
| `src/root.zig` | public API (re-exports) |
| `src/tests.zig` | hand-traced unit tests |

The decoder and encoder keep the C++ explicit state machines, so deeply nested
documents cannot overflow the stack. `merge` and `clone` are recursive, as in
the C++ code.

## API mapping

| C++ | Zig |
|---|---|
| `Unmarshal(text, opt)` | `unmarshal(gpa, text, opt) !Parsed` (`parsed.deinit()`) |
| exceptions (`syntax_error`) | `error.SyntaxError`; message via `unmarshalWithDiagnostic` + `Diagnostic` |
| `Marshal(v, opt)` | `marshal(gpa, &v, opt) ![]u8` (caller frees) |
| `MarshalJson(v)` | `marshalJson(gpa, &v)` |
| `Merge(base, ext)` | `merge(arena, &base, &ext)` |
| `Value::type()` | `v.getType()`; `Type.undef/nil/boolean/double/int64/string/vector/map` |
| `v["k"]` (const) | `v.get("k") ?*const Value` |
| `v["k"] = x` | `v.put(a, "k", x)`; `assign_with_comments` is `putWithComments` |
| `v.at("k")` / `v[i]` | `v.at(k)` / `v.atIndex(i)` (error unions) |
| `push_back`, `erase`, `move`, `key`, `size`, `empty`, `clear` | `pushBack`, `eraseIndex`/`eraseKey`, `move`, `keyAt`, `size`, `isEmpty`, `clear` |
| `to_double/to_int64/to_string` | `toF64`, `toI64`, `toStringAlloc` (+ strict `asF64/asI64/asString/asBool`) |
| `get_comment_before()` etc. | `v.comments.before/key/inside/after`; setters `setCommentBefore(a, s)` etc. |
| `deep_equal` | `eql` |
| `unknownAsNull` option | present, unused (the C++ sources don't use it either) |

Not ported on purpose: arithmetic/comparison operators on `Value`, implicit
conversion operators, `MapProxy`, `std::istream`/`ostream` operators, the three
`HJSON_NUMBER_PARSER` variants (Zig's `std.fmt` is locale independent), and
`UnmarshalFromFile` / `MarshalToFile` (file I/O in std changed across 0.16/0.17;
read the file yourself and pass it through `trimFileTail`, which reproduces
what `UnmarshalFromFile` strips; append `options.eol` yourself after writing,
like `MarshalToFile` does).

## Memory model

C++ `Value` shares containers through `shared_ptr`. Zig `Value` is a plain
struct. A tree and every string/key in it must live in one arena. `unmarshal`
returns a `Parsed` owning that arena. Copying a `Value` struct aliases
containers; use `clone(a)` for deep copies. `==` on containers (pointer
identity in C++) has no equivalent; use `eql`.

## Deliberate deviations from the C++ behaviour

1. `clone()` and `Merge()` returned **Undefined** for empty vectors/maps and
   for merging two empty maps (they started from an Undefined `Value`).
   Here the type is preserved.
2. `deep_equal` on maps compared only the values in key order and never the
   keys. `eql` also compares keys (and ignores insertion order).
3. Doubles in exponent form with a one-digit mantissa were written as
   `1e+20.0` (does not parse back). Here: `1.0e+20`.
4. `a:` followed directly by EOF: the C++ code read one byte past the input
   (and yields a string containing `\0`). Here the value is an empty string.
5. Double formatting emulates `%.15g` via `{e:.14}`; NaN/Inf in `toStringAlloc`
   give `nan`/`inf` (the encoder still writes `null`).

## Quirks kept on purpose (faithful to the C++ code)

- `\uD83D\uDE00` style surrogate pairs are decoded as two separate 3-byte
  sequences (invalid UTF-8); hjson-go combines them. Easy to fix if wanted.
- Multiline-string encoding treats `\r\n` as two line breaks (the regex
  `\r|\n|\r\n` matches `\r` first).
- Duplicate keys (when not an error) keep the first key's position.
- The `!(vParent.empty() && withoutBraces)` condition in `_readObjectBegin`
  is always true; kept literally.

## Things to verify first

- `zig build test` (see the note at the top of `src/tests.zig` about
  hand-derived expectations).
- `build.zig.zon` fingerprint placeholder (`zig build` prints the right one).
- `std.fmt` `{e:.14}` output shape for `f64` in 0.17 (the code parses mantissa
  digits and exponent leniently, so either `e0` or `e+00` is fine).
- `std.heap.ArenaAllocator` API (`init(child)`, `allocator()`, `deinit()`),
  `ArrayList` / `StringArrayHashMapUnmanaged` unmanaged method names
  (`.empty`, `append(gpa, x)`, `ensureTotalCapacity`, `putAssumeCapacity`,
  `orderedRemoveAt`, `shrinkRetainingCapacity`).
- Next step: port hjson-cpp's `test/` asset suite and compare output
  byte-for-byte.

## License

hjson-cpp is MIT licensed. This port is a derivative work: keep the upstream
copyright and permission notice (copy hjson-cpp's `LICENSE`) with it.
